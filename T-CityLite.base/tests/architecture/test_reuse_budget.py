"""REUSE-01 — 重复实现的**棘轮**：只许变少，不许变多。

`reuse_scan` 报的是"同名函数被定义了几次"。这个数字本身不是错误（有些同名函数是
有意重复的），但它必须**可控**：要么合并，要么在预算里写明理由。

规则三条：
1. 任何名字的当前定义数 **不得高于** `reuse_budget.json` 里的预算（防止新增碎片）；
2. 预算里登记的名字如果实际值**更低**，测试失败并要求把预算降到实际值
   （否则棘轮只朝一个方向松动，永远不会真正收敛）；
3. 出现新的"≥4 次同名定义"却没登记预算 → 失败（逼一次显式决策）。

有意重复的例子：`DebugPrint` 每个资源有**自己的**调试开关与前缀，合并会改变语义，
所以登记为 intentional 并写明理由。`loadAnimDict` 语义完全一致，已合并到
`core-framework` 的 `shared/util.lua`，qb/standalone 下的残留属于"不迁上游"决策。

Run: ``python3 -m pytest -q tests/architecture/test_reuse_budget.py``
"""

from __future__ import annotations

import importlib.util
import json
import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
REPO = BASE.parent
TOOL = REPO / "tools" / "dev" / "reuse_scan.py"
BUDGET = Path(__file__).with_name("reuse_budget.json")
MIN_COUNT = 4   # ≥4 才纳入预算；3 次属于观察区，报告可见但不设闸


def load_tool():
    spec = importlib.util.spec_from_file_location("reuse_scan", TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)          # 只加载，不执行 main()
    return module


def current_counts() -> dict[str, int]:
    tool = load_tool()
    found = tool.definitions(tool.RESOURCES)
    return {name: len(files) for name, files in found.items() if len(files) >= MIN_COUNT}


def load_budget() -> dict:
    return json.loads(BUDGET.read_text(encoding="utf-8"))


def violations(counts: dict[str, int], budgets: dict[str, dict]) -> list[str]:
    problems: list[str] = []
    for name, count in sorted(counts.items()):
        entry = budgets.get(name)
        if entry is None:
            problems.append(f"`{name}` 有 {count} 份实现但没登记预算（合并，或在 reuse_budget.json 里写明理由）")
            continue
        if count > entry["max"]:
            problems.append(f"`{name}` 现在 {count} 份 > 预算 {entry['max']}：碎片变多了")
        elif count < entry["max"]:
            problems.append(f"`{name}` 现在 {count} 份 < 预算 {entry['max']}：把预算降到 {count}（棘轮只许往下走）")
    for name in budgets:
        if name not in counts:
            problems.append(f"`{name}` 已不再重复（<{MIN_COUNT} 份），请删掉这条预算条目")
    return problems


def test_no_new_duplication_and_budget_is_tight():
    problems = violations(current_counts(), load_budget()["budgets"])
    assert not problems, "重复实现预算不成立：\n" + "\n".join(problems)


def test_budget_entries_carry_a_reason():
    budgets = load_budget()["budgets"]
    missing = [name for name, entry in budgets.items() if not entry.get("reason", "").strip()]
    assert not missing, "这些预算没写理由（没理由的豁免就是永久豁免）：" + ", ".join(missing)


def test_rule_fires_on_bad_shapes():
    budgets = {"a": {"max": 3, "reason": "x"}}
    assert violations({"a": 5}, budgets)          # 超出
    assert violations({"a": 2}, budgets)          # 低于预算（棘轮要收紧）
    assert violations({"b": 4}, budgets)          # 未登记的新重复
    assert violations({}, {"a": {"max": 3, "reason": "x"}})   # 条目已失效
    assert not violations({"a": 3}, budgets)


# ---------------------------------------------------------------------------
# 共享实现的契约：导出必须在客户端侧注册，调用方必须"调用时解析"
# ---------------------------------------------------------------------------

CORE_UTIL = BASE / "resources" / "[standalone]" / "core-framework" / "shared" / "util.lua"
MANIFEST = BASE / "resources" / "[standalone]" / "core-framework" / "fxmanifest.lua"


def test_shared_export_is_registered_for_the_client_only():
    src = CORE_UTIL.read_text(encoding="utf-8")
    assert "exports('LoadAnimDict'" in src, "共享实现必须注册导出"
    # 客户端原生：服务端调用 RequestAnimDict 会直接报错，所以必须包在守卫里
    assert "IsDuplicityVersion()" in src, "导出必须在 \'not IsDuplicityVersion()\' 守卫内"
    guard = src.index("IsDuplicityVersion()")
    assert guard < src.index("exports('LoadAnimDict'"), "守卫必须在导出之前"
    # 原实现是无上限 while，字典缺失会卡死线程；共享版必须有超时
    assert "deadline" in src and "GetGameTimer()" in src, "共享实现必须有超时上限"


def test_shared_util_is_listed_in_the_manifest():
    manifest = MANIFEST.read_text(encoding="utf-8")
    assert "shared/util.lua" in manifest, "没进 fxmanifest 的脚本不会被执行"


def test_callers_resolve_the_export_at_call_time():
    """迁移后的调用方必须用 `function(dict) return exports[...]` 惰性包装。

    直接 `local f = exports['core-framework']:LoadAnimDict` 会在**加载期**解析，
    资源启动顺序一旦变化就报 No such export——所以这条要钉住。
    """
    migrated = [
        BASE / "resources" / "[custom]" / "custom-police" / "client" / "job.lua",
        BASE / "resources" / "[custom]" / "custom-police" / "client" / "interactions.lua",
        BASE / "resources" / "[custom]" / "custom-vehicles" / "client" / "main.lua",
        BASE / "resources" / "[custom]" / "custom-vehicles" / "client" / "vehiclepush.lua",
        BASE / "resources" / "[custom]" / "custom-agent-client" / "client" / "main.lua",
    ]
    problems = []
    for path in migrated:
        src = path.read_text(encoding="utf-8")
        if "exports['core-framework']:LoadAnimDict" not in src:
            problems.append(f"{path.relative_to(BASE)}: 没走共享实现")
        if re.search(r"local\s+loadAnimDict\s*=\s*exports", src):
            problems.append(f"{path.relative_to(BASE)}: 加载期解析导出（应惰性包装）")
        if "HasAnimDictLoaded" in src and "local function loadAnimDict" in src:
            problems.append(f"{path.relative_to(BASE)}: 还留着自己的循环实现")
    assert not problems, "\n".join(problems)


CONVAR_CALLERS = [
    "resources/[custom]/custom-security/config.lua",
    "resources/[custom]/custom-economy/config.lua",
    "resources/[custom]/custom-main/config/config.lua",
    "resources/[custom]/custom-crime/server/crime.lua",
    "resources/[custom]/custom-director/server/main.lua",
    "resources/[custom]/custom-director/server/director.lua",
    "resources/[custom]/custom-director/server/live_api.lua",
    "resources/[custom]/custom-director/server/live_events.lua",
    "resources/[custom]/custom-agent-client/server/main.lua",
]


def test_convar_helpers_come_from_the_shared_library():
    problems = []
    for rel in CONVAR_CALLERS:
        src = (BASE / rel).read_text(encoding="utf-8")
        if "exports['core-framework']:Convar" not in src:
            problems.append(f"{rel}: 没走共享的 Convar* 实现")
        # 还留着自己解析 GetConvar 的私货就说明没迁干净
        if "GetConvar(name" in src or "GetConvar(convar" in src:
            problems.append(f"{rel}: 还留着自己解析 convar 的代码")
    assert not problems, "\n".join(problems)


def test_load_time_callers_declare_the_core_dependency():
    """在 `config.lua` 顶层（加载期）就调用核心导出的资源，必须声明 dependencies。

    这是 convar 族和 loadAnimDict 的关键差别：后者只在玩家触发时调用，前者在资源
    加载那一刻就要值。没有 dependencies 兜底，启动顺序一变就是 `No such export`
    ——而且是整个资源加载失败，不是动画不播。
    """
    problems = []
    for rel in CONVAR_CALLERS:
        path = BASE / rel
        # 找到所属资源根（resources/<bracket>/<res>）
        parts = path.parts
        idx = parts.index("resources")
        root = Path(*parts[: idx + 3])
        manifest = root / "fxmanifest.lua"
        text = manifest.read_text(encoding="utf-8")
        if idx + 2 >= len(parts):
            continue
        if "core-framework" not in text:
            problems.append(f"{root.name}: 没在 fxmanifest 的 dependencies 里声明 core-framework")
    assert not problems, "\n".join(problems)

