# 设计文档: 移除 escape_sqli 手动转义，改为全参数化查询

## 目标与验收标准

**目标:** 消除 qb-phone/server/main.lua 中因 escape_sqli 手动转义导致的 SQL 注入风险敞口

**验收标准:**
1. `escape_sqli` 函数定义被移除
2. `qb-phone:server:FetchResult` 改用 `?` 参数化查询构建动态条件
3. `qb-phone:server:GetVehicleSearchResults` 移除无意义的 `escape_sqli` 调用
4. 所有参数化查询通过 `MySQL.query.await` 执行
5. 功能行为不变（相同输入产生相同输出）

## 受影响文件

| 文件 | 行号 | 改动类型 |
|------|------|---------|
| `resources/[qb]/qb-phone/server/main.lua` | L29-35 (escape_sqli 定义) | 删除 |
| `resources/[qb]/qb-phone/server/main.lua` | L386-432 (FetchResult) | 重写查询构建逻辑 |
| `resources/[qb]/qb-phone/server/main.lua` | L434-435 (GetVehicleSearchResults 首行) | 删除 escape_sqli 调用 |

## 变更策略

### FetchResult (L386-432)

**现状:** 字符串拼接构建 SQL:
```lua
local query = 'SELECT * FROM `players` WHERE `citizenid` = "' .. search .. '"'
if #searchParameters > 1 then
    query = query .. ' OR `charinfo` LIKE "%' .. searchParameters[1] .. '%"'
    ...
```

**改造后:** 参数数组 + `?` 占位符:
```lua
local conditions = {'citizenid = ?'}
local params = {search}
-- 对 searchParameters 的每个词添加 LIKE 条件 + 对应参数
-- 用 table.concat 构建 query，用 params 表传入所有参数
```

### GetVehicleSearchResults (L434-435)

只需删除第 435 行 `search = escape_sqli(search)` — 后续查询已在行 438 使用 `?` 参数化:
```lua
local result = MySQL.query.await('SELECT * FROM player_vehicles WHERE plate LIKE ? OR citizenid = ?', { query, search })
```

### escape_sqli 函数定义 (L29-35)

整段删除，确认无其他调用者。

## 向后兼容

✅ 完全向后兼容 — 输入输出接口不变，仅重构内部实现路径。三个回调的函数签名不变。

## 风险点与回滚

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|---------|
| LIKE 查询参数化后行为不一致 | 低 | 搜索结果不匹配 | 在参数值中保留 `%` 通配符逻辑 |
| 多词搜索 OR/AND 逻辑写错 | 中 | 搜索结果异常 | 参数数组顺序必须与条件数组严格对齐 |
| 遗漏 escape_sqli 调用点 | 低 | 仍有注入风险 | 搜索确认只有 2 处调用 |

**回滚方案:** 用 `git checkout -- resources/[qb]/qb-phone/server/main.lua` 恢复。

## 设计决策记录

1. 保留 `SplitStringToArray` 函数不变（仅文本分割，无 SQL 风险）
2. `FetchResult` 中的公寓数据查询 (L406-408) 和结果解析逻辑完全不动
3. 重构后生成的 SQL 语义与原版完全等价
