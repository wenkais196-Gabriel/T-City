# ⚙️ T-City Lite Career (职业身份) 系统重构技术方案

> **适用版本**: v0.6 - v1.0+  
> **核心特性**: 模块化、高性能、高安全、可拓展  
> **文档定位**: 作为整个 Career 体系及其下属所有职业深化的**总技术指导规范**。

---

## 🏛️ 1. 架构拓扑与交互模型 (Architecture & Topology)

重构后的 Career 系统采用“微内核 + 插件式”架构。`custom-career` 作为核心数据总线与认证核，其他职业脚本作为子功能模块（插件）向核心核注册与通信。

```
                       ┌──────────────────────────────┐
                       │   数据持久化层 (MariaDB / SQL) │
                       └──────────────▲───────────────┘
                                      │ (异步批量写入)
                       ┌──────────────┴───────────────┐
                       │  custom-career 核心缓存引擎   │
                       └──────────────┬───────────────┘
                                      │
              ┌───────────────────────┼───────────────────────┐
              │ (State Bags / 内存缓存)│ (Exports / API 比对)   │ (事件总线)
              ▼                       ▼                       ▼
   ┌────────────────────┐   ┌────────────────────┐   ┌────────────────────┐
   │    LSPD 警察模块   │   │  EMS 医疗救援模块  │   │  平民/供应链模块   │
   │ (警衔/部门/特警装备) │   │ (科室/飞行救护/复活)│   │ (矿工/货运/垃圾任务)│
   └────────────────────┘   └────────────────────┘   └────────────────────┘
              ▲                       ▲                       ▲
              └───────────────────────┼───────────────────────┘
                                      │ (调用)
                       ┌──────────────┴───────────────┐
                       │      证书与文档投射系统       │
                       │   (custom-certificates)      │
                       └──────────────────────────────┘
```

---

## 🛠️ 2. 重构设计规范

### 1) 模块化设计 (Modularity)
* **核心与业务解耦**：
  * `custom-career` **只做三件事**：玩家身份内存缓存、组织结构定义、组织/阶层/证书比对服务。
  * **职业特定逻辑**：如警察的警用雷达、机修工的车辆改色、垃圾工的垃圾箱位置，必须封装在各自独立的资源中，严禁写入 `custom-career` 核心内。
* **微服务化注册**：
  子职业通过 export 动态查询身份标记，不直接读写彼此的数据库或内存变量：
  ```lua
  -- 示例：警员武器库通过 Tag API 进行授权校验
  local hasAccess = exports['custom-career']:PlayerMatchesTags(source, {
      org = "lspd",
      department = "SWAT",
      tier = "mid"
  })
  ```

### 2) 高性能设计 (High Performance)
* **零延迟读取 (State Bags)**：
  * 废除所有高频循环（如 `Wait(0)` 级的 Tick）中对 Lua 跨资源 export 接口的调用。
  * 玩家的职业身份完整数据（包含 org_id, rank_tier, department, district, certs）统一缓存于 **Player State Bag**：`Player(src).state.career_identity`。
  * 客户端可以通过全局只读变量 `LocalPlayer.state.career_identity` 随时、零开销、无延迟地读取自身属性。
* **异步双重存盘管道**：
  * 职业标记和证书的变更，先写入服务器的内存缓存，并通过 State Bag 同步给客户端，实现界面秒开和即时交互。
  * 数据库的写入全部采用异步 `MySQL.query.await`，并排队放入 60s 定时批量刷盘队列，杜绝同步阻塞（Sync Query）造成的服务器掉帧。

### 3) 高安全设计 (Security & Antispoof)
* **服务端绝对权威**：
  * 客户端的 State Bag 是只读的，任何职级提升、部门变更或证书吊销必须由**服务端事件**发起，并由 `custom-career` 进行签名和持久化。
  * 严禁客户端上报“我的工资是 $500”这类带有结算乘数或金额的数据。所有经济结算仅通过任务 Nonce 机制路由至 `AddScaledMoney`。
* **防刷与流控守护**：
  * 针对执勤状态切换（`/duty`）、领取警用车等操作，在服务端设置基于时间滑动窗口的 Rate Limiter。
  * **物理空间围栏**：所有交互点（更衣室、车库、武器库）在服务端处理请求时，必须使用物理距离检验：
    ```lua
    local ped = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(ped)
    local dist = #(playerCoords - Config.Locations['armory'][stationId])
    if dist > 5.0 then
        -- 触发安全审计日志，疑似使用外挂注入事件
        exports['custom-main']:LogSecurity(src, "武器库物理距离异常", dist)
        return
    end
    ```

### 4) 可扩展性 (Extensibility & Future-Proof)
* **支持多角色并存 (Multi-Role Tagging)**：
  * 玩家在拥有主职业（如 LSPD 警察）的同时，还可以拥有副职业（如市议员）或非法身份（帮派成员）。
  * 重构后，元数据中的 `certs` 采用 JSON 数组设计，支持玩家同时持有多个许可证（如同时拥有 `pilot` 和 `heavy` 驾驶证）。
* **动态属性插槽 (Dynamic Metadata Slots)**：
  * 保留属性插槽 `department` 与 `district`，并为未来扩展（如声望值 `rep`、工时统计 `work_hours`）预留 JSON 扩展字段。
  * 升级兼容层（Legacy Shim）：拦截旧有 QBCore 的 `QBCore:Server:OnJobUpdate` 事件，自动解析并同步状态至 `custom-career` 缓存，实现老旧第三方脚本的“无缝接入”。

---

## 📅 3. 多职业与单职业深化路线图

| 实施阶段 | 职业/模块 | 架构深化点 | 扮演体验提升点 |
| :--- | :--- | :--- | :--- |
| **Stage 1** | **警察与医护重构**<br>(Police & EMS) | 1. 接入 `department` 与 `certs`。<br>2. 限制特种载具（如直升机）的飞行执照。<br>3. 重构执照吊销命令至证书系统。 | 划分 SWAT/CID 科室；启用 LSPD 专业化执勤与 3D 文档查验。 |
| **Stage 2** | **工业与平民物流**<br>(Miner & Trucker) | 1. 自研轻量级 `custom-mining`。<br>2. 引入 `heavy_license` 重载货运车钥匙限制。<br>3. 将物流路线接入手机 Job Board。 | 强制城郊往返，打通原材料流向。 |
| **Stage 3** | **市政与司法治理**<br>(Mayor, Judge, Lawyer) | 1. 挂接市长公共财政与项目发布。<br>2. 法院指令联动物理驾照吊销。<br>3. 律师执业证件的 3D 悬浮验证。 | 打造“法警联动”、“市政工程建设”的闭环 RP 体验。 |
| **Stage 4** | **常规公共服务**<br>(Taxi, Bus, Tow, Garbage) | 1. 全面移除 legacy 臃肿轮询。<br>2. 统一用 `custom-quest` 状态机包装。<br>3. 自动计算社会组织 KPI。 | 玩家通过手机一键执勤，流程可视化，减少内存消耗。 |

---

## 🚦 4. 重构验证标准 (Evaluation Metrics)

1. **零 Tick 延迟**：客户端读取身份元数据必须在 0ms 内（直接读取内存 State Bag），无 export 跨资源通信造成的画面卡顿。
2. **零同步阻塞**：重构后的代码中，不允许存在任何 `MySQL.Sync` 字样，必须全部为 `MySQL.query.await` 或异步回调。
3. **安全拦截率 100%**：客户端伪造事件触发（如隔空刷车、非 SWAT 成员刷长枪）在服务端必须被物理坐标和 Career Tags 判定拦截，并自动生成 Webhook 记录。
