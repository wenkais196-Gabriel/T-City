# QBCore 帮派基地拓展与配置标准化指南 (Gang Base Expansion Guide)

本指南旨在为您提供一套标准化的“帮派基地拓展流程”。通过本指南，您可以在后期极速、无缝地为服务器添加任何全新的帮派领地（如 The Lost MC、Vagos、Ballas 等）。

---

## 📂 目录
1. [Cartel 基地实境配置清单 (Cartel HQ Config Checklist)](#-cartel-基地实境配置清单-cartel-hq-config-checklist)
2. [门与门锁配置 (Gates & Doorlocks)](#1-门与门锁配置-gates--doorlocks)
3. [防叠车防爆车库 (Gang Garage)](#2-防叠车防爆车库-gang-garage)
4. [NPC 友好守卫与同盟关系 (NPC Alliances)](#3-npc-友好守卫与同盟关系-npc-alliances)
5. [Boss 菜单与标识 (Boss Menus & Markers)](#4-boss-菜单与标识-boss-menus--markers)
6. [成员菜单、仓库、更衣室与武装店 (Non-Boss Member Features)](#5-成员菜单仓库更衣室与武装店-non-boss-member-features)

---

## 📌 Cartel 基地实境配置清单 (Cartel HQ Config Checklist)

以下是已完美部署并投入使用的 **La Fuente Blanca (Cartel 庄园)** 最终版本配置清单，作为您今后拓展新基地的官方对照范本：

| 模块名称 | 交互坐标 (Coords) | 目标实体/参数 (Model/Offsets) | 权限设置 (Authorized) | 标识样式 (Marker Style) | 标识颜色 (Marker Color) | 声音/附加配置 (Sounds/Extra) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **主入口滑动门**<br>`cartel_gate_main` | **交互中心**:<br>`vec3(1316.76, 1106.17, 106.00)` | **左门**: `1316.67, 1106.31, 104.97`<br>Heading: `108.04`<br>**右门**: `1316.86, 1106.04, 104.97`<br>Heading: `288.62` | `cartel` 帮派<br>级职限制: `0`<br>(仅帮众可锁/开门) | `doublesliding`<br>双联感应滑门 | 原生 UI 提示盒：<br>锁定: 红色 `RGB(219, 58, 58)`<br>解锁: 蓝色 `RGB(19, 28, 74)` | 锁门: `metal-locker.ogg`<br>开门: `metallic-creak.ogg`<br>雷达距离: `12.0m`<br>地面对齐: `104.97` |
| **后山摆动门**<br>`cartel_gate_back`<br>(重构虚拟摆门) | **交互中心**:<br>`vec3(1313.23, 1188.65, 108.00)` | **左门**: `1313.22, 1185.69, 107.10`<br>Heading: `90.00` $\rightarrow$ `180.0`<br>**右门**: `1313.25, 1191.61, 107.10`<br>Heading: `90.00` $\rightarrow$ `0.0` | `cartel` 帮派<br>级职限制: `0`<br>(仅帮众可锁/开门) | `custom`<br>逻辑虚拟大摆门<br>(客户端绝对物理冻结) | 同上 | 锁门: `metal-locker.ogg`<br>开门: `metallic-creak.ogg`<br>雷达距离: `12.0m`<br>地面对齐: `107.10` |
| **帮派车库**<br>`cartel_hq` | **取车菜单**:`vector4(1411.67, 1117.80, 114.84, 90.0)` | **出车点 A**: `1395.65, 1117.45, 114.43, 91.6`<br>**出车点 B**: `1414.30, 1117.51, 114.42, 91.21` | `cartel` 帮派<br>级职限制: `0` | QBCore 门标/菜单 | 默认车库样式 | 哨兵防叠车检测: 开启<br>检测半径: `3.0m` |
| **帮派 Boss 房**<br>`qb-management` | **Boss 菜单**: `vector3(1395.80, 1141.74, 115.24)` | 桌面交互点 | `cartel` 帮派<br>级职限制: `4`<br>(仅 President Boss) | 原生浮空 3D 文字 /<br>target 交互点 | 3D Text: 白色文字<br>底盒: 灰色半透明 | 功能：帮派资金库、<br>招聘帮众、开除与升降职 |
| **共享大仓库**<br>`cartel_stash` | **Stash 箱**: `vector3(1390.00, 1145.00, 114.50)` | 帮派大保险柜 | `cartel` 帮派<br>级职限制: `0` | Marker 类型 `2`<br>(旋转立体向下箭头)<br>尺寸: `0.3, 0.3, 0.2` | 科技蔚蓝色<br>`RGB(0, 150, 255, 150)` | 触发: E 键打开<br>容量: 4,000,000g<br>格子: 120 个 |
| **更衣室**<br>`cartel_cloakroom` | **衣柜交互**: `vector3(1392.00, 1143.00, 114.50)` | 帮派更衣间/衣柜 | `cartel` 帮派<br>级职限制: `0` | Marker 类型 `2`<br>(旋转立体向下箭头)<br>尺寸: `0.3, 0.3, 0.2` | 薄荷翠绿色<br>`RGB(0, 255, 150, 150)` | 触发: E 键打开服装保存/<br>穿衣菜单 |
| **特色军火武装店**<br>`cartel_armory` | **武装柜台**: `vector3(1388.00, 1140.00, 114.50)` | 特色枪弹柜 | `cartel` 帮派<br>级职限制: `0` | Marker 类型 `2`<br>(旋转立体向下箭头)<br>尺寸: `0.3, 0.3, 0.2` | 警示烈红色<br>`RGB(255, 50, 50, 150)` | 触发: E 键打开特色<br>帮派武装购买商店 |

---

## 1. 门与门锁配置 (Gates & Doorlocks)

当要在新帮派基地建立可控的安全大门时，必须让 **Spawner 创生端**与 **Doorlock 控制端**完美配合：

### A. 门体流式创生 (Spawner Setup)
1. **新建 Spawner 脚本**（例如 `resources/[standalone]/lost-gates/client.lua`）：
   * **清理默认地图门板**：使用 `CreateModelHide` 抹除默认地图的静态门以防穿模。
     ```lua
     CreateModelHide(x, y, z, radius, modelHash, true)
     ```
   * **创生时强制对齐高度**：在 `CreateObject` 后，必须**第一行立即调用 `SetEntityCoordsNoOffset` 焊死绝对 Z 坐标**，防止引擎物理延迟导致大门滑坠入土中：
     ```lua
     local obj = CreateObject(hash, coords.x, coords.y, coords.z, false, false, true)
     if DoesEntityExist(obj) then
         SetEntityCoordsNoOffset(obj, coords.x, coords.y, coords.z, false, false, false) -- 瞬间重置高度防止重力滑坠
         SetEntityHeading(obj, heading)
         FreezeEntityPosition(obj, true)
     end
     ```

2. **左右侧滑门对开几何学公式**：
   * 要想实现左右“对开侧滑”，两扇门的 Heading 必须**恰好相差 180 度（镜像对称）**。
   * **侧滑轴向计算**：大门是沿着其局部 X 轴（Right/Left）侧向滑开的。对于给定的 Heading $h$，侧滑方向的单位向量为：
     $$\text{dirX} = \cos(\text{rad}(h))$$
     $$\text{dirY} = \sin(\text{rad}(h))$$
     * *示例（左门 Heading 108.04）*：$\text{dir} = \text{vector3}(-0.31, 0.95, 0.0)$
     * *示例（右门 Heading 288.62）*：$\text{dir} = \text{vector3}(0.32, -0.95, 0.0)$

### B. 锁门注册 (`qb-doorlock` config)
在新帮派基地建立配置文件 `qb-doorlock/configs/gangname.lua`：
```lua
Config.DoorList['gangname_gate'] = {
    textCoords = vec3(x, y, z), -- 交互文本悬浮点（双门设在中心）
    authorizedGangs = { ['gangname'] = 0 }, -- 仅允许该帮派上锁/解锁
    locked = true,
    pickable = false,
    distance = 12.0,
    doorType = 'doublesliding', -- 激活双自动滑门机制（解锁后雷达开门，未锁时任何人靠近感应）
    doorRate = 1.2,
    audioLock = { ['file'] = 'metal-locker.ogg', ['volume'] = 0.6 },    -- 重锁扣声音
    audioUnlock = { ['file'] = 'metallic-creak.ogg', ['volume'] = 0.7 }, -- 重滑轨摩擦声
    doors = {
        { objName = 'prop_lrggate_02', objYaw = leftHeading, objCoords = vec3(x, y, z) },  -- 左门
        { objName = 'prop_lrggate_02', objYaw = rightHeading, objCoords = vec3(x, y, z) } -- 右门
    }
}
```

### C. 虚拟逻辑与客户端对称摆门重构 (Virtual & Custom Swing Gates)
对于一些动态生成的道具（例如庄园后铁门 `prop_lrggate_01_l/r`），其模型中并没有内置铰链（Hinge）关节约束。如果使用原生的 `AddDoorToSystem` 进行物理接管，解锁后大门就会受到重力影响**直接坠入地下**。
为了完美避开此问题，必须采用**“逻辑虚拟锁 + 物理绝对冻结 + 客户端对称 Heading 插值”**的设计：

1. **大门控制端注册 (`qb-doorlock` config)**：
   * 将 `doorType` 设为 `'custom'` 门锁类型。在此类型下，`qb-doorlock` 仅作为纯“逻辑锁”管理其锁状态同步、E 键交互与音效播放，**完全不调用** native `AddDoorToSystem`：
   ```lua
   Config.DoorList['cartel_gate_back'] = {
       textCoords = vec3(1313.23, 1188.65, 108.00), -- 交互提示中心
       authorizedGangs = { ['cartel'] = 0 },         -- 权限设置
       locked = true,
       pickable = false,
       distance = 12.0,
       doorType = 'custom',                          -- 核心：虚拟自定义类型
       objCoords = vec3(1313.23, 1188.65, 107.10),   -- 逻辑坐标中心
       objName = 'fake_gate_back_placeholder',       -- 占位名称
       audioLock = { ['file'] = 'metal-locker.ogg', ['volume'] = 0.6 },
       audioUnlock = { ['file'] = 'metallic-creak.ogg', ['volume'] = 0.7 }
   }
   ```

2. **门体创生与物理冻结 (Spawner Setup)**：
   * 实体使用 `FreezeEntityPosition(obj, true)` 保持永久物理冻结，绝对防坠地。

3. **客户端平滑对称摆动动画线程**：
   * 利用 client 线程，直接读取 `qb-doorlock` 同步 of 锁状态，并在玩家靠近 `12.0` 米内时，在客户端直接对实体 Heading 进行高性能插值（60 FPS）：
   ```lua
   -- 对称旋转摆动 (左门偏航 Heading 变大，右门偏航 Heading 变小)
   if leftGate and DoesEntityExist(leftGate) then
       SetEntityHeading(leftGate, 90.0 + (90.0 * backProgress))
   end
   if rightGate and DoesEntityExist(rightGate) then
       SetEntityHeading(rightGate, 90.0 - (90.0 * backProgress))
   end
   ```

> [!TIP]
> **原生滑门修复**：我们在 `qb-doorlock/client/main.lua` 中的 `updateDoors` 函数中打上了修复补丁。现已完备，任何在 `qb-doorlock` 里配置为 `sliding` 或 `doublesliding` 的大门，在流式加载进玩家视野时就会**自动激活 30.0 米的原生感应雷达**，解锁后玩家及所有非帮派人员无需 any 多余操作均可丝滑靠近、滑开、通过！

---

## 2. 防叠车防爆车库 (Gang Garage)

当要为新帮派配置专属 Gang 车库时：

### A. 车库数据库与配置注册
在 `qb-garages/config.lua` 中声明新车库：
```lua
Config.Garages["gangname_hq"] = {
    showBlip = false, -- 帮派车库通常对外保密
    label = "帮派俱乐部车库",
    coords = vector4(x, y, z, h), -- 存车/取车交互菜单点
    spawnPoint = {
        vector4(x1, y1, z1, h1), -- 出车车道 A
        vector4(x2, y2, z2, h2)  -- 出车车道 B（支持多车道出车）
    },
    type = "gang", -- 类型标记为帮派专用
    job = "gangname", -- 绑定帮派名
}
```

### B. 取车防叠车防爆安全哨兵 (Overlap Protection)
我们已经在 `qb-garages/client/main.lua` 的取车逻辑中重构了出车安全哨兵。每次玩家从帮派车库提车时，系统会强制执行 `IsPositionOccupied`（空间占用）检测：
```lua
-- 检测出车位周围 3.0 米范围内是否有其他物体占用
if IsPositionOccupied(spawnPoint.x, spawnPoint.y, spawnPoint.z, 3.0, false, true, true, false, false, 0, false) then
    QBCore.Functions.Notify("出车车道已被车辆占用，请等待清理后再试！", "error")
    return false -- 安全拦截，杜绝爆炸
end
```

---

## 3. NPC 友好守卫与同盟关系 (NPC Alliances)

当要在帮派基地放置驻防守卫 NPC 并保证他们对自家帮众 and 卧底警匪绝对友好，甚至开枪不反击：

### A. 全民同盟关系覆盖 (Companion Override)
在你的核心帮派资源（如 `custom-main/client/dispatch.lua`）中，监听玩家刷新的事件，动态建立同盟组：
```lua
local relationshipGroups = {
    "AMBIENT_GANG_MEXICAN", -- 墨西哥黑帮 (马德拉索庄园守卫)
    "AMBIENT_GANG_LOST",    -- Lost MC 摩托帮守卫
    "AMBIENT_GANG_BALLAS",  -- 巴拉斯帮守卫
    "AMBIENT_GANG_VAGOS",   -- 瓦格斯帮守卫
}

CreateThread(function()
    while true do
        local playerPed = PlayerPedId()
        local playerGroup = GetPedRelationshipGroupHash(playerPed)
        
        for _, groupName in ipairs(relationshipGroups) do
            local groupHash = GetHashKey(groupName)
            -- 1. 玩家对守卫友好 (0 代表 Companion / 伴侣同盟)
            SetRelationshipBetweenGroups(0, playerGroup, groupHash)
            SetRelationshipBetweenGroups(0, groupHash, playerGroup)
            -- 2. 守卫内部防误伤同盟
            SetRelationshipBetweenGroups(0, groupHash, groupHash)
        end
        Wait(5000) -- 每 5 秒动态刷新确保同盟持久有效
    end
end)
```

### B. 双重身份兼容（卧底与值勤警察判定）
如果你的服务器中有玩家兼任“卧底警察”或“身兼多职”，在 `dispatch.lua` 或守卫判定中，**必须优先验证 Gang 身份，随后才验证警员值勤状态**：
```lua
-- 警匪双重身份安全覆盖
if PlayerData.gang and PlayerData.gang.name == "cartel" then
    -- 如果是 Cartel 帮派成员，即便处于 on-duty police 状态，依然判定为 Cartel 友军，守卫不会开火！
    SetPoliceIgnorePlayer(playerPed, true)
else
    -- 其他普通值勤警察逻辑...
end
```

---

## 4. Boss 菜单与标识 (Boss Menus & Markers)

帮派的大脑是 Boss 菜单，用于管理帮派资金、招募成员、升降职等：

### A. 定义帮派数据
在 `qb-core/shared/gangs.lua` 中声明新帮派及其职级：
```lua
['lostmc'] = {
    label = 'Lost MC',
    grades = {
        ['0'] = { name = 'Recruit' },
        ['1'] = { name = 'Enforcer' },
        ['2'] = { name = 'Road Captain' },
        ['3'] = { name = 'Vice President' },
        ['4'] = { name = 'President', isboss = true }, -- 必须设置 isboss = true
    }
}
```

### B. 在 `qb-management` 中建立 Boss Menu 浮空标识
1. 打开 `qb-management/config.lua`，在 `Config.GangMenus` 下添加你的帮派基地 Boss 房桌案中心的 Vector3 坐标：
   ```lua
   Config.GangMenus = {
       lostmc = {
           vector3(982.26, -104.22, 74.85), -- Boss Menu 交互点
       },
       cartel = {
           vector3(1395.80, 1141.74, 115.24), -- 庄园 Boss 房坐标
       }
   }
   ```
2. 只要玩家的 Gang Grade 标记了 `isboss = true`，当他走到该坐标时，就会自动呈现 3D 浮空立体标记 `[E] - 帮派管理`，按下 `E` 键即可开启 **帮派财务提取/存入、帮众招聘、开除与职级更替** 等全套生产功能。

---

## 5. 成员菜单、仓库、更衣室与武装店 (Non-Boss Member Features)

非 Boss 成员共享大仓库 (Stash)、更衣室 (Cloakroom) 与武装特色商店 (Armory) 的配置与写法如下：

### A. 成员功能区域结构化配置
创建一个简单的 `resources/[standalone]/gang-facilities/client.lua`：
```lua
local QBCore = exports['qb-core']:GetCoreObject()
local PlayerGang = {}

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    PlayerGang = QBCore.Functions.GetPlayerData().gang
end)

RegisterNetEvent('QBCore:Client:OnGangUpdate', function(gang)
    PlayerGang = gang
end)

-- 各个帮派基地设施坐标表
local Facilities = {
    lostmc = {
        stash = vector3(980.0, -102.0, 74.8),     -- 共享大仓库
        cloakroom = vector3(985.0, -105.0, 74.8), -- 更衣室
        armory = vector3(978.0, -100.0, 74.8),    -- 军火库
    },
    cartel = {
        stash = vector3(1390.0, 1145.0, 114.5),
        cloakroom = vector3(1392.0, 1143.0, 114.5),
        armory = vector3(1388.0, 1140.0, 114.5),
    }
}

-- 实时绘制交互 Marker
CreateThread(function()
    while true do
        local sleep = 1000
        if LocalPlayer.state.isLoggedIn and PlayerGang and Facilities[PlayerGang.name] then
            local playerCoords = GetEntityCoords(PlayerPedId())
            local fc = Facilities[PlayerGang.name]
            
            -- 1. 帮派共享仓库 Stash (科技蔚蓝色)
            local distStash = #(playerCoords - fc.stash)
            if distStash < 5.0 then
                sleep = 0
                DrawMarker(2, fc.stash.x, fc.stash.y, fc.stash.z, 0,0,0, 0,0,0, 0.3,0.3,0.2, 0, 150, 255, 150, false, true, 2, false, nil, nil, false)
                if distStash < 1.5 then
                    QBCore.Functions.DrawText3D(fc.stash.x, fc.stash.y, fc.stash.z + 0.2, "[E] 开启帮派共享仓库")
                    if IsControlJustPressed(0, 38) then -- E 键
                        TriggerServerEvent("inventory:server:OpenInventory", "stash", PlayerGang.name .. "_stash", {
                            maxweight = 4000000, -- 4000 KG 超大负重
                            slots = 120,        -- 120 超大格子
                        })
                        TriggerEvent("inventory:client:SetCurrentStash", PlayerGang.name .. "_stash")
                    end
                end
            end
            
            -- 2. 帮派衣柜 Cloakroom (薄荷翠绿色)
            local distCloak = #(playerCoords - fc.cloakroom)
            if distCloak < 5.0 then
                sleep = 0
                DrawMarker(2, fc.cloakroom.x, fc.cloakroom.y, fc.cloakroom.z, 0,0,0, 0,0,0, 0.3,0.3,0.2, 0, 255, 150, 150, false, true, 2, false, nil, nil, false)
                if distCloak < 1.5 then
                    QBCore.Functions.DrawText3D(fc.cloakroom.x, fc.cloakroom.y, fc.cloakroom.z + 0.2, "[E] 开启私人衣柜")
                    if IsControlJustPressed(0, 38) then
                        TriggerEvent('qb-clothing:client:openOutfitMenu') -- 触发原生服装店/私人衣柜菜单
                    end
                end
            end
            
            -- 3. 帮派武装与道具店 Armory (警示烈红色)
            local distArmory = #(playerCoords - fc.armory)
            if distArmory < 5.0 then
                sleep = 0
                DrawMarker(2, fc.armory.x, fc.armory.y, fc.armory.z, 0,0,0, 0,0,0, 0.3,0.3,0.2, 255, 50, 50, 150, false, true, 2, false, nil, nil, false)
                if distArmory < 1.5 then
                    QBCore.Functions.DrawText3D(fc.armory.x, fc.armory.y, fc.armory.z + 0.2, "[E] 开启帮派武装店")
                    if IsControlJustPressed(0, 38) then
                        -- 打开特定的帮派军火库/武装道具配置
                        TriggerServerEvent("inventory:server:OpenInventory", "shop", "gang_" .. PlayerGang.name, Config.GangShops[PlayerGang.name])
                    end
                end
            end
        end
        Wait(sleep)
    end
end)
```
