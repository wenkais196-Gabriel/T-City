"""GATES-02 — 变异冒烟用例本身要可信。

`tools/dev/gate_mutation_smoke.py` 往仓库里注入"该被拦住的形状"，跑对应闸门，确认它变红。
这套工具的价值完全取决于**用例指向的闸门还真的存在**：一旦某条测试被改名，用例会静默
变成空跑（pytest 对不存在的 nodeid 也会报错，但如果用例被整文件删掉就没人发现）。

这里钉三件事：
1. 每条用例的 nodeid 都能解析到真实的 `test_*` 函数；
2. 注入路径都在仓库内、且不会覆盖已存在的源文件（除声明为"就地篡改"的）；
3. 反向校验：喂一个指向不存在测试的用例，校验函数必须返回问题。
"""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
REPO = BASE.parent
TOOL = REPO / "tools" / "dev" / "gate_mutation_smoke.py"


def load_tool():
    spec = importlib.util.spec_from_file_location("gate_mutation_smoke", TOOL)
    module = importlib.util.module_from_spec(spec)
    # 必须先注册进 sys.modules：工具里有 `from __future__ import annotations` + dataclass，
    # dataclass 解析字符串注解时要回查 sys.modules[cls.__module__]，没注册就是 None。
    sys.modules["gate_mutation_smoke"] = module
    spec.loader.exec_module(module)
    return module


def unresolved(cases) -> list[str]:
    """返回 nodeid 解析不到真实测试函数的用例描述。"""
    problems = []
    for case in cases:
        nodeid = case.gate
        if "::" not in nodeid:
            problems.append(f"{nodeid}: 不是 <file>::<test> 形式")
            continue
        rel, test_name = nodeid.split("::", 1)
        path = BASE / rel
        if not path.is_file():
            problems.append(f"{nodeid}: 测试文件不存在")
            continue
        if not re.search(rf"^def {re.escape(test_name)}\(", path.read_text(encoding="utf-8"), re.M):
            problems.append(f"{nodeid}: 文件里没有 def {test_name}（改名了？）")
    return problems


def test_every_mutation_points_at_a_real_gate():
    tool = load_tool()
    assert tool.MUTATIONS, "一条用例都没有"
    problems = unresolved(tool.MUTATIONS)
    assert not problems, "变异用例指向的闸门不存在（用例会静默空跑）：\n  " + "\n  ".join(problems)


def test_mutations_never_overwrite_an_existing_source_file():
    tool = load_tool()
    problems = []
    for case in tool.MUTATIONS:
        target = case.target
        assert target.parent.is_relative_to(BASE), f"{case.path}: 注入路径跑到仓库外了"
        if case.content is not None and target.exists():
            problems.append(f"{case.path}: 文件已存在，注入会被跳过")
        if case.content is None and not target.exists():
            problems.append(f"{case.path}: 声明就地篡改但文件不存在")
    assert not problems, "\n".join(problems)


def test_each_mutation_states_what_it_represents():
    tool = load_tool()
    missing = [c.gate for c in tool.MUTATIONS if not c.what.strip()]
    assert not missing, "每条注入要说明它代表什么错误形状：" + ", ".join(missing)


def test_dry_run_lists_every_case(capsys=None):
    tool = load_tool()
    code = tool.main(["gate_mutation_smoke.py", "--dry-run"])
    assert code == 0


def test_unresolved_detects_a_renamed_test():
    from dataclasses import dataclass

    @dataclass(frozen=True)
    class Fake:
        gate: str

    assert unresolved([Fake("tests/architecture/test_economy_single_owner.py::test_does_not_exist")])
    assert not unresolved([Fake("tests/architecture/test_economy_single_owner.py::test_only_the_owner_writes_players_money")])
    assert unresolved([Fake("no-such-test")])
