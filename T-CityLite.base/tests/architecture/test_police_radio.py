"""L0 无线电层（蓝图 §6.2）的闸门。

这一层是"往所有人耳朵里塞声音"，最容易出的三类事故：
* 没门控 —— 服主关不掉；
* 刷屏 —— 一次事件给一个人播十条；
* 越权 —— 发给平民，或者把坐标/citizenid 一起播出去。

文案本身是纯函数，行为在 golden（`police_radio` 10 checks）；这里钉服务端用法。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]  # 仓库根（worktree）
RES = REPO / "T-CityLite.base/resources/[custom]/custom-police"
RADIO = RES / "server/radio.lua"
TEXT = RES / "shared/radio_text.lua"
BACKUP = RES / "server/p2_system.lua"


def _read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def test_radio_is_gated_budgeted_and_officer_only() -> None:
    src = _read(RADIO)

    # 门控：一个 convar 关掉整层，默认开。
    assert "GetConvar('police_radio_voice', '1')" in src, "无线电层必须可被 convar 关闭"

    # 只发给在岗警察，且必须判 onduty（关掉 duty 就不该听到调度）。
    assert "job.name == 'police'" in src and "onduty == true" in src

    # 预算：单人 + 全局双重限流（缺一个就会在连点下变成复读机）。
    assert "PER_UNIT_GAP_MS" in src and "GLOBAL_GAP_MS" in src
    assert "lastToUnit" in src and "lastGlobalAt" in src

    # 走手机已有的 TTS 通道，不要自己造一条音频通道。
    assert "phone:client:systemSpeech" in src
    assert "GetResourceState('custom-phone')" in src, "手机没起来时要静默降级"

    # 诊断日志不许打正文（宪法 §7：遥测不落 PII）。
    assert "#text" in src, "日志只能记长度"
    assert "text = text" not in src.split("print(")[1][:200] if "print(" in src else True


def test_radio_text_never_carries_identity_or_coordinates() -> None:
    src = _read(TEXT)

    # 文案模板里不许出现坐标占位（vector3/%f 这类）与身份字段。
    for banned in ("citizenid", "vector3", "%f", "coords"):
        assert banned not in src.split("local TEMPLATES")[1], (
            "无线电文案里不许出现 " + banned
        )

    # 呼号优先用 metadata，且必须剥控制字符（玩家能改自己的 callsign）。
    assert "metadata.callsign" in src
    assert "gsub('%c', '')" in src

    # 单句上限，防止 TTS 念菜单。
    assert "MAX_TEXT = 160" in src


def test_backup_events_speak_through_the_radio() -> None:
    src = _read(BACKUP)

    # 派出 / 到场 / 撤离三个时刻都要有播报，而且都走同一个门面。
    assert src.count("radioSay(") >= 3, "派出/到场/撤离三处都要播报"
    assert "radioSay('dispatch'" in src
    assert "radioSay('onscene'" in src
    assert "radioSay('clear'" in src

    # 播报永远不是关键路径：模块缺失或抛错都不能带崩接警。
    assert "if not PoliceRadio or not callsign then return end" in src
    assert "pcall(PoliceRadio.Say" in src
