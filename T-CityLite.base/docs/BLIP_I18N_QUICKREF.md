# Blip 本地化维护速查卡

> **适用人员**: 翻译 / 策划 / 运维  
> **前置阅读**: `docs/BLIP_I18N_GUIDE.md`（技术文档）

---

## 核心原则

```
Blip 显示文本 = _L('blip_<实体名>')

  _L() 读取玩家 GTA5 客户端语言:
    简体中文 (12) / 繁体中文 (9) → zh
    其他                           → en (兜底)
```

**只改 locales.lua，不改脚本。**

---

## 加一个新 Blip 名称（三步）

### 1️⃣ 打开 `locales.lua`

路径: `resources/[system]/production-freeze/locales/locales.lua`

### 2️⃣ 在 `blip` 段追加一行

找到 `-- ── blip` 开头的注释区域，在对应子段末尾加：

```lua
blip_<名字> = { zh = '中文名', en = 'English Name' },
```

### 3️⃣ 重启 `production-freeze` 资源

```
F8 → restart production-freeze
```

---

## 修改已有翻译

找到对应行，只改 `zh` 或 `en` 的值：

```lua
-- 改前
blip_carwash = { zh = '自助洗车', en = 'Hands Free Carwash' },
-- 改后
blip_carwash = { zh = '全自动洗车', en = 'Hands Free Carwash' },
```

重启资源生效。

---

## 带占位符的翻译

`%s` = 字符串, `%d` = 数字，顺序对应 `_L()` 的后续参数：

```lua
blip_wanted_suspect = { zh = '【通缉犯】%s (%d星)', en = '【WANTED】%s (%d stars)' },
blip_surrender      = { zh = '⚖️ 自首: %s',        en = '⚖️ Surrender: %s' },
```

脚本调用:
```lua
_L('blip_wanted_suspect', suspectName, wantedLevel)
_L('blip_surrender', data.name)
```

---

## 验证方法

```
F8 控制台输入:
  print(_L('blip_cartel_hq'))

正确输出:
  中文客户端 → 卡特尔总部
  英文客户端 → Cartel HQ

缺少 key 时:
  → [blip_cartel_hq]     ← 说明 locales.lua 没这个键
```

---

## 常用修改场景

| 想做的事 | 改哪个文件 | 改什么 |
|---------|-----------|--------|
| 把"警察局"改为"警署" | `locales.lua` | `blip_police_mission_row` 等 3 个键的 `zh` 字段 |
| 停车场改名 | `locales.lua` | `blip_parking_*` 对应键 |
| 新增一个地图标记点 | `config_blips.lua` + `locales.lua` | 各加一行 |
| 切换全服语言 | `server.cfg` | `set qb_locale zh-cn` 或 `en` |
| 离线环境字体修复 | `map_sidebar.css` | 删掉 `@import` 行，信任系统字体 |

---

## 文件位置速查

| 文件 | 路径关键字 |
|------|-----------|
| 语言包 | `production-freeze/locales/locales.lua` |
| Blip 配置 | `qb-core/config_blips.lua` |
| 侧边栏样式 | `qb-mapsidebar/html/css/map_sidebar.css` |
| 侧边栏逻辑 | `qb-mapsidebar/html/js/map_sidebar.js` |
