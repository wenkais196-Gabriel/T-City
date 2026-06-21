# 05 — 叙事所有权：让服务器拥有自己的历史

> **核心命题**: "这个服务器有自己的故事，而我的行为是故事的一部分"——叙事所有权将玩家体验从"玩游戏"提升为"活在另一个世界里"。  
> **前置阅读**: [00 — 所有权哲学](00-ownership-philosophy.md) / [02 — 世界痕迹](02-world-traces.md)

---

## 1. 为什么叙事很重要？

没有叙事所有权的服务器：
- 你玩了半年，回想起来只有"攒了多少钱"和"杀过多少人"
- 服务器关了就关了，你没有任何留恋
- 新玩家来了，不知道这里发生过什么——历史从零开始

有叙事所有权的服务器：
- 你能说出"2026年3月，CartelB趁黑夜突袭了码头，那是本服最大的一场帮派战"
- 你在 Discord 频道里，新玩家问你"你当年参与过码头之战吗？"——你正在创造传说
- 赛季结束时，系统生成编年史——你在条目里看到了自己的名字

> **叙事所有权 = 服务器不是"一个可以玩的地方"，而是"一个值得被记住的世界"。**

---

## 2. 叙事所有权的四层

```
┌──────────────────────────────────┐
│ 第四层: 赛季编年史 (Season Chronicle)│
│ 系统自动生成，全服可见               │
├──────────────────────────────────┤
│ 第三层: 帮派/组织史诗 (Org Saga)     │
│ 每个组织有自己的历史事件线            │
├──────────────────────────────────┤
│ 第二层: 个人传记 (Personal Chronicle) │
│ 每个玩家有自己的生平大事记            │
├──────────────────────────────────┤
│ 第一层: 重大事件日志 (Event Log)      │
│ 基础设施——所有叙事的原始数据源         │
└──────────────────────────────────┘
```

---

## 3. 第一层：重大事件日志（基础设施）

### 3.1 事件数据表

```sql
CREATE TABLE world_events (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  event_type    VARCHAR(32) NOT NULL,         -- 'territory_war', 'economic_crisis', 'player_achievement', ...
  severity      ENUM('minor', 'notable', 'major', 'legendary') NOT NULL,
  title         VARCHAR(255) NOT NULL,        -- 可读标题
  description   TEXT,                         -- 系统生成的客观描述
  participants  JSON,                         -- [{citizenid, role}, ...]
  location      VARCHAR(128),                 -- 区域标识
  outcome       JSON,                         -- 事件结果
  duration_sec  INT,                          -- 事件持续时长
  triggered_by  VARCHAR(64),                  -- citizenid 或 'system'
  timestamp     TIMESTAMP DEFAULT NOW(),

  INDEX idx_type_time (event_type, timestamp),
  INDEX idx_severity (severity, timestamp),
  INDEX idx_participant (participants),       -- 需要 MySQL 8.0+ 多值索引或应用层处理
  FULLTEXT idx_title_desc (title, description)
);
```

### 3.2 事件发射

所有重大操作都发射世界事件：

```lua
-- 在 EconomyService, GangService, TerritoryService 等敏感操作处插入

-- 示例1: 帮派战结束
Bus.Publish('world:event', {
  event_type = 'territory_war',
  severity = 'major',
  title = '码头之战: CartelB 从 CartelA 手中夺取码头区控制权',
  description = '经过约3小时的激烈交火后，CartelB 突破了 CartelA 的防线...',
  participants = {
    { citizenid = 'CIT1234', role = 'attacker_leader' },
    { citizenid = 'CIT5678', role = 'defender_leader' },
    -- ... (系统自动从参战记录中汇总)
  },
  location = 'dock_zone',
  outcome = { controller_changed = true, new_controller = 'CartelB' },
  duration_sec = 10800,
  triggered_by = 'system',
})

-- 示例2: 经济异常
Bus.Publish('world:event', {
  event_type = 'economic_anomaly',
  severity = 'notable',
  title = '武器价格暴涨: 铁矿石供应短缺',
  description = '由于主要采矿帮派内部动荡，铁矿石产量骤降60%，武器价格随之飙升...',
  participants = {{ citizenid = 'CIT9012', role = 'affected_trader' }},
  location = 'server_wide',
  outcome = { price_change_pct = 45, affected_items = {'pistol', 'rifle', 'ammo'} },
  triggered_by = 'system',
})

-- 示例3: 玩家里程碑
Bus.Publish('world:event', {
  event_type = 'player_achievement',
  severity = 'notable',
  title = '玩家 [XX] 成为本服第一位大师级武器商',
  description = '经过4个月的努力，[XX] 完成了所有武器制造考核...',
  participants = {{ citizenid = 'CIT3456', role = 'achiever' }},
  triggered_by = 'system',
})
```

---

## 4. 第二层：个人传记

每个玩家有自动生成的生平大事记：

```lua
-- 玩家数据中的 chronicle 字段
{
  chronicle = {
    first_seen = '2026-01-15',
    milestones = {
      { date = '2026-01-15', event = '首次进入 T-City' },
      { date = '2026-01-17', event = '加入组织 CartelB' },
      { date = '2026-02-03', event = '参与码头之战 (CartelB vs CartelA)' },
      { date = '2026-03-15', event = '成为本服第一位大师级武器商' },
      { date = '2026-04-01', event = '当选 CartelB 首领' },
    },
    war_record = {
      battles_fought = 12,
      battles_led = 3,
      territories_captured = 2,
      rivalries = { 'CIT5678' },  -- 最常对阵的敌对玩家
    },
    economic_record = {
      total_earned = 4500000,
      total_traded = 2800000,
      largest_single_trade = 500000,
      trade_partners = 47,
    },
  }
}
```

**展示方式**：
- 客户端个人面板里的"生涯"标签页
- Discord 机器人命令 `!profile [玩家名]` 返回传记摘要
- 其他玩家查看你时，可以看到你的公开传记

---

## 5. 第三层：帮派/组织史诗

每个组织有自己的历史事件线：

```lua
-- 组织数据中的 saga 字段
{
  saga = {
    founded = '2026-01-10',
    founded_by = 'CIT1234',
    founding_story = '由前警官 [XX] 创建的黑色产业链集团...', -- 可选，由创始人手写
    events = {
      { date = '2026-01-10', event = 'CartelB 成立', type = 'org_created' },
      { date = '2026-01-20', event = '首次领土争夺: 挑战码头区失败', type = 'war_lost' },
      { date = '2026-02-03', event = '码头之战: 成功夺取码头区', type = 'war_won' },
      { date = '2026-03-01', event = '与 CartelC 结盟', type = 'alliance' },
      { date = '2026-04-01', event = '首领换届: XX → YY', type = 'leadership_change' },
    },
    territory_history = {
      { region = 'dock_zone', held_from = '2026-02-03', held_to = null },
      { region = 'market_district', held_from = '2026-03-15', held_to = '2026-04-20' },
    },
    rivalries = {
      { org = 'CartelA', wars = 3, battles = 8, current_status = 'hostile' },
      { org = 'CartelC', wars = 0, battles = 0, current_status = 'allied' },
    },
    former_leaders = {
      { citizenid = 'CIT1234', period = '2026-01-10 ~ 2026-04-01', reason = '选举换届' },
    },
  }
}
```

---

## 6. 第四层：赛季编年史

每季度/赛季结束时，系统自动生成编年史。

### 6.1 生成规则

```
赛季编年史 生成器:

1. 查询 world_events 表当季所有事件 (severity >= 'notable')
2. 按事件类型分组:
   - 战争与领土: 帮派战、领土变更
   - 经济: 价格波动、市场形成、垄断
   - 人物: 玩家里程碑、首领更迭
   - 社会: 组织兴衰、联盟/断交
3. 按时间线排序，自动生成章节标题
4. 每个事件自动生成一句话描述
5. 识别"赛季MVP": 出现在最多 major+ 事件中的玩家
6. 生成统计数据: 总战斗次数、经济总量、活跃组织数
7. 输出为 Markdown → 同时发布到游戏内终端和 Discord 频道
```

### 6.2 编年史示例

```markdown
# T-City 第一赛季编年史: "黑帮崛起"
## 2026年1月-4月

### 赛季统计
- 活跃玩家峰值: 78人
- 帮派战争: 14场
- 领土变更: 6次
- 经济总量: ¥12,400,000 流通
- 赛季MVP: [XX] (参与7场重大事件)

### 第一章: 蛮荒之地
1月10日 — CartelB 成立，创始人为 [XX]。这是服务器的第二个帮派。
1月15日 — 码头区爆发第一次领土争夺，CartelA 成功防守。
...

### 第二章: 群雄割据
2月3日 — "码头之战" — CartelB 经过3小时激战，从 CartelA 手中夺取码头区。此战成为本季最大规模帮派战争。
2月10日 — CartelC 成立，三方格局形成。
...

### 终章: 新秩序
4月1日 — CartelB 首次民主选举首领。原首领 [XX] 和平交棒给 [YY]。
4月15日 — 第一赛季结束。

### 致敬
感谢所有78位玩家。你们创造了这个世界的第一个故事。
```

---

## 7. 玩家对叙事的参与

叙事不是系统单向输出的——玩家可以：

### 7.1 对事件添加"亲历者注释"

```lua
-- 玩家可以在自己的视角为世界事件添加注释
Bus.Publish('world:event_annotation', {
  event_id = 42,
  citizenid = 'CIT3456',
  annotation = '那一晚我在码头东侧防守。我记得凌晨2点，弹药快打完的时候，首领在频道里喊"再坚持10分钟，援军快到了"——然后我们真的守住了。那是我在这个游戏里最紧张的时刻。',
  timestamp = os.time(),
})
```

其他玩家阅读编年史时，可以看到这些亲历者注释——就像维基百科的"讨论"页。

### 7.2 自定义帮派创始故事

帮派创始人可以撰写帮派的"创始故事"（可选，但鼓励）：

```lua
-- 存储在 organization saga 中
"saga.founding_story": "前警官 [XX] 在一次内部腐败调查中被陷害，被迫离开警队。他召集了几个同样被体制背叛的人，在码头区的一家废弃仓库里建立了 CartelB。我们的信条是: 在这座城市里，忠诚比法律更重要。"
```

---

## 8. Bus Service 接口

```lua
Bus.RegisterService('chronicle', {
  -- 事件记录
  RecordEvent = function(event_data) end,  -- 写入 world_events

  -- 个人传记
  GetPlayerChronicle = function(citizenid) end,
  AddPlayerMilestone = function(citizenid, milestone_data) end,

  -- 组织史诗
  GetOrgSaga = function(org_id) end,
  AddOrgEvent = function(org_id, event_data) end,

  -- 编年史
  GenerateSeasonChronicle = function(season_id, start_date, end_date) end,
  GetChronicle = function(season_id) end,

  -- 注释
  AddAnnotation = function(event_id, citizenid, annotation) end,
  GetAnnotations = function(event_id) end,

  -- 查询
  GetEventsByPlayer = function(citizenid, limit) end,
  GetEventsByType = function(event_type, start_date, end_date) end,
  GetSeasonMVP = function(season_id) end,
})
```

---

## 9. 最小可行实施 (MVP)

Phase 0-1: 只做事件发射 + 记录。

1. `world_events` 表
2. 在帮派战结算、领土变更、玩家成为大师等处插入 `Bus.Publish('world:event', ...)`
3. Discord Webhook: 每个 major+ 事件自动发布到公共频道

Phase 2: 个人传记 + 组织史诗。
Phase 3: 赛季编年史 + 亲历者注释。

**关键判断**: 叙事系统不是"内容"——它是"数据基础设施"。不需要设计故事，只需要设计"哪些事件值得被记录"。故事是玩家自己写的，系统只是提供纸张。

---

## 下一步

阅读 [06 — 付费模型](06-payment-model.md)，理解 Patron（养服务器）+ Identity（买面儿）双轨付费设计。
