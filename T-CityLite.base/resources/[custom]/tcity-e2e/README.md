# tcity-e2e — Scenario DSL 服务端端到端测试（无客户端）

用 JSON 场景驱动多个 fake player，在真实 FXServer 上跑通：

1. 创建测试角色（直接写 `players` 表 + `QBCore.Player.CreatePlayer`）
2. 经济：加钱 → 落库
3. 任务：`TriggerQuest`（验证 `required_tags` / `story_arc` 门控）→ 逐步推进
4. 剧情：`MakeChoice` 服务端提交
5. 奖励：只发一次；重复决策/完成不再发奖
6. 清理测试角色与任务/决策/冷却/背包数据
7. 输出 JSON 报告（通过/失败、CID 映射、步骤日志）

生产环境不受影响：只有 `setr tcity_e2e 1` 时才会执行。

## 快速运行

```cfg
# server.cfg（仅测试环境）
setr tcity_e2e 1
setr tcity_e2e_scenario civilian_ch1   # 可选，默认 civilian_ch1
ensure tcity-e2e
```

启动后看 console：

```
[E2E] PASS | scenario.load | civilian_ch1 seed=42 players=2 steps=13
[E2E] PASS | quest.trigger | cid=SIM001 step=accept Quest accepted: ...
...
[E2E] PASS | quest.duplicate_complete_no_reward | cid=SIM001 ... delta=0
[E2E] PASS | cleanup.SIM001 | cid=SIM001_... residue=0
[E2E] DONE | pass=N fail=M
```

报告写入 `reports/agent-sim-<YYYYMMDD-HHMMSS>.json`。如果运行目录不可写，会打印
`[E2E] report inline | {...}`，不会中断测试。

跑完把 `setr` 两行移除（或 `setr tcity_e2e 0` 后重启资源）。

## Scenario DSL

场景文件位于 `config/scenarios/<name>.json`，通过 convar
`tcity_e2e_scenario` 选择（不带 `.json` 后缀）。根对象：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `schema_version` | 是 | 当前只支持 `1` |
| `seed` | 是 | `math.randomseed`，同时写入报告 |
| `players` | 是 | 非空数组，最多 100 个（source 池 9001–9100） |
| `steps` | 是 | 非空数组，**严格按数组顺序执行**（没有 `at` 时间轴） |
| `assert` | 是 | 非空数组，见下 |
| `name` | 否 | 报告中的场景名，默认使用文件名 |
| `ordering` | 否 | 只允许 `"sequential"`，用于显式声明有序语义 |
| `description` | 否 | 备注 |

### players（persona）

```json
{
  "cid": "SIM001",
  "source": 9001,
  "job": "unemployed",
  "gang": "none",
  "grade": 0,
  "money": { "cash": 1000, "bank": 10000, "crypto": 0 },
  "charinfo": { "firstname": "Sim", "lastname": "One", "birthdate": "1990-01-01", "gender": 0, "nationality": "US" }
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `cid` | 是 | 逻辑 ID，必须以 `SIM` 开头且唯一；最长 6 字符（live DB `players.citizenid` 是 `VARCHAR(11)`） |
| `source` | 否 | 缺省按数组下标分配 `9001, 9002, ...`；显式值必须在 9001–9100 且唯一 |
| `job` | 是 | 必须是 `QBCore.Shared.Jobs` 中存在的 job |
| `gang` | 否 | 默认 `none`，必须是 `QBCore.Shared.Gangs` 中存在的 gang |
| `grade` | 否 | 默认 0，非负整数 |
| `money` | 否 | 与 QBCore 默认货币合并；覆盖 `cash`/`bank`/`crypto` 等 |
| `charinfo` | 否 | 覆盖默认姓名/生日等字段 |

**运行期 CID 隔离**：`cid` 是 persona 模板，实际写入 DB 的 citizenid 是
`<cid>_<4位十六进制 runId>`（例如 `SIM001_ab12`，正好 11 字符）。live DB 的
`players.citizenid` 是 `VARCHAR(11)`，所以 persona `cid` 限制为最多 6 字符。
报告 `cid_map` 里有映射。原因有两个：

- story-engine 的剧情线完成标记在资源内存里缓存，固定 CID 在同一 server
  生命周期内第二次运行会被一次性门控拒绝；
- 避免上一次失败运行的 DB 残留（`players` / `player_quests` / `player_choices`）
  串到下一次。

所有测试角色 metadata 都带 `synthetic = true` 和 `e2e_scenario`。

### steps

每个 step 都必须有 `action`；`id` 可选（缺省 `step_<序号>`），`id` 也是断言
checkpoint 的名字。除 `wait` 外都必须有 `cid`。

| action | 额外字段 | 行为 |
| --- | --- | --- |
| `accept_quest` | `quest` | 调 `custom-quest:TriggerQuest`，并检查 DB 中任务为 `in_progress` |
| `complete_step` | `quest`, `step` | 调 `custom-quest:CompleteStep` |
| `make_choice` | `quest`, `step`, `decision`, `option` | 调 `story-engine:MakeChoice` |
| `add_money` | `amount`, `account`（默认 bank）, `reason` | 给指定 persona 加钱并检查 DB 落库 |
| `wait` | `ms`（默认 500） | 等待，用于让异步 DB/奖励结算完成 |

可选字段：

- `wait`：该 step 执行后的额外等待毫秒数（`complete_step` 默认 300，
  `make_choice` 默认 800，`accept_quest` 默认 500）。
- `expect_fail`：为 `true` 时，`make_choice` 必须失败；用于
  “重复决策被拒绝”的幂等检查。

### assert

断言默认在所有 step 之后按数组顺序执行。带 `after: "<step id>"` 的断言会在
对应 step 完成后立即执行（适合检查 `current_step` 等中间状态）。

| type | 字段 | 说明 |
| --- | --- | --- |
| `db` / `db_scalar` | `sql`, `params`, `expect`, `cid` 可选 | 查询单个标量。SQL 必须以 `SELECT` 开头；若给了 `cid`，运行期 CID 会自动作为**第一个** `?` 参数，`params` 依次追加 |
| `quest_status` | `cid`, `quest`, `expect`, `completion_count` 可选 | 查最新一条 `player_quests` 的 status；可选同时校验完成次数 |
| `choice_count` | `cid`, `expect`, `decision` 可选 | 统计 `player_choices` 行数 |
| `money_delta` | `cid`, `account`, `since`, `min`, `max` | 当前 DB 金额 − checkpoint 金额，闭区间判断 |
| `no_change` | `cid`, `account`, `since` | 当前 DB 金额必须等于 checkpoint 金额（用于重复操作不再发奖） |
| `event` | `event`, `expect` 可选, `cid`/`quest` 可选 | 可选的事件断言；在本场景运行期间监听该事件，`expect: false` 表示断言未发生 |

公共可选字段：

- `name`：console/report 中的检查名（建议保留旧检查名，如
  `quest.reward_granted_once`）。
- `after`：在该 step id 完成后立即执行。
- `cid`：逻辑 persona CID，runner 自动映射到运行期 CID。

Checkpoint 规则：runner 启动时记录 `setup`，并在被断言 `since` 引用的 step
执行后强制保存并记录该 step id 的金额快照。

### 语法示例（可直接运行）

```json
{
  "schema_version": 1,
  "name": "smoke",
  "ordering": "sequential",
  "seed": 42,
  "players": [
    { "cid": "SIM001", "job": "unemployed", "gang": "none",
      "money": { "cash": 1000, "bank": 10000 } },
    { "cid": "SIM002", "job": "unemployed", "gang": "none",
      "money": { "cash": 250, "bank": 5000 } }
  ],
  "steps": [
    { "id": "accept", "action": "accept_quest", "cid": "SIM001",
      "quest": "civilian_ch1_first_dollar" },
    { "id": "accepted", "action": "wait", "ms": 700 },
    { "id": "add_bank", "action": "add_money", "cid": "SIM002",
      "account": "bank", "amount": 250 }
  ],
  "assert": [
    { "name": "quest.db_in_progress", "type": "quest_status", "cid": "SIM001",
      "quest": "civilian_ch1_first_dollar", "expect": "in_progress" },
    { "name": "economy.add_money_persisted", "type": "money_delta", "cid": "SIM002",
      "account": "bank", "since": "setup", "min": 250, "max": 250 }
  ]
}
```

`config/scenarios/civilian_ch1.json` 是完整可运行示例：两个 unemployed 平民、
不同现金/银行存款、完整任务链、`honest_citizen` 决策、重复决策/重复推进、
奖励幂等、DB 完成次数/抉择次数和清理检查。

## 保留的检查语义

Runner 仍覆盖原 harness 的 21 项检查语义（检查名可能带 persona 后缀）：

- fake player 创建/保存/角色标签（civilian、unemployed、police 拒绝）
- 加钱落库
- 接任务、任务进入 DB、逐步推进到 decision
- 决策成功、`player_choices` 落库
- 任务 completed、`completion_count == 1`
- 奖励金额 300–600 且只发一次
- 重复决策被拒绝、重复完成不再发奖
- 额外增加每个 persona 的清理残留检查

## 清理

测试结束（包括失败/异常）会：

1. 保存并 `QBCore.Player.Logout` 每个 fake player；
2. 按运行期 CID 删除 `players` / `player_quests` / `player_choices` /
   `quest_cooldowns` / `quest_daily_limits` / `inventories`；
3. 尽力删除 `quest_event_log` / `story_completions`，避免下一次运行被一次性门控；
4. 对每个 persona 输出 `cleanup.<cid>` 残留检查。

只操作本次运行生成的合成 CID，不会按 `source` 或通配符删除真实玩家数据。

## 限制

- **无真实客户端**：不测试 NUI、输入、渲染、客户端节点交互；这些仍需真实客户端。
- **fake player 没有真实 inventory**：不加载 qb-inventory 的玩家背包；
  `AddItem` 可能 no-op 或打印 `[quest-rewards] ⚠️ item reward failed`，
  且不影响测试结果。**物品奖励（sandwich 等）不做断言**，也不验证 rep/crypto。
- fake player 不是真实网络客户端：`GetPlayerName` 可能为空，发给该 source 的
  `TriggerClientEvent` 会被丢弃。测试只覆盖服务端/DB 路径。
- 断言 SQL 只允许 `SELECT`；runner 不执行写 SQL 测试（清理除外）。测试库需已执行
  `migrations/v0.7_quest_system.sql`、`v0.7_story_engine.sql`、
  `v0.7.2_schema_reconcile.sql` 等迁移。
- 单次运行最多 100 个 fake player（source 9001–9100）。同一资源实例只应运行一次，
  不要并发 `ensure tcity-e2e`。
- 报告目录不可写时只打印 inline JSON；JSON 报告是运行产物，已在
  `reports/.gitignore` 中忽略。
- 清理依赖表结构：`inventories` 同时兼容 `identifier`（qb-inventory）与
  `citizenid` 两种列名。
- 场景里写死的 quest/decision/step/job/gang ID 必须与当前资源版本一致；
  场景变更不需要改 Lua，但非法 ID 会以明确的 FAIL detail 报出。
