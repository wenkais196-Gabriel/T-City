---
id: claude
type: meta
status: active
system: meta
owner: hermes
updated: 2026-10-25
review_by: 2027-04-30
---

# CLAUDE.md — 指针

规则只有一处事实源：`AGENTS.md`。不要在这里另写一份（规则分叉比没有规则更危险）。

- 不变量：`docs/engineering/CONSTITUTION.md` ｜ 依赖方向：`docs/engineering/ARCHITECTURE.md`
- 运行模型：`docs/engineering/agent-operating-model.md` ｜ 工艺准则：`docs/engineering/llm-craft.md`

三条最常被违反的红线：① 服务端权威，NUI 隐藏 ≠ 权限；② 钱/物品只走 `Player.Functions.*`；③ 没有测试的修复不算完成。

其他 agent 工具（Codex / Cursor / Jules …）读 `AGENTS.md`，本文件只做指向。
