#!/usr/bin/env python3
"""Unit checks for the custom-director action broker (#30/#32).

Run from the repository root or from T-CityLite.base:

    python3 -m pytest -q tests/unit/layer3_business/test_agent_actions.py

The behavioural assertions live in a dependency-free Lua harness so they can
also be run without Python:

    lua5.4 T-CityLite.base/tests/agent/test_agent_actions_policy.lua

These tests never touch MariaDB, FXServer or a real player. Live-server and DB
integration are verified separately (migration + manual curl) and documented in
the resource README.
"""

from __future__ import annotations

import shutil
import subprocess
import unittest
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parents[3]  # T-CityLite.base/
REPO_ROOT = BASE_DIR.parent
LUA_TEST = BASE_DIR / "tests" / "agent" / "test_agent_actions_policy.lua"
LUA_BIN = shutil.which("lua5.4")

RESOURCE_DIR = BASE_DIR / "resources" / "[custom]" / "custom-director"
MIGRATION = BASE_DIR / "migrations" / "v2.3_agent_actions.sql"


class LuaPolicyTests(unittest.TestCase):
    """Run the standalone Lua policy/preview/idempotency suite."""

    @unittest.skipUnless(LUA_BIN, "lua5.4 is not installed")
    def test_policy_suite_passes(self) -> None:
        result = subprocess.run(
            [LUA_BIN, str(LUA_TEST)],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(
            result.returncode,
            0,
            msg=f"Lua suite failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        self.assertIn("[AGENT-ACTION-TEST] RESULT", result.stdout)
        self.assertNotIn("[AGENT-ACTION-TEST] FAIL", result.stdout)
        self.assertNotIn("[AGENT-ACTIONS-SELFTEST] FAIL", result.stdout)
        self.assertRegex(
            result.stdout,
            r"\[AGENT-ACTIONS-SELFTEST\] RESULT passed=\d+ failed=0",
        )


class MigrationContractTests(unittest.TestCase):
    """The migration must match the documented agent_actions contract."""

    def setUp(self) -> None:
        self.sql = MIGRATION.read_text(encoding="utf-8")

    def test_table_columns_and_status_enum(self) -> None:
        for column in (
            "id",
            "agent_id",
            "action_type",
            "params",
            "status",
            "idempotency_key",
            "preview",
            "result",
            "error",
            "requested_at",
            "approved_by",
            "approved_at",
            "executed_at",
            "expires_at",
        ):
            with self.subTest(column=column):
                self.assertIn(f"`{column}`", self.sql)

        for status in (
            "proposed",
            "pending_approval",
            "approved",
            "executed",
            "rejected",
            "failed",
        ):
            with self.subTest(status=status):
                self.assertIn(f"'{status}'", self.sql)

    def test_idempotency_and_read_indexes(self) -> None:
        self.assertIn("UNIQUE KEY `uq_idem` (`idempotency_key`)", self.sql)
        self.assertIn("KEY `idx_status_requested` (`status`, `requested_at`)", self.sql)
        self.assertIn("KEY `idx_agent_requested` (`agent_id`, `requested_at`)", self.sql)


class ResourceContractTests(unittest.TestCase):
    """Static guardrails for the server-only resource and its HTTP surface."""

    def setUp(self) -> None:
        self.manifest = (RESOURCE_DIR / "fxmanifest.lua").read_text(encoding="utf-8")
        self.main = (RESOURCE_DIR / "server" / "main.lua").read_text(encoding="utf-8")
        self.http = (RESOURCE_DIR / "server" / "http_api.lua").read_text(encoding="utf-8")
        self.selftest = (RESOURCE_DIR / "server" / "selftest.lua").read_text(encoding="utf-8")

    def test_manifest_is_server_only_and_has_dependencies(self) -> None:
        self.assertIn("server_only 'yes'", self.manifest)
        self.assertNotIn("client_script", self.manifest)
        self.assertIn("@oxmysql/lib/MySQL.lua", self.manifest)
        self.assertIn("@core-framework/bus.lua", self.manifest)
        for dependency in ("qb-core", "oxmysql", "custom-quest", "core-framework"):
            with self.subTest(dependency=dependency):
                self.assertIn(f"'{dependency}'", self.manifest)

    def test_required_convars_and_routes(self) -> None:
        for convar in (
            "agent_actions_enabled",
            "agent_actions_token",
            "agent_actions_admin_token",
            "agent_actions_max_money",
            "agent_actions_daily_budget",
            "agent_actions_max_notify_chars",
            "agent_actions_ttl_seconds",
        ):
            with self.subTest(convar=convar):
                self.assertIn(convar, self.main)

        self.assertIn("agent_actions_selftest", self.selftest)
        self.assertIn("'server/http_api.lua'", self.manifest)
        self.assertLess(
            self.manifest.index("'server/http_api.lua'"),
            self.manifest.index("'server/main.lua'"),
        )

        for route in (
            "/agent/v1/act",
            "/agent/v1/actions",
            "/agent/v1/policy",
        ):
            with self.subTest(route=route):
                self.assertIn(route, self.http)

        self.assertIn("X-Agent-Id", self.http)
        self.assertIn("pending_approval", self.main)
        self.assertIn("agent_action:", self.main)


if __name__ == "__main__":
    unittest.main()
