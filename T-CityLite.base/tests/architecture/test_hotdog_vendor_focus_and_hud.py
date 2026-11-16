"""热狗摊 S-C：CEF 焦点（S13）与状态条六项（S12）的离线契约。

真机验收清单 `docs/plan/jobs-content/14-hotdog-live-checklist.md` 把这两条列为
已知缺口：`custom-quest` 没有任何 `SetNuiFocus`（HTML 按钮点不了），状态条也缺
顾客 / 押金 / 剩余时间三项。

本文件钉住两件事：

* **焦点只有一个所有者** —— `client/vendor_focus.lua` 声明 `NUI_FOCUS_OWNER`，
  业务文件只调用 `VendorFocus.Acquire/Release`；开焦点顺序是 keepInput → focus，
  关焦点只 `SetNuiFocus(false,false)`。每条规则都有反向用例。
* **状态条六项有数据来源** —— 服务端 `PushState` 必须带 served / deposit /
  expiresAtMs，客户端 `PushStatus` 必须把它们送进 NUI，HTML 必须有对应 DOM。
  反向用例删掉任一字段必须变红。

每条正向规则都写成纯函数；反向用例把坏形状喂给同一个函数，证明规则真的会红。

    python -m pytest -q tests/architecture/test_hotdog_vendor_focus_and_hud.py
"""
from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

import lua_source

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
QUEST = BASE / "resources" / "[custom]" / "custom-quest"
FOCUS = QUEST / "client" / "vendor_focus.lua"
VENDOR = QUEST / "client" / "quest_hotdog_vendor_client.lua"
BRIDGE = QUEST / "server" / "quest_vendor_bridge.lua"
HTML = QUEST / "html" / "vendor.html"
MANIFEST = QUEST / "fxmanifest.lua"
PROBE = Path(__file__).resolve().parent / "fixtures" / "vendor_focus_probe.lua"

LUA = shutil.which("lua5.4.exe") or shutil.which("lua5.4")

FOCUS_CALL_RE = re.compile(r"\bSetNuiFocus(?:KeepInput)?\s*\(")
FOCUS_TRUE_RE = re.compile(r"\bSetNuiFocus\s*\(\s*true\b")
FOCUS_FALSE_RE = re.compile(r"\bSetNuiFocus\s*\(\s*false\b")
FOCUS_OWNER_RE = re.compile(r"\bNUI_FOCUS_OWNER\s*=\s*true\b")

#: UX A7 的六项：成品三档 / 原料 / 顾客 / 已售 / 押金 / 剩余时间。
#: `st-revenue` 是既有“收入”格，保留它（已售 + 收入是 UX §4.5 的同一行）。
REQUIRED_STATUS_IDS = (
    "st-exotic", "st-rare", "st-common",
    "st-raw", "st-served", "st-sold", "st-deposit", "st-time",
)

#: PushStatus 必须送进 NUI 的字段（覆盖六项，外加既有收入/提示）。
HUD_FIELDS = (
    "stock", "raw", "served", "sold", "deposit", "expiresAtMs", "remainingMs", "revenue",
)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def function_block(source: str, marker: str) -> str:
    """截取 `marker` 到列 0 的 `end`（本仓库的顶层/局部函数写法）。"""
    at = source.find(marker)
    assert at != -1, f"找不到 {marker}"
    lines = source[at:].splitlines()
    body = [lines[0]]
    for line in lines[1:]:
        body.append(line)
        if line.rstrip() == "end":
            break
    else:
        raise AssertionError(f"{marker} 没有以列 0 的 end 收尾")
    return "\n".join(body)


def on_resource_stop_block(source: str) -> str:
    at = source.find("AddEventHandler('onResourceStop'")
    assert at != -1, "没有 onResourceStop"
    lines = source[at:].splitlines()
    body = [lines[0]]
    for line in lines[1:]:
        body.append(line)
        if line.rstrip() == "end)":
            break
    else:
        raise AssertionError("onResourceStop 没有以列 0 的 end) 收尾")
    return "\n".join(body)


# ---------------------------------------------------------------------------
# 判定函数（正向/反向共用）
# ---------------------------------------------------------------------------


def focus_ownership_problems(sources: dict[str, str]) -> list[str]:
    """声明了 NUI_FOCUS_OWNER 的资源，焦点调用只能出现在声明文件里。"""
    masked = {rel: lua_source.blank_noise(body) for rel, body in sources.items()}
    owners = {rel for rel, code in masked.items() if FOCUS_OWNER_RE.search(code)}
    problems: list[str] = []
    if not owners:
        return ["没有任何文件声明 NUI_FOCUS_OWNER，焦点没有单点所有者"]
    for rel, code in masked.items():
        if rel not in owners and FOCUS_CALL_RE.search(code):
            problems.append(f"{rel} 直接调用了焦点原生；必须走 {sorted(owners)[0]}")
    return problems


def focus_module_problems(source: str) -> list[str]:
    """开/关路径的成对与顺序；反向用例删掉关调用后必须红。"""
    code = lua_source.blank_noise(source)
    problems: list[str] = []

    # keep_strings=True: 抹掉注释但保留字符串；注释里提到 native 名字不算调用。
    acquire = lua_source.blank_noise(
        function_block(source, "function VendorFocus.Acquire("), keep_strings=True)
    release = lua_source.blank_noise(
        function_block(source, "function VendorFocus.ReleaseOwner("), keep_strings=True)
    stop = lua_source.blank_noise(on_resource_stop_block(source), keep_strings=True)

    if "SetNuiFocusKeepInput(true)" not in acquire:
        problems.append("打开焦点没有 SetNuiFocusKeepInput(true)")
    if "SetNuiFocus(true, true)" not in acquire:
        problems.append("打开焦点没有 SetNuiFocus(true, true)")
    if (
        "SetNuiFocusKeepInput(true)" in acquire
        and "SetNuiFocus(true, true)" in acquire
        and acquire.index("SetNuiFocusKeepInput(true)") > acquire.index("SetNuiFocus(true, true)")
    ):
        problems.append("顺序反了：keepInput 必须在 SetNuiFocus 之前")

    if "SetNuiFocus(false, false)" not in release:
        problems.append("Release 没有 SetNuiFocus(false, false)，焦点会泄漏")
    # 仓库既有语义：关面板保留 keepInput，下一次打开才能继续移动。
    if "SetNuiFocusKeepInput(false)" in release:
        problems.append("Release 不该把 keepInput 置 false（会冻结下一次打开）")

    if "SetNuiFocus(false, false)" not in stop:
        problems.append("onResourceStop 没有 SetNuiFocus(false, false)")
    if "SetNuiFocusKeepInput(false)" not in stop:
        problems.append("onResourceStop 没有复位 keepInput，热重载会留给下一个资源")

    if len(FOCUS_TRUE_RE.findall(code)) != 1:
        problems.append(
            f"SetNuiFocus(true) 出现 {len(FOCUS_TRUE_RE.findall(code))} 次；"
            "开焦点只能有一个实现点")
    return problems


def exit_path_problems(vendor: str, focus: str) -> list[str]:
    """六个关闭时机都必须能到达 Release/SetNuiFocus(false)。"""
    problems: list[str] = []

    hide_offer = function_block(vendor, "local function HideOffer(")
    if "Focus.ReleaseOwner('offer')" not in hide_offer:
        problems.append("HideOffer 没有释放 offer 焦点")

    clear_menu = function_block(vendor, "local function ClearBuyMenu(")
    if "Focus.ReleaseOwner('menu')" not in clear_menu:
        problems.append("ClearBuyMenu 没有释放 menu 焦点")

    clear_offer = function_block(vendor, "local function ClearOffer(")
    if "HideOffer()" not in clear_offer:
        problems.append("ClearOffer 没有走 HideOffer（焦点会留到下一次清理）")

    prune = function_block(vendor, "local function PruneBystanderBooths(")
    if "ClearBuyMenu()" not in prune:
        problems.append("PruneBystanderBooths 离开范围时没有关购买菜单")

    cleanup = function_block(vendor, "local function CleanupQuest(")
    for needle in ("ClearOffer(", "ClearBuyMenu("):
        if needle not in cleanup:
            problems.append(f"CleanupQuest 没有调用 {needle}")

    update = function_block(vendor, "local function UpdateBuyMenu(")
    if "ClearBuyMenu()" not in update:
        problems.append("UpdateBuyMenu 超出距离时没有关菜单")

    # 收摊：vendorState state=closed 清报价/菜单。
    closed_at = vendor.find("if state == 'closed' then")
    if closed_at == -1:
        problems.append("vendorState 没有处理 state=closed")
    else:
        closed_block = vendor[closed_at:closed_at + 2000]
        for needle in ("ClearOffer(", "ClearBuyMenu()"):
            if needle not in closed_block:
                problems.append(f"state=closed 分支没有调用 {needle}")

    # 任务完成 / 失败 / 放弃：三个事件都汇到 HandleQuestEnd → CleanupQuest。
    handle = function_block(vendor, "local function HandleQuestEnd(")
    if "CleanupQuest(questId, reason)" not in handle:
        problems.append("HandleQuestEnd 没有调用 CleanupQuest")
    for event in ("QUEST_COMPLETED", "QUEST_FAILED", "QUEST_ABANDONED"):
        if event not in vendor:
            problems.append(f"没有挂 {event}")

    # 死亡：客户端 IsEntityDead 兜底；资源停止：onResourceStop 收一次。
    if "IsEntityDead" not in focus or "ReleaseAll('dead')" not in focus:
        problems.append("焦点模块没有死亡兜底（IsEntityDead → ReleaseAll）")
    if "Focus.ReleaseAll('dead')" not in vendor:
        problems.append("主循环死亡分支没有立即释放焦点")
    if "CleanupQuest(nil, 'resourceStop')" not in vendor:
        problems.append("业务侧 onResourceStop 没有 CleanupQuest")

    # 掉线是服务端路径：会话关闭 + Tick 停止。
    if "AddEventHandler('playerDropped'" not in read(BRIDGE):
        problems.append("服务端 playerDropped 没有关会话")
    return problems


def status_html_problems(html: str) -> list[str]:
    problems: list[str] = []
    for ident in REQUIRED_STATUS_IDS:
        if f'id="{ident}"' not in html:
            problems.append(f"vendor.html 缺 id={ident}")
        if f"$('{ident}')" not in html:
            problems.append(f"vendor.html 没有读取 {ident}")
    for ident in ("st-served", "st-deposit"):
        if not re.search(rf"\$\('{ident}'\)\.textContent\s*=", html):
            problems.append(f"{ident} 没有被赋值")
    if "paintStatusTime" not in html or "statusEnds" not in html:
        problems.append("剩余时间没有本地倒计时（paintStatusTime/statusEnds）")
    for field in ("served", "deposit", "remainingMs"):
        if f"d.{field}" not in html:
            problems.append(f"HTML 没有消费状态字段 {field}")
    if "backdrop-filter" in html:
        problems.append("vendor.html 用了 backdrop-filter（真机会掉帧）")
    if re.search(r'(?:src|href)\s*=\s*[\'"]https?://', html, re.I):
        problems.append("vendor.html 引用了公网资源（CEF 离线）")
    return problems


def push_status_problems(source: str) -> list[str]:
    block = lua_source.blank_noise(
        function_block(source, "local function PushStatus("), keep_strings=True)
    problems = [f"PushStatus 没有发送 {field} =" for field in HUD_FIELDS
                if f"{field} =" not in block]
    return problems


def bridge_payload_problems(source: str) -> list[str]:
    block = lua_source.blank_noise(
        function_block(source, "local function PushState("), keep_strings=True)
    problems = [f"PushState 没有发送 {field} =" for field in
                ("served", "deposit", "expiresAtMs", "serverNowMs")
                if f"{field} =" not in block]
    code = lua_source.blank_noise(source)
    if code.count("RegisterNetEvent(") != 1:
        problems.append("同事件扩字段不该新增 net event")
    return problems


def client_sources() -> dict[str, str]:
    return {
        path.relative_to(QUEST).as_posix(): read(path)
        for path in sorted((QUEST / "client").rglob("*.lua"))
    }


# ---------------------------------------------------------------------------
# 正向 + 反向：同一份判定函数先判真实仓库，再判坏形状
#
# 每个测试函数都必须“自带反向校验”（命名带 reverse/rejects/detects），否则
# tools/dev/gate_coverage.py 会把它记成一条未证明规则（GATES-03 预算）。
# ---------------------------------------------------------------------------


def client_script_entries(manifest: str) -> list[str]:
    match = re.search(r"\bclient_scripts\s*\{(.*?)\}", manifest, re.S)
    assert match, "fxmanifest 里没有 client_scripts 块"
    return re.findall(r"['\"]([^'\"]+)['\"]", match.group(1))


def manifest_order_problems(entries: list[str]) -> list[str]:
    owner = "client/vendor_focus.lua"
    consumer = "client/quest_hotdog_vendor_client.lua"
    problems: list[str] = []
    if owner not in entries:
        problems.append("vendor_focus.lua 不在 client_scripts 里")
    if consumer not in entries:
        problems.append("quest_hotdog_vendor_client.lua 不在 client_scripts 里")
    if owner in entries and consumer in entries and entries.index(owner) > entries.index(consumer):
        problems.append("焦点模块必须排在 vendor client 之前")
    return problems


def test_reverse_focus_outside_owner_is_rejected():
    assert FOCUS.is_file(), "缺 client/vendor_focus.lua"
    assert not focus_ownership_problems(client_sources())

    files = {
        "client/vendor_focus.lua": "local NUI_FOCUS_OWNER = true\n"
                                   "SetNuiFocus(true, true)\nSetNuiFocus(false, false)\n",
        "client/rogue.lua": "SetNuiFocus(true, true)\nSetNuiFocus(false, false)\n",
    }
    assert focus_ownership_problems(files)


def test_manifest_focus_order_rejects_consumer_first():
    entries = client_script_entries(read(MANIFEST))
    assert not manifest_order_problems(entries)
    assert manifest_order_problems(list(reversed(entries)))


def test_reverse_missing_close_branch_is_rejected():
    assert not focus_module_problems(read(FOCUS))

    source = read(FOCUS)
    release = function_block(source, "function VendorFocus.ReleaseOwner(")
    assert "SetNuiFocus(false, false)" in release, "变异点不唯一，先更新反向用例"
    mutated = source.replace("        SetNuiFocus(false, false)\n", "", 1)
    problems = focus_module_problems(mutated)
    assert any("Release 没有 SetNuiFocus(false, false)" in item for item in problems), problems


def test_reverse_missing_keepinput_reset_on_stop_is_rejected():
    assert not focus_module_problems(read(FOCUS))

    source = read(FOCUS)
    mutated = source.replace("    SetNuiFocusKeepInput(false)\n", "", 1)
    problems = focus_module_problems(mutated)
    assert any("没有复位 keepInput" in item for item in problems), problems


def test_reverse_menu_close_does_not_release_focus():
    assert not exit_path_problems(read(VENDOR), read(FOCUS))

    source = read(VENDOR)
    mutated = source.replace("    Focus.ReleaseOwner('menu')\n", "", 1)
    problems = exit_path_problems(mutated, read(FOCUS))
    assert any("ClearBuyMenu 没有释放 menu 焦点" in item for item in problems), problems


def test_reverse_status_field_removed_from_push_status_is_rejected():
    assert not push_status_problems(read(VENDOR))

    source = read(VENDOR)
    assert "served = booth.served," in source
    mutated = source.replace("served = booth.served,", "", 1)
    problems = push_status_problems(mutated)
    assert any("served" in item for item in problems), problems


def test_reverse_status_dom_node_removed_is_rejected():
    assert not status_html_problems(read(HTML))

    html = read(HTML)
    assert 'id="st-served"' in html
    mutated = html.replace('id="st-served"', 'id="st-served-removed"', 1)
    problems = status_html_problems(mutated)
    assert any("st-served" in item for item in problems), problems


def test_reverse_server_field_removed_is_rejected():
    assert not bridge_payload_problems(read(BRIDGE))

    source = read(BRIDGE)
    assert "served = session.served or 0," in source
    mutated = source.replace("served = session.served or 0,", "", 1)
    problems = bridge_payload_problems(mutated)
    assert any("served" in item for item in problems), problems


def run_focus_probe(source: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [LUA, str(PROBE), str(source)],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        timeout=60, stdin=subprocess.DEVNULL,
    )


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4")
def test_focus_runtime_probe_detects_wrong_open_order(tmp_path: Path):
    """真跑焦点模块，再把 keepInput/focus 顺序换错，探针必须红。"""
    proc = run_focus_probe(FOCUS)
    assert proc.returncode == 0, f"探针失败：\n{proc.stdout}\n{proc.stderr}"
    assert "SUMMARY 10/10" in proc.stdout, proc.stdout

    source = read(FOCUS)
    mutated = source.replace(
        "    SetNuiFocusKeepInput(true)\n    SetNuiFocus(true, true)\n",
        "    SetNuiFocus(true, true)\n    SetNuiFocusKeepInput(true)\n",
        1,
    )
    assert mutated != source, "变异点不唯一，先更新反向用例"
    target = tmp_path / "vendor_focus_wrong_order.lua"
    target.write_text(mutated, encoding="utf-8")
    broken = run_focus_probe(target)
    assert broken.returncode != 0, "顺序换错后探针仍然通过"
    assert "FAIL open_sequence" in broken.stdout, broken.stdout
