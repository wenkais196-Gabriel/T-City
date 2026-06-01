# 🧪 T-City Lite 自动化测试方案

> **版本**: v1.0
> **创建日期**: 2026-05-31
> **关联版本**: v0.5 犯罪玩法系统（开发中）
> **本文档由 `//goal 创建自动化测试方案文档` 生成**

---

## 目录

1. [现状分析](#1-现状分析)
2. [测试体系架构总览](#2-测试体系架构总览)
3. [Layer 1: 离线检测（Offline Tests）](#3-layer-1-离线检测offline-tests)
4. [Layer 2: 游戏内自动化测试（In-Game Tests）](#4-layer-2-游戏内自动化测试in-game-tests)
5. [测试用例设计规范](#5-测试用例设计规范)
6. [执行流程与 CI 集成](#6-执行流程与-ci-集成)
7. [Roadmap](#7-roadmap)

---

## 1. 现状分析

### 现有测试资产

| 资产 | 类型 | 状态 | 说明 |
|------|------|------|------|
| `[test]/example-loadscreen` | Cfx 默认资源 | ❌ 不可用 | 仅加载画面模板，无测试逻辑 |
| `[test]/fivem` | Cfx 默认资源 | ❌ 不可用 | basic-gamemode 兼容包装，无测试逻辑 |
| `docs/v0.2-master-test-manual.md` | 手动测试手册 | ✅ 已存在 | 126 行，涵盖多模块测试入口 |
| `docs/v0.2-test-checklist.md` | 手动测试清单 | ✅ 已存在 | 118 行，分模块的手动清单 |
| `docs/v0.2-wanted-handover-test-guide.md` | 手动测试指南 | ✅ 已存在 | 警星移交 7 深度用例 |
| `docs/v0.3-test-manual.md` | 手动测试验收手册 | ✅ 已存在 | 267 行，基础设施层详细用例 |
| `docs/v0.3-test-checklist.md` | 手动测试清单 | ✅ 已存在 | v0.3 模块清单 |
| `logs/v0.1-startup-test.md` | 测试报告 | ✅ 已记录 | 9 项玩家流程检查 PASS |
| `logs/v0.2-status-persistence-test-report.md` | 测试报告 | ✅ 已记录 | 5 用例全部 PASS |

### 关键结论

1. **没有自动化测试代码** — 所有测试目前都是手动进游戏操作
2. **测试文档质量高** — 已有手册步骤清晰、预期明确，可直接转化为自动化脚本
3. **模块化架构友好** — 14 个独立 `.cfg` 模块 = 天然按模块独立测试
4. **自研模块体系成熟** — `custom-economy`、`custom-security`、`custom-main` 等提供了统一的 hook 点

---

## 2. 测试体系架构总览

```
T-City Lite 测试体系
│
├── 🖥️ Layer 1: 离线检测 (Offline)
│   ├── 无需启动 FiveM 服务端
│   ├── Python 脚本，秒级完成
│   └── 每次改代码后先跑
│
├── 🎮 Layer 2: 游戏内测试 (In-Game)
│   ├── 需要服务器运行 + 客户端连接
│   ├── FiveM 资源，用 /test 命令触发
│   ├── 单人可跑（服务端模拟多角色）
│   └── 输出结构化 PASS/FAIL 报告
│
└── 📋 文档与报告
    ├── 测试方案（本文档）
    ├── 按模块的测试套件
    └── 测试结果日志
```

### 目录结构

```
T-CityLite.base/
├── tests/                              # 【新增】离线检测脚本
│   ├── check_cfgs.py                   # CFG 配置完整性
│   ├── check_lua_syntax.py             # Lua 语法检查
│   ├── check_db_schema.py              # 数据库表结构
│   ├── check_dependencies.py           # 资源依赖图
│   └── run_all.py                      # 一键全部
│
├── resources/[custom]/custom-testing/  # 【新增】游戏内测试资源
│   ├── fxmanifest.lua
│   ├── server_test.lua                 # 测试调度入口
│   ├── suites/
│   │   ├── 01_banking_test.lua
│   │   ├── 02_police_test.lua
│   │   ├── 03_crime_test.lua
│   │   ├── 04_security_test.lua
│   │   └── 05_persistence_test.lua
│   └── lib/
│       ├── test_runner.lua             # 断言 + 报告引擎
│       └── mock_events.lua             # 事件模拟工具
│
└── docs/automated-testing-plan.md      # 【本次产出】本文件
```

---

## 3. Layer 1: 离线检测（Offline Tests）

不进游戏，在终端直接跑 Python 脚本。适合作为每次修改后的**快速验证 gate**。

### 3.1 CFG 配置完整性检查 (`check_cfgs.py`)

扫描所有 `configs/modules/*.cfg`，对每个 `ensure xxx` 和 `start xxx` 验证对应资源的 `fxmanifest.lua` 是否存在。

```python
# 伪代码逻辑
def check_cfg_integrity():
    errors = []
    for cfg_file in glob("configs/modules/*.cfg"):
        for line in read_lines(cfg_file):
            resource = parse_ensure(line)
            manifest = f"resources/**/{resource}/fxmanifest.lua"
            if not glob_exists(manifest):
                errors.append(f"{cfg_file}: {resource} → manifest NOT FOUND")
    return errors
```

**检查项**:
- 每个 `ensure` 的资源是否存在对应目录和 `fxmanifest.lua`
- 是否有重复的 `ensure`（同一资源在多处启用）
- 是否有注释掉的资源但未被禁用清单记录

### 3.2 Lua 语法检查 (`check_lua_syntax.py`)

使用 `luacheck` 批量扫描所有 Lua 文件。

```bash
luacheck resources/[custom]/ --no-color -q
```

**检查项**:
- 未声明的全局变量
- 未使用的变量/函数
- 潜在的 nil 访问
- 类型不一致

### 3.3 数据库表结构验证 (`check_db_schema.py`)

连接 MariaDB，验证所有预期的表、字段、索引是否存在。

| 表名 | 关键字段 | 索引 |
|------|---------|------|
| `players` | citizenid, license, money | PRIMARY(citizenid) |
| `bank_accounts` | account_id, citizenid, balance | idx_citizenid |
| `bank_statements` | citizenid, account_id, amount, date | idx_citizenid_account_date |
| `player_vehicles` | citizenid, plate, garage | idx_citizenid |

### 3.4 资源依赖图检查 (`check_dependencies.py`)

扫描每个资源的 `fxmanifest.lua`，提取 `dependencies`、`exports`、`@exports`，生成完整的依赖树。

**检查项**:
- 循环依赖检测（A → B → C → A）
- 孤儿资源检测（没有在任何 cfg 中被 ensure，也不是任何资源的依赖）
- 缺失依赖检测（A depends on B 但 B 不在启用的 cfg 中）

### 3.5 一键执行 (`run_all.py`)

```bash
python tests/run_all.py
```

输出格式：

```
═══════════════════════════════════════
 T-City Lite 离线检测报告
═══════════════════════════════════════
[PASS] CFG 完整性      — 54 resources, 0 errors
[FAIL] Lua 语法        — 3 warnings in custom-main
  → custom-main/client.lua:42: unused variable 'ped'
  → custom-main/server.lua:88: value assigned to 'result' is unused
  → custom-main/config.lua:15: accessing undefined field 'debug'
[PASS] 数据库结构      — 6 tables, 9 indexes, all OK
[PASS] 依赖图          — 0 circular deps, 0 orphans
───────────────────────────────────────
Result: 3/4 PASS → 1 FAIL (non-blocking)
```

---

## 4. Layer 2: 游戏内自动化测试（In-Game Tests）

需要在服务器运行时执行的测试，通过 FiveM 资源 `[custom]/custom-testing` 实现。

### 4.1 测试资源架构

```
custom-testing/
  fxmanifest.lua              # server_scripts + client_scripts
  server_test.lua             # 主调度器，处理 /test 命令
  suites/
    01_banking_test.lua       # 银行系统测试
    02_police_test.lua        # 警察/通缉系统
    03_crime_test.lua         # 犯罪系统 (v0.5)
    04_security_test.lua      # 安全边界/防刷
    05_persistence_test.lua   # 状态持久化
  lib/
    test_runner.lua           # assert, describe, it, report
    mock_events.lua           # TriggerEvent 模拟 + NetEvent mock
```

### 4.2 测试命令接口

| 命令 | 用途 | 示例 |
|------|------|------|
| `/test list` | 列出所有可用测试套件 | `/test list` |
| `/test run <suite>` | 运行指定套件 | `/test run banking` |
| `/test run all` | 运行全部测试 | `/test run all` |
| `/test report` | 查看上次测试结果 | `/test report` |

### 4.3 测试引擎核心 (`test_runner.lua`)

```lua
-- 测试框架核心 API
Test.describe("银行系统", function()
  Test.it("存款后余额应增加", function()
    local before = GetPlayerBalance(source)
    DoDeposit(source, 1000)
    local after = GetPlayerBalance(source)
    Test.assert_equal(before + 1000, after, "存款 1000 后余额应 = 原余额 + 1000")
  end)

  Test.it("取款超过余额应被拒绝", function()
    local balance = GetPlayerBalance(source)
    local result = DoWithdraw(source, balance + 1)
    Test.assert_false(result.success, "取款超余额应返回失败")
  end)
end)

-- 输出:
-- [banking] ✓ 存款后余额应增加
-- [banking] ✓ 取款超过余额应被拒绝
-- Result: 2/2 PASS
```

### 4.4 单人模拟多人测试（关键机制）

一个人测试时，通过服务端 `TriggerEvent` 模拟其他玩家的操作：

```lua
-- mock_events.lua 示例
Mock.player("罪犯A", { job = "unemployed" })
Mock.player("警察B", { job = "police", onduty = true })
Mock.player("警察C", { job = "police", onduty = true })

-- 测试警察数量门槛（v0.5 核心需求）
Test.it("只有 1 名警察在线时抢劫应被拒绝", function()
  Mock.set_onduty_count("police", 1)  -- 模拟只 1 警察上班
  local result = TriggerRobbery(source)
  Test.assert_false(result.success, "警察不足 2 人时拒绝抢劫")
end)

Test.it("2 名警察在线时抢劫可触发", function()
  Mock.set_onduty_count("police", 2)  -- 模拟 2 警察上班
  local result = TriggerRobbery(source)
  Test.assert_true(result.success, "警察 ≥ 2 人时允许抢劫")
end)
```

### 4.5 测试套件清单（v0.5 阶段）

| 套件 | 文件 | 测试重点 | 对应文档 |
|------|------|---------|---------|
| **银行系统** | `01_banking_test.lua` | 存取款、转账、流水、子账户、销户退款 | v0.3-test-manual.md |
| **警察系统** | `02_police_test.lua` | duty 切换、警星移交、/clearwanted、雷达 blip | v0.2-wanted-handover-test-guide.md |
| **犯罪系统** | `03_crime_test.lua` | 便利店抢劫、毒品链路、在线警察门槛、冷却时间 | v0.5-crime-gameplay.md |
| **安全边界** | `04_security_test.lua` | 客户端伪造事件拦截、距离校验、rate limit | v0.5 安全测试清单 |
| **状态持久化** | `05_persistence_test.lua` | 代谢值、血量、死亡状态、骨折的跨登录保持 | v0.2 测试报告 |

---

## 5. 测试用例设计规范

### 5.1 每个测试用例必须包含

```markdown
### 🧪 用例 N.N：标题
* **目的**：一句话说明测什么
* **前置条件**：需要什么状态（警察在线？钱包有钱？）
* **操作步骤**：1. 2. 3. ...
* **预期结果**：验证什么
* **自动化状态**：`[ ] 未实现` / `[x] 已实现` / `[~] 部分实现`
```

### 5.2 手动测试 → 自动测试的转换优先级

| 优先级 | 判断标准 | 例子 |
|--------|---------|------|
| P0 | 核心流程，频繁回归 | 登录/出生/背包/HUD/银行存取 |
| P1 | 安全关键，防刷漏洞 | 客户端伪造事件拦截、警察门槛 |
| P2 | 常规功能，偶发回归 | 子账户销户退款、流水记录 |
| P3 | 边缘场景，低频使用 | 重名开户幽灵数据、ATM 净化 |

---

## 6. 执行流程与 CI 集成

### 6.1 开发工作流中的测试位置

```
改代码 → 跑离线检测 (Layer 1) → 发现问题？→ 修
    ↓ 通过
启动服务器 → 跑游戏内测试 (Layer 2) → 发现问题？→ 修
    ↓ 通过
更新 PROJECT_PROGRESS.md → 提交 commit
```

### 6.2 单人测试策略

由于你是单人开发，建议的测试节奏：

| 场景 | 做法 |
|------|------|
| **改了一个 cfg** | `python tests/run_all.py` (3 秒) |
| **改了一段 Lua 逻辑** | `python tests/check_lua_syntax.py` + 进游戏 `/test run <模块>` |
| **完成一个功能模块** | 完整的 Layer 1 + Layer 2 + 手动验证关键路径 |
| **版本迭代节点** | 全部 5 个测试套件跑一遍，输出报告存档到 `logs/` |

### 6.3 测试报告模板

每次测试结果存到 `logs/` 目录：

```markdown
# Test Report: v0.5-crime-2026-06-01

## Layer 1: Offline
- [PASS] CFG Integrity: 54 resources
- [PASS] Lua Syntax: 0 warnings
- [PASS] DB Schema: 6 tables
- [PASS] Dependencies: no cycles

## Layer 2: In-Game
- [PASS] banking: 8/8
- [PASS] police: 5/5
- [FAIL] crime: 3/4  ← 用例 3.2 失败：冷却时间未生效
- [SKIP] security: not implemented
- [PASS] persistence: 5/5

## Summary
14/15 PASS, 1 FAIL, 1 SKIP
Next action: fix crime cooldown logic in custom-crime
```

---

## 7. Roadmap

| 阶段 | 内容 | 预计工时 | 前置条件 |
|------|------|---------|---------|
| **Phase 1** | 离线检测脚本 (check_cfgs + check_lua + check_db + run_all) | 1 天 | Python 3.12 + luacheck |
| **Phase 2** | 游戏内测试框架 (custom-testing 资源骨架 + test_runner) | 1 天 | FiveM 服务器可运行 |
| **Phase 3** | 银行系统测试套件 (01_banking_test.lua) | 0.5 天 | Phase 2 完成 |
| **Phase 4** | 犯罪系统测试套件 (03_crime_test.lua) | 0.5 天 | v0.5 犯罪系统开发完成 |
| **Phase 5** | 安全边界测试套件 (04_security_test.lua) | 1 天 | v0.3 security 模块 |
| **Phase 6** | CI 集成 + 测试报告自动生成 | 0.5 天 | Phase 1~5 稳定 |

---

## 附录：现有手动测试用例 → 自动化映射表

| 手册 | 用例数 | 可自动化 | 优先级 | 对应测试套件 |
|------|--------|---------|--------|------------|
| v0.2-test-checklist.md 模块一（职业） | ~6 | 3 | P2 | 待建 |
| v0.2-test-checklist.md 模块二（银行） | ~8 | 8 | P0 | `01_banking_test.lua` |
| v0.3-test-manual.md 用例 1.1~1.4（银行） | 4 | 4 | P0 | `01_banking_test.lua` |
| v0.3-test-manual.md 用例 2.1~2.4（经济/日志） | 4 | 2 | P1 | `04_security_test.lua` |
| v0.5-crime-gameplay.md 安全测试 | 4 | 4 | P0 | `04_security_test.lua` |
| v0.2-wanted-handover-test-guide.md | 7 | 5 | P1 | `02_police_test.lua` |
| v0.2-status-persistence-test-report.md | 5 | 5 | P1 | `05_persistence_test.lua` |
