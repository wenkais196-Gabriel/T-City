# A · 世界痕迹第一条链 — 施工图（research → plan）

> 状态：**未开工**。本文只写"要动什么、谁写、怎么验"，不含代码。
> 前置调研：`docs/engineering/2026-11-01-next-epic-research.md`（候选对比与外部调研）。
> 依据：`docs/server-design/02-world-traces.md`、`docs/engineering/CONSTITUTION.md`、`docs/engineering/ARCHITECTURE.md`。

---

## 0. 一句话范围

把「警情结案」变成一条**能被别的玩家看到**的世界状态：结案 → 区域状态落库 → 手机 CityFeed 一条城市动态。
只做这一条链，五个痕迹类目里只碰"社会/物理"这一类。

---

## 1. 开工前必须知道的五个事实（都按代码核过）

| # | 事实 | 证据 | 对施工图的影响 |
|---|---|---|---|
| 1 | `world_state` 的读写服务、表、缓存、事件发射都写好了，但**全仓零调用方** | 服务在 core-framework 的 services/world_state_service.lua；`SetRegionState`/`GetRegionState` 在服务文件之外 0 次出现 | 不需要新建表与服务，只需要**第一个写者与读者** |
| 2 | **四个事件发射点全是死代码**：`EventTypes` 在那些资源里是 `nil` | 只有 core-framework 自己的 shared_scripts 加载 events 目录下的 event_types.lua；`custom-cartel/fxmanifest.lua:15` 只引用了 @core-framework/bus.lua，`custom-career` 连 bus 都没加载。于是 `custom-cartel/server/drug_lab.lua:256`、`custom-career/server/main.lua:250,291`、`custom-quest/server/quest_manager.lua:882`、core_economy 的 `server/main.lua:209` 的 `if EventTypes and EventTypes.Publish` 恒为假，**静默跳过** | 不能假设"发射一个事件就有人收"。要么补加载，要么换通道（见 §3 决策 D1） |
| 3 | 就算补了加载，`EventTypes.Publish` 也传不到别的资源 | `events/event_types.lua:112-120` 里跨资源那段是 `TriggerEvent(eventName, ...)` —— FiveM 服务端的 `TriggerEvent` **只在本资源内派发** | 服务端到服务端的解耦必须走 Bus.Plugin 或显式 export，不能靠 `TriggerEvent` |
| 4 | CityFeed 是现成出口，但**没有"城市发布者"这个概念** | 表 `phone_cityfeed.citizenid NOT NULL`（custom-phone 的 server/main.lua:52-58）；读取时 `LEFT JOIN players`，查不到就显示 `Anonymous`；前端 `src/apps/CityFeed.svelte:94` 写死 `@{post.name}` | 要新增 `author_kind`，否则城市公告会显示成 `@Anonymous` |
| 5 | **读路径本身是坏的，而且是已登记未修的债**：`world_state_service` 用 `Citizen.Await` 同步查库，且 `prepare` 取三列后直接 `local value = row`（拿到整行）并把 `changed_by` 硬写成 `nil`（注释说"not in this query"，查询里明明有） | `services/world_state_service.lua:36-55`；2026-10-21 审计已登记为 **R7**，`2026-10-21-self-review.md` §4 第 3 条明确"未在本轮修复" | 缓存一冷，`GetRegionState` 返回的就是行表而不是值 —— 所以 T2 必须连读路径一起修，否则本图的"重启后仍能读到"验收必红 |

---

## 2. 数据

| 对象 | 现状 | 本次动作 |
|---|---|---|
| `world_state` | 表在（unique `(region_id, state_key)`、`previous_value`、`changed_by`、`changed_at`） | **不改表**。只写入 |
| `world_events` | 表在（`event_type/severity/title/participants/outcome`） | **本阶段不写**（编年史是下一阶段；先证明状态链） |
| `phone_cityfeed` | `citizenid NOT NULL` | 迁移加 `author_kind ENUM('citizen','city') NOT NULL DEFAULT 'citizen'`（纯增量、幂等），并给既有行填 `citizen` |
| 区域注册表 | **不存在**（全仓无 region 定义，只有服务注释里的示例 `dock_zone`） | 新增数据文件 core-framework 的 shared/regions.lua：8–10 个 `{id, label, x, y, radius}` + 纯函数 `RegionOf(x, y)`；取不到 → `city_wide` |

`state_key` 本阶段只定义两个，**枚举写死在服务里**（Lua pattern 没有 `{n,m}` 也没有 `|`，校验只能一条一条比）：

| region_id | state_key | value |
|---|---|---|
| 见 regions.lua | `crime_pressure` | `{open, closed_24h, closed_7d, last_closed_at}` |
| `city_wide` | `crime_pressure` | 同上（全城汇总） |

---

## 3. 架构决策

**D1 — 不用事件解耦，用「单写者 + 显式 export」**
痕迹链的写者只有一个：core-framework 新增的 services/world_trace_service.lua（和 `world_state_service` 同资源，直接复用它的 `SetRegionState` 与缓存）。
其它资源只调 `exports['core-framework']:service_world_trace_Record(...)`（`Bus.RegisterService` 已经会自动生成这个名字的 export，见 bus.lua:24-30）。
理由：事实 2/3 说明事件通道现在既不可靠也不跨资源；先把写路径做对，事件留到有第二个订阅者时再补。**这条决定可以回滚**——将来把 @core-framework/events/event_types.lua 补进各资源 manifest 不需要改痕迹链的调用方。

**D2 — 审计归属写清楚**
`Record` 不写 `police_audit`（它不归警察），审计由 `world_state` 自己的 `changed_by` + `changed_at` + `previous_value` 三列承担。FIT-04 的"写操作必须写审计"只约束 custom-police/server 的 export，新 export 在 core-framework，不适用；但**读路径**如果将来对外返回带 citizenid 的痕迹，必须按宪法第 7 条脱敏。

**D3 — 写者失败不影响业务**
痕迹不是玩家主流程。`Record` 返回 `false, reason`，调用方记一行日志就继续；结案成功与否**永远不取决于痕迹写没写进去**（对齐宪法第 1 条：业务权威在 owner）。

**D4 — 读走 GetRegionState，不给客户端开新事件**
CityFeed 的城市动态走 `custom-phone` 既有的 `phone:server:getCityFeed` callback，不新增客户端事件、不新增 net event 登记项。

**D5 — 文案模板化，不生成**
公告文案由 Lua 模板拼（`'%s 刚结案：%s'`），**不接任何生成式模型**。生成式内容留给"公测前需要单独评估 TOS"的那条线，不在核心循环里。

---

## 4. 改动面（谁、动哪个文件、为什么）

| 序 | 资源 / 文件 | 改动 | 宪法条款 |
|---|---|---|---|
| 1 | core-framework 的 services/world_trace_service.lua | **新增**：`Record(region_id, state_key, value, changed_by, meta)`；枚举白名单、长度上限、30 s 同键去抖、调 `WorldStateService.SetRegionState` | 4（新 export 登记）、6（唯一写者）、5（幂等） |
| 2 | core-framework 的 contracts.lua | 注册 `world_trace` 服务（`Bus.RegisterService`） | 4 |
| 3 | core-framework/shared/regions.lua | **新增**：区域数据 + `RegionOf(x,y)` 纯函数。放世界层不放警察层：第二条链（cartel 地盘）要复用同一套 region id，放 custom-police 会逼出第二份 | —（纯函数，可离线测） |
| 4 | custom-police/server/p0_incidents.lua | 结案分支（`targetStatus == 'closed'`，`:294-330`）成功后调 1 次 `Record`；`pcall` 包裹 | 1（结案权威不变）、8（只动一处平面） |
| 5 | custom-phone/server/main.lua + 迁移 v3.15 | `phone_cityfeed.author_kind`；新增 export `PostCityBulletin(content, meta)`（内部写 `author_kind='city'`）；`getCityFeed` 回包带 `author_kind` | 6（唯一写者仍是 custom-phone） |
| 6 | custom-phone 前端 CityFeed.svelte | `author_kind === 'city'` 时显示「📣 城市」而不是 `@Anonymous` | —（构建产物要一起提交） |
| 7 | `table_owners.json` | 加一条 owner：`core-framework` ← `world_state` / `world_events`。**不改 `scan` 列表、不改闸门代码**：FIT-02 只检查「已登记表」的写入方，登记 owner 之后任何被扫描资源直接写这两张表都会红，这就是我们要的边界。`export_allowlist.json` **不动**（FIT-04 只扫 custom-police/server，且新 export 属于 core-framework，不归它管） | 4, 6 |

**不加**：net event、新表、新资源、新 NUI 平面。

---

## 5. 验收

**离线（先红后绿，命令照抄）**

```bash
cd T-CityLite.base && /usr/bin/python3 -m pytest tests/unit tests/architecture -q
lua5.4 tests/agent/lua/runner.lua
```

| 用例 | 断言 |
|---|---|
| `RegionOf` 边界 | 圆心内 / 圆外 / 正好半径 / `nil` 坐标 / 越界坐标（Inf）→ 各自有确定结果 |
| `Record` 参数 | 非法 region / 非法 state_key / 空 value / 超长 value / 缺 changed_by → `false, <reason>`，且**不落库** |
| 幂等 | 同 `(region, state_key)` 连写两次 → 只有一行；`previous_value` 是上一次的值 |
| 去抖 | 30 s 内同键第二次 → `false, 'debounced'`；换 key 不受影响 |
| 结案解耦 | 让 `Record` 抛错 → 结案**仍然成功**且返回 `closed`（反向校验：把 `pcall` 去掉这条测试必须红） |
| 反向校验（人工变异，**不算闸门**） | 把 p0_incidents 里的 `Record` 调用删掉，人工跑一次确认测试变红、再恢复。它无法进 CI，所以真正的防线是下面的正控断言 |
| 正控（进 CI） | 造一单 → close(cited) → 断言该 region 的 `crime_pressure` **恰好 1 行**、`changed_by` = 结案警员工号、`last_closed_at >=` 用例开始时刻、`closed_24h == 1`；CityFeed 里 `author_kind='city'` **恰好 1 条** |
| city 公告 | `PostCityBulletin` 走的是 custom-phone 自己的 writer；空文案/超 200 字被拒；`author_kind='city'` 落库 |

**真机（一次，写进 ACCEPTANCE）**

| 步 | 期望证据 |
|---|---|
| 结一单（结案 disposition=cited） | `world_state` 出现该 region 的 `crime_pressure` 行，`changed_by` = 结案警员工号 |
| 手机打开 CityFeed | 出现一条「📣 城市」动态，文案含区域名与单号 |
| `restart core-framework` 后再读 | `GetRegionState` 仍返回同值 —— **前提是 T2 已修 R7**，否则这条必红（返回行表）；修完还应断言返回的是 `table` 且 `value.open` 可读 |
| 结案被策略拒绝（非 lead） | **负控**：必须在正控之后跑，先记 `SELECT COUNT(*)` 与 CityFeed 条数快照，再触发非 lead 结案，断言两个计数**增量都为 0**（CC 评审指出：直接断言"没有痕迹行"在拒绝发生在 close 之前时是假验收 —— 把 `Record` 整段删掉也绿） |
| agent 侧 | `get_world_state` 工具读到新值（这条同时验证 agent 可观测） |

---

## 5.5 实施进度（2026-11-01 首轮）

| task | 状态 | 落点 | 证据 |
|---|---|---|---|
| T1 区域注册表 | ✅ | core-framework 的 shared/regions.lua | `tests/unit/layer1_core/test_world_regions.py`（4 条：锚点回落自己、半径边界、非法坐标兜底、纯度静态检查） |
| T2 修 R7 + 痕迹写者 | ✅ | services/world_state_service.lua、services/world_trace_service.lua | `tests/unit/layer1_core/test_world_traces.py`（6 条：R7 三条回归断言 + 行为 harness 的 11 组用例） |
| T3 结案挂钩 | ✅ | custom-police 的 server/p0_incidents.lua 结案分支（`pcall` 包裹） | 同上文件的挂钩断言（SELECT 带 x/y、调用点在 closed 分支内、早于通用 UPDATE） |
| T4 CityFeed 公告 | ✅ | custom-phone 的 server/city_feed.lua、server/main.lua、migrations/v3.15 | `tests/unit/layer1_core/test_city_feed.py`（5 条静态 + 行为 harness） |
| T5 前端「📣 城市」标识 | ✅ | web/src/apps/CityFeed.svelte（构建产物已重建） | `npx svelte-check` 0 errors；`npm run build` 产物 hash 更新 |
| T6 真机验收 | ⬜ 未做 | — | 需要起栈（见 §5 真机表） |

**反向校验（人工变异）**：把 `value = decodeValue(row.state_value)` 改回 `value = row` → R7 断言变红；
把结案里的 `RecordAt` 整段删掉 → 挂钩断言变红；两处都是一改就红、改回就绿（脚本跑过，见提交说明）。

**回归面**：`pytest tests/unit tests/architecture -q` → **1109 passed / 147 skipped**（基线 1100 + 新增 10 减去改写的 1 处）；
`lua5.4 tests/agent/lua/runner.lua` → 18 suites / 0 failed；四个改动的 Lua 文件 `luac5.4 -p` 全过。

---

## 6. 任务拆分

| task | 内容 | 估时 | 依赖 |
|---|---|---|---|
| T1 | `regions.lua` + `RegionOf` + 边界单测 | 0.5 d | — |
| T2 | 修 R7 读路径（`execute` + `rows[1].state_value` + `changed_by` 如实回填）+ `world_trace_service` + 注册 + 参数/幂等/去抖单测 | 1.5 d | T1 |
| T3 | p0_incidents 结案挂钩 + 解耦与反向校验单测 | 0.5 d | T2 |
| T4 | 迁移 v3.15 + `PostCityBulletin` + getCityFeed 带 `author_kind` + 单测 | 1 d | —（可与 T2/T3 并行） |
| T5 | CityFeed 前端「城市」标识 + 重建产物 | 0.5 d | T4 |
| T6 | 登记表（table_owners / export_allowlist）+ 真机验收 + CHANGELOG + 文档 | 0.5 d | 全部 |

合计 **4.5 人日**（含修 R7；比初版预估 5–8 少：砍掉了多写者、多类目、多边形区域）。

---

## 7. 不做清单（写下来免得又被提）

- 不做 polygon 区域判定（圆心 + 半径够用；将来换 polygon 只改 `RegionOf` 一个函数）。
- 不写 `world_events`（编年史下一阶段）。
- 不做 NPC 物价 / 巡逻密度联动（那是第二条链，验证完这条再谈）。
- 不接生成式文案。
- 不做痕迹的奖励结算（痕迹只改变"看得见的世界描述"，不发钱）。
- 不在客户端判定任何区域/痕迹（客户端只显示服务端回包）。

---

## 8. 风险

| 风险 | 缓解 |
|---|---|
| region_id 写进 DB 后改名要迁移 | id 用稳定英文短名，`label` 单独放中文；改名只改 label |
| 结案高频 → 刷屏 | 30 s 同键去抖 + 只有 `disposition` 非 `stale/cancelled` 才发公告 |
| 想顺手把 core-framework 加进 FIT-02 的 `scan`：那要同时改 `test_cross_resource_writes.py` 的 `RESOURCE_DIRS`，而 core-framework 还有 persistence/metadata 两条写路径，很可能一次翻出成片历史违规 | **本阶段只登记 owner、不进 scan**（边界对 10 个被扫描资源已经生效）。补扫另开一条 tech-debt 任务，先 dry-run 数违规量 |
| `world_state_service` 的 `loadFromDB` 用 `prepare` 取回的是单值，`changed_by` 拿不到（代码里是 `nil`） | 不在本次修；读需要 changed_by 时走 `GetPlayerTraces`（它查了 changed_by） |

---

## 8.5 交付标准（DoD，Claude Code 起草，2026-11-01）

| 门槛 | 命令 | 期望 | 不达标怎么处置 |
|---|---|---|---|
| 单测绿 | `pytest tests/unit tests/architecture -q`；`lua5.4 tests/agent/lua/runner.lua` | 0 failed / 0 error，且新增用例覆盖 §5 全部行 | 修红再提，不许 `-k` 跳过 |
| 反向校验会红 | 人工删 `RecordAt` 调用 / 去掉 `pcall`，重跑 | 对应用例**变红** | 不红 = 用例没测到，重写用例（不许补实现绕过） |
| Lua 语法 | `luac5.4 -p <每个改动 .lua>` | 全部 exit 0 | 逐个修；禁止用 `load()` 自查替代 |
| 登记表 | 读 `table_owners.json` | `world_state`/`world_events` 的 owner = core-framework | 缺一条即退回 |
| 文档断链 | `python3 tools/dev/docs_links_report.py` | 0 断链 | 改文档路径，不许改脚本 |
| CHANGELOG | 对照 diff 人工核 | Added（新服务/注册表）+ Fixed（R7、查询缺坐标）各有条目 | 补条目 |
| 安全闸门 | `python3 tools/dev/release_check.py` | 通过，无凭据/PII | 修，不许加白名单 |
| 真机三条自检 | 控制台 | `restart core-framework` 后 `GetRegionState` 返回 table 且 `.closed_total` 可读 | 无日志 = 未验，ACCEPTANCE 不签 |
| 负控 | 非 lead 结案前后 `SELECT COUNT(*)` + CityFeed 条数快照 | 两计数**增量 0** | 增量非 0 → 拒绝路径漏写，退回 |

> 一处修正：CC 写的是「`export_allowlist.json` 加新 export」，实际不需要 —— FIT-04 只扫 custom-police/server，
> 且新 export 属于 core-framework；`export_allowlist.json` 是"例外登记"，不是全量登记簿。所以本图的 DoD 不含这条。

**反作弊条款（照抄进 PR 描述）**

1. **空壳测试**（`assert True`、只断非 nil、跳过落库断言）→ 把被测函数体整段注释掉重跑，用例必须红；还绿就是空壳。
2. **假验收**（只断言"查不到痕迹行"，而拒绝发生在 close 之前）→ 先取 COUNT 快照再触发，断言**增量 = 0**；拿不出快照即视为未验。
3. **放宽闸门 / 只改文档**（改 `docs_links_report.py`、加 allowlist、删断言、只改蓝图文案）→ `git diff --stat` 里出现 `tools/`、`tests/architecture/` 或闸门脚本改动即退回。

---

## 9. 独立评审记录（Claude Code，2026-11-01）

一次跑题（`--max-turns 18` 被读文件吃光，无可解析结果），改成"图纸全文塞进 prompt + 只给 `Grep` + 10 turns"后 4 turns 收敛。它独立指出两件事：

| CC 的判断 | 我的复核 | 落到本图哪一处 |
|---|---|---|
| §5 真机「restart 后仍返回同值」必红：`loadFromDB` 取三列却直接 `local value = row`，还硬写 `changed_by = nil` | **成立**，且与 2026-10-21 审计的 R7 是同一条债（审计说改 `execute` + `rows[1].state_value`） | §1 事实 5、T2、§5 真机第 3 行 |
| 「非 lead 结案不产生痕迹」是假验收 —— 拒绝发生在 close 之前，删掉 `Record` 也绿 | **成立** | §5 验收表改为"正控精确计数 + 负控计数增量"两段 |

同时它给的"把 `Record` 删掉测试必须红"这条我保留但降级为**人工变异**（进不了 CI），真正的防线是正控断言。
