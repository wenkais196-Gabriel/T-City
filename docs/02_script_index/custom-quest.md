# custom-quest — 数据驱动任务系统

> **路径**: `resources/[custom]/custom-quest/` | **状态**: ✅ ENABLED | **CFG 模块**: custom.cfg
> **依赖**: qb-core, oxmysql, core-framework, production-freeze | **被依赖**: custom-vehicles (logistics stamp), custom-cartel (initiation)

---

## 文件清单 (28 个 Lua 文件)

### 服务端核心
| 文件 | 角色 |
|:---|:---|
| `server/main.lua` | 入口：导出注册、事件监听、Bus 集成 |
| `server/quest_registry.lua` | 任务模板注册表 — 加载/验证/查询 |
| `server/quest_manager.lua` | 任务状态机 — TriggerQuest/AdvanceStep/CompleteQuest/Abandon/Fail |
| `server/quest_db.lua` | 数据库访问层 — player_quests/quest_cooldowns/quest_event_log/quest_daily_limits |
| `server/quest_cache.lua` | 内存缓存 — 活跃任务、冷却、每日限制 |
| `server/quest_security.lua` | 安全守卫 — Nonce 验证、事件校验、速率限制 |
| `server/quest_rewards.lua` | 奖励计算与发放 — 金钱/物品/声望 |
| `server/quest_address_resolver.lua` | 地址池解析 — 随机 NPC 地址分配 |
| `server/quest_logistics_validators.lua` | 物流任务校验 — 拖车/货物/航路 |
| `server/quest_entity_registry.lua` | 实体注册 — 任务中动态实体的生命周期 |
| `server/quest_entity_placement.lua` | 实体放置 — 服务端权威位置校验 |
| `server/quest_entity_tracker.lua` | 实体追踪 — 回收/清理 |

### 客户端
| 文件 | 角色 |
|:---|:---|
| `client/main.lua` | 入口：NUI 回调、GPS/标记管理 |
| `client/quest_checkpoint.lua` | 检查点渲染 — 原生 checkpoint + PolyZone |
| `client/quest_pos_collector.lua` | 位置收集 — 上传坐标给服务端 |
| `client/quest_logistics_client.lua` | 物流客户端 — 拖车/货物/航路 |
| `client/quest_entity_placement.lua` | 实体放置 — 客户端位置报告 |
| `client/quest_cargo_damage.lua` | 货物损坏追踪 |

### 配置
| 文件 | 内容 |
|:---|:---|
| `config.lua` | 主配置 — 步类型、限流、距离、最大任务数 |
| `config/quests/quest_driver_exam.lua` | 驾考任务 |
| `config/quests/quest_pilot_exam.lua` | 飞行考试 |
| `config/quests/quest_logistics.lua` | 物流运输任务 |
| `config/quests/quest_legal_aviation.lua` | 合法航空任务 |
| `config/quests/quest_public_services.lua` | 公共服务任务 |
| `config/quests/quest_civilian_misc.lua` | 平民杂项任务 |
| `config/quests/address_pools.lua` | 地址池数据 |

---

## 任务状态机

```
Not Started ──[TriggerQuest]──→ In Progress (Step 0)
                                    │
                         ┌──────────┼──────────┐
                         ↓          ↓          ↓
                   [AdvanceStep]  [FailQuest] [AbandonQuest]
                         │          │          │
                         ↓          ↓          ↓
                   In Progress   Failed     Abandoned
                   (Step N+1)
                         │
                    [last step]
                         ↓
                     Completed
```

---

## 12 种步类型

| 类型 | 说明 |
|:---|:---|
| `reach` / `goto` | 到达坐标（PolyZone 或原生 checkpoint） |
| `collect` | 背包物品校验（服务端权威扣减） |
| `script_trigger` | 调用外部资源 export（Config 白名单） |
| `custom_event` | 监听外部事件（如 `trailer_hooked`） |
| `validator` | 运行已注册的校验函数 |
| `interact` | 进度条 + 动画（E 键或自动触发） |
| `deliver` | 运输物品/车辆到目标区域 |
| `combat` | 生成 NPC，计数击杀 |
| `wait` | 在区域内停留 N 秒 |
| `placement` | 拖车分离放入区域（服务端位置校验） |
| `reward` | 透明步 — 自动推进到完成 |
| `dialog` | NPC 对话交互 |

---

## 安全机制 (quest_security.lua)

| 层级 | 机制 |
|:---|:---|
| Nonce 验证 | 每个任务操作生成一次性 nonce，30 秒过期 |
| 步顺序校验 | `enforce_step_order` — 禁止跳过步骤 |
| 客户端事件校验 | `ValidateClientEvent(source, eventType, data)` — 源验证 + 数据清理 |
| 速率限制 | `quest_rate_limit_ms` (默认 1000ms) |
| 物理距离 | `quest_max_reach_distance` (默认 25m) |
| 每日/每周限制 | `quest_daily_limits` 表 |
| 冷却时间 | `quest_cooldowns` 表 + 内存缓存 |
| 活跃任务上限 | `quest_max_active` (默认 3) |

---

## 数据库表

| 表 | 列 |
|:---|:---|
| `player_quests` | id, citizenid, quest_id, status, current_step, progress_data (JSON), started_at, completed_at, completion_count |
| `quest_cooldowns` | citizenid, quest_id, expires_at, completion_count |
| `quest_event_log` | id, citizenid, quest_id, step_id, event_type, metadata (JSON), created_at |
| `quest_daily_limits` | citizenid, quest_id, limit_type, period_start, count |

---

## 核心 API (exports)

| Export | 描述 |
|:---|:---|
| `TriggerQuest(source, questId)` | 接受任务 |
| `CompleteStep(source, questId, stepId)` | 直接完成步骤（外部资源调用） |
| `GetActiveQuests(source)` | 获取活跃任务列表 |
| `GetQuestProgress(source, questId)` | 单个任务进度 |
| `IsQuestActive(source, questId)` | 检查任务是否活跃 |
| `GetQuestStep(source, questId)` | 当前步 ID |
| `AbandonQuest(source, questId)` | 放弃任务 |
| `GetCategorizedList()` | 任务分类列表（手机 UI） |

---

## 奖励系统 (quest_rewards.lua)

- **金钱**: 通过 `AddScaledMoney`（应用 `economy_wage_multiplier` 倍率）→ `Bus.EconomyService` 或 fallback 到 `Player.Functions.AddMoney`
- **物品**: 通过 `exports['qb-inventory']:AddItem(source, item, count)`
- **声望**: 通过 `Player.Functions.AddRep(citizenid, repType, amount)`
- **审计**: 触发 `QBCore:Server:OnMoneyChange` 和 `quest:server:onQuestCompleted` 事件
