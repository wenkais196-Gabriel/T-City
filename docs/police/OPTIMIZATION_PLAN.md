---
id: police-optimization-plan
type: plan
status: active
system: justice
owner: hermes
updated: 2026-10-24
review_by: 2027-04-30
---

# 优化批次（P6）调研与方案

范围（用户指定五项）：
1. 法庭 `/trial`、`/plea` 实机联调
2. 案件详情显示 justice 案件号与判决
3. legacy `/jail` 下线
4. Wanted 单源
5. 罚单/报告模板

## 调研结论

| 项 | 现状 | 方案 | 风险 |
|---|---|---|---|
| 1 法庭联调 | 命令已实现，缺第二角色；无自动化覆盖 | 先补 Lua/静态契约 + 手动验收脚本；实机等第二名玩家 | 单人无法完成，不阻塞代码 |
| 2 判决持久化 | justice 案件/判决只在内存，关闭即丢；报告有 `justice_case_id` 但无判词 | v3.7 给 reports 加 `justice_verdict TEXT`、`justice_status`；`ResolveCase` 通过 oxmysql 回写；案件详情显示 | justice 需引入 `@oxmysql/lib/MySQL.lua`；失败只告警，不影响判决 |
| 3 legacy `/jail` | 客户端 `/jail` → qb-input → 服务端事件；可绕过新逮捕流程 | 删除客户端命令与 `police:client:JailPlayer`；服务端事件保留但只接受 `source=0` 或直接删除；`/unjail` 保留 | 旧玩家习惯；文档标注 |
| 4 Wanted 单源 | `police_warrants`（搜查令/通缉）、`police_reports.is_bolo`、`metadata.wanted`（custom-main 5 星在逃）三套 | 明确语义：warrant=长期令状，BOLO=报告标签，active_wanted=实时星级；Person 查询分字段返回并标注来源，不再混用 `wants` | 不能删 custom-main 的实时系统；只统一展示与命名 |
| 5 模板 | 报告/罚单全手填 | MDT 内置模板（常见罪名组合/报告开头/罚单原因），选择即填充，仍可编辑 | 纯 UI，无后端风险 |

## 实施顺序

1. v3.7 判决持久化 + case detail（后端 + UI）
2. legacy `/jail` 下线（客户端/命令/事件）
3. Wanted 分源展示（p0 lookup + Person UI）
4. 报告/罚单模板（纯 UI）
5. 法庭联调：Lua/静态测试 + 手动脚本，实机待第二角色

## 验收

- 案件详情显示 `justice_case_id` + 判词/刑期/罚款
- `/jail` 客户端命令不存在；新流程仍可用
- Person 查询分开显示 warrant/BOLO/active wanted
- 模板一键填充，提交仍走服务端校验
- `tests/unit` + `tests/tools` 全绿
