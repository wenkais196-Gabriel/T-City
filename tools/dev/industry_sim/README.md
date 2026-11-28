# 产业仿真

> 一周一个四季、季度软重置的**参数实验台**。数值来自
> `T-CityLite.base/resources/[custom]/custom-industry/config/*.lua`；
> 决策是脚本策略。它证明算术与配置形状，**不证明玩家行为、留存或全服通胀**。

| 文件 | 干什么 | 怎么跑 |
|---|---|---|
| `run_sim.py` | **验收依据**：复用 `industry_harness` 的假 DB，驱动真实 Lua 跑 N 周，输出 JSONL + 基线比对 | `python run_sim.py --weeks 13 --policy steady --out /tmp/a.jsonl` |
| `sim_seasons.py` | 参数扫描（Python **复刻**规则，只用于先看形状） | `python sim_seasons.py` |
| `build_report.py` | 用 `sim_seasons.py` 现算并生成 `report.html` | `python build_report.py` |
| `demo.html` | 可点的交互 demo（一周四季 + 升级 + 提现 + 季度结算） | 浏览器直接打开 |
| `report.html` | 参数报告页（四张表 + 推荐值 + 边界说明） | 浏览器直接打开 |

口径与结论见 `docs/plan/industry-ops/10-plan.md`。

---

## 真实 Lua 仿真器（P4 #412）

`run_sim.py` 和 `sim_seasons.py` 的分工是**刻意的**：

| | `run_sim.py` | `sim_seasons.py` |
|---|---|---|
| 规则来源 | 真实 `custom-industry/server/*.lua` | Python 里再写一遍公式 |
| 用途 | 验收、基线、改配置后的回归 | 快速扫参数、先看形状 |
| 会不会漂移 | 不会：公式只有线上那一份 | **会**：线上改了它不知道 |
| CI | `tests/unit/layer3_business/test_industry_sim.py` | 不跑 |

所以：**任何"参数能不能定"的结论以 `run_sim.py` 为准；`sim_seasons.py` 只作参考。**

### 它怎么驱动真实 Lua

装配链来自 `T-CityLite.base/tests/unit/layer3_business/industry_harness.py`
（`sim_script` / `run_sim_script`，P4 新增的辅助函数；既有 helper 行为不变）：

```
industry_probe_common.lua（假 DB 语义）
  → industry_cycle_probe.lua（假 MySQL）
  → run_sim.py 的 SIM_DB_GLUE（只补 SQL 形状：两时钟 industry_state / 设施 rich 读 /
    提现周额度流水 / 季度 DELETE）
  → core-framework/server/db.lua
  → config*.lua → server/*.lua（treasury / audit / access / announce / cycle /
    settlement / facility / production / sale / commands）
  → 仿真 driver
```

driver 只做三件事：注入时间（`now` 显式传入，业务时钟不用 `os.time()`）、把策略压成
`decide(ctx)`、把读数转成 JSONL。价格、产量、配额、税、季度结算全部由真实 Lua 计算。

### 策略

唯一接口：

```lua
decide(ctx) -> { build = 0..n, sell = int, upgrade_stock = boolean }
```

| 策略 | 行为 |
|---|---|
| `idle` | 什么都不做（不建厂、不卖、不提库存） |
| `steady` | 保持工位；能卖就卖 |
| `max` | 有钱就建工位；能卖就卖 |
| `hoard` | 只在售价倍率 ≥ 1.2 时卖（即冬季）；钱优先升库存，其次建工位 |

仿真启动时 `idle` 以外的策略会先建一座设施 + 1 个工位（初始金库 $200,000）；
之后每一步能不能做成仍由真实 Lua 裁决（余额、工位上限、配额 50%、阶段可购置性）。

### 输出

JSONL 每周一行 + 末尾 summary 一行：

```json
{"kind":"week","week":1,"quarter":1,"season":"winter","workstations":1,
 "stock":0,"stock_cap":540,"quota_used":24,"revenue":32760,"treasury":107760,
 "prestige":0,"withdrawals":25000,"tax_burned":5000}
```

| 字段 | 口径 |
|---|---|
| `season` | 该周最后一个季节（每周固定以冬季收尾） |
| `quota_used` | 该周最后一个季节的 `industry_demand.quota_used`（全服） |
| `revenue` / `withdrawals` / `tax_burned` | **本**周卖单收入 / 顶格提现总额 / 销毁税 |
| `treasury` / `prestige` | 周末组织金库余额 / 永久威望 |

summary 里的 `quarter_revenue` 来自 `SettleQuarter` 的结果行（本季卖单流水合计），
`workstations` / `stock_level` 是**结算前**的设施行快照。

### 基线比对（CI 报警）

```bash
python tools/dev/industry_sim/run_sim.py --weeks 13 --policy steady --out /tmp/a.jsonl \
  --baseline T-CityLite.base/tests/architecture/industry_sim_baseline.json
```

- 通过：`BASELINE OK`，退出码 0；
- `quarter_revenue` / `workstations` / `stock_level` 相对基线偏离超过 ±10%：
  打印 `BASELINE MISMATCH` 与逐项差异，退出码 2。

基线文件 `T-CityLite.base/tests/architecture/industry_sim_baseline.json` 由
`--write-baseline` 用 `steady` 生成，`_comment` 写明生成方式与口径；文件名不带版本号。

**服务端权威自证**：`--sale-price 60` 会通过 convar 把 `industry_sale_price` 从 50
改成 60。若价格真的来自服务端配置，季度收入应 +20%，基线比对必须报错：

```bash
python tools/dev/industry_sim/run_sim.py --weeks 13 --policy steady --out /tmp/x.jsonl \
  --sale-price 60 --baseline T-CityLite.base/tests/architecture/industry_sim_baseline.json
# BASELINE MISMATCH: quarter_revenue: ... 偏离 +20.0%（阈值 ±10%）
# 退出码 2
```

### 确定性

- 起点固定为 2024-01-01（周一）本地零点，按 3600 秒步进；
- 所有 ref 由仿真器生成，不用 `os.time()` 当业务时钟；
- 输出不含 epoch / 随机数 / 字典无序遍历结果。

同参数两次跑，JSONL **逐字节一致**（测试里同时断言 sha256）。

### 不模拟什么

- 多组织抢单时序（下一片）；
- 玩家在线时长 / NPC 工位卡人；
- 结算时的在线成员分配（`GetQBPlayers` 返回空；每周提现走真实的
  `orgfundwithdraw` 命令路径，税仍照常销毁）。

### 旧警告已失效

早期 README 写着「`industry_sales` 没有 `phase` 列，跨阶段卖单会被拒」。该 bug 已由
#408（配额按阶段独立）与 #409（`season` 维度接线）修复；当前基线建立在修复后的规则上。
