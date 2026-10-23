# T-City通用任务系统：原子节点设计与配置规范手册 (v2.0.0 — 解耦重构版)

本手册是为 `custom-quest` 任务系统定制的高指导性规范。在架构设计上，本版本**不再受限于传统 QB 框架的 legacy 写法**，而是基于 **“模块化、高性能、安全、可拓展”** 四大铁律进行框架重构，建立抽象隔离层（Adapter Pattern），实现完全去耦合的微服务化设计。

---

## 🏛️ 架构四大核心原则在任务系统的落实

### 1. 模块化 (Modularity) — 适配器解耦
任务系统内核（FSM、节点引擎）决不直接调用任何具体框架（如 `qb-core`、`qb-inventory` 或 `qb-target`）的 exports。取而代之的是采用**适配器模式（Adapter Pattern）**：
* **`FrameworkAdapter`**：封装获取玩家数据（Identifier/CitizenID/Source）的接口。
* **`InventoryAdapter`**：封装物品扣除与查询，未来可以无缝替换为 `ox_inventory` 或自主研发的背包。
* **`InteractionAdapter`**：封装本地 UI（DrawText）、Target 射线系统（`qb-target`、`ox_target`），由适配器根据服务器运行时环境动态绑定。

### 2. 高性能 (High Performance) — 事件驱动与零 Tick 轮询
* **客户端零线程挂起**：严禁在客户端脚本中挂载常驻高频 `Wait(0)` 的距离检测线程。
* **PolyZone 事件分发**：所有 `GOTO`、`DELIVER`、`WAIT` 节点均通过客户端 PolyZone 触发 `onPlayerInOut` 回调，激活或休眠本地事件监听器。
* **Target 实体挂载**：`INTERACT` 节点在实体生成时动态挂载到 Target 系统的碰撞网格上，只有玩家聚焦并点击时才唤醒 Lua 逻辑。

### 3. 安全 (Security) — 服务端绝对校验环
* 客户端仅负责提交**“操作意图”**与**“实体 Network ID”**。
* 服务端通过系统 API（如 `NetworkGetEntityFromNetworkId`）直接在后端提取并验证载具、NPC 的实体状态（位置、血量、归属、时间戳）。
* **时间审计**：`WAIT` 节点的时间流逝完全由服务端时间戳对比 `started_at` 决定，客户端无权参与计时上报。

### 4. 可拓展 (Extensibility) — 数据驱动与动态生命周期
* **零代码任务拼装**：通过 JSON/Lua Table 声明式配置，无需修改任何框架代码即可热插拔新任务。
* **动态生命周期控制**：任务引擎负责在步骤开始时自动生成所需 NPC/道具，并在完成/中断时自动垃圾回收。

---

## 1. 隔离层设计 (Adapters)

在代码实现中，建立 `server/adapters.lua` 和 `client/adapters.lua`。

### 服务端适配器示例 (server/adapters.lua)
```lua
Adapters = {
    -- 隔离框架层获取 CitizenID
    GetPlayerIdentifier = function(source)
        local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(source)
        return Player and Player.PlayerData.citizenid or nil
    end,

    -- 隔离背包系统检测与扣除
    HasItem = function(source, itemName, amount)
        if GetResourceState('qb-inventory') ~= 'missing' then
            return exports['qb-inventory']:HasItem(source, itemName, amount)
        end
        -- fallback to raw Player functions or other inventory system
        local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(source)
        return Player and Player.Functions.HasItem(itemName, amount) or false
    end,

    RemoveItem = function(source, itemName, amount)
        if GetResourceState('qb-inventory') ~= 'missing' then
            return exports['qb-inventory']:RemoveItem(source, itemName, amount)
        end
        local Player = exports['qb-core']:GetCoreObject().Functions.GetPlayer(source)
        if Player then Player.Functions.RemoveItem(itemName, amount) end
    end
}
```

---

## 2. 原子节点底层运行机制与安全加固

### 2.1 GOTO 节点 (前往区域)
* **运行机制**：
  * **客户端**：根据配置的 shape（Circle, Box, Poly）初始化 PolyZone。通过 `onPlayerInOut(isInside)` 回调监听。当玩家进入且当前步骤匹配时，向服务器请求一次性 Nonce，校验通过后向服务器发送 `QUEST_REACH` 事件。
  * **服务端**：提取玩家 ped 坐标，比对配置中该 shape 的物理中心。若 3D 距离差 $\le \text{radius} + 10$ 米的延迟容差，且移动速度未超过最高Convar配置阈值，判定通过。

### 2.2 INTERACT 节点 (交互/读条)
* **运行机制**：
  * **OnActive**：
    * 服务端动态创建网络同步实体（Ped/Prop），例如在坐标上生成一个“手提箱”或“联络人”，并锁定其位置。
    * 将该实体的 `NetId` 写入玩家此步骤的任务缓存中，同时广播给客户端。
    * 客户端接收 `NetId`，并通过 `InteractionAdapter` 将其注册至本地 Target（或创建局部检测环）。
  * **OnComplete / OnClean**：
    * 无论任务成功与否，服务端自动在同步列表中将此 `NetId` 指向的实体删除，释放服务器资源。
  * **安全校验**：
    * 客户端触发 `nodeComplete` 时必须上传实体的 `NetId`。
    * 服务端验证：该 `NetId` 是否为任务生成并绑定给该玩家的实体？玩家当前坐标与实体的距离是否 $\le 5$ 米？

### 2.3 DELIVER 节点 (运送与回收)
* **运行机制**：
  * **载具安全回收流程**：
    * 若配置了 `consume_vehicle = true`，当玩家将车辆停在交付圈内并触发交付时，服务端首先执行车牌与任务绑定比对（防止误删别人或路边车）。
    * 比对通过后，服务端执行**非阻塞式物理回收**：
      1. 将车辆锁死（防止玩家开走或再次移动）。
      2. 使用 `SetTimeout` 在 5 秒后检测，若主驾驶玩家已下车，直接在服务端调用 `DeleteEntity` 物理销毁。
      3. 若车内有其他玩家，等待其下车后再行销毁，绝不阻塞主线程。

### 2.4 COMBAT 节点 (战斗/清剿)
* **运行机制**：
  * **绝对安全防线**：
    * 服务端动态在区域坐标随机偏移生成配置数量的敌对 Peds，并把它们的 `NetId` 记录到玩家的任务步骤内存数据库中。
    * 客户端注册事件驱动的 `gameEventTriggered` 监听 `'CEventNetworkEntityDamage'`。
    * 当发现有 Ped 死亡（`victimDied == true`）且该 Ped 对应的 `NetId` 属于玩家的任务怪物池时，客户端将死者 `NetId` 上报。
    * **服务端判定**：服务端将该 `NetId` 的 NPC 在服务端标记为“已击杀”，并检查该实体的实际健康度（Health $\le 0$）。若服务端验证其状态确为死亡，递增击杀计数。这阻断了客户端直接伪造死亡总数的可能。

### 2.5 WAIT 节点 (计时生存/防守)
* **运行机制**：
  * **OnActive**：服务端记录步骤激活时的系统时间戳 `start_time = os.time()`。
  * **OnUpdate**：客户端仅执行本地 UI 的沙漏读条，不可修改服务端的判断。
  * **安全校验**：客户端在本地倒计时结束后发送完成意图。服务端执行 `os.time() - start_time >= duration`。时间不满足直接断定为修改了本地客户端内存，判定作弊并拦截。

---

## 3. 标准配置规范 (Payload Specs)

### GOTO 节点 Payload
```lua
{
    id = "go_to_checkpoint",
    type = "GOTO",
    data = {
        coords = { x = 950.0, y = -120.0, z = 75.0 }, 
        shape = "box",                        -- 'circle' | 'box' | 'poly'
        size = { length = 10.0, width = 8.0, height = 4.0 }, -- 仅 box 有效
        heading = 120.0,                      -- 仅 box 有效
        radius = 15.0,                        -- 仅 circle 有效
        stayTime = 3,                         -- 停留触发判定秒数
        blip = { sprite = 1, color = 2, route = true },
        label = "驾车驶入安检通道"
    }
}
```

### INTERACT 节点 Payload
```lua
{
    id = "steal_plans",
    type = "INTERACT",
    data = {
        coords = { x = -137.2, y = -632.1, z = 34.5 },
        
        -- 动态生命周期实体生成配置
        spawn_entity = {
            type = "prop",                    -- 'ped' | 'prop'
            model = "prop_ld_suitcase_01",    -- 道具模型
            heading = 0.0,
            freeze = true,
        },
        
        in_vehicle = false,                   -- 是否要求在车内
        duration = 6000,                      -- 进度条时长 (ms)
        label = "正在搜寻机密文件箱...",
        animDict = "anim@amb@business@biker@class_warehouse@ui_look_around@",
        animName = "look_around_v1_operator",
        
        -- OX / QB Target 配置适配
        target = {
            use_target = true,                -- 是否启用 Target 点击交互 (Fallback 到按 E)
            icon = "fas fa-briefcase",
            label = "拿取机密文件箱"
        }
    }
}
```

### DELIVER 节点 Payload
```lua
{
    id = "deliver_shipment",
    type = "DELIVER",
    data = {
        destCoords = { x = 1200.0, y = 120.0, z = 32.0 },
        radius = 8.0,
        
        -- 背包扣除适配器配置
        items = {
            { name = "smuggled_goods", count = 3 }
        },
        consume = true,                       -- 结算扣物
        
        -- 载具清理与移交配置
        vehicle = {
            required = true,
            use_bound = true,                 -- 必须是绑定的任务载具
            consume_vehicle = true,           -- 运抵后服务端安全销毁
            require_trailer = true,           -- 是否需要物理挂挂车
        },
        label = "交付走私货物及挂车"
    }
}
```

### COMBAT 节点 Payload
```lua
{
    id = "eliminate_guards",
    type = "COMBAT",
    data = {
        coords = { x = 1400.0, y = 200.0, z = 40.0 },
        npcModel = "g_m_m_chigoon_01",
        count = 4,                            -- 必须消灭的 NPC 个数
        weapon = "WEAPON_PISTOL",             -- NPC 携带武器
        npcHealth = 150,
        npcArmor = 50,
        npcAccuracy = 20,
        label = "消灭突袭的走私者保镖"
    }
}
```

### WAIT 节点 Payload
```lua
{
    id = "hideout_cooldown",
    type = "WAIT",
    data = {
        coords = { x = 1450.0, y = 250.0, z = 42.0 },
        radius = 40.0,
        duration = 45,                        -- 服务端绝对计时时长 (秒)
        allowLeave = false,                   -- 离开则重置计时
        leavePenalty = "reset",               -- 离开惩罚行为: 'reset' | 'fail'
        label = "在藏身处保持隐蔽"
    }
}
```

---

> [!TIP]
> **设计思想核心回顾**
> 1. **不要为新任务写新代码**：有了这 5 个抽象层适配和强校验的节点，你可以配置任何复杂的运输、抢劫、防御、交互任务。
> 2. **极致安全与性能**：消灭了客户端计时舞弊与击杀舞弊；使用 PolyZone 与 Target 取代了高频 Tick 的位置轮询，完全遵循 T-City Lite 开发铁律。
