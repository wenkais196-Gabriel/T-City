"""qb-menu / qb-input → custom-menu 适配层的行为闸门（issue #366）。

为什么是行为用例而不是静态字符串断言：
- 「A 开 → B 关 → A 仍在」只有真的把两个资源跑在同一个 Lua 状态里才证明得了；
- 二级菜单回退、qb-input 取消回传 nil 都是**栈语义**，grep 不出来；
- convar 关闭时行为不变是回滚路径，必须与开启时跑同一套用例做对照。

做法沿用 `test_menu_host.py`：`lua5.4` 沙箱 + 手写 FiveM 原生 stub。
额外用一个很小的协作式调度器（coroutine）复现 `Wait` / `Citizen.Await`，
这样 `qb-input:ShowInput` 的阻塞语义也能在离线环境里驱动。
"""

from __future__ import annotations

import pathlib
import re
import subprocess

PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE = PROJECT_ROOT
MENU_DIR = BASE / "resources" / "[custom]" / "custom-menu"
QB_MENU_DIR = BASE / "resources" / "[qb]" / "qb-menu"
QB_INPUT_DIR = BASE / "resources" / "[qb]" / "qb-input"

MENU_SPEC = (MENU_DIR / "shared" / "menu_spec.lua").as_posix()
MENU_HOST = (MENU_DIR / "client" / "host.lua").as_posix()
QB_MENU_MAIN = (QB_MENU_DIR / "client" / "main.lua").as_posix()
QB_MENU_ADAPTER = (QB_MENU_DIR / "client" / "adapter.lua").as_posix()
QB_INPUT_MAIN = (QB_INPUT_DIR / "client" / "main.lua").as_posix()
QB_INPUT_ADAPTER = (QB_INPUT_DIR / "client" / "adapter.lua").as_posix()

PRELUDE = r"""
-- ── FiveM 原生 / 运行时 stub ──────────────────────────────────────────────
-- FiveM 的 Lua 带 table.clone（CfxLua 扩展）；原生 lua5.4 没有
table.clone = table.clone or function(src)
  local copy = {}
  for key, value in pairs(src) do copy[key] = value end
  return copy
end

GlobalState = {}
local USE_ADAPTER = __USE_ADAPTER__
local CURRENT = 'custom-menu'
local INVOKING = nil
local nui = {}
local nuiCallbacks = {}
local netHandlers = {}
local addEventHandlers = {}
local exportFns = {}
local exportProxies = {}
local threads = {}
local serverEvents = {}
local commands = {}
local timer = 1000
local uiTaken, uiOwns = false, false
local pushCalls, popCalls = 0, 0

local function ensureResource(name)
  exportFns[name] = exportFns[name] or {}
  return exportFns[name]
end

local function proxy(res)
  if exportProxies[res] then return exportProxies[res] end
  local p = setmetatable({}, {
    __index = function(_, method)
      return function(_, ...)
        local fns = exportFns[res]
        local fn = fns and fns[method]
        if not fn then
          error(('missing export %s:%s'):format(res, method), 2)
        end
        return fn(...)
      end
    end,
  })
  exportProxies[res] = p
  return p
end

exports = setmetatable({}, {
  __call = function(_, name, fn) ensureResource(CURRENT)[name] = fn end,
  __index = function(_, res) return proxy(res) end,
})

GetCurrentResourceName = function() return CURRENT end
GetInvokingResource = function() return INVOKING end
GetResourceState = function(_name) return 'started' end
GetConvar = function(name, default)
  if name == 'qb_menu_use_custom_menu' then
    return USE_ADAPTER and 'true' or 'false'
  end
  return default
end
GetGameTimer = function() return timer end
SendNUIMessage = function(msg) nui[#nui + 1] = msg end
RegisterNUICallback = function(name, fn)
  nuiCallbacks[CURRENT] = nuiCallbacks[CURRENT] or {}
  nuiCallbacks[CURRENT][name] = fn
end
RegisterNetEvent = function(name, fn)
  netHandlers[name] = netHandlers[name] or {}
  netHandlers[name][#netHandlers[name] + 1] = fn
end
AddEventHandler = function(name, fn)
  addEventHandlers[name] = addEventHandlers[name] or {}
  addEventHandlers[name][#addEventHandlers[name] + 1] = fn
end

local function dispatch(list, ...)
  if not list then return end
  for i = 1, #list do list[i](...) end
end

TriggerEvent = function(name, ...)
  dispatch(netHandlers[name], ...)
  dispatch(addEventHandlers[name], ...)
end
TriggerServerEvent = function(name, ...)
  serverEvents[#serverEvents + 1] = { name = name, args = table.pack(...) }
end
ExecuteCommand = function(cmd) commands[#commands + 1] = cmd end
RegisterCommand = function(name, fn) commands['cmd:' .. name] = fn end
RegisterKeyMapping = function(_name, _label, _input, _key) end

-- 协作式线程：Wait / Citizen.Await 只 yield，测试用 pump() 推进
CreateThread = function(fn) threads[#threads + 1] = coroutine.create(fn) end
Wait = function(ms) coroutine.yield(ms or 0) end
Citizen = {
  Await = function(p)
    while not p.done do coroutine.yield('await') end
    return p.value
  end,
}
promise = {
  new = function()
    local p = { done = false, value = nil }
    function p:resolve(v)
      self.done = true
      self.value = v
    end
    return p
  end,
}

local focusCalls = {}
SetNuiFocus = function(hasFocus, hasCursor)
  focusCalls[#focusCalls + 1] = { hasFocus, hasCursor }
end
SetNuiFocusKeepInput = function(_v) end

local customUiOpen, customUiClose = 0, 0
ensureResource('custom-ui')
exportFns['custom-ui'].OpenMenu = function(_opts) customUiOpen = customUiOpen + 1 end
exportFns['custom-ui'].CloseMenu = function(_opts) customUiClose = customUiClose + 1 end
exportFns['custom-ui'].IsTaken = function() return uiTaken end
exportFns['custom-ui'].Owns = function() return uiOwns end
exportFns['custom-ui'].Push = function(_frame)
  pushCalls = pushCalls + 1
  uiTaken, uiOwns = true, true
  return true
end
exportFns['custom-ui'].Pop = function(_id)
  popCalls = popCalls + 1
  uiTaken, uiOwns = false, false
  return true
end
exportFns['custom-ui'].GuardControls = function(_ms) end

ensureResource('qb-core')
exportFns['qb-core'].GetCoreObject = function()
  return { Shared = { Items = {} } }
end

-- ── 加载真实源码（顺序与 fxmanifest 一致）────────────────────────────────
CURRENT = 'custom-menu'
dofile('__MENU_SPEC__')
dofile('__MENU_HOST__')

CURRENT = 'qb-menu'
dofile('__QB_MENU_ADAPTER__')
dofile('__QB_MENU_MAIN__')

CURRENT = 'qb-input'
dofile('__QB_INPUT_ADAPTER__')
dofile('__QB_INPUT_MAIN__')

-- ── 测试小工具 ────────────────────────────────────────────────────────────
local function pump(rounds)
  for _ = 1, rounds or 400 do
    local any = false
    local snapshot = #threads
    for i = 1, snapshot do
      local co = threads[i]
      if coroutine.status(co) == 'suspended' then
        local ok, err = coroutine.resume(co)
        if not ok then error('thread error: ' .. tostring(err)) end
        if coroutine.status(co) ~= 'dead' then any = true end
      end
    end
    if not any then return end
  end
  error('pump: 线程在 400 轮内没有收敛（疑似死等）')
end

local function lastNui(action)
  for i = #nui, 1, -1 do
    if nui[i].action == action then return nui[i] end
  end
  return nil
end

local function countNui(action)
  local n = 0
  for i = 1, #nui do
    if nui[i].action == action then n = n + 1 end
  end
  return n
end

local function callNui(resource, name, payload)
  local group = nuiCallbacks[resource]
  local cb = group and group[name]
  assert(cb, ('missing NUI callback %s:%s'):format(resource, name))
  local responses = {}
  cb(payload or {}, function(r) responses[#responses + 1] = r end)
  return responses[1]
end
"""


def _find_lua54() -> str:
    import shutil

    for candidate in ("lua5.4", "lua5.4.exe", "lua54"):
        found = shutil.which(candidate)
        if found:
            return found
    raise RuntimeError("lua5.4 binary is not available on PATH")


def _run(scenario: str, use_adapter: bool = True) -> None:
    files = {
        "__MENU_SPEC__": MENU_SPEC,
        "__MENU_HOST__": MENU_HOST,
        "__QB_MENU_MAIN__": QB_MENU_MAIN,
        "__QB_MENU_ADAPTER__": QB_MENU_ADAPTER,
        "__QB_INPUT_MAIN__": QB_INPUT_MAIN,
        "__QB_INPUT_ADAPTER__": QB_INPUT_ADAPTER,
    }
    prelude = PRELUDE.replace("__USE_ADAPTER__", "true" if use_adapter else "false")
    for key, path in files.items():
        prelude = prelude.replace(key, path)
    proc = subprocess.run(
        [_find_lua54(), "-e", prelude + scenario],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=20,
    )
    assert proc.returncode == 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    assert "OK" in proc.stdout, f"scenario did not print OK:\n{proc.stdout}"


ROOT_MENU = """
    { header = 'Root menu', isMenuHeader = true },
    { header = 'Open child', txt = 'sub', params = { event = 'test:open_child' } },
"""


def test_cross_resource_close_does_not_touch_other_resources_menu() -> None:
    """反例 #1：A 开菜单 → B 调 closeMenu → A 仍在；A 自己关才生效。

    改造前 qb-menu 是全局单例，B 的 closeMenu 会把 A 关掉（这就是 issue 里
    `cl_org.lua` 提示循环误关产业面板的那条）。这个用例在适配层落地前必须是红的。
    """
    _run(
        """
INVOKING = 'resource-a'
exports['qb-menu']:openMenu({ __ROOT_MENU__ })
assert(exports['custom-menu']:IsOpen() == true, 'A 打开后 custom-menu 必须是开的')

INVOKING = 'resource-b'
exports['qb-menu']:closeMenu()
assert(exports['custom-menu']:IsOpen() == true,
    'B 的 closeMenu 不许关掉 A 的菜单（归因错误）')

INVOKING = 'resource-a'
exports['qb-menu']:closeMenu()
assert(exports['custom-menu']:IsOpen() == false, 'A 自己的 closeMenu 必须生效')
print('OK')
""".replace("__ROOT_MENU__", ROOT_MENU)
    )


def test_duplicate_open_keeps_single_frame() -> None:
    """反例 #2：同一资源连开两次 → custom-ui 只推一帧，不出现两个浮层。"""
    _run(
        """
INVOKING = 'resource-a'
exports['qb-menu']:openMenu({ __ROOT_MENU__ })
local firstPush = pushCalls
exports['qb-menu']:openMenu({
    { header = 'Second menu', isMenuHeader = true },
    { header = 'Only item', params = { event = 'test:noop' } },
})
assert(exports['custom-menu']:IsOpen() == true)
assert(pushCalls == firstPush, '重复 open 不许再推 custom-ui 帧')
assert(countNui('menu:open') == 2, '第二次 open 应替换当前菜单')
assert(lastNui('menu:open').spec.title == 'Second menu')
print('OK')
""".replace("__ROOT_MENU__", ROOT_MENU)
    )


def test_nested_menus_push_and_back_returns_to_parent() -> None:
    """反例 #3：三层嵌套返回第 2 层时内容正确，不是回到最外层。"""
    _run(
        """
INVOKING = 'resource-a'
RegisterNetEvent('test:open_child', function()
    exports['qb-menu']:openMenu({
        { header = 'Child menu', isMenuHeader = true },
        { header = 'Open grandchild', params = { event = 'test:open_grandchild' } },
    })
end)
RegisterNetEvent('test:open_grandchild', function()
    exports['qb-menu']:openMenu({
        { header = 'Grandchild menu', isMenuHeader = true },
        { header = 'Grandchild action', params = { event = 'test:noop' } },
    })
end)

exports['qb-menu']:openMenu({ __ROOT_MENU__ })
local rootOpen = lastNui('menu:open')
callNui('custom-menu', 'nui:ack', { ackToken = rootOpen.ackToken })

local level2 = callNui('custom-menu', 'nui:intent', {
    menuId = rootOpen.spec.id, itemId = 'i2',
    intent = 'qb-menu:resource-a:menu', args = { slot = 2 },
})
assert(level2 and level2.dispatched == 'submenu' and level2.depth == 2, '二级菜单应入栈')
assert(lastNui('menu:update').spec.title == 'Child menu')

local childSpec = lastNui('menu:update').spec
local level3 = callNui('custom-menu', 'nui:intent', {
    menuId = childSpec.id, itemId = 'i2',
    intent = 'qb-menu:resource-a:menu', args = { slot = 2 },
})
assert(level3 and level3.dispatched == 'submenu' and level3.depth == 3, '三级菜单应入栈')
assert(lastNui('menu:update').spec.title == 'Grandchild menu')

local back1 = callNui('custom-menu', 'nui:back', {})
assert(back1.depth == 2, '第一次返回应回到第 2 层')
assert(lastNui('menu:update').spec.title == 'Child menu', '不是回到最外层')

local back2 = callNui('custom-menu', 'nui:back', {})
assert(back2.depth == 1, '第二次返回应回到第 1 层')
assert(lastNui('menu:update').spec.title == 'Root menu')
print('OK')
""".replace("__ROOT_MENU__", ROOT_MENU)
    )


def test_qb_input_submit_returns_form_values() -> None:
    """qb-input 表单提交：值必须原样回到调用方（老调用方按下标读）。"""
    _run(
        """
INVOKING = 'resource-a'
local result = 'unset'
local shown = false

threads[#threads + 1] = coroutine.create(function()
    result = exports['qb-input']:ShowInput({
        header = 'Sell item',
        submitText = 'Sell',
        inputs = {
            { type = 'number', name = 'amount', text = 'Amount', isRequired = true, default = '1' },
            { type = 'text', name = 'note', text = 'Note' },
        },
    })
    shown = true
end)

threads[#threads + 1] = coroutine.create(function()
    while not lastNui('menu:open') do coroutine.yield() end
    local openMsg = lastNui('menu:open')
    assert(openMsg.spec.surface == 'form', 'qb-input 必须映射成 form surface')
    callNui('custom-menu', 'nui:ack', { ackToken = openMsg.ackToken })
    callNui('custom-menu', 'nui:intent', {
        menuId = openMsg.spec.id,
        itemId = '__form__',
        intent = openMsg.spec.intent,
        values = { amount = '7', note = 'hello' },
    })
end)

pump()
assert(shown == true, 'ShowInput 没有返回（线程悬挂）')
assert(type(result) == 'table')
assert(result.amount == '7')
assert(result.note == 'hello')
assert(exports['custom-menu']:IsOpen() == false, '提交后菜单必须关闭')
print('OK')
"""
    )


def test_qb_input_cancel_resolves_nil() -> None:
    """qb-input 取消路径：老调用方普遍写 `if not result then`，必须回传 nil。"""
    _run(
        """
INVOKING = 'resource-a'
local result = 'unset'
local shown = false

threads[#threads + 1] = coroutine.create(function()
    result = exports['qb-input']:ShowInput({
        header = 'Sell item',
        inputs = {
            { type = 'number', name = 'amount', text = 'Amount' },
        },
    })
    shown = true
end)

threads[#threads + 1] = coroutine.create(function()
    while not lastNui('menu:open') do coroutine.yield() end
    local openMsg = lastNui('menu:open')
    callNui('custom-menu', 'nui:ack', { ackToken = openMsg.ackToken })
    callNui('custom-menu', 'nui:close', { reason = 'form_cancel' })
end)

pump()
assert(shown == true, '取消后 ShowInput 必须返回（线程悬挂）')
assert(result == nil, '取消必须回传 nil，实际 ' .. tostring(result))
assert(exports['custom-menu']:IsOpen() == false)
print('OK')
"""
    )


def test_qb_input_unsupported_types_fall_back_to_legacy_dialog() -> None:
    """select/radio/color 无法无损映射到 MenuSpec：整张对话框回退旧 NUI。"""
    _run(
        """
INVOKING = 'resource-a'
local result = 'unset'
local shown = false

threads[#threads + 1] = coroutine.create(function()
    result = exports['qb-input']:ShowInput({
        header = 'Paint',
        inputs = {
            { type = 'select', name = 'primary', text = 'Primary',
              options = { { value = 'none', text = 'None' } } },
        },
    })
    shown = true
end)

threads[#threads + 1] = coroutine.create(function()
    while not lastNui('OPEN_MENU') do coroutine.yield() end
    -- 旧对话框还开着时，第二张（哪怕类型可适配）必须直接返回 nil：
    -- 旧实现的全局单飞 `if properties then return end` 不能丢。
    local second = exports['qb-input']:ShowInput({
        header = 'Second',
        inputs = { { type = 'number', name = 'n', text = 'N' } },
    })
    assert(second == nil, '旧对话框开着时第二次 ShowInput 必须返回 nil')
    callNui('qb-input', 'buttonSubmit', { data = { primary = 'none' } })
end)

pump()
assert(shown == true)
assert(type(result) == 'table' and result.primary == 'none', '回退路径必须返回旧格式')
assert(exports['custom-menu']:IsOpen() == false, '回退路径不许占用 custom-menu')
assert(#focusCalls > 0, '回退路径沿用旧 SetNuiFocus（与改造前一致）')
print('OK')
"""
    )


def test_convar_off_keeps_legacy_behavior() -> None:
    """回滚路径：convar 关闭时 qb-menu / qb-input 的老页面与焦点调用一行不变。"""
    _run(
        """
INVOKING = 'resource-a'
exports['qb-menu']:openMenu({ __ROOT_MENU__ })
assert(exports['custom-menu']:IsOpen() == false, 'convar 关闭时不许碰 custom-menu')
local openMsg = lastNui('OPEN_MENU')
assert(openMsg and openMsg.data[1].header == 'Root menu', '老 NUI 必须收到 OPEN_MENU')
assert(customUiOpen == 1, '老路径必须走 custom-ui:OpenMenu')

exports['qb-menu']:closeMenu()
assert(customUiClose == 1, '老路径必须走 custom-ui:CloseMenu')
assert(lastNui('CLOSE_MENU') ~= nil)

nui = {} -- 清掉 qb-menu 那条 OPEN_MENU，避免 qb-input 用例误匹配
local result = 'unset'
local shown = false
threads[#threads + 1] = coroutine.create(function()
    result = exports['qb-input']:ShowInput({
        header = 'Legacy form',
        inputs = { { type = 'number', name = 'amount', text = 'Amount' } },
    })
    shown = true
end)
threads[#threads + 1] = coroutine.create(function()
    while not lastNui('OPEN_MENU') do coroutine.yield() end
    callNui('qb-input', 'buttonSubmit', { data = { amount = '3' } })
end)
pump()
assert(shown == true)
assert(result and result.amount == '3', '老 qb-input 必须返回表单值')
assert(#focusCalls > 0, '老 qb-input 自己调 SetNuiFocus')
assert(exports['custom-menu']:IsOpen() == false)
print('OK')
""".replace("__ROOT_MENU__", ROOT_MENU),
        use_adapter=False,
    )


def test_global_state_enables_adapter_and_rejects_when_both_signals_off() -> None:
    """真机事故复现：服务端 convar=true、客户端 `GetConvar` 读不到 → 旧 UI。

    适配层因此改成「GlobalState 优先、convar 兜底」，并且**在调用时判断**。
    这条用例故意把 convar 置 false（模拟客户端读不到），只把 GlobalState 置 true：
    适配层必须接管，老 NUI 一条消息都不许发。
    """
    _run(
        """
GlobalState.qb_menu_use_custom_menu = true
INVOKING = 'resource-a'
exports['qb-menu']:openMenu({ __ROOT_MENU__ })
assert(exports['custom-menu']:IsOpen() == true, 'GlobalState 打开时必须接管')
assert(lastNui('OPEN_MENU') == nil, '接管后老 NUI 不许再收到 OPEN_MENU')
print('OK')
""".replace("__ROOT_MENU__", ROOT_MENU),
        use_adapter=False,   # convar 侧是 false —— 只有 GlobalState 为真
    )
    # 反向：两个信号都关时必须**拒绝接管**并回退老路径（否则就是"永远接管"的假绿）
    _run(
        """
GlobalState.qb_menu_use_custom_menu = false
INVOKING = 'resource-a'
exports['qb-menu']:openMenu({ __ROOT_MENU__ })
assert(exports['custom-menu']:IsOpen() == false, '两个信号都关时不许接管')
assert(lastNui('OPEN_MENU') ~= nil, '必须回退老 NUI')
print('OK')
""".replace("__ROOT_MENU__", ROOT_MENU),
        use_adapter=False,
    )


# --------------------------------------------------------------------------- #
# 静态红线（带反向校验）
# --------------------------------------------------------------------------- #

FOCUS_RE = re.compile(r"\bSetNuiFocus(?:KeepInput)?\s*\(")
NET_EVENT_RE = re.compile(r"\bRegisterNetEvent\s*\(")


def _code_only(source: str) -> str:
    """注释里提到 API 不算调用。"""
    return "\n".join(line.split("--", 1)[0] for line in source.splitlines())


def _scan(pattern, sources: list[tuple[str, str]]) -> list[str]:
    return [
        f"{name}:{lineno}"
        for name, source in sources
        for lineno, line in enumerate(_code_only(source).splitlines(), start=1)
        if pattern.search(line)
    ]


def test_adapter_code_never_writes_focus_or_registers_net_events() -> None:
    """适配层只走 custom-menu 的导出：0 处 SetNuiFocus、0 个新 net event。"""
    sources = [
        (path.name, path.read_text(encoding="utf-8"))
        for path in (pathlib.Path(QB_MENU_ADAPTER), pathlib.Path(QB_INPUT_ADAPTER))
    ]
    assert not _scan(FOCUS_RE, sources), "适配层不许出现 SetNuiFocus（焦点归 custom-ui 栈）"
    assert not _scan(NET_EVENT_RE, sources), "适配层不许 RegisterNetEvent（不新增 net event）"

    # 反向校验：喂进坏形状，两条规则都必须红
    bad = [("fake.lua", "SetNuiFocus(true, true)\nRegisterNetEvent('evil:event', function() end)\n")]
    assert len(_scan(FOCUS_RE, bad)) == 1
    assert len(_scan(NET_EVENT_RE, bad)) == 1

def test_no_bom_in_new_lua_files_detects_a_bom(tmp_path) -> None:
    """Lua 文件开头带 UTF-8 BOM 会让 `luac`/FiveM 解析直接失败（症状极难认）。

    2026-11-26 真机：`qb-input/client/adapter.lua:1: unexpected symbol near '<239>'`，
    原因是文件以 `EF BB BF` 开头 —— 而 `luac -p` 在 Windows 上按字节读也会拒它，
    但只对**被改过的**文件生效，没人会为每条命令重跑语法检查。所以加一条全树扫描。
    """
    import pathlib as _pl

    resources = _pl.Path(__file__).resolve().parents[2] / "resources"
    bad = []
    for lua in resources.rglob("*.lua"):
        with lua.open("rb") as fh:
            if fh.read(3) == b"\xef\xbb\xbf":
                bad.append(str(lua.relative_to(resources)))
    assert bad == [], "以下 Lua 文件带 UTF-8 BOM，FiveM 会解析失败：\n" + "\n".join(bad)

# --------------------------------------------------------------------------- #
# 跨资源序列化闸门（真机 #366 事故）
# --------------------------------------------------------------------------- #

def _non_json_route_fields(source: str) -> list[str]:
    """返回路由表里出现的函数字段（跨资源必丢）以及非 resource 的路由类型。"""
    problems: list[str] = []
    for match in re.finditer(r"RegisterIntent',\s*[^,]+,\s*\{(.*?)\n\s*\}\)", source, re.S):
        body = match.group(1)
        if re.search(r"\b(handler|builder)\s*=\s*function", body):
            problems.append("route carries a function: " + body.strip().splitlines()[0])
        if not re.search(r"type\s*=\s*'resource'", body):
            problems.append("route is not type='resource': " + body.strip().splitlines()[0])
    return problems


def test_intent_routes_rejects_function_fields_and_non_resource_types() -> None:
    """跨资源注册的 route 不许带函数，且必须走 type='resource'。

    2026-11-26 真机：qb-menu 往 custom-menu 注册 `{type='client', handler=<闭包>}`。
    闭包穿过资源边界时被序列化丢弃 → 对面收到 route.handler=nil →
    判定 `client_route_requires_event_or_handler` → 注册失败 → 静默回退旧 NUI。
    沙箱里函数能过界，所以原来的单测全绿。现在两条都钉住：
    路由只带字符串（resource/method），回调走对方资源的导出。
    """
    for name in ("qb-menu/client/adapter.lua", "qb-input/client/adapter.lua"):
        src = (BASE / "resources" / "[qb]" / name).read_text(encoding="utf-8")
        assert _non_json_route_fields(src) == [], f"{name}: {_non_json_route_fields(src)}"

    # 自证：把一条带闭包的路由喂进校验器，必须被识别
    poisoned = "callMenu('RegisterIntent', intentId, {\n        type = 'client',\n        handler = function(ctx) end,\n    })"
    assert _non_json_route_fields(poisoned) != [], "校验器抓不住函数路由，等于没有闸门"


def test_disabled_without_event_maps_to_info_and_rejects_all_disabled_regression() -> None:
    """issue #374：disabled=true 且无 params.event 必须映射成 info（hint=txt）；带 event 保持 disabled action。"""
    industry_menu = """
    { header = '洛圣都矿业公司 · L1 · Mine Owner', isMenuHeader = true, icon = 'fa-solid fa-industry' },
    { header = '金库余额', txt = '$4,195,095', icon = 'fa-solid fa-vault', disabled = true },
    { header = '尚未建设施', icon = 'fa-solid fa-hammer', disabled = true },
    { header = '雇工位（$123,018）', txt = '资金不足', icon = 'fa-solid fa-user-plus', disabled = true, params = { event = 'industry:client:hire' } },
    { header = '返回', icon = 'fa-solid fa-angle-left', params = { event = 'qb-orgmenu:client:OpenMenu' } },
"""
    _run(
        """
INVOKING = 'custom-industry'
exports['qb-menu']:openMenu({ __IND_MENU__ })
local openMsg = lastNui('menu:open')
assert(openMsg and openMsg.spec, 'custom-menu 必须收到 menu:open')
local items = openMsg.spec.items
assert(#items == 4, '应该有 4 行（标题进 title），实际 ' .. tostring(#items))

-- 1. 信息行（带 txt）：kind=info、hint=txt、无 disabled/intent/args/description
local infoRow = items[1]
assert(infoRow.kind == 'info', '无 params.event 的 disabled 行必须映射成 kind=info，实际 ' .. tostring(infoRow.kind))
assert(infoRow.hint == '$4,195,095', 'info.hint 必须取原来的 txt，实际 ' .. tostring(infoRow.hint))
assert(infoRow.disabled == nil, 'info 行不许带 disabled')
assert(infoRow.intent == nil, 'info 行不许带 intent')
assert(infoRow.args == nil, 'info 行不许带 args')
assert(infoRow.description == nil, 'info 行值应放 hint，不重复放 description')

-- 2. 信息行（缺 txt）：kind=info、hint=nil、校验仍通过
local emptyInfo = items[2]
assert(emptyInfo.kind == 'info', '缺 txt 的无动作 disabled 行也应映射成 info')
assert(emptyInfo.hint == nil, '缺 txt 时 hint 应为 nil')
assert(emptyInfo.disabled == nil and emptyInfo.intent == nil)

-- 3. 禁用动作行（带 params.event）：保持 disabled action，且带 disabledReason
local disabledAct = items[3]
assert(disabledAct.kind == 'action', '带 params.event 的 disabled 行必须保持 action，实际 ' .. tostring(disabledAct.kind))
assert(disabledAct.disabled == true, '禁用动作行必须保留 disabled=true')
assert(disabledAct.disabledReason == '资金不足', '禁用动作行必须带 disabledReason，实际 ' .. tostring(disabledAct.disabledReason))
assert(type(disabledAct.intent) == 'string' and #disabledAct.intent > 0, '禁用动作行必须保留 intent')

-- 4. 正常动作行
local normalAct = items[4]
assert(normalAct.kind == 'action' and normalAct.disabled == nil)
print('OK')
""".replace("__IND_MENU__", industry_menu)
    )

    # convar 关闭回滚路径：必须原样进老 NUI OPEN_MENU，保留 disabled = true
    _run(
        """
INVOKING = 'custom-industry'
exports['qb-menu']:openMenu({ __IND_MENU__ })
assert(exports['custom-menu']:IsOpen() == false, 'convar 关闭时不许碰 custom-menu')
local legacyMsg = lastNui('OPEN_MENU')
assert(legacyMsg and legacyMsg.data[2].disabled == true, 'convar 关闭时老 NUI 必须保持原样')
print('OK')
""".replace("__IND_MENU__", industry_menu),
        use_adapter=False,
    )

    # 反向自证：把适配层改回“全 disabled action”的旧写法，在真实 Lua 沙箱里跑同一套菜单必须红
    adapter_src = pathlib.Path(QB_MENU_ADAPTER).read_text(encoding="utf-8")
    anchor = "if legacy.isMenuHeader == true or (legacy.disabled == true and not hasLegacyAction(legacy)) then"
    assert anchor in adapter_src, "未找到适配层信息行映射分支"
    mutated_adapter = adapter_src.replace(anchor, "if legacy.isMenuHeader == true then", 1)
    mutated_prelude = PRELUDE.replace("__USE_ADAPTER__", "true")
    for key, path in {
        "__MENU_SPEC__": MENU_SPEC,
        "__MENU_HOST__": MENU_HOST,
        "__QB_MENU_MAIN__": QB_MENU_MAIN,
        "__QB_MENU_ADAPTER__": QB_MENU_ADAPTER,
        "__QB_INPUT_MAIN__": QB_INPUT_MAIN,
        "__QB_INPUT_ADAPTER__": QB_INPUT_ADAPTER,
    }.items():
        mutated_prelude = mutated_prelude.replace(key, path)
    # 用临时篡改后的适配层源码替换 dofile(QB_MENU_ADAPTER)
    mutated_prelude = mutated_prelude.replace(
        f"dofile('{QB_MENU_ADAPTER}')",
        f"assert(load({mutated_adapter!r}))()",
    )
    bad_proc = subprocess.run(
        [
            _find_lua54(),
            "-e",
            mutated_prelude
            + """
INVOKING = 'custom-industry'
exports['qb-menu']:openMenu({ __IND_MENU__ })
local items = lastNui('menu:open').spec.items
assert(items[1].kind == 'info' and items[1].disabled == nil)
print('OK')
""".replace("__IND_MENU__", industry_menu),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=20,
    )
    assert bad_proc.returncode != 0, "反向注入失效：把适配层改回全 disabled 后用例竟然仍通过"


# ══════════════════════════════════════════════════════════════════════════
# custom-menu 重启后的自愈（2026-11-27 真机故障）
#
# 故障链：qb-menu 用 state.routes 记住"这两个 intent 注册过了"。custom-menu 一被
# restart，它的注册表就空了，但 qb-menu 还记着 → 之后每次 open 都跳过注册 →
# `Open` 整单拒绝 `Unknown intent "qb-menu:qb-management:menu"` →
# 玩家按 E / 敲 /orgmenu 什么都开不出来，直到 qb-menu 也重启。
# ══════════════════════════════════════════════════════════════════════════

def test_unknown_intent_rejection_self_heals() -> None:
    """custom-menu 拒单说 Unknown intent 时，适配层必须重注册并重试一次。"""
    _run(
        """
INVOKING = 'qb-management'
exports['qb-menu']:openMenu({ __ROOT_MENU__ })
assert(exports['custom-menu']:IsOpen() == true, '首次打开必须成功')
exports['qb-menu']:closeMenu()

-- 模拟 custom-menu 重启后的拒单：第一次 Open 直接回 Unknown intent
local realOpen = exportFns['custom-menu'].Open
local rejected = 0
exportFns['custom-menu'].Open = function(self, spec)
  if rejected == 0 then
    rejected = rejected + 1
    return false, 'Unknown intent "qb-menu:qb-management:menu" at items[2]'
  end
  return realOpen(self, spec)
end

exports['qb-menu']:openMenu({ __ROOT_MENU__ })
assert(rejected == 1, '测试前提没生效：Open 没有被拒一次')
assert(exports['custom-menu']:IsOpen() == true,
    'Unknown intent 之后必须自愈（重注册 + 重试），不能整单放弃')
print('OK')
""".replace("__ROOT_MENU__", ROOT_MENU)
    )


def _selfheal_contract(source: str) -> list[str]:
    """静态契约：两条自愈路径必须都在。抽出来才能自证闸门会红。"""
    errors: list[str] = []
    # 注意别用子串判断：把事件名改长成 `onClientResourceStartDisabled`，
    # 旧写法 `"onClientResourceStart" in source` 仍然为真，闸门就成了橡皮章。
    if "AddEventHandler('onClientResourceStart'" not in source:
        errors.append("缺少 onClientResourceStart 监听：custom-menu 重启后不会清 routes 记忆")
    elif "state.routes = {}" not in source:
        errors.append("onClientResourceStart 里没有清空 state.routes")
    if "Unknown intent" not in source:
        errors.append("缺少 Unknown intent 自愈重试")
    return errors


def test_adapter_keeps_restart_selfheal_paths() -> None:
    source = pathlib.Path(QB_MENU_ADAPTER).read_text(encoding="utf-8")
    errors = _selfheal_contract(source)
    assert not errors, "适配层自愈契约被破坏：\n" + "\n".join(errors)


def test_selfheal_contract_gate_is_not_a_rubber_stamp() -> None:
    """自证：把两条自愈路径删掉，契约检查必须报错。"""
    source = pathlib.Path(QB_MENU_ADAPTER).read_text(encoding="utf-8")
    assert not _selfheal_contract(source)
    gutted = source.replace("onClientResourceStart", "onClientResourceStartDisabled")
    assert _selfheal_contract(gutted), "删掉资源启动监听后闸门仍然全绿 —— 这条闸门是假的"
    no_retry = source.replace("Unknown intent", "unknown-intent")
    assert _selfheal_contract(no_retry), "删掉 Unknown intent 判定后闸门仍然全绿 —— 这条闸门是假的"


def test_runtime_convar_switch_wins_over_stale_boot_globalstate() -> None:
    """启动时 convar=false 把 GlobalState 写成 false，之后 `setr ... true` 必须能生效。

    没有这条，`isEnabled()` 会在 `shared == false` 处短路，convar 兜底永远走不到 ——
    表现就是"开关改了但菜单还是原版"（2026-11-27 真机：要靠 restart qb-menu 才生效）。
    """
    _run(
        """
GlobalState.qb_menu_use_custom_menu = false   -- 启动快照（convar 当时是 false）
-- convar 侧此时已经是 'true'（_run 的 USE_ADAPTER=true 就是这个含义）
assert(GetConvar('qb_menu_use_custom_menu', 'false') == 'true', '测试前提：convar 必须为 true')
INVOKING = 'resource-runtime'
exports['qb-menu']:openMenu({ __ROOT_MENU__ })
assert(exports['custom-menu']:IsOpen() == true,
    'GlobalState 的启动快照不许压掉运行期的 convar 开关')
print('OK')
""".replace("__ROOT_MENU__", ROOT_MENU)
    )
