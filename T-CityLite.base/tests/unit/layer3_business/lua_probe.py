"""tests/unit/layer3_business/lua_probe.py — 跑 Lua probe 并解析 `KEY|VALUE` 输出。

为什么单独一个模块：`test_shops_guards.py`、`test_quest_step_gate.py` 等一批业务测试
都要「用 lua5.4 真加载资源源码 → 收集 emit 出来的键值」。这段脚手架原本在每个测试文件里
复制一遍，SonarCloud 会把它算成新代码重复（阶段 D · C1 报过 15.8%）。

用法：

    from lua_probe import run_probe
    data = run_probe("shops_probe.lua", "[qb]/qb-shops", fixtures=Path(__file__).parent / "fixtures")

约定：probe 第一参数是资源目录；stdout 每行 `KEY|VALUE`，同名键保留第一条。
`HANDLER_ERROR|...` 视为失败（说明被测 handler 抛错了，不能当"没付钱"来读）。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

#: 仓库根（本文件在 T-CityLite.base/tests/unit/layer3_business/ 下）
BASE = Path(__file__).resolve().parents[3]

#: core-framework 的 DB 结果适配器。S4 之后写库调用点统一走 `Db.Insert/Db.Update`，
#: 所以加载写库模块的 harness 必须先把适配器读进来（顺序与 custom-police 的 manifest 一致）。
DB_ADAPTER = BASE / "resources" / "[standalone]" / "core-framework" / "server" / "db.lua"


#: custom-industry 的共享模块（`server/org_id.lua`）。它必须排在 treasury / facility /
#: production / sale 之前加载——拼装顺序要与该资源 fxmanifest 的 server_scripts 一致。
INDUSTRY_ORG_ID = BASE / "resources" / "[custom]" / "custom-industry" / "server" / "org_id.lua"


def load_with_db(stubs: str, source: Path, body: str, prereqs: tuple[Path, ...] = ()) -> str:
    """拼出「stubs → db.lua → prereqs → 被测源码 → body」的 Lua 脚本。

    这段拼装原本在 test_police_records/citations/evidence_writer 里各写一遍
    （同一段 10 行 × 3），SonarCloud 会算成新代码重复。

    `prereqs` 是被测源码依赖的**同资源共享模块**（先加载，顺序照 manifest）。
    """
    return (
        stubs + "\n"
        + DB_ADAPTER.read_text(encoding="utf-8") + "\n"
        + "".join(prereq.read_text(encoding="utf-8") + "\n" for prereq in prereqs)
        + source.read_text(encoding="utf-8") + "\n"
        + body
    )


def load_industry(stubs: str, source: Path, body: str) -> str:
    """custom-industry 专用：先加载 `server/org_id.lua` 再加载被测文件。"""
    return load_with_db(stubs, source, body, prereqs=(INDUSTRY_ORG_ID,))


def run_probe(
    probe: str,
    resource_path: str,
    fixtures: Path | None = None,
    timeout: int = 90,
    extra_args: list[str] | None = None,
) -> dict[str, str]:
    """跑一个离线 Lua probe，返回 `{KEY: VALUE}`。

    `resource_path` 是相对 `T-CityLite.base/resources/` 的路径，
    例如 `[qb]/qb-shops` 或 `[custom]/custom-quest`。
    """
    probe_path = (fixtures or (Path(__file__).resolve().parent / "fixtures")) / probe
    argv = ["lua5.4", probe_path.as_posix(), (BASE / "resources" / resource_path).as_posix()]
    argv.extend(extra_args or [])
    proc = subprocess.run(
        argv,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    assert proc.returncode == 0, f"probe 失败：{proc.stderr} / {proc.stdout}"

    data: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        data.setdefault(key, value)

    if "HANDLER_ERROR" in data:
        raise AssertionError(f"handler 抛错：{data['HANDLER_ERROR']}")
    return data
