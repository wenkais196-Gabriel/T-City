---
id: ux-menu-regression-checklist
type: runbook
status: active
system: ux
owner: hermes
updated: 2026-11-26
review_by: 2027-02-28
---

# qb-menu / qb-input 适配层 · 20 条最小真机清单

> 对应 issue #366。范围**只有适配层**：145 处调用点（`tests/architecture/menu_surface_baseline.json`）
> 一行不改，`qb-menu` / `qb-input` 仍然是调用入口。本清单不需要、也不检查"全量迁移"。
>
> 开关：`setr qb_menu_use_custom_menu true` → `refresh`（改了 fxmanifest）→ `restart qb-menu`、
> `restart qb-input`。**关掉这个 convar 就是回滚路径**，清单里每一条都应在关掉时表现一致
> （除了"跨资源误关"这条在旧实现下本来就是坏的，见 §3）。
>
> 记号：**[单]** 一个账号即可。每条都按「资源 / 打开方式 / 选一项 / 关闭方式 / 期望」过；
> 没通过时先看 §4 的已知差异，再判断是不是适配层回归。

## 1. 先过这 5 条（覆盖最容易出事的路径）

| # | 资源 | 打开方式 | 选一项 | 关闭方式 | 期望（人不卡住、焦点回游戏） |
|---|---|---|---|---|---|
| 1 | `qb-mechanicjob` | 机修店对载具按 ALT →「维修 / 改装」 | 任意子菜单项 | `Esc` | 菜单消失后立刻能走动、能开火；不会呼出暂停菜单 |
| 2 | `qb-pawnshop` | 当铺 NPC/柜台交互 →「卖出物品」 | 一件物品 → 输入数量 | 表单里点「取消」 | 回传 `nil`：不发服务端事件、不掉物品、不扣钱；人能立刻动 |
| 3 | `qb-vehicleshop` | 展厅载具 ALT →「购买」 | 一台车 → 进入分期表单 | 表单 `Esc` | 不产生订单；光标释放、人物可移动 |
| 4 | `qb-management` | `/orgmenu`（或组织坐标区按 E） | 任意二级菜单 | `Backspace` 再 `Esc` | 第一次返回上一级（内容正确，不是回到最外层）；`Esc` 后焦点回游戏 |
| 5 | `qb-input`（表单面） | 任一 `ShowInput`：如当铺卖出、`custom-industry` 卖出 | 填一个数字 → 提交 | 再开一次 → `Esc` | 提交的值与旧表单一致（字符串数字）；取消那次调用方拿到 `nil` |

## 2. 20 条最小路径（每个调用资源至少一条）

| # | 资源 | 打开方式 | 选一项 | 关闭方式 | 期望（人不卡住、焦点回游戏） |
|---|---|---|---|---|---|
| 1 | `qb-mechanicjob` | 机修店对载具按 ALT →「维修」 | 维修项 | `Esc` | 动作执行；焦点释放 |
| 2 | `qb-mechanicjob` | 同店「外观 / 喷漆」→ 选择类表单 | 改一项后提交 | 表单「取消」 | 取消不写车漆；人可移动（这是"不支持的类型回退旧 NUI"路径） |
| 3 | `qb-vehicleshop` | 展厅载具 ALT →「购买」 | 一辆车 → 分期表单 | 表单 `Esc` | 无订单、无扣款；焦点释放 |
| 4 | `qb-vehicleshop` | 展厅载具 ALT →「试驾」 | 试驾项 | `Esc` | 试驾结束/菜单关；可开火 |
| 5 | `qb-pawnshop` | 当铺交互 →「熔炼」 | 一件物品 | `Esc` | 不熔炼；焦点释放 |
| 6 | `qb-pawnshop` | 当铺交互 →「洗钱」 | 输入金额 → 提交 | 提交后 | 服务端收到金额；菜单自己关闭 |
| 7 | `qb-management` | `/orgmenu` | 二级菜单项 | `Backspace` | 回到上一级（标题 / 面包屑正确） |
| 8 | `qb-management` | 组织坐标区按 E（Boss 菜单） | 雇员项 | `Esc` | 菜单关；焦点回游戏（旧实现会关到别人的菜单，这里只关自己的） |
| 9 | `qb-clothing` | 服装店热区 / `/clothing` 入口 | 任一分类 | `Esc` | 菜单关；人物可动 |
| 10 | `custom-police` | 上班 LEO → 警局车库或扣押场 | 取车/扣押项 | `Esc` | 菜单关；警用动作正常 |
| 11 | `qb-houses` | 房屋门 ALT → 钥匙管理 | 任一子项 | `Esc` | 菜单关；门锁状态不异常 |
| 12 | `qb-apartments` | 公寓入口 ALT → 公寓菜单 | 任一子项 | `Esc` | 菜单关；不误触传送 |
| 13 | `qb-cityhall` | 市政厅 NPC 交互 | 身份/工作菜单项 | `Esc` | 菜单关；不重复发证件 |
| 14 | `qb-ambulancejob` | 医院载具菜单 | 取车项 | `Esc` | 菜单关；可移动 |
| 15 | `qb-adminmenu` | `/admin` | 任一子项 | `Esc` | 这是 menuv 垫片（M1 #353），不走本适配层；不许回归成"Esc 呼出暂停菜单" |
| 16 | `custom-mining` | 冶炼厂交互 → 熔炼菜单 | 任一矿石 | `Esc` | 菜单关；焦点释放 |
| 17 | `custom-justice` | 司法菜单（律师/减刑入口） | 减刑项 | `Esc` | 菜单关；不发二次请求 |
| 18 | `custom-cartel` | 供应商/分销商 NPC 交互 | 买卖项 → 数量表单 | 表单「取消」 | 取消回传 `nil`；不交易 |
| 19 | `custom-industry` | `/industry`（或 Boss 菜单注入项） | 任一子项 | `Esc` | 面板关；焦点释放 |
| 20 | `qb-shops` | 送货菜单 | 任一送货项 | `Esc` | 菜单关；不重复接单 |

## 3. 归因与叠栈的专项验证

| # | 场景 | 操作 | 期望 |
|---|---|---|---|
| A | 跨资源误关（反例 #1） | A 资源打开 qb-menu 菜单 → 另一个资源调 `exports['qb-menu']:closeMenu()` | A 的菜单**仍在**；只有 A 自己关才生效（自动化用例 `test_qb_menu_adapter.py` 覆盖） |
| B | 重复 open（反例 #2） | 同一资源连开两次菜单 | 只出现一个浮层；后一次替换前一次，不叠窗 |
| C | 三层嵌套（反例 #3） | 一级 → 二级 → 三级，连按两次 `Backspace` | 依次回到二级、一级；内容与选中状态正确 |
| D | custom-ui 重启 | 菜单开着时 `restart custom-ui` | 菜单消失、焦点回游戏；再开菜单正常，无残留 |
| E | 输入框取消 | `qb-input` 表单 `Esc` 或点取消 | 调用方 `if not result then` 分支命中；线程不悬挂 |

## 4. 已知差异（适配层打开时才出现，属预期）

1. **`showHeader` 无被动渲染**：custom-menu 没有"不抢焦点、只画一行提示"的 surface。
   适配层打开时该导出是 no-op；`UseTarget true` 时 `qb-vehicleshop` / `qb-pawnshop` /
   `custom-police` 的 `showHeader` 路径都不执行，真机走不到。
2. **`select` / `radio` / `color` / `checkbox` 表单回退旧 NUI**：MenuSpec 的 form 只有
   text/password/number/toggle/range，硬翻译会丢选项值。含这些类型的对话框整张走旧
   `qb-input` 页面（`qb-mechanicjob` 的喷漆/颜色表单即此路径），行为与改造前一致。
3. **异步 reopen 不自动叠栈**：`params.event` 里先 `TriggerCallback`、回调里再 `openMenu`
   的二级菜单（如 `qb-pawnshop` 的卖出列表）会成为新的根菜单；它们自带的"返回"项仍然可用
   （点击后显示上一级内容，但会多压一层）。同步 reopen 才有自动叠栈。
4. **`custom-ui` 被占用时不开**：旧 `qb-menu` 会直接抢焦点叠上来；适配层尊重
   `custom-ui:IsTaken()`，手机/其它 UI 开着时菜单不打开。先关当前 UI 再交互。
5. **物品图标**：老 `openMenu` 会把 `QBCore.Shared.Items` 里同名图标换成
   `nui://qb-inventory/...`；适配层按 issue 约定「icon 原样」透传，custom-menu 对未知
   图标名显示通用图标。功能不受影响。
6. **同一资源在表单开着时调 `closeMenu()` 会连带关闭表单**：`qb-input` 的 form 与
   `qb-menu` 的列表共用 custom-menu 宿主，归属都是同一资源。旧实现是两个独立 NUI
   页面，只关自己的。真机路径上暂未发现会同时发生（表单会锁住移动，区域离开通常
   在表单关闭后），但改相关流程时要按这条检查。
7. **并发顶开**：A 的表单/菜单开着时，B 资源打开新菜单会替换宿主内容。A 的
   `qb-input:ShowInput` 会一直等待（轮询只认"宿主关了"，认不出"被换掉了"）。旧实现
   同样是单焦点、同样会卡住，只是表现不同；不要在真机上同时开两套 UI 验这条。

8. **服装店（`qb-clothing`）外观完全不变，这是预期**：它不走 `qb-menu`，是自己的一套 NUI
   预览界面（qb-clothing 的 client 里直接调 `SetNuiFocus`）。适配层不接管、也不该接管 ——
   看到"服装店还是老样子"不是漏接，是它本来就在范围外。要统一外观需要单独迁移这个资源。
9. **产业面板（组织菜单里的「产业」）信息行语义（#374 已收口）**：无 `params.event` 的 `disabled = true`
   信息行由适配层自动映射为 `kind = 'info'`（`hint = txt`），左标签正常字重 + 右对齐亮值、无 hover /
   无焦点描边 / 方向键跳过 / 点击无反应；带 `params.event` 的不可用动作行（「雇工位」「卖出」）保留
   `disabled = true` + `disabledReason` 压暗提示。关掉 `qb_menu_use_custom_menu` 回退旧 `qb-menu` 时行为与改造前一致。
10. **`restart custom-ui` 会把打开中的菜单收掉**：custom-ui 是焦点宿主，重启它等于把帧连根拔掉。
   适配层现在会在宿主卸载时主动收摊并放焦点（`onClientResourceStop`），所以是"菜单消失、人能动"，
    不再是"菜单看不见、人也卡死"。要在菜单开着时重启宿主，预期就是菜单被关掉。

## 5. 记录

| 日期 | 执行人 | convar | 结果 | 备注 |
|---|---|---|---|---|
| 2026-11-26 | 宋文凯（真机） | true | **通过** | 当铺（qb-target + qb-menu）、车店、服装店、组织/产业面板、adminmenu 均验；差异见 §4 第 8/9/10 条 |
| 2026-11-27 | 宋文凯（真机） | true | **通过** | 方案 A 信息行语义：产业面板 6 行信息不再压暗、数值右对齐；方向键跳过信息行；点信息行无反应；`卖出` 保持可用态、`雇工位` 仍是 disabled + 原因（金库余额不足） |
| — | — | false（基线） | 待跑 | 回滚路径（`setr qb_menu_use_custom_menu false` → `restart qb-menu`） |
