"""HTTP contract tests for custom-director's pure Lua handler.

Drives T-CityLite.base/tests/agent/lua/runner.lua in a lua5.4 subprocess and
asserts on the structured JSON it writes (never on console text). The Lua
golden cases are the single source of truth for status codes and payloads;
this module independently pins the public contract so a silent Lua edit cannot
weaken both sides at once.

Run from either the repository root or T-CityLite.base:

    python3 -m pytest -q tests/unit/test_director_http_contract.py
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
LUA_BIN = shutil.which("lua5.4")
RUNNER = BASE_DIR / "tests" / "agent" / "lua" / "runner.lua"

# Independent expectations for the golden cases that the task pins.
EXPECTED = {
    "disabled_returns_503": (503, "disabled"),
    "empty_token_returns_503": (503, "agent_token_not_configured"),
    "unknown_path_before_auth": (404, "not_found"),
    "wrong_method_returns_405": (405, "method_not_allowed"),
    "admin_route_without_admin_token": (503, "admin_token_not_configured"),
    "admin_wrong_bearer_returns_401": (401, "unauthorized"),
    "agent_wrong_bearer_returns_401": (401, "unauthorized"),
    "policy_returns_200": (200, None),
    "missing_agent_id_returns_400": (400, "missing_agent_id"),
    "invalid_json_returns_400": (400, "bad_request"),
    "non_object_body_returns_400": (400, "bad_request"),
    "content_length_over_limit_returns_413": (413, "body_too_large"),
    "act_dry_run_returns_200": (200, None),
    "missing_content_length_returns_400": (400, "missing_body"),
    "agent_token_cannot_approve": (401, "unauthorized"),
    "admin_approve_returns_200": (200, None),
    "trailing_slash_returns_404": (404, "not_found"),
    "empty_array_reaches_act_envelope": (400, "bad_request"),
    "list_returns_rows_for_agent": (200, None),
}


def _run_contract(tmp_path: Path) -> dict:
    out_file = tmp_path / "http_contract.json"
    env = {
        **os.environ,
        "TCITY_ROOT": str(REPO_ROOT),
        "TZ": "UTC",
    }
    proc = subprocess.run(
        [LUA_BIN, str(RUNNER), "--case", "http_contract", "--out", str(out_file)],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
    )

    assert out_file.exists(), (
        f"Lua runner produced no output file (rc={proc.returncode})\n"
        f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    )
    payload = json.loads(out_file.read_text(encoding="utf-8"))
    assert proc.returncode in (0, 1), (
        f"harness error rc={proc.returncode}: {payload}\n"
        f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    )
    assert proc.returncode == 0, (
        f"contract cases failed: {payload}\n"
        f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    )
    return payload


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_http_contract_golden(tmp_path: Path) -> None:
    payload = _run_contract(tmp_path)

    assert payload["ok"] is True, payload
    data = payload["data"]
    assert data["failed"] == 0, data
    assert data["passed"] == data["total"], data
    assert data["total"] >= 12, f"expected at least 12 goldens, got {data['total']}"

    by_name = {case["name"]: case for case in data["cases"]}
    missing = sorted(set(EXPECTED) - set(by_name))
    assert not missing, f"missing golden cases: {missing}"

    for name, (status, code) in EXPECTED.items():
        case = by_name[name]
        assert case["ok"] is True, (name, case.get("error"))
        assert case["status"] == status, (name, case["status"], case.get("body"))
        assert case["expected_status"] == status, name
        body = case.get("body") or {}
        assert body.get("code") == code, (name, body.get("code"), body)
        assert case.get("expected_code") == code, name

    # Headers are part of the contract, not just status codes.
    assert by_name["wrong_method_returns_405"]["headers"]["Allow"] == "POST"
    assert (
        by_name["admin_wrong_bearer_returns_401"]["headers"]["WWW-Authenticate"]
        == "Bearer"
    )
    assert (
        by_name["agent_wrong_bearer_returns_401"]["headers"]["WWW-Authenticate"]
        == "Bearer"
    )

    # Successful bodies expose the expected fields.
    policy_body = by_name["policy_returns_200"]["body"]
    assert policy_body["schema_version"] == 1
    assert policy_body["enabled"] is True
    act_body = by_name["act_dry_run_returns_200"]["body"]
    assert act_body["ok"] is True
    assert act_body["status"] == "proposed"
    assert act_body["id"] == 1
    list_body = by_name["list_returns_rows_for_agent"]["body"]
    assert list_body["count"] == 1
    assert isinstance(list_body["actions"], list)
    assert list_body["actions"][0]["id"] == 1
