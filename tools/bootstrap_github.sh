#!/usr/bin/env bash
# bootstrap_github.sh — 一次性初始化 GitHub 标签 / 里程碑 / Issue
#
# 前置条件：
#   1. 已安装 GitHub CLI: https://cli.github.com/
#   2. 已登录: gh auth login
#   3. 在仓库根目录执行
#
# 用法:
#   bash tools/bootstrap_github.sh
#
# 说明:
#   - 已存在的标签会自动跳过/更新
#   - 已存在的 Issue（按标题精确匹配）不会重复创建
#   - 不会修改代码、不会创建 PR

set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "❌ 未找到 gh CLI。请先安装：https://cli.github.com/"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "❌ gh 未登录。请先执行: gh auth login"
  exit 1
fi

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "📦 仓库: $REPO"

# ── 标签 ────────────────────────────────────────────────────────────
create_label() {
  local name="$1" color="$2" desc="$3"
  gh label create "$name" --color "$color" --description "$desc" --force >/dev/null 2>&1 || true
}

echo "🏷  创建标签..."
create_label "type:bug"         "d73a4a" "缺陷修复"
create_label "type:feature"     "0e8a16" "新功能"
create_label "type:security"    "b60205" "安全修复"
create_label "type:refactor"    "5319e7" "重构/架构"
create_label "type:docs"        "0075ca" "文档"
create_label "type:chore"       "cfd3d7" "构建/CI/依赖"
create_label "priority:P0"      "b60205" "阻断启动 / 可刷钱 / 可破坏他人"
create_label "priority:P1"      "d93f0b" "功能失效 / 数据错误"
create_label "priority:P2"      "fbca04" "降级 / 维护风险"
create_label "area:boot"        "1d76db" "启动链/依赖/配置"
create_label "area:quest"       "0052cc" "任务系统"
create_label "area:story"       "5319e7" "剧情/决策"
create_label "area:economy"     "006b75" "经济/银行/市场"
create_label "area:vehicle"     "0e8a16" "载具"
create_label "area:justice"     "bfd4f2" "警察/EMS/司法"
create_label "area:phone"       "c5def5" "手机/NUI"
create_label "area:db"          "006b75" "数据库/持久化"
create_label "area:ci"          "cfd3d7" "CI/DevOps"
create_label "area:docs"        "0075ca" "文档"
create_label "phase:1"          "fef2c0" "Phase 1 — 基础功能"
create_label "phase:2"          "fef2c0" "Phase 2 — 角色扮演/多系统"
create_label "phase:3"          "fef2c0" "Phase 3 — Agent 导演"
create_label "status:blocked"   "000000" "被阻塞"
create_label "status:needs-info" "d4c5f9" "缺少信息"
create_label "status:needs-test" "d4c5f9" "待实机验证"

# ── 里程碑 ──────────────────────────────────────────────────────────
create_milestone() {
  local title="$1" desc="$2"
  gh api "repos/$REPO/milestones" \
    -f title="$title" -f description="$desc" -f state="open" >/dev/null 2>&1 || true
}

echo "🎯 创建里程碑..."
create_milestone "Phase 1 — Foundation" \
  "启动链、数据库、持久化、安全、观测底座。退出标准：空库启动 0 错误；24h 不掉档；P0 清零。"
create_milestone "Phase 2 — Roleplay & Systems" \
  "任务/剧情/职业/司法/经济闭环与社交漏斗。退出标准：新玩家 30min 内首次真人交互；三线可通关。"
create_milestone "Phase 3 — Agent Director" \
  "Director Bridge、动作白名单、规则导演、LLM 导演、NPC 演员。退出标准：72h 运行；act 失败率 <2%。"

# ── Issue ───────────────────────────────────────────────────────────
EXISTING_TITLES="$(gh issue list --repo "$REPO" --state all --limit 300 --json title -q '.[].title' || true)"

issue_exists() {
  printf '%s\n' "$EXISTING_TITLES" | grep -Fxq "$1"
}

create_issue() {
  local title="$1" labels="$2" milestone="$3" body="$4"
  if issue_exists "$title"; then
    echo "   ↷ 已存在: $title"
    return
  fi
  gh issue create --repo "$REPO" \
    --title "$title" \
    --body "$body" \
    --label "$labels" \
    --milestone "$milestone" >/dev/null
  echo "   ✅ $title"
}

echo "📝 创建 Issue..."

create_issue \
  "[Phase 1] 实机启动冒烟与 24h 压测" \
  "priority:P0,phase:1,area:boot,status:needs-test" \
  "Phase 1 — Foundation" \
  "## 目标
在真实 FXServer 上验证本轮静态修复，确认 80 个资源全部启动、无脚本错误、24h 不掉档。

## 检查项
- [ ] 按 \`T-CityLite.base/docs/audit/2026-10-21-review-and-three-phase-plan.md\` §7 执行
- [ ] 控制台无 \`Could not start resource\` / \`Failed to load script\` / \`No such export\` / \`attempt to index a nil value (global 'MySQL')\`
- [ ] \`SHOW TABLES\` 含 quest/story 四表
- [ ] 48 人并发 24h，无掉档、无经济异常
- [ ] 记录 artifact 版本、MySQL 版本、资源列表

## 产出
把控制台完整日志（脱敏）贴到本 Issue；失败项拆成独立 Issue。"

create_issue \
  "[Phase 1] Bus 跨资源桥接与命名统一" \
  "priority:P0,type:refactor,phase:1,area:boot" \
  "Phase 1 — Foundation" \
  "## 背景
FiveM 每个 resource 是独立 Lua state，\`_G.Bus\` 不跨资源。当前 20+ 个消费方 \`if Bus then\` 静默跳过；服务名也不一致（\`Bus.job\` vs \`Bus.JobService\`）。

## 方案
- [ ] core-framework 增加 \`BusCall(service, method, ...)\` export（参数化，返回 ok/result）
- [ ] 统一服务命名（snake_case），删除 PascalCase 调用
- [ ] 为 custom-storage / custom-market / custom-cartel / custom-mining / custom-justice 增加 \`@core-framework/bus.lua\`（server_scripts）以完成注册
- [ ] 消费方改为显式 export 调用，保留 fallback
- [ ] 增加 smoke test：跨资源调用返回非 nil

## 验收
\`BusStatus\` 能列出全部服务；组织仓库/市场价/律师通知不再静默降级。"

create_issue \
  "[Phase 1] 任务奖励幂等与 CompleteStep 收口" \
  "priority:P0,type:bug,phase:1,area:quest" \
  "Phase 1 — Foundation" \
  "## 问题
完成分支直接 \`GrantRewards\`，不看 DB \`affectedRows\`；\`CompleteStep\` export 可重复调用 → 重复发钱/物品。

## 方案
- [ ] \`QuestDB.CompleteQuest\` 增加 affectedRows 回调
- [ ] 只有 \`affectedRows > 0\` 才发奖励/通知/事件
- [ ] \`CompleteStep\` 增加状态与当前步骤断言
- [ ] 并发测试：同一 quest 双击完成，只发一次奖励

## 验收
重复调用 \`CompleteStep\` 不会产生第二笔奖励。"

create_issue \
  "[Phase 1] 剩余客户端越权事件收口" \
  "priority:P1,type:security,phase:1,area:boot" \
  "Phase 1 — Foundation" \
  "## 待处理
- [ ] \`mining:server:mineOre\` 距离（本轮已加矿点校验，需回归）
- [ ] \`cartel:server:finishProduction\`（本轮已加 start/duration，需回归）
- [ ] \`custom-main:server:ResetDeathStatus\` 可清死亡状态
- [ ] \`custom-main:server:policeHandoverAlert\` 无限流假警情
- [ ] \`custom-quest:savePosCollection\` 已加 admin，需回归
- [ ] \`police:server:plateFlagged\` 零鉴权
- [ ] 其余 \`nodeComplete\` nonce 跳过（已加类型/距离）

## 验收
每个事件附"攻击路径 → 修复后行为"的复测记录。"

create_issue \
  "[Phase 1] world_state 服务异步化与返回结构修复" \
  "priority:P1,type:bug,phase:1,area:db" \
  "Phase 1 — Foundation" \
  "## 问题
\`world_state_service.lua\` 用 \`Citizen.Await\` 同步查 DB，且 \`prepare\` 返回结构在 \`GetRegionState\` 与 \`GetRegionSnapshot\` 中假设矛盾。

## 方案
- [ ] 统一用 \`exports.oxmysql:execute\` + \`rows[1].state_value\`
- [ ] 读路径改为异步回调或 Cache-first，避免阻塞主线程
- [ ] 增加最小单测 / 游戏内测试

## 验收
重启后首次读取返回业务值；主线程无阻塞告警。"

create_issue \
  "[Phase 1] 生产配置移除 custom-testing / 开发工具" \
  "priority:P1,type:chore,phase:1,area:boot" \
  "Phase 1 — Foundation" \
  "## 问题
\`custom-testing\`（\`/test\` 对所有玩家开放）、\`hud-position-tool\`、\`custom-debug\` 在生产 cfg 中 ensure。

## 方案
- [ ] 拆分 \`configs/modules/dev.cfg\`（仅开发环境 exec）
- [ ] 从 \`server.cfg.template\` 移除开发工具
- [ ] \`/test\` 增加 \`admin\` 限制（双保险）

## 验收
生产环境无 \`/test\` 入口；开发环境仍可用。"

create_issue \
  "[Phase 1] 补齐剩余数据库 DDL" \
  "priority:P1,type:chore,phase:1,area:db" \
  "Phase 1 — Foundation" \
  "## 待补
- [ ] \`player_warns\`（qb-adminmenu）
- [ ] \`server_logs\`（qb-multicharacter）
- [ ] 核对所有 \`MySQL.*\` 表名 vs migrations

## 验收
新库执行 \`migrations/*.sql\` 后，启动与核心流程无 \`table doesn't exist\`。"

create_issue \
  "[Phase 1] 文档与进度看板同步" \
  "priority:P1,type:docs,phase:1,area:docs" \
  "Phase 1 — Foundation" \
  "## 问题
\`PROJECT_PROGRESS.md\` 停在 v0.7a（56 资源/14 模块），实际 80 资源/17 模块；\`ROADMAP.md\` 与代码不一致。

## 方案
- [ ] 重跑 \`manage_progress.py sync\` 或手动更新活动资源清单
- [ ] 修正 ROADMAP 状态（组织外交/社区立法仍待开发）
- [ ] 修复 \`file:///d:/txData\` 死链
- [ ] 在 README 增加"当前阶段 + 审查报告"入口

## 验收
看板与 \`server.cfg.template\` 一致。"

create_issue \
  "[Phase 3] custom-director Bridge 与观测流" \
  "priority:P2,type:feature,phase:3,area:boot" \
  "Phase 3 — Agent Director" \
  "## 目标
新增 server-only \`custom-director\` resource：\`SetHttpHandler\` + Bearer token + \`/v1/snapshot\` \`/v1/observe\` \`/v1/act\` \`/health\`。

## 任务
- [ ] 事件采集：quest/story/world/economy → 队列 → 批量外发
- [ ] \`world_events\` 写入 + 因果链（beat_id/action_id）
- [ ] 动作执行器骨架（仅 L1：notify/atmosphere/world_state）
- [ ] 预算/幂等/审计表
- [ ] 只监听 127.0.0.1，token 走 convar

## 验收
外部脚本能读快照、发一条 L1 动作、在 \`world_events\` 看到审计。"

create_issue \
  "[Phase 3] 导演动作白名单 / 预算 / 人审" \
  "priority:P2,type:feature,phase:3,area:boot" \
  "Phase 3 — Agent Director" \
  "## 目标
把动作分级 L0–L4，默认最小权限。

## 任务
- [ ] L1 表现 / L2 世界 / L3 任务 / L4 经济权限 的 schema 与校验
- [ ] 幂等键、TTL、undo_token
- [ ] 预算（act/min、token/hour、经济上限）
- [ ] L3+ 人审队列（Discord/Web）
- [ ] Kill switch + 自动熔断

## 验收
越权/超预算/重复动作全部被拒；事故可追责。"

create_issue \
  "[Phase 3] NPC 演员 MVP" \
  "priority:P2,type:feature,phase:3,area:story" \
  "Phase 3 — Agent Director" \
  "## 目标
只对"玩家主动接触的 NPC"启用 LLM，背景 NPC 用模板。

## 任务
- [ ] persona + 记忆流 + 反思 + 计划（参考 Generative Agents）
- [ ] 对话输出走 NUI/chat，行为走服务端动作
- [ ] 成本上限与降级模板
- [ ] 隐私：不把聊天全量送入模型

## 验收
10 个 NPC 并发对话不越权、不泄露玩家隐私、成本可测。"

echo
echo "✅ 完成。打开 GitHub 查看："
echo "   https://github.com/$REPO/issues"
echo "   https://github.com/$REPO/milestones"
echo
echo "建议下一步：在 GitHub Projects 创建 Board（Backlog → Ready → In Progress → In Review → Done），"
echo "并把 phase:* 标签的 Issue 批量加入。"
