#!/usr/bin/env bash
# install-hooks.sh — 安装仓库自带的 Git hooks
#
# 用法（仓库根目录）:
#   bash tools/dev/install-hooks.sh
#
# 安装后每次 git commit 会先运行 T-CityLite.base/tests/run_all.py。
# 紧急情况下可用 `git commit --no-verify` 跳过（不建议）。

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HOOK_SRC="$ROOT/T-CityLite.base/.githooks/pre-commit"
HOOK_DST="$ROOT/.git/hooks/pre-commit"

if [[ ! -f "$HOOK_SRC" ]]; then
  echo "❌ 未找到 $HOOK_SRC"
  exit 1
fi

cp "$HOOK_SRC" "$HOOK_DST"
chmod +x "$HOOK_DST"

echo "✅ 已安装 pre-commit hook: $HOOK_DST"
echo "   下次 commit 前会运行 T-CityLite.base/tests/run_all.py"
