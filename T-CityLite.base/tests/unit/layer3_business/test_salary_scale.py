"""R2 · 薪资抑制：`PaycheckInterval` 发的是 `QBShared.Jobs[..].grades[..].payment`。

我们只压这张共享表（不改 qb-core 一行），让它从「$60–1,200/小时的白拿收入」降到
「$150–300/小时」，干活才成为主要收入。

四条不变量，任何一条破了都是经济事故：

1. **安全默认**：没配 convar 时（1.0）工资一分不动；
2. **幂等**：`restart core_economy` 不能把工资越压越低；
3. **从原始值重算**：改 convar 后按原始 payment 重算，而不是在当前值上再乘一次；
4. **单调性**：缩放+封顶后，高等级不许比低等级拿得少。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lua_probe import run_probe  # noqa: E402

PROBE = "salary_scale_probe.lua"
RES = "[system]/core_economy"


def _data() -> dict[str, str]:
    return run_probe(PROBE, RES)


def test_module_registers_its_export():
    data = _data()
    assert data["EXPORTED"] == "true", "ApplySalaryScale 没有导出（运维无法手动重算）"


def test_default_scale_changes_nothing():
    data = _data()
    assert data["DEFAULT_SCALE_NOOP"] == "true", (
        "convar 为默认 1.0 时工资被改了 —— 安全默认失效，任何服务器升级都会动经济"
    )


def test_scale_and_cap_are_applied():
    data = _data()
    assert data["SCALED_G1"] == "true", "40 × 0.35 应为 14（缩放没生效或取整错了）"
    assert data["SCALED_G2_CAPPED"] == "true", "80 × 0.35 应为 28（不该触顶）"
    assert data["CAPPED_P1"] == "true", "200 × 0.35 = 70 应被封顶到 50"
    assert data["JOB_LEVEL_SCALED"] == "true", "写在 job 层的 payment（PaycheckInterval 的兜底分支）没被缩放"
    assert data["REPORT_COUNTS"] == "true", "回报里的职业/等级计数不对（运维靠它判断有没有扫到表）"


def test_reapplying_is_idempotent():
    data = _data()
    assert data["IDEMPOTENT"] == "true", (
        "第二次应用把工资又压了一次 —— restart core_economy 会让工资螺旋下降"
    )


def test_rescale_always_starts_from_the_original_value():
    data = _data()
    assert data["RESCALE_FROM_ORIGINAL"] == "true", (
        "改 convar 后是在上一次结果上再乘（80→28→14），而不是从原始值算（80→40）"
    )
    assert data["CAP_OFF_RESTORES_RANGE"] == "true", "取消封顶没有恢复原始区间（cap=0 应当不封顶）"


def test_salary_ordering_survives_compression():
    data = _data()
    assert data["MONOTONIC"] == "true", "压缩后高等级拿得比低等级少（职业晋升失去意义）"


def test_invalid_config_falls_back_to_safe_default():
    data = _data()
    assert data["INVALID_SCALE_FALLBACK"] == "true", (
        "负的 scale / cap 没有被拒绝 —— 会把工资算成负数或 0"
    )
    assert data["RESTORED_BY_SCALE_1"] == "true", "把 scale 调回 1.0 无法还原原始工资（不可回滚）"
