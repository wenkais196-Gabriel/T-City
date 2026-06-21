# 📜 T-City Lite 统一日志输出规范 (logging_spec.md)

> **修订日期**: 2026-06-04  
> **适用范围**: 所有自研 custom 模块与重构的 qb-core 核心及业务模块。  
> **设计目标**: 提升控制台日志可读性、避免高频字符串拼接损耗、严防客户端敏感信息泄露。

---

## 1. 日志级别与色彩/符号规范

系统日志采用业内标准的 **5 级分级日志体系**。在 FiveM 服务端控制台中，使用原生色彩控制符（如 `^2`, `^3`）进行美化：

| 级别 | 控制台色彩样式 | 标志符号 | 使用场景描述 |
| :--- | :--- | :---: | :--- |
| **DEBUG** | `^5[DEBUG] [模块名] ^7` (淡蓝) | `⚙️` | 调试信息。如：网络事件包体、局部计算过程、临时物理坐标。 |
| **INFO** | `^2[INFO]  [模块名] ^7` (绿色) | `✓` | 正常业务流程状态变更。如：玩家上线、车辆刷出、数据聚合落盘成功。 |
| **WARN** | `^3[WARN]  [模块名] ^7` (黄色) | `⚠️` | 边界异常但系统已自动处理。如：退位交接时候选人离线、数据库响应超 200ms。 |
| **ERROR** | `^1[ERROR] [模块名] ^7` (红色) | `❌` | 运行时逻辑错误。如：JSON解析异常、SQL执行失败、依赖服务缺失。 |
| **FATAL** | `^8[FATAL] [模块名] ^7` (深红) | `🚨` | 导致服务崩溃或数据不可逆损坏的灾难性错误。如：总线初始化失败、缓存不可写入。 |

---

## 2. 高性能日志设计（四大原则：高性能）

为了防止关闭调试日志时，Lua 依然产生高频的字符串格式化与拼接开销，必须使用以下两种高性能方案：

### 方案 A：静态级别拦截（推荐）
在输出日志前进行级别判定，避免传参计算。

```lua
-- ❌ 不推荐（即使全局设为 INFO，也会在内存中执行 string.format 和参数传递）
Logger.debug("玩家 %s 执行抢劫，距离收银台 %.2f 米", playerCid, dist)

-- ✅ 推荐（只有在全局为 DEBUG 级别时才执行格式化和输出）
if Logger.IsDebugEnabled() then
    Logger.debug("玩家 %s 执行抢劫，距离收银台 %.2f 米", playerCid, dist)
end
```

### 方案 B：统一 Logger 工厂封装
统一由 `core-framework` 提供的 `Logger` 类库管理日志，通过 CVar 动态调节日志门槛：

```lua
-- server.cfg 中设置 log 门槛
-- setr log_level "INFO"
```

---

## 3. 日志安全性标准（四大原则：安全）

> [!WARNING]
> 客户端控制台 (F8) 是外挂和逆向玩家获取服务器机密的重要入口，必须实施静默隔离。

1.  **敏感数据脱敏**：
    *   **禁止**在客户端 F8 打印：玩家的 `citizenid`、Steam Hex 标识、License 秘钥、数据库物理 IP、高精确玩家坐标。
    *   **允许**在服务端打印，但对玩家敏感标识进行掩码处理（如：`license:12a...f3`）。
2.  **错误隔离原则**：
    *   当客户端发生网络或业务逻辑异常时，客户端只允许打印精简的提示：`[System] Operation failed. Please retry.`。
    *   详细堆栈与异常数据应异步回传至服务端进行 `Logger.error` 或 Discord Webhook 日志写入。
3.  **开发级静默开关**：
    *   所有客户端资源头必须定义 `local enableDebugLogs = false`。
    *   任何客户端调试级输出，必须包裹在 `if enableDebugLogs then` 块内，在发布到生产环境时必须默认关闭。

---

---

### 3.4 玩家标识符脱敏标准（强制）

> [!CAUTION]
> citizenid 和平台标识符 (steam/license/xbl/discord/live) 是数据库主键等价物，泄露后可直接关联玩家真实身份和绕过安全系统。

**citizenid 掩码格式**（所有服务端 `print()` 输出必须遵守）：

```lua
-- ✅ 推荐：前4后4掩码
local maskedCid = citizenid:sub(1,4) .. "..." .. citizenid:sub(-4)
print(("[模块名] 操作完成: CID=%s"):format(maskedCid))
-- 输出示例: [模块名] 操作完成: CID=ABCD...WXYZ
```

**identifier 掩码格式**（禁止直接 `print()` 完整标识符列表）：

```lua
-- ❌ 禁止：直接输出完整标识符
print(table.concat(GetPlayerIdentifiers(src), ", "))

-- ✅ 推荐：仅输出类型计数摘要
local idSummary = {}
for _, v in ipairs(identifiers) do
    local prefix = v:match("^(%a+):") or "unknown"
    idSummary[prefix] = (idSummary[prefix] or 0) + 1
end
-- 输出示例: steam:1 license:1 xbl:1 live:1 discord:1 fivem:1
```

### 3.5 客户端 Convar 调试开关（强制）

所有客户端 Lua 脚本中的调试输出必须受 Convar 控制，**不得硬编码 `local enableDebugLogs = true/false`**（容易被遗忘在生产环境开启）。

```lua
-- ✅ 推荐：Convar 驱动，生产环境默认关闭
local enableClientDebug = GetConvar('debug_client', 'false') == 'true'
local function ClientDebugPrint(msg, ...)
    if enableClientDebug then
        print(string.format('^5[DEBUG:%s]^7 %s', GetCurrentResourceName(),
            ... and string.format(msg, ...) or msg))
    end
end
```

### 3.6 服务端模块级调试开关

服务端高频业务模块（如任务系统、税务系统）应使用独立 Convar 控制调试日志，避免全局 `log_level=DEBUG` 导致所有模块刷屏：

```lua
-- ✅ 推荐：模块独立 Convar
local QUEST_DEBUG = GetConvar('quest_debug', 'false') == 'true'
local function QuestPrint(msg, ...)
    if QUEST_DEBUG then
        print(string.format('[quest-manager] %s', ... and string.format(msg, ...) or msg))
    end
end

-- server.cfg 中按需开启:
-- setr quest_debug "true"
```

---

## 4. 日志代码实现样例

以下为在 `core-framework` 架构下推荐的标准日志封装类代码，可供各业务资源引用：

```lua
-- 在业务脚本 (sv_main.lua) 中初始化 Logger
local Logger = {}
local LOG_LEVELS = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, FATAL = 5 }
local CURRENT_LEVEL = LOG_LEVELS[GetConvar("log_level", "INFO")] or 2
local RESOURCE_NAME = GetCurrentResourceName()

local COLOR_CODES = {
    DEBUG = "^5[DEBUG]^7",
    INFO  = "^2[INFO] ^7",
    WARN  = "^3[WARN] ^7",
    ERROR = "^1[ERROR]^7",
    FATAL = "^8[FATAL]^7"
}

local ICONS = {
    DEBUG = "⚙️",
    INFO  = "✓",
    WARN  = "⚠️",
    ERROR = "❌",
    FATAL = "🚨"
}

local function formatLog(level, msg, ...)
    local formatted = ... and string.format(msg, ...) or msg
    return string.format("%s %s [%s] %s", ICONS[level], COLOR_CODES[level], RESOURCE_NAME, formatted)
end

function Logger.IsDebugEnabled()
    return CURRENT_LEVEL <= LOG_LEVELS.DEBUG
end

function Logger.debug(msg, ...)
    if CURRENT_LEVEL <= LOG_LEVELS.DEBUG then
        print(formatLog("DEBUG", msg, ...))
    end
end

function Logger.info(msg, ...)
    if CURRENT_LEVEL <= LOG_LEVELS.INFO then
        print(formatLog("INFO", msg, ...))
    end
end

function Logger.warn(msg, ...)
    if CURRENT_LEVEL <= LOG_LEVELS.WARN then
        print(formatLog("WARN", msg, ...))
    end
end

function Logger.error(msg, ...)
    if CURRENT_LEVEL <= LOG_LEVELS.ERROR then
        print(formatLog("ERROR", msg, ...))
    end
end

function Logger.fatal(msg, ...)
    if CURRENT_LEVEL <= LOG_LEVELS.FATAL then
        print(formatLog("FATAL", msg, ...))
    end
end

-- 示例用法：
-- Logger.info("系统初始化完毕，共加载了 %d 个模块", 14)
-- Logger.error("解析 JSON 配置失败: %s", err)
```
