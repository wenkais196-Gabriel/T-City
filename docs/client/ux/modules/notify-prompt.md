---
id: ux-notify-prompt
type: manual
status: active
system: ux
owner: hermes
updated: 2026-11-11
review_by: 2027-02-28
---

# 通知与交互提示 · UX 设计

> 横向模块：其余所有模块都通过它说话。覆盖 `custom-notify`（三层通知）、
> `custom-prompt`（交互提示）、`qb-core` 的 `QBCore:Notify`（历史通道）。

## 1. 调研（现状）

### 1.1 通道盘点（实测规模）

| 通道 | 调用点 | 外观 | 依据 |
|---|---|---|---|
| `QBCore:Notify`（带 type） | ≈440 | 屏幕右侧，黑底 + 左色条 + 图标 + 进度 | `T-CityLite.base/resources/[qb]/qb-core/client/functions.lua`:182 |
| `QBCore:Notify`（无 type） | ≈110 | 落到 GTA 原生 feed（左下） | 同上 |
| `NativeNotify.Show/Advanced` | 20 | 左下黑条，可带头像 | `T-CityLite.base/resources/[qb]/qb-core/client/native_notify.lua`:95 |
| `DrawText` | 52（12 资源） | 屏幕左中，单条 | `T-CityLite.base/resources/[qb]/qb-core/client/drawtext.lua`:7 |
| `qb-target` 热区（带 label） | **19**（10 资源） | 长按 ALT 的世界物件面板，按住禁移动 | 扫描（`AddBoxZone`/`AddTargetEntity` 等） |
| `chat:addMessage` | 99 | 左上滚动历史 | — |
| 手机通知 | 14 | 手机内列表，无 toast 无音 | `T-CityLite.base/resources/[custom]/custom-phone/server/core/notify.lua`:156 |
| `custom-notify`（新） | 1（试点） | feed 左下 / toast 中央 / error 左下红 | 本仓库新增 |
| `custom-prompt`（新） | 0（未迁移） | 准星下方单条 + 右侧 ≤3 | 本仓库新增 |

### 1.2 问题

| # | 问题 | 后果 |
|---|---|---|
| 1 | 没有"哪条消息走哪条通道"的规则 | 罚款、短信、NPC 台词、系统错误长一个样 |
| 2 | 同一件事可能同时发两条（NUI + 原生 feed） | 玩家看到重复 |
| 3 | `QBCore:Notify` 限流 **200ms/1 条** | 一次交易的第二条（"余额不足"）被静默丢掉 |
| 4 | 交互提示三套并存（DrawText / ALT 面板 / 原生 feed） | 玩家猜不到按什么 |

## 2. 设计（目标）

### 2.1 通道边界（唯一判定表）

| kind | 判定条件（if 就能写出来） | 位置 | 时长 | 上限 |
|---|---|---|---|---|
| `feed` | 玩家**主动**做了动作且**成功** | 左下（小地图上方） | 5s | 4 |
| `toast` | 玩家**没主动**做但影响他 | 中央偏上 | 2.5s | 2 |
| `error` | 玩家动作**没生效** | 左下红色 | 5s | 4 |
| `phone` | 内容来自另一个玩家 / NPC / 系统凭证 | 手机通知中心 | 永久 | 50 |

### 2.2 交互提示形态

| 情境 | 形态 | 参数 |
|---|---|---|
| 面前唯一动作 | 准星下方单条 `[E] 打开商店` | 键块 + 动词，长按类带进度条 |
| 2–3 个动作 | 右侧列表 ≤3 条 | 排序：距离由近到远 |
| >3 个动作 | 只列最近 3 + `+N 更多` | — |
| 世界物件（多目标） | 右侧列表，键位统一 `ALT` | 按住时**不禁移动**（待改） |

### 2.3 禁止项

- `error` 走 toast（打断）。
- IC 内容上屏（毁世界观）。
- 同一事件双通道（重复）。
- 一个交互物件同时有 E 和 ALT（猜不到）。

## 3. 计划（任务）

| # | 任务 | 文件 | 风险 | 验收 |
|---|---|---|---|---|
| N-1 | 给 `QBCore:Notify` 加一层兼容分派：带 type 的走旧 NUI，无 type 的走新 `feed` | `T-CityLite.base/resources/[qb]/qb-core/client/functions.lua`:182 | 中（550 调用点） | 现有调用行为不变，但样子统一 |
| N-2 | 迁移 12 个资源的 `DrawText` → `custom-prompt` | 见 INDEX 阶段 A | 低 | 提示出现在准星下方 |
| N-3 | `qb-target` 收紧到"多目标专用"，单目标改 E | 19 个热区 | 中 | 单目标不再需要 ALT |
| N-4 | `custom-notify` 增加"去重"：同文本 3 秒内合并 | `T-CityLite.base/resources/[custom]/custom-notify/server/main.lua` | 低 | 连点两次只出一条 |

## 4. 验收（步骤）

1. F8 执行 `/notifytest feed|toast|error`（`setr notify_dev 1`）：三条分别落在左下/中央/左下红；
2. 吃一个食物：左下 feed 出现"水：饥饿/口渴"且 HUD 圆环同步；
3. 走到商店：只有一条 `[E] 打开商店`；
4. 钱不够时购买：左下红条，**无**中央 toast；
5. 连点两次购买按钮：只出现一条 feed（去重生效）。

## 5. 已知未决

- `QBCore:Notify` 的 550 个调用点迁移策略（一次性改完 vs 按模块分批）—— 目前选分批；
- `qb-target` 的"按住禁移动"是否可配置（影响 19 个热区的操作手感）；
- `chat:addMessage` 的 99 处是否要收进 `feed`（管理公告例外）。
