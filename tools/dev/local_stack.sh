#!/usr/bin/env bash
# tools/dev/local_stack.sh — bring up the local T-City dependencies and print
# the environment block an MCP host needs.
#
#   bash tools/dev/local_stack.sh            # start DB, load schema, print env
#   bash tools/dev/local_stack.sh --check    # only probe, never mutate
#
# What it does (idempotent):
#   1. starts a mariadb:11.8 container named tcity-mariadb on $PORT (default 3307)
#   2. imports tests/fixtures/tcity_schema.sql when the DB is empty
#   3. applies every migration in versions order (they are idempotent)
#   4. creates the least-privilege agent_ro account (SELECT on the 5 agent views)
#   5. prints the exports for gateway + MCP, and probes the gateway if it runs
#
# It never touches server.cfg, tokens in git, or the live server; the DB lives
# in a container and can be removed with `docker rm -f tcity-mariadb`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$REPO_ROOT/T-CityLite.base"
CONTAINER="${TCITY_DEV_DB_CONTAINER:-tcity-mariadb}"
PORT="${TCITY_DEV_DB_PORT:-3307}"
ROOT_PW="${TCITY_DEV_DB_ROOT_PASSWORD:-tcityroot}"
DB="${TCITY_DEV_DB_NAME:-TCityLite}"
AGENT_USER="${TCITY_DEV_AGENT_USER:-agent_ro}"
AGENT_PW="${TCITY_DEV_AGENT_PASSWORD:-agentro}"
IMAGE="${TCITY_DEV_DB_IMAGE:-mariadb:11.8}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# Docker Desktop's credsStore helper is missing on some Windows installs and
# breaks `docker pull` with "docker-credential-desktop not found". An empty
# config sidesteps it without touching the user's ~/.docker/config.json.
if [ -z "${DOCKER_CONFIG:-}" ]; then
    DOCKER_CONFIG="$(mktemp -d)"
    printf '{}\n' > "$DOCKER_CONFIG/config.json"
    export DOCKER_CONFIG
fi

say() { printf '%s\n' "$*" >&2; }

db_exec() {
    docker exec -i "$CONTAINER" mariadb -uroot -p"$ROOT_PW" "$@" 2>&1 | grep -v "Using a password" || true
}

if [ "$CHECK_ONLY" -eq 0 ]; then
    if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
        say "→ starting $IMAGE as $CONTAINER on 127.0.0.1:$PORT"
        docker run -d --name "$CONTAINER" \
            -e MARIADB_ROOT_PASSWORD="$ROOT_PW" \
            -e MARIADB_DATABASE="$DB" \
            -p "$PORT:3306" "$IMAGE" >/dev/null
    elif [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]; then
        say "→ restarting $CONTAINER"
        docker start "$CONTAINER" >/dev/null
    fi

    for _ in $(seq 1 30); do
        if docker exec "$CONTAINER" mariadb-admin ping -uroot -p"$ROOT_PW" --silent 2>/dev/null | grep -q alive; then
            break
        fi
        sleep 2
    done

    table_count=$(docker exec "$CONTAINER" mariadb -uroot -p"$ROOT_PW" -N \
        -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB'" 2>/dev/null | tr -d '\r')
    if [ "${table_count:-0}" = "0" ]; then
        say "→ importing tests/fixtures/tcity_schema.sql (empty database)"
        docker exec -i "$CONTAINER" mariadb -uroot -p"$ROOT_PW" "$DB" < "$BASE/tests/fixtures/tcity_schema.sql" >/dev/null 2>&1
    fi

    say "→ applying migrations"
    failed=0
    for migration in $(ls "$BASE"/migrations/*.sql | sort -V); do
        err=$(docker exec -i "$CONTAINER" mariadb -uroot -p"$ROOT_PW" "$DB" < "$migration" 2>&1 >/dev/null | grep -v "Using a password" || true)
        if [ -n "$err" ]; then
            say "  ! $(basename "$migration"): $err"
            failed=1
        fi
    done

    # 迁移失败以前只是一行提示，脚本照样往下走 —— 结果警用终端起来后
    # police_units/police_incidents 根本不存在，board 端点 500，MDT 列表全空。
    say "→ verifying schema"
    present=$(db_exec -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema='$DB'" | tr -d '')
    for table in police_units police_incidents police_cases player_quests agent_actions agent_effects; do
        if ! printf '%s
' "$present" | grep -qx "$table"; then
            say "  ✗ missing table after migrations: $table"
            exit 1
        fi
    done
    [ "$failed" -eq 0 ] || { say "  ✗ some migrations reported errors"; exit 1; }

    say "→ ensuring $AGENT_USER (SELECT on the five agent views)"
    db_exec -e "
        CREATE USER IF NOT EXISTS '$AGENT_USER'@'%' IDENTIFIED BY '$AGENT_PW';
        GRANT SELECT ON \`$DB\`.agent_player_snapshot TO '$AGENT_USER'@'%';
        GRANT SELECT ON \`$DB\`.agent_player_timeline TO '$AGENT_USER'@'%';
        GRANT SELECT ON \`$DB\`.agent_events_feed     TO '$AGENT_USER'@'%';
        GRANT SELECT ON \`$DB\`.agent_world_state     TO '$AGENT_USER'@'%';
        GRANT SELECT ON \`$DB\`.agent_economy_metrics TO '$AGENT_USER'@'%';
        FLUSH PRIVILEGES;" >/dev/null
fi

players=$(docker exec "$CONTAINER" mariadb -uroot -p"$ROOT_PW" -N \
    -e "SELECT COUNT(*) FROM \`$DB\`.players" 2>/dev/null | tr -d '\r' || echo "?")

cat <<ENV
# ── gateway (read channel) ────────────────────────────────────────────────
export AGENT_DB_HOST=127.0.0.1
export AGENT_DB_PORT=$PORT
export AGENT_DB_USER=$AGENT_USER
export AGENT_DB_PASS=$AGENT_PW
export AGENT_DB_NAME=$DB
export AGENT_HTTP_PORT=8787
export AGENT_TOKEN=devgw-token          # tools/agent_gateway.py
#   start it with:
#     AGENT_TOKEN=\$AGENT_TOKEN python3 tools/agent_gateway.py

# ── MCP host (tools/agent_mcp.py over stdio) ──────────────────────────────
export AGENT_GATEWAY_URL=http://127.0.0.1:8787
export AGENT_GATEWAY_TOKEN=\$AGENT_TOKEN
export AGENT_DIRECTOR_URL=http://127.0.0.1:30130/custom-director
export AGENT_DIRECTOR_TOKEN=dev-agent-token
export AGENT_LIVE_TOKEN=dev-live-token
export AGENT_AGENT_ID=mcp.local

# the three above must match server.cfg:
#   set agent_actions_token "dev-agent-token"
#   set agent_actions_admin_token "dev-admin-token"
#   set agent_live_token "dev-live-token"
#   set agent_actions_enabled 1
#   set agent_live_enabled 1

# ── state ─────────────────────────────────────────────────────────────────
# database: $DB on 127.0.0.1:$PORT (players rows: $players)
ENV
