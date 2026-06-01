# T-City Lite 🏙️

基于 QBCore 的精简模块化 FiveM RP 服务器框架。

> **核心理念**: 模块化启动、安全优先、可迭代架构
> **当前版本**: v0.5 犯罪玩法系统（开发中）

---

## ✨ 特点

- **模块化启动** — 废除 `ensure [qb]` 粗粒度加载，14 个独立 CFG 模块按需启用
- **双层自动化测试** — 离线检测 + 游戏内测试框架，118 个测试用例覆盖 v0.1~v0.4
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
| v0.5 | 🚧 进行中 | 犯罪玩法系统 |
| v0.6+ | ⏳ 规划中 | 民间经济 / 沙盒社会生态 |

---

## 🚀 快速开始

### 前置要求

- FiveM 服务器端（[下载](https://fivem.net/)）
- MariaDB / MySQL 数据库
- Node.js 18+（用于 NUI 构建）
- Python 3.12+（用于离线检测脚本）

### 安装

```bash
# 1. 克隆仓库
git clone https://github.com/YOUR_USER/T-City-Lite.git
cd T-City-Lite/T-CityLite.base

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
├── configs/modules/         # 14 个模块化启动配置
│   ├── core.cfg             # v0.1 核心框架
│   ├── player.cfg           # v0.1 玩家流程
│   ├── voice.cfg            # v0.1 语音
│   ├── custom.cfg           # v0.1+ 自定义资源
│   ├── economy.cfg          # v0.3 经济倍率
│   ├── security.cfg         # v0.3 安全边界
│   ├── jobs.cfg             # v0.2 职业
│   ├── banking.cfg          # v0.2 银行
│   ├── vehicles.cfg         # v0.2 载具
│   ├── police.cfg           # v0.2 警察
│   ├── medical.cfg          # v0.2 医疗
│   ├── crime.cfg            # v0.5 犯罪
│   ├── career.cfg           # v0.3 多职业
│   └── admin.cfg            # v0.3 管理
├── resources/[custom]/      # 自研资源
│   ├── custom-main          # 主逻辑（Spawn Death / duty / 通缉接管）
│   ├── custom-economy       # 统一经济出口
│   ├── custom-security      # 安全防火墙
│   ├── custom-logs          # 审计日志
│   ├── custom-career        # 多标签职业
│   ├── custom-admin         # 管理面板
│   ├── custom-crime         # 犯罪逻辑
│   ├── custom-phone         # v0.4 自研手机（Svelte + Vite）
│   └── custom-testing       # 🧪 自动化测试框架
├── tests/                   # 离线检测脚本
│   ├── run_all.py           # 一键执行
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
# 离线检测（不进游戏，5 秒）
python T-CityLite.base/tests/run_all.py

# 游戏内测试
F8 → /test run all          # 全部套件
F8 → /test run banking      # 银行专用
F8 → /test mock 2           # 模拟 2 名警察在线
```

测试覆盖率:
- **118 个测试用例**，覆盖 v0.1~v0.4 全部 14 个模块
- **9 个测试套件**: 核心启动 / 银行 / 警察 / 犯罪 / 安全 / 持久化 / 职业载具 / 经济管理 / 手机
- **单人模式**: 用 `mock_events.lua` 模拟多玩家场景

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
| 测试离线 | Python 3.12+ |
| 自动化 CI | (规划中) |

---

## 📄 许可证

T-City Lite 基于 QBCore Framework 构建。
QBCore Framework © QBCore-Framework Team.
本项目代码仅用于学习和非商业用途。
