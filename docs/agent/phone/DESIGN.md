---
id: phone-design
type: spec
status: active
system: comms
owner: hermes
updated: 2026-10-31
review_by: 2027-04-30
supersedes: [base-agent-phone-design]
source_of_truth: true
---

# custom-phone 性能与职业 App 接口设计

> 输入：`qb-phone-research.md`（上游 qb-phone 架构/性能/借鉴清单）、`custom-phone-audit.md`（本地 20 条 bug、10 条性能问题）。
> 本文只定方向与接口；P0 数据层修复已随 `cc1965d` 落地，见文末"已完成"。

## 1. 结论先行

**不换手机、不抄 qb-phone 的数据层。** custom-phone 已有比 qb-phone 更好的底子：Svelte 前端、按行存 `phone_messages`、事件推送。真正缺的是三件事：

1. **服务端权威的职业 App 注册表**（现在写死在 `App.svelte` 的 13 个分支里）；
2. **一致的角色解析**（`custom-career` v2 没有 `primary_role`，已用 `PhoneIdentity.Resolve` 适配）；
3. **查询预算**（当前开屏 fanout、无分页、无缓存上限；qb-phone 的 60s 全量轮询更差，不要学）。

## 2. 从 qb-phone 借什么、不借什么

| 借鉴 | 原因 |
|---|---|
| 锁屏/关闭状态也能看到的 OS 级通知 | 成本低、体验收益高；我们已有 `phone:client:newNotification`，只差可见性 |
| 可操作通知/邮件按钮（接受/拒绝/导航） | 把"通知"变成动作入口，减少打开 App 的层级 |
| App 网格 + 未读角标 | 职业 App 的入口形态，NUI 侧一次做好 |
| `job` / `onduty` 门控 | 权限必须服务端再校验，NUI 隐藏只算 UX |
| 短信/通话事件推送 | 我们已有；不要退回轮询 |

| 不借 | 原因 |
|---|---|
| `phone_messages` 按联系人对存 JSON、整段双写 | 并发丢更新、无单条 ID、无法分页；我们现已按行存 |
| 70KB 单页 `index.html` + 84 个 NUI callback | 新增 App 改 7–9 个文件；我们要注册表 + schema 渲染 |
| 客户端隐藏 = 权限 | MDT callback 无 job 校验，客户端可直接调 |
| 关闭手机仍 60s 全量拉取 | 48 人约 5.6 qps 的无意义查询 |
| `-1` 全服广播、无清理的内存 map | 与"职业 App 单播"目标相反 |

## 3. 目标架构

```
┌──────────────────────────── client (Svelte) ────────────────────────────┐
│ App.svelte        AppGrid（由 registry 渲染）   通用 AppView(schema)      │
│ stores/call.ts    未读角标/通知中心              动态组件（仅特殊 App）    │
└───────────────▲───────────────────────────────▲─────────────────────────┘
                │ phone:app:registry (一次)      │ app:query / app:action
┌───────────────┴───────────────────────────────┴─────────────────────────┐
│ server: PhoneApps.Register / CanUse / HandleQuery / HandleAction         │
│         权威角色解析 PhoneIdentity.Resolve(source)                        │
│         数据访问 PhoneDb（insert/execute 归一化）                          │
└───────────────▲─────────────────────────────────────────────────────────┘
                │ 只读视图/限界查询（LIMIT + 复合索引）
             MariaDB (phone_messages, phone_contacts, phone_notifications, ...)
```

### 3.1 服务端注册协议（最小可行）

```lua
-- server/phone_apps.lua
PhoneApps.Register({
    id = 'police_mdt',
    label = 'MDT',
    icon = 'shield',
    audience = { jobs = { 'police' }, onduty = true },
    -- 查询：只读，默认分页
    queries = {
        incidents = function(source, params)  -- params: {cursor, limit}
            return { rows = ..., next_cursor = ... }
        end,
    },
    -- 动作：写，服务端二次鉴权 + 幂等键
    actions = {
        assign_case = function(source, params)
            -- 返回 {ok=true, data=...} 或 {ok=false, code='...'}
        end,
    },
})
```

约束：

- `audience` 只是**默认拒绝**：`CanUse(source, appId)` 在服务端按 `job_name/rank_tier/onduty` 判断，NUI 隐藏不构成权限；
- `queries` 必须有 `LIMIT`，服务端统一 `clamp_limit`（默认 20，最大 50）；
- `actions` 必须带 `idempotency_key`，写路径走现有 `PhoneDb`；
- 新增职业 App = 1 个 server 模块 + 1 个 NUI 组件（或用 schema 渲染，0 个组件）。

### 3.2 客户端注册表

- 服务端在 `phone:open` 时返回 `apps = PhoneApps.ForPlayer(source)`（id/label/icon/unread/audience 结果），不返回 query 实现；
- `AppGrid` 用这个列表渲染，替代 `App.svelte` 的硬编码分支；特殊 App（PhoneCall/Camera）保留本地组件映射；
- 未读角标由 `phone:app:unread` 推送，不轮询。

### 3.3 性能预算

| 指标 | 目标 | 现状 |
|---|---|---|
| 开手机 DB 查询数 | ≤ 3 条（profile/contacts/unread） | 5 条 fanout（audit Q1） |
| 消息列表 | 每会话 `LIMIT 30` + cursor | 全量（audit Q2） |
| 联系人头像 | 批量一次，禁用前导 `LIKE '%...%'` | N+1 / 全表扫 |
| 推送 | 事件驱动，无常驻轮询 | 已无 60s 轮询（修复） |
| NUI 首包 | ≤ 30KB gzip | 待测 |

## 4. 分阶段路线

**P0（已完成，`cc1965d`）**
- `phone_messages` 迁移 v2.7 + 索引；
- `PhoneDb.InsertId/AffectedRows` 统一 oxmysql 返回值；
- 通知回环拆除（`origin='server'`，只落库一次、单播一次）；
- 来电常驻监听 + M 键输入保护 + 时间推送降频；
- job cache 作用域、jobboard 奖励回滚、`PhoneIdentity.Resolve`。

**P1（下一步，职业 App MVP）**
- `PhoneApps` 注册表 + `CanUse` + `app:query/app:action` 路由；
- 先接 1 个职业：**police MDT**（案件列表/指派），验证鉴权、分页、审计；
- NUI：AppGrid 从 registry 渲染 + 通用列表组件。

**P2（性能与通话）**
- 消息会话分页 + 保留策略；联系人头像批量；开屏查询合并；
- 通话服务端状态机（ringing/ongoing/missed/completed）+ 掉线清理 + 语音通道；
- 通知中心分页/已读。

**P3（可观测）**
- `phone_metrics`（查询数/耗时/推送失败）接入 evaluator；
- 职业 App 审计（谁调了什么、被拒原因）。

## 5. 验收与测试

- Lua：`PhoneApps.CanUse` 单测（job/onduty/未知 App 默认拒绝）、`clamp_limit` 边界；
- Python：迁移幂等、insert 契约、registry schema（参考 `tools/agent_contract.py` 的做法，钉死 App 清单）；
- 实机：无警察 job 的玩家打 `/phone police_mdt` 必须被服务端拒绝；有 job 的玩家分页/指派成功；
- 性能：开手机查询数 ≤3、消息列表首屏 ≤30 条、NUI 首包 ≤30KB（用 FiveM NUI devtools/日志计时）。

## 6. 与现有系统的兼容

- 消息仍写 `phone_messages`，职业 App 复用 `phone_notifications` 做入口；
- `PhoneIdentity.Resolve` 已是唯一角色入口，新 App 不再直接读 `identity.primary_role`；
- `phoneDataCache` 的失效点（写路径）继续保留，注册表变化时只推 `registry` 事件，不整包重拉。

## 7. 尚未解决（明确记录）

- 旧 `phone_messages_legacy` 的 JSON 数据不自动 explode（需要单独脚本）；
- 真实铃声资产（当前 WebAudio 合成，可能被 autoplay 策略静音）；
- 服务端振铃超时/掉线清理依赖 P2 的状态机；
- 语音（pma-voice）与手机通话的频道绑定未验证。
