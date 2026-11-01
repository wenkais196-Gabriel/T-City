---
id: doc-lifecycle
type: meta
status: active
system: meta
owner: hermes
updated: 2026-10-31
review_by: 2027-04-30
tracks: [tools/docs_lifecycle.py, docs/INDEX.md]
topic: doc-lifecycle
source_of_truth: true
---

# 文档生命周期管理规范

> **类型**：meta（规范本身） ｜ **适用**：`docs/**`、`T-CityLite.base/docs/**`、`QBCore_Lite_versions/**` 与根目录 `*.md`
> **配套工具**：[`tools/docs_lifecycle.py`](../../tools/docs_lifecycle.py) ｜ **自动索引**：[`../INDEX.md`](../INDEX.md)
> **一句话**：每份文档都有**类型、状态、归属、到期日**，都能被工具找到、被 CI 约束、被索引统计。

---

## 0. 为什么需要这份规范（本项目的真实病灶）

这不是通用套话，四条都是本仓实测出来的：

| 病灶 | 实测证据 | 后果 |
|---|---|---|
| 文档数量与可发现性脱节 | 范围内 **172 份** md，其中 **43 份**在全仓任何文件里都没被提及（孤儿，25%） | 写了没人读得到，等于没写 |
| 同一事实多处陈述，数字互相打架 | `PROJECT_PROGRESS.md` 写「78 资源 / 17 CFG」，实测 82 / 18；`01_resource_inventory.md` 自标「历史快照」 | 以文档为准做规划会踩空 |
| 链接静默腐烂 | 建立规范时扫出 **3 处**断链（2 处真断、1 处是代码块内的示例被误判，已修）；`docs-check` 是 advisory，从不阻断 | 读者点到 404，信任崩塌 |
| 本机绝对路径混入文档 | **67 处** `file:///e:/T-City/...` 分布在 14 个文件 | 换机器/换人全部失效，CI 也查不出来（被 `file://` 规则跳过） |
| 状态只存在于人的脑子里 | 172 份里只有 10 份（本次补的）声明了类型/状态/复审日 | 没人知道哪份还能信、哪份该归档 |

所以本规范的目标不是"写得更漂亮"，而是**让文档可被检索、可被信任、可被统计**。

---

## 1. 分类法（先分类，再存放）

**8 种类型，类型决定生命周期、必填字段、复审周期与存放目录。** 一份文档只能有一种类型；混合型说明该拆。

| 类型 | 是什么 | 典型产物 | 存目录 | 状态终点 | 复审周期 |
|---|---|---|---|---|---|
| `spec` | 设计与施工图：要做什么、怎么做、怎么验收 | `BLUEPRINT.md`、`DESIGN.md`、v0.x 规格 | `docs/spec/<system>/` | `active`（被替代时 `superseded`） | 180 天 |
| `manual` | 手册/接口索引：**描述现在是什么** | 模块手册、脚本索引、API/Bus 参考 | `docs/manual/<system>/` | `active` 持续维护 | **90 天**（跟随代码，最易过期） |
| `adr` | 决策记录：为什么这样选，放弃了什么 | 选型、取舍、裁决 | `docs/adr/` | `final`（永不修改，只被新 ADR 替代） | 永不 |
| `plan` | 路线图/阶段计划：什么时候做什么 | 版本规划、阶段任务清单 | `docs/plan/` | `archived`（版本关闭时） | 每版本 |
| `audit` | 审计/验收/测试报告：某时刻的**快照** | 审查报告、验收报告、试玩记录 | `docs/audit/` | `final`（写完即冻结，改就新开一份） | 永不 |
| `research` | 调研：外部事实与结论，**会过期** | 生态调研、竞品分析 | `docs/research/` | `final` → `archived` | 180 天 |
| `runbook` | 运行手册：出事时照着做 | 起服、排障、备份、应急 | `docs/runbook/` | `active` | 90 天 |
| `meta` | 规范与索引：规则本身、目录页 | 本文件、`INDEX.md`、`docs/README.md` | `docs/standards/`、`docs/` | `active` | 180 天 |

**判定口诀**：读它是为了**动手做**→`spec`；为了**知道现状**→`manual`；为了**知道为什么**→`adr`；为了**知道什么时候**→`plan`；是**某天的证据**→`audit`；是**外部世界的结论**→`research`；是**出事时的步骤**→`runbook`；是**规则/导航**→`meta`。

---

## 2. 存储结构（两个根，一条边界）

本仓历史上有两个文档根，**不强制搬迁**（搬迁成本 > 收益，且 100+ 处链接会断），但边界必须写死：

| 根 | 定位 | 放什么 | 不放什么 |
|---|---|---|---|
| `docs/` | **项目级**（跨资源、人读） | 系统全景、施工图、调研、审计、ADR、路线图、工程规范 | 单个资源的内部说明 |
| `T-CityLite.base/docs/` | **工程级**（随服务器代码走） | 代码规范（`standards/`）、v0.x 手册、资源级设计、`agent/` 设计评审 | 跨系统的顶层规划（那是 `docs/plan/`） |
| `QBCore_Lite_versions/` | **历史版本规格**（只读归档） | 已发布版本的 spec | 新写的文档 |

**目标结构**（`docs/` 内按类型分目录，再按系统分一层）：

```
docs/
├── README.md            # 人工入口：3 分钟读完就知道从哪看（手写）
├── INDEX.md             # 自动生成：唯一文档清单 + 进度统计（禁手改）
├── standards/           # meta：规范
├── spec/<system>/       # 施工图
├── manual/<system>/     # 手册/接口
├── adr/                 # NNNN-<slug>.md
├── plan/                # 版本与阶段计划
├── audit/               # YYYY-MM-DD-<slug>.md
├── research/            # YYYY-MM-<slug>.md
├── runbook/
└── archive/             # 已归档（superseded/archived），只读
```

`<system>` 取值固定为 §7 的 18 个系统键；**不允许新建目录名**（新增系统先改 §7）。

---

## 3. 命名规范

| 对象 | 规则 | 例 |
|---|---|---|
| 目录 | 小写 kebab-case，系统键用 §7 的固定值 | `spec/justice/` |
| 文件 | 小写 kebab-case；**既有全大写规范名保留**（`BLUEPRINT.md`/`STATUS.md`/`DESIGN.md`/`ACCEPTANCE.md`），但不再新增；**不含版本号、不含日期**（除非 audit/research） | `mdt-blueprint.md` |
| ADR | `NNNN-<slug>.md`，四位序号连续 | `0003-keep-qb-inventory.md` |
| audit | `YYYY-MM-DD-<slug>.md` | `2026-10-21-full-audit.md` |
| research | `YYYY-MM-<slug>.md` | `2026-10-police-ecosystem.md` |
| 标题 | 文件第一行 `# <中文标题>`，**同仓唯一** | `# 警察模块蓝图 v1` |
| 禁止 | `-final`、`-v2-new`、`副本`、`tmp`、空格、大写开头 | ❌ `Police_BLUEPRINT_v2_final.md` |

> 版本不进文件名：版本写在正文首行与 frontmatter；历史版本由 git 与 `superseded_by` 承担。

---

## 4. frontmatter 规范（机器可读的唯一入口）

每份文档以 YAML frontmatter 开头，**只支持扁平键值**（工具用标准库解析，不引入 PyYAML）：

```markdown
---
id: justice-mdt-blueprint
type: spec
status: active
system: justice
owner: hermes
updated: 2026-10-31
review_by: 2027-04-30
supersedes: []
superseded_by: []
tracks: [qb-policejob, custom-justice]
source_of_truth: true
---
```

| 字段 | 必填 | 取值 | 说明 |
|---|---|---|---|
| `id` | ✅ | 小写 kebab-case，全仓唯一 | 引用用的稳定标识，**永不变**（改名不改 id） |
| `type` | ✅ | §1 的 8 种 | 决定复审周期与目录 |
| `status` | ✅ | `draft`｜`review`｜`active`｜`final`｜`superseded`｜`archived` | 见 §5 |
| `system` | ✅ | §7 的 18 个键 | 决定索引分组 |
| `updated` | ✅ | `YYYY-MM-DD` | **内容**最后变更日；工具会与 git 提交日比对告警 |
| `owner` | 建议 | `hermes`｜人名｜`team` | 复审责任人 |
| `review_by` | `manual`/`research`/`runbook` **必填** | `YYYY-MM-DD` | 到期未复审 → 索引标黄 |
| `supersedes` | 替代他文时 | `[id, ...]` | 必须与对方 `superseded_by` 双向一致 |
| `superseded_by` | 被替代时 | `[id, ...]` | `status: superseded` 时必填 |
| `tracks` | 建议 | 资源名/任务键 | 让"文档 ↔ 代码"可互查 |
| `topic` | 可选 | 小写 kebab-case | 主题键；**同一 `topic` 只允许一个 `source_of_truth`**（同一 system+type 下多主题时才需要填） |
| `source_of_truth` | 建议 | `true` | 该主题的唯一权威文档 |

---

## 5. 状态机（谁能改，改了要做什么）

```
        ┌────────┐  评审通过   ┌────────┐  长期维护   ┌────────┐
        │ draft  │───────────▶│ review │───────────▶│ active │
        └────────┘            └────────┘            └───┬────┘
             │                     │                    │
             │ 放弃                 │ 打回                │ 被新文档替代
             ▼                     ▼                    ▼
        ┌──────────┐          ┌────────┐          ┌────────────┐
        │ archived │◀─────────│ draft  │          │ superseded │
        └──────────┘          └────────┘          └─────┬──────┘
                                                         │ 6 个月后
                                                         ▼
                                                   ┌──────────┐
                                                   │ archived │
                                                   └──────────┘

audit / research / adr 走短链：draft → final →（可选）archived / superseded
```

| 转移 | 触发 | 必须同时做的事 |
|---|---|---|
| `draft → review` | 作者认为可评审 | 补 `updated`；写出验收标准（spec 类） |
| `review → active` | 通过评审（spec 类=开工许可） | 更新 `docs/INDEX.md`（由工具生成） |
| `active → superseded` | 有新文档取代 | 双方 `supersedes`/`superseded_by` 成对；新文档 `source_of_truth: true` |
| `active → archived` | 主题失去意义 | 正文首行加 `> 已归档，勿据此开发` |
| `final`（audit/research） | 结论落定 | **此后不再修改**，要改就新开一份并 `supersedes` |
| 复审到期（工具计算，非手写） | `review_by < today` 且 `status: active` | 三选一：改内容并顺延 `review_by`／标 `superseded`／归档 |

**铁律**：`stale`（过期）**不是一个可手写的状态**——它由 `review_by` 与代码/Git 时间计算得出，杜绝"文档自称最新"。

---

## 6. 工作流（三条主线）

### 6.1 新功能（唯一允许的开工路径）

```
① spec/draft          先写"做什么 + 怎么验收"，不写代码
② spec/review→active  评审通过 = 开工许可
③ 实现                代码 PR 必须同 PR 更新对应 manual（哪怕只加一节）
④ audit/final         交付时出一份验收报告（数字必须来自实测命令）
⑤ 更新 INDEX          工具自动；plan 里勾掉任务
```

### 6.2 现状维护（不写新功能时的日常）

| 场景 | 动作 |
|---|---|
| 读代码发现文档与实现不符 | **以代码为准**：立刻修 `manual` 或把旧文标 `superseded`，不留"待修正" |
| 改了资源行为 | 同一 PR 修 `manual` + 更新 `tracks` 里对应条目 |
| 发现两份文档讲同一件事 | 选一份 `source_of_truth: true`，另一份标 `superseded` 并链过去 |
| 半年没碰过的 `active` 文档 | 跑 `--report`，过期清单进当版本收尾任务 |

### 6.3 事件响应（出事时）

事后 24h 内产出一份 `audit` 或 `runbook` 更新：
- 事故根因 → `audit/YYYY-MM-DD-<slug>.md`（`final`）
- 可复用的处置步骤 → 直接改进 `runbook`（`active`），并顺延 `review_by`

---

## 7. 系统键（`system` 的合法取值）

与全服系统调研（[`../analysis/2026-10-31-systems-coverage-survey.md`](../analysis/2026-10-31-systems-coverage-survey.md) §1）一一对应，**新增系统必须先改这里再建目录**：

| 键 | 系统 | 键 | 系统 |
|---|---|---|---|
| `identity` | 身份与角色 | `org` | 组织与社交 |
| `economy` | 经济与金融 | `comms` | 通讯（手机/语音） |
| `justice` | 执法与司法 | `quest` | 任务与叙事 |
| `medical` | 医疗急救 | `ops` | 运营与安全 |
| `crime` | 犯罪与地下经济 | `ux` | 表现层/交互 |
| `jobs` | 正当职业 | `world` | 世界与环境 |
| `vehicle` | 载具全生命周期 | `agent` | AI Agent 层 |
| `items` | 物品与获取 | `delivery` | 交付与运维 |
| `property` | 房产与所有权 | `meta` | 规范/索引/顶层导航 |
| `infra` | 框架与基础设施（qb-core、oxmysql、Bus） | | |

---

## 8. 阅读路径（"方便阅读"的落地）

`docs/INDEX.md` 解决"有哪些"；`docs/README.md` 解决"从哪读"。**任何新读者按这三条路径之一，都应能在 10 分钟内到达目标文档**：

| 角色/目的 | 路径 |
|---|---|
| 新会话 / 新 agent 接手 | `AGENTS.md` → `T-CityLite.base/docs/agent/STATUS.md` → `docs/INDEX.md` 找对应系统 |
| 要改某个系统 | `INDEX.md` → 该系统 `spec`（做什么）→ `manual`（现状）→ `tracks` 指向的代码 |
| 要知道"还缺什么" | `docs/analysis/*systems-coverage*`（缺口）→ `docs/plan/`（排期）→ `INDEX.md` 里 `status: draft` 的 spec |

**入口约束**：`docs/README.md` 只允许放导航与"当前版本入口"不超过 5 条链接，禁止变成第二个总手册。

---

## 9. 进度追踪（怎么知道"文档这摊事"在变好）

### 9.1 口径

| 指标 | 定义 | 当前基线（2026-10-31 首次测量） | 目标 |
|---|---|---|---|
| 已登记率 | 有 frontmatter 的文档 / 范围内文档 | **10 / 172（5.8%）** | ≥ 90% |
| 孤儿率 | 全仓无人引用的文档 / 总数 | **43 / 172（25%）** | ≤ 5% |
| 断链 | 相对链接 404 数 | **0**（本次修掉 2 处真断链；第 3 处是代码块内的示例，已改工具跳过） | 恒为 0 |
| 本机绝对路径 | `file:///` 出现次数 | **67（14 个文件，存量未清）** | 0 |
| 到期未复审 | `review_by < today` 且 `active` | 0（刚建立，尚无到期） | 每版本清零 |
| SoT 冲突 | 同一 `topic` 多个 `source_of_truth` | 0 | 恒为 0 |

> 基线怎么来的：`python tools/docs_lifecycle.py --report`（明细在 `docs/_lifecycle.json`）。**每次版本收尾重跑一次并把 summary 记进版本报告**，这就是"文档进度"的可比数据。

### 9.2 分工（不要再让两份文档抢同一件事）

| 文档 | 只负责 | 不再负责 |
|---|---|---|
| `PROJECT_PROGRESS.md` | **版本与任务进度**（做了什么、卡在哪） | 资源清单数字（交由工具/索引） |
| `docs/INDEX.md` | **文档资产**（有哪些文档、什么状态） | 任务进度 |
| `docs/analysis/*coverage*` | **系统覆盖与缺口**（缺什么） | 排期 |

### 9.3 节奏

- **每次提交**：CI 跑 `--check`（现在是 advisory，Phase 3 转阻断）
- **每个 PR 合入后**：`--index` 重新生成（可由 CI 校验是否最新）
- **每个版本收尾**：`--report` 归档 `docs/_lifecycle.json` 快照，与本版对比"已登记率/孤儿率"变化
- **每季度**：清理 `archive/`，把 `superseded` 满 6 个月的移到 `archive/`

---

## 10. 自动化与本工具

```bash
python tools/docs_lifecycle.py --report     # 生成 docs/_lifecycle.json + 摘要（未登记/孤儿/重复）
python tools/docs_lifecycle.py --index      # 生成 docs/INDEX.md
python tools/docs_lifecycle.py --check      # 校验（退出码 1 = 有 ERROR）；--verbose 看全部告警
python tools/docs_lifecycle.py --adopt <文件...> [--yes]   # 给旧文档补最小 frontmatter
```

**校验项**（`--check`）：

| 级别 | 检查 |
|---|---|
| ERROR | 必填字段缺失、枚举非法、`updated` 格式错或未来日期、`id` 重复、同一 `topic` 两个 SoT、`supersedes` 指向不存在的 id |
| WARN | 未登记、`review_by` 已过期、`superseded` 未写 `superseded_by`、双向不一致、重复标题、断链、文件名不合规、同一 `(system,type)` 多份 SoT 但未分 `topic`、`INDEX.md` 不是最新 |

> 注意语义方向：`updated` 是**过去**日期（内容最后变更），`review_by` 是**未来**日期（复审截止）。写反了会直接报错。

**CI**：`.github/workflows/ci.yml` 的 `docs-lifecycle` job（advisory）。转阻断的条件：已登记率 ≥ 90% 且断链为 0。

---

## 11. 迁移计划（存量 170 份怎么处理）

| Phase | 动作 | 判定完成 | 状态 |
|---|---|---|---|
| **0** | 落规范 + 工具 + 索引 + CI advisory | `--check` 能跑通、`docs/INDEX.md` 生成 | ✅ 本次交付 |
| **1** | 补 SoT：每个系统的 `manual` 指定唯一权威文档；重复主题标 `superseded` | `(system,type)` SoT 无冲突 | 待做 |
| **2** | 分批补 frontmatter（按系统，一次 1–2 个系统） | 已登记率 ≥ 90% | 待做 |
| **3** | 清孤儿（44 份）：并入 `manual`／移 `archive/`／在索引里显式挂载 | 孤儿率 ≤ 5% | 待做 |
| **4** | CI 从 advisory 转 blocking | CI 红则不能合 | 待做 |

**批次建议**（按活跃度，而非目录）：`justice`（警察 BLUEPRINT 系）→ `comms`（手机）→ `agent` → `economy` → `delivery` → 其余。

---

## 12. 反模式（本仓真实出现过，一律禁止）

| 反模式 | 为什么禁 | 本仓实例 |
|---|---|---|
| 文档里写会过期的数字（资源数、用例数） | 一天就漂 | `PROJECT_PROGRESS.md` 的 78/17 |
| `file:///e:/...` 本机绝对路径 | 换人换机全废，CI 也查不出 | 67 处 / 14 文件 |
| 同一主题两份文档都自称权威 | 读者不知信谁 | `01_resource_inventory.md` vs `PROJECT_PROGRESS.md` |
| 用文件名表达状态（`-final`、`-v2`） | 状态会变，文件名不改就撒谎 | 历史遗留若干 |
| audit/验收报告事后修改 | 快照失真 | —（用 `supersedes` 开新篇） |
| "写完就算完"（无 owner、无复审日） | 半年后没人敢动 | 当前 170 份全部如此 |
| 索引手写维护 | 必然与事实脱节 | 旧 `PROJECT_PROGRESS.md` 的手工块 |

---

> **变更本规范**：改 §1 类型、§4 字段、§7 系统键，属于**破坏性变更**——必须同时改 `tools/docs_lifecycle.py` 的枚举并重跑 `--check`，否则 CI 会集体报错。规范自身遵循自己的规则（见本文 frontmatter 示例）。
