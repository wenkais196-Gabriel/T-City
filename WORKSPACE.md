# WORKSPACE.md — 本工作区（E:\T-City）实况

> 适用对象：在 **Windows 机器、`E:\T-City` 单 checkout** 里干活的会话。
> 最后核对：2026-10-23（以下数字全部是本机实测，不是文档抄来的）。
> `AGENTS.md` 是项目入口与规范；本文只讲**这台机器上这个 checkout 的真实状态**。

---

## 0. 一分钟

T-City Lite = **QBCore / FiveM RP 服务器** + **LLM agent 接管栈**（`custom-director` 18 动作 L1–L4 + 31 个 agent 工具 + live 感知 + 离线评测）。

本 checkout 当前只做到 **「静态验证全绿」**，还**起不了服**：缺 `server.cfg`、`alpine/`（Linux FXServer 运行时）、MariaDB。详见 §5。

---

## 1. 位置与版本

| 项 | 实测值 |
|:---|:---|
| 工作区 | `E:\T-City`（git checkout，分支 `master`） |
| HEAD | `99e0c27` docs: add AGENTS.md, the entry point for new sessions |
| `origin/master` = `origin/dev` | 都是 `99e0c27`（两边同步，0 ahead / 0 behind） |
| 其余远程分支 | `chore/repo-cleanup`、`fix/foundation-audit-2026-10-21`、`recons`、`v0.5-crime` |
| 工作树规模 | 6216 个文件；`.git` 348 MB（历史含大量资源入库） |
| git 身份 | Song Wenkai <wenkais196@gmail.com>；`gh` 已登录 `wenkais196-Gabriel` |

**布局变化**：`AGENTS.md` 旧版描述的 Linux 双 worktree（`T-City/` 跑服 + `T-City-agent/` 开发）在这台机器上不存在，只有这一个 checkout。改完直接 PR，不再需要「两边同步」。

---

## 2. 工具链（本机实装）

| 工具 | 本机版本 / 位置 | 用于 | 状态 |
|:---|:---|:---|:---|
| Python | 3.12（`C:\Users\swkgb\AppData\Local\Programs\Python\Python312`），pytest 9.0.3 | 全部 pytest 套件、`tools/*.py` | ✅ |
| Lua | **5.4.6**（winget `DEVCOM.Lua` → `%LOCALAPPDATA%\Programs\Lua\bin`） | Lua golden 套件、`luac5.4 -p` | ✅ |
| Node / npm | v26.7.0 / 12.0.2 | `custom-phone/web` 构建 | ✅ 可用（未装 `node_modules`） |
| git / gh | git 2.x（mingw64）、gh 已登录 | 分支 / PR | ✅ |
| MariaDB / MySQL | **未安装**，无 `mysql` 客户端 | 132 个 DB 用例、实机库 | ❌ |
| Docker | 已装（Docker Desktop 在 PATH） | 拉起 MariaDB 11.8 的最省事路径 | ✅ |
| FXServer + 客户端 | **无** | 实机冒烟 / 玩法验收 | ❌ |

### Lua 安装的坑（换机器必看）

winget 装的 exe 叫 `lua.exe`，但仓库测试硬编码 `lua5.4` / `luac5.4`，而 **Windows `CreateProcess` 对名字里带点的文件不会自动补 `.exe`**（`lua5.4` 被当成扩展名 `.4`），所以只建 `lua5.4.exe` 仍然 `FileNotFoundError`。

可用做法：在 `%LOCALAPPDATA%\Programs\Lua\bin` 和 `C:\Users\swkgb\bin` 各放一份**无扩展名**的 PE 副本 —— `lua5.4`、`luac5.4`（PE 文件不靠扩展名也能执行），并把 Lua bin 目录写进 `HKCU\Environment\Path`：

```powershell
$b = "$env:LOCALAPPDATA\Programs\Lua\bin"
Copy-Item "$b\lua.exe"  "$b\lua5.4"  ; Copy-Item "$b\lua.exe"  "$b\lua5.4.exe"
Copy-Item "$b\luac.exe" "$b\luac5.4" ; Copy-Item "$b\luac.exe" "$b\luac5.4.exe"
```

验证：`python3 -c "import subprocess;print(subprocess.run(['luac5.4','-v'],capture_output=True,text=True).stdout)"`

---

## 3. 能跑什么 / 实测结果（2026-10-23）

| 命令 | 实测结果 |
|:---|:---|
| `python3 -m pytest -q tests/agent`（仓库根） | **203 passed, 3 skipped, 546 subtests**（跳过=3 条需 `AGENT_DB_PASS`） |
| `cd T-CityLite.base && python3 -m pytest -q tests/unit` | **288 passed, 132 skipped**（跳过=需 `TCITY_DB_PASS` 的 DB 用例） |
| `cd T-CityLite.base && python3 -m pytest -q tests/agent` | **3 passed**（Lua harness 桥接） |
| `lua5.4 T-CityLite.base/tests/agent/lua/runner.lua` | **9 suites / 236 checks / 0 failed**（http_contract 21、http_adapter 10、live_rules 12、live_api 24、effect_rules 41、effect_server 22、director_actions 95、director_denials 6、phone_sms 5） |
| `python3 tools/agent_tools.py --check` | **OK（31 tools，2 个生成文件无漂移）** |
| `cd T-CityLite.base && python3 tests/check_cfgs.py` | **82 个 manifest 存在，0 缺失** |
| `cd T-CityLite.base && python3 tests/check_dependencies.py` | 通过，但警告 3 个资源「存在未启用」：`qb-mapsidebar`、`notify-test`、`monitor` |
| 全仓 `luac5.4 -p` 扫描（1344 个 .lua） | 1216 通过 / 116 跳过（反引号 joaat）/ 12 失败 |

**那 12 个「失败」不是 bug**：它们用了 **CfxLua 方言**（五 `+=`/`-=`，qb-target 用 `?[1]` 安全索引），标准 `luac5.4` 必然报错。CfxLua 是 FiveM 对 Lua 5.4 的魔改（compound operators、safe navigation、反引号 hash、C 风格块注释、`in` 解包）。

> 结论：**不要拿全仓 `luac5.4 -p` 当门禁**。语法真值只能靠 FXServer 加载，或只 parse 改动文件 + 对上述 12 个方言文件放行（CI 目前只跳反引号，改到这 12 个文件时会假红）。

**跑不了的三类**：DB 用例（无 MariaDB）、实机冒烟 `agent_smoke.py`（无服无客户端）、NUI Playwright（`custom-phone/web` 未 `npm install`）。

---

## 4. 运营/开发常用入口（本机可用性）

| 用途 | 入口 | 本机 |
|:---|:---|:---|
| 服务器状态 / 在线玩家 | `curl -s http://127.0.0.1:30120/players.json` | 无服，不可用 |
| 起服 | `./start.sh`（依赖 `alpine/` musl loader） | ❌ 缺运行时 |
| 用模板生成配置 | `T-CityLite.base/server.cfg.template` → `server.cfg`（gitignored，含 DB 密码/license/agent token） | 待做 |
| 数据库迁移 | `T-CityLite.base/migrations/v*.sql`（幂等） | ❌ 无库 |
| 手机前端 | `custom-phone/web`（Svelte 5 + Vite）→ `npm run build` → `html/`（已入库） | ✅ 需先 `npm install` |
| 工具注册表 | `tools/agent_tools.json`（唯一事实源）→ `python3 tools/agent_tools.py --write/--check` | ✅ |
| Agent 冒烟/评测 | `tools/agent_smoke.py`、`tools/agent_eval.py` | ❌ 需服 / 需导出 JSONL |

---

## 5. 起服还缺什么（运营前置清单）

| 缺项 | 说明 | 怎么补 |
|:---|:---|:---|
| `T-CityLite.base/server.cfg` | gitignored；含 `mysql_connection_string`、`sv_licenseKey`、`agent_*_token` | 从 `server.cfg.template` 复制并填；**永不入库** |
| `alpine/` | FXServer 的 Linux musl 运行时，`start.sh` 写死路径 `alpine/opt/cfx-server/` | Linux/musl 环境直接放；**Windows 上得另下 FXServer Windows artifacts**（`start.sh` 不适用） |
| MariaDB 11.8 + 库 `TCityLite` | 全部 DB 用例与实机数据 | 最省事：Docker 起 `mariadb:11.8` 映射 3306，再按 `tests/fixtures/tcity_schema.sql` / `migrations/` 建表 |
| `cache/` | 资源缓存，改 manifest 后需 `restart <resource>` | 起服时自动生成，gitignored |
| `custom-phone/web/node_modules` | 改前端才需要 | `cd .../web && npm install && npm run build` |
| `~/.tcity-agent-test.env` | director/admin/live token + `AGENT_AGENT_ID`（600，未入库） | 首次实机冒烟前建 |

---

## 6. 文档阅读顺序

1. `AGENTS.md`（项目入口 + 规范 + 踩坑清单）
2. `T-CityLite.base/docs/agent/STATUS.md`（agent 栈一页纸：有什么/缺什么）
3. `docs/00_SERVER_MASTER_MANUAL.md` → `docs/01_module_manuals/*`（系统全貌）
4. `PROJECT_PROGRESS.md`（路线图；**资源清单块已过期**，以 `T-CityLite.base/docs/audit/2026-10-21-review-and-three-phase-plan.md` 为准）
5. `docs/DEVOPS.md` + `CONTRIBUTING.md`（分支 / CI / 提交规范）
6. `docs/server-design/00..08`（运营哲学、付费模型、agent 导演）

---

## 7. 本次核对发现的文档漂移

| 位置 | 文档说法 | 实测 | 处置 |
|:---|:---|:---|:---|
| `AGENTS.md` §1 | Linux 双 worktree 路径（`/home/swk/...`） | `E:\T-City` 单 checkout | ✅ 已改 |
| `STATUS.md:45` | Lua golden `234 checks` | **236 checks** | ✅ 已改 |
| `PROJECT_PROGRESS.md` 资源块 | 78 资源 / 17 module cfg | **82 个 `ensure` / 18 个 cfg** | ⚠️ 未改：该块手工维护且按模块逐条列出，改数字得整表重扫，留给 `manage_progress.py` 恢复或专项 PR |
| `PROJECT_PROGRESS.md` 头部 | 「实际 80 个启用资源 / 17 个模块」 | 同上 82 / 18 | ⚠️ 同上 |
| `docs/agent/reviews/03-contract-ci.md` F-11 | 「CI 不跑 `T-CityLite.base/tests/agent`」 | `ci.yml` 已含 `pytest -q ../tests/agent` | ✅ 已过时（review 是历史记录，不回改） |

---

## 8. 本工作区已做的改动（未提交）

| 文件 | 改动 | 原因 |
|:---|:---|:---|
| `tools/agent_eval.py` | `_read_text` 把 Windows 的 `nul` 与 `/dev/null` 一同视作空导出 | 原判断要求 `Path(path).is_absolute()`，而 `os.devnull` 在 Windows 是 `nul`（非绝对路径），导致 `--input nul` 被 root guard 拒绝，`tests/agent` 1 条用例红 |
| `WORKSPACE.md` | 新增本文 | 工作区实况 |
| `AGENTS.md` | §1 改为 Windows 单 checkout + 指向本文 | 旧路径失效 |
| `T-CityLite.base/docs/agent/STATUS.md` | 234 → 236 checks | 数字与实测对齐 |

---

## 9. 下一步（建议顺序）

1. **起服**：Docker 起 MariaDB → `server.cfg` → Windows FXServer artifacts → `curl players.json` 看到服；这是「运营」和「实机验收」的共同前置。
2. **补齐 DB 用例**：设 `TCITY_DB_PASS` / `AGENT_DB_PASS` 后重跑，132 + 3 个 skipped 变绿才算真基线。
3. **v0.7a 实机验收**（`PROJECT_PROGRESS.md` §当前阶段）：车店 NUI 购车/分期/试驾、车库、中控屏、物流接单→结算。
4. **手机待办**：职业 App 注册表（`docs/agent/phone/DESIGN.md`，先接警察 MDT）、相机/相册。
5. **门禁收口**：`tests/check_lua_syntax.py` 目前只会调 `luacheck`（未装则降级为「只扫文件结构」＝几乎不检查）；建议接 `luac5.4 -p` + 方言文件白名单。
