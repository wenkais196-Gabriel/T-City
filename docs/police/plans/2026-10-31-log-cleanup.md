# 日志清理：两个还在复发的脚本错误（研究 → 计划 → 施工）

> 数据来源：`scratch/fxserver-live.log`（8524 行，本机 FXServer @30130）。
> 只挑**仍在复发**的；历史残留（已修的）不重复处理。

## 1. 日志里的错误分布

| 次数 | 错误 | 状态 |
|---|---|---|
| **47** | `@qb-crypto/server/main.lua:104: attempt to compare table with number` | **仍复发** |
| 14 | `[oxmysql] Error in nested ref call for oxmysql` | **仍复发**（与上一条同因，见 §2） |
| 6 | `@custom-quest/.../quest_availability.lua:67: No such export IsArcEnabled` | 历史（已修：`callExport` 把索引包了 pcall） |
| 6 | `custom-phone ... GetAvailableQuests failed: nil` | **仍复发** |
| 1 | `custom-police/server/scenery.lua:47`（`SetEntityAsMissionEntity`） | 历史（布景已迁客户端） |
| 1 | `native ...: Argument at index 1 was null` | 历史 |
| 31 | `Server list query returned an error: Cfx failed to reach the server` | 本机无外网，属环境噪音，不修 |

## 2. qb-crypto:104 —— 研究

代码：

```lua
MySQL.update('UPDATE crypto ...', props, function(affectedRows)
    if affectedRows < 1 then            -- ← 第 104 行，炸在这里
        MySQL.insert('INSERT INTO crypto ...', props)
    end
    RefreshCrypto()                     -- ← 里面又是 MySQL.query.await
end)
```

| 发现 | 证据 |
|---|---|
| 本服 oxmysql 的 update 回调**回表**（`{affectedRows=…, insertId=…}`），不是数字 | `[qb]/qb-core/server/services/economy_service.lua:291` 已经有同款归一化：`type(x)=='table' and (x.affectedRows or 0) or tonumber(x)` |
| 回调里再调 `MySQL.query.await`（`RefreshCrypto`）会触发 **nested ref call** | 日志里 14 条 `Error in nested ref call for oxmysql` 与 104 行错误成对出现 |

**结论**：一次回调里既比较错了类型，又在回调内做同步 await —— 两个问题叠在同一个函数里。

## 3. custom-quest `GetAvailableQuests` —— 研究

| 观察 | 结论 |
|---|---|
| 报错是 `An error occurred while calling export 'GetAvailableQuests': nil` | 错误对象来自 export 内部抛错，FiveM 只给了 `nil` 文案，**拿不到堆栈** |
| `List()` → `Evaluate()` 里有 `QBCore.Functions.GetDutyCount`、`callExport(...)`（已 pcall）、`QuestRegistry.GetCategorizedList()` | `callExport` 已安全；剩下未保护的是 `QBCore` 与注册表读取 |
| 手机端每次打开任务 App 都会调它 | 影响：任务列表可能直接空白，且日志刷屏 |

**结论**：这条是**读路径**，正确姿势是 fail-soft（出错返回空列表 + 一条诊断日志），而不是让异常穿透到手机。真正的 nil 来源需要诊断日志才能定位，先埋点。

## 4. 施工计划

| # | 文件 | 改动 | 判据 |
|---|---|---|---|
| 1 | `[qb]/qb-crypto/server/main.lua` | `affectedRows` 归一化（table/number 都吃）；把回调内的 `RefreshCrypto()`（含 `.await`）改成无嵌套：更新后**同步**查一次 | 重启后 `104` 与 `nested ref` 都不再新增 |
| 2 | `custom-quest/server/main.lua` | `GetAvailableQuests` / `GetQuestDetail` 包 `pcall`，失败返回 `{}` / `nil,'unavailable'`；`quest_debug=1` 时打印真实错误（每条资源只打一次，防刷屏） | 手机任务列表不再报错；开启 `quest_debug` 能看到根因 |
| 3 | 闸门 | 防止回归：crypto 归一化写法、quests export 必须 pcall | 新测试 2 条 |

## 5. 验证方式

1. `restart qb-crypto` → 触发一次价格更新（等待 tick 或 `setcryptoworth`）→ 日志 `104` 新增 **0**、`nested ref` 新增 **0**；
2. `restart custom-quest` + `restart custom-phone` → 打开任务 App（或等客户端拉取）→ 日志 `GetAvailableQuests failed` 新增 **0**；
3. 全量 `pytest` + `release_check` 通过。

## 6. 风险与回滚

| 风险 | 处置 |
|---|---|
| 改 `[qb]` 上游文件会吞掉未来 diff | 只动这 6 行（归一化 + 去嵌套 await），并在改动处写 `-- T-City: ...` 标记，便于下次升级对账 |
| fail-soft 把真错误藏起来 | 只在 `quest_debug=1` 时打印；默认静默但不再穿透 |

## 7. 施工结果（2026-10-31 真机）

| 项 | 结果 |
|---|---|
| `qb-crypto` 归一化 + 去嵌套 await | 已改；控制台 `setcryptoworth qbit 5200` 后 `crypto.worth = 5200` 落库 |
| 控制台 `source=0` 报错 | 已加分支；控制台改价输出 `[qb-crypto] setcryptoworth qbit -> 5200 (from console)`，无 SCRIPT ERROR |
| 真机计数（基线之后） | `attempt to compare table` **0**、`nested ref` **0**、`SCRIPT ERROR` **0** |
| `GetAvailableQuests` fail-soft | 已改；手机任务列表不再因内部异常整页失败，诊断留给 `quest_debug=1` |
| 闸门 | 新增 2 条（crypto 不能回调+必须归一化、quests 手机读路径必须 pcall） |

### 7.1 顺手发现的第三件事

`crypto` 表**一直是空的** —— 因为旧代码在 `affectedRows < 1` 那一步就崩了，insert 分支永远执行不到。
修完之后表里才有第一行。这解释了为什么"crypto 从来没数据"却没人报障：界面读不到就静静空着。

### 7.2 没修的一类

`Server list query returned an error: Cfx failed to reach the server`（31 次）——
本机没有外网，是 FXServer 上报主列表的正常噪音，不属于代码缺陷。
