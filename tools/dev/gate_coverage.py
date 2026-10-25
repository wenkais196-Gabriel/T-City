#!/usr/bin/env python3
"""闸门覆盖率 —— 哪些规则**从未被证明会红**。

`gate_stats.py` 回答"每条规则命中过几次"；这个工具回答另一个问题：**这条规则有没有被检验过**。

一条规则可以长期 0 命中而完全没问题（它保护的错误形状真的不存在了），也可以是"从来没人
给它写过反向注入"——后者会让人误以为安全。两者在命中率报表里长得一模一样，所以这里把
"证明"单独定义：

一条规则算"已证明"当且仅当满足其一：
  1. 它在 ``tests/architecture/gate_history.jsonl`` 里**失败过**（真的拦住过东西）；
  2. 它是 ``tools/dev/gate_mutation_smoke.py`` 里的一个变异用例（注入该形状 → 确认变红 → 撤回）；
  3. 它**本身就是反向校验**（名字里带 reverse / injected / fires / detects / rejects / on_bad_shapes）
     —— 这类测试自己构造坏形状并断言失败，本身就是"这条规则会红"的证明。

其余都算"未证明"。未证明不是错误，是**技术债**：所以用一个预算文件
（``tests/architecture/gate_coverage_budget.json``）钉住数量，只许往下走。

用法::

    python3 tools/dev/gate_coverage.py             # 汇总
    python3 tools/dev/gate_coverage.py --list      # 未证明清单（按模块分组）
    python3 tools/dev/gate_coverage.py --json

退出码：0 = 读完算完；2 = 环境问题（找不到测试目录/历史文件）。
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
ARCH = BASE / "tests" / "architecture"
HISTORY = ARCH / "gate_history.jsonl"
SMOKE = REPO / "tools" / "dev" / "gate_mutation_smoke.py"

TEST_DEF = re.compile(r"^def (test_\w+)\(", re.M)

#: 反向校验的命名约定。约定的好处是工具能把"规则"和"规则的证明"分开数。
SELF_PROVING = re.compile(r"test_\w*(on_bad_shapes|reverse|injected|fires|detects|rejects|catches)\w*")


def architecture_rules() -> dict[str, list[str]]:
    """{模块文件名: [test 函数名, ...]}"""
    out: dict[str, list[str]] = {}
    for path in sorted(ARCH.glob("test_*.py")):
        names = TEST_DEF.findall(path.read_text(encoding="utf-8", errors="ignore"))
        if names:
            out[path.name] = names
    return out


def ever_failed() -> set[str]:
    """历史里失败过的 nodeid（相对 T-CityLite.base 的路径）。"""
    failed: set[str] = set()
    if not HISTORY.is_file():
        return failed
    for line in HISTORY.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue                     # 坏行跳过，和 gate_stats 的容错策略一致
        for nodeid, status in (record.get("counts") or {}).items():
            if status == "failed":
                failed.add(nodeid)
    return failed


def smoke_cases() -> set[str]:
    """变异冒烟工具里声明过的 nodeid。"""
    if not SMOKE.is_file():
        return set()
    spec = importlib.util.spec_from_file_location("gate_mutation_smoke", SMOKE)
    if spec is None or spec.loader is None:
        return set()
    module = importlib.util.module_from_spec(spec)
    sys.modules["gate_mutation_smoke"] = module   # dataclass + future annotations 需要
    spec.loader.exec_module(module)
    return {case.gate for case in module.MUTATIONS}


def coverage() -> dict:
    rules = architecture_rules()
    proven = ever_failed() | smoke_cases()
    all_nodes = [f"tests/architecture/{mod}::{name}" for mod, names in rules.items() for name in names]
    self_proving = [n for n in all_nodes if SELF_PROVING.fullmatch(n.split("::")[1])]
    proven = proven | set(self_proving)
    unproven = [n for n in all_nodes if n not in proven]
    by_module: dict[str, list[str]] = defaultdict(list)
    for node in unproven:
        by_module[node.split("/")[-1].split("::")[0]].append(node.split("::")[1])
    return {
        "total": len(all_nodes),
        "proven_by_history": len([n for n in all_nodes if n in ever_failed()]),
        "proven_by_smoke": len([n for n in all_nodes if n in smoke_cases()]),
        "proven_by_reverse_tests": len(self_proving),
        "proven": len(all_nodes) - len(unproven),
        "unproven": len(unproven),
        "unproven_by_module": dict(sorted(by_module.items(), key=lambda kv: -len(kv[1]))),
    }


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--list", action="store_true", help="列出未证明的规则（按模块分组）")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv[1:])

    if not ARCH.is_dir():
        print(f"找不到架构闸门目录：{ARCH}", file=sys.stderr)
        return 2

    data = coverage()
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 0

    print(f"架构规则 {data['total']} 条：已证明 {data['proven']} 条"
          f"（历史命中 {data['proven_by_history']} / 变异冒烟 {data['proven_by_smoke']} / "
          f"自带反向校验 {data['proven_by_reverse_tests']}），未证明 {data['unproven']} 条")
    if args.list:
        for module, names in data["unproven_by_module"].items():
            print(f"\n{module}  ({len(names)})")
            for name in names:
                print(f"    {name}")
    else:
        print("\n未证明最多的模块：")
        for module, names in list(data["unproven_by_module"].items())[:8]:
            print(f"  {len(names):3d}  {module}")
        print("\n（--list 看全部。未证明不是错误，是技术债；"
              "要么给它写一个变异用例，要么删掉这条规则。）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
