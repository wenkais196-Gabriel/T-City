"""R2 · `conditions.daily_limit` 必须真的生效（在此之前是死字段）。

`quest_db.lua` 里 `CheckDailyLimit` 与 `UpdateDailyLimit` 都写好了，但**两边都没有调用点** ——
配置里写着 `daily_limit = 8`，运行时同一条路线可以一天刷无限次，于是
`04-numbers.md` 的「$/h」只能算理论值。

判定在 `server/quest_daily_limit.lua`：内存优先（TriggerQuest 是同步函数，不能等异步查询），
未命中时查一次库并按「当天」缓存，完成时内存 +1、DB 异步累加。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lua_probe import run_probe  # noqa: E402

PROBE = "daily_limit_probe.lua"
RES = "[custom]/custom-quest"


def _data() -> dict[str, str]:
    return run_probe(PROBE, RES)


def test_limit_is_enforced():
    data = _data()
    assert data["UNDER_LIMIT_ALLOWED"] == "true", "没到上限就被拒（过度收紧）"
    assert data["AT_LIMIT_BLOCKED"] == "true", "到了上限还能接 —— daily_limit 还是没生效"


def test_completion_counts_once_and_lands_in_db():
    data = _data()
    assert data["DB_WRITES"] == "true", "完成两次没有写两次计数（跨重启后上限会失效）"


def test_scope_is_per_quest_and_per_player():
    data = _data()
    assert data["OTHER_QUEST_INDEPENDENT"] == "true", "刷一条任务把另一条也锁了（键里没带 questId）"
    assert data["OTHER_PLAYER_INDEPENDENT"] == "true", "一个玩家刷满后别的玩家也接不了（键里没带 citizenid）"


def test_counter_resets_with_the_period():
    data = _data()
    assert data["NEW_PERIOD_RESETS"] == "true", (
        "跨天后计数没归零 —— 昨天刷满的人今天永远接不了（周期没进缓存键）"
    )
    assert data["WEEKLY_PERIOD_IS_MONDAY"] == "true", "weekly 周期不是本周一（周期起点算错）"


def test_database_outage_fails_open_but_recovery_enforces():
    data = _data()
    assert data["DB_DOWN_FAILS_OPEN"] == "true", (
        "DB 抖动时把玩家全部拦住 —— 一次 ETIMEDOUT 会锁死所有人的任务"
    )
    assert data["DB_BACK_ENFORCES"] == "true", "DB 恢复后仍然放行（熔断没有复位）"


def test_missing_limit_means_unlimited():
    data = _data()
    assert data["ZERO_LIMIT_MEANS_UNLIMITED"] == "true", (
        "没写 daily_limit（或写 0）的模板被误伤 —— 既有 50+ 个模板都不能受限"
    )
