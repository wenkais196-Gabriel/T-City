# Module 1: 核心基础设施 (core.cfg / player.cfg / voice.cfg)

> **CFG 文件**: `configs/modules/core.cfg` `player.cfg` `voice.cfg`
> **资源数**: 30 个 (14 + 15 + 1)
> **启动顺序**: 最先加载 — 必须在任何 gameplay 资源之前

---

## 1.1 启动流程

```
os.time
 ↓
aaa_silence       ← 全局静默模式 + print 过滤器
 ↓
mapmanager        ← CFX 地图管理
chat              ← CFX 聊天
spawnmanager      ← CFX 出生管理
sessionmanager    ← CFX 会话管理
basic-gamemode    ← CFX 基础游戏模式
hardcap           ← CFX 性能上限
baseevents        ← CFX 基础事件
 ↓
oxmysql           ← 数据库驱动 (node-mysql2)
 ↓
qb-core           ← QBCore 核心框架 (Player 类、Functions、事件、数据库表)
production-freeze ← 生产模式冻结 (i18n + Debug OFF + Entity GC)
qb-loading        ← 加载画面
 ↓
menuv             ← 菜单库
qb-adminmenu      ← 管理员菜单
 ↓
PolyZone          ← 多边形区域检测
qb-menu           ← 交互菜单
qb-input          ← 输入菜单
qb-target         ← 第三人称瞄准交互
 ↓
qb-interior       ← 室内壳模型
qb-clothing       ← 服装系统
qb-weathersync    ← 时间/天气同步
 ↓
qb-apartments     ← 公寓分配
qb-spawn          ← 出生点选择
qb-multicharacter ← 多角色创建
 ↓
qb-cityhall       ← 市政厅 (身份证/执照/职业变更)
 ↓
qb-weapons        ← 武器系统
qb-inventory      ← 背包系统 ← 依赖 qb-weapons
 ↓
qb-hud            ← HUD (饥饿/口渴/压力)
qb-scoreboard     ← 计分板
 ↓
pma-voice         ← VOIP 语音 (最后加载)
```

---

## 1.2 关键资源详解

### qb-core — 框架核心

**文件**: `resources/[qb]/qb-core/`

- 50+ `QBCore.Functions.*` 公共 API
- `Player` 类：登录 → 加载角色数据 → 存盘 → 登出
- 核心表：`players`, `bans`, `whitelist`
- 经济服务：`AddMoney/RemoveMoney/SetMoney/TransferMoney`（纯内存 + DirtyFlush）
- 安全服务：`ValidateMoneyEvent/JobEvent/GangEvent/ItemEvent`
- 回调系统：`TriggerClientCallback/CreateCallback`

> 📄 详见: `../02_script_index/qb-core.md`

### oxmysql — 数据库驱动

**导出模式**: `MySQL.query.await`, `MySQL.scalar.await`, `MySQL.insert.await`, `MySQL.update.await` 等异步接口。**T-City 标准要求使用回调模式 `MySQL.Async.fetchAll` 替代同步 await**（见四大铁律 §2 高性能）。

### production-freeze — 生产模式冻结

- 全局 i18n 多语言
- 调试输出关闭 (`PRODUCTION_MODE`)
- 实体 GC (垃圾回收)
- PolyZone 打磨

### qb-inventory — 背包系统

**27 个 exports** — 核心物品操作 API。被几乎所有交互资源使用。

⚠️ **已知问题**:
- `SetInventoryData` 在 `otherplayer-` 库存间移动物品时缺少距离校验
- `closeInventory` 中的同步 DB 写可迁移至 DirtyFlush

> 📄 详见: `../02_script_index/qb-inventory.md`

---

## 1.3 数据流

```
Player Joins
  ↓
qb-multicharacter → 选择/创建角色
  ↓
qb-core:Player.LoadFromDB() → players 表
  ↓
qb-apartments → 分配公寓
qb-spawn → 选择出生点
  ↓
qb-inventory:LoadInventory → 从 players.inventory JSON 加载
  ↓
HUD + Scoreboard 显示
  ↓
Player Plays...
  ↓
qb-core:Player.Functions.Save() → DirtyFlush 标记
  ↓
Player Leaves → DirtyFlush.ForceFlush → players 表 UPSERT
```

---

## 1.4 安全边界

| 边界 | 机制 |
|:---|:---|
| 客户端注入 | qb-core `PrepForSQL` SQL 注入模式检查 |
| 角色创建 | `IsLicenseInUse` 重复许可证检查 |
| 白名单 | `IsWhitelisted` 检查 |
| 封禁 | `IsPlayerBanned` → bans 表自动过期检查 |
| 作弊 | `ExploitBan` → 插入 bans + Drop |

---

## 1.5 维护要点

1. **oxmysql** 必须最先加载（在 qb-core 之前），否则所有依赖资源的 DB 查询失败
2. **qb-weapons** 必须在 qb-inventory 之前加载（fxmanifest 硬依赖）
3. **qb-interior → qb-clothing → qb-weathersync** 序列不可改变 — qb-apartments 依赖它们全部
4. **pma-voice** 需要 `onesync on`（通过 txAdmin 设置）
5. **production-freeze** 的 `PRODUCTION_MODE` 覆盖所有资源中的 `print()` 行为
