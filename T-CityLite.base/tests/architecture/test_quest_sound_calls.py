"""热狗线音效闸门（B）：只用 interact-sound 的现有素材，且只在明确的受众上播。

扫描 `[custom]/custom-quest` 里的音效调用，三条硬规则：

1. 文件名必须能在 `[standalone]/interact-sound/client/html/sounds/<name>.ogg` 找到；
2. 音量必须是数字常量，且落在 `(0, 0.5]`（叠音/刺耳的来源通常是"顺手拉满"）；
3. 不许新增 `TriggerClientEvent(..., -1, ...)` 全服广播点（`broadcast_sites` 预算 143/143）。

扫描器只认代码：`lua_source.blank_noise` 先把注释与字符串抹成空白（长度/行号不变），
所以注释或文案里的示例调用不会被当成真调用。下面三条变异用例分别把"未知文件 /
超音量 / -1 广播"喂给同一个判定函数，证明闸门不是永远绿。
"""

from __future__ import annotations

import re
from pathlib import Path

import lua_source

BASE = Path(__file__).resolve().parents[2]
CUSTOM_QUEST = BASE / "resources" / "[custom]" / "custom-quest"
SOUNDS = (BASE / "resources" / "[standalone]" / "interact-sound"
          / "client" / "html" / "sounds")
CLIENT = CUSTOM_QUEST / "client" / "quest_hotdog_vendor_client.lua"

WORLD_EVENT = "InteractSound_SV:PlayWithinDistance"
ONE_EVENT = "InteractSound_CL:PlayOnOne"
MAX_VOLUME = 0.5

#: 本片只允许这四个调用点（顾客上门 + 三处收银）。新增声音要连同测试一起改。
EXPECTED = sorted([
    ("world", "doorbell", 0.3, 25.0),
    ("one", "Shop", 0.35, None),
    ("one", "Shop", 0.3, None),
    ("one", "Shop", 0.25, None),
])

_CALL = re.compile(r"\b(TriggerServerEvent|TriggerClientEvent)\s*\(")
_QUOTED = re.compile(r"(['\"])(.*?)\1", re.S)
_NUMBER = re.compile(r"^[0-9]+(?:\.[0-9]+)?$")


def _literal(raw: str) -> str | None:
    match = _QUOTED.fullmatch(raw.strip())
    return match.group(2) if match else None


def _scan_source(source: str, rel: str = "<probe>") -> tuple[list[dict], list[dict]]:
    """返回 `(音效调用点, -1 广播点)`；注释/字符串里的示例不算。"""
    code = lua_source.blank_noise(source)                      # 注释 + 字符串 → 空白
    text = lua_source.blank_noise(source, keep_strings=True)   # 注释 → 空白，字符串保留
    sounds: list[dict] = []
    broadcasts: list[dict] = []

    for match in _CALL.finditer(code):
        function = match.group(1)
        open_index = match.end() - 1
        arguments = lua_source.argument_spans(code, open_index)
        raw = [text[slice(*span)].strip() for span in arguments]
        plain = [code[slice(*span)].strip() for span in arguments]
        line = lua_source.line_of(code, match.start())

        if function == "TriggerClientEvent" and len(plain) >= 2:
            if re.sub(r"\s+", "", plain[1]) == "-1":
                broadcasts.append({"rel": rel, "line": line})

        event = _literal(raw[0]) if raw else None
        if function == "TriggerServerEvent" and event == WORLD_EVENT and len(raw) >= 4:
            sounds.append({
                "kind": "world", "file": _literal(raw[2]), "raw_file": raw[2],
                "volume": raw[3], "distance": raw[1], "rel": rel, "line": line,
            })
        elif function == "TriggerClientEvent" and event == ONE_EVENT and len(raw) >= 4:
            sounds.append({
                "kind": "one", "file": _literal(raw[2]), "raw_file": raw[2],
                "volume": raw[3], "distance": None, "rel": rel, "line": line,
            })
    return sounds, broadcasts


def _scan_repo() -> tuple[list[dict], list[dict]]:
    sounds: list[dict] = []
    broadcasts: list[dict] = []
    for path in sorted(CUSTOM_QUEST.rglob("*.lua")):
        found, global_calls = _scan_source(
            path.read_text(encoding="utf-8", errors="ignore"),
            path.relative_to(BASE).as_posix())
        sounds.extend(found)
        broadcasts.extend(global_calls)
    return sounds, broadcasts


def _site_key(site: dict) -> tuple:
    volume = float(site["volume"]) if _NUMBER.fullmatch(site["volume"]) else site["volume"]
    distance = (
        float(site["distance"]) if site["kind"] == "world" and _NUMBER.fullmatch(site["distance"])
        else None
    )
    return (site["kind"], site["file"], volume, distance)


def _problems(sounds: list[dict], broadcasts: list[dict]) -> list[str]:
    problems: list[str] = []
    for site in broadcasts:
        problems.append(
            f"{site['rel']}:{site['line']} 新增 TriggerClientEvent(..., -1, ...) —— "
            "broadcast_sites 预算 143/143，全服广播必须先过 broadcast_allowlist")
    for site in sounds:
        label = f"{site['rel']}:{site['line']} {site['kind']}"
        name = site["file"]
        if not name:
            problems.append(f"{label}: 文件名必须是字符串常量（收到 {site['raw_file']!r}）")
        elif name.endswith(".ogg") or "/" in name or "\\" in name:
            problems.append(
                f"{label}: interact-sound 传的是不带扩展名的名字，收到 {name!r}")
        elif not (SOUNDS / f"{name}.ogg").exists():
            problems.append(f"{label}: interact-sound 里没有 {name}.ogg")

        if not _NUMBER.fullmatch(site["volume"]):
            problems.append(f"{label}: 音量必须是数字常量（收到 {site['volume']!r}）")
        else:
            volume = float(site["volume"])
            if not 0 < volume <= MAX_VOLUME:
                problems.append(f"{label}: 音量 {volume} 不在 (0, {MAX_VOLUME}]")

        if site["kind"] == "world" and not _NUMBER.fullmatch(site["distance"]):
            problems.append(f"{label}: 距离必须是数字常量（收到 {site['distance']!r}）")
    return problems


def test_quest_sound_calls_are_bounded():
    sounds, broadcasts = _scan_repo()
    assert sounds, "一处热狗音效都没找到 —— 扫描范围被改坏了？"
    problems = _problems(sounds, broadcasts)
    assert not problems, (
        "热狗音效调用不合规（文件名 / 音量 / 全服广播）：\n  " + "\n  ".join(problems))
    assert sorted(_site_key(site) for site in sounds) == EXPECTED, (
        "音效调用点与 B 片规格不一致（顾客上门 doorbell 25m/0.3；收银 Shop 0.35/0.3/0.25）：\n"
        f"  实际：{sorted(_site_key(site) for site in sounds)}\n  期望：{EXPECTED}")


def test_gate_rejects_an_unknown_sound_file():
    sounds, broadcasts = _scan_source(
        "TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 25.0, 'nope', 0.3)")
    problems = _problems(sounds, broadcasts)
    assert any("nope.ogg" in problem for problem in problems), problems

    # 反向的另一半：注释/字符串里的示例不能被误报（否则闸门会被文案噪声淹没）。
    decoy = (
        "-- TriggerClientEvent('InteractSound_CL:PlayOnOne', -1, 'Shop', 0.9)\n"
        "--[[\nTriggerServerEvent('InteractSound_SV:PlayWithinDistance', 25.0, 'nope', 0.9)\n]]\n"
        "local text = \"TriggerClientEvent('InteractSound_CL:PlayOnOne', -1, 'Shop', 0.9)\"\n"
    )
    sounds, broadcasts = _scan_source(decoy)
    assert sounds == [] and broadcasts == [], (
        f"注释/字符串里的示例被误报了：{sounds} / {broadcasts}")


def test_gate_rejects_a_volume_above_the_cap():
    sounds, broadcasts = _scan_source(
        "TriggerClientEvent('InteractSound_CL:PlayOnOne', 7, 'Shop', 0.9)")
    problems = _problems(sounds, broadcasts)
    assert any("0.9" in problem and "不在" in problem for problem in problems), problems


def test_gate_rejects_a_new_global_broadcast():
    sounds, broadcasts = _scan_source("TriggerClientEvent('probe:client:all', -1)\n")
    problems = _problems(sounds, broadcasts)
    assert any("-1" in problem for problem in problems), problems


def test_gate_detects_a_loud_real_sound_call():
    """变异用例：把真实的 doorbell 0.3 改成 0.9，同一个判定函数必须报错。"""
    source = CLIENT.read_text(encoding="utf-8")
    assert source.count("'doorbell', 0.3") == 1, (
        "doorbell 调用点不唯一或已被改名：先更新这条变异用例")
    sounds, broadcasts = _scan_source(source.replace("'doorbell', 0.3", "'doorbell', 0.9", 1))
    problems = _problems(sounds, broadcasts)
    assert any("0.9" in problem for problem in problems), problems


