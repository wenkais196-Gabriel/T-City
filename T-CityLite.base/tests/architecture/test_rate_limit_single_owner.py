"""RATE-01 — 限流只允许一个实现（安全原语不能各写一份）。

背景：仓库里曾有 7 份限流，语义分三类（每键冷却 / 固定窗口计数 / 令牌桶+突发）。
其中 5 份已收敛到 `core-framework/server/rate_limit.lua`；剩下两处是**刻意的**：

* `tcity-atmosphere` 的计数存在每个玩家的 state 结构里（`requestCount` /
  `requestWindowStart`），和它自己的场景状态机绑在一起，挪出来反而要重构状态机；
* `custom-phone` 的 `server/core/rate_limit.lua` 是带 diag 钩子的令牌桶，
  有独立单测，语义与"冷却/窗口"不同。

所以规则不是"全仓只许有一个函数"，而是：**新的限流逻辑不许再长出来**，且已知的
例外必须显式登记（下面两张表），登记项如果消失也要报出来（否则例外会永远留着）。

Run: ``python3 -m pytest -q tests/architecture/test_rate_limit_single_owner.py``
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
RESOURCES = BASE / "resources"
OWNER = RESOURCES / "[standalone]" / "core-framework" / "server" / "rate_limit.lua"

# 允许保留自己实现的文件（必须写理由）
# 值 = (理由, 该文件自己那份实现的识别痕迹)。痕迹用于判断例外是否已失效：
# 合并掉之后痕迹会消失，这条例外就必须从表里删掉，否则例外会永远留着。
EXCEPTIONS = {
    RESOURCES / "[system]" / "tcity-atmosphere" / "server" / "atmosphere_service.lua":
        ("限流计数是每玩家 state（requestCount/requestWindowStart），与场景状态机耦合",
         "requestWindowStart"),
    RESOURCES / "[custom]" / "custom-phone" / "server" / "core" / "rate_limit.lua":
        ("带 diag 钩子的令牌桶（突发预算），语义不同于冷却/窗口，且有独立单测",
         "buckets"),
}

# 已经迁到 owner、必须提到它的调用方
CALLERS = [
    RESOURCES / "[standalone]" / "core-framework" / "services" / "notify_service.lua",
    RESOURCES / "[system]" / "tcity-dashboard" / "server" / "police_api.lua",
    RESOURCES / "[custom]" / "custom-vehicles" / "server" / "main.lua",
    RESOURCES / "[custom]" / "custom-security" / "server" / "security.lua",
    RESOURCES / "[custom]" / "custom-main" / "server" / "security.lua",
    RESOURCES / "[custom]" / "custom-vehicles" / "server" / "dashboard_api.lua",
]

# 自建限流表/循环的典型痕迹 —— 出现即视为"又写了一份限流"
IMPL_MARKERS = re.compile(
    r"\bUserCooldowns\b|\bopCooldowns\b|\brateLimits\s*\[\s*src\s*\]|\brateLimiter\s*=\s*\{"
    r"|\brequestWindowStart\b|\bbuckets\s*=\s*\{"
)


def strip_comments(text: str) -> str:
    return re.sub(r"--(?=\[\[).*?\]\]|--[^\n]*", "", text, flags=re.DOTALL)


def label(path: Path) -> str:
    try:
        return str(path.relative_to(BASE))
    except ValueError:
        return path.name


def rogue_implementations(files: list[Path], owner: Path, exceptions: dict[Path, tuple[str, str]]) -> list[str]:
    hits = []
    for path in files:
        if path == owner or path in exceptions:
            continue
        try:
            text = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
        except OSError:
            continue
        if IMPL_MARKERS.search(text):
            hits.append(label(path))
    return sorted(hits)


def test_owner_exists_and_exposes_both_shapes():
    text = OWNER.read_text(encoding="utf-8")
    for name in ("RateLimit.Cooldown", "RateLimit.Window", "RateLimit.Reset", "RateLimit.Sweep"):
        assert f"function {name}" in text, f"owner 缺 {name}"
    for export in ("RateLimitCooldown", "RateLimitWindow", "RateLimitReset"):
        assert f"exports('{export}'" in text, f"owner 缺导出 {export}"
    # 时间源必须可注入（否则只能靠 sleep 测）
    assert "now = now or" in text, "owner 的时间参数必须可注入，便于单测"


def test_no_new_rate_limiter_grows():
    bad = rogue_implementations(sorted(RESOURCES.rglob("*.lua")), OWNER, EXCEPTIONS)
    assert not bad, (
        "这些文件又写了一份限流实现，请改用 exports['core-framework']:RateLimitCooldown/Window：\n  "
        + "\n  ".join(bad))


def test_migrated_callers_use_the_owner():
    problems = []
    for path in CALLERS:
        assert path.is_file(), f"缺少 {label(path)}"
        text = path.read_text(encoding="utf-8")
        if "RateLimitCooldown" not in text and "RateLimit.Window" not in text:
            problems.append(label(path))
    assert not problems, "这些调用方没走限流 owner：" + ", ".join(problems)


def test_exceptions_are_still_needed():
    """例外文件一旦自己不再实现限流，就该从表里删掉——否则例外会永远留着。"""
    stale = [
        label(p) for p, (_, marker) in EXCEPTIONS.items()
        if marker not in strip_comments(p.read_text(encoding="utf-8"))
    ]
    assert not stale, "这些例外已经不需要了（它自己那份实现已被合并），请从 EXCEPTIONS 删除：" + ", ".join(stale)


def test_every_exception_has_a_reason():
    missing = [label(p) for p, (reason, marker) in EXCEPTIONS.items() if not reason.strip() or not marker]
    assert not missing, "例外必须写理由：" + ", ".join(missing)


# ---------------------------------------------------------------------------
# 反向校验
# ---------------------------------------------------------------------------

def test_rules_fire_on_bad_shapes(tmp_path: Path):
    rogue = tmp_path / "rogue.lua"
    rogue.write_text("local UserCooldowns = {}\n", encoding="utf-8")
    commented = tmp_path / "commented.lua"
    commented.write_text("-- 以前这里有 local UserCooldowns = {}\n", encoding="utf-8")
    clean = tmp_path / "clean.lua"
    clean.write_text("local ok = exports['core-framework']:RateLimitCooldown(key, 1000)\n", encoding="utf-8")

    assert rogue_implementations([rogue], OWNER, {}) == ["rogue.lua"]
    assert rogue_implementations([commented], OWNER, {}) == [], "注释里的旧实现不该误报"
    assert rogue_implementations([clean], OWNER, {}) == []
    # 登记的例外不算违规
    assert rogue_implementations([rogue], OWNER, {rogue: ("理由", "UserCooldowns")}) == []
