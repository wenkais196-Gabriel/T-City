#!/usr/bin/env bash
# 把 configs/modules/*.cfg 全部重新 exec 一遍。
#
# 为什么要这个：FXServer 的 `restart X` 会**连带停掉所有依赖 X 的资源**，且不会
# 自动把它们拉回来。典型事故：restart qb-inventory 一次停掉 12 个资源
# （custom-police / qb-ambulancejob / qb-cityhall ...），/revive 之类的功能静默失效
# —— 命令根本没注册，玩家只会看到"没反应"。
#
# 用法：tools/dev/resync_modules.sh [T-CityLite.base 路径]
#   有 tcity-cmd（Linux 布局）就直接执行；没有就把命令打出来，手工贴到控制台。
set -uo pipefail

BASE="${1:-T-CityLite.base}"
if [ ! -d "$BASE/configs/modules" ]; then
    echo "找不到 $BASE/configs/modules" >&2
    exit 1
fi

have_cli=0
command -v tcity-cmd >/dev/null 2>&1 && have_cli=1

shopt -s nullglob
for cfg in "$BASE"/configs/modules/*.cfg; do
    line="exec configs/modules/$(basename "$cfg")"
    if [ "$have_cli" = 1 ]; then
        echo "== $line"
        tcity-cmd -w 2 "$line" >/dev/null 2>&1
    else
        echo "$line"
    fi
done

if [ "$have_cli" = 0 ]; then
    echo
    echo "# 没有 tcity-cmd：把上面每行贴进服务器控制台（或走 RCON）执行。"
    echo "# 核对：curl -H 'Authorization: Bearer <live-token>' http://127.0.0.1:30130/custom-director/agent/v1/live/server"
fi
