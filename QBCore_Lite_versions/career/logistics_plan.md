# 🚚 T-City Lite 货运司机与物流系统 (Logistics) 细化规划

> **适用版本**: v0.7a - v0.8  
> **涉及资源**: `custom-quest` (任务系统), `custom-career` (职业), `custom-certificates` (证照), `custom-vehicles` (载具控制)

---

## 🔍 1. 全局扫描与现状分析

经过对任务系统及物流子模块的扫描，我们发现 T-City Lite 的货运系统采用了非常先进的**数据驱动无脚本化**设计，但仍有安全和体验漏洞需要闭环：

1. **完全基于通用任务系统集成**：
   * 区别于传统独立的 `qb-truckerjob`，我们的货运系统已完全合并至 `custom-quest` 中，通过 [quest_logistics.lua](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_logistics.lua) 配置了三款代表性任务：
     * `euro_trucking_steel`（C/B级常规钢板配送）
     * `euro_trucking_heavy_trailer`（A级 Semi 重载挂车运输，集成物理挂钩检测）
     * `aviation_smuggling_flight`（飞行走私，集成低空避雷达监控）
2. **严重的执照准入校验缺失 (Exploit Risk)**：
   * 在物流任务配置中，明确定义了 `conditions = { min_license = 'heavy' }`（需要重载执照）及 `min_license = 'pilot'`（飞行执照）。
   * **漏洞**：但在 [quest_manager.lua:L83-L90](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-quest/server/quest_manager.lua#L83-L90) 的 `TriggerQuest` 触发检测中，**完全没有**对 `min_license` 这一条件进行核验。
   * **后果**：任何没有重型载具驾照、甚至没有飞行执照的平民，均可在手机端直接接单并驾驶重卡、半挂和飞机进行运输工作，这破坏了 `custom-certificates` 的准入闭环。
3. **租用车钥匙与锁车逻辑脱节**：
   * 在 [quest_logistics_validators.lua:L150-L182](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-quest/server/quest_logistics_validators.lua#L150-L182) 中，租用卡车（如 Benson 或 Phantom）通过扣除押金和绑定车牌实现。
   * **问题**：绑定租用车后，系统并没有自动通过 `custom-vehicles` (或 `qb-vehiclekeys`) 向玩家发放车钥匙。这会导致如果玩家下车锁门后，将无法再次开锁进入车辆，直接卡死任务。

---

## 🛠️ 2. 细化重构规划

### 1) 修复任务执照准入守卫 (Fix License Guard in Quest Trigger)
在任务状态机接单流程中，补充对证书/执照的强制强安全校验。

* **修改文件**：[quest_manager.lua](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-quest/server/quest_manager.lua)
* **具体做法**：
  在 `TriggerQuest` 校验链中，添加 `min_license` 的检测逻辑：
  ```lua
  -- 在 TriggerQuest 校验 required_tags 和 min_police 之后添加：
  if template.conditions and template.conditions.min_license then
      local licenseType = template.conditions.min_license
      local hasLicense = exports['custom-certificates']:HasLicense(source, licenseType)
      if not hasLicense then
          local licenseLabels = { heavy = "重型载具执照", pilot = "飞行执照", boat = "船舶执照" }
          return false, ('接单失败：你需要持有 %s 且处于激活状态！'):format(licenseLabels[licenseType] or licenseType)
      end
  end
  ```

### 2) 租车联动与车钥匙自动分发 (Rental Vehicle Keys Integration)
打通租车生成验证器与载具要是分发系统的桥梁。

* **修改文件**：[quest_logistics_validators.lua](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-quest/server/quest_logistics_validators.lua)
* **具体做法**：
  在 `validate_logistics_vehicle` 租车成功、绑定车牌的步骤后，立即分发虚拟钥匙：
  ```lua
  -- 在 validate_logistics_vehicle 成功绑定 PlayerBindings 并 return true 之前：
  if vehInfo.plate then
      -- 触发钥匙系统分发
      TriggerClientEvent('vehiclekeys:client:SetOwner', src, vehInfo.plate)
      -- 如果自研 custom-vehicles 启用，同步调用其 export 授予物理临时钥匙
      if exports['custom-vehicles'] then
          exports['custom-vehicles']:GiveTemporaryKey(src, vehInfo.plate)
      end
  end
  ```

### 3) 供应链联动与市长 KPI 反哺 (Mayor KPI & Society Integration)
让平民货运司机与城市工程、市长业绩指标真正关联。

* **修改文件**：[quest_logistics_validators.lua](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-quest/server/quest_logistics_validators.lua)
* **具体做法**：
  在物流到达交付步骤（如运送钢材、桥梁箱梁）中，更新城市建设指标：
  * 当任务 `euro_trucking_steel` 完成时，触发：
    ```lua
    TriggerEvent('custom-leaders:server:AddCityProgress', 'infrastructure', 5) -- 基础设施进度 + 5
    ```
  * 从而在市长手机终端的“城市工程”APP 中，动态更新项目建设进度，将物流数据作为政治家业绩考评的依据。

---

## 🚦 3. 讨论与下一步操作

请审核本份**货运司机与物流系统细化规划**。如果您同意该规划，我们可以执行以下操作：
1. **通过/批准**：您可以回复“**批准该规划**”，我将进入 `Planning Mode` 准备实施这些修改。
2. **修改意见**：如果您对执照检查拦截、租车扣款金额或与其他职业（如市长）的 KPI 联动方式有任何修改意见，请随时告诉我。
