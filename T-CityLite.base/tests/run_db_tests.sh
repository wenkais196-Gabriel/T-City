#!/usr/bin/env bash
# FIT-06 database verification: recreate the throwaway test schema, import the
# canonical fixture twice, then run the DB-backed unit/architecture suites.
#
# Credentials come from ~/.tcity-agent-test.env (chmod 600, not committed).
# Safety: this script DROPs TCITY_DB_NAME, so it refuses any name that does not
# end in `_test` (or when TCITY_DB_ALLOW_RESET=1 is explicitly set).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${TCITY_TEST_ENV:-$HOME/.tcity-agent-test.env}"
FIXTURE="$ROOT/tests/fixtures/tcity_schema.sql"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing $ENV_FILE (run: see tests/README.md)" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${TCITY_DB_HOST:?}"; : "${TCITY_DB_USER:?}"; : "${TCITY_DB_PASS:?}"; : "${TCITY_DB_NAME:?}"
if [[ "$TCITY_DB_NAME" != *_test && "${TCITY_DB_ALLOW_RESET:-0}" != "1" ]]; then
  echo "refusing to reset '$TCITY_DB_NAME': name must end in _test (or set TCITY_DB_ALLOW_RESET=1)" >&2
  exit 2
fi
if [[ ! -f "$FIXTURE" ]]; then echo "missing fixture: $FIXTURE" >&2; exit 2; fi

export MYSQL_PWD="$TCITY_DB_PASS"
MYSQL=(mysql -u "$TCITY_DB_USER" -h "$TCITY_DB_HOST" -P "${TCITY_DB_PORT:-3306}")

echo "==> recreate database $TCITY_DB_NAME"
"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`$TCITY_DB_NAME\`; CREATE DATABASE \`$TCITY_DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

for pass in 1 2; do
  echo "==> import fixture (pass $pass)"
  "${MYSQL[@]}" "$TCITY_DB_NAME" < "$FIXTURE"
done

counts=$("${MYSQL[@]}" -N "$TCITY_DB_NAME" -e "
  SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$TCITY_DB_NAME';
  SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$TCITY_DB_NAME' AND table_name LIKE 'police\\_%';")
echo "==> tables: $(echo "$counts" | paste -sd/ -) (total/police_*)"

export PYTHONPATH="${TCITY_TEST_PYTHONPATH:-/tmp/fit6deps}${PYTHONPATH:+:$PYTHONPATH}"

echo "==> check_db_schema"
(cd "$ROOT" && python3 tests/check_db_schema.py)

echo "==> DB-backed unit + architecture tests"
(cd "$ROOT" && python3 -m pytest -q tests/unit tests/architecture)

echo "==> FIT-06 OK ($TCITY_DB_NAME)"
