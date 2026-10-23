"""Smoke entry point so `pytest tests/agent` exercises the Lua harness.

Detailed HTTP assertions live in tests/unit/test_director_http_contract.py;
this file only proves the harness itself loads and the existing pure-policy
suite still passes without FXServer, MySQL or a player.
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
LUA_BIN = shutil.which("lua5.4")


def _run_lua_case(case: str, tmp_path: Path) -> dict:
    out_file = tmp_path / f"{case}.json"
    result = subprocess.run(
        [
            LUA_BIN,
            str(AGENT_TESTS / "lua" / "runner.lua"),
            "--case",
            case,
            "--out",
            str(out_file),
        ],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=30,
        env={**os.environ, "TCITY_ROOT": str(REPO_ROOT), "TZ": "UTC"},
    )
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    payload = json.loads(out_file.read_text(encoding="utf-8"))
    assert payload["ok"] is True, payload
    assert payload["data"]["failed"] == 0
    return payload


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_lua_contract_runner_passes(tmp_path: Path) -> None:
    payload = _run_lua_case("http_contract", tmp_path)
    assert payload["data"]["total"] >= 12


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_lua_adapter_runner_passes(tmp_path: Path) -> None:
    payload = _run_lua_case("http_adapter", tmp_path)
    assert payload["data"]["total"] >= 8


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_policy_suite_still_passes() -> None:
    result = subprocess.run(
        [LUA_BIN, str(AGENT_TESTS / "test_agent_actions_policy.lua")],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "[AGENT-ACTION-TEST] RESULT" in result.stdout
    assert "FAIL" not in result.stdout
