---
id: industry-ops-w2-push-plan
type: plan
status: active
system: economy
owner: hermes
updated: 2026-11-27
review_by: 2027-03-31
stage: P
plan_status: 1
---

# 计划：W2 — 周期公告推送（警告 + 结果，#389）

```plan-status
ALL | done | #389 | 2026-11-27
```

---

结算会清空设施、库存、配额与金库余额。没有提前通知，玩家会以为资产被偷。
S7 只做了 CityFeed（打开手机才看得到），这一片补**手机推送**。

## 1. 契约

| 面 | 内容 |
|---|---|
| 通知出口 | `custom-phone` 的 `Notify(citizenid, title, content, appId, meta)` —— 既有导出，**零新 net event** |
| 白名单 | `NOTIFY_APP_IDS` 放行 `industry`，通知可深链进产业 App |
| 收件人 | **只有在线**且属于 `Config.Industry.OrgWhitelist` 的成员；组织判定只走 `IndustryAccess.OrgMembership` |
| 水位 | **不自建**：挂在既有 `warning_announced_at` / `result_announced_cycle` 之后，同周期只发一次 |
| 失败 | 推送崩了只打日志，不阻断公告与结算 |
| PII | 正文只含周期号、组织名、金额、威望；无玩家名 / 坐标 / citizenid |

## 2. 离线验证（我跑的，不是自报）

| 检查 | 结果 |
|---|---|
| `test_industry_push.py` | **9 passed** |
| `layer3_business` + `architecture` | 1808 passed / 16 skipped / 51 subtests |
| `release_check.py` | 通过（6602 文件） |
| net event 新增 | **0** |

### 2.1 我补的两条用例（CC 最初的 7 条有两个洞）

| 注入 | CC 交来时 | 补完之后 |
|---|---|---|
| 删 `pushSafely` 外层 `pcall` | **7 passed**（原用例让 `Notify` 抛错，异常落在 per-player 内层 pcall，外层从没被走到） | 让 **Player 对象本身畸形**（`PlayerData` 访问抛错）→ 删掉外层 pcall 即 **1 failed** |
| 删 `result_announced_cycle` 水位 | **7 passed**（原用例 `Tick(1001)` 到不了结果公告：结算后阶段已翻页，是**阶段**挡的，不是水位） | 直接对同一周期调两次 `IndustryAnnounce.Result`（覆盖结算重试 / `industry_settle` 重跑）→ 删水位即 **1 failed** |

## 3. 真机验收（2026-11-27，压缩周期）

旋钮：`industry_phase_seconds=60`、`industry_cycle_warn_seconds=60`、`industry_cycle_retry_seconds=1`
（**改完要 `restart custom-industry`**，见 `docs/engineering/LIVE_VERIFICATION.md` §2.1）。
周期起点：`UPDATE industry_state SET phase_ends_at = NOW() + INTERVAL 5 SECOND`。

| 时刻 | 事件 | 实测证据 |
|---|---|---|
| 19:40:22 | **警告推送** | `phone_notifications` id=**81**「产业周期 #1 即将结算」`app_id=industry`；`warning_announced_at` 落库 |
| 19:40:22 | 警告公告 | `phone_cityfeed` id=**24**（推送没把 CityFeed 吞掉） |
| 19:41:22 | **结算** | `industry_cycle_results` cycle 1：`mining_co` revenue **$11,650**、`cartel` 0；`settled_cycle_no=1` |
| 19:41:22 | **结果推送** | `phone_notifications` id=**82**「产业周期 #1 已结算：榜首 mining_co，累计销售额 $11650，威望 +0」 |
| 19:41:22 | 结果公告 | `phone_cityfeed` id=**25** |
| 19:41:22 | 周期推进 | `cycle_no` 1 → **2**，phase 回 `expansion` |

**幂等**：整轮只有一条警告 + 一条结果，无重复推送。
**客户端**：手机上两条通知可见，**点结果通知直达产业面板**（用户实测确认）。
**阶段顺序**（读代码时我按旧的 10/10/5/3/2 猜错过）：实测是
`expansion → competition → maturity → recession`。

### 3.1 结算把产业层清空了（设计行为，不是 bug）

```
org_ledger:        mining_co -59,825 → 0   reason=settlement-clear
                   cartel      -500 → 0   reason=settlement-clear
industry_facility: 空（工位 / 库存 / 产出归零）
```

驱动周期前已 dump 6 张产业表 + `org_ledger` 到容器 `/tmp/industry_snapshot.sql`，可回滚。

## 4. 没做的

| 项 | 为什么 |
|---|---|
| 待机推送 / 每日摘要 | 设计里没有，玩家上线靠 CityFeed 补齐 |
| 离线推送（离线成员上线后补推） | **伪造推送**比不推更糟：玩家会收到一条"已经过期"的警告 |
| 推送点击埋点 | 属于遥测，本片不加（宪法第 7 条：诊断不回包、不落 PII） |

## 5. 文件清单

| 文件 | 变化 |
|---|---|
| `T-CityLite.base/resources/[custom]/custom-industry/server/announce.lua` | `PushToMembers` / `pushSafely` / `playerOrgId` |
| `T-CityLite.base/resources/[custom]/custom-phone/server/core/notify.lua` | `NOTIFY_APP_IDS` 放行 `industry` |
| `T-CityLite.base/tests/unit/layer3_business/test_industry_push.py` | 9 条用例（含 2 条我补的） |

## 6. 回滚

单个资源重启即可：`restart custom-industry`。数据面无迁移 —— 通知写既有
`phone_notifications`，公告写既有 `phone_cityfeed`。
