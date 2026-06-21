# 02 — 世界痕迹系统：让玩家行为留下可见、持久的世界后果

> **核心命题**: "我上次下线前做的事，这次上线还能看到后果"——这是所有权感最直接的来源。  
> **前置阅读**: [00 — 所有权哲学](00-ownership-philosophy.md)

---

## 1. 定义：什么是世界痕迹？

世界痕迹是玩家行为对环境（非仅自身数据）产生的持久改变。

**是痕迹的**：
- 帮派A控制了码头区 → 码头区NPC物价上涨5%
- 某个商贩长期在广场摆摊 → 广场生成"非正式市场"标记
- 某玩家举报作弊者并经核实 → 该区域安全评级提升

**不是痕迹的**：
- 玩家自己的金钱+500（只改变自身数据）
- 玩家完成了任务（只有他自己知道）
- 玩家买了皮肤（只改变外观渲染）

> **区分标准**: 痕迹是"另一个无关玩家也能感受到的变化"。

---

## 2. 世界痕迹的五类

| 类别 | 示例 | 持久性 | 影响范围 |
|:---|:---|:---|:---|
| **领土痕迹** | 帮派控制区域、企业垄断资源 | 数周至永久 | 全服 |
| **经济痕迹** | 物价波动、资源稀缺、市场位置 | 数天至数周 | 全服 |
| **社会痕迹** | 帮派声望、人物名望、组织兴衰 | 数月至永久 | 相关群体 |
| **物理痕迹** | 建筑外观变化、涂鸦、临时路障 | 数小时至数天 | 路过者 |
| **叙事痕迹** | 事件记录、编年史条目 | 永久 | 全服 |

---

## 3. 核心数据结构：World State 表

```sql
CREATE TABLE world_state (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  region_id   VARCHAR(64) NOT NULL,       -- 区域标识 (如 "dock_zone", "plaza_market")
  state_key   VARCHAR(64) NOT NULL,       -- 状态键 (如 "controller", "price_modifier", "market_exists")
  state_value JSON NOT NULL,              -- 状态值
  changed_by  VARCHAR(64),                -- 造成此状态的玩家 citizenid
  changed_at  TIMESTAMP DEFAULT NOW(),
  previous_value JSON,                    -- 上一个状态值（用于回滚和审计）

  UNIQUE KEY idx_region_key (region_id, state_key),
  INDEX idx_changed_by (changed_by),
  INDEX idx_changed_at (changed_at)
);
```

**设计要点**：
- `previous_value` 字段支持"撤销"——如果帮派B反攻夺回地盘，系统知道之前的值是什么
- `changed_by` 字段让"谁改变了世界"可追溯——这正是所有权感的来源（"那块地是我打下来的"）
- JSON 类型允许灵活的状态值——不同类别的痕迹可以是任意结构

---

## 4. 世界痕迹的读写管道

```
写入路径:
  玩家行为 → Security Pipeline (校验) → EventBus.Publish('world:state_changed', ...)
    → WorldStateService: 更新缓存 + 标记脏数据
    → DirtyFlush: 异步批量写 world_state 表

读取路径:
  客户端请求区域信息 → WorldStateService: 内存缓存命中 → 直接返回
  缓存未命中 → world_state 表读取 → 回填缓存
```

**性能关键**：世界状态是**高频读、极低频写**（帮派夺地可能一天几次，但读取是每个进入区域的玩家都触发）。必须走内存缓存。

---

## 5. 具体实现示例

### 5.1 领土痕迹：帮派控制区域

```lua
-- 当帮派战胜负确定后
Bus.Publish('world:territory_changed', {
  region_id = 'dock_zone',
  old_controller = 'CartelA',
  new_controller = 'CartelB',
  changed_by = 'CIT1234',  -- 帮派B的首领
  timestamp = os.time(),
})

-- WorldStateService 消费此事件：
function WorldStateService:OnTerritoryChanged(event)
  -- 1. 更新缓存
  self.cache['dock_zone:controller'] = 'CartelB'
  DirtyFlush.MarkDirty('world_state', 'dock_zone:controller')

  -- 2. 计算衍生效果
  local price_mod = self:GetControlPriceModifier('CartelB')  -- 帮派B的政策
  self.cache['dock_zone:price_modifier'] = price_mod
  DirtyFlush.MarkDirty('world_state', 'dock_zone:price_modifier')

  -- 3. 广播给区域内所有在线玩家
  TriggerClientEvent('world:territory_updated', -1, {
    region = 'dock_zone',
    new_controller = 'CartelB',
    narration = '码头区已被 CartelB 控制，物价发生变化。',
  })
end
```

### 5.2 经济痕迹：玩家商贩形成的市场

```lua
-- 当某个玩家在同一个位置摆摊超过累计10小时
Bus.Publish('world:market_emerged', {
  region_id = 'plaza_south',
  founder_citizenid = 'CIT5678',
  market_type = 'informal',
  created_at = os.time(),
})

-- WorldStateService:
function WorldStateService:OnMarketEmerged(event)
  self.cache['plaza_south:market_exists'] = true
  self.cache['plaza_south:market_founder'] = event.founder_citizenid
  DirtyFlush.MarkDirty('world_state', 'plaza_south:market_exists')

  -- 生成 NPC 客流
  self:SpawnMarketNPCs('plaza_south', event.market_type)

  -- 广播
  TriggerClientEvent('world:new_market', -1, {
    location = '南广场',
    founder = event.founder_citizenid,
    narration = '南广场上自发形成了一个交易市场。',
  })
end
```

### 5.3 社会痕迹：帮派声望

```lua
-- 帮派声望根据战绩、控制领地数、活跃度综合计算
Bus.Publish('world:reputation_updated', {
  gang_id = 'CartelB',
  old_score = 73,
  new_score = 81,
  reason = '控制码头区 +8',
  timestamp = os.time(),
})

-- 这个分数影响：
-- - NPC 商贩对帮派成员的折扣
-- - 帮派招募新人的成功率
-- - 在帮派列表中的排序
-- - 编年史中的排名
```

---

## 6. 客户端表现

世界痕迹不仅要存储，还要**让玩家看见**。以下是表现层要求：

| 痕迹类型 | 客户端表现 |
|:---|:---|
| 领土变更 | 地图涂色变化、边界标识、区域名牌 |
| 物价变化 | 商店价格标签颜色变化、NPC 对话台词 |
| 市场形成 | 地面摊贩标记、NPC 客流、环境音效 |
| 帮派声望 | 帮派总部外观华丽度、NPC 致敬 |
| 物理痕迹 | 墙上的涂鸦、路障、临建物（地图编辑器） |

**关键原则**: 痕迹的表现必须是**无义务的**——玩家可以选择不看，但这些信息客观上存在于环境中。就像现实世界你不会"收到通知"说隔壁街开了新店——你就是路过时看到。

---

## 7. 与世界痕迹系统交互的 Bus Service

```lua
Bus.RegisterService('world_state', {
  -- 读取
  GetRegionState = function(region_id, state_key) end,
  GetAllRegionStates = function(region_id) end,  -- 获取某区域所有状态

  -- 写入（仅内部 service 调用，不暴露给客户端）
  SetRegionState = function(region_id, state_key, value, changed_by) end,

  -- 查询
  GetRegionsControlledBy = function(gang_id) end,
  GetPlayerWorldTraces = function(citizenid) end,  -- 这个玩家对世界留下了哪些痕迹

  -- 通知
  GetActiveNotifications = function(citizenid) end,  -- 玩家上线时，推送"你不在时世界发生了什么"
})
```

---

## 8. "你不在时发生了什么"——上线通知系统

这是世界痕迹系统最重要的玩家可见功能：

```
玩家上线时，系统查询 world_state 表：

"你不在的 14 小时内，世界发生了这些变化："

→ CartelB 攻占了码头区（你所在的帮派失去了控制权）  [与玩家直接相关]
→ 南广场上形成了一个新的交易市场                          [与玩家间接相关]
→ 你的修车铺收到了 3 条新好评                             [与玩家直接相关]
→ CartelA 的首领换了人                                     [与玩家相关 — 同组织]

每条通知按与玩家的关联度排序：
  1. 直接相关（你的组织、你的资产、你的互赖关系）
  2. 间接相关（你的常去区域、你的交易对象）
  3. 全局重大（全服性质事件）
```

**心理机制**: 这个通知相当于告诉玩家"你不在的时候，世界继续运转了——而你的缺席是有影响的"。这是所有权感最强的触发器。

---

## 9. 最小可行实施 (MVP)

Phase 0-1 可以只实现：

1. `world_state` 表（上面 DDL）
2. `WorldStateService` 的基础读写 + 缓存
3. 一个事件发布钩子：帮派战结束后发射 `world:territory_changed`
4. 一个客户端通知：玩家上线时显示"你不在时的世界变化"（先从1-2种痕迹做起）

这四样加起来约 300-400 行代码，不改变任何现有游戏逻辑，但立刻给玩家一个"世界是活的"的体验。

---

## 下一步

阅读 [03 — 不可替代性与声誉](03-irreplaceability-reputation.md)，理解如何让玩家之间建立"非我不可"的互赖关系。
