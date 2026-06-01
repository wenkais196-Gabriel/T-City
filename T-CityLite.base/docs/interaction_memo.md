# T-City Lite 交互设计规范备忘录 (Interaction Design Memo)

## 📌 交互范式概述

T-City Lite 服务器采用 **方案 C（ALT 瞄准为主，近身 E 键为辅）** 的混合交互风格规范。
该设计旨在平衡游戏的 **沉浸感（Roleplay 体验）**、**交互精确性（避免重叠干扰）**、**操作便利性（高频操作快捷）** 以及 **客户端性能 (FPS)**。

---

## 🎯 场景判定规则 (什么时候用 ALT，什么时候用 E)

### 🔴 规则 1：静态世界物体 / 车辆交互 / 选项分支多 ── 必须统一使用 [ALT] (Third-Eye 模式)
在世界中分布广泛、容易造成视觉污染、或同一物体有多个分支选项的场景，统一使用 ALT。
* **典型场景**：
  * **世界实体**：ATM 机、垃圾桶（搜刮）、自动售货机、公共电话。
  * **NPC / 商店**：各类买卖 NPC（非法药品交易、废品回收站）、租车 NPC。
  * **车辆系统**：对车辆进行“撬锁”、“搜刮手套箱”、“查看底盘车况”、“开启后备箱”等。
  * **门禁系统**：各类需要开锁/密码输入的门。
* **设计理由**：避免玩家路过这些物体时满屏弹出“按 E 交互”的 UI，同时有效防止多个物体（如路边并排的 3 台 ATM）交互发生冲突。

### 🟢 规则 2：专属功能区域 / 高频单一动作 / 界面传送 ── 统一支持或保留 [E] (Proximity 模式)
专为特定玩家行为设计、物理区域排他、站过去的目标单一且高频的场景，统一保留或加入近身 E 键提示。
* **典型场景**：
  * **进入/退出点**：公寓大门、电梯间、传送门（进出楼宇）。
  * **个人功能区**：服装店更衣室、警察局装备柜、医院复活病床、车库管理员取车点。
  * **高频执勤点**：上下班打卡处。
  * **银行柜台**：虽然支持 ALT，但因为柜台是独立专属的大厅区域，额外增加 [E] 近身交互可以让存取款更快捷顺畅。
* **设计理由**：这些区域的交互目标极其纯粹，玩家走过去 99% 就是为了做这一件事，直接按 E 能获得最连贯、无打断的爽快体验。

---

## 💻 官方标准参考代码模板 (Developer References)

为确保未来的交互系统风格完全统一，所有资源编写必须遵守以下代码规范：

### 🧬 范式一：[ALT] 第三只眼标准实现 (`qb-target`)

#### A. 针对“特定 3D 模型”注册全局 ALT 监听 (例如：所有同型号 ATM 机)
```lua
-- 客户端 client.lua
local atmModels = { 'prop_atm_01', 'prop_atm_02', 'prop_atm_03', 'prop_fleeca_atm' }

CreateThread(function()
    for i = 1, #atmModels do
        exports['qb-target']:AddTargetModel(atmModels[i], {
            options = {
                {
                    icon = 'fas fa-university', -- FontAwesome 图标
                    label = '使用自动柜员机',     -- 悬浮显示的中文文本
                    item = 'bank_card',         -- [可选] 必须持有该道具才显示此选项
                    action = function(entity)   -- 触发后的客户端函数
                        OpenATM()
                    end,
                }
            },
            distance = 1.5 -- 允许交互的物理距离
        })
    end
end)
```

#### B. 针对“特定空间坐标”注册 ALT 圆形/盒子区域 (例如：银行柜台)
```lua
-- 客户端 client.lua
CreateThread(function()
    exports['qb-target']:AddCircleZone('bank_counter_1', vector3(149.05, -1041.3, 29.37), 1.0, {
        name = 'bank_counter_1',
        useZ = true, -- 是否启用高度 Z 轴判定
        debugPoly = false, -- 调试多边形开关（开发调试时可设为 true）
    }, {
        options = {
            {
                icon = 'fas fa-wallet',
                label = '办理银行柜台业务',
                action = function()
                    OpenBank()
                end,
            }
        },
        distance = 1.5
    })
end)
```

---

### 🏃 范式二：[E] 键近身感应标准实现 (`PolyZone` + `ComboZone`)

为防止多区域计算导致客户端卡顿，**严禁**使用无差值的 `GetDistanceBetweenCoords` 暴力死循环。必须统一采用 `PolyZone` (或 `CircleZone`) + `ComboZone` 的事件监听机制，且务必做好 **`isUIOpen` 状态锁** 防止界面连击穿透。

```lua
-- 客户端 client.lua
local zones = {}
local isPlayerInsideZone = false
local isUIOpen = false -- UI 状态锁，极其重要！

-- 1. 创建触发区域
CreateThread(function()
    local interactPoints = {
        vector3(149.05, -1041.3, 29.37),
        vector3(313.32, -280.03, 54.17),
    }

    for i = 1, #interactPoints do
        local zone = CircleZone:Create(interactPoints[i], 2.5, {
            name = 'custom_zone_' .. i,
            debugPoly = false,
        })
        zones[#zones + 1] = zone
    end

    local combo = ComboZone:Create(zones, {
        name = 'custom_combo',
        debugPoly = false,
    })

    -- 2. 监听玩家进出事件
    combo:onPlayerInOut(function(isPointInside)
        isPlayerInsideZone = isPointInside
        if isPlayerInsideZone then
            -- 统一使用 QBCore 内置侧边 DrawText 规范，文案格式统一为：[E] 操作描述
            exports['qb-core']:DrawText('[E] 打开专属面板', 'left')
            
            -- 3. 启用独立按键监听线程
            CreateThread(function()
                while isPlayerInsideZone do
                    Wait(0)
                    -- 控制器 0, 按键 38 (E 键)。同时校验 UI 锁
                    if IsControlJustPressed(0, 38) and not isUIOpen then
                        TriggerInteractionLogic()
                    end
                end
            end)
        else
            -- 玩家离开区域，必须立刻隐藏文本
            exports['qb-core']:HideText()
        end
    end)
end)

-- 4. 交互处理函数
function TriggerInteractionLogic()
    isUIOpen = true -- 加锁
    exports['qb-core']:HideText() -- 开启 UI 时主动收回按键提示，保持界面整洁
    
    -- 触发逻辑 (例如打开 NUI 面板)
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'openUI' })
end

-- 5. NUI 关闭事件（务必在这里解锁）
RegisterNUICallback('closeApp', function(_, cb)
    SetNuiFocus(false, false)
    isUIOpen = false -- 解锁，允许玩家下次再次按 E 触发
    cb('ok')
end)
```

---

## 🛡️ 全局兼容性保障建议

在未来的开发中，若要实现“ALT 可开可不开”的自适应兼容，在配置阶段请优先读取 Convar 参数：
```lua
Config = {
    -- 自动读取服务器 server.cfg 的全局 UseTarget 设定
    useTarget = GetConvar('UseTarget', 'false') == 'true',
}
```
* 当 `Config.useTarget` 为 `true` 时：注册 `qb-target` 交互。
* 当 `Config.useTarget` 为 `false` 时：动态降级注册 `E` 键近身交互（如 qb-banking 对 ATM 的降级处理）。
