"""QA-02 — 手机任务 App 的注册契约与参数清洗。

任务 App 是玩家点得到的第一个"内容入口"，它出错的方式很难看：把非法 quest_id 透传给
custom-quest（客户端可控输入直通业务层），或者在导出不可用时把手机打成空白。

所以这里真跑 `custom-quest` 的 app 文件（lua5.4 + 桩），断言：
* 注册的是 quests、对所有职业可见、四个处理器都在；
* 导出正常时 list 返回 rows/count；导出不可用时返回结构化错误而不是抛异常；
* 非法 id **不会**下沉到 custom-quest（调用计数为 0）——清洗必须在边界内完成；
* 被拒时把下游给玩家的原因带回来，而不是压成一句 rejected。
"""
from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
APP = BASE / "resources/[custom]/custom-phone/server/apps/quests.lua"
HARNESS = BASE / "tests/fixtures/quest_app_harness.lua"


def run() -> dict[str, str]:
    assert APP.is_file(), f"缺少手机 App: {APP}"
    # Lua 里这个路径是字面量：Windows 的反斜杠会被当成非法转义（stdin:40），
    # 所以统一换成 POSIX 分隔符（lua5.4 在 Windows 上同样接受）。
    script = HARNESS.read_text(encoding="utf-8").replace("__APP__", str(APP).replace("\\", "/"))
    proc = subprocess.run(["lua5.4", "-"], input=script, capture_output=True, text=True, timeout=30)
    if proc.returncode != 0:
        raise AssertionError(f"Lua 执行失败:\n{proc.stdout}\n{proc.stderr}")
    out: dict[str, str] = {}
    for line in proc.stdout.strip().splitlines():
        key, _, value = line.partition("|")
        out[key] = value
    return out


def test_registration_is_visible_to_everyone_and_exposes_both_faces():
    got = run()
    assert got["registered"] == "true", "app 没有被注册（PhoneApps.Register 没调用）"
    assert got["id"] == "quests"
    assert got["audience_is_open"] == "true", (
        "平民线也要能看任务，audience 不能锁死职业（锁了就只有警察能看到）"
    )
    assert got["has_queries"] == "true", "缺少 list/active/detail 查询"
    assert got["has_actions"] == "true", "缺少 accept/abandon 动作"


def test_queries_degrade_instead_of_throwing():
    got = run()
    assert got["list_count"] == "2", f"正常时 list 要返回条数: {got.get('list_count')}"
    assert got["list_rows_len"] == "2"
    assert got["list_unavailable_error"] == "quest_unavailable", (
        "custom-quest 不在时要返回结构化错误，而不是让 pcall 打掉整个请求"
    )
    assert got["list_unavailable_count"] == "0"


def test_bad_quest_ids_are_rejected_at_the_boundary():
    got = run()
    assert got["detail_bad_id_error"] == "bad_id"
    assert got["detail_bad_id_no_downstream_call"] == "true", (
        "非法 id 不许下沉到 custom-quest（客户端可控输入直通业务层就是越界）"
    )
    assert got["accept_long_id_error"] == "bad_id"
    assert got["accept_long_id_no_downstream_call"] == "true", (
        "超长 id 必须在清洗层被拦，不能指望下游兜住"
    )


def test_accept_reports_the_real_reason_and_abandon_works():
    got = run()
    assert got["accept_ok"] == "true"
    assert got["accept_echoes_id"] == "q_a", "成功后要把 quest_id 带回去给 UI 刷新"
    assert got["accept_rejected_ok"] == "false"
    assert got["accept_rejected_error"] == "rejected"
    assert "cooldown" in got["accept_rejected_detail"], (
        f"被拒原因要原样带给玩家（现在是 {got.get('accept_rejected_detail')!r}）"
    )
    assert got["abandon_ok"] == "true"
