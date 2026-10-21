#!/usr/bin/env python3
"""Unit checks for the rule-based director bridge (#31).

Run from the repository root or from T-CityLite.base:

    python3 -m pytest -q tests/unit/layer3_business/test_director_rules.py

The behavioural assertions live in a dependency-free Lua harness so they can
also be run without Python:

    lua5.4 T-CityLite.base/tests/agent/test_director_rules.lua

These tests never touch MariaDB, FXServer or a real player. Migration/DB
verification and the live approval walkthrough are documented in
docs/agent/DIRECTOR.md.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import unittest
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parents[3]  # T-CityLite.base/
REPO_ROOT = BASE_DIR.parent
LUA_TEST = BASE_DIR / "tests" / "agent" / "test_director_rules.lua"
LUA_BIN = shutil.which("lua5.4")

RESOURCE_DIR = BASE_DIR / "resources" / "[custom]" / "custom-director"
MIGRATION = BASE_DIR / "migrations" / "v2.3.1_agent_director.sql"
DIRECTOR_RULES = RESOURCE_DIR / "server" / "director_rules.lua"
DIRECTOR = RESOURCE_DIR / "server" / "director.lua"
FXMANIFEST = RESOURCE_DIR / "fxmanifest.lua"
SCENARIO = (
    BASE_DIR
    / "resources"
    / "[custom]"
    / "tcity-e2e"
    / "config"
    / "scenarios"
    / "director_bridge.json"
)
DOC = BASE_DIR / "docs" / "agent" / "DIRECTOR.md"


class LuaDirectorRulesTests(unittest.TestCase):
    """Run the standalone pure-Lua rule/harness suite."""

    @unittest.skipUnless(LUA_BIN, "lua5.4 is not installed")
    def test_rule_suite_passes(self) -> None:
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
        self.assertIn("[DIRECTOR-RULES-TEST] RESULT", result.stdout)
        self.assertNotIn("[DIRECTOR-RULES-TEST] FAIL", result.stdout)
        self.assertRegex(
            result.stdout,
            r"\[DIRECTOR-RULES-TEST\] RESULT total=\d+ failed=0",
        )


class MigrationContractTests(unittest.TestCase):
    """The migration must persist the documented cursor state."""

    def setUp(self) -> None:
        self.sql = MIGRATION.read_text(encoding="utf-8")

    def test_table_columns(self) -> None:
        for column in ("name", "cursor", "updated_at", "last_event_at"):
            with self.subTest(column=column):
                self.assertIn(f"`{column}`", self.sql)
        self.assertIn("PRIMARY KEY (`name`)", self.sql)
        self.assertIn("`cursor`        BIGINT      NOT NULL DEFAULT 0", self.sql)
        self.assertIn("`last_event_at` DATETIME(3) NULL", self.sql)

    def test_seed_row_is_idempotent(self) -> None:
        self.assertIn("INSERT IGNORE INTO `agent_director_state`", self.sql)
        self.assertIn("VALUES ('agent_events', 0)", self.sql)


class ResourceContractTests(unittest.TestCase):
    """Static guardrails for the observe -> propose-only bridge."""

    def setUp(self) -> None:
        self.manifest = FXMANIFEST.read_text(encoding="utf-8")
        self.director = DIRECTOR.read_text(encoding="utf-8")
        self.rules = DIRECTOR_RULES.read_text(encoding="utf-8")

    def test_manifest_loads_rules_and_director_after_broker(self) -> None:
        self.assertIn("'server/director_rules.lua'", self.manifest)
        self.assertIn("'server/director.lua'", self.manifest)
        self.assertLess(
            self.manifest.index("'server/main.lua'"),
            self.manifest.index("'server/director.lua'"),
        )

    def test_convars_and_exports(self) -> None:
        for convar in (
            "agent_director_enabled",
            "agent_director_interval",
            "agent_director_batch",
            "agent_director_max_proposals",
        ):
            with self.subTest(convar=convar):
                self.assertIn(convar, self.director)

        for export in ("RunOnce", "GetState", "Reset"):
            with self.subTest(export=export):
                self.assertIn(f"exports('{export}'", self.director)

        self.assertIn("agent_actions_enabled", self.director)

    def test_proposes_but_never_approves(self) -> None:
        self.assertIn("AgentActions.Propose", self.director)
        self.assertNotIn("Approve", self.director)
        self.assertNotIn("agentapprove", self.director.lower())

    def test_rule_map(self) -> None:
        self.assertIn("civilian_ch1_first_dollar", self.rules)
        self.assertIn("civilian_ch2_startup_struggle", self.rules)
        self.assertIn("police_ch1_first_shift", self.rules)
        self.assertIn("police_ch2_corruption_web", self.rules)
        self.assertNotRegex(
            self.rules,
            r"cartel_ch1_first_blood\s*=\s*'cartel_ch2_territory_war'",
        )
        self.assertIn("DirectorRules.idempotencyKey", self.rules)
        self.assertIn("DirectorRules.extractCompletedQuest", self.rules)


class ScenarioContractTests(unittest.TestCase):
    """director_bridge.json must keep the human inspection window open."""

    def setUp(self) -> None:
        self.scenario = json.loads(SCENARIO.read_text(encoding="utf-8"))

    def test_schema_and_players(self) -> None:
        self.assertEqual(self.scenario["schema_version"], 1)
        self.assertGreaterEqual(len(self.scenario["players"]), 1)
        self.assertEqual(self.scenario["players"][0]["cid"], "SIM001")

    def test_completes_ch1_then_waits(self) -> None:
        steps = self.scenario["steps"]
        self.assertTrue(any(s.get("quest") == "civilian_ch1_first_dollar" for s in steps))
        self.assertTrue(any(s.get("action") == "make_choice" for s in steps))
        waits = [s.get("ms") for s in steps if s.get("action") == "wait"]
        self.assertIn(120000, waits)

    def test_asserts_ch1_completed(self) -> None:
        asserts = self.scenario["assert"]
        completed = [
            a
            for a in asserts
            if a.get("type") == "quest_status"
            and a.get("quest") == "civilian_ch1_first_dollar"
            and a.get("expect") == "completed"
        ]
        self.assertTrue(completed)


class DocumentationTests(unittest.TestCase):
    def test_director_doc_exists(self) -> None:
        self.assertTrue(DOC.is_file())
        text = DOC.read_text(encoding="utf-8")
        self.assertIn("observe", text.lower())
        self.assertIn("agent_director_enabled", text)
        self.assertIn("cursor", text.lower())


if __name__ == "__main__":
    unittest.main()
