#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <subdomain.oursky.com> [site_dir]"
  exit 1
fi

DOMAIN="$1"
SITE_DIR="${2:-}"
ROOT_ZONE="oursky.com"
CLOUDFRONT_ZONE_ID="Z2FDTNDATAQYW2"
OAC_NAME="${DOMAIN//./-}-oac"

if [[ "$DOMAIN" != *".${ROOT_ZONE}" ]]; then
  echo "Error: domain must end with .${ROOT_ZONE}"
  exit 1
fi

if [[ "$DOMAIN" == "$ROOT_ZONE" ]]; then
  echo "Error: expected a subdomain like app.${ROOT_ZONE}, not the zone apex"
  exit 1
fi

AWS_REGION="${AWS_REGION:-$(aws configure get region || true)}"
if [[ -z "${AWS_REGION}" ]]; then
  echo "Error: AWS region is not set. Export AWS_REGION or configure a default region."
  exit 1
fi

if [[ -n "${SITE_DIR}" && ! -d "${SITE_DIR}" ]]; then
  echo "Error: site directory not found: ${SITE_DIR}"
  exit 1
fi

has_value() {
  local value="${1:-}"
  [[ -n "${value}" && "${value}" != "None" && "${value}" != "null" ]]
}

bucket_exists() {
  aws s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1
}

find_certificate_arn() {
  local cert_arn

  cert_arn="$(aws acm list-certificates \
    --region us-east-1 \
    --certificate-statuses ISSUED \
    --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn | [0]" \
    --output text 2>/dev/null || true)"
  if has_value "${cert_arn}"; then
    echo "${cert_arn}"
    return
  fi

  aws acm list-certificates \
    --region us-east-1 \
    --certificate-statuses PENDING_VALIDATION INACTIVE \
    --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn | [0]" \
    --output text 2>/dev/null || true
}

find_oac_id() {
  aws cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?OriginAccessControlConfig.Name=='${OAC_NAME}'].Id | [0]" \
    --output text 2>/dev/null || true
}

find_distribution() {
  aws cloudfront list-distributions \
    --query "DistributionList.Items[?Aliases.Quantity > \`0\` && contains(Aliases.Items, '${DOMAIN}')].[Id,DomainName,ARN] | [0]" \
    --output text 2>/dev/null || true
}

HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name \
  --dns-name "${ROOT_ZONE}" \
  --query "HostedZones[?Name=='${ROOT_ZONE}.' && Config.PrivateZone==\`false\`] | [0].Id" \
  --output text | sed 's|/hostedzone/||')"

if [[ -z "${HOSTED_ZONE_ID}" || "${HOSTED_ZONE_ID}" == "None" ]]; then
  echo "Error: public Route 53 hosted zone for ${ROOT_ZONE} not found"
  exit 1
fi

BUCKET="${DOMAIN}"
S3_ORIGIN_DOMAIN="${BUCKET}.s3.${AWS_REGION}.amazonaws.com"
CALLER_REF="$(date +%s)-${DOMAIN//./-}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "==> Ensuring S3 bucket: ${BUCKET}"
if bucket_exists; then
  echo "    Reusing existing bucket"
else
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${BUCKET}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
  fi
fi

aws s3api put-public-access-block \
  --bucket "${BUCKET}" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

aws s3api put-bucket-ownership-controls \
  --bucket "${BUCKET}" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

if [[ -n "${SITE_DIR}" ]]; then
  echo "==> Uploading site from ${SITE_DIR}"
  aws s3 sync "${SITE_DIR}" "s3://${BUCKET}/" --delete
fi

CERT_ARN="$(find_certificate_arn)"
if has_value "${CERT_ARN}"; then
  echo "==> Reusing ACM certificate in us-east-1 for ${DOMAIN}"
else
  echo "==> Requesting ACM certificate in us-east-1 for ${DOMAIN}"
  CERT_ARN="$(aws acm request-certificate \
    --region us-east-1 \
    --domain-name "${DOMAIN}" \
    --validation-method DNS \
    --query 'CertificateArn' \
    --output text)"
fi

CERT_STATUS="$(aws acm describe-certificate \
  --region us-east-1 \
  --certificate-arn "${CERT_ARN}" \
  --query 'Certificate.Status' \
  --output text)"

if [[ "${CERT_STATUS}" != "ISSUED" ]]; then
  echo "==> Fetching DNS validation record"
  for _ in {1..20}; do
    CERT_RECORD_NAME="$(aws acm describe-certificate \
      --region us-east-1 \
      --certificate-arn "${CERT_ARN}" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' \
      --output text 2>/dev/null || true)"
    CERT_RECORD_TYPE="$(aws acm describe-certificate \
      --region us-east-1 \
      --certificate-arn "${CERT_ARN}" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Type' \
      --output text 2>/dev/null || true)"
    CERT_RECORD_VALUE="$(aws acm describe-certificate \
      --region us-east-1 \
      --certificate-arn "${CERT_ARN}" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' \
      --output text 2>/dev/null || true)"

    if has_value "${CERT_RECORD_NAME}"; then
      break
    fi
    sleep 5
  done

  if ! has_value "${CERT_RECORD_NAME}"; then
    echo "Error: ACM validation record was not ready in time"
    exit 1
  fi

  cat > "${TMP_DIR}/cert-validation.json" <<JSON
{
  "Comment": "ACM DNS validation for ${DOMAIN}",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${CERT_RECORD_NAME}",
        "Type": "${CERT_RECORD_TYPE}",
        "TTL": 300,
        "ResourceRecords": [
          { "Value": "${CERT_RECORD_VALUE}" }
        ]
      }
    }
  ]
}
JSON

  echo "==> Ensuring ACM validation DNS record in Route 53"
  aws route53 change-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --change-batch "file://${TMP_DIR}/cert-validation.json" >/dev/null

  echo "==> Waiting for certificate to be issued"
  aws acm wait certificate-validated \
    --region us-east-1 \
    --certificate-arn "${CERT_ARN}"
else
  echo "==> ACM certificate already issued"
fi

OAC_ID="$(find_oac_id)"
if has_value "${OAC_ID}"; then
  echo "==> Reusing CloudFront Origin Access Control"
else
  echo "==> Creating CloudFront Origin Access Control"
  OAC_ID="$(aws cloudfront create-origin-access-control \
    --origin-access-control-config \
    "Name=${OAC_NAME},Description=OAC for ${DOMAIN},SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query 'OriginAccessControl.Id' \
    --output text)"
fi

cat > "${TMP_DIR}/distribution.json" <<JSON
{
  "CallerReference": "${CALLER_REF}",
  "Aliases": {
    "Quantity": 1,
    "Items": ["${DOMAIN}"]
  },
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "s3-${DOMAIN}",
        "DomainName": "${S3_ORIGIN_DOMAIN}",
        "OriginPath": "",
        "CustomHeaders": {
          "Quantity": 0
        },
        "S3OriginConfig": {
          "OriginAccessIdentity": ""
        },
        "ConnectionAttempts": 3,
        "ConnectionTimeout": 10,
        "OriginAccessControlId": "${OAC_ID}"
      }
    ]
  },
  "OriginGroups": {
    "Quantity": 0
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-${DOMAIN}",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": {
        "Quantity": 2,
        "Items": ["GET", "HEAD"]
      }
    },
    "Compress": true,
    "SmoothStreaming": false,
    "LambdaFunctionAssociations": {
      "Quantity": 0
    },
    "FunctionAssociations": {
      "Quantity": 0
    },
    "FieldLevelEncryptionId": "",
    "TrustedSigners": {
      "Enabled": false,
      "Quantity": 0
    },
    "TrustedKeyGroups": {
      "Enabled": false,
      "Quantity": 0
    },
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6"
  },
  "Comment": "Static site for ${DOMAIN}",
  "Logging": {
    "Enabled": false,
    "IncludeCookies": false,
    "Bucket": "",
    "Prefix": ""
  },
  "PriceClass": "PriceClass_100",
  "Enabled": true,
  "ViewerCertificate": {
    "ACMCertificateArn": "${CERT_ARN}",
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021",
    "Certificate": "${CERT_ARN}",
    "CertificateSource": "acm"
  },
  "Restrictions": {
    "GeoRestriction": {
      "RestrictionType": "none",
      "Quantity": 0
    }
  },
  "WebACLId": "",
  "HttpVersion": "http2",
  "IsIPV6Enabled": true
}
JSON

DIST_LOOKUP="$(find_distribution)"
if has_value "${DIST_LOOKUP}"; then
  echo "==> Reusing CloudFront distribution"
  read -r DIST_ID DIST_DOMAIN DIST_ARN <<<"${DIST_LOOKUP}"
else
  echo "==> Creating CloudFront distribution"
  read -r DIST_ID DIST_DOMAIN DIST_ARN < <(
    aws cloudfront create-distribution \
      --distribution-config "file://${TMP_DIR}/distribution.json" \
      --query 'Distribution.[Id,DomainName,ARN]' \
      --output text
  )
fi

cat > "${TMP_DIR}/bucket-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontServicePrincipalReadOnly",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudfront.amazonaws.com"
      },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET}/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceArn": "${DIST_ARN}"
        }
      }
    }
  ]
}
JSON

echo "==> Attaching S3 bucket policy for CloudFront"
aws s3api put-bucket-policy \
  --bucket "${BUCKET}" \
  --policy "file://${TMP_DIR}/bucket-policy.json"

cat > "${TMP_DIR}/route53-alias.json" <<JSON
{
  "Comment": "Alias ${DOMAIN} to CloudFront",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${CLOUDFRONT_ZONE_ID}",
          "DNSName": "${DIST_DOMAIN}",
          "EvaluateTargetHealth": false
        }
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}",
        "Type": "AAAA",
        "AliasTarget": {
          "HostedZoneId": "${CLOUDFRONT_ZONE_ID}",
          "DNSName": "${DIST_DOMAIN}",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
JSON

echo "==> Creating Route 53 alias records"
aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "file://${TMP_DIR}/route53-alias.json" >/dev/null

echo "==> Waiting for CloudFront distribution deployment"
aws cloudfront wait distribution-deployed --id "${DIST_ID}"

cat <<EOF

Done.

Domain:        ${DOMAIN}
Bucket:        ${BUCKET}
Certificate:   ${CERT_ARN}
Distribution:  ${DIST_ID}
CloudFront:    ${DIST_DOMAIN}
Route53 Zone:  ${HOSTED_ZONE_ID}

Test after DNS propagation:
  https://${DOMAIN}

EOF

