# AGENTS.md — `[qb]` 上游框架（qb-core 系）

> 目录：`T-CityLite.base/resources/[qb]/`。这些资源来自 QBCore 生态，
> **不是我们的代码**。改动原则：最小 diff、只改必须改的、每次改动都记进 CHANGELOG。

## 范围

`qb-core`、`qb-inventory`、`qb-houses`、`qb-vehicleshop`、`qb-ambulancejob`、`qb-policejob`、
`qb-garages`、`qb-hud`、`qb-adminmenu`、`qb-lapraces`、`qb-crypto`、`qb-cityhall` 等。

## 唯一入口（我们与它的交界）

| 交界 | 做法 |
|---|---|
| 读玩家/核心对象 | `exports['qb-core']:GetCoreObject()`（惰性解析并缓存，`_G.QBCore` 不保证存在） |
| 钱 / 物品 / 载具 | `Player.Functions.*`、`QBCore.Shared.*`；不绕过框架直接写库 |
| 新增命令 | `QBCore.Commands.Add(name, help, arguments, argsRequired, cb, permission)`；**cb 里必须判 `GetPlayer(source)` 为 nil** |
| 事件 | 框架事件（`QBCore:Server:*`）优先；自定义事件不得占用框架命名空间 |

## 禁止

- 不要重排版/重命名/调整顺序：每一次无关 diff 都会让上游更新无法合并。
- 不要为了"顺手统一"把 `[qb]` 的代码风格改成 `[custom]` 的风格。
- 不要在没有 CHANGELOG 条目的情况下改框架行为（后续排查会归因错）。
- 不要把业务逻辑塞进 `qb-core`：能放在 `[custom]` 的就别动框架。

## 改动前必读

- **`qb-core/server/commands.lua` 用 CfxLua 扩展语法（`+=`），`luac5.4 -p` 无法解析**；
  报错行固定停在 `+=` 那一行是正常的，不代表你的改动有语法错。判断方法：改动前后
  报错行号是否变化。
- `qb-core` 的命令分发不在 pcall 里：handler 抛错会静默吞掉，表现为"命令没反应"。
  所以命令里任何可能为 nil 的对象都要先判空。
- 参数缺失时框架自己会给玩家发 `chat:addMessage`；从控制台执行（`source = 0`）会抛
  `native … Argument at index 1 was null`——这条已在 `commands.lua` 里修掉，
  如果又出现，说明有人回退了那个判断。
- 载具/物品/住宅这类资源的状态有多个写入口，改之前先看 `table_owners.json`。

## 验收命令

```bash
cd T-CityLite.base && /usr/bin/python3 -m pytest tests/unit tests/architecture -q
luac5.4 -p resources/[qb]/<res>/server/*.lua   # qb-core 例外，见上
tcity-cmd -w 8 "restart <res>"
tcity-cmd --page | grep -aiE "script error|attempt to index"
```

`restart` 之后控制台必须没有 `SCRIPT ERROR`；有的话先看是不是 `source = 0` 触发的
框架通知路径（`Argument at index 1 was null`），再判断是不是自己的 handler。
