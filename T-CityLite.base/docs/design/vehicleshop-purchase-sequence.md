---
id: base-vehicleshop-purchase-sequence
type: spec
status: active
system: vehicle
owner: hermes
updated: 2026-10-21
review_by: 2027-04-30
---

# qb-vehicleshop 购车流程梳理（v0.7a 实测后）

> 目的：把当前 NUI 购车 sequence 与成熟 FiveM 车店对比，明确已修项与剩余优化。
> 日期：2026-10-21

---

## 1. 当前 sequence（NUI 模式）

```
玩家走入 PDM PolyZone
  → zones.lua: insideShop=name, _vSetClosestShowroomVehicle()
  → 仅提示“按 E 浏览车辆”，不自动打开面板
  → 玩家按 E → _vOpenNui(name)
  → nui.lua: SetNuiFocus(true,true) + SetNuiFocusKeepInput(true)
  → SendNUIMessage({type='open', vehicle/specs/finance...})
  → NUI 渲染面板

玩家操作
  ├─ Buy Now    → fetch buyVehicle → 客户端回调 → 关闭焦点 → TriggerServerEvent(buyShowroomVehicle)
  │                → 服务端校验执照/余额 → 扣钱 → INSERT player_vehicles
  │                → TriggerClientEvent(buyShowroomVehicle) → 客户端 spawn → 给钥匙 → 传送上车
  ├─ Finance    → fetch financeVehicle → 扣首付 → 插入分期字段
  ├─ Test Drive → fetch testDrive → 关闭焦点 → TestDrive 事件（NUI 仍 visible）
  ├─ Change     → fetch swapVehicle → 关闭面板 → 提示走到其他展车旁按 E
  └─ Close/ESC  → fetch closeNui → 关闭焦点 + 隐藏

玩家离开区域
  → _vCloseNui()（v0.7a 修复：确保 nuiOpen=false）
```

## 2. 实测发现的问题

| # | 问题 | 影响 | 状态 |
|---|------|------|------|
| 1 | 每次展示车变化都重新 `open` + 抢焦点 | 闪屏、焦点丢失、日志重复 Opening NUI | ✅ 改为 `update` 原地刷新 |
| 2 | 离开区域没有重置 `nuiOpen` | 再进店只 update 不显示/不抢焦点 | ✅ `_vCloseNui()` |
| 3 | Buy/Finance 乐观隐藏 NUI，失败无反馈 | 余额不足/执照不足时只看到通知，面板已消失 | ✅ Buy 已改为 processing/error；Finance 仍乐观 |
| 4 | TestDrive 只关焦点不隐藏 NUI | 试驾时车店面板残留在屏幕上 | ⚠️ 仍待做关闭+试驾 HUD |
| 5 | Change Vehicle 走 qb-menu 分类再重开 | 两套菜单切换，体验割裂 | ✅ 关闭并提示按 E 换车 |
| 6 | 无 loading / 防连点 | 快速双击可能重复发购买事件 | ✅ NUI processing + 服务端 2s 防连点 |
| 7 | 服务端无距离/频率二次校验 | 客户端可伪造事件远程购买 | 🟡 已加 2s 频率限制；距离校验待做 |
| 8 | 扣钱与 INSERT 非事务 | INSERT 失败会扣钱不交车 | ⚠️ 建议失败退款/事务 |
| 9 | 车店 NUI 默认关闭 | 用户默认看到 qb-menu，不是 v0.7a NUI | 配置项 `vehicleshop_use_nui` 控制 |

## 3. 与成熟车店对比

| 环节 | 成熟做法（qb/ESX/ox 系） | 当前实现 | 建议 |
|------|--------------------------|----------|------|
| 打开 | 进店按 E 主动打开，不自动劫持 | 已修为 E 提示 + update | ✅ |
| 数据 | 服务端报价 + 车辆配置，客户端只展示 | 客户端读 `QBCore.Shared.Vehicles` | 中 |
| 购买 | 确认弹窗 → loading → 成功/失败 → 关闭 | 直接买，失败仅 notify | 高 |
| 防刷 | 服务端校验距离/事件 nonce/rate limit | 仅金额/执照 | 高 |
| 交付 | 事务扣款 + 插库 + spawn + 钥匙 | 先扣钱后异步插库 | 高 |
| 试驾 | 关闭面板、独立车辆、倒计时、归还点 | 面板残留 | 中 |
| 分期 | 首付/期数校验、月供展示、合同 | 已有基础 | 中 |
| 换车 | 店内左右切换/分类，不重开 | qb-menu 分类重开 | 中 |
| 反馈 | 错误留在面板内，可重试 | 面板关闭 | 高 |

## 4. 本轮已修

- 进店不再自动打开购买面板，改为“按 E 浏览车辆”；关闭后不会自动重开。
- NUI `open` / `update` 分离：展示车变化不再闪屏/重复抢焦点。
- 离开区域统一 `_vCloseNui()`，重置 `nuiOpen`。
- Buy/Finance/TestDrive/Swap 回调统一关闭 NUI，避免面板残留。
- NUI 增加 `update` 消息处理，切换车辆保留分期输入。
- 新增 Playwright 购车序列断言：open → update → close → open → Buy Now → 校验 `buyVehicle` 请求体含正确车型 → 失败错误态 → 成功关闭。
- 服务端购买新增车辆参数校验、2 秒防连点、`purchaseResult` 事件。

## 5. 自动化覆盖

| 层 | 测试 | 覆盖 |
|----|------|------|
| NUI | `tests/nui/run_ui_tests.py` | 打开、原地切换、关闭、Buy Now 请求体 |
| 服务端 | `tests/unit/layer3_business/test_vehicleshop.py` | 购买扣钱、INSERT、事件路径 |
| 游戏内 | `test run all` | 车店资源加载/Convar/callback 注册 |

**未覆盖**：INSERT 失败退款、服务端距离校验、分期失败反馈、试驾全流程。

## 6. 下一步优先级

1. 购买确认 + loading + 错误留在面板（P0）
2. 服务端距离/频率校验 + 扣款插入失败退款（P0）
3. 试驾关闭面板 + 试驾 HUD/倒计时（P1）
4. NUI 内换车，不再走 qb-menu（P1）
5. 分期合同/还款入口（P2）
