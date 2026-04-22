#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 1 ]]; then
  echo "Usage: $0 <output_file>"
  echo "Example: $0 ./active-access-keys.txt"
  exit 1
fi

OUTPUT_FILE="$1"

has_value() {
  local value="${1:-}"
  [[ -n "${value}" && "${value}" != "None" && "${value}" != "null" ]]
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Error: required command not found: ${command_name}" >&2
    exit 1
  fi
}

require_command aws

USER_NAMES="$(aws iam list-users --query 'Users[].UserName' --output text)"

: > "${OUTPUT_FILE}"

if ! has_value "${USER_NAMES}"; then
  echo "==> No IAM users found"
  echo "==> Wrote 0 active access keys to ${OUTPUT_FILE}"
  exit 0
fi

KEY_COUNT=0

for USER_NAME in ${USER_NAMES}; do
  ACCESS_KEY_IDS="$(aws iam list-access-keys \
    --user-name "${USER_NAME}" \
    --query 'AccessKeyMetadata[?Status==`Active`].AccessKeyId' \
    --output text 2>/dev/null || true)"

  if ! has_value "${ACCESS_KEY_IDS}"; then
    continue
  fi

  for ACCESS_KEY_ID in ${ACCESS_KEY_IDS}; do
    echo "${USER_NAME}:${ACCESS_KEY_ID}" >> "${OUTPUT_FILE}"
    KEY_COUNT=$((KEY_COUNT + 1))
  done
done

echo "==> Wrote ${KEY_COUNT} active access keys to ${OUTPUT_FILE}"
