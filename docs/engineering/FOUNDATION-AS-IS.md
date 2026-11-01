---
id: engineering-foundation-as-is
type: manual
status: active
system: meta
owner: hermes
updated: 2026-11-01
review_by: 2027-01-30
tracks: [docs/engineering/STANDARDS.md]
---

# 基石现状（AS-IS）— 组件、三条主链路、已知缺口

> **类型**：manual（描述现在是什么，跟随代码，90 天复审）
> **数据时点**：2026-11-01 本机实测（FXServer 8 槽、85 个资源在跑、117 个 manifest）
> **配套**：目标形态见 `docs/engineering/FOUNDATION-TO-BE.md`，施工顺序见 `docs/engineering/2026-11-foundation-plan.md`

## 1. 部署拓扑

![部署与运行时拓扑](assets/foundation/d1-deployment.svg)

| 面 | 实体 | 入口 |
|---|---|---|
| 客户端 | GTA V + CEF（Svelte 5，产物进 custom-phone 的 html/） | `fetchNui` → `RegisterNUICallback` |
| 服务端 | FXServer `:30130`，`sv_maxclients 8`，OneSync，lua54（80/117 manifest 显式声明） | net event / export / 命令 |
| 数据 | MariaDB 11.8（Docker，`127.0.0.1:3307`），oxmysql 异步驱动 | 参数化 SQL |
| 运维 | txAdmin / monitor、custom-director 的 HTTP（`/actions`、`/policy`，token 鉴权） | 人工与 agent 两条口子 |

配置现实：端口、槽位、license、DB DSN 只写在 gitignored 的 server.cfg（不入库，CI 里不存在）；
`server.cfg.template` 已是 48 槽 / `:30120`，与实跑漂移。

## 2. 组件清单

| 层 | 文件（资源内相对路径） | 行数 | 状态 |
|---|---|---|---|
| 服务总线 | core-framework/bus.lua | 231 | 每资源 include 一份的私有注册表，不是跨资源总线 |
| 契约占位 | core-framework/contracts.lua | 214 | 5 个 Phase2-3 服务返回常量 |
| 经济便利层 | core-framework/services/economy_service.lua | 168 | 与 qb-core 的同名实现并存 |
| 安全 | core-framework/services/security_service.lua | 561 | 运行期调用方 0（只有 export 与注册） |
| 限流 | core-framework/server/rate_limit.lua | 163 | 三类语义收敛，实现正确 |
| 持久化 | core-framework/services/persistence_manager.lua | 252 | 与 qb-core 的同名文件并存 |
| 兼容层 | core-framework/compat.lua | 124 | 全局猴补 `QBCore.Functions.GetPlayer/Notify/AddMoney` |
| 奖励网关 | [system]/core_economy/server/main.lua | 279 | 热度只存内存；倍率单位与读者冲突 |
| 玩家账本 | qb-core 的 player.lua + services/economy_service.lua | ~1600 | **真正生效的写者** |

## 3. 三条主链路

### 3.1 钱（奖励发放）

![奖励发放时序](assets/foundation/d4-reward-sequence.svg)

要点：`TriggerReward` → `Player.Functions.AddMoney` → qb-core 的 `EconomyService` → 内存 + 事件 → DirtyFlush。
两处**已写好但运行期不发生**：框架版 `ValidateMoneyEvent` 零调用；`compat.lua` 的 AddMoney 参数错位恒回退。
倍率单位二义：整数读者（`core_economy`、qb-shops、economy-dashboard 都按 `÷100`）与浮点读者
（custom-economy 的 `RewardScale`）共用 `economy_reward_scale`，而 cfg 写的是 `1.0`。

### 3.2 事件（客户端触发）

![入站事件时序](assets/foundation/d5-event-sequence.svg)

要点：`RegisterNetEvent` → 资源 handler → 各资源自己判职业 → 参数化 SQL → 投影回包。
现状缺口：闸门只扫 3 个目录；`QBCore:DebugSomething` 无鉴权；`QBCore:UpdatePlayer` 无限流；
`TriggerClientCallback` 可被任意客户端 resolve。

### 3.3 数据（玩家存档）

![玩家数据状态机](assets/foundation/d6-data-lifecycle.svg)

要点：两套 dirty 池各有一个 900s 定时器；刷盘失败也清脏标记；`ForceFlush → Save(true)` 构成环
（已用等价 Lua 复现栈溢出，当前未爆只因 qb-core 的全局 `DirtyFlush` 指向它自己的 thin 实现）。

## 4. 资源分组与启动

![资源包图与启动顺序](assets/foundation/d3-packages.svg)

117 个 manifest 分 8 组；启动由 17 个 module cfg 的 86 条 ensure 拼出来，10 处"必须先于/必须晚于"
只写在注释里，没有任何闸门读它。

## 5. 已知缺口（按证据排序）

| 缺口 | 实测 | 影响 |
|---|---|---|
| 持久化所有权分裂 | 两套池 / 两个定时器 / 失败即清 | 静默丢钱丢数据 |
| net event 治理 | 179 / 1102（16%） | 引擎层事件无人审 |
| 安全防火墙不在路径上 | 561 行零调用 | 钱路径只剩"调用方自觉" |
| 经济倍率单位二义 | 3 个整数读者 + 2 个浮点读者 | 商店价与奖励可能差 100 倍 |
| NUI 回调无闸门 | 218 处 / 34 文件 | 客户端消息信任边界缺失 |
| 迁移不幂等 / 版本重号 | v3.11、v3.12 各两条 | 重跑迁移会中断 |

修法与顺序见 `docs/engineering/2026-11-foundation-plan.md`。
