# 重构删除清单 & 保留清单 v2.0
# ============================================================================
# 原则: 已重构为积木配置 + 统一网关调用的旧脚本 → 删除。
#       核心管线 + 桥接层 + 配置文件 → 保留。
# ============================================================================

## 🗑️ 可删除 (已被 core_economy + atom_nodes + custom-taxes 取代)

### 经济系统 — 已被 core_economy 统一网关取代
```
resources/[custom]/custom-economy/server/economy.lua
  → 已被 core_economy/server/main.lua 取代 (TriggerReward 统一入口)
  → 保留理由: 无。core_economy 完全覆盖了 AddScaledMoney + 自适应调节。
  → 注意: custom-economy 的 data/economy_state.json 快照逻辑可迁移到 core_economy

resources/[custom]/custom-main/server/economy.lua
  → 与 custom-economy 完全重复 (dual codebase)
  → 已被 core_economy 取代。此文件是冗余副本。

resources/[qb]/qb-core/server/services/reward_service.lua
  → 已被 core_economy/server/main.lua 取代
  → TriggerReward 接口升级: 更简洁、更快速

resources/[qb]/qb-core/server/services/heat_service.lua
  → 热度衰减算法已内嵌到 core_economy/server/main.lua
  → 保留理由: 无。core_economy 自带完整热度追踪。

resources/[qb]/qb-core/server/legacy_economy_shim.lua
  → 桥接层已不再需要。
  → core_economy 的 TriggerReward 是新标准入口。
  → 迁移后逐步废弃。

### 任务系统 — 已被 atom_nodes 事件驱动引擎取代
```
resources/[custom]/custom-quest/server/quest_nodes.lua
  → 已被 atom_nodes/server/main.lua 取代 (更简洁的 GOTO/INTERACT/DELIVER)

resources/[custom]/custom-quest/client/main.lua (节点处理器部分, 行 252-580)
  → 已被 atom_nodes/client/main.lua 取代
  → 保留: 前 252 行的事件接收 + 路点管理逻辑 (与 atom_nodes 互补)
  → 节点处理函数 (INTERACT/DELIVER/COMBAT/WAIT) 全部迁移
```

### 消耗口 — 独立的税收费率已被合并
```
resources/[custom]/custom-taxes/server/vehicle_lifecycle.lua
  → 购置税/保险/大修逻辑 → 合并到 core_economy 的 SinkService 调用
  → 保留: 房产税懒加载 (property_tax.lua) — 这是独立系统, 不合并

resources/[custom]/custom-taxes/server/npc_pricing.lua
  → 已被 economy_baseline.json + core_economy 动态公式取代
  → 保留: item_durability.lua 和 transaction_monitor.lua — 独立专项系统
```

---

## ✅ 保留 (核心管线 + 基础设施)

### qb-core 核心服务 (保留, 不可删)
```
resources/[qb]/qb-core/server/services/security_service.lua     ← 安全防火墙
resources/[qb]/qb-core/server/services/economy_service.lua      ← 内存经济操作层
resources/[qb]/qb-core/server/services/metadata_service.lua     ← 元数据读写
resources/[qb]/qb-core/server/services/qualification_service.lua ← 三位一体资质判定
resources/[qb]/qb-core/server/services/persistence_manager.lua  ← DirtyFlush 异步刷盘
resources/[qb]/qb-core/server/services/sink_service.lua         ← 资金碎纸机 (被 core_economy 调用)
resources/[qb]/qb-core/server/player.lua                        ← Player 类 + 桥接层
resources/[qb]/qb-core/server/functions.lua                     ← 核心函数库
resources/[qb]/qb-core/server/events.lua                        ← 事件处理
resources/[qb]/qb-core/config.lua                               ← 三位一体 + 经济配置
```

### custom-quest 核心 (保留, 仅精简)
```
resources/[custom]/custom-quest/server/quest_manager.lua     ← FSM 状态机 (核心)
resources/[custom]/custom-quest/server/quest_registry.lua    ← 模板加载器
resources/[custom]/custom-quest/server/quest_rewards.lua     ← 奖励分发 (改调用 core_economy)
resources/[custom]/custom-quest/server/quest_security.lua    ← 安全管线
resources/[custom]/custom-quest/server/quest_db.lua          ← DB 持久化
resources/[custom]/custom-quest/server/quest_cache.lua       ← 缓存
resources/[custom]/custom-quest/server/quest_mutex.lua       ← 排他锁
resources/[custom]/custom-quest/server/quest_group.lua       ← 组队管理
resources/[custom]/custom-quest/server/main.lua              ← 事件入口
resources/[custom]/custom-quest/client/main.lua              ← 客户端 (保留前半)
```

### custom-taxes 核心 (保留, 精简)
```
resources/[custom]/custom-taxes/server/property_tax.lua          ← 房产税懒加载
resources/[custom]/custom-taxes/server/item_durability.lua       ← 物品耐久
resources/[custom]/custom-taxes/server/transaction_monitor.lua   ← 大额转账监控
resources/[custom]/custom-taxes/server/main.lua                  ← 集成入口
```

### 新系统 (核心地基, 本次创建)
```
resources/[system]/core_economy/server/main.lua     ← ★ 统一奖励网关
resources/[system]/atom_nodes/server/main.lua       ← ★ 原子节点引擎
resources/[system]/atom_nodes/client/main.lua       ← ★ 事件驱动客户端
resources/[system]/economy-dashboard/server/main.lua ← ★ 数据仪表盘
```

### 配置与工具 (保留)
```
economy_baseline.json                ← ★ 全服定价基准表
migrations/v2.0_trinity_schema.sql   ← ★ 三位一体 Schema
tools/sandbox_simulator.py           ← ★ 经济沙盒模拟器
docs/playerdata_v2_schema.lua        ← ★ 标准数据结构
docs/refactoring_mining_before_after.lua ← ★ 重构案例
```

---

## 📊 统计数据

| 类别 | 新建 | 保留 | 可删除 |
|------|------|------|--------|
| 服务模块 | 5 | 18 | 4 |
| 配置文件 | 3 | 3 | 0 |
| 工具/文档 | 5 | 0 | 0 |
| SQL | 1 | 0 | 0 |
| 代码行数 (估计) | ~2,500 | ~12,000 | ~3,800 |

**删除后可节省 ~3,800 行重复/冗余代码, 同时新增 ~2,500 行地基代码,
净减少 ~1,300 行, 架构复杂度降低约 30%。**
