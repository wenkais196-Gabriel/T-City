#!/usr/bin/env bash
# T-City Lite — 桌面启动器后端脚本
# 由 ~/Desktop/T-City-Server.desktop 调用，也可直接运行：
#   ./start_server_gui.sh          # 启动服务器
#   ./start_server_gui.sh --check  # 只检查依赖，不启动

set -u

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$ROOT" || exit 1

LOG_DIR="$ROOT/logs"
LOG_FILE="$LOG_DIR/server-$(date +%Y%m%d-%H%M%S).log"

echo "========================================"
echo "  T-City Lite 开发服务器"
echo "  目录: $ROOT"
echo "========================================"
echo ""

# ── 启动前检查 ────────────────────────────────────────────────
missing=0
check_file() {
    if [ ! -e "$1" ]; then
        echo "  ❌ 缺少: $1"
        missing=1
    fi
}
check_file "alpine/opt/cfx-server/FXServer"
check_file "alpine/opt/cfx-server/ld-musl-x86_64.so.1"
check_file "T-CityLite.base/server.cfg"
check_file "T-CityLite.base/resources/[standalone]/oxmysql/dist/build.js"
check_file "T-CityLite.base/resources/[system]/tcity-dashboard/nui/dist/index.html"

if [ "$missing" -ne 0 ]; then
    echo ""
    echo "启动所需文件不完整，请先补齐上面列出的文件。"
    read -r -p "按 Enter 关闭窗口..." _
    exit 1
fi

if [ "${1:-}" = "--check" ]; then
    echo "  ✅ 依赖检查通过（未启动服务器）"
    exit 0
fi

mkdir -p "$LOG_DIR"
echo "  日志: $LOG_FILE"

# ── 启动 ──────────────────────────────────────────────────────
# 保留 stdin 给 FXServer 控制台；stdout/stderr 同时写入日志。
echo "正在启动 FXServer...（控制台可直接输入 quit 关闭）"
echo ""

./start.sh 2>&1 | tee "$LOG_FILE"
rc=${PIPESTATUS[0]}

echo ""
echo "========================================"
if [ "$rc" -eq 0 ]; then
    echo "  服务器已退出（code 0）"
else
    echo "  服务器异常退出（code $rc）"
fi
echo "  日志已保存: $LOG_FILE"
echo "========================================"
read -r -p "按 Enter 关闭窗口..." _
exit "$rc"
