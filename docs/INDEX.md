# 文档索引（自动生成，请勿手改）

> 由 `python tools/docs_lifecycle.py --index` 生成。规范：[`standards/doc-lifecycle.md`](standards/doc-lifecycle.md)。

**生成时间**：2026-11-01 ｜ **文档总数**：283 ｜ **已登记**：283 ｜ **未登记**：0

**状态分布**：✅ active 158 ・ 🟡 draft 3 ・ 🔍 review 0 ・ 📌 final 75 ・ ♻️ superseded 3 ・ 📦 archived 44

## 按系统

### economy（6）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [Module 3: 经济系统 (economy.cfg / banking.cfg / security.cfg)](01_module_manuals/03_economy_system.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `docs/01_module_manuals/03_economy_system.md` |
| [core_economy + economy-dashboard — 经济网关与仪表盘](02_script_index/economy-systems.md) | manual | 📦 archived | 2026-06-21 | 2027-01-30 |  | `docs/02_script_index/economy-systems.md` |
| [🏙️ T-City 宏观经济模拟层 — 施工蓝图](../T-CityLite.base/docs/architecture/economic-simulation-blueprint.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/architecture/economic-simulation-blueprint.md` |
| [v0.3 基础设施层](archive/QBCore_Lite_versions/v0.3-economy.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v0.3-economy.md` |
| [v0.6a 民间经济职业生态（Civilian Economy）](archive/QBCore_Lite_versions/v0.6a-civilian-economy.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v0.6a-civilian-economy.md` |
| [06 — 付费模型：Patron + Identity 双轨设计](server-design/06-payment-model.md) | spec | ✅ active | 2026-06-21 | 2027-04-30 |  | `docs/server-design/06-payment-model.md` |

### justice（65）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [ADR-0001 值班/勤务状态收敛为单一状态机](police/architecture/06-adr/0001-duty-state.md) | adr | 📌 final | 2026-10-24 | — |  | `docs/police/architecture/06-adr/0001-duty-state.md` |
| [ADR-0002 justice 案件与判决持久化](police/architecture/06-adr/0002-justice-persistence.md) | adr | 📌 final | 2026-10-24 | — |  | `docs/police/architecture/06-adr/0002-justice-persistence.md` |
| [ADR-0003 NPC 支援：服务端权威 + 客户端 AI](police/architecture/06-adr/0003-npc-authority.md) | adr | 📌 final | 2026-10-24 | — |  | `docs/police/architecture/06-adr/0003-npc-authority.md` |
| [ADR-0004 职业 App 走 PhoneApps 注册表](police/architecture/06-adr/0004-phoneapps-boundary.md) | adr | 📌 final | 2026-10-24 | — |  | `docs/police/architecture/06-adr/0004-phoneapps-boundary.md` |
| [ADR-0005 敏感读审计 fail-closed](police/architecture/06-adr/0005-audit-fail-closed.md) | adr | 📌 final | 2026-10-24 | — |  | `docs/police/architecture/06-adr/0005-audit-fail-closed.md` |
| [ADR-0006 跨资源契约统一错误码与版本](police/architecture/06-adr/0006-contract-errors.md) | adr | 📌 final | 2026-10-24 | — |  | `docs/police/architecture/06-adr/0006-contract-errors.md` |
| [ADR-0007 custody 服务端计时](police/architecture/06-adr/0007-custody-server-timing.md) | adr | 📌 final | 2026-10-24 | — |  | `docs/police/architecture/06-adr/0007-custody-server-timing.md` |
| [ADR-0008 NPC 警情：服务端调度 + 客户端场景](police/architecture/06-adr/0008-npc-callout.md) | adr | 📌 final | 2026-10-24 | — |  | `docs/police/architecture/06-adr/0008-npc-callout.md` |
| [验收记录 — P5（AI 支援）· 2026-10-30](agent/police/ACCEPTANCE-RUN-2026-10-30.md) | audit | 📌 final | 2026-10-31 | — |  | `docs/agent/police/ACCEPTANCE-RUN-2026-10-30.md` |
| [警察 MDT 错误码契约（FIT-04）](police/ARCHITECTURE_ERRORS.md) | audit | 📌 final | 2026-10-24 | — |  | `docs/police/ARCHITECTURE_ERRORS.md` |
| [警察 P0 真实服务端 E2E（`police_e2e`）](police/E2E_TESTING.md) | audit | 📌 final | 2026-10-24 | — |  | `docs/police/E2E_TESTING.md` |
| [警察系统进服验收清单](police/LIVE_ACCEPTANCE.md) | audit | 📌 final | 2026-10-24 | — |  | `docs/police/LIVE_ACCEPTANCE.md` |
| [进服测试问题记录](police/LIVE_TEST_NOTES.md) | audit | 📌 final | 2026-10-24 | — |  | `docs/police/LIVE_TEST_NOTES.md` |
| [T-City 警察能力现状审计（local audit）](police/audit-current.md) | audit | 📌 final | 2026-10-23 | — |  | `docs/police/audit-current.md` |
| [P2 调度总线 · 现状核对（2026-10-31）](police/plans/2026-10-31-p2-dispatch-audit.md) | audit | 📌 final | 2026-10-31 | — |  | `docs/police/plans/2026-10-31-p2-dispatch-audit.md` |
| [P3 盘查与文书 · 现状核对（2026-10-31）](police/plans/2026-10-31-p3-audit.md) | audit | 📌 final | 2026-10-31 | — |  | `docs/police/plans/2026-10-31-p3-audit.md` |
| [P4 证据与 bodycam · 施工方案（2026-10-31）](police/plans/2026-10-31-p4-audit.md) | audit | 📌 final | 2026-10-31 | — |  | `docs/police/plans/2026-10-31-p4-audit.md` |
| [qb-policejob + qb-ambulancejob — 执法与医疗职业](02_script_index/qb-police-ambulance.md) | manual | 📦 archived | 2026-06-21 | 2027-01-30 |  | `docs/02_script_index/qb-police-ambulance.md` |
| [弃用登记（Deprecations）](police/architecture/deprecations.md) | manual | ✅ active | 2026-10-24 | 2027-01-30 |  | `docs/police/architecture/deprecations.md` |
| [警察系统 · 入口与沉淀（2026-10-31）](agent/police/README.md) | meta | ✅ active | 2026-10-31 | 2027-04-30 |  | `docs/agent/police/README.md` |
| [警察扮演（Police Roleplay）](police/README.md) | meta | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/README.md` |
| [警察系统架构基线](police/architecture/README.md) | meta | ✅ active | 2026-10-29 | 2027-04-30 |  | `docs/police/architecture/README.md` |
| [警察系统现状与缺口（2026-10-31）](agent/police/STATUS-2026-10-31.md) | plan | ✅ active | 2026-10-31 | 2027-04-30 |  | `docs/agent/police/STATUS-2026-10-31.md` |
| [👮 T-City Lite 警察职业与司法系统 (LSPD) 细化规划](archive/QBCore_Lite_versions/career/police_plan.md) | plan | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/career/police_plan.md` |
| [方案 B 落地计划（已拍板）](police/B_PLAN.md) | plan | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/B_PLAN.md` |
| [优化批次（P6）调研与方案](police/OPTIMIZATION_PLAN.md) | plan | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/OPTIMIZATION_PLAN.md` |
| [P4 — 警察调度 Agent 工具（实现清单）](police/P4_AGENT.md) | plan | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/P4_AGENT.md` |
| [警察系统实现状态（2026-10-23）](police/STATUS.md) | plan | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/STATUS.md` |
| [警察系统技术债](police/TECH_DEBT.md) | plan | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/TECH_DEBT.md` |
| [计划：支援单位的生成点与到场（spawn v3）](police/plans/2026-10-29-backup-spawn-v3.md) | plan | ✅ active | 2026-10-30 | 2027-04-30 |  | `docs/police/plans/2026-10-29-backup-spawn-v3.md` |
| [计划：SM-06 NPC 支援 v2（生命周期 ack + 统一 TTL + 结束审计）](police/plans/2026-10-29-backup-v2.md) | plan | ✅ active | 2026-10-29 | 2027-04-30 |  | `docs/police/plans/2026-10-29-backup-v2.md` |
| [任务：小地图回原生 + 车载面板诊断（给 Claude Code）](police/plans/2026-10-31-cc-brief-minimap-dashboard.md) | plan | ✅ active | 2026-10-31 | 2027-04-30 |  | `docs/police/plans/2026-10-31-cc-brief-minimap-dashboard.md` |
| [日志清理：两个还在复发的脚本错误（研究 → 计划 → 施工）](police/plans/2026-10-31-log-cleanup.md) | plan | ✅ active | 2026-10-31 | 2027-04-30 |  | `docs/police/plans/2026-10-31-log-cleanup.md` |
| [三个体感问题：小地图 / I 键 / 序章 node（研究 → 计划）](police/plans/2026-10-31-map-key-quest.md) | plan | ✅ active | 2026-10-31 | 2027-04-30 |  | `docs/police/plans/2026-10-31-map-key-quest.md` |
| [P4 证据收口：盘查读数延迟绑定（研究与施工图）](police/plans/2026-10-31-p4-evidence-binding.md) | plan | ✅ active | 2026-10-31 | 2027-04-30 |  | `docs/police/plans/2026-10-31-p4-evidence-binding.md` |
| [P6-4 AI 调度员：文本报案 → call 卡草稿（研究与施工图）](police/plans/2026-10-31-p6-4-ai-dispatcher.md) | plan | ✅ active | 2026-10-31 | 2027-04-30 |  | `docs/police/plans/2026-10-31-p6-4-ai-dispatcher.md` |
| [P6 Agent 动作 · 研究与施工图（2026-10-31）](police/plans/2026-10-31-p6-agent-tools.md) | plan | ✅ active | 2026-10-31 | 2027-04-30 |  | `docs/police/plans/2026-10-31-p6-agent-tools.md` |
| [两个遗留问题：调研 → 方案 → 验证（2026-10-31）](police/plans/2026-10-31-quest-storyengine-and-sonar.md) | plan | ✅ active | 2026-10-31 | 2027-04-30 |  | `docs/police/plans/2026-10-31-quest-storyengine-and-sonar.md` |
| [计划：剧情抉择 UI 重构（decision surface）](police/plans/2026-11-01-decision-ui-refactor.md) | plan | ✅ active | 2026-11-01 | 2027-04-30 |  | `docs/police/plans/2026-11-01-decision-ui-refactor.md` |
| [T-City Lite 警察模块调研：功能清单 + UX 设计](agent/police/RESEARCH-2026-10-ARCHIVED.md) | research | ♻️ superseded | 2026-10-30 | 2027-01-30 |  | `docs/agent/police/RESEARCH-2026-10-ARCHIVED.md` |
| [T-City Lite 警察模块调研 v2](agent/police/RESEARCH-2026-10.md) | research | ✅ active | 2026-10-30 | 2027-01-30 |  | `docs/agent/police/RESEARCH-2026-10.md` |
| [Agent 全面接管服务器与自动化测试调研](police/AGENT_CONTROL_RESEARCH.md) | research | 📌 final | 2026-10-24 | 2027-01-30 |  | `docs/police/AGENT_CONTROL_RESEARCH.md` |
| [警察扮演流程调研（FLOW_RESEARCH）](police/FLOW_RESEARCH.md) | research | 📌 final | 2026-10-24 | 2027-01-30 |  | `docs/police/FLOW_RESEARCH.md` |
| [GTA V 警察模组在 FiveM 服务器上的复现调研](police/GTA_MOD_RESEARCH.md) | research | 📌 final | 2026-10-24 | 2027-01-30 |  | `docs/police/GTA_MOD_RESEARCH.md` |
| [外部警察 / 调度 / MDT / 监狱 / 法庭模组调研](police/research-external.md) | research | 📌 final | 2026-10-23 | 2027-01-30 |  | `docs/police/research-external.md` |
| [警察模块验收标准（ACCEPTANCE）](agent/police/ACCEPTANCE.md) | spec | ✅ active | 2026-10-31 | 2027-04-30 |  | `docs/agent/police/ACCEPTANCE.md` |
| [警察道具层蓝图（Items & Props）](agent/police/BLUEPRINT-ITEMS-ARCHIVED.md) | spec | ♻️ superseded | 2026-11-01 | 2027-04-30 |  | `docs/agent/police/BLUEPRINT-ITEMS-ARCHIVED.md` |
| [警察道具层蓝图（Claude Code 独立版）](agent/police/BLUEPRINT-ITEMS-CC.md) | spec | 🟡 draft | 2026-11-01 | 2027-04-30 |  | `docs/agent/police/BLUEPRINT-ITEMS-CC.md` |
| [警察道具层蓝图（Items & Props）v2](agent/police/BLUEPRINT-ITEMS.md) | spec | ✅ active | 2026-11-01 | 2027-04-30 |  | `docs/agent/police/BLUEPRINT-ITEMS.md` |
| [警察模块蓝图 v1（待开发）](agent/police/BLUEPRINT.md) | spec | ✅ active | 2026-10-31 | 2027-04-30 |  | `docs/agent/police/BLUEPRINT.md` |
| [AI 调度员 MVP：agent 拿内容 → 解析 → call 卡草稿](agent/police/DISPATCHER-MVP.md) | spec | 🟡 draft | 2026-10-31 | 2027-04-30 |  | `docs/agent/police/DISPATCHER-MVP.md` |
| [Agent Ops — 警察服务器实时观测与介入](police/AGENT_OPS.md) | spec | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/AGENT_OPS.md` |
| [T-City 警察玩法与系统设计（Police Roleplay DESIGN）](police/DESIGN.md) | spec | ✅ active | 2026-10-23 | 2027-04-30 |  | `docs/police/DESIGN.md` |
| [T-City 警察 / 罪犯 / 律师 流程审计（FLOW_INTERNAL）](police/FLOW_INTERNAL.md) | spec | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/FLOW_INTERNAL.md` |
| [警察系统架构总览（00 Overview）](police/architecture/00-overview.md) | spec | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/architecture/00-overview.md` |
| [警察系统领域模型（01 Domain Model）](police/architecture/01-domain-model.md) | spec | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/architecture/01-domain-model.md` |
| [02 状态机（执勤 / 警情 / 文书 / 司法 / 在押 / NPC 支援 / Agent / NPC 警情）](police/architecture/02-state-machines.md) | spec | ✅ active | 2026-10-29 | 2027-04-30 |  | `docs/police/architecture/02-state-machines.md` |
| [03 — 跨资源契约（Contracts）](police/architecture/03-contracts.md) | spec | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/architecture/03-contracts.md` |
| [04 — 数据所有权（Data Ownership）](police/architecture/04-data-ownership.md) | spec | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/architecture/04-data-ownership.md` |
| [05 — 非功能需求（NFR）与数字预算](police/architecture/05-nfr.md) | spec | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/architecture/05-nfr.md` |
| [07 — 架构适应度测试（Fitness Tests）](police/architecture/07-fitness-tests.md) | spec | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/architecture/07-fitness-tests.md` |
| [08 端到端场景（验收基线）](police/architecture/08-scenarios.md) | spec | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/architecture/08-scenarios.md` |
| [09 · Intent TTL + Outbox（SM-03 残留补偿）](police/architecture/09-outbox.md) | spec | ✅ active | 2026-10-24 | 2027-04-30 |  | `docs/police/architecture/09-outbox.md` |
| [SM-06 v2：NPC 支援的生命周期契约](police/architecture/10-backup-v2.md) | spec | ✅ active | 2026-10-31 | 2027-04-30 |  | `docs/police/architecture/10-backup-v2.md` |
| [10 — 警情全生命周期：自动结算、两个按钮、一条归档线](server-design/10-police-incident-lifecycle.md) | spec | ✅ active | 2026-10-26 | 2027-04-30 |  | `docs/server-design/10-police-incident-lifecycle.md` |

### medical（1）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [🏥 T-City Lite 医护职业与救援系统 (EMS) 细化规划](archive/QBCore_Lite_versions/career/medical_plan.md) | plan | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/career/medical_plan.md` |

### crime（5）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [设计文档：商店抢劫重构 — "罪与罚" 沉浸式玩法](archive/design-notes/store-robbery-redesign-20260601.md) | audit | 📦 archived | 2026-10-23 | — |  | `docs/archive/design-notes/store-robbery-redesign-20260601.md` |
| [商店抢劫重构 — "罪与罚" 沉浸式玩法文档](store-robbery-redesign-20260601.md) | audit | 📌 final | 2026-10-25 | — |  | `docs/store-robbery-redesign-20260601.md` |
| [Module 6: 犯罪系统 (crime.cfg)](01_module_manuals/06_crime_system.md) | manual | ✅ active | 2026-06-21 | 2027-01-30 |  | `docs/01_module_manuals/06_crime_system.md` |
| [custom-security + custom-crime + custom-main — 安全与犯罪三件套](02_script_index/custom-security-crime-main.md) | manual | 📦 archived | 2026-06-21 | 2027-01-30 |  | `docs/02_script_index/custom-security-crime-main.md` |
| [v0.5 犯罪玩法](archive/QBCore_Lite_versions/v0.5-crime-gameplay.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v0.5-crime-gameplay.md` |

### jobs（7）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [v0.7a 验收报告（服务端 / 无头）](../T-CityLite.base/docs/v0.7a-acceptance-report.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/v0.7a-acceptance-report.md` |
| [Module 5: 职业与权限系统 (jobs.cfg / police.cfg / medical.cfg / career.cfg / admin.cfg)](01_module_manuals/05_jobs_and_permissions.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `docs/01_module_manuals/05_jobs_and_permissions.md` |
| [🚗 T-City Lite 驾驶员与驾考系统 (Driver) 细化规划](archive/QBCore_Lite_versions/career/driver_plan.md) | plan | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/career/driver_plan.md` |
| [🚚 T-City Lite 货运司机与物流系统 (Logistics) 细化规划](archive/QBCore_Lite_versions/career/logistics_plan.md) | plan | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/career/logistics_plan.md` |
| [🎭 T-City Lite 职业身份与扮演体验（Career）总规划](archive/QBCore_Lite_versions/career/overall_plan.md) | plan | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/career/overall_plan.md` |
| [T-City Lite — 职业声望与进阶养成系统设计](../T-CityLite.base/docs/v0.7-career-reputation-design.md) | spec | ✅ active | 2026-06-21 | 2027-04-30 |  | `T-CityLite.base/docs/v0.7-career-reputation-design.md` |
| [v0.7a 载具系统重构与通用物流任务系统集成](archive/QBCore_Lite_versions/v0.7a-civilian-logistics.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v0.7a-civilian-logistics.md` |

### vehicle（6）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [Module 4: 车辆系统 (vehicles.cfg)](01_module_manuals/04_vehicle_system.md) | manual | ✅ active | 2026-06-21 | 2027-01-30 |  | `docs/01_module_manuals/04_vehicle_system.md` |
| [custom-vehicles — 统一车辆系统](02_script_index/custom-vehicles.md) | manual | 📦 archived | 2026-06-21 | 2027-01-30 |  | `docs/02_script_index/custom-vehicles.md` |
| [✈️ T-City Lite 飞行员与航空系统 (Pilot) 细化规划](archive/QBCore_Lite_versions/career/pilot_plan.md) | plan | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/career/pilot_plan.md` |
| [T-City2 改装店玩法分析报告](analysis/tuning_shop_analysis.md) | research | 📌 final | 2026-10-25 | 2027-01-30 |  | `docs/analysis/tuning_shop_analysis.md` |
| [T-City2 改装店玩家体验流程设计](analysis/tuning_shop_player_experience.md) | research | 📌 final | 2026-06-21 | 2027-01-30 |  | `docs/analysis/tuning_shop_player_experience.md` |
| [qb-vehicleshop 购车流程梳理（v0.7a 实测后）](../T-CityLite.base/docs/vehicleshop-purchase-sequence.md) | spec | ✅ active | 2026-10-21 | 2027-04-30 |  | `T-CityLite.base/docs/vehicleshop-purchase-sequence.md` |

### items（1）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [qb-inventory — 玩家背包系统](02_script_index/qb-inventory.md) | manual | 📦 archived | 2026-06-21 | 2027-01-30 |  | `docs/02_script_index/qb-inventory.md` |

### org（1）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [v0.7 组织系统五件套](02_script_index/v07-org-systems.md) | manual | 📦 archived | 2026-06-21 | 2027-01-30 |  | `docs/02_script_index/v07-org-systems.md` |

### comms（10）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [custom-phone 审计报告（性能 + 当前故障）](../T-CityLite.base/docs/agent/phone/custom-phone-audit.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/agent/phone/custom-phone-audit.md` |
| [地图 Blip 配置与本地化 — 技术文档](../T-CityLite.base/docs/BLIP_I18N_GUIDE.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/BLIP_I18N_GUIDE.md` |
| [Blip 本地化维护速查卡](../T-CityLite.base/docs/BLIP_I18N_QUICKREF.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/BLIP_I18N_QUICKREF.md` |
| [GPS 任务消息模式 — 模板文档](../T-CityLite.base/docs/gps-message-pattern.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/gps-message-pattern.md` |
| [custom-phone — 高性能 Phone-First 手机系统](02_script_index/custom-phone.md) | manual | 📦 archived | 2026-06-21 | 2027-01-30 |  | `docs/02_script_index/custom-phone.md` |
| [手机架构（目标态 v2）](client/PHONE_ARCHITECTURE.md) | manual | ✅ active | 2026-10-27 | 2027-01-30 |  | `docs/client/PHONE_ARCHITECTURE.md` |
| [qb-phone 调研报告](../T-CityLite.base/docs/agent/phone/qb-phone-research.md) | research | 📌 final | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/agent/phone/qb-phone-research.md` |
| [custom-phone 性能与职业 App 接口设计（旧副本，现行版在 docs/agent/phone/DESIGN.md）](../T-CityLite.base/docs/agent/phone/DESIGN.md) | spec | ♻️ superseded | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/agent/phone/DESIGN.md` |
| [custom-phone 性能与职业 App 接口设计](agent/phone/DESIGN.md) | spec | ✅ active | 2026-10-31 | 2027-04-30 | ★ | `docs/agent/phone/DESIGN.md` |
| [v0.4 自研手机系统（custom-phone）](archive/QBCore_Lite_versions/v0.4-custom-phone.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v0.4-custom-phone.md` |

### quest（10）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [custom-quest — 数据驱动任务系统](02_script_index/custom-quest.md) | manual | 📦 archived | 2026-06-21 | 2027-01-30 |  | `docs/02_script_index/custom-quest.md` |
| [T-City 职业与组织任务情景建立手册 (Batch 1, Batch 2, Batch 3 & Batch 4)](archive/QBCore_Lite_versions/career/careers_quest_designe/task_scenarios_setup_manual.md) | manual | 📦 archived | 2026-10-23 | 2027-01-30 |  | `docs/archive/QBCore_Lite_versions/career/careers_quest_designe/task_scenarios_setup_manual.md` |
| [T-City Lite — 通用任务模板系统设计](../T-CityLite.base/docs/v0.7-mission-template-design.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/v0.7-mission-template-design.md` |
| [🎭 T-City · 中东翻版剧情线 — 叙事设计全案](07_narrative/middle-east-narrative-design.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/07_narrative/middle-east-narrative-design.md` |
| [T-City 职业、资质与组织任务重构讨论蓝图 (v1.0)](archive/QBCore_Lite_versions/career/careers_quest_designe/career_task_discussion_blueprint.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/career/careers_quest_designe/career_task_discussion_blueprint.md` |
| [T-City通用任务系统：原子节点设计与配置规范手册 (v2.0.0 — 解耦重构版)](archive/QBCore_Lite_versions/career/careers_quest_designe/task_atomic_nodes_spec.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/career/careers_quest_designe/task_atomic_nodes_spec.md` |
| [T-City角色扮演核心任务设计与场景装配手册 (v2.0 — 经济与小游戏闭环版)](archive/QBCore_Lite_versions/career/careers_quest_designe/task_scenarios_design.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/career/careers_quest_designe/task_scenarios_design.md` |
| [v0.6-quest 通用任务系统（Quest/Mission System）](archive/QBCore_Lite_versions/v0.6-quest-system.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v0.6-quest-system.md` |
| [05 — 叙事所有权：让服务器拥有自己的历史](server-design/05-narrative-ownership.md) | spec | ✅ active | 2026-06-21 | 2027-04-30 |  | `docs/server-design/05-narrative-ownership.md` |
| [09 — 任务的三种入口：日常是货架、剧情是剧本、奇遇是天气](server-design/09-quest-pre-start-and-kinds.md) | spec | ✅ active | 2026-10-26 | 2027-04-30 |  | `docs/server-design/09-quest-pre-start-and-kinds.md` |

### ops（1）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [Reasonix 通知声音配置](reasonix-hooks-config.md) | runbook | ✅ active | 2026-06-21 | 2027-01-30 |  | `docs/reasonix-hooks-config.md` |

### ux（20）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [T-City 客户端（FiveM / QBCore / NUI）审计](client/CLIENT_AUDIT.md) | audit | 📌 final | 2026-10-25 | — |  | `docs/client/CLIENT_AUDIT.md` |
| [客户端与 NUI 资料库](client/README.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/client/README.md` |
| [客户端基线与手机查询故障 —— 计划（2026-10-25）](client/plans/2026-10-25-client-baseline.md) | plan | 📦 archived | 2026-10-25 | 2027-04-30 |  | `docs/client/plans/2026-10-25-client-baseline.md` |
| [输入分层提案：让 UI 像 GTA 暂停菜单那样接管输入](client/plans/2026-10-27-input-layering.md) | plan | 📦 archived | 2026-10-27 | 2027-04-30 |  | `docs/client/plans/2026-10-27-input-layering.md` |
| [调研 + 计划：任务 App 的「可发现性」与平板详情栏](client/plans/2026-10-27-quests-app-review.md) | plan | 📦 archived | 2026-10-27 | 2027-04-30 |  | `docs/client/plans/2026-10-27-quests-app-review.md` |
| [车机中控的输入管线审查（2026-10-31）](client/plans/2026-10-31-dashboard-input-pipeline.md) | plan | 📦 archived | 2026-10-31 | 2027-04-30 |  | `docs/client/plans/2026-10-31-dashboard-input-pipeline.md` |
| [FiveM / QBCore 客户端与 NUI 深度调研](client/FIVEM_CLIENT_RESEARCH.md) | research | ✅ active | 2026-10-25 | 2027-01-30 |  | `docs/client/FIVEM_CLIENT_RESEARCH.md` |
| [FiveM 客户端 NUI/CEF 架构与调试实践（2026）](client/research/fivem-nui-2026.md) | research | ✅ active | 2026-10-25 | 2027-01-30 |  | `docs/client/research/fivem-nui-2026.md` |
| [输入层与键位冲突（调研）](client/research/input-layers-and-keybindings.md) | research | ✅ active | 2026-10-27 | 2027-01-30 |  | `docs/client/research/input-layers-and-keybindings.md` |
| [手机/平板 NUI 的键盘与手柄导航（研究 + 设计）](client/research/keyboard-and-gamepad-navigation.md) | research | ✅ active | 2026-10-27 | 2027-01-30 |  | `docs/client/research/keyboard-and-gamepad-navigation.md` |
| [NUI POST 未到达客户端 Lua 回调 —— 系统排查手册](client/research/nui-debug-playbook.md) | research | ✅ active | 2026-10-27 | 2027-01-30 |  | `docs/client/research/nui-debug-playbook.md` |
| [QBCore 客户端代码面分析（T-City 实测 + 上游对照）](qbcore-client-code-analysis.md) | research | 📌 final | 2026-10-27 | 2027-01-30 |  | `docs/qbcore-client-code-analysis.md` |
| [T-City Lite 交互设计规范备忘录 (Interaction Design Memo)](../T-CityLite.base/docs/interaction_memo.md) | spec | ✅ active | 2026-06-21 | 2027-04-30 |  | `T-CityLite.base/docs/interaction_memo.md` |
| [菜单交互设计规范（NUI / 世界交互）](../T-CityLite.base/docs/menu-interaction-design.md) | spec | ✅ active | 2026-10-21 | 2027-04-30 |  | `T-CityLite.base/docs/menu-interaction-design.md` |
| [v0.4 NUI 现代化标准与测试手册](../T-CityLite.base/docs/v0.4-nui-standard.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/v0.4-nui-standard.md` |
| [v0.4 复杂 UI 样板](archive/QBCore_Lite_versions/v0.4-ui-template.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v0.4-ui-template.md` |
| [v0.7b 智能车载中控屏与诊断系统 (Sleek Glassmorphic Dashboard NUI)](archive/QBCore_Lite_versions/v0.7b-vehicle-dashboard.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v0.7b-vehicle-dashboard.md` |
| [v0.8 客户端自适应多语言本土化架构系统](archive/QBCore_Lite_versions/v0.8-localization-adaptation.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v0.8-localization-adaptation.md` |
| [手机四段往返可观测设计（`phone:server:diag`）](client/research/client-observability-design.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/client/research/client-observability-design.md` |
| [11 · 工作平板：一台设备的两种形态](server-design/11-work-tablet.md) | spec | ✅ active | 2026-10-26 | 2027-04-30 |  | `docs/server-design/11-work-tablet.md` |

### world（11）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [T-City Atmosphere — 游戏内氛围音乐系统](../T-CityLite.base/docs/systems/atmosphere.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/systems/atmosphere.md` |
| [T-City 服务器核心机制设计手册](server-design/README.md) | meta | ✅ active | 2026-10-26 | 2027-04-30 |  | `docs/server-design/README.md` |
| [v0.6b 沙盒社会生态与领袖体系（Sandbox Sociology）](archive/QBCore_Lite_versions/v0.6-sandbox-sociology.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v0.6-sandbox-sociology.md` |
| [v0.7 硬核原位登录与极端情况防范重生系统](archive/QBCore_Lite_versions/v0.7-hardcore-spawn-system.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v0.7-hardcore-spawn-system.md` |
| [A · 世界痕迹第一条链 — 施工图（research → plan）](engineering/2026-11-01-world-traces-blueprint.md) | spec | ✅ active | 2026-11-01 | 2027-04-30 |  | `docs/engineering/2026-11-01-world-traces-blueprint.md` |
| [情景制造器（Scenario Engine）设计稿](engineering/scenario-engine/DESIGN.md) | spec | ✅ active | 2026-10-29 | 2027-04-30 |  | `docs/engineering/scenario-engine/DESIGN.md` |
| [00 — 所有权哲学：为什么所有权感是留存与付费的唯一引擎](server-design/00-ownership-philosophy.md) | spec | ✅ active | 2026-06-21 | 2027-04-30 |  | `docs/server-design/00-ownership-philosophy.md` |
| [01 — 预设→涌现漏斗：如何让预设任务成为涌现式玩法的入口](server-design/01-preset-to-emergent-funnel.md) | spec | ✅ active | 2026-06-21 | 2027-04-30 |  | `docs/server-design/01-preset-to-emergent-funnel.md` |
| [02 — 世界痕迹系统：让玩家行为留下可见、持久的世界后果](server-design/02-world-traces.md) | spec | ✅ active | 2026-06-21 | 2027-04-30 |  | `docs/server-design/02-world-traces.md` |
| [03 — 不可替代性与声誉：让玩家成为"基础设施"](server-design/03-irreplaceability-reputation.md) | spec | ✅ active | 2026-06-21 | 2027-04-30 |  | `docs/server-design/03-irreplaceability-reputation.md` |
| [04 — 共治系统：让玩家成为规则的共同制定者](server-design/04-co-governance.md) | spec | ✅ active | 2026-06-21 | 2027-04-30 |  | `docs/server-design/04-co-governance.md` |

### agent（33）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [fivem-mcp 实机验证报告（ziyacivan/fivem-mcp 0.6.0）](../T-CityLite.base/docs/agent/FIVEM_MCP_LIVE_TEST.md) | audit | 📌 final | 2026-10-27 | — |  | `T-CityLite.base/docs/agent/FIVEM_MCP_LIVE_TEST.md` |
| [01 — Python 工具契约层对抗性评审（`498b888`）](../T-CityLite.base/docs/agent/reviews/01-python-contract.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/agent/reviews/01-python-contract.md` |
| [02 · Lua HTTP 抽取重构对抗性评审（`ccdd61e`）](../T-CityLite.base/docs/agent/reviews/02-lua-refactor.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/agent/reviews/02-lua-refactor.md` |
| [03 — 工具契约与 CI 评审（commit `498b888`）](../T-CityLite.base/docs/agent/reviews/03-contract-ci.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/agent/reviews/03-contract-ci.md` |
| [04 · Live perception（`/agent/v1/live/*`）对抗性评审](../T-CityLite.base/docs/agent/reviews/04-live-perception.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/agent/reviews/04-live-perception.md` |
| [05 — Live tools / `auth` / 游标对抗性评审（`e8df70a`）](../T-CityLite.base/docs/agent/reviews/05-live-tools.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/agent/reviews/05-live-tools.md` |
| [06 — 四方契约最终一致性评审（`4400d8b`）](../T-CityLite.base/docs/agent/reviews/06-final-contract.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/agent/reviews/06-final-contract.md` |
| [07 — 最终安全集成评审：四条凭证链 / 客户端 / 路径 / PII](../T-CityLite.base/docs/agent/reviews/07-final-security.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/agent/reviews/07-final-security.md` |
| [08 — Phase 2 快速安全评审（A 手机系统短信 / B agent_effects 审计 / C live money）](../T-CityLite.base/docs/agent/reviews/08-phase2.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/agent/reviews/08-phase2.md` |
| [FiveM 双端 Agent 自动化测试：现状调研与落地方案](analysis/agent-e2e-testing-20261022.md) | audit | 📌 final | 2026-10-25 | — |  | `docs/analysis/agent-e2e-testing-20261022.md` |
| [Agent Action Contract (`custom-director`, v1)](../T-CityLite.base/docs/agent/ACTIONS.md) | manual | ✅ active | 2026-10-31 | 2027-01-30 |  | `T-CityLite.base/docs/agent/ACTIONS.md` |
| [Agent Read API and MCP Sidecar (issue #24)](../T-CityLite.base/docs/agent/API.md) | manual | ✅ active | 2026-10-23 | 2027-01-30 |  | `T-CityLite.base/docs/agent/API.md` |
| [驱动服务器控制台（`tcity-cmd`）](../T-CityLite.base/docs/agent/CONSOLE.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/agent/CONSOLE.md` |
| [把 MCP 接到 T-City 上（本地全链路）](../T-CityLite.base/docs/agent/MCP_WIRING.md) | manual | ✅ active | 2026-10-31 | 2027-01-30 |  | `T-CityLite.base/docs/agent/MCP_WIRING.md` |
| [加 / 改一个 agent 动作：检查清单](agent/police/ATOOLS-DISCIPLINE.md) | manual | ✅ active | 2026-10-31 | 2027-01-30 |  | `docs/agent/police/ATOOLS-DISCIPLINE.md` |
| [Agent Read Layer (Phase 3 / P1)](../T-CityLite.base/docs/agent/README.md) | meta | ✅ active | 2026-10-27 | 2027-04-30 |  | `T-CityLite.base/docs/agent/README.md` |
| [2026-11-01 · 下一步开发方向调研（Hermes + Claude Code 双份意见）](engineering/2026-11-01-next-epic-research.md) | research | ✅ active | 2026-11-01 | 2027-01-30 |  | `docs/engineering/2026-11-01-next-epic-research.md` |
| [客户端双端测试 Harness（MCP）](../T-CityLite.base/docs/agent/CLIENT_HARNESS.md) | spec | ✅ active | 2026-10-26 | 2027-04-30 |  | `T-CityLite.base/docs/agent/CLIENT_HARNESS.md` |
| [客户端可观测性：服务端能看见客户端](../T-CityLite.base/docs/agent/CLIENT_OBSERVABILITY.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/agent/CLIENT_OBSERVABILITY.md` |
| [Rule-Based Director Bridge (`custom-director`, v1)](../T-CityLite.base/docs/agent/DIRECTOR.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/agent/DIRECTOR.md` |
| [Agent Action Evaluation (`tools/agent_eval.py`)](../T-CityLite.base/docs/agent/EVAL.md) | spec | ✅ active | 2026-10-23 | 2027-04-30 |  | `T-CityLite.base/docs/agent/EVAL.md` |
| [Live Smoke Checks (`tools/agent_smoke.py`)](../T-CityLite.base/docs/agent/SMOKE.md) | spec | ✅ active | 2026-10-26 | 2027-04-30 |  | `T-CityLite.base/docs/agent/SMOKE.md` |
| [Agent 接管 · 实现状态](../T-CityLite.base/docs/agent/STATUS.md) | spec | ✅ active | 2026-10-27 | 2027-04-30 |  | `T-CityLite.base/docs/agent/STATUS.md` |
| [01 — 实时感知层 v2（Live Perception）](../T-CityLite.base/docs/agent/design/01-live-perception.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/agent/design/01-live-perception.md` |
| [02 — 客户端效果通道（Effect Channel）v1 设计](../T-CityLite.base/docs/agent/design/02-client-effect-channel.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/agent/design/02-client-effect-channel.md` |
| [03 — 统一工具面（Tool Surface）v1 设计](../T-CityLite.base/docs/agent/design/03-tool-contract.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/agent/design/03-tool-contract.md` |
| [04 — 写操作扩展 v2：15 个动作与治理闭环](../T-CityLite.base/docs/agent/design/04-write-actions.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/agent/design/04-write-actions.md` |
| [05 · Agent 基础设施测试与评测体系 v1](../T-CityLite.base/docs/agent/design/05-test-and-eval.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/agent/design/05-test-and-eval.md` |
| [06 · 客户端模型：性质、可验证性、双端 Agent 准备](../T-CityLite.base/docs/agent/design/06-client-model.md) | spec | ✅ active | 2026-10-27 | 2027-04-30 |  | `T-CityLite.base/docs/agent/design/06-client-model.md` |
| [07 · 本地 console harness：把「看得见」变成「断言得出」](../T-CityLite.base/docs/agent/design/07-harness-channel.md) | spec | ✅ active | 2026-10-27 | 2027-04-30 |  | `T-CityLite.base/docs/agent/design/07-harness-channel.md` |
| [08 · 客户端状态探测（read-only probe）](../T-CityLite.base/docs/agent/design/08-client-state-probe.md) | spec | ✅ active | 2026-10-27 | 2027-04-30 |  | `T-CityLite.base/docs/agent/design/08-client-state-probe.md` |
| [Agent 基础设施推进顺序（P1 → P2 → P3）](../T-CityLite.base/docs/agent/sequencing.md) | spec | ✅ active | 2026-10-21 | 2027-04-30 |  | `T-CityLite.base/docs/agent/sequencing.md` |
| [08 — Agent 中枢游戏导演：架构设计与三阶段落地](server-design/08-agent-director.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/server-design/08-agent-director.md` |

### delivery（29）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [🏁 T-City Lite — 工程交付报告](../T-CityLite.base/docs/audit/2026-06-20-delivery-report.md) | audit | 📌 final | 2026-06-21 | — |  | `T-CityLite.base/docs/audit/2026-06-20-delivery-report.md` |
| [🏛️ T-City Lite — 全局代码审计报告](../T-CityLite.base/docs/audit/2026-06-20-full-audit-report.md) | audit | 📌 final | 2026-06-21 | — |  | `T-CityLite.base/docs/audit/2026-06-20-full-audit-report.md` |
| [实机玩法回归测试计划（Issue #16）](../T-CityLite.base/docs/audit/2026-10-21-ingame-test-plan.md) | audit | 📌 final | 2026-10-21 | — |  | `T-CityLite.base/docs/audit/2026-10-21-ingame-test-plan.md` |
| [T-City Lite — 全局审查、修复与三阶段路线图](../T-CityLite.base/docs/audit/2026-10-21-review-and-three-phase-plan.md) | audit | 📌 final | 2026-10-21 | — |  | `T-CityLite.base/docs/audit/2026-10-21-review-and-three-phase-plan.md` |
| [自审记录 — Phase 1 审查与修复分支合并](../T-CityLite.base/docs/audit/2026-10-21-self-review.md) | audit | 📌 final | 2026-10-21 | — |  | `T-CityLite.base/docs/audit/2026-10-21-self-review.md` |
| [测试报告 — 2026-10-21](../T-CityLite.base/docs/audit/2026-10-21-test-report.md) | audit | 📌 final | 2026-10-22 | — |  | `T-CityLite.base/docs/audit/2026-10-21-test-report.md` |
| [🧪 T-City Lite v0.1~v0.4 自动化测试报告](../T-CityLite.base/docs/test-report-v0.1-v0.4.md) | audit | 📌 final | 2026-06-21 | — |  | `T-CityLite.base/docs/test-report-v0.1-v0.4.md` |
| [T-City Lite v0.2 综合测试与实机联调主手册 (Master Test Manual)](../T-CityLite.base/docs/v0.2-master-test-manual.md) | audit | 📌 final | 2026-06-01 | — |  | `T-CityLite.base/docs/v0.2-master-test-manual.md` |
| [T-City Lite v0.2 In-Game Test Checklist](../T-CityLite.base/docs/v0.2-test-checklist.md) | audit | 📌 final | 2026-06-01 | — |  | `T-CityLite.base/docs/v0.2-test-checklist.md` |
| [T-City Lite v0.2 - 警星移交与雷达追踪实机测试指南](../T-CityLite.base/docs/v0.2-wanted-handover-test-guide.md) | audit | 📌 final | 2026-06-01 | — |  | `T-CityLite.base/docs/v0.2-wanted-handover-test-guide.md` |
| [T-City Lite v0.3 基础设施层实机测试清单 (Test Checklist)](../T-CityLite.base/docs/v0.3-test-checklist.md) | audit | 📌 final | 2026-10-23 | — |  | `T-CityLite.base/docs/v0.3-test-checklist.md` |
| [T-City Lite v0.3 基础设施层测试验收手册 (Test Manual)](../T-CityLite.base/docs/v0.3-test-manual.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/v0.3-test-manual.md` |
| [🎮 T-City Lite v0.4 联合测试情景手册](../T-CityLite.base/docs/v0.4-joint-test-scenarios.md) | audit | 📌 final | 2026-06-21 | — |  | `T-CityLite.base/docs/v0.4-joint-test-scenarios.md` |
| [v0.4 自研手机系统验证与完善计划](../T-CityLite.base/docs/v0.4-validation-plan.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/v0.4-validation-plan.md` |
| [🎮 T-City Lite v0.5 犯罪玩法联合测试手册](../T-CityLite.base/docs/v0.5-joint-test-manual.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/v0.5-joint-test-manual.md` |
| [T-City Lite v0.7 — 全系统联调测试手册](../T-CityLite.base/docs/v0.7-integration-test-manual.md) | audit | 📌 final | 2026-06-21 | — |  | `T-CityLite.base/docs/v0.7-integration-test-manual.md` |
| [T-City Lite — 服务器重构项目交付与长期维护手册](../T-CityLite.base/docs/DELIVERY_MANUAL.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/DELIVERY_MANUAL.md` |
| [T-City Lite 开发工作流指南](../T-CityLite.base/docs/archive/dev-workflow-guide-2026-06-01.md) | manual | 📦 archived | 2026-10-23 | 2027-01-30 |  | `T-CityLite.base/docs/archive/dev-workflow-guide-2026-06-01.md` |
| [T-City Lite v0.1 技术维护文档](../T-CityLite.base/docs/v0.1-maintenance.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/v0.1-maintenance.md` |
| [T-City Lite v0.2 存盘性能优化与数据库异步落盘技术维护文档](../T-CityLite.base/docs/v0.2-database-performance-maintenance-guide.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/v0.2-database-performance-maintenance-guide.md` |
| [T-City Lite v0.2 - 医院地图与美术资产长期优化指南 (方案 A)](../T-CityLite.base/docs/v0.2-hospital-optimization-guide.md) | manual | ✅ active | 2026-06-01 | 2027-01-30 |  | `T-CityLite.base/docs/v0.2-hospital-optimization-guide.md` |
| [T-City Lite v0.2 技术维护文档](../T-CityLite.base/docs/v0.2-maintenance.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/v0.2-maintenance.md` |
| [T-City Lite v0.3 基础设施层技术维护手册 (Technical Manual)](../T-CityLite.base/docs/v0.3-technical-manual.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/v0.3-technical-manual.md` |
| [🔧 T-City Lite v0.5 技术维护手册](../T-CityLite.base/docs/v0.5-maintenance-guide.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/v0.5-maintenance-guide.md` |
| [🧪 T-City Lite 自动化测试方案](../T-CityLite.base/docs/automated-testing-plan.md) | plan | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/automated-testing-plan.md` |
| [v1.0 Open Beta 上线验收与发布清单](archive/QBCore_Lite_versions/v1.0-beta-launch.md) | plan | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v1.0-beta-launch.md` |
| [维护与排障手册](03_maintenance_manuals/maintenance_guide.md) | runbook | ✅ active | 2026-06-21 | 2027-01-30 |  | `docs/03_maintenance_manuals/maintenance_guide.md` |
| [运维手册（RUNBOOK）— T-City Lite](ops/RUNBOOK.md) | runbook | ✅ active | 2026-10-26 | 2027-01-30 |  | `docs/ops/RUNBOOK.md` |
| [🚀 T-City 生产部署架构设计书](../T-CityLite.base/docs/design/tcity-deployment-design-spec.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/design/tcity-deployment-design-spec.md` |

### meta（60）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [注意项解决方案（2026-10-21）](../T-CityLite.base/docs/attention-items-solutions.md) | audit | 📌 final | 2026-10-21 | — |  | `T-CityLite.base/docs/attention-items-solutions.md` |
| [T-City Lite 全局架构审计与现代化调整白皮书](../T-CityLite.base/docs/global-audit-whitepaper.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/global-audit-whitepaper.md` |
| [T-City Lite v0.2 角色状态持久化与系统稳定性技术维护文档](../T-CityLite.base/docs/v0.2-status-persistence-technical-memo.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/v0.2-status-persistence-technical-memo.md` |
| [T-City Lite v0.2 - 警星移交与雷达追踪系统技术维护文档](../T-CityLite.base/docs/v0.2-wanted-handover-technical-memo.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/v0.2-wanted-handover-technical-memo.md` |
| [T-City Lite 银行系统安全净化与对账重构文档 (v0.3)](../T-CityLite.base/docs/v0.3-banking-refactor.md) | audit | 📌 final | 2026-06-01 | — |  | `T-CityLite.base/docs/v0.3-banking-refactor.md` |
| [v0.4 自研手机系统实现分析报告](../T-CityLite.base/docs/v0.4-implementation-analysis.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/v0.4-implementation-analysis.md` |
| [🔍 T-City Lite v0.5 架构与安全深度审查报告](../T-CityLite.base/docs/v0.5-code-review-report.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/v0.5-code-review-report.md` |
| [v0.7b 收尾 vs v1.0 联调 — 决策建议](../T-CityLite.base/docs/v0.7b-v1.0-decision.md) | audit | 📌 final | 2026-10-25 | — |  | `T-CityLite.base/docs/v0.7b-v1.0-decision.md` |
| [T-City 仓库删除审计提案](cleanup/delete-proposal.md) | audit | 📌 final | 2026-10-23 | — |  | `docs/cleanup/delete-proposal.md` |
| [T-City 仓库 `.gitignore` 审计提案](cleanup/ignore-proposal.md) | audit | 📌 final | 2026-10-23 | — |  | `docs/cleanup/ignore-proposal.md` |
| [T-City 仓库结构与分类整改提案](cleanup/structure-proposal.md) | audit | 📌 final | 2026-10-23 | — |  | `docs/cleanup/structure-proposal.md` |
| [net event 治理基线（P1-3 第 1 步）](engineering/2026-11-foundation-net-events-baseline.md) | audit | ✅ active | 2026-11-01 | 2027-02-01 |  | `docs/engineering/2026-11-foundation-net-events-baseline.md` |
| [P1-2 / P1-1 验收证据（存档单写者 + 拆环）](engineering/2026-11-foundation-p1-evidence.md) | audit | ✅ active | 2026-11-01 | 2027-05-01 |  | `docs/engineering/2026-11-foundation-p1-evidence.md` |
| [T-CityLite 服务器总领手册](00-server-master-manual.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `docs/00-server-master-manual.md` |
| [🏛️ T-City 统一组织建立指导手册](ORGANIZATION_GUIDE.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `docs/ORGANIZATION_GUIDE.md` |
| [基石现状（AS-IS）— 组件、三条主链路、已知缺口](engineering/FOUNDATION-AS-IS.md) | manual | ✅ active | 2026-11-01 | 2027-01-30 |  | `docs/engineering/FOUNDATION-AS-IS.md` |
| [AGENTS.md — T-City 入口索引](../AGENTS.md) | meta | ✅ active | 2026-11-01 | 2027-04-30 |  | `AGENTS.md` |
| [Changelog](../CHANGELOG.md) | meta | ✅ active | 2026-11-01 | 2027-04-30 |  | `CHANGELOG.md` |
| [CLAUDE.md — 指针](../CLAUDE.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `CLAUDE.md` |
| [Contributing to T-City Lite](../CONTRIBUTING.md) | meta | ✅ active | 2026-10-21 | 2027-04-30 |  | `CONTRIBUTING.md` |
| [T-City Lite](../README.md) | meta | ✅ active | 2026-10-26 | 2027-04-30 |  | `README.md` |
| [Security Policy](../SECURITY.md) | meta | ✅ active | 2026-10-21 | 2027-04-30 |  | `SECURITY.md` |
| [T-CityLite.base/docs/ — 服务器与 agent 技术文档](../T-CityLite.base/docs/README.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/README.md` |
| [历史归档（不维护）：T-CityLite.base/docs/audit](../T-CityLite.base/docs/audit/LEGACY.md) | meta | 📌 final | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/audit/LEGACY.md` |
| [🏛️ T-City Lite 统一开发标准与规范索引 (README.md)](../T-CityLite.base/docs/standards/README.md) | meta | ✅ active | 2026-06-21 | 2027-04-30 |  | `T-CityLite.base/docs/standards/README.md` |
| [🚀 T-City Lite 开发与维护工作流规范 (dev_workflow.md)](../T-CityLite.base/docs/standards/dev_workflow.md) | meta | ✅ active | 2026-06-21 | 2027-04-30 |  | `T-CityLite.base/docs/standards/dev_workflow.md` |
| [📜 T-City Lite 统一日志输出规范 (logging_spec.md)](../T-CityLite.base/docs/standards/logging_spec.md) | meta | ✅ active | 2026-06-21 | 2027-04-30 |  | `T-CityLite.base/docs/standards/logging_spec.md` |
| [🔧 T-City Lite 运维与维护手册规范 (maintenance_manual_spec.md)](../T-CityLite.base/docs/standards/maintenance_manual_spec.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/standards/maintenance_manual_spec.md` |
| [📦 T-City Lite 脚本模板规范 (script_templates.md)](../T-CityLite.base/docs/standards/script_templates.md) | meta | ✅ active | 2026-06-21 | 2027-04-30 |  | `T-CityLite.base/docs/standards/script_templates.md` |
| [📘 T-City Lite 技术手册编写规范 (technical_manual_spec.md)](../T-CityLite.base/docs/standards/technical_manual_spec.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/standards/technical_manual_spec.md` |
| [🧪 T-City Lite 测试手册编写规范 (testing_manual_spec.md)](../T-CityLite.base/docs/standards/testing_manual_spec.md) | meta | ✅ active | 2026-06-21 | 2027-04-30 |  | `T-CityLite.base/docs/standards/testing_manual_spec.md` |
| [历史归档（不维护）：docs/02_script_index](02_script_index/LEGACY.md) | meta | 📌 final | 2026-10-25 | 2027-04-30 |  | `docs/02_script_index/LEGACY.md` |
| [docs/ — 项目级文档](README.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/README.md` |
| [历史归档（不维护）：docs/archive](archive/LEGACY.md) | meta | 📌 final | 2026-10-25 | 2027-04-30 |  | `docs/archive/LEGACY.md` |
| [📋 T-City Lite 版本规划索引](archive/QBCore_Lite_versions/README.md) | meta | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/README.md` |
| [历史归档（不维护）：docs/cleanup](cleanup/LEGACY.md) | meta | 📌 final | 2026-10-25 | 2027-04-30 |  | `docs/cleanup/LEGACY.md` |
| [ARCHITECTURE — 四个平面与依赖方向](engineering/ARCHITECTURE.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/engineering/ARCHITECTURE.md` |
| [CONSTITUTION — T-City 的十条不变量](engineering/CONSTITUTION.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/engineering/CONSTITUTION.md` |
| [消耗品与状态层（custom-consumables）](engineering/CONSUMABLES.md) | meta | ✅ active | 2026-10-31 | 2027-04-30 |  | `docs/engineering/CONSUMABLES.md` |
| [真机验证工作流（Live verification）](engineering/LIVE_VERIFICATION.md) | meta | ✅ active | 2026-10-30 | 2027-04-30 |  | `docs/engineering/LIVE_VERIFICATION.md` |
| [REUSE — 共享代码放哪、什么该合并、怎么收敛](engineering/REUSE.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/engineering/REUSE.md` |
| [STANDARDS — 技术标准 v0.2（可执行、可验证）](engineering/STANDARDS.md) | meta | ✅ active | 2026-11-01 | 2027-04-30 | ★ | `docs/engineering/STANDARDS.md` |
| [工作树与分支流程](engineering/WORKTREE.md) | meta | ✅ active | 2026-11-01 | 2027-04-30 |  | `docs/engineering/WORKTREE.md` |
| [Agent 时代的工程运行模型（T-City 落地提案 v1）](engineering/agent-operating-model.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/engineering/agent-operating-model.md` |
| [LLM 通用工艺准则（原 CLAUDE.md，2026-10-25 归档）](engineering/llm-craft.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/engineering/llm-craft.md` |
| [交付：<主题>](engineering/templates/delivery.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/engineering/templates/delivery.md` |
| [计划：<主题>](engineering/templates/plan.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/engineering/templates/plan.md` |
| [调研：<主题>](engineering/templates/research.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/engineering/templates/research.md` |
| [任务清单：<主题>](engineering/templates/tasks.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/engineering/templates/tasks.md` |
| [验证：<主题>](engineering/templates/verification.md) | meta | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/engineering/templates/verification.md` |
| [历史归档（不维护）：docs/police](police/LEGACY.md) | meta | 📌 final | 2026-10-25 | 2027-04-30 |  | `docs/police/LEGACY.md` |
| [文档生命周期管理规范](standards/doc-lifecycle.md) | meta | ✅ active | 2026-10-31 | 2027-04-30 | ★ | `docs/standards/doc-lifecycle.md` |
| [🌟 T-City Lite 项目总进度看板 (PROJECT_PROGRESS.md)](../PROJECT_PROGRESS.md) | plan | ✅ active | 2026-10-23 | 2027-04-30 |  | `PROJECT_PROGRESS.md` |
| [⚙️ T-City Lite Career (职业身份) 系统重构技术方案](archive/QBCore_Lite_versions/career/refactor_plan.md) | plan | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/career/refactor_plan.md` |
| [仓库整理总方案（合并三份提案）](cleanup/PLAN.md) | plan | 📌 final | 2026-10-23 | 2027-04-30 |  | `docs/cleanup/PLAN.md` |
| [2026-11 基石加固计划（P0 / P1 / P2）](engineering/2026-11-foundation-plan.md) | plan | ✅ active | 2026-11-01 | 2026-12-31 |  | `docs/engineering/2026-11-foundation-plan.md` |
| [T-City 服务器系统覆盖与规划缺口调研](analysis/2026-10-31-systems-coverage-survey.md) | research | 📌 final | 2026-10-31 | 2027-04-30 | ★ | `docs/analysis/2026-10-31-systems-coverage-survey.md` |
| [T-City Lite — DevOps 工作流](DEVOPS.md) | runbook | ✅ active | 2026-10-23 | 2027-01-30 |  | `docs/DEVOPS.md` |
| [📖 T-City Wiki 系统设计规格书](../T-CityLite.base/docs/design/tcity-wiki-design-spec.md) | spec | 🟡 draft | 2026-10-25 | 2027-04-30 |  | `T-CityLite.base/docs/design/tcity-wiki-design-spec.md` |
| [基石目标形态（TO-BE）— 五层、单写者、可验收的预算](engineering/FOUNDATION-TO-BE.md) | spec | ✅ active | 2026-11-01 | 2027-04-30 |  | `docs/engineering/FOUNDATION-TO-BE.md` |

### infra（17）

| 文档 | 类型 | 状态 | 更新 | 复审 | SoT | 路径 |
|---|---|---|---|---|---|---|
| [设计文档: 移除 escape_sqli 手动转义，改为全参数化查询](archive/design-notes/refactor-escape-sqli-20260601.md) | audit | 📦 archived | 2026-10-23 | — |  | `docs/archive/design-notes/refactor-escape-sqli-20260601.md` |
| [安全重构: 移除 escape_sqli 手动转义](refactor-escape-sqli-20260601.md) | audit | 📌 final | 2026-10-25 | — |  | `docs/refactor-escape-sqli-20260601.md` |
| [T-City Lite — Bus API 插件开发手册](../T-CityLite.base/docs/bus-api-reference.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/bus-api-reference.md` |
| [🏗️ T-City Lite v0.5 架构重构交付报告](../T-CityLite.base/docs/v0.5-architecture-migration.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `T-CityLite.base/docs/v0.5-architecture-migration.md` |
| [Module 1: 核心基础设施 (core.cfg / player.cfg / voice.cfg)](01_module_manuals/01_core_infrastructure.md) | manual | ✅ active | 2026-06-21 | 2027-01-30 |  | `docs/01_module_manuals/01_core_infrastructure.md` |
| [Module 2: 自研核心框架 (custom.cfg)](01_module_manuals/02_custom_framework.md) | manual | ✅ active | 2026-10-25 | 2027-01-30 |  | `docs/01_module_manuals/02_custom_framework.md` |
| [T-CityLite 全项目资源清单与启用矩阵](01_resource_inventory.md) | manual | 📦 archived | 2026-10-21 | 2027-01-30 |  | `docs/01_resource_inventory.md` |
| [core-framework — 核心服务框架 (v0.5 Data-Access Layer)](02_script_index/core-framework.md) | manual | 📦 archived | 2026-06-21 | 2027-01-30 |  | `docs/02_script_index/core-framework.md` |
| [qb-core — QBCore 核心框架](02_script_index/qb-core.md) | manual | 📦 archived | 2026-06-21 | 2027-01-30 |  | `docs/02_script_index/qb-core.md` |
| [Convars 全集索引](04_call_reference/convars_index.md) | manual | ✅ active | 2026-06-21 | 2027-01-30 |  | `docs/04_call_reference/convars_index.md` |
| [数据库表全量索引](04_call_reference/database_index.md) | manual | ✅ active | 2026-06-21 | 2027-01-30 |  | `docs/04_call_reference/database_index.md` |
| [Cross-Resource Events Index](04_call_reference/events_index.md) | manual | ✅ active | 2026-10-22 | 2027-01-30 |  | `docs/04_call_reference/events_index.md` |
| [重构删除清单 & 保留清单 v2.0](../T-CityLite.base/docs/refactoring_manifest_v2.md) | plan | 📌 final | 2026-06-21 | 2027-04-30 |  | `T-CityLite.base/docs/refactoring_manifest_v2.md` |
| [P1-4 调研：拆掉 compat 的全局猴补](engineering/2026-11-foundation-p1-4-research.md) | research | ✅ active | 2026-11-01 | 2026-12-31 |  | `docs/engineering/2026-11-foundation-p1-4-research.md` |
| [v0.1 精简启动](archive/QBCore_Lite_versions/v0.1-lite-startup.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v0.1-lite-startup.md` |
| [v0.2 基础 RP](archive/QBCore_Lite_versions/v0.2-basic-rp.md) | spec | 📦 archived | 2026-10-23 | 2027-04-30 |  | `docs/archive/QBCore_Lite_versions/v0.2-basic-rp.md` |
| [07 — 架构集成：如何嵌入 T-City Phase 0-3](server-design/07-architecture-integration.md) | spec | ✅ active | 2026-10-25 | 2027-04-30 |  | `docs/server-design/07-architecture-integration.md` |
