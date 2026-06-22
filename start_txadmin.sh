#!/bin/bash
# T-City Lite — txAdmin 启动脚本 (Linux)
# 用法: ./start_txadmin.sh
# Web 面板: http://localhost:40120/

set -e

SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "$SCRIPT")
BASE="$SCRIPTPATH/T-CityLite.base"
ALPINE="$SCRIPTPATH/alpine"
TXA_PORT="${TXHOST_TXA_PORT:-40120}"
TXA_DATA="${TXHOST_DATA_PATH:-$BASE/txData}"

echo "============================================"
echo "  T-City Lite - txAdmin v8.0.1"
echo "  Port: $TXA_PORT"
echo "  Data: $TXA_DATA"
echo "  Web:  http://localhost:$TXA_PORT/"
echo "============================================"
echo ""

cd "$BASE"

# 创建必要目录
mkdir -p cache "$TXA_DATA"

# 使用 Alpine musl loader 以 monitor 模式启动 FXServer
exec "$ALPINE/opt/cfx-server/ld-musl-x86_64.so.1" \
    --library-path "$ALPINE/usr/lib/v8/:$ALPINE/lib/:$ALPINE/usr/lib/" -- \
    "$ALPINE/opt/cfx-server/FXServer" \
    +set citizen_dir "$ALPINE/opt/cfx-server/citizen/" \
    +set monitorMode true \
    +set txAdminPort "$TXA_PORT" \
    +set txDataPath "$TXA_DATA" \
    "$@"
