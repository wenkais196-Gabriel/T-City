# qb-inventory — 玩家背包系统

> **路径**: `resources/[qb]/qb-inventory/` | **状态**: ✅ ENABLED | **CFG 模块**: player.cfg
> **依赖**: qb-weapons | **被依赖**: qb-policejob, qb-ambulancejob, qb-management, custom-*, 几乎所有交互资源

---

## 核心 Exports (27 个)

| Export | 描述 |
|:---|:---|
| `LoadInventory(source)` | 从 DB 加载玩家背包 |
| `SaveInventory(source)` | 保存玩家背包到 DB |
| `AddItem(source, item, amount, slot?, info?)` | 添加物品 |
| `RemoveItem(source, item, amount, slot?)` | 移除物品 |
| `HasItem(source, items, amount?)` | 检查是否拥有物品 |
| `GetItemCount(source, item)` | 获取物品数量 |
| `GetItemByName(source, name)` | 按名称获取物品 |
| `GetItemsByName(source, name)` | 获取同名物品列表 |
| `GetSlots(source)` | 获取背包格子数 |
| `GetTotalWeight(source)` | 获取总重量 |
| `CanAddItem(source, item, amount)` | 检查能否添加 |
| `ClearInventory(source)` | 清空背包 |
| `OpenInventory(source, target?, type?)` | 打开背包 UI |
| `OpenShop(source, shop)` | 打开商店 UI |
| `CreateShop(shop)` | 创建商店 |
| `CreateInventory(id, data)` | 创建库存（stash） |
| `GetInventory(id)` | 获取库存 |

---

## 事件安全审计

| 事件 | 风险 | 问题 |
|:---|:---:|:---|
| `qb-inventory:server:SetInventoryData` | 🟠 MEDIUM | **核心物品移动处理器** — 解析客户端 `fromInventory`/`toInventory` 字符串。`otherplayer-` 前缀被解析和信任，**两玩家间无距离检查**。`shop-` 前缀已阻止。 |
| `qb-inventory:server:closeInventory` | 🟡 LOW | ⚠️ 每次关闭写入 `Inventories` 表 — 高频事件中的同步 DB 写 |
| `qb-inventory:server:snowball` | 🟢 LOW | 2s 冷却 |

---

## 数据库操作

| 操作 | 表 | 频率 |
|:---|:---|:---|
| `SELECT * FROM inventories` (启动) | `inventories` | 一次 |
| `INSERT ... ON DUPLICATE KEY UPDATE` | `inventories` | ⚠️ 每次 closeInventory |
| `SELECT inventory FROM players WHERE citizenid = ?` | `players` | LoadInventory |
| `UPDATE players SET inventory = ? WHERE citizenid = ?` | `players` | SaveInventory |

⚠️ **潜在性能问题**: `closeInventory` 中的 `MySQL.prepare` 是高频事件中的同步 DB 写。建议迁移到 DirtyFlush 批处理。

---

## 备注
- qb-inventory 自身不处理金钱 — 购买通过 `attemptPurchase` 回调，服务端验证商店距离、物品/价格匹配和现金余额
- 物品操作触发 `qb-log:server:CreateLog` 审计
