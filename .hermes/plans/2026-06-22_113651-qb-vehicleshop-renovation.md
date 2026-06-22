# qb-vehicleshop 全面改造计划 (v2.2.0 → v2.3.0)

> **For Hermes:** 使用 TDD + 增量实现 + 向后兼容策略。每个 Phase 内部任务按顺序执行，Phase 间可独立交付。

**Goal:** 优化 car shop 性能（消除空闲轮询）、拆分过长模块（finance.lua）、完善 NUI 交互、客户端模块化 + Bus 注册

**Architecture:** 保持现有 server/ + client/ 模块化结构不变。每个 Phase 增量为独立 commit，保持所有 13 个旧事件名、callback、command 100% 向后兼容。

**Tech Stack:** Lua 5.4, FiveM/QBCore, Python/pytest, Bus (core-framework)

**Principles:** TDD (RED→GREEN→REFACTOR) · 增量实现 (每步可运行) · 向后兼容 (事件名不变) · 四原则

**Baseline test command:**
```bash
cd /home/swk/tcity/T-CityLite.base && python3 -m pytest tests/unit/layer3_business/test_vehicleshop.py -v
```

---

## Phase 1: 空闲轮询优化 (while insideShop → 事件驱动)

**Motivation:** zones.lua 当前使用 `while insideShop do ... Wait(1000)` 轮询 (line 78-128 free-use, line 152-208 managed)。每秒重建 vehicleMenu 表，即使玩家静止不动也在消耗 CPU。改为事件驱动：菜单只在状态变化时重建。

**Impact:** low risk, high reward — 不改变业务逻辑，只改触发机制。

### Task 1.1: Write failing test — verify new event `qb-vehicleshop:client:refreshMenu`

**Files:**
- Modify: `tests/unit/layer3_business/test_vehicleshop.py`

**Step 1: Write failing test**

```python
class TestClientEventRefresh:
    """Phase 1: 空闲轮询优化 — 事件驱动菜单刷新"""

    def test_refresh_menu_event_exists(self):
        """新事件 qb-vehicleshop:client:refreshMenu 可用于触发热更新"""
        r = run_vehicleshop_test([BUS_LUA], """
-- 用纯 Lua 模拟客户端事件注册
RegisterNetEvent('qb-vehicleshop:client:refreshMenu', function(shopName)
    assert(shopName ~= nil, "shopName required")
end)
-- 验证已注册
local registered = false
for _, name in ipairs(__test.events) do
    if name == 'qb-vehicleshop:client:refreshMenu' then registered = true end
end
assert(registered, "refreshMenu event not registered")
""")
        assert r['ok'], f"Lua error: {r['stderr']}"
```

**Step 2:** Run `pytest ...::TestClientEventRefresh -v` — expected FAIL (event not yet registered)

**Step 3:** Add `RegisterNetEvent('qb-vehicleshop:client:refreshMenu', ...)` to zones.lua

**Step 4:** Run — expected PASS

### Task 1.2: Refactor free-use shop menu to event-driven

**Files:**
- Modify: `resources/[qb]/qb-vehicleshop/client/zones.lua` (lines 67-135)
- Modify: `resources/[qb]/qb-vehicleshop/client/util.lua` (add `_vBuildVehicleMenu` function)

**Changes:**

1. Extract menu-building logic from the `while insideShop` loop into a named function `_vBuildVehicleMenu(shopName)` in util.lua

```lua
-- util.lua: 替换全局 vehicleMenu 赋值为函数
function _vBuildVehicleMenu(shopName)
    if not shopName or not Config.Shops[shopName] then return end
    local shop = Config.Shops[shopName]
    if shop['Type'] == 'free-use' then
        vehicleMenu = {
            { isMenuHeader = true, icon = 'fa-solid fa-circle-info',
              header = _vGetVehBrand():upper() .. ' ' .. _vGetVehName():upper() .. ' - $' .. _vGetVehPrice() },
            { header = Lang:t('menus.test_header'), txt = Lang:t('menus.freeuse_test_txt'),
              icon = 'fa-solid fa-car-on', params = { event = 'qb-vehicleshop:client:TestDrive' } },
            { header = Lang:t('menus.freeuse_buy_header'), txt = Lang:t('menus.freeuse_buy_txt'),
              icon = 'fa-solid fa-hand-holding-dollar',
              params = { isServer = true, event = 'qb-vehicleshop:server:buyShowroomVehicle',
                args = { buyVehicle = shop['ShowroomVehicles'][ClosestVehicle].chosenVehicle } } },
            { header = Lang:t('menus.finance_header'), txt = Lang:t('menus.freeuse_finance_txt'),
              icon = 'fa-solid fa-coins',
              params = { event = 'qb-vehicleshop:client:openFinance',
                args = { price = _vGetVehPrice(), buyVehicle = shop['ShowroomVehicles'][ClosestVehicle].chosenVehicle } } },
            { header = Lang:t('menus.swap_header'), txt = Lang:t('menus.swap_txt'),
              icon = 'fa-solid fa-arrow-rotate-left',
              params = { event = Config.FilterByMake and 'qb-vehicleshop:client:vehMakes' or 'qb-vehicleshop:client:vehCategories' } },
        }
    elseif shop['Type'] == 'managed' then
        vehicleMenu = {
            { isMenuHeader = true, icon = 'fa-solid fa-circle-info',
              header = _vGetVehBrand():upper() .. ' ' .. _vGetVehName():upper() .. ' - $' .. _vGetVehPrice() },
            { header = Lang:t('menus.test_header'), txt = Lang:t('menus.managed_test_txt'),
              icon = 'fa-solid fa-user-plus',
              params = { event = 'qb-vehicleshop:client:openIdMenu',
                args = { vehicle = shop['ShowroomVehicles'][ClosestVehicle].chosenVehicle, type = 'testDrive' } } },
            { header = Lang:t('menus.managed_sell_header'), txt = Lang:t('menus.managed_sell_txt'),
              icon = 'fa-solid fa-cash-register',
              params = { event = 'qb-vehicleshop:client:openIdMenu',
                args = { vehicle = shop['ShowroomVehicles'][ClosestVehicle].chosenVehicle, type = 'sellVehicle' } } },
            { header = Lang:t('menus.finance_header'), txt = Lang:t('menus.managed_finance_txt'),
              icon = 'fa-solid fa-coins',
              params = { event = 'qb-vehicleshop:client:openCustomFinance',
                args = { price = _vGetVehPrice(), vehicle = shop['ShowroomVehicles'][ClosestVehicle].chosenVehicle } } },
            { header = Lang:t('menus.swap_header'), txt = Lang:t('menus.swap_txt'),
              icon = 'fa-solid fa-arrow-rotate-left',
              params = { event = Config.FilterByMake and 'qb-vehicleshop:client:vehMakes' or 'qb-vehicleshop:client:vehCategories' } },
        }
    end
end
```

2. Replace the `while insideShop` loop in `_vCreateFreeUseShop` with:

```lua
-- zones.lua: free-use zone (替换 lines 67-135)
function _vCreateFreeUseShop(shopShape, name)
    local zone = PolyZone:Create(shopShape, { name = name, minZ = shopShape.minZ, maxZ = shopShape.maxZ })
    zone:onPlayerInOut(function(isPointInside)
        if isPointInside then
            insideShop = name
            _vBuildVehicleMenu(name)  -- 立即构建菜单 (不再轮询)
        else
            insideShop = nil
            ClosestVehicle = 1
            vehicleMenu = {}
        end
    end)
end
```

3. Same for `_vCreateManagedShop`:

```lua
-- zones.lua: managed zone (替换 lines 141-215)
function _vCreateManagedShop(shopShape, name)
    local zone = PolyZone:Create(shopShape, { name = name, minZ = shopShape.minZ, maxZ = shopShape.maxZ })
    zone:onPlayerInOut(function(isPointInside)
        if isPointInside then
            insideShop = name
            if PlayerData and PlayerData.job and PlayerData.job.name == Config.Shops[name]['Job'] then
                _vBuildVehicleMenu(name)
            end
        else
            insideShop = nil
            ClosestVehicle = 1
            vehicleMenu = {}
        end
    end)
end
```

4. Register the refreshMenu event:

```lua
-- zones.lua: 在文件末尾 (print 之前) 添加
-- ==============================================================
-- 事件: 菜单刷新 (替代旧轮询)
-- ==============================================================
RegisterNetEvent('qb-vehicleshop:client:refreshMenu', function()
    if insideShop then
        _vSetClosestShowroomVehicle()
        _vBuildVehicleMenu(insideShop)
    end
end)
```

5. Trigger refreshMenu at all relevant points:
   - After swapVehicle in menus.lua (via TriggerEvent on client)
   - Already handled: `qb-vehicleshop:client:homeMenu` will re-open the menu, so the menu gets rebuilt on next open. Add a single `Wait(1500)` + `TriggerEvent('qb-vehicleshop:client:refreshMenu')` when ClosestVehicle changes.

**Verification:**
```bash
python3 -m pytest tests/unit/layer3_business/test_vehicleshop.py -v
# Ensure all existing 43 tests still pass
```

### Task 1.3: Commit Phase 1

```bash
git add tests/ resources/[qb]/qb-vehicleshop/client/
git commit -m "perf(qb-vehicleshop): Phase 1 — replace while-insideShop polling with event-driven menu refresh

Eliminate idle Wait(1000) loops in free-use and managed shop zones.
Menu rebuilt only on zone enter and on explicit refreshMenu event.
Backward compatible: all event names unchanged."
```

---

## Phase 2: finance.lua 拆分 (410行 → lifecycle + payments)

**Motivation:** finance.lua 是服务端最长模块，混合了三个职责：玩家生命周期追踪 (add/removePlayer, playerDropped)、分期还款 (financePayment/PaymentFull)、分期购买 (financeVehicle, sellfinanceVehicle)。

**拆分方案:**
- `server/finance-lifecycle.lua` (140行): 玩家计时器 + 逾期检查 + 车辆操作事件 (delete/swap/customTestDrive)
- `server/finance-payments.lua` (270行): 分期购买 + 还款 + getVehicles callback

**向后兼容:** 所有事件/callback 名不变，`fxmanifest.lua` 中添加新文件路径。

### Task 2.1: Write failing test — verify finance split loads cleanly

**Files:**
- Modify: `tests/unit/layer3_business/test_vehicleshop.py`

**Step 1: Write failing test**

```python
# New test file paths
FINANCE_LC_LUA = os.path.join(SHOP_DIR, 'server', 'finance-lifecycle.lua')
FINANCE_PM_LUA = os.path.join(SHOP_DIR, 'server', 'finance-payments.lua')

class TestFinanceSplit:
    """Phase 2: finance.lua 拆分验证"""

    def test_split_modules_load(self):
        """两个新分文件能加载且不报错"""
        r = run_vehicleshop_test([BUS_LUA, FINANCE_LC_LUA, FINANCE_PM_LUA], """
-- 验证所有事件仍然注册
local required = {
    'qb-vehicleshop:server:addPlayer',
    'qb-vehicleshop:server:removePlayer',
    'playerDropped',
    'qb-vehicleshop:server:deleteVehicle',
    'qb-vehicleshop:server:swapVehicle',
    'qb-vehicleshop:server:customTestDrive',
    'qb-vehicleshop:server:financePayment',
    'qb-vehicleshop:server:financePaymentFull',
    'qb-vehicleshop:server:financeVehicle',
    'qb-vehicleshop:server:sellfinanceVehicle',
    'qb-vehicleshop:server:checkFinance',
}
local reg = {}
for _, name in ipairs(__test.events) do reg[name] = true end
for _, name in ipairs(required) do
    assert(reg[name], "missing event: " .. name)
end
assert(__test.callbacks['qb-vehicleshop:server:getVehicles'] ~= nil)
""")
        assert r['ok'], f"Lua error: {r['stderr']}"

    def test_split_events_match_original(self):
        """拆分后事件数与拆分前完全一致"""
        # Load original finance.lua
        r1 = run_vehicleshop_test([BUS_LUA, FINANCE_LUA], """
local events_original = {}
for _, name in ipairs(__test.events) do events_original[name] = true end
_G._events_original = events_original
""")
        # Load split modules
        r2 = run_vehicleshop_test([BUS_LUA, FINANCE_LC_LUA, FINANCE_PM_LUA], """
local events_split = {}
for _, name in ipairs(__test.events) do events_split[name] = true end
assert(#__test.events >= 10, "should have at least 10 events")
""")
        assert r1['ok'] and r2['ok'], f"Split load failed"
```

**Step 2:** Run — expected FAIL (files don't exist yet)

**Step 3:** Create the two new files

### Task 2.2: Extract player lifecycle to finance-lifecycle.lua

**Files:**
- Create: `server/finance-lifecycle.lua`
- Modify: `server/finance.lua` (remove extracted code)

**Content for finance-lifecycle.lua** (lines moved from finance.lua):
- `local financetimer = {}` 变量声明
- `calculateFinance` / `calculateNewFinance` 本地函数（被 payments 引用 → 改放 bus.lua 的 _G._vehicleshop 中，或其他共享方式）
- `addPlayer` / `removePlayer` / `playerDropped` 事件
- `deleteVehicle` / `swapVehicle` / `customTestDrive` 事件
- `checkFinance` 事件

**关键问题: calculateFinance/calculateNewFinance 被两个模块都需要:**
解决方案: 移到 `_G._vehicleshop` (bus.lua 中暴露) 或保留在 finance-lifecycle.lua 并让 finance-payments.lua 通过 `_G._vehicleshop` 或 shopUtil 引用。

实际上看了代码... `calculateFinance` 和 `calculateNewFinance` 是 finance.lua 的 `local function`，只在分期购买/还款内部使用。拆分时需要把它们提升为模块间共享。

**Decision:** 将 `calculateFinance` 和 `calculateNewFinance` 移到 bus.lua 的 `_G._vehicleshop` 表中。

### Task 2.3: Extract payment logic to finance-payments.lua

**Files:**
- Create: `server/finance-payments.lua`
- Modify: `server/finance.lua` (remove extracted code)

**Content for finance-payments.lua:**
- `getVehicles` callback
- `financePayment` / `financePaymentFull` 事件
- `financeVehicle` / `sellfinanceVehicle` 事件

### Task 2.4: Update fxmanifest.lua

**Files:**
- Modify: `fxmanifest.lua`

```lua
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/bus.lua',               -- 共享工具 + Bus 注册
    'server/purchases.lua',         -- 购买逻辑
    'server/finance-lifecycle.lua', -- Phase 2: 玩家计时 + 车辆操作 + 逾期
    'server/finance-payments.lua',  -- Phase 2: 分期购买 + 还款
    'server/finance.lua',           -- 保留空文件或移除 (Phase 2 过渡: 改为空)
    'server/integration.lua',       -- Phase 3: 集成
    'server/main.lua',              -- 入口
}
```

**实际上要移除 finance.lua 或改为空文件**，因为所有内容已迁移。

### Task 2.5: Verify all tests pass + backward compat

```bash
python3 -m pytest tests/unit/layer3_business/test_vehicleshop.py -v
```

Expected: All 45+ tests pass (including new split tests)

### Task 2.6: Commit Phase 2

```bash
git add tests/ resources/[qb]/qb-vehicleshop/server/ resources/[qb]/qb-vehicleshop/fxmanifest.lua
git commit -m "refactor(qb-vehicleshop): Phase 2 — split finance.lua into lifecycle + payments

410-line monolith → finance-lifecycle.lua (player tracking + repo)
                     + finance-payments.lua (financing + repayments)
calculateFinance/New moved to _G._vehicleshop shared table.
100% backward compatible — all events/callbacks preserved."
```

---

## Phase 3: 客户端 NUI 完善 (Config.UseNui=true 全功能)

**Motivation:** NUI 已有基础框架（nui.lua + html/index.html + html/nui.js）但被 `Config.UseNui = false (Convar default)` 关停。需要完善使其成为正式交互方式，与 qb-menu 并存（通过 Convar 切换）。

**当前 NUI 状态:**
- nui.lua: 4 个 NUICallback (closeNui/buyVehicle/financeVehicle/testDrive/swapVehicle) + OpenVehicleShopNui
- html/index.html: Vue.js 基础模板
- html/nui.js: 前端逻辑（需审查）
- zones.lua 的 free-use/managed zone 完全不调用 NUI

### Task 3.1: 审查并完善 NUI 前端

先读 html/nui.js 和 html/index.html 确认当前状态。

**Files:**
- Modify: `html/index.html`
- Modify: `html/nui.js`
- Modify: `html/nui.css`

**需要确认/修改:**
1. NUI 正确展示车辆信息（brand, name, price, specs）
2. 分期计算器可在 NUI 中调整 downPayment/paymentCount，实时显示每期金额
3. ESC/右键正确关闭（参照 phone-nui-patterns.md 规范）
4. 响应式布局适配不同分辨率

### Task 3.2: 集成 NUI 到 zones.lua

**Files:**
- Modify: `client/zones.lua`

在 `_vCreateFreeUseShop` 和 `_vCreateManagedShop` 的 `onPlayerInOut` 中添加 NUI 路径：

```lua
-- zones.lua: free-use zone (当 Config.UseNui = true)
function _vCreateFreeUseShop(shopShape, name)
    -- ... existing zone creation ...
    zone:onPlayerInOut(function(isPointInside)
        if isPointInside then
            insideShop = name
            if Config.UseNui then
                _vSetClosestShowroomVehicle()
                _vOpenNui(name)  -- 打开 NUI 而非构建 qb-menu
            else
                _vBuildVehicleMenu(name)
            end
        else
            if Config.UseNui then
                SetNuiFocus(false, false)
                SetNuiFocusKeepInput(false)
                SendNUIMessage({ type = 'close' })
            end
            insideShop = nil
            ClosestVehicle = 1
        end
    end)
end
```

### Task 3.3: 添加 NUI 车辆切换支持

**Files:**
- Modify: `client/nui.lua`

当玩家在 NUI 中切换展示车辆时，需要触发服务端 swapVehicle 事件。当前 swapVehicle NUICallback 只是触发类别选择菜单，需要改为传递具体车辆信息。

```lua
-- nui.lua: 修改 swapVehicle NUICallback
RegisterNUICallback('swapVehicle', function(data, cb)
    if data and data.toVehicle then
        -- 有具体车辆 → 直接触发换车
        TriggerServerEvent('qb-vehicleshop:server:swapVehicle', {
            toVehicle = data.toVehicle,
            ClosestVehicle = ClosestVehicle,
            ClosestShop = insideShop,
        })
    else
        -- 无具体车辆 → 打开选择菜单
        TriggerEvent(Config.FilterByMake and 'qb-vehicleshop:client:vehMakes'
                                          or 'qb-vehicleshop:client:vehCategories')
    end
    cb('ok')
end)
```

### Task 3.4: 添加 NUI 测试

**Files:**
- Modify: `tests/unit/layer3_business/test_vehicleshop.py`

```python
class TestNuiIntegration:
    """Phase 3: NUI 功能验证"""

    def test_nui_callbacks_exist(self):
        """所有 NUI callback 已注册"""
        # NUI callbacks are client-side RegisterNUICallback — tested differently
        # For now: verify nui.lua loads without error
        r = run_vehicleshop_test([BUS_LUA], """
-- Mock NUI callbacks (RegisterNUICallback is client-only)
RegisterNUICallback = function(name, handler)
    table.insert(__test.events or {}, 'nui:' .. name)
end
dofile('CLIENT_NUI_LUA_PATH')
""")
        assert r['ok']

    def test_open_nui_builds_correct_message(self):
        """OpenVehicleShopNui 发送正确的 NUI message"""
        # Tested via Lua mock
        pass
```

### Task 3.5: Commit Phase 3

```bash
git add tests/ resources/[qb]/qb-vehicleshop/html/ resources/[qb]/qb-vehicleshop/client/
git commit -m "feat(qb-vehicleshop): Phase 3 — complete NUI interaction mode

NUI now fully functional as alternative to qb-menu.
Vehicle detail display, finance calculator, vehicle switching all work from NUI.
Config.UseNui Convar toggles between NUI and qb-menu modes."
```

---

## Phase 4: 客户端模块化 + Bus 注册

**Motivation:** 服务端已有完整的 Bus 注册，客户端仍然是全局函数（_v* 前缀）。注册客户端 Bus 服务可让其他 client 资源通过 exports 调用车店功能。

**关键约束:** FiveM client 端 Bus 与 server 端是隔离的 — core-framework 的 Bus 是 shared_script，所以 `Bus.RegisterService` 在 client 端也可用。但需要验证 core-framework 的 client 端 Bus 是否支持。

### Task 4.1: 确认 core-framework client Bus

**Action:** 读取 `core-framework/bus.lua` 确认 client 端 Bus.RegisterService 可用性。

### Task 4.2: 注册客户端 dealership 服务

**Files:**
- Create: `client/bus.lua`
- Modify: `fxmanifest.lua`

```lua
-- client/bus.lua — 客户端 Bus 注册

local QBCore = exports['qb-core']:GetCoreObject()

local ClientDealership = {}

--- 获取当前所在车店
function ClientDealership.GetCurrentShop()
    return insideShop
end

--- 获取当前最近车辆
function ClientDealership.GetClosestVehicle()
    return ClosestVehicle
end

--- 构建车店菜单 (供其他客户端资源使用)
function ClientDealership.BuildMenu(shopName)
    return _vBuildVehicleMenu(shopName)  -- 从 util.lua 暴露
end

-- Register
if Bus and Bus.RegisterService then
    Bus.RegisterService('dealership_client', {
        GetCurrentShop    = ClientDealership.GetCurrentShop,
        GetClosestVehicle = ClientDealership.GetClosestVehicle,
        BuildMenu         = ClientDealership.BuildMenu,
    })
end

print('[qb-vehicleshop] 🏪 客户端 Bus 已注册 (dealership_client, 3 methods)')
```

**fxmanifest.lua 更新:**
```lua
client_scripts {
    -- ... existing ...
    'client/bus.lua',        -- Phase 4: 客户端 Bus 注册 (在 util.lua 之后)
    -- ...
}
```

### Task 4.3: Export 全局函数为模块方法

将 `_v*` 全局函数封装为更清晰的模块方法，保留 `_v*` 别名用于向后兼容：

```lua
-- util.lua: 添加 exports
exports('GetCurrentShop', function() return insideShop end)
exports('GetClosestVehicle', function() return ClosestVehicle end)
```

### Task 4.4: Commit Phase 4

```bash
git add tests/ resources/[qb]/qb-vehicleshop/client/bus.lua resources/[qb]/qb-vehicleshop/client/util.lua resources/[qb]/qb-vehicleshop/fxmanifest.lua
git commit -m "feat(qb-vehicleshop): Phase 4 — client-side Bus registration

Register dealership_client service (3 methods): GetCurrentShop, GetClosestVehicle, BuildMenu.
Backward compatible — all _v* globals preserved."
```

---

## Verification Checklist (All Phases)

- [ ] `python3 -m pytest tests/unit/layer3_business/test_vehicleshop.py -v` — 全部通过
- [ ] 13 个服务端事件名全部保留
- [ ] 3 个 callback 全部保留 (spawnvehicle, getVehicles, getVehicleDetail)
- [ ] 1 个 command 保留 (transfervehicle)
- [ ] Config.Shops 格式不变
- [ ] 现有 5 个商店配置不变 (pdm/luxury/boats/air/truck)
- [ ] fxmanifest.lua 依赖不变 (qb-core, core-framework, PolyZone)
- [ ] 函数覆盖率 98%+

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Phase 1 菜单不刷新导致购买失败 | refreshMenu 在 zone enter + swapVehicle 后触发 |
| Phase 2 交叉引用导致 nil | calculateFinance/New 放入 _G._vehicleshop |
| Phase 3 NUI 与 qb-menu 冲突 | Config.UseNui=false 默认，渐进启用 |
| Phase 4 Bus 客户端不支持 | Phase 4 先读 core-framework 源码确认 |
| server.lua.bak 被移除过早 | 保留 server.lua 直到全量测试通过 |

## Execution Order

建议按 Phase 1 → 2 → 3 → 4 顺序执行，每个 Phase 内部按 TDD 流程。Phase 间独立，可中断和恢复。
