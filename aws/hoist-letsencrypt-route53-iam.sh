#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 4 ]]; then
  echo "Usage: $0 <hosted_zone_name> [user_name] [role_name] [credentials_file]"
  echo "Example: $0 oursky.com letsencrypt-dns-user letsencrypt-route53-role ./letsencrypt-dns-user.credentials"
  exit 1
fi

HOSTED_ZONE_NAME_RAW="$1"
HOSTED_ZONE_NAME="${HOSTED_ZONE_NAME_RAW%.}"
DEFAULT_USER_NAME="${HOSTED_ZONE_NAME//./-}-letsencrypt-user"
DEFAULT_ROLE_NAME="${HOSTED_ZONE_NAME//./-}-letsencrypt-route53-role"
USER_NAME="${2:-${DEFAULT_USER_NAME}}"
ROLE_NAME="${3:-${DEFAULT_ROLE_NAME}}"
DEFAULT_CREDENTIALS_FILE="${PWD}/${USER_NAME}.credentials"
CREDENTIALS_FILE="${4:-${DEFAULT_CREDENTIALS_FILE}}"
USER_INLINE_POLICY_NAME="${USER_NAME}-assume-${ROLE_NAME}"
ROLE_INLINE_POLICY_NAME="${ROLE_NAME}-route53-inline"
AWS_REGION="${AWS_REGION:-$(aws configure get region || true)}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

has_value() {
  local value="${1:-}"
  [[ -n "${value}" && "${value}" != "None" && "${value}" != "null" ]]
}

mask_value() {
  local value="$1"
  local prefix_length="${2:-4}"
  local suffix_length="${3:-4}"
  local value_length
  local prefix
  local suffix

  value_length="${#value}"
  if (( value_length <= prefix_length + suffix_length )); then
    echo "${value}"
    return
  fi

  prefix="${value:0:prefix_length}"
  suffix="${value:value_length-suffix_length:suffix_length}"
  echo "${prefix}***${suffix}"
}

user_exists() {
  aws iam get-user --user-name "${USER_NAME}" >/dev/null 2>&1
}

role_exists() {
  aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1
}

credentials_file_exists() {
  [[ -f "${CREDENTIALS_FILE}" ]]
}

write_credentials_file() {
  local access_key_id="$1"
  local secret_access_key="$2"

  cat > "${CREDENTIALS_FILE}" <<EOF
[default]
aws_access_key_id = ${access_key_id}
aws_secret_access_key = ${secret_access_key}
EOF

  if has_value "${AWS_REGION}"; then
    cat >> "${CREDENTIALS_FILE}" <<EOF
region = ${AWS_REGION}
EOF
  fi

  chmod 600 "${CREDENTIALS_FILE}"
}

create_access_key() {
  aws iam create-access-key \
    --user-name "${USER_NAME}" \
    --query 'AccessKey.[AccessKeyId,SecretAccessKey]' \
    --output text
}

ensure_user_access_key() {
  local access_key_output
  local active_key_count

  if credentials_file_exists; then
    echo ""
    return
  fi

  active_key_count="$(aws iam list-access-keys \
    --user-name "${USER_NAME}" \
    --query 'length(AccessKeyMetadata[?Status==`Active`])' \
    --output text 2>/dev/null || true)"

  if ! has_value "${active_key_count}"; then
    active_key_count="0"
  fi

  if [[ "${active_key_count}" -ge 2 ]]; then
    echo "Error: IAM user ${USER_NAME} already has 2 active access keys. Delete one or provide an existing credentials file at ${CREDENTIALS_FILE}." >&2
    exit 1
  fi

  access_key_output="$(create_access_key)"
  echo "${access_key_output}"
}

HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name \
  --dns-name "${HOSTED_ZONE_NAME}" \
  --query "HostedZones[?Name=='${HOSTED_ZONE_NAME}.' && Config.PrivateZone==\`false\`] | [0].Id" \
  --output text | sed 's|/hostedzone/||')"

if ! has_value "${HOSTED_ZONE_ID}"; then
  echo "Error: public Route 53 hosted zone for ${HOSTED_ZONE_NAME} not found"
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"
USER_ARN="arn:aws:iam::${ACCOUNT_ID}:user/${USER_NAME}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
HOSTED_ZONE_ARN="arn:aws:route53:::hostedzone/${HOSTED_ZONE_ID}"

cat > "${TMP_DIR}/trust-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "${USER_ARN}"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

cat > "${TMP_DIR}/role-inline-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ChangeAcmeTxtRecord",
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": "${HOSTED_ZONE_ARN}",
      "Condition": {
        "ForAllValues:StringEquals": {
          "route53:ChangeResourceRecordSetsRecordTypes": [
            "TXT"
          ],
          "route53:ChangeResourceRecordSetsActions": [
            "UPSERT",
            "DELETE"
          ]
        }
      }
    },
    {
      "Sid": "ListZoneRecords",
      "Effect": "Allow",
      "Action": [
        "route53:ListResourceRecordSets"
      ],
      "Resource": "${HOSTED_ZONE_ARN}"
    },
    {
      "Sid": "ReadZoneMetadata",
      "Effect": "Allow",
      "Action": [
        "route53:GetChange",
        "route53:GetHostedZone"
      ],
      "Resource": "*"
    },
    {
      "Sid": "FindHostedZoneByName",
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZonesByName"
      ],
      "Resource": "*"
    }
  ]
}
JSON

cat > "${TMP_DIR}/user-inline-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "${ROLE_ARN}"
    }
  ]
}
JSON

if user_exists; then
  echo "==> Reusing IAM user: ${USER_NAME}"
else
  echo "==> Creating IAM user: ${USER_NAME}"
  aws iam create-user --user-name "${USER_NAME}" >/dev/null
fi

echo "==> Waiting for IAM user to become visible"
aws iam wait user-exists --user-name "${USER_NAME}"

if role_exists; then
  echo "==> Reusing IAM role: ${ROLE_NAME}"
  echo "==> Updating role trust policy"
  aws iam update-assume-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-document "file://${TMP_DIR}/trust-policy.json"
else
  echo "==> Creating IAM role: ${ROLE_NAME}"
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${TMP_DIR}/trust-policy.json" >/dev/null
fi

echo "==> Applying Route 53 inline policy to role"
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${ROLE_INLINE_POLICY_NAME}" \
  --policy-document "file://${TMP_DIR}/role-inline-policy.json"

echo "==> Applying assume-role inline policy to user"
aws iam put-user-policy \
  --user-name "${USER_NAME}" \
  --policy-name "${USER_INLINE_POLICY_NAME}" \
  --policy-document "file://${TMP_DIR}/user-inline-policy.json"

ACCESS_KEY_OUTPUT="$(ensure_user_access_key)"
ACCESS_KEY_ID=""
SECRET_ACCESS_KEY=""

if has_value "${ACCESS_KEY_OUTPUT}"; then
  read -r ACCESS_KEY_ID SECRET_ACCESS_KEY <<<"${ACCESS_KEY_OUTPUT}"
  write_credentials_file "${ACCESS_KEY_ID}" "${SECRET_ACCESS_KEY}"
  echo "==> Wrote AWS CLI credentials file: ${CREDENTIALS_FILE}"
  echo "    Access key: $(mask_value "${ACCESS_KEY_ID}")"
  echo "    Secret key: $(mask_value "${SECRET_ACCESS_KEY}" 4 4)"
elif credentials_file_exists; then
  echo "==> Reusing existing credentials file: ${CREDENTIALS_FILE}"
else
  echo "Error: credentials file was not written and no existing file was found at ${CREDENTIALS_FILE}" >&2
  exit 1
fi

cat <<EOF

Done.

Hosted zone:                 ${HOSTED_ZONE_NAME}
Hosted zone ID:              ${HOSTED_ZONE_ID}
IAM user:                    ${USER_NAME}
IAM role:                    ${ROLE_NAME}
Role ARN:                    ${ROLE_ARN}
User inline policy:          ${USER_INLINE_POLICY_NAME}
Role inline policy:          ${ROLE_INLINE_POLICY_NAME}
Credentials file:            ${CREDENTIALS_FILE}

Example assume-role profile:

[profile letsencrypt-route53]
role_arn = ${ROLE_ARN}
source_profile = default
region = ${AWS_REGION:-us-east-1}

Use with:
AWS_SHARED_CREDENTIALS_FILE=${CREDENTIALS_FILE} aws sts assume-role --role-arn ${ROLE_ARN} --role-session-name letsencrypt-test

EOF
