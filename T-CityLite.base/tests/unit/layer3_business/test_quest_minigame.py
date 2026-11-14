"""小游戏原语（quest_minigame.lua）的服务端契约闸门（热狗线 S3）。

两层闸门：
  • 运行时探针跑**真实实现**（标记块抽取，不复制逻辑），覆盖 nonce 生命周期、
    三档映射与四个错误码；
  • 静态契约盯住「quit 分支必须先消费 nonce 再返回」。探针只能证明这一次跑对，
    正则能防止以后有人把顺序改回去（改回去就又能拿同一 nonce 反复退出重试）。

反向校验（坏形状必须红）：
  • 把 tiers 匹配改成「永远命中 common」，探针必须红；
  • 把 quit 分支的 consume 拿掉，或把 consume 改成空操作，静态规则必须判红；
  • 把落库/事件/钱的接线代码塞进内核，副作用规则必须判红。

只建文件、不接线：net event / StepTypes / 物品发放都不在这里。
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
SOURCE = BASE / "resources/[custom]/custom-quest/server/quest_minigame.lua"
PROBE = Path(__file__).resolve().parent / "fixtures" / "minigame_probe.lua"

# 优先 .exe：Windows 的 PATH 里同时有 lua5.4（可能是 Git Bash 包装脚本）
# 和 lua5.4.exe，subprocess 只能直接执行后者。
LUA = shutil.which("lua5.4.exe") or shutil.which("lua5.4")

EXPECTED_CHECKS = 7


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


# ---------------------------------------------------------------------------
# 运行时探针：真跑源码里的 nonce 生命周期
# ---------------------------------------------------------------------------

def _run_probe(source: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [LUA, str(PROBE), str(source)],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60,
    )


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4；缺它就只跑静态规则")
def test_minigame_probe_passes():
    proc = _run_probe(SOURCE)
    assert proc.returncode == 0, f"探针失败：\n{proc.stdout}\n{proc.stderr}"
    assert f"SUMMARY {EXPECTED_CHECKS}/{EXPECTED_CHECKS}" in proc.stdout


# 「按 faults 匹配第一个档位」是唯一决定品质的分支。变异点写死成一个字符串，
# 改名时这条反向校验会先醒（count != 1），而不是悄悄变成永远绿。
TIER_MATCH = "if faults <= entry.max_faults then"


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4；缺它就只跑静态规则")
def test_probe_goes_red_when_tier_matching_is_broken(tmp_path: Path):
    """反向校验（运行时）：把按 tiers 匹配改成永远命中 common，探针必须红。

    0 失误本应 exotic，变异后也会落进 common —— 证明探针确实在验映射，
    而不是只验「Resolve 返回了东西」。
    """
    src = read(SOURCE)
    assert src.count(TIER_MATCH) == 1, (
        "变异点不唯一或已被改名：先更新 TIER_MATCH，否则这条反向校验会失效")
    mutated = src.replace(TIER_MATCH, "if entry.tier == 'common' then")
    target = tmp_path / "quest_minigame_mutant.lua"
    target.write_text(mutated, encoding="utf-8")

    proc = _run_probe(target)
    assert proc.returncode != 0, (
        "把三档映射改成永远 common 后探针仍然通过 —— 探针没有在验证品质映射")
    failed = [line for line in proc.stdout.splitlines() if "FAIL" in line]
    assert any("tier_mapping_0_1_2" in line for line in failed), (
        f"期望 tier_mapping_0_1_2 变红，实际失败行：{failed}")


# ---------------------------------------------------------------------------
# 静态契约：quit 分支必须先消费 nonce，再返回
# ---------------------------------------------------------------------------

QUIT_CONSUMES_NONCE = re.compile(
    r"if\s+payload\.quit\s*==\s*true\s+then\s*\n"
    r"\s*consume\(\s*nonce\s*,\s*session\s*\)[^\n]*\n"
    r"\s*return\s+true\s*,\s*\{\s*quit\s*=\s*true\s*\}",
)


def quit_consumes_nonce(src: str) -> bool:
    return bool(QUIT_CONSUMES_NONCE.search(src))


CONSUME_DELETES_SESSION = re.compile(
    r"local\s+function\s+consume\(\s*nonce\s*,\s*session\s*\)\s*\n"
    r"\s*Sessions\[\s*nonce\s*\]\s*=\s*nil",
)


def consume_deletes_session(src: str) -> bool:
    return bool(CONSUME_DELETES_SESSION.search(src))


def test_quit_branch_consumes_nonce_before_returning():
    src = read(SOURCE)
    assert consume_deletes_session(src), (
        "consume() 必须真的删掉 Sessions[nonce]：否则 quit 分支调了 consume "
        "也挡不住重放")
    assert quit_consumes_nonce(src), (
        "quit 分支必须先 consume(nonce) 再 return：否则同一 nonce 可以反复"
        "「退出→重开」，退出语义会被绕过")


def test_quit_rule_rejects_the_old_shape():
    """反向校验（静态）：先返回、不消费的旧形状必须判红。"""
    old = """
    if payload.quit == true then
        return true, { quit = true }
    end
    """
    assert not quit_consumes_nonce(old)


def test_consumption_rule_rejects_a_noop_consume():
    """反向校验（静态）：consume 改名成不删会话的空操作必须判红。"""
    noop = """
    local function consume(nonce, session)
        -- mutated: 不删会话
    end
    """
    assert not consume_deletes_session(noop)


# ---------------------------------------------------------------------------
# 静态契约：内核不落库、不发事件、不碰钱/物品
# ---------------------------------------------------------------------------

FORBIDDEN_SIDE_EFFECTS = (
    "TriggerClientEvent(",
    "TriggerEvent(",
    "MySQL.",
    "AddMoney(",
    "RemoveMoney(",
    "AddItem(",
    "RemoveItem(",
)


def offending_side_effects(src: str) -> list[str]:
    return [token for token in FORBIDDEN_SIDE_EFFECTS if token in src]


def test_kernel_has_no_db_network_or_economy_side_effects():
    assert offending_side_effects(read(SOURCE)) == [], (
        "内核只能返回结果；落库/发事件/动钱动物品必须留给接线方，"
        "否则产出会有两条路径，审计无法对账")


def test_side_effect_rule_rejects_a_wired_up_version():
    """反向校验（静态）：把接线代码塞进内核必须被判红。"""
    wired = (
        "TriggerClientEvent('quest:minigame:done', src, result)\n"
        "MySQL.query.await('INSERT INTO x VALUES (?)', { 1 })\n"
        "Player.Functions.AddMoney('cash', 10)\n"
    )
    assert offending_side_effects(wired) != []
