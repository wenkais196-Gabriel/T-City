# 安全重构: 移除 escape_sqli 手动转义

## 变更概述

移除 `qb-phone/server/main.lua` 中的 `escape_sqli` 手动转义函数，将 `FetchResult` 和 `GetVehicleSearchResults` 的查询构建改为全参数化查询模式。消除字符串拼接引入的 SQL 注入风险。

## 变更文件

| 文件 | 行数变化 | 说明 |
|------|---------|------|
| `resources/[qb]/qb-phone/server/main.lua` | 1120→1113 (-7行) | 删除函数+重写查询构建 |

## 变更详情

### 1. 删除 `escape_sqli` 函数 (原 L29-35)

**移除代码：**
```lua
local function escape_sqli(source)
    local replacements = {
        ['"'] = '\\"',
        ["'"] = "\\'"
    }
    return source:gsub("['\"]", replacements)
end
```

**原因：** 手动转义不可靠（未处理反斜杠、Unicode 编码绕过等场景），应使用数据库驱动的参数化查询。

### 2. 重写 `FetchResult` 查询构建 (原 L386-432)

**重构前：** 字符串拼接（有 SQL 注入风险）
```lua
local query = 'SELECT * FROM `players` WHERE `citizenid` = "' .. search .. '"'
if #searchParameters > 1 then
    query = query .. ' OR `charinfo` LIKE "%' .. searchParameters[1] .. '%"'
    for i = 2, #searchParameters do
        query = query .. ' AND `charinfo` LIKE  "%' .. searchParameters[i] .. '%"'
    end
else
    query = query .. ' OR `charinfo` LIKE "%' .. search .. '%"'
end
local result = MySQL.query.await(query)
```

**重构后：** 参数数组 + `?` 占位符
```lua
local conditions = {'citizenid = ?'}
local params = {search}
...
local query = 'SELECT * FROM `players` WHERE ' .. table.concat(conditions, ' ')
local result = MySQL.query.await(query, params)
```

生成的 SQL 语义等价（已验证所有分支）：
- **单次搜索** `"john"`: `WHERE citizenid=? OR charinfo LIKE ?` ✅
- **多词搜索** `"john smith"`: `WHERE citizenid=? OR charinfo LIKE ? AND charinfo LIKE ?`（AND>OR 优先级，与原版一致）✅

### 3. 删除 `GetVehicleSearchResults` 的 escape_sqli 调用 (原 L435)

该回调已在行 438 使用 `?` 参数化查询，`escape_sqli` 调用是多余的，直接删除。

## 安全性分析

| 攻击向量 | 重构前 | 重构后 |
|---------|--------|--------|
| SQL 注入（`' OR 1=1 --`） | ⚠️ 不完全防护（escape_sqli 转义引号） | ✅ 参数化查询彻底免疫 |
| 编码绕过（Unicode/hex） | ❌ escape_sqli 不处理 | ✅ 参数化查询不受影响 |
| LIKE 通配符滥用（`%_%`） | ⚠️ 同样存在 | ⚠️ 同样存在（非本重构范围） |

## 向后兼容性

✅ **完全向后兼容。** 三个 CreateCallback 的函数签名、参数、返回值均无变化。仅内部实现路径重构。

## 审查与自愈记录

| 轮次 | 发现 | 处理 |
|:----:|------|------|
| Round 1 | `table.concat(conditions, ' OR ')` 将多词 AND 错误改为 OR | 嵌入 OR/AND 前缀，分隔符改为空格 |
| Round 2 | 全部通过 | verdict: pass |

## 性能影响

无负面影响。参数化查询与原始查询的执行路径相同，params 数组的构建开销可忽略。
