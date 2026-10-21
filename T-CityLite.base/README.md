# T-City Lite 🏙️

基于 QBCore 的精简模块化 FiveM RP 服务器框架。

> **核心理念**: 模块化启动、安全优先、可迭代架构
> **当前版本**: v0.7a 载具重构与物流（代码完成，待实机验收）

---

## ✨ 特点

- **模块化启动** — 废除 `ensure [qb]` 粗粒度加载，17 个独立 CFG 模块按需启用
- **三层自动化测试** — pytest 单测/集成 286 例 + oxmysql JS 148 例 + 游戏内测试框架；GitHub Actions 门禁
- **统一经济出口** — 所有资金变动通过 `AddScaledMoney`，Convar 热调节
- **安全边界** — Rate Limit、距离校验、服务端事件拦截、Discord 审计日志
- **自研手机系统** — Svelte + Vite 构建，Phone-First 架构，<250KB gzipped

## 🏗️ 版本路线

| 版本 | 状态 | 说明 |
|------|------|------|
| v0.1 | ✅ 完成 | 精简启动链，模块化 CFG |
| v0.2 | ✅ 完成 | 基础 RP（职业/银行/警察/医疗/载具） |
| v0.3 | ✅ 完成 | 基础设施层（经济出口/安全边界/审计） |
| v0.4 | ✅ 完成 | 自研手机系统（Svelte + Vite） |
| v0.5 | ✅ 主体完成 | 犯罪玩法系统（3 项文档遗留待确认） |
| v0.6 | ✅ 完成 | 架构安全与性能加固（DirtyFlush / SecurityService） |
| v0.6-quest | ✅ 完成 | 通用任务系统 `custom-quest` |
| v0.7a | 🚧 待验收 | 载具重构（custom-vehicles）+ 物流任务 + 车店 NUI |
| v0.7b | 🟡 提前落地 | 车载中控屏 `tcity-dashboard` v2.1，待验收 |

---

## 🚀 快速开始

### 前置要求

- FiveM 服务器端（[下载](https://fivem.net/)）
- MariaDB / MySQL 数据库
- Node.js 18+（用于 NUI 构建）
- Python 3.12+（用于离线检测脚本）

### 运行时目录 `alpine/`（必须自行准备）

本仓库**不包含** `alpine/` 目录——它已被 `.gitignore` 排除。这是 FXServer 的 Alpine 运行时（约 293MB，其中 `libnode22.so` 单文件 123MB），超过 GitHub 单文件 100MB 上限，无法入库。

`start.sh` 依赖以下路径，缺一不可：

```
alpine/opt/cfx-server/FXServer
alpine/opt/cfx-server/ld-musl-x86_64.so.1
alpine/opt/cfx-server/citizen/
alpine/usr/lib/v8/    alpine/lib/    alpine/usr/lib/
```

新机器克隆后按以下任一方式补齐（放在仓库根目录，与 `T-CityLite.base/` 同级）：

```bash
# 方式 A：从已有开发机打包（推荐，版本一致）
tar -cJf alpine.tar.xz alpine/          # 在旧机器上
scp alpine.tar.xz newhost:~/T-City/     # 传到新机器
tar -xJf alpine.tar.xz                  # 在仓库根目录解压

# 方式 B：用官方 Linux artifact
# 从 https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/ 下载 fx.tar.xz
# 解压后把 cfx-server 相关内容按上面的结构放进 alpine/，并核对 start.sh 中的路径
```

> ⚠️ 不要用 `git add -f alpine/` 强行提交，否则推送会被 GitHub 拒绝（单文件超限）。

### 构建产物（oxmysql / menuv / dashboard）

以下运行时构建产物已强制纳入版本管理（2026-10-21，约 370KB）：

```
T-CityLite.base/resources/[standalone]/oxmysql/dist/build.js
T-CityLite.base/resources/[standalone]/oxmysql/web/build/index.html
T-CityLite.base/resources/[standalone]/menuv/dist/
T-CityLite.base/resources/[system]/tcity-dashboard/nui/dist/
```

- `oxmysql/dist/build.js` 是 FXServer 实际加载的服务端脚本，缺失会导致 `oxmysql` 启动失败。
- 这些文件被各自上游 `.gitignore` 忽略，但部署必须存在，因此用 `git add -f` 跟踪；更新后同样需要 `git add -f`。
- CI 的 `Verify runtime build artifacts` 步骤会校验它们存在。

### 安装

```bash
# 1. 克隆仓库
git clone https://github.com/wenkais196-Gabriel/T-City.git
cd T-City/T-CityLite.base

# 2. 配置服务器
cp server.cfg.template server.cfg
# 编辑 server.cfg，填入你的:
#   - sv_licenseKey（从 https://keymaster.fivem.net 获取）
#   - mysql_connection_string（数据库连接信息）
#   - steam_webApiKey（从 https://steamcommunity.com/dev/apikey 获取）

# 3. 导入数据库
# 使用 QBCore_CDB34E.sql（如果有）或全新安装 qb-core 数据库

# 4. 启动服务器
# 方法 A: 直接启动
/path/to/FXServer.exe +exec server.cfg

# 方法 B: txAdmin 管理面板
# 在 txAdmin 中设置服务端路径为 T-CityLite.base
```

### 验证安装

```bash
# 运行离线检测
python tests/run_all.py

# 进游戏后 F8 控制台运行
/test run all
```

---

## 📁 项目结构

```
T-CityLite.base/
├── server.cfg.template      # 服务器配置模板（首次使用请复制为 server.cfg）
├── configs/modules/         # 17 个模块化启动配置
│   ├── core.cfg             # v0.1 核心框架
│   ├── player.cfg           # v0.1 玩家流程
│   ├── voice.cfg            # v0.1 语音
│   ├── custom.cfg           # v0.1+ 自定义资源
│   ├── economy.cfg          # v0.3 经济倍率
│   ├── security.cfg         # v0.3 安全边界
│   ├── jobs.cfg             # v0.2 职业
│   ├── banking.cfg          # v0.2 银行
│   ├── vehicles.cfg         # v0.2/v0.7a 载具与中控屏
│   ├── police.cfg           # v0.2 警察
│   ├── medical.cfg          # v0.2 医疗
│   ├── crime.cfg            # v0.5 犯罪
│   ├── career.cfg           # v0.3 多职业
│   ├── admin.cfg            # v0.3 管理
│   ├── quest.cfg            # v0.6 任务系统
│   ├── story.cfg            # v0.7 剧情引擎
│   └── atmosphere.cfg       # 场景 BGM
├── resources/[custom]/      # 自研资源
│   ├── custom-main          # 主逻辑（Spawn Death / duty / 通缉接管）
│   ├── custom-economy       # 统一经济出口
│   ├── custom-security      # 安全防火墙
│   ├── custom-logs          # 审计日志
│   ├── custom-career        # 多标签职业
│   ├── custom-admin         # 管理面板
│   ├── custom-crime         # 犯罪逻辑
│   ├── custom-quest         # v0.6 任务系统
│   ├── custom-vehicles      # v0.7a 钥匙/车辆状态
│   ├── custom-phone         # v0.4 自研手机（Svelte + Vite）
│   └── custom-testing       # 🧪 自动化测试框架
├── tests/                   # pytest + 离线检测脚本
│   ├── unit/                # 单元测试（layer0~layer3）
│   ├── integration/         # 跨服务集成测试
│   ├── run_all.py           # 离线检测一键入口
│   ├── check_cfgs.py        # CFG 完整性
│   ├── check_lua_syntax.py  # Lua 语法
│   ├── check_db_schema.py   # 数据库结构
│   └── check_dependencies.py # 依赖图
└── docs/                    # 文档
    ├── automated-testing-plan.md   # 测试方案
    └── test-report-v0.1-v0.4.md    # 测试报告
```

---

## 🧪 测试

```bash
# 离线检测（不进游戏）
python T-CityLite.base/tests/run_all.py

# pytest 单元 + 集成测试（需要 lua5.4）
cd T-CityLite.base && python -m pytest tests -q

# 游戏内测试
F8 → /test run all          # 全部套件
F8 → /test run banking      # 银行专用
F8 → /test mock 2           # 模拟 2 名警察在线
```

测试覆盖:
- **424 个 pytest 用例**（完整环境，含 MySQL schema 校验）；无 DB 连接时 **286 passed / 132 skipped**
- **148 个 oxmysql JS 用例**
- **3 个 NUI 无头冒烟用例**（Playwright：车店 / 中控屏 / 手机）
- **游戏内套件**: 控制台 `test run all` → 298 PASS / 0 FAIL / 9 SKIP（有玩家上下文）；无玩家时 225 PASS / 8 SKIP
- **CI**: `.github/workflows/ci.yml` 含离线检查、oxmysql JS、MariaDB schema、NUI 冒烟

本地跑 DB 用例：

```bash
pip install mysql-connector-python
# 可选：导入 schema 到一次性库
mysql -uroot -p<db> < tests/fixtures/tcity_schema.sql
TCITY_DB_NAME=<db> python -m pytest tests -q
```

NUI 冒烟（无头 Chromium）：

```bash
pip install playwright
playwright install chromium
python tests/nui/run_ui_tests.py          # 截图输出到 tests/nui/artifacts/
```

---

## 🔒 安全

提交代码前请确认:
1. ✅ `server.cfg` 已在 `.gitignore` 中（使用 `server.cfg.template` 替代）
2. ✅ Discord Webhook URL 已替换为空字符串或占位符
3. ✅ 数据库密码不硬编码在任何文件中
4. ✅ FiveM License Key 不在仓库中明文出现

配置文件中包含 `CHANGE_ME` 或 `YOUR_` 标记的项均为部署前必须替换的敏感配置。

---

## 🧰 技术栈

| 层 | 技术 |
|----|------|
| 服务端框架 | QBCore (Lua) |
| 前端 NUI | Svelte + Vite + TypeScript |
| 数据库 | MariaDB / MySQL (oxmysql) |
| 语音 | pma-voice |
| 测试离线 | Python 3.12+ / pytest / Lua 5.4 |
| 自动化 CI | GitHub Actions（`.github/workflows/ci.yml`） |

---

## 📄 许可证

T-City Lite 基于 QBCore Framework 构建。
QBCore Framework © QBCore-Framework Team.
本项目代码仅用于学习和非商业用途。
