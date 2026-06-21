# qb-policejob + qb-ambulancejob — 执法与医疗职业

> **状态**: ✅ BOTH ENABLED | **CFG 模块**: police.cfg / medical.cfg

---

## qb-policejob — 警察系统

**路径**: `resources/[qb]/qb-policejob/` | **依赖**: qb-core, qb-inventory, custom-career, custom-certificates, custom-documents

### T-City 安全加固点 (相比原版 qb-policejob)

| 加固 | 位置 |
|:---|:---|
| **Impound** — 添加 `onduty` 检查 + custom-logs 审计 | `server/vehicle.lua:42-48` |
| **TakeOutImpound** — 添加 `onduty` + 10m 距离检查 + DropPlayer | `server/vehicle.lua` |
| **BillPlayer** — 罚款上限 $50K（服务端强制） | `server/main.lua` |
| **SetHandcuffStatus** — 仅 LEO/EMS 可解铐 | `server/main.lua` |
| **License 命令** — 全部委托给 custom-certificates | `server/commands.lua` |
| **SeizeDriverLicense** → `custom-certificates:RevokeLicense` | `server/main.lua` |
| **/checkid, /checklicense** → `custom-documents:server:verifyPlayer` | `server/commands.lua` |
| **Department/District** → `custom-career:SetPlayerDepartment/District` | `server/commands.lua` |

### 敏感事件安全

| 事件 | 操作 | 验证链 |
|:---|:---|:---|
| `police:server:BillPlayer` | 罚款 | 距离 + `job.type == 'leo'` + 服务端金额上限 |
| `police:server:JailPlayer` | 监禁 | 距离 + `job.type == 'leo'` |
| `police:server:SeizeCash` | 没收现金 | 距离 + `job.type == 'leo'` → 转为 moneybag 物品 |
| `police:server:RobPlayer` | 抢劫玩家 | 距离 2.5m → 抢走所有现金 + 打开背包 |
| `police:server:SearchPlayer` | 搜查 | `job.type == 'leo'` + 距离 → 查看背包 + 现金报告 |
| `police:server:SetTracker` | 追踪器 | 距离 2.5m + 异常检测 → DropPlayer |

### 文件
| 文件 | 功能 |
|:---|:---|
| `server/main.lua` | 核心事件：cuff/escort/kidnap/bill/jail/seize/rob/search |
| `server/vehicle.lua` | 车辆管理：impound/takeout/evidence |
| `server/objects.lua` | 物体生成：路障/钉刺带 |
| `server/interactions.lua` | 交互逻辑 |
| `server/commands.lua` | `/spikestrip /impound /checkid /checklicense` 等 |
| `client/main.lua` | 客户端核心 |
| `client/job.lua` | 执勤系统 |
| `client/stolen_radar.lua` | 被盗车辆雷达 |

---

## qb-ambulancejob — 医疗系统

**路径**: `resources/[qb]/qb-ambulancejob/` | **依赖**: qb-core, qb-inventory, custom-career, custom-certificates

### 功能
- 死亡/濒死状态 (`laststand`)
- 治疗/包扎/复苏
- 病床/担架
- EMS 执勤切换

### 与 custom-main 的协作
- `custom-main/client/main.lua` 有死亡自动复活 fallback（qb-ambulancejob 禁用时）
- `custom-main/server/main.lua` 处理死亡元数据清理 (`ResetDeathStatus`)

### 文件
| 文件 | 功能 |
|:---|:---|
| `server/main.lua` | 服务端治疗/死亡逻辑 |
| `config.lua` | 医院位置、药品价格、复活费用 |
| `client/main.lua` | 客户端 UI/交互 |
| `client/job.lua` | 执勤系统 |
