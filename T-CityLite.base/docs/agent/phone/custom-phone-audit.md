# custom-phone 审计报告（性能 + 当前故障）

> 仓库：`/home/swk/Documents/deepseek-harness/default-workspace/T-City-agent`，分支 `master`
> 资源：`T-CityLite.base/resources/[custom]/custom-phone/`
> 运行日志：`/tmp/fxserver.log`（运行中实例，未重启、未杀进程）
> 实测环境：同一份资源文件与运行中的 `T-City/T-CityLite.base` 逐文件 `cmp` 一致；数据库 `TCityLite` 只做 SELECT/SHOW/DESCRIBE，并用一次事务内回滚的 INSERT 复现错误（无数据变更）
> 方法：静态代码审计 + 日志 grep + 数据库结构/数据核对；**没有客户端运行时实测**，NUI 交互结论基于代码路径推断

---

## 0. 结论

| 维度 | 结论 |
|:---|:---|
| 能否启动 | **能**。`/tmp/fxserver.log:136-137` 有 `Creating script environments for custom-phone` / `Started resource custom-phone`，无加载错误。 |
| 能否正常使用 | **不能**。短信、通话、通知、联系人/点赞、职业 App 多条核心链路存在互相独立的 P0 级故障（详见第 1 节）。 |
| 总体判断 | **有问题，需要局部重构**：数据访问层（schema + insert 返回值）、事件层（通知回环/来电监听）、身份映射层（`primary_role`）需要重做；**不建议整机重写**，Svelte 组件和 UI 结构可以保留。 |

一句话：资源“能跑起来”，但 `phone_messages` 表结构已与代码不一致，`insert` 回调返回值被错误当成数字，通知事件存在无限回环，来电监听只在通话 App 内注册，职业身份字段已从 `custom-career` 中消失。这些问题在 UI 上多数表现为“点了没反应/空列表/自己关闭”，所以用户只能笼统地说“手机还是有问题”。

严重度定义：`P0` 核心功能不可用或会造成数据/服务端放大；`P1` 功能错误或明显性能/一致性问题；`P2` 可维护性、体验、边界问题。

---

## 1. 高概率 Bug 表

### 1.1 P0（先修，否则“手机还是有问题”不会消失）

| ID | 严重度 | 位置(file:line) | 现象推测 | 证据 | 修复建议 |
|:---|:---|:---|:---|:---|:---|
| B01 | P0 | `server/main.lua:16-34`（建表/迁移）、`:216-218`（SELECT）、`:326`（INSERT）、`:366`（UPDATE 已读）；`tests/fixtures/tcity_schema.sql:383-394` | 发短信“没反应”：输入框清空、聊天里不出现；短信历史永远为空；已读不生效；`SendSystemMessage` 返回 `db_error` | 实际 DB 的 `phone_messages` 是 qb-phone 旧结构：`id,citizenid,number,messages,gps,msg_status`；代码读写 `sender_number,receiver_number,message,timestamp,is_read`。实测 `SELECT ... WHERE sender_number` 与 `INSERT ... (sender_number,...)` 均报 `ERROR 1054 Unknown column`。`CREATE TABLE IF NOT EXISTS` 对已存在表是空操作，`ALTER ... ADD COLUMN IF NOT EXISTS gps/msg_status` 只补了两列，不会改列名/补列。测试 fixture 本身也是旧的，所以测试不会发现 | 加幂等迁移：先 `RENAME TABLE phone_messages TO phone_messages_qbphone_legacy`（或新表名 `phone_sms`），再按代码 schema 建新表；启动时用 `information_schema.COLUMNS` 校验全部列，缺失就 `print`/报错而不是静默继续；同步修 `tests/fixtures/tcity_schema.sql`；测试从“表存在”改为“列齐全且可读写” |
| B02 | P0 | `server/main.lua:289-292,326-337,440-447,530-543,809-830`；`server/jobboard.lua:108-125`；对照 `[standalone]/oxmysql/dist/build.js:168-172` | 通话接不起来（`answerCall` 返回 `Call not found`）；新发布的 Job 接不了；刚加的联系人删不掉；点赞/删除通知失败；所有 NUI 收到的 `id` 变成 `{insertId:...}` 对象 | 该仓库的 oxmysql 是定制后端，`insert` 回调返回 `{ insertId, affectedRows }` 而不是数字（`dist/build.js:171`；`tests/unit/layer3_business/test_vehicleshop.py:152` 也明确注明了这一点）。`server/main.lua:398-403` 的 `SendSystemMessage` 已经做了 `type(insertId)=='table'` 归一化，但其余 6 处没有；`initiateCall` 用 table 作 `activeCalls[callId]` 的 key，NUI 回传 JSON 后变成新 table，永远查不到 | 统一 DB 契约。首选把 `resources/[standalone]/oxmysql/dist/build.js` 的 `insert` 恢复为上游语义（返回 `insertId` 数字），`execute/update` 返回 `affectedRows` 数字；或封装 `PhoneDb.Insert/Update` 并在所有回调里先 `type(r)=='table' and r.insertId/r.affectedRows` 归一化。不要逐处猜；加一个“insert 返回 table”的契约测试 |
| B03 | P0 | `client/main.lua:413-420`；`server/main.lua:435-454`（尤其 `:447`） | 任意一条系统通知都会触发**无限循环**：客户端把收到的通知再发给服务端持久化，服务端插入后又推回客户端；通知列表无限增长、DB 狂写、客户端/服务端卡顿，严重时拖垮整个服务器 | 代码路径无任何“已持久化”标记或去重：服务端 `TriggerClientEvent('phone:client:newNotification')` → 客户端 `TriggerServerEvent('phone:server:storeNotification')` → 服务端插入 `phone_notifications` → `:447` 再 `TriggerClientEvent` → 回到第一步。所有通知源都受影响：`server/main.lua:344,418,630,726`、`server/banking.lua:53`、`server/jobboard.lua:129,190`、`server/faction.lua:98`。注意：当前 SMS 因 B01 在插入阶段就失败，反而暂时掩盖了这个循环；**一旦修好短信表，第一笔短信就会触发回环**。Job 发布会对全服每个玩家各触发一次，放大为 N 倍 | 删除客户端 `TriggerServerEvent('phone:server:storeNotification')`；通知在服务端源头持久化后只推一次（带 `persisted=true`/DB id）。如果确有“客户端本地通知”需求，服务端 `storeNotification` 只落库、不回推，并加 `notification.id` 幂等/去重、内容长度校验和每玩家速率限制 |
| B04 | P0 | `web/src/apps/PhoneCall.svelte:106-133`；`web/src/App.svelte:280-281`；`client/main.lua:437-442` | 来电没有铃声/弹窗；如果接听者当时不在 Phone App 里（默认在 Home，或手机根本没开），完全收不到来电；主叫一直“Ringing”直到手动挂断 | `phone:incomingCall/callAnswered/callEnded` 的 `registerNuiEvent` 只写在 `PhoneCall.svelte` 的 `onMount` 中；而 `PhoneCall` 只在 `$activeApp === 'phonecall'` 时渲染（`App.svelte:280-281`）。Lua 侧却无条件 `SendNUIMessage`；NUI 没有全局监听器接收。`grep` 也没有任何 ringtone/音频代码 | 把来电/接通/结束监听移到 `App.svelte`（始终挂载）或顶层 store；收到来电时强制切到通话覆盖层并播放铃声；加 30s 振铃超时；`PhoneCall` 只负责展示 |
| B05 | P0 | `web/src/App.svelte:124-133`；`client/main.lua:29-33`（`keepInput=true`）、`:167`（M 键位）；`config.lua:4` | 在短信/组织频道/搜索框里输入任何包含 `m`/`M` 的词（如 `me`、`message`、`come`）手机立刻关闭，输入内容丢失；按 M 开关手机还可能和游戏键位互相抢，出现“开不出来/刚开就关”；`keepInput=true` 时 WASD 仍会驱动角色，打字时人物乱走 | 全局 `window.addEventListener('keydown')` 对 `e.key === 'm'` 或 `'M'` 直接 `closePhone()`，**没有判断 target 是否 input/textarea/contenteditable，也没有判断 `$isPhoneOpen`**。同时 `OpenMenu({ keepInput = true })` 让游戏输入继续生效，`RegisterKeyMapping('phone', ..., 'M')` 仍绑定 M；两条路径同时响应。构建产物 `resources/[custom]/custom-phone/html/assets` 下的 hash 化 bundle 中同样存在该逻辑（`e.key` 为 `m`/`M` 时关闭） | 二选一：保留游戏 M 键位就删掉 NUI 的 M 关闭（只保留 ESC）；或保留 NUI M 关闭就把 `keepInput=false`。无论哪种，keydown 先判断 `if (!isOpen) return; if (target.closest('input,textarea,select,[contenteditable]')) return;`。顺手把“ESC 关闭”限制在手机打开时。改完**必须重新 `npm run build` 生成 `resources/[custom]/custom-phone/html/assets` 下的 hash 化 bundle** |
| B06 | P0 | `server/main.lua:134,190,688`；`server/faction.lua:25,44,68,96,122`；`server/jobboard.lua:97`；`client/main.lua:557`；`web/src/App.svelte:147-159` | 警察/EMS/市长/帮派领袖看不到职业 App；组织频道发消息报服务端错误（输入框已清空、消息没发出去）；热线在线人数永远 0；市长无法发布工程、Sheriff/Gang 指令永远 Unauthorized；组织频道广播永远匹配不到人 | `custom-career` v2 的 `GetPlayerIdentity` 返回 `job_name/job_label/org_id/org_label/gang_name/rank_tier/...`（`custom-career/server/main.lua:58-72`），**没有 `primary_role` 字段**；全仓库 `primary_role` 只在 custom-phone 里出现。`getPhoneData` 把该 identity 直接塞进 `career`，NUI 的 `getLeaderAppIcon($playerData.career.primary_role)` 得到 `undefined` → 不渲染领袖图标。`faction.lua:44` 得到 `role=nil`，`BroadcastToFaction` 在 `:15` 执行 `FactionMessages[nil] = {}` 直接抛 `table index is nil`，回调不返回；`:25` 的接收者判断永远 false。`main.lua:688-689` 执行 `playerJobs[nil] = ...` 同样抛错，Hotlines 的 `getAllHotlineStatus` 回调失败。日志里本机玩家 `IYY39878` 正是 `职业: Law Enforcement，组织: LSPD，等级: Chief，阶层: leader`（`/tmp/fxserver.log:450`） | 在 custom-phone 内加一个**唯一的角色解析器**：`gang_name` 非空→`gang`；`job_name` 为 `police/ambulance/mayor/...` 映射到 NUI 约定的 `police/medic/mayor/...`；否则 `civilian`。把 `identity.primary_role = ResolveRole(identity)` 只算一次，替换所有 `identity.primary_role`；或者修改 custom-career 契约，在服务端 identity 中补 `primary_role`（推荐，但影响面更大）。补一个用真实 identity 形状的单测 |
| B07 | P0 | `server/main.lua:809-830,834-898`；`client/main.lua:437-457`；`resources/[custom]/custom-phone/web/src/apps/PhoneCall.svelte` | 即使修好 B04，接听/挂断仍会失败；通话没有真正的语音通道，双方“Connected”但互相听不见（除非恰好都在附近用 proximity voice） | 除了 B02 的 callId=table，通话系统没有任何 `pma-voice`/`mumble`/voice channel 集成：对 custom-phone 执行 `grep` 搜 `mumble`、`pma-voice`、`voice`，只命中 Hotlines 的文案注释。`answerCall` 只改 UI/DB 状态，不建立语音路由。`activeCalls` 也没有 `playerDropped` 清理（见 B15） | 先归一化 callId（B02）+ 全局来电监听（B04）；再接 `pma-voice` 的 call channel（或明确标注“仅 UI 模拟，不提供语音”，避免用户误以为坏了）。补玩家掉线/超时清理 |

### 1.2 P1/P2（高概率但优先级低于 P0）

| ID | 严重度 | 位置(file:line) | 现象推测 | 证据 | 修复建议 |
|:---|:---|:---|:---|:---|:---|
| B08 | P1 | `client/main.lua:549-565`；`custom-career/client/main.lua:3-6` | 领袖 App 的“动态注册/移除”从不生效；职业晋升/降级后手机必须重开才可能刷新（而 B06 又让图标根本不出现） | 客户端调用 `exports['custom-career']:GetLocalIdentity()`，但 custom-career 客户端只导出 `GetPlayerIdentity`（`custom-career/client/main.lua:6`）。`pcall` 把 “No such export” 吞掉，`success=false`，函数静默返回 | 改成 `exports['custom-career']:GetPlayerIdentity()`（客户端版本无参）或读取 `LocalPlayer.state.career_identity`；失败时 `print` 一次，不要静默 |
| B09 | P1 | `server/jobboard.lua:184-196`（`:187`）；`[custom]/custom-main/server`（无该 export） | 玩家到达任务点后 Job 被标记 completed，但**奖励不到账、完成通知不发**，回调也不返回；任务从列表消失但白干 | `exports['custom-main']:AddScaledMoney(...)` 在 custom-main 中不存在：`grep -rn "AddScaledMoney" custom-main` 只有引用没有 `exports('AddScaledMoney')`；`core-framework/compat.lua:12,24` 的注释也明确写“custom-main:AddScaledMoney(不存在)”。`jobboard.lua:184` 先执行 `UPDATE ... status='completed'`，`:187` 才抛 “No such export”，没有回滚 | 改走 `Bus.EconomyService.AddMoney` 或 `core_economy` 的统一奖励出口；用 `pcall` 包住，失败时把 status 回滚为 `taken` 并把错误回传给客户端；加一条“完成即到账”的集成测试 |
| B10 | P1 | `server/main.lua:234,243` vs `:259,267` | Job Board 永远显示旧数据：接单/完成后重开手机又变回 `open`；新发布的工程别人看不到；后台每 2 分钟的刷新完全无效 | Lua 词法作用域：`:234` 在函数定义时引用的是**全局** `phoneJobBoardCache`（因为局部变量在 `:259` 才声明，声明在函数之后）；函数内 `:243` 赋值到全局；而 `:259` 的同名局部只被后台线程 `:267` 写。结果：后台线程查了 20 行但没人读；首次查询的全局缓存永不失效 | 把 `local phoneJobBoardCache = { data = nil, expires = 0 }` 移到 `getPhoneData` 定义之前；后台线程更新同一个 local；post/accept/complete/share 后失效；用 TTL 而不是永久缓存 |
| B11 | P1 | `server/main.lua:120,130-136,194`；失效点只有 `:290,304,462,473,485`；无 `playerDropped` | 新短信/已读状态/联系人/任务状态在 30s 内重开手机不可见；手机关闭时收到的短信在重开后被旧缓存覆盖，像“消失”了；长时间运行后缓存随 citizenid 无限增长 | `phoneDataCache` 是普通 table，只按 citizenid 累积，没有玩家退出清理、没有容量上限；`sendMessage`、`markMessagesRead`、`acceptJob`、`shareContactNearby` 都不失效缓存。`getPhoneData` 在缓存命中时直接返回旧 `messages/contacts/jobBoard/notifications` | 写路径全部失效（或直接更新缓存）；`playerDropped` 时 `phoneDataCache[citizenid]=nil`；加 LRU/最大条数；同一玩家并发 open 加 in-flight 去重 |
| B12 | P1 | `server/main.lua:138,176-183,216-218`；DB `phone_numbers` 数据 | 多号码玩家的“我的号码”可能和实际收发号码不一致：自己发的短信显示在“对方”一侧、未读角标永远清不掉；发到第二号码的短信在线收不到、重登也查不到 | `phone_numbers` 实测有同一玩家两条 `is_primary=1`（`IYY39878`: `4075632296` 和 `5599802662`，`charinfo.phone=5599802662`）；`SELECT number, is_primary` 无 `ORDER BY`，`data.playerData.phone` 取“最后一个 primary”，不确定；短信查询/已读却固定用 `charinfo.phone`；`GetPlayerByPhone` 只比较 `charinfo.phone`，第二号码永远找不到在线玩家 | 数据层约束“每个 citizenid 只有一个 primary”（事务里先清零再置一，或生成列+唯一索引）；`getPhoneData` 返回 `ownNumbers` 列表；短信查询用 `receiver_number IN (...)`；NUI 用 `ownNumbers.includes(...)` 判断“我发的”，不要只比一个 number |
| B13 | P1 | `server/jobboard.lua:27-49`（`:38` decode、`:49` UPDATE）、`:61,204` | 两个玩家可同时接同一单，都收到成功和 GPS；`target_tags` 为 NULL/坏 JSON 时接单直接报错；完成后可能被重复结算 | `SELECT` 后独立 `UPDATE ... SET status='taken' WHERE id=?`，没有 `AND status='open'`，也没有事务/行锁；`json.decode(job.target_tags)` 对 NULL 会抛错（`getPhoneData` 里反而做了 `type(...)=='string'` 保护）；完成时同样只按 id 更新，没有 `taken_by` 条件 | `UPDATE phone_jobboard SET status='taken', taken_by=? WHERE id=? AND status='open'`，以 `affectedRows==1` 判定成功；`target_tags` 用 `pcall(json.decode)` + 空值兜底；完成改成 `WHERE id=? AND status='taken' AND taken_by=?` |
| B14 | P1 | `server/banking.lua:112-113`；对照 `oxmysql/dist/build.js:174-180` | 离线转账：发送方已扣款、收款方 DB 已加钱，但 UI 一直转圈/报错，审计日志和成功回调都不执行；极端情况下看不到回滚 | 该 oxmysql 后端的 `execute/update` 回调返回 `{affectedRows}` 表；`banking.lua:113` 却写 `if rowsChanged > 0`，在 Lua 中比较 table 和 number 会抛 “attempt to compare table with number”。此时 `UPDATE players ...` 已经执行，`Player.Functions.RemoveMoney` 也已执行 | 改为 `if type(rowsChanged)=='table' and rowsChanged.affectedRows > 0`（或统一 DB helper 后返回数字）；`LogEconomy` 用 `pcall` 包住，避免审计失败阻断资金回调；成功后显式 `cb` |
| B15 | P1 | `server/main.lua:774`（`activeCalls`）、`:802-831`、`:834-898`；无 `playerDropped` | 玩家掉线/崩溃后通话记录永远停在 `ringing`，`activeCalls` 泄漏；来电不接会一直响/占线；可被刷通话记录 | `activeCalls` 只在 reject/hangup 时删除；没有 `playerDropped`；没有振铃超时；`initiateCall` 无冷却/频率限制 | 加 `playerDropped` 清理（涉及该玩家的 call 全部结束并更新 DB）；加 30s 振铃超时线程；加每玩家通话冷却和 DB 状态索引 |
| B16 | P1 | `server/main.lua:680-698`（`getAllHotlineStatus`）、`:700-709`（`getHotlineStatus`）、`:712-741`（`triggerHotlineCall`）；`web/src/apps/Hotlines.svelte:6-13,35-49` | 热线在线人数永远 0 或面板加载失败；`getAllHotlineStatus` 和 `getHotlineStatus` 统计口径不一致（一个用 career role，一个用 QB `job.name`）；“热线呼叫”只是给值班人员发一条通知，没有真正通话/回拨 | `getAllHotlineStatus` 用 `identity.primary_role`（nil，见 B06）且 `jobTypes` 里是 `ambulance/mechanic/mayor/bank`，而 career role 是 `medic` 等；`getHotlineStatus` 用 `Player.PlayerData.job.name`；`triggerHotlineCall` 也是 `job.name`；Hotlines 列表写死 6 项并在 mount 时只查一次 | 统一用一个 `ResolveJobKey(identity)`（police/ambulance/mechanic/mayor/bank），统计口径统一为“QB job + onduty”或“career job_name + rank”；结果缓存 10s；热线按钮要么创建真实 callId 并进入振铃，要么明确做成“留言/派单”，不要假装接通 |
| B17 | P2 | `fxmanifest.lua:35-38`（dependencies）、`:30-33`（files） | 单独 `ensure custom-phone` 时 `exports['custom-ui']/['custom-career']/['custom-main']` 可能不存在；`getPhoneData` 在 `server/main.lua:141` 没有 pcall，会直接报错、回调不返回；`favicon.svg` 404 | manifest 只声明 `qb-core`、`oxmysql`，但代码依赖 `custom-ui`（client `:8,29`）、`custom-career`（server `:141`, client `:551`）、`custom-main`（banking `:69,124`、jobboard `:142,177`）；`files` 只包含 `resources/[custom]/custom-phone/html/index.html` 和 `html/assets/*`，`html/favicon.svg` 没被打包；`html/icons.svg` 未被引用 | dependencies 补 `custom-ui`、`custom-career`、`custom-main`；`getPhoneData` 的 career export 用 `pcall` 并降级到 civilian；`files` 加 `html/favicon.svg`（或删掉 index.html 里的 favicon 引用）；加 `onResourceStop`/`onClientResourceStop` 释放 NUI 焦点 |
| B18 | P2 | `client/main.lua:25-46`（`:38-39` 忙等）、`:5-22`（`ClosePhone` 早退）；`custom-ui/client/main.lua:14,46-65` | 打开动画字典迟迟不加载时线程永久 `Wait(0)`；在加载窗口内关闭手机，`isPhoneOpen=false` 后线程仍会 `SendNUIMessage('phone:open')`，出现“UI 开着但 Lua 认为已关/焦点残留”；与 qb-menu 等其它 NUI 同时打开时互相抢焦点（custom-ui 只有一个全局 `isOpen`，没有栈） | `while not HasAnimDictLoaded('cellphone@') do Wait(0) end` 不检查 `isPhoneOpen`；`ClosePhone` 在 `isPhoneOpen==false` 时直接 return，不再释放焦点；phone 不检查 `exports['custom-ui']:IsMenuOpen()` | 动画加载加超时（例如 2s）并在每次循环检查 `isPhoneOpen`；`SendNUIMessage('phone:open')` 前再确认一次状态；`ClosePhone` 即使 Lua 状态为 false 也执行一次焦点释放（幂等）；custom-ui 改成引用计数/栈，或 phone 打开前检查并关闭其它菜单 |
| B19 | P2 | `web/src/App.svelte:115-122`（天气未使用）、`:176-183`（天气硬编码）；`web/src/apps/Messages.svelte:53-70`（失败静默） | 短信发送失败时用户看不到任何错误（输入已清空）；首页天气永远 “72°F Sunny”，Lua 每秒发来的 `weatherIcon/weatherLabel` 没人用；`Config.MaxMessagesPerNumber`/`NotificationExpiry`/`JobAcceptCooldown` 都没实现，历史数据无限增长 | `Messages.svelte:64-67` 只有 `if (res.success)` 分支，没有 else/错误提示；`App.svelte` 的模板写死 `72°F`/`☀️ Sunny`；`grep` 三个 Config 字段在 client/server 无引用 | 发送失败保留输入并显示 `res.message`；首页使用 `weatherIcon/weatherLabel`；实现或删除三个 Config；加消息/通知保留策略 |
| B20 | P2 | `html/assets/index.css`（`@import https://fonts.googleapis.com/...`） | NUI 首次打开可能被外部字体请求拖慢/卡住（离线或被墙时更明显），首屏字体回退不一致 | `grep` 到 CSS 顶部 `@import "https://fonts.googleapis.com/css2?family=Inter...&family=Outfit..."`；FiveM 的 NUI 不应依赖外网资源 | 把 Inter/Outfit 字体文件 vendor 到 `html/assets/fonts/` 并用本地 `@font-face`；或直接删掉外链，使用系统字体 |

---

## 2. 性能问题表

> 说明：当前 DB 里消息/通知都是 0 行，所以这些不是“现在已经在烧 CPU”的问题，而是**加人/加历史后必然出现**的结构性问题；按 48 人、每玩家每天几百条消息估算。

| 问题 | 位置 | 影响 | 优化 |
|:---|:---|:---|:---|
| 每次打开手机 fanout 5 条查询（contacts/numbers/messages/jobs/notifications），其中 3 条 `SELECT *`；打开高峰会放大 | `server/main.lua:123-256`（`:200,208,216,238,251`） | 48 人同时登录/反复开关：每人每 30s 一次 = ~1.6 次/s × 5 = 8 qps；缓存过期瞬间并发叠加；`SELECT *` 把 `message/gps` 等大字段一起读 | 用一条 `getPhoneData` 聚合查询（或多语句 batch）替代 5 次 round-trip；只 SELECT 需要列；缓存 TTL 按数据分片（contacts 60s、messages 增量、jobs 60s）；同一玩家并发请求 in-flight 合并 |
| 消息查询是全局 `LIMIT 100`，没有分页/按会话查询；`Config.MaxMessagesPerNumber` 未实现 | `server/main.lua:216-218`；`config.lua:7` | 聊得多的玩家会把旧会话挤出 100 条，旧线程从 UI 消失；表无限增长；每次仍扫 100 行 | 加 `(receiver_number, timestamp)`、`(sender_number, timestamp)` 复合索引；按会话 `WHERE (a,b) ... LIMIT 50` 分页；打开线程时拉该会话；后台按 `Config.MaxMessagesPerNumber` 归档/删除；加 `since_id` 增量同步 |
| Job Board 缓存作用域 bug：后台线程每 2 分钟查 20 行写到一个没人读的 local；首次全局缓存永不刷新 | `server/main.lua:234,243,259-268` | 每 2 分钟一次无效查询；UI 永远旧数据；接单/完成后重开回退，导致重复接单/重复导航 | 修作用域（见 B10）；用 `{data,expires}` TTL；写路径失效；不需要后台线程，打开时按 TTL 拉取即可 |
| `phoneDataCache` 无淘汰、无玩家退出清理 | `server/main.lua:120,194`；无 `playerDropped` | 玩家越多、运行越久内存越高；每个 citizenid 持有 100 条消息 + 50 条通知 + 联系人 + 20 个 job 的 Lua table | `playerDropped` 清理；LRU/最大 N 条；缓存只存 id/摘要，正文按需取 |
| `GetPlayerByPhone` 每次 O(players) 遍历；`getNearbyPlayers` 每次 O(players) 取坐标；`faction` 广播/`getAllHotlineStatus` 每次 O(players) 调 export | `server/main.lua:109-117`（短信/银行/通话）、`:568-596`、`:685-690`、`server/faction.lua:23-28` | 48 人时单次 48 次；短信高峰/组织广播时放大为 O(n²) 级别；`GetPlayerPed/GetEntityCoords` 是服务端每玩家开销 | 维护 `phoneNumber -> source` 索引（玩家加载/换号/退出时更新），`GetPlayerByPhone` O(1)；`getNearbyPlayers` 先按 bucket/距离粗筛；hotline 人数按 job 变更事件维护计数器，或缓存 10s |
| `GlobalState.FactionMessages` 每发一条消息就整表重新赋值，触发所有客户端的状态复制 | `server/faction.lua:16-20` | 每条组织消息把最多 4×50 条历史复制给所有客户端；刷屏时带宽/序列化开销线性上升 | 只 `TriggerClientEvent` 推增量消息（已有 `phone:client:factionReceive`）；历史按需 `getPhoneData` 取；不要把全量历史放进 `GlobalState` |
| `getCityFeed` 每次打开都 `LEFT JOIN players` 并逐行 `json.decode(charinfo)` | `server/main.lua:496-516` | 30 行 × JSON decode；玩家表大时 join 成本上升；频繁打开时重复计算 | 缓存 feed 15-30s；`phone_cityfeed` 冗余存 `name`（发布时快照）或用覆盖索引；只查需要的列；分页 |
| `likeCityFeed` 每次点击 2 条 SQL，且无“每人只能赞一次”约束/速率限制 | `server/main.lua:551-561` | 可被连点/脚本刷爆；每次更新+查询 | 新增 `phone_cityfeed_likes(post_id,citizenid)` 唯一键，`INSERT IGNORE` 后按计数缓存；加节流 |
| NUI 在收到短信/联系人/组织消息时重算 `smsThreads`（全量分组+排序）；`phone:updateTime` 每秒写 store 触发 Home/状态栏重渲染 | `web/src/stores/phone.ts:57-101`；`web/src/App.svelte:115-122`；`client/main.lua:133-146` | 100 条内可接受；但消息多时每次 append 都 O(n log n)，每秒 time store 更新会重渲染状态栏/首页 | `smsThreads` 用增量/索引 Map 维护；`phone:updateTime` 只在 `hour/minute` 变化时发送（客户端比较后再 set）；通话计时已有 1s interval，可复用 |
| 客户端手机打开期间每帧 `Wait(0)` + 约 20 个 `DisableControlAction` + `DisableDisplayControlActions` | `client/main.lua:99-148` | 单机 CPU 开销很小，但每帧调用 20+ native；与其它资源同时禁控时可能冲突 | 把禁用列表集中为常量；只在打开/关闭时切换 `DisableDisplayControlActions`；保留必需的 WASD/相机控制；用 `Wait(0)` 是合理的，不必改 |
| oxmysql 后端 `insert/update` 返回 table 与上游不一致；多处调用还在猜类型 | `[standalone]/oxmysql/dist/build.js:168-181` | 不只是 phone，所有资源都要兼容两种返回；错误在回调里才爆，启动期发现不了 | 与上游 oxmysql 语义对齐（insert→number、update→affectedRows），或做统一封装；加 CI 契约测试（mock 返回 table 和 number 各跑一遍） |

---

## 3. “职业 App 扩展点”现状

### 3.1 结论：**没有注册点，目前是全写死**

新增一个警察/EMS/出租车 App，当前需要同时改 NUI、客户端、服务端、manifest 四层，且权限判断分散在各模块。具体改动面：

| 层 | 文件 | 需要做什么 |
|:---|:---|:---|
| 清单 | `fxmanifest.lua:15-21` | `server_scripts` 增加新 server 文件（或在现有文件里加 callback） |
| 服务端 | `resources/[custom]/custom-phone/server/main.lua`、`resources/[custom]/custom-phone/server/banking.lua`、`resources/[custom]/custom-phone/server/jobboard.lua`、`resources/[custom]/custom-phone/server/faction.lua` | 新增 `QBCore.Functions.CreateCallback('phone:server:xxx')`；每个 callback 自己写角色/等级校验；没有统一权限层 |
| 客户端 | `client/main.lua:237-400` | 每个 NUI action 手工加一个 `RegisterNUICallback` + `TriggerCallback`（当前 30+ 个） |
| NUI 路由 | `web/src/App.svelte:274-300` | `{#if $activeApp === '...'}` 链加分支；`:185-249` 首页网格加按钮 |
| NUI 权限 | `web/src/App.svelte:147-159` | `getLeaderAppIcon` 只认 `mayor/police/gang`，且依赖 B06 的 `primary_role` |
| NUI 组件 | `web/src/apps/*.svelte` | 新建组件；`web/src/apps/leader/*.svelte` 是现有领袖 App 样板 |
| NUI 状态 | `resources/[custom]/custom-phone/web/src/stores/phone.ts` | 新 store/加载字段；`loadPhoneData` 里逐个 `set` |
| NUI mock | `web/src/utils/nui.ts:130-350` | `switch (eventName)` 加 mock 分支（否则浏览器预览不可用） |
| 构建 | `resources/[custom]/custom-phone/html/assets` 下的 hash 化 bundle | 改完 `web/src` 必须 `npm run build`，否则线上跑的是旧 bundle |
| 热线 | `web/src/apps/Hotlines.svelte:6-13`、`server/main.lua:682` | 热线列表和 `jobTypes` 各自写死，新增职业要两处同步 |

> 当前已有“职业”相关模块：`resources/[custom]/custom-phone/server/banking.lua`（银行，所有人）、`resources/[custom]/custom-phone/server/jobboard.lua`（Job Board + Mayor 发布）、`resources/[custom]/custom-phone/server/faction.lua`（组织频道 + Sheriff/Gang 指令）、`web/src/apps/leader/*`（Mayor/Sheriff/GangBoss）。它们不是 App 框架，只是 3 个独立脚本 + 3 个独立组件。

### 3.2 建议的最小接口（服务端权威 + 注册制）

目标：新增 police/EMS/taxi 只写“一个 server 模块 + 一个 Svelte 组件 + 一条注册”，不改核心。

**服务端（新增 `resources/[custom]/custom-phone/server/phone_apps.lua`，在 main 之前加载）**

```lua
PhoneApps = { defs = {} }

-- def = {
--   id = 'police', label = 'MDT', icon = '👮',
--   roles = { 'police' }, min_tier = 'entry',
--   actions = { patrol = function(src, cb, payload) ... end }
-- }
function PhoneApps.Register(def)
    PhoneApps.defs[def.id] = def
    for action, fn in pairs(def.actions or {}) do
        QBCore.Functions.CreateCallback(('phone:server:app:%s:%s'):format(def.id, action),
            function(src, cb, payload)
                if not PhoneApps.CanUse(src, def) then
                    return cb({ success = false, message = 'forbidden' })
                end
                return fn(src, cb, payload)
            end)
    end
end

function PhoneApps.CanUse(src, def)
    local id = exports['custom-career']:GetPlayerIdentity(src)
    local role, tier = PhoneRole.Of(id)          -- 唯一解析器（见 B06）
    if not PhoneRole.In(role, def.roles) then return false end
    return PhoneRole.TierAtLeast(tier, def.min_tier or 'entry')
end

function PhoneApps.Allowed(src)
    local out = {}
    for id, def in pairs(PhoneApps.defs) do
        if PhoneApps.CanUse(src, def) then out[#out+1] = { id=id, label=def.label, icon=def.icon } end
    end
    return out
end
```

`getPhoneData` 返回 `apps = PhoneApps.Allowed(source)`；客户端/NUI 只渲染服务端允许的 App。

**客户端（通用路由，替代 30+ 个手写 callback）**

```lua
RegisterNUICallback('appAction', function(data, cb)
    QBCore.Functions.TriggerCallback(
        ('phone:server:app:%s:%s'):format(data.app, data.action), cb, data.payload)
end)
```

**NUI（注册表，替代 if/else 链）**

```ts
// web/src/apps/registry.ts
export const apps = import.meta.glob('./apps/*.svelte', { eager: true });
// App.svelte:
//   $allowedApps.map(a => <button onclick={() => activeApp.set(a.id)}>...)
//   <svelte:component this={apps[`./apps/${activeApp}.svelte`]?.default} />
```

**权限解析器（唯一实现，替代散落的 `primary_role`）**

```lua
PhoneRole = {}
function PhoneRole.Of(identity)          -- identity 来自 custom-career
    if not identity then return 'civilian', 'entry' end
    if identity.gang_name and identity.gang_name ~= 'none' then return 'gang', identity.rank_tier end
    local job = (identity.job_name or ''):lower()
    local map = { police='police', ambulance='medic', doctor='medic', mayor='mayor',
                  judge='justice', lawyer='justice', mechanic='mechanic', taxi='taxi' }
    return map[job] or 'civilian', identity.rank_tier or 'entry'
end
```

### 3.3 加 police/EMS/taxi 的最小改动清单

- **不改核心、按现有写法**：`fxmanifest.lua`（+1 行 server 文件）→ `server/apps/<job>.lua`（新增 callbacks）→ `resources/[custom]/custom-phone/client/main.lua`（每个 action +1 个 NUI callback）→ `web/src/apps/<Job>.svelte`（新增组件）→ `resources/[custom]/custom-phone/web/src/App.svelte`（import + 分支 + 首页按钮；若是领袖 App 还要加 `getLeaderAppIcon` 映射）→ `resources/[custom]/custom-phone/web/src/utils/nui.ts`（mock 分支）→ `npm run build`。约 **6-8 个文件/职业**，其中 `App.svelte`、`resources/[custom]/custom-phone/client/main.lua` 会反复冲突。
- **采用上面的注册制后**：`server/apps/<job>.lua` + `web/src/apps/<Job>.svelte` + 一条 `PhoneApps.Register`（可放在 server 模块内）；`App.svelte`/`resources/[custom]/custom-phone/client/main.lua`/`fxmanifest.lua` 只改一次。**约 2 个文件/职业**，权限自动继承 `roles/min_tier`。
- **现有可复用的能力**：`exports['custom-career']:PlayerMatchesTags(src, tags)` 已存在（`custom-career/server/main.lua:218`），可以直接做 `target_tags`/职业门控，不要再用 `primary_role` 手写 if。
- **建议先修的扩展前提**：B06 的角色解析、B02 的 DB 返回值、B08 的客户端身份 export；否则新 App 也会复制同一批 bug。

---

## 4. 现场检查记录

### 4.1 日志（`/tmp/fxserver.log`，去 ANSI 后 441 行）

- custom-phone 相关只有两行，没有启动错误、没有运行期错误：
  - `136: [c-scripting-core] Creating script environments for custom-phone`
  - `137: [resources] Started resource custom-phone`
- 没有 `[phone]` 输出：客户端 `print(('[phone] GameTime=...'))` 只在打开手机时执行；本段日志里 `story-engine` telemetry 一直 `nuiOpen:false`，说明没有人打开手机，因此日志不能证明“运行正常”，只能证明“资源加载成功”。
- 日志里唯一与本资源相关的“角色”线索：`450: [custom-career] Loaded: 我说不可 | 职业: Law Enforcement | 组织: 洛圣都警察局 (LSPD) | 等级: Chief | 阶层: leader`。这正好命中 B06：该玩家是警察领袖，但 `primary_role` 不存在，手机不会出现 Command App。
- 其它错误（与本资源无直接关系，但同期存在）：
  - `439: [qb-ambulancejob] SCRIPT ERROR: @qb-ambulancejob/server/main.lua:482: attempt to index a nil value (local 'Player')`
  - `441: [qb-core] SCRIPT ERROR:`（空消息）
  - `449/454/456/463: server thread hitch warning: timer interval of 1051/256/245/236 milliseconds`。这里无法归因到 phone（当时没有 phone callback 执行），但说明启动/玩家加载阶段服务端有卡顿，建议单独查。
- 结论：**日志没有暴露 phone 的 bug，因为 phone 采用“静默失败”**（SQL 错误由 oxmysql 回调吞掉、NUI 不展示错误）。这正是需要补日志/错误提示的地方。

### 4.2 文件 / 资源大小 / 缺失资源

| 检查项 | 结果 |
|:---|:---|
| 资源总大小 | `716K`（49 个文件） |
| `html/` | `192K`；`resources/[custom]/custom-phone/html/assets` 下的 hash 化 bundle **114,519 B**，`index.css` **47,809 B**，`index.html` **437 B / 14 行** |
| `resources/[custom]/custom-phone/html/index.html` 只有 14 行？ | **正常**。它是 Vite 的 dist 壳：`<div id="app">` + 同目录 `assets` 下的入口 bundle + `./assets/index.css`；dist 存在，不是缺失文件 |
| `web/` 源码 | `372K`；没有 `node_modules`；`web/src` 是 Svelte 5 + Vite 源码 |
| `fxmanifest.lua` | `ui_page 'html/index.html'`；`files` 包含 `resources/[custom]/custom-phone/html/index.html`、`html/assets/*`；`client_scripts` 只有 `resources/[custom]/custom-phone/client/main.lua`；`server_scripts` 顺序为 `sms.lua` → `main.lua` → `banking.lua` → `jobboard.lua` → `faction.lua`，sms 在 main 之前，正确 |
| 依赖 | 只声明 `qb-core`、`oxmysql`；实际还依赖 `custom-ui`（client `:8,29`）、`custom-career`（server `:141`、client `:551`）、`custom-main`（banking `:69,124`、jobboard `:142,177`）——manifest 未声明，见 B17 |
| 缺失/404 | `html/favicon.svg` 存在但未在 `files` 中，`index.html` 引用 `./favicon.svg` → NUI 404；`html/icons.svg` 是未引用的死资源；`html/assets` 的 JS/CSS 文件名非 hash（Vite 配置 `entryFileNames: 'assets/[name].js'`），改源码后容易忘记 rebuild |
| 外部资源 | `html/assets/index.css` 顶部有 `@import https://fonts.googleapis.com/...Inter/Outfit`，NUI 首开可能被外网字体阻塞，见 B20 |
| 构建一致性 | `resources/[custom]/custom-phone/html/assets` 下的 hash 化 bundle 与 `web/src` 同仓库提交；`App.svelte`/`phone.ts`/`PhoneShell.svelte` 的 mtime 晚于 bundle，但当前 bundle 已包含 `phone:removeLeaderApp`、`phone-backdrop-mask`、`phoneTargetNumber` 等新逻辑；改 `web/src` 后仍需 `npm run build`，manifest 不会自动构建 |

### 4.3 数据库（只读）

连接串来自运行中的 `server.cfg`（`mysql://swk:***@localhost/TCityLite`），只执行 `SELECT/SHOW/DESCRIBE` 和一次回滚的 INSERT 复现：

- 存量数据量：`phone_notifications=0`、`phone_messages=0`、`phone_contacts=0`、`phone_calls=4`（全部 `missed`）、`phone_cityfeed=5`、`phone_jobboard=0`、`phone_numbers=2`。
- **`phone_messages` 结构不匹配**（B01 的决定性证据）：
  - 实际列：`id,citizenid,number,messages,gps,msg_status`
  - 代码期望：`id,sender_number,receiver_number,message,timestamp,is_read,gps,msg_status`
  - 直接执行 `SELECT * FROM phone_messages WHERE sender_number='1' OR receiver_number='1' ...` → `ERROR 1054 (42S22): Unknown column 'sender_number' in 'WHERE'`
  - 回滚 INSERT `(sender_number,receiver_number,message)` → `ERROR 1054 ... in 'INSERT INTO'`
  - `SHOW INDEX FROM phone_messages` 显示旧索引 `citizenid`/`number`，没有 `idx_receiver/idx_sender/idx_time`。
- `phone_numbers` 有重复 primary：`IYY39878` 同时有 `4075632296` 和 `5599802662` 两条 `is_primary=1`；`charinfo.phone=5599802662`（B12）。
- `players` 已有 `phone_number` 虚拟列 + `idx_players_phone`（`migrations/v2.1_perf_indexes.sql:9-17` 已执行），但 `banking.lua:76-79` 仍用 `JSON_UNQUOTE(JSON_EXTRACT(charinfo,'$.phone'))` 全表扫描，未用已有索引。
- `phone_jobboard` 为空：Job Board 打开就是空列表；结合 B06/B09/B13，市长发单和完成结算都不可用。
- `phone_calls` 4 条都是 `missed`，没有 `ringing/ongoing/completed`，与“没有客户端实际打电话/或者无法接通”一致；没有 `playerDropped` 清理的痕迹。

### 4.4 关键 grep / 静态证据

| 检查 | 结果 |
|:---|:---|
| `grep -rn "primary_role" --include=*.lua --include=*.svelte .` | 只命中 custom-phone（server/client/web）；custom-career 完全不返回该字段 |
| `grep -rn "GetLocalIdentity"` | 全仓库只有 `custom-phone/client/main.lua:551` 一处；custom-career 客户端只有 `GetPlayerIdentity`（`:6`） |
| `grep -rn "AddScaledMoney"` | custom-phone `jobboard.lua:187` 引用；custom-main 没有 `exports('AddScaledMoney')`，只有 `compat.lua:12,24` 注释说明其不存在 |
| `grep -rn "mumble\|pma-voice\|voice"`（custom-phone） | 只命中 Hotlines 的文案注释，没有通话语音集成 |
| `grep "phone:client:newNotification"` | client `:413` 注册，server 至少 8 处触发；client 内又 `TriggerServerEvent('phone:server:storeNotification')`，服务端 `:447` 再触发，闭环成立 |
| `grep "playerDropped"`（custom-phone） | 无任何命中；`activeCalls`/`phoneDataCache` 无退出清理 |
| `grep "MaxMessagesPerNumber\|NotificationExpiry\|JobAcceptCooldown"` | 只在 `config.lua` 定义，client/server 零引用 |
| `grep "oxmysql.*insert"` 契约 | `dist/build.js:171` 返回 `{insertId,affectedRows}`；`tests/unit/layer3_business/test_vehicleshop.py:152` 注释明确说明 |
| 测试覆盖 | `resources/[custom]/custom-testing/suites/08_phone_test.lua` 主要用 `LoadResourceFile` 做静态字符串/表存在性断言（例如 2.1 只查 `SHOW TABLES LIKE 'phone_messages'`），没有列校验、没有事件回环测试、没有 insert 返回值测试，因此上述 P0 全绿 |

---

## 5. 建议修复顺序（不是代码改动，仅排序）

1. **先做 B01 + B02 + B14 的数据层**：迁移/新建 `phone_messages`，统一 `insert/update` 返回契约。否则后面所有功能验证都会被“静默 DB 错误”污染。
2. **再做 B03 + B04 + B07 的事件/通话层**：断通知回环（否则修好短信后第一笔短信就会把服务器打爆）、全局来电监听、callId 归一化、语音/超时/掉线清理。
3. **再做 B06 + B08 + B09/B10/B11 的身份与缓存层**：角色解析器、`GetLocalIdentity`、`AddScaledMoney`、job cache 作用域、phoneDataCache 失效/淘汰。
4. **最后做索引/分页/保留策略与体验项**（第 2 节、B18-B20），并在 CI 加“列齐全 + insert 契约 + 通知不回环”的测试。

---

## 6. 结论摘要（最后 6 行）

1. 最可能解释“手机还是有问题”①：DB 里 `phone_messages` 仍是 qb-phone 旧列，custom-phone 的短信 SELECT/INSERT 全部 1054 报错且被 NUI 静默吞掉 → 发短信没反应、历史为空（本机 DB 与测试 fixture 均可复现）。
2. 最可能解释“手机还是有问题”②：手机内全局 M 键监听 + `keepInput=true` 与 M 开关键位冲突，任何输入框打 `m/M` 都会立刻关手机，表现为“打字打一半手机没了/按 M 开不出来”。
3. 先做优化①：统一数据访问层——幂等迁移 `phone_messages`，并把定制 oxmysql 的 `insert/update` 返回值归一化（insert→数字、update→affectedRows），一次修好短信/通话/接单/联系人/点赞。
4. 先做优化②：拆掉 `phone:client:newNotification` → `phone:server:storeNotification` → 回推的无限回环，同时给 `phoneDataCache` 加写路径失效、`playerDropped` 清理和容量上限。
5. 先做优化③：加复合索引 + 会话级分页/保留策略，去掉 `SELECT *` 与每开屏 5 条查询的 fanout；`GetPlayerByPhone`/Hotline 人数改 O(1) 索引/缓存，避免人数增长后的 O(n²)。
6. 职业 App 最小改动面：现在每个职业要改 6-8 个文件（manifest + server 模块 + `resources/[custom]/custom-phone/client/main.lua` + `App.svelte` 的 import/分支/图标 + 新 Svelte 组件 + nui mock + rebuild）；先落 B06 的统一角色解析器和 `PhoneApps.Register/CanUse` 注册接口，可压到“1 个 server 模块 + 1 个 Svelte 组件”。
