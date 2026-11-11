"""人事反馈契约闸门（J-4 / J-5）。

两条规则，都来自真机问题：

1. **老板 / 黑帮 / 组织菜单只有一个动作 → 必须 [E]（custom-prompt）**。
   全服 `setr UseTarget true`，这些菜单原本走 qb-target，玩家要长按 ALT 才看得到；
   现在靠 `Config.ManagementUsePrompt` 强制走 custom-prompt。
2. **66 处人事通知必须走通道**：老板看到的走 `feedback`（feed/error），
   被操作的当事人走 `personnelNote`（手机留档，离线可查）；文案不许残留英文。

每条都在同一个用例里构造错误形状并断言会红（gate_coverage 认 `detects` 记号）。
"""

from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
MGMT = REPO / "T-CityLite.base" / "resources" / "[qb]" / "qb-management"
CLIENT_FILES = [MGMT / "client" / n for n in ("cl_boss.lua", "cl_gang.lua", "cl_org.lua")]
SERVER_FILES = [MGMT / "server" / n for n in ("sv_boss.lua", "sv_gang.lua", "sv_org.lua")]
NL = chr(10)


def test_alt_fallback_detects_disabled_prompt_flag():
    for path in CLIENT_FILES:
        text = path.read_text(encoding="utf-8")
        assert "Config.ManagementUsePrompt" in text, (
            path.name + " 没有读 ManagementUsePrompt —— 会被全局 UseTarget 拖回 ALT 入口")
        assert "exports['qb-core']:DrawText" not in text, (
            path.name + " 还在用 qb-core 的 DrawText 黑条，应改成 custom-prompt")
    cfg = (MGMT / "config.lua").read_text(encoding="utf-8")
    assert re.search(r"Config\.ManagementUsePrompt\s*=\s*true", cfg), (
        "config.lua 里 ManagementUsePrompt 没开 —— 菜单会退回 ALT")

    # 反向：把开关关掉，这条规则必须红
    broken = cfg.replace("Config.ManagementUsePrompt = true",
                         "Config.ManagementUsePrompt = false", 1)
    assert broken != cfg
    assert not re.search(r"Config\.ManagementUsePrompt\s*=\s*true", broken)


def test_naked_notify_detects_injected_line():
    for path in SERVER_FILES:
        text = path.read_text(encoding="utf-8")
        assert "local function feedback" in text, path.name + " 缺 feedback helper"
        assert "local function personnelNote" in text, path.name + " 缺 personnelNote helper"
        naked = [l for l in text.splitlines()
                 if "QBCore:Notify" in l and not l.strip().startswith("--")]
        assert not naked, path.name + " 还有 " + str(len(naked)) + " 处裸通知：" + str(naked[:2])

    # 反向：塞一行裸通知回去，规则必须认出来
    sample = SERVER_FILES[0].read_text(encoding="utf-8")
    broken = sample + NL + "TriggerClientEvent('QBCore:Notify', src, 'oops', 'error')" + NL
    naked = [l for l in broken.splitlines()
             if "QBCore:Notify" in l and not l.strip().startswith("--")]
    assert naked, "闸门没认出裸通知"


def test_english_leftover_detects_regression():
    banned = ("You cannot", "You have been", "Employee fired", "Invalid job",
              "kicked yourself", "Failed to", "Successor is", "Choose someone")
    for path in SERVER_FILES:
        text = path.read_text(encoding="utf-8")
        for word in banned:
            pattern = re.compile(r"'[^'" + NL + r"]*" + re.escape(word) + r"[^'" + NL + r"]*'")
            for match in pattern.finditer(text):
                raise AssertionError(
                    path.name + " 仍有英文玩家文案：" + match.group(0)[:90])

    # 反向：把一句英文塞进玩家文案，规则必须红
    sample = SERVER_FILES[0].read_text(encoding="utf-8")
    broken = sample + NL + "feedback(src, 'You cannot do that', 'error')" + NL
    hit = re.search(r"'[^'" + NL + r"]*You cannot[^'" + NL + r"]*'", broken)
    assert hit, "闸门没认出英文文案"
