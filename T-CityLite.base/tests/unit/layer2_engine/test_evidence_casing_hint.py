"""EVD-02：值班执法人员要能“看见地上有东西”。

原生玩法（qb-policejob 原版，老服同款）只有「手电照着 + 1.5 米内」才浮出文字。
实机验证的结论是：地上确实有弹壳数据，但**没人能发现它**——玩家反馈就是“我看不到弹壳”。

这里加的是提示层，不是替代拾取流程：

* 值班 LEO、25 米内 → 一枚小箭头 + 距离（DrawMarker 细柱 + ▼ 文字）；
* 平民、下班 → 什么都不画（证据位置不对外暴露）；
* 超出 25 米 → 不画（避免全城箭头，也避免逐帧遍历变成热点）。

测法：真跑 client/evidence.lua（桩掉 FiveM 原生），直接调 EvidenceHints.DrawCasings。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
EVIDENCE = BASE / "resources" / "[custom]" / "custom-police" / "client" / "evidence.lua"

_BACKTICK = re.compile(r"`([^`\n]+)`")


def cfx_source() -> str:
    """CfxLua 的反引号哈希不是标准 Lua，换成 GetHashKey('...') 再跑。"""
    return _BACKTICK.sub(lambda m: "GetHashKey(%r)" % m.group(1), EVIDENCE.read_text(encoding="utf-8"))


STUBS = """
-- ── FiveM 原生 / 资源依赖桩 ─────────────────────────────
__markers, __texts, __events, __threads, __prints = {}, {}, {}, {}, {}
function __say(s) io.write(tostring(s) .. string.char(10)) end
function print(...) __prints[#__prints + 1] = table.concat({ ... }, ' ') end
function TriggerServerEvent(name, ...) __events[#__events + 1] = { name = name, args = { ... } } end
function TriggerEvent(...) end
function CreateThread(fn) __threads[#__threads + 1] = fn end
function Wait(_ms) end
function RegisterNetEvent(_name, _fn) end
function RegisterCommand(_name, _fn, _restricted) end
function RegisterNUICallback() end
function GetConvarInt(_name, default) return default end

-- 向量：`#(a - b)` 走 __len
local vmt = {}
vmt.__sub = function(a, b)
    return setmetatable({ dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z }, {
        __len = function(t) return math.sqrt(t.dx * t.dx + t.dy * t.dy + t.dz * t.dz) end,
    })
end
function vector3(x, y, z) return setmetatable({ x = x, y = y, z = z }, vmt) end

__now = 1000
function GetGameTimer() return __now end
function PlayerPedId() return 1 end
function PlayerId() return 0 end
function GetEntityCoords(_ped) return vector3(0.0, 0.0, 0.0) end
function GetOffsetFromEntityInWorldCoords(_ped, x, y, z) return vector3(x, y, z) end
function GetSelectedPedWeapon(_ped) return 0 end
function IsPedShooting(_ped) return false end
function IsPlayerFreeAiming(_id) return false end
function IsControlJustReleased(_a, _b) return false end
function GetStreetNameAtCoord(_x, _y, _z) return 1, 2 end
function GetStreetNameFromHashKey(_h) return 'Street' end
function GetHashKey(name)
    local h = 0
    for i = 1, #name do h = (h * 31 + name:byte(i)) % 2147483647 end
    return h
end
function DrawMarker(...) __markers[#__markers + 1] = { ... } end

LocalPlayer = { state = { isLoggedIn = true } }
PlayerJob = { type = 'leo', onduty = true }
-- 注意：文件里用的是冒号调用 Lang:t(key)，桩必须把 self 放在第一位，
-- 否则会返回整个 Lang 表（第一版就这样，三条提示全变成了 table: 0x...）
Lang = { t = function(_self, key, _params) return key end }
Config = { AmmoLabels = {} }
QBCore = {
    Shared = { Weapons = {}, Items = {} },
    Functions = {
        Progressbar = function() end,
        Notify = function() end,
        HasItem = function() return false end,
    },
}
CFShared = {
    DrawText3D = function(x, y, z, text) __texts[#__texts + 1] = { x = x, y = y, z = z, text = text } end,
    LoadModel = function() return true end,
    ReleaseModel = function() end,
    Report = function() end,
}
"""


def lua() -> str:
    exe = shutil.which("lua5.4") or shutil.which("lua")
    if not exe:
        pytest.skip("lua5.4 不可用")
    return exe


def run(body: str) -> dict:
    script = STUBS + "\n" + cfx_source() + "\n" + textwrap.dedent(body)
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr[-800:]}"
    out = {}
    for line in proc.stdout.strip().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def three_drops(distance: float, prefix: str = "") -> str:
    """三种地面证据各塞一条（等价于服务端广播过来的 Add* 事件）。"""
    d = float(distance)
    tag = prefix
    return f"""
        Casings['{tag}c1'] = {{ type = 12345, serie = 'S1', coords = {{ x = {d}, y = 0.0, z = 0.0 }} }}
        Blooddrops['{tag}b1'] = {{ citizenid = 'CIT', bloodtype = 'AB-', coords = {{ x = {d}, y = 0.0, z = 0.0 }} }}
        Fingerprints['{tag}f1'] = {{ fingerprint = 'F', coords = {{ x = {d}, y = 0.0, z = 0.0 }} }}
"""


def test_all_three_kinds_get_their_own_marker_and_label():
    out = run(three_drops(8.0) + """
        local drawn = EvidenceHints.DrawDrops(vector3(0.0, 0.0, 0.0))
        __say('drawn=' .. tostring(drawn))
        __say('markers=' .. tostring(#__markers))
        __say('marker_type=' .. tostring(__markers[1][1]))
        __say('texts=' .. tostring(#__texts))

        local colours = {}
        for i = 1, #__markers do
            colours[i] = __markers[i][14] .. '/' .. __markers[i][15] .. '/' .. __markers[i][16]
        end
        __say('colours=' .. table.concat(colours, ','))

        local labels = {}
        for i = 1, #__texts do labels[i] = __texts[i].text end
        __say('labels=' .. table.concat(labels, ' ; '))
        __say('near=1')
    """)
    assert out["drawn"] == "3", "弹壳、血迹、指纹三种都要画"
    assert out["markers"] == "3" and out["texts"] == "3"
    assert out["marker_type"] == "1", "地面要有一根细柱标记"
    # 三种颜色必须互不相同，否则玩家分不清地上那摊是什么
    assert out["colours"] == "255/70/70,150/25/25,90/200/255", out["colours"]
    assert "info.casing" in out["labels"]
    assert "info.blood" in out["labels"]
    assert "info.fingerprint" in out["labels"]
    assert out["labels"].count("▼") == 3, "每条提示都要带箭头，否则只是柱子"
    assert "8.0m" in out["labels"], "带上距离才知道还要走多远"


def test_civilian_and_off_duty_see_nothing_and_far_ones_are_skipped():
    far = three_drops(400.0, prefix="far_")
    out = run(three_drops(8.0) + far + """
        local pos = vector3(0.0, 0.0, 0.0)

        __say('leo=' .. tostring(EvidenceHints.DrawDrops(pos)))
        __say('leo_markers=' .. tostring(#__markers))

        -- 平民
        _G.__markers, _G.__texts = {}, {}
        PlayerJob = { type = 'none', onduty = true }
        __say('civilian=' .. tostring(EvidenceHints.DrawDrops(pos)))
        __say('civilian_markers=' .. tostring(#__markers))

        -- 下班警察
        PlayerJob = { type = 'leo', onduty = false }
        __say('offduty=' .. tostring(EvidenceHints.DrawDrops(pos)))
        __say('offduty_markers=' .. tostring(#__markers))

        -- 重新值班：400 米外那三颗不该被画
        PlayerJob = { type = 'leo', onduty = true }
        __say('onduty_again=' .. tostring(EvidenceHints.DrawDrops(pos)))
    """)
    assert out["leo"] == "3", "8 米那三颗都要画"
    assert out["leo_markers"] == "3"
    assert out["civilian"] == "0" and out["civilian_markers"] == "0", "平民不该看到证据位置"
    assert out["offduty"] == "0" and out["offduty_markers"] == "0", "下班状态也不该看到"
    assert out["onduty_again"] == "3", "400 米外那三颗必须跳过（否则遍历和绘制都变成热点）"


def test_the_pickup_prompt_names_the_real_key_and_the_bag():
    """采集键是 G（控制位 47），不是 E；而且必须先有一颗空证据袋。

    这条规则来自实机：我给的说明书写了"按 E"，玩家照着按没反应，真实答案是 G + 空袋子。
    键位这种东西一旦写错，代码没错也会浪费一轮排查，所以钉死：
    控制位必须是 47，而且提示文案里必须出现 G（locales 里用 ~g~G~s~ 上色）。
    """
    client = EVIDENCE.read_text(encoding="utf-8")
    assert "IsControlJustReleased(0, 47)" in client, "弹壳/血迹/指纹的采集键是 G（47），改了就得同步改文档"

    locale = (BASE / "resources" / "[custom]" / "custom-police" / "locales" / "en.lua").read_text(encoding="utf-8")
    prompt_line = next(
        (line for line in locale.splitlines() if "bullet_casing = " in line and "~g~G~s~" in line), None)
    assert prompt_line, "找不到弹壳提示文案"
    assert "~g~G~s~" in prompt_line, "提示里必须告诉玩家按 G"

    # 服务端才是"要空证据袋"的判定点：没有空袋子就只发一条错误提示，不给证据
    server = (EVIDENCE.parents[1] / "server" / "evidence.lua").read_text(encoding="utf-8")
    assert "RemoveItem(src, 'empty_evidence_bag'" in server
    assert "'filled_evidence_bag'" in server
    assert "error.have_evidence_bag" in server, "没有空袋子时必须给出可读的错误提示，而不是静默失败"


# ── 拾取块的空值守卫 ─────────────────────────────────────────────────────────
# 服务端现在会定期清扫过期痕迹并广播 Remove*，客户端可能在**任意时刻**丢掉一条记录。
# 如果拾取块仍然直接 `Casings[CurrentCasing].coords`，那一刻就是
# "attempt to index a nil value" —— 玩家手上的脚本直接报错。
# 这条是形状钉（不是行为证明）：真实路径在 while true 线程里，线程没法在单测里直接驱动。

_PICKUP_BLOCKS = {
    "CurrentCasing": "Casings",
    "CurrentBlooddrop": "Blooddrops",
    "CurrentFingerprint": "Fingerprints",
}


def unguarded_pickup_blocks(source: str) -> list[str]:
    """找出"直接索引 Current* 对应表"而没有先取局部变量判空的块。"""
    problems = []
    for current, store in _PICKUP_BLOCKS.items():
        guarded = f"local {'casing' if current == 'CurrentCasing' else ('blooddrop' if current == 'CurrentBlooddrop' else 'fingerprint')} = {current} and {store}[{current}]"
        if guarded not in source:
            problems.append(f"{current}: 少了 `{guarded}` 这层守卫")
        if f"if {current} and {current} ~= 0 then" in source:
            problems.append(f"{current}: 还是旧的 `if ... ~= 0 then` 形状（没有判空）")
    # 旧形状：任何 Current* 作为下标的直接用法
    for match in re.finditer(r"\w+\[(Current\w+)\]\.", source):
        problems.append(f"{match.group(1)}: 直接索引后取字段，可能踩到已删除的记录")
    return problems


def test_pickup_blocks_survive_a_record_that_was_swept_away():
    source = EVIDENCE.read_text(encoding="utf-8")
    assert unguarded_pickup_blocks(source) == [], "\n".join(unguarded_pickup_blocks(source))

    # 反向：旧写法必须被抓到
    bad = "        if CurrentCasing and CurrentCasing ~= 0 then\n            DrawText3D(Casings[CurrentCasing].coords.x)\n"
    assert unguarded_pickup_blocks(bad), "扫描器抓不住没有守卫的拾取块"
