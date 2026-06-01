# QBCore Lite 技术讨论记录

## 当前项目位置

主项目目录：

```text
D:\txData\QBCore_CDB34E.base
```

关键路径：

```text
D:\txData\QBCore_CDB34E.base\server.cfg
D:\txData\QBCore_CDB34E.base\resources\[qb]\qb-core
D:\txData\QBCore_CDB34E.base\resources\[qb]
D:\txData\QBCore_CDB34E.base\resources\[custom]\custom-main
```

当前服务器是完整 QBCore base，`server.cfg` 中使用了：

```cfg
ensure qb-core
ensure [qb]
ensure [standalone]
ensure [voice]
ensure [defaultmaps]
ensure custom-main
```

这意味着服务器启动时会一次性加载大量 QBCore 资源。

## 目标

开发一个精简版、可拓展、安全、启动较快的 QBCore 私服基础版本。

核心目标：

```text
启动快速
资源模块化
功能可迭代
玩家加载负担低
安全边界清晰
方便后期扩展
```

## 技术方向

不建议直接大改 `qb-core` 本体。建议以现有 QBCore 为基础，做成模块化 Lite Server Pack。

核心思路：

```text
文件可以先保留
资源不再一口气 ensure [qb]
通过白名单启动必要资源
按版本逐步加入系统
自定义逻辑放在 [custom] 下
```

## 资源加载理解

模块化不代表后期玩家永远只加载少量资源。

它解决的是：

```text
开发阶段不要过早加载不用的系统
测试阶段减少干扰
正式服按功能模块清楚启用
方便定位报错和性能问题
```

后期正式服如果开放大量功能，玩家仍然会加载很多资源。因此玩家加载速度的核心还包括：

```text
资源体积
图片数量
stream 资产大小
NUI 前端大小
客户端常驻线程
SendNUIMessage 频率
资源之间重复依赖
```

## 推荐启动分层

建议把资源按模块拆分：

```text
core        核心框架、数据库、基础依赖
player      登录、角色、出生、背包、HUD
voice       语音、无线电
jobs        普通职业
police      警察、医院、监狱、门锁
crime       抢劫、毒品、黑市
vehicles    车库、车钥匙、车店
housing     公寓、房产
maps        地图、MLO、IPL
custom      自定义服务器逻辑
```

第一阶段建议最小启动：

```cfg
ensure oxmysql
ensure qb-core
ensure qb-menu
ensure qb-input
ensure qb-target
ensure qb-multicharacter
ensure qb-spawn
ensure qb-apartments
ensure qb-inventory
ensure qb-hud
ensure qb-weathersync
ensure pma-voice
ensure custom-main
```

暂时不启动的资源示例：

```text
qb-phone
qb-houses
qb-clothing
qb-policejob
qb-ambulancejob
qb-bankrobbery
qb-doorlock
qb-garages
qb-vehicleshop
qb-drugs
qb-houserobbery
qb-storerobbery
qb-jewelery
qb-lapraces
qb-streetraces
```

注意：第一阶段先禁用，不删除。

## UI 与图片策略

图片、模型、音频等 stream 资源通常比 Lua 脚本更影响玩家加载速度。

建议：

```text
优先使用 GTA5 原生素材
简单交互使用 qb-menu / qb-input / qb-target / 原生 UI
复杂界面使用 NUI
大图片、大背景、大动画谨慎使用
```

适合原生或轻量菜单的功能：

```text
任务点
小地图图标
NPC 交互
商店菜单
职业选择
车库列表
```

适合 NUI 的功能：

```text
手机
背包
HUD
银行
警用 MDT
角色创建
管理后台
小游戏
```

## 前端技术栈

TypeScript 和组件化可以提高可维护性，但不会自动提升性能。性能取决于最终打包体积和运行方式。

推荐方向：

```text
Lua：QBCore 服务端/客户端逻辑
TypeScript：NUI 前端类型约束
Svelte + Vite：复杂 UI，例如手机、HUD、银行、MDT
原生 GTA/QB 菜单：简单交互
```

FiveM NUI 性能注意点：

```text
避免大量高清图片
避免每帧 SendNUIMessage
关闭 UI 后停止定时器
列表使用分页或虚拟滚动
只在状态变化时更新 UI
打包产物尽量小
```

## 安全方向

高风险操作必须由服务端最终决定。

重点审计：

```text
AddMoney
RemoveMoney
AddItem
RemoveItem
SetJob
SetGang
GiveWeapon
车辆生成
商店购买
抢劫奖励
任务奖励
```

规则：

```text
客户端只能请求，不能决定结果
服务端校验距离、职业、权限、物品、冷却时间
高价值操作写日志
敏感事件加 rate limit
密钥、数据库密码、Discord webhook 不进公开仓库
```

## 成本评估

```text
只做精简启动：0.5 到 1 天
做到模块化可维护：3 到 5 天
做到稳定 Lite 版本：1 到 2 周
加安全审计：再加约 1 周
重做主要 NUI：2 到 6 周，视范围而定
```

推荐不要一开始重做手机、背包等大系统。先做启动链和模块边界。

## 推荐版本路线

```text
v0.1 精简启动
保留登录、出生、背包、HUD、语音、基础商店、车库

v0.2 基础 RP
加入警察、医院、车辆钥匙、银行、基础职业

v0.3 经济系统
加入自定义经济调节、日志、奖励统一出口

v0.4 复杂 UI
选择手机或 HUD 作为 TypeScript/Svelte 样板

v0.5 犯罪玩法
逐步加入抢劫、毒品、黑市
```

## 下一步建议

1. 复制一份新 base，例如：

```text
D:\txData\T-CityLite.base
```

2. 不动原始 `QBCore_CDB34E.base`。

3. 在新 base 中重写 `server.cfg`，用白名单资源替代 `ensure [qb]`。

4. 启动测试，记录缺失依赖。

5. 建立模块配置目录，例如：

```text
configs\modules\core.cfg
configs\modules\player.cfg
configs\modules\voice.cfg
configs\modules\custom.cfg
```

6. 后续逐步加入 jobs、police、crime、vehicles、housing、maps。
