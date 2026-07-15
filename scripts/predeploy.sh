#!/usr/bin/env bash
set -Eeuo pipefail

# The renderer writes root-owned files under /opt/secrets.
# Komodo may execute the predeploy command as deploy.
if [ "${EUID}" -ne 0 ]; then
  exec sudo -n bash "$0" "$@"
fi

STACK_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
  pwd
)"

COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
RENDER_SCRIPT="${STACK_DIR}/scripts/render-twenty-app-env.sh"

APPROLE_FILE="/opt/secrets/twenty-app/openbao-approle.env"
SECRET_ENV="/opt/secrets/twenty-app/twenty.env"

CA_FILE="/opt/internal-ca/infra-ca.crt"

DATABASE_DNS="twenty-db.internal.mynaghi.me"
DATABASE_IP="10.10.1.4"
DATABASE_PORT="5433"

EXPECTED_BIND_IP="10.10.1.6"

echo "======================================================================"
echo "Twenty CRM predeploy"
echo "======================================================================"

echo
echo "=== Validate required files ==="

test -f "$COMPOSE_FILE" || {
  echo "ERROR: Docker Compose file is missing: ${COMPOSE_FILE}" >&2
  exit 1
}

test -f "$RENDER_SCRIPT" || {
  echo "ERROR: render script is missing: ${RENDER_SCRIPT}" >&2
  exit 1
}

test -r "$APPROLE_FILE" || {
  echo "ERROR: AppRole credentials are missing: ${APPROLE_FILE}" >&2
  exit 1
}

APPROLE_OWNER="$(
  stat -c '%U:%G' "$APPROLE_FILE"
)"

APPROLE_MODE="$(
  stat -c '%a' "$APPROLE_FILE"
)"

if [ "$APPROLE_OWNER" != "root:root" ]; then
  echo "ERROR: AppRole file must be owned by root:root." >&2
  echo "Current owner: ${APPROLE_OWNER}" >&2
  exit 1
fi

if [ "$APPROLE_MODE" != "600" ]; then
  echo "ERROR: AppRole file must have mode 0600." >&2
  echo "Current mode: ${APPROLE_MODE}" >&2
  exit 1
fi

echo "OK: required files exist"

echo
echo "=== Render secrets from OpenBao ==="

bash "$RENDER_SCRIPT"

echo
echo "=== Validate rendered environment ==="

test -s "$SECRET_ENV" || {
  echo "ERROR: rendered environment is missing or empty: ${SECRET_ENV}" >&2
  exit 1
}

SECRET_OWNER="$(
  stat -c '%U:%G' "$SECRET_ENV"
)"

SECRET_MODE="$(
  stat -c '%a' "$SECRET_ENV"
)"

if [ "$SECRET_OWNER" != "root:root" ]; then
  echo "ERROR: rendered environment must be owned by root:root." >&2
  echo "Current owner: ${SECRET_OWNER}" >&2
  exit 1
fi

if [ "$SECRET_MODE" != "600" ]; then
  echo "ERROR: rendered environment must have mode 0600." >&2
  echo "Current mode: ${SECRET_MODE}" >&2
  exit 1
fi

for key in \
  APP_SECRET \
  PG_DATABASE_URL \
  STORAGE_S3_ACCESS_KEY_ID \
  STORAGE_S3_SECRET_ACCESS_KEY \
  EMAIL_SMTP_USER \
  EMAIL_SMTP_PASSWORD
do
  if ! grep -Eq "^${key}='[^']+'" "$SECRET_ENV"; then
    echo "ERROR: ${key} is missing or empty in ${SECRET_ENV}." >&2
    exit 1
  fi
done

if grep -Fq "DUMMY_REPLACE" "$SECRET_ENV"; then
  echo "ERROR: rendered environment still contains dummy values." >&2
  exit 1
fi

echo "OK: rendered environment validated"

echo
echo "=== Validate generated PostgreSQL URL ==="

PG_DATABASE_URL="$(
  sed -n \
    "s/^PG_DATABASE_URL='\(.*\)'$/\1/p" \
    "$SECRET_ENV"
)"

test -n "$PG_DATABASE_URL" || {
  echo "ERROR: generated PG_DATABASE_URL could not be read." >&2
  exit 1
}

case "$PG_DATABASE_URL" in
  postgresql://*|postgres://*)
    ;;
  *)
    echo "ERROR: generated PG_DATABASE_URL has an invalid scheme." >&2
    exit 1
    ;;
esac

if [[ "$PG_DATABASE_URL" != *"${DATABASE_DNS}:${DATABASE_PORT}/default"* ]]; then
  echo "ERROR: generated PG_DATABASE_URL uses the wrong endpoint or database." >&2
  exit 1
fi

if [[ "$PG_DATABASE_URL" != *"sslmode=verify-full"* ]]; then
  echo "ERROR: generated PG_DATABASE_URL does not enforce sslmode=verify-full." >&2
  exit 1
fi

if [[ "$PG_DATABASE_URL" != *"sslrootcert=/etc/twenty/ca/postgresql-ca.crt"* ]]; then
  echo "ERROR: generated PG_DATABASE_URL does not reference the mounted CA." >&2
  exit 1
fi

unset PG_DATABASE_URL

echo "OK: generated PostgreSQL URL validated"

echo
echo "=== Validate internal PostgreSQL CA ==="

test -r "$CA_FILE" || {
  echo "ERROR: internal CA is missing: ${CA_FILE}" >&2
  exit 1
}

openssl x509 \
  -in "$CA_FILE" \
  -noout \
  -subject \
  -issuer \
  -dates

openssl x509 \
  -checkend 604800 \
  -noout \
  -in "$CA_FILE" || {
    echo "ERROR: internal CA expires within seven days." >&2
    exit 1
  }

echo
echo "=== Validate database DNS ==="

getent hosts "$DATABASE_DNS" || {
  echo "ERROR: cannot resolve ${DATABASE_DNS}." >&2
  exit 1
}

RESOLVED_DATABASE_IPS="$(
  getent ahostsv4 "$DATABASE_DNS" |
  awk '{print $1}' |
  sort -u
)"

printf '%s\n' "$RESOLVED_DATABASE_IPS"

grep -Fxq "$DATABASE_IP" <<<"$RESOLVED_DATABASE_IPS" || {
  echo "ERROR: ${DATABASE_DNS} does not resolve to ${DATABASE_IP}." >&2
  exit 1
}

echo
echo "=== Validate PostgreSQL TLS ==="

TLS_RESULT="$(
  openssl s_client \
    -connect "${DATABASE_DNS}:${DATABASE_PORT}" \
    -starttls postgres \
    -servername "$DATABASE_DNS" \
    -CAfile "$CA_FILE" \
    </dev/null 2>&1
)"

if ! grep -Fq "Verify return code: 0 (ok)" <<<"$TLS_RESULT"; then
  echo "$TLS_RESULT"
  echo "ERROR: PostgreSQL TLS verification failed." >&2
  exit 1
fi

echo "OK: PostgreSQL TLS verified"

echo
echo "=== Validate Docker Compose ==="

cd "$STACK_DIR"

docker compose \
  -f "$COMPOSE_FILE" \
  config >/dev/null

SERVICES="$(
  docker compose \
    -f "$COMPOSE_FILE" \
    config --services
)"

printf '%s\n' "$SERVICES"

for expected_service in server worker redis; do
  grep -Fxq "$expected_service" <<<"$SERVICES" || {
    echo "ERROR: expected service is missing: ${expected_service}" >&2
    exit 1
  }
done

for forbidden_service in \
  db \
  db2 \
  postgres \
  change-vol-ownership
do
  if grep -Fxq "$forbidden_service" <<<"$SERVICES"; then
    echo "ERROR: forbidden local service found: ${forbidden_service}" >&2
    exit 1
  fi
done

echo
echo "=== Validate resolved Compose configuration ==="

RESOLVED_COMPOSE="$(
  docker compose \
    -f "$COMPOSE_FILE" \
    config
)"

grep -Fq "$EXPECTED_BIND_IP" <<<"$RESOLVED_COMPOSE" || {
  echo "ERROR: Compose does not bind Twenty to ${EXPECTED_BIND_IP}." >&2
  exit 1
}

grep -Fq \
  "/opt/secrets/twenty-app/twenty.env" \
  <<<"$RESOLVED_COMPOSE" || {
    echo "ERROR: rendered OpenBao environment is not configured." >&2
    exit 1
  }

grep -Fq \
  "/opt/internal-ca/infra-ca.crt" \
  <<<"$RESOLVED_COMPOSE" || {
    echo "ERROR: internal PostgreSQL CA is not mounted." >&2
    exit 1
  }

if grep -E \
  'server-local-data|\.local-storage|test_db|db2-data|test_server-local-data' \
  <<<"$RESOLVED_COMPOSE"
then
  echo "ERROR: legacy local application storage or database configuration found." >&2
  exit 1
fi

echo
echo "OK: Twenty predeploy validation passed"
