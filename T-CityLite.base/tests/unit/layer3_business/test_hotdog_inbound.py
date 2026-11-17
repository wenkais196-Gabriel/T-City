"""G 片：顾客 INBOUND 走位 + 服务端报价生命周期。

两条规则，各自真跑源码里的纯函数（`-- [marker]` 抽块，不复制实现）：

1. `PickSpawnPoint` 把生成点钉在 25–40 m：扫 0–360°（每 15°）距离必须等于输入，
   5 / 100 这类越界值被夹紧而不是报错，z 始终等于摊位高度；
2. 报价生命周期 = `inbound_budget_ms + patience_ms`：喂假 cfg 直接算，不碰真实时间；
   同时确认 `CreateOffer` 的 `expiresAt` 真的接的是这个算式。

反向校验：把 `PickSpawnPoint` 改回固定 2.2 m、把 `expiresAt` 改回 `now + patience`，
探针都必须红 —— 否则这两条断言证明不了任何东西。
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
QUEST = BASE / "resources/[custom]/custom-quest"
CLIENT = QUEST / "client/quest_hotdog_vendor_client.lua"
SERVER = QUEST / "server/quest_vendor.lua"
PROBE = Path(__file__).with_name("fixtures") / "hotdog_inbound_probe.lua"

#: 优先 .exe：Windows PATH 里裸名 lua5.4 会被当成 .4 文档弹「选择一个应用」。
LUA = shutil.which("lua5.4.exe") or shutil.which("lua5.4")


def run_probe(mode: str, source: Path) -> subprocess.CompletedProcess[str]:
    assert LUA, "需要 lua5.4 / lua5.4.exe"
    return subprocess.run(
        [LUA, str(PROBE), mode, str(source)],
        capture_output=True, encoding="utf-8", errors="replace",
        timeout=60, stdin=subprocess.DEVNULL,
    )


def assert_green(mode: str, source: Path) -> str:
    proc = run_probe(mode, source)
    assert proc.returncode == 0, f"{proc.stdout}\n{proc.stderr}"
    assert "SUMMARY" in proc.stdout
    return proc.stdout


# ---------------------------------------------------------------------------
# 正向：真实仓库必须绿
# ---------------------------------------------------------------------------


def test_pick_spawn_point_stays_in_the_walk_band():
    assert_green("client", CLIENT)


def test_offer_lifetime_is_inbound_plus_patience():
    assert_green("server", SERVER)


# ---------------------------------------------------------------------------
# 反向：错误形状必须红
# ---------------------------------------------------------------------------


def test_reverse_fixed_2_2m_spawn_is_rejected(tmp_path: Path):
    source = CLIENT.read_text(encoding="utf-8")
    assert "local INBOUND_MIN_M = 25.0" in source
    assert "local INBOUND_MAX_M = 40.0" in source
    mutated = source.replace("local INBOUND_MIN_M = 25.0", "local INBOUND_MIN_M = 2.2", 1)
    mutated = mutated.replace("local INBOUND_MAX_M = 40.0", "local INBOUND_MAX_M = 2.2", 1)
    path = tmp_path / "client_fixed_spawn.lua"
    path.write_text(mutated, encoding="utf-8")

    proc = run_probe("client", path)
    assert proc.returncode != 0, (
        "PickSpawnPoint 退回固定 2.2 m 仍然通过 —— 距离断言没有咬住\n" + proc.stdout)
    assert "FAIL" in proc.stdout


def test_reverse_expires_at_with_only_patience_is_rejected(tmp_path: Path):
    source = SERVER.read_text(encoding="utf-8")
    wire = "expiresAt = now + offerLifetimeMs(session.cfg)"
    assert wire in source
    mutated = source.replace(wire, "expiresAt = now + session.cfg.patience_ms", 1)
    path = tmp_path / "quest_vendor_patience_only.lua"
    path.write_text(mutated, encoding="utf-8")

    proc = run_probe("server", path)
    assert proc.returncode != 0, (
        "expiresAt 退回 now + patience 仍然通过 —— 生命周期接线断言没有咬住\n" + proc.stdout)
    assert "create_offer_uses_lifetime" in proc.stdout and "FAIL" in proc.stdout


def test_reverse_lifetime_formula_dropping_inbound_is_rejected(tmp_path: Path):
    source = SERVER.read_text(encoding="utf-8")
    assert "return inbound + patience" in source
    mutated = source.replace("return inbound + patience", "return patience", 1)
    path = tmp_path / "quest_vendor_lifetime_drop_inbound.lua"
    path.write_text(mutated, encoding="utf-8")

    proc = run_probe("server", path)
    assert proc.returncode != 0, (
        "生命周期算式漏掉 inbound 仍然通过 —— 纯函数断言没有咬住\n" + proc.stdout)
    assert "lifetime_case_1" in proc.stdout and "FAIL" in proc.stdout
