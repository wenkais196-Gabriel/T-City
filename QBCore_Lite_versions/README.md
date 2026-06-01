# QBCore Lite 版本迭代纲要

来源文档：`D:\txData\QBCore_Lite_技术讨论.md`  
实施蓝图：`C:\Users\swkgb\.gemini\antigravity\brain\f874b9da-b66b-4e1f-8f41-ad8647d1bdba\implementation_plan.md`

目标是把当前完整 QBCore base 改造成精简、模块化、可扩展、边界清晰的 Lite Server Pack，并在 8 周内上线 v1.0 开放公测。

---

## 核心架构决策

| 决策 | 结论 |
|------|------|
| 交互入口 | **Phone-First**：所有系统交互通过手机完成；NPC 只用于商店等必须线下存在的场景 |
| 手机系统 | **自研** `custom-phone`（Svelte + Vite），不使用 qb-phone |
| 职业身份 | **多标签体系**（职业标签 + 层级标签 + 部门标签），扩展 QBCore 原生 job+grade |
| 领袖终端 | **手机内专属 App**（`rank_tier=leader` 时动态解锁），无物理终端实体 |
| 开发模式 | **三轨并行**（基础设施 + 特色系统 + 民间经济） |
| Beta 定位 | **开放公测** → 积累社群 → 视情况转白名单私服 |

---

## 基础原则

- 不直接大改 `qb-core` 本体。
- 保留原始 `QBCore_CDB34E.base`，新建 Lite base 作为改造对象。
- 不再使用 `ensure [qb]` 一次性加载全部资源。
- 通过白名单资源和模块 cfg 控制启动顺序。
- 自定义逻辑放在 `[custom]` 下。
- 每个版本都要能启动、能回滚、能记录缺失依赖。

---

## 推荐目录

```text
D:\txData\T-CityLite.base
D:\txData\T-CityLite.base\configs\modules
D:\txData\T-CityLite.base\resources\[custom]
```

模块配置：

```text
configs\modules\core.cfg
configs\modules\player.cfg
configs\modules\voice.cfg
configs\modules\economy.cfg
configs\modules\security.cfg
configs\modules\career.cfg
configs\modules\civilian-economy.cfg
configs\modules\jobs.cfg
configs\modules\police.cfg
configs\modules\medical.cfg
configs\modules\banking.cfg
configs\modules\vehicles.cfg
configs\modules\crime.cfg
configs\modules\leaders.cfg
configs\modules\catalysts.cfg
configs\modules\admin.cfg
configs\modules\logs.cfg
configs\modules\wiki.cfg
```

---

## 版本路线

### 已完成

- [v0.1 精简启动](./v0.1-lite-startup.md) ✅
- [v0.2 基础 RP](./v0.2-basic-rp.md) ✅

### v1.0 开发周期（8 周并行推进）

**三轨并行**：

| 轨道 | 文件 | 说明 |
|------|------|------|
| A - 基础设施 | [v0.3 基础设施层](./v0.3-economy.md) | 经济/安全/职业体系/服装/帮派/门锁/Admin/Discord |
| B - 特色系统 | [v0.4 自研手机](./v0.4-custom-phone.md) | Phone-First + Job Board + 职业频道 + 领袖 App |
| A - 基础设施 | [v0.5 犯罪玩法](./v0.5-crime-gameplay.md) | 便利店抢劫 + 毒品（供应链联动） |
| C - 民间经济 | [v0.6a 民间经济](./v0.6a-civilian-economy.md) | 矿工/渔民/农民/货运/机修（5职业） |
| B - 特色系统 | [v0.6b 沙盒社会生态](./v0.6-sandbox-sociology.md) | 三线领袖 + 催化剂卡牌 + 盲盒百科 |
| 发布 | [v1.0 Beta 上线](./v1.0-beta-launch.md) | 联调验收 + 运营准备 + 发布清单 |

### v1.0 之后（上线后迭代）

- [v0.7 硬核原位登录](./v0.7-hardcore-spawn-system.md)（v1.3 实现）
- [v0.8 多语言本土化](./v0.8-localization-adaptation.md)（v1.4 实现）

---

## 周度推进时间线

```
周次    1    2    3    4    5    6    7    8
        ──────────────────────────────────────────
A轨   [v0.3经济+安全][服装][职业标签+帮派+门锁][v0.5犯罪][Admin+Discord]
B轨        [手机脚手架──────────────────][v0.6b三线领袖──][卡牌+Wiki]
C轨             [民间经济DB][矿工][货运][供应链联调──────]
                                                        ↓
                                                v1.0 Beta 上线
```

---

## 每版通用验收标准

- 服务端能启动，无阻塞级报错。
- 玩家能进入服务器并完成当前版本核心流程。
- `server.cfg` 只加载当前版本需要的模块。
- 新增资源记录依赖、启动顺序和禁用原因。
- 高风险服务端事件列入安全审计清单。
- 所有资金变更经过 `AddScaledMoney` 统一出口（v0.3 之后）。

---

## 自定义资源清单（v1.0 目标）

| 资源 | 说明 | 版本 |
|------|------|------|
| `custom-main` | 核心工具函数（AddScaledMoney 等） | v0.3 |
| `custom-economy` | 统一经济出口、倍率配置、经济日志 | v0.3 |
| `custom-security` | Rate Limit、事件校验、伪造拦截 | v0.3 |
| `custom-career` | 多标签职业体系 API | v0.3 |
| `custom-admin` | 管理员指令（setleader/demote/settier） | v0.3 |
| `custom-logs` | Discord Webhook 5 频道审计 | v0.3 |
| `custom-phone` | 自研手机（Svelte + Vite） | v0.4 |
| `custom-mining` | 矿工系统（自研） | v0.6a |
| `custom-trucking` | 货运系统（自研，接 Job Board） | v0.6a |
| `custom-leaders` | 三线领袖业务逻辑（无 UI） | v0.6b |
| `custom-catalysts` | 催化剂卡牌系统 | v0.6b |
| `custom-wiki` | 游戏内百科（Anti-Meta-Gaming） | v0.6b |
