"""P2-3 闸门：迁移版本号唯一 + 文件名形状。

背景：`migrations/` 下有 4 组**重号**（v0.7 ×2、v2.2 ×2、v3.11 ×2、v3.12 ×2）。重号本身不会让
`tools/dev/local_stack.sh` 崩（它用 `ls | sort -V`），但它把「哪个先跑」变成了按文件名字母序的
意外结果：同一个版本号下两条迁移互相看不见，谁依赖谁全靠运气；新加第三条时更是没人能说清顺序。

所以这条闸门的判据是**版本号前缀全仓唯一**，零基线零豁免 —— 要并行改同一版本，就显式写
`v3.11.1` `/ v3.12.1` 这种二级号，而不是再塞一个 `v3.11_`。
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
MIGRATIONS = BASE / "migrations"

# v3 / v3.11 / v0.7.2 这些前缀都合法；后面必须是下划线 + 全小写蛇形名
FILENAME = re.compile(r"^v(?P<version>\d+(?:\.\d+)*)_(?P<name>[a-z0-9][a-z0-9_]*)\.sql$")


def versions(directory: Path = MIGRATIONS) -> dict[str, list[str]]:
    """版本号 → 文件列表（按文件名排序）。"""
    found: dict[str, list[str]] = {}
    for path in sorted(directory.glob("*.sql")):
        match = FILENAME.match(path.name)
        if not match:
            continue
        found.setdefault(match.group("version"), []).append(path.name)
    return found


def duplicates(directory: Path = MIGRATIONS) -> dict[str, list[str]]:
    return {version: names for version, names in versions(directory).items() if len(names) > 1}


def malformed(directory: Path = MIGRATIONS) -> list[str]:
    return [path.name for path in sorted(directory.glob("*.sql")) if not FILENAME.match(path.name)]


# ══════════════════════════════════════════════════════════════════
# 仓库现状
# ══════════════════════════════════════════════════════════════════


def test_every_migration_version_is_unique():
    dup = duplicates()
    assert not dup, (
        "同一个版本号下有多条迁移（先后顺序变成文件名字母序的意外结果）："
        f"{dup}。给后来者加二级号（v3.11.1_…），不要在 v3.11_ 下再塞一条。"
    )
    # 反向保护：一个都扫不到说明口径写错（目录改名/正则写坏），闸门会永久绿
    assert len(versions()) >= 30, f"只扫到 {len(versions())} 个版本，迁移目录可能变了"


def test_migration_filenames_are_well_formed():
    bad = malformed()
    assert not bad, f"迁移文件名不符合 v<version>_<snake_name>.sql：{bad}"


# ══════════════════════════════════════════════════════════════════
# 反向形状：同样的重号 / 坏名字喂进去必须被认出来
# ══════════════════════════════════════════════════════════════════

BAD_TREE = [
    "v3.11_police_case_verdict.sql",
    "v3.11_police_npc_callout.sql",
    "v3.12.1_police_incident_ref.sql",
    "v3.12.Police_Outbox.sql",       # 大写 + 点分名 → 文件名形状不合规
    "3.13_no_prefix.sql",            # 少了 v 前缀
]

GOOD_TREE = [
    "v3.11_police_case_verdict.sql",
    "v3.11.1_police_npc_callout.sql",
    "v3.12.1_police_incident_ref.sql",
    "v3.12.2_police_outbox.sql",
]


def _write(directory: Path, names: list[str]) -> Path:
    for name in names:
        (directory / name).write_text("-- probe\n", encoding="utf-8")
    return directory


def test_reverse_duplicate_versions_are_detected(tmp_path):
    _write(tmp_path, BAD_TREE)
    assert duplicates(tmp_path), "重号没被认出来"
    assert "3.11" in duplicates(tmp_path), "版本号键应当是不带 v 的数字串"


def test_reverse_malformed_names_are_detected(tmp_path):
    _write(tmp_path, BAD_TREE)
    bad = malformed(tmp_path)
    assert "v3.12.Police_Outbox.sql" in bad
    assert "3.13_no_prefix.sql" in bad


def test_reverse_clean_tree_passes(tmp_path):
    _write(tmp_path, GOOD_TREE)
    assert not duplicates(tmp_path), "合法命名被判成重号"
    assert not malformed(tmp_path), "合法命名被判成不合规"
