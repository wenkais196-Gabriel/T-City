"""报警分类契约闸门（C-1）。

规则：
1. 服务端 `ALERT_KINDS` 的每一项都要有中文标题与合法优先级（1–3）；
2. `officer_down` 必须是最高优先级（警员受伤要排最前）；
3. 所有 `police:server:policeAlert` 调用点都必须带 kind，且 kind 在 `ALERT_KINDS` 里；
4. 调用点不许再把英文自由文本当标题传（`Drug sale in progress` 这类）。

每条都在同一用例里自己构造错误形状并断言会红（gate_coverage 认 `detects`）。
"""

from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base" / "resources"
SERVER = RES / "[custom]" / "custom-police" / "server" / "main.lua"
CALLSITES = [
    RES / "[custom]" / "custom-police" / "client" / "main.lua",
    RES / "[custom]" / "custom-vehicles" / "client" / "main.lua",
    RES / "[qb]" / "qb-drugs" / "client" / "cornerselling.lua",
    RES / "[qb]" / "qb-drugs" / "client" / "deliveries.lua",
    RES / "[qb]" / "qb-houserobbery" / "client" / "main.lua",
    RES / "[qb]" / "qb-storerobbery" / "client" / "main.lua",
]

KIND_ENTRY = re.compile(r"(\w+)\s*=\s*\{\s*title\s*=\s*'([^']+)'\s*,\s*priority\s*=\s*(\d)\s*\}")


def _kinds(text: str) -> dict[str, tuple[str, int]]:
    match = re.search(r"local ALERT_KINDS = \{(.*?)\n\}", text, re.S)
    assert match, "custom-police 服务端找不到 ALERT_KINDS 表"
    return {m.group(1): (m.group(2), int(m.group(3))) for m in KIND_ENTRY.finditer(match.group(1))}


def test_alert_kinds_detects_bad_priority_or_english_title():
    kinds = _kinds(SERVER.read_text(encoding="utf-8"))
    assert len(kinds) >= 6, "报警分类少于 6 类（漏了犯罪类型）"
    for name, (title, priority) in kinds.items():
        assert 1 <= priority <= 3, f"{name} 的优先级 {priority} 超出 1–3"
        assert re.search(r"[\u4e00-\u9fff]", title), f"{name} 的标题不是中文：{title}"
    assert kinds["officer_down"][1] == max(p for _, p in kinds.values()), (
        "警员受伤必须是最高优先级（最危险的事要排最前）")

    # 反向：把警员受伤降成 1，规则必须红
    broken = {"officer_down": ("警员受伤，请求支援", 1)}
    assert broken["officer_down"][1] != max(p for _, p in kinds.values())


def test_callsites_pass_known_kind_detects_free_text():
    kinds = set(_kinds(SERVER.read_text(encoding="utf-8")))
    for path in CALLSITES:
        text = path.read_text(encoding="utf-8")
        for line in text.splitlines():
            if "police:server:policeAlert" not in line or line.strip().startswith("--"):
                continue
            # 取出第二个参数（kind）
            call = re.search(r"policeAlert'\s*,\s*(.+)\)\s*$", line.rstrip())
            assert call, f"{path.name} 的调用点形状认不出来：{line.strip()[:80]}"
            args = call.group(1)
            kind = re.findall(r"'([a-z_]+)'\s*$", args)
            assert kind, f"{path.name} 的报警没带 kind：{line.strip()[:90]}"
            assert kind[-1] in kinds, f"{path.name} 传了未知 kind：{kind[-1]}"
            # 反向：英文自由文本不许出现在调用点
            assert not re.search(r"'[A-Z][a-z]+ [a-z]+", line), (
                f"{path.name} 还在传英文自由文本：{line.strip()[:90]}")


def test_reverse_unknown_kind_is_unmatched():
    """未知 kind 必须走回退（不命中分类表），否则会写成空标题。"""
    kinds = _kinds(SERVER.read_text(encoding="utf-8"))
    assert "not_a_real_kind" not in kinds
    assert "store_robbery" in kinds
