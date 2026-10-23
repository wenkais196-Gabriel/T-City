# 🏥 T-City Lite 医护职业与救援系统 (EMS) 细化规划

> **适用版本**: v0.6 - v0.8  
> **涉及资源**: `qb-ambulancejob` (医院), `custom-career` (职业), `custom-certificates` (证照), `custom-documents` (文档)

---

## 🔍 1. 全局扫描与现状分析

经过对 `qb-ambulancejob` 源码的扫描，发现当前医护系统的运行机制和可以优化的地方如下：

1. **载具解锁基础代码完备，但配置缺失**：
   * 在 [client/job.lua:L44-L54](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-ambulancejob/client/job.lua#L44-L54) 中，`getAuthorizedVehicles` 函数已经写好了“高等级玩家能够向下兼融低等级所有载具”的累进解锁逻辑。
   * **问题**：但在 [config.lua:L115-L119](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-ambulancejob/config.lua#L115-L119) 的配置中，只有 `[0]` 键分配了唯一的一辆 `ambulance`。这导致高级医护人员（如主治医生、外科主任）提车时没有阶梯性待遇，缺乏职业进阶感。
2. **直升机生成无任何限制**：
   * 在 [client/job.lua:L364-L392](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-ambulancejob/client/job.lua#L364-L392) 的 `EMSHelicopter` 交互点，任何救护人员只要在 duty 状态下，均可直接刷出并驾驶警用/医用直升机。
   * **痛点**：这绕过了飞行执照校验，使 `custom-certificates` 中的 `pilot`（飞行许可证）在 EMS 体系中形同虚设。
3. **空置的扩展属性（科室分工）**：
   * 医院内部同样需要精细化扮演。例如**外科医生（Surgeon）**与**急救员（Paramedic）**在抢救病人、执行直升机转运时的职责大不相同。目前整个 `qb-ambulancejob` 只是单一的 `ambulance` 职业包，没有任何内部科室（`department`）区分。
4. **急救包（firstaid）使用与判定**：
   * 在 [server/main.lua:L200-L234](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua#L200-L234) 中，服务器只验证了操作者是否拥有 `ambulance` 职业或者背包里有 `firstaid`（急救包）物品。如果是平民使用急救包，将无法区分其是否具有医疗背景。

---

## 🛠️ 2. 细化重构规划

### 1) 累进车库配置与空中救援队限制 (Garage progression & Air Rescue Limit)
补全阶梯救护车库配置，并将飞行限制接入 `custom-certificates`。

* **修改文件**：[config.lua](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-ambulancejob/config.lua)
* **具体做法**：
  * **阶梯载具配置**：
    ```lua
    Config.AuthorizedVehicles = {
        [0] = { -- 实习医护 (Recruit)
            ambulance = 'Classic Ambulance (常规救护车)'
        },
        [1] = { -- 正式急救员 (Paramedic)
            rescue = 'Off-road Rescue Van (野外应急救护车)'
        },
        [2] = { -- 主治医生 (Doctor)
            emssuv = 'Medical Response SUV (医疗指挥 SUV)'
        },
        [3] = { -- 外科主任 (Surgeon)
            emsrun = 'High-speed Medical Interceptor (极速救护跑车)'
        },
        [4] = { -- 院长 (Chief)
            emscommander = 'Chief Executive SUV (行政长官 SUV)'
        }
    }
    ```
  * **直升机生成限制**：
    在客户端 `qb-ambulancejob/client/job.lua` 的 `EMSHelicopter` 事件中：
    ```lua
    local hasPilotLicense = exports['custom-certificates']:HasLicense(GetPlayerServerId(PlayerId()), 'pilot')
    if not hasPilotLicense then
        QBCore.Functions.Notify('错误：你没有飞行执照 (Pilot License)，无法申领空中急救直升机！', 'error')
        return
    end
    ```

### 2) 医院内部科室 (Department) 扮演重构
借助 `custom-career` 元数据，为医院细分日常科室。

* **部门定义**：
  * `EMERGENCY` (急诊科/前线急救员)：负责出警车去现场接伤员、实施包扎与除颤。
  * `SURGERY` (外科手术部/医生)：负责在医院无菌手术室对重伤员进行手术（如清创、骨折缝合）。
  * `AIR_RESCUE` (空中救援组)：负责使用直升机转运偏远郊区（Paleto/沙漠）的重伤患。
* **分配指令（院长/副院长可用）**：
  * `/setemsdept [id] [EMERGENCY/SURGERY/AIR_RESCUE]`：分配所属科室，调用 `SetPlayerDepartment`。
* **业务功能锁定**：
  * **手术台治疗限制**：如果病人处于骨折或多发枪伤（可通过 `/status` 查看），常规 `EMERGENCY` 只能进行紧急止血（绷带），无法让其痊愈。必须由 `SURGERY` 部门的医生在手术台使用特定道具或交互点才能完全消除骨折伤害。
  * **药物库房（Stash）**：肾上腺素、医疗缝合针等高级急救资源仅对 `department == 'SURGERY'` 开放提取权限。

### 3) 医疗执业执照与院外急救 (Medical Cert & Field Treatment)
* **医疗执照 (medical_cert) 认证**：
  * 玩家必须在 `custom-career` 拥有 `medical_cert` 证书，才能使用急救包（`firstaid`）对其他重伤倒地玩家进行心肺复苏（复活）。
  * 杜绝服务器上平民无任何扮演背景、无证违规行医或滥用除颤仪的行为。
* **3D 医疗执业证展示**：
  * 医护人员在执勤、开药或现场急救时，可以通过 `custom-documents` 出示其“洛圣都医疗中心医师执业证”（显示其姓名、所属科室 `department` 以及证书序列号），提升市民互动沉浸感。

### 4) 自愈自检与 F8 医疗日志
* 将所有 `hospital:server:RevivePlayer` 和 `TreatWounds` 结算动作接入 `custom-main` 统一的经济与行为审计 Webhook。记录：“[时间] 外科医生A 对 玩家B 实施了复活，耗费急救包 x1”。

---

## 🚦 3. 讨论与下一步操作

请审核本份**医护职业细化规划**。如果您同意该规划，我们可以执行以下操作：
1. **通过/批准**：您可以回复“**批准该规划**”。
2. **修改意见**：如果您有任何需要添加或修改的 EMS 扮演交互细节（例如手术玩法或急救包扣除条件），请直接告诉我，我将更新规划文件。
