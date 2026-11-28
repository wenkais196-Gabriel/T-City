# 产业仿真（demo 级）

> 一周一个四季、季度软重置的**参数实验台**。数值抄自
> `T-CityLite.base/resources/[custom]/custom-industry/config/*.lua`；
> 决策是脚本策略。它证明算术与配置形状，**不证明玩家行为、留存或全服通胀**。

| 文件 | 干什么 | 怎么跑 |
|---|---|---|
| `sim_seasons.py` | 参数扫描：库存步长 / 提现额度×税 / 黑五三维 / 分配比例 | `python sim_seasons.py` |
| `build_report.py` | 用 `sim_v4` 现算并生成 `report.html` | `python build_report.py` |
| `demo.html` | 可点的交互 demo（一周四季 + 升级 + 提现 + 季度结算） | 浏览器直接打开 |
| `report.html` | 参数报告页（四张表 + 推荐值 + 边界说明） | 浏览器直接打开 |

口径与结论见 `docs/plan/industry-ops/10-plan.md`。

⚠️ 这些数字建立在「配额按阶段独立」的**设计口径**上；线上 `industry_sales` 目前没有 `phase` 列，
跨阶段卖单会被 `org_cap_reached` 拒 —— 该 bug 修复前，任何基线都无效。
