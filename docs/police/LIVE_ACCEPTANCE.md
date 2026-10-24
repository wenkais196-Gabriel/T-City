# 警察系统进服验收清单

> 测试角色：`IYY39878`（police / grade 4 / onduty）。测试库状态已清空：无 open incident、无 active sentence、无未付罚单、无令状。

## A. 值班（SM-01 / FIT-01）

| # | 操作 | 期望 | DB |
|---|---|---|---|
| A1 | 手机 MDT → 我的 → 10-7 | 状态变下班；MDT 仍可见 | `police_units.status=off_duty`, `job.onduty=false` |
| A2 | 再点 10-8 | 状态回在勤 | `status=available`, `onduty=true` |
| A3 | `/duty` | 与 MDT 同步切换；非警察职业不受影响 | 同上 |
| A4 | 通缉状态尝试上班 | 被强制下班 | `onduty=false` |

## B. 警情（SM-02）

| # | 操作 | 期望 |
|---|---|---|
| B1 | `/911 测试警情` | 在勤警察收到通知；MDT 调度出现警情 |
| B2 | MDT 派单给自己 → 前往 → 到场 | 状态 `assigned→enroute→on_scene` |
| B3 | 清场 | 警情从队列消失；`status=closed`, `disposition=cleared` |
| B4 | 45 分钟无活动 | stale sweep 关闭，`disposition=stale` |

## C. NPC 支援（FIT-07）

| # | 操作 | 期望 |
|---|---|---|
| C1 | MDT 调度 → 请求支援 | 约 1 车 2 NPC，蓝色 blip，到场跟随 |
| C2 | 60 秒内再请求 | 提示冷却 |
| C3 | 同时请求第 3 个 | 提示上限（每人 2 slots） |
| C4 | 离开 150m / 5 分钟 | NPC 清理，名额释放 |

## D. NPC 警情

| # | 操作 | 期望 |
|---|---|---|
| D1 | 控制台 `npc_callout store_robbery` | MDT 出现带 `NPC` 标签的 211 |
| D2 | 到场 | 2 名持枪嫌疑人 + 店员 |
| D3 | 控制现场按 E | 警情关闭、奖励 $500、审计 `npc.callout.resolve` |
| D4 | 或 MDT 清场 | 场景清理，预算释放 |

## E. 逮捕 / 罚单 / 报告（SM-03）

| # | 操作 | 期望 |
|---|---|---|
| E1 | 上铐目标 → MDT 逮捕 → 选罪名 → 提交 | 生成 1 份 report；可选罚单/证据/案件 |
| E2 | 快速双击提交 | 只生成 1 份；第二次返回同一 report_id |
| E3 | 勾选「同时开庭」 | 返回 `justice_case_id`，写入 `police_reports.justice_case_id` |
| E4 | 罚单 → Banking 支付 | 只扣一次；重复支付提示已支付 |
| E5 | 报告 + 证据 + BOLO | 报告生成；证据有保管链；BOLO 出现在案件页 |

## F. 法庭 / 监狱（SM-05）

| # | 操作 | 期望 |
|---|---|---|
| F1 | 先入狱 2 分钟 | `justice_sentences` active，`ends_at=now+2m` |
| F2 | `/plea CASE-xxxx`（无法官，grade≥2） | 剩余刑期被覆盖为判决值（不是追加） |
| F3 | 监狱电工工作 | 服务端 `ends_at` 减 2 分钟，60s 冷却 |
| F4 | 刑满 | sweep 自动释放，`status=expired`，出狱 |
| F5 | `/unjail <id>` | DB sentence 变 `released`，不是只传送 |

## G. 安全 / 审计

| # | 操作 | 期望 |
|---|---|---|
| G1 | 平民尝试 RobPlayer / 清证据 | 被拒 |
| G2 | 连续 `/911` | 5 秒限流 |
| G3 | 查询人员/案件/罚单/报告 | 正常；审计失败时明确拒绝 |
| G4 | `police_outbox` | 通知最终 `done`；失败有退避 |

## 监控命令

```sql
SELECT id,code,status,disposition,npc_template FROM police_incidents ORDER BY id DESC LIMIT 5;
SELECT citizenid,status,incident_id FROM police_units;
SELECT id,citizenid,status,minutes,ends_at FROM justice_sentences ORDER BY id DESC LIMIT 5;
SELECT status,COUNT(*) FROM police_outbox GROUP BY status;
SELECT action,COUNT(*) FROM police_audit WHERE created_at > NOW() - INTERVAL 10 MINUTE GROUP BY action;
```
