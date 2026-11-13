"""R1 · P1：多站路线校验器 `validate_route_stop`。

garbage / bus 共用一份校验器。它要回答的问题是「这一站现在该不该算完成」，五条判据：

1. **顺序**：站号必须等于会话里记的下一站（线性状态机下这是唯一可行的顺序约束）；
2. **职业**：`stepData.job` 与玩家当前职业一致；
3. **在岗**：`require_duty` 时还要求 `onduty`；
4. **距离**：玩家与服务端配置的坐标距离 ≤ `radius`；
5. **载具**：`require_vehicle` 时必须在车里。

写会话的时机在**全部判据通过之后**——先落账再校验会让「被拒的那一次」也推进进度，
玩家跳一站就能把后面的站全部顶掉。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lua_probe import run_probe  # noqa: E402

PROBE = "route_stop_probe.lua"
RES = "[custom]/custom-quest"


def _data() -> dict[str, str]:
    return run_probe(PROBE, RES)


def test_validator_is_registered():
    data = _data()
    assert data["REGISTERED"] == "true", "validate_route_stop 没有注册（R1 的两个职业都用不了）"


def test_happy_path_and_monotonic_session():
    data = _data()
    assert data["FIRST_STOP_OK"] == "true", "第一站在正确位置也没通过（过度收紧）"
    assert data["SECOND_STOP_OK"] == "true", "第二站推进失败"
    assert data["REPLAY_STOP_BLOCKED"] == "true", "重复提交已完成的站还能通过（可以刷结算）"
    assert data["SKIP_STOP_BLOCKED"] == "true", "跳站能通过（顺序约束形同虚设）"


def test_job_duty_distance_and_vehicle_are_enforced():
    data = _data()
    assert data["FAR_BLOCKED"] == "true", "距离外提交能通过（客户端可以伪造到达）"
    assert data["WRONG_JOB_BLOCKED"] == "true", "职业不符也能推进"
    assert data["OFF_DUTY_BLOCKED"] == "true", "不在岗也能推进"
    assert data["NO_VEHICLE_BLOCKED"] == "true", "要求载具时徒步也能完成"
    assert data["VEHICLE_OK"] == "true", "要求载具且在车里却被拒（过度收紧）"


def test_rejections_do_not_advance_the_session():
    """被拒的那几次不许推进进度，否则拒一次就白送一站。"""
    data = _data()
    assert data["SESSION_SURVIVES_REJECTS"] == "true", (
        "职业/在岗被拒之后，原本该过的第 3 站也过不去了 —— 说明会话在校验前就被推进"
    )


def test_bad_input_is_safe_and_does_not_advance():
    data = _data()
    assert data["NO_COORDS_SAFE"] == "true", "没有 coords 的步骤抛错或通过了"
    assert data["BAD_INDEX_SAFE"] == "true", "站号 0 / 非数字没被拒"
    assert data["NO_PLAYER_SAFE"] == "true", "玩家不存在时抛错"
    assert data["NIL_STEP_SAFE"] == "true", "stepData 为 nil 时抛错"


def test_sessions_are_scoped_per_quest():
    data = _data()
    assert data["SESSION_IS_PER_QUEST"] == "true", (
        "另一个任务的第 1 站被同一会话卡住（会话键没带 questId），garbage 和 bus 会互相顶掉"
    )


def test_stale_session_is_reset_on_quest_start():
    """放弃/失败/掉线后会话停在中间站，重新接单必须从第 1 站开始，不能把任务锁死。"""
    data = _data()
    assert data["STALE_SESSION_BLOCKS_RESTART"] == "true", "陈旧会话没有拦住第 1 站（顺序约束失效）"
    assert data["RESET_SESSION_ALLOWS_RESTART"] == "true", (
        "ResetSession 之后第 1 站仍然过不去 —— 玩家会永远卡在这个任务上"
    )


def test_cold_start_adopts_the_current_step_index():
    """资源/服务器重启后会话丢了，但任务还在 DB 的某一站 —— 那一站必须能过，不能锁死。"""
    data = _data()
    assert data["COLD_START_ADOPTS_INDEX"] == "true", (
        "会话丢失后第 7 站被拒：重启会让所有多站任务卡死（CC 在验收里抓到的死锁）"
    )
    assert data["COLD_START_THEN_MONOTONIC"] == "true", (
        "冷启动采纳站号之后不再单调，同一站可以重复提交"
    )
