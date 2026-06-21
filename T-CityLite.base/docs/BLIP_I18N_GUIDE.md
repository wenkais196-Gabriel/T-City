# 地图 Blip 配置与本地化 — 技术文档

> **版本**: v1.0  
> **最后更新**: 2025-07  
> **涉及资源**: `qb-core`, `qb-mapsidebar`, `production-freeze`, `qb-management`

---

## 📋 目录

1. [架构概览](#1-架构概览)
2. [文件清单](#2-文件清单)
3. [数据流](#3-数据流)
4. [添加新 Blip 分类](#4-添加新-blip-分类)
5. [添加新 Locale Key](#5-添加新-locale-key)
6. [侧边栏 NUI 资源](#6-侧边栏-nui-资源)
7. [场景速查](#7-场景速查)
8. [Blip 显示行为控制](#8-blip-显示行为控制)
9. [故障排查](#9-故障排查)

---

## 1. 架构概览

```
┌──────────────────────────────────────────────────────────────┐
│                    数据定义层 (Config)                         │
│  qb-core/config_blips.lua                                    │
│  → Config.BlipCategories = { category_key = { items[] } }    │
│  → 每个 item 只存 localeKey + coords，不存硬编码文本          │
└──────────────────────────┬───────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                    翻译层 (i18n)                               │
│  production-freeze/locales/locales.lua                       │
│  → { zh = '卡特尔总部', en = 'Cartel HQ' }                    │
│  production-freeze/client/i18n.lua                           │
│  → _L('blip_cartel_hq') → 按玩家 GTA5 语言自动返回 zh/en     │
└──────────────────────────┬───────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                 客户端管道 (Client Pipeline)                   │
│  qb-mapsidebar/client/main.lua                               │
│  → BuildBlipPayload() 收集 Config.BlipCategories            │
│  → T(key) 调用 _L() 解析为真实文本                           │
│  → SendNUIMessage → NUI                                      │
└──────────────────────────┬───────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                  前端渲染 (NUI)                                │
│  qb-mapsidebar/html/map_sidebar.html + .css + .js            │
│  → 按 F9 打开侧边栏                                          │
│  → 分类折叠显示 · <> 切换子项 · 📍 GPS 定位                   │
└──────────────────────────────────────────────────────────────┘
```

---

## 2. 文件清单

| 文件 | 位置 | 角色 |
|------|------|------|
| `config_blips.lua` | `[qb]/qb-core/` | **唯一配置入口** — 所有 Blip 分类和子项 |
| `locales.lua` | `[system]/production-freeze/locales/` | **统一语言包** — 所有 blip 的 `{ zh, en }` 键值对 |
| `i18n.lua` | `[system]/production-freeze/client/` | **翻译引擎** — `_L(key)` 运行时解析 |
| `main.lua` | `[qb]/qb-mapsidebar/client/` | **管道脚本** — 收集、翻译、发送数据给 NUI |
| `map_sidebar.html` | `[qb]/qb-mapsidebar/html/` | NUI 页面 |
| `map_sidebar.css` | `[qb]/qb-mapsidebar/html/css/` | NUI 样式 (含 Noto Sans SC 中文字体) |
| `map_sidebar.js` | `[qb]/qb-mapsidebar/html/js/` | NUI 交互逻辑 |
| `fxmanifest.lua` | `[qb]/qb-mapsidebar/` | 资源声明 (dependency: qb-core + production-freeze) |
| `cl_gang.lua` | `[qb]/qb-management/client/` | 帮派成员专属 Blip (cartel/ballas/families/lostmc/vagos) |

### 其他使用 `_L()` 的 Blip 文件

这些文件中的 Blip 名称也已统一使用 `_L()`，不需要单独维护：

| 文件 | Locale Key |
|------|-----------|
| `qb-drugs/client/cornerselling.lua` | `blip_drugs_buyer` |
| `qb-jewelery/client/main.lua` | `blip_vangelico_jewelry` |
| `qb-recyclejob/client/main.lua` | `blip_recycle_center` |
| `qb-smallresources/client/carwash.lua` | `blip_carwash` |
| `qb-storerobbery/client/main.lua` | `blip_surrender` |
| `qb-truckrobbery/client/main.lua` | `blip_truckrobbery_assault` / `_10_90` / `_van` |
| `qb-vineyard/client.lua` | `blip_vineyard_dropoff` |
| `custom-quest/client/main.lua` | `blip_quest_target` |
| `atom_nodes/client/main.lua` | `blip_atom_target` |
| `custom-justice/client/main.lua` | `blip_courthouse` / `blip_state_prison` |
| `custom-mining/client/main.lua` | `blip_quarry` / `blip_mountain` / `blip_desert` / `blip_coast` / `blip_smelter` |
| `custom-main/client/dispatch.lua` | `blip_wanted_suspect` |

---

## 3. 数据流

### 3.1 侧边栏（按 F9）

```
1. 玩家按下 F9
2. main.lua: BuildBlipPayload()
   ├── 遍历 Config.BlipCategories
   ├── 对每个 item.localeKey 调用 T(key)
   │   ├── 优先: _L(nil, key) → 按 GetCurrentLanguage() 选 zh/en
   │   └── 降级: Lang:t(key) 或 key 本身
   └── 组装为 { id, label, icon, items: [{ name, coords }] }
3. SendNUIMessage({ action:'mapSidebar:open', categories })
4. NUI 渲染: 警察局 < 1 / 4 > 📍
```

### 3.2 帮派原生 Blip（加入帮派时自动显示）

```
1. 玩家加入帮派 → QBCore:Client:OnGangUpdate 触发
2. cl_gang.lua: UpdateGangBlips()
   ├── 遍历 5 个帮派
   └── AddTextComponentSubstringPlayerName(_L('blip_cartel_hq'))
       → GTA5 原生地图上显示 "卡特尔总部" 或 "Cartel HQ"
```

### 3.3 其他游戏 Blip（运行时动态创建）

```
各脚本直接调用 _L():
  BeginTextCommandSetBlipName("STRING")
  AddTextComponentSubstringPlayerName(_L('blip_wanted_suspect', name, stars))
  EndTextCommandSetBlipName(blip)
  → 中文玩家看到 "【通缉犯】张三 (3星)"
  → 英文玩家看到 "【WANTED】Zhang San (3 stars)"
```

---

## 4. 添加新 Blip 分类

### Step 1: 在 `config_blips.lua` 添加 Category

```lua
-- 示例: 添加"银行"分类
Config.BlipCategories.banks = {
    localeKey   = 'blip_cat_banks',          -- ★ 必须先到 locales.lua 创建此键
    icon        = 'fa-solid fa-building-columns',
    blipSprite  = 108,                        -- 银行图标
    blipColor   = 2,                          -- 绿色
    items = {
        B { localeKey = 'blip_bank_fleeca_1',   coords = vector3(150.0, -1040.0, 29.0) },
        B { localeKey = 'blip_bank_fleeca_2',   coords = vector3(-350.0, -50.0, 49.0) },
        B { localeKey = 'blip_bank_pacific',     coords = vector3(250.0, 220.0, 106.0) },
    },
}
```

### Step 2: 在 `locales.lua` 添加对应 Locale Key

```lua
-- 在 blip 段（约第 265 行附近）追加:

    -- ── 银行 blip ────────────────────────────────────────────────
    blip_cat_banks       = { zh = '银行',               en = 'Banks' },
    blip_bank_fleeca_1   = { zh = 'Fleeca 银行 (市区)',  en = 'Fleeca Bank (City)' },
    blip_bank_fleeca_2   = { zh = 'Fleeca 银行 (西区)',  en = 'Fleeca Bank (West)' },
    blip_bank_pacific    = { zh = '太平洋标准银行',      en = 'Pacific Standard Bank' },
```

### 完成

重启资源后按 F9 即可看到新分类。**不需要修改任何其他文件。**

---

## 5. 添加新 Locale Key

### 命名规范

```
blip_cat_<分类名>        — 分类标签 (如 blip_cat_police)
blip_<实体名>            — 子项名称 (如 blip_cartel_hq)
```

### 添加步骤

1. 打开 `[system]/production-freeze/locales/locales.lua`
2. 在 `-- ── blip 分类标签 ──` 段或对应子段末尾追加
3. 格式: `key_name = { zh = '中文', en = 'English' },`
4. 缩进 4 空格，与已有键对齐

### 占位符支持

`_L()` 内部调用 `string.format()`，支持 `%s`、`%d` 等占位符：

```lua
blip_wanted_suspect = { zh = '【通缉犯】%s (%d星)', en = '【WANTED】%s (%d stars)' },
```

调用: `_L('blip_wanted_suspect', suspectName, wantedLevel)`

### 完整 Locale Key 索引

| Key | zh | en |
|-----|----|----|
| `blip_title` | 地图标记 | Map Markers |
| **分类标签** | | |
| `blip_cat_parking` | 公共停车场 | Public Parking |
| `blip_cat_police` | 警察局 | Police Stations |
| `blip_cat_hospitals` | 医院 | Hospitals |
| `blip_cat_gang_hqs` | 帮派据点 | Gang HQs |
| `blip_cat_hangars` | 机库 | Hangars |
| `blip_cat_boathouses` | 船坞 | Boathouses |
| `blip_cat_depots` | 扣押场 | Depots |
| `blip_cat_shops` | 商店 | Shops |
| **警察局** | | |
| `blip_police_mission_row` | 警察局 (Mission Row) | Police Station (Mission Row) |
| `blip_police_paleto` | 警察局 (Paleto) | Police Station (Paleto) |
| `blip_police_sandy` | 警察局 (Sandy Shores) | Police Station (Sandy Shores) |
| `blip_prison` | 监狱 | Prison |
| **帮派** | | |
| `blip_cartel_hq` | 卡特尔总部 | Cartel HQ |
| `blip_cartel_garage` | 卡特尔车库 | Cartel Garage |
| `blip_cartel_boss` | 卡特尔首脑控制台 | Cartel Boss Suite |
| `blip_ballas_hq` | 巴拉斯总部 | Ballas HQ |
| `blip_families_hq` | 家族帮总部 | Families HQ |
| `blip_lostmc_hq` | 失落摩托总部 | Lost MC HQ |
| `blip_vagos_hq` | 维戈斯总部 | Vagos HQ |
| **停车场** | | |
| `blip_parking_motel` | Motel 停车场 | Motel Parking |
| `blip_parking_casino` | 赌场停车场 | Casino Parking |
| `blip_parking_san_andreas` | San Andreas 停车场 | San Andreas Parking |
| `blip_parking_spanish` | Spanish Ave 停车场 | Spanish Ave Parking |
| `blip_parking_caears24` | Caears 24 停车场 | Caears 24 Parking |
| `blip_parking_caears242` | Caears 24 停车场 #2 | Caears 24 Parking #2 |
| `blip_parking_laguna` | Laguna 停车场 | Laguna Parking |
| `blip_parking_airport` | 机场停车场 | Airport Parking |
| `blip_parking_beach` | 海滩停车场 | Beach Parking |
| `blip_parking_motor_hotel` | Motor Hotel 停车场 | The Motor Hotel Parking |
| `blip_parking_liqour` | Liqour 停车场 | Liqour Parking |
| `blip_parking_shore` | Shore 停车场 | Shore Parking |
| `blip_parking_bell_farms` | Bell Farms 停车场 | Bell Farms Parking |
| `blip_parking_dumbo` | Dumbo 停车场 | Dumbo Private Parking |
| `blip_parking_pillbox` | Pillbox 停车场 | Pillbox Garage Parking |
| `blip_parking_grapeseed` | Grapeseed 停车场 | Grapeseed Parking |
| **医院** | | |
| `blip_hospital_pillbox` | Pillbox 医院 | Pillbox Hospital |
| `blip_hospital_sandy` | Sandy Shores 医疗中心 | Sandy Shores Medical |
| `blip_hospital_paleto` | Paleto Bay 医疗中心 | Paleto Bay Medical |
| **司法** | | |
| `blip_courthouse` | 法院 | Courthouse |
| `blip_state_prison` | 州立监狱 | State Prison |
| **采矿** | | |
| `blip_quarry` | 砂石场 | Quarry |
| `blip_mountain` | 山区矿脉 | Mountain Vein |
| `blip_desert` | 煤矿 | Coal Mine |
| `blip_coast` | 海岸矿场 | Coastal Site |
| `blip_smelter` | 冶炼厂 | Smelter |
| **通缉/警察** | | |
| `blip_wanted_suspect` | 【通缉犯】%s (%d星) | 【WANTED】%s (%d stars) |
| **杂项** | | |
| `blip_drugs_buyer` | 买家 | Buyer |
| `blip_vangelico_jewelry` | Vangelico 珠宝店 | Vangelico Jewelry |
| `blip_recycle_center` | 回收中心 | Recycle Center |
| `blip_carwash` | 自助洗车 | Hands Free Carwash |
| `blip_surrender` | ⚖️ 自首: %s | ⚖️ Surrender: %s |
| `blip_truckrobbery_assault` | 运钞车袭击 | Assault on the transport of cash |
| `blip_truckrobbery_10_90` | 10-90: 运钞车抢劫 | 10-90: Armored Truck Robbery |
| `blip_truckrobbery_van` | 运钞车 | Van with Cash |
| `blip_vineyard_dropoff` | 交货点 | Drop Off |
| `blip_quest_target` | 任务目标 | Quest Target |
| `blip_atom_target` | 目标 | Target |

---

## 6. 侧边栏 NUI 资源

### 资源结构

```
[qb]/qb-mapsidebar/
├── fxmanifest.lua              # dependency: qb-core, production-freeze
├── client/
│   └── main.lua                # BuildBlipPayload + T() + NUI 消息
└── html/
    ├── map_sidebar.html         # NUI 页面 (lang="zh-CN", UTF-8)
    ├── css/
    │   └── map_sidebar.css      # 样式 + Noto Sans SC 中文字体
    └── js/
        └── map_sidebar.js       # 渲染 + <> 切换 + GPS 定位
```

### 快捷键

- **F9** — 打开/关闭地图侧边栏
- **ESC** — 关闭侧边栏
- **点击行** — 设置 GPS 导航点
- **点击 📍 按钮** — 设置 GPS 导航点
- **点击 `<` `>` 箭头** — 在多子项分类中切换

### CSS 中文字体栈

```css
@import url('https://fonts.googleapis.com/css2?family=Noto+Sans+SC:wght@400;500;700&display=swap');

:root {
    --font-cjk: 'Noto Sans SC', 'Microsoft YaHei', 'PingFang SC',
                'Hiragino Sans GB', 'WenQuanYi Micro Hei', sans-serif;
}
```

如果服务器离线运行（无法访问 Google Fonts），去掉 `@import` 行，仅靠系统字体降级链覆盖。

### 关键 JS 函数

| 函数 | 作用 |
|------|------|
| `renderAll()` | 全量渲染分类列表 |
| `updateSingleRow(catIdx)` | 局部更新单行（`<>` 切换时） |
| `switchItem(catIdx, delta)` | 切换子项索引并刷新 UI |
| `locate(catIdx, idx)` | 发送 GPS 坐标给 Lua |
| `post(action, data)` | fetch POST 到 NUI callback |

---

## 7. 场景速查

### 场景 A: 新增一个"银行"分类到侧边栏

```lua
-- 1. config_blips.lua
Config.BlipCategories.banks = {
    localeKey = 'blip_cat_banks',
    icon = 'fa-solid fa-building-columns',
    items = {
        B { localeKey = 'blip_bank_pacific', coords = vector3(...) },
    },
}

-- 2. locales.lua
blip_cat_banks    = { zh = '银行',              en = 'Banks' },
blip_bank_pacific = { zh = '太平洋标准银行',     en = 'Pacific Standard Bank' },

-- 3. 重启 qb-mapsidebar → 完成
```

### 场景 B: 修改某个 Blip 的中文翻译

```lua
-- 只需编辑 locales.lua 一处:
blip_carwash = { zh = '自助洗车', en = 'Hands Free Carwash' },
-- 改为:
blip_carwash = { zh = '全自动洗车', en = 'Hands Free Carwash' },
-- 重启 production-freeze → 全局生效
```

### 场景 C: 在自定义脚本中添加一个带 `_L()` 的 Blip

```lua
-- 前提: locales.lua 中已有 blip_my_feature 键
local blip = AddBlipForCoord(x, y, z)
SetBlipSprite(blip, 100)
BeginTextCommandSetBlipName("STRING")
AddTextComponentSubstringPlayerName(_L('blip_my_feature'))
EndTextCommandSetBlipName(blip)
```

### 场景 D: 调试 — 检查 `_L()` 是否正确返回

```lua
-- 在游戏中 F8 控制台:
print(_L('blip_cartel_hq'))
-- 中文客户端输出: 卡特尔总部
-- 英文客户端输出: Cartel HQ
-- 键不存在时输出: [blip_xxx]  ← 表示 locales.lua 缺此键
```

---

## 8. Blip 显示行为控制

### 8.1 核心 API

GTA5 的 Blip 显示行为由三个原生 API 控制：

| Native | 作用 | 常用值 |
|--------|------|--------|
| `SetBlipDisplay(blip, mode)` | 控制在哪些地图层显示 + 是否显示边缘方向箭头 | 见下表 |
| `SetBlipAsShortRange(blip, bool)` | `true` = 仅近距离可见；`false` = 全地图可见 | — |
| `SetBlipScale(blip, scale)` | 图标大小 | `0.6`~`1.2` |

### 8.2 `SetBlipDisplay` 模式速查

| mode | 小地图可见 | 暂停地图可见 | 小地图边缘箭头 | 典型用途 |
|------|-----------|-------------|---------------|---------|
| `0` | ❌ | ❌ | ❌ | 隐藏 |
| `2` | ✅ | ✅ | ✅ **始终指向** | 任务目标 / 通缉犯（始终显示方向） |
| `3` | ❌ | ❌ | ❌ | 仅 HUD |
| `4` | ✅ | ✅ | ❌ | **常规地点标记（推荐）** |
| `5` | ✅ | ❌ | ❌ | 仅小地图 |
| `8` | ✅ | ✅ | ❌ | 全显示（无箭头） |

### 8.3 常见组合

```lua
-- ✅ 常规固定地点（法院、商店、停车场）— 仅近距可见，无边缘箭头
SetBlipDisplay(blip, 4)
SetBlipAsShortRange(blip, true)
SetBlipScale(blip, 0.7)

-- ✅ 任务追踪目标 — 全地图可见 + 边缘方向指示
SetBlipDisplay(blip, 2)
SetBlipAsShortRange(blip, false)
SetBlipScale(blip, 1.0)
SetBlipRoute(blip, true)         -- 显示导航线
SetBlipRouteColour(blip, 1)      -- 红色路径

-- ✅ 动态事件（通缉、抢劫警报）— 闪烁 + 边缘指示 + 定时消失
SetBlipDisplay(blip, 2)
SetBlipFlashes(blip, true)
SetBlipAlpha(blip, 250)
-- ... 定时器 Wait(N) 后 RemoveBlip(blip)
```

### 8.4 排查：Blip 始终卡在地图边缘

**症状**: 法院/监狱/某个 Blip 不论多远都在小地图边缘显示箭标。

**根因**: 缺少 `SetBlipDisplay(blip, 4)` + `SetBlipAsShortRange(blip, true)`。GTA5 默认行为可能以 mode 2（始终指示）创建 blip。

**修复**: 在 `AddBlipForCoord` 之后立即加上：

```lua
SetBlipDisplay(blip, 4)
SetBlipAsShortRange(blip, true)
```

**已修复的文件**: `custom-justice/client/main.lua`（法院 + 监狱，2025-07）

### 8.5 Config 中预留 display 字段

对于在 `config.lua` 中定义的 blip，可以新增可选的 `display` 字段：

```lua
-- 常规地点 (默认 4)
blip = { sprite = 419, color = 38, scale = 0.8, display = 4 }

-- 任务目标 (2 = 带边缘箭头)
blip = { sprite = 458, color = 1, scale = 1.0, display = 2 }
```

客户端读取时：`SetBlipDisplay(blip, cfg.blip.display or 4)`

---

## 9. 故障排查

| 症状 | 可能原因 | 检查步骤 |
|------|---------|---------|
| 中文显示为方块 ⬜⬜⬜ | CSS 字体栈缺 CJK 字体 | 确认 `map_sidebar.css` 有 `@import Noto+Sans+SC`；检查网络能否访问 Google Fonts |
| `[blip_xxx]` 显示在 UI 上 | locales.lua 缺少该键 | `search_content "blip_xxx"` 检查是否存在 |
| 侧边栏不显示 | qb-mapsidebar 未启动 | `ensure qb-mapsidebar` 或在 server.cfg 中确认 |
| 中英文玩家看到相同文字 | `_L()` 未正确调用 | 确认调用的是 `_L('key')` 而非硬编码字符串 |
| 新加的分类不出现 | config_blips.lua 未加载 | 确认 `qb-core/fxmanifest.lua` 的 shared_scripts 包含 `config_blips.lua` |
| Blip 始终卡在小地图边缘 | 缺少 `SetBlipDisplay(4)` + `SetBlipAsShortRange(true)` | 参考 [§8.4](#84-排查blip-始终卡在地图边缘)，在 `AddBlipForCoord` 后补上两行 |

---

> **维护原则**: 改翻译 → 只动 `locales.lua`；加新地点 → `config_blips.lua` + `locales.lua` 各加一行。不要在任何脚本中硬编码 blip 名称文本。
