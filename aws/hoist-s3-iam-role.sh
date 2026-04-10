#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 <bucket> [user_name] [credentials_file]"
  echo "Example: $0 subdomain.oursky.com subdomain.oursky.com-s3-user ./subdomain.oursky.com-s3-user.credentials"
  exit 1
fi

BUCKET="$1"
USER_NAME="${2:-${BUCKET}-s3-user}"
DEFAULT_CREDENTIALS_FILE="${PWD}/${USER_NAME}.credentials"
CREDENTIALS_FILE="${3:-${DEFAULT_CREDENTIALS_FILE}}"
INLINE_POLICY_NAME="${BUCKET}-s3-inline"
AWS_REGION="${AWS_REGION:-$(aws configure get region || true)}"
BUCKET_ARN="arn:aws:s3:::${BUCKET}"
OBJECT_ARN="${BUCKET_ARN}/*"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

has_value() {
  local value="${1:-}"
  [[ -n "${value}" && "${value}" != "None" && "${value}" != "null" ]]
}

user_exists() {
  aws iam get-user --user-name "${USER_NAME}" >/dev/null 2>&1
}

credentials_file_exists() {
  [[ -f "${CREDENTIALS_FILE}" ]]
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

cat > "${TMP_DIR}/inline-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:*"
      ],
      "Resource": [
        "${OBJECT_ARN}",
        "${BUCKET_ARN}"
      ]
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

echo "==> Applying inline IAM policy to user"
aws iam put-user-policy \
  --user-name "${USER_NAME}" \
  --policy-name "${INLINE_POLICY_NAME}" \
  --policy-document "file://${TMP_DIR}/inline-policy.json"

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

Bucket:            ${BUCKET}
User:              ${USER_NAME}
Inline policy:     ${INLINE_POLICY_NAME}
Credentials file:  ${CREDENTIALS_FILE}

EOF