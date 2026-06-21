# 04 — 共治系统：让玩家成为规则的共同制定者

> **核心命题**: "这个世界的规则，我有发言权"——当玩家从规则的被动接受者变成共同制定者，所有权感达到顶峰。  
> **前置阅读**: [00 — 所有权哲学](00-ownership-philosophy.md) / [03 — 不可替代性与声誉](03-irreplaceability-reputation.md)

---

## 1. 为什么共治是所有权感的终极锚点？

在真实世界里，你对自己的房子有所有权感，不仅因为你住在那，更因为：
- 你可以决定客厅的布局
- 你可以决定谁来、谁不能来
- 你可以决定是否养宠物

在虚拟世界里，共治让玩家获得同样的心理体验——**对这个世界的部分规则有决定权**。

没有共治的帮派 = 一群人在一个聊天频道里，管理员说了算。
有共治的帮派 = 一个微型社会，成员共同制定帮规、选举首领、决定宣战或休战。

---

## 2. 共治的三层范围

```
┌──────────────────────────────────────┐
│ 第三层: 全服共治 (Community Council)  │
│ 参与资格: IRI 前20% + 连续在线>60天    │
│ 权限: 服务器规则提案、管理员监督      │
├──────────────────────────────────────┤
│ 第二层: 组织共治 (Organization Vote)   │
│ 参与资格: 组织成员                     │
│ 权限: 帮规修改、首领选举、宣战/休战    │
├──────────────────────────────────────┤
│ 第一层: 个人领地 (Personal Domain)     │
│ 参与资格: 房产/车辆/企业所有者         │
│ 权限: 装修、定价、准入控制             │
└──────────────────────────────────────┘
```

---

## 3. 第一层：个人领地（保障安全感）

这是共治的最基础层，也是最容易实现的：

### 3.1 房产自治

| 权限 | 说明 |
|:---|:---|
| 装修自定义 | 家具、墙纸、灯光（通过游戏内编辑器或第三方工具） |
| 准入控制 | 白名单/黑名单；临时访客码 |
| 商业授权 | 如果房产是商铺，可以设定营业时间、定价策略 |
| 转租 | 可以将部分空间转租给其他玩家 |

### 3.2 企业自治

如果玩家拥有企业（修车铺、武器店等）：

| 权限 | 说明 |
|:---|:---|
| 招聘/解雇 | 决定谁可以在这里工作 |
| 定价 | 在产品基础价格上设定自己的利润率 |
| 供应链 | 选择原材料供应商（固定NPC还是玩家供应商） |
| 品牌 | 企业名称、标志（绑定成就解锁或付费） |

**实现**: 这些大多是现有系统的扩展——房屋系统、企业系统。关键是确保这些操作的服务器端权威校验不遗漏。

---

## 4. 第二层：组织共治（核心——这是"微型社会"的引擎）

### 4.1 提案-投票-执行的完整生命周期

```
阶段1: 提案
  任何成员（或达到特定资格）可以创建提案
  提案类型: 修改帮规、选举/罢免首领、宣战/休战、联盟/断交、资金分配、新成员准入标准
  提案需要附理由（最少50字）

阶段2: 联署
  提案需要获得N个成员联署才能进入投票阶段
  N = 组织总人数的平方根（取整）——既不是1人独裁，也不是全员乱投

阶段3: 投票
  投票期: 24-72小时（根据提案类型）
  权重: 一人一票 + 高阶成员有加权（可选）
  匿名投票（防社交压力）
  最低投票人数门槛

阶段4: 自动执行
  如果通过 → 系统自动执行提案内容
  如果否决 → 提案进入冷却期（同样提案30天内不得再提）

阶段5: 公示
  结果在组织内部公告 + 可选同步 Discord
```

### 4.2 提案类型与执行映射

| 提案类型 | 通过条件 | 自动执行动作 |
|:---|:---|:---|
| 修改帮规 | 60%赞成 | 更新 `organization_rules` 表，通知全员 |
| 选举首领 | 50%赞成 + 最高票 | 更新 `organization.leader`，触发首领更迭事件 |
| 罢免首领 | 66%赞成 | 首领降为普通成员，触发重新选举 |
| 宣战 | 60%赞成 | 系统创建战争状态，启用PVP规则和领土争夺 |
| 休战/和平 | 50%赞成 | 结束战争状态，恢复和平规则 |
| 资金分配 | 50%赞成 | 从组织金库转账到指定用途 |
| 新成员准入 | 50%赞成 | 自动发送邀请 |

### 4.3 帮规模板（减少冷启动负担）

帮派创建时，不是从空白开始——提供预制模板：

```yaml
帮规模板:
  1. 民主制:
     - 首领每30天选举一次
     - 重大决策需投票
     - 资金使用需公示

  2. 独裁制:
     - 首领无限期
     - 首领有权直接决策
     - 成员可以投票罢免

  3. 财阀制:
     - 按出资比例分配投票权
     - 核心圈由出资前5名组成
     - 新成员需购买股份

  4. 委员会制:
     - 3-5人委员会共同决策
     - 轮值主席
     - 专业性分工（后勤、作战、外交）
```

---

## 5. 第三层：全服共治（社区议会）

**仅在服务器运营6个月+、活跃玩家>50人后开启。**

### 5.1 议会结构

```
社区议会 (9-15席):
  选举席位 (60%):  由全体活跃玩家投票选出
  成就席位 (20%):  系统根据 IRI 指数自动分配（不可投票干涉）
  管理员席位 (20%): 服务器运营方

任期: 3个月
连任: 最多连续2届
```

### 5.2 议会的权限范围

| 可议 | 不可议 |
|:---|:---|
| 经济参数调整建议（税率、刷新率） | 管理员人事 |
| 新功能优先级投票 | 服务器关停 |
| 赛季主题投票 | 付费定价 |
| 举报审核（复核管理员封禁决定） | 反作弊规则 |
| 活动策划 | 代码开发方向 |

**关键设计**: 议会是"建议权"而非"决策权"——管理员有最终否决权。但否决需要公开说明理由。这个设计保证：
- 玩家有参与感（发言权是真实的）
- 服务器不会因为玩家投票而走向自杀（管理员有否决权）
- 否决的透明化本身就是信任建设

### 5.3 Patron 与共治的关系

Patron 获得微小但真实的投票权加成：

| Tier | 投票权加成 | 议会资格 |
|:---|:---|:---|
| 无 | 1 票 | 可被选举 |
| Tier 1 | 1 票 | 可被选举 |
| Tier 2 | 1 票 | 可被选举 |
| Tier 3 | 1.5 票 | 可被选举 |

**关键**: 付费不改变"能否参与"（门槛不变），只给 Tier 3 一个温和的权重加成。这个加成小到不会改变选举结果（1.5票 vs 1票，在50人的投票中微不足道），但足够让 Tier 3 玩家感到"我的支持被认可了"。

---

## 6. 核心数据结构

### 6.1 提案表

```sql
CREATE TABLE governance_proposals (
  id              INT AUTO_INCREMENT PRIMARY KEY,
  scope           ENUM('organization', 'server') NOT NULL,
  scope_id        VARCHAR(64),                  -- 组织ID（组织级别）或 NULL（服务器级别）
  proposal_type   VARCHAR(32) NOT NULL,         -- 提案类型
  title           VARCHAR(255) NOT NULL,
  description     TEXT NOT NULL,
  proposed_by     VARCHAR(64) NOT NULL,         -- citizenid
  proposed_at     TIMESTAMP DEFAULT NOW(),

  -- 联署
  required_cosign INT DEFAULT 0,
  cosigners       JSON DEFAULT '[]',            -- [citizenid, ...]

  -- 投票阶段
  status          ENUM('draft', 'cosigning', 'voting', 'passed', 'rejected', 'executed', 'vetoed') DEFAULT 'draft',
  voting_start    TIMESTAMP NULL,
  voting_end      TIMESTAMP NULL,
  min_voters      INT DEFAULT 0,
  votes_for       INT DEFAULT 0,
  votes_against   INT DEFAULT 0,
  vote_details    JSON DEFAULT '{}',            -- {citizenid: {vote, weight}}

  -- 执行
  execution_fn    VARCHAR(64),                  -- 自动执行函数名
  execution_args  JSON,
  executed_at     TIMESTAMP NULL,
  executed_by     VARCHAR(64),                  -- 'system' 或管理员 citizenid

  -- 公示
  result_announced BOOLEAN DEFAULT FALSE,

  INDEX idx_scope (scope, scope_id),
  INDEX idx_status (status),
  INDEX idx_proposed_by (proposed_by)
);
```

### 6.2 组织规则表

```sql
CREATE TABLE organization_rules (
  id              INT AUTO_INCREMENT PRIMARY KEY,
  org_id          VARCHAR(64) NOT NULL,
  rule_key        VARCHAR(64) NOT NULL,         -- 'election_period', 'vote_threshold', ...
  rule_value      JSON NOT NULL,
  changed_by_proposal INT NULL,                -- 关联的提案ID
  changed_at      TIMESTAMP DEFAULT NOW(),

  UNIQUE KEY idx_org_rule (org_id, rule_key)
);
```

---

## 7. Bus Service 接口

```lua
Bus.RegisterService('governance', {
  -- 提案
  CreateProposal = function(scope, scope_id, proposal_type, title, description, proposed_by) end,
  CosignProposal = function(proposal_id, citizenid) end,
  Vote = function(proposal_id, citizenid, vote, weight) end,
  GetProposal = function(proposal_id) end,
  GetActiveProposals = function(scope, scope_id) end,

  -- 执行
  ExecuteProposal = function(proposal_id) end,  -- 仅系统调用
  VetoProposal = function(proposal_id, admin_citizenid, reason) end,

  -- 查询
  GetProposalHistory = function(scope, scope_id, limit) end,
  GetVoterEligibility = function(citizenid, scope, scope_id) end,

  -- 组织规则
  GetOrgRule = function(org_id, rule_key) end,
  SetOrgRule = function(org_id, rule_key, value, proposal_id) end,
})
```

---

## 8. 最小可行实施 (MVP)

Phase 1 (组织共治)：

1. `governance_proposals` 表
2. `organization_rules` 表（先在 organization metadata JSON 中也可以，但独立表查询更方便）
3. 两种提案类型: "选举首领" + "宣战/休战"
4. 客户端 UI: 组织面板里的"提案"标签页
5. 自动执行: 选举结果自动更换首领职位

Phase 3 (全服共治)：
- 社区议会选举
- 服务器级别提案
- 管理员否决 + 公开说明

先做组织共治的 MVP——它同时也是帮派系统真正"活"起来的关键——目前大多数帮派只是大号组队。

---

## 下一步

阅读 [05 — 叙事所有权](05-narrative-ownership.md)，理解如何让服务器拥有自己的历史，让每个玩家都成为历史的一部分。
