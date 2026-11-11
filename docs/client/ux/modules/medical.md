---
id: ux-medical
type: manual
status: active
system: ux
owner: hermes
updated: 2026-11-11
review_by: 2027-02-28
---

# 医疗与急救 · UX 设计

> 覆盖 `qb-ambulancejob`（急救/复活/医院）、`custom-consumables`（饥渴/酒精/药物，唯一写者）。

## 1. 调研（现状）

### 1.1 链路与触点

| 环节 | 实现 | 依据 |
|---|---|---|
| 倒地/濒死 | `qb-ambulancejob` 的 `InLaststand` 状态，屏幕变灰 + 倒计时 | client/main.lua（laststand 段） |
| 呼救 | 911 / 手机报警（`phone:server:report911` → `custom-police:CreateIncident`） | `custom-phone/server` |
| 玩家互救 | ALT 热区 + `[E]`？—— 实际**只有 ALT**，且需要 `firstaid` 物品 | `T-CityLite.base/resources/[qb]/qb-ambulancejob/client/job.lua`:253 |
| EMS 处理 | 医院点 ALT：上班/储物/电梯（6 个热区全是 ALT） | 扫描：`qb-ambulancejob` 6 处 target |
| 复活（管理员） | `/revive` → `hospital:client:Revive` | server/main.lua 第 681 行、client/main.lua 第 574 行 |
| 饥渴来源 | 只有 `custom-consumables` 写 `metadata.hunger/thirst` | `T-CityLite.base/resources/[custom]/custom-consumables/server/main.lua` |

### 1.2 `/revive` 到底恢复了什么（真机核对）

| 项 | 恢复？ | 实现 |
|---|---|---|
| 血量 200 / 出血 / 伤口 / 骨伤 / 疼痛 | ✅ | `ResetAll()` + `SetEntityHealth(200)` |
| 压力 | ✅ `RelieveStress 100` | client/main.lua 第 596 行 |
| 濒死/死亡标记 | ✅ | `SetDeathStatus(false)` / `SetLaststandStatus(false)` |
| **护甲** | ❌ 完全没碰 | — |
| **饥饿 / 口渴** | ❌ 完全没碰（唯一写者在 custom-consumables） | — |

### 1.3 玩家会卡住的场景

| # | 场景 | 现在 |
|---|---|---|
| 1 | 队友倒地，玩家站旁边 | 只按 E **没反应**（要按 ALT），真机已复现 |
| 2 | 被救起来 | 血量满了但仍饿着（饥渴值不变），下一分钟又倒 |
| 3 | 濒死倒计时 | 只有灰屏，没有"还有多少秒"的文字 |
| 4 | 医院上班/取车 | 6 个热区全是 ALT，玩家要长按 |

## 2. 设计（目标）

### 2.1 濒死 → 获救 流程

```
受伤倒地 → toast: "濒死 · 15 秒后失去意识"（每秒刷新剩余秒数）
   → 队友靠近 → prompt: [E] 施救（需要 firstaid）
   → 施救完成 → let: 双方 feed
        · 救人者 feed: "已救起 <名字>"
        · 被救者 feed: "已被 <名字> 救起 · 护甲 0 / 饥渴 50"
   → 若无人救 → 15 秒后失去意识 → 医院复活（同一套规则）
```

### 2.2 复活后状态（D3=甲，PO 已拍板）

| 项 | 复活后 | 由谁执行 |
|---|---|---|
| 血量 | 200 | `qb-ambulancejob` |
| 护甲 | **0** | `qb-ambulancejob`（明示"裸装起来"） |
| 饥渴 | **提到 50**（不超上限） | **`custom-consumables` 的 export**，由 ambulance 调用 |
| 压力 | 0 | 已有 |
| 伤口/出血/骨伤 | 清零 | 已有 |

> 为什么不直接写 `metadata.hunger`：饥渴的唯一写者是 `custom-consumables`，
> 任何别处直接写都会破坏"单一写者"约定（P1-5 血的教训）。

### 2.3 交互与提示

| 对象 | 键 | 提示 |
|---|---|---|
| 倒地玩家 | **E**（从 ALT 迁来） | `[E] 施救（需要急救包）`；没有物品时 `[E] 施救` 灰显 + error "需要急救包" |
| 医院前台 | E | `[E] 上班` / `[E] 下班` |
| 医院储物柜 | E | `[E] 打开储物` |
| 电梯 | E | `[E] 上楼` / `[E] 顶楼` |

### 2.4 空态与失败

| 情形 | 表现 |
|---|---|
| 没急救包 | error "需要急救包"（不是静默） |
| 距离 > 5m | 提示消失（不显示不可用的动作） |
| 施救被中断 | feed "施救中断" |

## 3. 计划（任务）

| # | 任务 | 文件 | 风险 | 验收 |
|---|---|---|---|---|
| M-1 | 施救从 ALT 热区改为 E 提示 | `T-CityLite.base/resources/[qb]/qb-ambulancejob/client/job.lua`:253、`custom-police` 同类 | 中（要实测距离/判定） | 站在倒地队友旁直接按 E |
| M-2 | 濒死倒计时加文字（剩余秒数） | `T-CityLite.base/resources/[qb]/qb-ambulancejob/client/main.lua`（laststand 段） | 低 | 倒地后屏幕显示秒数 |
| M-3 | 复活规则：护甲 0 + 饥渴 50 | client/main.lua 第 574 行、`custom-consumables` 新增 `exports('RestoreAfterRevive')` | 中（碰饥渴写者） | 复活后 HUD 圆环显示 50，护甲条为 0 |
| M-4 | 医院 6 个热区 ALT → E | `T-CityLite.base/resources/[qb]/qb-ambulancejob/client/job.lua`:446-662 | 中 | 医院前台/柜子/电梯都按 E |
| M-5 | 施救成功/失败的 feed 文案 | 同上 | 低 | 救起后双方各有 feed |

## 4. 验收（步骤）

1. 让队友把你打倒 → 屏幕出现"濒死 · 剩余 N 秒"且**每秒递减**；
2. 队友站到你旁边 → 出现 `[E] 施救`（不是 `ALT`）；
3. 队友没急救包时按 E → 左下红条"需要急救包"，**没有** toast；
4. 有急救包时按 E → 进度条 → 你被救起；
5. 被救起瞬间：HUD 血满、**护甲 0**、**饥渴 50**（若原值 < 50）；
6. 医院前台/储物柜/电梯：走近只出现一条 `[E] …`，**不需要长按 ALT**。

**反例**：复活后饥渴仍是 0（说明还在别处写）；按 E 无反应（说明热区没迁干净）。

## 5. 已知未决

- 医院床位的"付钱离床"流程没有 UX 设计（涉及扣费与同意）；
- 玩家互救的 `firstaid` 消耗逻辑与提示不一致（消耗了但没提示）；
- EMS 的 `/heal` 与 `/revive` 权限边界需要与"管理与审计"模块统一。
