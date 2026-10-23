# T-City角色扮演核心任务设计与场景装配手册 (v2.0 — 经济与小游戏闭环版)

本手册基于**行为经济学**与**微服务架构设计标准**制定。我们使用系统已有的 5 大原子节点（`GOTO`、`INTERACT`、`DELIVER`、`COMBAT`、`WAIT`）为积木，为 T-City 规划一套高度可控的资本经济模型、模块化小游戏接口、以及打破“自给自足”的部门统筹采购维护体系。

---

## 🏛️ 1. 金钱资本主导型经济循环机制

为了确保服务器经济的绝对可控性，防止物品无限产出带来的通货膨胀，我们确立了**以金钱资本流动为主导**的资源模型：

```
           [ 玩家劳动 (环卫/采矿/巡逻) ]
                       │
                       ▼
           [ 产出物品 (垃圾/矿石/证物) ] 
                       │
                       ▼ (DELIVER 节点 100% 强制回收)
           [ 系统回收站 (System Sink) ] ──(获得金钱)──► [ 玩家个人账户 ]
                                                             │
                                                             ▼ (资本流动消费)
   [ 购买载具/配件/服务 ] ◄──(金钱消费)─── [ 购买系统物资/加工服务 ]
```

* **系统强制回收制 (System Sink)**：
  * 玩家参与日常劳动（环卫、采矿等）产出的额外物品，通过任务系统的 `DELIVER` 节点以 **100% 消耗（`consume = true`）** 的方式移交给系统。系统作为庄家提供唯一的结算出口（Faucet），转化为金钱资本。
* **资本二次消费与流转**：
  * 玩家使用结算到的资金去购买服务器内的服务与加工原料。这大幅减少了实体物品在玩家之间的离线物物交换囤积，让所有资源交互都留有交易日志，便于管理员调控宏观经济。

---

## 2. qb-minigames 小游戏库审计与精简建议

通过对项目文件 [qb-minigames](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-minigames) 的扫描，我们整理出可供 `INTERACT` 节点调用的基础小游戏，并提出优化建议：

### 2.1 现有小游戏素材盘点
| 小游戏名称 | 导出路径 (Export) | 建议用途 | 沉浸感评估 (RP Value) |
| :--- | :--- | :--- | :--- |
| **锁匠 (Lockpick)** | `exports['qb-minigames']:Lockpick(pins)` | 车门锁破解、金库锁破解 | ⭐⭐⭐⭐⭐ (极高) |
| **安全终端 (Hacking)** | `exports['qb-minigames']:Hacking(size, time)` | 车载电脑 ECU 解密、终端拷贝 | ⭐⭐⭐⭐⭐ (极高) |
| **QTE 读条 (Skillbar)** | `exports['qb-minigames']:Skillbar(diff, keys)` | 紧急维生、现场包扎、垃圾压实 | ⭐⭐⭐⭐ (高) |
| **密码盘 (Pinpad)** | `exports['qb-minigames']:Pinpad(...)` | 保险箱密码输入、门禁破解 | ⭐⭐⭐⭐ (高) |
| **数字按键 (Keyminigame)**| `exports['qb-minigames']:Keyminigame(...)` | 机械结构解锁 | ⭐⭐⭐ (中) |

### 2.2 删减与补充建议
* **建议精简（禁用）**：`quiz`（问答）、`wordguess`（猜单词）、`wordscramble`（字母拼盘）。这类纯文字/智力类游戏在 RP 任务中会严重打破沉浸感（跳戏），建议在任务配置中**永久屏蔽**，仅保留具备物理操作联想的小游戏（如 Lockpick, Skillbar）。
* **任务适配器设计**：
  在客户端适配器中建立 `MinigameAdapter` 统一调用口，隔离直接调用 `qb-minigames` 的实现：
  ```lua
  -- client/adapters.lua
  MinigameAdapter = {
      Play = function(gameType, params)
          if gameType == 'lockpick' then
              return exports['qb-minigames']:Lockpick(params.pins or 3)
          elseif gameType == 'hacking' then
              return exports['qb-minigames']:Hacking(params.size or 4, params.time or 10)
          elseif gameType == 'skillbar' then
              return exports['qb-minigames']:Skillbar(params.difficulty or 'easy', params.keys)
          end
          return true -- 默认放行
      end
  }
  ```

---

## 3. 组织部门经济统筹系统 (防止自给自足)

公职部门（PD、EMS、市政等）的任务不再采取传统的“魔法凭空生成车辆（Temp Spawner）”或者“开私家车执勤”模式。我们设计一套**部门公共采购与损耗折旧系统**，通过资金杠杆强制拉动部门之间的社会化合作。

### 3.1 部门财政与车辆生命周期流程

```
 ┌────────────────┐
 │ 部门财政金库  │ ◄──(税收/市长拨款)── [ 市政厅统一拨款 ]
 └───────┬────────┘
         │ (资金划拨采购)
         ▼
 ┌────────────────┐
 │ 商业车辆销售商 │ ──(选定车型, 扣除金库资金)──► [ 登记到部门名下(Fleet DB) ]
 └────────────────┘                                           │
                                                              ▼
 ┌────────────────┐                                   ┌───────────────┐
 │  维修技工中心  │ ◄───(支付金库/个人资金进行维修)────┤ 车辆执行任务  │ (产生物理耗损)
 └────────────────┘                                   └───────────────┘
```

1. **统一采购制 (Department Fleet)**：
   * 警员/医生无权通过任务命令生成执勤车辆。所有的警车与救护车，必须由部门高层（PD局长、医院院长）使用**部门公共账户 (Department Vault)** 的预算，向商业载具销售商（或政府集中采购平台）支付采购。
   * 车辆一经采购，其 NetID、车牌号和车辆型号将永久注册入该部门的“公用舰队数据库（Department Fleet DB）”。
2. **物理耗损与社会化维护 (Maintenance Sinks)**：
   * 执勤车辆拥有长周期的“引擎状况”、“轮胎磨损”、“车身完整度”以及“燃油”数据。
   * **维修壁垒**：公职人员无法使用管理员指令修复车辆。当车辆损耗过大时，警员/医护必须前往**私人或公共维修厂（Mechanics）**。
   * **资金流动**：维修费用由部门公账报销（或执勤人员垫付），将资金从公职部门转移到私营技工手中，拉动技工行业的就业与活跃，彻底杜绝自给自足的闭环。

### 3.2 任务流程的适配器改造 (以警员巡逻为例)

在 `VALIDATOR` 节点中，重构车辆验证逻辑，不仅校验载具 Class，还要校验是否属于部门公车库：

```lua
-- server/quest_logistics_validators.lua

local function validate_department_vehicle(src, stepData, questData)
    local Player = QBCore.Functions.GetPlayer(src)
    local jobName = Player.PlayerData.job.name -- 'police' or 'ambulance'
    local vehNetId = questData.vehicleNetId
    
    local vehInfo = getPlayerVehicle(src, vehNetId)
    if not vehInfo then
        return false, "你必须在一辆载具中进行验证"
    end

    -- 校验该车牌是否登记在所属 job 的 Fleet 库中
    local isFleetVehicle = false
    local p = promise.new()
    
    -- 从数据库查询公用载具表
    MySQL.query('SELECT plate FROM department_fleet WHERE job = ? AND plate = ?', {
        jobName, vehInfo.plate
    }, function(result)
        isFleetVehicle = result and #result > 0
        p:resolve(isFleetVehicle)
    end)
    
    Citizen.Await(p)
    
    if not isFleetVehicle then
        return false, ("验证失败！此车 [%s] 不属于 %s 部门的公用编队车辆"):format(vehInfo.plate, jobName:upper())
    end

    return true, "✅ 部门公车绑定成功，执勤记录已激活"
end
```

### 3.3 任务收益的统筹分成设计 (Public-Funding Faucet)
公职人员完成任务（如完成一次急救运送或巡逻拦截）产生的金钱收益，采取**“分成模型”**：
* **个人津贴 (80%)**：直接进入个人银行账户，奖励玩家的劳动力。
* **部门储备金 (20%)**：自动划拨到该部门的 `qb-management` 公共账户中。这笔资金将作为部门未来**采购新警车、报销维修账单、加油**的储备金，形成了“完成任务 $\rightarrow$ 部门充能 $\rightarrow$ 购买/维护更好装备 $\rightarrow$ 做更多任务”的正向团队合作轮转。
