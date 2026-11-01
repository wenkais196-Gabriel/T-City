"""net event 基线生成器（P1-3）。

把"全仓服务端 net event 的现状"固化成一个可 diff 的文件：
每条资源的事件数、已鉴权 / 已登记 / 未登记，以及未登记事件的名字清单。
闸门 `test_net_event_inventory.py` 用它做两件事：

1. **棘轮**：现在的未登记集合必须和基线**逐条相等** —— 新冒出来一个未鉴权的
   net event，闸门立刻红，必须在同一个 PR 里要么加鉴权、要么登记进 allowlist，
   然后重新生成基线（diff 里能看见数字变化）；
2. **债要有主**：每个还有未登记事件的资源，必须在 `debt` 里有一条 owner + expires，
   过期即红。

重新生成（只在你有意改变现状时跑）：

    python tests/architecture/net_event_baseline.py --write
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from datetime import date
from pathlib import Path

from net_event_scan import auth_tokens, non_literal_registrations, scan_repo

BASE = Path(__file__).resolve().parents[2]          # T-CityLite.base/
RESOURCES = BASE / "resources"
ARCH = Path(__file__).resolve().parent
BASELINE = ARCH / "net_events_baseline.json"
ALLOWLIST = ARCH / "net_events_allowlist.json"

#: 已 100% 覆盖、由 `test_net_event_auth.py` 硬性强制的资源
ENFORCED = ("qb-core",)

#: 债务到期：一次性给三个月；到期必须重新评估（要么修掉，要么续期并说明）
DEFAULT_EXPIRES = "2027-03-31"

BATCHES = {
    "engine": ("qb-core",),
    "custom": ("[custom]",),
    "qb": ("[qb]",),
    "other": ("[system]", "[standalone]", "[voice]", "[cfx-default]"),
}


def _allowlist_names() -> set[str]:
    data = json.loads(ALLOWLIST.read_text(encoding="utf-8"))
    return {entry["name"] for entry in data.get("entries", [])}


def ensured_resources() -> set[str]:
    """启动集：configs/**/*.cfg 与 server.cfg 里的 ensure/start。"""
    import re
    names: set[str] = set()
    base = RESOURCES.parent
    files = list((base / "configs").rglob("*.cfg")) + [base / "server.cfg"]
    for path in files:
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            match = re.match(r"^\s*(?:ensure|start)\s+(\S+)", line)
            if match:
                names.add(match.group(1))
    return names


def _batch_of(group: str) -> str:
    for batch, prefixes in BATCHES.items():
        if group in prefixes:
            return batch
    return "other"


def build(resources: Path | None = None) -> dict:
    resources = resources or RESOURCES
    events, problems = scan_repo(resources)
    registered = _allowlist_names()

    per_resource: dict[str, dict] = {}
    unguarded: dict[str, list[str]] = defaultdict(list)
    batches: dict[str, dict] = {
        name: {"events": 0, "guarded": 0, "allowlisted": 0, "unguarded": 0} for name in BATCHES
    }

    for event in events:
        rel = event.path.relative_to(resources)
        group = rel.parts[0]
        batch = "engine" if event.resource in ENFORCED else _batch_of(group)
        stats = per_resource.setdefault(
            event.resource,
            {"batch": batch, "group": group, "events": 0, "guarded": 0, "allowlisted": 0, "unguarded": 0},
        )
        stats["events"] += 1
        batches[batch]["events"] += 1

        if auth_tokens(event.body):
            stats["guarded"] += 1
            batches[batch]["guarded"] += 1
        elif event.name in registered:
            stats["allowlisted"] += 1
            batches[batch]["allowlisted"] += 1
        else:
            stats["unguarded"] += 1
            batches[batch]["unguarded"] += 1
            unguarded[event.resource].append(event.name)

    debt = [
        {
            "resource": resource,
            "batch": per_resource[resource]["batch"],
            "unguarded": len(names),
            "owner": resource,
            "expires": DEFAULT_EXPIRES,
            "reason": "存量未鉴权的服务端 net event，按资源整体登记；修复后本条目与数字同时下降",
        }
        for resource, names in sorted(unguarded.items())
    ]

    ensured = ensured_resources()
    for resource, stats in per_resource.items():
        stats["started"] = resource in ensured

    return {
        "$comment": "P1-3 net event 基线。由 tests/architecture/net_event_baseline.py --write 生成，"
                    "手改会被 test_net_event_inventory.py 判红。",
        "version": 1,
        "rule": "P1-3",
        "measured_at": date.today().isoformat(),
        "scope": "resources/** 服务端脚本（排除 client/ 目录与 cl_*/client*.lua）",
        "enforced": list(ENFORCED),
        "batches": batches,
        "resources": dict(sorted(per_resource.items())),
        "unguarded": {resource: sorted(names) for resource, names in sorted(unguarded.items())},
        "debt": debt,
        "non_literal": sorted(non_literal_registrations(resources)),
        "unparsed": sorted(problems_where(problems, resources)),
    }


def problems_where(problems: list[str], resources: Path | None = None) -> list[str]:
    """解析失败的 handler —— 也是债（扫描器看不见的那部分）。

    路径同样要相对化：基线在 Windows 与 CI 的 Linux 上必须逐字节一致。
    """
    out = []
    for problem in problems:
        where = problem.split(" ", 1)[0]
        if resources:
            try:
                where = Path(where).relative_to(resources).as_posix()
            except ValueError:
                pass
        out.append(where)
    return out


def load() -> dict:
    return json.loads(BASELINE.read_text(encoding="utf-8"))


def write() -> dict:
    data = build()
    BASELINE.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return data


def main(argv: list[str]) -> int:
    if "--write" not in argv:
        data = build()
        print(json.dumps({
            "events": sum(batch["events"] for batch in data["batches"].values()),
            "batches": data["batches"],
            "resources_with_debt": len(data["debt"]),
        }, ensure_ascii=False, indent=2))
        return 0
    data = write()
    print(f"wrote {BASELINE} ({sum(b['events'] for b in data['batches'].values())} events, "
          f"{len(data['debt'])} resources with debt)")
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI
    sys.exit(main(sys.argv[1:]))
