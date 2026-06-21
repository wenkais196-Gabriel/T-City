# 🏛️ T-City 统一组织建立指导手册

> **版本**: v1.0  
> **适用架构**: 统一五级组织模板  
> **最后更新**: 2025-07-15

---

## 目录

1. [核心概念：统一五级模板](#1-核心概念统一五级模板)
2. [快速入门：新建一个职业](#2-快速入门新建一个职业)
3. [快速入门：新建一个帮派](#3-快速入门新建一个帮派)
4. [等级命名规范](#4-等级命名规范)
5. [Tier 层级映射](#5-tier-层级映射)
6. [Boss 管理配置](#6-boss-管理配置)
7. [服装与载具授权](#7-服装与载具授权)
8. [安全规范](#8-安全规范)
9. [退位交接机制](#9-退位交接机制)
10. [完整检查清单](#10-完整检查清单)

---

## 1. 核心概念：统一五级模板

本服所有组织（职业 Job / 帮派 Gang）统一采用 **五级等级制度**：

```
Grade 0 = 实习/学徒     ← 新人，无任何管理权限
Grade 1 = 正式成员       ← 正式成员，基本操作权限
Grade 2 = 小组长         ← 基层管理，可管小团队
Grade 3 = 副部长         ← 高级管理，Boss 的副手
Grade 4 = Boss 👑        ← 最高领导，拥有全部管理权限
```

**关键规则**：
- `isboss = true` **仅**出现于 Grade 4
- 所有组织必须完整定义 0→4 共五个等级
- `none`（无帮派）和 `unemployed`（无业）只保留 Grade 0

---

## 2. 快速入门：新建一个职业

### 步骤 1：定义职业数据

编辑 `qb-core/shared/jobs.lua`，在 `QBShared.Jobs` 表中添加：

```lua
-- === 示例：新建安保公司 / Security ===
security = {
    label = 'Security Corp',
    type = 'security',          -- 可选: 'leo', 'ems', 'mechanic', 或自定义
    defaultDuty = true,         -- 上线是否自动执勤
    offDutyPay = false,         -- 下班是否仍有工资
    grades = {
        ['0'] = { name = 'Trainee', payment = 30 },            -- 实习保安
        ['1'] = { name = 'Security Guard', payment = 50 },     -- 正式保安
        ['2'] = { name = 'Shift Supervisor', payment = 80 },   -- 值班主管
        ['3'] = { name = 'Deputy Chief', payment = 120 },      -- 副总监
        ['4'] = { name = 'Chief of Security', isboss = true, payment = 180 }, -- 总监/Boss
    },
},
```

### 步骤 2：配置 Boss 菜单坐标

编辑 `qb-management/config.lua`，在 `Config.BossMenus` 中添加：

```lua
Config.BossMenus = {
    -- ... 已有职业 ...
    security = {
        vector3(100.0, -1500.0, 30.0),  -- Boss 菜单交互坐标
    },
}
```

> 💡 支持多个坐标（数组），每个坐标都会生成一个 Boss 交互点。

### 步骤 3：配置默认数据

编辑 `qb-core/config.lua`，确认 `PlayerDefaults` 中 job 默认值无误（通常无需修改）：

```lua
job = {
    name = 'unemployed',
    label = 'Civilian',
    isboss = false,
    grade = { name = 'Freelancer', level = 0 }
},
```

### 步骤 4：可选 — 添加 Tier 角色映射

如果你的职业需要出现在 `custom-career` 的层级系统中，编辑 `custom-career/configs.lua`：

```lua
QBConfig.Career.Roles = {
    -- ... 已有 ...
    security = { label = "安保", tiers = {"leader", "mid", "entry"} },
}
```

> ⚠️ 只有 `gang` 角色才有 `"boss"` 层级（含 `godfather` 权限）。普通职业最高到 `"leader"`。

### 步骤 5：可选 — 配置服装

编辑 `qb-clothing/config.lua`，在对应职业下添加 0→4 级的服装：

```lua
['security'] = {
    ['male'] = {
        [0] = { -- 实习
            outfitData = { ... },
        },
        [1] = { -- 正式
            outfitData = { ... },
        },
        -- ... 2, 3, 4 ...
    },
    ['female'] = {
        -- 同上
    },
},
```

### 步骤 6：可选 — 配置载具授权

在你的职业脚本 `config.lua` 中（或 `qb-core/shared/vehicles.lua`）：

```lua
Config.AuthorizedVehicles = {
    [0] = { -- Trainee: 基础巡逻车
        { model = 'securitycar', label = 'Security Patrol' },
    },
    [1] = { -- Guard: 同上
        { model = 'securitycar', label = 'Security Patrol' },
    },
    [2] = { -- Supervisor: + SUV
        { model = 'securitycar', label = 'Security Patrol' },
        { model = 'securitysuv', label = 'Security SUV' },
    },
    [3] = { -- Deputy Chief: + 直升机
        { model = 'securitycar', label = 'Security Patrol' },
        { model = 'securitysuv', label = 'Security SUV' },
        { model = 'securityhelo', label = 'Security Heli' },
    },
    [4] = { -- Chief: 全解锁
        { model = 'securitycar', label = 'Security Patrol' },
        { model = 'securitysuv', label = 'Security SUV' },
        { model = 'securityhelo', label = 'Security Heli' },
        { model = 'securitylimo', label = 'Security Limo' },
    },
}
```

> 💡 载具授权采用"累进解锁"模式：等级越高，可使用的载具越多。客户端代码通过 `for grade = 0, playerGrade` 遍历所有低于当前等级的授权载具。

---

## 3. 快速入门：新建一个帮派

### 步骤 1：定义帮派数据

编辑 `qb-core/shared/gangs.lua`，在 `QBShared.Gangs` 表中添加：

```lua
-- === 示例：新建雅库扎 / Yakuza ===
yakuza = {
    label = 'Yakuza',
    grades = {
        ['0'] = { name = 'Kumi-in' },              -- 組員見習 / 实习
        ['1'] = { name = 'Shatei' },               -- 舎弟 / 正式小弟
        ['2'] = { name = 'Wakagashira-hosa' },     -- 若頭補佐 / 小组长
        ['3'] = { name = 'Wakagashira' },           -- 若頭 / 二把手
        ['4'] = { name = 'Oyabun', isboss = true }, -- 親分 / 组长/Boss
    },
},
```

### 步骤 2：配置帮派 Boss 菜单坐标

编辑 `qb-management/config.lua`，在 `Config.GangMenus` 中添加：

```lua
Config.GangMenus = {
    -- ... 已有帮派 ...
    yakuza = {
        vector3(500.0, -1300.0, 30.0),  -- Boss 据点坐标
    },
}
```

### 步骤 3：配置 Tier 映射

编辑 `custom-career/configs.lua`，确认 `gang` 角色已定义且包含 `"boss"` 层级：

```lua
QBConfig.Career.Roles = {
    gang = { label = "帮派", tiers = {"boss", "leader", "mid", "entry"} },
    -- ...
}
```

> ✅ 所有帮派共享同一个 `gang` 角色定义，无需为每个帮派单独添加。系统通过 `OnGangUpdate` 事件自动将 `lvl >= 4` 的帮派成员映射为 `"boss"` 层级，`lvl >= 2` 为 `"mid"`。

---

## 4. 等级命名规范

### 命名原则

| 原则 | 说明 |
|------|------|
| **组织特色优先** | 优先使用该行业/文化背景中的真实职级名称 |
| **等级递进清晰** | 从 Grade 0 到 Grade 4 应有明显的"权力递增"感 |
| **国际化** | 可使用外语术语（如西班牙语、日语），但确保拼写正确 |
| **简洁** | 每个名称控制在 1-3 个单词内 |

### 参考模板

#### 蓝领/技工类（mechanic, beeker, bennys）

```
0 = Apprentice     ← 学徒
1 = Technician     ← 技工
2 = Specialist     ← 专修技师
3 = Shop Foreman   ← 车间领班
4 = Shop Owner 👑  ← 店主
```

#### 交通运输类（bus, trucker, tow, taxi）

```
0 = Trainee            ← 实习司机
1 = Driver/Operator    ← 正式司机
2 = Senior Driver      ← 资深司机
3 = Supervisor/Dispatcher ← 主管/调度
4 = Manager 👑         ← 经理
```

#### 政府/司法类（mayor, judge, lawyer）

```
0 = Intern/Clerk     ← 实习/助理
1 = Clerk/Counsel    ← 办事员/顾问
2 = Supervisor/Magistrate ← 主管/地方法官
3 = Deputy ~         ← 副职
4 = Chief/Mayor 👑   ← 正职
```

#### 街头帮派（ballas, families, vagos）

```
0 = 小喽啰 (Tiny/Youngster/Chavala)
1 = 正式帮众 (Soldier/Hustler/Soldado)
2 = 小队头目 (Lieutenant/Big Homie/Jefe de Calle)
3 = 二当家 (Underboss/Subjefe)
4 = 大头目 👑 (Kingpin/Godfather/El Padrino)
```

#### 有组织犯罪（cartel, mafia, yakuza）

```
0 = 外围/探子 (Halcon/Associate)
1 = 正式成员 (Sicario/Made Man)
2 = 堂口主管 (Jefe de Plaza/Caporegime)
3 = 副手 (Subteniente/Underboss)
4 = 首领 👑 (El Jefe/Don)
```

---

## 5. Tier 层级映射

`custom-career` 系统维护一个全局 `rank_tier` 字段，用于跨职业的权限判断。

### 映射规则

```
触发时机: QBCore:Server:OnJobUpdate   → 自动映射 job  tier
触发时机: QBCore:Server:OnGangUpdate  → 自动映射 gang tier
触发时机: playerLoaded                → 从 DB 加载 + 自愈修正
```

| 组织类型 | Grade ≥ 4 | Grade ≥ 2 | 默认 |
|----------|----------|----------|------|
| **Gang** | `"boss"` | `"mid"` | `"entry"` |
| **Job** | `"leader"` | `"mid"` | `"entry"` |

### Tier 权限

| Tier | 标签 | 权限 |
|------|------|------|
| `boss` | 教父 | `kpi_terminal`, `catalyst`, `godfather` |
| `leader` | 领袖 | `kpi_terminal`, `catalyst` |
| `mid` | 中层 | `dept_manage` |
| `entry` | 基层 | *(无特殊权限)* |

### 手动覆写

如需手动调整某玩家的 Tier（例如跨职业提拔或降级）：

```lua
-- 将玩家提升为 boss 层级
exports['custom-career']:SetPlayerTier(src, 'boss')

-- 查询玩家当前层级
local identity = exports['custom-career']:GetPlayerIdentity(src)
print(identity.rank_tier)  -- "boss", "leader", "mid", "entry"
```

---

## 6. Boss 管理配置

### 自动注册

所有在 `shared/jobs.lua` 和 `shared/gangs.lua` 中定义的职业/帮派，只要其 Grade 4 标记了 `isboss = true`，即可自动接入 Boss 管理系统。无需额外注册。

### 菜单系统

Boss 菜单由两套系统并行提供：

| 系统 | 文件 | 说明 |
|------|------|------|
| **新统一系统** | `cl_org.lua` + `sv_org.lua` | 自适应职业/帮派，含退位交接 |
| **旧向后兼容** | `cl_boss.lua` + `sv_boss.lua` | 职业专用（旧事件名保留） |
| **旧向后兼容** | `cl_gang.lua` + `sv_gang.lua` | 帮派专用（旧事件名保留） |

### 菜单功能

```
Boss 菜单
├─ 管理成员     → 成员列表 → [升级/降级] [开除]
├─ 招募成员     → 附近10m内玩家列表
├─ Boss 仓库    → 组织公共仓库（25格/4000kg）
├─ 更衣室       → 职业/帮派服装
├─ 🔑 退位交接  → 选择接班人 → 确认 → 原子交接
└─ 退出
```

### 动态菜单扩展

第三方插件可通过 export 向 Boss 菜单注入自定义选项：

```lua
-- 客户端注入
local menuId = exports['qb-management']:AddOrgMenuItem({
    header = '💊 非法交易',
    txt = '查看当前市场价格',
    icon = 'fa-solid fa-pills',
    params = {
        event = 'my-drug-plugin:client:OpenMarket',
    }
})

-- 移除
exports['qb-management']:RemoveOrgMenuItem(menuId)
```

---

## 7. 服装与载具授权

### 服装系统

`qb-clothing/config.lua` 中按 `[jobName][gender][grade]` 组织：

```lua
Config.Outfits = {
    ['police'] = {
        ['male'] = {
            [0] = { outfitData = { ... } },  -- Recruit 服装
            [1] = { outfitData = { ... } },  -- Officer 服装
            [2] = { outfitData = { ... } },  -- Sergeant 服装
            [3] = { outfitData = { ... } },  -- Lieutenant 服装
            [4] = { outfitData = { ... } },  -- Chief 服装
        },
        ['female'] = {
            -- 同上
        },
    },
}
```

> ⚠️ 必须覆盖全部 5 个等级（0-4），否则低等级或高等级成员无法使用更衣室。

### 载具授权

两种模式均可使用：

**A) 累进解锁（推荐）**：每个等级列出该等级**新增**的载具，客户端代码遍历 `0→playerGrade` 汇总：

```lua
Config.AuthorizedVehicles = {
    [0] = { { model = 'car1', label = 'Basic' } },
    [1] = { { model = 'car2', label = 'Better' } },
    [2] = { { model = 'car3', label = 'Advanced' } },
    [3] = { { model = 'car4', label = 'Elite' } },
    [4] = { { model = 'car5', label = 'Boss' } },
}
```

**B) 完整枚举**：每个等级列出该等级能用的**全部**载具：

```lua
Config.AuthorizedVehicles = {
    [0] = { { model = 'car1', label = 'Basic' } },
    [1] = { { model = 'car1', label = 'Basic' }, { model = 'car2', label = 'Better' } },
    -- ...
}
```

---

## 8. 安全规范

### Boss 操作安全校验

所有 Boss 管理事件（晋升、降级、开除、招募、退位交接）均包含以下校验链：

| 校验项 | 说明 | 失败后果 |
|--------|------|----------|
| `isboss == true` | 操作者必须是 Grade 4 Boss | `ExploitBan` 永久封禁 |
| 不能操作自己 | 开除自己 → 提示走退位交接 | 提示 + 拒绝 |
| 不能越级操作 | Boss 不能晋升成员到比自己高的等级 | 提示 + 拒绝 |
| 接班人校验 | 必须在同组织、在线、非 Boss | 提示 + 拒绝 |
| 原子交接 | 先升后降，降失败自动回滚 | 提示 + 回滚 |

### 数据库安全

所有数据库查询均使用**参数化查询**，杜绝 SQL 注入：

```lua
-- ✅ 正确
MySQL.query.await('SELECT * FROM players WHERE JSON_UNQUOTE(JSON_EXTRACT(job, "$.name")) = ?', { jobName })

-- ❌ 禁止
MySQL.query.await('SELECT * FROM players WHERE job LIKE "%' .. jobName .. '%"')
```

### 客户端事件安全

涉及金钱、物品、职位变更的 Server 端事件**必须**校验 `source`：

```lua
RegisterNetEvent('my-event:server:doSomething', function(...)
    local src = source  -- ⚠️ 必须使用 source，不可信任客户端参数
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    -- ...
end)
```

---

## 9. 退位交接机制

### 流程

```
Boss 打开菜单 → 🔑 Transfer Ownership
  → 显示同组织在线非 Boss 成员列表
  → 选择接班人 → ⚠️ 不可逆确认弹窗
  → Server 原子执行:
     ┌─ Step 1: 接班人.SetJob/Gang(orgName, 4)  ← 先升为 Boss
     ├─ Step 2: 原Boss.SetJob/Gang(unemployed/none, 0)  ← 后退出
     └─ Step 2 失败 → 自动回滚 Step 1
  → 双方通知 + 审计日志
```

### 事件接口

| 事件 | 参数 | 说明 |
|------|------|------|
| `qb-orgmenu:server:TransferOwnership` | `{ successorCid, orgName }` | 统一事件（推荐） |
| `qb-bossmenu:server:TransferOwnership` | `{ successorCid, orgName }` | 职业旧命名空间 |
| `qb-gangmenu:server:TransferOwnership` | `{ successorCid, orgName }` | 帮派旧命名空间 |

### 必要条件

- 操作者：Grade 4 `isboss == true`
- 接班人：在线 + 同组织 + 非 Boss
- 不可传给自己
- 操作**不可逆**（有确认弹窗）

---

## 10. 完整检查清单

新建一个组织时，逐项勾选：

---

### ☐ 数据定义

- [ ] `shared/jobs.lua` 或 `shared/gangs.lua` 中添加组织定义
- [ ] Grade 0-4 五个等级全部定义
- [ ] Grade 4 标记 `isboss = true`
- [ ] Grade 4 标记 `payment = <最高工资>`
- [ ] 等级名称符合组织特色，递进清晰
- [ ] 设置 `defaultDuty = true`（职业）或无需设置（帮派）

### ☐ Tier 映射

- [ ] 如果是帮派：确认 `gang` 角色在 `custom-career/configs.lua` 中包含 `"boss"` 层级
- [ ] 如果是新角色类型（非 gang 非现有 role）：在 `custom-career/configs.lua` 的 `Roles` 中添加

### ☐ Boss 菜单

- [ ] 在 `qb-management/config.lua` 的 `Config.BossMenus` 或 `Config.GangMenus` 中添加坐标
- [ ] 坐标指向实际场景中的 Boss 办公室/据点位置
- [ ] 测试：以 Grade 4 Boss 身份走到坐标点，确认菜单可交互

### ☐ 服装（可选）

- [ ] 在 `qb-clothing/config.lua` 中添加 `[male]` 和 `[female]` 各 5 套服装
- [ ] 测试：Boss 菜单 → 更衣室，确认所有等级均可正常换装

### ☐ 载具（可选）

- [ ] 在职业脚本配置中定义 `AuthorizedVehicles[0..4]`
- [ ] 确认累进解锁逻辑正确（高等级 = 更多载具）

### ☐ 门禁（可选）

- [ ] 在 `qb-doorlock` 配置中添加该组织的门禁权限
- [ ] 使用动态最小等级门槛，而非硬编码

### ☐ 安全审计

- [ ] 所有涉及该组织的 Server 事件使用 `source` 校验
- [ ] 无 SQL 字符串拼接
- [ ] 金钱/物品/职位变更使用 `Bus.SecurityService` 清洗

### ☐ 测试

- [ ] 管理员 `/setjob [id] [jobName] 4` 设置为 Boss → 打开 Boss 菜单
- [ ] 招募一名普通玩家 → 该玩家 Grade 变为 0
- [ ] 晋升/降级 → 等级变更生效
- [ ] 开除 → 玩家变回 `unemployed`/`none`
- [ ] 🔑 退位交接 → 接班人变为 Grade 4 Boss，原 Boss 变为 `unemployed`/`none`
- [ ] 确认弹窗 → 取消不执行
- [ ] 非 Boss 玩家无法打开 Boss 菜单

---

## 附录 A：完整职业等级速查表

| 职业 | Grade 0 | Grade 1 | Grade 2 | Grade 3 | Grade 4 👑 |
|------|---------|---------|---------|---------|-----------|
| police | Recruit | Officer | Sergeant | Lieutenant | Chief |
| ambulance | Recruit | Paramedic | Doctor | Surgeon | Chief |
| taxi | Recruit | Driver | VIP Driver | Fleet Supervisor | Manager |
| cardealer | Trainee | Showroom Sales | Business Sales | Finance | Dealer Principal |
| mechanic* | Apprentice | Technician | Specialist | Shop Foreman | Shop Owner |
| realestate | Trainee | House Sales | Business Sales | Broker | Agency Owner |
| mayor | Intern | Clerk | Supervisor | Deputy Mayor | Mayor |
| judge | Law Clerk | Associate Counsel | Magistrate | District Judge | Chief Justice |
| lawyer | Paralegal | Junior Associate | Senior Associate | Partner | Managing Partner |
| reporter | Intern | Reporter | Senior Reporter | Editor | Editor-in-Chief |
| bus | Trainee | Driver | Senior Driver | Route Supervisor | Depot Manager |
| trucker | Trainee | Driver | Senior Driver | Dispatcher | Logistics Manager |
| tow | Trainee | Operator | Senior Operator | Supervisor | Manager |
| garbage | Trainee | Collector | Crew Leader | Route Supervisor | Operations Manager |
| vineyard | Seasonal Worker | Vineyard Worker | Cellar Hand | Winemaker | Vineyard Owner |
| hotdog | Trainee | Vendor | Shift Lead | Area Manager | Franchise Owner |

## 附录 B：完整帮派等级速查表

| 帮派 | Grade 0 | Grade 1 | Grade 2 | Grade 3 | Grade 4 👑 |
|------|---------|---------|---------|---------|-----------|
| lostmc | Prospect | Patch Member | Road Captain | Vice President | President |
| ballas | Tiny | Soldier | Lieutenant | Underboss | Kingpin |
| vagos | Chavala | Soldado | Jefe de Calle | Subjefe | El Padrino |
| cartel | Halcon | Sicario | Jefe de Plaza | Subteniente | El Jefe |
| families | Youngster | Hustler | Big Homie | Underboss | Godfather |
| triads | Blue Lantern | 49 Boy | Red Pole | White Paper Fan | Dragon Head |

## 附录 C：修改文件速查

| 要做什么 | 改哪个文件 |
|----------|-----------|
| 新增/修改职业等级 | `qb-core/shared/jobs.lua` |
| 新增/修改帮派等级 | `qb-core/shared/gangs.lua` |
| 新增 Boss 菜单坐标 | `qb-management/config.lua` |
| 新增/修改服装 | `qb-clothing/config.lua` |
| 新增/修改载具授权 | 对应职业脚本的 `config.lua` |
| Tier 角色/权限定义 | `custom-career/configs.lua` |
| Tier 自动映射逻辑 | `custom-career/server/main.lua` |
| Boss 管理服务端 | `qb-management/server/sv_org.lua`（新）或 `sv_boss.lua`/`sv_gang.lua`（旧） |
| Boss 管理客户端 | `qb-management/client/cl_org.lua`（新）或 `cl_boss.lua`/`cl_gang.lua`（旧） |
| 门禁权限 | `qb-doorlock` 配置 |
| 商店购买权限 | `qb-shops` 配置 |
