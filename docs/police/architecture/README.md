# 警察系统架构基线

> 基线：**基线快照 `master @ 568acd2`，当前复评 HEAD `3bbcab3`**（2026-10-24）。这是 **as-built（现状）** 基线，不是目标态；各文档保留基线快照，并用 `post-baseline` 小节记录之后落地的行为。
> 目标态见 [../DESIGN.md](../DESIGN.md)；已知债见 [../TECH_DEBT.md](../TECH_DEBT.md)。

## 文档地图

| # | 文档 | 回答的问题 |
|---|---|---|
| 00 | [overview](00-overview.md) | 系统由什么组成、信任边界、请求怎么流动 |
| 01 | [domain-model](01-domain-model.md) | 限界上下文、聚合、不变量、统一语言 |
| 02 | [state-machines](02-state-machines.md) | 8 个关键对象（SM-01..07 + SM-09 NPC 警情）的状态、迁移、失败回退 |
| 03 | [contracts](03-contracts.md) | 56 export / 27 事件 / 17 query / 17 MDT action / 21 director action 的契约面 |
| 04 | [data-ownership](04-data-ownership.md) | 13 张 `police_*` + `justice_sentences` 谁写谁读、单一事实源、一致性等级 |
| 05 | [nfr](05-nfr.md) | 48 人、NPC 预算、延迟、可靠性、安全、可观测 |
| 06 | [adr](06-adr/) | 关键决策记录（为什么这样选） |
| 07 | [fitness-tests](07-fitness-tests.md) | 13 条架构约束的自动检查与评分卡（当前 27/100） |
| 08 | [scenarios](08-scenarios.md) | 6 条端到端场景走查（含失败、权限、NPC 警情） |

### ADR 索引

| ADR | 决策 | 状态 | 一句话 |
|---|---|---|---|
| [0001](06-adr/0001-duty-state.md) | 值班/勤务状态收敛为单一状态机 | **Accepted（已实施 `bb64d87`）** | `police_units.status` 为状态、`job.onduty` 降为投影；API 见 02 §1.4，现状见 02 §1.6 |
| [0002](06-adr/0002-justice-persistence.md) | justice 案件与判决持久化 | Proposed（未实施；`justice_sentences` 已先行） | 新增 `justice_cases`/`justice_verdicts`；`justice_case_id` 是展示号，服刑计时归 ADR-0007 |
| [0003](06-adr/0003-npc-authority.md) | NPC 支援：服务端权威 + 客户端 AI | Accepted（已实现 MVP） | 全局 cap ≤6、每人 ≤2，超限 `global_limit`；客户端只负责生成与清理 |
| [0004](06-adr/0004-phoneapps-boundary.md) | 职业 App 走 PhoneApps 注册表 | Accepted（已实现） | 注册表只管磁贴，权限/审计仍在 `custom-police` 服务端复检 |
| [0005](06-adr/0005-audit-fail-closed.md) | 敏感读审计 fail-closed | Proposed | 范围是 3 个导出；其余读未全部 fail-closed，tracking=FIT-05 |
| [0006](06-adr/0006-contract-errors.md) | 跨资源契约统一错误码与版本 | **Partially accepted**（`f690230`：arrest/report 结构化 + 幂等键） | `{ok,error,detail}` + `perm./input./state./deps.` 分层 + 幂等键 |
| [0007](06-adr/0007-custody-server-timing.md) | custody 服务端计时 | **Accepted（已实施 `2ae3da4`）** | `justice_sentences.ends_at` 为唯一时钟；qb-prison 降为表现层，`SetJailStatus` 只投影 |
| [0008](06-adr/0008-npc-callout.md) | NPC 警情：服务端调度 + 客户端场景 | Accepted（MVP `a52d2ca`/`3bbcab3`） | 服务端 8min/30%/max1、固定模板坐标、关闭复用 SM-02；客户端只建场景/上报 |

## 怎么用

1. **新增玩法前**：先回答 02（状态机）与 04（数据归属），再写 03（契约），最后才写代码。
2. **设计评审**：按 08 的 6 条场景逐条走，失败场景必须给回退。
3. **每个关键取舍**：写一页 ADR，不写“口头决定”。
4. **CI**：把 07 中标记为 blocking 的规则实现为 Python 检查，禁止架构退化。

## 基线结论（先看这五条；post-baseline 状态见下）

1. `custom-police` 是唯一执法写入口；`custom-justice` 只应负责量刑，`qb-prison` 只应负责刑期执行。
2. 当前最大架构风险是**双状态**（`job.onduty` vs `police_units.status`）与**内存判决**（justice `activeCases`）。
3. 契约面大且不统一：17 个 MDT action 里只有 2 个透传错误码（`report_submit`/`request_backup`），14 个压平（13 个 `ok and res ~= false` + `arrest_submit`），`alert` 为特例（成功 `{sent}`、失败压平）；export 层只有 4 个契约有结构化错误码。
4. 数据所有权总体清晰（12 张 `police_*` 表），但 `phone_notifications` 有 6 个写者、`players.*` 有 7 个资源直写。
5. 安全与取证类 fitness test 当前 5 条中 4 条 FAIL；这是下一步最该补的自动化。

**post-baseline（`3bbcab3`）复核**：

1. 写入口边界不变；custody 的权威已从 qb-prison 客户端迁到 `justice_sentences`（`2ae3da4`）。
2. 最大风险从“双状态 + 内存判决”变为“**仍无事务** + **justice 案件仍内存** + **backup 无 TTL**”；duty 双源已由 `bb64d87` 收敛。
3. 契约面扩大（46→56 export、22→27 事件），错误码仍不统一：arrest/report 已结构化，14/17 MDT action 仍压平。
4. 数据所有权新增 2 张表（`police_write_intents`、`justice_sentences`）；`phone_notifications` 写者从 5 处增到 6 处。
5. fitness 评分从 **21/100 → 27/100**：duty 投影、incident 关闭/幂等、custody 服务端计时、迁移覆盖带来加分；同时 FIT-07 因 NPC 警情绕过 backup 实体预算降为 PARTIAL。HEAD 上扫描器仍未落地。


## 基线校正（以代码为准）

- **agent 风险等级**：DESIGN/B_PLAN 写“建警情 L2”，代码是 `police_incident_create` **L1 自动执行**（`custom-director/server/policy.lua`）；派单 L2、入狱 L3。安全评审以代码为准。
- **`police_arrests` 未完全停写**：新 `ArrestSubmit` 只写 `police_reports(kind='arrest')`，但 agent `Sys.Jail` 与 legacy `RegisterArrest` 仍写 `police_arrests`；`GetArrests` 只读 reports，legacy 行仅在案件详情 UNION 可见。
- **敏感读 fail-closed**：3 个导出（lookup.citizen / lookup.vehicle / GetCaseDetail），不是 2 个；9 个读导出写审计（3 个即上述 fail-closed、6 个忽略返回值），5 个完全不写（GetUnits/GetIncidents/GetAudit/GetCitations/GetReports）。
- **契约面口径（基线）**：46 export = 37 police 服务端 + 2 justice + 6 director + 1 client；若把 `custom-director/server/director.lua` 另 3 个 export 也算上则为 49。跨资源事件 22（13 入站 + 9 出站）。**post-baseline**：56 = 42 + 7 + 6 + 1（含 director.lua 则 59），事件 27（15 入站 + 12 出站）。
- **数据所有权**：00 的所有权矩阵是“一句话级”，与 04 冲突时**以 04-data-ownership.md 为准**。
- **`police_units.dept`** 目前无写入点；MDT 单位恒显示 PATROL。
- **`police_warrants`** 只有 citizenid/reason/status，没有搜查令地址/范围字段。
- **`police_*` 无 `idem_key`（基线）**：**post-baseline** 已有 `police_write_intents.idem_key` 应用层账本（ArrestSubmit/ReportSubmit 接受 `idempotency_key`），但业务表仍无幂等列。


## 施工进度（post-baseline）

基线冻结于 `568acd2`。之后按 SM 顺序落地，**当前 HEAD `3bbcab3`**：

| 提交 | 内容 | 影响文档 |
|---|---|---|
| `bb64d87` | **SM-01 duty/unit 收敛**：10-8/10-7 经 `SetJobDuty` 投影；OnJobUpdate 保留任务态；掉线释放并回开警情；启动 sweep；grade1 自派；`cleared→closed`；MDT 下班可见 | 02 §1.6、04 §2.3、05 REL-01/04、07 FIT-01/11、08 §1.7/§5.5 |
| `2ae3da4` | **SM-05 server-authoritative custody**：v3.8 `justice_sentences`；`ends_at` 为唯一时钟；15s sweep；trial `replace` | 02 §5.6、03 §2.5/§2.8、04 §2.3/§5、05 REL-05/COMPAT-03、08 §2.7 |
| `f690230` | **SM-03 idempotent arrest/report + payment**：v3.9 `police_write_intents`；`idempotency_key`；`open_case` cap；citation/evidence 审计；支付抢占；qb-prison work/release 防刷 | 02 §3.6、03 §2.3/§2.8、04 §5、05 REL-05/SEC-04、07 FIT-04、08 §2.7 |
| `5c2d3ca` + `9481074` | **SM-02 incident lifecycle**：transition 表、disposition、45min stale sweep、`GetIncidents` 排除 closed、派单幂等 | 02 §2.6、03 §2.1.1、04 §3.1、05 SCALE-02、07 FIT-11、08 §1.7 |
| `a52d2ca` + `3bbcab3` | **NPC callouts（SM-09）**：v3.11 `npc_template`；4 模板/固定坐标；8min/30%/max1；客户端 300m/60s/End 清理 | 02 §8、03 §2.8/§3.4、04 §2.3/§3.1、05 SCALE-03、07 FIT-07、08 §6 |
| `46f2225` + `568acd2` | NPC backup MVP（本基线已收录） | 02 §6、03 §2.3、08 §3 |
| `27c2619` | `justice_case_id` + v3.7 `justice_verdict`（基线已收录，仅补投影） | 04 §3.1、03 §2.5 |

**仍未实施（HEAD `3bbcab3`）**：SM-04 案件持久化（ADR-0002）、SM-06 服务端 TTL/状态机、SM-07 `Sys.Jail` 补偿。**post-baseline `3e720bf` 已落地 FIT-03/FIT-05 扫描器与修复**，FIT-09 仍待做。

> **post-baseline `3e720bf`**：FIT-03/FIT-05 已提交并接入 CI；07 的 FIT-03/FIT-05 已转 PASS。

下一次重新基线的触发条件建议：SM-04 落地或上述修复进 CI。

