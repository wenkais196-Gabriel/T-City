# 07 — 架构集成：如何嵌入 T-City Phase 0-3

> **核心命题**: 前6篇设计的系统不能"以后再说"——Phase 0-1 的架构决策将决定它们是"轻松叠加"还是"重构第二次"。  
> **前置阅读**: 所有前6篇 + T-City2 全量工程路线图 v3.0

---

## 1. 总体集成策略

```
原则: "Phase 0 预留坑位，Phase 1 铺设数据管，Phase 2 实现功能，Phase 3 深度打磨。"

Phase 0 (骨架):  表结构预留 + Bus Contract 定义 + EventBus 事件类型枚举
Phase 1 (核心):  基础数据管道（世界事件发射、信任图读写、Patron 验证）
Phase 2 (替换):  Patron 系统 + 声誉 MVP + 编年史 MVP
Phase 3 (扩展):  共治系统 + 漏斗引擎 + 赛季编年史 + 商城 UI
```

---

## 2. Phase 0 — 骨架阶段必须做的事

### 2.1 Player Metadata Schema 预留

**文件**: `tcity-core/player/schema.lua` (新建)

```lua
-- Player metadata 完整 Schema 定义
-- Phase 0 只定义，不全量实现

local PlayerSchema = {
  -- 现有字段
  money = 'number',
  bank = 'number',
  job = 'table',
  inventory = 'table',

  -- Phase 0-1 新增: 所有权引擎数据
  -- (这些 key 必须在 metadata_service 中预留，即使暂时返回空值)
  achievements = 'table',       -- {achievement_id: {unlocked_at, tier, is_active}}
  reputation_graph = 'table',   -- 信任图摘要（完整图在 trust_graph 表）
  patron_tier = 'number',       -- 0/1/2/3
  world_traces = 'table',       -- 玩家对世界的痕迹列表
  social_signals = 'table',     -- 漏斗社交信号
  chronicle = 'table',          -- 个人传记
  council_votes = 'table',      -- 共治投票记录
  cosmetic_loadout = 'table',   -- 当前装备的外观物品
  skill_ranks = 'table',        -- 技能位阶
}

return PlayerSchema
```

### 2.2 数据库表创建（DDL）

**文件**: `tcity-core/db/migrations/002_ownership_tables.sql`

```sql
-- Phase 0: 创建所有权系统的核心表（空表，后续填充）

-- 世界状态
CREATE TABLE IF NOT EXISTS world_state (
  id INT AUTO_INCREMENT PRIMARY KEY,
  region_id VARCHAR(64) NOT NULL,
  state_key VARCHAR(64) NOT NULL,
  state_value JSON NOT NULL,
  changed_by VARCHAR(64),
  changed_at TIMESTAMP DEFAULT NOW(),
  previous_value JSON,
  UNIQUE KEY idx_region_key (region_id, state_key),
  INDEX idx_changed_by (changed_by)
);

-- 世界事件
CREATE TABLE IF NOT EXISTS world_events (
  id INT AUTO_INCREMENT PRIMARY KEY,
  event_type VARCHAR(32) NOT NULL,
  severity ENUM('minor','notable','major','legendary') NOT NULL,
  title VARCHAR(255) NOT NULL,
  description TEXT,
  participants JSON,
  location VARCHAR(128),
  outcome JSON,
  duration_sec INT,
  triggered_by VARCHAR(64),
  timestamp TIMESTAMP DEFAULT NOW(),
  INDEX idx_type_time (event_type, timestamp),
  INDEX idx_severity (severity, timestamp)
);

-- 信任图
CREATE TABLE IF NOT EXISTS trust_graph (
  id INT AUTO_INCREMENT PRIMARY KEY,
  from_citizen VARCHAR(64) NOT NULL,
  to_citizen VARCHAR(64) NOT NULL,
  category VARCHAR(32) NOT NULL,
  weight FLOAT NOT NULL,
  reason_event VARCHAR(255),
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  UNIQUE KEY idx_trust_edge (from_citizen, to_citizen, category),
  INDEX idx_to_citizen (to_citizen)
);

-- Patron 记录
CREATE TABLE IF NOT EXISTS patron_records (
  id INT AUTO_INCREMENT PRIMARY KEY,
  citizenid VARCHAR(64) NOT NULL UNIQUE,
  tier INT NOT NULL DEFAULT 0,
  started_at TIMESTAMP NULL,
  expires_at TIMESTAMP NULL,
  external_id VARCHAR(128),
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

-- 治理提案
CREATE TABLE IF NOT EXISTS governance_proposals (
  id INT AUTO_INCREMENT PRIMARY KEY,
  scope ENUM('organization','server') NOT NULL,
  scope_id VARCHAR(64),
  proposal_type VARCHAR(32) NOT NULL,
  title VARCHAR(255) NOT NULL,
  description TEXT NOT NULL,
  proposed_by VARCHAR(64) NOT NULL,
  proposed_at TIMESTAMP DEFAULT NOW(),
  required_cosign INT DEFAULT 0,
  cosigners JSON DEFAULT '[]',
  status ENUM('draft','cosigning','voting','passed','rejected','executed','vetoed') DEFAULT 'draft',
  voting_start TIMESTAMP NULL,
  voting_end TIMESTAMP NULL,
  votes_for INT DEFAULT 0,
  votes_against INT DEFAULT 0,
  vote_details JSON DEFAULT '{}',
  execution_fn VARCHAR(64),
  execution_args JSON,
  executed_at TIMESTAMP NULL,
  INDEX idx_scope (scope, scope_id),
  INDEX idx_status (status)
);

-- 技能位阶
CREATE TABLE IF NOT EXISTS skill_ranks (
  id INT AUTO_INCREMENT PRIMARY KEY,
  skill_name VARCHAR(32) NOT NULL,
  citizenid VARCHAR(64) NOT NULL,
  rank ENUM('apprentice','journeyman','expert','master') NOT NULL,
  achieved_at TIMESTAMP DEFAULT NOW(),
  rank_score FLOAT DEFAULT 0,
  is_active BOOLEAN DEFAULT TRUE,
  INDEX idx_skill_rank (skill_name, rank),
  INDEX idx_citizenid (citizenid)
);

-- 外观物品
CREATE TABLE IF NOT EXISTS cosmetic_items (
  id INT AUTO_INCREMENT PRIMARY KEY,
  item_id VARCHAR(64) NOT NULL UNIQUE,
  item_name VARCHAR(128) NOT NULL,
  item_type VARCHAR(32) NOT NULL,
  required_achievement VARCHAR(64),
  price_cny INT NOT NULL,
  is_permanent BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS player_cosmetics (
  id INT AUTO_INCREMENT PRIMARY KEY,
  citizenid VARCHAR(64) NOT NULL,
  item_id VARCHAR(64) NOT NULL,
  purchased_at TIMESTAMP DEFAULT NOW(),
  equipped BOOLEAN DEFAULT FALSE,
  frozen BOOLEAN DEFAULT FALSE,
  UNIQUE KEY idx_player_item (citizenid, item_id)
);

-- 组织规则
CREATE TABLE IF NOT EXISTS organization_rules (
  id INT AUTO_INCREMENT PRIMARY KEY,
  org_id VARCHAR(64) NOT NULL,
  rule_key VARCHAR(64) NOT NULL,
  rule_value JSON NOT NULL,
  changed_by_proposal INT NULL,
  changed_at TIMESTAMP DEFAULT NOW(),
  UNIQUE KEY idx_org_rule (org_id, rule_key)
);
```

### 2.3 Bus Service Contract 注册

**文件**: `tcity-framework/bus/contracts.lua` (扩展)

```lua
-- Phase 0: 定义所有未来服务的契约接口
-- 实际实现在后续 Phase 中完成

Bus.Contracts = {
  -- Phase 0 已有
  economy = {
    AddMoney = 'function(citizenid, amount, reason)',
    RemoveMoney = 'function(citizenid, amount, reason)',
    GetBalance = 'function(citizenid)',
    Transfer = 'function(from_citizen, to_citizen, amount, reason)',
  },

  -- Phase 1-2 新增契约
  world_state = {
    GetRegionState = 'function(region_id, state_key)',
    GetPlayerTraces = 'function(citizenid)',
    GetActiveNotifications = 'function(citizenid)',
  },

  reputation = {
    AddTrustEdge = 'function(from_citizen, to_citizen, category, weight, reason)',
    GetTrustSummary = 'function(citizenid)',
  },

  chronicle = {
    RecordEvent = 'function(event_data)',
    GetPlayerChronicle = 'function(citizenid)',
  },

  governance = {
    CreateProposal = 'function(scope, scope_id, type, title, desc, proposed_by)',
    Vote = 'function(proposal_id, citizenid, vote)',
  },

  patron = {
    GetTier = 'function(citizenid)',
  },

  cosmetics = {
    GetUnlockable = 'function(citizenid)',
    Purchase = 'function(citizenid, item_id)',
    Equip = 'function(citizenid, item_id)',
  },

  funnel = {
    RecordSocialSignal = 'function(citizenid, signal_type, data)',
    GetRecommendations = 'function(citizenid)',
  },
}
```

### 2.4 EventBus 事件类型枚举

**文件**: `tcity-framework/events/event_types.lua` (新建)

```lua
-- 所有权引擎事件类型定义
-- Phase 0 统一定义，各服务按需发射/消费

EventTypes = {
  -- 世界痕迹
  WORLD = {
    TERRITORY_CHANGED  = 'world:territory_changed',
    MARKET_EMERGED     = 'world:market_emerged',
    REPUTATION_UPDATED = 'world:reputation_updated',
    ECONOMIC_ANOMALY   = 'world:economic_anomaly',
    STATE_CHANGED      = 'world:state_changed',
  },

  -- 叙事
  CHRONICLE = {
    EVENT_RECORDED     = 'chronicle:event_recorded',
    ANNOTATION_ADDED   = 'chronicle:annotation_added',
    SEASON_ENDED       = 'chronicle:season_ended',
  },

  -- 信任
  REPUTATION = {
    TRUST_EDGE_ADDED   = 'reputation:trust_edge_added',
    TRUST_EDGE_REVOKED = 'reputation:trust_edge_revoked',
    SKILL_RANK_CHANGED = 'reputation:skill_rank_changed',
  },

  -- 共治
  GOVERNANCE = {
    PROPOSAL_CREATED   = 'governance:proposal_created',
    PROPOSAL_PASSED    = 'governance:proposal_passed',
    PROPOSAL_REJECTED  = 'governance:proposal_rejected',
    LEADER_CHANGED     = 'governance:leader_changed',
  },

  -- 漏斗
  FUNNEL = {
    SOCIAL_SIGNAL      = 'funnel:social_signal',
    RECOMMENDATION     = 'funnel:recommendation',
    STAGE_ADVANCED     = 'funnel:stage_advanced',
  },
}
```

---

## 3. Phase 1 — 核心迁移阶段做的事

### 3.1 铺设事件发射点

在现有系统的关键位置插入 `Bus.Publish`：

| 现有位置 | 发射的事件 | 优先级 |
|:---|:---|:---|
| 帮派战结算 | `world:territory_changed` | P0 |
| 经济交易完成 | `world:economic_anomaly` (仅在价格波动>30%时) | P1 |
| 玩家加入/离开组织 | `funnel:social_signal` | P0 |
| 玩家完成 Quest | `funnel:social_signal` | P0 |
| 玩家成为首位某成就达成者 | `chronicle:event_recorded` | P1 |

**代码量**: 每处变更 < 5 行。不改变逻辑，仅插入事件发射。

### 3.2 实现 WorldStateService 基础版

```lua
-- tcity-core/services/world_state_service.lua

local WorldStateService = {
  cache = {},        -- { 'region_id:state_key' → value }
  dirty_keys = {},   -- 脏数据标记
}

function WorldStateService:GetRegionState(region_id, state_key)
  local cache_key = region_id .. ':' .. state_key
  if self.cache[cache_key] ~= nil then
    return self.cache[cache_key]
  end
  -- fallback: DB 查询
  local row = MySQL.Sync.fetchScalar('SELECT state_value FROM world_state WHERE region_id = ? AND state_key = ?', {region_id, state_key})
  if row then
    self.cache[cache_key] = json.decode(row)
  end
  return self.cache[cache_key]
end

function WorldStateService:SetRegionState(region_id, state_key, value, changed_by)
  local cache_key = region_id .. ':' .. state_key
  self.cache[cache_key] = value
  self.dirty_keys[cache_key] = {
    region_id = region_id,
    state_key = state_key,
    value = value,
    changed_by = changed_by,
  }
  -- 由 DirtyFlush 定时刷入 DB（重用现有管道）
end

Bus.RegisterService('world_state', WorldStateService)
```

### 3.3 实现 PatronService 基础版

```lua
-- tcity-core/services/patron_service.lua

local PatronService = {
  tier_cache = {},  -- { citizenid → tier }
}

function PatronService:GetTier(citizenid)
  if self.tier_cache[citizenid] ~= nil then
    return self.tier_cache[citizenid]
  end
  local row = MySQL.Sync.fetchScalar('SELECT tier FROM patron_records WHERE citizenid = ?', {citizenid})
  local tier = row or 0
  self.tier_cache[citizenid] = tier
  return tier
end

function PatronService:SetTier(citizenid, tier, external_data)
  -- 仅支付回调/管理员命令可调用
  -- Security: 此函数不在客户端可触达的路径上
  MySQL.Async.execute('REPLACE INTO patron_records (citizenid, tier, external_id, started_at, expires_at) VALUES (?, ?, ?, NOW(), DATE_ADD(NOW(), INTERVAL 1 MONTH))', {
    citizenid, tier, external_data.external_id
  })
  self.tier_cache[citizenid] = tier
  DirtyFlush.MarkDirty(citizenid, 'patron_tier')
end

Bus.RegisterService('patron', PatronService)
```

---

## 4. Phase 2 — 自研替换阶段做的事

### 4.1 Patron 完整系统

- 支付 Webhook 接收端点（Express/Node 或 FiveM 外部 HTTP 服务）
- HMAC 签名验证
- Discord Bot 集成（`!patron-status` 命令）
- 运营透明度面板（Discord 频道嵌入）
- 客户端名字颜色渲染（根据 `patron_tier`）

### 4.2 信任图 MVP

- `ReputationService` 基础 CRUD
- 7天交互门槛校验
- 同IP检测（防自评）
- 客户端"查看玩家信誉"UI

### 4.3 编年史 MVP

- `ChronicleService` 事件记录
- Discord Webhook: major+ 事件自动推送
- 上线通知: "你不在时发生了什么"（从 world_events 表查询）

---

## 5. Phase 3 — 深度打磨阶段做的事

- 共治系统（提案-投票-自动执行完整生命周期）
- 漏斗引擎（社交信号累积 → 阈值触发 → 推荐）
- 赛季编年史自动生成器
- 商城 UI（游戏内）
- 技能位阶系统（容量限制 + 挑战/晋升）
- 组织史诗页面
- 个人传记可视化

---

## 6. 安全管道集成

所有权系统的安全要求直接嵌入现有的五层校验链：

```
层级1: Source 权威
  → 所有 patron/cosmetic/governance 写操作必须来自服务端回调或已验证的管理员命令
  → 客户端发起的任何此类请求 → 直接拒绝

层级2: 类型/数值校验
  → patron_tier 必须在 [0,1,2,3]
  → trust weight 必须在 [-1.0, 1.0]
  → vote 必须为 'for' 或 'against'

层级3: 权限/身份校验
  → 购买 cosmetic 前必须验证对应 achievement 真实存在且有效
  → 提案投票前必须验证投票资格（组织成员 / 议会成员）
  → 信任边创建前必须验证7天交互记录

层级4: 物理距离
  → 信任评价（同一场景内交互过才可评价）
  → 帮派提案（需要在帮派总部或指定地点）

层级5: 限流冷却
  → 信任边创建: 每人每天最多3条
  → 提案创建: 每人每周最多2条（组织级别）
  → Patron 支付回调: 每公民ID每天最多1次状态变更
```

---

## 7. 兼容性保障

### 7.1 对现有插件的影响

| 系统 | 影响程度 | 兼容策略 |
|:---|:---|:---|
| 新增表 | 零影响 | 新表，不改变现有表结构 |
| Player Metadata 扩展 | 零影响 | 新增 key，现有 key 不变 |
| EventBus 事件发射 | 零影响 | 纯新增事件，不修改现有事件 |
| Bus 新 Service | 零影响 | 新注册，现有 service 不变 |
| 客户端 UI | 受影响但渐进 | 先做非侵入式（名字颜色、称号），再做独立面板 |

### 7.2 QBCore 兼容桥

```lua
-- compat.lua 中新增所有权系统的兼容映射
-- 现有 QBCore API 不变，但底层享受新架构

-- 例如: 现有帮派系统调用 QBCore.Functions.SetGang() 时
-- compat 层在完成原名逻辑后，额外发射新事件:
function Compat.SetGang(citizenid, gang_id)
  -- 原名逻辑
  QBCore_Original.SetGang(citizenid, gang_id)
  -- 新架构事件
  Bus.Publish('world:state_changed', {...})
  Bus.Publish('funnel:social_signal', {citizenid = citizenid, signal_type = 'gang_joined'})
end
```

---

## 8. 文件清单汇总

按 Phase 列出所有需创建/修改的文件：

### Phase 0 (8 个文件)

| 文件 | 操作 | 说明 |
|:---|:---|:---|
| `tcity-core/player/schema.lua` | 新建 | Player metadata 完整 Schema |
| `tcity-core/db/migrations/002_ownership_tables.sql` | 新建 | 所有权系统全部 DDL |
| `tcity-framework/bus/contracts.lua` | 扩展 | 新增 7 个 Service Contract |
| `tcity-framework/events/event_types.lua` | 新建 | 事件类型枚举 |
| `docs/server-design/README.md` | 新建 | 本手册索引 |
| `docs/server-design/00-07` | 新建 | 8 篇设计文档 |

### Phase 1 (4 个文件)

| 文件 | 操作 | 说明 |
|:---|:---|:---|
| `tcity-core/services/world_state_service.lua` | 新建 | 世界状态读写 + 缓存 |
| `tcity-core/services/patron_service.lua` | 新建 | Patron 等级读写 |
| `systems/gang/server/main.lua` | 修改 | 帮派战结算处插入事件发射 |
| `systems/economy/server/main.lua` | 修改 | 经济异常处插入事件发射 |

### Phase 2 (4 个文件)

| 文件 | 操作 | 说明 |
|:---|:---|:---|
| `tcity-core/services/reputation_service.lua` | 新建 | 信任图 CRUD |
| `tcity-core/services/chronicle_service.lua` | 新建 | 事件记录 + 上线通知 |
| `systems/patron/server/webhook.lua` | 新建 | 支付 Webhook 处理 |
| `systems/patron/client/display.lua` | 新建 | 客户端名字颜色/称号渲染 |

### Phase 3 (待规划)

共治系统、漏斗引擎、赛季编年史、商城 UI 等——不在本手册 v1.0 范围内详细展开。

---

## 下一步

本手册系列到此结束。建议的后续行动：

1. **团队对齐**: 将 `00-ownership-philosophy.md` 在团队内部过一遍，确保"所有权感驱动"的核心哲学被所有人理解
2. **Phase 0 启动**: 创建表、定义 Schema、注册 Contract——这些纯粹是"挖坑"，不改变任何现有逻辑，零风险
3. **先做 Patron**: Patron 系统是最独立、最能快速验证"养服务器"假设的功能——不需要等所有系统就位
4. **用指标说话**: 追踪 D7/D30 留存率、付费转化率、帮派加入率——拿数据验证所有权感模型是否成立
