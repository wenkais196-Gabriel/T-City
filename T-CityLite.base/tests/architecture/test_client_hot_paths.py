"""CLIENT-01 — 逐帧循环里的两件事必须走统一实现。

历史：`custom-police/client/job.lua` 有 **8 段**几乎一样的逐帧轮询（值班/储物柜/垃圾桶/
直升机/拖车场/车库/指纹/证据），每段 14~17 行，差别只有"哪个 flag""要不要在车里""按下做什么"。
其中 6 段还带着 `if PlayerJob.onduty then sleep = 5 end` —— `sleep` 全局从未被读过，是拷贝留下的死代码。

这类循环的代价不在于"每帧做的事多"，而在于：
  * 它是纯轮询（Wait(0)），等的却只是一个按键；
  * 8 份拷贝各自演化，退出条件藏在 else 分支里，看不出它其实只在区域内才活；
  * 新功能会再拷一份。

所以钉两条：
1. `while ... do` 里同时出现 `IsControlJustReleased` 与 `Wait(0)` 的，只能出现在
   `client/interact.lua`（`PoliceInteract.Watch` 是唯一实现）；
2. 任何逐帧循环体内，`GetEntityCoords(PlayerPedId())` 最多一次——每帧重复取 ped 坐标
   是白跑（`evidence.lua` 的三个分支原本各取一次）。
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
CLIENT = BASE / "resources" / "[custom]" / "custom-police" / "client"
OWNER = CLIENT / "interact.lua"

WHILE_RE = re.compile(r"^(?P<indent>\s*)while\b.*\bdo\b")
#: Wait(0) 与 Wait(1) 都算逐帧（1ms 和 0ms 在玩家体感上没有区别）
PER_FRAME = re.compile(r"\bWait\(\s*[01]\s*\)")
CONTROL_POLL = re.compile(r"\bIsControlJustReleased\s*\(")
PED_COORDS = re.compile(r"GetEntityCoords\(\s*PlayerPedId\(\)\s*\)")


def loop_blocks(path: Path) -> list[tuple[int, str]]:
    """返回 [(起始行号, 循环体)]；按缩进匹配同名 `end`。"""
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    blocks: list[tuple[int, str]] = []
    for index, line in enumerate(lines):
        match = WHILE_RE.match(line)
        if not match:
            continue
        indent = len(match.group("indent"))
        body: list[str] = []
        for cursor in range(index + 1, len(lines)):
            current = lines[cursor]
            if current.strip() == "end" and (len(current) - len(current.lstrip())) == indent:
                break
            body.append(current)
        blocks.append((index + 1, "\n".join(body)))
    return blocks


#: 逐帧轮询但**不该**并入 helper 的地方：文件 → (行号, 为什么不一样)
#: 例外要带痕迹校验：痕迹（该文件仍有 IsControlJustReleased）消失就该删掉这一行。
# 登记的是**允许的处数**，不是行号：行号会被上面任何一次无关编辑推走，
# 于是闸门开始报"第 230 行逐帧轮询按键"这种假红（加四行日志就红一次）。
EXCEPTIONS: dict[str, tuple[int, str]] = {
    "evidence.lua": (
        1,
        "这不是\"站在区域里按 E\"：三个目标（弹壳/血迹/指纹）各自带就近判定、"
        "DrawText3D 提示与不同的按键副作用，由 Wait(1) 驱动绘制；并发按键会互相吞掉，"
        "合并成单区域 helper 会改变行为。已把每帧的 ped 坐标取值提到循环外（一次/帧）。",
    ),
}


def violations() -> list[str]:
    found: list[str] = []
    polls_by_file: dict[str, list[int]] = {}
    for path in sorted(CLIENT.glob("*.lua")):
        for line_no, body in loop_blocks(path):
            if path == OWNER:
                continue
            if PER_FRAME.search(body) and CONTROL_POLL.search(body):
                excused = EXCEPTIONS.get(path.name)
                polls_in_file = polls_by_file.setdefault(path.name, [])
                polls_in_file.append(line_no)
                if not excused or len(polls_in_file) > excused[0]:
                    found.append(
                        f"{path.name}:{line_no} 逐帧轮询按键 —— 用 PoliceInteract.Watch()")
            ped_calls = len(PED_COORDS.findall(body))
            if PER_FRAME.search(body) and ped_calls > 1:
                found.append(
                    f"{path.name}:{line_no} 逐帧循环里取了 {ped_calls} 次 ped 坐标 —— 提到循环外取一次")
    return found


def test_no_duplicate_per_frame_control_polling():
    found = violations()
    assert not found, "逐帧循环不该自己轮询按键/坐标：\n  " + "\n  ".join(found)


def test_the_owner_itself_still_polls():
    """反向：owner 必须真的在轮询，否则这条规则会"因为没人做事"而永远绿。"""
    source = OWNER.read_text(encoding="utf-8")
    assert "IsControlJustReleased" in source and PER_FRAME.search(source), (
        "PoliceInteract.Watch 自己不轮询了？那 8 个调用点就没有东西在等按键")


def test_job_lua_delegates_instead_of_reimplementing():
    job = (CLIENT / "job.lua").read_text(encoding="utf-8")
    assert job.count("PoliceInteract.Watch(") >= 8, "8 个区域交互都该走 helper"
    assert not CONTROL_POLL.search(job), "job.lua 里不该再有手写的按键轮询"
    assert "sleep = 5" not in job, "`sleep` 是拷贝留下的死赋值，从未被读取"


def test_scanner_reverse_check(tmp_path: Path):
    """反向校验：喂一段"自己轮询"的源码，必须被判违规。"""
    global CLIENT, OWNER
    original_client, original_owner = CLIENT, OWNER
    try:
        CLIENT = tmp_path
        OWNER = tmp_path / "interact.lua"
        (tmp_path / "rogue.lua").write_text(
            "CreateThread(function()\n"
            "    while true do\n"
            "        Wait(0)\n"
            "        if IsControlJustReleased(0, 38) then break end\n"
            "    end\n"
            "end)\n", encoding="utf-8")
        assert violations(), "手写按键轮询必须被抓到"

        (tmp_path / "rogue.lua").write_text(
            "CreateThread(function()\n"
            "    while true do\n"
            "        Wait(0)\n"
            "        local a = GetEntityCoords(PlayerPedId())\n"
            "        local b = GetEntityCoords(PlayerPedId())\n"
            "    end\n"
            "end)\n", encoding="utf-8")
        assert violations(), "每帧取两次 ped 坐标必须被抓到"

        (tmp_path / "rogue.lua").write_text(
            "CreateThread(function()\n"
            "    while true do\n"
            "        Wait(0)\n"
            "        local a = GetEntityCoords(PlayerPedId())\n"
            "    end\n"
            "end)\n", encoding="utf-8")
        assert not violations(), "只取一次不该被误报"
    finally:
        CLIENT, OWNER = original_client, original_owner


def test_exceptions_still_describe_the_truth():
    """例外不是永久豁免：痕迹消失（循环没了 / 文件删了）就该把这一行删掉。"""
    stale = []
    for name, (allowed_count, reason) in EXCEPTIONS.items():
        path = CLIENT / name
        if not path.is_file():
            stale.append(f"{name}: 文件不存在")
            continue
        if not CONTROL_POLL.search(path.read_text(encoding="utf-8", errors="ignore")):
            stale.append(f"{name}: 已经没有按键轮询了")
        if not reason.strip():
            stale.append(f"{name}: 没写清为什么必须是例外")
    assert not stale, "\n".join(stale)
