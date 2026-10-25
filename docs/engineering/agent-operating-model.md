# Agent 时代的工程运行模型（T-City 落地提案 v1）

> 目标：让「人 + 多个 agent」在同一个仓库里持续产出**可验收**的代码，并且不需要每次重新解释这个项目。
> 本文是调研结论 + 分层模型 + 本仓库映射 + 分三批的落地路线。
> 非目标：不引入新的框架依赖，不要求每个小改动都走全流程。

---

## 0. 一页结论

| 层 | 载体（本仓库落点） | 回答的问题 | 失效信号 |
|---|---|---|---|
| **L0 宪法** | `docs/engineering/CONSTITUTION.md` | 哪些东西**永远**不能违反 | 争论反复回到"要不要这么写" |
| **L1 分治** | `docs/engineering/ARCHITECTURE.md` + 依赖方向测试 | 谁可以调用谁、唯一通道是什么 | 客户端出现业务 SQL、NUI 直连服务端 |
| **L2 Agent 文件** | 根 `AGENTS.md`（索引）+ 分区 `AGENTS.md` | 动手前必须知道什么 | 规则文件越写越长、没人读完 |
| **L3 流程** | `docs/engineering/templates/` 五份模板 | 一个改动怎么从想法走到交付 | 计划写在聊天里、验收靠"看起来对" |
| **L4 技能** | `.agents/skills/<name>/SKILL.md` | 这类活**怎么做** | 同一个坑每次重新踩 |
| **L5 闸门** | `tests/architecture/` + lint + CI | 谁来判定"做完了" | 只有人肉评审，没有机器否决 |

一句话：**L0/L1 定不变量，L2 定入口，L3 定节奏，L4 定手法，L5 定裁判。** 缺任何一层，其余层都会被滥用：没有 L5，L0 就只是口号；没有 L0，L5 就变成无穷无尽的风格检查。

---

## 1. 先把问题定义清楚

行业里比较一致的判断是：模型能力不是瓶颈，**包裹模型的那层环境**才是。Thoughtworks 把它写成一条公式——`Agent = Model + Harness`，模型提供推理，harness 提供结构化的环境、工具约束、上下文边界和反馈闭环[5]。

这条公式有两个直接推论：

1. **只有仓库里可检索的东西才算数。** OpenAI 那套百万行 / 1500 PR 的实践里，工程师的首要工作被重新定义为"把上下文推进仓库"：Slack 里达成的架构共识、只存在于某人大脑里的领域知识，对 agent 来说等于不存在[4]。
2. **反馈必须自动化。** harness 里的"传感器"在每轮实现后自动跑，不依赖 agent 自评；并且遵循「静默成功、失败啰嗦」（silent success, verbose failure）——通过时几乎不产出，失败时给出可执行的细节[5]。

所以「分治 + 约束文件 + 流程」这个直觉是对的，但要补三个关键件才闭环：**不变量（宪法）**、**机器裁判（fitness functions）**、**可回收的债务（规则/清单都要有到期日）**。

### 三个典型失效模式（本仓库要主动防的）

| 失效模式 | 表现 | 对策层 |
|---|---|---|
| 规则文件膨胀 | `AGENTS.md` 写到 800 行，agent 只读前 200 行，人也不读 | L2 分层 + 索引化 |
| 约束不可判定 | "注意性能""保持简洁" —— 无法判断违反与否 | L2 写法约束 + L5 落地 |
| 流程变仪式 | 小改动也要写 spec，最后所有人绕过流程 | L3 分级（right-sized）[7] |

---

## 2. 六层模型逐层定义

### L0 宪法：10 条以内，写得像不变量

宪法只放**不可协商**的东西，而且必须能推出"违反 = 打回"。建议本仓库的十条（已有实践，抽出来固化）：

1. 服务端权威：客户端传来的任何数据都要服务端复验；NUI 隐藏 ≠ 权限。
2. 写路径唯一：钱/物品只走 `Player.Functions.*` / `core_economy:TriggerReward`，不直接 SQL。
3. SQL 参数化 + 列白名单 + `LIMIT`；禁止 `SELECT *`。
4. 每个 net event 必须过鉴权或登记为 `diagnostic`，并有投影/限流/预算。
5. 幂等：动作可重试，迁移可重复执行。
6. 表所有权唯一（`table_owners.json`），跨资源写表必须走 owner。
7. 诊断/遥测通道永不回包、永不落 PII。
8. 一次改动只动一个平面；跨平面必须显式说明契约变化。
9. 没有测试的修复不算完成（先红后绿）。
10. 交付物三件套：代码 + 文档 + CHANGELOG。

写法要求：每条 **≤ 2 行**，用"必须/禁止"开头，附一句"为什么"和一个可验证的落点（测试文件或脚本）。宪法改动 = 需要显式声明的一次决策。

### L1 分治：四平面 + 依赖方向矩阵

把系统切成四个平面，每个平面只暴露一个入口：

| 平面 | 载体 | 唯一入口 | 禁止 |
|---|---|---|---|
| **NUI** | `custom-phone/web/src`（Svelte 5 + Vite） | `resources/[custom]/custom-phone/web/src/utils/nui.ts` 的 `fetchNui` / `requestAppQuery` | 直接 `fetch`、拼 URL、读 localStorage 业务态 |
| **Client Lua** | `*/client/**` | `PhoneBridge.RegisterNui` / `Request` | 直接 SQL、直接改钱、直连 DB |
| **Server Lua** | `*/server/**` | `RegisterNetEvent` + 鉴权表 / exports | 假设客户端已校验、把 NUI 当可信来源 |
| **Shared** | `shared/`、`config.lua`、`types` | 纯数据与纯函数 | 依赖任何一侧的运行时 |

依赖方向只有一条：**NUI → Client → Server → DB**。反向（Server 主动改 NUI 状态）必须通过事件回来，不允许"服务端读一个网页变量"这种事。这条方向性是架构测试的直接输入（`test_resource_wiring.py` 已经在做资源级连线检查，可以扩展到平面级）。

工程上这类"边界自动化"有成熟工具形态：JS 侧用 dependency-cruiser 之类做规则化依赖检查，Lua 侧继续用仓库已有的 pytest 架构门禁。关键不是工具，而是**把边界写成一个会失败的测试**——这就是 fitness function：对必须保持的架构特性给出客观的完整性评估[8]。

### L2 Agent 文件：根文件当索引，分区文件当约束

AGENTS.md 是纯 Markdown、没有必填字段，生态里 Codex / Jules / Cursor / Aider / Devin 等都能读；**目录树里离被改文件最近的那份优先**，用户当场的对话指令覆盖一切[1]。OpenAI 主仓在写那篇文章时有 88 份 `AGENTS.md`[1]——这说明了正确用法：**不是写一份大全，而是分层**。

本仓库的目标形态：

```
AGENTS.md                      ← 索引：50~80 行，只放"去哪找"和"红线"
CLAUDE.md                      ← 指针：真正的规则在 AGENTS.md，别分叉
docs/engineering/
  CONSTITUTION.md              ← L0
  ARCHITECTURE.md              ← L1（平面图 + 依赖矩阵 + 唯一通道表）
  agent-operating-model.md     ← 本文（L0~L5 的说明书）
  templates/{research,plan,tasks,verification,delivery}.md   ← L3
T-CityLite.base/resources/[custom]/AGENTS.md   ← custom 资源专属约束
T-CityLite.base/resources/[qb]/AGENTS.md       ← 上游框架：允许改什么、怎么改
T-CityLite.base/tests/AGENTS.md                ← 测试怎么写（marker 抽块、反向校验）
custom-phone/web/AGENTS.md                     ← 前端：构建、产物、缓存、超时
```

每份分区文件控制在 **80 行内**，结构固定：`范围` / `唯一入口` / `禁止项` / `改动前必读` / `验收命令`。这样 agent 读到哪一层就知道到哪一层为止，避免"整份读不完"。

`CLAUDE.md` 现在是一份通用的"减少 LLM 犯错"清单，与本项目无关；建议改成 5 行指针 + 3 条项目红线，否则两份规则会分叉（规则分叉比没有规则更危险）。模块化指引、按文件类型限定范围的做法在 Fowler 那篇 context engineering 里也是推荐形态[6]。

### L3 流程：五阶段，每阶段一个 Markdown 产物

Spec Kit 把 SDD 的核心过程固化成 `Specify → Plan → Tasks → Implement → Converge`，每一阶段产出一份 Markdown 喂给下一阶段，用"结构化上下文"替代即兴提示[2]。BMAD 的思路一致，但强调 **right-sized**：清晰的改动直接做，大改动才加更深的计划[7]。

本仓库落成五阶段，与现有习惯对齐（我们已经有 `docs/client/research/` 和 `docs/client/plans/`）：

| 阶段 | 产物（放哪） | 退出条件（缺一不可） |
|---|---|---|
| **R 调研** | `docs/<area>/research/<date>-<topic>.md` | 影响面清单（文件:行）+ 证据（日志/源码/文档链接）+ 至少 1 条"排除掉的假设" |
| **P 计划** | `docs/<area>/plans/<date>-<topic>.md` | 范围 / 非范围 / 验收标准 / 回滚方式 / 风险 |
| **D 开发** | 代码 + 测试 | 每个切片可运行；先红后绿有记录 |
| **V 审查** | `verification.md` 或 PR 描述 | 测试输出原文、反向校验、`luac -p`/`svelte-check`、真机证据 |
| **S 交付** | commit + CHANGELOG + 文档 | push 前密钥扫描、allowlist 到期检查、文档同步 |

**分级**（避免流程变仪式）：
- L1 微改（注释/文案/单行 bug）：直接改 + 测试；
- L2 常规（一个函数/一个回调）：R 省略，P 写在 commit message 里；
- L3 结构（跨文件/跨平面）：完整五阶段；
- L4 架构（表结构、鉴权模型、协议）：五阶段 + 宪法检查 + 人审。

一票否决（任何一项出现就退回）：无测试的修复、无回滚方式的结构改动、绕过 allowlist、诊断通道回包、把 NUI 当权限边界。

### L4 技能：把"怎么做"从"必须遵守"里拆出来

Skill 的本质是**渐进式披露**：启动时只把 `name` + `description` 常驻上下文（第一层，足够判断"该不该用"），命中后才读完整 `SKILL.md`（第二层），需要时再读 `references/`、跑 `scripts/`（第三层）[3]。OpenAI 的仓库也是同一套：从一个很小的稳定入口开始，入口告诉你下一步去哪[4]。

所以 L2 与 L4 分工明确：
- **L2（AGENTS.md）= 必须遵守的约束**，少而硬；
- **L4（skills）= 某类任务的做法**，多而软，按需加载。

本仓库缺口：`tests/architecture/test_nui_client_contracts.py` 的注释里引用了 `.dsh/skills/fivem-client`，但 `.dsh/` 并不存在——说明技能曾经是"脑子里/外部工具里"的东西。建议把技能**版本化进仓库**（`.agents/skills/<name>/SKILL.md`），至少四个：

| 技能 | 触发条件 | 内容要点 |
|---|---|---|
| `fivem-resource-dev` | 写/改任意 FiveM 资源 | manifest 与 refresh 语义、NUI 应答通道三形态、焦点栈 |
| `phone-app-dev` | 改 custom-phone | 四段链路追踪、off-by-one 超时阶梯、限流预算 |
| `arch-gate` | 新增 net event / 表 / 跨资源调用 | 三处登记（allowlist/owner/budget）+ 投影与限流证据 |
| `release-check` | 交付前 | 密钥扫描、到期清单、文档同步、真机自检 |

每份技能带 `owner` 和 `last_verified`；超过 90 天未验证的技能标记为"存疑"，与债务清单同样的回收机制。

### L5 闸门：fitness functions

fitness function 的定义是"对必须保持的架构特性给出客观、持续、自动的完整性评估"[8]。本仓库已经有相当好的底子：**16 个架构测试 + 10 份 JSON 登记表**（net event、表所有权、查询、导出、数字预算、NUI 契约、资源连线、deprecations…）。这已经覆盖了 L0/L1 的大部分可判定项。

要补的四类闸门（按性价比排序）：

| 缺口 | 判定方式 | 拦截的问题 |
|---|---|---|
| **文档新鲜度** | lint：文档里引用的路径/命令/函数必须真实存在（`tests/architecture/test_docs_links.py`） | 文档描述的行为已不成立 |
| **Agent 文件交叉引用** | lint：每份分区 `AGENTS.md` 必须出现在根索引里、`验收命令` 能跑通 | 规则写了却没人加载 |
| **平面依赖方向** | 测试：client 里出现 `MySQL.`/`exports['oxmysql']` 直接报红；NUI 里出现裸 `fetch` 报红 | 边界被悄悄穿透 |
| **复用/重复** | 脚本：同名能力（如"取玩家身份"）出现第 2 个实现时提示 | 组件碎片化 |

「静默成功、失败啰嗦」原则要落到输出上[5]：架构测试通过时只打一行，失败时必须给出 `文件:行 + 反例形状 + 怎么改`——我们现有的 allowlist 报错已经接近这个标准，可以在文案上统一。

---

## 3. 与本仓库现状的差距（结论：底子在，缺分层与回收）

| 项 | 现状 | 差距 | 动作 |
|---|---|---|---|
| 宪法 | 散落在 `AGENTS.md §3` | 没有单一不变量文件 | 抽出 `CONSTITUTION.md`（10 条） |
| 分治 | 资源级连线测试（`test_resource_wiring`）、NUI 契约测试 | 没有**平面级**依赖矩阵 | 写 `ARCHITECTURE.md` + 1 个平面依赖测试 |
| Agent 文件 | 根 `AGENTS.md` 238 行、`CLAUDE.md` 通用清单 | 无分区文件、索引化不足、两份规则有分叉风险 | 根文件瘦身成索引 + 4 份分区文件 + CLAUDE.md 改指针 |
| 流程 | `docs/client/{research,plans}` 已在用；commit message 写得好 | 无模板、无分级、无 `verification.md` | 五份模板 + 分级表 |
| 技能 | 全局 `~/.hermes/skills/fivem-resource-development` | 未版本化进仓库、无 owner/到期 | `.agents/skills/` + 注册表 |
| 闸门 | 16 arch 测试 / 10 清单 / 733 用例 | 缺文档与复用的闸门 | 补 2 个 lint + 1 个复用脚本 |
| 回收 | allowlist 都带 `expires`（很好） | 文档/技能没有到期 | 统一 `expires` + 每季度"园丁"扫一轮[4] |

---

---

## 落地状态（2026-10-25）

三批已经全部落地，且每条约束都有机器裁判（`pytest tests/architecture`，CI 已包含）：

| 批次 | 交付物 | 验收 |
|---|---|---|
| **Batch 1 约束骨架** | `CONSTITUTION.md`（10 条，每条带落点）、`ARCHITECTURE.md`（四平面 + 依赖矩阵 + 唯一通道）、根 `AGENTS.md`（88 行索引）、4 份分区 `AGENTS.md`（`[custom]` / `[qb]` / `tests` / `custom-phone/web`）、`CLAUDE.md` 指针、5 份模板 | `test_agent_docs.py`：根索引必须登记全部分区文件、固定小节齐全、`CLAUDE.md` ≤20 行、宪法 10 条且落点文件真实存在 |
| **Batch 2 闸门** | `test_plane_boundaries.py`（4 条平面规则）、`test_docs_links.py`（约束区路径必须存在）、`test_agent_docs.py` | 四条注入全部变红：client 直连 DB、文档断链、新增未登记 `AGENTS.md`、宪法条款落点不存在 |
| **Batch 3 流程自动化** | `tools/dev/release_check.py`（凭据 + 债务到期 + CHANGELOG）、`tools/dev/reuse_scan.py`（同名实现复用报告）、PR 模板挂级别/阶段/发布检查 | `release_check.py` 通过；`reuse_scan.py` 首轮报告：`loadAnimDict` 17 份、`DebugPrint` 14 份 —— 正是"组件碎片化"的量化入口 |

**闸门覆盖率（`tools/dev/gate_coverage.py`）**：把"这条规则有没有被检验过"变成一个数字。
一条规则算已证明，当且仅当它在 `gate_history` 里失败过、是变异冒烟用例、或本身是反向校验；
其余算未证明（技术债）。未证明数写进 `tests/architecture/gate_coverage_budget.json`，
超过上限红，明显低于上限也红（逼着收紧）——和复用预算是同一套棘轮。

**闸门自身的可信度**：`tools/dev/gate_mutation_smoke.py` 会把"该被拦住的形状"真的注入仓库、
跑对应闸门、确认变红、再撤回，8 条核心闸门实测 7 条全部"注入后红、撤掉后绿"。
理由是 `gate_stats` 的另一半：205 条规则里长期 0 命中的那些，要么该删，要么从未被检验过——
而"从未红过"和"有效"在报表上长得一模一样。

**下一步的候选**（按价值排序，尚未开始）：

1. 用 `reuse_scan.py` 的结果做第一轮合并：`loadAnimDict` / `DebugPrint` 收敛到 `core-framework` 的公共库；
2. 把 `docs_links` 的范围从"约束区"扩到 `T-CityLite.base/docs/**`（需先清历史断链，报告见 `tools/dev/docs_links_report.py` 计划）；
3. ~~规则命中率指标~~ —— **已落地**：`tools/dev/gate_stats.py` 采集。`python3 tools/dev/gate_stats.py --record` 跑整套 `tests/architecture`，把每个用例的 PASSED/FAILED 连同时刻与 `git rev-parse --short HEAD` 追加成一行到 `T-CityLite.base/tests/architecture/gate_history.jsonl`；`python3 tools/dev/gate_stats.py --report`（默认，加 `--json` 给 CI）输出每条规则的最近一次结果、最近 20 次通过/失败，并单列「连续 0 命中」的规则 —— 那张清单就是季度复核的输入：删掉，或者补一条 `test_reverse_check_detects_*` 证明它会红。历史缺失/损坏都不报错（损坏行跳过并计数），工具本身永远不因「有规则从未失败」而退出非 0。

## 4. 落地路线（三批，每批都能独立验收）

**Batch 1 — 约束骨架（只加文件，不改代码）**
- `docs/engineering/CONSTITUTION.md`（10 条）
- `docs/engineering/ARCHITECTURE.md`（四平面 + 依赖矩阵 + 唯一通道表）
- 根 `AGENTS.md` 瘦身为索引（≤ 100 行），新增 4 份分区 `AGENTS.md`
- `CLAUDE.md` 改为 5 行指针
- 验收：任意 agent 从根文件能在 2 跳内找到"改动某资源要读哪份、跑哪条命令"

**Batch 2 — 闸门补齐（每个都是一条会失败的测试）**
- `test_docs_links.py`：文档里引用的路径/命令必须存在
- `test_plane_boundaries.py`：四平面依赖方向（client 不碰 DB、NUI 不裸 fetch、server 不读 NUI）
- `test_agent_docs.py`：分区 `AGENTS.md` 必须在根索引登记，且 `验收命令` 可执行
- `tools/dev/reuse_scan.py`：同名能力多实现提示（先只报告，不阻断）
- 验收：故意注入 4 种错误形状，4 条闸门全部变红

**Batch 3 — 流程自动化**
- `docs/engineering/templates/` 五份模板（R/P/D/V/S）
- PR 模板挂"分级 + 五阶段检查表"；commit message 模板带"问题/范围/审查/验证"四段（我们已经在用这个结构，只是没模板化）
- `tools/dev/release_check.py`：密钥扫描 + allowlist 到期 + 文档同步提示
- 验收：一次真实的 L3 改动全程只靠模板与脚本完成，人工只做判断不做检查

---

## 5. 度量（只留四个，能真实采集）

1. **首次通过率**：PR 第一次跑 CI 就绿的比例（低了 = 约束没进上游）。
2. **回归逃逸数**：上线后由人发现、而闸门没拦住的缺陷数（高了 = 缺闸门类型）。
3. **复用率**：新代码里"调用既有能力"的比例（靠 `reuse_scan` 与 owner 表统计）。
4. **规则命中率**：每条宪法/闸门的拦截次数；长期 0 命中的规则要么删掉，要么说明它没被检验（后者会让人误以为安全）。

---

## 6. 反模式（写在这里，避免半年后重犯）

- 把 README 抄一遍当 `AGENTS.md`：agent 读到的是历史，不是约束。
- 全流程强制：小改也写 spec → 团队绕过流程 → 流程名存实亡。分级是必需的[7]。
- 不可判定的规则："要高性能""注意安全"——违反与否无法判定，等于没写。
- 只约束不回收：清单没有 `expires`，两年后没人知道哪条还有效。
- 技能写死实现：`SKILL.md` 里贴大段代码，代码一改技能就过期；应当只写"决策与坑"，代码放 `references/`。
- 把闸门写成"风格警察"：闸门应该拦**架构性错误**，格式交给 formatter。

---

## Sources

## Sources

[1] https://agents.md — AGENTS.md — open format
[2] https://github.github.com/spec-kit — GitHub Spec Kit — Spec-Driven Development
[3] https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills — Anthropic — Agent Skills
[4] https://www.infoq.cn/article/CEaf1AP69tbwBDFxkmeh — InfoQ — Codex 百万行产品实践（OpenAI harness engineering 中文摘要）
[5] https://www.thoughtworks.com/en-us/insights/blog/architecture/engineering-the-harness-a-practical-pattern-for-reliable-coding-agents — Thoughtworks — Engineering the harness
[6] https://martinfowler.com/articles/exploring-gen-ai/context-engineering-coding-agents.html — martinfowler.com — Context Engineering for Coding Agents
[7] https://github.com/bmad-code-org/BMAD-METHOD — BMAD-METHOD
[8] https://www.continuous-architecture.org/practices/fitness-functions — Continuous Architecture — Fitness Functions
   （历史文件按运行追加：本地跑 `--record` 入库；CI 里跑一次作为工件上传，不自动提交，避免仓库被数据膨胀。）
