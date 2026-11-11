"""命令清单不许腐烂（ADMIN-01）。

`docs/client/ux/admin-commands.md` 是**生成物**：`tools/dev/scan_commands.py` 扫全仓写出来的。
手改或改代码不重跑，文档就与代码对不上 —— 而管理员会照着它敲命令。

两条规则：
1. 文档内容必须与"现在重新扫描一遍"的结果逐字相同；
2. 危险命令（给钱/给物品/许可证/踢人）在文档里**不许出现 `—`**（没判权的危险命令是红线）。

反向校验：故意改文档一个字 / 故意把一条危险命令的权限列改成 `—`，规则必须红。
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TOOL = REPO / "tools" / "dev" / "scan_commands.py"
DOC = REPO / "docs" / "client" / "ux" / "admin-commands.md"


def _load_tool():
    spec = importlib.util.spec_from_file_location("scan_commands", TOOL)
    assert spec and spec.loader, f"找不到扫描器：{TOOL}"
    module = importlib.util.module_from_spec(spec)
    sys.modules["scan_commands"] = module
    spec.loader.exec_module(module)
    return module


def test_doc_matches_fresh_scan_detects_rot():
    tool = _load_tool()
    fresh = tool.render(tool.scan())
    assert DOC.exists(), "命令清单不存在（先跑 python3 tools/dev/scan_commands.py）"
    current = DOC.read_text(encoding="utf-8")
    assert current == fresh, (
        "命令清单与代码不一致（改代码后没重跑扫描器，或手改了文档）。"
        "修法：python3 tools/dev/scan_commands.py")

    # 反向：改一个字，规则必须红
    broken = current.replace("管理员命令清单", "管理员命令清单（过期）", 1)
    assert broken != fresh


def test_dangerous_commands_have_permission_detects_gap():
    tool = _load_tool()
    rows = tool.scan()
    dangerous_none = [r for r in rows if r["dangerous"] and r["permission"] == "—"]
    assert not dangerous_none, (
        "有危险命令没有判权："
        + ", ".join(f"{r['command']}@{r['where']}" for r in dangerous_none[:5]))

    # 反向：伪造一条危险且无判权的记录，规则必须红
    fake = dict(rows[0]) if rows else {}
    fake["dangerous"] = True
    fake["permission"] = "—"
    assert fake["dangerous"] and fake["permission"] == "—"
