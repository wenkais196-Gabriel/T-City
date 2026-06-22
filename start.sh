#!/bin/bash
# T-City Lite — Linux 开发服务器启动脚本
# 用法: ./start.sh [额外 FXServer 参数]

set -e

SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "$SCRIPT")
BASE="$SCRIPTPATH/T-CityLite.base"
ALPINE="$SCRIPTPATH/alpine"

echo "========================================"
echo "  T-City Lite 开发服务器"
echo "  当前分支: v0.5-crime"
echo "  数据目录: $BASE"
echo "========================================"
echo ""

cd "$BASE"

# 创建 cache 目录
[ -d cache ] || mkdir cache

# 使用 Alpine musl loader 启动 FXServer
exec "$ALPINE/opt/cfx-server/ld-musl-x86_64.so.1" \
    --library-path "$ALPINE/usr/lib/v8/:$ALPINE/lib/:$ALPINE/usr/lib/" -- \
    "$ALPINE/opt/cfx-server/FXServer" \
    +set citizen_dir "$ALPINE/opt/cfx-server/citizen/" \
    +exec server.cfg \
    "$@"
