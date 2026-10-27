# 08 · 客户端状态探测（read-only probe）

> L3（跨资源：`custom-phone` → `custom-agent-client` → `custom-director`，新增事件 + 导出 + HTTP 路由 + 两个只读工具）。
> 前置：`06-client-model.md` §5.2 缺口 #1「客户端状态不可读」、§5.3 `client.ui_probe`。

## 1. 范围

- 要做：
  1. `custom-phone` 暴露 `GetUiState()`（只读、白名单字段）；
  2. `custom-agent-client` 每 5s（以及登录后立即）把**结构化快照**推给服务端，服务端校验后按 source 缓存；
  3. `custom-director` 的 live 通道加 `GET /agent/v1/live/clients[/{citizenid}]`（live token，只读）；
  4. 两个工具：`get_client_state`（director/live）、`get_server_state`（director/live，进程级）。
- 不做：
  - 不给客户端任何新动作（本次仍然只有 6 个 handler；`ui_open/ui_close` 留到下一版）；
  - 不把 NUI 正文/玩家输入带出来（只有枚举、布尔、数字）；
  - 不引入新表（快照只在内存里，`agent_events` 不写）；
  - 不改 `agent_effects` / `agent_actions` 语义。

## 2. 验收标准（可执行）

| # | 标准 | 怎么验证 |
|---|---|---|
| 1 | 快照只在服务端内存，且 15s 过期 | `pytest -q T-CityLite.base/tests/agent` 的 `client_state` 用例：写入→读取→推进时钟→过期返回 nil |
| 2 | 未知字段/超长字符串/非白名单枚举被丢弃 | 同上：喂 `{ui={app='x'*500}}`、`{foo=1}` 后读回的快照键集合固定 |
| 3 | 每个 source 1 次/秒上限 | 连发 5 条只接受 1 条（`dropped` 计数） |
| 4 | 玩家掉线/资源停止清空 | `playerDropped` 后 `/clients/:citizenid` → 404 `client_state_unavailable` |
| 5 | 路由只读、要 live token | `curl -H "Authorization: Bearer dev-live-token" .../live/clients` → 200；无 token → 401 |
| 6 | 工具注册表一致 | `python3 tools/agent_tools.py --check` → OK |
| 7 | 实机可见 | 进服后 `/live/clients` 返回 `{logged_in:true, phone:{open:false,...}, screen:{w,h}}` |

## 3. 契约（唯一事实源：本文 + `tools/agent_tools.json`）

```jsonc
// GET /agent/v1/live/clients
{ "schema_version": 1, "count": 1, "sampled_at": 1793..., "clients": [ { …snapshot, citizenid, source, age_ms } ] }

// GET /agent/v1/live/clients/{citizenid}
{ "schema_version": 1, "client": { …snapshot, citizenid, source, age_ms } }

// snapshot（服务端只存这些键）
{
  "v": 1,
  "logged_in": true,
  "phone": { "open": false, "surface": "phone"|"tablet"|null,
             "focused": false, "keep_input": false, "focus_owner": "phone"|null,
             "nui_focus_native": false,
             "app": { "id": "quests", "tab": "active", "selected": null } /* 可选 */ },
  "ped":   { "in_vehicle": false, "vehicle_class": 0, "health": 200, "dead": false },
  "screen":{ "w": 1920, "h": 1080 }
  // focused/keep_input 报的是 PhoneFocus 的记账（我们申请到了什么）。
  // nui_focus_native 是引擎原生的原话：本 build 恒 false（nui-debug-playbook §3.0a），
  // 两者不一致 ≠ 手机没焦点，只是原生在撒谎；判定永不读它。
  // 壳的状态（open/surface/focus）由 Lua 自己知道；app 块只能由 App 回吐：
  // Svelte 侧 reportAppState(app, tab, selected) → fetchNui('appState') → Lua 存三个
  // 短 token。任务 App 已接；MDT/银行还没有，所以 app 是可选字段，缺了不代表出错。
}
```

- 枚举：`surface ∈ {phone, tablet}`、`focus_owner` 字符串 ≤ 16 且 `[a-z0-9_]`。
- 数字全部取整并夹紧（health 0–1000、vehicle_class 0–23、screen 320–8192）。
- `age_ms` 由服务端算，客户端不能提供。

## 4. 切片

| # | 切片 | 文件 | 验证 |
|---|---|---|---|
| S1 | `GetUiState()` 导出 | `T-CityLite.base/resources/[custom]/custom-phone/client/main.lua` | `luac5.4 -p`；实机 `/clients` 里 `phone.open` 随 M 变化 |
| S2 | 客户端采集 + 服务端缓存 | `T-CityLite.base/resources/[custom]/custom-agent-client/client/main.lua`、`T-CityLite.base/resources/[custom]/custom-agent-client/server/main.lua` | Lua golden 新增 `client_state` 用例（sanitize/过期/限流/掉线清空） |
| S3 | live 路由 | `T-CityLite.base/resources/[custom]/custom-director/server/live_api.lua` | `live_api` golden 加 3 个 case（list/detail/404/401） |
| S4 | 工具 | `tools/agent_tools.json` → `agent_tools.py --write` | `--check` OK；MCP `tools/list` 41 |
| S5 | server state | `T-CityLite.base/resources/[custom]/custom-director/server/live_api.lua`（`/agent/v1/live/server`） | 实机 curl：`{uptime_s, players, weather, time, resources:{started,total}}` |
| S6 | 文档数字 | `TOOLS.md`、`STATUS.md`、`AGENTS.md` | docs 闸门 |

## 5. 回滚

- 代码：`git revert <merge sha>`（三处都是新增，无迁移）。
- 运行时：`restart custom-phone custom-agent-client custom-director`。
- 数据：无（内存态，重启即清）。

## 6. 风险

| 风险 | 处理 |
|---|---|
| 5s 心跳变成噪音 | 事件驱动（手机广播 `phone:client:stateChanged`）+ 5s 心跳兜底；服务端 1/s 限流；不落库、不打日志 |
| 跨资源 `exports` 在客户端不可靠（06 P10） | 全部 `pcall` + 缺省值；phone 没起来时 `phone=null` 而不是整条失败 |
| 快照被当成"证据" | `age_ms` 必填；>15s 直接 404，避免 agent 拿旧状态做决定 |
| 玩家伪造快照 | 只当"客户端自述"，不做权限/判定依据；服务端仍以自身状态为准 |
