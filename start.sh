#!/bin/bash
# T-City Lite — Linux 开发服务器启动脚本
# 用法: ./start.sh [额外 FXServer 参数]

set -e

SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "$SCRIPT")
BASE="$SCRIPTPATH/T-CityLite.base"
ALPINE="$SCRIPTPATH/alpine"
BRANCH=$(git -C "$SCRIPTPATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# 单实例锁：每次启动在 licence 校验之前就会先打 Cfx.re 一次，而"30120 被占用"要到
# 校验之后才发现 —— 也就是说，重复启动的代价是**烧掉一次 licence 配额**（实测 4 次
# 连续失败就把 429 限流打了回来）。所以在启动任何东西之前先抢锁。
LOCK=/tmp/tcity-server.lock
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "[start] 已有实例在运行（锁 $LOCK 被占用）" >&2
    echo "        先停掉它：sudo systemctl stop tcity   或   screen -S tcity -X quit" >&2
    exit 1
fi

echo "========================================"
echo "  T-City Lite 开发服务器"
echo "  当前分支: $BRANCH"
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
