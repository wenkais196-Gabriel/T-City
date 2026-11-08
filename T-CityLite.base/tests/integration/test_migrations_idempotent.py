"""P2-3：迁移必须**可重复执行** —— 对同一个库连跑两遍，第二遍不许报错。

判据来自 `tools/dev/migrations_double_apply.py`（容器里跑 `mariadb` CLI：迁移含
`CREATE TRIGGER … BEGIN … END`，用驱动就得自己写 SQL 切分器，见该脚本头部说明）。

没有 docker / 容器没起 / 没有 `server.cfg` 时 **skip** —— 静态闸门
`tests/architecture/test_migration_versions.py` 在 CI 里永远跑，这条是本地/带栈环境的强化。

修过的具体缺陷：`v2.1_perf_indexes.sql` 原来裸 `ALTER TABLE players ADD COLUMN phone_number`
+ `CREATE INDEX`，第二次执行必然 `ERROR 1060 Duplicate column name`；现在每一步都先查
`information_schema` 再 `PREPARE/EXECUTE`。
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
TOOL = REPO / "tools" / "dev" / "migrations_double_apply.py"


def _load_tool():
    spec = importlib.util.spec_from_file_location("migrations_double_apply", TOOL)
    assert spec and spec.loader, f"找不到工具：{TOOL}"
    module = importlib.util.module_from_spec(spec)
    sys.modules["migrations_double_apply"] = module
    spec.loader.exec_module(module)
    return module


def test_every_migration_can_run_twice():
    tool = _load_tool()
    try:
        clean_passes, errors = tool.double_apply()
    except tool.EnvironmentBroken as exc:
        pytest.skip(f"没有可用的本地 DB 栈，跳过：{exc}")

    assert not errors, "迁移不可重复执行：\n" + "\n".join(errors)
    assert clean_passes == 2, f"只有 {clean_passes}/2 遍无错误"
