# ARCHITECTURE — 四个平面与依赖方向

> 这份文件回答一个问题：**谁可以调用谁**。
> 目录结构不是约束，依赖方向才是。凡是本文没写允许的调用，都属于禁止。
> 配套闸门：`tests/architecture/test_plane_boundaries.py`、`test_resource_wiring.py`。

## 0. 一张图

```
        ┌──────────────────────────────┐
        │  P1  NUI（CEF 页面）          │   Svelte 5 + Vite，产物 html/
        │  custom-phone/web/src         │   ❌ 无 DB、无 net event、无游戏原生
        └───────────────┬──────────────┘
                        │  https://<resource>/<callback>   （唯一通道：fetchNui）
        ┌───────────────▼──────────────┐
        │  P2  Client Lua               │   ❌ 无 DB、无 SQL；可读玩家状态
        │  */client/**                  │
        └───────────────┬──────────────┘
                        │  TriggerServerEvent / TriggerCallback   （必须过鉴权）
        ┌───────────────▼──────────────┐
        │  P3  Server Lua               │   ✅ 唯一可以碰 DB / 钱 / 物品
        │  */server/**                  │
        └───────────────┬──────────────┘
                        │  MySQL（参数化，列白名单，LIMIT）
        ┌───────────────▼──────────────┐
        │  P4  DB（MariaDB / TCityLite）│   表归属见 table_owners.json
        └──────────────────────────────┘

        ┌──────────────────────────────┐
        │  P0  Shared（纯数据/纯函数）  │   shared/、config.lua、types
        │  被 P1/P2/P3 引用，不反向依赖 │
        └──────────────────────────────┘
```

## 1. 平面定义与唯一入口

| 平面 | 载体 | 唯一入口 | 禁止 | 现有闸门 |
|---|---|---|---|---|
| **P1 NUI** | `resources/[custom]/custom-phone/web/src/**` | `resources/[custom]/custom-phone/web/src/utils/nui.ts`：`fetchNui` / `requestAppQuery` / `requestAppAction` | 裸 `fetch`、拼 `cfx-nui-` 主机名、直接 `SendNUIMessage` 语义、读业务 localStorage | `test_nui_client_contracts.py`、`test_nui_baseline.py` |
| **P2 Client** | `resources/*/**/client/**` | `RegisterNUICallback` / `PhoneBridge.RegisterNui`（应答通道统一走 `AnswerFn`） | `MySQL.*`、`exports['oxmysql']`、直接改钱/物品、直接 `LoadResourceFile` 服务端数据 | `test_plane_boundaries.py`、`test_phone_client_core.py` |
| **P3 Server** | `resources/*/**/server/**` | `RegisterNetEvent` + 鉴权 / `exports` / DB helper | 依赖客户端已验证、把 NUI 当权限、`SetNuiFocus`（客户端原生） | `test_net_event_auth.py`、`test_query_discipline.py`、`test_export_contracts.py` |
| **P0 Shared** | `resources/*/**/shared/**`、`*/config.lua` | 纯函数 + 常量表 | `RegisterNetEvent`、`TriggerClientEvent`、`SetNuiFocus`、任何 IO | `test_plane_boundaries.py` |

## 2. 四条方向规则

1. **只能向下调用**：P1 → P2 → P3 → P4。反向（P3 主动"读" P1 的状态）不存在——
   服务端要影响界面只能用事件推下去。
2. **P0 不被任何平面反向依赖**：shared 里出现 `RegisterNetEvent` / `SetNuiFocus`，
   说明它偷偷变成了某一侧的代码。
3. **跨资源调用必须显式**：`exports['<res>']:*` 与自定义 net event 都是"契约"，
   改签名 = 破坏性变更，必须在 PR 里点名所有调用方。
4. **诊断通道是单向的**：`phone:server:diag`、`phone:server:clientError` 这类只接收不回包，
   也禁止携带业务 payload（见宪法第 7 条）。

## 3. 唯一通道速查

| 需求 | 唯一做法 | 反例（会被闸门或评审打回） |
|---|---|---|
| 前端拿数据 | `fetchNui('<callback>', payload)` → 客户端回调 → `PhoneBridge.Request` → 服务端 | 页面里 `fetch('https://cfx-nui-...')` |
| 前端做动作 | `requestAppAction` → 服务端 `appAction` 分支（带限流与权限） | 前端拼 SQL / 直接改 store 当成已生效 |
| 客户端拿数据 | `PhoneBridge.Request(event, payload, cb, timeoutMs)` | 自己维护 request id 表 |
| 服务端推 UI | `TriggerClientEvent('phone:client:...')` → 客户端 `SendNUIMessage` | 服务端直接发 NUI 消息（不存在） |
| 改钱/物品 | `Player.Functions.AddMoney` / `core_economy:TriggerReward` | `UPDATE players SET money` |
| 新增表 | `migrations/v*.sql`（幂等）+ `table_owners.json` + `tests/fixtures/tcity_schema.sql` | 直接改库 |

## 4. 平面之外：资源边界

`resources/` 下有 116 个资源，它们之间的耦合靠三份登记表约束：

- `net_events_allowlist.json`：事件名 → 类别（`auth` / `diagnostic`）/ owner / 到期日；
- `table_owners.json`：表 → owner 资源，跨资源写必须走 owner；
- `resource_wiring_allowlist.json`：资源级引用（`exports` / 资源名硬编码）的豁免登记。

新增任何一条跨越这三个边界的调用，必须在同一 PR 里更新对应登记表，并写清楚
"投影 / 限流 / 预算"或"为什么不需要"。这不是形式主义：登记表的 `expires` 是债务回收的钩子。

## 5. 改动影响面自查

改一个平面的东西，按这张表往下看一层就够：

| 你改了 | 必须同时检查 |
|---|---|
| `web/src/**` | `npm run build` → `html/` 产物提交；`index.html` 的 hash 引用；`test_nui_baseline.py` |
| `client/**` | 回调是否经 `AnswerFn`；焦点配对；`restart <resource>` 后自检（`[probe]`） |
| `server/**` | 事件鉴权登记；查询白名单；错误码是否与前端映射一致 |
| `shared/**` | 两侧都重启；类型/常量是否被两边同时引用 |
| `migrations/` | `tests/fixtures/tcity_schema.sql` + 幂等重跑 |
