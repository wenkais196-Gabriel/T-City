"""`DirtyFlushStats` 的契约：管线未接入要**说出来**，不能返回一个永远为 0 的计数。

背景（老账）：`custom-testing` 的压测套件原来靠 `dirty_count == 0` 判断"脏池是空的"，而实际上
`DirtyFlush` 全局从来没有被定义过 —— 导出走的是 `{ dirty_count = 0 }` 兜底，于是那条断言永远是
"空池，通过"。现在导出带上 `available` 字段，压测据此报**跳过**而不是假通过。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _run() -> dict[str, str]:
    proc = subprocess.run(
        ["lua5.4", (FIXTURES / "bus_dirtyflush_probe.lua").as_posix(),
         (BASE / "resources" / "[standalone]" / "core-framework").as_posix()],
        capture_output=True,
        text=True,
        timeout=90,
    )
    assert proc.returncode == 0, f"probe 失败：{proc.stderr} / {proc.stdout}"
    data: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        key, _, value = line.partition("|")
        data[key] = value
    return data


def test_dirtyflush_stats_reports_whether_the_pipeline_exists():
    data = _run()
    assert data["ABSENT_AVAILABLE"] == "true", "管线未接入时没标 available=false（会让人以为池是空的）"
    assert data["ABSENT_COUNT"] == "true", "兜底 dirty_count 不是 0（调用方会误判）"
    assert data["PRESENT_AVAILABLE"] == "true", "管线存在时没标 available=true"
    assert data["PRESENT_COUNT"] == "true", "管线存在时没透出真实数字"
    assert data["PRESENT_FIELDS_KEPT"] == "true", "透出时丢了 Stats() 里的其他字段"
    assert data["NIL_STATS_AVAILABLE"] == "true", "Stats() 返回 nil 时没降级成 available=false"
