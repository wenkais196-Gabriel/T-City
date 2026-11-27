"""人事反馈与单入口收敛契约闸门（J-4 / J-5 / M6b #385）。

四条规则，都来自真机问题：

1. **老板 / 黑帮 / 组织菜单只有一个动作 → 必须 [E]（custom-prompt）**。
   全服 `setr UseTarget true`，这些菜单原本走 qb-target，玩家要长按 ALT 才看得到；
   现在靠 `Config.ManagementUsePrompt` 强制走 custom-prompt。
2. **66 处人事通知必须走通道**：老板看到的走 `feedback`（feed/error），
   被操作的当事人走 `personnelNote`（手机留档，离线可查）；文案不许残留英文。
3. **单一交互入口与零自管焦点（M6b #385）**：删除重复 `cl_boss.lua` / `cl_gang.lua`，
   收敛至 `cl_org.lua`；同坐标只注册一次，`Config.BossMenus` / `Config.GangMenus` 不允许多重遍历，
   `cl_org.lua` 零 `SetNuiFocus` / `Wait(0)` / `DisableAllControlActions`。
4. **CloseMenu 按 owner 归因 & 防叠栈**：`CloseMenuFull` 按持有者归因关闭，
   不许关闭他人 `qb-menu` / `custom-phone` / 面板；远程 `/orgmenu` 不被距离循环误关；
   `custom-ui:IsTaken()` 占用时禁止叠开，`custom-industry` 「产业」项保持可见。

每条都在同一个用例里构造错误形状并断言会红（gate_coverage 认 `detects`/`rejects` 记号）。
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import lua_source

REPO = Path(__file__).resolve().parents[3]
MGMT = REPO / "T-CityLite.base" / "resources" / "[qb]" / "qb-management"
CLIENT_DIR = MGMT / "client"
CLIENT_FILES = [CLIENT_DIR / "cl_org.lua"]
SERVER_FILES = [MGMT / "server" / n for n in ("sv_boss.lua", "sv_gang.lua", "sv_org.lua")]
NL = chr(10)


def check_single_entrypoint_contract(client_dir: Path, source_override: str | None = None) -> list[str]:
    """校验 qb-management 客户端单文件、单坐标注册与零自管焦点不变量。"""
    errors: list[str] = []
    for retired in ("cl_boss.lua", "cl_gang.lua"):
        if (client_dir / retired).exists():
            errors.append(f"存在已退场重复客户端文件: {retired}")

    org_path = client_dir / "cl_org.lua"
    if not org_path.exists():
        errors.append("缺少统一入口文件: cl_org.lua")
        return errors

    source = source_override if source_override is not None else org_path.read_text(encoding="utf-8")
    code_only = lua_source.blank_noise(source)

    boss_loops = re.findall(r"\bpairs\s*\(\s*Config\.BossMenus\s*\)", code_only)
    if len(boss_loops) != 1:
        errors.append(f"Config.BossMenus 遍历次数异常: 期望 1，实测 {len(boss_loops)}")

    gang_loops = re.findall(r"\bpairs\s*\(\s*Config\.GangMenus\s*\)", code_only)
    if len(gang_loops) != 1:
        errors.append(f"Config.GangMenus 遍历次数异常: 期望 1，实测 {len(gang_loops)}")

    threads = re.findall(r"\bCreateThread\s*\(", code_only)
    if len(threads) != 1:
        errors.append(f"CreateThread 入口数量异常: 期望 1，实测 {len(threads)}")

    if "seenCoords" not in code_only and "coordKey" not in code_only:
        errors.append("cl_org.lua 缺少坐标去重逻辑 (seenCoords/coordKey)")

    for forbidden, pat in (
        ("SetNuiFocus", r"\bSetNuiFocus(?:KeepInput)?\s*\("),
        ("DisableAllControlActions", r"\bDisableAllControlActions\s*\("),
        ("Wait(0)", r"\bWait\s*\(\s*0\s*\)"),
    ):
        if re.search(pat, code_only):
            errors.append(f"cl_org.lua 违规调用 {forbidden}")

    if "IsTaken" not in code_only or "Top" not in code_only:
        errors.append("cl_org.lua 未接入 custom-ui IsTaken()/Top() 焦点栈守卫")

    if not re.search(r"local\s+function\s+CloseMenuFull\s*\(\s*owner\s*\)", code_only):
        errors.append("CloseMenuFull 必须显式接收 owner 参数做归因校验")
    elif not re.search(r"activeMenuOwner\s*~=\s*nil.*activeMenuOwner\s*~=\s*owner|owner\s*~=\s*RESOURCE_OWNER", code_only, re.S):
        errors.append("CloseMenuFull 缺少 activeMenuOwner / owner 比对归因逻辑")

    return errors


def _lua_bin() -> str:
    return shutil.which("lua5.4") or shutil.which("lua5.4.exe") or "lua5.4.exe"


def test_alt_fallback_detects_disabled_prompt_flag():
    assert not (CLIENT_DIR / "cl_boss.lua").exists(), "cl_boss.lua 应已合并进 cl_org.lua"
    assert not (CLIENT_DIR / "cl_gang.lua").exists(), "cl_gang.lua 应已合并进 cl_org.lua"
    for path in CLIENT_FILES:
        text = path.read_text(encoding="utf-8")
        assert "Config.ManagementUsePrompt" in text, (
            path.name + " 没有读 ManagementUsePrompt —— 会被全局 UseTarget 拖回 ALT 入口")
        assert "exports['qb-core']:DrawText" not in text, (
            path.name + " 还在用 qb-core 的 DrawText 黑条，应改成 custom-prompt")
    cfg = (MGMT / "config.lua").read_text(encoding="utf-8")
    assert re.search(r"Config\.ManagementUsePrompt\s*=\s*true", cfg), (
        "config.lua 里 ManagementUsePrompt 没开 —— 菜单会退回 ALT")

    # 反向：把开关关掉，这条规则必须红
    broken = cfg.replace("Config.ManagementUsePrompt = true",
                         "Config.ManagementUsePrompt = false", 1)
    assert broken != cfg
    assert not re.search(r"Config\.ManagementUsePrompt\s*=\s*true", broken)


def test_naked_notify_detects_injected_line():
    for path in SERVER_FILES:
        text = path.read_text(encoding="utf-8")
        assert "local function feedback" in text, path.name + " 缺 feedback helper"
        assert "local function personnelNote" in text, path.name + " 缺 personnelNote helper"
        naked = [l for l in text.splitlines()
                 if "QBCore:Notify" in l and not l.strip().startswith("--")]
        assert not naked, path.name + " 还有 " + str(len(naked)) + " 处裸通知：" + str(naked[:2])

    # 反向：塞一行裸通知回去，规则必须认出来
    sample = SERVER_FILES[0].read_text(encoding="utf-8")
    broken = sample + NL + "TriggerClientEvent('QBCore:Notify', src, 'oops', 'error')" + NL
    naked = [l for l in broken.splitlines()
             if "QBCore:Notify" in l and not l.strip().startswith("--")]
    assert naked, "闸门没认出裸通知"


def test_english_leftover_detects_regression():
    banned = ("You cannot", "You have been", "Employee fired", "Invalid job",
              "kicked yourself", "Failed to", "Successor is", "Choose someone")
    for path in SERVER_FILES:
        text = path.read_text(encoding="utf-8")
        for word in banned:
            pattern = re.compile(r"'[^'" + NL + r"]*" + re.escape(word) + r"[^'" + NL + r"]*'")
            for match in pattern.finditer(text):
                raise AssertionError(
                    path.name + " 仍有英文玩家文案：" + match.group(0)[:90])

    # 反向：把一句英文塞进玩家文案，规则必须红
    sample = SERVER_FILES[0].read_text(encoding="utf-8")
    broken = sample + NL + "feedback(src, 'You cannot do that', 'error')" + NL
    hit = re.search(r"'[^'" + NL + r"]*You cannot[^'" + NL + r"]*'", broken)
    assert hit, "闸门没认出英文文案"


def test_single_entrypoint_and_coord_registration_detects_duplicate_loops(tmp_path: Path) -> None:
    """单文件 + 单坐标注册 + 零 SetNuiFocus；还原重复文件/循环/SetNuiFocus 必红。"""
    errors = check_single_entrypoint_contract(CLIENT_DIR)
    assert not errors, "单入口契约校验失败:\n" + "\n".join(errors)

    org_text = (CLIENT_DIR / "cl_org.lua").read_text(encoding="utf-8")

    # 反向 1：把 cl_boss.lua 放回目录（模拟退回双入口），必须报错
    dup_dir = tmp_path / "dup_file"
    dup_dir.mkdir()
    (dup_dir / "cl_org.lua").write_text(org_text, encoding="utf-8")
    (dup_dir / "cl_boss.lua").write_text("-- restored duplicate\n", encoding="utf-8")
    assert check_single_entrypoint_contract(dup_dir), "还原 cl_boss.lua 必须变红"

    # 反向 2：往 cl_org.lua 塞回第二段 pairs(Config.BossMenus) 注册，必须报错
    dup_loop = org_text + "\nfor _, z in pairs(Config.BossMenus) do end\n"
    assert check_single_entrypoint_contract(CLIENT_DIR, source_override=dup_loop), (
        "重复遍历 Config.BossMenus 必须变红"
    )

    # 反向 3：注入 SetNuiFocus(true, true)，必须报错
    leaked_focus = org_text + "\nlocal function leak() SetNuiFocus(true, true) end\n"
    assert check_single_entrypoint_contract(CLIENT_DIR, source_override=leaked_focus), (
        "注入 SetNuiFocus 必须变红"
    )

    # 反向 4：退回无参盲关 CloseMenuFull()，必须报错
    blind_close = org_text.replace("local function CloseMenuFull(owner)", "local function CloseMenuFull()", 1)
    assert blind_close != org_text
    assert check_single_entrypoint_contract(CLIENT_DIR, source_override=blind_close), (
        "退回无 owner 归因的 CloseMenuFull() 必须变红"
    )


def test_close_menu_owner_attribution_and_org_menu_contract_rejects_blind_close(tmp_path: Path) -> None:
    """Lua 5.4 运行时沙箱验证：Boss+Org 同屏合区、产业项可见、归因关闭、防叠手机、单点 Target。"""
    org_text = (CLIENT_DIR / "cl_org.lua").read_text(encoding="utf-8")
    blind = org_text.replace("if activeMenuOwner == nil or owner ~= RESOURCE_OWNER or activeMenuOwner ~= owner then", "if false then", 1)
    assert blind != org_text
    assert check_single_entrypoint_contract(CLIENT_DIR, source_override=blind), (
        "关闭前跳过 activeMenuOwner 归因校验必须被静态闸门拦截"
    )

    script = r"""
local mgmt = assert(arg[1])

local vec_mt
vec_mt = {
    __sub = function(a, b)
        return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, vec_mt)
    end,
    __len = function(a)
        return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
    end,
}
function vector3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, vec_mt)
end

local state = {
    playerData = {
        job = { name = 'police', label = 'LSPD', isboss = true, grade = { name = 'Chief', level = 4 } },
        gang = { name = 'none', label = 'None', isboss = false, grade = { name = 'None', level = 0 } },
    },
    pedCoords = vector3(0.0, 0.0, 0.0),
    keyJustReleased38 = false,
    uiStarted = true,
    uiTaken = false,
    uiTop = nil,
    openCalls = {},
    closeCalls = 0,
    promptShows = 0,
    promptHides = 0,
    targetZones = {},
    targetCoords = {},
    outfitCalls = 0,
    blips = {},
    events = {},
    handlers = {},
    threads = {},
}

function GetCurrentResourceName() return 'qb-management' end
function GetConvar(_, default) return default end
function GetResourceState(res) return res == 'custom-ui' and (state.uiStarted and 'started' or 'stopped') or 'started' end
function PlayerPedId() return 1 end
function PlayerId() return 99 end
function GetEntityCoords() return state.pedCoords end
function GetGameTimer() return 1000 end
function IsControlJustReleased(_, code) return code == 38 and state.keyJustReleased38 end
function Wait(ms) coroutine.yield(ms) end
function CreateThread(fn) state.threads[#state.threads + 1] = coroutine.create(fn) end
function RegisterNetEvent(ev, fn) state.events[ev] = fn end
function AddEventHandler(ev, fn) state.handlers[ev] = fn end
function TriggerEvent(ev, ...)
    if ev == 'qb-clothing:client:openOutfitMenu' then state.outfitCalls = state.outfitCalls + 1 end
    if state.events[ev] then return state.events[ev](...) end
end
function TriggerServerEvent() end

local blipSeq = 0
function AddBlipForCoord(x, y, z)
    blipSeq = blipSeq + 1
    state.blips[blipSeq] = { x = x, y = y, z = z, exists = true }
    return blipSeq
end
function DoesBlipExist(id) return state.blips[id] and state.blips[id].exists == true end
function RemoveBlip(id) if state.blips[id] then state.blips[id].exists = false end end
function SetBlipSprite() end
function SetBlipDisplay() end
function SetBlipScale() end
function SetBlipColour() end
function SetBlipAsShortRange() end
function SetBlipCategory() end
function BeginTextCommandSetBlipName() end
function AddTextComponentSubstringPlayerName() end
function EndTextCommandSetBlipName() end

local mgmtExports = {}
exports = setmetatable({
    ['qb-core'] = {
        GetCoreObject = function()
            return {
                Functions = {
                    GetPlayerData = function() return state.playerData end,
                    TriggerCallback = function(name, cb)
                        if name == 'qb-orgmenu:server:GetEmployees' then
                            cb({
                                { name = '🟢 Bob', empSource = 'CID1', isOnline = true, isboss = false, grade = { name = 'Officer', level = 1 } },
                            })
                        elseif name == 'qb-orgmenu:getplayers' then
                            cb({
                                { name = 'Alice', citizenid = 'CID2', sourceplayer = 12 },
                            })
                        end
                    end,
                },
                Shared = {
                    Jobs = {
                        police = { grades = { ['0'] = { name = 'Cadet' }, ['4'] = { name = 'Chief' } } },
                    },
                    Gangs = {
                        cartel = { grades = { ['0'] = { name = 'Member' }, ['4'] = { name = 'Boss' } } },
                    },
                },
            }
        end,
    },
    ['qb-menu'] = {
        openMenu = function(_, items)
            state.openCalls[#state.openCalls + 1] = items
            state.uiTaken = true
            state.uiTop = { id = 'custom-menu', owner = 'custom-menu' }
        end,
        closeMenu = function()
            state.closeCalls = state.closeCalls + 1
            state.uiTaken = false
            state.uiTop = nil
        end,
    },
    ['custom-prompt'] = {
        Show = function() state.promptShows = state.promptShows + 1 end,
        Hide = function() state.promptHides = state.promptHides + 1 end,
    },
    ['custom-ui'] = {
        IsTaken = function() return state.uiTaken end,
        Top = function() return state.uiTop end,
    },
    ['qb-target'] = {
        AddCircleZone = function(_, name, coords, _, _, cfg)
            state.targetZones[#state.targetZones + 1] = { name = name, coords = coords, cfg = cfg }
            local key = string.format('%.2f:%.2f:%.2f', coords.x, coords.y, coords.z)
            state.targetCoords[key] = (state.targetCoords[key] or 0) + 1
        end,
    },
}, {
    __call = function(_, name, fn)
        mgmtExports[name] = fn
    end,
})

dofile(mgmt .. '/config.lua')
dofile(mgmt .. '/client/cl_utils.lua')
dofile(mgmt .. '/client/cl_org.lua')

-- 1. Verify custom-industry dual AddBossMenuItem + AddGangMenuItem deduplicates into ONE 「产业」 entry + Boss & Org sections
local item = { header = '产业', txt = '查看与经营产业', params = { event = 'industry:client:open' } }
mgmtExports.AddBossMenuItem(item, 'industry_panel')
mgmtExports.AddGangMenuItem(item, 'industry_panel')
TriggerEvent('qb-orgmenu:client:OpenMenu')
assert(#state.openCalls == 1, 'openMenu should be called once for /orgmenu')
local root = state.openCalls[1]
local headers, industryCount, hasExitClose = {}, 0, false
for _, row in ipairs(root) do
    headers[row.header] = true
    if row.header == '产业' then industryCount = industryCount + 1 end
    if row.header == 'Exit' and row.params and row.params.event == 'qb-orgmenu:client:CloseMenu' then
        hasExitClose = true
    end
end
assert(headers['老板视图 · 人事与库存'], 'missing Boss view section header')
assert(headers['组织视图 · 治理与扩展'], 'missing Org view section header')
assert(headers['Manage Members'] and headers['🔑 Transfer Ownership'], 'missing core Boss/Org entries')
assert(industryCount == 1, 'expected exactly 1 「产业」 entry, got ' .. tostring(industryCount))
assert(hasExitClose, 'Exit must route to qb-orgmenu:client:CloseMenu')

-- 2. Remote /orgmenu must NOT auto-close after stepping prompt thread repeatedly
local co = assert(state.threads[1], 'missing prompt thread')
for _ = 1, 5 do
    local ok = coroutine.resume(co)
    assert(ok, 'prompt thread errored')
end
assert(state.closeCalls == 0, 'remote /orgmenu was closed by proximity loop!')

-- 3. CloseMenu owned by qb-management DOES close; then non-owner / other UI stays untouched
TriggerEvent('qb-orgmenu:client:CloseMenu')
assert(state.closeCalls == 1, 'owner close should close qb-menu')

-- Another resource (e.g. /industry) opens qb-menu while ped stands at desk & walks away
state.uiTaken = true
state.uiTop = { id = 'custom-menu', owner = 'custom-menu' }
state.pedCoords = vector3(447.16, -974.31, 30.47)
coroutine.resume(co)
state.pedCoords = vector3(460.0, -974.31, 30.47)
coroutine.resume(co)
assert(state.closeCalls == 1, 'walking away must NOT close another resource qb-menu!')

-- 4. Phone focus stack blocks opening ([E] and /orgmenu); custom-menu 「返回」 allowed
state.uiTaken = true
state.uiTop = { id = 'phone', owner = 'custom-phone' }
local beforeOpen = #state.openCalls
TriggerEvent('qb-orgmenu:client:OpenMenu')
assert(#state.openCalls == beforeOpen, 'must not open orgmenu over custom-phone')
state.pedCoords = vector3(447.16, -974.31, 30.47)
state.keyJustReleased38 = true
coroutine.resume(co)
state.keyJustReleased38 = false
assert(#state.openCalls == beforeOpen, 'must not open [E] menu while custom-phone is taken')

state.uiTaken = true
state.uiTop = { id = 'custom-menu', owner = 'custom-menu' }
TriggerEvent('qb-orgmenu:client:OpenMenu')
assert(#state.openCalls == beforeOpen + 1, 'Return from custom-menu should be allowed')
TriggerEvent('qb-orgmenu:client:CloseMenu')
assert(state.closeCalls == 2, 'close after Return should work')

-- 5. Open at [E] prompt -> if custom-phone replaces UI, walking away must NOT close phone; if own menu, walking away DOES close
state.uiTaken = false
state.uiTop = nil
state.pedCoords = vector3(447.16, -974.31, 30.47)
state.keyJustReleased38 = true
coroutine.resume(co)
state.keyJustReleased38 = false
assert(#state.openCalls == beforeOpen + 2, '[E] at Boss desk must open menu')
state.uiTop = { id = 'phone', owner = 'custom-phone' }
state.pedCoords = vector3(460.0, -974.31, 30.47)
coroutine.resume(co)
assert(state.closeCalls == 2, 'must never close qb-menu when custom-phone owns Top frame')

state.pedCoords = vector3(447.16, -974.31, 30.47)
state.uiTaken = false
state.uiTop = nil
state.keyJustReleased38 = true
coroutine.resume(co)
state.keyJustReleased38 = false
assert(#state.openCalls == beforeOpen + 3)
state.pedCoords = vector3(460.0, -974.31, 30.47)
coroutine.resume(co)
assert(state.closeCalls == 3, 'leaving Boss desk must close own menu')

-- 6. Compat events + submenus + Cartel member panel + blips + Wardrobe
TriggerEvent('qb-bossmenu:client:employeelist')
assert(#state.openCalls == beforeOpen + 4)
TriggerEvent('qb-bossmenu:client:ManageEmployee', {
    player = { name = 'Bob', empSource = 'CID1' },
    work = { name = 'police' },
})
assert(#state.openCalls == beforeOpen + 5)
TriggerEvent('qb-orgmenu:client:TransferOwnership')
assert(#state.openCalls == beforeOpen + 6)
TriggerEvent('qb-orgmenu:client:ConfirmTransfer', {
    successorCid = 'CID1', successorName = 'Bob', orgName = 'police', orgType = 'job', orgLabel = 'LSPD',
})
assert(#state.openCalls == beforeOpen + 7)
TriggerEvent('qb-bossmenu:client:Wardrobe')
assert(state.outfitCalls == 1)

state.playerData.job = { name = 'unemployed', isboss = false }
state.playerData.gang = { name = 'cartel', label = 'Cartel', isboss = true, grade = { name = 'Boss', level = 4 } }
TriggerEvent('QBCore:Client:OnGangUpdate', state.playerData.gang)
local activeBlips = 0
for _, b in pairs(state.blips) do if b.exists then activeBlips = activeBlips + 1 end end
assert(activeBlips == 3, 'Cartel boss must have 3 blips (HQ, garage, boss office), got ' .. tostring(activeBlips))
TriggerEvent('qb-gangmenu:client:OpenMemberMenu')
assert(#state.openCalls == beforeOpen + 8)
TriggerEvent('qb-gangmenu:lient:ManageMember', {
    player = { name = 'Carlos', empSource = 'CID9' },
    work = { name = 'cartel' },
})
assert(#state.openCalls == beforeOpen + 9)
state.handlers.onResourceStop('qb-management')
activeBlips = 0
for _, b in pairs(state.blips) do if b.exists then activeBlips = activeBlips + 1 end end
assert(activeBlips == 0, 'onResourceStop must clean blips')

-- 7. UseTarget mode: every coordinate registered at most ONCE across BossMenus + GangMenus + cartel office
state.threads = {}
state.targetZones = {}
state.targetCoords = {}
Config.UseTarget = true
Config.ManagementUsePrompt = false
dofile(mgmt .. '/client/cl_org.lua')
local tco = assert(state.threads[1])
assert(coroutine.resume(tco))
assert(#state.targetZones > 0, 'UseTarget must register zones')
for coordStr, count in pairs(state.targetCoords) do
    assert(count == 1, 'duplicate qb-target registration at coord ' .. coordStr .. ': ' .. tostring(count))
end
print('ALL_MGMT_CHECKS_OK')
"""

    probe = tmp_path / "mgmt_probe.lua"
    probe.write_text(script, encoding="utf-8")
    proc = subprocess.run(
        [_lua_bin(), probe.as_posix(), MGMT.as_posix()],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, f"Lua 5.4 check failed:\nstdout={proc.stdout}\nstderr={proc.stderr}"
    assert "ALL_MGMT_CHECKS_OK" in proc.stdout, proc.stdout
