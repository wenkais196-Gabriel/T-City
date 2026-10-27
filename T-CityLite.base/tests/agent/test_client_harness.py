"""Headless client-side harness: the client half that used to need a real game.

`runner_client.lua` loads *unmodified* client Lua into `stubs/client.lua`, which
models the five client mechanisms we actually get bitten by: the coroutine
scheduler + virtual clock (Wait/CreateThread), the NUI focus state machine, the
NUI message/callback channel, net events, and the native surface our client
files use. Cases assert on recorded state instead of a screenshot.

This is the counterpart to `CLIENT_HARNESS.md` (which needs a Windows FiveM
client + MCP bridge): everything assertable here costs no player, no GPU and no
server. Anything that still needs the real client is listed in
`docs/agent/design/06-client-model.md` §3.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

BASE_DIR = Path(__file__).resolve().parents[2]  # T-CityLite.base/
REPO_ROOT = BASE_DIR.parent
AGENT_TESTS = BASE_DIR / "tests" / "agent"
RUNNER = AGENT_TESTS / "lua" / "runner_client.lua"
LUA_BIN = shutil.which("lua5.4")


def _run(case: str, tmp_path: Path) -> dict:
    assert LUA_BIN is not None
    out_file = tmp_path / f"{case}.json"
    result = subprocess.run(
        [LUA_BIN, str(RUNNER), "--case", case, "--out", str(out_file)],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=60,
        env={**os.environ, "TCITY_ROOT": str(REPO_ROOT), "TZ": "UTC"},
    )
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    payload = json.loads(out_file.read_text(encoding="utf-8"))
    assert payload["ok"] is True, payload
    return payload


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_phone_client_focus_and_input(tmp_path: Path) -> None:
    payload = _run("phone_focus", tmp_path)
    assert payload["data"]["failed"] == 0
    # 12 invariants; a shrinking count means checks were quietly deleted.
    assert payload["data"]["total"] >= 12


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_agent_effect_channel(tmp_path: Path) -> None:
    payload = _run("agent_effects", tmp_path)
    assert payload["data"]["failed"] == 0
    assert payload["data"]["total"] >= 11


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_full_client_suite(tmp_path: Path) -> None:
    assert LUA_BIN is not None
    out_file = tmp_path / "all.json"
    result = subprocess.run(
        [LUA_BIN, str(RUNNER), "--case", "all", "--out", str(out_file)],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=60,
        env={**os.environ, "TCITY_ROOT": str(REPO_ROOT), "TZ": "UTC"},
    )
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    payload = json.loads(out_file.read_text(encoding="utf-8"))
    assert payload["ok"] is True, payload
    assert payload["data"]["failed"] == 0
    assert payload["data"]["total"] >= 2
