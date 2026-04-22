#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 1 ]]; then
  echo "Usage: $0 <input_file>"
  echo "Example: $0 ./active-access-keys.txt"
  exit 1
fi

INPUT_FILE="$1"

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Error: required command not found: ${command_name}" >&2
    exit 1
  fi
}

trim_line() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  echo "${value}"
}

if [[ ! -f "${INPUT_FILE}" ]]; then
  echo "Error: input file not found: ${INPUT_FILE}" >&2
  exit 1
fi

require_command aws

DELETE_COUNT=0

while IFS= read -r RAW_LINE || [[ -n "${RAW_LINE}" ]]; do
  LINE="$(trim_line "${RAW_LINE}")"

  if [[ -z "${LINE}" || "${LINE}" == \#* ]]; then
    continue
  fi

  if [[ "${LINE}" != *:* ]]; then
    echo "Error: invalid line format (expected user:key-id): ${RAW_LINE}" >&2
    exit 1
  fi

  USER_NAME="${LINE%%:*}"
  ACCESS_KEY_ID="${LINE#*:}"

  if [[ -z "${USER_NAME}" || -z "${ACCESS_KEY_ID}" || "${ACCESS_KEY_ID}" == *:* ]]; then
    echo "Error: invalid line format (expected user:key-id): ${RAW_LINE}" >&2
    exit 1
  fi

  echo "==> Deleting access key ${ACCESS_KEY_ID} for user ${USER_NAME}"
  aws iam delete-access-key \
    --user-name "${USER_NAME}" \
    --access-key-id "${ACCESS_KEY_ID}"
  DELETE_COUNT=$((DELETE_COUNT + 1))
done < "${INPUT_FILE}"

echo "==> Deleted ${DELETE_COUNT} access keys listed in ${INPUT_FILE}"
