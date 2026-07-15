#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# The rendered file must be created as root.
# Komodo may execute the predeploy command as deploy.
if [ "${EUID}" -ne 0 ]; then
  exec sudo -n bash "$0" "$@"
fi

APPROLE_FILE="/opt/secrets/twenty-app/openbao-approle.env"

OUTPUT_DIR="/opt/secrets/twenty-app"
OUTPUT_FILE="${OUTPUT_DIR}/twenty.env"

APP_SECRET_API_PATH="secret/data/infra/twenty/app"
DB_SECRET_API_PATH="secret/data/infra/twenty/db"

POSTGRES_CA_CONTAINER_PATH="/etc/twenty/ca/postgresql-ca.crt"

test -r "$APPROLE_FILE" || {
  echo "ERROR: AppRole file is not readable: ${APPROLE_FILE}" >&2
  exit 1
}

# shellcheck disable=SC1090
source "$APPROLE_FILE"

: "${BAO_ADDR:?BAO_ADDR is required}"
: "${BAO_ROLE_ID:?BAO_ROLE_ID is required}"
: "${BAO_SECRET_ID:?BAO_SECRET_ID is required}"

WORKDIR="$(mktemp -d /run/twenty-app-render.XXXXXX)"
TMP_ENV="${WORKDIR}/twenty.env"

cleanup() {
  rm -rf "$WORKDIR"

  unset \
    BAO_ROLE_ID \
    BAO_SECRET_ID \
    CLIENT_TOKEN \
    LOGIN_RESPONSE \
    APP_SECRET_RESPONSE \
    DB_SECRET_RESPONSE \
    APP_SECRET \
    ENCRYPTION_KEY \
    FALLBACK_ENCRYPTION_KEY \
    STORAGE_S3_ACCESS_KEY_ID \
    STORAGE_S3_SECRET_ACCESS_KEY \
    EMAIL_SMTP_USER \
    EMAIL_SMTP_PASSWORD \
    OTEL_EXPORTER_OTLP_HEADERS \
    TWENTY_DB_HOST \
    TWENTY_DB_PORT \
    TWENTY_DB_NAME \
    TWENTY_DB_USER \
    TWENTY_DB_PASSWORD \
    ENCODED_DB_USER \
    ENCODED_DB_PASSWORD \
    PG_DATABASE_URL
}

trap cleanup EXIT

require_value() {
  local response="$1"
  local key="$2"

  jq -er \
    --arg key "$key" \
    '.data.data[$key]
     | select(type == "string" and length > 0)' \
    <<<"$response"
}

optional_value() {
  local response="$1"
  local key="$2"

  jq -r \
    --arg key "$key" \
    '.data.data[$key] // ""' \
    <<<"$response"
}

url_encode() {
  local value="$1"

  jq -nr \
    --arg value "$value" \
    '$value | @uri'
}

write_env_value() {
  local key="$1"
  local value="$2"

  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "ERROR: ${key} contains a newline." >&2
    exit 1
  fi

  # Single-quoted values are supported by Docker Compose env_file parsing.
  # Reject apostrophes so the generated file cannot be broken.
  if [[ "$value" == *"'"* ]]; then
    echo "ERROR: ${key} contains a single quote." >&2
    echo "Use a value without an apostrophe." >&2
    exit 1
  fi

  printf "%s='%s'\n" "$key" "$value"
}

echo "Authenticating to OpenBao..."

LOGIN_RESPONSE="$(
  curl \
    --silent \
    --show-error \
    --fail \
    --connect-timeout 5 \
    --max-time 15 \
    --request POST \
    --header "Content-Type: application/json" \
    --data "$(
      jq -nc \
        --arg role_id "$BAO_ROLE_ID" \
        --arg secret_id "$BAO_SECRET_ID" \
        '{
          role_id: $role_id,
          secret_id: $secret_id
        }'
    )" \
    "${BAO_ADDR}/v1/auth/approle/login"
)"

CLIENT_TOKEN="$(
  jq -er '.auth.client_token' <<<"$LOGIN_RESPONSE"
)"

echo "Reading Twenty application secrets..."

APP_SECRET_RESPONSE="$(
  curl \
    --silent \
    --show-error \
    --fail \
    --connect-timeout 5 \
    --max-time 15 \
    --header "X-Vault-Token: ${CLIENT_TOKEN}" \
    "${BAO_ADDR}/v1/${APP_SECRET_API_PATH}"
)"

echo "Reading existing Twenty database secrets..."

DB_SECRET_RESPONSE="$(
  curl \
    --silent \
    --show-error \
    --fail \
    --connect-timeout 5 \
    --max-time 15 \
    --header "X-Vault-Token: ${CLIENT_TOKEN}" \
    "${BAO_ADDR}/v1/${DB_SECRET_API_PATH}"
)"

# ---------------------------------------------------------------------------
# Application-specific secrets
# ---------------------------------------------------------------------------

APP_SECRET="$(
  require_value "$APP_SECRET_RESPONSE" APP_SECRET
)"

ENCRYPTION_KEY="$(
  optional_value "$APP_SECRET_RESPONSE" ENCRYPTION_KEY
)"

FALLBACK_ENCRYPTION_KEY="$(
  optional_value "$APP_SECRET_RESPONSE" FALLBACK_ENCRYPTION_KEY
)"

STORAGE_S3_ACCESS_KEY_ID="$(
  require_value "$APP_SECRET_RESPONSE" STORAGE_S3_ACCESS_KEY_ID
)"

STORAGE_S3_SECRET_ACCESS_KEY="$(
  require_value "$APP_SECRET_RESPONSE" STORAGE_S3_SECRET_ACCESS_KEY
)"

EMAIL_SMTP_USER="$(
  require_value "$APP_SECRET_RESPONSE" EMAIL_SMTP_USER
)"

EMAIL_SMTP_PASSWORD="$(
  require_value "$APP_SECRET_RESPONSE" EMAIL_SMTP_PASSWORD
)"

OTEL_EXPORTER_OTLP_HEADERS="$(
  optional_value "$APP_SECRET_RESPONSE" OTEL_EXPORTER_OTLP_HEADERS
)"

# ---------------------------------------------------------------------------
# Existing database secrets
# ---------------------------------------------------------------------------

TWENTY_DB_HOST="$(
  require_value "$DB_SECRET_RESPONSE" TWENTY_DB_HOST
)"

TWENTY_DB_PORT="$(
  require_value "$DB_SECRET_RESPONSE" TWENTY_DB_PORT
