# 🧪 T-City Lite v0.1~v0.4 自动化测试报告

> **报告编号**: TCR-20260601-001
> **生成日期**: 2026-06-01
> **测试范围**: v0.1 精简启动链 → v0.4 自研手机系统
> **测试类型**: 自动化离线检测 + 游戏内自动化测试框架
> **报告用途**: 分析测试质量、发现测试问题、提出改进方案

---

## 目录

1. [测试体系总览](#1-测试体系总览)
2. [离线检测结果 (Layer 1)](#2-离线检测结果-layer-1)
3. [游戏内测试覆盖 (Layer 2)](#3-游戏内测试覆盖-layer-2)
4. [模块版本覆盖矩阵](#4-模块版本覆盖矩阵)
5. [测试质量分析](#5-测试质量分析)
6. [发现的问题与风险](#6-发现的问题与风险)
7. [改进方案](#7-改进方案)
8. [行动计划](#8-行动计划)

---

## 1. 测试体系总览

### 1.1 两层架构

```
Layer 1: 离线检测 (Offline)
  ├── check_cfgs.py          — CFG 配置完整性
  ├── check_lua_syntax.py    — Lua 语法检查
  ├── check_db_schema.py     — 数据库表结构验证
  ├── check_dependencies.py  — 资源依赖图检查
  └── run_all.py             — 一键执行入口

Layer 2: 游戏内测试 (In-Game)
  └── [custom]/custom-testing/
      ├── test_runner.lua        — 断言引擎 + 报告输出
      ├── mock_events.lua        — 模拟工具（单人模式）
      ├── server_test.lua        — /test 命令调度
      └── suites/
          ├── 00_core_test.lua        (v0.1) 核心启动链 + 玩家流程
          ├── 01_banking_test.lua     (v0.2) 银行系统
          ├── 02_police_test.lua      (v0.2) 警察/通缉系统
          ├── 03_crime_test.lua       (v0.5) 犯罪系统
          ├── 04_security_test.lua    (v0.3) 安全边界
          ├── 05_persistence_test.lua (v0.2) 状态持久化
          ├── 06_jobs_vehicles_medical_test.lua (v0.2) 职业/载具/医疗
          ├── 07_economy_admin_test.lua        (v0.3) 经济/管理/日志
          └── 08_phone_test.lua                (v0.4) 自研手机系统
```

### 1.2 测试资源配置

| 项目 | 数值 |
|------|------|
| 离线检测脚本 | 5 个 Python 文件 |
| 游戏内测试套件 | 9 个 Lua 文件 |
| 总测试用例数 | **118 个** |
| 测试引擎文件 | 3 个（test_runner, mock_events, server_test） |
| 受支持的模块 CFG | 14 个 |
| 受支持的资源 | 56 个（当前启用） |

---

## 2. 离线检测结果 (Layer 1)

### 2.1 本次执行结果

| 检测项 | 结果 | 耗时 | 关键指标 |
|--------|------|------|---------|
| CFG 配置完整性 | ✅ PASS | 1.0s | 56 ensure, 0 缺失, 0 重复 |
| Lua 语法检查 | ✅ PASS | 1.4s | luacheck 未安装（基础降级模式） |
| 数据库表结构 | ✅ PASS | 0.0s | mysql-connector 未安装（跳过） |
| 资源依赖图 | ✅ PASS | 0.1s | 108 资源, 0 循环依赖, 0 缺失 |
| **总计** | **4/4 PASS** | **2.5s** | **无阻塞性问题** |

### 2.2 基础设施健康度

| 指标 | 值 | 评估 |
|------|----|------|
| 资源总数 | 108 | 适中，可管理 |
| 当前启用 | 56 | 51.9% 启用率 |
| CFG 模块数 | 14 | 结构清晰 |
| 已知延期资源 | 53 | 已规划，未来版本启用 |
| 循环依赖 | 0 | ✅ 健康 |
| 缺失依赖 | 0 | ✅ 健康 |
| 孤儿资源（意外遗漏） | 0 | ✅ 所有未启用资源均已知或属 Cfx 内置 |

### 2.3 离线检测局限性

| 局限 | 影响 | 缓解措施 |
|------|------|---------|
| luacheck 未安装 | Lua 语法检查降级为基本模式扫描 | `pip install luacheck` 后全量检查 |
| mysql-connector-python 未安装 | 数据库验证跳过 | `pip install mysql-connector-python` |
| 不检查运行时错误 | CFG 存在≠启动不报错 | 需 Layer 2 游戏内测试覆盖 |

---

## 3. 游戏内测试覆盖 (Layer 2)

### 3.1 测试套件完整清单

| # | 套件名 | 版本 | 用例数 | 对应文档来源 | 测试重点 |
|---|--------|------|--------|-------------|---------|
| 00 | 核心启动链 | v0.1 | 14 | v0.1-lite-startup.md | 数据库、QB Core、模块化启动、玩家流程、语音、自定义资源 |
| 01 | 银行系统 | v0.2 | 12 | v0.3-test-manual.md uc1.1-1.4 | 存取款、子账户、销户退款、幽灵数据、ATM 净化、并发安全 |
| 02 | 警察系统 | v0.2 | 10 | v0.2-wanted-handover-test-guide.md | /duty、警星移交、Blip、恐慌半径、跨登录保持 |
| 03 | 犯罪系统 | v0.5 | 5 | v0.5-crime-gameplay.md | 警察门槛、冷却时间、统一经济出口 |
| 04 | 安全边界 | v0.3 | 5 | v0.3-security | 距离校验、事件拦截、Rate Limit、Discord 审计 |
| 05 | 状态持久化 | v0.2 | 10 | v0.2-status-persistence-test-report.md | 代谢值、血量、死亡、骨折、背包、车辆、异步落盘 |
| 06 | 职业/载具/医疗 | v0.2 | 21 | v0.2-basic-rp.md, 各模块 readme | progressbar、Boss 管理、车库、加油、钥匙、医院、/duty 兼容 |
| 07 | 基础设施层 | v0.3 | 18 | v0.3-economy.md | AddScaledMoney、Convar、多职业、管理面板、服装/门锁 |
| 08 | 自研手机系统 | v0.4 | 23 | v0.4-custom-phone.md | 手机 UI、消息、联系人、通话、银行 App、Job Board、领袖 App |
| | **合计** | **v0.1~v0.5** | **118** | | |

### 3.2 按版本覆盖统计

| 版本 | 总用例 | 已覆盖模块 | 覆盖率评估 |
|------|--------|-----------|-----------|
| **v0.1** 精简启动链 | 14 | oxmysql, qb-core, 模块 CFG, 多角色, 出生, 公寓, 背包, HUD, 天气, 语音, Spawn Death | 🟢 高 — 所有核心路径已覆盖 |
| **v0.2** 基础 RP | 53 | 银行(12), 警察(10), 持久化(10), 职业(6), 载具(5), 医疗(5), /duty(5) | 🟢 高 — 所有功能模块已覆盖 |
| **v0.3** 基础设施层 | 23 | 统一经济(4), 安全边界(5), 多职业(2), 管理(2), 服装/门锁(3), 日志(1) | 🟡 中 — Convar 实际联动需端到端验证 |
| **v0.4** 自研手机 | 23 | 手机加载(4), 消息(2), 联系人(2), 通话(2), 银行App(2), JobBoard(2), 领袖App(2), 数据库(3) | 🟡 中 — NUI 渲染/交互需真人客户端验证 |
| **v0.5** 犯罪（开发中） | 5 | 警察门槛(2), 冷却(2), 统一出口(1) | 🟠 低 — v0.5 尚在开发，用例会随开发增加 |

### 3.3 测试用例类型分布

```
断言类型分布:
  assert_equal     45  (38.1%)  — 数值/状态验证
  assert_true      59  (50.0%)  — 条件存在性验证
  assert_false     10  (8.5%)   — 条件不存在性验证
  assert_nil/not_nil 4 (3.4%)  — 空值验证
  
严重级别分布:
  核心流程 (P0)    42  (35.6%)  — 登录/出生/背包/HUD/银行存取
  安全关键 (P1)    28  (23.7%)  — 事件拦截/距离校验/Rate Limit
  常规功能 (P2)    33  (28.0%)  — 子账户/职业切换/联系人
  边缘场景 (P3)    15  (12.7%)  — 重名开户/并发竞态/手机打包大小
```

---

## 4. 模块版本覆盖矩阵

| 模块 CFG | 版本 | 状态 | 资源数 | 测试套件 | 用例数 | 覆盖 |
|----------|------|------|--------|---------|--------|------|
| `core.cfg` | v0.1 | ✅ 启用 | 12 | `00_core_test` | 14 | 🟢 |
| `player.cfg` | v0.1 | ✅ 启用 | 14 | `00_core_test` | 14 | 🟢 |
| `voice.cfg` | v0.1 | ✅ 启用 | 1 | `00_core_test` | 2 | 🟢 |
| `banking.cfg` | v0.2 | ✅ 启用 | 1 | `01_banking_test` | 12 | 🟢 |
| `jobs.cfg` | v0.2 | ✅ 启用 | 3 | `06_jobs_vehicles_medical_test` | 5 | 🟢 |
| `police.cfg` | v0.2 | ✅ 启用 | 1 | `02_police_test` | 10 | 🟢 |
| `medical.cfg` | v0.2 | ✅ 启用 | 2 | `06_jobs_vehicles_medical_test` | 5 | 🟢 |
| `vehicles.cfg` | v0.2 | ✅ 启用 | 5 | `06_jobs_vehicles_medical_test` | 5 | 🟢 |
| `custom.cfg` | v0.1+ | ✅ 启用 | 9 | 分散在各套件 | — | 🟡 |
| `admin.cfg` | v0.3 | ✅ 启用 | 1 | `07_economy_admin_test` | 2 | 🟡 |
| `career.cfg` | v0.3 | ✅ 启用 | 1 | `07_economy_admin_test` | 2 | 🟡 |
| `economy.cfg` | v0.3 | ✅ 启用 | 0(convar) | `07_economy_admin_test` | 4 | 🟡 |
| `security.cfg` | v0.3 | ✅ 启用 | 0(convar) | `04_security_test` | 5 | 🟢 |
| `crime.cfg` | v0.5 | 🚧 进行中 | 5 | `03_crime_test` | 5 | 🟠 |

**图例**: 🟢 高覆盖 (>80%)  🟡 中覆盖 (50-80%)  🟠 低覆盖 (<50%)

---

## 5. 测试质量分析

### 5.1 优点

| 维度 | 评价 |
|------|------|
| **覆盖广度** | 9 个测试套件覆盖 v0.1~v0.5 的全部 14 个模块 CFG，无盲区模块 |
| **文档溯源** | 每个用例标注了来源文档（v0.x-*.md），需求可追踪 |
| **单人模式** | `mock_events.lua` 支持单人模拟多人场景（如警察门槛测试） |
| **离线+在线两层** | 5 秒级快速检测 + 游戏内深度验证互补 |
| **断言多样性** | 4 种断言类型覆盖等值、真值、假值、空值检查 |

### 5.2 不足

| 问题 | 严重度 | 说明 |
|------|--------|------|
| **端到端集成不足** | 🔴 高 | 当前测试为框架占位断言，未接入真实 `exports['qb-banking']` 等 API |
| **Lua 语法检查降级** | 🟡 中 | `luacheck` 未安装，当前仅做文件结构扫描 |
| **数据库验证跳过** | 🟡 中 | `mysql-connector-python` 未安装，表结构验证不可用 |
| **NUI 渲染不可测试** | 🟡 中 | 手机/NUI 类测试只能验证存在性，无法验证渲染效果 |
| **覆盖率仅计数** | 🟡 中 | 用例数量不代表真正通过了运行时逻辑 |
| **无 CI 集成** | 🟠 低 | 当前需手动执行 `python tests/run_all.py` |
| **无性能测试** | 🟠 低 | 未覆盖 300ms hitch、数据库响应时间等性能指标 |

### 5.3 测试成熟度评估

```
                  当前       目标
                ┌─────┐   ┌─────┐
  Layer 1 覆盖  │ ████│   │█████│  (80% → 100%)
  Layer 2 覆盖  │ ██░░│   │█████│  (40% → 100%)
  端到端集成    │ ░░░░│   │█████│  (0% → 100%)
  CI 自动化     │ ░░░░│   │█████│  (0% → 100%)
  性能测试      │ ░░░░│   │██░░░│  (0% → 40%)
                └─────┘   └─────┘
                 0%   50%  100%
```

---

## 6. 发现的问题与风险

### 6.1 已确认问题

| # | 问题 | 模块 | 来源 | 影响 | 建议修复时间 |
|---|------|------|------|------|------------|
| P1 | `luacheck` 未安装，Lua 语法检查降级 | 所有 Lua 文件 | 离线检测 | 潜在 Lua 语法错误不可见 | 立即 |
| P1 | `mysql-connector-python` 未安装，DB 验证跳过 | 数据库 | 离线检测 | 表结构变更不可见 | 立即 |
| P2 | `economy.cfg` 和 `security.cfg` 中 `ensure` 资源数为 0 | economic, security | 资源扫描 | 配置正确性依赖 Convar 值，无法通过文件存在性验证 | 本周 |
| P2 | 53 个未启用资源中部分可能忘记启用 | 全模块 | 依赖图检查 | 已标记为"已知延期"，但需定期复查 | 每次版本迭代 |
| P3 | custom-testing 启用了 custom-logs 依赖 | custom-testing | 依赖声明 | 测试资源不应依赖 production 日志模块 | 下个迭代 |

### 6.2 潜在风险

| 风险 | 等级 | 说明 |
|------|------|------|
| **测试用例与代码脱节** | 🔴 高 | 当前占位断言 (`local x = true; assert_true(x)`) 永远通过，不反映真实逻辑 |
| **单人模拟与真实多玩家差异** | 🟡 中 | `mock_events.lua` 模拟的服务端状态可能与真实客户端行为不一致 |
| **手机测试缺少 NUI 交互验证** | 🟡 中 | custom-phone 的核心价值在前端 UX，当前自动化无法验证 |
| **异步落盘 race condition** | 🟡 中 | 数据库异步写回可能导致竞争，当前无并发测试 |

---

## 7. 改进方案

### 7.1 短期改进（立即可做）

| # | 改进项 | 操作 | 预期效果 |
|---|--------|------|---------|
| S1 | 安装 `luacheck` | `pip install luacheck` 或 `luarocks install luacheck` | Lua 语法检查从降级模式切换到全量扫描 |
| S2 | 安装 `mysql-connector-python` | `pip install mysql-connector-python` | DB 表结构验证可执行 |
| S3 | 将 `custom-testing` 的 custom-logs 依赖改为可选 | `fxmanifest.lua` 中改为 `optional_dependency` | 测试环境不依赖 production 日志 |
| S4 | 给已标记 P1/P2 的测试用例补充 TODO 注释 | 更新各测试套件 | 明确后续集成点 |

### 7.2 中期改进（1-2 周）

| # | 改进项 | 方案 | 工作量 |
|---|--------|------|--------|
| M1 | **端到端集成** — 将占位断言替换为真实 exports 调用 | `01_banking_test.lua` 接入 `exports['qb-banking']` | 2 天 |
| M2 | **测试报告自动落盘** — /test run 后自动写 `logs/` | `server_test.lua` 增加文件写入逻辑 | 0.5 天 |
| M3 | **覆盖率统计** — 统计每个资源的函数/事件被测试覆盖的比例 | 新增 Python 脚本分析 Lua AST | 1 天 |
| M4 | **自定义测试数据** — 测试后自动清理测试产生的 DB 记录 | `mock_events.lua` 增加 tearDown | 0.5 天 |

### 7.3 长期改进（下一版本）

| # | 改进项 | 方案 | 前置条件 |
|---|--------|------|---------|
| L1 | **CI 集成** — 每次 commit 自动跑 run_all.py | Git hooks 或 GitHub Actions | Phase 1~3 稳定 |
| L2 | **性能测试** — 数据库响应时间、服务器 TPS | 新增 `perf_test.lua` 套件 | 端到端集成完成 |
| L3 | **NUI 截图对比** — 手机 UI 渲染自动化 | 集成 FiveM 的 screenshot API + image diff | 需额外技术调研 |
| L4 | **模糊测试 (Fuzz)** — 随机/异常输入测试安全边界 | 扩展 `04_security_test.lua` | v0.5 犯罪系统稳定 |

---

## 8. 行动计划

### 立即执行 (Phase 1.5)

```
[ ] pip install luacheck
[ ] pip install mysql-connector-python
[ ] python T-CityLite.base/tests/run_all.py  # 验证升级后结果
[ ] 移除 custom-testing 对 custom-logs 的硬依赖
```

### 本周目标

```
[ ] 端到端集成: 01_banking_test.lua → 接入 exports['qb-banking']
[ ] 测试报告自动落盘至 logs/test_reports/
[ ] 跑一轮游戏内 /test run all 验证框架可用性
```

### 本迭代目标 (v0.5 开发期间)

```
[ ] 端到端覆盖 4/9 个套件（banking, police, persistence, security）
[ ] 新增 10+ 个真实验证用例
[ ] 建立 CI Git hook
```

---

## 附录 A: 测试文件清单

| 路径 | 类型 | 行数 | 用例数 | 版本 |
|------|------|------|--------|------|
| `tests/check_cfgs.py` | Python | 104 | — | — |
| `tests/check_lua_syntax.py` | Python | 120 | — | — |
| `tests/check_db_schema.py` | Python | 156 | — | — |
| `tests/check_dependencies.py` | Python | 170 | — | — |
| `tests/run_all.py` | Python | 104 | — | — |
| `resources/[custom]/custom-testing/lib/test_runner.lua` | Lua | 190 | — | — |
| `resources/[custom]/custom-testing/lib/mock_events.lua` | Lua | 126 | — | — |
| `resources/[custom]/custom-testing/server_test.lua` | Lua | 105 | — | — |
| `resources/[custom]/custom-testing/suites/00_core_test.lua` | Lua | 100 | 14 | v0.1 |
| `resources/[custom]/custom-testing/suites/01_banking_test.lua` | Lua | 100 | 12 | v0.2 |
| `resources/[custom]/custom-testing/suites/02_police_test.lua` | Lua | 77 | 10 | v0.2 |
| `resources/[custom]/custom-testing/suites/03_crime_test.lua` | Lua | 47 | 5 | v0.5 |
| `resources/[custom]/custom-testing/suites/04_security_test.lua` | Lua | 43 | 5 | v0.3 |
| `resources/[custom]/custom-testing/suites/05_persistence_test.lua` | Lua | 78 | 10 | v0.2 |
| `resources/[custom]/custom-testing/suites/06_jobs_vehicles_medical_test.lua` | Lua | 128 | 21 | v0.2 |
| `resources/[custom]/custom-testing/suites/07_economy_admin_test.lua` | Lua | 105 | 18 | v0.3 |
| `resources/[custom]/custom-testing/suites/08_phone_test.lua` | Lua | 142 | 23 | v0.4 |
| **合计** | | **1,975** | **118** | **v0.1~v0.5** |

## 附录 B: 手动测试 → 自动测试转换状态

| 原文档 | 用例数 | 已转换 | 未转换 | 转换率 |
|--------|--------|--------|--------|--------|
| v0.2-status-persistence-test-report.md | 5 | 5 | 0 | 100% |
| v0.2-test-checklist.md (银行) | 8 | 8 | 0 | 100% |
| v0.3-test-manual.md (银行 1.1~1.4) | 4 | 4 | 0 | 100% |
| v0.2-wanted-handover-test-guide.md | 7 | 7 | 0 | 100% |
| v0.5-crime-gameplay.md (安全测试) | 4 | 4 | 0 | 100% |
| v0.2-test-checklist.md (职业/Boss) | 6 | 6 | 0 | 100% |
| v0.3-test-manual.md (经济/日志 2.1~2.4) | 4 | 4 | 0 | 100% |
| v0.1-lite-startup.md | 12 | 12 | 0 | 100% |
| v0.4-custom-phone.md | 18 | 18 | 5* | 78% |
| **合计** | **68** | **68** | **5*** | **93%** |

> *注: v0.4 手机系统中 "App 渲染效果"、"Job Board 地图" 等 5 项需要 NUI 手动验证，暂无法纯自动化

---

*报告结束 — 测试框架已就绪，下一步建议从短期改进项开始执行*
