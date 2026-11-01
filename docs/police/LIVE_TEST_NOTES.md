---
id: police-live-test-notes
type: audit
status: final
system: justice
owner: hermes
updated: 2026-10-24
---

# 进服测试问题记录

> 测试人：玩家 1（IYY39878）。先记录，全部测完统一修。

## 2026-10-24

### L1 第一次点击总是提示失败（待修）

- **现象**：MDT 里的操作（首次点击 10-7/10-8）第一次提示失败，再点一次成功。
- **范围**：待确认是仅状态按钮，还是所有 action 首次都失败。
- **影响**：不影响最终结果，但体验差、可能让玩家以为无效。
- **疑点（未验证）**：
  1. 手机打开后首次 `appQuery`/`appAction` 与 NUI 回调注册存在竞态；
  2. 资源重启后客户端缓存了旧 `phone_mdt` app 注册/权限，首次请求失败后第二次命中；
  3. 10-8 的 `SetJobDuty` → `OnJobUpdate` 重入，首次返回 `duty_failed`，第二次状态已收敛。
- **备注**：服务端日志需在复现时抓 `appAction` / `duty.set` / `duty_failed`。

### L2 911 已在 DB 建单，但 MDT「接警」看不到（待修）

- **现象**：`/911 测试警情一号` 后 MDT 接警列表为空。
- **实际**：DB 已有 `police_incidents #6`，`status=open`，`code=911`，审计 `incident.create` 已写。
- **判断**：创建成功，**前端列表没有刷新**。MDT 的 `ensure('dispatch')` 只加载一次；如果 911 发生在加载之后，列表仍是旧快照。手动点「刷新」应能看到。
- **建议修法**：911/NPC 警情创建后推送事件刷新列表，或在调度页做 15–30s 轮询；至少给「新警情」提示。
- **临时绕行**：MDT「调度 → 接警」点刷新。

### L3 NPC 支援设计有缺陷（待补细节）

- **现象**：实测后认为 NPC 支援设计有缺陷（具体表现待用户补充：可能是到场不跟随/不反击/警车卡住/回收异常/误伤）。
- **影响**：NPC 支援 MVP 不能按当前形态交付。
- **后续**：需要拿到具体场景（截图/描述）后重做行为状态机或生成/回收逻辑。

### L4 MDT「接警」空 + 刷新无反应（待修，阻断 B/D）

- **现象**：`/911` 和 `npc_callout` 都已建单（DB `police_incidents #6/#7` open），但 MDT 接警页为空；点「刷新」无反应。
- **代码定位**：
  1. `PoliceMDT.svelte` 的 `refresh()` 没有 `try/finally`：首次 `queryApp` 只要一次 reject/挂起，`loading` 永远为 true，刷新按钮一直 disabled，表现为“点了没反应”。
  2. `police_mdt.lua` 的 `units`/`incidents` handler 把 export 的 `false,error` 吞成 `{rows={},count=0}`，UI 显示空列表而不是错误，无法定位是权限/审计还是查询失败。
  3. 首次失败可能来自资源重启后 phone app 注册/回调竞态；第二次打开或刷新才恢复（与 L1 同源）。
- **建议修法**：`refresh()` 用 `try/finally` 复位 `loading`；handler 返回 `{ok=false,error}`；首次查询失败自动重试一次；911/NPC 创建后推事件刷新。
- **临时绕行**：关闭手机重新打开 MDT，或先点其他页再回调度；仍可能空白。

### L5 刑满后无法在自由门按 E 退出（已修，待复测）

- **现象**：sentence 到期/减刑后，走到自由门按 E 不出去，只提示剩余时间。
- **原因**：
  1. `prison:client:Leave` 只看本地 `jailTime`，而本地按分钟递减，落后于服务端 `ends_at`；
  2. `prison:client:UnjailPerson` 只在 `jailTime > 0` 时执行，本地已到 0 时 sweep 释放变成空操作；
  3. sweep 只发 `UnjailPerson`，没有把服务端剩余同步给客户端。
- **修复**：
  - 客户端 `UnjailPerson` 改为 `inJail or jailTime > 0`；
  - 新增 `prison:client:SyncJailTime`，WorkReduction 与 sweep 都推送服务端剩余；
  - 自由门按 E 时新增 `prison:server:RequestRelease`，服务端复核 `RemainingSeconds` 后强制释放/提示。
- **复测**：入狱 → 减刑/等 sweep → 自由门按 E。
