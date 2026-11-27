---
id: changelog
type: meta
status: active
system: meta
owner: hermes
updated: 2026-11-27
review_by: 2027-04-30
---

# Changelog

All notable changes to T-City Lite will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed
- **菜单宽度被静默压窄 + 适配层重启后菜单全打不开（`custom-menu` / `qb-menu`）**：
  ① **宽度回归**：#383 的标题是「产业面板方案 A —— 信息行语义」，却顺手把共享的
  `.menu-shell` 宽度从 **520px 改成 300px**，所有走新菜单的界面一起变窄（标题折行、配额折行、
  禁用行说明折成两行）。现改为声明式：`:root` 新增 `--menu-width: 520px` /
  `--menu-width-min: 320px` / `--menu-width-max: 640px`，`.menu-shell` 只许引用
  `var(--menu-width*)`，并新增基线 `T-CityLite.base/tests/architecture/menu_theme_baseline.json`
  —— **改宽度必须同 commit 改基线**，review 时是一行显式 diff；
  `T-CityLite.base/tests/architecture/test_menu_width_tokens.py` 钉住四件事（token 存在、
  引用而非字面量、与基线一致、区间 300–640），并自证「改回 300 / 改成看着也合理的 440 /
  删 token」三种偷改都会红。
  ② **适配层重启自愈**：`qb-menu` 用 `state.routes` 记住 intent 注册过，而 `custom-menu`
  一被 `restart` 注册表就空了 —— 之后每次 open 都跳过注册、被 `Open` 整单拒绝
  `Unknown intent "qb-menu:qb-management:menu"`，玩家按 E / `/orgmenu` 什么都开不出来。
  现在 `onClientResourceStart('custom-menu')` 会清空记忆，且 `Open` 因 `Unknown intent`
  失败时会重注册并重试一次。
  ③ **运行期开关生效**：`isEnabled()` 原来在 `GlobalState == false` 处短路，而
  `server/adapter_state.lua` 是启动时把 convar 快照写进 `GlobalState` —— 于是运维
  `setr qb_menu_use_custom_menu true` 之后不重启就永远不生效（convar 兜底成死代码）。
  现在 `false` 不再短路，`setr` 即时生效。

### Changed
- **产业周期公告推送（警告 + 结果，`custom-industry` / `custom-phone`，#389）**：
  ① `T-CityLite.base/resources/[custom]/custom-industry/server/announce.lua` 在既有公告水位
  （`warning_announced_at` / `result_announced_cycle`）之后按在线组织成员调用 `custom-phone`
  的 `Notify` 导出：`app_id = industry`、`meta.source` 取 `Player.PlayerData.source`，
  组织判定只走 `IndustryAccess.OrgMembership`；推送没有自己的水位，同一周期只发一次；
  ② `T-CityLite.base/resources/[custom]/custom-phone/server/core/notify.lua` 的
  `NOTIFY_APP_IDS` 放行 `industry`，通知因此能深链进产业 App；
  ③ **边界**：只有**在线**且属于 `Config.Industry.OrgWhitelist` 的成员会收到推送，
  离线成员靠 CityFeed 历史公告补看，不做全服广播、不伪造离线推送；推送失败
  （导出缺失 / 抛错 / 写库失败）只打日志，不阻断公告与结算；标题/正文只含周期号、
  组织名、金额、时间，不含玩家名、坐标、citizenid、余额明细。
  新增 `T-CityLite.base/tests/unit/layer3_business/test_industry_push.py` 7 条用例
  （2 成员 + 1 非成员 → 恰好 2 条、重复 tick → 0 条新增、`industry_enable=false` → 0 条、
  推送抛错结算照常完成、`app_id` 与 PII、结果推送）；反向注入删掉 warning 水位后
  重复 tick 用例变红（2 → 6），还原后绿。
- **M6b —— `qb-management` 老板菜单与组织菜单合并为单入口，关闭按 owner 归因（#385）**：
  ① **单入口与单菜单面板**：删除重复的 `cl_boss.lua` 与 `cl_gang.lua`，统一收敛至 `T-CityLite.base/resources/[qb]/qb-management/client/cl_org.lua`，同一坐标在 `[E]` 提示与 `qb-target` 下均仅注册一次，并将「老板视图 · 人事与库存」（成员管理、招新、仓库、更衣室）与「组织视图 · 治理与扩展」（退位交接、`custom-industry` 「产业」等动态挂载项）分区合并进同一菜单；保留全部 `qb-bossmenu:client:*` / `qb-gangmenu:client:*` 兼容事件、Cartel 个人面板与帮派地图标记；
  ② **owner 归因关闭与焦点防叠**：拆分提示条显示状态与菜单持有权 `activeMenuOwner` / 区域锚点 `activeZoneCoords`，`CloseMenuFull(owner)` 仅在归属本资源且 `custom-ui` 栈顶属于菜单平面时才关闭对应 `qb-menu`，解决无坐标 `/orgmenu` 自闭及误关其它资源（如 `/industry`）界面问题，同时在打开前通过 `custom-ui:IsTaken()` / `Top()` 拦截在手机等活跃界面上叠开（`qb-management` 保持 `0` 处 `SetNuiFocus`）；
  ③ **取证与闸门**：`menu_surface_census.py` `qb_menu_entry` 由 159 降至 139（`qb-management` 22 → 2）、`orgmenu_export` 由 10 降至 6（`qb-management` 8 → 4）、`setnui_focus` 保持 195（`qb-management` 0）；更新 `T-CityLite.base/tests/architecture/test_management_feedback_contract.py` 增加单入口与归因关闭反向注入 + Lua 5.4 运行时沙箱验证，并同步 `T-CityLite.base/tests/architecture/menu_surface_baseline.json` 与 `docs/plan/next-wave/01-candidates.md`。
- **手机端产业动作入口（卖出 / 雇工位，`custom-phone` / `custom-industry`，#388）**：
  ① **服务端**：`T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua` 新增导出
  `HireIndustryWorkstation`，直接复用 `IndustryUi.HireWorkstation`——成员身份与
  `IndustryAccess.IsOrgBoss` 判定仍只有这一份；手机 App
  `T-CityLite.base/resources/[custom]/custom-phone/server/apps/industry.lua` 新增 `hire` 动作，
  参数只收 `orgId`，金额/工位号一律由服务端从配置与 SQL 计算（客户端传了也不读）；
  ② **前端**：新增 `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Industry.svelte`
  （快照只读、卖出 estimate → 确认 → sell、雇工位显示 `nextWorkstationCost` / `hireBlocked`），
  `T-CityLite.base/resources/[custom]/custom-phone/web/src/core/appRegistry.ts` 注册 `industry`；
  `dyn:industry` 仍先查专用页面，注册缺失（旧构建 / 构建失败）时回落 `DynamicApp` 只读列表；
  ③ **回退修复**：`T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/DynamicApp.svelte`
  在 runes 模式下把 `rows` / `loading` / `error` / `message` / `feedback` 改成 `$state`，
  否则异步结果永不触发重渲染，回退列表实际停在「暂无数据」；
  ④ **测试**：`T-CityLite.base/tests/unit/layer3_business/test_industry_ui.py` 新增端到端用例
  （非成员不可见、Boss 卖 5 件时 `industry_sales` / `org_ledger` 各一行、非 Boss 伪造
  `sell` / `hire` 返回 `not_boss`、越权 orgId 返回 `not_member`、被拒请求零写入），
  `T-CityLite.base/tests/unit/layer3_business/test_phone_apps.py` 增加页面注册/回退与参数契约断言，
  NUI harness 新增 5 条产业场景（含注册缺失回落 `DynamicApp`）；导出面接线断言更新为 5 个 export。
  构建产物 `T-CityLite.base/resources/[custom]/custom-phone/html/` 已重建并提交。
- **M7 —— 手机双 `Wait(0)` 合一 + prompt 去重 + 菜单架构棘轮（#349）**：
  ① **手机单点每帧泵**：将 `T-CityLite.base/resources/[custom]/custom-phone/client/core/device_lock.lua` 中的独立 `CreateThread` + `Wait(0)` 循环改为无线程 `DeviceLock.Tick()`，并入 `T-CityLite.base/resources/[custom]/custom-phone/client/main.lua` 唯一主循环内调用（闭合退出及 `onResourceStop` / `onClientResourceStop` 仍显式 `DeviceLock.End()`）；`client_wait_zero` 从 219 降至 218（`custom-phone` 2 → 1）；
  ② **`custom-prompt` 上下文去重**：`T-CityLite.base/resources/[custom]/custom-prompt/client/main.lua` 为 `SetContext` 增加同内容快照比对（`ClearContext` 重置），避免每帧调用方重复刷新 NUI；新增 `T-CityLite.base/tests/unit/layer3_business/test_custom_prompt.py`、更新 `T-CityLite.base/tests/unit/layer3_business/test_phone_surface.py` 与 `T-CityLite.base/tests/agent/lua/cases_client/phone_focus.lua`；
  ③ **菜单架构棘轮**：新增 `T-CityLite.base/tests/architecture/test_menu_architecture.py` 与 `T-CityLite.base/tests/architecture/menu_focus_allowlist.json`，约束 `SetNuiFocus*` 只允许出现在 `ApplyFocus` / `onResourceStop` / `onClientResourceStop` 三边界并对全仓调用点按文件登记，棘轮锁定 `menuv_entry`、`disable_all_controls`、`backdrop_filter`、`cdn_ref` 与 `client_wait_zero` 并校验 `T-CityLite.base/tests/architecture/menu_surface_baseline.json` 每个数字可由 `tools/dev/menu_surface_census.py` 实时复算（含反向注入自证）；`docs/DEVOPS.md` 补充 `menu` 影响面标签。
- **M6a —— `qb-adminmenu` 迁出 `menuv` 接入 `custom-menu` + 下线 `menuv`（#348，`qb-management` 拆分至 #385）**：
  ① **逐屏迁移（17 张原 MenuV 菜单 + 拆出子视图全部走 MenuSpec）**：新增 `T-CityLite.base/resources/[qb]/qb-adminmenu/client/menu_specs.lua` 纯构建器与 `AdminMenuIntent` 跨资源导出，按屏迁完 `menu1`–`menu15` 及动态 `Players` / `EditDealer`——`Server Time (00..23)` 与 `Entity View Distance (5..50)` 复用 `range` surface，`Permissions` 与删 dealer 复用 `confirm` surface，`Kick` 与 `Ban`（预设时长列表 + 自定义秒数/原因）复用 `form` surface，零新增 UI 组件；
  ② **去除原生键盘与每帧禁控**：删掉 `T-CityLite.base/resources/[qb]/qb-adminmenu/client/client.lua` 的 `LocalInput` / `LocalInputInt`（`DisableAllControlActions(0)` 2 处清零，只保留 `T-CityLite.base/resources/[qb]/qb-adminmenu/client/noclip.lua` 飞行模式 3 处），删掉 `T-CityLite.base/tests/architecture/m4_focus_allowlist.json` 的 `qb-adminmenu-local-input-disable-all` 条目，修复 `godmode` 在 NUI 回调线程里阻塞的隐患；
  ③ **下线 `menuv` 与退场临时垫片**：删除 `#353` 过渡垫片 `menu_shim.lua`、去掉 `T-CityLite.base/resources/[qb]/qb-adminmenu/fxmanifest.lua` 的 `menuv` 引用和 `T-CityLite.base/configs/modules/core.cfg` 的 `ensure menuv`，清零 `T-CityLite.base/tests/architecture/input_layer_allowlist.json` 的 `unintegrated_menu_ledger`，`T-CityLite.base/tests/check_dependencies.py` 将 `menuv` 标为已下线延期，保留 `menuv` 资源目录只读；
  ④ **闸门与反向注入**：更新 `T-CityLite.base/tests/architecture/test_adminmenu_input_shim.py`、`T-CityLite.base/tests/architecture/test_input_layer_contracts.py` 与 `T-CityLite.base/tests/architecture/menu_surface_baseline.json`（`menuv_entry` 47 → 29，仅剩只读 `menuv` 目录自身；非 `menuv` 引用清零），Lua 5.4 沙箱实测全部 17 屏通过 `MenuSpec.Validate`，且把任一屏改回 `MenuV` / 恢复 `menu_shim.lua` / `LocalInput` 均变红。
- **产业数值卡与真实周期长度（`custom-industry`，#387）**：周期正式定为 **28 天**（10/10/5/3）；
  设计稿 §5 的「结算 2 天」不再当第五阶段，结算是衰退结束边界上的一次事件（`SettleCycle`），状态机不改。
  正式数值：`industry_units_per_hour` 12→**4.5**（满建 10×4.5=45 ≥ 衰退期 50% 配额所需的 43.65）、
  `industry_demand_seed` 10→**11,000**/阶段（单组织上限 5,500/4,675/3,850/2,200，四阶段 16,225 件/周期）、
  `stockCap` 144→**540**（满建 12h；旧值按 1 工位算，满建 1.2h 就触顶）、
  `industry_prestige_k` 500→**50,000**（满建约 3 点/周期，$5M 累计正好 +20% 封顶）；
  售价 $50、`baseCost` $50,000、1.35 工位曲线、`OrgCapRatio` 0.5、每级 +2%/上限 +20% 保持不动。
  回本口径改为**净现金** `C/(R−C)`（S7 每周期清空设施，必须扣重建成本）：设施+首工位 $100,000
  对应 1 工位 **$157,540/周期、净回本 6.95 周**；推荐 4 工位 **$630,280/周期、6.14 周、日毛利 $22,510**；
  满建 10 工位 **$796,812/周期、日毛利 $28,457**（配额饱和上限，非利润最优）。
  新增 `T-CityLite.base/tests/unit/layer3_business/test_industry_balance.py` 9 条断言，
  并把三条反向注入（阶段天数 +1 / `SeedQuota` 回 10 / `OrgCapRatio` 改 1.0）实际跑红后恢复。
  文档同步：`docs/server-design/12-industry-operations.md` §5/§10/§20/§21、`docs/plan/industry-ops/07-plan.md`。
- **产业面板方案 A —— 信息行语义落地（`custom-menu` / `qb-menu` / `custom-industry`，#374）**：
  ① **契约层（`T-CityLite.base/resources/[custom]/custom-menu/shared/menu_spec.lua`）**：巩固 `MenuSpec.KINDS.info = true` 语义——`info` 项为只读信息（必填 `label`，值放字符串 `hint`），校验显式拒绝 `action` / `params` / `intent`，缺失 `hint` 可正常通过，非字符串 `hint` 与非 JSON-safe 值均报错；
  ② **渲染与样式（`T-CityLite.base/resources/[custom]/custom-menu/html/renderer.js`、`T-CityLite.base/resources/[custom]/custom-menu/html/styles.css`）**：`info` 行左标签正常字重（`rgb(226,232,240)`）+ 右对齐亮值（`rgb(248,250,252)`）、无 hover、无焦点描边、无 `›` 箭头、不压暗、不加 `disabled` class（含虚拟列表分支）；方向键 `ArrowDown`/`ArrowUp` 与初始焦点跳过 `info` 行，点击无 intent/toast 副作用；卡片宽度收敛至 `300px` 且全量字号 `>= 12px`；不可用动作行维持压暗 + `disabledReason`；
  ③ **适配层与调用方（`T-CityLite.base/resources/[qb]/qb-menu/client/adapter.lua`、`T-CityLite.base/resources/[custom]/custom-industry/client/main.lua`）**：无 `params.event` 且 `disabled = true` 的 legacy 项映射为 `kind = 'info'`（`hint` 取 `txt`），带 `params.event` 的 `disabled = true` 项保持禁用动作并携带 `disabledReason`；为 `custom-industry` 两条真正受阻的写操作（雇工位 / 卖出）补回 `params.event` 使其保持禁用动作语义，信息行零改动自动生效，关闭 `qb_menu_use_custom_menu` 回退旧渲染；
  ④ **测试与反向校验**：新增 `T-CityLite.base/resources/[custom]/custom-menu/tests/nui/run.mjs`（Node DOM 单元 + 无头 Chromium CDP 实测）、`T-CityLite.base/tests/unit/test_menu_schema.py` / `T-CityLite.base/tests/architecture/test_menu_host.py` / `T-CityLite.base/tests/architecture/test_qb_menu_adapter.py` 自证用例与 `tools/dev/gate_mutation_smoke.py` 适配层回归变异用例。

  **真机（2026-11-27）**：`industry_enable=true` 的本地服务器上，产业 App 打开正常
  （诊断 `kind=query app=industry code=ok`），卖出三次全部入账 —— `org_ledger` 当日
  `ref=sale:7` +250 / `sale:8` +8,900 / `sale:9` +50，`balance_after` 48,425 → 57,325 → 57,375
  逐条自洽；`industry_facility.stock` 204 → 2、`industry_demand.quota_used` 184。
  手机 `hire` 与非 Boss 只读**尚未真机走到**，记在 #397，参见
  `docs/plan/industry-ops/08-plan.md` §4.2。

### Fixed
- **周期探针的就绪判据改走 DB 事实（#392）**：preflight 原来要求控制台输出里出现 `settlement dry-run`，但 FXServer 的 stdout 重定向到文件是**块缓冲**，`print()` 可能几秒后才落盘，而 `--console-log` 只等 3 秒 → 真机上两次误报「industry_enable 未开」（功能其实正常）。改为：`industry_state` 有行即判就绪，控制台文本降级为提示；两处行为各有一条用例（有行必须过、无行必须报错）。
- **产业面板改为「信息行 + 动作行」两分（方案 A，#374）**：`MenuSpec.KINDS` 新增 `info` —— 只读信息行（标签 + 右对齐数值，不压暗、不进焦点、点击无反应），校验禁止它带 `action`/`params`/`intent`；qb-menu 适配层按「`disabled` 且无 `params.event` → 信息行」映射，所以 `custom-industry` 的信息行一行没改就变成信息行。真机 2026-11-27 通过。
- **M5 收尾：把剩下的 6 处 `backdrop-filter` 也清掉（@qb 三处）**：`qb-core` 通知容器、
  `qb-multicharacter` 三处面板、`qb-vehicleshop` 的 overdrive overlay。做法与 dashboard/banking 一致
  ——去掉模糊、提一点底色不透明度补偿层次。清完非排除资源真的为零（只剩 monitor 6 处，
  第三方打包产物，已登记在基线的 `excluded` 段）。
  同轮修两个**会让闸门假绿**的问题：① 闸门原来只扫 `src/`，而游戏加载的是 `html/` 与 `nui/dist/`
  ——源码干净、线上仍模糊（本次实测：改完不重建产物就等于没改），现在两处都扫；
  ② `menu_surface_census.py --json` 会把人手维护的 `excluded` 段冲掉，加 `carry_exclusions()`
  保留并重算 `non_excluded_total`。
  `backdrop-filter` 的判据也从「词出现」改成「真的在声明模糊」：Tailwind 产出的
  `transition-property: backdrop-filter, …` 与 `filter: var(--tw-blur,)` 不算违规（否则闸门被误报关掉）。

### Changed
- **M5 清理 `backdrop-filter` 与合并车机重复键盘监听（#347）**：
  ① **样式替换（源码层）**：将三项任务指定资源源码里的 `backdrop-filter` / `-webkit-backdrop-filter`
  替换为半透明深色渐变 + 顶部内高光（`inset 0 1px 0`）+ 边框，不改动 HTML/DOM 结构、按钮 id 与外链 CDN：
  `T-CityLite.base/resources/[system]/tcity-dashboard/nui/src/style.css`（`.dash-shell` 2 处，并移除 `--tcity-blur`，保留 `--tcity-bg-primary` 主题变量叠层）、
  `T-CityLite.base/resources/[system]/tcity-dashboard/nui/src/components/SeatPicker.vue`（`.seat-picker-card` 2 处）、
  `T-CityLite.base/resources/[qb]/qb-banking/web/src/app.css`（`.glass-panel` 2 处）、
  `T-CityLite.base/resources/[qb]/qb-banking/web/src/components/BankDashboard.svelte`（`.bank-container` 2 处）、
  `T-CityLite.base/resources/[custom]/hud-position-tool/html/overlay.html`（`#panel` 1 处）。
  ② **车机 `keydown` 监听去重**：合并 `T-CityLite.base/resources/[system]/tcity-dashboard/nui/src/App.vue` 中
  重复注册的 `document` 级 `onKeyDown` 监听到单一 `window` 级 `onKeydown`（并在 `onUnmounted` 同步清理
  `keydown` 与 `contextmenu`，同时保留 `SeatPicker` 可见时按 `Escape`/`Backspace`/`I` 关闭，避免输入框内误关），
  `T-CityLite.base/tests/architecture/test_dashboard_focus.py` 新增重复监听守卫。
  ③ **基线与架构闸门**：`T-CityLite.base/tests/architecture/menu_surface_baseline.json` 的 `backdrop_filter`
  新增 `excluded.monitor`（第三方 txAdmin 打包产物 6 处及理由）并更新实时计数（`24 → 15`，非排除 `9`）；
  新增 `T-CityLite.base/tests/architecture/test_no_backdrop_filter.py`（剥离注释、校验三项目标源码为 0、
  验证 `monitor` 排除正例与 `tmp_path` 反向注入变红、对全仓非排除资源设 0 命中门禁）。
  注：当前 worktree 未安装 `node_modules`，`tcity-dashboard/nui` 与 `qb-banking/web` 的构建产物待重编；
  另全仓仍存在未点名的 `qb-multicharacter`（3）、`qb-core`（2）、`qb-vehicleshop`（1）共 6 处存量 CSS 命中。

### Fixed
- **qb-target 的 client 脚本里 8 处 JS 可选链让整个资源解析失败**：`zone.targetoptions.drawColor?[1]` 不是合法 Lua（`unexpected symbol near '?'`），却从 2026-11 的架构重构一直留到现在 —— CI 的 `Lua syntax (changed files)` 只解析**改动过的**文件，存量错误永远检查不到；线上看起来没事是因为 FXServer 用编译缓存里的旧字节码，**重启就会整个 qb-target 不加载**。已改为 `(x or {})[n]`，并新增闸门 `T-CityLite.base/tests/architecture/test_lua_js_syntax_rejects.py`：剥掉字符串与注释后全仓扫描 JS 专有形（带自证用例：真实事故形状必须被抓到、字符串里的问号不许误报）。

- **qb-menu / qb-input 适配层跨资源注册 intent 失败（#366）**：custom-menu 的 intent 路由携带 `handler`/`builder` 闭包，跨资源边界被序列化丢弃（对面收到 nil），注册静默失败并回退旧 NUI。新增 `type='resource'` 路由（只带 `resource`/`method` 两个字符串，回调走对方资源导出的 `MenuIntent`），并把「路由不许带函数」写成自证闸门。同时修正：适配层开关改为**调用时**判断（`GlobalState` 优先、convar 兜底），避免事后 `setr` 必须重连才生效；关闭态回落到老路径（`closeMenu` 补传 `closeMenuLegacy`）。
- **M4 消费者接入 `custom-ui` 焦点栈（`qb-target` / `qb-inventory` / `qb-hud` / `story-engine`，#346）**：
  ① 四目录内门卫用途的原生焦点判重全部收口到调用期 `custom-ui:IsTaken()`（`qb-target` 开启眼标、`qb-inventory` `/openInv`、`qb-hud` `/hudsettings`、`story-engine` 看护恢复），门卫用途 `IsNuiFocused()` 清零；
  ② 四个资源统一通过 `custom-ui:Push`/`Pop` + `GuardControls` 管理焦点并导出 `ApplyFocus` 与 `ForceClose`、补齐 `onResourceStop` 焦点兜底释放，移除业务路径上的裸 `SetNuiFocus*` 调用，同时删除 `T-CityLite.base/tests/architecture/nui_client_allowlist.json` 中已修复的 `story-focus-no-stop-cleanup` 条目；
  ③ 移除 `qb-target` 菜单/眼标路径的每帧 `DisableAllControlActions(0)`，改为瞄准期定向屏蔽攻击/武器/交互/菜单键、打开菜单后由 `custom-ui` 帧 `allow` 白名单（行走 30–35 与 Alt 19）接管；
  ④ 新增 M4 架构闸门 `T-CityLite.base/tests/architecture/test_m4_focus_stack.py` 与allowlist `T-CityLite.base/tests/architecture/m4_focus_allowlist.json`（登记 `story-engine` 6 处诊断读取与 `noclip` / 死亡态 / `spawn` / 押送 / 原生键盘 8 处合法 `DisableAllControlActions`，逐条附理由与到期日，且按四目录范围做反向注入校验）。
- **配额双源对账（`custom-industry`，S6 前置，#364）**：全服已用原先只信可变计数器
  `industry_demand.quota_used`，单组织已用却由 `SUM(industry_sales.qty)` 派生；真机手动重置计数器后
  出现「全服剩 10、本组织剩 0」这种数学上不可能的状态。读取改为
  `max(quota_used, SUM(qty))`，`Inspect` 的 `orgRemaining` 再与 `globalRemaining` 取 min；
  计数器欠账时用 `UPDATE ... WHERE quota_used < ?` 条件回填（幂等）并写一条 `quota_drift`
  审计（payload 只含数字，不含玩家身份）。`SettleSale` 的原子预留 CAS、表结构与正常卖出路径的
  写入次数均不变。
- **S5 真机跑起来的四个缺陷（`custom-industry` / `qb-management`）**：
  ① 服务端与客户端都用 `type(qb.Functions.X) == 'function'` 判 QBCore 的函数，而本 build 里
  `exports['qb-core']:GetCoreObject()` 交出来的函数是**可调用表**（`type == 'table'`，靠 `__call` 调用），
  守卫恒假 —— 服务端 5 个 callback 一个都没注册（只留一行日志），客户端 `uiEnabled` 永远是 false
  （注入被自己挡掉）。改为只判 nil + `pcall`，并给注册加有界重试（500ms×60）。
  ② 客户端 `Money()` 是 qb-core 的客户端全局，本资源没 import，渲染第一行就
  `attempt to call a nil value (global 'Money')`。换成本地千分位实现（从右往左每 3 位分组；
  左侧贪婪正则会在长数字上反复插入逗号直到死循环）。
  ③ qb-management 的 Boss 菜单是**世界坐标触发区**，`Config.BossMenus` 里没有 `miner`，
  注入的菜单项没有任何入口可达；同时 `cl_boss.lua` 与 `cl_org.lua` 会遍历同一份坐标表在**同一坐标**
  注册两个菜单，玩家按 E 随机进其中一个。改为给组织菜单一个确定入口 `/orgmenu`（服务端校验成员身份），
  并新增 `/industry` 直开面板。
  ④ `cl_org.lua` 的提示循环会在「菜单开着但玩家不在 1.5m 内」时调 `qb-menu:closeMenu()`，
  这会关掉**任何**用 qb-menu 打开的界面。`/industry` 直开不置 `shownMenu`，因此不受影响。
- **三处 `type(x.Functions.y) == 'function'` 造成的静默故障（#363）**：本 build 里
  `exports['qb-core']:GetCoreObject()` 交出来的函数是**可调用表**（`type == 'table'`），
  那条守卫恒假。① custom-director 的广播通知：`delivered` 永远 0，**通知从未送达**；
  ② custom-quest 的 vendor `payCash`：守卫恒真 → 永远返回 false，**卖东西从不付款**（库存照扣）；
  ③ custom-phone 的 jobboard：只让顶层的 `AddMoney` 分支变成死代码（有玩家侧回退，无行为影响）。
  三处都改为只判 nil + `pcall` 调用。新增闸门
  `tests/architecture/test_qbcore_callable_table_guards.py`：全 [custom] 树静态零命中 +
  反向注入 3 种形状必须判红 + **行为对照**（把 `payCash` 抽出来，用 `__call` 元表模拟可调用表，
  断言真的付了钱且只调一次）。恢复事故前的写法 → 形状闸门与行为用例同时变红。
- **`qb-adminmenu` 接入 `custom-ui` 输入栈（#353）**：`/admin` 原先既不查栈也不入栈，真机表现为
  ① 手机开着时仍能叠开、② 菜单开着按 `Esc` 关不掉反而呼出游戏暂停菜单。新增垫片
  （qb-adminmenu 的 client/menu_shim.lua）：打开前问 `custom-ui:IsTaken()`（被占用则拒绝并提示），打开时
  `Push('adminmenu')`、关闭/强制关闭/资源卸载时 `Pop`；菜单开着期间只屏蔽暂停控制 `199/200`
  并用 `IsDisabledControlJustPressed` 消费 `Esc`。**不改 menuv 本体、不新增第二处 `SetNuiFocus`**。
  同轮停用 `/givenuifocus` 的焦点写入（命令与权限保留，只打印说明）——它是 qb-adminmenu 里唯一
  绕过栈直接写焦点的入口。存量 5 处 `DisableAllControlActions`（输入框循环、noclip）按 `#346` 的
  账保留，棘轮禁止新增。真机需 `refresh` 后再 `restart qb-adminmenu`（fxmanifest 改了）。
  新增闸门 `tests/architecture/test_adminmenu_input_shim.py`（三条规则 + 反向注入）。

### Added
- **qb-menu / qb-input 适配层（#366）**：`qb-menu` 与 `qb-input` 的 export 在 convar
  `qb_menu_use_custom_menu`（默认 **false**）打开时翻译成 `MenuSpec` 交给 `custom-menu`，
  存量 145 处调用点（20 个资源，`tests/architecture/menu_surface_baseline.json`）**一行不改**；
  convar 关着时走原路径，行为与改造前完全一致（回滚路径）。
  ① 归因：每次 open 用 `GetInvokingResource()` 记调用方，`closeMenu()` 只关调用方自己的
  session —— A 开菜单时 B 调 `closeMenu()` 不再误关 A（旧实现是全局单例）；
  ② 二级菜单：`params.event` 里同步再调 `openMenu` 的，走 custom-menu 的 submenu builder
  压栈，`Backspace` 能回上一级（异步 reopen 仍是新的根菜单，见清单 §4）；
  ③ `qb-input:ShowInput` → form surface，取消回传 `nil`；`select/radio/color/checkbox`
  MenuSpec 表达不了，整张对话框回退旧 NUI（行为不变）。
  新增行为闸门 `test_qb_menu_adapter.py`（Lua 沙箱跑真实源码：跨资源误关、重复 open、
  三层嵌套返回、表单提交/取消、convar 关闭对照）+ 静态红线（适配层 0 处 `SetNuiFocus`、
  0 个新 net event，均带反向注入）；真机清单 `docs/client/ux/menu-regression-checklist.md`。
- **S8 上线前收口（`custom-industry` + `tools/dev`，#375）**：
  ① **prestige 永久加成接线**：`org_treasury.prestige` 每 1 点 = 1 级、每级 **+2% 产能**，
  第 10 级封顶 **+20%**。加成只乘产能、不乘售价——售价已叠 `core_economy` 全局/热度与阶段倍率，
  再加一层货币倍率会把通胀从「库存上限 × 配额」挪到价格上；产能仍受这两道闸约束。
  加成在**读取路径**生效：生产结算每次从 `org_treasury` 读当前值（无账户 = 无加成，读库失败
  fail closed），`IndustrySales.Inspect` / UI 快照把等级与百分比随快照返回（只展示、不参与报价）；
  设施/卖单/结果表不新增任何倍率列，结算仍只写 prestige 绝对值。新增 convar
  `industry_prestige_bonus_per_level`（默认 0.02）与 `industry_prestige_max_level`（默认 10）。
  ② **真机周期验收脚本** `tools/dev/industry_cycle_probe.py --scale 60 --cycles 2`：
  自动压阶段/心跳、`restart custom-industry` 一次验证重启续跑、在衰退期连发两次
  `industry_settle confirm` 验证幂等、把 `phase_ends_at` 改到过去验证补推不跳段，
  结算前后对 `players` / `player_vehicles` / `inventories` / `player_houses` 做
  `CHECKSUM TABLE` 全等断言；脚本自带 SQL 静态守卫（个人层只允许读）并在结束时恢复
  `industry_state` / 结果 / 配额 / 设施 / 金库，只留 `industry_audit` 作为验收痕迹。
  ③ **结算崩溃恢复演练**：新增「设施已删、卖单还没删」的离线用例——重跑收敛到
  设施/卖单/配额/余额全 0、prestige 只发一次，`cycle.settle` 审计恰好一条。
  验证：新增 5 条 prestige 用例 + 1 条删一半崩溃用例 + 45 条探针离线契约；
  三条反向注入（删 +20% 上限、删生产读取倍率、删阶段顺序守卫）均实际变红后恢复。
- **S6 周期状态机 + S7 结算转生（`custom-industry`，#338，同一片）**：
  `industry_state` 单行表（`CHECK id = 1`）以绝对时间驱动四阶段（扩张/竞争/成熟/衰退）。
  推进线程挂在 S3 已有的 30 秒生产心跳上；`guarded UPDATE` 的 `affected == 1` 是唯一推进许可，
  停机跨边界按顺序**一次补推一格、不跳段**，重启从 DB 续跑。四阶段倍率接到既有读点：
  产能（S3）× 1.25/1.00/1.00/0.70，售价（S4）× 1.00/0.95/1.10/0.80，
  配额种子 × 1.00/0.85/0.70/0.40，购置在衰退期返回 `purchases_closed`（**卖出仍开放**）。
  压缩旋钮 `industry_cycle_scale` / `industry_phase_seconds`；唯一人为手段是控制台
  `industry_setphase`（restricted + `source == 0` + 审计）。
  结算 `industry_cycle_results`（`UNIQUE(org_id, cycle_no)`）按 `prestige = floor(sqrt(累计销售额 / K))`
  发威望；清分边界是**表级显式清单**：设施/库存、卖单、配额、金库余额全清，
  **个人层（`players` / 物品 / 车辆）一个字节不动**（静态扫描 + fixture 越界标记 + 前后 checksum 三层证明），
  `org_ledger` 补一条 `settlement-clear` 流水。`applied` 水位 + prestige 绝对值让结算中途崩溃可重试、
  不重复入账。`industry_settle [dry|confirm]` 默认 dry-run（只打印将删/将写行数，零写入）；
  结算前 7 天与结算结果各发一条 CityFeed 公告（每周期一次，失败不阻断结算）。
  迁移 `v4.4_industry_cycle.sql`；无新增 net event、无新增轮询线程。

- **S5 产业 UI（`custom-industry` + `custom-phone`）**：新增唯一读模型（custom-industry 的 server/ui.lua）
  （`Snapshot` / `EstimateSale` / `Sell` / `HireWorkstation`）——快照里配额是**两个数**
  （全服 `globalRemaining` 与单组织 `orgRemaining`，后者 = `floor(total × 0.5) − 已卖`），
  卖出上限 `maxQty = min(库存, 本组织剩余, 全服剩余)`，拒绝原因分 `stock_empty` / `org_cap_reached` /
  `demand_exhausted` 三种。Boss 菜单注入一项「产业」（qb-management `AddBossMenuItem`）：非 Boss 只看数、
  不出现写操作；未建厂只显示「尚未建设施」。手机侧注册 `industry` App（只读快照，按组织成员可见），
  **不改 `custom-phone/web/src`、无新增构建产物**。鉴权在 UI 层与销售层各复验一次（本片补了
  「非 Boss 到不了销售层」的短路用例），前端上送 `price/revenue/multiplier` 一律只记录不参与计算。
  无新增 net event（走 QBCore callback + export）。

- **S4 销售 / 配额（`custom-industry`）**：`industry_demand`（`cycle_no/phase/item_name` 主键，全服配额）与
  `industry_sales`（卖单流水，`UNIQUE(org_id, ref)` 幂等）。`SettleSale` 是**全仓唯一一个「无对应玩家扣款」的
  净增货币点**：服务端定价 × `core_economy:GetGlobalMultiplier()`，库存 CAS → 配额 CAS（全服剩余与本组织
  `SUM(s.qty) + ? <= FLOOR(quota_total × 0.5)` 写在**同一条 UPDATE**）→ 卖单落库 → `Treasury.Deposit`；
  任一步失败逐级回退，退不掉打 `CRITICAL` 并审计 `rollback_failed`。命令层只有控制台入口 `/orgsell`
  （convar `industry_sales_debug` 默认关、`restricted`、`source==0`）；`economy-dashboard` 新增
  `industrySaleInflow`（此前组织入账是通胀盲区）。迁移 `v4.3_industry_sales.sql`；无新增 NUI。
  真机：卖 5 件入账 $250、超 50% 得 `org_cap_reached`、同一 ref 只入账一次、全服剩余不足时按剩余截断。
- **组织 id 校验合并（`custom-industry` 的 server/org_id.lua）**：原本 S1–S4 各抄一份的校验（非空 / ≤64 / `^[%w_%-]+$`）从 S1–S4 各抄的
  合并为单一模块 `IndustryOrgId.IsValid`，`fxmanifest` 排在金库之前。

- **S1 组织金库（`custom-industry`）**：`org_treasury` / `org_ledger` / `industry_audit` 三张表，
  余额扣减守卫写在单条 `UPDATE … WHERE balance + ? >= 0` 里（affectedRows 裁决，无 TOCTOU），
  流水以 `UNIQUE(org_id, ref)` 做幂等键，插流水失败会把余额补偿回去。命令层只有
  `/orgfund`、`/orgfunddeposit`、`/orgfundwithdraw`、`/orgfundgrant` 四条服务端命令，
  convar `industry_enable` 默认关闭。迁移 `v4.0_industry_treasury.sql`；无 net event / NUI / exports。
- **S2 设施 / 工位（`custom-industry`）**：新增 `industry_facility`（一组织一设施）与
  `mine` 设施 / 铁矿石精炼配方配置。`Facility.Build` / `AddWorkstation` / `Get` 全部经
  `Treasury.Withdraw` 付款；工位成本 `floor(base × 1.35^(n-1))`，上限与乐观锁写在同一
  条 `UPDATE … WHERE workstations = ? AND workstations < ?` 里，写行失败/冲突会退款。
  命令 `/orgbuild`、`/orghire`、`/orgfacility`（Grade4，复用共享 `IndustryAccess.IsOrgBoss`）。
  迁移 `v4.1_industry_facility.sql`；无 net event / NUI / exports。
- **S3 离线生产（`custom-industry`）**：`IndustryProduction.Compute` 是纯函数
  （`dt = now - last_tick_at`，`effectiveDt = min(dt, max_catchup)`，
  `produced = floor(workstations × unitsPerHour × 倍率 × effectiveDt / 3600)`，
  库存截断 `min(期望产出, cap - stock)`）；tick / 玩家上线 / 控制台 `orgproduce`
  三条入口都走同一个 `SettleFacility`，没有离线专用公式。写库只走 `Db.Update`，
  以 `last_tick_at` 做 CAS，并发 tick 不会双算；产出只进 `industry_facility.stock`，
  满仓冻结且不产生任何通知/回执；`produced_units` 累计列供 S7 结算（迁移
  `v4.2_industry_production.sql`，幂等 `ADD COLUMN IF NOT EXISTS`）。新增 convar：
  `industry_tick_seconds`（默认 30）、`industry_max_catchup`（默认 3600）、
  `industry_units_per_hour`（默认 12）、`industry_production_debug`（默认 false，
  只注册 restricted 原生命令 `orgproduce`，仅控制台）。无 net event / NUI / exports，
  不碰 `Treasury`。
- **`docs/server-design/12-industry-operations.md`：产业运营 / 组织运营的 MVP 基础方案**（design-only，
  无代码）。Hermes 与 Claude Code 各出一版独立设计后合并，产出四样东西：① 五条**事实纠错**
  （组织钱包不是"不存在"而是 qb-banking 的 `bank_accounts` 半成品——缺负余额闸 / 幂等 ref /
  gang 账户预建 / 异步写；`custom-economy` 的服务端脚本是空的，所谓"自适应通胀刹车"不存在；
  组织是 25 条不是 19 条；周期状态不能住 `world_state`——它是 `(region_id, state_key)` 键且冷缓存
  返回 nil；组织入账走不了 `TriggerReward`——它第一步就 `GetPlayer(source)`）；② 向下依赖树
  （组织金库是唯一承重柱）；③ S1–S7 分片与两个里程碑（M1 闭环 / M2 周期+结算，S6 与 S7 必须同 PR）；
  ④ 8 张新表 + 三道通胀闸 + prestige 折算。另附 13 条读代码顺手发现的既有缺陷（4 条已复核：
  组织仓 `OpenInventoryById` 传字符串 id 导致打不开、`RemoveMoney` 不查余额、启动不建 gang 账户、
  v0.8 建的 9 张表里 7 张没有 owner）。配图三张在 `docs/server-design/assets/industry-ops/`。

### Added
- **单片计划的 `ALL` 行**：35 份 `type: plan` 里 15 份没有切片表（多是一次性的 police 施工图）。
  强制它们「先划片再登记」只会发明假粒度，所以规范补一条：**正文没有切片表时，`plan-status`
  只允许一行 `ALL | state | ev | date`**；有切片表时写 `ALL` 会按「ID 不在正文切片表」判红。
  看板对这类计划「片」列显示 `单片`、「当前片」显示 `整体 wip`。`gate_coverage` 预算 278 → 281
  （3 条前向规则，已在预算文件里写明到期条件）。

### Fixed
- **热狗顾客 INBOUND 走位 + 服务端报价时机**：顾客不再在摊位旁 2.2 m 原地出现，改在
  25–40 m 外生成并走到摊位前 2.4 m；服务端报价生命周期从 `now + patience_ms` 改成
  `now + inbound_budget_ms + patience_ms`（走位不再吃掉决策窗口），payload 下发
  `inboundMs` / `patienceMs` / `remainingMs` / `boothNetId`，并修掉接线方 `offerId = offer.id`
  （应为 `offer.offerId`，此前整条报价会被客户端忽略）。到位前状态条只显示「顾客正在走来
  （约 N 米）」，到位后才出 Y/N 面板与耐心倒计时；新增 `hotdog_inbound_probe.lua` 探针与
  5 条用例（含 2 条反向校验）。
- **摊位坐标服务端复验（红线①）**：`QuestBooth.Register` / `MoveTo` 之前把客户端申报的
  `pos` 原样入库，买家的 6 m 交互半径与 10 m 旁观者广播都按这条坐标算。现在服务端用
  实体真坐标复验申报点（容差 ≤3 m，失败返回 `bad_coords`），**入库/挪位只写实体真坐标**；
  `move` 分支的实体句柄取服务端记录里的 `booth.netId`，忽略 `payload.netId`。同时修好
  探针距离桩（`__len` 曾被当普通字段，Lua 的 `#` 恒为 0，距离判据从未执行），新增 5 条
  坐标复验用例 + 1 条「桩失效必须红」的反向用例。
- **`docs/plan/BOARD.md` 会静默过期**：PR #321 引入 `--board` 后，合并当天就踩到——另一个 PR（#320）
  把一份 md 改名，BOARD 里那行链接立刻指错，而块校验全绿，`--check` 对此一无所知。
  现在 `--check` 比对「重算 == 落盘」，过期或手改都报 `BOARD.md 不是最新`（WARN，与 `INDEX.md` 同口径），
  缺文件报「不存在」。测试用临时仓库跑真实 `main()`：生成→不报 / 追加一行→报过期 / 删掉→报不存在。
- **`docs_lifecycle.py` 的孤儿检测有盲点：手写的 `INDEX.md` 不算"有人引用"**。原实现按 basename 排除
  `INDEX.md`（本意是排除自动生成的文档总索引，否则孤儿恒为 0），结果把 `docs/client/ux/INDEX.md` 这种
  **手写导航宿主**也一起排除了——被它索引着的 5 篇文档被误报成孤儿。改为只排除生成的那一份
  （`docs/INDEX.md` 的绝对路径比较）。`--report` 实测孤儿 **11 → 6**，修完剩下 6 篇是真没人引用（见下条）。
  顺手把语料遍历抽成 `_corpus_text()`、读文件抽成 `_read_for_corpus()`（只吞 `OSError`，不吞 `Exception`）：
  `report()` 少了 10 行嵌套，异常范围也从"什么都吞"收到"只吞读不到"。

### Changed
- **仓库打扫与文档沉淀（维护轮）**：三件事。
  ① **孤儿清零**：修完上面的检测盲点后，剩余 6 篇逐个挂进正经宿主——
  `T-CityLite.base/docs/design/interaction-memo.md` → `T-CityLite.base/docs/README.md` 的文档表；
  `2026-11-foundation-p1-4-plan.md` / `-p1-6-plan.md` → 父计划 `2026-11-foundation-plan.md` 的 P1 表对应行；
  `docs/plan/jobs-content/03-plan.md` → `docs/plan/jobs-content-roadmap.md` §5「分批」；
  `2026-11-abstraction-audit.md` → 收敛计划的首行"唯一来源"（原文写的是 `abstraction-audit-report.md`，
  一个解析不到的名字，且该快照已归档）；
  另新建 `docs/plan/README.md` 作为计划目录索引（`agent-module-execution.md` 此前无宿主）。
  最终 `orphans=0 / dup_groups=0`，文档数 326。
  ② **`luac.out` 移出版本库**：Lua 字节码（3950 B，`luac5.4 <file>` 的默认输出名），自初始提交起被跟踪、
  全仓 0 引用、可再生产。`git rm --cached` + `.gitignore` 增加 `luac.out`。
  ③ `PROJECT_PROGRESS.md` 补记「2026-11 结构治理 ✅」。
  验证：`docs_lifecycle --check` 326/0 error/0 warning；`--index` 后 `docs/INDEX.md` 无 diff；
  两条文档闸门 20 passed；`release_check` 通过。

### Added
- **计划状态的机器可读块（`plan_status: 1` + `plan-status` 块）**：`tools/docs_lifecycle.py`
  新增块解析、`--check` 形状/取证校验与 `--board` 看板生成（`docs/plan/BOARD.md`，幂等）。
  首批登记 foundation / abstraction-convergence / hotdog-remaining 三份计划；`done` 但 `ev` 为
  `-` 或 PR 区间的片在 `--check` 记 `未取证`（WARN，不阻断），看板单列。规范见
  `docs/standards/doc-lifecycle.md` §4.1，`PROJECT_PROGRESS.md` 的任务清单降级为指针。
- **热狗账单 P1a（手机端：第三个 tab + 账单卡）**：`T-CityLite.base/resources/[custom]/custom-phone/server/apps/quests.lua`
  新增 `receipts` 查询，走既有 `questExport('GetQuestReceipts', ...)` 读取 custom-quest 的内存账本
  （`questId` 可选；导出缺失/返回非表时回 `{ rows = {}, count = 0, error = 'receipt_unavailable' }`，不抛异常），
  `amount_text` / `net_text` 原样透传。
  `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Quests.svelte` 增加第三个「已结算」tab 与账单卡：
  手机（stack）在 list 内联展开、平板（grid）在右栏渲染；六行明细用 `row.id → 短标签` 映射（缺省回落 `row.label`），
  售出标「已付现 · 不计入净额」、`muted` 行标「未启用」且金额显示 `—`，金额带 `+` / `−` 与 tabular-nums，
  底部只显示「本班净额」并直接使用服务端 `net_text`（前端不对 rows 求和、不显示「手头现金」）；
  空态为「还没有已结算的班次」，`replayed` 行标「已结算（重复查看）」，页脚写明「账单在本次服务器运行期间可回看」。
  `T-CityLite.base/resources/[custom]/custom-phone/html/` 同步重建。
  测试：`T-CityLite.base/resources/[custom]/custom-phone/web/tests/nui/harness.mjs` 增加 `world.questReceipts`
  与 `receipts` case；`T-CityLite.base/resources/[custom]/custom-phone/web/tests/nui/quests.spec.mjs` 增加 5 个场景
  （六行/售出/税/净额≠求和、空态、replayed、平板两栏、导出缺失）。
- **`docs/engineering/TREE.md` + 放置闸门（只判新增文件）**：仓库此前有"文档怎么写"的规范（`doc-lifecycle.md`）和
  "红线/平面"的规范（`CONSTITUTION/ARCHITECTURE`），但**没有一条规则回答"新文件放哪"**——实测
  `doc-lifecycle.md` §2 要求的 `spec/ manual/ adr/ research/ runbook/` 五个目录一个都不存在，而
  `docs_lifecycle.py --check` 依然 0 error（它校验 frontmatter 与链接，不校验位置）。
  TREE.md 补齐三件：①三个根的边界（仓库根 / `T-CityLite.base/` / `docs/`）；②「新文件放哪」决策树
  （CI 检查→`tests/` 根白名单；pytest 用例→`tests/{unit,architecture,agent,integration}/`；控制台 exec 的 harness→
  `tests/game/`；裸 `lua5.4` 脚本→`tests/lua/`；node 冒烟→`tests/js/`）；③命名禁令（`_v2/_v3/-final/-new/副本`，
  日期只给 `audit/research`）。配套闸门 `T-CityLite.base/tests/architecture/test_tree_placement.py` 用
  `git diff --diff-filter=AR` **只判新增与重命名**，存量按 §7 登记豁免——否则第一天就要做一次大搬迁，规则会被 review 成本拖死。
  闸门自带 9 条反向校验，并实测两组注入变红（`tests/` 根新增 `.lua`、`base/docs` 根新增 `.md`）；同时修掉第一版正则的误报
  （`new-note.md`、`09-new.md` 曾被判成版本号）。另外按 `tools/dev/gate_mutation_smoke.py` 的机制补了一条变异用例
  （往 tests 根注入一个 .lua → 闸门红 → 撤回 → 绿），否则 `gate_coverage` 的棘轮会把这条新规则记成"未证明"
  （CI 第一次就是这么红的：`未证明的规则从 278 涨到 279`）。§6 逐条写明它**拦不住**什么（存量、内容错位、同日放宽规则、
  无 base ref、生成物、一次性语义），避免"有闸门"被读成"位置不会错"。
- **`.hermes/` 进 `.gitignore` + 文档断链闸门显式忽略**：Hermes/agent 的本地计划草稿（`.hermes/plans/*.md`）引用的
  是待建/待搬的路径，而 `test_docs_links.py` 走 `rglob` 遍历工作树、不读 `.gitignore`，会把"计划"当成"现状"判红。
  按 `.agents` 已有的豁免写法把它加进 `IGNORED_DIRS`，并同步 `.gitignore`（换机器后无需再改 `.git/info/exclude`）。

- **热狗账单 P1a（服务端内存版）**：`T-CityLite.base/resources/[custom]/custom-quest/server/main.lua`
  新增字面量导出 `GetQuestReceipts(citizenid, opts)`，返回
  `{ rows, count }`（坏 id 返回 `{ rows = {}, count = 0, error = 'bad_id' }`，不抛异常）。
  行内金额除原始数字外附带 `amount_text` / `net_text`，统一由 `QuestMoney`（core-framework
  `FormatMoney`）生成，手机端只加 `$` 与正负号；不返回 citizenid、不新增 net event /
  `TriggerClientEvent(..., -1, ...)`、不碰 DB。
  `T-CityLite.base/resources/[custom]/custom-quest/server/quest_settle.lua` 新增
  `QuestSettle.Recent(citizenid, questId, limit)`：新的在前（同秒按发单序号）、缺省 5 张、
  上限 `KEEP_PER_PLAYER`、`questId` 为空表示该角色全部任务、只回 `billable` 的账，
  并返回浅拷贝（含六行明细与 context，调用方改不坏内部账本）。
  `T-CityLite.base/resources/[custom]/custom-quest/server/quest_manager.lua` 的
  `issueSettleReceipt` 现组装 `context`（`quest_title` / `minutes` / `sold_count` /
  `leftover` / `raw_count` / `billable`）；`QuestSettle.Compute` 仍是纯钱计算。
  测试：扩 `T-CityLite.base/tests/unit/layer3_business/fixtures/settle_probe.lua`
  （37 项，含 per-run key / Recent / context）与
  `T-CityLite.base/tests/architecture/test_quest_entrypoint.py`（守卫先后 + 两处反向注入）。
- **热狗摊音效（顾客上门 + 收银）**：只复用 interact-sound 现有的 doorbell / Shop 两个 ogg，
  不新增素材。顾客报价到达时，客户端用 `InteractSound_SV:PlayWithinDistance` 播 25 m 世界声
  （音量 0.3）；NPC 成交与玩家购买的成功分支由服务端用 `InteractSound_CL:PlayOnOne` 给摊主 /
  买家播收银声（0.35 / 0.3 / 0.25），只传常量文件名与常量音量，不转发任何客户端参数，
  也没有新增 `TriggerClientEvent(..., -1, ...)` 广播点（`broadcast_sites` 预算仍为 143）。
  新增 `T-CityLite.base/tests/architecture/test_quest_sound_calls.py`：扫描
  `T-CityLite.base/resources/[custom]/custom-quest` 的音效调用，断言文件名能在
  `T-CityLite.base/resources/[standalone]/interact-sound/client/html/sounds` 找到、
  音量落在 `(0, 0.5]`、没有新增全服广播，并用变异用例证明闸门会红。
- **热狗摊位改 CEF 菜单（中文不再变方块）**：`T-CityLite.base/resources/[custom]/custom-quest` 新增 `ui_page 'html/vendor.html'`，
  摊位状态条、顾客报价（进度条 + 成交/拒绝）、今日菜单（上下选择 + Enter 买 1 份）三块面板改由
  CEF 渲染——原生 `DrawText` 没有 CJK 字形，中文只能画成方块。新增两个 NUI 回调
  `offerAction`（accept/reject）与 `buyRow`（按行购买），Lua 侧只推送 `status`/`offer`/`menu`/`hint`
  四种消息，**不新增 net event**（`T-CityLite.base/tests/architecture/net_events_baseline.json` 只改 `measured_at`）。
  网页侧 `post()` 带 `AbortController` + 5s 超时，回调丢了界面不会永远转圈（NUI-CLIENT-01）。
- **摊位微调位置**：`quest:server:vendorAction` 新增 `move` 动作，服务端 `QuestBooth.MoveTo` 只改
  坐标、**不重建实体**（推车 netId 不变，客户端不用重新上报），校验复用首次摆放的
  `QuestBooth.ValidatePlacement`（同样的距离/道路/遮挡判据），失败按 reason 提示。

### Fixed
- **热狗摊位 CEF 焦点 + 状态条六项（S12/S13 验收前置）**：
  `T-CityLite.base/resources/[custom]/custom-quest/client/vendor_focus.lua`（新增）成为本资源唯一的
  `SetNuiFocus` / `SetNuiFocusKeepInput` 所有者：报价/购买菜单可见时先渲染再
  `SetNuiFocusKeepInput(true)` → `SetNuiFocus(true,true)`，最后一个 owner 释放时只
  `SetNuiFocus(false,false)`（保留 keepInput）；死亡轮询、`onResourceStop` 额外复位 keepInput。
  六条退出路径（Esc/菜单关闭、收摊、任务完成/放弃、死亡/掉线兜底、离开摊位范围、资源停止）都会释放。
  `T-CityLite.base/resources/[custom]/custom-quest/client/quest_hotdog_vendor_client.lua` 只登记
  `VendorFocus.Acquire/ReleaseOwner`；HTML keydown 与 Lua 原生命令共用 250ms 动作去重（不双发）。
  `T-CityLite.base/resources/[custom]/custom-quest/html/vendor.html` 增加顾客 / 押金 / 剩余时间三格
  与本地倒计时（`paintStatusTime`）、菜单关闭按钮与 Esc。
  `T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor.lua` 新增会话级 `served`
  （NPC 成交/拒绝、玩家成交各算 1 位顾客，超时离开不算；与 `sold` 的份数分开）；
  `T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor_bridge.lua` 的
  `quest:client:vendorState` **同事件扩字段** `served/deposit/expiresAtMs/serverNowMs`
  （押金取实际租借会话，模板 `validator_data.deposit` 回落；不新增 net event）。
  `T-CityLite.base/resources/[custom]/custom-quest/fxmanifest.lua` 在 vendor client 之前加载焦点模块。
  测试：`T-CityLite.base/tests/architecture/test_hotdog_vendor_focus_and_hud.py`（焦点单点/成对/
  六条退出路径/状态条字段 + 反向变异）、`T-CityLite.base/tests/architecture/fixtures/vendor_focus_probe.lua`
  （运行时开关顺序与 owner 计数）、`T-CityLite.base/tests/architecture/test_nui_client_contracts.py`
  把 `focus_unpaired` 扩成按文件配对并新增 `focus_outside_owner`；
  `T-CityLite.base/tests/unit/layer3_business/fixtures/vendor_probe.lua` 增加 `served` 用例。
  字体按新字符集重建（`tools/dev/build_quest_font.py`，1567 字形）。
- **可重复任务（热狗）第二班账单被判成第一班回放**：
  `T-CityLite.base/resources/[custom]/custom-quest/server/quest_manager.lua` 原来用
  `questId .. ':complete'` 做幂等键，热狗 cooldown 0 / daily_limit 20，第二班完成时
  `QuestSettle.Issue` 直接返回第一班的副本并标 `replayed`，历史里永远只有一张账。
  现在键改成 `questId .. ':complete:' .. runToken`：优先取
  `QuestRental.Close` 返回值里新增的 `startedAt`
  （`T-CityLite.base/resources/[custom]/custom-quest/server/quest_rental.lua` 的会话起点，
  关闭后会话即清，所以必须往外带），同一流程重复调用时回落到接取时记下的本班起点
  （`QuestRunLatest`，`markRunStart` 写入、`takeRunElapsed` 不清），保证同班稳定、跨班不同；
  没有用 `os.time()` 当 token。新增探针用例证明「同 run 两次 → 同一张 + replayed」「跨 run →
  两张不同 key」「Last 返回最新」。
- **热狗收摊按一次 E 推进两次（Step order violation）**：`quest_hotdog.lua` 的 `step_sell`
  （`type = 'vendor'`）同时带了 `coords / radius / duration`，于是既走服务端 `close` 分支的
  `AdvanceStep`，又被 `quest_manager.lua` 的 `_eventMap.VENDOR` 映射成通用 `nodeInteract`
  再报一次 `nodeComplete`。现在去掉该步的通用交互数据（方案 A）：vendor 步骤的推进只由
  服务端收摊分支完成，交互提示继续由热狗客户端自己画（`vendorState` 状态条 + E 键映射）。
  不新增 net event，`BOOTH` / `RENTAL` 的 `nodeInteract` 复用不受影响。新增静态闸门
  `T-CityLite.base/tests/architecture/test_quest_vendor_single_channel.py`（真加载全部模板 +
  反向校验：带 coords 的 vendor 步必须判红）与运行时探针
  `T-CityLite.base/tests/unit/layer3_business/fixtures/vendor_single_channel_probe.lua`
  （真实模板 + 真实 `nodeInteract` 处理器 + 真实 `close` 分支：一次动作只推进一次）。
- **买家看不到别人的摊位（整条购买路径不可达）**：`T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor_bridge.lua`
  的 `PushState` 只把摊位状态单播给摊主本人，买家客户端永远没有别人的摊位记录，`[ALT]` 购买菜单因此不可达。
  现在另加一条旁观者推送：`QuestVendorBridge.PushBystanders` 用
  `Broadcast.Scope('quest:client:vendorState', { coords, radius = 10 }, payload)` 只发给摊位附近的玩家
  （复用既有事件名，**不新增 net event**，`net_events_baseline.json` 仍为 440 / 0）。payload 由
  `BuildBystanderPayload` 唯一构造，字段白名单只有 `isOwner=false` / `boothNetId` / `state` / `coords` /
  `items`（可买档位 + 单价），不含库存明细、收入、押金、顾客报价或 citizenid；摊主状态仍只走 `PushState`。
  客户端按 `isOwner=false` 走买家分支，离开 12 m 后清掉旁观者记录；custom-quest 的 fxmanifest 补上
  core-framework 的 server/broadcast.lua（manifest 的 @ 包含写法，不是仓库内可解析的路径）。新增运行时探针
  `T-CityLite.base/tests/unit/layer3_business/fixtures/vendor_bystander_probe.lua`（喂带 citizenid / 收入的
  假会话，深扫返回值）与静态闸门 `T-CityLite.base/tests/architecture/test_quest_vendor_bystander.py`
  （四条反向校验证明规则会红）。
- **收摊后账单的售出 / 回收行恒为 0**：`T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor_bridge.lua`
  里 `CloseFor` 返回的汇总原来只用来发一条聊天通知就被丢掉；任务完成路径
  （`T-CityLite.base/resources/[custom]/custom-quest/server/quest_manager.lua` 的 `closeVendorFor`）
  再调一次 `CloseFor` 时已无会话 → nil，`issueSettleReceipt` 拿到的 `vendorSummary` 是 nil，
  于是售出 / 成品回收 / 原料回收（`soldTotal` / `leftover` / `raw`）全算成 0。
  现在桥里按 citizenid 留一份最近一次 `CloseFor` 的汇总（30 分钟过期、同一人开新会话即清），
  完成路径用 `TakeLastSummary` 取一次即删，同一份收摊数据不会开出第二张账单。
  新增 `T-CityLite.base/tests/unit/layer3_business/test_quest_vendor_summary.py` 与
  `T-CityLite.base/tests/unit/layer3_business/fixtures/vendor_summary_probe.lua`：真跑三个
  `T-CityLite.base/resources/[custom]/custom-quest/server` 下的 Lua 实现，并用「删掉消费点」
  的变异用例证明缓存不是只写不删。
- **挪摊位推了一个不存在的方法**：`T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor_bridge.lua`
  的 `move` 分支调用 `QuestVendorBridge.PushFor(citizenid)`，而这个方法从未定义（真正的推送函数是
  `PushState`）——`MoveTo` 成功之后立刻 `attempt to call a nil value`，界面不刷新。
  新闸门 `T-CityLite.base/tests/architecture/test_namespace_method_calls.py`：资源内自建命名空间
  （`Name = {}` / `Name = X or {}`）的每次 `Name.Method(` 调用都必须在资源内有定义（含
  `function Name.M(`、`Name.M = <非 nil>`、`local M = Name` 别名三种写法）；外部命名空间
  （`Citizen` / `CFShared` / `MySQL` / `QuestNodes` …）不参与。全 `[custom]` 115 个资源实测只有这一处违规，
  零误报、无白名单；`gate_mutation_smoke` 有变异用例证明会红。
- **`local function` 在定义之前被调用**（运行时报 `attempt to call a nil value`，`luac -p` 查不出来）：
  `T-CityLite.base/resources/[custom]/custom-police/server/coroner.lua` 的 `coronerFeedback` 与 `T-CityLite.base/resources/[custom]/custom-quest/client/quest_hotdog_client.lua`
  的 `HidePreviewText` 都定义在调用点之后，已前移。新增闸门
  `T-CityLite.base/tests/architecture/test_lua_local_order.py`（[custom] 的 quest/phone/police 全量扫描，注释与字符串已剥除），
  并在 `tools/dev/gate_mutation_smoke.py` 里加了变异用例证明会红。

### Changed
- **`T-CityLite.base/docs/` 根级两份 `.lua` 文档归位（M8c）**：M8b 之后根级只剩 `README.md` 与两份非 Markdown 文档——
  `playerdata_v2_schema.lua`（内存 PlayerData 结构的 LuaLS 注解式定义，字段与现行代码对得上，**是活文档**）与
  `refactoring_mining_before_after.lua`（采矿重构前后对照，**历史案例**）。处置：前者进 `docs/architecture/playerdata-schema.lua`
  （去版本号——`_v2` 会给重命名撞上 `TREE.md` §4 的版本号禁令），后者进 `docs/archive/refactoring-mining-before-after.lua`
  （已登记 legacy 的历史目录）。顺带修掉 `docs/systems/delivery-manual.md` 的三条过期路径：其中
  refactoring_manifest_v2.md 那条是 M8 把该文件改名归档后的遗漏（该文件已不存在），另两条只是随搬迁更新。
  现在 `T-CityLite.base/docs/` 根级**只剩 `README.md` 一个文件**（连非 Markdown 也算），`TREE.md` §6 的存量描述字面成立。
  实测：两条文档闸门 **20 passed**；`docs_lifecycle --check` **325 / 0 error / 0 warning**；`luac5.4 -p` 两份均通过；
  `docs/INDEX.md` 无变化（索引只收 `.md`）。
- **`T-CityLite.base/docs/` 根级 10 篇收口（M8b）**：M8 留根的 10 篇按 type 分流，最后只留人工入口 `README.md`：
  **3 篇 spec → `design/`**（interaction-memo、menu-interaction-design、vehicleshop-purchase-sequence，
  首篇由下划线改名）、**5 篇 manual → `systems/`**（blip-i18n-guide、blip-i18n-quickref、bus-api-reference、
  delivery-manual、gps-message-pattern，其中三篇由全大写改名）、**1 篇 plan → `docs/plan/automated-testing-plan.md`**。
  `standards/` **零新增**：它的契约是 meta 规范目录（README 写明“6 个独立的指导手册”），混入 manual/spec/plan
  后读者无法从目录判断“必须遵守的规则”与“随代码过期的现状”，也打开“不好分类就放这里”的垃圾桶先例；
  因此 manual 统一进唯一 type 一致的 `systems/`，plan 回项目级 `docs/plan/`。跨文件 token/链接（9 个 blocking）
  与 `T-CityLite.base/docs/README.md` 索引同批修正；frontmatter（type/status/id/updated/review_by）全部未动，
  根级两个 `.lua` 不在本次口径。4 个切片各自一个原子 commit，索引 hunk 与 `git mv` 同 commit，可独立 revert。
  实测验收：`test_docs_links.py` + `test_tree_placement.py` **20 passed**；
  `python tools/docs_lifecycle.py --check` → `total=325 registered=325 unregistered=0 errors=0 warnings=0`；
  `docs/INDEX.md` 重生成后 `git diff --exit-code` 无输出；根级 `*.md` = **1**（`README.md`）。
- **`T-CityLite.base/docs/` 根级 40 篇按状态归位（M8）**：**26 篇归档**（20 篇 `audit/final` 快照原样移入
  `T-CityLite.base/docs/archive/`，其中 `refactoring_manifest_v2.md` 同批改名为 `refactoring-manifest.md`；
  6 篇版本名 `active` 维护/迁移手册先改 `status: archived` 并加"已归档"横幅）、**4 篇去版本号移入现有子目录**
  （`T-CityLite.base/docs/systems/database-persistence.md`、`T-CityLite.base/docs/standards/nui-standard.md`、
  `T-CityLite.base/docs/design/career-reputation-design.md`、`T-CityLite.base/docs/design/mission-template-design.md`，
  后两篇因 API 未落地同时由 `active` 回退为 `draft`）、**10 篇留根**（M8b 再分流）。
  归档目录补 `LEGACY.md` 并在 `legacy_docs.json` 登记（`broken_at_marking: 3`，均来自归档文档内部的当时路径，
  按历史不改写）；活跃文档里的旧路径 token/链接同步修正，`docs/INDEX.md` 重生成。
  实测验收：`test_docs_links.py` + `test_tree_placement.py` **20 passed**；
  `python tools/docs_lifecycle.py --check` → `total=325 registered=325 unregistered=0 errors=0 warnings=0`。
- **`T-CityLite.base/tests/` 根级归位（结构提案 M7 收口）**：根目录从 29 个文件清到 **12 个**
  （10 个 `TREE.md` §3 白名单脚本 + `AGENTS.md` + `README.md`），三个独立提交、各自可回滚：
  ① **A**：10 个游戏内 harness → `tests/game/`（`architecture_stress_test`、`integration_test`、`run_all_tests`、
  `v0.5_e2e_test`、6 个 `vehicle_*_test`），同批改 `run_all_tests.lua` 的 13 行内部 `exec` 串与 3 处自述路径、
  `v0.5-architecture-migration.md` 两处、`RESEARCH-2026-10.md` 两处、`tests/README.md` 的游戏内测试段；
  ② **B**：`db_check.js`、`db_chain_check.js`、`package.json`、`package-lock.json` → `tests/js/`，README 的 `cd`
  改到 `tests/js` 并补 `NODE_PATH` 与 `../unit/layer0_js/…`（`npm install` 落点变了，原命令会找不到模块）；
  ③ **C**：`police_dashboard_test`、`validate_checkpoint_config` → `tests/lua/`，
  `simulate_aviation_routes_v4` / `validate_aviation_medical_airlift_v2` 去版本号改名进 `tests/lua/`，
  **删除**被高版实质替代且全仓 0 引用的 4 个旧版（`simulate_aviation_routes{,_v2,_v3}`、
  `validate_aviation_medical_airlift`）——git 历史保留，需要时 `git show` 可取。
  **为什么分 `game/` 与 `lua/`**：前者只能在 FXServer 控制台 `exec`，后者能直接 `lua5.4 <file>` 跑；混在一起后
  "这个脚本能不能本地跑"会重新变成猜测（旧提案把 18 个全归 `game/`，实测其中 8 个不依赖 FiveM 全局）。
  验证：`pytest tests/architecture/{test_docs_links,test_tree_placement,test_gate_coverage}.py` → 25 passed；
  `luac5.4 -p` 14/14 OK；`docs_lifecycle --check` 0 error 0 warning；活跃文档已无指向旧路径的引用。
  **顺手记一条存量缺陷（不是本次引入）**：`tests/lua/simulate_aviation_routes.lua:142` 给 `string.rep` 传了非整数
  （`bad argument #2 … number has no integer representation`），**master 上的原文件同样崩这一行**（已用
  `git show master:…` 复现确认）。本次只搬家不动行为，修它属于另一件事。
- **文档路径漂移收口（换机 2026-11-16）**：工作树从旧机 `E:/T-City` 换到本机 `C:\tcity`，而 `AGENTS.md` §6 与
  `docs/engineering/WORKTREE.md` 仍把 `E:/T-City` 写成"唯一工作树"，新机器上照文档找不到树。处理：
  `docs/engineering/WORKTREE.md` 新增 **§0 环境表**（仓库根 / FXServer 目录 / 起服入口 / 端口 / 旧树归档 / 备份）
  作为**唯一写盘符的地方**，§1 改为"一棵工作树 + 一份历史归档"，§2 命令去掉 `git -C E:/T-City` 前缀，
  §2.1 起服路径改指 `.\start.cmd` / `./start.sh`；根 `AGENTS.md` §6 同步改成"本克隆根即唯一工作树"（仍 ≤110 行，`test_agent_docs.py` 绿）。
  配套规则写进 WORKTREE §3：**操作性文档只写"仓库根"或相对路径；`docs/engineering/2026-11-*` 与 `docs/archive/**` 是当时快照，不回溯改写其绝对路径**。
  同步修掉 `docs/agent/police/BLUEPRINT.md` §0.2（`cd E:/T-City-harness` → 仓库根）、`docs/agent/police/ACCEPTANCE.md`
  （旧机 Python312 绝对路径 → 以 `python -m pytest --version` 能跑通为准）、`T-CityLite.base/tests/agent/lua/client_bootstrap.lua` 注释里的示例路径。
  `type: audit / status: final` 的 `T-CityLite.base/docs/agent/FIVEM_MCP_LIVE_TEST.md` 按规范不修改（快照）。
- **`PROJECT_PROGRESS.md` 接回真源**：原文顶部说"以 2026-10-21 审计报告为准"，更新协议却指向一个**仓库里不存在的**
  `manage_progress.py sync/complete/start`（已核实），且把"80 资源 / 17 模块"这类会漂的数字写进正文（`doc-lifecycle.md` §12 明确列为反模式）。
  现在只保留"版本与任务进度"这一职责：数字交回 `check_cfgs.py` / `check_dependencies.py` / `docs/INDEX.md`，
  状态真源指向 `2026-11-foundation-plan.md` §4.1、`T-CityLite.base/docs/agent/STATUS.md`、`CHANGELOG` 的 `[Unreleased]`；
  同步时间更新到 2026-11-16，并补上「2026-11 基石加固 P0/P1/P2 ✅」与下一方向。
- **`docs/README.md` 导航表去腐烂**：`design/` `audit/` `systems/` 三个条目指向**不存在的目录**（其中审查报告实际在
  `T-CityLite.base/docs/audit/`），而真实存在的 `agent/` `client/` `ops/` `plan/` `police/` `server-design/` 六目录未登记。
  按实际目录重排，并把 `docs/` 之外的三个常用入口单列一行。
- **下一方向结论按代码重估**：`2026-11-01-next-epic-research.md` 推荐"世界痕迹收口"的第一条链**已经落地**——
  `T-CityLite.base/resources/[standalone]/core-framework/services/world_trace_service.lua`（2026-11-01）是 `world_state` 的唯一写者，`T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua`
  结案时写 `crime_pressure`。实测**读侧仍为 0 消费者**（`crime_pressure` 除写入点外全仓无引用，手机 `CityFeed` 未接），
  所以下一方向应是"读侧接线"，不是再建写侧。
- **热狗数值改成测试期占位档**（正式值等经济系统联动）：`T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_hotdog.lua`
  押金 250 → **50**、租金 6 → **1 每分钟**（免租 60 → 30 秒，计费上限 60 → 20 分钟，保证满时长也扣不穿押金）、
  单价 6/9/14 → **8/16/32**（取偶数，成品回收按 0.5 折价不会出 $7.5）、顾客节奏 8–15 s/15–40 s → **3–6 s/6–15 s**、
  耐心 45 → 30 秒。新增闸门 `T-CityLite.base/tests/architecture/test_hotdog_test_numbers.py`
  （真加载模板表，校验押金 ≥ 计费上限 × 费率、单价递增且偶数、节奏自洽，并带两个反向控制）。
- **新增真机验收清单** `docs/plan/jobs-content/14-hotdog-live-checklist.md`：单人 13 条 / 多人 8 条分列，
  多人项一律标 ⛔ 待后期；单人的三个已知缺口（CEF 无焦点、状态条缺三项、顾客原地生成）单独列出，不算通过。

### Security
- **凭据泄露收口（2026-11-16）**：`tools/dev/local_stack.sh` 用 shell 默认值的形式带着开发库的
  root 与 agent 只读账号口令，而这个文件自 2026-10-27 起就在被跟踪的代码里（`release_check.py` 的
  连接串规则只认 `mysql://user:pass@`，看不见 `${VAR:-口令}` 这种形状）。处理：
  ① 两个账号的口令已**轮换**（库里 `ALTER USER`，新值只写进 gitignored 的 server.cfg（T-CityLite.base 下那份）与环境变量）；
  ② `local_stack.sh` 改成缺环境变量直接报错，不再有任何默认口令；
  ③ `release_check.py` 新增两条规则——shell 默认口令（`${*PASS*:-字面量}`）与命令行内联口令，报告里只出现变量名、不回显值。
     旧形状的反向验证在本地跑过：喂一个 `VAR="${X:-真口令}"` 必须命中。
- **S7 证据广播按受众收口**：`T-CityLite.base/resources/[custom]/custom-police/server/evidence.lua` 的 9 处 `TriggerClientEvent(..., -1, ...)`
  改为 `Broadcast.Scope(..., { job = 'police', onduty = true }, ...)`，DNA/血型/指纹/弹壳只在岗警察可见；
  `[custom]` 剩余 19 处全服广播登记 `broadcast_allowlist.json`（按 file+event 合并为 13 条，含
  owner/reason/expires），`broadcast_sites` 预算 152 → 143。

### Added
- **S4 热狗售卖闭环（服务端 + 接线）**：`T-CityLite.base/resources/[custom]/custom-quest` 新增顾客会话内核 `quest_vendor` 与接线层
  `quest_vendor_bridge`。摊位一摆好就开张（玩家不需要再按一次「开卖」），每秒 Tick 决定
  「现在能不能来顾客」，报价金额、库存、一次性 `offerId` 全在服务端算；客户端只能按 Y/N 或买。
  买家这条路径**先扣买家再动库存**（内核 `Purchase` 只负责扣库存 + 给摊主记收入，
  它不知道买家是谁），内核失败自动退款 —— 顺序反过来就会在买家付不出时白送一份。
  只新增**一条** net event `quest:server:vendorAction`（action 白名单 + 5 秒 10 次限流 +
  6 m 距离 + 归属校验），并且把它登记进 `net_event_guard_helpers.json` 的
  `QuestVendorGuard.Validate`，全仓 net event 仍是 440 / **0 未登记**。
  顺带修掉扫描器的一个假阳性：`"end" in text` 会把标识符里的子串当关键字
  （helper 名为 `QuestVendorGuard.Validate` 时，"V**end**or" 被切中）。
- **S2 热狗摊位实体（服务端权威 + 客户端推车）**：新增 `T-CityLite.base/resources/[custom]/custom-quest` 的 `quest_booth` 服务端脚本与
  `quest_hotdog_client` 客户端脚本，把「把推车推到某处放下」变成一条**可判定的规则**而不是一句提示。
  服务端自己算三条硬判据（离租赁点 / 离路面节点 / 离其它摊位）外加配置禁摆区；客户端能拿到
  `IsPointOnRoad`、坡度、水面这些服务端没有的原生，所以它参与测算，但**只能让判定更严（veto），不能放宽**。
  路面点不是现算的：`tools/dev/booth_roads.py` 从 `.cache/roads/road_points.bin` 离线切出 Legion Square
  一带的路面节点写成 `T-CityLite.base/resources/[custom]/custom-quest` 的 `hotdog_roads` 配置（1402 个，19.9 KB），服务端只做一次最近点比较；
  `--check` 让「缓存更新了但 Lua 没重生成」这件事变成一条会红的测试。
  拒绝文案与 UX 规格一致（离租赁点太远 / 挡在车道上 / 旁边已经有摊位 / 这里放不稳 / 这里不许摆摊）。
  实体走既有 `QuestEntityRegistry`（`on_quest_end`，不走 `on_leave`：玩家走开去卖货是常态），
  四条关闭路径（归还/放弃/失败/断线）都删实体。**没有新 net event、没有新表**：摆放坐标与 netId 走
  既有 `nodeComplete` 的 `clientData`，由 `validate_booth_place` 校验器裁决。
  闸门：`tests/unit/layer3_business/test_quest_booth.py` 6 条（探针 17/17、删掉压路判据必红、
  `booth` 已进 `VALIDATED_TYPES` 与 `META_KEYS`、清单声明、路网点与缓存同步、dev 模板真的用上 booth）。
- **薪资抑制（R2）：让「干活」成为主要收入**：qb-core 每 10 分钟按职级发 `grades[level].payment`，
  原始区间 10–200 → **$60–1,200/小时**的白拿收入，会盖过 R1 三个循环职业的 1,400–2,800 $/h。
  新增 `T-CityLite.base/resources/[system]/core_economy/server/salary_scale.lua`：只改 `QBShared.Jobs` 这张共享表（就是 PaycheckInterval 读的那张），
  **qb-core 一行没动**，上游可以照常合并。两个 convar：`economy_salary_scale`（默认 1.0 = 不动）、
  `economy_salary_cap`（默认 0 = 不封顶）；本次配 0.35 / 50 → 单次 $4–50，折算 **$24–300/小时**。
  实现要点：每次应用都从**原始值**重算（`restart core_economy` 不会把工资越压越低），非法 convar 一律回落
  安全默认，回滚只需把 scale 改回 1.0 并重启。闸门：`tests/unit/layer3_business/test_salary_scale.py`
  7 条（安全默认 / 缩放封顶 / 幂等 / 从原始值重算 / 单调性 / 非法值 / 可回滚）。- **单趟耗时遥测（数值卡的数据源）**：`T-CityLite.base/resources/[custom]/custom-quest` 在接单时记 `os.time()`、完成/放弃/失败时清掉，
  并在 `🏁 COMPLETING` 那行日志里带出「用时=x.x 分钟」。只走内存 + 日志，0 新表 / 0 新事件。
  起因：`04-numbers.md` 的时薪是「站数 × 单站耗时 × 收益」三条假设叠出来的，其中单站耗时从来没测过 ——
  存量 7 条任务壳要不要降价，得先有真实数据才谈得上定价。- **R1 真机验收：bus 也跑通**：`bus_v1_city`（6 站）同一会话跑完 → `completing` → `$486 (bank) + bus rep +25`，
  与配置一致；同一位玩家先 garbage 后 bus，验证会话键按任务隔离。证据已并入 `docs/plan/jobs-content/05-verification.md` §4.2。
- **R1 真机验收记录**：新增 `docs/plan/jobs-content/05-verification.md`（type=audit）。
  记录 `garbage_v1_city` 在 `:30130` 真机上的完整一趟：报到 → 4 站 validator 全过（无 `validator failed`）
  → 自动交回 → `🏁 COMPLETING` → `$370 (bank) + garbage rep +8`，与配置的 4 站 / $370 / 10 袋一致；
  同时存档修复前的失败证据（`global 'QBCore'` 那两行）与 6 项未覆盖（bus 三档、district/full 档、
  断线重连、手机列表、结算落库、薪资抑制）。- **职业内容填充规划**：新增 `docs/plan/jobs-content-roadmap.md`（type=plan, status=draft）。实测 22 个职业里只有 4 个有真实循环、
  市政厅可申请的 7 个民职有 6 个是空壳；据此确立「三种机制 × N 份数据」的内容模型与 R0–R6 分批，
  硬约束为 0 个新资源 / 0 张新表 / 0 个新 net event。§11.1 记录五项拍板（首批 R0+R1、干活为主、先 NPC、职权型不做、realestate 不碰）。
- **职业内容调研（阶段 R）**：新增 `docs/plan/jobs-content/01-research.md`（type=research）。含内部实测 8 条（带 file:line）、
  外部 7 个来源的做法对照、6 条假设（4 条被证据排除）、按平面的影响面，以及与 Claude Code 的引擎表达力盘点
  （NPC 乘客 / 里程计价 / 乱序多站 / 失败判定 / 结算幂等五项，逐条给现在靠哪个 step 类型与最小新增）。
  调研修正了三条原判断：数值按技能分三档而不是统一一条带、放弃「玩家自排路线」、NPC 预算不能复用警察的。
- **validator 步骤的服务端闸（阶段 D · C1）**：`T-CityLite.base/resources/[custom]/custom-quest` 新增 quest_step_gate.lua（纯函数，零原生依赖），
  并在 `nodeComplete` 处理器里**于 `AdvanceStep` 之前**执行步骤的 `validator_id`。原因：`validator` 步骤过去只在
  `dashboardStampDelivery` 那条路径上跑过校验器，客户端 `nodeComplete` 这条腿直接推进 ——「到达判定」「绑定载具」
  走客户端就能整段跳过（调研 §2.1-5）。回滚：`setr quest_step_validator_enforce 0`（只记日志不拦）。
  只对**声明了** `validator_id` 的步骤生效，未注册校验器时不拦（向后兼容）。
  两条腿共用一个 `runStepValidator` helper（dashboard 走 force、nodeComplete 受 convar 控制），
  原来 dashboard 里那份 validator 白名单已删除 —— SonarCloud 对首次提交报的 20% 新代码重复就是这两段。
  证据：`test_quest_step_gate.py` 5 条（判定/入参/开关）+ `test_quest_step_gate_contract.py` 2 条（契约顺序 + 顺序调反必须判红）；
  全量 `pytest tests/unit tests/architecture` → 1409 passed / 147 skipped。
  **真机未验**：logistics/aviation 的 27 个 validator 步骤要在服务器上跑一遍，确认真实流程不被误拦。
- **多站路线校验器（R1 · P1）**：新增 custom-quest 的 server/quest_route_validators.lua，注册 `validate_route_stop`，
  garbage / bus 共用。五条判据按顺序判：站号合法 → **顺序**（只能完成会话里的下一站）→ 职业/在岗 → 坐标存在
  → 距离 ≤ radius → 载具（可选），**全部通过之后才写会话**（先落账会白送一站）。会话只在内存，键是
  `citizenid:questId`，0 张新表。
  另修一条会锁死任务的路径：`QuestManager.TriggerQuest` 每次接单都清该任务的会话 —— 玩家在第 3 站放弃/掉线后
  会话停在 3，重新接单从第 1 站开始，会被「只能完成下一站」永久拒掉。
  证据：`test_route_stop_validator.py` 7 条（顺序/跳站/重放/远距/错职业/不在岗/无载具/坏参数/跨任务隔离/陈旧会话重置）；
  先红后绿：实现文件不存在时 6 条全红。全量 `pytest tests/unit tests/architecture` → 1417 passed / 147 skipped。
  验收后补两处（Claude Code 在 R1·P1 复核里指出）：①**冷启动**——没有会话时以当前步自己声明的站号为准，
  否则资源/服务器重启后任务停在 N 站而会话丢失，该站被永久判 out_of_order（只能放弃重接）；
  ②`quest:server:reach` 只准推进 reach 步骤、`CompleteStep` 导出也过同一道闸 —— 原来这两条路都能绕过
  validator（C1 的闸只挂在 nodeComplete 与 dashboard 上）。
- **garbage 站点谱（R1 · P2）**：新增 custom-quest 的 config/quests/quest_garbage.lua，三档任务
  `garbage_v1_city/district/full`（4/6/8 站）。每站一个 `validator` 步骤走 `validate_route_stop`，
  首尾是 interact（报到 / 交回）。金额 = 站×30 + 袋×25，按 02-design §2.3 定为固定值
  $370 / $705 / $1,140（≈1,388 / 1,763 / 2,138 $/h，落在低技能带）。
  注册要改两处（这是这套引擎的坑）：fxmanifest 的 files 与 quest_registry 的 knownFiles 列表，缺一处就静默不加载。
  证据：`test_garbage_route_config.py` 3 条 —— 站号必须连续从 1 开始（跳号会让玩家卡站）、
  每站必须带 validator_id/job/require_duty/coords/radius、首尾必须是 interact、坐标不许重复、quest id 全局唯一；
  反向：删掉配置文件 → probe 直接失败。全量 pytest → 1420 passed / 147 skipped。
  **真机未验**：坐标是洛圣都常驻垃圾点的大致位置，P2 验收要求先在 dev 服跑一条真实任务。
  **已知缺陷（既有）**：`conditions.daily_limit` 在 custom-quest 里没有调用点，所以每日上限目前不生效。
  **上线前修掉的接线 bug**：`QuestStepGate.ValidatorPayload` 只给校验器 `validator_data` + 白名单 meta，
  而 `coords` 不在白名单里 —— 第一版配置只把坐标写在顶层 `data.coords`（客户端画交互点要用），
  校验器拿到 nil，每站都判 `no_coords`，真机表现就是「走到点按 E 没反应」。现在坐标在 `validator_data`
  里也放一份，并加了 `route_integration_probe.lua` 把「配置 → 载荷 → 校验器」整条链跑一遍（删掉
  validator_data 里的 coords 会立刻红）。
- **bus 线路（R1 · P3）**：新增 custom-quest 的 config/quests/quest_bus.lua，三档 `bus_v1_city/crosstown/full`
  （6/8/10 站），金额按 02-design §2.3 的 bus 档固定为 $486 / $648 / $810（站×90×0.9，≈1,620 $/h）。
  与 garbage 同构：每站一个 `validator` 走 `validate_route_stop`，首尾 interact（签到 / 交班）。
  配置测试与 garbage 共用一份通用 probe（route_config_probe.lua，文件名作参数），避免两份脚手架；
  另外整链用例也参数化了，bus 同样断言「配置 → 载荷 → 校验器」能跑通第一站。
  证据：test_bus_route_config.py 3 条 + 全量 pytest → 1425 passed / 147 skipped。
  **本轮未做**：准点率（punctuality）—— 现有 CalculateTimeBonus 只读物流追踪器，bus 没有；记进 03-plan §7。
  **真机未验**：坐标是主干道公交站的大致位置。
- **接单条件与校验器不一致的卡死（R1 复核修复）**：garbage/bus 的 `required_tags` 只写了 `role=civilian`，
  而服务端校验器要求 `job=garbage/bus` —— 平民能接单、走到第 1 站必被判 `wrong_job`，任务卡死。
  两处一起修：①配置的 `required_tags` 加 `job`（手机列表据此过滤）；②`TriggerQuest` 新增
  `conditions.require_job` 校验，接单时就拒。**只认显式声明的字段**，不改既有模板语义
  （否则帮派成员做矿工任务这类正常路径会被一并关掉——过度收紧比漏拦更难查）。
  证据：两份配置测试各加三条断言（validator job / required_tags.job / require_job 三者必须一致）。
  另新增 docs/plan/jobs-content/04-numbers.md（数值卡）：三个职业九档的 $/h 与目标带逐项对照。
- **Agent 控制平面升级计划**：新增 `docs/plan/agent-control-plane-upgrade.md`（type=plan, status=active, source_of_truth）。
  合并两轮独立盘点（主会话判断 + Claude Code 274 行静态分析），建立 15 项工作项与 Issue 映射
  （Epic #234 ／ 执行项 #235–#240 ／ 检索专题 #233），并记录 4 处判断修正：
  `agent_harness.py` 不是 agent 循环（全仓无 LLM SDK）、成本计量并入 runtime、排期改为 8 周口径、
  自建 runtime 是为承载「执行前挂起等人批」而必须。
- `docs/INDEX.md` 重新生成（308 篇，0 未登记）。

### Changed
- **`FormatMoney` 合并 8 份 `[custom]` 金额格式化实现**：唯一实现收口到
  `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua` 的 `FormatMoney`
  （nil/非数字/NaN → `'0'`，整数无小数点，小数两位，负数保留符号），并在客户端与服务端都
  注册为导出。custom-market / custom-main / custom-cartel / custom-security / custom-crime /
  custom-phone / custom-quest / custom-taxes 各自的 shared/money_format.lua **删除**；
  四个历史别名（`Money`/`PhoneMoney`/`QuestMoney`/`TCMoney`）只在
  `T-CityLite.base/resources/[standalone]/core-framework/shared/money_aliases.lua`
  定义一次，各资源 fxmanifest 以 '@core-framework/shared/money_aliases.lua' include
  （8 份逐行相同的门面会让 Sonar
  新代码重复涨到 9.9%；集中一份后为 0）。
  `$%d` 基线 66→59（market main 6、phone client 1 改为 `$%s` + 别名）；新闸门
  `tests/architecture/test_money_format_single_owner.py` 抓第二份实现/别名、
  并检查每个别名调用点的 fxmanifest 真的加载了别名文件，变异冒烟证明会红。
- **退役跨资源 Bus（税/热度/通知）**：qb-core 新增两个 append-only 导出
  `exports('SinkWithdraw', SinkService.Withdraw)` / `exports('HeatReset', HeatService.ResetHeat)`，
  内部仍走既有的 `EconomyService.RemoveMoney` / `HeatService.ResetHeat`，不新增扣钱路径。
  custom-taxes 的 4 个扣税点改走 `exports['qb-core']:SinkWithdraw`（保留原
  `Player.Functions.RemoveMoney` 回落）：大额转账税/房产税/购房印花税/武器维修费此前**只扣钱、
  不进 sink 统计**，现在都进 sink 并触发 `QBCore:Server:OnMoneySink`；跨组织转账税此前因
  `_G.Bus.SinkService` 恒 nil 且无回落而**从未扣除**，现在会真的扣 3%。
  production-freeze 的 `ResetEconomyToDayOne` 改走 `HeatReset`（热度重置此前从未执行），
  并保留删除 npc_prices.json 的代码；qb-shops 删掉永远为 nil 的 `_G.Bus.NPCPricing`
  分支（改用 `GetResourceState('core_economy')`）；custom-phone 删掉 `_G.Bus.EconomyService`
  分支保留手动转账；`QBCore.Functions.Notify` 直接 `TriggerClientEvent`，不再走从未注册的
  `_G.Bus.notify`。`test_bus_scope.py` 扫描根扩到上述 4 个目录 + qb-core 的 `functions.lua` /
  `heat_service.lua`。
- **退役跨资源 Bus（场景/作业/车辆）**：`_G.Bus` 是每个 resource 私有的 Lua 状态，跨资源读
  `Bus.<service>` 恒 nil。本次把 4 处 BGM 死调用（custom-police 追车、qb-ambulancejob
  重生/死亡、qb-storerobbery 抢劫）改成 `exports['tcity-atmosphere']:service_atmosphere_PlayScene`；
  `custom-police` 的 `Bus.JobService.SetJob` 分支删掉，直接走 qb-core 的
  `player.Functions.SetJob`。`qb-vehicleshop` 不再调用 `Bus.RegisterService('dealership')`
  （该资源不加载 Bus，注册从未执行）：8 个 `service_dealership_*` 改为静态 `exports(...)`，
  二手车状态改走 `exports['custom-vehicles']:GetVehicleState`。core-framework 的
  contracts.lua 删除 5 个从未实现的占位服务（reputation/chronicle/governance/cosmetics/funnel），
  `service_contracts.json` 的 `planned_services` 清空。
  新增闸门 `tests/architecture/test_bus_scope.py`：跨资源 Bus 读取 + `Bus.RegisterService`
  的 manifest 接线双判据，变异冒烟证明会红。
- **PowerShell 下 Lua 检查必须写 `.exe`**：`luac5.4` / `lua5.4` 的扩展名被 Windows 读成 `.4`（无关联程序），PowerShell 会把该文件当“文档”交给 ShellExecute → 弹「选择一个应用以打开此 .4 文件」并**阻塞命令**，表现是「每改一个 Lua 文件弹一个框」而语法检查其实一次都没跑。约定层同步到 `AGENTS.md §5`、`CONTRIBUTING.md`、PR 模板与 `.agents/skills/fivem-resource-development/{SKILL.md,references/verification.md}`：PowerShell 写 `luac5.4.exe` / `lua5.4.exe`，bash/MSYS 与 Python `subprocess` 继续用裸名。加 `.cmd` 包装无效（`where` 顺序：字面文件 → `.cmd` → `.exe`）。**已在本机落地根因修复**（2026-11-16）：用户级 `PATHEXT` 追加 `.4`（`.COM;…;.lexe;.4`，`reg add HKCU\Environment /v PATHEXT`），此后 PowerShell 与 cmd 的裸名都正常执行；仅新进程生效，已开终端与 Hermes gateway 重启后继承。
- **送货循环归 trucker，结算额回到带内（R0.3）**：qb-shops 的 `Config.DeliveryPrice` 从 **$500/站降到 $70/站**。
  原值 20 站/趟 = $10,000，按 25–40 分钟折算 **$15k–24k/h**，比低技能带（$1.8k–2.5k/h）高 6–13 倍；
  现值 ≈ $1,400/趟 ≈ $2.4k/h。同时新增 `Config.DeliveryJob = { name = 'trucker', requireDuty = true }`：
  **租车与结算都要求在岗 trucker**（此前任何职业都能租车跑单；只放结算不放租车 = 收押金却结算不了）。
  每站结算额外给 `delivery` 声望 +1 —— 这条声望此前只在死代码 `PaySlip` 里发过，从未真正产生。
  另把每站 10% 概率的 `cryptostick` 改成配置 `DeliveryCryptostickChance`（默认 **0**）：一根按 qb-crypto 的
  `Worth = 1000` 兑换，20 站/趟期望 2 根 = $2,000，比现金结算还多，实际收益约 $6k/h —— 这条是 Claude Code
  验收时抓出来的。数值依据与分档见 `docs/plan/jobs-content/02-design.md` §2。
- **一键启动**：新增 `start-tcity.ps1` + `start.cmd`（`-Status` / `-Restart` / `-Stop`）。顺序固定为
  Docker 引擎 → 容器 → `mariadb-admin ping` → FXServer → 自检（资源数稳定、关键资源齐全、日志无
  `SCRIPT ERROR` / `awaitConnection failed`）。起因：Docker Desktop 被关掉后 MariaDB 一起没了，
  FXServer 照样起得来而 `oxmysql` 卡在 `connect ETIMEDOUT`，且它不会自己重试。

### Fixed
- **`LoadModel` 收口到 `CFShared.LoadModel`**：删除 custom-police/custom-cartel/custom-quest
  的 4 份本地实现（其中 custom-quest combat 节点**无超时**，custom-cartel 是 300×10ms 轮询）；
  模型缺失时客户端不再卡死，失败经 `CFShared.Report` 上报一次。新闸门
  `tests/architecture/test_load_model_single_owner.py` 只抓「无退出条件的循环」，热狗两个
  客户端的 `deadline`/`generation` 有界循环不在范围内。
- **`Db` 结果适配器**：`insertId/affectedRows` 归一化收口到
  `T-CityLite.base/resources/[standalone]/core-framework/server/db.lua`
  （`Db.Insert/Update/Query/Single/Scalar` +
  `Db.InsertId/AffectedRows`）；director 不再把 `affectedRows=1` 当记录 id；
  phone/police 的 5 个调用方保留门面、行为不变；新闸门
  `tests/architecture/test_db_result_adapter.py` 钉住「归一化只在适配器里」。
- **方法级导出契约闸门 + 修 11 处死调用 + 1 处兜底**：卖物品不再丢物品、抢劫奖励不再报
  `No such export`、武器耐久恢复更新。闸门（`tools/dev/service_contracts_scan.py` +
  `tests/architecture/test_service_contracts.py`）把全仓字面量 `exports['<res>']:<Method>(`
  调用与声明逐方法对账（登记表 `service_contracts.json`，176 个 service 方法 + 33 个外部
  调用点复核）；本次换掉 `custom-main:AddScaledMoney/CheckRateLimit`、
  `custom-economy:GetEconomyRewardScale/AddScaledMoney`、`qb-inventory:SetItemInfo`、
  `custom-career:GetLocalIdentity` 共 12 个真实死调用：当铺卖物品失败自动退回物品；
  抢劫奖励走 `core_economy:GetGlobalMultiplier`（pcall 回落 1.0）；洗钱、街角卖货、
  压力测试回到 `Player.Functions` 原语写路径；武器耐久改走 `qb-inventory:SetItemData`；
  手机 Leader app 改走 `custom-career:GetPlayerIdentity`。
- **热狗线 S0 坐标踏勘**：Legion Square 东侧广场定下 7 个坐标（租赁点 / 3 个摆位 / 2 个顾客生成点 /
  队列点），逐个过「离最近路面 ≤ 10 m、高差 ≤ 1.5 m + 卫星图人眼」；摆位 A 用的是真机验证过的旧壳点位。
  见 `docs/plan/jobs-content/12-hotdog-coordinates.md`（含被淘汰的候选与原因）。
- **热狗线 S1：租借原语 custom-quest 的 quest_rental 服务端脚本** —— 押金会话（同任务只能一个）、按分钟计租
  （免租期 + `max_minutes` 封顶）、四条关闭路径（归还 / 放弃 / 失败 / 断线）、重启扫描 + 登录补退。
  钱只走 `Player.Functions`；断线与重启都不直接转账（离线玩家没有合法写入路径），改为排队到下次登录。
  接线：新 step 类型 `rental`（客户端按 interact 处理，推进走既有 `nodeComplete`，**0 新 net event**）；
  校验器 `validate_rental_open`；`QuestDB.FindUnclosedRentals` 读日志。
  测试 `tests/unit/layer3_business/test_quest_rental.py` + 探针 9 条不变量（含反向校验：去掉封顶必须红）。
- **热狗线 S3 内核（CC 实现）：custom-quest 的 quest_minigame 服务端脚本** —— 一次性 nonce、过期、
  `quit` 也消耗 nonce、`faults → 三档品质` 服务端映射；探针 7 条 + 反向校验（改成永远返回 common 必须红）。- **热狗摊 UX 规格定稿（草稿）**：状态机（租借/推车/摆放/营业/做热狗/顾客/成交/收摊/结算/挂起）+
  逐状态的「看到/听到/能做/失败态」、6 张线框图、键位矩阵、中英文案表、音效清单、账单明细规则、
  中断恢复，以及 A1–A22 可打勾的 UX 验收 + V1–V8 真机剧本 + D1–D12 开发口径。
  见 `docs/plan/jobs-content/10-hotdog-ux-spec.md`。- **物流租借绑定的三个真 bug**：① 绑定里的押金写死 `rentalDeposit = 0`（配置里 300–2000 的押金
  在收据上永远是 $0）；② `ClearLogisticsBinding` 定义了却全仓库零调用（失败/放弃后 plate / netId /
  rentalFeePct 残留，下一趟按上一趟费率结算）；③ `playerDropped` 只清 `QuestCache`，断线后旧绑定还在。
  修法：押金改从 `stepData.rental_deposit` 读（自有车仍为 0）；`FailQuest` / `AbandonQuest` 走
  `clearLogisticsFor()`（pcall 保护）；新增 `ClearAllLogisticsBindings(citizenid)` 供断线整表清。
  回归闸：`tests/unit/layer3_business/test_logistics_binding_lifecycle.py`（3 条静态契约 + 1 条运行时探针，
  每条都带反向校验；探针真跑源码里的绑定存储，验幂等/计数/只清一个不动兄弟）。- **物流「租借会话」只有开始、没有关闭**：`rentalDeposit` 在 `quest_logistics_validators.lua:193` 写死为 `0`
  （配置里的押金根本收不到）；`ClearLogisticsBinding` 定义了却**全仓库没有一处调用**；`playerDropped`
  只清 `QuestCache`，不清 logistics binding。放弃/失败/掉线后 plate / netId / rentalFeePct 会残留。
- **成熟职业脚本调研（官方 9 个 job + 社区）**：提炼出押金即会话、服务端发牌、结算走物理点、
  基础值×条件倍率−税、反作弊三件套等 7 个模式，并定位到可复用的正确骨架（custom-cartel 的生产引擎：
  `finishAt` + 完成时复验 + 扣料产出）。见 `docs/plan/jobs-content/08-mature-scripts-survey.md`。- **任务节点能力的真实边界被查清了**：`Config.Quest.StepTypes` 声明 13 种，实际只有 8 种有处理分支 ——
  `collect` / `wait` / `combat` / `placement` 是**死类型**（注册器只校验名字在白名单里，客户端毫无反应，
  配置选到它们任务会静默卡死）。
- **热狗这类循环型任务缺 4 类节点**：对照上游 qb-hotdogjob 的真实流程（押金租摊 → 推车 → KeyMinigame
  定三档品质 → NPC 顾客成交 → 归还退押金），我们只有「到点/交互」两种能用，缺租借（押金+计时）、
  小游戏生产、持续售卖、归还结算。调研与模板草案见 `docs/plan/jobs-content/07-quest-ux-research.md`。- **旧壳任务印钞（约 11,000 $/h，新路线的 4–8 倍）**：真机跑 `hotdog_vendor` 拿到第一个实测
  —— 同点连做 4 步，结算日志 `用时=0.9 分钟`，发给玩家 $165。7 条民职旧壳按 2,000 $/h 重定价：
  hotdog $150–350→$22–40、taxi $200–500→$35–55、bus $300–600→$38–58、tow $400–800→$38–58、
  garbage_collection $250–500→$55–80、recycle $200–450→$50–75、news $300–600→$85–130，
  折算 1,984–3,016 $/h，落在目标带内。
- **收益从来没有被算成每小时**：新增 `tools/dev/quest_econ.py`（路程 × 1.4 绕路系数 / 15 m/s +
  交互时长 + 25 s 开销）与 `tests/architecture/test_quest_economy.py`（受闸任务必须落在
  1,400–2,800 ±400；一次性剧情章节按 `story_arc` 豁免；自带超发模板的反向校验）。- **Docker 引擎起不来时启动器只说「看日志」，没说怎么办**：真机形态是 Docker Desktop 报
  `Docker Desktop is unable to start`、`com.docker.service` 停在 Stopped、WSL 的 Ubuntu 与
  `docker-desktop` 两个发行版都是 Stopped —— 卡的是 **WSL 虚拟机**，不是 Docker 服务，
  所以 `Start-Service` 或单独启发行版都无效。同一根因还会让 Docker 自己崩一次并弹
  `vpnkit-bridge handshake failed … received bad magic string`（管道里回来的是 NUL + 一句 Windows
  超时文本）。启动器的 180 秒超时现在会直接给出四步恢复法（`wsl --shutdown` → 结束 Docker 进程 →
  重开 → 再跑脚本），并明确警告**不要点 “Reset to factory defaults”**（会连卷一起删，丢 `tcity-mariadb` 数据）。- **6 个模板的任务点落在建筑内部 / 楼顶，玩家到不了**：把全部 78 个模板渲染成卫星联络图逐格看过之后，
  确认 `hotdog_vendor`（前一 PR 已修）、`cartel_ch4_benevolent_king`、`cartel_ch4_tyrant`、
  `civilian_ch4_artisan`、`civilian_ch4_survivor`、`news_report` 的点都在**建筑内部**；
  `civilian_ch4_mogul` 的 3 步在 Arcadius **楼顶**（z=150，比路面高 122 m，玩家上不去）。
  全部移到最近的可站立位置（车道 / 人行道 / 街面），`mogul` 的「站在顶层办公室」文案同步改成「站在楼下」。
  这类「在楼里但离路只有 20 m」的点，路网判据抓不到，只能靠联络图人眼过 —— 方法见
  `docs/engineering/QUEST_COORDS.md`，全量结论见 `docs/plan/jobs-content/06-coord-audit.md`。
- **`quest_map.py` 新增 `--sheet` / `--only` / `--tile`**：把全部模板渲染成每页 12 格的卫星联络图，
  一次看完 78 个模板的点位分布；配合 `--only` 可以只放大可疑的几个复查。- **7 条物流任务的目的地是占位坐标 `(0,0,0)`，整条任务永远交不掉**：`euro_trucking_steel` /
  `euro_trucking_heavy_trailer` / `euro_fuel_tanker` / `euro_container_haul` / `euro_car_transport` /
  `euro_oversized_construction` / `euro_timber_haul` 的 `destCoords`（和 `step_unload_cargo` 的 coords）
  全是 `{0, 0, 0}`。`validate_delivery_arrival` 会拿它算距离，而原点是路面下方 70 m 的一个点 ——
  玩家把车开到那儿也判不到。已按各自主题换成真实目的地（港口/Cypress Flats/机场货运/加油站/车行/工地/锯木厂），
  每个都核对过离路 < 35 m、与路面高差 < 3 m。
- **坐标体检加了「离路多远」「与路面高差」两条判据，并抓出上面的占位点**：`tools/dev/quest_map.py`
  新增 `--build-roads`（一次性把 DurtyFree 的 67,454 个路面节点收成 108 KB 缓存）与两条提示规则
  （离路 > 60 m / 高差 > 25 m；水面节点已剔除、飞行类任务跳过）；`(0,0,0)` 升为**硬错误**。
  首次全仓扫描还留下 17 条提示，其中矿工四个任务离路 438–456 m、`civilian_ch4_mogul` 三步骤比路面高 122 m，
  需要进游戏或人眼再确认。- **热狗摊任务的地点在大楼里面，玩家根本到不了**：`hotdog_vendor` 的 4 个步骤都写在同一组坐标
  `(-150, -250, 44)`，离线渲染后可以看到它落在 Las Lagunas Boulevard 东侧一栋建筑的**内部** ——
  走过去既进不去、也不会出现交互提示。坐标改到 Legion Square 广场空地 `(215.8, -810.3, 30.7)`
  （卫星/街区两种底图都核对过是开阔地面），半径相应放宽到 8 m / 5 m。
- **没有离线核对任务坐标的手段（新增工具 + 闸门）**：一次要校 78 个模板 / 179 个坐标点，
  原先只能进游戏肉身跑。新增 `tools/dev/quest_map.py`：按社区标定把游戏坐标换算成像素、
  抓 GTA 地图瓦片（atlas / satellite / grid）渲染 PNG，红点 + 半径圈 + 比例尺，
  `--scan` 模式给出硬错误（世界边界外 / z 越界，退出码非 0）与提示（z 偏高、多步骤同点）。
  闸门 `tests/architecture/test_quest_coords.py`：硬错误必须为 0，反向用例喂一个界外点必须red；
  同时钉住热狗摊不许回到那栋楼里。用法与判读方法见 `docs/engineering/QUEST_COORDS.md`。- **`conditions.daily_limit` 是死字段，同一条路线可以一天刷无限次**：`T-CityLite.base/resources/[custom]/custom-quest` 里
  `QuestDB.CheckDailyLimit` 与 `QuestDB.UpdateDailyLimit` 都写好了，但**两边都没有调用点** ——
  配置里写着 `daily_limit = 8`，运行时形同不存在，`04-numbers.md` 的「$/h」只能算理论值。
  新增 `T-CityLite.base/resources/[custom]/custom-quest/server/quest_daily_limit.lua` 接管：接单时内存判定（`TriggerQuest` 是同步函数，不能等异步查询），
  未命中查一次库并按「当天」缓存；完成时内存 +1 立即生效、DB 异步累加；跨周期自动归零；
  DB 不可用时**放行并警告**（一次 ETIMEDOUT 不能把所有人的任务锁死）；未声明上限的模板视为不限。
  闸门：`test_daily_limit.py` 6 条（上限生效 / 计数落库 / 按玩家与任务隔离 / 跨周期归零 /
  DB 抖动放行且恢复后重新拦 / 没写上等于不限）。- **一键启动在冷启动（重启电脑后）直接退出，FXServer 根本没起**：`start-tcity.ps1` 的数据库检查用了
  `docker exec mariadb-admin ping`，而 PowerShell 5.1 在 `$ErrorActionPreference = 'Stop'` 下把**原生程序的
  stderr 当成 terminating error** —— 容器刚 `docker start`、InnoDB 还在恢复时 ping 会往 stderr 写
  `connect to server at '127.0.0.1' failed`，脚本就以这条消息退出（实测复现）。三处修法：
  ① ping 改在 `Continue` 语义下跑，只看退出码；② 顺带发现 **ping 的退出码不可信**（密码错也返回 0），
  改成真跑 `SELECT 1`，且必须用 `--host=/--user=/--password=` 长选项（PowerShell 把 `-h127.0.0.1`
  交给原生程序会变成 host `127`）；③ 等待窗口 120s → 180s，每 20 秒报一次「等 InnoDB 恢复」进度。
- **启动自检把上一次启动的日志当成这次失败**：日志文件跨启动复用，自检扫全文件，于是旧日志里的
  `awaitConnection failed` 让新一次启动判红（实测：服务器明明正常，却提示「oxmysql 连接数据库失败，请 -Restart」）。
  现在记录本次启动的日志字节偏移，只扫之后新增的行；挂到已在运行的实例时以当前长度为起点。
- **`start.cmd -Status` 在只有 1 条可疑行时崩**：PowerShell 5.1 里单条匹配不是数组、没有 `.Count`，
  改成 `@($badList).Count`；同时把提示改成「历史可疑行（含上次启动）」，避免误读成当前故障。- **`QuestManager.AbandonQuest` 被定义了两次，前一份的校验静默失效**：`quest_manager.lua` 里同名函数
  出现两遍，Lua 后一份覆盖前一份。第一份带「questId 必须是字符串 + 任务必须真的在进行中」两道校验，
  第二份没有 —— 生效的是第二份，于是传 nil/空串也会一路走到 `QuestDB.AbandonQuest`，而 SQL 那边的
  参数是 nil。现在合并为一份（保留校验 + 保留日志），并加闸 `test_quest_manager_definitions.py`：
  `QuestManager.X` 重复定义必须被抓到（判定逻辑喂合成文本，正反形状都断言）。- **按 I 键仍然弹出 qb-hud 的设置菜单，和中控屏抢键**：qb-hud 早先已把 I 键的 `RegisterKeyMapping`
  注释掉，但**玩家本机的绑定是持久化的** —— 玩家本机的 CitizenFX 的 fivem.cfg 里留着
  `rbind qb-hud KEYBOARD I "hud"`，删掉代码里的注册不会删掉它，于是按 I 同时触发 `hud`（弹 HUD 设置）
  和 `dashboard`（载具中控屏，被前者占走焦点）。修法：HUD 设置的命令名从 `hud` 改为 `hudsettings`，
  `hud` 保留为**空操作**专用于接住那条残留绑定。现在 I 只有中控屏一条路径，未坐进载具时由
  tcity-dashboard 自己回一句「你必须坐在载具中才能打开中控屏」。玩家若要恢复键位，在五M设置的
  按键绑定里给「HUD 设置」自己绑，或敲 `/hudsettings`。
- **多站路线校验器在真机上把玩家卡在第 1 站（R1 真机验收抓出）**- **多站路线校验器在真机上把玩家卡在第 1 站（R1 真机验收抓出）**：`T-CityLite.base/resources/[custom]/custom-quest` 的
  `quest_route_validators.lua` 用了裸全局 `QBCore`，而该资源里根本不存在这个全局（每个服务端文件
  都用 `exports['qb-core']:GetCoreObject()` 现取）。第一次站点校验就抛
  `attempt to index a nil value (global 'QBCore')`，经 `pcall` 在客户端只剩一句被截断的
  `Validator error: @custom-quest/server/quest_rou…` —— 玩家侧表现为「到了点按 E 没反应」。
  补 `local QBCore = exports['qb-core']:GetCoreObject()` 后 `garbage_v1_city` 四站全程通过。
- **校验器的拒绝原因被注册表吞掉**：`QuestValidators.Run` 写的是 `local ok, result = pcall(fn, ...)`，
  只接住两个返回值 —— 校验器返回 `(false, 'wrong_job')` 时第二个值被丢弃，所有拒绝都压成字符串
  `'failed'`。这影响**所有**校验器（不止多站路线），是排查看不到原因的第二层原因。改成
  `local ok, passed, message = pcall(...)` 并原样返回 `message`。
- **任务列表的三个门控从来没生效过（CC 复核发现）**：`quest_availability.lua` 同样用裸 `QBCore`，
  但写法是 `type(QBCore) == 'table'` 守卫 —— 不报错、条件恒假，于是剧情抉择前置、在勤警力、
  冷却三项**静默 fail-open**：有前置要求的任务恒显示「可接」，冷却中的不显示剩余时间。补
  `local QBCore = exports['qb-core']:GetCoreObject()` 后三项一次修好（玩家可见行为会变：
  该灰的会灰、冷却会显示）。根因能藏这么久，是因为测试桩自己造了一个生产环境没有的全局 QBCore。
- **校验失败的提示发错了时机**：`runStepValidator` 的聊天/通知提示写在 `Enforced()` 判断之前，
  `quest_step_validator_enforce=0`（放行模式）时校验失败会被放行，玩家却仍收到红字误报。
  现在提示只在「真的拦住」的分支里发；服务端 `print` 保持无条件（诊断要全量）。
- **qb-shops 补货结算是敞开的钱口（R0 第 1 项）**：`T-CityLite.base/resources/[qb]/qb-shops/server/main.lua` 的
  `RestockShopItems` 只有「10 米距离 + 每玩家每店 30 秒」两道闸，**没有任何「这一趟是跑出来的」凭据** ——
  任何职业站在任意交货点，每 30 秒就能领 `Config.DeliveryPrice`（$500），配置里 45 处交货点。
  现在改成**押金会话**：只有 `DoBail(true)` 扣过押金才开一趟，趟内最多结算 `Config.MaxDeliveries` 次
  （与客户端 `JobsDone` 同口径），还车退押金时关闭会话。钥匙用 `citizenid` 而非 source，重连不白送新趟。
  先红后绿的证据：旧实现的 probe 在「没付押金」场景下照付；新实现在同场景拒绝、付过押金的照付、满 20 次后拒绝、
  还车后拒绝（`tests/unit/layer3_business/test_shops_guards.py`）。
- **濒死时「按 E 呼救」没有任何反应**：`T-CityLite.base/resources/[qb]/qb-ambulancejob/client/dead.lua` 的文案写 E，
  轮询的却是 control 47（INPUT_DETONATE = 键盘 G）；改成 38 并补一条 feed 回执。
- **扣押场「有钱但无法付款」**：`T-CityLite.base/resources/[qb]/qb-garages/html/script.js` 把 `state=2` 一律渲染成 `Impound` 且按钮 disabled，
  在扣押场也点不动；现在 `type='depot'` 且 `depotPrice>0` 就渲染成可点的 `$金额`（公共车库里的被扣车仍只读）。
- **交互提示仍走 DrawText**：`qb-garages` 的 "E - Depot"/房屋车库两处改走 `custom-prompt`（准星下方）；
  `custom-prompt:Show` 增加"同 key 同文案不重发"，逐帧调用者不再刷 NUI。
- **通知统一到新标准（N-1a 轨 0）**：`QBCore.Functions.Notify` 入口按 type 映射到 custom-notify 的三个通道
  （success/primary/info→feed、error→error、warning/police/ambulance→toast），**1119 处调用点一行不改**；
  custom-notify 不可用时 pcall 失败回落原三条轨。右侧 qb-core 黑条与 GTA 原生黑条默认不再出现。
- **扣押场取车面板没有光标、点不了付款**
  - 真因：`SetNuiFocus` 按资源生效，`custom-ui` 无 ui_page，从它那里调等于把焦点给空气（其 `:122-125` 注释已写明）。
    `OpenMenu({owner=…})` 现在压栈，由拥有页面的资源导出 `ApplyFocus` 真正按焦点；`CloseMenu({owner=…})` 只弹自己那层。
    涉及 `custom-ui`、`qb-garages`（上一版漏写了 export —— 注释里有、代码里没有）、`qb-menu`、`qb-vehicleshop`；
    `qb-garages` 另加一道"自己再按一次焦点"的双保险。
  - 连带修掉 CC 评审指出的两个回归点：① `qb-vehicleshop` 的分期/试驾回调绕开栈直接 `SetNuiFocus` → `menu:qb-vehicleshop`
    帧滞留，之后玩家"下车走不动"，现改为走 `_vCloseNui()` 弹栈；② `custom-ui:CloseMenu` 弹栈后又补一刀
    `SetNuiFocus(false,false)`，与栈的结论打架，现在只在老路径（未弹栈）时才清。
  - 新闸门（`tests/architecture/test_input_layer_contracts.py`）：**用 `OpenMenu(owner=…)` 的资源必须导出 `ApplyFocus`**，
    锚定行首匹配（注释/字符串里提到不算），并带两条反向用例。当前扫描 62 个资源、0 违规。
- **手机车库的「📍 地图」点了没反应**
  - `phone:server:garageCoords` 把 `exports['qb-garages']:getAllGarages()` 当字典用（`garages[key]`），
    而它返回的是**数组**（每项带 `name` 字段）→ 永远 nil → 客户端静默返回 `no_coords`。
    改成先兼容字典、再线性匹配 `name`；真取不到坐标时给一条 error feed（不再静默）。
- **载具键位 · ESC 菜单里方向键会打灯（PO 说的老问题）**
  - `custom-vehicles` 的输入门只问 `custom-ui:IsTaken()`，而 ESC 暂停菜单是 GTA 自己的前端、不在层栈里，
    所以车里按 ←/→/↓ 导航菜单时会同时切转向灯/双闪。门里补 `IsPauseMenuActive()` 与 `IsNuiFocused()`；
    `cruise.lua` 的 lock 模式 ↑↓ 同样加门（`seatbelt.lua` 一直是对的，照它写）。
  - 双闪开/关提示从 qb-core 右栏（`'primary'`）改走 feed。
- **游戏内提示层 · 真机第四轮（PO 2026-11-12 夜）**
  - **采矿 `SCRIPT ERROR: attempt to call a nil value (global 'IsDowned')`**：`IsDowned()` 写在文件 215 行、
    第一次使用在 101 行，Lua 的 local 只对其后可见 → 移到文件顶部（13 行）。`luac -p` 拦不住这类错误。
  - **冶炼厂 blip 回滚**：恢复 `SetBlipAsShortRange(true)`（全图可见是为排查"找不到冶炼炉"临时加的，
    PO 已确认找到）。
  - **I 键不再绑 HUD 设置**：去掉 `RegisterKeyMapping('hud', …, 'I')`，I 留给载具信息板（尚未实现），
    HUD 设置只走 `/hud`。
  - **电影模式 on/off 分居左右**：`cinematic_off` 原来带 `'error'` → 右侧 qb-core NUI，`cinematic_on` 走 feed →
    左侧，看起来像两条各弹一个；现在都走 feed。
- **游戏内提示层 · 真机第三轮（PO 2026-11-12）**
  - **商店界面打开后仍显示 `[E] 打开商店`**：`qb-inventory` 新增只读 `exports('IsOpen')`（开关时刻只有它知道），
    `qb-shops` 在背包界面开着时让位、关掉后按需重现。
  - **薪水 / 送货 / HUD 设置提示没迁移**：`qb-core` 发薪 2 处、`qb-shops` 送货 13 处、`qb-hud` 5 处
    （地图形状 / 电影模式）改为走 `custom-notify`（`error` 保持红条），资源缺失时回落原通道。
  - **护甲误报**：`qb-hud` 的护甲提醒改成"从有到无"的边沿触发（新增 `armorPeak`），没装护甲不再弹
    "护甲已经打光了"。
  - **采矿交互返工**：`custom-mining` 客户端加 `IsDowned()`（四键状态袋）——倒地不出提示、不派发 E、
    中断采矿循环；服务端 `mining:server:mineOre` 以 `metadata.isdead/inlaststand` 拒绝产出。
    冶炼厂 blip 从 `SetBlipAsShortRange(true)` 改成 `false` + `SetBlipDisplay(4)` —— 它离矿点 5.0–5.7 km，
    近距离模式等于永远看不见（"不知道冶炼炉在哪"的根因）。
  - **保险箱按 E 无反馈**：`qb-storerobbery` 现在无论 `usable` 都响应 E —— 警力不足给 `error`
    「警力不足 · 需 N 名，当前 M 名」，冷却/已空给 `feed`「冷却剩余 mm:ss」（沿用 C-2 的口径变更）。
- **游戏内提示层 · 真机第二轮（PO 2026-11-11）**
  - **feed 压小地图**：`custom-notify` 的 `bottom` 从 10.3vh 改 21vh。实测原生通知块底边在 20.9vh
    （同窗 2546×1434 底部留 300px），小地图约占底部 19.8% 高 —— 原来 10.3vh 正好压上去。
  - **`[E]` 要反复按才开商店**：`T-CityLite.base/resources/[qb]/qb-shops/client/main.lua` 的 `IsControlJustReleased(0,38)` 原来在
    `Wait(200)` 的轮询里采样（松开只在 1 帧为真，约 11/12 次采不到）；改成"在范围内每帧采样 +
    内容未变不重发 NUI 消息"，离开范围仍回落 500ms。
  - **复活后仍走原生提示**：`T-CityLite.base/resources/[qb]/qb-ambulancejob/client/main.lua` 的 `info.healthy` 与
    `T-CityLite.base/resources/[qb]/qb-hud/server.lua` 的 `stress_removed` 都没有 type（落 GTA 原生 feed）→ 改走
    `exports['custom-notify']:PushLocal('feed', …)` / `:Push(src, 'feed', …)`，自定义通知资源不在时
    回落到原来的 `QBCore.Functions.Notify`。
  - **商店提示闪烁的根因**：`T-CityLite.base/resources/[custom]/custom-mining/client/main.lua` 每轮（800ms）无条件
    `exports['custom-prompt']:Hide()`，会打掉别家正在显示的提示；补 `promptShown` 守卫，只 Hide 自己
    Show 过的（与 qb-shops / qb-storerobbery / qb-ambulancejob / qb-management 一致）。
  - **HUD 五环圆心缺状态图标**：H-1 为把数值移到环下，删掉了 armor/hunger/thirst/stress/oxygen
    五个内层环的 `show-value`；Quasar 2.1.0 只在 `showValue` 时渲染默认插槽 → 图标连 DOM 都不生成。
    补回 `show-value`（插槽会盖掉数值，环下 `.stat-num` 仍是唯一数字）。
  - 闸门：`tests/architecture/test_hud_contract.py` 新增 `test_ring_icon_slot_needs_show_value_*`，
    反向校验"删掉 show-value 必须红"。

### Added
- **游戏内 UI/UX · P1 手机打字 + P2 三层通知**（PO 2026-11-10 拍板 D1=B / D5=乙）
  - 手机文字输入：`focus.lua` 的 `PushFrame` 支持 `keepInput` 覆盖，text 帧改为
    `keepInput=false`（原来写死读 convar，键盘一直归游戏，CEF 收不到字符）；
    新增 `textFocus` NUI 回调，鼠标点输入框也入栈；`nav.lua` 在 text 帧期间不注入按键
    （否则一键两用、Backspace 把输入框 blur 掉）。custom-phone 前端新增 layers.ts
    （`textOwned` store + `use:textFocus` action），Messages 已接入。
  - 三层通知：新资源 `custom-notify`（`feed` 左下 / `toast` 中央 / `error` 左下红 /
    `phone` 只进手机），服务端唯一入口 `exports['custom-notify']:Push`，
    每玩家 6/s 限流（qb-core Notify 的 200ms/1 条会把一次交易的第二条静默丢掉）。
    首个迁移点：`custom-consumables` 吃喝结果。
  - `/amenu` 补 `'admin'` 权限参数（原来默认 `user`，任何玩家能打开管理员面板）；
    `custom-ui` 屏蔽表加 E(38) / ALT(19)：手机开着时不再触发游戏交互。
  - 闸门：`test_notify_contract.py`（kind 两侧一致 / phone 不上屏 / 限流下限 / 必须在启动集）
    + 4 条变异用例；`test_consumables.py` 的切块从死代码事件改为 `CreateUseableItem`。
- **开服就绪包**（目标从「磨底座」转成「能开门」）：新增 `tools/dev/launch_check.py`，把"这台机器能不能
- **开服就绪包 · CC 复核后的加固**（两条 P0 + 四条 P1）：
  ① **#1 原来不扫真正决定启动集的 `server.cfg`** —— 运维在那里加一行 `exec configs/modules/dev.cfg`
  就能把 `/test` `/stress` `/agent` 还给玩家，而所有检查依然全绿；现在 module cfg 递归扫 + `server.cfg`
  （或 `TCITY_SERVER_CFG` 指的那份）一起扫，`ensure|start|exec` 三种写法都认；
  ② **占位符能带着 P0=0 上生产** —— 新增 #12：license / rcon / DB 口令是 `<...>` 或缺失就红；
  #8 的 hostname 也认占位符；#9 改成"开关开着但没 token = 红"（原来这个组合反而绿）；
  ③ `db_backup.py` 的口令原来进了 `docker exec -e MYSQL_PWD=<口令>` 的 argv（宿主机 ps/WMI/EDR 可见）→
  改成 `-e MYSQL_PWD` 只传变量名、值走子进程 env；备份写入改成临时文件 + fsync + `os.replace`（半截文件不再冒充有效备份）；
  ④ #11 从"mtime ≤ 24h"改成读 manifest：大小对不上或表数 < 50 都判红；
  ⑤ #5 从"文件存在"改成查 `db_backup.py` 里有 dump 实现、runbook 里写了"恢复演练"；
  ⑥ #2 的守卫判据改跑去掉注释后的调用文本（`-- IsAdmin` 不再算守卫）。
  另外：模板补 `sv_scriptHookAllowed 0` / `sv_pureLevel` / txAdmin 端口与 ACE 说明；runbook 补
  "生产预演"一节与演练库授权（少了那条，`--restore --to-scratch` 第一步建库就失败）。

  实测：按模板填一份 `server.prod.local.cfg`（gitignored），`TCITY_SERVER_CFG=… launch_check.py`
  → **12 项检查 P0 = 0**（唯一 P1 是 txAdmin 自带文档里的示例 license）。
  1339 passed / 147 skipped / 51 subtests。
  开门"拆成 11 项可复跑的检查，分 `repo`（CI 能跑）与 `local`（只在部署机跑）两半。
  首次运行抓到的真问题：

  | 项 | 发现 | 处置 |
  |---|---|---|
  | #1 | `hud-position-tool`、`custom-debug` 在**默认启动集**里（等于把调试入口开给玩家） | 移进 `configs/modules/dev.cfg`（生产不 exec） |
  | #2 | 服务端 dev 命令无守卫（`careertest` 等） | 逐个核对：`careertest` 早已是 `'admin'`；其余在 dev-only 资源/测试夹具里 |
  | #3 | 入库文件里的"密钥" | 全是占位符或 vendored 示例（txAdmin 文档里的 `cfxk_…`），非本仓库密钥 |
  | #4 | 没有生产配置模板 | 新增 `configs/prod/server.cfg.example`（无密钥）+ 模板内容校验 |
  | #5 | **从没做过备份** | 新增 `tools/dev/db_backup.py`（dump + manifest + 保留策略 + 恢复演练），实测 403 KB / 68 表，恢复到 `_restore_probe` 后 73 表 |
  | #6–#11 | 本机是开发配置（8 槽、hostname 带 DEV、agent 开关全开、DB 是 root） | 写进 runbook 的"生产 vs 开发"对照表；生产值由模板承载 |

  另：`docs/engineering/2026-11-launch-runbook.md`（开服前/中/后 + 出事处置 + 回滚 + 明确列出"还没做的"）、
  `.gitignore` 加 `backups/`（含真实玩家数据，永不入库）、`launch_check.py --ci` 接入闸门
  `tests/architecture/test_launch_readiness.py`（3 条用例，含两条注入式反向验证 + 1 条变异）。
### Added
- **`DirtyFlushStats` 说清"管线是否存在"**（老账：custom-testing 的压测靠 `dirty_count == 0` 判"脏池是空的"，
  而 `DirtyFlush` 全局从来没被定义过，导出走的是 `{ dirty_count = 0 }` 兜底 —— 那条断言永远是
  "空池，通过"）。现在导出带 `available`：未接入 → `available=false`，已实现 → 原样透出 + `available=true`，
  `Stats()` 返回 nil 也降级成 `available=false`。
  压测套件据此报 **跳过**（新增 `skip` 状态与「N 跳过」汇总）而不是假通过。
  新用例 `test_dirtyflush_contract.py` + 探针 `bus_dirtyflush_probe.lua`（真加载 bus.lua，三条路径都断言）。
### Added
- **net event 口径校准（清掉 §3.1.1 那笔 36 条的账）**：`job_deny_guard` 原来把「判空 + 参数校验」也算成
  职业守卫，按严格口径（条件里必须真的提到 `.PlayerData.job`）重跑后 36 条从"已鉴权"翻成"未登记"。
  逐条复核后分三类处理，**本仓库自有资源的未登记事件归零**（439 事件 / 已鉴权 204 / 已登记 249 / 未登记 0）：

  | 类别 | 处理 |
  |---|---|
  | 归属/状态校验（`owner ~= Player.PlayerData.citizenid`、`Races[id].Racers[citizenid]`） | 新增证据类 `self_scope_guard`（含"从 citizenid 取自己那条"的别名识别） |
  | 真 helper：`inReviveWindow`、`IsRaceHost`、`IsWhitelisted` | 登记 `net_event_guard_helpers.json` / `already_checked` |
  | 供应商资源：cfx-default 21、monitor 33、PolyZone 4、connectqueue 1 | 新增 `vendor_example` 类别，闸门**按文件前缀**校验，防止给自己代码开后门 |
  | 缺 `local src = source` 绑定的（qb-weapons ×1、pma-voice ×3） | 补绑定，行为不变 |

  新闸门 `tests/architecture/test_net_event_scope.py`：出口判据「本仓库自有资源未鉴权又未登记 = 0」
  + 守卫形状的双向用例（接受真守卫 / 拒绝"只判空"与"无 return"）+ 1 条变异（把 `self_scope_guard`
  从 `is_guarded` 里摘掉 → 立刻变红）。
### Added
- **P2-4 预算数字化**：`tools/dev/budget_probe.py` 按 fxmanifest 找服务端脚本、脱掉注释后统计六项静态计数，
  输出基线并由 `T-CityLite.base/tests/architecture/io_budget.json` 钉住上限（`--update` 只允许往下写）：

  | 指标 | 基线 | 含义 |
  |---|---|---|
  | `db_call_sites` | 463 | `MySQL.*` / `exports.oxmysql` 调用点总数（趋势指标） |
  | `fast_polling_loops` | 2 | `while true` + 首个 `Wait ≤100ms`（≈600 次/分钟/条） |
  | `warm_polling_loops` | 5 | `while true` + `Wait ≤1000ms`（≈60 次/分钟/条） |
  | `wait_zero_loops` | 1 | `while true` + `Wait(0)`（吃满一个 tick） |
  | `broadcast_sites` | 150 | `TriggerClientEvent(..., -1, ...)` 全服广播点 |
  | `broadcast_inline_json` | 5 | 广播点里内联 `json.encode`（每次广播重新序列化） |

  `fast_polling_loops` 的两条与 `wait_zero_loops` 的一条已逐一点名（txAdmin 的 runcode web 服务、
  qb-core 离线玩家清理循环、connectqueue 的排队 pop 循环），都是上游代码，预算条目里写了 owner 与到期日。
- **闸门 `tests/architecture/test_budget.py`**：5 条反向形状（新增 DB 调用 / 50ms 轮询 / `Wait(0)` 循环 /
  广播内联 `json.encode` / 注释里的形状不该计数）+ 1 条变异（往 custom-justice 注入 50ms 轮询 → 红、撤回 → 绿）。
- **第九轮 CC 复核**：Lua 的真值规则是"只有 `nil` / `false` 为假"，而常量求值用了 Python 的 `bool()` ——
  `while 0 do` 在 Lua 里是死循环，却被判成"等条件"。修法：常量求值一律按 Lua 真值判定（`0`、`""` 为真）。
  反向用例：`while 0 do Wait(1) end` 必须计入 fast；`repeat Wait(0) until 0` 只跑一次 → 归等条件循环。
- **第八轮 CC 复核**：上一轮的修法引入了新漏洞 —— 外层取"体内第一个 Wait"，遇到
  `while true do for … do Wait(2000) end Wait(0) end` 会先取到 2000ms（>1000，一个桶都不命中），
  而内层 for 的 2000ms 也不计，四个桶全空。修法改成取体内**最小**的 Wait：最小 = 最坏节奏，
  `Wait(0)` 在体里出现就说明这条循环在自旋。反向用例：「先 2000ms 后 Wait(0)」必须计入 wait_zero。
- **第七轮 CC 复核**：`while true do for … do Wait(50) end end` —— 外层节流其实由内层 `for` 提供，
  但嵌套排除把内层整体剔掉、`for` 又不算 conditional，于是 fast/warm/zero/unknown 全都不动。
  修法：只排除**同为无限**的嵌套循环（它有自己的节奏）；嵌套的 `for` / 等条件循环里的 Wait 算外层的。
  反向用例：「外层无限 + 内层 for 节流」必须计入 fast。`conditional_busy_wait_loops` 12→13 是分类器
  把 connectqueue / monitor 里两个 `for` + `Wait(0)` 认了进来（判据更严，不是新债）。
- **第六轮 CC 复核**：`repeat … until false` 后面还有同块语句时，条件会把后面的 token 一并吞进来
  （`false cleanup ( )`），常量求值取不到 → 判成"等条件"。修法：条件只取到本行结束或 `;`。
  反向用例：`until false` 后跟 `cleanup()` 仍必须是无限轮询。
- **第五轮 CC 复核**：`until (false)`（括号包着）与 `until 1 == 2`（常量比较）仍被归成"等条件" →
  条件归一化（去外层括号）+ 常量布尔求值（只放行数字/比较/逻辑符号，`false`/`true`/`nil` 先映射）。
  反向用例再补一条：`false` / `(false)` / `1 == 2` 三种恒假写法都必须是无限轮询、`until not cond` 是等条件。
- **第四轮 CC 复核（一处真错误）**：`lua_blocks.loops()` 对 `repeat` 的 condition 写死成空串，而
  `_is_infinite` 把空条件当无限 → **所有** `repeat … until <非 false 条件>` 都被当成无限轮询。
  后果有两个方向：qb-multicharacter 那两条 `repeat Wait(10) until hasData()` 被计成 fast（实际是等条件），
  以及"把 `until false` 改成 `until cond`"这种无限化回归看不出来。修法：`repeat` 的条件从 `until` 之后
  按块深度取到块外，只有字面量 `false` 算无限。基线随之收紧：`fast_polling_loops` 4→2、
  `warm_polling_loops` 6→5（原来多算的就是那两条 repeat）。反向用例补到 16 条。
- **第三轮 CC 复核：放弃正则，改用词法切分 + 块配对**。前两轮修的都是同一个病根 —— 用正则截循环体，
  字符串里的 `end`、`elseif … then`、嵌套 `CreateThread`、`for` 循环全都会让截断错位。新增
  `tools/dev/lua_blocks.py`（约 170 行）：把 Lua 切成 token（字符串/长字符串/数字/名字/符号），
  开块只认 `do`/`function`/`if`/`repeat`、收块只认 `end`/`until`（`then` 不单独计数，所以
  `elseif … then` 不会多算一层），于是 `for … do` / `while … do` 都各配一次 `end`。
  预算探针改为在 token 上工作：`for i = 1, n do Wait(0) end` 归「等条件循环」、
  `print("end")` 不再截断循环体、嵌套循环的 Wait 不再算到外层头上（外层真正 60 秒一圈不会被误报成 fast）。
  基线随之收敛：`conditional_busy_wait_loops` 13→12、`broadcast_sites` 150→152（token 口径比正则准）。
  反向用例补到 15 条。
- **第二轮 CC 复核（又四条）**：⑤ 循环体用 600 字符定窗，`while true do` 先干活、末尾才 `Wait(60)` 的
  写法会整条漏掉 → 改成配对到 `end`/`until` 取体内第一个 Wait；⑥ `Wait(1e3)` / `Wait(0x64)` 落在常量
  字符集之外被当"未知" → 放进字符集，并对 `10**400` 这类加溢出/超大值收敛（超一天即封顶）；
  ⑦ `while running do Wait(50)` 这类非字面量条件不匹配 → 现在**所有 `while … do` 与 `repeat` 都认**，
  但按条件分两类：字面量 `true/1`（或 `repeat`）= 无限轮询，其余 = 等条件循环；
  ⑧ 等条件循环里的 `Wait(0)` 是正常写法（等到就退出），不该算进 `wait_zero_loops` → 新增
  `conditional_busy_wait_loops` 单独计（11 条，用来发现"等一个永远不成立的条件"）。
  基线随判据再更新：新增 `conditional_busy_wait_loops` 11、`polling_loops_unknown_interval` 22→23。
- **CC 复核后的判据加固（四条都是"能绕过"）**：① `Wait` 参数不是数字字面量（`Wait(ms)` / `Wait()`）时
  整条循环被静默丢弃 → 新增 `polling_loops_unknown_interval` 单独计数（有预算就会显形）；
  ② 循环只认 `while true`，漏 `while (true)` / `while 1` / `repeat … until` → 一并认；
  ③ `Wait(3600 * 1000)` 这种常量表达式被当"未知" → 改成安全求值（只允许数字与四则运算）；
  ④ 广播用 300 字符窗口找 `json.encode`，会把下一条语句的序列化算到广播头上、也会漏掉长参数 →
  改成按配对括号取参数列表。
  判据变严后基线随之变化（这不是退步，是判据换了）：`fast_polling_loops` 2→4（新增把
  qb-multicharacter 两条 10ms 循环显形）、`warm_polling_loops` 5→6、`broadcast_inline_json` 5→1
  （固定窗口的 4 个是误计）。反向用例补到 10 条。
- **顺带收敛**：把「哪些文件算服务端」的判定从 `tests/architecture/server_await_scan.py` 提到
  `tools/dev/fivem_manifest.py`，P2-1 的闸门与 P2-4 的探针共用同一份 manifest 解析（此前只有前者一份，
  但预算探针也要用 —— 复制一份迟早会走岔）。
- **P2-2 启动顺序进版本库**：`T-CityLite.base/configs/boot.json` = 模块 exec 顺序的唯一事实来源
  （`server.cfg` 是 gitignored，17 行 `exec configs/modules/*.cfg` 的顺序以前只活在本地那份文件里）。
  新增 `tools/dev/boot_cfg.py`：把 boot.json 的模块顺序 + 各模块 cfg 的 `ensure` 行展开成真实启动序列，
  再按每个资源 `fxmanifest.lua` 的 `dependency` / `depend` 校验「依赖必须先于使用」，另核对
  boot.json ↔ 模块目录一一对应、`ensure` 不指空、同一资源不重复 ensure。
  实测：84 个资源 / 17 个模块，0 错序；本地 `server.cfg` 的 exec 顺序与 boot.json 一致；
  真机 85 个在线资源里 84 个都在序列内（多出的 `fivem-map-skater` 由 server.cfg 的 `start` 拉起）。
- **闸门 `tests/architecture/test_boot_order.py`**：6 条反向形状（错序 / 注释写对但顺序错 / 重复 ensure /
  ensure 不存在的资源 / 模块没进 boot.json / server.cfg 与 boot.json 不一致）+ 嵌套资源目录
  （`[qb]/qb-core`）形状 + 1 条变异（把 `ensure qb-core` 挪到 `ensure oxmysql` 前面 → 红、撤回 → 绿）。
  判据只看 `ensure` 行与 manifest 依赖，**顺序注释不参与判定** —— 删掉注释不影响结论。
- **CC 复核修正**：`BUILTIN_RESOURCE` 硬编码名单原来**先于**仓库索引判断，名字同时出现在 resources/ 和
  内置名单里（自带 fork 的 chat 这类）时会被当内置跳过，缺失/错序静默通过 → 改成「仓库里有就按仓库判，
  没有才看内置名单」，并补一条反向形状（仓库里真有 chat、依赖方没 ensure chat → 必须报）。
- **DoD 自证**：新增用例把真实 configs/ 复制到临时目录、删掉全部注释行，①原顺序仍通过 ②交换两条
  ensure 仍红 —— 「删掉顺序注释后闸门仍能拦住错序」由测试本身证明。
- **已知残留**：`boot.json` 只管 `ensure` 的 84 个资源；地图这类由 server.cfg `start` 拉起的资源不在内。
  另外「资源 A 在加载期读资源 B 的 exports 但没声明 `dependency`」这类隐式顺序约束无法静态判定。
- **P2-1 `patron_service` 读路径不再 Await DB**：`GetTier` 原来在缓存未命中时 `promise.new()` +
  `Citizen.Await` 同步查 `patron_records`，第一次读就挂住处理该事件的协程（它还被 `IsActive` /
  `GetTierBySource` 这类高频入口调用）。现在只读缓存、未命中返回 0（保守）并后台预热，另加
  `GetTierAsync(citizenid, cb)` 给需要确定值的调用方；DB 失败/无行给 30 秒退避的 0，避免缓存一冷
  就被并发打爆。
- **闸门 `tests/architecture/test_no_server_await.py`**：只扫服务端脚本（客户端 Await NUI/动画是正常
  写法）且跑在**脱掉注释**的代码上；存量 5 条进 `server_await_allowlist.json`（每条写明为何不是
  阻塞主线程 + owner + 到期日），allowlist 里有、代码里没有也会红；配 1 条变异用例（往
  custom-justice 注入 Await → 确认变红），`gate_coverage` 未证明数仍 **276**。
- **探针 `patron_probe.lua`**：`Citizen.Await` 桩成 `error('would block the game thread')`，fake oxmysql
  支持正常 / 同步抛错 / 永不回调三种模式。对 master 版本跑 5 true / **17 false**；真机启动
  `patron (5 methods)`、85 资源、`SCRIPT ERROR: 0`。
- **CC 复核后的三处修正**：① 闸门原来按路径猜服务端，漏掉了 core-framework 的 patron_service.lua 本体和
  `contracts.lua` / `bus.lua` / 根级 `*_server.lua` → 改成以 `fxmanifest.lua` 的 `server_scripts` /
  `shared_scripts` 为准（309 个服务端文件），变异点也改到 `services/` 布局上证明覆盖；
  ② 失败条目的退避实际是 5 分钟（沿用 CACHE_TTL，`failed_at` 分支成了死代码）→ 抽出 `cacheValid`
  让失败条目按 30 秒过期；③ `loading` 用 `pcall` 包住导出调用并在 10 秒后允许重试，
  否则一次同步抛错/回调丢失会让该玩家永久返回 0。
- **第二轮 CC 复核再修两处**：① manifest 解析器只认 `keyword [{=]` 的形状，而仓库里 20+ 处是
  `server_script 'server/main.lua'` / `shared_script '...'`（单数 + 空格）—— 那些资源贡献 0 个
  服务端文件；改成「括号配对 / 到行尾」两种取法，glob 加 recursive 且对目录做 escape
  （`[voice]`、`[qb]` 在 glob 里是字符类）。服务端文件集合 309 → **701**。② `SetTier` 与在途查询
  无代际校验：冷读发出 SELECT → `SetTier(3)` 写缓存 → 旧回调无行，会把刚设的等级覆盖成 0
  （失败 30 秒、旧行 300 秒）。加 `generation[cid]`，回调先核对代际再落地。
- **第三轮 CC 复核再修两处**：① 解析器做 `server - client` 减法，把 connectqueue 里同时声明为
  `server_script` + `client_script` 的 shared/sh_queue.lua 剔出了服务端集合（它确实在服务端执行）→
  去掉减法，client 桶只留作诊断；② 看门狗超时重发时没有换代际，q1/q2 持有同一代际，慢的那条晚到
  仍会覆盖新结果或写 markFailed → 重发前 bump；另让跨代际丢弃时也回调调用方（否则
  GetTierAsync 的 cb 永不触发）。服务端文件集合 701 → **704**。
- 服务端剩余 4 处 Await 已声明性质：`qb-core` 的 `TriggerClientCallback` 同步模式、`custom-agent-client`
  的动作回执、`T-CityLite.base/resources/[custom]/custom-quest` 缓存空窗 DB 兜底 ×2、`qb-crypto` ticker HTTP（独立线程）。
- **基石三件套（规范 / 现状 / 目标）入库**：新增 `docs/engineering/STANDARDS.md`（TS-1…TS-13，每条挂闸门或显式缺口）、`docs/engineering/FOUNDATION-AS-IS.md`（组件、三条主链路、已知缺口，附 7 张 UML）、`docs/engineering/FOUNDATION-TO-BE.md`（五层目标、三条硬规则、性能预算数字），以及 `docs/engineering/2026-11-foundation-plan.md`（P0/P1/P2 施工计划与交付标准）。图纸在 `docs/engineering/assets/foundation/`（部署拓扑、分层组件、资源包图、奖励时序、事件时序、数据状态机、路线图），源生成器为一次性脚本，产物为纯 SVG，无外部依赖。
- **两个 P0 闸门先红后绿**（改动前实测 `5 failed`：`test_economy_multiplier` 的 3 条 + `test_engine_event_guards` 的 2 条；改完后两个文件共 7 passed）：`tests/architecture/test_engine_event_guards.py`（引擎层调试事件的来源守卫，带剥守卫反向用例）、`tests/unit/layer1_core/test_economy_multiplier.py`（真实加载 core_economy 的 main.lua 跑 Lua 沙箱，钉住倍率单位）。

### Changed
- **文档生命周期 Phase 1–4 落地：276 份文档全登记、孤儿清零、本机绝对路径清零**（`docs/standards/doc-lifecycle.md`）：按规范 §11 把存量一次做完，数字全部来自 `python tools/docs_lifecycle.py --check/--report`。具体：① 给 273 份文档补 frontmatter（登记率 3/276 → **276/276**），`system` 按 §7 的 19 个键、`type` 按 §1 的 8 种、`id` 由路径派生保证唯一、`updated` 取 git 最后提交日、`review_by` 按类型周期（manual/research/runbook 90 天，spec/meta/plan 180 天）；② 孤儿 43 → **0**，全部挂进所属目录的 README 索引（`T-CityLite.base/docs/README.md` 根级补遗表、`T-CityLite.base/docs/agent/README.md` 评审表、`docs/police/README.md` 的 plans 索引等）；③ 带盘符的 file URL 67 处 → **0**，同目录引用改相对文件名、其余改仓库根相对路径、`docs/reasonix-hooks-config.md` 的 PowerShell 音乐路径改用 `$env:USERPROFILE`；④ 4 组重复主题定 SoT 并双向 `supersedes`（`phone-design`、`BLUEPRINT-ITEMS`、`RESEARCH-2026-10`、5 份 `LEGACY.md` 的重复标题改为按目录区分）；⑤ 4 个不合规文件名改正（`BLUEPRINT-ITEMS-v1` / `RESEARCH-2026-10-v1` → `-ARCHIVED`，`00_SERVER_MASTER_MANUAL.md` → `00-server-master-manual.md`，中文名叙事设计稿 → `middle-east-narrative-design.md`）。`--check` 现为 **0 error / 0 warning**。
- **`tools/docs_lifecycle.py` 三处口径修正**：① 断链检查改为复用 `T-CityLite.base/tests/architecture/legacy_docs.json` —— 与既有的 `test_docs_links.py` 同一张豁免表，不再一边豁免一边报断（历史归档不修引用是有意的，改路径会伪造历史）；② `supersedes` 双向校验原来拿**文件路径**去比对方的 **id 列表**，只要有 `supersedes` 就必然误报，改为比 `id`；③ 新增 `docs/INDEX.md` 过期即红的 CI 校验。生成物（`<!-- @generated by ... -->` 打头的 `T-CityLite.base/docs/agent/TOOLS.md`）按 `INDEX.md` 的既有先例排除出扫描范围 —— 给它盖 frontmatter 会被 `tools/agent_tools.py --check` 立刻判 stale。
- **CI 新增 `docs-lifecycle` job（blocking）**：`.github/workflows/ci.yml` 补上规范 §10 声称存在但实际缺失的 job —— `--check --verbose` 有 ERROR 即红，`--index` 后 `docs/INDEX.md` 有 diff 也红。转阻断的两个前提（已登记率 ≥ 90%、断链 0）本次同时满足。
- **根入口文档压回行数闸门内**：补 frontmatter 后 `AGENTS.md` 119 行、`CLAUDE.md` 27 行，双双越过 `test_agent_docs.py` 的上限（110 / 20）。按 AGENTS.md 自己的规矩压到 **105 / 20** 行：合并重复的环境事实与命令块，指向新增的 `docs/INDEX.md` 作为全量清单入口。


- **存档收敛为单一写者，拆掉 `ForceFlush → Save(true)` 的环（P1-2 / P1-1）**（qb-core / core-framework）：qb-core 的 `persistence_manager.lua` 重写为唯一写者 `Store`（一份脏池、一个定时器、一条 upsert），core-framework 的同名文件降级为纯委托层（无池、无 SQL、无定时器、不再回调 `Save(true)`）。三处语义修正：① 刷盘**成功才清脏**，失败保留 + 指数退避 + `failed_flushes` 计数（以前无论 SQL 成不成都清）；② `QBCore.Player.Save` 强制存档改为直接 `Store.SaveNow`，失败时 `IsDirty` 保持为 true 并 `ShowError`（以前无条件清）；③ `FlushAll` 兜底扫描 `IsDirty = true` 但没进池子的玩家（economy/metadata 服务只标 `IsDirty`，他们的钱以前只在下线那一刻才落库）。停服刷盘返回 ack `{reason, attempted, ok, failed, duration_ms}` 并打日志。证据：`tests/unit/layer1_core/test_persistence_single_owner.py`（改动前 **12 failed，含 399,964 层栈溢出**；改动后 19 passed）+ 重写的 `test_persistence.py`（delegate 转发契约），见 `docs/engineering/2026-11-foundation-p1-evidence.md`；全仓 `pytest tests/unit tests/architecture` → 1120 passed。真机：`restart qb-core` + 逐个 `ensure` 拉回被连带停掉的资源后，日志出现 `single owner store loaded` / `delegate loaded (owner=qb-core: resolved)`，无 SCRIPT ERROR。

- **P1-5 阶段 F：qb-drugs 配送押金/报酬改服务端权威（可刷钱漏洞）**（2026-11-07）：
  - 漏洞：`acceptDelivery` 与 `successDelivery` 直接采信客户端 `deliveryData` 的
    `deposit` / `basePayout` / `amount` / `fastTime`。实测一个改过的包：不交押金拿到 999 个货；
    结算时把 `deposit` 说成 1e9 → `AddMoney(finalReward + deposit)` 一次进账 **2,200,000,000**；
    同一次结算还能重放。
  - 修法：接单时按 Config 反算押金/报酬/时间窗口并存档（`activeDeliveries[src]`），数量固定 1；
    结算只认这份存档（先消费再结算，防重放），`elapsed` 用服务端计时；背包里没有货就不发钱；
    商品 key 必须在 `Config.DeliveryItems` 里。
  - 新增 `test_drugs_delivery_authority.py`：mock 运行时真的触发两个 net event，断言
    「押金 500 / 发货 1 个 / 结算 1500 / 重放 0 / 伪造 key 0 / 缺货 0」。对照旧实现实测为
    「押金 0 / 发货 999 / 结算 2.2e9 / 重放再发一次」。
  - CC 复核后又补两个洞：**连开两单会覆盖记录**（押金白扣、货白留，实测净赚 500/轮）→ 接单时拒绝
    已有活跃单；**断线后 source 被复用**会让新角色结算旧单 → 记录绑定 citizenid + playerDropped 清理。
  - 测试探针本身也修了：SetTimeout 原来是 no-op，accept 的排他锁永远不释放，导致「伪造 key /
    缺货不发钱」两条断言其实是空过（CC 抓到）；现在用真的定时器队列 + tick(ms) 推进时间。
  - 连带：这两个事件现在被闸门识别为「已鉴权」，net event 基线 qb 未登记 197 → 195。
- **P1-3 批 7：qb-storerobbery 9 + qb-crypto 6**（2026-11-08）：
  - **CC 九轮复核查出的后续**（都属于「任意玩家 vs 正在店里的人」这类边界，逐条收口）：
    ① `Rebooting` 改成**服务端会话**：只有真的扣掉一根 cryptostick 的 `ExchangeFail` 能建会话，
    进度上报只认 owner，60 秒静默 + 5 分钟硬上限；② `callCops`/`setSafeStatus` 要绑定「本人
    正在/刚抢过这家店」（`recentStoreRobberies` 10 分钟窗口，按 citizenid）；③ 掉线清理补
    `srcToCitizenid` 反查表；④ 兑换回补失败挂到 `metadata.cryptostick_refunds`，上线自动补发；
    ⑤ **客户端** `SyncReboot`/`GetRebootState` 改为按服务端 payload 落地 —— 原来无条件当成
    「开始重启」，导致 owner 收尾/超时/掉线的「停止」广播在别的客户端眼里变成「开始」，
    别人会一直显示假重启约 2 分钟。

  - **白拿钱**：`qb-crypto:server:ExchangeSuccess` 忽略 `RemoveItem` 的返回值 —— 兑换时如果
    扣不掉 cryptostick，`AddMoney` 照样执行（探针实测旧代码在扣货失败时仍入账一次）。
    现在 `RemoveItem == false` 直接返回。
  - **伪造警情**：`qb-storerobbery:server:callCops` 的店名与坐标全来自客户端 —— 任意玩家能凭空
    给全服推一条「某店正在被抢」，坐标任意；坏 key 还会 `attempt to index a nil value`。
    现在只认 Config 里真实存在的收银机/保险箱，坐标取服务端配置。
  - **锁死全服保险箱**：`setSafeStatus` 原来任何玩家调一次就能把任意保险箱标成「已抢」
    （40~80 分钟不可用）。现在要求调用者本人站在该保险箱交互距离内。
  - **伪造交易所重启**：`Rebooting(state, percentage)` 原来把客户端值原样写进全服共享状态
    （实测 `'hax'` 与 `150%` 都能写进去）→ 只接受已知 state + 0~100 进度 + 1 秒节流。
  - 其余：`FetchWorth`（每币一条 SQL）加 5 秒冷却防放大；`syncMinPolice`/`SyncReboot` 广播加节流；
    两个开锁器事件先确认本人真的持有再扣。
  - 数字：两个资源 15 → 0；全仓未登记 **192 → 177**、qb **110 → 95**、allowlist **97 → 112**。
  - 运行级测试：`T-CityLite.base/tests/unit/layer3_business/fixtures/storerobbery_probe.lua`、
    `T-CityLite.base/tests/unit/layer3_business/fixtures/crypto_probe.lua`，2 条 pytest；
    旧实现实测全红（客户端坐标被转发、远处锁保险箱、扣货失败照样发钱）。
- **P1-3 批 6：qb-lapraces 10 + qb-apartments 10**（2026-11-08）：
  - **连带修掉的真 bug**（CC 六轮验收逐条揪出来的，都属于「能玩」级别）：
    ① `CreateApartment` 形参叫 `type` 遮蔽全局 `type()` → 事件一触发就崩、公寓建不出来；
    ② 用 `racer.Finished` 当防重放标记，而客户端完赛前会先把它置 true → **每次正常完赛都不结算**；
    ③ `table.remove(AvailableRaces, nil)` 会删掉**另一场**正在开放的比赛；
    ④ 最佳圈校验写成 `BestLap / TotalLaps` → 10 圈赛里合法的 45 秒最佳圈被算成 4.5 秒并被改写；
    ⑤ `BestLap <= TotalTime` 太松（45 秒最佳圈 > 20 秒平均圈也能过）→ 改为 `<= 平均圈速`；
    ⑥ 没开赛就能报成绩（`StartedAt == nil` 时整套校验被跳过）；
    ⑦ 结算/离开后的清理只清一半 → `LastLeaderboard` / `NotFinished` / `LastRaces` / `StartedAt`
       跨场残留，赛道可能永久卡在「运行中」。
  - 运行级测试：`T-CityLite.base/tests/unit/layer3_business/fixtures/lapraces_probe.lua`（9 个场景，用 `debug.getupvalue` 直接读 handler
    闭包里的私有表断言清理结果）、`T-CityLite.base/tests/unit/layer3_business/fixtures/apartments_probe.lua`，共 2 条 pytest。

  - **公寓储物柜没有归属判定**：`apartments:server:openStash(apartmentId)` 传个 id 就
    `OpenInventory` 到别人家柜子 → 只认 `apartments` 表里登记在册的房主；
    `OpenDoor(target, …)` 同样改为房主才能把访客放进来。
  - **比赛状态零校验**：`UpdateRaceState` 原来四条赋值没有任何判断 —— 任何玩家改包就能把
    任意比赛开起来/停掉；`UpdateRacerData` / `FinishPlayer` 的 `RaceId` 坏值直接 nil 索引崩服务端；
    `FinishPlayer` 还能让参赛者随便报 `BestLap` 刷赛道纪录。现在全部要求「是这场比赛的在册车手」
    + 成绩必须是合理数字（`BestLap ≤ TotalTime`）。
  - **建房/建赛道没有授权一致性**：`SaveRace` 原来任何玩家都能凭空写一条赛道到 DB（无限写），
    改为与 `CreateLapRace` 同一白名单；`CancelRace` / `StartRace` 收敛到 `IsRaceHost` helper。
  - **真 bug**：`SaveRace` 里 `GenerateRaceId()` 调了两次 —— 内存里的赛道 id 与写进 DB 的 id 不一致，
    重启后赛道记录对不上。现在只生成一次。
  - qb-apartments 其余事件（`SetInsideMeta` / `RingDoor` / `AddObject` / `RemoveObject` / 建改公寓）
    补齐类型与存在性判断：这些 key 全来自客户端，坏值原来会让服务端抛 `attempt to index a nil value`。
  - 数字：qb-lapraces 10 → 0、qb-apartments 10 → 0；全仓未登记 **212 → 192**、qb **130 → 110**、
    allowlist **92 → 97**。
- **P1-3 批 5：qb-houses 19 个事件（入室盗窃链）**（2026-11-08）：
  - **任何玩家能打开别人家的储物柜**：`openStash(house)` 只查 `Config.Houses[house]` 是否存在，
    没有任何钥匙判定 —— 传个房子名就 `OpenInventory` 到人家的 stash 上，物品直接拿走。
    现在必须 `hasKey(license, citizenid, house)`（房主或持有人）。
  - **入室链**：`OpenDoor(target, house)` 能把**任意玩家**传进任意房子；`lockHouse` 能上/开别人家的锁；
    `setLocation` 能挪走别人家的储物柜/衣柜坐标；`savedecorations` 能改别人家装修。
    四条现在分别要求 hasKey / isHouseOwner。
  - **任何玩家能建房**：`addNewHouse`（任意价位）、`addGarage`、`createBlip`（全服广播）无管理员判定 →
    加 `QBCore.Functions.HasPermission(src, 'admin')`。
  - `SetRamState` / `SetHouseRammed` 是警察行为 → 要求在职 `police`；`buyHouse` / `viewHouse` /
    `RingDoor` 缺查表（坏 house 名会让服务端崩）→ 先查 `Config.Houses`。
  - `LogoutLocation` 会落盘 + `Player.Logout`，客户端连点会反复触发存档 → 加 citizenid 维度 10 秒冷却。
  - 闸门：`hasKey` / `isHouseOwner` 登记进 `net_event_guard_helpers.json`（含 defined_at 与函数体证据），
    每条调用点由闸门验证「在 `if not H(...)` 的否定分支里且真的 return」。
  - 数字：qb-houses 19 → 0；全仓未登记 **231 → 212**、qb **149 → 130**、allowlist **91 → 92**。
- **P1-3 批 4：qb-drugs 角落贩售 / qb-prison / qb-weapons 共 20 个事件**（2026-11-08）：
  - **印钱**：`updateDealerItems` 忽略 `RemoveItem` 的返回值 —— 库存打空时调一次
    `{slot=1}, 999, 'Sandy Dealer'` 就 `AddMoney(999×15)`（实测旧代码 PAID=14985，背包一件没有）；
    坏 slot 还会 `attempt to index a nil value` 崩服务端。现在 dealer/slot/name 逐个校验，
    先扣货、`RemoveItem` 返回 false 就不发钱。
  - **武器复制**：`TakeBackWeapon(k)` 不校验归属与修理状态 —— 任意玩家对任意 k 都能取回，
    送修者修好后再取一把（实测旧代码 ADDED 1→2→3）。现在要求 `CitizenId` 对得上、`Ready == true`，
    取走即清记录。
  - **无限弹药**：`UpdateWeaponAmmo` 把客户端 `amount` 原样写入（实测 999999 / -5 都写进去），
    且不比对武器名。现在夹到 0~9999、必须整数、槽位与名字都要对。
  - **监狱**：`SecurityLockdown` / `SetGateHit` 原来任意玩家调一次就能锁死全监狱 / 刷破门广播；
    `JailAlarm` 无冷却可连点刷警报。三个都补了（狱警/在押者限定 + 60 秒冷却）。
  - **角落贩售**：`giveStealItems` 只比对 item/amount，任何玩家都能领走别人被抢的货 →
    记录里存 src 并要求一致；`availableDrugs[drugType]` 用物品名索引数组恒为 nil（rob 路径直接抛错）→
    改按名字查表；`sendDeliverySMS` 的文案改为非空字符串 + 300 字截断。
  - 数字：全仓未登记 **253 → 231**、qb **171 → 149**、allowlist **64 → 91**；
    新增两组 Lua 沙箱探针（dealer 卖货 / 武器取回），旧实现实测全红。
- **P1-3 批 3：qb-vehicleshop 5 个事件（分期还款 / 全额结清 / 分期购车 / 代客售车）**（2026-11-08）：
  - **两个真漏洞**：①`financePaymentFull` 的 `vehBalance` / `vehPlate` 全来自客户端 —— 付 1 块钱就能把
    **别人**的分期记录 balance 清零（等于白送一台车）；②`financePayment` 的 `vehData` 同样是客户端给的，
    `UPDATE … WHERE plate = ?` 也能改到别人的车。现在余额/期数/每期额一律
    `SELECT … WHERE plate = ? AND citizenid = ?` 从 DB 取，UPDATE 也带 citizenid。
  - **代客售车没有店员校验**：任意玩家可把旁边路人的钱扣掉给对方买车、自己拿提成 ——
    `sellShowroomVehicle` / `sellfinanceVehicle` 现在要求 `job.name == 'cardealer'` 且 onduty。
  - 三处 `QBCore.Shared.Vehicles[vehicle].price` 直接索引（客户端传坏车名会让服务端崩）→ 先校验车型存在。
  - 数字：qb 未登记 **176 → 171**；全仓 **258 → 253**（allowlist 61 → 64，两个代售事件转 guarded）。
- **P1-3 批 2：qb-ambulancejob 7 个事件（复活/治疗/病床/药箱）**（2026-11-08）：
  - `RevivePlayer` / `TreatWounds` 原来把权限判断写成「if 是 EMS then 干活」，闸门不算鉴权；
    改成 deny-early：抽出 `CanRevive(Player, src)` helper（在职 EMS，或 firstaid + medical_cert），
    非授权直接审计 + return。登记进 `net_event_guard_helpers.json`。
  - `removeBandage` / `removeIfaks` / `removePainkillers` 只动 caller 自己的背包 → 登记 `self_scoped`。
  - `SendToBed` / `RespawnAtHospital` 是平民也要用的路径 → 登记 `civilian`，并补**索引校验**：
    `bedId` / `hospitalIndex` 全是客户端传的，原来直接索引 `Config.Locations['hospital'][idx]['beds'][bedId]`
    能让服务端崩；现在 tonumber + 查表命中失败即 return。
  - 顺带把变异冒烟的锚点从 `"guarded": NN`（每清一批就失效）改成 `"events": 440`（总数稳定）。
  - 数字：qb 未登记 **183 → 176**；全仓 **265 → 258**（allowlist 56 → 61）。
- **P1-3 批 1：qb-management 8 个老板菜单事件转「已鉴权」**（2026-11-08）：
  - 这 8 个事件（bossmenu 4：GradeUpdate / FireEmployee / HireEmployee / TransferOwnership；
    orgmenu 4：GradeUpdate / FireMember / HireMember / TransferOwnership）
    本来就有 isboss + 菜单点 5m 双重校验，只是闸门不认识内联的 `job.isboss`；
    现在抽出两个 helper（`IsJobBoss` / `IsPlayerBoss`）并登记进 `net_event_guard_helpers.json`，
    闸门按登记证据逐条验证（定义一次 + 函数体含 `isboss == true` + 调用点必须是 `if not ... then return`）。
  - 顺手补真洞：**招募可以隔着地图把人塞进职业/组织/帮派**（原来只校验 Boss 在菜单点，不看目标），
    三个 Hire 事件都要求目标也在 5m 内；sv_boss / sv_gang 缺 `if not Player then return end` 的
    handler 一并补上。
  - 顺带修掉一条**失效的闸门变异**：`tools/dev/gate_mutation_smoke.py` 里锚点 `"guarded": 19,` 随 P1-3
    清债早已不存在，这条变异一直在静默跳过（CC 复核发现）；改锚到当前 qb 批次的 guarded 数，
    现在 12/12 都是「注入红 / 对照绿」。
  - 数字：qb 未登记事件 **195 → 183**（合计 277 → 265）；qb-management guarded 8 → 12。
- **P1-5 阶段 G：掉线配送结算（押金不再白丢，也不白送一件货）**（2026-11-08）：
  - 之前：接单后掉线 = 押金没收、货留在背包（与“接了不做”等价，但玩家是意外掉线，体验上像被罚）。
  - 现在：`playerDropped` 把未结算的配送记到 citizenid 名下；玩家**重新上线**时结算 ——
    货还在就回收并全额退押金，货没了就不退（避免“退了押金又白拿货”）。
    不在离线阶段动背包：离线装卸 inventory 会和存档打架。
  - 新增用例：`test_drop_settlement_refunds_only_when_goods_are_recovered`
    （退 500 + 货清零 / 货没了退 0；qb-inventory 未就绪时保留 pending、下次上线补退），退回上一版实现时红。
  - CC 复核的非阻断项已采纳：结算改成「成功后才消费 pending」+ `pcall` 包住 `RemoveItem`
    + `RemoveItem` 未注入时打印并保留 pending（qb-inventory 热重启期间登录不会丢退款）。
  - 仍留一条：pending 无 TTL（玩家永不上线则常驻内存，条目很小；服务器重启会丢），
    需要落表或加过期，已记入计划遗留。
- **P1-5 阶段 E：金额 `$%d` A 档 26 处偿还（93 → 68）**（2026-11-07）：
  - 按 CC 的分诊口径（A 真风险 / B 假风险 / C 待定），只修 A 档：实参可能是小数的那些。
    A 档分布：qb-drugs 8、custom-cartel 9、custom-crime 3、custom-security 2、custom-main 2、
    custom-market 2（余额与管理员改价），共 26 处字面量。
  - 每个资源自带一份 shared 目录下的 money_format 模块（函数名 `Money`），不跨资源引用 —— 避免新增加载顺序依赖。
    语义：整数不带小数点（$500）、小数两位（$61.75）、非数字回落 `0`。
  - B 档 21 处（整数常量 / `math.floor` / DB 整数列）留在基线里，`$comment` 已注明是假阳性；
    C 档 46 处多为 `production-freeze` 的 locale 模板串，不参与 `format`。
  - 新增 `test_money_renderers.py`：8 个渲染器 × 8 组输入（0.5 / 61.75 / 负数 / 字符串 / nil / 非数字），
    防止某个资源的 `Money()` 把整数渲染成 `500.00` 或对 nil 抛错。
- **P1-6 阶段 C：17 条 server 风险清零 + 同步重解析改成线程重试**（2026-11-07）：
  - 17 个 `[qb]` 资源补 `onResourceStart('qb-core')` 重解析；其中 qb-doorlock / qb-garages / qb-weed
    原本的处理器只认**自己**启动，另挂专用处理器。基线 server 17 → **0**。
  - ⚠️ 关键订正：PR #196 那种**事件里同步**调 `exports['qb-core']:GetCoreObject()` 不可靠 ——
    再跑一次真机复现 `qb-clothing/server/main.lua:9 … Execution of function reference in script
    host failed`（事件触发时本资源持有的 export 引用仍指向旧 script host）。改成 `CreateThread`
    里 `pcall` 重试（最多 30 次 × 500ms），复验 0 SCRIPT ERROR。
  - 扫描器的重挂判定接受两种安全写法（直接赋值 / 线程重试后 `QBCore = core`），但仍要求给同一
    变量赋值且附近有 `GetCoreObject`。
- **P1-6：`restart qb-core` 后的「失效函数引用」+ 审计留存**（2026-11-07）：
  - 真机 `qb-clothing` 报 `Execution of function reference in script host failed` —— 这是第三类跨资源引用问题：
    文件顶层 `local QBCore = exports['qb-core']:GetCoreObject()` 拿的是**当次 script host 的快照**，
    qb-core 重启后表里的函数引用全部失效。与「MySQL 回调里调引用」（PR #193/#194）不是一回事。
  - 修 qb-clothing（加 `onResourceStart` 重解析）与 custom-security（原重挂只复位标记、**没重解析 QBCore**，
    守卫会挂到旧表上）。新增闸门 `test_no_stale_core_cache.py`：四条件判定 + server 17 条基线棘轮
  （另 19 个 client 文件记 `client_unverified`，跨客户端语义未验证，不进棘轮但新增判红）。
  判重挂是结构化匹配：`RegisterNetEvent` 冒充、注释里的假重挂、给别的变量赋值都不算自愈。
  - 审计留存：按天分片 + 保留 30 天（`custom_logs_retention_days`）+ 单文件 10MB 滚动 + 单日 20 片封顶，
    启动宽扫 10 年清积压、每小时窄扫；**删除只看 retention**（第一版写错过，把 5 天前的文件删了，被测试抓住）。
  - 真机：`restart qb-core` + resync + 客户端加载 → 0 SCRIPT ERROR；`🧹 启动清理：删除 1 个过期审计分片`。
- **P1-5 阶段 B/C/D：金额格式化偿还 + 审计桥接 + 重启 SOP**（2026-11-07）：
  - **B**：`custom-taxes` / `custom-phone` / `T-CityLite.base/resources/[custom]/custom-quest` 各加一份资源内的 money_format 共享脚本
    （TCMoney / PhoneMoney / QuestMoney 三个函数，语义一致：整数不带小数点、小数两位），
    把税（比例计算）、转账、乘算奖励这些**必然带小数**的金额从 `$%d` 改成 `$%s`；
    金额格式化基线 **120 → 93**（`qb-drugs` / `custom-cartel` 仍留在基线里作为债）。
  - **C**：`custom-logs` 新增 `qb-log:server:CreateLog` 桥接 —— 全仓 47 处发送点此前**零消费者**
    （唯一监听者在 `archive/`，不启动），经济/反作弊/进出服审计全部丢失。桥接用
    `AddEventHandler`（不是 `RegisterNetEvent`，防客户端伪造），按 `playermoney`/`anticheat` 分流到
    已有的 `LogEconomy`/`LogSecurity`/`LogGeneric`；落盘前过 `SanitizeLogText`
    （citizenid 掩码、license/ip/discord/steam 打码、控制字符清掉、截断 500）。
  - **D**：`tools/dev/resync_modules.ps1`（RCON 包装，`-DryRun` 打印 17 条 `exec`，跑完核对资源数 85）
    + `docs/engineering/2026-11-restart-sop.md`（`restart qb-core` 会停 44 个依赖资源的 SOP）。
- **P1-4 阶段 D：compat.lua 整份下线**（core-framework）：删掉 `QBCore.Functions.Notify` 的包装、
  fxmanifest 去掉该行、文件删除，猴补登记表 5 → 4 条。删除而不是「改 export + GetResourceState 守卫」的理由：
  export 到已停止的资源一样失败（只是换了个报错位置），且会多出第二个 Notify 入口；而这一层还静默改变语义
  —— notify_service 每源 200ms 只放 1 条、超限直接丢、没有丢弃计数，qb-core 原实现不丢消息。
  新增 `tests/architecture/test_compat_notify_removed.py`：文件已删 / manifest 不再引用 / 没有 `_G.Bus` 时
  qb-core 的 Notify 仍把 `QBCore:Notify` 发出去（qb-core 从未注册 `Bus.notify`，恒走第 5 层回退）。
  三条各配变异，「注入红、对照绿」实测通过。阶段 B/C 的两个包装级单元测试随文件退休。
- **P1-4 阶段 C：删掉 `Player.Functions.AddMoney` 的包装（纯删除，一行不修）**（core-framework）：
  这段包装今天本来就是死代码 —— `_G` 不跨资源，core-framework 里 `_G.Bus.EconomyService` 恒 nil，
  ES 分支整段跳过、永远回落。但"死"不等于"无害"：它每 10 分钟把 Notify 与 AddMoney 的计数混在一起打印
  （运维会以为加钱走了新路径），而且它的形参是 `self` 而全仓 60 处调用点是 3 参 dot 调用 —— 一旦有人
  "顺手修好"ES 可见性，`self = 'cash'`，每个加钱点直接 SCRIPT ERROR；修好传参而不改签名则是
  pcall 回落 + 原函数各调一次 ES = **双倍加钱**。所以只删不修。新增单元测试断言 PlayerLoaded 之后
  `Player.Functions.AddMoney` 仍是玩家自己那个函数、调用确实落在它上面；换回旧实现 1 红。登记表 6 → 5 条。
- **P1-4 阶段 B：删掉 `QBCore.Functions.GetPlayer` 的缓存猴补**（core-framework）：qb-core 的
  `GetPlayer` 本来就是一次表查，compat 外面套的 `playerCache` + `GetPlayerName` 活性校验有三个问题：
  命中时多一次 native 调用；**登出时不清缓存**（`QBCore.Player.Logout` → `OnPlayerUnload` → 200ms 后才置 nil，
  compat 没监听该事件）→ 停在选人界面的玩家会拿到**已登出**的 Player 表，`if not Player then return end`
  全线失效；本资源重启后旧 funcref 留在 qb-core 表里形成叠层。新增单元测试断言：函数**本身**仍是 qb-core
  那一个（不是返回值相等）、`Players[src]` 清空后返回 nil、字符串 source 不抛错（旧实现的 `source <= 0`
  会 attempt to compare string with number）。换回旧实现该用例 1 红 1 绿；闸门登记表 7 → 6 条。
- **P1-4 阶段 A：猴补闸门落地（冻结新增，存量 7 条带到期日）**（架构闸门）：`core-framework` 的
  compat 一直在往 `QBCore.Functions` 上赋值（`GetPlayer` / `Notify` / `AddMoney`），这类改动在 diff 里
  看不出来——调用点一行没变。新增唯一扫描器 `monkey_patch_scan.py` + 闸门 `test_no_monkey_patch.py`：
  覆盖四种赋值形态（`function X.Y(`、`X.Y =`、`X["Y"] =` 单双引号、裸 `QBCore.X =`），排除 qb-core
  （API owner）与 tests；登记表要求 owner + expires，**死条目**（登记了却一处都不命中）同样判红。
  实测存量 8 处命中 / 7 个 (file,symbol)：core-framework 三条、custom-vehicles 的 `OnGiveKeys`（兼容层）、
  production-freeze 的 Debug/ShowError/ShowSuccess（dev-only 工具）。两条边界写进扫描器：
  `_G.Bus.X =` 是总线注册不算猴补，客户端文件里的裸 `QBCore.X =` 是玩家数据快照不算。
  三条变异用例（新增未登记猴补 / 登记过期 / 死条目）全部"注入红、对照绿"。
- **[custom] net event 覆盖率 85.7% → 90.2%（第 5 批）**：133 个 `[custom]` 事件里 120 个已鉴权或已登记。
  真修两处：① `qb-mechanicjob:server:updateDrivingDistance`（旧兼容事件）**完全没有校验** ——
  任何客户端可以给任意车牌刷里程；现在先过 `CanModifyPlate`。② 中控屏锁表原来用**原始**车牌作键
  （" abc123 " 与 "ABC123" 能拿到两把锁），统一 `NormalizePlate` 并抽出 `HoldsDashboardLock`。
  另把物流交单的"有具体物流任务"抽成 `FindLogisticsQuest`（只认 euro_trucking_* / aviation_smuggling_flight
  三个模板），三条自作用域事件（`releaseDashboard`、`RemoveKeys`、`ToggleEngine`）按真实语义登记。
  统计口径：440 事件 / 105 已鉴权 / 56 已登记 / 279 未登记 / 53 个债资源。
- **[custom] net event 覆盖率 80.5% → 85.7%（第 4 批）**：133 个 `[custom]` 事件里 114 个已鉴权或已登记。
  这批补的是"归属/前置条件住在别处"的三类：`custom-agent-client` 的 `ClaimPending`
  （ack 的 rid 必须在**自己的** pending 表里且 session 令牌一致）、`custom-justice` 的
  `JusticeService.GetOwnInmate`（只吃调用者自己的 Player 对象——探视请求判的是**目标**，因此单列 civilian 不计入）、以及 `job_deny_guard` 支持
  "先取职业名再比较"（`local callerJob = Caller.PlayerData.job.name`）这种别名写法 —— 直接拿下
  `justice:server:imprison`（原来只判了 caller job 但扫描器看不见）与 `qb-mechanicjob:server:stash`。
  `custom-agent-client` 的 `ready` / `state` / `devcmd_result` 按真实语义登记（自作用域 / 遥测），
  并给 `devcmd_result` 补了每源 500ms 节流与长度上限（原来任何客户端都能刷服务端日志）。
  统计口径：440 事件 / 102 已鉴权 / 53 已登记 / 285 未登记 / 54 个债资源。
- **[custom] net event 覆盖率 64% → 80.5%，P1-3 的 ② 达成（第 3 批）**：133 个 `[custom]` 事件里
  107 个已鉴权或已登记。这一批把"校验住在别处的"四类都做了可验证登记：警情分发器
  （`PoliceDispatch.ArriveIncident` / `.ClaimIncident`、`NPC.SubmitResult`：能力位判定在被调函数体内）、
  导出函数（`AdoptDraft` / `ListDrafts`：能力位 + 审计）、任务安全层
  （`QuestSecurity.ValidateClientEvent`：nonce + 限频 + 步骤顺序 + 尝试次数）、帮派成员
  （`CartelService.IsMember`）。登记表新增 `shape`（`local_check` / `pcall` / `export` / `delegate`），
  每种形状都要求"返回值真的被判定"而不是"名字出现过"。同时加了一个 token `job_deny`
  （形如 `if xjob.name ~= '…' then … return end` 的职业白名单判定，与 `HasPermission` 同级）。
  真修四处：① `quest:server:placementComplete` / `trailerHitched` 原来只查状态不查任务归属，
  任何人可对任意 questId 上报"放好了/挂上了"，现在先过任务安全层；② `custom-cartel` 的 NPC 回调
  取了 `IsMember` 却没用，非成员也能拿到 NPC 列表；③ `custom-vehicles` 的 `GiveKeys` 与
  `AcquireVehicleKeys` 各写了一遍认领校验且宽严不一 —— 收敛成 `CanClaimPlate`（会话车主 /
  数据库车主 / 车旁三档），顺手给 `GiveKeys` 补上了它没有的数据库车主校验。另删除
  `quest:server:entityRecycled` 这个注册成 NetEvent 但函数体为空的死 handler。
- **net event 覆盖率 48% → 64%，并补上"资源自己的校验也算数"的登记表（P1-3 第 2 步）**：
  `[custom]` 从 64/134 提到 **86/134**。做法不是放宽 token 名单，而是新增
  `tests/architecture/net_event_guard_helpers.json` 登记**资源内部**的鉴权 helper
  （`CanModifyPlate` / `IsEmergencyService` / `IsSeatedIn` / `IsSeatedInPlate` / `onDutyOfficer`）：
  每个 helper 必须定义唯一、函数体含约定证据（剥注释后比对）、资源内**每一处**调用都走
  `if not H(...) then return`，登记了却没有调用点也算红。顺带修了三处真问题：
  ① `custom-vehicles:server:logisticsQuickLoad` 原来只有限频、没有"有活才能装货"，任何玩家能推任务进度；
  ② `dashboard_api` 的职业判断在三个事件里重复且两个事件压根没有 —— 抽出 `IsEmergencyService`，
     给 `policeRadarLog`（伪造超速记录）和 `anchorControl` 补上；
  ③ 中控屏锁 `requestDashboard` 能被不在车内的人抢走（远程占位），改为必须坐在该车牌车内；
     氮气火焰广播只允许车内的人触发。基线总计 441 事件 / 63 已鉴权 / 61 已登记 / 317 未登记，
  11 条变异用例全部"注入红 / 对照绿"。
  验收方（CC）第一轮抓出两个 P0 并已修：① 抽 `IsEmergencyService` 时连 `local job` 一起删掉，
  PA 喊话穿过鉴权后必抛 `job` 为 nil —— 运行时才炸；② `[system]/tcity-dashboard` 里另有一份
  同名 `logisticsQuickLoad` 的无守卫 handler（net event 按名字全局派发），把刚补的守卫整个旁路，
  已删除副本并加注释说明为什么不能有第二份。登记表的门槛同时收紧：证据比对限定在**函数体**、
  调用点必须"否定分支里真的 return"（`if not H(x) then end` 不算）、`if false` 死代码不算、
  同名 helper 以登记表的严格形状为准（此前 `extra` 覆盖会把严格模式降级成宽松词匹配）。
- **net event 治理落地基线，引擎层覆盖到 100%（P1-3 第 1 步）**（qb-core / 架构闸门）：`QBCore:Server:TriggerClientCallback` 以前**任何客户端都能 resolve 任意待决的客户端回调**（回调只按名字索引，没有归属），伪造返回值会直接进服务端逻辑；现在建回调时记 `source`、handler 校验 `pending.source ~= src`，顺带修掉"回答后条目被清空、`Citizen.Await` 恢复时索引 nil"的潜伏错误。新增唯一扫描器 `net_event_scan.py`（闸门与基线生成器共用，支持内联与 `RegisterNetEvent` + `AddEventHandler` 两种写法），把全仓 **442 个服务端 net event** 固化成 `T-CityLite.base/tests/architecture/net_events_baseline.json`：引擎层 qb-core 15/15（5 已鉴权 + 10 按真实语义登记），`[custom]` 64/134、`[qb]` 16/216、其它 7/77；58 个还有欠账的资源各有 owner + expires 的债（其中 15 个不在启动集，占 93/340），新增未鉴权事件、变量名注册、解析失败、过期债、手改数字全部会红（10 条变异用例证明"注入红/对照绿"）。三个新登记类别都带可检查承诺（`self_scoped` 必须有 `local src = source` 且不索引别的玩家、`callback_relay` 必须走 `ServerCallbacks[name]` 且高危目标有守卫、`deprecated_blocked` 必须写安全日志、且不含列出的写 API（AddItem/RemoveItem/AddMoney/RemoveMoney/SetMetaData/SetJob/SetJobDuty/SetGang/SetMoney、任何 `MySQL.*`、`exports[...]:Set*`））。`[custom]` 覆盖率 48%，距计划里的 80% 还差 44 个事件，记在 `docs/engineering/2026-11-foundation-net-events-baseline.md`。
- **`tools/dev/gate_mutation_smoke.py` 撤注入后清理新建的空目录**：变异用例把文件写进不存在的资源目录时，`unlink` 只删文件，空目录会让 `test_no_orphan_scripts`（每个 `[custom]` 目录必须有 fxmanifest）误红。

### Fixed

- **P2-3：迁移版本号唯一 + 可重复执行**（2026-11-08）：`migrations/` 下有 **4 组重号**
  （v0.7 ×2、v2.2 ×2、v3.11 ×2、v3.12 ×2）。重号不会让 `local_stack.sh` 崩（它用 `ls | sort -V`），
  但把「谁先跑」变成了文件名字母序的意外结果，同一个版本号下两条迁移互相看不见。给每组里引用较少的
  那个加二级号并同步 8 处引用：`v0.7_story_engine` → `v0.7.1_story_engine`、`v2.2_schema_reconcile` →
  `v2.2.3_schema_reconcile`、`v3.11_police_case_verdict` → `v3.11.1_police_case_verdict`、
  `v3.12_police_incident_ref` → `v3.12.1_police_incident_ref`（docs / 测试 / e2e README 一并更新）。
  幂等这边修了一处真缺陷：`v2.1_perf_indexes.sql` 原来裸 `ALTER TABLE players ADD COLUMN phone_number
  … VIRTUAL` + `CREATE INDEX`，**第二次执行必然** `ERROR 1060 Duplicate column name 'phone_number'`
  → 四步都改成先查 `information_schema` 再 `PREPARE/EXECUTE`（沿用 v3.11/v3.12 的形状）。
  新增闸门 `tests/architecture/test_migration_versions.py`：版本号前缀唯一（零基线零豁免）+ 文件名
  必须是 `v<version>_<snake>.sql`，配 3 条反向形状（重号树 / 坏名字树 / 干净树）与 2 条
  `gate_mutation_smoke` 变异用例（注入重号文件、注入坏文件名），实测「注入后红、对照绿」；
  `gate_coverage` 未证明数仍 276。幂等性用 `tools/dev/migrations_double_apply.py` 在真库上验证：
  先铺基线 schema（并删掉 dump 里已带的 `phone_number` / `idx_players_phone`，否则 v2.1 的 DDL 分支
  只会走 `DO 0`，等于没验），再把 35 个迁移连跑两遍 —— **35/35 × 2 遍无错误**。
  另按 CC 复核修了两处：① `v2.1_perf_indexes.sql` 的 PREPARE 串里引号层数写错（`"''$.phone''"`
  会被解析成带引号的 `'$.phone'`，MySQL 报 3143 非法 JSON path）→ 去掉双引号；用**不含**该列的最小
  schema 实测：ALTER + 3 条 CREATE INDEX 真的执行、插入后 `phone_number` 取值正确、第二遍幂等
  ② 5 个迁移文件里 8 处注释/Run 指令仍指旧文件名。`tests/integration/` 里有同名
  用例复用该工具（没有 docker / 容器时 skip，静态闸门在 CI 里始终生效）。

- **P1-5 二期：金额写路径收敛（拒绝语义）**（2026-11-08）：`SecurityService` 里新增
  `ValidateAmount(amount, opts)` 作为金额入参的**唯一**实现（非数字 / NaN / inf / 负数 / 0 / 超过
  `MONEY_MAX_SINGLE_TRANSACTION` 一律拒绝，**不 clamp**），`ValidateMoneyEvent` 的金额四步也收敛到它。
  三个写入口全部接上：`EconomyService.AddMoney` / `RemoveMoney` / `SetMoney`，以及 qb-core 的
  player.lua 里 offline 与 `Bus.EconomyService` 缺失时的 fallback 共 6 条分支 —— 之前**同一个非法输入
  在不同路径得到不同答复**：`AddMoney` 接受 NaN（钱写成 NaN）、接受 inf、接受 5,000,001；`RemoveMoney`
  接受 NaN；fallback 分支这些全放行；只有 `SetMoney` 有阈值熔断。探针对 master 实测
  `ECONOMY_AddMoney_NAN|accept` / `_INF|accept` / `_OVER|accept` / `ECONOMY_RemoveMoney_NAN|accept`，
  新版全 `reject`，而 `999999`（低于阈值）与 `SetMoney(0)`（清空）仍放行 —— 全拒的实现过不了这几条。
  新增闸门 `tests/architecture/test_money_write_path.py`（3 条判据：money 表只许收敛层写、阈值只定义
  一次、三个入口都调 `ValidateAmount`；4 条反向形状 + 注释/字符串不算命中），并给 `tools/dev/gate_mutation_smoke.py`
  加 3 条变异用例（注入跨资源写表 / 第二份阈值定义 / 摘掉校验），三条实测「注入后红、对照绿」；
  `gate_coverage` 未证明数仍为 276。`money_format_baseline.json` 因删掉一行 `$%d` 的 SECURITY 日志
  同步重生成（债 68 → 67）。真机（0 玩家在线）：`start qb-core` 后 `[SecurityService] ✅ Registered` →
  `[EconomyService] Registered` 顺序正确、无 assert 失败，`resync_modules.ps1` 补回连带资源后 89 个资源
  0 `SCRIPT ERROR`。CC 复核的两个跟踪项也一并处理：① `player.lua` / `economy_service.lua` 里原来的
  `assert(_G.Bus.SecurityService)` 改成「告警 + `ValidateAmount` 全拒绝桩」—— assert 会让整个
  player.lua（`QBCore.Player` 全部定义）加载失败，故障面远大于经济模块；② `qb-cityhall` 的
  `RemoveMoney('cash', itemInfo.cost)` 加 `cost > 0` 守卫（cost 为 0 是合法的免费项目，
  收紧后 `RemoveMoney(0)` 返回 false 会把它卡成"钱不够"）。1322 passed / 147 skipped。

- **P1-3 批 20：qb-weed 5 + qb-streetraces 3 —— `[qb]` 归零**（2026-11-08）：qb-weed 先修了一个
  "这个资源根本跑不起来"的 bug —— `local plantCache = {}` 声明在文件**末尾**（第 126 行），而
  `placePlant` / `removeDeathPlant` / `harvestPlant` / `foodPlant` 四个 handler 都在它之前，引用的是
  全局 `plantCache`（nil）。对 master 版本跑探针，五个崩溃点：`server/main.lua:43/49/68/97` 的
  `attempt to index a nil value (global 'plantCache')` 与 `:63` 的 `attempt to index a nil value
  (local 'Player')` —— **"种一株植物"每次都会抛错**（行写进 DB 了，缓存行抛错、后续刷新不执行）。
  把表挪到所有 handler 之前，并删掉末尾那份会把作用域再遮蔽一次的重复声明。在此之上补校验：
  `placePlant` 原来**连 Player 都没取**（任何客户端都能往 house_plants 塞任意行）→ 要求 Player +
  house 非空 + sort 在 `QBWeed.Plants` 白名单 + coords 能解出地图内 x/y/z + 单屋 20 株上限；
  `removeDeathPlant` 只能铲缓存里且 building 对得上的植株；`harvestPlant` 的 `amount`（只用来发种子）
  夹成 1..6、`plantName` 走白名单；`foodPlant` 的 `plantName` 走白名单（原来
  `QBWeed.Plants[plantName]['label']` 遇到坏名字直接 nil 索引崩线程）。CC 复核又抓到一条**我自己引入的
  P0**：`house_plants.plantid` 是 varchar(50)，DB 回来与客户端回传的都是**字符串**，而 `placePlant` 用
  `math.random` 的**数字**当缓存键 —— 于是「本次会话种下的植株」在 `removeDeathPlant` / `harvestPlant`
  里按字符串查必然 miss（死株铲不掉），收获时 `plantCache[plantId] = nil` 也只清字符串键、数字键条目
  变成幽灵继续占着单屋 20 株上限。修法：缓存键统一 `tostring`（含启动加载），并补「刚种下 → 收获 → 铲除」
  的探针用例。qb-streetraces 三条**本来就是**
  服务端权威（stake 夹在 Config 区间、奖池按参赛人数重建、先销毁赛局再发钱、禁重复报名），本轮把
  `RaceId` 规范成数字并登记，不改玩法。⚠️ 两个资源都不在启动集里，所以只有 `luac5.4 -p` + 探针，
  **没有真机验证**。数字：未登记 **67 → 59**，**`[qb]` 216/216 与 `[custom]` 133/133 全部归零**；
  allowlist 181。

- **P1-3 批 19：qb-shops 5 条 + 修复批 17 的登记回退**（2026-11-08）：
  `qb-shops:server:PaySlip(drops)` **全仓没有任何客户端调用点**（deliveries.lua 只发 RestockShopItems /
  DoBail），却按客户端给的 `drops` 直接 `AddMoney('bank', Config.DeliveryPrice * drops)` —— 站在交货点发
  `PaySlip(99999)` 就是 500 × 99999 的印钞机（探针实测旧版 `PAYSLIP_CLIENT_BLOCKED=false`）→ 改成只认
  服务端来源。`RestockShopItems(shop)` 的 `deliveryPay` 有 10 米距离校验，但没有冷却也没有次数概念：
  站在交货点循环发就能一遍遍拿 500 + 10% 概率的 `cryptostick`（旧版 `RESTOCK_COOLDOWN_BLOCKED=false`）
  → 加 30 秒冷却（**键是「玩家 + 店」**：只按玩家计会吞掉同一玩家跑下一家店的工资，而路线里相邻两家的
  交货点可能只隔 47 米），距离校验改成显式的 `nearCoords` helper（`deliveryPay` 内部那次是"不付钱就
  return"，闸门认不出是守卫）。`UpdateShopItems(shop, itemData, amount)` 的 slot/amount 全客户端给：坏 slot 抛
  `attempt to index a nil value`，负数 amount 会把库存**加上去**（白拿货）→ slot 必须命中该店商品、
  amount 正数并夹到 1000。`openShop(data)` 的 `data` 为 nil 时抛错、且能在任意位置开任意店 →
  类型校验 + 与门店坐标 5 米内。`DoBail` 补 Player 判空与 bool 类型校验。
  另修一个**我自己在批 17 引入的回退**：`net_event_guard_helpers.json` 里 `custom-justice` 是整键覆盖，
  把原有的人 `JusticeService.GetOwnInmate` 登记冲掉了，导致 `requestReduction` / `sentenceComplete`
  从「已鉴权」翻回「未登记」（本轮恢复，custom 重新归零）。教训已写进 static-rule-gates 技能：
  登记表一律 merge，不许 `d[key] = {...}`。
  探针：qb-shops（补货工资的距离/冷却、PaySlip、库存扣减、开店距离）。数字：未登记 **74 → 67**
  （qb 13 → 8、custom 2 → 0、allowlist 173）。

- **P1-3 批 18：tcity-dashboard 3 + story-engine 2 + production-freeze 2**（2026-11-08）：
  `tcity-dashboard` 的车牌标记/取消/追踪器**本来就是**「在职警察」（`isOnDutyLeo`：`job.type == 'leo'`
  或 `job.name == 'police'` 且 onduty），本轮登记进 helpers；真修的是参数——`plate:upper()` 遇到
  nil / 数字直接抛错打断事件线程（旧版实测两处 `attempt to index a nil value (local 'plate')`），
  `reason` 也无长度上限 → 加类型/长度校验。`story:server:makeDecision` 的校验全在
  `DecisionEngine.MakeChoice`（按 source 存 pending、quest/step/decision 三元组必须全等、带
  expiresAt），本轮给它补 `return` 并登记成 delegate 形状。`tcity:client:telemetry` 会**写库**
  （agent_events）而事件名/payload 大小/频率全由客户端定：一个改过的客户端可以每帧写一条大 payload
  把表写爆（旧版实测 200 条全落库，`TELEMETRY_RATE_LIMITED=false`）→ 现在 64 字 / 2KB / 60 秒 120 条。
  `i18n:client:reportLanguage(lang)` 原来客户端传什么就写什么（表、4000 字串、伪造的 `'xx'` 都进
  `metadata.client_lang`）；顺带发现这个文件**根本没取 core object**（`QBCore` 在本资源恒为 nil），
  所以「读/写玩家语言」两条路都是死代码、服务端永远按 en 渲染 → 显式 `GetCoreObject()` + 走
  `Player.Functions.SetMetaData`，语言代码只认 `zh`/`en`。`production:client:freezeDebug` 是**客户端**
  事件却注册在服务端 main 脚本里并被 `TriggerClientEvent(..., -1)` 广播 —— 服务端注册的 handler 永远
  收不到广播，所以「生产模式关闭客户端 DrawText3D / PolyZone debug」从未生效，而那份服务端副本还让
  任何客户端能覆盖**服务端**全局 → 处理器回到客户端的 main 脚本，服务端只留 `source ~= 0` 就拒绝的空实现；
  同时删掉客户端 i18n 脚本里那份永远收不到的服务端事件注册。三个探针（dashboard / story telemetry /
  i18n lang，位于 layer3_business 的 fixtures 目录）。数字：未登记 **81 → 74**（custom 4 → 2、
  other 64 → 59、allowlist 162）；真机 restart 三个资源 0 错误。

- **P1-3 批 17：qb-adminmenu / custom-justice / qb-hud / qb-scoreboard**（2026-11-08）：
  `qb-admin:server:GetPlayersForBlips` **没有任何权限校验**，谁发谁拿，而下发的 `qb-admin:client:Show`
  是**全服玩家的名字 + 实时坐标**——等于把 wallhack 发给所有人（客户端在轮询，拿到就是持续跟踪）。
  客户端只在管理员打开 blips/names 开关时才轮询，所以服务端按 `admin` 权限 + ACE `command` 对齐不会
  堵死任何职能（旧版实测 `BLIPS_CIVILIAN_BLOCKED=false`）。`hud:server:GainStress` /
  `RelieveStress(amount)` 的 `amount` 全来自客户端：表/字符串让 `currentStress + amount` 直接抛
  `attempt to perform arithmetic on a table value (local 'amount')` 打断事件线程，超大数字能一键把
  压力拉满或清零 → 统一走 `sanitizeStressStep`（必须为正数、上限 100，与 qb-ambulancejob 治伤发的
  100 相容）。`qb-scoreboard:server:SetActivityBusy(activity, bool)` 全仓**没有任何客户端调用点**却对
  客户端开放：任何玩家能用坏 key 让 `Config.IllegalActions[activity].busy` 抛 `attempt to index a nil
  value`，或者直接改全服的"非法活动占用"状态（等于全服抢劫开关）→ 改成 `source ~= 0` 拒绝 + activity
  白名单 + bool 类型校验。`custom-justice` 的 `justice:server:imprison` 本来就是警察/法官限定，只是
  写成正分支，闸门认不出形状 → 抽成 `IsLawEnforcement(Player)` 并登记（行为零变化，探针对旧版同样通过）。
  另有 7 条登记为 `self_scoped` / `civilian`：证照自发（要求本人持该类执照）、死亡状态重置（冷却 +
  医院资源运行期拦截 + 审计）、通缉上报（坐标校验 + 星级夹取 + 防刷）、出示证件（配置白名单 + 序列号
  与持有人绑定）、武器耐久（配置白名单 + 只降自己那把）、stress 两条。三个探针（adminmenu / hud+scoreboard
  共用一个带模式参数的探针，位于 layer3_business 的 fixtures 目录）。数字：未登记 **89 → 81**
  （qb 17 → 13、custom 8 → 4、allowlist 160）。

- **P1-3 批 16：qb-fuel 3 + qb-doorlock 3 + qb-mechanicjob 3**（2026-11-08）：三个资源同一类问题——
  客户端报什么就信什么。qb-fuel 的 `setCanFuel(fuel)` 直接把客户端给的数字写进油桶，而客户端调用点
  传的是 `canLiter - liter`（语义是**扣减**）；服务端分不清"加满"和"扣减"，任何玩家发一条
  `setCanFuel(40)` 就白得 40 升油（旧版实测 `CAN_INCREASE_BLOCKED=false`）。改为只允许单调递减 +
  夹在 0..`Config.JerryCanLitre`；**想"加"的请求直接拒绝并提示**，而不是静默写成当前值 —— 客户端
  `canLiter` 来自 `GetAmmoInPedWeapon`（油桶 ammo 是 0..100 刻度，`Config.JerryCanLitre` 只有 40），
  两边错位时静默按当前值写会变成"油桶一个不少、车里油却加上去了"的刷油复制。`refillVehicle(litres)` 的升数夹到 300 升且必须为正（旧版负数会
  把价格算成负数、`'abc'`/表直接抛 `attempt to mul a 'string' with a 'number'`）；`buyJerryCan` /
  `refillJerryCan` 加"在加油站 40 米内"（旧版全图任意位置能下单）；老油桶 `info` 为 nil 时旧版
  `jerryCan.info.fuel = ...` 直接抛错，现在补表。qb-doorlock 的 `updateState` 鉴权对象原来是
  `sentSource or source`——**客户端塞第 8 个参数报一个在线警察的 server id，鉴权就按那个警察算**，
  普通的门禁形同虚设（全仓客户端调用点都不传这个参数，旧版实测 `FORGED_SOURCE_BLOCKED=false`）；
  改为只用 `source` 鉴权、`sentSource` 与 source 不符即拒绝。qb-mechanicjob 的
  `sprayVehicle`/`sprayVehicleCustom` 没有任何来源校验：任何玩家能给**地图上任意一辆车**免费改色，
  还能让服务端 `FreezeEntityPosition` 住 `PaintTime*1000` 毫秒（能把别人的车冻在路口）；改为
  "本店员工 + 在本店喷漆位 20 米内 + 车在 20 米内"（与 client 侧 qb-target 的 paintbooth 职业限制
  等价）。`removeItem(part, amount)` 顾客修车时也会调，所以**不加**职业限制，只做有界校验
  （part 必须在 `QBCore.Shared.Items` 里、amount 夹成 1..10 整数）。三个探针（qb-fuel / qb-doorlock /
  qb-mechanicjob 各一个，位于 layer3_business 的 fixtures 目录），对 master 版本跑实测 12 条断言翻红。
  数字：未登记 **98 → 89**（qb 26 → 17、allowlist 153）；架构 455 passed / 15 skipped。

- **P1-3 批 15：qb-management 4 + custom-quest 4**（2026-11-08）：qb-management 那三个 boss 仓库入口
  （职业 / 帮派 / 组织）其实早就写了「本人是 boss + 站在菜单点 2.5 米内」的判定，只是写成
  `if not playerJob.isboss then return end` 这种闸门认不出来的形状 —— 本轮抽成
  `CanOpenBossStash(src, Player, orgType, orgName)` 并登记进 `net_event_guard_helpers.json`，
  **行为不变**（探针对旧版跑也是全绿），换来闸门能按 deny-early 形状持续核对；顺带给
  `personalStash` 补了 gang 字段类型校验。custom-quest 那四条是「客户端报告任务进度」，
  原来只判了 `Player` 存在：`aviationHeightMonitorComplete()` **连参数都没有**，任何玩家随手发一条
  就能把自己「低空飞行 45 秒」的步骤标记完成 → 现在要求 questId 是字符串、确实在跑这单任务、
  人**在载具里**（机型校验 best-effort：服务端原生不可用时放行，绝不 fail-closed —— 客户端发送后
  会立即停掉监控，服务端拒绝就没有重试路径）；`registerTrailer` 补「必须正在跑该任务」与
  **必填**的模型比对（写成 opt-in 的话少传一个参数就绕过）；`entityTrackingFail` 补 questId 校验与任务归属、`reason` 截断 100 字
  （它会进安全审计日志）；`cargoDamageResult` 在 `data` 为 nil 时直接抛错、四个数值无界 → 类型
  校验 + 各自夹取上限。客户端 `quest_logistics_client.lua` 现在把 `questId` 一起发上来。
  测试：两个探针。旧版实测：`cargoDamageResult` 在 nil/非表时分别抛
  `attempt to index a nil value (local 'data')` 与 `attempt to index a number value (local 'data')`，
  坏 questId 时抛 `bad argument #3 to 'format' (number expected, got nil)`，`DAMAGE_CLAMPED=false`。
  新增第三个探针 `quest_events_probe.lua`（真加载 custom-quest 的 server 主脚本）覆盖 fail-open 与模型比对：
  旧版实测 `AVIATION_CAR_BLOCKED` / `AVIATION_ON_FOOT_BLOCKED` / `AVIATION_WRONG_QUEST_BLOCKED` /
  `TRAILER_MISSING_MODEL_BLOCKED` / `TRAILER_MODEL_MISMATCH_BLOCKED` 全为 false。
  数字：未登记 **106 → 98**（qb 30 → 26、custom 8；allowlist 151）；合计事件数按实测校正为 439。

- **P1-3 批 14：qb-pawnshop 4 + qb-multicharacter 4**（2026-11-08）：qb-pawnshop 两条都是印钞机 ——
  `sellPawnItems` 的单价来自客户端（`totalPrice = itemAmount * itemPrice`，卖一块石头要价一百万），
  `pickupMelted` 的奖励表也来自客户端（`item.items[*].item.reward` 直接照单发物品，可要 99999 个金条），
  `meltItemRemove` 的熔炼耗时同样采信客户端提交的条目。三者一律改成按服务端 `Config.PawnItems` /
  `Config.MeltingItems` 查表结算，数量夹 1..100，非法物品直接丢弃。qb-multicharacter：
  `loadUserData(cData)` 遇到 nil/非表/非字符串 citizenid 直接抛错（归属校验本身在 qb-core 的
  `Player.Login` 里比对 license）；`createCharacter` 把客户端整张表 `newData.charinfo = data`
  写进 players.charinfo（可夹带 isAdmin / money / 5KB 字符串），改成白名单字段 + 长度收敛、`cid`
  归一化成数字；`deleteCharacter` 补类型校验（归属由 qb-core 的 `DeleteCharacter` 比对）。
  **CC 复核后又补两条**：① `pickupMelted` 原来只是把奖励表换成服务端配置，仍然可以站在当铺门口
  反复触发、无限领配置奖励（不需要原料、不需要等熔炼时间）—— 改成 `meltItemRemove` 扣料成功时登记
  `PendingMelt[src]`（含 `readyAt`），取回只按这批发、到时间才发、发完清除、背包满时保留、
  掉线清理；② `Config.PawnItems.price` 是 `math.random(50,100)`，客户端与服务端各自求值，
  改成服务端权威结算后会出现「显示 80 实收 52」—— `getInv` 回调同时下发价格表，客户端展示用服务端价；
  ③ 批次里逐条记 `paid[index]`：多奖励条目（rolex 是 diamond / goldbar / electronickit 三条）在
  「一条发得出去、一条背包满」时整批保留，会把已经发出去的那几条重复发 —— 只有全发完才清批次。
  测试：两个探针。旧版实测：`SELL_PAID_CONFIG_PRICE=false`、`SELL_AMOUNT_CAPPED=false`、
  `SELL_UNKNOWN_ITEM_REJECTED=false`、`MELT_USES_SERVER_ENTRY=false`；`loadUserData` 三种坏参数各抛一次
  `attempt to index a ... value (local 'cData')`，`CREATE_STRIPS_UNKNOWN_FIELDS=false`、
  `CREATE_CID_NUMERIC=false`。
  数字：未登记 **114 → 106**（qb 38 → 30；allowlist 143 → 151）。附带发现：
  `job_deny_guard` 的判据其实是「任一 player 变量上的 `~=` + return」，把「Player 存在性 + 类型」
  也算作职业守卫（换更严的 `.job` 判据会有 36 条历史事件翻面，本轮不动闸门，已在基线文档记录）。

- **P1-3 批 13：qb-cityhall 5 + interact-sound 5**（2026-11-08）：qb-cityhall 最实在的一条是
  `getIDs` 直接绑到 `giveStarterItems()` —— **任何玩家可以反复触发，每次都给一份 phone / id_card /
  driver_license**（无限刷物品）；改成按背包里是否已有逐个跳过。其余：`requestId(item, hall)` 的
  `hall` 来自客户端且直接索引 `Config.Cityhalls[hall]`（那是数组，坏下标 = nil 索引打崩事件线程）；
  `sendDriverTest(instructors)` 的 instructors 是客户端给的 citizenid 列表、长度不限，对离线玩家走
  `sendNewMailToOffline`（探针实测一次请求 49 封邮件），加条数上限 10 + 每人 60 秒冷却；
  `ApplyJob` 的距离校验用的是**客户端声称**的市政厅坐标（在任意地点把坐标报成自己脚下就能远程
  申请工作），改用服务端 `Config.Cityhalls[*].coords`。interact-sound 则在客户端开放了
  `PlayOnAll` / `PlayOnOne`（仓库内**没有任何调用点**）—— 任何人能给全服或指定玩家刷声；
  `PlayOnSource` / `PlayWithinDistance` 的文件名与音量零校验且无限流；`PlayWithinDistance` 还被
  注册了两次（后一个覆盖前一个，前一个是死代码）。改为：全局播放仅服务端可触发、声音参数走
  `^[A-Za-z0-9_%-]+$` 白名单 + 音量 0..1 + 按 (玩家, 文件) 100ms 限流（车辆转向灯频率高，不能用更长的
  窗口），并删掉重复注册。
  测试：两个探针（cityhall_probe.lua / interactsound_probe.lua，位于 layer3_business 的 fixtures 目录）。旧版实测：`requestId`
  坏 hall 抛 `attempt to index a nil value (field '?')`、`STARTER_REPEAT_NOTHING_ADDED=false`、
  `DRIVERTEST_MAIL_COUNT=49`、`APPLY_JOB_REMOTE_REJECTED=false`、`ALL_FROM_CLIENT_BLOCKED=false`、
  `ONE_FROM_CLIENT_BLOCKED=false`、`SOURCE_BAD_FILENAME_BLOCKED=false`、
  `SOURCE_BAD_VOLUME_BLOCKED=false`、`SOURCE_RATE_LIMITED=false`。
  数字：未登记 **124 → 114**（qb 43 → 38、other 65 → 64；`interact-sound` 5 → 4，重复注册已删）；
  `1276 passed`。

- **P1-3 批 12：qb-houserobbery 5 + qb-clothing 5**（2026-11-08）：qb-houserobbery 有一个**功能级**
  bug —— 搜刮家具的准入导出写成了 `exports['custom-main']:CheckHouseRobbery`，而这个导出只有
  `custom-crime` 提供，每次搜刮都会抛 `No such export CheckHouseRobbery in resource custom-main`，
  等于**整条房屋搜刮流程从来没跑通**；顺带 `SetBusyState(cabin, house, bool)` / `enterHouse(house)` /
  `searchFurniture(cabin, house)` 都拿客户端传来的 house/cabin 直接索引 `Config.Houses[...]`（坏 key
  就是一个 nil 索引，打崩事件线程），`SetBusyState` 还能把任意家具标成 isBusy 锁死整间房子，已搜过的
  抽屉服务端也照样发奖。qb-clothing 集中在"客户端数据没有边界"：`saveSkin` 无结构/长度校验就进 RAM
  缓存与 `playerskins` 列；`saveOutfit` 在 `Player` 为 nil 时直接索引崩、且**没有条数上限**（可无限往
  `player_outfits` 插，每次插入还会全量回读）；`removeOutfit` 同样缺判空；`QBCore:Server:OnPlayerUnload(src)`
  是服务端内部事件，客户端能自己发一份（还能传别人的 src 强制写盘别人的皮肤）。
  测试：两个探针真加载 config + server/main.lua。旧版实测：`SetBusyState`/`enterHouse` 遇坏 key 抛
  `attempt to index a nil value (field '?')`，`searchFurniture` 抛 `No such export CheckHouseRobbery
  in resource custom-main`（`SEARCH_NO_ERROR=false`、`SEARCH_MARKED_SEARCHED=false`），
  `SKIN_HUGE_REJECTED=false`、`UNLOAD_CLIENT_BLOCKED=false`、`OUTFIT_LIMIT_ENFORCED=false`，
  且 `saveOutfit`/`removeOutfit` 在玩家对象缺失时抛 `attempt to index a nil value (local 'Player')`。
  数字：未登记 **134 → 124**（qb 53 → 43，allowlist 132 → 139）；`1269 passed`。

- **P1-3 批 11：qb-inventory 8 条**（2026-11-08）：核心资源，改动只限制在"客户端参数形状"与"归属"
  两层，不碰物品搬运算法 ① `openVending(data)` / `closeInventory(inventory)` / `useItem(item)`
  直接索引客户端参数（`data.coords` / `inventory:find` / `item.slot`），发个数字就能把事件线程打崩
  → 补类型校验；② `openDrop(dropId)` 只认 `isOpen`，一个人打开后不发 `closeInventory`（改过的
  客户端或直接崩游戏）就能把掉落物**永久锁死** → 记 `openedBy/openedAt`，2 分钟后允许接管；
  ③ `updateDrop(dropId, coords)` 只校验"玩家 ↔ 声称坐标"距离、不校验归属，任何玩家都能把别人的
  包一段段拖走（每次 5 米、次数不限）→ 只允许创建者或管理员；④ `QBCore:Server:UpdateObject`
  的判据是 `source ~= ''`，而服务端 `source` 是数字 0，`0 ~= ''` 恒真 → handler 实际是**死代码**
  （qb-core 重启后没人能刷新对象），改成 `source ~= 0`；⑤ `snowball` / `SetInventoryData` 已有
  冷却与 `validateOtherPlayerInventory`（目标在线 + 3 米内），登记进 allowlist 并把该 helper 写进
  `net_event_guard_helpers.json`。
  测试：探针真加载 config + server/main.lua（functions.lua 的全局函数用桩替代，因为是核心资源，
  加载整条依赖链不现实）。旧版实测：`openVending`/`closeInventory`/`useItem` 三个 handler 在收到
  数字参数时分别抛 `attempt to index a number value`，`DROP_TAKEOVER_AFTER_TIMEOUT=false`、
  `DROP_MOVE_FOREIGN_BLOCKED=false`、`UPDATE_OBJECT_SERVER_ALLOWED=false`。
  数字：未登记 **142 → 134**（qb 61 → 53，allowlist 127 → 132）；`1262 passed`。

- **P1-3 批 10：qb-vehicleshop 7 条 + 试驾生成回调**（2026-11-08）：批 3 已把"钱"的面改成服务端
  权威，这次剩下的都在**实体与配置**层：① 试驾生成回调 `spawnvehicle(plate, vehicle, coords)`
  三个参数全来自客户端且**没有任何校验** —— 车型直接进 `GetHashKey`、坐标直接进生成函数，
  任何玩家能在任意坐标生成任意载具；改为「车型必须出现在某家车店的展台上 + 玩家在该店附近 +
  请求的生成点也在该店试驾点附近」，并在生成时记账 `TestDriveVehicles[netId] = {src, model, at}`；
  ② `deleteVehicle(netId)` 的 netId 直接进 `DeleteEntity` —— 任意 netId 就是任意实体（别人的车、
  NPC、玩家），改为只认本资源给这个玩家生成的那台（`IsOwnTestDrive`），并校验实体存在；
  ③ `swapVehicle(data)` 会向**全服**广播客户端给的 data → 改所有人的展车，改为只有在职店员
  （`dealerOnDuty`）；④ `customTestDrive(vehicle, playerid)` 任何玩家能给任意人发**任意车型**
  （含警车/飞机），改为在职店员 + 车型必须在展台上；⑤ `addPlayer/removePlayer(citizenid)` 的
  citizenid 由客户端传 —— 能重置/结算**别人**的分期计时器，改为只认同调用者自己的；⑥
  `checkFinance()` 在 player 为 nil 时直接索引 `player.PlayerData` 抛错，且 handler 里有
  `Wait(Config.PaymentWarning * 60000)`，连点会堆睡眠线程，补判空 + 每玩家 10 分钟冷却。
  测试：探针真加载 config + server/bus.lua + server/finance-lifecycle.lua；旧版实测
  `SPAWN_FOREIGN_MODEL_BLOCKED=false`、`SPAWN_FAR_BLOCKED=false`、`DELETE_FOREIGN_BLOCKED=false`、
  `SWAP_CIVILIAN_BLOCKED=false`、`TESTDRIVE_FOREIGN_MODEL_BLOCKED=false`、
  `TIMER_VICTIM_UNTOUCHED=false`，以及 `checkFinance` 的 `attempt to index a nil value (local 'player')`。
  数字：未登记 **149 → 142**（qb 68 → 61，allowlist 123 → 127）；`1256 passed`。

- **P1-3 批 9：qb-ambulancejob 14 条**（2026-11-08）：这个资源之前已经加过 `CanRevive`、
  `SendToBed` 索引校验与 30 秒限流、"无伤不得自报死亡"，剩下 14 条里 9 条是真洞：
  ① `qb-ambulancejob:server:stash` 只看客户端菜单上的 job 过滤条件（可绕过）→ **任何玩家都能打开
  救护队储物柜**，改成服务端确认在职 EMS；② `LeaveBed(id, hospitalIndex)` 向全服广播
  `SetBed(..., false, ...)` 且无归属校验 → 任何人传任意床号就能把全服的床标成空闲/赶人，改成
  服务端按 `BedOccupant[院:床] = src` 记账，只有占用者本人或收床的在职 EMS 能放；③
  `resetHungerThirst` 等于免费把饥饿/口渴拉满，改成只认服务端刚复活/送进院的玩家
  （`markRevived` 在 RevivePlayer / RespawnAtHospital / txAdmin heal 三处写入，窗口 180 秒）；
  ④ `ambulanceAlert(text)` 文案来自客户端且无冷却 → 一人刷爆所有在职 EMS，加 string 校验 +
  截断 200 字 + 15 秒按玩家冷却；⑤ `SendDoctorAlert` 只有一个全局开关，谁先按下谁就能把它锁
  `Config.DocCooldown` 分钟 → 院名必须命中配置 + 按玩家 30 秒冷却；⑥ `CanHelp` 任何玩家都能
  替人回答"可以施救" → 只认 `UseFirstAid` 写入的 `PendingAid` 回执；⑦ `RemoveDoctor` 按客户端
  传的 `job == 'ambulance'` 减 `doctorCount` → 平民能把医生数刷到 0，改成只认服务端登记过的
  在班 EMS；⑧ `SyncInjuries` / `SetWeaponDamage` 写自己 metadata 但内容无界（`isBleeding = 1e9`）
  → 类型校验 + 数值夹取。
  EMS 判定抽成 `isOnDutyEMS` 并登记进 `net_event_guard_helpers.json`（闸门按 `if not isOnDutyEMS(...)`
  形状核对）。测试：探针真加载该资源的 config.lua 与 server/main.lua，旧版实测
  `STASH_CIVILIAN_BLOCKED=false`、`BED_RELEASED_BY_STRANGER=1`、`HUNGER_OUTSIDE_WINDOW_BLOCKED=false`、
  `ALERT_COOLDOWN_BLOCKED=false`、`DOCTOR_ALERT_FAKE_NAME_IGNORED=false`、
  `CANHELP_WITHOUT_PENDING=false`、`DOCTOR_COUNT_AFTER_CIVILIAN=0`、`INJURIES_BLEEDING_CLAMPED=false`。
  数字：未登记 **164 → 149**（qb 82 → 68，allowlist 113 → 123）；`1249 passed`。
- **P1-3 批 8：qb-garages 6 + qb-weathersync 7**（2026-11-08）：qb-garages 是货真价实的洞 ——
  取车回调 `spawnvehicle(plate, vehicle, coords)` 三个参数全来自客户端而服务端只查「在外车辆数 +
  驾照等级」，**别人的车牌 / 任意车型 / 全图任意坐标都能生成**；`syncGarage` 任何玩家都能整表
  覆盖 `Config.Garages`（全服车库点数与位置）；`PayDepotPrice` 按车牌查价不查 citizenid 也不查
  state（别人的车、停在库里的车都能走"赎车"通道召唤）；`UpdateOutsideVehicle` 可把任意
  (车牌, netID) 塞进全局表；`trackVehicle` 能拿任意车牌换实时坐标。修法：取车回调三重校验
  （归属 + 车型与 `player_vehicles.vehicle` 一致 + 生成点在玩家 100 米内）、`syncGarage` 限控制台
  或 admin、赎车要求「本人 + state=2 + 价格取库」、`OutsideVehicles` 要求本人实体真实存在、
  `updateVehicleState` 白名单 {0,1,2}、`updateVehicleStats` 三个数值夹区间。qb-weathersync 本来
  就有 `isAllowedToChange`（控制台 / admin ACE），但写成 `if isAllowed(...) then` 正分支，闸门只认
  deny-early 形状，6 个事件一直被记为「未登记」—— 重构成 deny-early + 在
  `net_event_guard_helpers.json` 登记（含 `requires_code` 证据），行为零变化；另补两处真缺口：
  `RequestStateSync` 加每玩家 5 秒冷却（原来一人连点 = 2N 条全服广播）、
  `QBCore:Server:OnPlayerLoaded` 加 `src ~= 0` 拒绝客户端触发。
  测试：两个探针（garages_probe.lua / weathersync_probe.lua，位于 layer3_business 的 fixtures 目录） 真加载资源 + mock 运行时，
  旧版实测 `SPAWN_OTHERS=false`、`SPAWN_MISMATCH=false`、`SPAWN_FAR=false`、`SYNC_BLOCKED_FOR_PLAYER=false`、
  `DEPOT_OTHERS=false`、`BROADCASTS_FROM_TWO_CALLS=4`、`BROADCASTS_FROM_CLIENT_TRIGGER=2`。
  数字：未登记 **177 → 164**（qb 95 → 82，allowlist 112 → 113）；`1238 passed`。

### Security
- **S3 限流收口到 `RateLimit`**（2026-11-15）：`custom-police` 7 个文件 / 8 张本地表
  （forensics / tow / coroner / evidence / p2_system / p0_incidents / main）与
  `custom-director` 的 `liveBuckets` 令牌桶全部迁到 `core-framework` 的
  `RateLimitCooldown` / `RateLimitTokenBucket`；键统一 `police:<src|cid>:<action>` 与
  `director:live:<hash>`，阈值按秒 → 毫秒等价换算。
  `playerDropped` 一次 `RateLimitReset('police:<src>:')` 清掉 src 键；cid 键由 owner 新增的
  60s 自清理线程回收（`RateLimit.Sweep(15 * 60 * 1000)`）。旧的 60s prune 循环与 evidence
  的每 64 次 prune / `pickupWrites` 计数器已删除；director 的 429 复用 owner 返回的
  `retryAfterMs`。闸门 `test_rate_limit_single_owner.py` 的 `IMPL_MARKERS` / `CALLERS`
  先红后绿。

## [0.7a] — 载具重构与物流 — 2026-10-21

> 代码完成于 2026-06-22，tag 于 2026-10-21；实机验收仍待完成。

### Added
- **结案从来没真的写进库（nil 参数让整条 UPDATE 静默失效）**（`custom-police` / `core-framework`）：真机排查发现本 build 的 oxmysql 是**客户端插值**的 —— 参数里出现 `nil` 时它不会绑成 `NULL`，而是把占位符 `?` 原样留在 SQL 里，于是语句语法错误、`.await` 也不报错。两处踩中：① MDT「清场」不带 reason，`closed_reason` 传 nil → 警情状态一直是 `on_scene`，而 `incident.close` 审计照写（"审计说关了、其实没关"，同一张单可以被反复"关"）；② `world_state` 落盘时 `previous_value` 传 nil → 首写静默丢失。现在 `closed_reason` 用空串、`previous_value` 传 JSON 的 `null`；并且**痕迹只在 `affected > 0` 时写**（`affected=0` 打日志不落痕迹），避免"警情没关、痕迹却 +1"。
- **城市公告在冷缓存下会丢**（`custom-police`）：原节流规则是「该区 24 小时内第一起结案」，靠 `world_state` 的 `closed_24h` 判断 —— 而 `Record` 在缓存冷时是异步落写，读回来是 `nil` → `closed_24h=0` → 公告静默不发（CC 评审 2026-11-01 指出）。改成调用方自己的**每区域 30 分钟冷却**（内存计时，重启清零，宁可多一条不漏），不再依赖跨资源读值。
- **`QBCore:DebugSomething` 是裸的 RegisterServerEvent（任意客户端可刷服务端日志）**（qb-core）：handler 的 `tbl` / `indent` / `resource` 全由客户端给，服务端直接 `print`，既能刷屏也能用深层表放大内存与 IO。现在用 `GetInvokingResource()` 区分「服务端自己 `QBCore.Debug`」与「客户端触发」，后者要求 `IsPlayerAceAllowed(src, 'qb.debug')`；`indent` 先 `tonumber` 再钳到 `MAX_DEBUG_INDENT = 8`（原来直接透传，可递归到栈溢出）。ACE 示例写进 `server.cfg.template`，不授予也不影响任何现有功能。闸门：`tests/architecture/test_engine_event_guards.py`（静态契约 + 剥守卫反向用例 + 跑真实文件的 Lua 行为验证：无 ACE 客户端 0 次打印、30 层嵌套表被截断）。
- **经济倍率一个 convar 两种单位（最多差 100 倍）**（core_economy / qb-shops / economy-dashboard）：`economy_reward_scale` 被三个整数读者按 `/100` 解析、被两个浮点读者直接当倍率，而 `economy.cfg` 写的是 `1.0` —— 走网关的奖励与商店价会变成 1%。统一为**浮点倍率**（`1.0 = 1x`），三处改 `GetConvarFloat`；`0 / 负数 / 未设置` 一律回落 `1.0`。`economy.cfg` 补单位注释，`T-CityLite.base/docs/systems/delivery-manual.md` 里 `/100` 的公式说明与 `80 / 120` 的示例命令同步改成倍率写法（否则运维照着旧文档敲 `80` 就是 80 倍）。闸门：`tests/unit/layer1_core/test_economy_multiplier.py`（真实加载源码跑 Lua 沙箱，含三读者单位一致性断言）。

### Fixed
- **`world_state` 读路径（审计 R7 挂了一个多月的那条债）**（`core-framework`）：旧实现用 `promise.new` + `Citizen.Await` 同步查库（首次读卡住主线程），且 `prepare` 取三列后直接 `local value = row` —— 拿到的是**整行**，还把 `changed_by` 硬写成 `nil`（注释说 not in this query，查询里明明有）。现在：`GetRegionState` 只读内存缓存、未命中返回 `nil` 并后台预热（绝不阻塞）；新增 `GetRegionStateAsync` / `GetRegionSnapshotAsync` / `GetPlayerTraces(cid, cb)` 走回调；`saveToDB` 把落盘的异步结果通过 `cb(ok, code)` 回报（`save_failed` 不再被静默吞掉）。证据：`tests/unit/layer1_core/test_world_traces.py` 的 `Citizen.Await` / `promise.new` / `local value = row` 三条回归断言 + 行为 harness（冷启动续写、落盘失败回报）。
- **结案查询缺坐标**（`custom-police`）：`SetIncidentStatus` 的 `SELECT id, status` 改为 `SELECT id, status, x, y` —— 结案要落世界痕迹，区域只能由坐标判定。

### Added
- **世界痕迹第一条链：结案 → 区域状态**（`core-framework` + `custom-police`）：新增 services 目录下的 world_trace_service.lua 作为 `world_state` 的**唯一写者**（`Record` / `RecordAt`，白名单 `crime_pressure`，30 s 同键去抖，`recent` 时间戳窗口上限 50）；新增 shared 目录下的 regions.lua（10 个区域，坐标取自 qb-storerobbery 与 qb-drugs 的既有配置 + 纯函数 `RegionOf`，非法坐标与远海一律兜底 `city_wide`）。`custom-police` 的结案分支在 `pcall` 里调 `service_world_trace_RecordAt`，**痕迹失败不影响结案**。`table_owners.json` 登记 `core-framework` 拥有 `world_state` / `world_events`（只登记 owner、不进 scan：边界对被扫描的 10 个资源已经生效，补扫另开任务）。施工图与验收：`docs/engineering/2026-11-01-world-traces-blueprint.md`；方向调研：`docs/engineering/2026-11-01-next-epic-research.md`。
- **城市公告出口（CityFeed）**（`custom-phone`）：`phone_cityfeed` 加 `author_kind`（迁移 v3.15 纯增量、`information_schema` 守卫、可重复执行；fixture 同步），玩家发帖由服务端写死 `'citizen'`、城市公告走导出 `PostCityBulletin` 写 `'city'` + 哨兵作者，读路径按 `author_kind` 归类（否则 LEFT JOIN 不到就是 `@Anonymous`）。校验规则抽到 custom-phone 的 server 目录下 city_feed.lua（纯模块，长度按**字符**算：200 个汉字是 600 字节，用 `#` 判会误杀）。手机前端 CityFeed 给城市公告加「📣 城市」标识。结案只在 `arrest`/`cleared` 且该区 24 小时内第一起时发公告（避免刷屏）。


### Changed
- **分支卫生：`dev` 与 `salvage/main-20261101` 清掉了**。`dev` 独有提交 0（tip 是 master 的祖先）、最后活动停在 2026-10-26，CI 的 `branches: [master, dev]` 同步改成只跑 master。`salvage` 是归档快照（相对 master 少 583 个提交、多 440 个文件，其中 401 个是上游残留），按内容逐个比对后把真正缺的 9 个文档/工具提取进 master（文档生命周期规范 + 工具、用 `--index` 对 275 份当前文档重新生成的 INDEX、手机 DESIGN、警察 BLUEPRINT-ITEMS 三份、系统覆盖调研），原始快照打成 tag `archive/salvage-20261101` 后删分支。`docs/engineering/WORKTREE.md` 里"6 个文件 master 里没有"的旧说法一并改正（实测 14，其中 5 个是路径迁移）。

### Fixed
- **剧情抉择面板：键鼠都能用，选完立刻释放焦点**（`story-engine`）。三处真机缺陷一起修：① `decision_nui.html` 的 NUI 回调写成了 `https://cfx-nui-story-engine/...` —— 那是**页面自身的 host**，回调必须 POST 到 `https://<GetParentResourceName()>/...`，于是 `nuiReady` / `nuiOpened` / `makeChoice` 全部 404 且被 `.catch` 吞掉（表现：面板能画、点不动、只能等 120 秒超时）；② 焦点顺序反了（`SetNuiFocus` 之后才 `SetNuiFocusKeepInput`），会把光标吃掉，改成**先 keepInput 再按焦点**；③ `options` 里带 `effects` 等表结构导致 `SendNUIMessage` 的 JSON 编码失败被静默丢弃，现在只发 `{id, text}`。另外：同一决策重复下发不再关闭重开（避免玩家点击时按钮 DOM 被重建）、手写测试页面卸载后不再残留 `nuiReady` 断言。真机：键盘 `1` → `nui.makeChoice` → `makeDecision choice=honest_cop` → `quest_event_log #89 complete`；鼠标点击同样产生一次 `makeChoice` + `makeDecision`。
- **序章任务链三处静默失败**（`T-CityLite.base/resources/[custom]/custom-quest`）：① checkpoint 半径原来优先取 cpType 默认值（`ring=30`），而服务端按模板 `step.data.radius`（15/20）复验距离 —— 于是"客户端喊到了、服务端判太远"，`quest_event_log` 里只有 `security_block distance_fail`（真机 `required=15.0 distance=28.78`）；② 决策节点把同一个事件派发**两遍**（`NODE_EVENTS[DECISION]` 本身就是 `story:client:offerDecision`，走到函数底部又发一次），第二遍关界面重开导致第一块面板的看门狗仍在计时；③ 决策 payload 只带 `decision_id`，`prompt/options` 在 story-engine 的决策定义里，而 `OfferDecision` 返回的是 `(true,'offered')` 不是表 —— 客户端永远收到 0 个选项走 skip 兜底。现在分别改为：模板优先的半径、DECISION 只派发一次、用 `GetDecision` 取定义并并进 payload。
- **决策超时不再死锁**（`story-engine`）：`police_ch1_honest_or_silent` 没有 `default_option`，超时/看门狗一触发就 `clearPending` 返回失败，任务永久停在 `step_decision`。现在缺省时用**第一个选项**兜底；连选项都没有时保留 pending 让玩家手动选。
- **任务接取去重**（`T-CityLite.base/resources/[custom]/custom-quest`）：同一玩家同一任务可能出现多条 `in_progress`（真机 3 条），恢复时各自下发一次状态。`CreateQuest` 先查在办记录，有就跳过。
- **story-engine 不在时决策会重试**（`T-CityLite.base/resources/[custom]/custom-quest`）：`restart custom-quest` 会连坐停掉 story-engine 且不自动拉回，决策 export 消失后只打一行 warning 就软锁。现在 5 秒重试 6 次，耗尽后明确通知玩家"剧情服务暂不可用，请重新连接"。
- **车机静默无响应**（`tcity-dashboard`）：`custom-vehicles` 被 `restart` 连坐停掉后，按 `I` 只发出 `request_lock` 就再无下文。服务端在 `onResourceStart` 检查并在必要时 `StartResource('custom-vehicles')`；客户端 900ms 无回执时提示"车机服务未就绪（custom-vehicles: stopped）"。
- **小地图回原生**（`qb-hud` / `hud-position-tool`）：qb-hud 的 square 分支把 mask/blur 放大到 `0.2293×0.2625`（原生 `0.111×0.159`）并替换雷达遮罩贴图、踢 bigmap —— 内容溢出边框、偶发"倾斜巨图"。现在默认 `hud_native_map=1` 直接跳过整段；`hud-position-tool` 关闭时不再写组件（两个写者互相覆盖）。

### Added
- **`tools/dev/fivem_focus.py`**：把 FiveM 窗口切到前台（`AttachThreadInput` + 必要时点窗口中心）。`fivem_console.py --key` 依赖窗口在前台，之前只能手动 Alt-Tab。
- **`tools/dev/cc_run.sh`**：在本机跑 Claude Code（后端是 DeepSeek 的 Anthropic 兼容端点）。修掉两个环境问题：`ANTHROPIC_*` 只在 `HKCU\Environment` 里、没有进 bash；模型名带本地后缀 `deepseek-flash[1m]` 端点不认。
- **开发期重放命令**：`quest_reenode <src>`（重放当前步骤节点）、`story_offer_dev <src> [decisionId] [questId] [stepId]`（不依赖任务状态直接下发决策）、`story_nui_ping <src>`（NUI 管道探针），均由 convar 门控、默认关闭。


### Added
- **警察系统文档沉淀**：新增 `docs/agent/police/README.md`（入口索引 + 现状一页表 + 踩坑清单 + 常驻/多机待办）与 `docs/agent/police/ATOOLS-DISCIPLINE.md`（加/改 agent 动作的九步检查清单：四处策略接点、工具名白名单、单一写者、fail-closed 审计、闸门命令）。
- **AI 调度员 MVP**：`tools/agent/dispatch_mvp.py` 只做两件确定性的事 —— 从 `phone_messages` 增量取内容、把解析结果提交成 `police_call_draft` 草稿（幂等键按来源 id，令牌不落盘不打印）；**解析由 agent 完成**，脚本里没有关键词映射表。真机：3 条报案短信 → 草稿 `#71/#72/#73`（`10-31` / `911` / `10-52`），系统消息被跳过。
- **指纹 / DNA 采样**：`forensics.lua` 新增 `fingerprint` / `dna` 样本；采样时把 30 m 内在场玩家记成候选写进证据描述，`police:server:compareSample` 只认这张名单 —— 命中给证据补 `subject_citizenid` 并追加 `matched` 链，名单外明确 `no_match`。比对逻辑在 `p2_evidence`（唯一写者），`forensics` 只做入口。
- **P4 证据收口**：盘查读数（酒测/药检）在**没有在办警情**时不再读完就散 —— 落成「待挂载证据」（`police_evidence.subject_citizenid` 有值、`case_id` 为空，迁移 v3.14 纯增量幂等）；立案后 `BindPendingFor` 按精确 citizenid 自动绑定到新案卷，保管链追加 `auto_bound`（不 UPDATE 旧行）；新增 `BindEvidence(source, evidence_id, case_id, force)` 供人工兜底，重复绑定返回 `already_bound`、主体不符返回 `subject_mismatch`（`force=true` 会写 `evidence.bind_forced` 审计）。
- **P6-4 草稿箱 UI（手机 / 平板 MDT）**：`PoliceMDT` 调度→接警页顶部新增「📝 草稿箱」，两条车道（可采纳 / 需核对）；采纳走 `draft → open`，丢弃需二次确认且服务端要求 grade ≥ 2。置信度**不建列**：`needs_review` 落在草稿行的 `disposition`，判据是「码位被降级成 911」或「描述短于 20 字」。草稿 30 分钟无人处理会自动归档（`disposition='stale'`，读路径惰性清理）。
- **P6-4 草稿箱（服务端闭环）**：`police:server:draftList` / `police:server:adoptDraft` + 导出 `ListDrafts` / `AdoptDraft`；列表只给在勤警察且**先审计后查询、审计失败不给看**（FIT-05，因为草稿带标题与描述）；采纳复用既有状态机 `draft → open` 并写 `incident.adopt`，带 3 秒冷却防止连点把整箱草稿一次发出去。
- **P6-4 AI 调度员（call 卡草稿）**：动作 `police_call_draft`（L2 审批）+ 工具 `apply_police_call_draft`；文本报案解析成结构化 call 卡后写 `police_incidents.status='draft'`（迁移 v3.13 给 enum 加 `draft`，纯增量幂等），**不广播、不派 NPC、不上在勤看板**，由警员采纳后变 `open`。未知 code 降级为 `911`（`AgentPolicy.KNOWN_CODES`），priority 夹到 1..3（与存储层一致）。
- **P6-3 agent 申请逮捕令**：动作 `police_warrant_request`（L3，审批后执行），工具 `apply_police_warrant`；入口与 `RequestWarrant` 同处 custom-police 的 p3_cases 模块（police_warrants 的唯一写者），共用同一条 INSERT，只写 `status='requested'`、审计 `actor_kind='agent'`、审计失败返回 `audit_unavailable`；不批准、不 BOLO、不入狱。
- **P6-2 agent 起草报告**：动作 `police_draft_report`（L2，审批后执行），工具名 `apply_police_report`；写路径委托唯一写者 `PoliceRecords.InsertReport`，固定 `status='draft'`、`kind='report'`，不提交/不罚款/不带 BOLO/不生成证据，随后写 `report.draft` 审计。
- **P6-1 agent 只读案卷**：`GET /agent/v1/live/police/cases/{case_id}`（live token，L0），返回案卷号/状态/判决/刑期/主办，**不含姓名、坐标、正文**；注册为 `get_police_case`（读类工具必须是 GET、`director_action=null`、`compensation=none`，这是第一次把它做成 action 被校验器否掉的原因）。研究与施工图见 `docs/police/plans/2026-10-31-p6-agent-tools.md`。
- **P4 第一步：盘查读数挂到现场**（还 P3 的债）。`fieldTest` 现在查这名警员当前未结的警情，有就调 `RegisterEvidence` 挂证物并把 `exhibit_no` 回给客户端；没有就只留审计，等立案后由 MDT 带入。bodycam 方案与三条约束（只 panic 自动 / 7 天保留 / 磁盘+路径）写进 `docs/police/plans/2026-10-31-p4-audit.md`。
- **警察系统现状与缺口盘点**（`docs/agent/police/STATUS-2026-10-31.md`）：P0/P1/P2/P3/P5 完成，P4 部分（表与链在、缺 bodycam/延迟化验/盘查读数绑定），P6 全缺（三个 agent 动作 0 命中）；另列指纹/DNA、保释/假释与多机验收清单。
- **P3 收尾**：蓝图 Phase 3 标记为完成（P3-1 玩家盘查面板、P3-2 酒测/药检、P3-3 盘查带入逮捕表单、P3-4 BOLO 推送），遗留两项（证据延迟绑定属 P4、多机验收待第二客户端）写进核对文档。
- **P3-4 BOLO 发布即推送**：以前 BOLO 只是 `police_reports` 上的标记，街上没人知道；现在 `broadcastBolo` 走 custom-phone 的 Outbox 推给所有**在勤且非本人**的警员（`BOLO · 标题` / `人员|车辆 · 目标 · 地点`），逮捕提交与报告提交两条路径都接。
- **P3-3 盘查 → 立案**：`custom-police` 按警员记录最近一次盘查（查证件 / 酒测 / 药检），`GetLastInspection` 带策略门与审计失败关闭；手机 MDT 新增 `last_inspection` 查询与「从最近盘查带入」按钮，一键把 citizenid 填进逮捕表单并显示读数。
- **`custom-consumables`（新资源）**：本服没有 qb-smallresources，`qb-core` 只**读** `metadata.hunger/thirst` 判断饿死扣血，全仓没有写者 —— 食物不顶饿、HUD 永远 100、酒测没有数据源。现在由它做**唯一写者**：饥渴/酒精/药物读数、60 s 衰减线程（−1.0 / −1.2）、物品使用入口（`GetItemByName` 归属校验 + 每物品冷却）。文档 `docs/engineering/CONSUMABLES.md`；警用酒测改为优先读它的 `GetAlcohol`。
- **P3-2 酒测 / 药检**：新增 `T-CityLite.base/resources/[custom]/custom-police/server/sobriety.lua` 作为酒精数据源（`beer +0.25` / `vodka +0.50`、每秒 -0.01 衰减、三档读数），物品使用带 `GetItemByName` 归属校验；`police:server:fieldTest` 服务端复算距离、离岗拒绝、60 s 冷却、写审计。盘查结果**不写** `police_evidence`（该表要求挂 case/incident，盘查发生在立案之前），绑定留到 P3-3。
- **P3-1 玩家盘查入口**：`qb-target` 的 `AddGlobalPlayer` 提供「查证件 / 搜身 / 铐起 / 押送」四个动作（仅在岗警察可见）；查证件走 `police:server:showId`，服务端复算距离（>3.5 m 拒绝）、离岗拒绝、写审计，只回公开资料。
- **P3 现状核对**：逮捕/报告/罚单/证据四个 MDT 子页、BOLO、搜身与押送事件**都已存在**；真正缺的是玩家 qb-target 交互面板（查证件/搜身/酒测/药检）与酒测药检本身。核对文档 `docs/police/plans/2026-10-31-p3-audit.md`。
- **P2 收尾（AC-P2-05 / 09 / 04）**：迁移 `v3.12` 给 `police_incidents` 加 `ref` + `merge_count`，合并改为 **ref 优先**、并在合并时累加次数；结案改为**只有 lead 能关**（无 lead 的单仍可由够级别的人关掉，否则没人接的单永远关不掉）；到场判定补 `ARRIVE_MAX_SPEED = 2.0` —— 进半径还要停稳，开车路过不再翻 `on_scene`。
- **车机中控开面板时仍可驾驶**：帧 `keepInput = true` + `allow` 放行车辆控制（油门/刹车/转向/手刹/灯光），视角 1–6 仍被栈屏蔽（否则鼠标一动镜头就转、游标没法用），攻击类照旧挡；`dashboard_drive_while_open 0` 可回滚成独占输入。
- **P2 调度总线收尾**：7 个发案来源逐个对账（qb-drugs ×2 / qb-houserobbery / qb-storerobbery / custom-vehicles ×2 / NPC callout），全部落在两个 handler 上；真机已证手机 911、NPC callout、控制台投影三条路径。蓝图 Phase 2 标记为完成。
- **车机终端的警情页（P2-4）**：`tcity-dashboard` 的 police 模块新增「📞 警情」——当前未结警情列表 + 一键设导航 + 刷新。链路四层各自把关（NUI → client 在岗 → server 在岗+限流 → `custom-police` 的 `GetIncidentsPublic` 策略+审计），坐标统一走 `T-CityLite.base/resources/[custom]/custom-police/shared/dispatch_view.lua` 投影（D5）。
- `T-CityLite.base/resources/[custom]/custom-police/shared/dispatch_view.lua`：警情对外投影的唯一实现（按单号稳定偏移 60–95% 半径，黄金角散布）。

### Fixed
- **小地图被改成非原生**：`hud-position-tool` 启动即按「圆形 + 87.5% + 自定义偏移」重排小地图组件。改为受 `hud_position_tool` 开关控制（默认 `0` = 不动原生）；同时 `custom-ui` 顶层新增雷达可见性线程：**步行不显示雷达、上车交回原生**（不碰尺寸/位置/形状）。
- **`I` 键唤不出车载面板**：命令里三个早退分支（被别的界面占用 / 不在载具 / 250ms 去抖）只弹提示不留证据。新增 `dashboard_debug` 诊断，按一次键即可在客户端日志看到 `enter` 与 `blocked:*` 的确切原因。
- **警察序章仍推进不了**：`SetupReachZone` 的检测区只写在 `if PolyZone then` 里，而 `PolyZone` 是它自己资源内的全局（`PolyZone = {}`），跨资源恒为 nil → **检测区从未被创建**。改为纯距离轮询（500ms）+ 触发日志 `[quest-reach]`，PolyZone 分支保留给将来手动挂库。
- **客户端刷屏 `event QBCore:Player:SetPlayerData was not safe for net`（280 次）**：custom-phone 的客户端脚本用 `AddEventHandler` 监听这个**服务端下发**的事件，没有声明为 net-safe；全仓其它 5 处（qb-core / qb-hud / qb-inventory / qb-fuel / custom-certificates）都是 `RegisterNetEvent`，只有手机这一处写错。已改，并加闸门禁止客户端再用 `AddEventHandler` 监听 `QBCore:Player:*`（服务端内部事件 `QBCore:Server:*` 不受影响，那本来就该用本地监听）。
- **qb-crypto:104 `attempt to compare table with number`（47 次）**：本服 oxmysql 的 `update` 回调回表，而代码按数字比较；且回调里再调 `MySQL.query.await`（`RefreshCrypto`）会触发 `nested ref call`。改成同步 `update.await` + 行数归一化（table/number 都吃）后再 insert + 刷新。真机：`crypto` 表本来**一直是空的**（因为 insert 分支永远走不到），修完 `qbit` 落库 `worth=5200`，重启后 `104` / `nested ref` / `SCRIPT ERROR` 新增 **0 / 0 / 0**。
- **`qb-crypto` 的 `setcryptoworth` 控制台执行报 null player**：`source=0` 时仍 `TriggerClientEvent`。已加控制台分支（改为打日志），控制台改价可用。
- **`custom-phone → custom-quest:GetAvailableQuests` export 异常**：手机任务列表是读路径，异常直接穿透会让整页空白且刷日志。改为 `pcall` fail-soft（失败返回空列表），真实错误在 `quest_debug=1` 时打印一次。
- **`No such export IsArcEnabled in resource story-engine`**：`T-CityLite.base/resources/[custom]/custom-quest` 的 `callExport` 用 `type(target[method])` 判断导出是否存在，但 FiveM 的 `exports[...]` 是代理表，**索引未注册的导出会直接抛错**，守卫本身成了崩溃点。改为把索引包进 `pcall`（资源没起时安全返回 nil = 跳过检查）。环境侧补 `ensure story-engine`。
- **SonarCloud `C Maintainability Rating on New Code`**：把 8 个 `test_p6*.py` 合并成 `test_p6_agent_stack.py`（共用路径与读取辅助，23 条断言不变），消除跨文件重复样板；覆盖率棘轮随之下调到 259。
- **`police_call_draft` 审批阶段 `unknown field code_fallback`**：服务端回填的 `code_fallback` 在 approve 时会拿存下来的 params 再规范化一次，白名单不认它 → 草稿永远停在 `rejected`。已把该字段纳入归一化白名单。
- **警察序章卡在第一步**：模板里 `reach` 步骤走到 `QuestNodes.ExecuteNode` 时 `_eventMap` 没有 `REACH`，日志出现 `Unknown node type: reach → REACH` 后直接 return —— 客户端拿不到 blip 与触发区，玩家永远走不到第一个点。补 `REACH → quest:client:nodeGoto`（复用既有 blip + SetupReachZone）。
- **`AbandonQuest` 只有注释没有实现**：`quest:server:abandon`、Bus 与手机 `exports['custom-quest']:AbandonQuest` 全部落空（真机日志 `No such export AbandonQuest in resource custom-quest`），玩家卡在坏任务里退不出来。补齐函数（清理节点/释放锁/失效缓存/DB 置 abandoned）并注册导出。
- **步骤类型全覆盖**：`collect` / `custom_event` 登记为 server-only（由 `quest:server:collect` 与外部事件驱动），不再在日志里出现假告警；新增闸门扫全部任务模板，任何未映射类型都会红。
- **文书类动作允许离线目标**：新增 `AgentPolicy.OFFLINE_TARGET_ACTIONS`（`police_warrant_request`、`police_draft_report`），不再要求目标在线（逮捕令本来就是给不在场的人开的）；但 propose 阶段会查 `players` 表，不存在的 citizenid 直接 `citizen_not_found`，不会进审批队列。
- **policy.lua 的 Lua pattern 量化词**：`^[A-Za-z0-9_%-]{1,11}$` 在 Lua 里永远不匹配（pattern 没有 `{n,m}`），导致合法 citizenid 被判非法；改为 `#s` 判长度 + `+` 判字符集。新增闸门禁止 policy 里再出现 `{n,m}`。
- **新增 agent 动作必须接满 policy.lua 四处**（ACTIONS / Normalize / Preview / CheckPolicy）：只接两处会在 propose 阶段静默返回 `unsupported_action`。新增闸门逐动作核对四处。
- **车机游标不出现**：`SetNuiFocus` 是按资源的 —— 栈只能决定谁该有输入，真正按下去必须由拥有页面的资源做。车机的帧现在带 `owner = 'tcity-dashboard'` 并导出 `ApplyFocus`，焦点回到车机页面本身（此前被 set 到了没有 ui_page 的 custom-ui）。
- **车机补齐手机那套输入能力**：方向键换页签、警情列表 ↑↓ 选行 + Enter 设导航、Esc/Backspace 关闭、NUI 就绪后 `RefreshFocus` 握手、以及 250 ms 去抖（反复 restart 后 `RegisterKeyMapping` 重复注册会让一次按键触发两条命令）。
- **车机中控改走交互路径栈**（`custom-ui` 的 `Input.Push/Pop`）：原来是 2025 年的旧写法，自己 `SetNuiFocus`，绕过了焦点仲裁 —— 于是栈非空时那条**每帧屏蔽视角控制**的线程不启动（视角还能转）、keepInput 沿用手机上粘住的 `true`、页面就绪后也不再施一次焦点（游标时有时无）。顺带让 `custom-ui:OpenMenu` 区分「没传 keepInput」与「显式 false」。审查记录见 `docs/client/plans/2026-10-31-dashboard-input-pipeline.md`。
- `tcity-dashboard` 的 `DriveTab.vue` 未使用的 `ref` 导入导致 `vue-tsc` 失败、`npm run build` 过不去。
- **警情通知预算层（P2-2）**：同 `code` 90 秒合并成「（×N）」（第 2、5 条播报，之后每 10 条），非紧急每人 5 秒最多 3 条，`priority ≤ 1` 穿透频率上限，`police_alert_budget 0` 一键回滚。限流原语委托 `core-framework` 的 `RateLimit`（RATE-01），本模块只管业务判断；golden `police_alert_budget` 8 个 case + 闸门 `test_police_alert_budget`。
- **P2 调度总线的现状核对**：`police_incidents` / `police_incident_units` 与建单、状态机、单位附着、同案合并、legacy `policeAlert` shim、手机 911 **都已存在**（蓝图里的 `police_calls` 不该新建）；真正的缺口是车机终端、`custom-crime` 接入、通知预算层、以及 7 个发案来源从未逐个验证。核对文档见 `docs/police/plans/2026-10-31-p2-dispatch-audit.md`。
- **司法链桩测试 `justice_chain`（7 个 case）**：律师通知恰好一次/不叠加/无律师仍建案、刑期被 `MaxSentence` 截断（DB 里绝不出现原始大数）、平民与**离岗警员**立案被拒。

### Fixed
- **调度下发坐标脱敏（AC-P2-02 / D5）**：`broadcastIncidentAlert` 原来把精确 x/y/z 广播给每个在勤警员，等于给开图玩家一个比调度还准的位置；现在按单号稳定偏移到半径 60–95% 的点（黄金角散布），库里仍保留精确坐标。闸门 `test_dispatch_coords` 钉住 payload 不得含原始坐标。
- `T-CityLite.base/resources/[custom]/custom-justice/server/arrest.lua` 只判 `job.name == 'police'`、**不判在岗** —— 离岗警员也能立案并触发律师通知；已补 `onduty == true`（桩测试抓到的真 bug）。

### Added
- **L1 布景层**：站点 120 m 内自动生成 2 名站岗警员（无敌、不持枪）+ 1 辆巡逻车（固定小环线），离站点 260 m 自动收；`/lockdown` 摆 6 锥桶 + 2 路障（服务端复验在岗、一次一组、5 分钟自清）。布景放在客户端：行为 native 只在客户端存在（服务端建 NPC 不会动，`SetEntityAsMissionEntity` 会 nil）。
- **凭据清理**：`MCP_WIRING.md` 的 MySQL 连接串换成掩码；`tools/dev/release_check.py` 重新通过。
- **L3 反应层补齐**：`/pa <文本>` 扩音器喊话（在岗限定、40 m 半径、8 s 冷却、审计只记长度与人次、`police_pa` 可一键关）与 `/backup surround` 包围（两名警员分左右 8 m 站位、转身朝外、车刹住、不碰战斗逻辑）。真机：`police.pa len=25;heard=1`、`backup order=surround applied=1`。
- **L2 后勤·现场化验**：`/sample gsr|drug|blood <案卷ID>` —— 采样立刻写一条证据（`EX-…` 已送检），60 秒后再写**第二条**结果（阳性/阴性，血迹为「DNA 待比对」）。append-only、不动 schema；警官离线只写审计不留孤儿证据。真机 `EX-000001 → EX-000002（阴性）`，审计 `forensic.sample/result`。至此蓝图 §6.2 的 L2 后勤三项（验尸官 / 拖车 / 化验）全部落地。
- **L2 后勤·拖车（方案 A：只拖 NPC 残骸）**：`/tow` 找 40m 内报废的空车，平板车从路网开来、`AttachEntityToEntity` 挂上后拖走并回收。**玩家自己的车由服务端查 `player_vehicles` 拒绝**（`tow.rejected` + 「走扣押流程」提示），不信客户端。名额 `NPCBudget(kind='tow')`、60s 冷却、180s 服务端收车、掉线回收。真机 `TW-1793394142-1`：118m 外生成，90 秒完成，`reason=done`。
- **验尸官的 qb-target 选项**（`Config.UseTarget` 开启时生效）：30 m 内的尸体自动挂上「叫验尸官」，尸体被收走/刷掉后自动 `RemoveTargetEntity`，不会留下对着空气能按的幽灵选项。
- **`/coroner` 命令**：自动找 30m 内最近一具尸体并叫验尸官（附近没尸体时给一条 feed 提示）。调试入口 `police_coroner_dev` 改为只造尸体，叫单必须走正式命令，两条路径不再混在一起。
- **L2 后勤层·验尸官（蓝图 §6.2）**：在岗警察可叫一次验尸官，面包车从**路网**开来（复用支援单位的四档取点），停稳后医生下车、跪 6 秒、**删除尸体**、再开走。名额走 `NPCBudget(kind='coroner')`，每人 60s 冷却，单 180s 未完成由服务端收车并放名额，掉线立即回收；审计三态 `coroner.request / .ended / .rejected`。调试入口 `police_coroner_dev <src>`（convar 默认关、仅控制台）造尸体并走同一条链路。真机：`CR-1793389434-1` 车在 84m 外路网生成，33 秒完成，`reason=done`。

### Changed
- **支援单位只在路网上生成**（玩家反馈「背对大海时会生成在海里」）：去掉偏移回落，候选不合格就按 `spawn_failed` 结束；搜索改为 `strict → relaxed → last → closest` 四档递进（日志带 `tier=`），守住「必须在路网」的硬规则，同时在山地/码头这类地形仍能给支援。顺带修掉三个沉默故障：`GetGroundZFor_3dCoord` 在部分地形恒 false 导致候选全灭、`IsPositionOccupied` 参数语义不一致把 37 个节点全判「被占」（改用 `GetClosestVehicle`）、BOOL 返回 1/0 时被判成假。

### Added
- **L0 无线电层（蓝图 §6.2）**：支援单位派出/到场/撤离时给所有在岗警察播一句 10-code。走手机已有的 `phone:client:systemSpeech`（字幕 + TTS），呼号取 metadata 的 `callsign`（没有则由 citizenid 稳定派生），单人 3s / 全局 2s 双重限流，文案 ≤160 字符且不含坐标/车牌/citizenid；`police_radio_voice` 默认开、可一键关掉。真机三句全响：`radio dispatch → onscene → clear`。
- **警察模块蓝图入库**：`docs/agent/police/BLUEPRINT.md`（施工图）+ `RESEARCH-2026-10.md`（调研定稿）+ v1 存档。蓝图补了 §0.3 实现进度表，并把基线命令从老路径改成本仓库现路径（1221 passed / 14 suites 149 checks）。
- **NPC 支援对齐蓝图 §6.3 配方**：司机加 `SetDriverAbility(0.9)` / `SetDriverAggressiveness(0.1)`；驾驶风格默认改回 `786603`（StopForVehicles/StopAtTrafficLights，可 `police_backup_drive_style 2883621` 回滚抢行档）；新增到场停留上限 `police_backup_onscene_ttl`（默认 120s，交战 `engaged` 即撤销倒计时）；新增「车停稳在 35m 内 2.5 秒就下车」的第三种到场出口，解决玩家在院内/屋内时被看门狗误判 `vehicle_lost`。`SetPedAsCop` 明确不调（原生警察 AI 会绕过「NPC 不打玩家」的默认关），差异记在 `docs/police/architecture/10-backup-v2.md` §3.13。
- **支援单位从路网上开过来了（spawn v3 · P1/P2）**：生成点改为在玩家**后方** 50m 的搜索中心取路网节点，扫 `nth ∈ {1,3,5,8,12,20}` 挑朝向最顺的候选，并用 `CalculateTravelDistanceBetweenPoints` 过滤掉高架/隧道另一侧那种「直线很近、开车不可达」的节点（不可达时驾驶任务会立刻 finished，车原地不动）；生成用节点坐标与节点朝向并 `LoadAllPathNodes(true)`，取不到则回落到旧偏移（`police_backup_spawn_mode=offset` 回滚）。行驶改 >150m 用 `TaskVehicleDriveToCoordLongrange`，驾驶风格切 `2883621`（不闯红灯停），并加「生成后 10s 宽限 + 每 20s 无进展记一次 + 连续 3 次判 `vehicle_lost`」的看门狗。真机四单：节点 43–137m、朝向点积 0.33–1.00，到场 ~10s，`dismount at 17–18m`。
- **开发期后门 `police_backup_dev <serverId> [tier]`**：控制台一行叫一单支援，走同一个 `RequestBackup`（权限/冷却/预算/审计都不跳过），`police_backup_dev_enabled` 默认 0、只接受 source 0。为真机迭代服务：UI 路径要过「开手机 → 直达 App → 逐格走焦点 → Enter」四层，任何一层窗口失焦都会静默失败。真机用它跑出第二单采样 `dismount at 16.9m`。
- **支援单位只在玩家身边下车（spawn v3 · P3）**：到场判定从「距离 ≤20m **或** 超过 30s」改成「距离 ≤20m **且** 车速 <5 m/s」；硬上限提到 90s，到点仍未到就记 `escort_timeout` 结束并释放名额，不再让两名警官从两百米外穿过车流跑过来。客户端日志新增 `dismount at %.1fm` 供验收。真机：`dismount at 14.8m`。
- **支援单位会跟着最近的警官（B3）**：`PickBackupEscort` 在请求时算一次「跟着谁」——优先离请求者最近的
  在勤警官（off-duty 与平民永不入选），没有别人就是请求者自己；结果随阶段条目 `escort_source` 暴露，
  客户端开车与跟随都以它为准、解析不到才回落到请求者。真机单警官 `escort=1`；多警官路径有 4 个 golden 用例，
  真机需第二个在勤账号。
- **支援的滥用防护（B4）**：`police_backup_min_real_cops`（默认 0 关闭）——在勤的**其它**警官数达到阈值时拒绝 NPC 支援（错误码 `police_available`），并写 `backup.denied`（`others`/`threshold`）留痕；off-duty 不计入、请求者自己不计入。golden 3 个用例；真机验了不触发的一侧（单客户端环境），拒绝侧需第二个在勤账号补验。
- **支援指标面板（B5）**：`tools/dev/police_backup_metrics.py` 从 `police_audit` 聚合生成成功率、平均生成耗时、平均存活、异常结束率与结束原因分布，不新增表、不加埋点。真机（6 小时 21 单）：成功率 85.7%、13 单服务端过期（全 `ttl`）、4 单正常结束（`timeout` 3 + `dismissed` 1）、平均存活 133.9 秒、异常 0。
- **支援单位可以指挥了（B2）**：`/backup follow|hold|dismiss` —— 待命会刹停并停掉驾驶/跟随任务（战斗照旧），撤回会回报 `dismissed`（已加入白名单，审计不再记 `unknown`）并走 S8 的开走流程；三条命令只作用于自己名下的单位，服务端寿命与名额不动。agent 侧可走 `adc <src> backup hold`。真机：`order=hold applied=1` → `order=dismiss applied=1` → `retreating (reason=dismissed)` → 审计 `backup.ended | reason=dismissed;live=29`。
- **修 devcmd 白名单的 Lua pattern 坑**：`'^backup (follow|hold|dismiss)$'` 永远匹配不上 —— Lua 的 pattern 没有 `|` 交替（和没有 `{n,m}` 是同一类）。改成三条独立 pattern。
- **支援可按响应级别叫（B1）**：`RequestBackup(source, tier)` 支持 1（1 车 2 人）/ 2（2 车 4 人，用满每人 2 槽），一次请求拆成 `tier` 个独立单位（各自 `requestId`/槽/阶段），任一单位抢不到槽就整组回滚；`tier` 由服务端夹取到 1–2，MDT 可传 `params.tier`，缺省吃 `police_backup_default_tier`（默认 1）；客户端一次收到整组 id 并错开停车位生成。真机：两单 `BU-…-1`/`BU-…-2` 同时 `onscene`，各 `entities=3`。
- **支援单位到点会开走，不再原地消失（S8）**：服务端 `BackupEnd` 到达后，如果请求者还在附近，单位改为 `SetPedIntoVehicle` 塞回座位 + `TaskVehicleDriveWander` 开走，交给引擎自然回收（`SetEntityAsNoLongerNeeded`）；车没了 / 距玩家 >220m / 已不在画面 / 15s 硬超时任一命中才真正删除。玩家跑远（>150m）时仍然即时散场。真机：`retreating` → `cleaned` 间隔 13.6s（S8 之前是 0）。
- **支援单位知道自己在哪个实例、该打谁（S7）**：阶段投影新增 `bucket`（请求者当时的 routing bucket）——支援单位刻意**不做桶隔离**，因为 bucket 是实例化工具而非可见性范围，隔离会把请求者自己关进单人世界；请求者在私有实例时，客户端建出来的实体天然只在该实例可见。新增服务端权威的通缉目标投影 `GetBackupTargets` 与 `police:server:backupTargets`（必须持有自己的活动单位、每 source 3 秒限流、只回 `net_id/distance/stars`，无坐标无身份），客户端据此让 NPC 优先交战通缉玩家；开关 `police_backup_engage_wanted` 默认 0。
- **支援单位不再无条件重发任务（S5）**：改用 `GetScriptTaskStatus` 判定——正在执行（1）只按心跳兜底（车 5s / 跟随 6s），空闲（3）、已完成（7）与不可知（0/nil，含未知任务哈希）立刻重发；判定本身是 P0 纯函数 `BackupContract.ShouldRetask`，四态都有 golden 用例。主循环按状态自适应 500ms / 1000ms。真机：`spawning→enroute→onscene` 7 秒走完，之后 49 秒稳定停在 `onscene entities=3`，车与两名 NPC 正常到场。
- **客户端不再自己算支援寿命（S4）**：`police_backup_v2` 打开时（默认）寿命由服务端持有，客户端 5 分钟自计时被 `serverOwnsLifetime()` 守卫；只有回滚（`0`）时才保留自清能力。新增闸门 `test_backup_lifetime_owner.py`（客户端守卫、300s/5s/10s 数字、sweep 挂 `onResourceStart`、先收再放），其中一条带变异冒烟用例。真机：TTL 压到 20s 时，`police_backup_v2 0` 下单位活到 49s 仍未收；切回 `1` 后 12s 内 `ending=true`、18s 内释放。
- **支援单位由服务端统一收尾（S3）**：10 秒一轮的 `BackupSweep` 按 `expires_at`（默认 300s，`police_backup_ttl` 可覆盖用于测试）与阶段 ack 超时（`requested` 10s / `spawning` 15s）判过期；到点**先发 `police:client:BackupEnd` 让客户端删车删人，宽限 5 秒再释放名额**，并把 `backup.expired`（`phase`/`why`/`live`）写进审计。名额回收从此不依赖客户端是否还活着；`setr police_backup_v2 0` 可整体回滚。真机：`ending=true` → 释放，客户端日志 `cleaned (reason=expired)`，审计 `phase=enroute;why=ttl;live=38`。
- **NPC 支援可见阶段（S2）**：服务端新增阶段表与 `police:server:backupAck`（三重校验：预算归属 / 阶段白名单 / 只向前，越权与倒退采样写 `backup.ack_rejected`）；客户端在收到事件、车与两人到手、下车到场、首次交战四处上报。`enroute` 写 `backup.spawned`（entities + 耗时）、首次 `engaged` 写 `backup.engaged`；`GetBackupState()` 导出与控制台`police_backup_state` 给出不含身份字段的只读投影。真机：`phase` 从 `requested` 推进到 `onscene`，5 分钟到点以 `reason=timeout;live=300` 结束并从投影消失。
- **真机验证工具化**：`tools/dev/fivem_console.py`（经 MCP→RCON 发控制台命令与按键，绕开本机"直连 RCON 被关连接 / Windows 控制台不吃管道输入 / PowerShell 注入到不了游戏"三个坑）与 `tools/dev/police_live_probe.py`（一次打印客户端 phone 状态、资源数与审计尾巴）。配套 `docs/engineering/LIVE_VERIFICATION.md` 写明起栈顺序、UI 驱动回路（adc + phoneui + press_key + 焦点读回）、三层断言与六条"别做"，并规定 Claude Code 只用于联网调研与有文件预算的评审。
- **修「手机关不掉、WASD 不动」**：完全接管（`keepInput=false`）后游戏不再处理输入，
  `IsRawKeyDown` 也读不到键 —— 键盘实际归 CEF。所以 **M 键改由 NUI 处理**（Esc 亦然），
  Lua 的原始按键只在 `keepInput=1` 模式下生效。此前 M 关不掉 → 手机一直开着 → 输入一直被接管，
  表现出来就是「WASD 不能动」。
- **修「手机开着没有游标、点不动」**：`SetNuiFocus` 是**按资源**的 —— 在 custom-ui（没有 ui_page）里调用，
  等于把焦点交给一个不存在的页面，手机页面因此收不到任何鼠标事件（背包/目标盘却正常）。
  现在栈只做决定，按焦点通过 `exports[owner]:ApplyFocus(...)` 回调**拥有页面的资源**。
  真机验证：自绘光标跟着鼠标走、点击 App 图标能进入。
- **手机默认改为完全接管输入**（`phone_keep_input` 默认 0）：真机实测 keepInput=true 时 OS 游标被钉在屏幕角落、既看不见也动不了；关掉后 GTA 把鼠标交出来，游标恢复、键盘导航照常（原始按键不受影响）。代价是手机开着不能走路；想边走边看就 `setr phone_keep_input 1`。
- **输入分层落地（S2+S3）**：手机不再自己 `SetNuiFocus`，焦点与控制屏蔽交给 custom-ui 的交互路径栈；打开 App 压一层 `phone:<app>`、聚焦输入框再压一层 `phone:text`，Esc/Backspace 逐层退出，退到底再按 Esc 就是 GTA 原生暂停菜单。`nav.lua` **不再禁用 172-175**（那正好会点亮转向灯），`indicators.lua` / `cruise.lua` 改为先问 `IsTaken()`。
- **`custom-ui` 增加交互路径栈**（`Push/Pop/Top/Path/IsTaken/Owns/ResetInput`）：世界 → 手机 → App → 输入框每一层是一帧，**只有栈顶拥有键盘**；栈顶声明 `allow` 白名单（放行走路等），其余控制整组屏蔽；栈空时立刻把输入还给游戏 —— 所以 Esc 每次退一层，退到底再按一次就是 GTA 原生暂停菜单。这是把“每处各自 SetNuiFocus + IsNuiFocused()”换成单一仲裁者的第一步（仅新增 API，未迁移资源）。
- **修「键盘只有 agent 能用、玩家按没反应」**：手机开着时 `KeepInput(true)` 让游戏继续吃硬件按键，CEF 收不到、`IsControlJustPressed(172-175)` 也读不到（注入的按键反而能到 CEF，所以此前一直没发现）。键盘改读 `IsRawKeyDown(VK)`（跟 GTA 控制映射无关），手柄仍走控制轮询；同一帧两边都命中时只走原始按键，不会一次挪两格。Tab/PageUp/PageDown/Home/End 也一并纳管。
- **键盘导航补翻页与滚动**：`PageUp`/`PageDown` 一次 7 格、`Home`/`End` 跳首尾；`End` 会留在焦点所在的可滚容器里（真机在 MDT 列表按 End 会跳到壳层「回桌面」）。输入框里这些键仍归输入框自己。滚动容器实测是 `T-CityLite.base/resources/[custom]/custom-phone/web/src` 下的 `.pane`。
- **修 `adc` 的 911 白名单永远不匹配**：Lua 的 pattern 没有 `{n,m}`，`'^911 [^%c;]{1,80}$'` 写成了正则的形状，结果 911 全部被拒（只回 `not_allowed`）。改成 `+` 并在代码里限长 96。
- **切 App 时回吐页面 id**：切到不报状态的 App（Settings、Banking 等）时状态里还挂着上一个 App（真机：屏幕是 Settings，`/live/clients` 说 police_mdt）。现在 `activeApp` 一变就报，回桌面报空。
- **键盘/手柄操作补完：Tab 进出输入框 + 焦点可读**。方向键和 Enter 在输入框里属于输入框自己（移光标 / 提交），所以 Tab = 下一个、Shift+Tab = 上一个，且在处理可编辑元素之前拦截；每次焦点变化都把标签回吐给 Lua（`aria-label` → 文字 → 标签名），`/live/clients` 的 `phone.focus` 现在能读到「焦点停在哪个控件」，agent 不用再盲按方向键（真机第一次盲按 Enter 落到的是"分享"）。
- **手机/平板可以用键盘和手柄操作了**：方向键移焦点、Enter 确认、Backspace 返回上一级；焦点环 + 开屏自动聚焦。键盘走 NUI 的 `keydown`（Tab 被 GTA 占了、方向键有效），手柄走 Lua 轮询 GTA 控制后发 `phone:nav` —— 两条腿落到同一组动作（`T-CityLite.base/resources/[custom]/custom-phone/web/src/core/nav.ts`），为手柄正式适配留好了底层。真机：Down×2 + Enter 打开 Contacts。
- **MDT 也回吐页状态**：警用终端在调度/人车/文书/案件/我的之间切换、以及选中某条警情时上报 `{app:'police_mdt', tab:<page>, selected:<警情 id>}`。只报 id，不报搜索词与案卷正文；离开调度页后 selected 自动清空，免得让人以为他还在看那条警情。
- **agent 能确定性地打开手机里的某个 App**：`/phoneui <app>`（`setr phone_ui_nav "1"` 才生效，生产默认关）→ `phone:navigate` 消息 → NUI 切页。起因是真机上 OS 光标被 GTA 锁在屏幕右下角（`SetCursorPos` 被每帧覆盖，`GetCursorPos` 恒为 2559,1439），合成点击永远落在手机外——这条通道是鼠标点不进去时的替代路径。
- **agent 能读客户端 UI 状态了**。`custom-phone` 导出 `GetUiState()`（`open` / `surface` / `focused` / `keep_input` / `focus_owner` / `nui_focus_native`，只回枚举与布尔），`custom-agent-client` 每 5s 推一份快照，服务端白名单 + 夹紧 + 1s/源限流 + 15s 过期 + 掉线清理，`custom-director` 暴露 `GET /agent/v1/live/clients[/{citizenid}]` 与 `/live/server`，配两个只读工具 `get_client_state` / `get_server_state`（registry 1.7.0，41 tools）。快照是自述，永不作为权限或策略输入。
- **App 停在哪一页也能问到了**。任务 App 通过 `fetchNui('appState')` 回吐 `{app, tab, selected}`（三个短 token，白名单校验），手机侧存起来放进 `GetUiState().app`，服务端再消毒一次。MDT/银行尚未接，`app` 是可选字段。
- **手机和平板是同一台设备的两个 surface**。`PhoneShell` 换成 `DeviceShell`，`surface` 只是一个 prop：外壳差异（尺寸/圆角/刘海/状态栏）全部由 `presetOf()` 驱动，业务组件不知道自己长在什么设备上。形态判定唯一源在客户端 Lua（客户端 core/surface_rules.lua 的纯函数 Decide()，优先级为入口 > 来电 > 载具 > 玩家偏好 > 默认手机）——判定不放 NUI，因为 `keepInput` 是 focus 的一部分，必须在打开这一刻定下来。平板打开时逐帧 `DisableControlAction(30–35)` 锁移动（不用 `FreezeEntityPosition`/`SetPlayerControl(false)` 这类粘性状态），六条失败出口统一收敛到 `Surface.Reset() + DeviceLock.End()`。
- **平板的排布靠 pane 契约，不靠 surface 身份**。新增 core/panes.ts + AppSurface.svelte + Pane.svelte：按容器宽度决定单栏还是分栏，窄了就按 `drill`/`flow` 降级。PoliceMDT 三栏（单位 300 / 接警 348 / 详情 344），Messages 用 drill、Quests 用 flow；手机形态保持原有单屏，详情栏只在 grid 渲染——手机上不该在 DOM 里多留一份重复按钮。
- **三道架构闸门**（`tests/architecture/test_surface_contracts.py`）：禁止 `Tablet*/Phone*App.svelte` 这类分叉组件（含改名克隆的相似度检查）、用了 AppSurface 的 app 必须有 `contracts/<id>.panes.ts` 且 pane id 与 `<Pane id="...">` 双向相等、`TABLET_GRANTS` 必须为空（平板不许新增任何查询/动作/字段）、服务端脚本不许读 `surface`。每条闸门自带反向注入：先扫真仓库要求干净，再往 tmp 写坏形状断言变红。
- **`/tablet` 与 `/phone` 命令**（带控制台 `tcity_tablet <id>` 分支）。以前平板只有设计稿，没有任何入口；已经打开时切换会以 `reason=switch` 关闭再重开，当前 app 不丢。

### Fixed
- **平板偶尔只剩一栏**：`AppSurface` 的 `width` 初始为 0、布局据此退回 `stack`，要等 `ResizeObserver` 第一次回调才切成两栏——快机器看不出来，慢机器（CI）上就是「平板只有列表」。现在 `onMount` 里先用 `getBoundingClientRect()` 同步量一次，之后仍由 observer 跟踪变化。
- **读到的状态总是慢半拍**：状态快照以前只有 5s 心跳，按完 M 立刻去查还是旧值。现在 `custom-phone` 在开/关/换页/`/phonefix` 时广播 `phone:client:stateChanged`，`custom-agent-client` 收到就立刻采一份推给服务端，心跳降级为兜底（15s 过期仍生效）；服务端每源限流从 1s 放宽到 250ms，否则事件推送会被心跳挤掉。真机：按 M 后 ~1s 内 `open` 翻转，之前最多要等 5s。
- **按 M 有时开、有时不开**：`keepInput=true` 让同一次按键同时到达游戏与 CEF —— 游戏（`RegisterKeyMapping`）打开手机，同一帧 NUI 的 `window.keydown('m')` 又把它关掉。密钥只有一个主人：`m/M` 归 Lua，NUI 只留 `Escape` 与自己独占的鼠标手势。真机复验：开→（4.5s 后按）关，`/live/clients` 的 `open` 与截图一致。
- **按 M 关不掉手机**（真机症状：点一次闪一下、再点也关不掉）。两个原因叠在一起：① `RegisterCommand('phone')` 被注册了两次，后一个（`/phone` 强制形态，已经开着就直接 `return`）覆盖了前一个 toggle——同名命令后注册者胜；② 剩下那条 toggle 用 `IsNuiFocused()` 判断"焦点还在不在"，而这个原生在本 build **恒 false**（61 条 focus 遥测里 0 条 true），于是每次"关闭"都走进"复位重开"分支。现在开关只看 `Surface.IsOpen()`、焦点只看 `PhoneFocus.State()`，原生降级为诊断字段 `nui_focus_native`；`/phone [phone|tablet]` 保留强制形态语义，去抖初值改为 `-300ms` 以免资源刚起第一下被吞。无头用例复现了原生撒谎的场景（`env.nui.focus_native_lies`）。
- **窗口大不等于要平板**。旧规则「宽 ≥ 900 且横向 → 平板」在 FiveM 里等于「每次按 M 都锁住移动」，因为 NUI 视口永远是整个游戏窗口（1080p 起）。已删除该规则：平板由意图（入口/偏好）触发，视口只保留一个降级作用——玩家要平板但窗口真装不下时退回手机。
- **`player_not_found` 曾经是时序，不是事实**。手机的 NUI 早于服务端加载玩家就绪，MDT 在这个空窗期查询会拿到"查无此人"，界面显示"角色尚未加载"。现在服务端回 `player_not_ready`，传输层只对这一码重试一次（1.2 秒），设备在角色加载完成前不打开（登录事件 / `SetPlayerData` / 每秒轮询三路判定）。
- **ESC 关闭触发两次 `closePhone`**：`DeviceShell` 与 `App.svelte` 各有一份 keydown。删掉外壳的监听，`closePhone()` 改为幂等。
- **MDT 详情栏显示 citizenid**（`COP002`）：新增 `callsignOf()`，显示呼号 `2-Lincoln-30`，无映射时回退 id 保证老数据可读。
- **NUI 首屏瓦片等待 5 秒不够**：慢机器上首次 `getPhoneApps` 会 `AbortError`，首页短暂为空。瓦片等待改 10 秒。

- **报警终于会变成一条警情**。`police:server:policeAlert`（qb-drugs / storerobbery / houserobbery / custom-vehicles 的热接线报警）与 `police:server:autoAlert`（系统警报）以前只给在勤警察发一条通知、在地图上插个旗就结束了——MDT 的警情板上什么都没有，于是"被抢了报警"在系统里等于没发生：不能派单、不能清场、不留记录、进不了统计。两条路径现在都走 `PoliceDispatch.CreateIncident`（系统来源走 `CreateIncidentFromSystem`），通知由建单统一发出，地图插旗与提示音仍然保留。
- **通知标题带警情单号**（`#38 911: 有人持枪抢店`）。以前手机上的"有人报警"和板上哪一行对不上，只能靠猜。
- **重复报警会并进同一单**：同 code、同地点 60 米内、5 分钟内的报警不再新建行，只刷新 `last_activity_at`，并且不再二次通知——一次抢劫被五个人报警不该变成五条单、响五遍。
- **手机里的 911 是真的入口了**。以前「热线」页的 911 只是一段拨号动画，真正的报警只有聊天命令 `/911`，新玩家不可能知道。现在热线页有报警卡片（输入一句原因 → 拨 911），服务端 `phone:server:report911` 做限流与清洗后调用 custom-police 建单，并把警情单号回显给玩家。
- **MDT 不再直接印 ISO 原文**：警情时间统一成 `HH:MM · 3 分钟前`（`created_at` 是 DB 的 `2026-10-26T09:43:42.000Z`，以前原样贴在板上）。

- **建单即投影：地图标记现在由建单统一发出**。以前地图插旗是各个报警处理器自己广播的，于是控制台派单、系统建单（`/911p`、车牌雷达）在板上看得见、地图上找不到。现在 `projectIncident` 是唯一发送点：任何来源建出一张单，在勤警察同时收到手机通知（带单号）+ 屏幕一句话 + 提示音 + 临时地图标记，合并的重复报警则一次都不响。`/911p` 和车牌雷达也一并改成建单（以前完全进不了警情板），NPC callout 复用同一条投影，通知也开始带单号。

- **MDT 点「前往」现在会画导航路线**：以前只把状态改成「前往中」，坐标得自己从板子上抄。现在按下「前往」就把现场画成一条带距离的 GPS 路线（画法与任务引导一致：route blip + 距离 + 路点），点「到场」时自动收掉，换目标时先清上一条，资源停止时也清。没有坐标的老单据（NPC 之前的单）只改状态、不领路。
- **警情全生命周期设计稿**（docs/server-design/10）：复核确认「前往/到场/清场只有下一个能点、只有被派遣者能点」三条约束一条都没落地——open 状态点「前往」必然 invalid_transition、清场不建档（police_cases 一直没被写过）、disposition 前端硬编码、多单位状态被 markIncidentUnits 一把刷。设计给出：allowed_actions 由服务端下发（判定与执行同源）、primary/support 单位模型与进度派生、清场 = 清场命令 + 归档（disposition 四选一 + case_id），并排入 P5-1..P5-4。

- **警情生命周期设计改成「自动结算 + 两个按钮」**（docs/server-design/10 v2）：到场不该由人点——坐标就在引擎里，让玩家汇报"我到了"既多一步又能造假。现在「前往」= 单人申领（assign + enroute + 自动领路一步到位），「到场」删除、改为客户端检测 30 米 + nonce + 服务端用 ped 坐标复算后自动结算，「清场」只在到场后出现并归档成案卷。文档补了状态机 / 时序 / ER 三张 UML 与端到端流程表，另附单文件前端 demo（docs/server-design/assets/10-mdt-lifecycle-demo.html），申领→自动路线→自动到场→清场归档全流程可点。

- **P5-1 落地：警情到场不再由玩家点按钮**。「前往」现在是一次申领（assign + enroute + 服务端推路线，一步到位），「到场」按钮删除——客户端每秒检测 30 米内（垂直 15 米、连续 2 次、离开 45 米重置），命中后申请一次性 nonce，服务端用 ped 坐标复算（35 米）才结算；自动检测失灵时菜单里有「补录到场」（≤100 米，审计标 manual）。GetIncidents 现在每行下发 units / primary / allowed_actions，MDT 的按钮由服务端判定渲染（不可点时置灰并给中文原因），前端不再复制状态机。新增能力位 incident.claim / incident.arrive / incident.clear，几何参数集中在 shared/policy.lua 的 PoliceIncidentRules（客户端与服务端同一份）。

- **p0 拆分（纯搬迁，零行为变化）**。1224 行 → 5 个模块：`p0.lua`（常量 + SM-02 转移表 + 共享助手）、`p0_units.lua`（值班/状态/指派/进度派生）、`p0_lifecycle.lua`（申领/到场/判定表/路线）、`p0_incidents.lua`（建单/合并/投影/状态机/清扫/911）、`p0_read.lua`（警情板/公民/车辆/审计）。模块之间不共享 local：共享名挂 `P.internal`，各模块按名字绑定、调用时解析，跨模块调用写成同名懒包装，所以函数体一字未改。每个模块自己登记自己的 exports（谁实现谁登记），否则 FIT-04 查不到实现体会变成装饰。附带把 `ArriveIncident` 里那条裸 `UPDATE police_units` 收进 `arriveUnitRow`（单位表现在只在 `p0_units.lua` 写）。闸门同步跟上：单写者规则从"单个文件"改成"p0 家族的固定文件集合"，导出/网络事件/number-budget 白名单路径更新，导出契约扫描器修了两个真 bug（单行函数体会吞掉后面的行；同名转发壳会覆盖实现，导致"委派给写者"被误判成"什么都没写"）。测试侧新增 `tests/p0_sources.py`，块查找不再跨模块。

- **手机 / 平板统一为一台设备的两种形态**。手机和平板不再是两台设备：一个 `DeviceShell(surface)`、一份 app 清单、一套权限。形态由客户端 Lua 的 `SurfaceRules.Decide()` 决定（入口 > 来电 > 载具 > 玩家偏好 > 窗口 ≥900×560 且横向 > 默认手机），因为 `keepInput` 属于 focus，必须在打开那一刻定下来；UI 只照做，不自己嗅探窗口。同一时刻只有一个面在前台（`Surface` 里一个 `current`，不是两个布尔）。**平板锁移动**用逐帧 `DisableControlAction`（30–35），不用 `SetPlayerControl`/`FreezeEntityPosition` 那种粘性状态——粘性状态加一次异常就是永久钉在原地。关闭路径（用户、M 键、切换、ack 超时、`/phonefix`、资源停止）统一走 `Surface.Reset() + DeviceLock.End()`。

- **pane 契约：一个 app 一个组件，两种排布**。`panes.ts` 的 `definePanes` + `AppSurface`（ResizeObserver 测容器宽度）+ `Pane`，排布只由**宽度**决定，不读 surface 身份。首批三个：警用终端（三栏，详情栏只在平板渲染，行内「前往/清场」保留——巡逻时一击不能变两击）、Messages（drill，手机二选一/平板并存，且不自动选会话，因为那会 `markMessagesRead` 把未读清掉）、任务（flow，手机不动、平板加详情栏并收窄列表）。其余 12 个 app 有意不加栏。

- **三道闸门守住"不慢慢长成两个产品"**：① 禁止分叉组件（`*Tablet.svelte` 或相似度 ≥0.9 的改名副本）② 用 `AppSurface` 的 app 必须有 pane 契约且与 DOM 的 `data-pane` 双向相等、`TABLET_GRANTS` 必须为空 ③ 服务端不许读 `surface`、app 不许自己判断形态。三条各自带反向注入（往 tmp 目录写坏形状 → 必须红），所以没有推高未证明预算。NUI 另加 6 个场景，含 parity：同一交互在两种形态下发出的 `appQuery/appAction` 集合必须完全相等。

### Added
- `custom-police` 新增导出 `CreateIncidentFromSystem(createdBy, data)`：给没有玩家 source 的系统来源建单，与玩家路径共用去重、审计与通知。`CreateIncident` 在导出契约里登记为 civilian_entry（平民 911 必须人人可调）。


### Fixed
- **通知的时间不再显示成 NaN:NaN**。`new Date(v).getHours()` 这种写法被复制了四份（通知托盘 / 城市动态 / 短信 / 帮派频道），只要字段缺失或是对象就直接印出 "NaN:NaN"——玩家会以为手机坏了。现在统一走 `utils/time.formatClock`：接受 Date、秒/毫秒时间戳、ISO、MySQL 的 "YYYY-MM-DD HH:MM:SS"，解析不出来回退成 `--:--`，并**只在第一次**遇到坏值时打一条带原始值的 warn（下次再出现，控制台会直接点名是谁）。NUI 新增一条场景守住它：一条有效时间戳 + 一条缺失时间戳，界面必须出现 HH:MM、出现 `--:--`、且整页不含 NaN。


### Changed
- **警察 NPC 支援：结束原因与结束审计（SM-06 v2 切片 S1）**：客户端 8 处清理与 5 处生成失败路径
  现在都带原因（`timeout/dead/left/resource_stop/spawn_failed/vehicle_lost/no_alive_ped`），
  服务端用 T-CityLite.base/resources/[custom]/custom-police/shared/backup_contract.lua 的白名单归一（白名单外记 `unknown`），并写
  `backup.ended` 审计（含 `live=` 存活秒数）。之前只有 `backup.request`，"支援为什么结束"无从统计。
- **golden runner 修正**：用例只回 `{ results, failed }` 时 runner 以前不看 `failed`，
  这类文件里的检查**永远通过**。现在 `failed > 0` 也算红，并因此暴露并修掉了
  `police_system` 的 3 条失效检查（缺 `PoliceAudit`、两条对已重构 `AssignUnit` 的 SQL 断言）。
- **手机改成"鼠标优先"的焦点模型**：开屏与换 App 都不预设键盘焦点（无蓝框/无标签/无键位提示），
  第一次按方向键或 Tab 才出现焦点，且不论方向都从第一个 App（Phone Dialer）开始；
  无焦点时 Enter 不做任何事。焦点标签与键位提示抬到 Dock 上方，不再压住图标。
- **手机输入修复（真机四连）**：方向键一次挪两格（CEF 与 Lua 双处理 → 开屏消息带 `lua_owns_keys`，
  键盘只留一个主人）、按 M 要两次才开（开屏那一帧已按住的键被当成新边沿）、
  点一下手机就关机（遮罩点击不再关闭 + 3px 侧键不再可点可聚焦）、界面很卡
  （`.glass-effect` 去掉 `backdrop-filter: blur(20px)`，改半透明渐变）。
  另修 City Feed 在 `feed` 缺失时 `feedList.length` 抛错导致白屏。
- **手机默认改为「边走边看」**（`phone_keep_input` 默认 1）：手机开着也能走路，键盘走 Lua 原始按键（方向/Tab/Enter/Backspace/Esc/M）。
  代价是引擎会把 OS 游标钉在屏幕角落，默认模式下没有鼠标指针；想要游标就 `setr phone_keep_input 0`（完全接管）。
- **手机任务列表只摆"现在能接的"**。需求清单摊开之后反而变成噪音：一张吃不到的菜单对玩家没价值。不可接的任务不再出现在列表里（数据仍在服务端，`/listquests` 与控制台诊断照旧能看到全部）。
- **需求清单只显示真正有约束力的项**。`min_police = 0`、`cooldown_hours = 0` 这类"没门槛"的声明不再渲染成"在勤警力 ≥ 0（当前 0）"——之前 18 条剧情任务就是靠这种废话凑出一行。

### Fixed
- **已通关的剧情线仍显示"可接"**。`TriggerQuest` 的 4c 门控一直拦着"已完成的剧情线"（每轮只能玩一遍），但列表层不查，于是 18 条带 `story_arc` 的任务通关后照样出现在可接列表里、点下去才被拒。现在通关即从列表消失，需求文案写明"每轮只能玩一遍"；arc 被 DLC 开关关掉时也会如实显示"暂未开放"。


### Added
- **任务需求逐条摆出来了，不再是一句 "You do not meet the requirements"**。手机里每条任务现在带一份 `requirements`：身份/职业/资历、在勤警力（含当前人数）、执照、剧情线前置、剧情抉择、冷却，每条都标注是否满足；未满足的单独标红，被拒原因取"第一条不满足的"那句人话。
- **补上两个以前完全没检查的准入条件**：`conditions.prerequisite_arc`（要先走完某条剧情线）和 `conditions.player_choices`（要先做出某个剧情选择）。TriggerQuest 会拒这两类，但 availability 层之前不查——于是在手机上看是"可接"、点下去被拒。涉及 9 条任务（cartel/police/civilian 的第四章分支）。


### Added
- **任务奖励发放现在有一行可核对的控制台审计**。`QuestRewards.GrantRewards` 成功后只往 `custom-logs`（Discord webhook）发一条审计；没配 webhook 时，玩家说"奖励没到"本地完全无从核对——日志里只有失败会打印。现在成功也打一行 `[quest-rewards] 💰 玩家 (citizenid) quest=... → $6000 (bank), item xN, rep +80`，一次任务测试结束就能对着日志确认发了什么。


### Fixed
- **重复启动的代价是一次 licence 配额：`start.sh` 现在有单实例锁**。今天修 systemd 时留下过一个 screen 残留进程，之后 systemd 的四次启动全部先通过 licence 校验、再在绑定 30120 时失败——那四次校验把 429 限流重新打了回来，服务被启动限流判 `failed`。现在 `start.sh` 用 `flock` 抢锁，第二个实例在启动二进制之前就被挡住并告诉你去停谁。
- **自检把 429 说成人话**：日志里出现 `HTTP 429` 时，`healthcheck.py` 直接报"Cfx.re 的 license 校验返回了 429（启动太快太多次）：停机等 20-30 分钟再起，期间每次尝试都会续命限流"，而不是只报"资源 0 个 / 标记缺失"让人去猜。

### Added
- **自检只看最后一次启动**：systemd 的日志是追加的，上一次崩溃留下的 `SCRIPT ERROR` 会让之后每次自检都红，人就开始忽略它。现在从最后一条启动横幅开始解析（上次的报错不算，这次的必须算）。


### Fixed
- **systemd 单元会让崩溃循环无限重试，把自己锁死在外部限流里**。实测：一次 Cfx.re license 429 之后，`Restart=always` + `RestartSec=5` 在半小时内重启了 **323 次**，每次都去打一次 license 校验——"等一会儿就好"的限流被续成了死锁。现在单元文件带 `StartLimitIntervalSec=300` + `StartLimitBurst=5`（5 次 / 5 分钟后 systemd 放弃并进入 failed，等人来看），`RestartSec` 放宽到 10 秒；`install_service.py` 的校验器把"缺启动限流"和"限流额度太小"都判为坏单元（反向用例：删掉 `StartLimitBurst`、改成 `StartLimitBurst=1` 都必须被拒）。

### Added
- **任务 App：30 个任务模板第一次有了玩家入口**。此前 `T-CityLite.base/resources/[custom]/custom-quest` 的 14,903 行与 `config/quests/` 下 30 个模板（平民/警察/卡特尔/物流/矿业…）只有 `custom-director` 的 agent 动作和 e2e 测试能触发，玩家在游戏里根本接不到任务。
  - custom-quest/server/quest_availability.lua：只读的「这个玩家现在能接什么」计算层，同步检查职业标签 / 在勤警力 / 执照 / 重复接取 / 冷却，五种原因码可区分；依赖资源缺失时与 `TriggerQuest` 同样采取宽松策略，不会把全部任务藏起来。**接取权威仍在 `quest_manager.TriggerQuest`**，这里算错最多是显示错，不会让玩家凭空接到任务。
  - 新增导出 `GetAvailableQuests(source)` / `GetQuestDetail(source, questId)`；详情只给步骤标题与类型，不暴露坐标等执行细节。
  - custom-phone/server/apps/quests.lua：注册 `quests` App（对所有职业可见，平民也有平民线）。`quest_id` 由客户端提供，所以在这一层先清洗（≤64 字符、`[A-Za-z0-9_]`），非法 id **不会**下沉到 custom-quest；接取/放弃走 `TriggerQuest`/`AbandonQuest`，被拒时把下游给玩家的原句带回 UI。
  - web/src/apps/Quests.svelte + core/appRegistry.ts：可接/进行中两个页签；不可接的任务**照样显示**并写明原因（"Not enough officers on duty"），而不是从列表里消失。没有专属组件的 App 仍然回退到 `DynamicApp`。
  - `/listquests` 支持控制台调用（`source == 0` 时直接 print）：运维在服务器上就能确认模板加载了多少条，而不是拿到 `native Argument at index 1 was null`
  - 启动自证：`T-CityLite.base/resources/[custom]/custom-quest` 导出注册后打印「手机任务入口已就绪」，手机 App 注册后打印「quests app registered」；`tools/ops/healthcheck.py` 的启动标记从 3 条扩到 5 条 —— 否则「入口挂了」和「入口没写」在日志上长得一模一样
  - 一条**跨资源导出调用约定**的回归：`exports['res']:Method(a)` 的第一个参数是 proxy 自己，少传 self 会静默把 `source` 当成 tags、把 tags 丢成 nil（真实表现是"所有带标签的任务都不可接"，而只看返回值的测试仍然全绿）。现已断言导出收到的参数各就各位，并做过去掉 self 必须变红的反向校验
  - 测试：`test_quest_availability.py`（lua5.4 真跑模块，5 种不满足条件逐个要求被拒）、`test_quest_phone_app.py`（注册契约 + 边界清洗，非法 id 时下游调用计数必须为 0）、`test_quest_entrypoint.py`（接线闸门，反向禁止手机层出现 `MySQL`/`QuestDB`/`QuestManager` 等旁路）、NUI 2 个新场景（列表渲染 + 点接取真的发 `appAction` 并显示下游拒绝原因）
- **P0 运维基础设施：服务器现在会自己起来、自己备份、自己体检**（见 `docs/ops/RUNBOOK.md`）
  - `tools/ops/healthcheck.py`：把「84 资源 / 0 SCRIPT ERROR / 三条启动标记 / 74 张表」从人眼判断变成一条命令的退出码，`--json` 供 agent 消费；失败项每句都能照着修，而不是只说 failed
  - `tools/ops/backup_db.py`：每日 `mysqldump` + 保留策略。口令从 `server.cfg` 读、经 `MYSQL_PWD` 传给子进程（不进命令行，`ps` 看不到）；`mysqldump` 非 0 或产出 0 字节都判失败并删掉半截文件，避免 cron 里静默成功；已装 `0 4 * * *` 定时任务，并用「导入临时库」验证过 74 张表可恢复
  - `tools/ops/persistence_check.py`：重启前后快照对比。**实测纠正了一个认知错误**：玩家背包在 `players.inventory`，不在 `inventories` 表里（后者存的是后备箱/公寓/组织仓库，键是 `glovebox-XXX` 而不是 citizenid）
  - `tools/ops/install_service.py` + `tools/ops/tcity.service`：systemd 守护，`Restart=always`、控制台进 `/var/log/tcity/console.log`；安装前先校验（缺 `[Install]`、`Restart=no`、`ExecStart` 指向不存在脚本、`User=root` 都会被拒）
  - 四个工具各配架构闸门：`tests/architecture/test_ops_healthcheck.py`、`tests/architecture/test_ops_backup.py`、`tests/architecture/test_ops_persistence.py`、`tests/architecture/test_ops_service_unit.py`，**每条规则都带反向校验**（抽掉标记 / 破坏单元文件 / 伪造空 dump 都必须被抓到）
- **`docs/ops/RUNBOOK.md`**：启停（systemd 与 screen 两种）、自检、备份与恢复、持久化回归、排障速查、工具一览
- 值班警察在 25 米内能看到**地面证据**落点提示：弹壳（红）/ 血迹（暗红）/ 指纹（青）各一根细柱 + `▼ 标签 · 8.0m` 浮字（平民与下班看不到；拾取流程不变，仍是 1.5 米内按 ~g~G~s~ 且要有空证据袋）。原生玩法只有手电照到才浮出文字，实测结果是「地上有东西但没人发现」；三种证据的发现门槛完全一样，所以一起加
- 客户端 MCP 测试 harness：Windows FiveM Legacy + `fivem-mcp-server`，经 FXServer 30120 HTTP 轮询桥接；提供 `client_command` / `screenshot` / `read_client_log` / `nuitest` 测试钩子
- Agent 接管栈：统一工具契约（`tools/agent_tools.json`，30 工具）、MCP 路由层、`custom-director` 17 个动作（L1–L4 分级 + 人审 + 执行后回读）、`custom-agent-client` 客户端效果通道
- 实时感知接口 `/agent/v1/live/*`（内存采样、25m 位置量化、独立 token）
- 拒绝审计 `agent_denials`（迁移 `v2.5`）与评测器 `tools/agent_eval.py`（成功率/审批/拒绝/P95/幂等）
- 实机冒烟 `tools/agent_smoke.py`（只读 → dry_run → 受控写三段式）
- Agent 文档：`docs/agent/{STATUS,TOOLS,EVAL,SMOKE,ACTIONS}.md` 与 `docs/agent/design/` 五份设计
- 全局审查报告与三阶段路线图：`T-CityLite.base/docs/audit/2026-10-21-review-and-three-phase-plan.md`
- Agent 中枢导演架构设计：`docs/server-design/08-agent-director.md`
- 任务系统建表脚本：`migrations/v0.7_quest_system.sql`（player_quests / quest_cooldowns / quest_event_log / quest_daily_limits）
- DevOps 工作流：CI（配置/依赖/Lua 语法）、Release、PR/Issue 模板、CODEOWNERS、CONTRIBUTING、SECURITY
- GitHub 初始化脚本：`tools/dev/bootstrap_github.sh`（标签 / 里程碑 / 待办 Issue）
- 开发工作流指南 (`T-CityLite.base/docs/archive/dev-workflow-guide-2026-06-01.md`)，涵盖目录结构、分支策略、日常开发流程、Git 速查
- `start_server.bat` 一键启动脚本（UTF-8 编码，自动切换工作目录）
- `tests/architecture/test_nui_baseline.py` + `test_command_guards.py`：把「MDT 永远查询失败」与「控制台 /status 崩溃」两次教训钉成 CI —— 禁 NUI 回调里的 `type(cb) ~= 'function'` 守卫、要求 `PhoneBridge.AnswerFn` 覆盖三种应答通道、禁 `GetConvarInt` 判 diag 门禁、client/server trace 相位表必须同序、判定只用可观测槽位、诊断投影不带业务字段、NUI 产物必须内容哈希、`_diag` 只在边界三处出现、命令处理器索引 `PlayerData` 前必须判空（各含反向校验）
- 新增三条架构闸门：`test_agent_docs.py`（根索引必须登记分区文件、固定小节、`CLAUDE.md` 只能是指针）、`test_plane_boundaries.py`（client 不碰 DB / server 不调 NUI 原生 / shared 不注册事件 / manifest 不把 server 代码列进 client）、`test_docs_links.py`（约束区文档的路径引用必须存在）；三条都带反向校验；新增 `tools/dev/release_check.py`（凭据 + 债务到期 + CHANGELOG）与 `tools/dev/reuse_scan.py`（同名实现复用报告）
- **CI 转绿：五处"本地绿、流水线红"的根因**。GitHub Actions 从 `chore(tools)` 起就一直是红的，原因不是某一个提交，而是**测试依赖了本地独有的东西**：
  1. 脚本根的 docs_links_report.py 多一个右括号 —— `compileall` 直接失败（这个文件与 T-CityLite.base 下那份是两份拷贝，我改错了那份）。
  2. 干净克隆里没有 server.cfg（含凭据，gitignored），于是 FIT-10 的"谁是导出消费者"扫描看到的是**模板链**，而模板链漏了 `ensure custom-director` —— CI 与生产看到两个不同的启动集合。补进 quest.cfg（它依赖 custom-quest，必须排在之后）。
  3. agent 的 Lua harness 从来没加载 core-framework 的 shared/util.lua，  而 director 读 convar 走的是 `exports['core-framework']:ConvarString`；更糟的是 harness 的 exports 桩对任何未注册的方法**一律返回 true**，所以 `enabled` 永远是 false → HTTP 适配器全 503，10 个用例里 9 个红。修法是两份：harness 先加载 util.lua，且 exports 桩优先调用本 env 里真正注册过的导出。
  4. integration harness 缺 ConvarInt 等全局（同样的 util.lua 缺失），以及 qb-core 的导出代理只提供了 GetCoreObject，离线入账走的 EconomyAddMoneyOffline 拿到 nil 直接炸。
  5. 两处文档指向 gitignored 的文件（运行时的 admins.json、含凭据的 server.cfg）—— 改成不带反引号的叙述。
  验证方式也换了：**在干净克隆里跑 CI 的四条命令**（`compileall`、tests/unit、tests/architecture、tests/agent、tests/integration），而不是只跑本地那两条目录。结果 920 passed / 132 skipped。
- **技能入库（`.agents/skills`）+ 同步工具 + SKILL-01 闸门**：技能是"这个项目怎么做"的程序性知识，却只活在 ~/.hermes/skills 里——不进 CI、不进 review、换机器就没了，而它描述的正是这台机器上的服务器。现在仓库是准的：`.agents/skills/fivem-resource-development/` 入库，tools/dev/skills_sync.py 负责 --to-hermes / --from-hermes / --check 三个方向，闸门先构造三种漂移（内容不同、副本缺文件、副本多文件）验证检测器能看见，再检查每个技能都有 SKILL.md。文档断链闸门把 .agents 排除（技能里的路径按"安装后位置"写，不是相对仓库根）。
- **端口暴露面收口（有证据，不是看起来）**：ufw 里 40120/tcp+udp 是直连模式下不存在的服务留下的残留规则，已删；现在只剩 30120 tcp/udp（v4+v6）。3306 一直有争议：mysqld 仍监听 0.0.0.0:3306（改 bind-address 需要 root），但 ufw 默认 deny incoming 且没有任何 3306 放行规则——外部连不进来。本机直连自己的局域网 IP 能通是因为走回环接口（lo 默认放行），不能当成外部可达的证据；这条判断已写进总领手册的端口与暴露面一节，并给出从另一台机器验证的命令。
- **客户端可观测性真的接上了（20 个资源，此前只有 2 个）**：`CFShared.Report` + 就绪信标的文档写了很久，但只有 custom-phone / custom-police 真接上——其余二十多个自有资源的客户端错误没有任何上行通道。现在 `[custom]`/`[system]` 里已 ensure 的资源全部把 @core-framework/client/shared.lua 放进 client_scripts 第一位，并声明 `dependencies { 'core-framework' }`。
  过程中挖出两个真问题：①**启动顺序**：production-freeze、hud-position-tool、custom-career 原本都在core-framework 之前启动，`@` 包含会在加载期找不到文件——把 `ensure core-framework` 从 custom.cfg 挪到 core.cfg 的 production-freeze 之后（core-framework 依赖它加载 `_L` i18n）、hud-position-tool 之前。②**环**：production-freeze 与 core-framework 互相依赖，所以它反向包含会成环——撤回并登记为例外。
  闸门 CLI-01（tests/architecture/test_client_observability.py）：缺包含点名、不在第一位点名、豁免双向校验、上游目录与 vendored 库也要校验没被注入；每条规则先构造坏形状证明能红。顺带修好解析盲点：`client_script 'x.lua'`（单数写法）此前完全不在扫描范围内，改成单数就能绕过。
  验证：全量 927 passed / 132 skipped；整机重启 84 资源 Started、0 SCRIPT ERROR、无 could not find / failed to load。
- **CI 全绿（6/6 job）**：最后两个 job 也是同一类毛病——**测试桩与它测的代码脱节**。
  agent 工具注册表：TOOLS.md 是 `tools/agent_tools.py --write` 的生成物，但有人在末尾手写了一段控制台驱动手册（tcity-cmd），`--check` 于是永远报 drift。那段内容本身有价值，搬到 T-CityLite.base/docs/agent/CONSOLE.md（并从 agent/README.md 索引），生成物恢复纯生成。
  NUI 冒烟：Playwright 的 fetch 桩返回**空正文**（`text: async () => ''`），而 custom-phone 现在把 `await resp.text()` 交给 JSON.parse（web/src/utils/nui.ts），于是每个回调都抛 "NUI <event> replied HTTP 200: "，这些 console error 把用例判红。桩改成按事件名返回非空 JSON（nuiReady/phoneOpenAck/closePhone/getPhoneData/getPhoneApps/getCallHistory）。
  验证：`python tests/nui/run_ui_tests.py` 4/4（截图是真渲染的手机主屏，不是空壳）、agent_tools --check OK、全量 920 passed / 132 skipped，GitHub Actions 六个 job 全 success。
- **警察模块收口（第三步完成）：案卷 / 逮捕 / 报告，例外表清零**。`police_cases` 有两个写者（p2 的逮捕建卷、p3 的玩家建卷，两段几乎逐字相同）、`police_arrests` 两个且**列集合不同**（p2 的 Sys.Jail 三列、p3 的 RegisterArrest 五列）、`police_reports` 三处 INSERT 加两处 UPDATE（p1 五列、p2 十四列/十二列、p3 只更新判决字段）。
  又碰到同一个 bug 家族：`case_id`/`incident_id` 位于参数数组**中间**，调用方常传 nil，数组出洞 → oxmysql 截断 → 参数少于占位符 → MariaDB 语法错 → `InsertId()` 拿到错误字符串。真库对照确认：旧形状 `ok=true` 但结果是错误字符串 —— 也就是说**不带案卷/事件建报告这条路是坏的**，而报告创建是逮捕与录入流程的必经环节。
  新增 custom-police 的 records.lua 作为三张表的唯一写者：`InsertCase`（案号 CASE-年-六位，插入后补写）、`InsertArrest`（incident/case 只在提供时出现）、`InsertReport`（kind/status/BOLO/charges 按需拼接）、`LinkReport`（case_id 数字、justice_case_id 字符串，只更新实际给的列）、`RecordVerdict`（返回 ok 与 affected，保留"写失败"与"没匹配到行"的区别）。p1/p2/p3 的 9 处写入全部改为委派。
  闸门里 `police_*` 的**例外表现在是空的**：14 张表全部有唯一写者。顺带修掉 `test_deprecations` 的误报来源 —— 它把注释里写的示例 SQL 当成真实写入（`police_arrests` 的预算因此被散文污染），现在先剥注释。
  验证：879 passed / 132 skipped；真库探针 —— 无案卷报告 `case_id` 为 NULL、案号 `CASE-2026-000001`、逮捕无 case 时该列为 NULL、字符串司法 id 链接与判决（`justice_status=closed`）都成功；84 资源零错误；探针数据已清理
- **警察模块收口（第二步）：证据 + 证据链，顺带修好一条整条死掉的路径**。`police_evidence` 与 `police_evidence_chain` 原本双写（p2_evidence 的登记 + p2_system 在逮捕/报告提交里各抄了一遍）。收口时在真库上对照两种形状，发现 **登记路径本身是坏的**：
  `INSERT INTO police_evidence (exhibit_no, ...) VALUES (?, ...)` 配 `{ nil, incidentId, ... }` —— 参数数组第一个就是洞，oxmysql 在洞处截断，发出的参数少于占位符，MariaDB 报 "syntax error near '?)'"，`InsertId()` 拿到的是错误字符串，于是**每一次证据登记都返回 db_error**，服务端日志里只有业务层一句"登记失败"。链记录的 `note` 为 nil 时同样留洞（`pcall` 看不见，因为错误是返回值）。
  修法：新增 `PoliceEvidenceWriter.Register` / `.Chain` 作为唯一写者，列集合按需拼接（不存在的字段写 NULL 进 SQL，参数数组永不留洞），展品号 EX-%06d 在写者内补齐，首条 'collected' 链记录一起写，返回值带 `chain_ok` 让"链失败必须回滚"的调用方保持原语义。p2_system 的两处拷贝改为一次委派（保留各自的回滚路径）。
  验证：867 passed / 132 skipped；真库探针 —— 登记成功 `EX-000002`、链记录 1 条、`chain_ok=true`、缺父级/短标签分别被拒为 `missing_case`/`invalid_label`；84 资源零错误。单玩家可验的部分（写库、链完整性、校验、审计）全测；"两个玩家在案发现场采集"这条仍需真实双人
- **客户端热路径：8 段逐帧轮询收成一个（可测的）实现**。custom-police 的 job.lua 里有 8 段几乎一样的循环（值班、储物柜、垃圾桶、直升机、拖车场、车库、指纹、证据），每段 14~17 行，差别只有"哪个 flag""要不要在车里""按下做什么"；其中 6 段还带着 `if PlayerJob.onduty then sleep = 5 end` —— `sleep` 全局从未被读取，纯拷贝残留。
  新增 interact.lua 的 `PoliceInteract.Watch{active, allowed, requireVehicle, onPress, after}`：退出条件写成显式的 `active`（离开区域即退出，不再藏在 else 分支里），可选的车内/职业/拒绝重试都在一处。job.lua 的 8 处调用点改为一行配置，`Wait(0)` 与手写按键轮询在该文件里归零（980 行，少 67 行）。
  evidence.lua 的弹壳/血迹/指纹提示循环原本每个分支各自 `GetEntityCoords(PlayerPedId())`，改为循环开头取一次复用；这个循环保留手写形态（三个目标各有就近判定与不同副作用，硬合并会改变行为），在闸门里以带理由的例外登记。
  新增闸门 `test_client_hot_paths.py`：逐帧循环里同时出现 `IsControlJustReleased` 与 `Wait(0|1)` 即红（唯一实现是 `PoliceInteract.Watch`）、每帧循环体内 `GetEntityCoords(PlayerPedId())` 最多一次，带反向校验、例外痕迹校验与变异冒烟（注入手写轮询 → 红）。
  验证：861 passed / 132 skipped；job.lua、interact.lua、fxmanifest 过 luac；84 资源零错误。
  诚实边界：客户端脚本的运行时行为要真客户端才能验，本轮证到的是"结构正确 + 语义单测"（`test_police_interact.py` 6 例：按下只触发一次、离开区域不按键、职业不符即退、车内门槛、onPress 可拒绝重试）
- **警察模块收口（第一步）：审计与建单各归一个写者**。`police_audit` 原先有 **8 份**各自实现的 `INSERT`，分两种写法；在真库上实测发现其中一种**在 `detail = nil` 时静默失败**——参数数组末尾的空洞被 oxmysql 截断，MariaDB 报语法错，而 `pcall` 返回的是 **true**（错误以字符串形式返回，不抛异常），于是调用方的 `if not audit(...)` 把失败当成了成功，**审计行根本没写**。
  新增 custom-police 的 audit.lua 作为唯一写者：`NULL` 直接写进 SQL（参数数组永不留洞）、把数据库返回的错误字符串判为失败、统一截断（target 64 / detail 500）、支持 `actor_kind`（player/agent/system）。七个文件的本地 `audit()`/`auditPlayer()`/`auditNpc()` 改为同名委托，调用点一行未改。
  `police_incidents` 从三个写者（p0 玩家 911、p2_system 的 agent 路径、p4_npc 的 NPC callout）收成一个：p0 里新增 `insertIncidentRow(createdBy, data, opts)`，列集合按需拼接（`npc_template` 这类可选列不再靠传 nil 参数），agent 路径保留自己的 fail-closed 预审计（`opts.audit = false` 避免一次建单记两条审计），NPC 路径保留预算回滚。
  新增闸门 `test_police_single_writer.py`：8 张表定下唯一写者，6 张未收口的表登记理由与"痕迹"（痕迹消失=例外失效要删表）；判据是"这张表只有它该有的那个文件在写"，并带反向校验与变异冒烟（注入第二个写者 → 红）。
  验证：840 passed；真库探针确认 nil 字段审计**写入成功**（此前静默丢失）、agent 建单 `created_by=agent:probe-agent`、`npc_template` 落库、`x` 为 NULL、一次建单只产生一条审计；84 资源全 Started、零错误
- **安全：关闭公网 3306**。主机 ufw 原本对 `3306/tcp` 全网放行，而 mysqld 监听在 `0.0.0.0:3306` —— 数据库（全部玩家数据）暴露在公网。已删除该规则（`sudo ufw delete allow 3306/tcp`），30120/tcp+udp 保持放行；服务器经 localhost 连库不受影响（重启后 84 资源全部正常、经济探针写入成功）。建议后续把 `bind-address` 收成 `127.0.0.1`（需要 root 改 `/etc/mysql/mysql.conf.d/mysqld.cnf` 并重启 mysql，本轮未做）
- **客户端可观测性：服务端能看见客户端了**。客户端的 `print` 只进玩家 F8、服务端永远看不到，于是"新客户端代码到底有没有加载""跨资源导出是不是缺了"这类问题只能靠对方截图——这个坑咬过两次（`loadAnimDict` 导出缺失、core-framework 客户端共享文件包含失效后的静默降级）。
  新增两个诊断事件（登记在 `net_events_allowlist.json`，category=diagnostic）：`clientReady` 在客户端资源加载后发一次 → `[client-ready] custom-police v1.7.0 Tester(#7)`；`clientReport` 是 `CFShared.Report(kind, msg)` 的出口 → `[client-report] error <player>: <msg>`。
  安全面按"输入完全由客户端控制、输出是服务端日志"来设计：去所有控制字符（尤其换行，防伪造日志行）、截断（消息 400 / 资源名 64 / 版本 32 且限字符集）、kind 白名单、每玩家限流走 owner（就绪 3/60s、上报 10/60s）、`src == 0` 直接忽略。
  顺带修了闸门的两个盲点：net event 扫描只覆盖两个资源（框架自己的事件从没被扫过）；以及 `RegisterNetEvent(EVENT_NAME, ...)` 用变量名注册时扫描器完全看不见——新增规则`test_net_event_registration_uses_a_literal_name` 钉死必须写字面量。allowlist 的 owner/path 校验也不再写死两个资源名（框架资源原先根本登记不进去）。
  验证：服务端一半与客户端一半都有真跑 Lua 的单测（`test_client_reports.py` 7 例、`test_client_shared.py` 5 例，桩只替换 FiveM 原生），启动探针实测 `ready_window_3 = YYYNN`、`report_window_10 = YYYYYYYYYYNN`。遗留："玩家登录后确实看到 `[client-ready]`"要真玩家才能验
- **闸门覆盖率：把"从未被证明会红"变成预算**。新增 `tools/dev/gate_coverage.py`——一条规则算"已证明"当且仅当：在 `gate_history` 里失败过 / 是变异冒烟用例 / 自身是反向校验；其余算未证明（技术债）。当前 211 条规则里 55 条已证明（冒烟 15 + 自带反向校验 40），未证明 156 条，写进 `gate_coverage_budget.json`：超上限红，明显低于上限也红（逼着收紧）。同时把变异冒烟从 8 条扩到 15 条，新增覆盖：net event 鉴权、状态写路径、跨资源写表、`SELECT *` / 无 LIMIT、命令处理器守空、SetJobDuty 写路径、分区 AGENTS.md 固定章节。扩容过程本身抓到两个"我以为会红"的坑：状态写扫描只认规则跟踪的列（写 `title` 不触发，写 `status` 才触发），跨资源写 `player_vehicles` 是已登记的豁免（拖车），得换 `player_houses` 才红
- **限流最后一处也收掉了，例外表清空**。`tcity-atmosphere` 原本在每玩家 state 里自己数窗口（`requestCount` / `requestWindowStart`）。当初保留它的理由是"与场景状态机耦合、要重构状态机"——实际 grep 全仓后发现这两个字段**没有任何外部读者**（唯一命中是 oxmysql 的 node_modules），于是三行就换成了 `exports['core-framework']:RateLimitWindow(key, 3, 10000, now)`，并在 `playerDropped` 里显式 `RateLimitReset`（原来是随 state 一起丢的）。至此 `test_rate_limit_single_owner.py` 的例外表为空：全仓限流只有一个实现
- **文档断链改成"活跃层必须 0 + 历史归档显式豁免"**。范围从"逐个目录收编"（每次都要改闸门代码，而且没收编和已修好"在报告里长得一样"）改成全仓 md 默认全覆盖，唯一例外是带 `LEGACY.md` 且登记在 `tests/architecture/legacy_docs.json` 的历史归档目录。豁免是**双向校验**的：有标记没登记 → 红（不许自己贴标记逃避闸门）；登记了但目录或标记没了 → 红（豁免不许烂在表里）；归档文档数 ≥ 活跃文档数 → 红（防止归档变成默认）。5 个历史目录（police 172 / audit 88 / 02_script_index 82 / cleanup 45 / archive 27 处）已标记并登记，活跃层 213 处断链全部修掉——多数是指向真实新位置（`qb-jewelery` 等进了 `archive/`，五处路径统一成 `resources/[组]/<res>/<file>`），确实已删除的文件改成不带反引号的叙述而不伪造路径。`docs_links_report.py` 现在分开报活跃层与归档，避免"414 处断链"这种数字让人以为闸门失守
- **删掉 1,233 行"看起来在跑"的死代码**。custom-main/server/security.lua（260 行）与 `T-CityLite.base/resources/[custom]/custom-security/server/security.lua` 是同一份安全服务的两份拷贝（差 26 行：日志前缀、`custom-main` → `custom-logs` 导出名），按"重复实现"思路该合并——但 `T-CityLite.base/resources/[custom]/custom-main/fxmanifest.lua` **根本没列这个文件**，它是资源拆分后的残骸。同批残骸：`custom-main` 的 server/crime.lua、server/logs.lua、client/security.lua，custom-admin/client/menu.lua（其监听的事件已由 `qb-adminmenu` 接管），custom-vehicles/client/dashboard.lua（531 行，中控屏已迁到 `[system]/tcity-dashboard`）及其 `html/` 下三个再无人引用的页面。
  全部删除，运行时行为不变（都没有被清单加载）。新增闸门 `test_no_orphan_scripts.py`：`[custom]` 下每个 `.lua` 必须出现在自己资源的 fxmanifest 里（含 `dir/*.lua` 通配），临时文件用 `_` 前缀、测试放 `tests/` 目录，否则红。
  连带更新了六张登记表（table_owners 的 `main-player-metadata`、NUI 白名单的 `vehicles-dead-dashboard-client`、NUI 回调下限 60 → 53、convar 调用方清单、限流调用方清单、复用预算 DebugPrint 14 → 11）——闸门全部按预期报"登记项已失效"，这正是棘轮该有的反应
- **真实调用验证抓到两个 bug（静态闸门都看不见）**。用一个资源启动时自动执行、结果 `SaveResourceFile` 落盘的探针，直接调 `exports['qb-core']:EconomyAddMoneyOffline` 与`exports['core-framework']:RateLimit*` 跑真实 DB 与真实限流表：
  - `cash +0.55` 存成 `100.5499999999999545` —— 参数以 DOUBLE 绑定，DECIMAL 相加后漂移；改为 `ROUND(COALESCE(CAST(JSON_EXTRACT(money, ...) AS DECIMAL(20,2)), 0) + ?, 2)`，并在经济闸门里加了一条"必须 ROUND 到分"的断言；
  - `TokenBucket` 的 burst=2 放过了**第 3 次**请求 —— 首个分支建桶时给了满 tokens 却没扣本次那一个；改为建桶即扣，并补 `tests/unit/layer1_core/test_rate_limit.py`（8 个用例真跑 Lua，时间用桩注入）把三种语义、前缀 Reset、Sweep、脏参数钉住。
  修复后同一探针复跑：`cash` 精确为 `100.55`、`tokenbucket_burst2 = true,true,false retry=1000`；同时确认 `keep` 这类未知字段在入账后仍在（不再是整块覆盖）、并发两次 +10 都在（无丢更新）、四类非法入账全部拒绝且余额不变
- **文档断链闸门再收编一层**：范围加上 `docs/client/**`、`docs/analysis/**`、`docs/server-design/**`，12 处文件、82 条引用改成可解析路径（规则本身未放宽、未加豁免）。全仓断链 706 → 619，约束区（agent 会照着做的那一层）现为 0 断链。仍未收编的是 `audit/`、`archive/`、`02_script_index/`、`cleanup/` 这类历史目录，由 `docs_links_report` 继续出报告
- **闸门变异冒烟：证明"这些规则真的会红"**。`tools/dev/gate_mutation_smoke.py` 把"往仓库里塞一个该被拦住的形状 → 跑那条闸门 → 确认变红 → 撤掉 → 确认恢复绿"变成可重复执行的工具，覆盖 8 条核心闸门（经济单写者 / 整块覆盖 / 限流 / 平面越界 / 复用预算 / 文档断链 / AGENTS 登记 / manifest 语法），实测 7 条全部"注入后红、撤掉后绿"（第 8 条因文档目录正在收编而暂时常红）。配套 `test_gate_mutation_smoke.py` 钉住"用例指向的闸门必须真实存在"——测试改名后用例会静默空跑，那是比没有冒烟更加危险的状态
- **限流收口：7 份实现 → 1 个 owner**。新增 `T-CityLite.base/resources/[standalone]/core-framework/server/rate_limit.lua`，提供三种语义（`Cooldown` 每键冷却 / `Window` 固定窗口计数 / `TokenBucket` 令牌桶 + 突发），带 `Reset(前缀)` 与 `Sweep`，时间参数可注入便于单测，并以 `RateLimitCooldown/Window/TokenBucket/Reset` 对外导出。迁了 7 处：`notify_service`（窗口）、`tcity-dashboard`（冷却）、`custom-vehicles` 的 `main` 与 `dashboard_api`、`custom-security`/`custom-main` 两份 security、`custom-agent-client`（令牌桶）。两处**刻意保留**并登记理由：`tcity-atmosphere`（计数在每玩家 state，与场景状态机耦合）、`T-CityLite.base/resources/[custom]/custom-phone/server/core/rate_limit.lua`（带 diag 钩子的令牌桶，有独立单测）。新增闸门 `test_rate_limit_single_owner.py`（含"例外失效要删表"与"注释里的旧实现不误报"两条反向校验）
- **新增 manifest 语法闸门**：`test_manifest_syntax.py`。起因是给 6 个资源补 `core-framework` 依赖时漏了逗号，`dependencies { 'qb-core' 'core-framework', }` 让 manifest 变成非法 Lua——而 `restart <resource>` **不会报错**（FiveM 复用已解析的元数据），直到整机启动才以"6 个资源 failed to load、只剩 76 个在跑"的形式炸出来。闸门同时对 `dependencies` 里的自有资源名做存在性校验
- **经济写路径收口（宪法②）**：三处绕过内存层、直接 `UPDATE players SET money` 的离线入账（core-framework 的 Transfer、custom-phone 的离线汇款、qb-crypto 的离线转账）统一到 owner `T-CityLite.base/resources/[qb]/qb-core/server/services/economy_service.lua` 新增的 `AddMoneyOffline`（JSON_SET 算术 + 货币类型白名单+ 影响行数校验 + 失败回滚），对外以 `exports['qb-core']:EconomyAddMoneyOffline` 暴露。其中 **qb-crypto 那份原本是 `SET money = ?` 整块覆盖**——先读快照再写回，中间任何人动过 bank/cash 都会被静默回滚，属丢更新，本轮一并修掉。`Bus.Plugin.GetEconomy()` 现在只返回原语层（原来 `Bus.economy or Bus.EconomyService` 两套不同方法集共用一条链，谁先注册谁生效），分层便利方法走新的 `GetEconomyTools()`；新增闸门 `test_economy_single_owner.py`（4 条规则 + 反向校验）
- **convar 助手族收敛（23 → 0 份本地实现）**：`GetIntConvar`/`GetBoolConvar`/`GetFloatConvar`/`GetStrConvar`/`GetNumConvar`/`convarInt`/`convarString` 统一到 `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua` 的 `ConvarString/Int/Float/Bool`；12 个调用文件改成惰性包装，6 个资源补 `dependencies { 'core-framework' }`（这批在 `config.lua` 加载期就调用，没有依赖声明会整个资源加载失败）；新增两条闸门钉住「不许留私货」与「加载期调用方必须声明依赖」
- **`docs/agent/TOOLS.md` 记录控制台注入的三个坑**：回显不可信（会混入日志片段，命令其实执行了，要按效果校验）、输入行不清空（只有"先发回车丢掉残留"有效）、被拼坏的命令会让资源静默停掉；另记新增脚本文件必须 `refresh` 才会交付给已连接的客户端
- **共享导出的真实调用已验证，并补上启动自证**：端到端探针发现 `restart` 后的客户端根本拿不到新增的 `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua`（`restart` 只重读清单里已有的文件），导出缺失要到玩家触发动画时才炸 `No such export LoadAnimDict in resource core-framework`——静态闸门与"重启无报错"都盖不住这个坑。现在 `util.lua` 客户端侧带一行启动自证 print（F8 可见），`refresh` + `restart` 后实测 `ok=true returned=true hasAnimDictLoaded=1`；`docs/engineering/REUSE.md §6` 增加了三步验证配方（自证行 / 导出存在 / 字典真的加载出来）
- **组件复用第一轮收敛**：新增 `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua`（客户端侧 `exports('LoadAnimDict')`，比原实现多 5s 超时，避免字典缺失把客户端脚本线程卡死）；`[custom]` 的 5 处重复实现（custom-police ×2、custom-vehicles ×2、custom-agent-client）改为惰性包装调用，`loadAnimDict` 17 → 12 份；`qb-*` 与 `standalone` 按「不迁上游」保留并写进预算理由；新增 `docs/engineering/REUSE.md` 与棘轮闸门 `test_reuse_budget.py` + `reuse_budget.json`（预算只许往下调，新增 ≥4 份同名必须登记决策）
- **文档断链闸门扩到 `docs/agent/**`**：该目录 17 份文档的 107 处相对路径改为可解析路径（`T-CityLite.base/docs/agent/**` 现为 0 断链），规则本身未放宽、未新增豁免
- **规则命中率可采集**：新增 `tools/dev/gate_stats.py`（`--record` 把整套架构闸门的结果追加进 `gate_history.jsonl`，`--report` 输出每条规则的最近结果/通过失败次数/长期 0 命中清单）与 `test_gate_stats.py`；首份基线 205 条规则全绿
- **Agent 运行模型（L0–L5）**：`docs/engineering/CONSTITUTION.md`（十条不变量，每条带可执行落点）、`docs/engineering/ARCHITECTURE.md`（四平面 + 依赖方向矩阵 + 唯一通道表）、`docs/engineering/agent-operating-model.md`（六层模型与落地路线）；根 `AGENTS.md` 瘦身为索引（88 行）+ 四份分区 `AGENTS.md`（`[custom]` / `[qb]` / `tests` / `custom-phone/web`）；`CLAUDE.md` 改为指针（避免与 `AGENTS.md` 分叉），原通用准则归档为 `docs/engineering/llm-craft.md`；五份流程模板 `docs/engineering/templates/*.md`（R/P/D/V/S）

### Security
- 地面证据（弹壳/血迹/指纹）现在会**过期消失**：默认 30 分钟，服务端每分钟扫一次，过期就删并广播 `evidence:client:Remove*` 让客户端把屏幕上的箭头一并抹掉。此前 TTL 只在「表满 500」时才顺手跑一次，没到上限就整局不清、而且清的时候一声不响（客户端留着换不出东西的幽灵标记）。TTL 可用 `set tcity_evidence_ttl <秒>` 覆盖（现场验证用 60 很合适），清扫周期常量 `TTL_SWEEP_INTERVAL`。客户端拾取块也补了空值守卫：记录被扫掉后仍按 G 不会让脚本崩在 "attempt to index a nil value"
- **地面证据拾取改为服务端权威**：拾取只校验「有权限 + 有空证据袋」，既不核对 id 是否真在服务端的掉落记录里，serie / 武器 / 血型 / DNA / 指纹 也全部采信客户端发来的描述 —— 改过的客户端可以凭空换证据袋，或者把枪号、指纹、血型写成别人的来栽赃。现在必须先查到自己那张记录表（`Casings` / `BloodDrops` / `FingerDrops`）里的行，身份字段一律取自服务端记录，唯一还采信客户端的只有街道名（只有客户端拿得到原生街道名）
- `custom-vehicles`: `qb-vehiclekeys:server:AcquireVehicleKeys` 此前只校验会话内车主，任何客户端可伪造车牌远程认领载具；现改为车牌格式校验 → 会话车主 → `player_vehicles` 登记车主 → 无主载具 10m 邻近（`vehicles_claim_max_dist`）+ 1s 限流 + 审计
- `custom-vehicles`: `KeyManager.*` 拒绝非字符串车牌；`GiveKeys` 对无主载具要求先持有钥匙；`RemoveKeys` 仅车主可移除他人钥匙
- `qb-inventory`: `SetInventoryData` 对 `otherplayer-*` 容器增加 3m 距离校验（管理员豁免），堵住伪造事件远程搬运他人物品；槽位/数量先 `tonumber` 再比较，避免非法类型报错
- `custom-admin`: 全量自动 admin 改为 `admin_autogrant` convar（默认关闭）
- `story-engine`: 决策绑定服务端 pending offer（quest/step/decision），拒绝跨任务伪造；超时由服务端按默认选项收口
- `T-CityLite.base/resources/[custom]/custom-quest`: `ValidateNode` 实现类型 + 服务端距离校验；`registerTrailer` 校验实体与距离；`cleanupTrailers` 改为非网络事件；`savePosCollection` 限制管理员
- `custom-vehicles`: 钥匙/改装/部件/氮气事件统一校验车主或执勤机修；部件值夹紧 0–100
- `qb-hotdogjob`: 职业校验 + 数量≤5 + 单价按 Config 边界，堵住 `$10k/秒`
- `qb-streetraces`: 服务端重建赛局与奖池，领奖前销毁，加入去重
- `custom-justice`: 出狱按刑期校验；入狱刑期上限
- `custom-mining` / `custom-cartel`: 矿点距离、生产开始/时长校验
- `custom-main`: `ResetDeathStatus` 仅在医疗未启用且服务端判定死亡/倒地时允许，10s 冷却；`policeHandoverAlert` 加 5s 冷却 + 坐标/星级/街道校验
- `tcity-dashboard`: `police:server:plateFlagged` 要求值班 LEO/admin，车牌规范化 + 2s 冷却；内部同步改为本地调用
- `custom-testing` 移出生产 cfg，改由 `configs/modules/dev.cfg` 按需启用

### Fixed
- **弹壳从上线起就没有成功生成过一次**：客户端把 `GetOffsetFromEntityInWorldCoords` 返回的原生 vector3 直接丢给服务端，而 `sanitizeCoords` 要求 `type(coords) == 'table'`，于是每一枪都在第一步被判非法并静默丢弃（日志里只有一句笼统的 coords too far）。现在客户端发 `{ x, y, z }` 普通表，服务端也兼容 vector3，校验函数把 nil 拆成带原因的返回值（不是表 / 超距 / 无 ped），`tcity_evidence_debug` 打开后每条拒绝都会写明原因
- `custom-phone`: 一次按 M 会派发**两条** `phone` 命令（`RegisterKeyMapping` 在资源重启时重复注册），第二条看到 `isPhoneOpen=true` 且 `IsNuiFocused()=true` 立刻走 `ClosePhone` —— 界面被叫出来又秒关，玩家看到的是「按 M 没反应」。命令入口加 300ms 防抖（重复调用打 `phase=toggle-debounced`），`RegisterKeyMapping` 改为只注册一次
- `custom-phone`: **MDT「查询失败/操作失败」的真正根因**——本 build 的 `RegisterNUICallback` 把应答通道交成**可调用表**（`{ __cfx_functionReference = ... }` 带 `__call` 元方法），而 `PhoneBridge.RegisterNui` 的守卫 `if type(cb) ~= 'function' then return end` 会静默丢弃每一次应答：handler 跑了、服务端也回包了，CEF 的 fetch 却一直挂到 9s abort，前端只能报 `query_failed`/`action_failed`。新增 `PhoneBridge.AnswerFn`，兼容 function / 可调用表 / 裸函数引用（`Citizen.InvokeFunctionReference`），无法应答时直接不执行 handler，避免跑一半留副作用
- `qb-ambulancejob`: `/status`、`/heal`、`/revivep` 未判 `QBCore.Functions.GetPlayer(src)` 为 nil；同一形状的命令处理器共 39 处（`qb-hud` `/cash` `/bank`、`custom-police` 24 处、`qb-houses`、`qb-lapraces`、`qb-adminmenu`、`qb-inventory`、`qb-crypto`、`qb-cityhall`、`qb-vehicleshop`）一并加上判空，并新增 `tests/architecture/test_command_guards.py` 钉住该规则（事件处理器不在范围内：那里的 `source` 一定是真实玩家），从控制台（`source=0`）或玩家刚掉线时执行会抛 `attempt to index a nil value (local 'Player')`；现改为先判空（控制台没有可通知的客户端，`TriggerClientEvent` 传 0 会触发 native 参数 null 错误）
- `qb-core`: `QBCore.Commands.Add` 在缺少必需参数时对 `source` 发 `chat:addMessage`，控制台执行（`source = 0`）会抛 `native ...: Argument at index 1 was null`；改为控制台打印用法、玩家仍走原通知路径
- `custom-phone`: `phone:open` 是 fire-and-forget，CEF 加载期间（每次 `restart custom-phone` 后）帧被静默丢弃，Lua 侧 `isPhoneOpen=true` 但屏幕上没有界面；改为 `PhoneBridge.AwaitAck` 每 250ms 重发、NUI 回 `phoneOpenAck` 才停，2.5s 无回执则复位半开状态并提示
- `custom-phone`: `focusState` 诊断按来源 5s 限流，同一次打开的 `open-nui-sent`/`open-ack` 互相吞掉，无法区分「NUI 未应答」和「焦点未生效」；改为按 phase 单独限流
- `custom-phone`: appQuery/appAction 预算拆成 120/min burst 40 与 30/min burst 10 后，单元测试仍按 burst 10 断言；测试对齐真实预算并覆盖 action 桶独立耗尽
- `custom-phone`: 移除 appQuery 逐请求调试 `print`，handoff 追踪改由 `appQuery-hit`/`appAction-hit` 诊断阶段承担
- `custom-director`: `police_run_e2e` 调用的 `custom-agent-ops` 只在 `configs/modules/dev.cfg` 启动，FIT-10 导出门禁红；登记为 deferred repo 资源（未启动时动作返回 `execution_failed`，不影响正常流程）
- `T-CityLite.base/resources/[custom]/custom-quest`: 服务端重启后 `QuestCache` 未从 DB 预加载，`step_decision` 重连不弹窗；改为 `QBCore:Server:PlayerLoaded` 预加载 + `/questrestore`
- `story-engine`: decision NUI 增加焦点/`keepInput` 遥测、300s 看门狗、`SetNuiFocusKeepInput(false)`，避免重连软锁与手机 UI 抢焦点
- `core-framework` 引用了不存在的 `cache/*.lua`，导致自身及 9 个下游资源无法启动
- 启动顺序与 `fxmanifest` 依赖冲突（11 处）；补齐 `qb-prison`、`qb-minigames`、`safecracker`
- `T-CityLite.base/resources/[custom]/custom-quest` / `custom-taxes` / `core-framework` / `qb-recyclejob` 缺少 manifest 里声明的 @oxmysql/lib/MySQL.lua
- qb-core 无定时刷盘：补 15min tick + `onResourceStop`；断线位置回退，避免写 `0,0,0`
- 任务冷却异步查询导致永久失效；改为内存权威 + 登录回填
- `core_economy` 未定义 `EconomyService`；市场/卡特尔卖货扣物不付钱
- 剧情登录事件名错误（`QBCore:Server:OnPlayerLoaded` → `PlayerLoaded`）
- 组队任务双重抢锁、`RemoveGroupMember` 错误 key、断线不释放锁
- 接新任务覆盖活跃任务缓存；步骤尝试次数不重置
- 任务完成奖励幂等：`CompleteQuest` 回调只看 affectedRows，内存锁 + 10s 超时兜底，避免重复发奖
- 地址池任务步骤顺序绕过：缓存空窗期改用 `_currentSteps` 内存步骤比对，不再直接放行
- Bus 跨资源调用：7 个注册方 manifest include @core-framework/bus.lua，cartel/mining/justice 共 18 处改为显式 `service_*` export
- core-framework 的兼容层（compat.lua，P1-4 阶段 D 已删除）: `GetPlayer` 缓存改用 `GetPlayerName` 做活性校验（`GetPlayerPing >= 0` 恒真）
- `txAdminPort 0` 禁用管理员模式，避免端口冲突

### Changed
- `server.cfg.template` 按依赖图重排：`core → career → player → voice → custom → quest → police → vehicles → jobs → banking → medical → economy → security → crime → story → atmosphere → admin`
- `T-CityLite.base/resources/[custom]/custom-quest` 从 `custom.cfg` 移到 `quest.cfg`；`custom-justice` 移到 `police.cfg`；`progressbar` 提前到 `player.cfg`
- `custom-testing` 从 `custom.cfg` 移到 `dev.cfg`（生产默认不加载）
- CI 增加 `check_bus_wiring.py`，防止注册方再次漏 include `bus.lua`

---

- **custom-vehicles**：替换 `qb-vehiclekeys`，事件驱动钥匙/锁车/共享，O(1) 内存缓存，兼容旧 exports/events；含安全带、巡航、转向灯、氮气、车辆损耗
- **tcity-dashboard v2.1**：Vue 3 车载中控屏，6 类载具模板，警用控制台 / ANPR / 雷达 / 追踪 / CCTV
- **custom-quest**：数据驱动任务状态机、外部脚本 API、安全门控、DB 持久化（v0.6 基础设施）
- **story-engine**：决策树与玩家选择追踪
- **物流任务模板**：`quest_logistics` 取货 → 运输 → 交付，含车辆/到达/货损校验
- **GitHub Actions CI**：CFG 完整性 + Lua 语法 + 依赖图 + pytest + oxmysql JS + MariaDB schema
- **运行时构建产物入库**：oxmysql `dist/web`、menuv `dist`、tcity-dashboard `nui/dist`
- **custom-ui**：统一 NUI 焦点、关闭后 300ms 防误触、距离校验；车店/车库/qb-menu/手机/中控屏接入
- **NUI 无头冒烟**：Playwright 覆盖车店 / 中控屏 / 车库 / 手机四个页面
- 开发工作流指南（`T-CityLite.base/docs/archive/dev-workflow-guide-2026-06-01.md`）与一键启动脚本

### Changed
- **qb-vehicleshop Phase 1–5**：`while insideShop` 轮询改事件驱动；`finance.lua` 拆分为 lifecycle + payments；NUI 模式接通；客户端 Bus 注册；试驾独立车牌与钥匙清理
- `vehicles.cfg` 启用 `custom-vehicles` + `tcity-dashboard`，停用 `qb-vehiclekeys`

### Fixed
- **qb-garages**：SELECT 查询从 `rawExecute` 改为 `query/single`，并补充空车库诊断
- **qb-vehicleshop NUI**：加载顺序与 ConVar 同步修复
- **custom-taxes**：为未实现的车辆税 / NPC 定价补桩，避免调用报错
- **菜单交互**：车店改为按 E 主动打开（3.5m 距离），服务端购买距离 8m/30m；关闭菜单不再误触攻击
- **车店购买**：Processing/错误态 + 2s 防连点；Change Vehicle 不再跳 qb-menu
- **车库**：修复 NUI 回传 vector4 丢失导致的 spawnPoint nil；spawn 被拒时不再死循环；开发期共享车库
- **手机**：qb-phone 式 keepInput + DisableDisplayControlActions；状态栏/主时钟统一游戏时间
- **测试夹具**：对齐 `LocalDirtyFlush` 与 oxmysql `insert` 回调契约；测试路径改为相对仓库根目录
- **DB schema 测试**：兼容 MariaDB（JSON=LONGTEXT、ENUM 默认值引号、COLUMN_KEY）；新增 `v2.2_schema_reconcile.sql` 补齐 story-engine 索引
- `txAdminPort 0` 禁用管理员模式，避免端口冲突

### Testing
- `pytest tests`：**426 passed**（含 MariaDB schema；无 DB 连接时 286 passed / 132 skipped）
- oxmysql JS 单测：**148 passed**
- NUI 冒烟：**4/4 passed**（Playwright Chromium）
- 游戏内 `/test run all`：**298 PASS / 0 FAIL / 9 SKIP**（有玩家上下文；无玩家时 225 PASS / 8 SKIP；见 `T-CityLite.base/docs/archive/v0.7a-acceptance-report.md`）
- 离线检查：CFG / 依赖图 PASS；`light_lint` 仍为 advisory（vendor 资源遗留 ~250 条 `Wait(0)` / `MySQL.Sync`）

### Known
- 车店 NUI、车库、物流任务尚未完成真人客户端验收
- 8 个手机用例需要真实玩家上下文（无客户端环境会 SKIP）

---

## [0.6.0] — 核心架构安全与性能加固 — 2026-06

### Security
- **SQL 注入修复**: `qb-management` `sv_boss.lua` + `sv_gang.lua` 的 `LIKE '%jobname%'` 拼接改为 `JSON_EXTRACT` 参数化查询
- **弃用事件硬拒绝**: `QBCore:Server:UseItem` / `RemoveItem` / `AddItem` 从"打印警告+放行"改为"安全日志+拒绝执行"
- **SecurityService 集成**: `AddMoney` / `RemoveMoney` / `SetMoney` / `SetJob` / `SetGang` 全部接入 `Bus.SecurityService` 校验层（source 验证 + 输入清洗 + 阈值熔断）
- **qb-banking Rate Limit**: withdraw / deposit / transfer ×4 回调添加 2 秒冷却防刷
- **compat.lua 缓存加固**: `GetPlayer` 缓存添加 `GetPlayerPing >= 0` 活性校验，消除幽灵对象风险

### Changed
- **DirtyFlush 管道集成**: `QBCore.Player.Save()` 从直接 SQL 改为 DirtyFlush 代理——非强制存盘仅标记脏数据，批量定时落盘（默认 15 分钟），IO 削减 ~66%
- **ForceFlush 去循环**: `DirtyFlush.ForceFlush` 改为直接 SQL 写入，避免 `Save → ForceFlush → Save` 循环
- **hunger/thirst 优化**: `SetMetaData` 中饥饿/口渴不再标记 `IsDirty`，消除每 5 分钟全字段 UPDATE
- **qb-houses 死循环消灭**: 7ms 轮询改为一次性加载后线程退出
- **qb-vehicleshop 异步化**: `playerDropped` + `removePlayer` 中的 `.await` 改为异步回调
- **qb-phone 缓存层**: 新增 `PhoneCache` + GetInvoices 异步化 + mail 缓存失效

### Documentation
- 新建 `T-CityLite.base/docs/systems/bus-api-reference.md`，完整记录 Economy / JobService / SecurityService / PersistenceService / DirtyFlush 接口

---

## [0.5.0] — 犯罪玩法系统 — 🚧 开发中

### Added
- `custom-crime` 资源（犯罪逻辑服务端）
- `custom-main` 集成犯罪事件处理（server/crime.lua）
- 模块化 CFG: `configs/modules/crime.cfg`

---

## [0.4.0] — 自研手机系统 — 2026-06-01

### Added
- **自研手机系统** (`custom-phone`): Svelte + Vite + TypeScript 构建，Phone-First 架构
  - 前端 gzip 仅 42KB（远低于 250KB 目标）
  - 应用: Banking / Contacts / Messages / CityFeed / JobBoard / FactionChannel / Garage / Hotlines / Notifications / PhoneCall
  - 领袖应用: GangBossApp / MayorApp / SheriffApp
  - `PhoneShell.svelte` 统一 UI 壳
  - `T-CityLite.base/resources/[custom]/custom-phone/web/src/stores/phone.ts` 状态管理 + `T-CityLite.base/resources/[custom]/custom-phone/web/src/utils/nui.ts` NUI 通信层
- **数据库表自动创建**: `phone_messages`, `phone_contacts`, `phone_cityfeed`, `phone_jobboard`
- 服务端子模块: `banking.lua` / `faction.lua` / `jobboard.lua` / `main.lua`

### Security
- **H1 RED**: `completeJob` 守卫条件修复 — 跳过 career-tag 直接完成 open 任务
- **H2 RED**: `bankTransfer` 离线转账竞态条件 — `JSON_SET` 原子操作
- **H3 RED**: `shareContactNearby` 输入校验 — name≤30 + number≤15
- **M4 YELLOW**: `postJob` 奖励上限 $50,000
- **M5 YELLOW**: `bankTransfer` 单笔上限 $100,000
- 全文件乱码 emoji 修复

### Testing
- `08_phone_test.lua`: 23 占位 → 38 真实断言
- 覆盖 10 组: UI / DB / API / 消息 / 联系人 / 银行 / JobBoard / 安全 / 事件 / 架构

### Documentation
- `T-CityLite.base/docs/archive/v0.4-validation-plan.md`
- `T-CityLite.base/docs/archive/v0.4-joint-test-scenarios.md`
- `T-CityLite.base/docs/standards/nui-standard.md`

---

## [0.3.0] — 基础设施层 — 2026-05

### Added
- **统一经济出口** (`custom-economy`): 所有资金变动通过 `AddScaledMoney`，Convar 热调节
- **安全防火墙** (`custom-security`): Rate Limit、距离校验、服务端事件拦截、Discord 审计日志
- **审计日志** (`custom-logs`): 结构化日志记录
- **多标签职业** (`custom-career`): 支持多职业切换
- **管理面板** (`custom-admin`): 服务端命令集
- 模块化 CFG: `economy.cfg` / `security.cfg` / `career.cfg` / `admin.cfg`
- `T-CityLite.base/docs/archive/v0.3-technical-manual.md` / `T-CityLite.base/docs/archive/v0.3-banking-refactor.md` / `T-CityLite.base/docs/archive/v0.3-test-checklist.md` / `T-CityLite.base/docs/archive/v0.3-test-manual.md`

### Testing
- 双层自动化测试框架 (`custom-testing`):
  - 离线 Python 检测: `check_cfgs.py` / `check_lua_syntax.py` / `check_db_schema.py` / `check_dependencies.py`
  - 游戏内测试框架: `test_runner.lua` + `mock_events.lua`
  - 9 个测试套件，118 个测试用例

---

## [0.2.0] — 基础 RP 模块 — 2026-05-28

### Added
- **职业系统**: `qb-management`（帮派/企业管理）
- **银行系统**: `qb-banking`
- **警察系统**: `qb-policejob`
- **医疗系统**: `qb-ambulancejob`
- **载具系统**: `qb-fuel` / `qb-vehiclekeys` / `qb-garages`
- **进度条**: `progressbar`
- 模块化 CFG: `jobs.cfg` / `banking.cfg` / `vehicles.cfg` / `police.cfg` / `medical.cfg`

### Fixed
- **pma-voice OneSync 依赖**: `server.cfg` 添加 `set onesync on`，解决语音系统启动失败

### Changed
- 启动加载保持模块化 `exec configs\modules\*.cfg`；`ensure [qb]` 保持禁用

### Gameplay
- **通缉等级警察接管系统** (`custom-main`):
  - 原生 GTA 通缉等级 ≥3 时自动清除 NPC 警察，移交追捕给玩家警察
  - 全服调度警报 + 持久化 metadata + 雷达三角定位红点（每 8 秒刷新）
  - `/clearwanted [id]` 警察命令
  - 本地平民 NPC 恐慌系统：行人尖叫逃窜、司机猛踩油门（25 米范围内）
- **自定义 Duty 切换命令**: `/duty` 快速切换执勤/下班，无需前往物理标记点

### Fixed
- Svelte UI 移除 "Order Physical Debit Card" 按钮（借记卡/ATM 已禁用）
- NUI 共享用户列表 bug 修复：`openBank` / `openATM` 回调中 `users` JSON 字符串解码为 Lua table

### Documentation
- `T-CityLite.base/docs/archive/v0.2-maintenance.md` / `T-CityLite.base/docs/archive/v0.2-test-checklist.md` / `T-CityLite.base/docs/archive/v0.2-master-test-manual.md`
- `T-CityLite.base/docs/archive/v0.2-wanted-handover-technical-memo.md` / `T-CityLite.base/docs/archive/v0.2-wanted-handover-test-guide.md`
- `T-CityLite.base/docs/archive/v0.2-status-persistence-technical-memo.md`
- `T-CityLite.base/docs/systems/database-persistence.md` / `T-CityLite.base/docs/archive/v0.2-hospital-optimization-guide.md`

---

## [0.1.0] — 精简启动链 — 2026-05-28

### Added
- 基于 `QBCore_CDB34E.base` 创建 Lite 版本
- **14 个模块化 CFG 启动体系**，废除 `ensure [qb]` 粗粒度加载
- 核心模块: `oxmysql` / `qb-core`
- 玩家流程: `qb-menu` / `qb-input` / `qb-target` / `PolyZone` / `qb-multicharacter` / `qb-spawn` / `qb-apartments` / `qb-interior` / `qb-clothing` / `qb-inventory` / `qb-weapons` / `qb-hud` / `qb-weathersync`
- 语音: `pma-voice`
- 自定义资源: `custom-main`

### Fixed
- **Spawn Death Prevention**: `custom-main` 实现自动血量恢复和复活回退系统（`qb-ambulancejob` 禁用时防止玩家出生即死亡）

### Infrastructure
- 依赖例外发现并添加: `PolyZone` / `qb-interior` / `qb-clothing` / `qb-weapons`
- 禁用资源追踪: `disabled-resources-v0.1.md`
- `server.cfg.template` 模板配置
- `T-CityLite.base/docs/archive/v0.1-maintenance.md`

### Testing
- 基础客户端测试通过
- 重连持久化验证通过

---

[0.7a]: https://github.com/wenkais196-Gabriel/T-City/releases/tag/v0.7a
[0.6.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/wenkais196-Gabriel/T-City/releases/tag/v0.1.0
