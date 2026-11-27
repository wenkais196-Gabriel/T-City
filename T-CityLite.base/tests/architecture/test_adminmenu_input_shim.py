"""#348 (M6) — qb-adminmenu 迁出 menuv，全屏走 custom-menu / MenuSpec 与下线 menuv 闸门。

验证内容：
  1) menuv 下线：menu_shim.lua 删除、fxmanifest 去 @menuv / dependency 'menuv'、
     configs/modules/core.cfg 去 ensure menuv、全仓非 [standalone]/menuv 目录归 0，
     且 [standalone]/menuv 目录保持存在（只读不删）；
  2) qb-adminmenu 入口与全屏迁移：17 张菜单（menu1–menu15 + Players + EditDealer）
     及 Range / Form / Confirm 子视图在 Lua 5.4 沙箱下逐屏构建并通过 MenuSpec.Validate，
     且禁用屏幕键盘（LocalInput / LocalInputInt）；
  3) 焦点与禁控守恒：qb-adminmenu / menuv 零 SetNuiFocus；client.lua 零 DisableAllControlActions
     （仅保留 noclip.lua 非菜单飞行屏蔽 3 处）；
  4) 全部规则自带正向 + 反向注入（把任意一屏改回 menuv / 恢复 LocalInput / 恢复 shim → 必须红）。
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

from lua_source import blank_noise

BASE = Path(__file__).resolve().parents[2]
ADMINMENU = BASE / "resources" / "[qb]" / "qb-adminmenu"
MENUV = BASE / "resources" / "[standalone]" / "menuv"
CUSTOM_MENU_SPEC = BASE / "resources" / "[custom]" / "custom-menu" / "shared" / "menu_spec.lua"
CORE_CFG = BASE / "configs" / "modules" / "core.cfg"
SHIM = ADMINMENU / "client" / "menu_shim.lua"
SPECS = ADMINMENU / "client" / "menu_specs.lua"
CLIENT = ADMINMENU / "client" / "client.lua"
MANIFEST = ADMINMENU / "fxmanifest.lua"

# 17 张原 MenuV 菜单 + 拆出的 Form/Range/Confirm 子视图与各自 intent / MenuSpec id
EXPECTED_SCREENS: tuple[tuple[str, str, str], ...] = (
    ("menu1", "qb_adminmenu_menu1", "adminmenu:open:menu1"),
    ("menu2", "qb_adminmenu_menu2", "adminmenu:open:menu2"),
    ("menu15", "qb_adminmenu_menu15", "adminmenu:open:menu15"),
    ("menu3", "qb_adminmenu_menu3", "adminmenu:open:menu3"),
    ("menu3_time", "qb_adminmenu_menu3_time", "adminmenu:open:menu3_time"),
    ("menu8", "qb_adminmenu_menu8", "adminmenu:open:menu8"),
    ("menu4", "qb_adminmenu_menu4", "adminmenu:open:menu4"),
    ("Players", "qb_adminmenu_player", "adminmenu:open:player"),
    ("menu10", "qb_adminmenu_menu10", "adminmenu:open:menu10"),
    ("menu9", "qb_adminmenu_menu9", "adminmenu:open:menu9"),
    ("menu9_form", "qb_adminmenu_menu9_form", "adminmenu:open:menu9_form"),
    ("menu11", "qb_adminmenu_menu11", "adminmenu:open:menu11"),
    ("menu11_confirm", "qb_adminmenu_menu11_confirm", "adminmenu:open:menu11_confirm"),
    ("menu5", "qb_adminmenu_menu5", "adminmenu:open:menu5"),
    ("menu12", "qb_adminmenu_menu12", "adminmenu:open:menu12"),
    ("menu13", "qb_adminmenu_menu13", "adminmenu:open:menu13"),
    ("menu6", "qb_adminmenu_menu6", "adminmenu:open:menu6"),
    ("EditDealer", "qb_adminmenu_dealer", "adminmenu:open:dealer"),
    ("dealer_delete_confirm", "qb_adminmenu_dealer_delete_confirm", "adminmenu:open:dealer_delete_confirm"),
    ("menu7", "qb_adminmenu_menu7", "adminmenu:open:menu7"),
    ("menu14", "qb_adminmenu_menu14", "adminmenu:open:menu14"),
    ("menu14_distance", "qb_adminmenu_menu14_distance", "adminmenu:open:menu14_distance"),
)


def read(path: Path) -> str:
    assert path.is_file(), f"missing {path}"
    return path.read_text(encoding="utf-8", errors="ignore")


def _sources(resource: Path) -> dict[str, str]:
    return {
        path.relative_to(resource).as_posix(): read(path)
        for path in sorted(resource.rglob("*.lua"))
    }


# ---------------------------------------------------------------------------
# 1) menuv 下线 + 垫片清理 + 全仓归零校验
# ---------------------------------------------------------------------------

def retirement_violations(
    admin_sources: dict[str, str],
    fxmanifest: str,
    core_cfg: str,
    *,
    has_shim_file: bool,
    menuv_exists: bool = True,
) -> list[str]:
    bad: list[str] = []
    if has_shim_file:
        bad.append("client/menu_shim.lua must be deleted after M6 menuv retirement")
    if not menuv_exists:
        bad.append("resources/[standalone]/menuv directory must remain read-only on disk")

    manifest_code = blank_noise(fxmanifest, keep_strings=True)
    if "@menuv/" in manifest_code or re.search(r"dependency\s+['\"]menuv['\"]", manifest_code):
        bad.append("fxmanifest.lua still references menuv")
    if "client/menu_specs.lua" not in manifest_code:
        bad.append("fxmanifest.lua missing client/menu_specs.lua")
    if re.search(r"dependenc(?:y|ies)[\s\S]*?(custom-menu|custom-ui)", manifest_code):
        bad.append("fxmanifest.lua must not declare static dependency on custom-menu/custom-ui (boot order)")

    cfg_lines = [line.split("#", 1)[0].strip().lower() for line in core_cfg.splitlines()]
    if any(re.match(r"^(ensure|start)\s+menuv\b", ln) for ln in cfg_lines):
        bad.append("configs/modules/core.cfg still ensures menuv")
    if not any(re.match(r"^(ensure|start)\s+qb-adminmenu\b", ln) for ln in cfg_lines):
        bad.append("configs/modules/core.cfg missing ensure qb-adminmenu")

    for rel, src in sorted(admin_sources.items()):
        code = blank_noise(src)
        if re.search(r"\bMenuV\s*[:.]", code):
            bad.append(f"{rel}: still contains MenuV calls")
        if "AdminMenuShim" in code:
            bad.append(f"{rel}: still references AdminMenuShim")
        if "DisplayOnscreenKeyboard" in code or re.search(r"\bLocalInput(?:Int)?\b", code):
            bad.append(f"{rel}: still uses GTA native LocalInput keyboard loop")

    return bad


def test_adminmenu_menuv_retired_rejects_shim_and_manifest_refs():
    sources = _sources(ADMINMENU)
    fx = read(MANIFEST)
    cfg = read(CORE_CFG)
    errs = retirement_violations(
        sources,
        fx,
        cfg,
        has_shim_file=SHIM.exists(),
        menuv_exists=(MENUV / "fxmanifest.lua").is_file(),
    )
    assert errs == [], "\n".join(errs)

    # 非 menuv 资源全局引用必须归零（仅允许 [standalone]/menuv 自身）
    for lua_path in sorted((BASE / "resources").rglob("*.lua")):
        rel = lua_path.relative_to(BASE).as_posix()
        if rel.startswith("resources/[standalone]/menuv/"):
            continue
        code = blank_noise(read(lua_path))
        assert not re.search(r"\bMenuV\s*[:.]", code), f"{rel} still uses MenuV"

    # 反向注入 1：把 menu_shim.lua 放回 / fxmanifest 加回 menuv / core.cfg 加回 ensure menuv → 必须红
    assert retirement_violations(sources, fx, cfg, has_shim_file=True)
    assert retirement_violations(sources, fx + "\ndependency 'menuv'\n", cfg, has_shim_file=False)
    assert retirement_violations(sources, fx, cfg + "\nensure menuv\n", has_shim_file=False)

    # 反向注入 2：把某一屏改回 MenuV 或加回 DisplayOnscreenKeyboard → 必须红
    reverted = dict(sources)
    reverted["client/client.lua"] += "\nlocal m = MenuV:CreateMenu(false, 'reverted')\n"
    assert retirement_violations(reverted, fx, cfg, has_shim_file=False)
    native_kbd = dict(sources)
    native_kbd["client/client.lua"] += "\nDisplayOnscreenKeyboard(1, 'FMMC_MPM_NA', '', '', '', '', '', 30)\n"
    assert retirement_violations(native_kbd, fx, cfg, has_shim_file=False)


# ---------------------------------------------------------------------------
# 2) 打开入口：/admin 必须经由 custom-menu:Open 进 custom-ui 焦点栈
# ---------------------------------------------------------------------------

def open_entry_violations(source: str) -> list[str]:
    code = blank_noise(source, keep_strings=True)
    at = code.find("'qb-admin:client:openMenu'")
    if at == -1:
        return ["missing qb-admin:client:openMenu handler"]
    block = code[at:at + 400]
    bad: list[str] = []
    if "MenuV:" in block or "AdminMenuShim" in block:
        bad.append("qb-admin:client:openMenu still opens via MenuV/AdminMenuShim")
    if "openCustomMenu(" not in block or "AdminMenuSpecs.BuildMenu1(" not in block:
        bad.append("qb-admin:client:openMenu must open menu1 via custom-menu Open()")
    return bad


def test_adminmenu_open_entry_rejects_menuv_or_unstacked_open():
    real = read(CLIENT)
    assert open_entry_violations(real) == [], open_entry_violations(real)

    broken = ("RegisterNetEvent('qb-admin:client:openMenu', function()\n"
              "    MenuV:OpenMenu(menu1)\n"
              "end)\n")
    assert open_entry_violations(broken), "回归 MenuV:OpenMenu 的打开入口未被拦截"


# ---------------------------------------------------------------------------
# 3) 逐屏迁移契约 + Lua 5.4 运行时探针（17 屏全过 MenuSpec.Validate）
# ---------------------------------------------------------------------------

def per_screen_violations(specs_source: str, client_source: str) -> list[str]:
    specs_code = blank_noise(specs_source, keep_strings=True)
    client_code = blank_noise(client_source, keep_strings=True)
    bad: list[str] = []

    if re.search(r"\bMenuV\s*[:.]", client_code):
        bad.append("client.lua contains MenuV calls")

    for name, spec_id, intent_id in EXPECTED_SCREENS:
        if f"'{spec_id}'" not in specs_code:
            bad.append(f"{name}: missing MenuSpec id '{spec_id}' in client/menu_specs.lua")
        if f"'{intent_id}'" not in specs_code:
            bad.append(f"{name}: missing intent '{intent_id}' in client/menu_specs.lua")
        if f"customMenuHandlers['{intent_id}']" not in client_code:
            bad.append(f"{name}: missing handler customMenuHandlers['{intent_id}'] in client/client.lua")

    if "exports(AdminMenuSpecs.EXPORT_METHOD" not in client_code:
        bad.append("client.lua missing AdminMenuIntent export for custom-menu resource routes")
    return bad


LUA_PROBE_HARNESS = r"""
local json_ok = true
local events = {}
local server_events = {}
local client_events = {}
local nui_messages = {}
local notifications = {}
local opened_specs = {}
local registered_intents = {}
local closed_reasons = {}
local menu_open = false
local noclip_toggles = 0
local last_ev_dist = nil
local visible_calls = {}
local coords_calls = 0

function GetResourceState(name)
    if name == 'custom-menu' then return 'started' end
    return 'missing'
end

local exported_self = {}
local function makeExports()
    local custom_menu_proxy = {}
    function custom_menu_proxy:RegisterIntent(id, route)
        if type(route) ~= 'table' or route.type ~= 'resource' then
            return false, 'must_be_resource_route'
        end
        for k, v in pairs(route) do
            if type(v) == 'function' then
                return false, 'closure_not_allowed:' .. tostring(k)
            end
        end
        registered_intents[id] = route
        return true, nil
    end
    function custom_menu_proxy:Open(spec, opts)
        local ok, err = MenuSpec.Validate(spec, opts)
        if not ok then
            return false, err
        end
        menu_open = true
        opened_specs[#opened_specs + 1] = spec
        return true, nil
    end
    function custom_menu_proxy:IsOpen()
        return menu_open
    end
    function custom_menu_proxy:Close(reason)
        menu_open = false
        closed_reasons[#closed_reasons + 1] = reason or 'closed'
        return true
    end

    local e = {}
    setmetatable(e, {
        __call = function(_, name, fn)
            exported_self[name] = fn
        end,
        __index = function(_, res)
            if res == 'custom-menu' then
                return custom_menu_proxy
            end
            if res == 'qb-adminmenu' then
                local self_proxy = {}
                for m, fn in pairs(exported_self) do
                    self_proxy[m] = function(_self, ...)
                        return fn(...)
                    end
                end
                return self_proxy
            end
            return nil
        end,
    })
    return e
end

exports = makeExports()

function RegisterNetEvent(name, fn)
    if fn then events[name] = fn end
end
function AddEventHandler(name, fn) end
function TriggerServerEvent(name, ...)
    server_events[#server_events + 1] = { name = name, args = { ... } }
end
function TriggerEvent(name, ...)
    client_events[#client_events + 1] = { name = name, args = { ... } }
end
function SendNUIMessage(msg)
    nui_messages[#nui_messages + 1] = msg
end
function CreateThread(_fn) end
function Wait(_ms) end
function PlayerPedId() return 101 end
function PlayerId() return 1 end
function GetEntityCoords() return { x = 1.0, y = 2.0, z = 3.0 } end
function GetEntityHeading() return 90.0 end
function GetEntityRotation() return { x = 0.0, y = 0.0, z = 90.0 } end
function GetEntityModel() return 12345 end
function GetFreeAimEntity() return 55 end
function GetClockHours() return 9 end
function GetCurrentEntityViewDistance() return 3 end
function SetEntityViewDistance(v) last_ev_dist = v end
function ToggleNoClip() noclip_toggles = noclip_toggles + 1 end
function SetEntityVisible(_ped, state) visible_calls[#visible_calls + 1] = state end
function SetPlayerInvincible() end
function ToggleEntityFreeView() end
function ToggleEntityVehicleView() end
function ToggleEntityObjectView() end
function ToggleEntityPedView() end
Entities = { [12345] = 'adder' }

local cb_mode = 'sync'
local async_queue = {}

QBCore = {
    Shared = {
        Weapons = {
            weapon_pistol = { name = 'weapon_pistol', label = 'Pistol', value = 'weapon_pistol' },
        },
        Vehicles = {
            adder = { name = 'Adder', category = 'super' },
            blista = { name = 'Blista', category = 'compacts' },
        },
        FirstToUpper = function(s) return (tostring(s):gsub('^%l', string.upper)) end,
        Round = function(num, dec)
            local mult = 10 ^ (dec or 0)
            return math.floor(num * mult + 0.5) / mult
        end,
    },
    Functions = {
        Notify = function(msg, typ)
            notifications[#notifications + 1] = { msg = msg, typ = typ }
        end,
        TriggerCallback = function(name, cb)
            local payload
            if name == 'test:getplayers' then
                payload = {
                    { id = 7, cid = 'ABC123', name = 'Alice' },
                }
            elseif name == 'test:getdealers' then
                payload = {
                    { name = 'DockDealer' },
                }
            elseif name == 'qb-admin:server:getrank' then
                payload = true
            end
            if cb_mode == 'sync' then
                cb(payload)
            else
                async_queue[#async_queue + 1] = function() cb(payload) end
            end
        end,
    },
}

local BASE_DIR = arg[1]
dofile(BASE_DIR .. '/resources/[qb]/qb-core/shared/locale.lua')
dofile(BASE_DIR .. '/resources/[qb]/qb-adminmenu/locales/en.lua')
dofile(BASE_DIR .. '/resources/[custom]/custom-menu/shared/menu_spec.lua')
dofile(BASE_DIR .. '/resources/[qb]/qb-adminmenu/client/menu_specs.lua')
dofile(BASE_DIR .. '/resources/[qb]/qb-adminmenu/client/client.lua')

local known = AdminMenuSpecs.KnownIntents()
local function assertSpec(spec, expectedId, tag)
    assert(type(spec) == 'table', tag .. ': spec missing')
    assert(spec.id == expectedId, tag .. ': expected id ' .. expectedId .. ', got ' .. tostring(spec.id))
    local ok, err = MenuSpec.Validate(spec, { knownIntents = known })
    assert(ok, tag .. ': MenuSpec.Validate failed: ' .. tostring(err))
end

local function callIntent(intentId, ctx)
    local fn = exported_self['AdminMenuIntent']
    assert(type(fn) == 'function', 'AdminMenuIntent export missing')
    return fn(intentId, ctx or {})
end

-- 1. openMenu -> menu1
events['qb-admin:client:openMenu']()
assert(menu_open == true, 'menu should be open after openMenu')
assertSpec(opened_specs[1], 'qb_adminmenu_menu1', 'openMenu')
for _, id in ipairs(AdminMenuSpecs.INTENTS) do
    assert(registered_intents[id] ~= nil, 'missing RegisterIntent for ' .. id)
end

-- 2. menu2 + toggles + menu15 weapons
local r2 = callIntent('adminmenu:open:menu2')
assertSpec(r2.spec, 'qb_adminmenu_menu2', 'menu2')
callIntent('adminmenu:action:toggle_option', { args = { option = 'noclip' }, values = { checked = true } })
callIntent('adminmenu:action:toggle_option', { args = { option = 'invisible' }, values = { checked = true } })
callIntent('adminmenu:action:toggle_option', { args = { option = 'godmode' }, values = { checked = true } })
callIntent('adminmenu:action:toggle_option', { args = { option = 'names' }, values = { checked = true } })
callIntent('adminmenu:action:toggle_option', { args = { option = 'blips' }, values = { checked = true } })
callIntent('adminmenu:action:revive_self')
assert(noclip_toggles == 1, 'noclip should toggle once')
local r15 = callIntent('adminmenu:open:menu15')
assertSpec(r15.spec, 'qb_adminmenu_menu15', 'menu15')
callIntent('adminmenu:action:give_weapon', { args = { weapon = 'weapon_pistol' } })

-- 3. menu3 + range time + menu8 weather
local r3 = callIntent('adminmenu:open:menu3')
assertSpec(r3.spec, 'qb_adminmenu_menu3', 'menu3')
local r3t = callIntent('adminmenu:open:menu3_time')
assertSpec(r3t.spec, 'qb_adminmenu_menu3_time', 'menu3_time')
assert(r3t.spec.surface == 'range', 'menu3_time must use range surface')
callIntent('adminmenu:action:set_time', { values = { value = 16 } })
local r8 = callIntent('adminmenu:open:menu8')
assertSpec(r8.spec, 'qb_adminmenu_menu8', 'menu8')
callIntent('adminmenu:action:set_weather', { args = { value = 'CLEAR', label = 'Clear' } })

-- 4. menu4 -> Players -> menu10 (kick form) -> menu9 (ban preset/custom form) -> menu11 (perms confirm)
local r4 = callIntent('adminmenu:open:menu4')
assertSpec(r4.spec, 'qb_adminmenu_menu4', 'menu4')
local rPly = callIntent('adminmenu:open:player', { args = { playerKey = '7' } })
assertSpec(rPly.spec, 'qb_adminmenu_player', 'player')
callIntent('adminmenu:action:player_action', { args = { action = 'kill' } })

local r10 = callIntent('adminmenu:open:menu10')
assertSpec(r10.spec, 'qb_adminmenu_menu10', 'menu10')
assert(r10.spec.surface == 'form', 'menu10 must use form surface')
local rKick = callIntent('adminmenu:action:kick_submit', { values = { reason = '  test kick  ' } })
assert(rKick.ok == true and menu_open == false, 'kick submit should dispatch and close menu')
menu_open = true

local r9 = callIntent('adminmenu:open:menu9')
assertSpec(r9.spec, 'qb_adminmenu_menu9', 'menu9')
local r9fp = callIntent('adminmenu:open:menu9_form', { args = { length = '3600', label = '1 Hour', custom = false } })
assertSpec(r9fp.spec, 'qb_adminmenu_menu9_form', 'menu9_form_preset')
assert(r9fp.spec.surface == 'form' and #r9fp.spec.items == 1, 'preset ban form has 1 reason field')
local r9fc = callIntent('adminmenu:open:menu9_form', { args = { label = 'Self', custom = true } })
assertSpec(r9fc.spec, 'qb_adminmenu_menu9_form', 'menu9_form_custom')
assert(r9fc.spec.surface == 'form' and #r9fc.spec.items == 2, 'custom ban form has length + reason')
local rBan = callIntent('adminmenu:action:ban_submit', { values = { length = '7200', reason = 'rule break' } })
assert(rBan.ok == true and menu_open == false, 'ban submit should dispatch and close menu')
menu_open = true

local r11 = callIntent('adminmenu:open:menu11')
assertSpec(r11.spec, 'qb_adminmenu_menu11', 'menu11')
local r11c = callIntent('adminmenu:open:menu11_confirm', { args = { rank = 'admin', label = 'Admin' } })
assertSpec(r11c.spec, 'qb_adminmenu_menu11_confirm', 'menu11_confirm')
assert(r11c.spec.surface == 'confirm', 'menu11_confirm must use confirm surface')
callIntent('adminmenu:action:perms_confirm')

-- Also check async path resets cleanly and ignores Esc-closed menu
cb_mode = 'async'
local r4async = callIntent('adminmenu:open:menu4')
assert(r4async.dispatched == 'async_pending', 'async callback returns pending')
menu_open = false -- user pressed Esc before callback returned
async_queue[1]()
assert(menu_open == false, 'async callback must not reopen menu after user Esc close')
menu_open = true
cb_mode = 'sync'

-- 5. menu5 -> menu12 -> menu13
local r5 = callIntent('adminmenu:open:menu5')
assertSpec(r5.spec, 'qb_adminmenu_menu5', 'menu5')
callIntent('adminmenu:action:veh_command', { args = { cmd = 'fix' } })
local r12 = callIntent('adminmenu:open:menu12')
assertSpec(r12.spec, 'qb_adminmenu_menu12', 'menu12')
local r13 = callIntent('adminmenu:open:menu13', { args = { category = 'super' } })
assertSpec(r13.spec, 'qb_adminmenu_menu13', 'menu13')
callIntent('adminmenu:action:veh_command', { args = { cmd = 'car', model = 'adder' } })

-- 6. menu6 -> EditDealer + delete confirm
local r6 = callIntent('adminmenu:open:menu6')
assertSpec(r6.spec, 'qb_adminmenu_menu6', 'menu6')
local rD = callIntent('adminmenu:open:dealer', { args = { dealerName = 'DockDealer' } })
assertSpec(rD.spec, 'qb_adminmenu_dealer', 'dealer')
callIntent('adminmenu:action:dealer_goto')
local rDc = callIntent('adminmenu:open:dealer_delete_confirm')
assertSpec(rDc.spec, 'qb_adminmenu_dealer_delete_confirm', 'dealer_delete_confirm')
assert(rDc.spec.surface == 'confirm' and rDc.spec.danger == true, 'dealer delete confirm')
callIntent('adminmenu:action:dealer_delete')

-- 7. menu7 -> menu14 -> range distance
local r7 = callIntent('adminmenu:open:menu7')
assertSpec(r7.spec, 'qb_adminmenu_menu7', 'menu7')
callIntent('adminmenu:action:copy', { args = { dataType = 'coords3' } })
local r14 = callIntent('adminmenu:open:menu14')
assertSpec(r14.spec, 'qb_adminmenu_menu14', 'menu14')
local r14d = callIntent('adminmenu:open:menu14_distance')
assertSpec(r14d.spec, 'qb_adminmenu_menu14_distance', 'menu14_distance')
assert(r14d.spec.surface == 'range', 'menu14_distance must use range surface')
callIntent('adminmenu:action:set_entity_distance', { values = { value = 35 } })
assert(last_ev_dist == '35', 'expected entity view distance 35, got ' .. tostring(last_ev_dist))

-- Verify server event trace contains expected actions
local seen = {}
for _, ev in ipairs(server_events) do seen[ev.name] = true end
for _, expected in ipairs({
    'qb-admin:giveWeapon',
    'qb-weathersync:server:setTime',
    'qb-weathersync:server:setWeather',
    'qb-admin:server:kill',
    'qb-admin:server:kick',
    'qb-admin:server:ban',
    'qb-admin:server:setPermissions',
    'QBCore:CallCommand',
}) do
    assert(seen[expected], 'missing expected ServerEvent: ' .. expected)
end

print('ALL_SCREENS_PROBE_OK')
"""


def test_adminmenu_per_screen_specs_and_lua_probe_detects_menuv_revert(tmp_path: Path):
    specs_src = read(SPECS)
    client_src = read(CLIENT)

    errs = per_screen_violations(specs_src, client_src)
    assert errs == [], "\n".join(errs)

    probe = tmp_path / "adminmenu_probe.lua"
    probe.write_text(LUA_PROBE_HARNESS, encoding="utf-8")
    proc = subprocess.run(
        ["lua5.4", str(probe), str(BASE)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, f"lua probe failed: {proc.stderr}\n{proc.stdout}"
    assert "ALL_SCREENS_PROBE_OK" in proc.stdout

    # 反向注入（逐屏）：把任意一屏的 handler 删掉或改回 MenuV 调用 → 闸门必须红
    for screen_name, _spec_id, intent_id in EXPECTED_SCREENS:
        dropped = client_src.replace(f"customMenuHandlers['{intent_id}']", f"local _unused_{screen_name}")
        assert dropped != client_src, f"fixture missed {intent_id}"
        assert per_screen_violations(specs_src, dropped), f"{screen_name} drop not caught"

        reverted_screen = client_src + f"\nlocal _rev_{screen_name} = MenuV:CreateMenu(false, '{screen_name}')\n"
        assert per_screen_violations(specs_src, reverted_screen), f"{screen_name} MenuV revert not caught"


# ---------------------------------------------------------------------------
# 4) 第二焦点写路径：qb-adminmenu 与 menuv 都不许出现 SetNuiFocus
# ---------------------------------------------------------------------------

def focus_writes_in(sources: dict[str, str]) -> list[str]:
    found = []
    for name, source in sources.items():
        if re.search(r"\bSetNuiFocus(?:KeepInput)?\s*\(", blank_noise(source)):
            found.append(name)
    return found


def test_adminmenu_and_menuv_rejects_a_second_focus_write_path():
    assert focus_writes_in(_sources(ADMINMENU)) == [], (
        "qb-adminmenu 里还有 SetNuiFocus：焦点必须只由 custom-ui 写"
    )
    assert focus_writes_in(_sources(MENUV)) == [], (
        "menuv 里出现了 SetNuiFocus：它应当只靠 RegisterKeyMapping 工作"
    )

    assert focus_writes_in({"fake-events.lua": "SetNuiFocus(focus, mouse)"}) == ["fake-events.lua"]
    assert focus_writes_in({"fake-comment.lua": "-- 不要写 SetNuiFocus\nreturn true\n"}) == []


# ---------------------------------------------------------------------------
# 5) 全禁控制：client.lua 已清零；仅保留 noclip.lua 非菜单飞行模式 3 处
# ---------------------------------------------------------------------------

LEGACY_BLANKET_DISABLE_ALL = {
    "client/noclip.lua": 3,   # DisableAllControlActions(0/1/2) — 非菜单飞行控制屏蔽
}


def blanket_disable_counts(sources: dict[str, str]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for name, source in sources.items():
        count = blank_noise(source).count("DisableAllControlActions")
        if count:
            counts[name] = count
    return counts


def blanket_growth(counts: dict[str, int], allowed: dict[str, int]) -> list[str]:
    return [
        f"{name}: {count} > {allowed.get(name, 0)}"
        for name, count in counts.items()
        if count > allowed.get(name, 0)
    ]


def test_adminmenu_rejects_new_blanket_disable_sites():
    sources = _sources(ADMINMENU)
    counts = blanket_disable_counts(sources)

    assert blanket_growth(counts, LEGACY_BLANKET_DISABLE_ALL) == [], (
        "qb-adminmenu 存在菜单路径/超额 DisableAllControlActions"
    )
    assert counts.get("client/client.lua", 0) == 0, (
        "client/client.lua 的 LocalInput/LocalInputInt DisableAllControlActions 必须清零"
    )

    # 反向注入：把 LocalInput 的 DisableAllControlActions 放回 client.lua → 必须红
    grown = dict(sources)
    grown["client/client.lua"] += "\nDisableAllControlActions(0)\n"
    assert blanket_growth(blanket_disable_counts(grown), LEGACY_BLANKET_DISABLE_ALL), (
        "恢复 client.lua 全禁控制未被拦截"
    )


def test_menuv_refs_json_and_baseline_contract_detects_stray_dependency(tmp_path: Path):
    """确认 menuv 引用计数清零（仅留只读 [standalone]/menuv 目录本身），且反向注入能拦住恢复引用。"""
    census_paths = [
        p for p in (BASE / "resources").rglob("*.lua")
        if not p.relative_to(BASE).as_posix().startswith("resources/[standalone]/menuv/")
    ]
    hits = [
        p.relative_to(BASE).as_posix()
        for p in census_paths
        if re.search(r"\bMenuV\s*[:.]", blank_noise(read(p)))
    ]
    assert hits == [], f"unexpected MenuV refs outside menuv: {hits}"

    # 反向注入：即使只在单个模块重新引用 @menuv/menuv.lua 或 MenuV:OpenMenu 也必须红
    bad_fx = read(MANIFEST) + "\nclient_script '@menuv/menuv.lua'\n"
    assert retirement_violations(_sources(ADMINMENU), bad_fx, read(CORE_CFG), has_shim_file=False)
