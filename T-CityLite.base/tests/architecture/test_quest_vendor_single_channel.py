"""热狗收摊只能有一条推进通道（真机：按一次 E 推进两次 → Step order violation）。

事故形状（2026-11-15 复核）：
  * `quest_hotdog.lua` 的 `step_sell`（`type = 'vendor'`）同时带了 `coords/radius/duration`；
  * `quest_manager.lua` 的 `_eventMap.VENDOR` 把它映射到 `quest:client:nodeInteract`；
  * 客户端于是画了一个通用交互点，按 E 跑完进度条 → `nodeComplete` → 推进一次；
  * 同一个 E 还触发了热狗客户端的收摊请求 → 服务端 `close` 分支再 `AdvanceStep` 一次。
    第二次必报 `Step order violation`。

这一片选择方案 A：**模板侧不再给 vendor 步骤任何通用交互数据**。理由：
  1. 全仓只有这一个 `type = 'vendor'` 模板（本闸门同时盯住未来的新增）；
  2. 收摊的交互提示由热狗客户端自己画（`vendorState` 的 NUI 状态条 + E 键映射），
     不依赖模板坐标 —— 模板里的 `STAND_A` 本来也只是参考点，不是玩家实际摊位；
  3. 不动 `_eventMap`，BOOTH / RENTAL 等仍在复用 `nodeInteract`，共享映射不需要改，
     也不会让既有单测（它断言 VENDOR == INTERACT）失真。

判据：`type = 'vendor'` 的步骤，`data` 里不得出现 `nodeInteract` 消费的触发字段。
本测试自己构造坏形状（带 coords 的 vendor 步）喂给同一个探针，必须判红；
再喂一个干净的 vendor 步做正向对照，证明规则不是“见 vendor 就红”。
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

#: tests/architecture → tests → T-CityLite.base
BASE = Path(__file__).resolve().parents[2]
QUESTS = BASE / "resources/[custom]/custom-quest/config/quests"
PROBE = Path(__file__).with_name("fixtures") / "vendor_step_probe.lua"

#: 优先 .exe：Windows PATH 里同时有 lua5.4（无扩展名）与 lua5.4.exe，
#: subprocess 只能直接执行后者（见 AGENTS.md §5）。
LUA = shutil.which("lua5.4.exe") or shutil.which("lua5.4")

#: `quest:client:nodeInteract` 真正消费的字段：
#:   * coords / targetCoords：没有它客户端直接 return；有它才会画点并在 E 后 nodeComplete；
#:   * radius / duration：交互范围与进度条时长（任务书点名要移除的两项）。
#: 只禁这四个：vendor 步骤将来若需要自己的展示字段，不应该被误伤。
INTERACTION_DATA_KEYS = frozenset({"coords", "targetCoords", "radius", "duration"})

BAD_VENDOR_STEP = """return {
    {
        id = 'probe_vendor_interact',
        steps = {
            {
                id = 'step_sell',
                type = 'vendor',
                data = {
                    coords = { x = 215.8, y = -810.3, z = 30.7 },
                    radius = 3.0,
                    duration = 800,
                },
            },
        },
    },
}
"""

#: ExecuteNode 也接受 `nextStep.payload`（`nextStep.data or nextStep.payload`），
#: 换个字段名同样会激活通用交互，所以这条形状也必须判红。
BAD_VENDOR_PAYLOAD = """return {
    {
        id = 'probe_vendor_payload',
        steps = {
            {
                id = 'step_sell',
                type = 'vendor',
                payload = {
                    coords = { x = 215.8, y = -810.3, z = 30.7 },
                },
            },
        },
    },
}
"""

CLEAN_VENDOR_STEP = """return {
    {
        id = 'probe_vendor_clean',
        steps = {
            { id = 'step_sell', type = 'vendor' },
        },
    },
}
"""


def _scan(paths: list[Path]) -> list[dict]:
    """跑 Lua 探针，返回 [{path, quest, step, keys}]。"""
    assert LUA is not None, "需要 lua5.4：这条闸门要真加载模板表，不能靠正则猜"
    proc = subprocess.run(
        [LUA, str(PROBE), *(str(path) for path in paths)],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90,
    )
    assert proc.returncode == 0, (
        "模板加载失败（闸门看不见就不能算通过）：\n" + proc.stdout + proc.stderr
    )

    rows = []
    for line in proc.stdout.splitlines():
        if not line.startswith("VENDOR|"):
            continue
        _, path, quest_id, step_id, raw_keys = line.split("|", 4)
        rows.append({
            "path": path,
            "quest": quest_id,
            "step": step_id,
            "keys": {key for key in raw_keys.split(",") if key},
        })
    return rows


def _violations(rows: list[dict]) -> list[str]:
    return [
        f"{row['quest']}/{row['step']}（{Path(row['path']).name}）带了 "
        f"{sorted(row['keys'] & INTERACTION_DATA_KEYS)}"
        for row in rows
        if row["keys"] & INTERACTION_DATA_KEYS
    ]


def test_vendor_step_shape_rejects_generic_interaction_data(tmp_path: Path) -> None:
    # 真实仓库：vendor 步骤不得再挂通用交互数据。
    # 用 rglob：模板也在 config/quests/lego/ 这样的子目录里注册（见 quest_registry.lua）。
    real = _scan(sorted(QUESTS.rglob("*.lua")))
    found = {(row["quest"], row["step"]) for row in real}
    assert ("hotdog_dev_rental", "step_sell") in found, (
        "没扫到热狗的 vendor 步骤：探针的 convar 桩失效或模板被改名，"
        f"实际扫到 {sorted(found)}"
    )
    bad = _violations(real)
    assert not bad, (
        "vendor 步骤同时拥有通用交互数据 —— 客户端会画点并报 nodeComplete，"
        "与服务端收摊各推进一次（Step order violation）：\n  " + "\n  ".join(bad)
    )

    # 反向校验：同样的 vendor 步骤，只要带上 coords/radius/duration 就必须判红。
    dirty = tmp_path / "quest_vendor_dirty.lua"
    dirty.write_text(BAD_VENDOR_STEP, encoding="utf-8")
    dirty_rows = _scan([dirty])
    assert _violations(dirty_rows), (
        "带 coords/radius/duration 的 vendor 步骤没有被判红 —— 这条闸门证明不了任何东西"
    )

    # 反向校验 2：写成 step.payload 也一样会被 ExecuteNode 采用，必须判红。
    payload_dirty = tmp_path / "quest_vendor_payload_dirty.lua"
    payload_dirty.write_text(BAD_VENDOR_PAYLOAD, encoding="utf-8")
    assert _violations(_scan([payload_dirty])), (
        "coords 写在 step.payload 里逃过了闸门 —— ExecuteNode 会读它并启动通用交互"
    )

    # 正向对照：干净形状必须通过，避免规则退化成“见 vendor 就红”。
    clean = tmp_path / "quest_vendor_clean.lua"
    clean.write_text(CLEAN_VENDOR_STEP, encoding="utf-8")
    assert not _violations(_scan([clean])), "没有交互数据的 vendor 步骤被误判了"
