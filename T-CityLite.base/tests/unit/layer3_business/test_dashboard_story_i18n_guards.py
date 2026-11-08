"""P1-3 批 18：tcity-dashboard / story-engine / production-freeze。

- `tcity-dashboard` 的车牌标记/取消/追踪器**本来就是**「在职警察」（`isOnDutyLeo`：`job.type == 'leo'`
  或 `job.name == 'police'` 且 `onduty == true`），只是闸门认不出这个 helper，本轮登记。
  真修的是参数：`plate:upper()` 遇到 nil / 数字会直接抛错打断事件线程，`reason` 也没有长度上限。
- `story:server:makeDecision` 的校验全在 `DecisionEngine.MakeChoice`（按 source 存 pending、
  quest/step/decision 三元组必须全等、带 expiresAt），本轮给它加 `return` 并登记 delegate 形状。
- `tcity:client:telemetry` 会**写库**（`agent_events`），原来事件名、payload 大小、频率全由客户端定：
  一个改过的客户端可以每帧写一条大 payload，把表写爆。现在三件都由服务端定（64 字 / 2KB / 60 秒 120 条）。
- `i18n:client:reportLanguage(lang)` 原来客户端传什么就写什么（表、4000 字字符串、随便造的 `'xx'`
  都进 `metadata.client_lang`），现在只认语言包里真实存在的 `zh` / `en`。
- `production:client:freezeDebug` 是**客户端**事件，却注册在 `server/main.lua` 里并被
  `TriggerClientEvent(..., -1)` 广播 —— 服务端注册的 handler 永远收不到广播，所以「生产模式关闭
  客户端 DrawText3D / PolyZone debug」从未生效；而那份服务端副本让任何客户端能覆盖**服务端**全局。
  现在处理器回到客户端脚本，服务端只留一条 `source ~= 0` 就拒绝的空实现。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _run(probe: str, resource_path: str) -> dict[str, str]:
    proc = subprocess.run(
        ["lua5.4", (FIXTURES / probe).as_posix(), (BASE / "resources" / resource_path).as_posix()],
        capture_output=True,
        text=True,
        timeout=90,
    )
    assert proc.returncode == 0, f"probe 失败：{proc.stderr} / {proc.stdout}"
    data: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        data.setdefault(key, value)
    assert "HANDLER_ERROR" not in data, f"handler 抛错：{data.get('HANDLER_ERROR')}"
    return data


# ══════════════════════════════════════════════════════════════════
# tcity-dashboard
# ══════════════════════════════════════════════════════════════════


def test_plate_actions_are_on_duty_police_only():
    data = _run("dashboard_probe.lua", "[system]/tcity-dashboard")
    assert data["FLAG_CIVILIAN_BLOCKED"] == "true", "路人能给别人的车牌打标记"
    assert data["FLAG_OFFDUTY_BLOCKED"] == "true", "下班警察也能打标记"
    assert data["FLAG_LEO_ALLOWED"] == "true", "在职警察打标记被拒（过度收紧）"
    assert data["UNFLAG_CIVILIAN_BLOCKED"] == "true", "路人能取消车牌标记"
    assert data["TRACKER_CIVILIAN_BLOCKED"] == "true", "路人能给别人装追踪器"


def test_plate_arguments_survive_bad_input():
    """`plate:upper()` 收到 nil / 数字会抛错打断事件线程（旧版实测两处都崩）。"""
    data = _run("dashboard_probe.lua", "[system]/tcity-dashboard")
    assert data["FLAG_BAD_PLATE_SAFE"] == "true", "flagPlate 收到 nil/数字会抛错"
    assert data["UNFLAG_BAD_PLATE_SAFE"] == "true", "unflagPlate 收到 nil 会抛错"


# ══════════════════════════════════════════════════════════════════
# story-engine
# ══════════════════════════════════════════════════════════════════


def test_telemetry_is_bounded_and_rate_limited():
    """这个 handler 会写 `agent_events`，三件预算必须由服务端定。"""
    data = _run("story_telemetry_probe.lua", "[custom]/story-engine")
    assert data["TELEMETRY_VALID_ACCEPTED"] == "true", "正常上报被拒（过度收紧）"
    assert data["TELEMETRY_BAD_ARGS_SAFE"] == "true", "坏事件名/坏 data 抛错"
    assert data["TELEMETRY_RATE_LIMITED"] == "true", "没有频率上限（旧版 200 条全写进去）"
    assert data["TELEMETRY_WINDOW_RESETS"] == "true", "窗口滑动后没恢复"


# ══════════════════════════════════════════════════════════════════
# production-freeze
# ══════════════════════════════════════════════════════════════════


def test_reported_language_must_be_a_real_locale():
    data = _run("i18n_lang_probe.lua", "[system]/production-freeze")
    assert data["LANG_ZH_ACCEPTED"] == "true", "zh 被拒（过度收紧）"
    assert data["LANG_EN_ACCEPTED"] == "true", "en 被拒（过度收紧）"
    assert data["LANG_BAD_VALUES_SAFE"] == "true", "表/超长串/数字抛错"
    assert data["LANG_BAD_VALUES_IGNORED"] == "true", "伪造语言代码写进了 metadata（旧版就是这样）"
    assert data["LANG_OFFLINE_SOURCE_SAFE"] == "true", "不存在的 source 会抛错"
