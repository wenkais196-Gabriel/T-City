---
id: police-gta-mod-research
type: research
status: final
system: justice
owner: hermes
updated: 2026-10-24
review_by: 2027-01-30
---

# GTA V 警察模组在 FiveM 服务器上的复现调研

> 问题：能否把 LSPDFR 类单机警察模组的体验（NPC 帮手、NPC 任务/警情）搬到 T-City？
> 结论：**能复现 60–70% 的“感觉”，但实现方式完全不同**——单机靠 RAGE Plugin Hook 直接操控游戏；FiveM 必须服务端权威 + 客户端 AI，且要控制 NPC 数量与性能。

## 1. 单机模组拆解（调研对象）

| 模组 | 核心能力 | 可复现性 |
|---|---|---|
| [Ultimate Backup](https://gtavillage.com/gta-5/mods/scripts-tools/9250-ultimate-backup-ai-partner-system-for-lspdfr-2026) | 一键呼叫巡逻/县警/州警/SWAT/K9/空中/消防/EMS；AI 队友；响应时间/武器/车辆可配 | 高（NPC 支援），中（SWAT/空中） |
| [Stop The Ped](https://gtavillage.com/gta-5/mods/scripts-tools/9246-stop-the-ped-best-lspdfr-traffic-stop-plugin-2026) | 拦停对话：要证件、查通缉、搜身、搜车、酒驾测试、开单/逮捕/放行 | 中高（交互可做，NPC 车靠边需调 AI） |
| [Assorted Callouts](https://gtavillage.com/gta-5/mods/scripts-tools/9251-assorted-callouts-best-lspdfr-callout-pack-2026) | 随机警情：交通事故、可疑车辆、家暴、商店抢劫、追车、持刀、肇事逃逸、毒品交易、人质、福利检查 | 高（服务端生成场景 + 客户端 NPC） |
| [AIBackup（FiveM 社区实现）](https://github.com/Mooreiche/AIBackup) | FiveM 的 NPC 警察支援脚本，证明思路可行 | 高（可参考，不直接搬代码） |
| [SetPedAsCop native](https://cfxnatives.dev/natives/SET_PED_AS_COP) | 让 NPC 具备“警察”行为标记 | 中（会引入原生通缉/攻击逻辑，需隔离） |

## 2. 单机 vs FiveM 的根本差异

| 维度 | 单机 LSPDFR | FiveM 服务器 |
|---|---|---|
| 运行位置 | 玩家本机 RAGE Plugin Hook | 服务端 + 每个客户端 |
| 权威 | 本地脚本直接改世界 | 服务端权威，客户端只表现 |
| NPC AI | 本机任意 Task 原生 | 实体需被客户端流式加载/拥有，任务在客户端跑 |
| 同步 | 无 | OneSync，实体所有权/延迟/重复生成 |
| 性能预算 | 单人 | 48 人 + 现有资源，NPC 数量必须硬上限 |
| 反作弊 | 不需要 | NPC 生成/奖励必须服务端校验 |

**关键结论**：NPC 的“生成、寻路、战斗”必须在**客户端**执行；服务端只负责“生成哪个场景、给谁、奖励/记录”。不能把单机脚本直接翻译成服务端 Lua。

## 3. 各类玩法的可行方案

### 3.1 NPC 帮手（最可行）

- 服务端收到 `/backup` 或 MDT 按钮 → 校验警察/在勤/冷却/上限；
- 选一个附近生成点 → 通知**请求者客户端**生成 NPC 警车 + 1–2 名警察；
- 客户端：`CreateVehicle`/`CreatePed` → `TaskVehicleDriveToCoord` 到玩家附近 → 下车 → `TaskGoToEntity` 跟随/警戒 → 有敌人时 `TaskCombatPed`；
- 服务端记录“NPC 单位”用于看板/上限，超时/死亡/玩家离开后客户端清理；
- 建议只做 **巡逻支援 + K9**，SWAT/空中放到后期。

**风险**：寻路失败、堵门、误伤玩家、实体残留；需要“超时回收 + 距离回收 + 上限 4”。

### 3.2 NPC 警情/任务（最可行）

- 复用现有 `police_incidents`：新增 `source='npc'` 的警情生成器；
- 服务端随机选模板 + 地点，写 incident，推给在勤警察（现有通知/深链）；
- 玩家接单后，服务端把“场景包”发给**接单者客户端**：生成嫌疑人/受害者/车辆/道具；
- 客户端上报结果（击倒/逮捕/救援/失败）→ 服务端结算奖励/报告/审计；
- 模板先做 4 个：交通事故、可疑车辆、商店抢劫、持械人员。

**风险**：NPC 不会“演”，需要简单状态机（待机/逃跑/攻击/投降）；场景重复感；玩家可能只刷奖励。

### 3.3 NPC 交通拦截（中等）

- 客户端让目标车靠边：`TaskVehicleTempAction(driver, vehicle, 6/7, 时间)` + 减速；
- 玩家下车靠近 → 3D 提示菜单（要证件/搜查/开单/逮捕）；
- “证件/通缉/保险”可复用 MDT 查询；
- 不需要真的做对话树，先做 3 个选项：警告/罚单/逮捕。

**风险**：GTA 的 AI 车辆靠边很不稳定；坡道/高速容易失败；建议只在城市道路生成。

### 3.4 K9 / SWAT / 空中（后期）

- K9：生成狗 ped + `TaskGoToEntity`/`TaskCombatPed`，可做“搜车/追踪”；
- SWAT：NPC 小队 + 护甲/步枪，只在人质/重火力警情；
- 空中：直升机 + `TaskHeliMission`，需要飞行员 AI，成本最高。

### 3.5 不要复现的

- LSPDFR 的完整对话树/动画演出；
- 单机式“按 Y 接警”强制流程（服务器应复用 MDT 接警）；
- 大规模 NPC 战争（48 人服性能撑不住）；
- 用 `SetPedAsCop` 直接接管原生警察 AI（会和玩家警察/通缉系统打架）。

## 4. 三个落地方案

### A. 轻量 NPC 支援（推荐先做，1–2 周）

- `/backup` 或 MDT 按钮：巡逻车 + 2 名 NPC 警察，跟随/战斗/超时回收；
- 4 个 NPC 警情模板（事故/可疑车辆/商店抢劫/持械）；
- 复用现有 incident、通知、审计、奖励；
- 上限：同时 2 个 NPC 单位、每单位 2 人。

### B. 巡逻循环（3–5 周）

- A + NPC 交通拦截（靠边、要证件、开单/逮捕）；
- NPC 嫌疑人状态机（投降/逃跑/攻击）；
- 搭档 AI（跟随、上车、战斗）；
- 奖励与报告自动草稿。

### C. 接近 LSPDFR（2–3 个月）

- 10+ 警情模板、K9/SWAT/空中、场景道具、语音字幕、案件联动；
- 需要专门做 AI 调试与性能预算，不建议当前阶段。

## 5. 与 T-City 现有系统的结合点

| 现有 | 复用方式 |
|---|---|
| `police_incidents` | NPC 警情写同一张表，`source='npc'` |
| MDT 五页 | 接警页显示 NPC 警情，派单/前往/清场不变 |
| 通知/深链 | 直接复用 |
| `police_reports` | NPC 警情结算后自动生成报告草稿 |
| `police_audit` | NPC 生成/结算/奖励写审计 |
| agent | 后续可让 agent 触发 NPC 警情（L1） |

## 6. 结论

- **NPC 帮手、NPC 警情完全可做**，而且是最适合 T-City 的“单机感”补充；
- 不建议一上来做 K9/SWAT/空中/对话树；
- 先做方案 A：**2 个 NPC 支援单位 + 4 个警情模板**，用现有 MDT/通知/审计串起来；
- 关键不是“生成 NPC”，而是**回收、上限、失败兜底、奖励防刷**。

## 参考

- [Ultimate Backup 功能与配置](https://gtavillage.com/gta-5/mods/scripts-tools/9250-ultimate-backup-ai-partner-system-for-lspdfr-2026)
- [Stop The Ped 拦停流程](https://gtavillage.com/gta-5/mods/scripts-tools/9246-stop-the-ped-best-lspdfr-traffic-stop-plugin-2026)
- [Assorted Callouts 警情类型](https://gtavillage.com/gta-5/mods/scripts-tools/9251-assorted-callouts-best-lspdfr-callout-pack-2026)
- [FiveM AIBackup 社区实现](https://github.com/Mooreiche/AIBackup)
- [SetPedAsCop native](https://cfxnatives.dev/natives/SET_PED_AS_COP)
