"""#353 — qb-adminmenu 必须接入 custom-ui 的输入栈（menuv 垫片）。

真机症状（2026-11-25）：
  * 手机开着时 `/admin` 还能叠开 —— menuv 既不查栈，别的菜单也看不见它；
  * `/admin` 开着按 Esc 关不掉，反而呼出游戏暂停菜单 —— menuv 只在 NUI 有焦点时
    才看得到 Esc，而它从不调 SetNuiFocus。

垫片（``client/menu_shim.lua``）只做三件事：
  1) 打开前 ``IsTaken()``，被占用就拒绝；
  2) 打开时 ``Push('adminmenu')``、关闭时 ``Pop``；
  3) 开期间只屏蔽暂停控制（199/200），并用 ``IsDisabledControlJustPressed`` 消费 Esc。

三条规则都自带反向注入：把坏形状喂进同一个扫描函数必须变红。
"""

from __future__ import annotations

import re
from pathlib import Path

from lua_source import blank_noise

BASE = Path(__file__).resolve().parents[2]
ADMINMENU = BASE / "resources" / "[qb]" / "qb-adminmenu"
MENUV = BASE / "resources" / "[standalone]" / "menuv"
SHIM = ADMINMENU / "client" / "menu_shim.lua"
CLIENT = ADMINMENU / "client" / "client.lua"


def read(path: Path) -> str:
    assert path.is_file(), f"missing {path}"
    return path.read_text(encoding="utf-8", errors="ignore")


# ---------------------------------------------------------------------------
# 1) 垫片必须真的查栈/入栈，Esc 必须"消费"而不是只禁掉
# ---------------------------------------------------------------------------

def shim_violations(source: str) -> list[str]:
    code = blank_noise(source)
    bad: list[str] = []

    # 走的是 custom-ui 的导出（带冒号的调用；helper 名字不算）
    for needed in (":IsTaken(", ":Owns(", ":Push(", ":Pop("):
        if needed not in code:
            bad.append(f"missing {needed}")

    # 门卫必须真的问栈：只留 helper 定义、不调用，等于没修
    if "if not stackIsTaken() then" not in code:
        bad.append("open guard never asks IsTaken before opening")

    if "DisableAllControlActions" in code:
        bad.append("disables every control instead of a curated list")

    if "SetNuiFocus" in code:
        bad.append("writes NUI focus directly (only custom-ui may)")

    # Esc 必须被读到，否则只是"关不掉但也不弹暂停"
    if ("IsDisabledControlJustPressed(0, 199)" not in code
            or "IsDisabledControlJustPressed(0, 200)" not in code):
        bad.append("Esc edge is never consumed")

    # 只许屏蔽暂停控制：表里恰好 199/200，调用点不许写死别的控制号
    pause = re.search(r"PAUSE_CONTROLS\s*=\s*\{([^}]*)\}", code)
    if not pause:
        bad.append("missing PAUSE_CONTROLS")
    else:
        ids = {int(number) for number in re.findall(r"\d+", pause.group(1))}
        if ids != {199, 200}:
            bad.append(f"PAUSE_CONTROLS must be exactly 199/200, got {sorted(ids)}")

    hardcoded = {int(number) for number in re.findall(r"DisableControlAction\s*\(\s*0\s*,\s*(\d+)", code)}
    if hardcoded - {199, 200}:
        bad.append(f"disables non-pause controls: {sorted(hardcoded - {199, 200})}")

    return bad


def test_adminmenu_shim_detects_missing_stack_contract():
    real = read(SHIM)
    assert shim_violations(real) == [], "\n".join(shim_violations(real))

    # 反向注入 1：删掉打开前的 IsTaken 判断（#353 的核心）必须变红
    without_guard = real.replace("    if not stackIsTaken() then return true end\n", "")
    assert without_guard != real, "夹具没命中：垫片里的 IsTaken 门卫形状变了？"
    caught = shim_violations(without_guard)
    assert any("IsTaken" in item for item in caught), caught

    # 反向注入 2：不再 Push / Pop 也必须变红
    for call in ("exports['custom-ui']:Push(frame)", "exports['custom-ui']:Pop(id)"):
        broken = real.replace(call, "nil")
        assert broken != real, f"夹具没命中：{call}"
        assert shim_violations(broken), f"没有 {call} 也必须被抓住"


def open_entry_violations(source: str) -> list[str]:
    """`qb-admin:client:openMenu` 是 /admin 的唯一外部入口，必须先问栈。"""
    code = blank_noise(source, keep_strings=True)
    at = code.find("'qb-admin:client:openMenu'")
    if at == -1:
        return ["missing qb-admin:client:openMenu handler"]

    block = code[at:at + 500]
    if "AdminMenuShim.OpenMenu(" not in block and "AdminMenuShim.CanOpen()" not in block:
        return ["admin menu opens without asking the input stack"]
    return []


def test_adminmenu_open_entry_detects_a_menu_that_skips_the_guard():
    real = read(CLIENT)
    assert open_entry_violations(real) == [], open_entry_violations(real)

    broken = ("RegisterNetEvent('qb-admin:client:openMenu', function()\n"
              "    MenuV:OpenMenu(menu1)\n"
              "end)\n")
    assert open_entry_violations(broken), "跳过栈检查的打开入口没有被抓到"


# ---------------------------------------------------------------------------
# 2) 第二焦点写路径：qb-adminmenu 与 menuv 都不许出现 SetNuiFocus
# ---------------------------------------------------------------------------

def focus_writes_in(sources: dict[str, str]) -> list[str]:
    found = []
    for name, source in sources.items():
        if re.search(r"\bSetNuiFocus(?:KeepInput)?\s*\(", blank_noise(source)):
            found.append(name)
    return found


def _sources(resource: Path) -> dict[str, str]:
    return {path.relative_to(resource).as_posix(): read(path)
            for path in sorted(resource.rglob("*.lua"))}


def test_adminmenu_and_menuv_rejects_a_second_focus_write_path():
    assert focus_writes_in(_sources(ADMINMENU)) == [], (
        "qb-adminmenu 里还有 SetNuiFocus：焦点必须只由 custom-ui 写")
    assert focus_writes_in(_sources(MENUV)) == [], (
        "menuv 里出现了 SetNuiFocus：它应当只靠 RegisterKeyMapping 工作")

    # 反向注入：换回老写法（events.lua 里的 /givenuifocus）必须变红
    assert focus_writes_in({"fake-events.lua": "SetNuiFocus(focus, mouse)"}) == ["fake-events.lua"]
    # 注释里提到不算
    assert focus_writes_in({"fake-comment.lua": "-- 不要写 SetNuiFocus\nreturn true\n"}) == []


# ---------------------------------------------------------------------------
# 3) 全禁控制：新代码一处都不许有；存量只许减不许增（#346 的账）
# ---------------------------------------------------------------------------

# #346 存量（不在 #353 范围）：noclip 需要同时全禁 0/1/2 三组控制；
# 两个输入框循环沿用旧写法。这里做棘轮：数量只能减、不能增。
LEGACY_BLANKET_DISABLE_ALL = {
    "client/client.lua": 2,   # LocalInput / LocalInputInt
    "client/noclip.lua": 3,   # DisableAllControlActions(0/1/2)
}


def blanket_disable_counts(sources: dict[str, str]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for name, source in sources.items():
        count = blank_noise(source).count("DisableAllControlActions")
        if count:
            counts[name] = count
    return counts


def blanket_growth(counts: dict[str, int], allowed: dict[str, int]) -> list[str]:
    return [f"{name}: {count} > {allowed.get(name, 0)}"
            for name, count in counts.items() if count > allowed.get(name, 0)]


def test_adminmenu_rejects_new_blanket_disable_sites():
    sources = _sources(ADMINMENU)
    counts = blanket_disable_counts(sources)

    assert blanket_growth(counts, LEGACY_BLANKET_DISABLE_ALL) == [], (
        "qb-adminmenu 新增了 DisableAllControlActions；#353 只许屏蔽暂停控制")
    # 新垫片自己必须为 0（回归形状：Esc 处理顺手把整组控制全禁了）
    assert counts.get("client/menu_shim.lua", 0) == 0

    # 反向注入：往垫片里加一处全禁必须变红
    grown = dict(sources)
    grown["client/menu_shim.lua"] += "\nDisableAllControlActions(0)\n"
    assert blanket_growth(blanket_disable_counts(grown), LEGACY_BLANKET_DISABLE_ALL), (
        "新增的全禁站点没有被抓到")
