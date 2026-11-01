#!/usr/bin/env bash
# cc_run.sh — 在本机跑 Claude Code（后端是 DeepSeek 的 Anthropic 兼容端点）
#
# 为什么需要这层壳：HKCU\Environment 里虽然有 6 个 ANTHROPIC_* 变量，但**不会**出现在
# Hermes/CI 起的 bash 里，于是 `claude` 直接报 `Not logged in · Please run /login`；
# 另外那边的模型名带 `[1m]` 后缀（deepseek-flash[1m]），端点不认 → `unrecognized_model`。
#
# 用法：  tools/dev/cc_run.sh "你的 prompt"     # 输出到 stdout
set -uo pipefail

ENVFILE="$(mktemp)"
trap 'rm -f "$ENVFILE"' EXIT

reg query 'HKCU\Environment' 2>/dev/null | tr -d '\r' \
  | sed -nE 's/^\s+(ANTHROPIC[A-Z_]*)\s+REG_SZ\s+(.*)$/\1|\2/p' > "$ENVFILE"

while IFS='|' read -r k v; do export "$k=$v"; done < "$ENVFILE"

# [1m] 是本地约定的后缀，端点不认；统一换成实际模型名
export ANTHROPIC_MODEL="${ANTHROPIC_MODEL%%\[*}"
export ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-chat"
export ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-chat"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-chat"

if [[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  echo "cc_run: 没取到 ANTHROPIC_AUTH_TOKEN（HKCU\\Environment 里没有？）" >&2
  exit 2
fi

CLAUDE_BIN="/c/Users/swkgb/AppData/Roaming/npm/claude"
[[ -x "$CLAUDE_BIN" ]] || CLAUDE_BIN="$(command -v claude)"

# `unrecognized_model` 是 CLI 启动探测打的噪音，真正的失败是后面的 API Error，故不过滤 stderr
exec "$CLAUDE_BIN" -p "${1:-}" --output-format text
