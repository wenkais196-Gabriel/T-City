# CLAUDE.md — 指针

本项目的规则**只有一处事实源**，请不要在这里另写一份（规则分叉比没有规则更危险）。

- 入口索引：`AGENTS.md`（去哪读、十条红线、流程分级、常用命令）
- 不变量：`docs/engineering/CONSTITUTION.md`
- 依赖方向：`docs/engineering/ARCHITECTURE.md`
- 运行模型：`docs/engineering/agent-operating-model.md`
- 通用工艺准则（可选阅读）：`docs/engineering/llm-craft.md`

三条最常被违反的项目红线，抄在这里只是为了让你在读到 `AGENTS.md` 之前就别踩：

1. 服务端权威：客户端传来的数据一律复验，NUI 隐藏 ≠ 权限。
2. 钱/物品只走 `Player.Functions.*` / `core_economy:TriggerReward`，不直接 SQL。
3. 没有测试的修复不算完成；交付要带上 CHANGELOG。

其他 agent 工具（Codex / Cursor / Jules …）读的是 `AGENTS.md`，本文件只做指向。
