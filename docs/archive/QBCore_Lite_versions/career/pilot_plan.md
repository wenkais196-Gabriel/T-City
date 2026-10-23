# ✈️ T-City Lite 飞行员与航空系统 (Pilot) 细化规划

> **适用版本**: v0.7a - v0.8  
> **涉及资源**: `custom-certificates` (证照), `custom-quest` (任务系统), `custom-documents` (文档), `qb-policejob`/`qb-ambulancejob` (紧急服务)

---

## 🔍 1. 全局扫描与现状分析

通过对航空器及飞行员相关的脚本与配置文件进行扫描，我们发现以下特点和架构缺陷：

1. **航空执照存在，但物理驾驶控制失效 (Core Loop Hole)**：
   * 在 [custom-certificates/client/main.lua:L65-L81](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-certificates/client/main.lua#L65-L81) 中，`CanDriveVehicleClass` 始终直接返回 `true`，并附带注释：“允许无证驾驶以方便警察扮演”。
   * **问题**：这导致游戏内对直升机（15级）和飞机（16级）的驾驶限制成了“摆设”。任何平民玩家无论有没有飞行执照（`pilot`），都可以任意开走机场的飞机和直升机，驾驶权限没有得到物理闭环。
2. **缺乏合法的航空培训与考核流程 (Aviation Exam)**：
   * 目前玩家获取飞行执照只有两种非 RP 途径：去市政厅直接花钱买、或者由管理员/警察使用指令赠送。
   * **痛点**：缺乏一个身临其境的“飞行学校”培训与考核流程（如起飞、空中过圈、平稳降落），导致飞行员扮演缺乏仪式感和技术门槛。
3. **已有的飞行器监控与任务链**：
   * [quest_logistics.lua:L245-L358](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_logistics.lua#L245-L358) 中已经设计了走私飞行任务（`aviation_smuggling_flight`），并利用 [quest_logistics_client.lua:L14-L121](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-quest/client/quest_logistics_client.lua#L14-L121) 实现了高精度的“海平面低空飞行监控雷达（低于 150m 保持 45s 闪红警告）”，技术底座非常扎实。

---

## 🛠️ 2. 细化重构规划

### 1) 强效物理驾驶限制 (Enforce Vehicle Class Restrictions)
收紧 `custom-certificates` 客户端的驾驶权判定，对无证强行开动航空器的行为实施拦截。

* **修改文件**：[custom-certificates/client/main.lua](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-certificates/client/main.lua)
* **具体做法**：
  * 在 `CanDriveVehicleClass` 中恢复真实校验，拦截 15（直升机）和 16（飞机）的驾驶权：
    ```lua
    exports('CanDriveVehicleClass', function(vehicleClass)
        local requiredLicense = nil
        for certType, config in pairs(Config.CertificateTypes) do
            for _, vc in ipairs(config.vehicleClasses) do
                if vc == vehicleClass then
                    requiredLicense = certType
                    break
                end
            end
        end
        if not requiredLicense then return true end

        -- 警局/医护执勤期间自动豁免 (方便扮演救援/拦截)
        local jobData = QBCore.Functions.GetPlayerData().job
        if jobData and (jobData.type == 'leo' or jobData.type == 'ems') and jobData.onduty then
            return true
        end

        -- 普通平民玩家必须拥有对应执照并且状态为 held
        return licenseCache[requiredLicense] == true
    end)
    ```
  * **客户端防强开 Loop**：
    在 `client/main.lua` 中开启一个 1000ms 的慢循环检测，当发现无证平民玩家进入飞机/直升机驾驶位（Seat -1）时，锁定引擎并强制其离开：
    ```lua
    CreateThread(function()
        while true do
            Wait(1000)
            local ped = PlayerPedId()
            if IsPedInAnyVehicle(ped, false) then
                local veh = GetVehiclePedIsIn(ped, false)
                if GetPedInVehicleSeat(veh, -1) == ped then
                    local vehClass = GetVehicleClass(veh)
                    if (vehClass == 15 or vehClass == 16) then
                        local hasLicense = exports['custom-certificates']:HasLicense('pilot')
                        -- 豁免警医执勤
                        local jobData = QBCore.Functions.GetPlayerData().job
                        local isService = jobData and (jobData.type == 'leo' or jobData.type == 'ems') and jobData.onduty
                        
                        if not hasLicense and not isService then
                            SetVehicleEngineOn(veh, false, true, true)
                            TaskLeaveVehicle(ped, veh, 0)
                            QBCore.Functions.Notify('🚨 警告：你没有飞行执照，系统已强行切断航空器引擎！', 'error', 5000)
                        end
                    end
                end
            end
        end
    end)
    ```

### 2) 飞行科目考核任务 (Pilot License Exam Quest)
新增一条在 `custom-quest` 中的飞行执照技能考试任务链，只有考核通过才能发放证书。

* **修改文件**：在 `custom-quest/config/quests/` 目录下创建新任务配置文件或写入 `quest_logistics.lua`。
* **考试任务设计 (`pilot_exam_course`)**：
  * **起步条件**：在市政厅或机场航站楼缴纳报名费（如 $1000 现金）。
  * **步骤 1 (准备阶段)**：前往 LSIA 国际机场 3 号机库 ➔ 租用/绑定一辆教练机（`mammatus`）➔ 获得起飞许可。
  * **步骤 2 (起飞与过圈)**：起飞并飞往 Sandy Shores 空域，必须平稳穿过空中分布的 5 个 3D 检查环（`reach` 节点，半空坐标点，半径 30 米）。
  * **步骤 3 (平稳降落)**：降低高度，成功平稳降落在大沙漠（Sandy Shores）跑道，并滑行至指定停机位停妥。
  * **考评发放**：完成最后一步时，任务奖励中配置 `script_trigger` 执行 `custom-certificates:GrantLicense`，永久将该玩家的飞行执照变更为 `held`，并发放实体证件。

### 3) 扩充合法民航物流任务 (Add Legal Air Transport Quests)
* 在 [quest_logistics.lua](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_logistics.lua) 中，除了走私飞行，新增一条合法的民航空运路线（例如：LSIA 港口空运医药箱 ➔ Grapeseed 跑道）。
* 该任务要求飞行高度**必须高于**海平面 250 米以保持民航线高度。低于 250 米会触发空域警告。

### 4) 紧急服务 (LEO/EMS) 空中力量联动
* 警局和医疗中心的直升机停机坪在生成直升机时，直接调用 `exports['custom-certificates']:HasLicense(src, 'pilot')`。无飞行执照的警员/医生无法申领并开动警用/医用直升机，强制要求警医团队内有专职“警航/急救飞行员”的职能划分。

---

## 🚦 3. 讨论与下一步操作

请审核本份**飞行员与航空系统细化规划**。如果您同意该规划，我们可以执行以下操作：
1. **通过/批准**：您可以回复“**批准该规划**”，我将进入 `Planning Mode` 准备实施这些重构。
2. **修改意见**：如果您对物理强踢出驾驶座的逻辑、飞行考试过圈的范围或警航免证权限有不同的看法，请随时提出来。
