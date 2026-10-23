# T-City 仓库 `.gitignore` 审计提案

> 审计对象：`/home/swk/Documents/deepseek-harness/default-workspace/T-City-agent`，分支 `chore/repo-cleanup`（基线 `99e0c27`）。
> 方式：只读分析。本文件只是提案，**未修改 `.gitignore`、未 `git rm`、未删除/移动任何文件、未 commit**。
> 关联 worktree：`../T-City`（`dev`）与本 worktree 共享同一仓库，`.gitignore` 的改动会同时影响两边；运行时目录（`alpine/`、`T-CityLite.base/cache/`、`.env`、`server.cfg`）只存在于主 worktree。

## 结论摘要（10 行）

1. 工作区本身没有“未跟踪且未忽略”的噪音：审计开始时两处 worktree 的 `git status --porcelain` 均为空（本提案文件除外）；磁盘噪音只有 10 / 13 个已忽略条目（缓存/运行时目录）。
2. 真正的问题是反向的：**16 个已跟踪文件仍命中 ignore 规则**（15 个 NUI/构建产物 + `default/config.json`），以及 **`admins.json` 被跟踪且完全未被忽略**。
3. 最高危安全项：`admins.json` 含 txAdmin 的 bcrypt `password_hash` 与 FiveM `identifier`，且已经进入 git 历史（`1e39c45`、`106ba48`），仅加 ignore 不能消除泄露。
4. 最高危功能项：根规则 `dist/` 与 `build/` 过宽，dashboard 的 hash 文件名每次构建都会变；新文件会被 `nui/.gitignore` 静默忽略 → 线上 dashboard NUI 白屏。
5. `custom-phone/html/` 是构建产物但**必须入库**（7 个文件，`fxmanifest.lua:28` 的 `ui_page 'html/index.html'`）；仓库共有 **614 个** `html/` NUI 文件，绝不能出现裸 `html/` 规则。
6. 4 个本地/生成根文件应移出索引：`admins.json`、`default/config.json`、`simulation_report.json`、`fxmanifest_inventory.json`（最后一个需先确认无人引用）。
7. 缺失的规则：`.pytest_cache/`（现在只靠 pytest 自动写的内部 `.gitignore`，clone 后若残留缓存就会冒出来）、`.env.*` 变体、`*.log`、coverage/mypy/venv、`*.sql.gz`、`*.dump`、`*.orig/*.rej`。
8. 冗余/失效 23 行：`cache/`、`logs/`、`yarn-cache/` 三重重复；`logs` 的两条否定规则因“父目录被排除”而永久失效；裸 `config.json` 误伤未来资源配置；`QBCore_CDB34E.base/`、`skills/`、`AI_SYNC_MEMO.md` 是死路径；第 128 行 `logs/` 与第 41 行重复。
9. CI 依赖的 `T-CityLite.base/tests/fixtures/tcity_schema.sql`、`custom-director/shared/agent_tools.lua`、`docs/agent/TOOLS.md` 均**未被忽略**，安全；它们是生成物但必须继续跟踪。
10. 只改根 `.gitignore` 不够：`tcity-dashboard/nui/.gitignore`、`oxmysql/.gitignore` 里的 `dist` / `fxmanifest.lua` 优先级更高，必须同步修，否则 negation 不生效。

---

## 表格 A：建议新增的 ignore 规则（根 `.gitignore`）

| # | 模式 | 原因 | 当前是否被跟踪 | 处理 |
|---|------|------|----------------|------|
| A1 | `/admins.json` | txAdmin 管理员文件：含 bcrypt 口令哈希 + FiveM `identifier`，属凭据/PII | **是**（`git ls-files admins.json` → `admins.json`） | `git rm --cached admins.json`；**同时改 txAdmin 密码**；历史清理另议 |
| A2 | `/default/config.json` | txAdmin 本地配置，含机器绝对路径 `F:/t-city/...`，非源码 | **是** | `git rm --cached default/config.json`；替代下面要删的裸 `config.json`（B16） |
| A3 | `/simulation_report.json` | `tools/oneoff/sandbox_simulator.py` 的默认输出（`--output` 默认值），一次模拟的结果快照 | **是** | `git rm --cached simulation_report.json` |
| A4 | `/fxmanifest_inventory.json` | 64KB 自动生成的资源清单（路径用 `\` 分隔），仓库内无生成脚本、无任何文档引用 | **是** | 先向团队确认；确认后 `git rm --cached`。若确认要留档，则不要加这条规则 |
| A5 | `.pytest_cache/` | pytest 缓存。当前仅靠 `.pytest_cache/.gitignore`（内容为 `*`）自忽略，该文件由 pytest 生成而非仓库规则，脆弱 | 否 | 仅加规则 |
| A6 | `.env*` + `!.env.example` | 现有规则只覆盖 `.env`、`.env.local`；`.env.production`、`.env.development.local` 等**未被忽略**（见证据 E3） | 否（`.env.example` 已跟踪，靠 `!` 保留） | 仅加规则（替换 B14/B15 两行） |
| A7 | `*.log` | 现在只忽略 `logs/` 目录，根目录或资源目录下单独的 `npm-debug.log`、`*.log` 不会被忽略 | 否 | 仅加规则 |
| A8 | `.coverage`、`coverage.xml`、`htmlcov/` | Python 覆盖率产物（本地跑 pytest-cov 即生成） | 否 | 仅加规则 |
| A9 | `.mypy_cache/`、`.ruff_cache/`、`.tox/` | Python 静态检查缓存 | 否 | 仅加规则 |
| A10 | `.venv/`、`venv/` | 本地虚拟环境 | 否 | 仅加规则 |
| A11 | `*.orig`、`*.rej` | 合并/打补丁残留 | 否 | 仅加规则 |
| A12 | `*.sql.gz`、`*.dump`、`/backups/` | DB dump/备份；**不要**加 `*.sql`（会误伤 32 个已入库的 schema/migration：15 个 migrations + 17 个资源 SQL） | 否 | 仅加规则 |
| A13 | `server.cfg.*` + `!server.cfg.template` | 用通配覆盖 `.bkp`/`.full-backup`/`.lite-draft` 及未来变体；`!` 必须在通配之后 | 否 | 仅加规则（替换 B2–B4 三行） |
| A14 | `.eslintcache`、`.stylelintcache` | 前端 lint 缓存 | 否 | 仅加规则 |
| A15 | `*.iml`、`.history/` | JetBrains / VS Code 本地历史 | 否 | 仅加规则 |
| A16 | `**/web/dist/`、`**/ui/dist/` | 只忽略真正可丢弃的 Vite 输出；**替换**裸 `dist/`、`build/`（B12/B13），避免误伤 menuv/dashboard/oxmysql 的已入库产物 | 否 | 仅加规则（替换 B12/B13） |

**嵌套 `.gitignore` 的 2 处修正（不是新增根规则，但必须一起做）：**

| # | 文件 | 修改 | 原因 |
|---|------|------|------|
| A17 | `T-CityLite.base/resources/[standalone]/oxmysql/.gitignore` | 在第 2、90 行之后各补 `!fxmanifest.lua`、`!dist/`、`!dist/build.js`（或直接删掉那两行） | 该文件自己忽略了 `fxmanifest.lua` 与 `dist`，但 `oxmysql/fxmanifest.lua:20` 是 `server_script 'dist/build.js'`，两者都已入库且服务器直接加载 |
| A18 | `T-CityLite.base/resources/[system]/tcity-dashboard/nui/.gitignore` | 删除 `dist` 行（或改成 `!dist/`） | 该目录的 `dist/` 是提交进仓库的 NUI；更深层规则会压过根目录的 negation |

---

## 表格 B：建议删除/替换的 ignore 行

“行”以当前 128 行的 `.gitignore`（commit `99e0c27`）为准。

| 行 | 规则 | 原因 |
|----|------|------|
| B1 | 13 `!server.cfg.template` | 冗余：`server.cfg` 是精确匹配，不会匹配 `server.cfg.template`（临时仓库实测：只写 `server.cfg` 时 template 未被忽略）。删除；如果采用 A13 的 `server.cfg.*`，则 negation 必须保留并移到通配之后 |
| B2–B4 | 27–29 `T-CityLite.base/server.cfg.bkp` / `.full-backup` / `.lite-draft` | 三条硬编码路径，当前两个 worktree 都没有这些文件；用 A13 `server.cfg.*` 统一覆盖 |
| B5 | 37 `**/cache/` | 与 36 行 `cache/` 完全重复（无前导斜杠的 `cache/` 本就匹配任意层级） |
| B6 | 38 `T-CityLite.base/cache/` | 同上，被 36 行覆盖；主 worktree 的 464MB cache 只靠 36 行也会被忽略 |
| B7 | 42 `**/logs/` | 与 41 行 `logs/` 重复 |
| B8 | 43 `T-CityLite.base/logs/` | 同上 |
| B9 | 44 `!T-CityLite.base/logs/test_reports/` | **无效**：父目录已被 41 行 `logs/` 排除，不能再 re-include 子路径；且两个 worktree 都没有 `test_reports/` |
| B10 | 45 `!**/logs/*.md` | **无效**：同上；实测 `T-CityLite.base/logs/foo.md` 仍命中 `logs/` |
| B11 | 49 `**/yarn-cache/` | 与 48 行 `yarn-cache/` 重复 |
| B12 | 68 `dist/` | **过宽**：误伤已入库的 `menuv/dist/`（7）、`tcity-dashboard/nui/dist/`（5）、`oxmysql/dist/build.js`；dashboard 的 hash 文件名每次构建都变，新文件会被静默忽略（见证据 E4） |
| B13 | 69 `build/` | **过宽**：误伤已入库的 `oxmysql/web/build/index.html`；未来 `web/build/` 源码目录也会被吞 |
| B14 | 95 `.env` | 过窄，改为 A6 的 `.env*` + `!.env.example` |
| B15 | 96 `.env.local` | 同上（`.env.production` 当前完全没被忽略） |
| B16 | 102 `config.json` | **过宽**：匹配任意层级的 `config.json`，会静默吞掉未来资源的 `config.json`（QBCore 生态常见配置名）；改为 A2 的 `/default/config.json` |
| B17 | 107 `QBCore_CDB34E.base/` | 死路径：两个 worktree 都没有该目录；实际保留的是 `QBCore_Lite_versions/`（已跟踪 30 个文件） |
| B18 | 110 `skills/` | 死路径：两个 worktree 均不存在 |
| B19 | 111 `AI_SYNC_MEMO.md` | 死路径：两个 worktree 均不存在 |
| B20 | 128 `logs/` | 与 41 行重复；实测任意 `logs/` 路径最终都命中第 128 行（后者覆盖前者），删除后行为不变 |

**嵌套 `.gitignore` 的删除项：**

| 位置 | 规则 | 原因 |
|------|------|------|
| B21 | `tcity-dashboard/nui/.gitignore:11` `dist` | 与已入库的 5 个 `nui/dist` 文件矛盾；深层规则优先于根目录，必须在本地删/negate |
| B22 | `oxmysql/.gitignore:2` `fxmanifest.lua` | `oxmysql/fxmanifest.lua` 已跟踪，且是资源清单，不能忽略 |
| B23 | `oxmysql/.gitignore:90` `dist` | `oxmysql/dist/build.js` 已跟踪且是 `server_script`，不能忽略 |

> 合计：删除/替换 **23 行**（根 20 行 + 嵌套 3 行），按 21 组列出（根 18 组 + 嵌套 3 组）。

---

## 表格 C：必须保留跟踪的“生成物”

| # | 路径 | 文件数 | 为什么必须入库 | 证据 |
|---|------|--------|----------------|------|
| C1 | `T-CityLite.base/resources/[custom]/custom-phone/html/` | 7 | **重点：这是构建产物，但 FXServer 直接读取**；`ui_page 'html/index.html'`，`files` 里还列了 `html/assets/*`。忽略或删除 → 线上手机 NUI 直接空白。Vite 输出文件名稳定（`entryFileNames: assets/[name].js`），所以可安全入库 | `fxmanifest.lua:28,31-33`；`vite.config.ts` `outDir: '../html'`；`git ls-files | grep custom-phone/html/` 命中 7 个 |
| C2 | `T-CityLite.base/resources/[system]/tcity-dashboard/nui/dist/` | 5 | `ui_page 'nui/dist/index.html'`，服务器直接读取；`index.html` 引用 `assets/index-CDQpKmmx.js` / `index-D6zbaQGC.css`。**hash 文件名每次构建都变**，忽略规则会让重建后的新 hash 文件进不了库 | `fxmanifest.lua:21,23-25`；`dist/index.html` 内的引用；`git ls-files` 5 个 |
| C3 | `T-CityLite.base/resources/[standalone]/menuv/dist/` | 7 | `ui_page 'dist/menuv.html'`，NUI 运行时资源；当前被根 `dist/` 命中（靠已跟踪才没丢） | `menuv/fxmanifest.lua:24-31`；`git ls-files` 7 个 |
| C4 | `T-CityLite.base/resources/[standalone]/oxmysql/dist/build.js`、`fxmanifest.lua`、`web/build/index.html` | 3 | `server_script 'dist/build.js'`；`web/build/index.html` 是已入库的 web 入口；三者分别被嵌套 `dist` / `fxmanifest.lua` 和根 `build/` 命中 | `oxmysql/fxmanifest.lua:20`；`git ls-files` 3 个 |
| C5 | `T-CityLite.base/resources/[custom]/custom-director/shared/agent_tools.lua` | 1 | 由 `tools/agent_tools.py --write` 生成，但被测/被 CI 当源文件校验；缺失会让 `test_agent_tools.py` 与 `agent_tools.py --check` 失败 | `tools/agent_tools.py:30-38`；`tests/agent/test_agent_tools.py:394-399` |
| C6 | `T-CityLite.base/docs/agent/TOOLS.md` | 1 | 同上，是工具注册表的生成文档，CI 依赖其与 `tools/agent_tools.json` 一致 | `.github/workflows/ci.yml:32-33`；`git check-ignore` 未命中 |
| C7 | `T-CityLite.base/tests/fixtures/tcity_schema.sql` | 1 | `db-schema` job 用它导入 MariaDB 后再跑全量 pytest；被忽略则 CI 直接挂 | `.github/workflows/ci.yml:177-178`；`git check-ignore` 未命中 |

> 另：全仓 **614 个** `html/` 文件（qb-inventory 295、qb-phone 47、custom-phone 7 等）都是资源 NUI。提案刻意不引入任何 `html/` 或 `assets/` 规则；清理脚本也不要用 `git clean -X` 去“清构建物”，NUI 目录必须保留。

**必须保留、但不要误当“生成物”忽略的源文件：** `tools/agent_tools.json`（工具注册表的 **source of truth**，不是生成物）、`package-lock.json`、`T-CityLite.base/migrations/*.sql`、`T-CityLite.base/resources/**/*.sql`（32 个 schema/migration 是源码）。

---

## 建议的 `.gitignore` 最终 diff（片段）

### 根 `.gitignore`

```diff
@@ Layer 1
 server.cfg
-!server.cfg.template
+
+# txAdmin 管理凭据（bcrypt 口令哈希 + FiveM identifier）
+/admins.json
+# 本地 txAdmin 配置（含机器绝对路径）
+/default/config.json
@@
-# 备份配置 (包含与 server.cfg 相同的敏感数据)
-T-CityLite.base/server.cfg.bkp
-T-CityLite.base/server.cfg.full-backup
-T-CityLite.base/server.cfg.lite-draft
+# 备份配置（通配；template 例外必须放在通配之后）
+server.cfg.*
+!server.cfg.template
@@
 # FiveM 服务器缓存
 cache/
-**/cache/
-T-CityLite.base/cache/
 
 # 运行时日志
 logs/
-**/logs/
-T-CityLite.base/logs/
-!T-CityLite.base/logs/test_reports/
-!**/logs/*.md
+*.log
 
 # Yarn 缓存
 yarn-cache/
-**/yarn-cache/
@@
-# NUI/Vite build
-dist/
-build/
+# NUI/Vite 构建中间产物。不要写裸 dist/、build/：
+# menuv/dist、tcity-dashboard/nui/dist、oxmysql/web/build 均已入库，
+# 是 FXServer 直接读取的 NUI，忽略会让重建后的 hash 文件静默丢失。
+**/web/dist/
+**/ui/dist/
 .nuxt/
 .next/
 .svelte-kit/
@@
-.env
-.env.local
+.env*
+!.env.example
 *.pyc
 __pycache__/
+.pytest_cache/
+.mypy_cache/
+.ruff_cache/
+.tox/
+.venv/
+venv/
+.coverage
+coverage.xml
+htmlcov/
+.eslintcache
+.stylelintcache
 .reasonix/
 
 # txAdmin 运行时数据（含 dashboard token）
-config.json
 T-CityLite.base/default/
 T-CityLite.base/txData/
 
-# 原始 QBCore base（只追踪修改后的 T-CityLite）
-QBCore_CDB34E.base/
-
-# 技能 / AI 辅助文件（开发端本地配置）
-skills/
-AI_SYNC_MEMO.md
-
@@ Layer 6
 *.bak
+*.orig
+*.rej
+*.sql.gz
+*.dump
+/backups/
+*.iml
+.history/
+
+# 生成报告（按需；确认后再 rm --cached）
+/simulation_report.json
+/fxmanifest_inventory.json
 
 # NUI 冒烟测试截图（本地生成）
 T-CityLite.base/tests/nui/artifacts/
-
-# 服务器启动器日志
-logs/
```

### `T-CityLite.base/resources/[system]/tcity-dashboard/nui/.gitignore`

```diff
-node_modules
-dist
-dist-ssr
+node_modules
+# dist 是提交进仓库的 NUI（fxmanifest ui_page 'nui/dist/index.html'），不得忽略
+dist-ssr
```

### `T-CityLite.base/resources/[standalone]/oxmysql/.gitignore`

```diff
 .yarn.installed
-fxmanifest.lua
+# 运行时入口：必须入库
+!fxmanifest.lua
@@
-dist
+# 运行时入口：必须入库
+!dist/
+!dist/build.js
```

> 注意：根 `.gitignore` 里的 negation 优先级低于更深的嵌套 `.gitignore`，所以 C2/C4 必须改嵌套文件，单改根文件无效。

---

## 风险与验证

### 风险

1. **`admins.json` 已在历史里**（`1e39c45`、`106ba48`）。`git rm --cached` 只停止未来跟踪，历史仍可检出 bcrypt 哈希与 identifier。必须：改 txAdmin 密码 → 移除索引 → 视仓库可见性决定是否用 `git filter-repo`/BFG 清历史并强推。
2. **`/fxmanifest_inventory.json` 是否有人离线引用未知**（仓库内无引用、无生成脚本）。先问团队，别直接 `rm --cached`。
3. **删除裸 `dist/`/`build/` 后可能冒出别的资源构建噪音**：用 `**/web/dist/`、`**/ui/dist/` 兜底，并在改完后跑一次全量构建 + `git status` 验证；不要顺手加 `**/dist/` 把 C2/C3 打死。
4. **`.env*` 的 negation 顺序**：`!.env.example` 必须紧跟在 `.env*` 之后，且 `.env.example` 已跟踪；否则新人 clone 后模板文件被忽略。
5. **`server.cfg.*` 会匹配 `server.cfg.template`**：必须保留 `!server.cfg.template` 且放在通配后面（B1 的删除只在“不采用 A13”时成立）。
6. **两个 worktree 共享同一套 ignore 规则**：在 `T-City-agent` 改完后，`../T-City` 的 `alpine/`、`cache/`、`.env`、`server.cfg` 仍应保持 ignored，需要复验。
7. **NUI 构建流程**：dashboard/custom-phone 的 `npm run build` 会得到新 hash/新内容；提交时必须 `git add -f` 或确保规则已放开，否则“本地能跑、线上白屏”。

### 验证命令（建议改完后逐条跑）

```bash
cd /home/swk/Documents/deepseek-harness/default-workspace/T-City-agent

# 1) 目标：跟踪文件不应再命中 ignore（输出应为空；template 的 negation 不算）
git ls-files -z | git check-ignore --no-index --stdin -z | tr '\0' '\n'

# 2) 关键 NUI 产物必须全部“NOT ignored”
for f in \
  "T-CityLite.base/resources/[custom]/custom-phone/html/index.html" \
  "T-CityLite.base/resources/[custom]/custom-phone/html/assets/index.js" \
  "T-CityLite.base/resources/[system]/tcity-dashboard/nui/dist/index.html" \
  "T-CityLite.base/resources/[standalone]/menuv/dist/menuv.html" \
  "T-CityLite.base/resources/[standalone]/oxmysql/dist/build.js" \
  "T-CityLite.base/resources/[standalone]/oxmysql/fxmanifest.lua"; do
  printf '%-90s ' "$f"; git check-ignore -v --no-index "$f" || echo "OK (not ignored)"
done

# 3) 新增规则应命中
git check-ignore -v --no-index .env.production admins.json .pytest_cache/x \
  foo.sql.gz backup.dump htmlcov/index.html

# 4) 不应误伤：未来资源 config.json / 源码目录必须是 NOT ignored
git check-ignore -v --no-index "T-CityLite.base/resources/[custom]/new-resource/config.json" \
  || echo "OK: config.json 不再被全局吞掉"
git check-ignore -v --no-index "T-CityLite.base/resources/[custom]/future/web/src/main.ts" \
  || echo "OK: 源码目录未被 dist/build 规则命中"

# 5) 噪音面：确认只剩缓存/运行时目录
git status --porcelain
git status --porcelain --ignored

# 6) CI 关键文件仍在库里（[custom] 用 literal pathspec 避免 glob 歧义）
git ls-files \
  "T-CityLite.base/tests/fixtures/tcity_schema.sql" \
  ":(literal)T-CityLite.base/resources/[custom]/custom-director/shared/agent_tools.lua" \
  "T-CityLite.base/docs/agent/TOOLS.md"
```

### 证据摘录

```text
# E1: 当前 16 个被跟踪文件仍命中 ignore 规则（15 构建物 + default/config.json）
$ git ls-files -z | git check-ignore --no-index --stdin -z | tr '\0' '\n' | wc -l
16

# E2: admins.json 已跟踪但完全没被忽略
$ git ls-files admins.json
admins.json
$ git check-ignore -v --no-index admins.json || echo "NOT IGNORED"
NOT IGNORED

# E3: .env 规则过窄
$ git check-ignore -v --no-index .env.production        # 无输出
NOT IGNORED
$ git check-ignore -v --no-index .env.local
.gitignore:96:.env.local        .env.local

# E4: dashboard 新 hash 文件会被静默忽略（深层规则优先）
$ git check-ignore -v --no-index \
    "T-CityLite.base/resources/[system]/tcity-dashboard/nui/dist/assets/index-NEWHASH.js"
T-CityLite.base/resources/[system]/tcity-dashboard/nui/.gitignore:11:dist  .../index-NEWHASH.js

# E5: logs negation 失效
$ git check-ignore -v --no-index T-CityLite.base/logs/test_reports/report.json
.gitignore:128:logs/    T-CityLite.base/logs/test_reports/report.json

# E6: .pytest_cache 只靠自身内部的 .gitignore（非仓库规则）
$ git check-ignore -v --no-index .pytest_cache       # 无输出
$ cat .pytest_cache/.gitignore
# Created by pytest automatically.
*

# E7: 无未跟踪噪音；磁盘忽略项仅缓存/运行时
$ git status --porcelain | grep '^??' || echo none
none
$ git -C ../T-City status --porcelain --ignored | grep '^!!' | wc -l
13

# E8: 资源 SQL 是源码，不是 dump（不要加 *.sql）
$ git ls-files | grep -c '\.sql$'
32
```

---

**新增**：16 组根规则（29 个 pattern，A4 为待确认项）+ 2 处嵌套修正
**删除**：23 行（根 20 + 嵌套 3，按 21 组列出）
**被跟踪生成物**：4 个应卸载（admins / default-config / 2 份报告）；25 个必须保留（22 个 NUI/运行时产物 + 3 个 CI 生成物）
**最危险**：`admins.json` 被跟踪，含 bcrypt 口令哈希 + FiveM identifier，且已进入 git 历史
**先做**：加 `/admins.json` 规则并 `git rm --cached admins.json`，同步改 txAdmin 密码（历史清理另开任务），再改两处嵌套 `dist`
