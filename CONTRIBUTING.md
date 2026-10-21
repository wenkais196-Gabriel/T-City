# Contributing to T-City Lite

感谢参与。这个仓库是一个 FiveM/QBCore Lite 服务器，改动会直接影响线上玩家，请先读：

1. [`CLAUDE.md`](CLAUDE.md) — 编码行为准则（先思考、最小改动、可验证）
2. [`T-CityLite.base/docs/audit/2026-10-21-review-and-three-phase-plan.md`](T-CityLite.base/docs/audit/2026-10-21-review-and-three-phase-plan.md) — 当前审查结论与三阶段计划
3. [`docs/DEVOPS.md`](docs/DEVOPS.md) — 分支、Issue、CI、发布流程

---

## 1. 开发环境

```bash
git clone git@github.com:wenkais196-Gabriel/T-City.git
cd T-City

# Python 静态检查
python3 --version        # >= 3.12

# Lua 语法检查（可选，本机）
lua5.4 -v
```

`alpine/` 运行时与 `server.cfg` 不入库，按 `README.md` 自行准备。

## 2. 分支模型

采用 **GitHub Flow**（短生命周期分支 + PR）：

| 分支 | 用途 | 规则 |
|:---|:---|:---|
| `master` | 可部署的稳定线 | 受保护；只接受 PR；CI 必须绿 |
| `dev` | 集成分支（如使用） | 可接受日常合并；发布前合入 `master` |
| `feat/<scope>` | 新功能 | 从 `master` 切出，≤ 5 天 |
| `fix/<scope>` | 缺陷修复 | 从 `master` 切出，≤ 3 天 |
| `chore/<scope>` | 构建/CI/依赖/文档 | 可短可长 |
| `hotfix/<scope>` | 线上紧急修复 | 从 tag 切出，修复后同时回合 `master` |

命名示例：`fix/quest-cooldown`、`feat/director-bridge`、`chore/ci-pipeline`。

## 3. 提交规范（Conventional Commits）

```
<type>(<scope>): <subject>

<body: 为什么、影响范围、验证方式>
```

- **type**：`feat` / `fix` / `security` / `refactor` / `docs` / `test` / `ci` / `chore` / `perf`
- **scope**：`boot` / `quest` / `story` / `economy` / `vehicle` / `justice` / `phone` / `db` / `ci` / `docs`
- 中文或英文均可，subject ≤ 72 字符，不以句号结尾。

示例：

```
fix(quest): bind decision steps to server-issued offers

- 客户端不再能伪造 questId/stepId 推进任务
- 超时由服务端按默认选项收口，避免 NUI 关闭后卡死
- 验证：luac5.4 -p + check_dependencies.py
```

**禁止**：一个提交混入无关格式化；提交 `server.cfg`、密钥、Webhook、数据库密码。

## 4. 本地检查（PR 前必须跑）

```bash
cd T-CityLite.base

# 配置完整性（ensure 目标都存在）
python3 tests/check_cfgs.py

# 依赖图 + 启动顺序（会解析 dependencies{} 表）
python3 tests/check_dependencies.py

# Bus 接线（注册方必须 include @core-framework/bus.lua）
python3 tests/check_bus_wiring.py

# Python 语法
python3 -m compileall -q tests

# 改到的 Lua 文件（FiveM 反引号字面量无法被标准 luac 解析，跳过即可）
luac5.4 -p resources/.../your_file.lua
```

## 5. PR 要求

- 标题符合 Conventional Commits；正文填写 PR 模板。
- 关联 Issue：`Closes #123`。
- 附验证证据：命令输出、控制台截图、游戏内复现步骤。
- 数据库变更必须提供 `migrations/*.sql`，使用 `CREATE TABLE IF NOT EXISTS`，可重复执行。
- 改动启动顺序 / 依赖时，必须跑 `check_dependencies.py`。
- 安全修复请附"攻击路径 → 修复后行为"的复测说明。
- 至少 1 位 Reviewer 批准；使用 **Squash merge**，保持 `master` 线性可读。

## 6. 发布

1. 更新 `CHANGELOG.md` 的 `[Unreleased]` → 新版本号。
2. 合并到 `master`，CI 绿。
3. 打 tag：`git tag -a v1.0.0 -m "v1.0.0" && git push origin v1.0.0`。
4. `.github/workflows/release.yml` 自动生成 GitHub Release。
5. 生产部署前按审查报告 §7 的清单做启动冒烟。

## 7. 安全

- 漏洞不要开公开 Issue，走 [`SECURITY.md`](SECURITY.md)。
- 所有客户端事件默认不可信：必须校验 `source`、参数类型/范围、距离、冷却。
- 新增写操作时，问一句：**客户端能不能伪造它？** 能，就先加服务端校验。
