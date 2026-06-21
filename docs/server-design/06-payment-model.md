# 06 — 付费模型：Patron + Identity 双轨设计

> **核心命题**: 付费不是"我给你东西，你给我钱"的交易，而是"这个服务器值得养，我的成就值得被看见"的归属行为。  
> **前置阅读**: [00 — 所有权哲学](00-ownership-philosophy.md) / [04 — 共治系统](04-co-governance.md)

---

## 1. 双轨模型概述

```
付费动机:
  所有权感
    ├── "我怕失去这个地方" → 轨道1: Patron (养服务器)
    └── "我的成就应该被看见" → 轨道2: Identity (买面儿)

铁律:
  ❌ 不卖游戏货币
  ❌ 不卖数值/属性优势
  ❌ 不卖执法豁免
  ❌ 不卖跳过互赖环节的道具
```

---

## 2. 轨道1: Patron — 养服务器

### 2.1 核心设计原则

> **Patron 不是"氪金"，是"养服"。**

这意味着：
- Patron 得到的不是游戏内优势，而是**身份标记**——对社区贡献者的表彰
- Patron 金额和服务器的运营透明度绑定——玩家知道他们的钱去哪了
- Patron 身份**在视觉上必须与成就标记可区分**——不能让人混淆"这个人充了钱"和"这个人是帮派首领"

### 2.2 等级设计

| 等级 | 月供 | 获得内容 | 设计意图 |
|:---|:---|:---|:---|
| **无** | ¥0 | 全部游戏内容 | 免费玩家是社区基石，绝不能受歧视 |
| **Tier 1** | ¥30 | `[资助者]` 称号前缀<br>Discord 专属角色<br>名字颜色: 铜色 | 心理门槛最低——"支持一下" |
| **Tier 2** | ¥60 | Tier 1 全部<br>名字颜色: 银色<br>服务器满员时优先排队<br>月度专属 Discord 频道 | "认真支持"——给实质性便利但不动平衡 |
| **Tier 3** | ¥100 | Tier 2 全部<br>名字颜色: 金色<br>自定义称号前缀<br>社区议会投票权重 1.5<br>新功能内测资格 | "核心赞助者"——给发言权，正式纳入共治体系 |

### 2.3 运营透明度面板

**展示位置**: Discord 频道 `#server-finance` + 游戏内终端 `/patron`

```
┌──────────────────────────────────────┐
│     T-City 运营资金 — 2026年6月        │
│                                      │
│  月度运营成本:                         │
│    VPS 主机         ¥350              │
│    数据库             ¥120             │
│    带宽               ¥80             │
│    其他               ¥50             │
│    合计              ¥600             │
│                                      │
│  当前 Patron 月供:                     │
│    Tier 1 × 12 人    ¥360             │
│    Tier 2 × 5 人     ¥300             │
│    Tier 3 × 2 人     ¥200             │
│    合计              ¥860             │
│                                      │
│  覆盖率: 143%  ████████████████░      │
│  储备金: ¥1,240 (用于服务器升级/活动)  │
└──────────────────────────────────────┘
```

**关键规则**：
- 总额公开，个人贡献金额不公开（防攀比）
- 超出成本部分进入"服务器储备金"——用途需在社区议会讨论
- 连续三个月覆盖不足 → 触发"服务器存续社区讨论"

### 2.4 支付与发放流程

```
玩家发起 Patron 订阅（外部支付平台，如爱发电/Patreon）
  → 支付平台 Webhook 回调
  → PatronService: 验证签名 + 匹配玩家（通过 Discord ID 或登记码）
  → 写入 player_metadata.patron_tier
  → 客户端渲染对应名字颜色和称号
  → 每月1日自动扣除（如支付失败，降为 Tier 0 + 通知）

关键安全点:
  - 支付回调必须走 HMAC 签名验证
  - patron_tier 字段只能由支付回调/管理员命令修改
  - 客户端事件修改 patron_tier 的请求 → 直接拒绝 + 安全审计日志
```

---

## 3. 轨道2: Identity — 买面儿

### 3.1 核心原则

> **你能买的，一定是你先挣到的。**

| 规则 | 说明 |
|:---|:---|
| **先挣后买** | 只有达成了某个成就，才能解锁购买对应的 cosmetic |
| **绑定成就** | cosmetic 绑定到成就状态——不再是帮派首领就不能继续佩戴首领徽章 |
| **不可交易** | Identity 物品绑定到角色，不可转让（防止RMT） |
| **不叠加数值** | 所有 Identity 物品纯粹是视觉表达，0数值加成 |

### 3.2 解锁树示例

```
成就: 成为帮派首领
  → 解锁购买:
      ├── 首领徽章 (¥30 / 永久)
      ├── 首领座驾涂装 (¥50 / 永久)
      ├── 帮派总部定制内饰 (¥100 / 永久)
      └── 首领专属动作 (¥15 / 永久)

成就: 成为大师级武器商
  → 解锁购买:
      ├── 熔炉特效皮肤 (¥30 / 永久)
      ├── 定制武器展示架 (¥40 / 永久)
      └── 大师工坊外观 (¥80 / 永久)

成就: 完成稀有任务链
  → 解锁购买:
      ├── 专属称号 (¥20 / 永久)
      └── 专属载具涂装 (¥40 / 永久)

成就: 参与10次以上帮派战
  → 解锁购买:
      └── 老兵纹身 (¥15 / 永久)
```

### 3.3 价格心理锚定

所有 Identity 物品价格在 ¥15-¥100 之间。原因：

| 价格区间 | 心理效应 |
|:---|:---|
| ¥15-30 | 冲动消费区。"才一杯奶茶钱"——买就买了 |
| ¥40-80 | 价值消费区。"这个徽章是我帮派首领的证明，值" |
| ¥100 | 里程碑消费区。只在特别重要的成就上放这个价 |

**不做的东西**：
- ❌ 抽卡/盲盒（赌博感毁信任）
- ❌ 限时绝版（人工稀缺毁所有权感——如果真的是绝版，应该是因为那个赛季确实结束了，而不是"这周不买就没了"）
- ❌ 捆绑包（"买三送一"——廉价感）

### 3.4 成就验证的安全流程

```
客户端请求: "我要买首领徽章"
  → 携带: { achievement_id: "gang_leader", item_id: "leader_badge" }

Server:
  1. AchievementService.Check(citizenid, 'gang_leader')
     → 查询 player_metadata.achievements 中是否有此成就
     → 验证成就仍然有效（玩家当前确实是帮派首领）
  2. UnlockService.IsUnlockable(citizenid, 'leader_badge')
     → 检查该物品是否需要此成就
     → 检查是否已经购买过（永久物品不可重复购买）
  3. CosmeticsService.Purchase(citizenid, 'leader_badge', price)
     → 记录购买
     → 发放物品到玩家的 cosmetic 库存

如果成就丢失（不再是首领）:
  → 已购买的徽章变为"不可装备"状态
  → 物品仍然在库存中（玩家可以重新获得成就后继续使用）
  → 不是删除——是"冻结"
```

**防注入要点**：
- `achievement_id` 必须在服务端校验——客户端传来的 achievement_id 不可信
- 校验分两步：①该玩家是否确实有此成就（查数据库）②该成就当前是否仍然有效（比如仍然是帮派首领）
- 如果 client 发送的 achievement_id 和 player 实际成就状态不一致 → 记录 SuspiciousEvent

---

## 4. 两个轨道的交叉点

### 4.1 Patron 获得小额 Identity 福利（非卖品）

| Patron 等级 | 额外解锁 |
|:---|:---|
| Tier 1 | 解锁购买 `[资助者]` 专属称号（¥0，就是 Patron 自带的那个） |
| Tier 2 | 解锁购买"银色姓名框"（¥0，就是你已经在用的那个） |
| Tier 3 | 解锁购买"金色冠名框"（¥0）+ 自定义称号（¥0） |

**关键**: 这些是 Patron 自带的，不需要额外付费。但它们的技术实现用的是 Identity 系统的同一套 unlock/purchase/equip 管道——减少系统碎片化。

### 4.2 不让 Patron 看起来像 Pay-to-Win

五大视觉区分规则：

| 可以区分 Patron 和成就 | 视觉差异 |
|:---|:---|
| 名字颜色 | Patron 用金属色（铜银金），成就用其他颜色（红蓝绿） |
| 称号前缀 | Patron 用方括号 `[资助者]`，成就用书名号 `《帮派首领》` |
| 称号位置 | Patron 称号在名字上方，成就称号在名字下方 |
| 徽章 | 完全不同形状——Patron 用盾形（守护者），成就用星形（成就者） |
| 列表排序 | Patron 和成就标记都不影响玩家列表的排序 |

**目标**: 让任何玩家扫一眼就知道——"这个人支持了服务器"和"这个人是帮派首领"是两个完全不同的概念。

---

## 5. 收入模型预测

假设服务器稳定在线 50-80 人（DAU），典型转化：

```
DAU:           60人
Patron 转化率: 15% → 9人
  其中 Tier 1: 5人 × ¥30  = ¥150
       Tier 2: 3人 × ¥60  = ¥180
       Tier 3: 1人 × ¥100 = ¥100
Patron 月收入: ¥430

Identity 购买:  约30%的DAU在3个月内会有至少一次购买
  月均交易: 18次 × 均价¥40 = ¥720

总月收入: ~¥1,150
运营成本: ¥600
净盈余: ¥550 → 进入储备金
```

**如果做不到这个转化率怎么办？**
不要降价，不要增加Pay-to-Win。问题不在付费设计，而在所有权感没建立起来——回到前5篇文档，检查漏斗、痕迹、声誉、共治、叙事哪个环节弱了。

---

## 6. 核心数据结构

### 6.1 Patron 记录

```sql
CREATE TABLE patron_records (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  citizenid     VARCHAR(64) NOT NULL,
  tier          INT NOT NULL DEFAULT 0,    -- 0=无, 1/2/3
  started_at    TIMESTAMP NULL,
  expires_at    TIMESTAMP NULL,            -- 月供到期日
  external_id   VARCHAR(128),             -- 外部支付平台的用户ID
  external_plan VARCHAR(64),              -- 外部平台的套餐ID
  auto_renew    BOOLEAN DEFAULT TRUE,
  created_at    TIMESTAMP DEFAULT NOW(),
  updated_at    TIMESTAMP DEFAULT NOW(),

  UNIQUE KEY idx_citizen (citizenid)
);
```

### 6.2 Identity 物品

```sql
CREATE TABLE cosmetic_items (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  item_id       VARCHAR(64) NOT NULL UNIQUE,
  item_name     VARCHAR(128) NOT NULL,
  item_type     VARCHAR(32) NOT NULL,      -- 'title', 'badge', 'vehicle_skin', 'interior', 'emote'
  required_achievement VARCHAR(64),        -- 需要的成就ID
  price_cny     INT NOT NULL,             -- 人民币价格（分）
  is_permanent  BOOLEAN DEFAULT TRUE,      -- TRUE=永久, FALSE=消耗品(未来扩展)
  preview_url   VARCHAR(255),              -- 预览图URL（Discord机器人会用到）
  created_at    TIMESTAMP DEFAULT NOW(),

  INDEX idx_achievement (required_achievement)
);

CREATE TABLE player_cosmetics (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  citizenid     VARCHAR(64) NOT NULL,
  item_id       VARCHAR(64) NOT NULL,
  purchased_at  TIMESTAMP DEFAULT NOW(),
  equipped      BOOLEAN DEFAULT FALSE,
  frozen        BOOLEAN DEFAULT FALSE,     -- 成就丢失后冻结

  UNIQUE KEY idx_player_item (citizenid, item_id),
  INDEX idx_equipped (citizenid, equipped)
);
```

---

## 7. Bus Service 接口

```lua
Bus.RegisterService('patron', {
  SetTier = function(citizenid, tier, external_data) end,  -- 仅支付回调/管理员
  GetTier = function(citizenid) end,
  GetAllPatrons = function() end,
  GetMonthlyStats = function() end,  -- 用于运营透明度面板
})

Bus.RegisterService('cosmetics', {
  GetUnlockable = function(citizenid) end,  -- 返回此玩家可购买的所有 cosmetic
  Purchase = function(citizenid, item_id) end,
  Equip = function(citizenid, item_id) end,
  Unequip = function(citizenid, item_id) end,
  GetLoadout = function(citizenid) end,     -- 当前装备的 cosmetic
  GetInventory = function(citizenid) end,   -- 拥有的所有 cosmetic
  CheckFrozen = function(citizenid) end,    -- 检查是否有 cosmetic 因成就丢失而冻结
})

Bus.RegisterService('unlocks', {
  IsUnlocked = function(citizenid, unlock_id) end,
  GetUnlocked = function(citizenid) end,
})
```

---

## 8. 最小可行实施 (MVP)

Phase 2 的实施顺序：

1. **先做 Patron 基础设施**（最早验证"养服务器"假设）
   - `patron_records` 表
   - `PatronService` 的 GetTier/SetTier
   - 客户端名字颜色 + 称号渲染
   - 支付 Webhook 接收端点（先手动验证，后自动化）

2. **再做 Identity 基础设施**
   - `cosmetic_items` + `player_cosmetics` 表
   - `CosmeticsService` 基础 CRUD
   - 成就验证链路（`AchievementService.Check()`）

3. **最后做运营透明度面板**
   - Patron 统计 + 成本配置
   - Discord Bot 命令 `/patron-status`

Phase 2 不需要做完整的商城 UI——可以先通过 Discord Bot 命令完成购买。游戏内 UI 在 Phase 3 再打磨。

---

## 下一步

阅读 [07 — 架构集成](07-architecture-integration.md)，理解以上所有系统如何嵌入 T-City Phase 0-3 的工程路线图。
