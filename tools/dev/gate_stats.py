#!/usr/bin/env python3
"""规则命中率采集器 —— 把每次架构闸门运行的结果变成可汇总的历史。

背景：``docs/engineering/agent-operating-model.md`` §5 的第 4 个度量是「规则命中率」：
每条宪法/闸门的拦截次数；长期 0 命中的规则要么删掉，要么说明它没被检验
（后者会让人误以为安全）。这个脚本只做一件事——让那个数字可采集。

用法::

    # 1) 跑整套 tests/architecture，并把结果追加进 gate_history.jsonl
    python3 tools/dev/gate_stats.py --record

    # 2) 默认 --report：每条规则最近一次结果 + 最近 20 次通过/失败 + 0 命中清单
    python3 tools/dev/gate_stats.py --report
    python3 tools/dev/gate_stats.py --report --window 50
    python3 tools/dev/gate_stats.py --report --json

设计约束（和闸门本身保持一致）：

* **只读仓库、只追加数据**：``--record`` 除了往历史文件追加一行 JSON 之外不改任何东西；
* **离线、确定性、标准库**：只依赖 ``subprocess`` + ``json``，不引第三方包；
* **不因「有规则从未失败」而失败**：这是报告工具，退出码 0 就代表「读到了、算完了」；
  只有「找不到 pytest 目录」这种环境问题才退出 2；
* **历史坏了不崩**：损坏的行跳过并计数，其余行照常统计；
* **节点名 = 规则名**：历史里存的是 pytest nodeid（``<file>::<test>``），
  这正是「一条闸门规则」在这套测试里的唯一身份。

判读提示：一条规则「0 命中」通常意味着两种之一——它保护的错误形状已经不存在了
（可以删），或者从来没人给它写过反向注入（``test_reverse_check_detects_*`` 这类用例
存在的意义就是让正向规则至少被检验一次）。报告不做这个判断，只把清单摊开。
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
ARCH_DIR = BASE / "tests" / "architecture"
HISTORY = ARCH_DIR / "gate_history.jsonl"
PYTHON = "/usr/bin/python3"
PYTEST_FLAGS = ["-q", "--tb=no", "-rA"]

DEFAULT_WINDOW = 20

#: pytest ``-rA`` 短摘要行 -> 本工具的三种状态。
#: ``ERROR``（fixture/collection 出错）按失败计：它同样是「这次闸门没通过」。
#: ``XFAIL``/``SKIPPED`` 记成 skipped 而不是 passed —— 没跑不等于通过。
STATUS_BY_OUTCOME = {
    "PASSED": "passed",
    "FAILED": "failed",
    "ERROR": "failed",
    "SKIPPED": "skipped",
    "XFAIL": "skipped",
    "XPASS": "passed",
}

SUMMARY_LINE = re.compile(
    r"^(?P<outcome>PASSED|FAILED|ERROR|SKIPPED|XFAIL|XPASS)\s+(?P<nodeid>\S.*?)\s*(?:\s+-\s+.*)?$"
)

EXIT_OK = 0
EXIT_ENV = 2


# ── 解析 ───────────────────────────────────────────────────────────────────


def parse_pytest_summary(text: str) -> "OrderedDict[str, str]":
    """从 pytest ``-rA`` 输出里抽出 ``nodeid -> passed|failed|skipped``。

    只认短摘要段里的整行（``PASSED tests/...::test_x``），正文里的同名 token
    不会误伤：行首必须是 outcome 关键字。重复出现的 nodeid 以最后一次为准
    （pytest 对 rerun 场景会打多行）。
    """
    results: "OrderedDict[str, str]" = OrderedDict()
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        match = SUMMARY_LINE.match(line)
        if not match:
            continue
        status = STATUS_BY_OUTCOME[match.group("outcome")]
        results[match.group("nodeid").strip()] = status
    return results


def current_commit(cwd: Path = REPO) -> str:
    """``git rev-parse --short HEAD``；不在 git 里就返回 ``unknown``（不阻断）。"""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    commit = out.stdout.strip()
    return commit or "unknown"


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_record(results: dict, commit: str, ts: str | None = None) -> dict:
    """把一次解析结果变成一条历史记录（skipped 不进 counts，不当成通过）。"""
    counts = {node: st for node, st in results.items() if st in ("passed", "failed")}
    return {"ts": ts or utc_now(), "commit": commit, "counts": counts}


def run_architecture_suite(arch_dir: Path = ARCH_DIR) -> tuple[str, int]:
    """跑整套架构闸门，返回 (合并输出, 退出码)。"""
    try:
        target = str(arch_dir.relative_to(BASE))
    except ValueError:
        target = str(arch_dir)
    proc = subprocess.run(
        [PYTHON, "-m", "pytest", target, *PYTEST_FLAGS],
        cwd=str(BASE),
        capture_output=True,
        text=True,
        check=False,
    )
    return (proc.stdout or "") + (proc.stderr or ""), proc.returncode


# ── 历史读写 ───────────────────────────────────────────────────────────────


def load_history(path: Path) -> tuple[list[dict], int]:
    """读 JSONL 历史，返回 (记录列表, 损坏行数)。缺文件 = 空历史。"""
    if not path.is_file():
        return [], 0
    records: list[dict] = []
    bad = 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            bad += 1
            continue
        if not isinstance(obj, dict) or not isinstance(obj.get("counts"), dict):
            bad += 1
            continue
        records.append(obj)
    return records, bad


def append_record(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


# ── 汇总 ───────────────────────────────────────────────────────────────────


def build_report(records: list[dict], window: int, bad_lines: int, history_path: Path) -> dict:
    """按 nodeid 汇总：最近一次结果、窗口内通过/失败、全历史失败次数、0 命中清单。"""
    rules: "OrderedDict[str, dict]" = OrderedDict()

    for record in records:
        for nodeid, status in record.get("counts", {}).items():
            if not isinstance(nodeid, str) or not isinstance(status, str):
                continue
            entry = rules.setdefault(
                nodeid,
                {
                    "nodeid": nodeid,
                    "last": status,
                    "pass": 0,
                    "fail": 0,
                    "fail_total": 0,
                    "runs": 0,
                    "last_failed_ts": None,
                },
            )
            entry["last"] = status
            entry["runs"] += 1
            if status == "failed":
                entry["fail_total"] += 1
                entry["last_failed_ts"] = record.get("ts")

    # 窗口内统计单独走一遍，保证「最近 N 次」是最近 N 条记录，而不是最近 N 条变化
    recent = records[-window:] if window > 0 else records
    for record in recent:
        for nodeid, status in record.get("counts", {}).items():
            entry = rules.get(nodeid)
            if entry is None:
                continue
            if status == "passed":
                entry["pass"] += 1
            elif status == "failed":
                entry["fail"] += 1

    ordered = sorted(rules.values(), key=lambda r: r["nodeid"])
    zero_hit = [r["nodeid"] for r in ordered if r["fail_total"] == 0]

    latest = records[-1] if records else None
    latest_failed = 0
    if latest:
        latest_failed = sum(1 for st in latest.get("counts", {}).values() if st == "failed")

    if not ordered:
        summary = "0 条规则，最近一次：空历史"
    elif latest_failed:
        summary = f"{len(ordered)} 条规则，最近一次有失败（{latest_failed} 条红）"
    else:
        summary = f"{len(ordered)} 条规则，最近一次全绿"

    return {
        "history": str(history_path),
        "records": len(records),
        "bad_lines": bad_lines,
        "window": window,
        "latest": (
            {"ts": latest.get("ts"), "commit": latest.get("commit")} if latest else None
        ),
        "rules": ordered,
        "zero_hit": zero_hit,
        "summary": summary,
    }


def render_text(report: dict) -> str:
    lines: list[str] = []
    latest = report["latest"]
    lines.append(f"规则命中率 —— {report['history']}")
    lines.append(
        f"记录 {report['records']} 条（损坏跳过 {report['bad_lines']} 行），"
        f"窗口 {report['window']} 次"
    )
    if latest:
        lines.append(f"最近一次：{latest['ts']}  commit {latest['commit']}")
    else:
        lines.append("最近一次：无记录")
    lines.append("")
    lines.append(report["summary"])

    red = [r["nodeid"] for r in report["rules"] if r["last"] == "failed"]
    if red:
        lines.append(f"最近一次红（{len(red)} 条）：")
        for nodeid in red:
            lines.append(f"  ! {nodeid}")
    lines.append("")

    if report["rules"]:
        header = f"{'最近':<8}{'近N次 通过/失败':>16}{'全历史失败':>11}  规则"
        lines.append(header)
        lines.append("-" * 64)
        for rule in report["rules"]:
            lines.append(
                f"{rule['last']:<8}{rule['pass']:>8}/{rule['fail']:<7}"
                f"{rule['fail_total']:>11}  {rule['nodeid']}"
            )
        lines.append("")

    zero_hit = report["zero_hit"]
    if zero_hit:
        lines.append(f"连续 0 命中（{len(zero_hit)} 条，全历史从未失败）：")
        for nodeid in zero_hit:
            lines.append(f"  - {nodeid}")
        lines.append("")
        lines.append(
            "复核方式：要么删掉（它保护的形状已不存在），要么补一条 test_reverse_check_detects_* 证明它会红。"
        )
    elif report["rules"]:
        lines.append("连续 0 命中：无（每条规则都至少红过一次）")

    return "\n".join(lines) + "\n"


# ── CLI ────────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="规则命中率：记录/汇总 tests/architecture 每次运行的结果。",
        epilog="rule hit-rate: record every gate run, report per-rule pass/fail and never-failed rules.",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--record", action="store_true", help="跑整套闸门并把结果追加进历史")
    mode.add_argument("--report", action="store_true", help="读历史出报告（默认行为）")
    parser.add_argument("--json", action="store_true", help="机读输出")
    parser.add_argument("--window", type=int, default=DEFAULT_WINDOW, help="窗口大小（默认 20）")
    parser.add_argument(
        "--history", type=Path, default=HISTORY, help="历史文件路径（默认 tests/architecture/gate_history.jsonl）"
    )
    parser.add_argument("--arch", type=Path, default=ARCH_DIR, help="架构测试目录（默认 T-CityLite.base/tests/architecture）")
    args = parser.parse_args(argv)

    history = args.history

    if args.record:
        if not args.arch.is_dir():
            print(f"找不到 pytest 目录：{args.arch}", file=sys.stderr)
            return EXIT_ENV

        output, code = run_architecture_suite(args.arch)
        results = parse_pytest_summary(output)
        if not results:
            print("pytest 输出里没有解析到任何用例结果，未记录。", file=sys.stderr)
            print(output[-2000:], file=sys.stderr)
            return EXIT_ENV

        record = build_record(results, current_commit())
        append_record(history, record)

        passed = sum(1 for st in record["counts"].values() if st == "passed")
        failed = sum(1 for st in record["counts"].values() if st == "failed")
        print(
            f"已记录 {len(record['counts'])} 条规则：{passed} passed / {failed} failed"
            f"（pytest 退出码 {code}）-> {history}"
        )
        print(f"ts={record['ts']} commit={record['commit']}")
        return EXIT_OK

    # 默认即 --report
    records, bad = load_history(history)
    report = build_report(records, args.window, bad, history)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=False))
    else:
        sys.stdout.write(render_text(report))
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
