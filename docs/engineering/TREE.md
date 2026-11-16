---
id: engineering-tree
type: meta
status: active
system: meta
owner: hermes
updated: 2026-11-16
review_by: 2027-05-31
tracks: [test_tree_placement, engineering-worktree]
source_of_truth: true
topic: repo-tree
---

# TREE — 文件放哪的判据

> 这份文件只回答一个问题：**新文件该放哪**、以及**为什么**。
> 它不重复 `CONSTITUTION.md`（不可协商的红线）、不重复 `ARCHITECTURE.md`（平面与依赖方向）、
> 不重复 `doc-lifecycle.md`（文档元数据与状态机）。三者管"写成什么样"，本文管"放在哪里"。
> 改写门槛：动 §2 决策树或 §6 闸门 = 闸门变更，同 PR 必须带反向校验（见 §8）。

## 0. 为什么需要它（三条实测，不是感想）

1. **规范写了目录，但没人执行，也没人发现**：`doc-lifecycle.md` §2 要求 `docs/{spec,manual,adr,research,runbook}/`，
   实测这五个目录**一个都不存在**；`docs_lifecycle.py --check` 依然 0 error —— 它校验 frontmatter 与链接，不校验位置。
2. **一次结构整理只做了一半**：`docs/cleanup/structure-proposal.md`（2026-10-23）的 M1–M6/M9 已执行，
   **M7（`tests/` 根级归位）与 M8（base docs 根级 40 篇）从未开始**，于是 `T-CityLite.base/tests/` 根仍平铺 29 个文件。
3. **同名不同义**：`docs/agent/` 与 `T-CityLite.base/docs/agent/` 各有一份 `STATUS.md`/`DESIGN.md`；
   `ORGANIZATION_GUIDE.md` 名字像目录规范，实际是职业/帮派五级模板。

结论：缺的不是口号，是**判据**。判据不写成机器可判的，就一定会退化成历史遗留。

## 1. 三个根

| 根 | 谁读 | 放什么 | 不放什么 |
|---|---|---|---|
| 仓库根 | 人 + 所有工具 | 六个入口文件（README / AGENTS / CONTRIBUTING / SECURITY / CHANGELOG / PROJECT_PROGRESS）、启动脚本（`start.*`）、`docs/ tests/ tools/ archive/ T-CityLite.base/` | 生成物、临时脚本、单主题长文 |
| `T-CityLite.base/` | FXServer（cwd 在这里） | `resources/ configs/ migrations/ tests/ docs/` —— 与服务器生命周期一致的东西 | 跨资源的顶层规划（属于 `docs/`） |
| `docs/` | 人 | 跨资源、给人读的：系统设计、调研、审计、路线图、规范 | 单个资源的内部说明（属于 `T-CityLite.base/docs/`） |

## 2. 新文件放哪（自上而下，第一条命中即用）

```
新增一个文件
├─ CI/钩子会执行的可执行检查？        → T-CityLite.base/tests/ 根（仅限 §3 白名单那 10 个名字）
├─ pytest 用例？                     → T-CityLite.base/tests/{unit,architecture,agent,integration}/
│                                      （测 tools/ 的 → 仓库根 tests/tools/）
├─ 只能在游戏内/服务端控制台 exec？    → T-CityLite.base/tests/game/
├─ 独立 lua5.4 脚本（io.open / arg[] / 无 FiveM 全局）？→ T-CityLite.base/tests/lua/
├─ Node + mysql2 之类的外部冒烟？      → T-CityLite.base/tests/js/
├─ 给 FXServer 跑的资源？             → resources/[custom]（自研）/ [standalone]（第三方）/ [system]（自研基础设施）
├─ 开发或运维脚本？                   → tools/dev（闸门与开发）/ tools/ops（运维）/ tools/oneoff（一次性）
├─ 文档？
│   ├─ 描述"现在是什么/怎么做"，随代码变 → T-CityLite.base/docs/<子目录>/
│   ├─ 某版本的历史交付物（audit/final）→ T-CityLite.base/docs/archive/
│   └─ 跨资源、给人读的                → docs/<system>/（type 见 doc-lifecycle §1）
└─ 一次性验证脚本？                   → tools/oneoff/（用完删，别留根目录）
```

**为什么 `game/` 与 `lua/` 要分开**：`game/` 里的东西只能在 FXServer 控制台 `exec`，`lua/` 里的能直接
`lua5.4 <file>` 跑。混在一起之后，"这个脚本能不能在本地跑"就重新变成猜测——而这类猜测的成本由每个新人重付一次。

## 3. `T-CityLite.base/tests/` 根的白名单（只有这 10 个名字）

| 文件 | 为什么必须留根 |
|---|---|
| `check_cfgs.py` / `check_dependencies.py` / `check_bus_wiring.py` / `check_db_schema.py` / `check_lua_syntax.py` / `light_lint.py` | `BASE_DIR = dirname(dirname(__file__))` 写死两层；下移一层会静默变成"0 个 CFG"，不报错 |
| `conftest.py` | `tests/unit`、`tests/integration` 的 fixture 源 |
| `run_all.py` | `.githooks/pre-commit` 与文档按裸名调用 |
| `p0_sources.py` | `TESTS_DIR = Path(__file__).parent`，再 `parent` 取仓库 |
| `run_db_tests.sh` | `ROOT=$(dirname)/..` 后拼 `tests/fixtures/...` |

新增名字进这张表 = 改本文 + 改闸门白名单（同 PR，带理由）。
新增 `.lua` / `.js` 到 `tests/` 根 **一律禁止**——它们有 `game/`、`lua/`、`js/` 三个去处。

## 4. 命名禁令（全部可机器判定）

| 禁止 | 原因 | 判据 |
|---|---|---|
| `_v2` `_v3` `-final` `-new` `副本` | 版本归 git，不归文件名 | 正则（`doc-lifecycle.md` §3 同义） |
| 文件名带日期但 `type` 不是 `audit`/`research` | 日期只对快照有意义 | frontmatter `type` 与文件名 `\d{4}-\d{2}-\d{2}` 交叉校验 |
| 提交可再生产物（`*.out`、生成的 JSON） | 会过期且会撒谎 | `.gitignore` + `git ls-files` |
| 同一主题在两个文档根各一份 | 读者不知信谁 | 同名文件必须有一份标 `superseded_by` |
| 名字与内容不符 | `ORGANIZATION_GUIDE.md` 的教训 | **不可判定** → 人审，不进闸门 |

## 5. 两个文档根的判据

- **`T-CityLite.base/docs/`**：随代码一起变，读者是改代码的人（工程规范、资源设计、agent 契约、版本验收报告）。
- **`docs/`**：跨资源，读者是规划/运营/产品（系统设计、调研、审计、路线图、导航）。
- 生成物例外：`docs/INDEX.md`、`T-CityLite.base/docs/agent/TOOLS.md` 由脚本写，**位置不由人决定，不要手改**。

## 6. 闸门：`test_tree_placement.py` 判什么

只判**本次新增/重命名**的文件，存量一律不判（存量有历史原因，见 §7）。实现要点：
`git diff --name-only --diff-filter=AR <base>...HEAD`，PR 用 `GITHUB_BASE_REF`，本地退回 `HEAD^`；
CI 里拿不到 base ref 时**fail-closed**（否则它就是一个可绕过的门）。

**它拦不住什么（必须知道，否则会高估安全感）**：

1. **存量**：现有 40 篇根文档、18 个根级 lua 永远不会被它判红。
2. **内容错位**：它知道文件在哪，不知道这份文档到底是 `spec` 还是 `manual`。
3. **同日放宽规则**：同一个 PR 里改白名单或改测试本身，它无法判断"规则被放宽了"。需要 review 兜底。
4. **直接 push 多提交**：没有 PR base ref 时只能看最后一次提交。
5. **生成物位置**：`docs/INDEX.md` 等由生成器决定，不由它判。
6. **"一次性"语义**：`tools/oneoff/` 之外的脚本是否真长期维护，机器判不了。

## 7. 存量豁免（不判，已登记）

- `T-CityLite.base/tests/` 根现有 18 个 lua / 2 个 js：M7 搬迁中，批次见 `docs/plan/`；迁完后此条删除。
- `T-CityLite.base/docs/` 根现有 40 篇：M8 处理，其中 20 篇 `audit/final` 归档、10 篇版本名但 `status: active` 需先改状态。
- `docs/engineering/2026-11-*`、`docs/archive/**`：历史快照，绝对路径不回溯改写（理由见 `WORKTREE.md` §3）。
- `tools/agent_*.py` + `agent_tools.json`：280 行引用 / 20 个文件，生成物路径写死。

## 8. 改这份文件的规矩

- 动 §2 决策树、§3 白名单、§6 闸门范围 → **闸门变更**，同 PR 必须带反向校验（喂错误形状，断言变红）。
- 新增豁免 → 必须写 owner 与到期日，否则下一个季度没人敢动它。
- 收集不到判据的规则不要写进来（例如"资源必须自研才进 `[custom]`"——没有机器可读标记，写进来只会制造假阳性）。
