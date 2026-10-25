# CONSTITUTION — T-City 的十条不变量

> 这份文件只写**不可协商**的东西。每条都能推出「违反 = 打回」，并且都有一个可执行的落点。
> 想改这一页 = 一次显式的架构决策（PR 描述里必须写"为什么旧条款不成立"）。
> 其他所有约束（风格、目录、命名）都不属于宪法，见 `AGENTS.md` 与分区文件。

**为什么只有十条**：约束越多，被执行的比例越低。这里只放"违反之后系统会坏掉"的条款；
其余全部下沉成 L1 架构文档、L4 技能与 L5 闸门。

| # | 条款 | 违反的表现 | 落点（可执行） |
|---|---|---|---|
| 1 | **服务端权威**：客户端传来的任何数据都要在服务端复验；NUI 里看不见 ≠ 没有权限 | 前端隐藏按钮当成权限校验 | `tests/architecture/test_net_event_auth.py` |
| 2 | **写路径唯一**：钱 / 物品只走 `Player.Functions.*`、`core_economy:TriggerReward`，禁止直接 SQL 改账 | 出现 `UPDATE player_... SET money` | `test_query_discipline.py` + `test_state_writers.py` |
| 3 | **SQL 必须参数化**：列白名单、`LIMIT`、禁止 `SELECT *` 全表拉取 | 拼接 SQL、`SELECT *` | `test_query_discipline.py` |
| 4 | **每个 net event 要么鉴权，要么登记为 `diagnostic`**，并给出投影 / 限流 / 预算 | 新增事件直接 `RegisterNetEvent` | `test_net_event_auth.py` + `net_events_allowlist.json` |
| 5 | **幂等**：动作可重试、迁移可重复执行、回调可重放 | 重连/重试后状态翻倍 | 迁移必须 `information_schema` 判断；动作测试 |
| 6 | **表有唯一 owner**：跨资源写别人的表必须走 owner 资源 | 两个资源同时写 `player_vehicles` | `test_cross_resource_writes.py` + `table_owners.json` |
| 7 | **诊断 / 遥测通道永不回包、永不落 PII** | diag 事件把 payload 打出来 | `test_nui_baseline.py::test_diag_projection_carries_no_business_payload` |
| 8 | **一次改动只动一个平面**；跨平面必须显式声明契约变化（事件名 / 字段 / 错误码） | 前后端字段悄悄改名 | `test_plane_boundaries.py` + PR 模板 |
| 9 | **没有测试的修复不算完成**：先红后绿，测试必须能在离线环境跑 | "我本地试过了" | CI（`pytest tests/unit tests/architecture`） |
| 10 | **交付三件套**：代码 + 文档 + `CHANGELOG.md`；push 前密钥扫描 | 功能上线、文档还是旧的 | `tools/dev/release_check.py` |

## 使用方式

- **开发前**：只需要记住第 1 条（服务端权威）和第 8 条（一次一个平面），其余由 L1 的依赖矩阵兜住。
- **审查时**：逐条对照，命中的必须给出"落点"里那个测试的输出。
- **加新条款**的门槛：同一类错误**重复发生两次以上**，且无法用 L1/L4/L5 表达，才升进宪法。否则写进分区 `AGENTS.md`。

## 与 L5 闸门的关系

宪法条款必须**能被机器验证**，否则它只是口号。上表第 4 列是当前落点；新增条款时，
同一批改动里必须包含对应闸门（或明确写出"为什么这条暂时无法自动验证，由谁在什么时候人工核对"）。

逆向要求同样成立：**闸门里拦下的规则，如果背后没有一条宪法/架构依据，就该删掉**——
没有依据的风格检查会让人把闸门当成噪音，最后连真问题一起忽略。
