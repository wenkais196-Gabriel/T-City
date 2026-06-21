# 03 — 不可替代性与声誉：让玩家成为"基础设施"

> **核心命题**: "这个服务器上有些事，非我不可"——当玩家意识到自己不可替代时，离开的成本变得极高。  
> **前置阅读**: [00 — 所有权哲学](00-ownership-philosophy.md) / [02 — 世界痕迹](02-world-traces.md)

---

## 1. 定义：什么是不可替代性？

不可替代性是**其他玩家对你的依赖程度**——如果少了你，某些事情会变得更难、更贵、或无法完成。

**可替代的**（大多数服务器）：
- 组队打副本 → 换个队友也能打
- 交易物资 → 找另一个商人也能买
- 加入帮派 → 帮派不缺你一个

**不可替代的**（目标状态）：
- 全服只有3个大师级武器商，你是之一 → 你的供货稳定影响帮战胜率
- 你掌握了某个区域的实时情报 → 别人交易前先问你
- 你是新手帮派的教官 → 他们的成长跟你直接挂钩

---

## 2. 不可替代性的两种来源

### 2.1 结构性不可替代（系统制造的稀缺）

**核心手段：容量限制。**

不要做成"人人可满级"的技能树，而是做**位阶系统**：

```
技能位阶:
  学徒    →  无限制（任何人都可以是学徒）
  匠人    →  每服务器最多 20 人
  专家    →  每服务器最多 8 人
  大师    →  每服务器最多 3 人

晋升规则:
  学徒→匠人: 完成技能树 + 通过考核任务
  匠人→专家: 在匠人中排名前8（按产出质量/交易量）
  专家→大师: 挑战当前大师，胜者上位；或大师主动让位/退役

降级规则:
  大师连续14天离线 → 自动降为专家，空出位置
  专家连续30天离线 → 降为匠人
```

**心理效应**: 
- 在位者怕失去 → 不会轻易离开
- 挑战者想上位 → 持续活跃
- 位置稀缺 → 成为大师是真实的成就，不是时间堆积

### 2.2 社交性不可替代（玩家自己建立的互赖）

**核心手段：有向信任图。**

不是5星评分，而是一个有向图：

```
玩家A --信任(+0.8)--> 玩家B  (A信任B作为武器商)
玩家B --信任(+0.6)--> 玩家A  (B信任A作为情报源)
玩家C --信任(-0.3)--> 玩家B (C与B有过纠纷)
```

这个图的特征：
- **有方向** —— A信任B不代表B信任A
- **带权重** —— 不仅是"信/不信"，还有程度
- **分类别** —— 信任B作为武器商，不代表信任B作为司机
- **历史可溯** —— 每条边关联着"为什么给出这个评价"的事件

---

## 3. 核心数据结构

### 3.1 技能位阶表

```sql
CREATE TABLE skill_ranks (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  skill_name    VARCHAR(32) NOT NULL,       -- 技能名 (weapon_smith, vehicle_repair, ...)
  citizenid     VARCHAR(64) NOT NULL,
  rank          ENUM('apprentice', 'journeyman', 'expert', 'master') NOT NULL,
  achieved_at   TIMESTAMP DEFAULT NOW(),
  ranked_by     VARCHAR(64),               -- 谁授予的 (NULL=系统自动)
  rank_score    FLOAT DEFAULT 0,           -- 排名分 (用于同阶排序)
  is_active     BOOLEAN DEFAULT TRUE,      -- 大师离线14天→FALSE

  INDEX idx_skill_rank (skill_name, rank),
  INDEX idx_citizenid (citizenid),
  UNIQUE KEY idx_skill_master (skill_name, rank) WHERE rank = 'master' AND is_active = TRUE
);
```

### 3.2 信任图

```sql
CREATE TABLE trust_graph (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  from_citizen  VARCHAR(64) NOT NULL,       -- 谁给出的信任
  to_citizen    VARCHAR(64) NOT NULL,       -- 信任谁
  category      VARCHAR(32) NOT NULL,       -- 信任类别 (weapon_supplier, driver, informant, ...)
  weight        FLOAT NOT NULL,             -- -1.0 到 +1.0
  reason_event  VARCHAR(255),               -- 关联的世界事件ID或说明
  created_at    TIMESTAMP DEFAULT NOW(),
  updated_at    TIMESTAMP DEFAULT NOW(),

  UNIQUE KEY idx_trust_edge (from_citizen, to_citizen, category),
  INDEX idx_to_citizen (to_citizen),
  INDEX idx_category_weight (category, weight)
);
```

### 3.3 Player Metadata 扩展

```lua
-- 每个玩家的 metadata 新增：
{
  -- 技能位阶
  skill_ranks = {
    weapon_smith = { rank = 'master', score = 94.2, held_since = '2026-03-15' },
    vehicle_repair = { rank = 'journeyman', score = 61.7 },
  },

  -- 信任图摘要（内存缓存，完整图在 trust_graph 表）
  trust_summary = {
    trusted_by_count = 47,          -- 有多少人信任我
    trusted_by_avg_weight = 0.82,   -- 平均信任度
    top_categories = {              -- 我最受信任的类别
      'weapon_supplier',
      'informant',
    },
    endorsements_given = 23,        -- 我给出去多少信任
  },
}
```

---

## 4. 信任图的读写规则

### 4.1 谁可以创建信任边？

只有**真人玩家**可以给另一个玩家创建信任边。系统只做聚合和展示，不做自动评价。

**创建条件**：
- 双方在过去7天内有实际交易/交互记录
- 不能在同一个IP或同一台机器（防自评）
- 每人每天最多创建3条信任边（防刷）

### 4.2 信任边如何被消费？

| 消费场景 | 消费者 |
|:---|:---|
| 帮派招募时查看候选人的受信任度 | 帮派首领 |
| 大额交易前查对方信誉 | 交易发起方 |
| 新手寻找师傅时按受信任度排序 | 系统推荐算法 |
| 社区议会候选人资格 | 系统自动筛选（受信任度>阈值） |
| 帮派内部选举 | 帮派成员 |

### 4.3 "不可替代性指数"计算

系统自动为每个玩家计算一个 IR 指数：

```
IRI = (
  结构性不可替代:
    skill_mastery_score × 0.4        -- 位阶 × 稀有度权重
  +
  社交性不可替代:
    trust_in_degree × 0.3            -- 被多少人信任
    trust_weight_avg × 0.2           -- 被信任的深度
    trust_category_diversity × 0.1   -- 被信任的广度
)
```

**IRI 的用途**：
- 不直接显示给玩家（防止攀比焦虑）
- 但系统用 IRI 来决定：离线通知的优先级、推荐算法的权重、治理系统的投票权
- 高 IRI 玩家如果连续离线，系统触发"关键人物流失预警"→ 提醒管理员

---

## 5. 防止系统被操控

| 攻击向量 | 防御 |
|:---|:---|
| 小号互评刷信任度 | 同IP检测 + 7天交互门槛 + 每日限额 |
| 大师占着位置不活跃 | 14天自动降级 |
| 恶意差评打压竞争者 | 负信任必须关联具体事件 + 被投诉方可以申诉 |
| 帮派集体刷某成员信任 | 信任边不按人数计数，按"边多样性"（来自不同帮派的信任权重大于同帮派） |

---

## 6. Bus Service 接口

```lua
Bus.RegisterService('reputation', {
  -- 信任图
  AddTrustEdge = function(from_citizen, to_citizen, category, weight, reason) end,
  RevokeTrustEdge = function(from_citizen, to_citizen, category) end,
  GetTrustSummary = function(citizenid) end,
  GetTrustGraph = function(citizenid, depth) end,  -- 深度N跳

  -- 技能位阶
  GetSkillRank = function(citizenid, skill_name) end,
  GetAllSkillRanks = function(citizenid) end,
  GetSkillMasters = function(skill_name) end,   -- 返回该技能的所有大师列表
  PromoteSkill = function(citizenid, skill_name, new_rank) end,  -- 仅内部调用
  DemoteSkill = function(citizenid, skill_name, reason) end,

  -- 不可替代性
  GetIRIndex = function(citizenid) end,
  GetCriticalPlayers = function() end,  -- IRI 前10%的玩家列表

  -- 查询
  FindTrusted = function(citizenid, category, min_weight) end,  -- 找到玩家信任的人
  FindTrusting = function(citizenid, category) end,  -- 找到信任这个玩家的人
})
```

---

## 7. 最小可行实施 (MVP)

Phase 0-1: **只做信任图的存储和读写**，不做位阶系统。

1. `trust_graph` 表
2. `ReputationService` 的基础增删查
3. 一个客户端 UI：查看某玩家的信任摘要（受多少人信任、在哪些类别）
4. 一个简单的交互门槛校验（7天内有过交易）

原因：信任图是纯粹的数据基础设施——不改变任何现有玩法，但后续所有"不可替代性"功能都建立在这张表上。先有数据，再做功能。

---

## 下一步

阅读 [04 — 共治系统](04-co-governance.md)，理解如何让玩家参与规则制定，完成从消费者到主人的身份转变。
