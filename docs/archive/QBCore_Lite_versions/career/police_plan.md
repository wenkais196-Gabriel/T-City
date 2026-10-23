# 👮 T-City Lite 警察职业与司法系统 (LSPD) 细化规划

> **适用版本**: v0.6 - v0.8  
> **涉及资源**: `qb-policejob` (警局), `custom-career` (职业), `custom-certificates` (证照), `custom-documents` (文档)

---

## 🔍 1. 全局扫描与现状分析

经过对 `qb-policejob` 相关文件的扫描，发现当前的代码设计存在以下限制和优化空间：

1. **证书/执照指令设计脱节**：
   * 在 [commands.lua:L10-L85](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-policejob/server/commands.lua#L10-L85) 中，警察的 `/grantlicense` 与 `/revokelicense` 是通过手动读写 `Player.PlayerData.metadata['licences']` 和 `'cert_status'` 实现的。
   * **痛点**：这绕过了 `custom-certificates` 的标准导出函数（如 `GrantLicense`/`RevokeLicense`），导致如果其他系统挂载了执照变更的 Hook，将无法触发。此外，这使得吊销/授权逻辑存在重复的硬编码（例如物品扣除）。
2. **载具授权等级失效与死码**：
   * 在 [config.lua:L126-L138](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-policejob/config.lua#L126-L138) 中，`Config.AuthorizedVehicles` 仅定义了 `[0]` 键。
   * 在 [client/job.lua:L168-L186](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-policejob/client/job.lua#L168-L186) 中，警局车库通过 `for grade = 0, playerGrade do` 循环去获取对应 grade 的授权载具。
   * **漏洞**：因为配置里只有 `0` 级键，正式警员 (1级)、警司 (2级) 等高等级玩家在车库无法看到任何车辆（获取到 `nil`）。且目前所有等级可取的载具完全一样，缺乏进阶扮演感。
3. **空置的扩展属性（部门与辖区）**：
   * 我们自研的 `custom-career` 提供了 `department` (部门/科室) 与 `district` (辖区) 的元数据，但在 `qb-policejob` 中**完全没有使用**。普通警员、特警（SWAT）和刑警（CID）在脚本层无法被区分。
4. **直升机等特殊装备无门槛**：
   * 目前 [client/job.lua:L444-L463](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-policejob/client/job.lua#L444-L463) 允许任何 LSPD 成员在直升机停机坪直接生成警用直升机（ZULU），未验证其是否持有 `pilot` (飞行执照)。

---

## 🛠️ 2. 细化重构规划

### 1) 统一重构证照指令接口 (Sync License Commands)
将警局指令中手写 metadata 的逻辑剥离，全面对接 `custom-certificates` 统一服务接口。

* **修改文件**：[commands.lua](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-policejob/server/commands.lua)
* **具体做法**：
  * 将 `/grantlicense` 的核心逻辑替换为 `exports['custom-certificates']:GrantLicense(targetId, licenseType)`。
  * 将 `/revokelicense` 替换为 `exports['custom-certificates']:RevokeLicense(targetId, licenseType)`。
  * 新增指令：`/suspendlicense [id] [type]`（暂停执照）➔ 调用 `SuspendLicense`。
  * 新增指令：`/reinstatelicense [id] [type]`（恢复执照）➔ 调用 `ReinstateLicense`。
* **效果**：由 `custom-certificates` 统一管理玩家状态和实体证件扣除，确保底层数据原子性。

### 2) 累进解锁车库与飞行许可制 (Garage Progression & Pilot Restriction)
重构车库配置，使警车解锁呈阶梯性，并对直升机进行执照限制。

* **修改文件**：[config.lua](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-policejob/config.lua) 与 [client/job.lua](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-policejob/client/job.lua)
* **阶梯载具配置**：
  ```lua
  Config.AuthorizedVehicles = {
      [0] = { -- 实习警员
          police = 'Vapid Stanier (Recruit Cruiser)',
      },
      [1] = { -- 正式警员
          police2 = 'Buffalo SX (Officer Cruiser)',
          policet = 'Transporter (Prison Transport)',
      },
      [2] = { -- 警司 (Sergeant)
          police3 = 'Interceptor (Highway Patrol)',
          sheriff = 'Sheriff Cruiser (County Patrol)',
      },
      [3] = { -- 副警监 (Lieutenant)
          sheriff2 = 'Sheriff Granger (Utility SUV)',
      },
      [4] = { -- 警长 (Chief)
          fbi = 'Unmarked Granger (Executive Cruiser)',
      }
  }
  ```
* **直升机生成限制**：
  在客户端 `qb-police:client:spawnHelicopter` 事件中引入前置校验：
  ```lua
  local hasPilotLicense = exports['custom-certificates']:HasLicense(GetPlayerServerId(PlayerId()), 'pilot')
  if not hasPilotLicense then
      QBCore.Functions.Notify('错误：你没有飞行执照 (Pilot License)，无法开动警用直升机！', 'error')
      return
  end
  ```

### 3) 部门 (Department) 与辖区 (District) 扮演系统
在警局内部划分子部门与分辖区巡逻，体现专业化分工。

* **部门定义**：
  * `SWAT` (特警组)：负责重型突袭、反恐。
  * `CID` (刑事侦查组/便衣)：负责收集证据、缉毒、卧底。
  * `TRAFFIC` (交通组)：负责超速罚单、高速拦截。
  * `PATROL` (常规巡逻组)：负责日常治安。
* **辖区定义**：
  * `Mission Row` (市区), `Paleto Bay` (北部), `Sandy Shores` (沙漠)。
* **管理指令（警长/副警监可用）**：
  * `/setdept [id] [SWAT/CID/TRAFFIC/PATROL]`：分配部门，调用 `SetPlayerDepartment`。
  * `/setdistrict [id] [MissionRow/Paleto/Sandy]`：分配巡逻辖区，调用 `SetPlayerDistrict`。
* **装备与功能锁定**：
  * **武器库 (Armory)**：Assault Rifle 和 SMG 仅对 `department == 'SWAT'` 的警员开放，常规警员仅能获取 Pistol 与 Shotgun。
  * **更衣室 (Locker)**：SWAT 重型防弹衣与战术服饰仅限 SWAT 部门警员穿着。
  * **便衣执勤 (CID 权限)**：CID 侦发组成员解锁便衣执勤权限，允许在 offduty 状态下使用警用手铐（`/cuff`）与查验指令，并且能提取 unmarked (无标识) 便衣警车。

### 4) 警用 3D 文档查验与互动
* 结合 `custom-documents` 模块，为警察新增 `/checkid [id]` 和 `/checklicense [id]` 指令：
  * 对目标玩家进行空间物理距离检测（确保 < 3.5m 查验距离，防超距作弊）。
  * 警察可当场看到目标玩家投射的 3D ID卡内容，并收到系统的实时许可证状态（如 `SuspendLicense` 会显示其驾照“暂停中”）。
  * 取消繁琐的菜单，通过直观的 3D 文字提示和 F8 审计日志进行核验。

---

## 🚦 3. 讨论与下一步操作

请审核本份**警察职业细化规划**。如果我们达成共识，可以执行以下任一操作：
1. **通过/批准**：您可以表示“**批准本规划**”，我将着手生成 implementation_plan 并进行代码重构。
2. **修改意见**：如果您对部门划分、车辆分配或指令名字有任何修改意见，请直接指出，我会进行调整。
