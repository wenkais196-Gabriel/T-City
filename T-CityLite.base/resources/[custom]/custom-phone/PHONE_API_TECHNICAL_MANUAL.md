# 📱 自研手机系统 (Custom Phone System v1.0) — 功能路由、接口与数据交互技术手册

> **项目路径**: `resources/[custom]/custom-phone/`
> **前端框架**: Svelte 4 + TypeScript
> **后端**: FiveM Lua (Lua 5.4)
> **数据库**: MariaDB (via `oxmysql`)
> **依赖**: `qb-core`, `oxmysql`, `pma-voice`（通话路由预留）
>
> **生成日期**: 2025-01-22
> **手册版本**: v1.0

---

## 📋 目录

- [模块总览](#-模块总览)
- [1. 手机核心 — Phone Core](#1️⃣-手机-core--phone-core-开机关屏数据加载)
- [2. 通讯录 — Contacts App](#2️⃣-通讯录--contacts-app)
- [3. 短信 — Messages App](#3️⃣-短信--messages-app)
- [4. 银行转账 — Banking App](#4️⃣-银行转账--banking-app)
- [5. 城市动态 — CityFeed App](#5️⃣-城市动态--cityfeed-app)
- [6. 任务板 — Job Board App](#6️⃣-任务板--job-board-app)
- [7. 派系频道 — Faction Channel App](#7️⃣-派系频道--faction-channel-app)
- [8. 紧急热线 & IVR — Hotlines App](#8️⃣-紧急热线--ivr--hotlines-app)
- [9. 车库查询 — Garage App](#9️⃣-车库查询--garage-app)
- [10. 拨号面板 — PhoneCall App](#1️⃣0️⃣-拨号面板--phonecall-app)
- [11. 通知中心 — Notifications App](#1️⃣1️⃣-通知中心--notifications-app)
- [12. 领袖应用 — Leader Apps](#1️⃣2️⃣-领袖应用--leader-apps)
- [13. 动态领袖权限注册](#1️⃣3️⃣-动态领袖权限注册)
- [14. 跨模块汇总参考](#1️⃣4️⃣-跨模块汇总参考)
- [安全边界说明](#-安全边界说明)

---

## 📋 模块总览

| 序号 | 模块名称 | 前端文件 | Lua 客户端 | Lua 服务端 | 数据表 |
|------|----------|----------|------------|------------|--------|
| 1 | **手机核心** (Phone Core) | `App.svelte` | `client/main.lua` | `server/main.lua` | `phone_numbers` |
| 2 | **通讯录** (Contacts) | `Contacts.svelte` | `client/main.lua` | `server/main.lua` | `phone_contacts` |
| 3 | **短信** (Messages) | `Messages.svelte` | `client/main.lua` | `server/main.lua` | `phone_messages` |
| 4 | **银行转账** (Banking) | `Banking.svelte` | `client/main.lua` | `server/banking.lua` | `players` (JSON) |
| 5 | **城市动态** (CityFeed) | `CityFeed.svelte` | `client/main.lua` | `server/main.lua` | `phone_cityfeed` |
| 6 | **任务板** (Job Board) | `JobBoard.svelte` | `client/main.lua` | `server/jobboard.lua` | `phone_jobboard` |
| 7 | **派系频道** (Faction) | `FactionChannel.svelte` | `client/main.lua` | `server/faction.lua` | 内存 (`GlobalState`) |
| 8 | **紧急热线** (Hotlines) | `Hotlines.svelte` | `client/main.lua` | `server/main.lua` | 无 (动态查询) |
| 9 | **车辆查询** (Garage) | `Garage.svelte` | `client/main.lua` | `server/main.lua` | `player_vehicles` |
| 10 | **拨号面板** (PhoneCall) | `PhoneCall.svelte` | 纯 UI | — | — |
| 11 | **通知中心** (Notifications) | `Notifications.svelte` | `client/main.lua` | 推送来源 | 内存 (瞬态) |
| 12 | **市长面板** (MayorApp) | `leader/MayorApp.svelte` | `client/main.lua` | `server/jobboard.lua` | `phone_jobboard` |
| 13 | **警长指挥** (SheriffApp) | `leader/SheriffApp.svelte` | `client/main.lua` | `server/faction.lua` | 内存 (`GlobalState`) |
| 14 | **黑帮老大** (GangBossApp) | `leader/GangBossApp.svelte` | `client/main.lua` | `server/faction.lua` | 内存 (`GlobalState`) |

---

## 1️⃣ 手机 Core — Phone Core (开机/关屏/数据加载)

### 1.1 功能概述

手机的开/关逻辑、游戏内时间天气同步、主数据初始化加载。按下 `M` 键或输入 `/phone` 命令开机，`ESC` 或在 UI 中点击关闭按钮关机。

**源码**: `client/main.lua` (OpenPhone / ClosePhone 函数), `web/src/App.svelte` (事件监听)

### 1.2 客户端命令与键绑定

| 名称 | 触发方式 | 作用 |
|------|----------|------|
| `phone` | 键盘 `M` 键 | 开/关手机（通过 `RegisterCommand` + `RegisterKeyMapping`） |

### 1.3 NUI ➔ Client (RegisterNUICallback)

#### closePhone

| 属性 | 值 |
|------|-----|
| **接口名称** | `closePhone` |
| **方向** | NUI ➔ Client |
| **功能** | 前端请求关闭手机 |
| **发送数据** | `{}` |
| **接收数据** | `{ "success": true }` |

#### getPhoneData

| 属性 | 值 |
|------|-----|
| **接口名称** | `getPhoneData` |
| **方向** | NUI ➔ Client (via `QBCore.Functions.TriggerCallback`) |
| **功能** | 应用启动时加载玩家全量数据 |
| **发送数据** | `{}` |
| **接收数据** | 见下方服务端回调 `phone:server:getPhoneData` |

### 1.4 Client ➔ Server (QBCore Callback)

#### phone:server:getPhoneData

| 属性 | 值 |
|------|-----|
| **接口名称** | `phone:server:getPhoneData` |
| **方向** | Client ➔ Server (CreateCallback) |
| **功能** | 加载玩家完整手机数据 |

**接收数据 (Callback)**:
```json
{
  "success": true,
  "playerData": {
    "citizenid": "string",
    "name": "string",
    "phone": "string",
    "phoneNumbers": ["string"],
    "money": { "cash": "number", "bank": "number" },
    "career": {
      "primary_role": "string",
      "rank_tier": "string",
      "department": "string",
      "certs": ["string"]
    }
  },
  "contacts": [/* 联系人数组 */],
  "messages": [/* 短信数组，最多100条 */],
  "notifications": [],
  "jobBoard": [/* 任务板数组，最多20条 */],
  "factionMessages": [/* 派系消息数组 */]
}
```

### 1.5 Client ➔ NUI (SendNUIMessage — 实时推送)

#### phone:open

| 属性 | 值 |
|------|-----|
| **事件名称** | `phone:open` |
| **方向** | Client ➔ NUI (`SendNUIMessage`) |
| **触发时机** | 按下 M 键打开手机 |
| **Payload** | `{ "action": "phone:open" }` |
| **NUI 监听** | `registerNuiEvent('phone:open', handler)` (App.svelte) |

#### phone:close

| 属性 | 值 |
|------|-----|
| **事件名称** | `phone:close` |
| **方向** | Client ➔ NUI |
| **触发时机** | 关闭手机 |
| **Payload** | `{ "action": "phone:close" }` |

#### phone:updateTime

| 属性 | 值 |
|------|-----|
| **事件名称** | `phone:updateTime` |
| **方向** | Client ➔ NUI |
| **触发时机** | 手机打开时每 ~2 秒同步一次 |
| **Payload** | `{ "action": "phone:updateTime", "hour": "number", "minute": "number", "dayName": "string", "date": "string", "weatherIcon": "string", "weatherLabel": "string" }` |

#### phone:updateMoney

| 属性 | 值 |
|------|-----|
| **事件名称** | `phone:updateMoney` |
| **方向** | Client ➔ NUI |
| **触发时机** | `QBCore:Client:OnMoneyChange` 或 `QBCore:Client:SetPlayerData` 事件触发时 |
| **Payload** | `{ "action": "phone:updateMoney", "money": { "cash": "number", "bank": "number" } }` |

### 1.6 Server ➔ Database

#### 表: phone_numbers

```sql
CREATE TABLE IF NOT EXISTS phone_numbers (
    id INT AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(50) NOT NULL,
    number VARCHAR(20) NOT NULL UNIQUE,
    is_primary INT DEFAULT 0,
    INDEX (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

**查询场景**:
- 读取玩家所有号码: `SELECT number, is_primary FROM phone_numbers WHERE citizenid = ?`
- 首次创建初号: `INSERT IGNORE INTO phone_numbers (citizenid, number, is_primary) VALUES (?, ?, 1)`

---

## 2️⃣ 通讯录 — Contacts App

### 2.1 功能概述

添加、删除联系人，搜索联系人，AirDrop 名片分享（近距离向其他玩家发送联系人卡片）。

**源码**: `web/src/apps/Contacts.svelte` (UI), `server/main.lua` (CRUD 逻辑)

### 2.2 NUI ➔ Client (RegisterNUICallback)

#### addContact

| 属性 | 值 |
|------|-----|
| **接口名称** | `addContact` |
| **方向** | NUI ➔ Client (via `QBCore.Functions.TriggerCallback`) |
| **功能** | 添加新联系人 |

**发送数据**:
```json
{
  "name": "string",     // 1-30 字符
  "number": "string"    // 1-15 位数字
}
```

**接收数据**:
```json
{
  "success": true,
  "contact": {
    "id": "number",
    "citizenid": "string",
    "name": "string",
    "number": "string"
  }
}
```

#### deleteContact

| 属性 | 值 |
|------|-----|
| **接口名称** | `deleteContact` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 删除指定联系人 |

**发送数据**: `{ "id": "number" }`

**接收数据**: `{ "success": true }`

#### getNearbyPlayers

| 属性 | 值 |
|------|-----|
| **接口名称** | `getNearbyPlayers` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 扫描 8 米范围内玩家（用于 AirDrop 名片分享和扫码转账） |

**发送数据**: `{}`

**接收数据**:
```json
[
  {
    "id": "number",          // source 玩家 ID
    "name": "string",        // 玩家全名
    "phone": "string"        // 电话号码
  }
]
```

#### shareContactNearby

| 属性 | 值 |
|------|-----|
| **接口名称** | `shareContactNearby` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 将自己的联系人卡片 AirDrop 给附近的玩家 |

**发送数据**:
```json
{
  "targetId": "number",    // 目标玩家 ID
  "name": "string",        // 名片上的姓名
  "number": "string"       // 名片上的电话
}
```

**接收数据**:
```json
{
  "success": true,
  "message": "Contact shared successfully!"
}
```

### 2.3 Client ➔ Server (Callback)

#### phone:server:addContact

| 属性 | 值 |
|------|-----|
| **接口名称** | `phone:server:addContact` (CreateCallback) |
| **服务端逻辑** | `MySQL.Async.insert('INSERT INTO phone_contacts ... ON DUPLICATE KEY UPDATE ...')` |
| **安全校验** | name 1-30 chars, number 1-15 chars |

#### phone:server:deleteContact

| 属性 | 值 |
|------|-----|
| **接口名称** | `phone:server:deleteContact` (CreateCallback) |
| **服务端逻辑** | `MySQL.Async.execute('DELETE FROM phone_contacts WHERE id = ? AND citizenid = ?')` |

#### phone:server:getNearbyPlayers

| 属性 | 值 |
|------|-----|
| **接口名称** | `phone:server:getNearbyPlayers` (CreateCallback) |
| **服务端逻辑** | 遍历在线玩家，计算 `#(GetEntityCoords(ped) - GetEntityCoords(targetPed)) <= 8.0` |

#### phone:server:shareContactNearby

| 属性 | 值 |
|------|-----|
| **接口名称** | `phone:server:shareContactNearby` (CreateCallback) |
| **服务端逻辑** | 距离重验证后，在目标玩家的数据库中插入联系人；推送通知给接收方 |

### 2.4 Server ➔ Client (TriggerClientEvent — 推送)

#### phone:client:newNotification (AirDrop)

| 属性 | 值 |
|------|-----|
| **事件名称** | `phone:client:newNotification` |
| **方向** | Server ➔ Client |
| **触发时机** | AirDrop 接收方收到名片后 |

**Payload**:
```json
{
  "id": "number",
  "title": "📥 Contact Received",
  "content": "string",
  "timestamp": "string",
  "is_read": false
}
```

### 2.5 Server ➔ Database

#### 表: phone_contacts

```sql
CREATE TABLE IF NOT EXISTS phone_contacts (
    id INT AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(50) NOT NULL,
    name VARCHAR(100) NOT NULL,
    number VARCHAR(20) NOT NULL,
    UNIQUE KEY uq_contact (citizenid, number),
    INDEX idx_citizenid (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## 3️⃣ 短信 — Messages App

### 3.1 功能概述

玩家间的文字短信发送、阅读状态管理（已读/未读）、会话线程分组管理。

**源码**: `web/src/apps/Messages.svelte` (UI), `server/main.lua` (SMS 逻辑)

### 3.2 NUI ➔ Client (RegisterNUICallback)

#### sendMessage

| 属性 | 值 |
|------|-----|
| **接口名称** | `sendMessage` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 发送一条短信给指定号码 |

**发送数据**:
```json
{
  "receiver_number": "string",  // 接收方号码 (1-15 位)
  "message": "string"           // 短信内容 (1-500 字符)
}
```

**接收数据**:
```json
{
  "success": true,
  "message": {
    "id": "number",
    "sender_number": "string",
    "receiver_number": "string",
    "message": "string",
    "timestamp": "string",       // YYYY-MM-DD HH:MM:SS
    "is_read": false
  }
}
```

#### markMessagesRead

| 属性 | 值 |
|------|-----|
| **接口名称** | `markMessagesRead` |
| **方向** | NUI ➔ Client (直发 `TriggerServerEvent`) |
| **功能** | 标记与某联系人的所有消息为已读 |

**发送数据**: `{ "sender_number": "string" }`

**接收数据**: `{ "success": true }`

### 3.3 Client ➔ Server

#### phone:server:sendMessage (CreateCallback)

**服务端逻辑**:
```lua
MySQL.Async.insert('INSERT INTO phone_messages (sender_number, receiver_number, message) VALUES (?, ?, ?)', ...)
-- 如果接收方在线，推送实时消息
TriggerClientEvent('phone:client:newMessage', targetSource, msgData)
TriggerClientEvent('phone:client:newNotification', targetSource, notifData)
```

#### phone:server:markMessagesRead (RegisterNetEvent — 单向通知)

**服务端逻辑**:
```lua
MySQL.Async.execute('UPDATE phone_messages SET is_read = 1 WHERE sender_number = ? AND receiver_number = ?', ...)
```

### 3.4 Server ➔ Database

#### 表: phone_messages

```sql
CREATE TABLE IF NOT EXISTS phone_messages (
    id INT AUTO_INCREMENT PRIMARY KEY,
    sender_number VARCHAR(20) NOT NULL,
    receiver_number VARCHAR(20) NOT NULL,
    message TEXT NOT NULL,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    is_read BOOLEAN DEFAULT FALSE,
    INDEX idx_receiver (receiver_number),
    INDEX idx_sender (sender_number),
    INDEX idx_time (timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

**查询**:
- 加载消息: `SELECT * FROM phone_messages WHERE sender_number = ? OR receiver_number = ? ORDER BY timestamp DESC LIMIT 100`
- 标记已读: `UPDATE phone_messages SET is_read = 1 WHERE sender_number = ? AND receiver_number = ?`

### 3.5 Server ➔ Client (实时推送)

#### phone:client:newMessage

| 属性 | 值 |
|------|-----|
| **事件名称** | `phone:client:newMessage` |
| **方向** | Server ➔ Client |
| **触发时机** | 接收方在线时，新消息到达 |

**Payload (SendNUIMessage)**:
```json
{
  "action": "phone:newMessage",
  "message": {
    "id": "number",
    "sender_number": "string",
    "receiver_number": "string",
    "message": "string",
    "timestamp": "string",
    "is_read": false
  }
}
```

---

## 4️⃣ 银行转账 — Banking App

### 4.1 功能概述

手机银行仅支持 **WIRE TRANSFER（转账汇款）**，存款/取款必须前往实体 ATM/柜台。支持在线收款方（内存即时转账）和离线收款方（数据库原子写入）。

**源码**: `web/src/apps/Banking.svelte` (UI), `server/banking.lua` (转账逻辑)

### 4.2 NUI ➔ Client (RegisterNUICallback)

#### bankTransfer

| 属性 | 值 |
|------|-----|
| **接口名称** | `bankTransfer` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 执行银行转账 |

**发送数据**:
```json
{
  "toPhoneNumber": "string",   // 收款方电话号码
  "amount": "number",          // 转账金额 (1~100,000)
  "reason": "string"           // 转账备注
}
```

**接收数据 — 成功**:
```json
{
  "success": true,
  "newBalances": { "cash": "number", "bank": "number" },
  "message": "Successfully transferred $X to Y!"
}
```

**接收数据 — 失败**:
```json
{
  "success": false,
  "message": "Insufficient checking balance"
}
```

#### bankDeposit (已禁用)

| 属性 | 值 |
|------|-----|
| **接口名称** | `bankDeposit` |
| **功能** | 手机存款（已禁用） |
| **接收数据** | `{ "success": false, "message": "Mobile deposits are disabled. Please use a physical ATM or bank teller." }` |

#### bankWithdraw (已禁用)

| 属性 | 值 |
|------|-----|
| **接口名称** | `bankWithdraw` |
| **功能** | 手机取款（已禁用） |
| **接收数据** | `{ "success": false, "message": "Mobile withdrawals are disabled. Please use a physical ATM or bank teller." }` |

### 4.3 Client ➔ Server

#### phone:server:bankTransfer (CreateCallback)

**服务端逻辑** (`server/banking.lua`):

**在线转账流程**:
1. 验证金额 (1 ≤ amount ≤ 100,000)
2. 验证余额充足 (`Player.PlayerData.money.bank >= amount`)
3. 自转账拦截
4. 通过 `QBCore.Functions.GetPlayers()` 查找目标号码
5. `Player.Functions.RemoveMoney('bank', amount)`
6. `targetPlayer.Functions.AddMoney('bank', amount)`
7. 推送 `phone:client:newNotification` 给收款方
8. 记录 `exports['custom-main']:LogEconomy("手机银行转账", ...)`

**离线转账流程**:
1. 同上验证
2. `SELECT citizenid, money, charinfo FROM players WHERE JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.phone')) = ?`
3. `Player.Functions.RemoveMoney('bank', amount)`
4. `UPDATE players SET money = JSON_SET(money, '$.bank', CAST(JSON_EXTRACT(money, '$.bank') AS DECIMAL(10,2)) + ?) WHERE citizenid = ?`
5. 失败时回滚: `Player.Functions.AddMoney('bank', amount, "Transfer Rollback")`

### 4.4 Server ➔ Client (实时推送)

#### phone:client:newNotification (Banking)

| 属性 | 值 |
|------|-----|
| **事件名称** | `phone:client:newNotification` |
| **方向** | Server ➔ Client |
| **触发时机** | 收款方在线时收到汇款通知 |

**Payload (NUI 格式)**:
```json
{
  "action": "phone:newNotification",
  "notification": {
    "id": "number",
    "title": "🏦 Wire Inbound",
    "content": "Received $X from Firstname Lastname. Memo: ...",
    "timestamp": "string",
    "is_read": false
  }
}
```

---

## 5️⃣ 城市动态 — CityFeed App

### 5.1 功能概述

类似微博/推特的全局城市动态墙，玩家可发帖（200 字以内）、点赞、浏览最新动态（最近 30 条）。

**源码**: `web/src/apps/CityFeed.svelte` (UI), `server/main.lua` (CityFeed 逻辑)

### 5.2 NUI ➔ Client (RegisterNUICallback)

#### getCityFeed

| 属性 | 值 |
|------|-----|
| **接口名称** | `getCityFeed` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 加载城市动态列表（最近 30 条） |

**发送数据**: `{}`

**接收数据**:
```json
{
  "success": true,
  "feed": [
    {
      "id": "number",
      "name": "string",
      "citizenid": "string",
      "content": "string",
      "likes": "number",
      "timestamp": "string"
    }
  ]
}
```

#### postCityFeed

| 属性 | 值 |
|------|-----|
| **接口名称** | `postCityFeed` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 发布一条城市动态 |

**发送数据**: `{ "content": "string" }`  // 1-200 字符

**接收数据**:
```json
{
  "success": true,
  "post": {
    "id": "number",
    "name": "string",
    "citizenid": "string",
    "content": "string",
    "likes": 0,
    "timestamp": "string"
  }
}
```

#### likeCityFeed

| 属性 | 值 |
|------|-----|
| **接口名称** | `likeCityFeed` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 给某条动态点赞 |

**发送数据**: `{ "id": "number" }`

**接收数据**: `{ "success": true, "likes": "number" }`

### 5.3 Server ➔ Database

#### 表: phone_cityfeed

```sql
CREATE TABLE IF NOT EXISTS phone_cityfeed (
    id INT AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(50) NOT NULL,
    content TEXT NOT NULL,
    likes INT DEFAULT 0,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_time (timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

**查询**:
- 获取 feed: `SELECT f.*, p.charinfo FROM phone_cityfeed f LEFT JOIN players p ON f.citizenid = p.citizenid ORDER BY f.timestamp DESC LIMIT 30`
- 发布: `INSERT INTO phone_cityfeed (citizenid, content) VALUES (?, ?)`
- 点赞: `UPDATE phone_cityfeed SET likes = likes + 1 WHERE id = ?`

---

## 6️⃣ 任务板 — Job Board App

### 6.1 功能概述

市长发布城市建设工程，平民玩家抢单接任务，抵达指定坐标后自动完成并发放奖金。支持职业标签匹配（Career Tags）和反距离欺骗保护。

**源码**: `web/src/apps/JobBoard.svelte` (UI), `server/jobboard.lua` (任务板逻辑)

### 6.2 NUI ➔ Client (RegisterNUICallback)

#### acceptJobBoardTask

| 属性 | 值 |
|------|-----|
| **接口名称** | `acceptJobBoardTask` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 接取一个开放的任务 |

**发送数据**: `{ "id": "number" }`

**接收数据 — 成功**:
```json
{
  "success": true,
  "message": "Project accepted! GPS Waypoint routed."
}
```

#### postJobBoardTask

| 属性 | 值 |
|------|-----|
| **接口名称** | `postJobBoardTask` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 市长发布新的城市工程 |

**发送数据**:
```json
{
  "title": "string",        // 1-50 字符
  "description": "string",  // 1-500 字符
  "reward": "number"        // 1~50,000
}
```

**接收数据**:
```json
{
  "success": true,
  "job": {
    "id": "number",
    "task_id": "number",
    "title": "string",
    "description": "string",
    "target_tags": { "role": "civilian", "tier": "entry" },
    "reward": "number",
    "status": "open",
    "taken_by": null,
    "posted_at": "string"
  },
  "message": "City Project published successfully!"
}
```

### 6.3 Client ➔ Server

#### phone:server:acceptJob (CreateCallback)

**服务端逻辑** (`server/jobboard.lua`):
1. `SELECT * FROM phone_jobboard WHERE id = ?` 检查状态为 'open'
2. 职业标签匹配验证: `exports['custom-career']:PlayerMatchesTags(source, targetTags)`
3. `UPDATE phone_jobboard SET status = "taken", taken_by = ? WHERE id = ?`
4. 广播 `TriggerClientEvent('phone:client:newJob', -1, jobUpdate)`
5. 推送 GPS 路由: `TriggerClientEvent('phone:client:routeGps', source, coords, title)`
6. 启动距离追踪: `TriggerClientEvent('phone:client:trackJobArrival', source, id, coords)`

#### phone:server:completeJob (RegisterNetEvent)

| 属性 | 值 |
|------|-----|
| **事件名称** | `phone:server:completeJob` |
| **方向** | Client ➔ Server |
| **触发时机** | 客户端距离追踪线程检测到玩家抵达目标 8 米内 |

**服务端验证**:
1. 检查 `job.status == 'taken' && job.taken_by == citizenid`
2. 距离反欺骗验证: `#(playerCoords - targetCoords) > 25.0` → 触发安全日志拦截
3. 通过后: `UPDATE phone_jobboard SET status = "completed"`
4. 发放奖励: `exports['custom-main']:AddScaledMoney(src, 'bank', reward, ...)`
5. 推送完成通知

#### phone:server:postJob (CreateCallback)

| 属性 | 值 |
|------|-----|
| **接口名称** | `phone:server:postJob` |
| **权限验证** | `identity.rank_tier == 'leader' && identity.primary_role == 'mayor'` |
| **服务端逻辑** | `MySQL.Async.insert` + 全服广播 `TriggerClientEvent('phone:client:newJob', -1, ...)` + 全服推送通知 |

### 6.4 Server ➔ Client (实时推送 — Job Board)

#### phone:client:newJob

| 属性 | 值 |
|------|-----|
| **事件名称** | `phone:client:newJob` |
| **方向** | Server ➔ Client (可向 -1 广播) |

**Payload (SendNUIMessage)**:
```json
{
  "action": "phone:jobboard:newJob",
  "job": {
    "id": "number",
    "task_id": "number",
    "title": "string",
    "description": "string",
    "target_tags": {},
    "reward": "number",
    "status": "string",
    "taken_by": "string|null"
  }
}
```

#### phone:client:routeGps

| 属性 | 值 |
|------|-----|
| **事件名称** | `phone:client:routeGps` |
| **方向** | Server ➔ Client |
| **功能** | 设置 GPS 导航路径点 |

**Payload (原生 Lua 参数)**: `coords` (vector3), `label` (string)

**Lua 处理**: `SetNewWaypoint(coords.x, coords.y)` + `QBCore.Functions.Notify("GPS Waypoint routing active: " .. label, "success")`

#### phone:client:trackJobArrival

| 属性 | 值 |
|------|-----|
| **事件名称** | `phone:client:trackJobArrival` |
| **方向** | Server ➔ Client |
| **功能** | 启动客户端距离追踪线程，抵达 8m 内自动触发 `phone:server:completeJob` |

### 6.5 Server ➔ Database

#### 表: phone_jobboard

```sql
CREATE TABLE IF NOT EXISTS phone_jobboard (
    id INT AUTO_INCREMENT PRIMARY KEY,
    task_id INT DEFAULT NULL,
    title VARCHAR(100) DEFAULT NULL,
    description TEXT DEFAULT NULL,
    target_tags JSON DEFAULT NULL,
    reward INT DEFAULT 0,
    status VARCHAR(20) DEFAULT 'open',
    taken_by VARCHAR(50) DEFAULT NULL,
    posted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    deadline DATETIME DEFAULT NULL,
    INDEX idx_status (status),
    INDEX idx_posted (posted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## 7️⃣ 派系频道 — Faction Channel App

### 7.1 功能概述

基于职业角色的加密群组聊天（LSPD 无线电、帮派加密频道、EMT 急救频率等），消息保存在内存中（GlobalState），最多保留 50 条历史。

**源码**: `web/src/apps/FactionChannel.svelte` (UI), `server/faction.lua` (派系逻辑)

### 7.2 NUI ➔ Client (RegisterNUICallback)

#### sendFactionMessage

| 属性 | 值 |
|------|-----|
| **接口名称** | `sendFactionMessage` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 向所属派系发送一条广播消息 |

**发送数据**: `{ "content": "string" }`  // 1-200 字符

**接收数据**:
```json
{
  "success": true,
  "message": {
    "sender": "string",
    "content": "string",
    "time": "number"       // Unix 时间戳
  }
}
```

### 7.3 Client ➔ Server

#### phone:server:sendFactionMessage (CreateCallback)

**服务端逻辑** (`server/faction.lua`):
1. 获取玩家职业身份: `exports['custom-career']:GetPlayerIdentity(source)`
2. 获取角色: `identity.primary_role` → `police / medic / gang / civilian`
3. 追加消息到 `GlobalState.FactionMessages[role]`
4. 保留最近 50 条: `if #FactionMessages[role] > 50 then table.remove(FactionMessages[role], 1)`
5. 广播给所有同角色在线玩家: `TriggerClientEvent('phone:client:factionReceive', playerId, msgData)`

### 7.4 Server ➔ Client (实时推送)

#### phone:client:factionReceive

| 属性 | 值 |
|------|-----|
| **事件名称** | `phone:client:factionReceive` |
| **方向** | Server ➔ Client |

**Payload (SendNUIMessage)**:
```json
{
  "action": "phone:faction:receive",
  "message": {
    "sender": "string",
    "content": "string",
    "time": "number"
  }
}
```

---

## 8️⃣ 紧急热线 & IVR — Hotlines App

### 8.1 功能概述

紧急热线目录，玩家可呼叫各机构（警察/救护/修车/市政/银行），支持在线坐席检测和 IVR 自动话务系统回退。

**源码**: `web/src/apps/Hotlines.svelte` (UI), `server/main.lua` (热线逻辑)

### 8.2 NUI ➔ Client (RegisterNUICallback)

#### getHotlineStatus

| 属性 | 值 |
|------|-----|
| **接口名称** | `getHotlineStatus` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 查询某个职业当前在线坐席数量 |

**发送数据**: `{ "jobType": "string" }`  // police / ambulance / mechanic / mayor / bank

**接收数据**: `"number"`  // 在线坐席数 (0 = 无人上班 → 转IVR)

#### triggerHotlineCall

| 属性 | 值 |
|------|-----|
| **接口名称** | `triggerHotlineCall` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 触发对某职业的热线呼叫 |

**发送数据**: `{ "jobType": "string" }`

**接收数据 — 有坐席在线**:
```json
{
  "success": true,
  "active": true,
  "message": "Connecting to available agents..."
}
```

**接收数据 — 无坐席**:
```json
{
  "success": true,
  "active": false,
  "message": "All lines busy. Re-routing to automated system."
}
```

**特殊值**: `jobType == 'surrender'` 走自首通道（直发 `qb-storerobbery:server:surrender`）

#### queryAutomatedIvr

| 属性 | 值 |
|------|-----|
| **接口名称** | `queryAutomatedIvr` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | IVR 自动应答数据查询 |

**发送数据**: `{ "actionType": "string" }`  // "economy" / "licenses" / "aitow"

**接收数据**:
```json
{
  "title": "string",
  "info": "string"
}
```

### 8.3 Client ➔ Server (Callback)

#### phone:server:getHotlineStatus (CreateCallback)

**服务端逻辑**: 遍历在线玩家，计数 `Player.PlayerData.job.name == jobType && Player.PlayerData.job.onduty == true`

#### phone:server:triggerHotlineCall (CreateCallback)

**服务端逻辑**: 遍历在线玩家，向所有匹配职业 + onduty 的玩家推送 `phone:client:newNotification` 热线警告

#### phone:server:queryAutomatedIvr (CreateCallback)

**服务端逻辑**: `GetConvar('economy_wage_multiplier', '1.0')` 或读取 `Player.PlayerData.metadata['licences']`

---

## 9️⃣ 车库查询 — Garage App

### 9.1 功能概述

查询玩家名下所有车辆的状态、位置、油量、引擎/车身健康度。

**源码**: `web/src/apps/Garage.svelte` (UI), `server/main.lua` (车库查询)

### 9.2 NUI ➔ Client (RegisterNUICallback)

#### getOwnedVehicles

| 属性 | 值 |
|------|-----|
| **接口名称** | `getOwnedVehicles` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 获取名下所有车辆 |

**发送数据**: `{}`

**接收数据**:
```json
[
  {
    "model": "string",
    "plate": "string",
    "garage": "string",
    "status": "string",     // "Stored" / "Out of Garage" / "Impounded"
    "fuel": "number",       // 0-100
    "engine": "number",     // 0-100
    "body": "number"        // 0-100
  }
]
```

### 9.3 Server ➔ Database

**查询**:
```lua
MySQL.Async.fetchAll('SELECT vehicle, plate, garage, state, fuel, engine, body FROM player_vehicles WHERE citizenid = ?', { citizenid }, ...)
```

---

## 1️⃣0️⃣ 拨号面板 — PhoneCall App

### 10.1 功能概述

标准的九宫格拨号面板，当前阶段为纯 UI（模拟拨号），无后端连接。未来可对接 `pma-voice` 实现真实通话。

**源码**: `web/src/apps/PhoneCall.svelte`

### 10.2 接口状态

| 接口 | 方向 | 状态 | 说明 |
|------|------|------|------|
| 拨号 | UI 本地 | ✅ 纯前端模拟 | 无后端交互 |
| 接通/挂断 | UI 本地 | ✅ 前端状态机 | 显示拨号中 / 已接通 / X:XX 计时 |
| 真实通话 | — | ⏳ **预留** | 需对接 `pma-voice` 的 `setCallChannel()` 等 |

---

## 1️⃣1️⃣ 通知中心 — Notifications App

### 11.1 功能概述

系统级通知聚合窗，接收来自银行、短信、任务板、派系频道、热线等各模块的推送通知。所有通知为纯内存瞬态数据。

**源码**: `web/src/apps/Notifications.svelte` (UI)

### 11.2 NUI ➔ Client (RegisterNUICallback)

#### markNotificationsRead

| 属性 | 值 |
|------|-----|
| **接口名称** | `markNotificationsRead` |
| **方向** | NUI ➔ Client |
| **功能** | 标记所有通知为已读（内存操作） |
| **接收数据** | `{ "success": true }` |

#### clearNotifications

| 属性 | 值 |
|------|-----|
| **接口名称** | `clearNotifications` |
| **方向** | NUI ➔ Client |
| **功能** | 清空所有通知 |
| **接收数据** | `{ "success": true }` |

#### deleteNotification

| 属性 | 值 |
|------|-----|
| **接口名称** | `deleteNotification` |
| **方向** | NUI ➔ Client |
| **功能** | 删除单条通知 |
| **接收数据** | `{ "success": true }` |

### 11.3 Server ➔ Client (实时推送 — 通用通知管道)

#### phone:client:newNotification

| 属性 | 值 |
|------|-----|
| **事件名称** | `phone:client:newNotification` |
| **方向** | Server ➔ Client (由多个模块触发) |

**Payload (SendNUIMessage)**:
```json
{
  "action": "phone:newNotification",
  "notification": {
    "id": "number",
    "title": "string",
    "content": "string",
    "timestamp": "string",
    "is_read": false
  }
}
```

---

## 1️⃣2️⃣ 领袖应用 — Leader Apps

### 12.1 市长面板 — MayorApp

**源码**: `web/src/apps/leader/MayorApp.svelte`

| 接口名称 | 方向 | 对应回调 |
|----------|------|----------|
| `postJobBoardTask` | NUI ➔ Client ➔ Server | `phone:server:postJob` |

**权限校验**: `identity.primary_role == 'mayor' && identity.rank_tier == 'leader'`

### 12.2 警长指挥面板 — SheriffApp

**源码**: `web/src/apps/leader/SheriffApp.svelte`

#### sendSheriffPatrolOrder

| 属性 | 值 |
|------|-----|
| **接口名称** | `sendSheriffPatrolOrder` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 警长向所有 LSPD 警员发布战术巡逻指令 |

**发送数据**:
```json
{
  "zone": "string",
  "details": "string"     // 1-500 字符
}
```

**接收数据**:
```json
{
  "success": true,
  "message": {
    "sender": "string",
    "content": "🚨 [PATROL ORDER] ...",
    "time": "number"
  }
}
```

**服务端**: `phone:server:sendSheriffPatrol` (CreateCallback) — 广播给所有 `primary_role == 'police'` 的在线玩家，推送 GPS 航点 + 通知

### 12.3 黑帮老大面板 — GangBossApp

**源码**: `web/src/apps/leader/GangBossApp.svelte`

#### sendGangObjective

| 属性 | 值 |
|------|-----|
| **接口名称** | `sendGangObjective` |
| **方向** | NUI ➔ Client (via callback) |
| **功能** | 黑帮老大向所有帮派成员发送加密指令 |

**发送数据**:
```json
{
  "objective": "string",    // 1-500 字符
  "quota": "number"         // 可选: 现金目标配额
}
```

**接收数据**:
```json
{
  "success": true,
  "message": {
    "sender": "string (Godfather)",
    "content": "👁️ [OBJECTIVE DISPATCH] ...",
    "time": "number"
  }
}
```

**服务端**: `phone:server:sendGangObjective` (CreateCallback) — 广播给所有 `primary_role == 'gang'` 在线玩家

---

## 1️⃣3️⃣ 动态领袖权限注册

### 13.1 功能概述

当玩家的职业晋升至 leader 级别时，手机主屏动态显示对应的领袖应用图标。

**源码**: `client/main.lua:CheckLeaderApp()`

### 13.2 Server ➔ Client (实时推送)

#### phone:registerLeaderApp / phone:removeLeaderApp

| 属性 | 值 |
|------|-----|
| **触发事件** | `QBCore:Client:OnPlayerLoaded` 或 `custom-career:client:tierChanged` |
| **方向** | Client 自判断后推送 NUI |

**Payload (晋升领袖)**:
```json
{ "action": "phone:registerLeaderApp", "role": "mayor|police|gang" }
```

**Payload (降级)**:
```json
{ "action": "phone:removeLeaderApp" }
```

---

## 1️⃣4️⃣ 跨模块汇总参考

### 14.1 全部 NUI ➔ Client 回调总表 (RegisterNUICallback)

| # | 回调名称 | 模块 | 后端类型 | 安全校验 |
|---|----------|------|----------|----------|
| 1 | `closePhone` | Core | 直通 | — |
| 2 | `getPhoneData` | Core | `TriggerCallback` | — |
| 3 | `addContact` | Contacts | `TriggerCallback` | name ≤ 30, number ≤ 15 |
| 4 | `deleteContact` | Contacts | `TriggerCallback` | 校验 owner |
| 5 | `sendMessage` | Messages | `TriggerCallback` | number ≤ 15, message ≤ 500 |
| 6 | `markMessagesRead` | Messages | `TriggerServerEvent` | — |
| 7 | `markNotificationsRead` | Notifications | 内存 | — |
| 8 | `clearNotifications` | Notifications | 内存 | — |
| 9 | `deleteNotification` | Notifications | 内存 | — |
| 10 | `bankTransfer` | Banking | `TriggerCallback` | 1 ≤ amount ≤ 100,000; 禁自转账 |
| 11 | `bankDeposit` | Banking | **已禁用** | — |
| 12 | `bankWithdraw` | Banking | **已禁用** | — |
| 13 | `getNearbyPlayers` | Contacts/Banking | `TriggerCallback` | 8m 距离限制 |
| 14 | `shareContactNearby` | Contacts | `TriggerCallback` | 距离重验证 ≤ 8m |
| 15 | `getOwnedVehicles` | Garage | `TriggerCallback` | — |
| 16 | `getHotlineStatus` | Hotlines | `TriggerCallback` | — |
| 17 | `triggerHotlineCall` | Hotlines | `TriggerCallback` / 自首分支 | — |
| 18 | `queryAutomatedIvr` | Hotlines | `TriggerCallback` | — |
| 19 | `acceptJobBoardTask` | Job Board | `TriggerCallback` | 职业标签匹配 |
| 20 | `postJobBoardTask` | Job Board | `TriggerCallback` | 仅 Mayor Leader |
| 21 | `sendFactionMessage` | Faction | `TriggerCallback` | content ≤ 200 |
| 22 | `sendSheriffPatrolOrder` | SheriffApp | `TriggerCallback` | 仅 Police Leader |
| 23 | `sendGangObjective` | GangBossApp | `TriggerCallback` | 仅 Gang Leader |
| 24 | `getCityFeed` | CityFeed | `TriggerCallback` | — |
| 25 | `postCityFeed` | CityFeed | `TriggerCallback` | content ≤ 200 |
| 26 | `likeCityFeed` | CityFeed | `TriggerCallback` | — |

### 14.2 全部 Server ➔ Client 推送事件总表 (SendNUIMessage 包装)

| # | 原生 Lua 事件 | NUI Action | 推送源 |
|---|--------------|------------|--------|
| 1 | 客户端自启 | `phone:open` | `OpenPhone()` |
| 2 | 客户端自启 | `phone:close` | `ClosePhone()` |
| 3 | 客户端自启 | `phone:updateTime` | 时间同步线程 |
| 4 | `phone:client:newMessage` | `phone:newMessage` | `server/main.lua` (发短信时) |
| 5 | `phone:client:newNotification` | `phone:newNotification` | bank.lua, jobboard.lua, faction.lua 等 |
| 6 | `phone:client:newJob` | `phone:jobboard:newJob` | `server/jobboard.lua` |
| 7 | `phone:client:factionReceive` | `phone:faction:receive` | `server/faction.lua` |
| 8 | 客户端自启 | `phone:registerLeaderApp` | `CheckLeaderApp()` |
| 9 | 客户端自启 | `phone:removeLeaderApp` | `CheckLeaderApp()` |
| 10 | 客户端自启 | `phone:updateMoney` | `OnMoneyChange` / `SetPlayerData` |
| 11 | `phone:client:routeGps` | (Lua 原生) | `server/jobboard.lua`, `server/faction.lua` |

### 14.3 数据库表总览

| 表名 | 所属模块 | 创建方式 | 说明 |
|------|----------|----------|------|
| `phone_numbers` | Core | `MySQL.ready` 自动建表 | 玩家号码注册表 |
| `phone_messages` | Messages | 自动建表 | 短信存储 |
| `phone_contacts` | Contacts | 自动建表 | 通讯录 |
| `phone_cityfeed` | CityFeed | 自动建表 | 城市动态 |
| `phone_jobboard` | Job Board | 自动建表 | 任务发布板 |
| `phone_calls` | (预留) | 自动建表 | 通话记录（v0.4.2 预留） |
| `player_vehicles` | Garage | `qb-core` 系统表 | 玩家车辆数据 |
| `players` | Banking | `qb-core` 系统表 | 玩家主数据（含 `money` JSON） |

---

## 🔐 安全边界说明

| 安全机制 | 所在文件:行号 | 说明 |
|----------|--------------|------|
| 输入长度校验 | `server/main.lua` (多处) | name ≤ 30, number ≤ 15, message ≤ 500, content ≤ 200 |
| 单次转账上限 | `server/banking.lua:13` | `amount > 100000` → 拒绝 |
| 自转账拦截 | `server/banking.lua:18` | `toPhoneNumber == self.phone` → 拒绝 |
| 距离反欺骗 | `server/jobboard.lua:200-217` | 交单时距离 > 25m 触发安全日志红色告警 |
| 职业标签验证 | `server/jobboard.lua:73-81` | `PlayerMatchesTags` 阻止不符合要求的玩家抢单 |
| 权限校验 (市长) | `server/jobboard.lua:127` | 仅 `rank_tier == 'leader' && role == 'mayor'` |
| 权限校验 (警长) | `server/faction.lua:82` | 仅 `rank_tier == 'leader' && role == 'police'` |
| 权限校验 (黑帮) | `server/faction.lua:136` | 仅 `rank_tier == 'leader' && role == 'gang'` |
| AirDrop 距离重验证 | `server/main.lua:288-294` | 分享名片时重新验证距离 ≤ 8m |
| 离线转账原子性 | `server/banking.lua:109-119` | `JSON_SET` + `CAST(JSON_EXTRACT) + amount` 确保并发安全 |
| 失败回滚机制 | `server/banking.lua:118` | 离线转账 DB 更新失败时回退 sender 扣款 |

---

> 📝 **手册版本**: v1.0 | **系统版本**: custom-phone v1.0 (Svelte 4 + TypeScript)
> 📁 **源码根目录**: `resources/[custom]/custom-phone/`
> 🎯 **总接口数**: 26 个 NUI 回调 + 11 个 Server➔Client 推送事件 + 13 个 Server 端 CreateCallback/RegisterNetEvent
