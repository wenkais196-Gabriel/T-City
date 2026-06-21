# 商店抢劫重构 — "罪与罚" 沉浸式玩法文档

## 一、用户手册

### 玩法总览

商店抢劫从原来的"撬锁→站桩25秒→拿钱"被重构为 **5阶段沉浸式流程**：

```
侦查 → 撬锁 → 翻找(主动操作) → 逃跑 → 良心独白
```

每个阶段都有清晰的行为动机和代入感设计。

### 各阶段详解

#### 阶段1：侦查 🔍
- 靠近商店收银机使用撬锁工具后自动触发
- 获得情报：摄像头位置、店员警觉度、是否有后门、是否装有报警系统
- **新机制**：了解情报后决定是否继续，提高策略性

#### 阶段2：撬锁 🔧
- 原有撬锁小游戏保留
- 撬锁成功触发NPC反应（4种不同类型的恐惧表现）
- **新机制**：NPC不再只有逃跑一种反应，增加了环境真实感

#### 阶段3：翻找收银机 💵
- **取代了旧版25秒干站**，改为主动翻找UI
- 进度条动态显示翻找进度
- 翻找期间随机触发环境威胁事件：
  - 远处警笛声 → 增加紧张感
  - 店内电话响 → 需要决定是否继续
  - 脚步声接近 → 威胁感升级
  - 心跳加速 → 心理压力增加
- 完成后选择拿取比例：
  - 🪙 只拿零钱 (25%) — 快速脱身
  - 💰 拿一半 (50%) — 适中收益
  - 💎 全部拿走 (100%) — 最大收益，最高风险

#### 阶段4：逃跑 🏃
- 翻找后进入逃跑选择：
  - 🕵️ 后巷溜走 — 隐蔽安全，速度较慢
  - 🏃 全速冲刺 — 快速但引人注目
  - 😐 混入人群 — 最隐蔽
- 逃跑方式影响良心扣分（不同方式代表不同的"危害程度"）

#### 阶段5：良心独白 💭
- **全新教育核心机制**
- 抢劫完成后自动触发内心独白UI
- 根据良心点数（0-200）展示不同的独白内容：
  - ≥80：良心尚在 — "你的手在发抖..."
  - 40-79：良心受创 — "店主恐惧的眼神挥之不去..."
  - <40：心灵麻木 — "你已经分不清对错了..."
- 玩家可选择：
  - 🤔 反思 — 减少压力
  - 😤 抛在脑后 — 持续麻木
  - ⚖️ 我想改变 — 进入救赎路径

### 救赎路径

**改过自新界面**提供三种救赎选择：
1. 🙏 **归还赃物** (+25良心) — 偷偷放回商店门口
2. ⚖️ **向警方自首** (+50良心) — 勇敢面对后果
3. ⏳ **再想想** — 退出界面

**累计善行奖励**：
- 归还赃物5次 → 获得「宽恕者」称号
- 自首 → 获得「第二人生」BUFF（合法工作收入+20%）

### 热赃物系统
- 抢劫获得的 `markedbills` 标记为热赃物
- 48小时内被警察搜身会被追查到
- 赃物可以匿名归还商店

---

## 二、开发者文档

### 文件清单

| 文件 | 角色 | 新增/修改 |
|------|------|-----------|
| `server/main.lua` | 服务端主逻辑 | 修改 |
| `client/main.lua` | 客户端主逻辑 | 修改 |
| `config.lua` | 配置文件 | 修改 |
| `html/index.html` | UI结构 | 修改 |
| `html/style.css` | UI样式 | 修改 |
| `html/script.js` | UI逻辑 | 修改 |
| `locales/en.lua` | 本地化 | 修改 |

### 新增事件

#### 服务端事件
| 事件名 | 触发方 | 参数 | 说明 |
|--------|--------|------|------|
| `qb-storerobbery:server:scoutingComplete` | 客户端 | `register` | 侦查阶段完成 |
| `qb-storerobbery:server:startLockpick` | 客户端 | `register` | 开始撬锁 |
| `qb-storerobbery:server:lootProgress` | 客户端 | `register, lootPercent` | 翻找进度更新 |
| `qb-storerobbery:server:lootingDone` | 客户端 | `register, takeAmount` | 翻找完成 |
| `qb-storerobbery:server:escapeComplete` | 客户端 | `register, escapeMethod` | 逃跑完成 |
| `qb-storerobbery:server:returnHotGoods` | 客户端 | `storeId, itemName` | 归还赃物 |
| `qb-storerobbery:server:surrender` | 客户端 | 无 | 自首 |

#### 客户端事件
| 事件名 | 参数 | 说明 |
|--------|------|------|
| `qb-storerobbery:client:scoutingIntel` | `intel` | 收到侦查情报 |
| `qb-storerobbery:client:enterEscape` | `data` | 进入逃跑阶段 |
| `qb-storerobbery:client:conscienceMonologue` | `data` | 良心独白 |
| `qb-storerobbery:client:threatAlert` | `alert` | 环境威胁警报 |

### 新增导出函数

```lua
-- 服务端
exports['qb-storerobbery']:GetConscience(citizenid)     -- 获取良心点数
exports['qb-storerobbery']:AdjustConscience(citizenid)   -- 调整良心点数
exports['qb-storerobbery']:AddHotGoods(citizenid, ...)   -- 添加热赃物
exports['qb-storerobbery']:HasHotGoods(citizenid)        -- 检查热赃物
exports['qb-storerobbery']:ReturnHotGoods(src, ...)      -- 归还赃物
exports['qb-storerobbery']:SurrenderToPolice(src)        -- 自首
```

### 新增配置项

```lua
-- config.lua 新增段落

-- 良心系统
Config.Conscience = {
    defaultPoints = 100,
    crimePenalty = -10,
    stealthEscapeBonus = 2,
    returnGoodsReward = 25,
    surrenderReward = 50,
    nightmareThreshold = 30,
    goodDeedThreshold = 5,
    hotGoodsDuration = 48,
}

-- 叙事配置
Config.Narrative = {
    threatCheckInterval = 5000,
    threatChance = 20,
    npcFearRadius = 40.0,
    npcReactionTime = 1200,
}

-- 赃物配置
Config.Loot = {
    lootingDuration = 25000,
    minTakePercent = 10,
    maxTakePercent = 100,
    markedbillsHotDuration = 48,
}
```

### 向后兼容

- 旧事件 `qb-storerobbery:server:startRobbery` 保留为路由器
- 旧客户端调用 `startRobbery` → 自动映射到 `startLockpick`
- 外部插件读取 `markedbills` 的行为完全不变
- 所有原有安全校验层（Rate Limit, 距离校验, 冷却）均保留

---

## 三、教育意义说明

### 设计哲学

```
不是不能犯罪，而是犯罪有重量。
每个犯罪选择都有连锁反应。
你在角色中体验后果，然后可以做出更好的选择。
这就是角色扮演的意义：体验不同人生，然后选择你想成为的人。
```

### 三层教育机制

1. **即时反馈层**（每轮抢劫后）
   - 良心独白 — 让玩家面对自己的选择
   - 三个回应选项 — "反思、忽略、改变"，尊重玩家自主性

2. **积累反馈层**（多次犯罪后）
   - 良心点数持续扣减 → NPC对话变化 → 噩梦效果
   - 累计善行 → 社区接纳 → 隐藏奖励
   - 让玩家看到行为的长期影响

3. **救赎路径层**（任何时候）
   - 归还赃物 — 弥补具体伤害
   - 自首 — 承担法律后果
   - "第二人生" — 给予重新开始的机会
   - **核心信息**：永远有一条回头路

### 为什么不是"禁止犯罪"？

因为完全的禁止会促使玩家寻找绕过方法。我们的设计是**让犯罪有真实感而非美化**：
- 不是"犯罪=坏"的说教
- 而是"犯罪有代价，但你可以选择改变"的叙事
- 尊重角色扮演的自由，同时提供反思的窗口
