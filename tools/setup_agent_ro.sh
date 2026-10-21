#!/usr/bin/env bash
# ============================================================================
# setup_agent_ro.sh — create/refresh the MariaDB read-only account for agents
# ============================================================================
# Creates `agent_ro`@`localhost` with SELECT on exactly these five views:
#   agent_player_snapshot, agent_player_timeline,
#   agent_world_state, agent_economy_metrics, agent_events_feed
#
# It never grants access to base tables and never grants write privileges.
#
# Password handling:
#   * Uses AGENT_DB_PASS if exported.
#   * Otherwise uses AGENT_DB_PASS from .env.
#   * Otherwise generates one with `openssl rand -hex 24` and stores it in .env.
#   * The effective password is (re)written to .env so repeated runs are
#     idempotent and never rotate the credential by accident.
#   * The password is never echoed or passed on a command line.
#
# Usage:
#   ./tools/setup_agent_ro.sh
#   AGENT_DB_PASS=... ./tools/setup_agent_ro.sh   # explicit rotation
#
# Requires: bash, mysql client, openssl (only when generating a password).
# ============================================================================
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE (copy .env.example and fill DB credentials)"
command -v mysql >/dev/null 2>&1 || die "mysql client not found"

# Load TCITY_DB_* and AGENT_DB_PASS (if present). Never echo the values.
# Explicit environment variables win over .env, so
# `AGENT_DB_PASS=... ./tools/setup_agent_ro.sh` really rotates the password and
# `TCITY_DB_USER=root ...` can be used by an admin without editing .env.
_override_agent_pass="${AGENT_DB_PASS-}"
_override_db_host="${TCITY_DB_HOST-}"
_override_db_port="${TCITY_DB_PORT-}"
_override_db_user="${TCITY_DB_USER-}"
_override_db_pass="${TCITY_DB_PASS-}"
_override_db_name="${TCITY_DB_NAME-}"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
if [[ -n "$_override_agent_pass" ]]; then AGENT_DB_PASS="$_override_agent_pass"; fi
if [[ -n "$_override_db_host" ]]; then TCITY_DB_HOST="$_override_db_host"; fi
if [[ -n "$_override_db_port" ]]; then TCITY_DB_PORT="$_override_db_port"; fi
if [[ -n "$_override_db_user" ]]; then TCITY_DB_USER="$_override_db_user"; fi
if [[ -n "$_override_db_pass" ]]; then TCITY_DB_PASS="$_override_db_pass"; fi
if [[ -n "$_override_db_name" ]]; then TCITY_DB_NAME="$_override_db_name"; fi
unset _override_agent_pass _override_db_host _override_db_port       _override_db_user _override_db_pass _override_db_name

[[ -n "${TCITY_DB_HOST:-}" ]] || die "TCITY_DB_HOST is missing"
[[ -n "${TCITY_DB_USER:-}" ]] || die "TCITY_DB_USER is missing"
[[ -n "${TCITY_DB_PASS:-}" ]] || die "TCITY_DB_PASS is missing"
[[ -n "${TCITY_DB_NAME:-}" ]] || die "TCITY_DB_NAME is missing"
[[ "$TCITY_DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "TCITY_DB_NAME contains unsupported characters"

if [[ -z "${AGENT_DB_PASS:-}" ]]; then
    command -v openssl >/dev/null 2>&1 || die "openssl not found (needed to generate AGENT_DB_PASS)"
    AGENT_DB_PASS="$(openssl rand -hex 24)"
    generated_password=1
else
    generated_password=0
fi

[[ "$AGENT_DB_PASS" != *$'\n'* ]] || die "AGENT_DB_PASS must be a single line"

MYSQL_ADMIN=(mysql --default-character-set=utf8mb4 --batch --skip-column-names
             -h "$TCITY_DB_HOST" -u "$TCITY_DB_USER")
if [[ -n "${TCITY_DB_PORT:-}" ]]; then
    MYSQL_ADMIN+=(-P "$TCITY_DB_PORT")
fi
export MYSQL_PWD="$TCITY_DB_PASS"

# Refuse to create a user that can read nothing (migration not applied yet).
view_count="$("${MYSQL_ADMIN[@]}" "$TCITY_DB_NAME" -e "
    SELECT COUNT(*) FROM information_schema.VIEWS
    WHERE TABLE_SCHEMA = '$TCITY_DB_NAME'
      AND TABLE_NAME IN ('agent_player_snapshot','agent_player_timeline',
                         'agent_world_state','agent_economy_metrics','agent_events_feed');")"
[[ "$view_count" == "5" ]] || die "expected 5 agent_* views, found ${view_count}. Apply v2.2_agent_read_layer.sql and v2.2.2_agent_events_view.sql first."

# GRANT requires GRANT OPTION. Check before touching .env or the account so a
# non-admin app account fails cleanly instead of leaving a password-only user.
if ! "${MYSQL_ADMIN[@]}" "$TCITY_DB_NAME" -e "SHOW GRANTS FOR CURRENT_USER();" | grep -q 'GRANT OPTION'; then
    die "DB user '${TCITY_DB_USER}' lacks GRANT OPTION; run this script as a MariaDB admin (for example root via unix_socket)"
fi

# Persist the effective password before changing the account, so a later run
# can reuse it even if this run is interrupted. Only the AGENT_DB_PASS line is
# replaced; other .env content is preserved.
escaped_env_pass="${AGENT_DB_PASS//\'/\'\\\'\'}"
tmp_file="$(mktemp "$ENV_FILE.tmp.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT
grep -vE '^(export[[:space:]]+)?AGENT_DB_PASS=' "$ENV_FILE" > "$tmp_file" || true
printf "AGENT_DB_PASS='%s'\n" "$escaped_env_pass" >> "$tmp_file"
cat "$tmp_file" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
rm -f "$tmp_file"
trap - EXIT

escaped_sql_pass="${AGENT_DB_PASS//\'/\'\'}"

"${MYSQL_ADMIN[@]}" "$TCITY_DB_NAME" <<SQL
CREATE USER IF NOT EXISTS 'agent_ro'@'localhost' IDENTIFIED BY '${escaped_sql_pass}';
ALTER USER 'agent_ro'@'localhost' IDENTIFIED BY '${escaped_sql_pass}';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'agent_ro'@'localhost';
GRANT SELECT ON \`${TCITY_DB_NAME}\`.\`agent_player_snapshot\` TO 'agent_ro'@'localhost';
GRANT SELECT ON \`${TCITY_DB_NAME}\`.\`agent_player_timeline\` TO 'agent_ro'@'localhost';
GRANT SELECT ON \`${TCITY_DB_NAME}\`.\`agent_world_state\`    TO 'agent_ro'@'localhost';
GRANT SELECT ON \`${TCITY_DB_NAME}\`.\`agent_economy_metrics\` TO 'agent_ro'@'localhost';
GRANT SELECT ON \`${TCITY_DB_NAME}\`.\`agent_events_feed\`     TO 'agent_ro'@'localhost';
FLUSH PRIVILEGES;
SQL

if [[ "$generated_password" == "1" ]]; then
    printf 'Generated AGENT_DB_PASS and stored it in .env (not displayed).\n'
else
    printf 'Used AGENT_DB_PASS from environment/.env.\n'
fi
printf 'agent_ro@localhost now has SELECT on the 5 agent_* views only.\n'
printf 'No password was printed. .env permissions set to 600.\n'
