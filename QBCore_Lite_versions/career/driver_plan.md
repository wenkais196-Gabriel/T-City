# 🚗 T-City Lite 驾驶员与驾考系统 (Driver) 细化规划

> **适用版本**: v0.7a - v0.8  
> **涉及资源**: `qb-cityhall` (市政厅), `custom-certificates` (证照), `custom-quest` (任务系统), `qb-policejob` (警用交互)

---

## 🔍 1. 全局扫描与现状分析

经对市政厅和驾驶执照模块进行扫描，发现目前的驾照获取和执法拦截逻辑存在以下特点：

1. **线下教练考试模型 (Legacy & Hard to Play)**：
   * 在 [server/main.lua:L249-L270](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-cityhall/server/main.lua#L249-L270) 中，玩家在驾校 NPC 处报名后，系统会给数据库配置的“驾校教练 (Instructors)”发送邮件。
   * 然后由在线教练上车测试，并由教练手动运行 `/drivinglicense [id]` 指令（[L314-L336](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-cityhall/server/main.lua#L314-L336)）批准考试，玩家再去市政厅打印实体驾照。
   * **痛点**：这是一个高度依赖“在线教练”人工处理的流程。在半夜或教练不在线时，新玩家根本无法考取驾照。
2. **市政厅手写元数据绕过**：
   * 在 [server/main.lua:L140-L165](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-cityhall/server/main.lua#L140-L165) 中，玩家花 $150 购买驾照时，市政厅依然是直接修改 `Player.PlayerData.metadata['licences']` 的布尔值，没有调用 `custom-certificates` 提供的标准导出 API。
3. **无证驾驶与司法执法的平衡**：
   * 在 [custom-certificates/client/main.lua:L78-L80](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-certificates/client/main.lua#L78-L80) 中，平民驾驶常规车辆（class 0~9）时，`CanDriveVehicleClass` 返回 `true`。
   * **RP 设计点**：这是合理的设计。允许无证驾驶以方便警察抓现行；但对于“重型载具 (heavy)”或“民航物流”，应当在任务触发时强制校验有无执照。

---

## 🛠️ 2. 细化重构规划

### 1) 自动驾驶考试系统 (Automated DMV Driving Exam Quest)
在 `custom-quest` 中新增一条自动化的驾考任务链（`driver_license_exam`），摆脱对人工教练的依赖，让考驾照成为有趣的日常挑战。

* **修改文件**：在 `custom-quest/config/quests/` 目录下新增驾考配置。
* **考试任务设计**：
  * **起步条件**：前往驾校 NPC（`a_m_m_eastsa_02`）处交纳 $100 报名费，接取任务。
  * **步骤 1 (考车绑定)**：坐进系统生成的专用黄色“DMV 考车”（`blista`）➔ 系统自动授予临时钥匙。
  * **步骤 2 (科目二：基础绕桩与刹车)**：按照地面蓝圈 GPS 导航行进 ➔ 在“STOP”红灯标志线内，系统监测车速是否归 0。如果直接冲卡则扣分。
  * **步骤 3 (科目三：限速与城市驾驶)**：驶入公路线，系统开启速度监控（例如限速 80km/h）。超速会闪红警告，累计超速 3 秒则考试失败。
  * **步骤 4 (倒车入库)**：将车辆平稳倒入驾校的专用库位，并熄火拉手刹。
  * **考评发放**：完成考试后，任务系统自动执行 `exports['custom-certificates']:GrantLicense(source, 'driver')` 授予其驾照权限。

### 2) 重型载具考试系统 (Heavy Vehicle License Exam)
对于货车司机、公交司机必需的“重型载具执照（`heavy`）”，新增重卡驾考任务。

* **任务流程**：
  * 玩家驾驶 Benson 重卡 ➔ 倒车穿过狭窄的堆料区 ➔ 将货物挂车准确推入仓库卸货台。
  * 考核通过后授予 `heavy` 执照。

### 3) 规范市政厅购买接口 (Standardize Cityhall Purchase API)
重构市政厅的购买和补办流程，拒绝手写 metadata。

* **修改文件**：[qb-cityhall/server/main.lua](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-cityhall/server/main.lua)
* **具体做法**：
  * 当玩家在市政厅申领或补办证件时，替换为：
    * `exports['custom-certificates']:IssueCertificate(src, licenseType)`
  * **考试与金钱的分流设计 (RP Choice)**：
    * 如果玩家选择**直接在市政厅免试购买**驾照，费用提高至 **$3,000**（懒人通道）；
    * 如果玩家选择**前往驾校通过自动化考试**，费用仅需 **$100**，鼓励玩家体验驾考任务。

### 4) 规范警用暂扣与吊销命令 (Police License Enforcement)
* **修改文件**：[qb-policejob/server/commands.lua](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-policejob/server/commands.lua)
* **具体做法**：
  * 重构警察的暂扣驾照指令 `/takedrivinglicense [id]`：
    调用 `exports['custom-certificates']:SuspendLicense(targetId, 'driver')`。
  * 吊销后，实体卡在背包中失效，当被警用 NUI 终端或 3D 文档查验时，驾照状态将变为 `suspended`（暂停）或 `revoked`（吊销）。如果玩家再次无证驾车被警察截停，将面临高额罚款或坐牢。

---

## 🚦 3. 讨论与下一步操作

请审核本份**驾驶员与驾考系统细化规划**。如果您同意该规划，我们可以执行以下操作：
1. **通过/批准**：您可以回复“**批准该规划**”，我将进入 `Planning Mode` 准备实施这些重构。
2. **修改意见**：如果您有任何关于驾考速度处罚、科目环线设定或市政厅直接购买费用的修改想法，请告诉我。
