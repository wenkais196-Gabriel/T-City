# T-City 仓库删除审计提案

> **分支**：`chore/repo-cleanup`（= `dev` = `master`，`99e0c27`）
> **审计日期**：2026-10-23
> **性质**：只读分析。**本文件只写提案，未删除/移动任何文件，未 commit，未触碰 FXServer。**
> **审计对象**：`/home/swk/Documents/deepseek-harness/default-workspace/T-City-agent`
> **基线**：6216 个跟踪文件；工作区约 679M（`T-CityLite.base/resources` 676M）；`.git` pack 345.27 MiB。

---

## 0. 结论摘要

1. **手机资源只有一个在跑**：`custom-phone` 在 `configs/modules/custom.cfg:20` 被 `ensure`；`qb-phone` 在**任何 CFG / server.cfg 中都没有 ensure**（4 处 `ensure qb-phone` 全部是上游 README 的安装说明）。
2. **但 `qb-phone` 不是“安全删”**：排除自身后仍有 **63 个文件 / 237 处引用 / 25 个 Lua 文件**，其中 **8 个已启用资源**在调用它的事件或导出。删除只是把“当前已静默失效”变成“永久没有实现”，正确顺序是**先迁移调用，再归档**。
3. **仓库里不存在** `server_archive`、被跟踪的 `cache/`、`logs/`、`node_modules`、数据库 dump、孤儿 hash bundle；`T-CityLite.base/cache/` 在本 worktree 根本不存在（只在 `T-City/` 运行工作区，464M，已被 gitignore）。
4. **真正安全删的只有 2.2M**：未跟踪的 pytest/`__pycache__` 缓存 1.3M + 57 个资源内上游 `.github/` 样板 0.84M + 2 个生成/空文件 64K。
5. **需确认组约 28M**，最大单块是 `[system]/monitor` 13M（txAdmin 集成，倾向保留）；最值得回收的是 `qb-phone` 3.2M。
6. **安全发现（优先处理）**：`admins.json` 被跟踪，含 txAdmin 管理员 **bcrypt 密码哈希**，且不在 `.gitignore` 中；应 `git rm --cached` + 轮换密码，而不是普通清理。

---

## 1. 审计口径与证据来源

| 需要证明 | 使用命令 | 说明 |
|:---|:---|:---|
| 是否被跟踪 | `git ls-files <path>` | 0 = 未跟踪 |
| 引用数（排除自身） | `git grep -l -I '<path>'` / `git grep -o -I '<path>'` | 只统计**已跟踪文本文件**；排除候选自身目录 |
| 是否被 ensure | `git grep -n -E '^\s*ensure\s+<name>'`（另跑 `'^\s*start\s+<name>'`）+ `grep -rn <name> configs/` | 同时检查 `server.cfg.template` |
| 运行配置 | `grep -n 'qb-phone' ../T-City/T-CityLite.base/server.cfg` | 只读、只匹配关键字，未读取/输出任何密钥 |
| 忽略状态 | `git status --ignored --porcelain` | 区分“未跟踪”与“被忽略” |
| 体积 | `du -sh` | 工作区占用；删除已跟踪文件**不会**缩小 `.git` 历史 |
| 分支状态 | `git branch --no-merged`、`git rev-list --count` | 只给建议，不执行 |

限制：`git grep` 不覆盖未跟踪的 `server.cfg` / `configs` 之外的运行时文件；文档引用是文本匹配，不等于运行时依赖。

---

## 2. 重点结论：`qb-phone` vs `custom-phone`

### 2.1 对照

| 维度 | `[qb]/qb-phone` | `[custom]/custom-phone` |
|:---|:---|:---|
| 是否被 ensure | **否**（0 条 CFG；4 条 `ensure qb-phone` 全在 README 安装说明） | **是**：`configs/modules/custom.cfg:20` |
| 运行中的 `server.cfg` | `grep qb-phone` 无命中（`T-City/` 只读检查） | 通过 `exec configs/modules/custom.cfg` 加载 |
| `fxmanifest` 依赖 | 0 个资源声明依赖它 | `custom-phone` 被 `custom.cfg`、文档、测试引用 |
| 仓库引用 | 81 个文件命中，排除自身 **63 个文件 / 237 处** | 大量引用，含 3 套测试（`phone_sms.lua`、`test_phone_db_contract.py`、NUI 测试） |
| 上游状态 | `docs/01_resource_inventory.md:123`：“v0.2 deferred，旧手机系统，**已被 custom-phone 替代**”；`:252` 替代表同样结论 | 当前手机系统，`AGENTS.md:16,140-151` |
| 兼容层 | — | `custom-phone` 中 `sendNewMail` / `AddTransaction` / `addPoliceAlert` 等兼容实现 = **0** |
| 体积 | 3.2M（html 3.0M + 63 文件） | 980K（59 个跟踪文件） |

### 2.2 关键证据：8 个**已启用**资源仍在调用 `qb-phone`

| 调用方（已启用） | 位置 | 调用内容 | 启用位置 |
|:---|:---|:---|:---|
| `qb-core` | `server/services/economy_service.lua:54` | `qb-phone:client:RemoveBankMoney` | `core.cfg:17` |
| `qb-cityhall` | `server/main.lua:235` | `exports['qb-phone']:sendNewMailToOffline` | `custom.cfg:41` |
| `qb-cityhall` | `client/main.lua:348` | `qb-phone:server:sendNewMail` | 同上 |
| `qb-weapons` | `server/main.lua:87` | `exports['qb-phone']:sendNewMailToOffline` | `player.cfg:23` |
| `qb-ambulancejob` | `client/main.lua:712` | `qb-phone:server:sendNewMail` | `medical.cfg:7` |
| `qb-pawnshop` | `client/main.lua:332` | `qb-phone:server:sendNewMail` | `crime.cfg:33` |
| `qb-policejob` | `client/main.lua:131`、`client/stolen_radar.lua:57`、`server/commands.lua:305,308,540`、`server/main.lua:160,173,263` | 邮件 / 罚单 / 警讯 | `police.cfg:7` |
| `qb-prison` | `client/prisonbreak.lua:109` | `qb-phone:client:addPoliceAlert` | `police.cfg:4` |
| `qb-storerobbery` | `server/main.lua:573` | `qb-phone:client:addPoliceAlert` | `crime.cfg:29` |

> 另有 6 个**未启用**资源（`qb-crypto`、`qb-diving`、`qb-houses`、`qb-lapraces`、`qb-scrapyard`、`qb-vehiclesales`）也在调用。
> `qb-garages/server/main.lua:294` 只是注释（“Call from qb-phone”），不算消费者。

**推论**：这些调用在当前就已经指向未启动资源（不会送达，导出可能抛“export 不存在”），是**迁移未完成的遗留**，不是“可随手删的死代码”。删除 `qb-phone` 前应先决定：迁移到 `custom-phone`，还是接受这些通知永久缺失。

### 2.4 任务清单中其余重点对象的逐项核查

| 重点对象 | 核查结果 | 处置 |
|:---|:---|:---|
| `T-CityLite.base/cache/` | 本 worktree **不存在**；`T-City/` 下的 `cache/` 464M 被 `.gitignore` 覆盖、仅本地 | 不动（运行时缓存） |
| `html/assets` 旧 hash 文件 | 6 个带 hash 的产物**全部被引用**，0 孤儿：`tcity-dashboard/nui/dist/assets/index-{CDQpKmmx.js,D6zbaQGC.css}`、`qb-banking/html/assets/index-{DDzwxARP.js,CFowxLEI.css}`、`monitor/panel/index-{f9doidst.v800.js,iqd44fe8.v800.css}`；`pma-voice` 的 `chunk-vendors.js` 也被引用 | 无候选 |
| `__pycache__` / `.pytest_cache` | 8 + 2 个目录，约 1.3M，**未跟踪**（`git status --ignored`） | A1–A3 |
| `node_modules` | `find` 结果 0 个目录；`.gitignore:44` 已覆盖 | 无 |
| `*.log` / `*.tmp` / `*.bak` / dump | 0 个跟踪、0 个存在（`.gitignore` 已覆盖） | 无 |
| `server_archive` | **不存在**（全仓库 `git grep -i 'server_archive'` = 0） | 无 |
| 根目录散落文件 | `fxmanifest_inventory.json`→A5；`simulation_report.json`→B12；`REASONIX.md`→B11；`QBCore_Lite_技术讨论.md` 被 `PROJECT_PROGRESS.md` + `docs/archive/QBCore_Lite_versions/README.md` 引用→保留；`PROJECT_PROGRESS.md` 为当前路线图→保留 | 见各表 |
| `docs/archive/QBCore_Lite_versions/` | 30 文件 / 356K；5 个外部引用 | B8 |
| `docs/` 旧版文档 | 472K 历史版本手册 + 审计报告，部分仍被引用 | B9 |
| 分支 `recons` / `v0.5-crime` / `feat/agent-takeover` | 前两者已完全合并；后者 102 behind、内容已被 master 覆盖 | §8 |

> 结论：**没有** `server_archive`；**没有**孤儿 hash bundle；**没有**被跟踪的 `cache/`、`node_modules`、日志或 dump。仓库内“看起来像垃圾”的东西主要是延期资源和历史文档，不是临时产物。

### 2.3 建议

**B 组：归档（不是第一批删除）**。两种落地方式：

```bash
# 方式 A（推荐，保留可回滚）：移出 resources/，FXServer 不会再加载
mkdir -p archive && git mv 'T-CityLite.base/resources/[qb]/qb-phone' archive/qb-phone

# 方式 B（确认不再需要）：直接删
git rm -r 'T-CityLite.base/resources/[qb]/qb-phone'
```

---

## 3. A 组 — 安全删（低风险、无运行时影响）

| # | 候选 | 类型 | 引用证据（已排除自身） | 风险 | 建议 | 删除命令 |
|:--|:---|:---|:---|:---:|:---|:---|
| A1 | `.pytest_cache/`（44K） | **未跟踪**（pytest 自建 `.gitignore`，`git status --ignored` 显示 `!!`） | 0 处引用；纯 pytest 运行缓存 | 低 | 删（并把 `.pytest_cache/` 写进 `.gitignore`） | `rm -rf .pytest_cache` |
| A2 | `T-CityLite.base/.pytest_cache/`（72K） | **未跟踪** | 0 处引用 | 低 | 删 | `rm -rf T-CityLite.base/.pytest_cache` |
| A3 | 8 个 `__pycache__/`（合计约 1.2M），分布：`tools/`、`tests/agent/`、`T-CityLite.base/tests/` 及 unit/layer0-3 | **未跟踪**（`.gitignore:98`） | 0 处引用；`.pyc` 可再生 | 低 | 删（CI 不依赖） | `find . -path ./.git -prune -o -type d -name __pycache__ -exec rm -rf {} +` |
| A4 | 57 个资源内 `.github/` 目录（399 个文件，0.84M）：`resources/[qb]/*/.github` + `[voice]/qb-radio/.github` | **跟踪** | `git grep` 在 `resources/` 之外 0 处引用；CI 只用仓库根 `.github/workflows/ci.yml`；每个资源重复同一份 11.2K `contributing.md`（55 份）、issue 模板、stale/lint 工作流 | 低 | 删（上游样板，不参与 FiveM 加载；LICENSE 另存不受影响） | `git rm -r -q $(find T-CityLite.base/resources -type d -name .github -not -path '*/.github/*')` |
| A5 | `fxmanifest_inventory.json`（64K，1 个文件） | **跟踪** | 0 处引用；内容是带 **Windows 反斜杠路径**的旧快照（`"[cfx-default]\\[gamemodes]..."`），无生成脚本、无 CI 使用 | 低 | 删（可由 manifest 重新扫描生成） | `git rm fxmanifest_inventory.json` |
| A6 | `T-CityLite.base/resources/[qb]/qb-minigames/html/css/tictactoe.css`（**0 字节**） | **跟踪** | 唯一引用是 `html/index.html:26` **被注释掉的** `<link>`；同目录 `js/tictactoe.js` 也不存在 | 低 | 删 | `git rm 'T-CityLite.base/resources/[qb]/qb-minigames/html/css/tictactoe.css'` |

> A4 是 A 组最大一块（0.84M），但只删上游仓库样板；如果团队想保留上游出处，可只删 55 份重复的 `contributing.md` 与 issue 模板，保留根级 LICENSE/README。

**A 组合计：约 2.2M。** 其中 A1–A3 是本地磁盘，A4–A6 是仓库内容。

---

## 4. B 组 — 需确认（有价值的清理目标，但有依赖/历史/安全权衡）

| # | 候选 | 类型 | 引用证据（已排除自身） | 风险 | 建议 | 删除/归档命令 |
|:--|:---|:---|:---|:---:|:---|:---|
| B1 | `[qb]/qb-phone`（3.2M，63 文件） | 跟踪 | 63 文件 / 237 处；25 个 Lua 文件；**8 个已启用资源**调用（§2.2）；`ensure`=0；`fxmanifest` 依赖=0；`custom-phone` 兼容实现=0 | **中** | 归档（先迁移或接受通知缺失） | `mkdir -p archive && git mv 'T-CityLite.base/resources/[qb]/qb-phone' archive/qb-phone` |
| B2 | `[system]/monitor`（13M，146 文件） | 跟踪 | 未 ensure；`qb-ambulancejob/server/main.lua:13` 以 `GetInvokingResource() ~= 'monitor'` 守卫 txAdmin 治疗事件；`docs/01_resource_inventory.md:172` 标 ❌；无 fxmanifest 依赖 | 中高 | **默认保留**（txAdmin 实机依赖）；确认不用 txAdmin 菜单后再归档 | `git mv 'T-CityLite.base/resources/[system]/monitor' archive/monitor`（仅确认后） |
| B3 | `[qb]/qb-radialmenu`（2.9M，36 文件） | 跟踪 | 未 ensure；**0 个外部代码引用**（只有自身 config 引用 `qb-hotdogjob`）；`docs/01:203` 列为延期 | 中低 | 归档 | `git mv 'T-CityLite.base/resources/[qb]/qb-radialmenu' archive/qb-radialmenu` |
| B4 | `[qb]/qb-hotdogjob`（2.4M，29 文件） | 跟踪 | 未 ensure；唯一引用是 `qb-radialmenu/config.lua`（也未启用）+ 压测事件字符串 | 中低 | 归档（与 B3 同批） | `git mv 'T-CityLite.base/resources/[qb]/qb-hotdogjob' archive/qb-hotdogjob` |
| B5 | `[voice]/qb-radio`（1.7M，22 文件） | 跟踪 | 未 ensure；**0 个外部代码引用**；`docs/01:183,206,254`：“已由 pma-voice 内置替代” | 中低 | 归档 | `git mv 'T-CityLite.base/resources/[voice]/qb-radio' archive/qb-radio` |
| B6 | `[qb]/qb-smallresources`（864K，65 文件） | 跟踪 | 未 ensure；4 个引用**全部**来自 `qb-radialmenu`（同样未启用）；`docs/01:205` v0.2 deferred | 中低 | 归档（与 B3 绑定） | `git mv 'T-CityLite.base/resources/[qb]/qb-smallresources' archive/qb-smallresources` |
| B7 | 15 个零外部引用的延期 qb 资源（约 2.7M）：`qb-bankrobbery`、`qb-busjob`、`qb-crafting`、`qb-diving`、`qb-garbagejob`、`qb-jewelery`、`qb-mapsidebar`、`qb-newsjob`、`qb-recyclejob`、`qb-scrapyard`、`qb-taxijob`、`qb-towjob`、`qb-truckrobbery`、`qb-vehiclesales`、`qb-vineyard` | 跟踪 | 全部未 ensure；被引用数=0（`qb-scrapyard` / `qb-vehiclesales` / `qb-diving` / `qb-truckrobbery` 只是**向外**调用 `qb-phone`）；`docs/01:203` 列为“未列入当前版本” | 中 | 归档（保留未来玩法素材）；不要直接删 | `mkdir -p archive/qb && for d in qb-bankrobbery qb-busjob qb-crafting qb-diving qb-garbagejob qb-jewelery qb-mapsidebar qb-newsjob qb-recyclejob qb-scrapyard qb-taxijob qb-towjob qb-truckrobbery qb-vehiclesales qb-vineyard; do git mv "T-CityLite.base/resources/[qb]/$d" archive/qb/; done` |
| B8 | `docs/archive/QBCore_Lite_versions/`（356K，30 文件） | 跟踪 | 5 个**外部**文件引用：`PROJECT_PROGRESS.md:33` + `T-CityLite.base/docs/` 下 4 篇（`agent/reviews/03-contract-ci.md`、`v0.3-test-checklist.md`、`v0.4-implementation-analysis.md`、`v0.4-validation-plan.md`）；目录内 `README.md` 还有相对链接；是 v0.1–v1.0 规格/路线历史，不是运行时资源 | 低 | **保留**或整体归档；不要逐文件删 | `git mv QBCore_Lite_versions docs/archive/QBCore_Lite_versions`（需同步 5 处外部链接） |
| B9 | 旧版文档包（472K）：`T-CityLite.base/docs/v0.*.md`、`T-CityLite.base/docs/audit/2026-06-20-*.md`、`test-report-v0.1-v0.4.md`、`global-audit-whitepaper.md`、`v0.5-code-review-report.md`、`bus-api-reference.md` | 跟踪 | 多为历史版本手册/审计。仍有引用：`bus-api-reference` 4 处、`2026-06-20-full-audit-report` 1 处（被 10-21 新审计复核引用）、`global-audit-whitepaper` 1 处、`test-report-v0.1-v0.4` 1 处、`v0.5-code-review-report` 2 处；`2026-06-20-delivery-report`、`2026-10-21-test-report/self-review/ingame-test-plan` 为 0 引用 | 中 | **归档，不删**（审计留痕）；新文档见 `docs/00_SERVER_MASTER_MANUAL.md`、`docs/03_maintenance_manuals/` | `mkdir -p docs/archive/legacy && git mv T-CityLite.base/docs/v0.*.md T-CityLite.base/docs/audit/2026-06-20-*.md T-CityLite.base/docs/{test-report-v0.1-v0.4.md,global-audit-whitepaper.md,v0.5-code-review-report.md,bus-api-reference.md} docs/archive/legacy/` |
| B10 | `design/`（2 个文件，20K） | 跟踪 | 精确路径引用=0；`design/refactor-escape-sqli-20260601.md`、`design/store-robbery-redesign-20260601.md` 是**设计稿**，`docs/` 下已有对应的实施报告（内容不同：设计稿有目标/验收标准，报告有变更记录） | 低 | 归档（保留设计动机） | `git mv design docs/archive/design` |
| B11 | `REASONIX.md`（16K） | 跟踪 | 0 处引用；内容是“全局逆向审计”的 **AI prompt 记忆**，与当前 `AGENTS.md` 重复；`.reasonix/` 已在 `.gitignore` | 低 | 删或归档 | `git rm REASONIX.md` |
| B12 | `simulation_report.json`（4K） | 跟踪 | 2 处引用：`tools/oneoff/sandbox_simulator.py:443`（默认输出名）+ 一篇 v0.6 文档链接；是生成物 | 低 | 删 + 改文档链接，或保留 | `git rm simulation_report.json` |
| B13 | `admins.json`（4K） | 跟踪 | 0 处代码引用（5 处是 monitor 文档里的泛称）；含 **bcrypt `password_hash`**；`.gitignore` **未**排除；提交于初始提交 `1e39c45` | **高（安全）** | **先移出版本库 + 轮换密码**（保留本地） | `git rm --cached admins.json` 然后 `echo 'admins.json' >> .gitignore`；`git commit` 后轮换 txAdmin 密码（历史提交仍含旧哈希，必要时 filter-repo） |
| B14 | `default/config.json`（176B） | 跟踪 | 0 处引用；txAdmin profile，`dataPath` 指向 **`F:/t-city/...`**（Windows 旧机器） | 中 | 确认 txAdmin 不使用该 profile 后删/改本地 | `git rm default/config.json`（确认后） |
| B15 | `.hermes/plans/2026-06-22_113651-qb-vehicleshop-renovation.md`（32K） | 跟踪 | 0 处引用；qb-vehicleshop 改造已完成；`.hermes/` 是历史计划目录 | 低 | 归档 | `git rm -r .hermes` |
| B16 | `docs/analysis/tuning_shop_analysis.html`（28K）、`tuning_shop_player_experience.html`（36K） | 跟踪 | 0 处引用；同目录已有同名 `.md`；HTML 是渲染版报告 | 低 | 删除 HTML，保留 Markdown | `git rm docs/analysis/tuning_shop_analysis.html docs/analysis/tuning_shop_player_experience.html` |
| B17 | 本地分支 `feat/agent-takeover` | 本地（未推送） | 3 commits ahead / **102 behind**；关键文件（`CLIENT_HARNESS.md`、`test_vehiclekeys_claim.py`、`tools/fivem_mcp_client.py`、`tools/windows/*`）在 master 均已存在；远程无同名分支（`git branch -r` 不含它） | 中 | 确认 3 个 commit 的 fix 已落地后删 | `git branch -D feat/agent-takeover` |

> 另有 4 个未启用资源与其它候选耦合，建议跟随决策、**不要单独删**：`qb-shops`（260K，唯一引用是 `qb-inventory/server/main.lua:420` 发出的 `qb-shops:server:UpdateShopItems`，no-op）、`qb-crypto`（168K，仅被 `qb-phone` 引用）、`qb-lapraces`（196K，仅被 `qb-phone` 引用）、`qb-weed`（164K，仅被 `qb-houses` 引用）。

**B 组合计：约 28M**（若 B2 monitor 保留，则实际可回收约 15M；即使只做 B1/B3/B4/B5/B6/B7，也有约 14M）。

---

## 5. C 组 — 不要删（删了会破坏运行时/测试/文档体系）

| # | 候选 | 类型 | 为什么不要删 |
|:--|:---|:---|:---|
| C1 | `[custom]/custom-phone`（980K，59 文件） | 跟踪 | 唯一启用的手机：`custom.cfg:20`；`fxmanifest` 的 `ui_page`/`files` 指向 `html/`；3 套测试读取其 `server/sms.lua`、`server/main.lua`；AGENTS 明确它是自研手机 |
| C2 | `[custom]/custom-director`（312K，13 文件） | 跟踪 | **仓库内确实没有 `ensure`**（只有 `custom.cfg:10` 注释、文档、测试），但它是 agent 动作代理：`tests/agent/lua/bootstrap.lua:77` 直接加载，9 个 Lua suite 依赖，`AGENTS.md:22,37` 列为关键资源。删除会击穿 agent 测试与实机栈；应先确认运行实例是否手动 `ensure`，再补 CFG（这是另一个待修问题） |
| C3 | `[custom]/custom-testing`（140K）+ `[custom]/tcity-e2e`（108K） | 跟踪 | `dev.cfg` 明确 `ensure custom-testing`；`tcity-e2e` 在 dev.cfg 中注释保留，`DIRECTOR.md` / 审计报告 / 测试引用其场景，是实机 E2E 唯一载体 |
| C4 | `[qb]/qb-houses`（440K，35 文件） | 跟踪 | 虽然未 ensure，但**已启用资源**在调用：`qb-garages/server/main.lua:220` 用 `exports['qb-houses']:hasKey`，`qb-multicharacter` 调用其 4 个事件。删除会把“未运行的软依赖”变成确定的缺失导出；要么保留，要么先迁移/启用 |
| C5 | `[qb]/qb-minigames`（316K） | 跟踪 | 被 `crime.cfg:30` ensure，是 `qb-houserobbery` 的 **manifest 硬依赖**（`dependencies { 'qb-minigames' }`） |
| C6 | 已提交的前端产物：`custom-phone/html`（296K）、`qb-banking/html`（144K）、`tcity-dashboard/nui/dist`（164K）、`menuv/dist`（264K） | 跟踪 | 都是 `ui_page` 指向的运行时文件；`dist/` 虽被 `.gitignore` 覆盖但**已被跟踪**，删除后必须重新构建才能启动 NUI。可另行讨论“产物不入库 + CI 构建”，但不属于本次删除 |
| C7 | `[custom]/custom-quest/tests/*`（108K） | 跟踪 | `custom-quest/fxmanifest.lua:110-111` 以 `server_script`/`client_script` 加载，是 `/quest_flow_test` 的运行时测试命令；与 `T-CityLite.base/tests/` 下的同名副本**服务不同入口**，不是冗余 |
| C8 | 当前文档与工程配置：`AGENTS.md`、`PROJECT_PROGRESS.md`、`CHANGELOG.md`、`docs/00-04`、`docs/agent/**`、`.github/workflows/*`、`CONTRIBUTING.md`、`SECURITY.md`、`CLAUDE.md`、`migrations/`、`tests/fixtures/tcity_schema.sql` | 跟踪 | 当前入口/CI/迁移/DB fixture；`docs-check` 是 advisory，但删这些会造成系统性断链 |
| C9 | `[cfx-default]` 内置资源（`spawnmanager`、`mapmanager`、`chat`、`basic-gamemode` 等） | 跟踪 | 即使没有 `ensure` 也是 FiveM 引擎默认/被 `core.cfg` 引用；删除会破坏启动链 |
| C10 | 资源内 `LICENSE` / `README` / 第三方许可（如 `monitor/THIRD-PARTY-LICENSES.txt`） | 跟踪 | 上游署名与合规要求；清理 `.github/` 时不要连带删 LICENSE |

---

## 6. 预计回收空间

| 组 | 工作区回收 | 说明 |
|:---|:---:|:---|
| A（安全删） | **约 2.2M** | 1.3M 本地缓存 + 0.84M 上游 `.github/` + 64K 生成 inventory + 0B 空 CSS |
| B（需确认） | **约 28M** | 含 monitor 13M；若保留 monitor，约 15M；最稳的 B1/B3–B7 约 14M |
| C（不要删） | 0 | 保护运行时与测试 |
| `T-City/` 运行工作区（仓库外） | 464M（cache）+ 293M（alpine） | **不在本仓库**；`cache/` 可再生，`alpine/` 是启动器运行时，二者都不建议动（本次不触碰 FXServer） |

> 注意：`git rm` 只缩小工作区，**不会**缩小 345M 的 `.git` pack（历史里仍有大 mesh）。要真正缩小仓库必须重写历史（`git filter-repo`），属于另一项高风险操作，本提案不建议。

---

## 7. 若删除资源：需要同步修改的 ensure / fxmanifest / CI 文件

| 删除对象 | ensure / CFG | fxmanifest | CI / 测试 | 文档 / 其他 |
|:---|:---|:---|:---|:---|
| `qb-phone` | **无需删 ensure**（本来就没有）；若运行实例手动 ensure 过，检查未跟踪的 `server.cfg` | 无资源声明依赖它；`custom-phone` 也不依赖 | `T-CityLite.base/tests/check_dependencies.py:23`（`DEFERRED_RESOURCES` 移除 `qb-phone`）；`T-CityLite.base/tests/architecture_stress_test.lua:141`、`[custom]/custom-testing/stress_test.lua:147` 的事件字符串 | `docs/01_resource_inventory.md:123,205,252`；`AGENTS.md:16,164,193`；`docs/agent/phone/qb-phone-research.md`；8 个调用方（见 §2.2） |
| `monitor` | 无 | 无 | `check_dependencies.py` 会把它报为 **orphan**（非致命，仅提示） | `docs/01_resource_inventory.md:172,203`；`qb-ambulancejob/server/main.lua:13`；`docs/agent/design/02-client-effect-channel.md:33-34` |
| `qb-radio` | `voice.cfg` 无 ensure，无需改 | 无 | `check_dependencies.py:38` | `docs/01_resource_inventory.md:183,206,254` |
| B3–B7 延期 qb 资源 | 全部未 ensure，无需改 | 无互相依赖（`qb-radialmenu`→`qb-hotdogjob` 是配置引用，需一起归档） | `check_dependencies.py:23-38` 的 `DEFERRED_RESOURCES` 列表；移除后 orphan 检查不再提示 | `docs/01_resource_inventory.md` §2.2、§3；`T-CityLite.base/README.md` 资源树 |
| `docs/archive/QBCore_Lite_versions/` | 无 | 无 | 无 | `PROJECT_PROGRESS.md:33`、`docs/archive/QBCore_Lite_versions/README.md:15,64,125`、4 篇旧文档的链接 |
| 旧文档包 | 无 | 无 | `.github/workflows/ci.yml` 的 **docs-check 是 advisory**（只打印、不失败） | `CHANGELOG.md`、`T-CityLite.base/LITE_CHANGELOG.md`、`docs/interaction_memo.md:190`、`docs/v0.5-maintenance-guide.md:296`、`T-CityLite.base/README.md` |
| 上游 `.github/` | 无 | 无 | 根 `.github/workflows/ci.yml` 不受影响 | 无 |

CI 事实核查：`.github/workflows/ci.yml` 中**没有**对 `qb-phone` / `monitor` / `qb-radio` 的直接引用；`check_cfgs.py` 只校验被 ensure 的资源，删除未 ensure 资源不会失败；`check_dependencies.py` 只有 `missing_resource` / `missing_dependency` / `startup_order` / `circular_dep` 会让 CI 失败，`orphan` 只是提示。

---

## 8. 分支 / 工作树建议（只建议，不执行）

| 对象 | 状态 | 建议 |
|:---|:---|:---|
| `recons` | 0 ahead / **160 behind** `master`，指向初始提交，完全已合并 | 可安全删：`git branch -d recons`（本地）；远程 `origin/recons` 视团队习惯保留或删 |
| `v0.5-crime` | 0 ahead / **157 behind**，完全已合并 | 可安全删：`git branch -d v0.5-crime`（本地） |
| `dev` / `master` | 同一提交 `99e0c27` | 保留；`chore/repo-cleanup` 当前也指向它 |
| `feat/agent-takeover` | 3 ahead / **102 behind**；仅本地分支；关键文件在 master 已存在 | 先确认 3 个 commit 的 fix 是否已落地，再 `git branch -D feat/agent-takeover` |
| `origin/fix/foundation-audit-2026-10-21` | 远程分支，未在本地跟踪列表；无未合并提交 | 可清理远程（需团队确认） |
| 第二个 worktree `T-City/`（dev） | 独立 worktree，含 `server.cfg`、`cache/` 464M、`alpine/` 293M | **不要删**：服务器运行工作区；`server.cfg` 含密钥且被 gitignore |

---

## 9. 建议执行批次

1. **第一批（零运行时影响，~2.2M）**：A1–A6。可在一个 PR 内完成；顺手把 `.pytest_cache/` 加进 `.gitignore`。
2. **第二批（安全，独立 PR）**：B13 `admins.json` 移出版本库 + 轮换密码（与清理分开评审）。
3. **第三批（资源归档，需负责人确认）**：B3/B4/B5/B6/B7，先建 `archive/` 并写 README，再 `git mv`，同步 `check_dependencies.py` 与 `docs/01_resource_inventory.md`。
4. **第四批（手机迁移）**：先把 §2.2 的 8 个调用方迁移到 `custom-phone`，再把 B1 归档。
5. **第五批（文档/分支）**：B8–B12、B14–B16、B17。`monitor`（B2）默认不动。

---

**最终结论（5 行）**

- 可安全删：**A 组 69 项 / 6 类，约 2.2M**（缓存 1.3M + 上游 `.github/` 0.84M + 2 个生成/空文件）。
- 需确认：**B 组 17 类，约 28M**（保留 `monitor` 则实际可回收约 15M）。
- 最大一块：**`[system]/monitor` 13M**（txAdmin 集成，建议保留）；实际最该回收的单品是 **`qb-phone` 3.2M**。
- 最危险候选：**`qb-phone`**（63 文件/237 处引用，8 个已启用资源在调用）；另 **`admins.json` 含 bcrypt 哈希**，是应优先处理的泄密风险。
- 建议第一批删：**`.pytest_cache/`、`__pycache__/`、57 个资源内 `.github/`、`fxmanifest_inventory.json`、0 字节 `tictactoe.css`**，共约 2.2M，零运行时影响。
