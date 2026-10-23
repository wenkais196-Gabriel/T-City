#!/usr/bin/env python3
"""Tests for the read-only agent data layer (issue #24).

Run from the repository root:

    python3 -m unittest discover -s tests/agent -v
    python3 -m pytest -q tests/agent/test_agent_data.py

The unit tests do not touch the database.  The integration class is skipped
automatically when ``AGENT_DB_PASS`` / the ``agent_ro`` views are unavailable.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_DIR = REPO_ROOT / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import agent_data  # noqa: E402


def _db_available() -> tuple[bool, str]:
    """Best-effort check for the local read-only DB integration fixture."""
    try:
        agent_data.load_env_file()
        if not os.environ.get("AGENT_DB_PASS"):
            return False, "AGENT_DB_PASS is not set"
        if not agent_data.db_ping():
            return False, "SELECT 1 via agent_ro failed"
        agent_data.get_world_state(limit=1)
        return True, ""
    except Exception as exc:  # noqa: BLE001 - only used for skip messaging
        return False, f"{type(exc).__name__}: {exc}"


_DB_AVAILABLE, _DB_REASON = _db_available()


class ValidationTests(unittest.TestCase):
    """Whitelists and limits are enforced before any SQL is sent."""

    def setUp(self) -> None:
        self._original_execute = agent_data._execute

        def fail_if_called(*args, **kwargs):
            raise AssertionError("validation should fail before the database is queried")

        agent_data._execute = fail_if_called

    def tearDown(self) -> None:
        agent_data._execute = self._original_execute

    def test_field_whitelist_rejects_injection(self) -> None:
        cases = [
            lambda: agent_data.query_players({"fields": "citizenid; DROP TABLE players"}),
            lambda: agent_data.query_players({"fields": ["citizenid", "name) FROM players --"]}),
            lambda: agent_data.query_players({"fields": "citizenid, nope"}),
            lambda: agent_data.query_players({"fields": "*, citizenid"}),
        ]
        for case in cases:
            with self.subTest(case=case):
                with self.assertRaises(ValueError):
                    case()

    def test_order_and_filter_whitelist_rejects_injection(self) -> None:
        cases = [
            lambda: agent_data.query_players({"order_by": "bank DESC; DROP TABLE players"}),
            lambda: agent_data.query_players({"order": "asc; DROP"}),
            lambda: agent_data.query_players({"job": "police' OR '1'='1"}),
            lambda: agent_data.query_players({"gang": "none%"}),
            lambda: agent_data.query_players({"updated_since": "not-a-date"}),
            lambda: agent_data.query_players({"bogus": "x"}),
            lambda: agent_data.get_player_snapshot("x' OR '1'='1"),
            lambda: agent_data.get_player_timeline("x' OR 1=1 --"),
            lambda: agent_data.list_events(type="quest.completed; DROP TABLE agent_events"),
            lambda: agent_data.list_events(since_id=-1),
            lambda: agent_data.get_world_state(limit="abc"),
        ]
        for case in cases:
            with self.subTest(case=case):
                with self.assertRaises(ValueError):
                    case()

    def test_whitelisted_values_are_accepted(self) -> None:
        self.assertEqual(
            agent_data.validate_fields("citizenid, job", agent_data.PLAYER_FIELDS),
            ["citizenid", "job"],
        )
        self.assertEqual(
            len(agent_data.validate_fields("*", agent_data.PLAYER_FIELDS)),
            len(agent_data.PLAYER_FIELDS),
        )
        self.assertEqual(agent_data.validate_order_direction("DESC"), "desc")
        self.assertEqual(agent_data.validate_event_type("quest.*"), "quest.*")
        self.assertIsNone(agent_data.validate_event_type("*"))


class LimitTests(unittest.TestCase):
    def test_limit_clamping(self) -> None:
        self.assertEqual(agent_data.clamp_limit(None), agent_data.DEFAULT_LIMIT)
        self.assertEqual(agent_data.clamp_limit(""), agent_data.DEFAULT_LIMIT)
        self.assertEqual(agent_data.clamp_limit(0), 1)
        self.assertEqual(agent_data.clamp_limit(-5), 1)
        self.assertEqual(agent_data.clamp_limit(1), 1)
        self.assertEqual(agent_data.clamp_limit(200), 200)
        self.assertEqual(agent_data.clamp_limit(201), 200)
        self.assertEqual(agent_data.clamp_limit(999999), 200)
        self.assertEqual(agent_data.clamp_limit("42"), 42)
        with self.assertRaises(ValueError):
            agent_data.clamp_limit("abc")

    def test_digest_window_and_budget_clamping(self) -> None:
        self.assertEqual(
            agent_data.clamp_int(None, 5, 1, 1440, "window_minutes"),
            5,
        )
        self.assertEqual(agent_data.clamp_int(0, 5, 1, 1440, "window_minutes"), 1)
        self.assertEqual(agent_data.clamp_int(99999, 5, 1, 1440, "window_minutes"), 1440)
        with self.assertRaises(ValueError):
            agent_data.clamp_int("x", 5, 1, 1440, "window_minutes")


class ParsingTests(unittest.TestCase):
    def test_parse_since(self) -> None:
        fixed = dt.datetime(2026, 10, 21, 12, 0, 0)
        self.assertEqual(agent_data.parse_since("15m", now=fixed), dt.datetime(2026, 10, 21, 11, 45))
        self.assertEqual(agent_data.parse_since("5h", now=fixed), dt.datetime(2026, 10, 21, 7, 0))
        self.assertEqual(agent_data.parse_since("7d", now=fixed), dt.datetime(2026, 10, 14, 12, 0))
        utc_noon = dt.datetime(2026, 10, 21, 12, 0, 0, tzinfo=dt.timezone.utc)
        self.assertEqual(
            agent_data.parse_since("2026-10-21T12:00:00Z", now=fixed),
            utc_noon.astimezone().replace(tzinfo=None),
        )
        self.assertEqual(
            agent_data.parse_since("2026-10-21", now=fixed),
            dt.datetime(2026, 10, 21, 0, 0, 0),
        )
        with self.assertRaises(ValueError):
            agent_data.parse_since("yesterday-ish", now=fixed)

    def test_select_only_guard(self) -> None:
        agent_data._assert_select_only("SELECT 1 AS ok")
        for statement in (
            "DELETE FROM players",
            "UPDATE players SET name = 'x'",
            "SELECT 1; DROP TABLE players",
            "SELECT * FROM players FOR UPDATE",
            "INSERT INTO agent_events (event_type) VALUES ('x')",
        ):
            with self.subTest(statement=statement):
                with self.assertRaises(agent_data.AgentDataError):
                    agent_data._assert_select_only(statement)

    def test_sql_literal_escaping(self) -> None:
        self.assertEqual(agent_data._sql_literal("O'Brien"), "'O\\'Brien'")
        self.assertEqual(agent_data._sql_literal(7), "7")
        self.assertEqual(agent_data._sql_literal(None), "NULL")


class DigestBudgetTests(unittest.TestCase):
    def _big_digest(self) -> dict:
        return {
            "digest_version": 1,
            "window_minutes": 5,
            "budget_tokens": 200,
            "players": {
                "total": 100,
                "online_estimate": 10,
                "recently_active": 10,
                "stale_24h": 5,
            },
            "events": {
                "available": True,
                "total": 1000,
                "top_types": [{"type": f"quest.step{k}", "count": 100 - k} for k in range(50)],
            },
            "recent_events": [
                {
                    "id": k,
                    "event_type": "quest.step",
                    "citizenid": "ABC123",
                    "created_at": "2026-10-21 10:00:00",
                    "payload_preview": "x" * 200,
                }
                for k in range(50)
            ],
            "economy": {
                "job_groups": 10,
                "players": 100,
                "total_cash": 1.0,
                "total_bank": 2.0,
                "top_jobs": [
                    {"job": f"job{k}", "player_count": 1, "total_bank": 2.0}
                    for k in range(20)
                ],
            },
            "risk": {
                "low_liquidity_count": 5,
                "low_liquidity_players": [
                    {"citizenid": "ABC123", "job": "x", "cash": 1, "bank": 2}
                    for _ in range(20)
                ],
                "stuck_quest_available": True,
                "stuck_quest_candidates": [
                    {
                        "citizenid": "ABC123",
                        "event_type": "quest.advance",
                        "occurred_at": "2026-10-21 10:00:00",
                        "minutes_ago": 120,
                    }
                    for _ in range(20)
                ],
            },
            "truncated": False,
        }

    def test_digest_respects_budget(self) -> None:
        original = self._big_digest()
        original_json = json.dumps(original, ensure_ascii=False, sort_keys=True)
        for budget in (50, 100, 200, 300, 500, 1000, 2000):
            with self.subTest(budget=budget):
                fitted = agent_data.fit_digest_budget(original, budget)
                encoded = json.dumps(fitted, ensure_ascii=False, separators=(",", ":"))
                self.assertLessEqual(len(encoded), budget * 4)
                self.assertLessEqual(agent_data.estimate_tokens(fitted), budget)
                self.assertIn("estimated_tokens", fitted)
                self.assertTrue(fitted.get("truncated"))
        # Even pathological budgets must be respected (detail is dropped).
        for budget in (1, 5, 10, 20):
            with self.subTest(budget=budget):
                fitted = agent_data.fit_digest_budget(original, budget)
                encoded = json.dumps(fitted, ensure_ascii=False, separators=(",", ":"))
                self.assertLessEqual(len(encoded), budget * 4)
        # The input must not be mutated.
        self.assertEqual(
            json.dumps(original, ensure_ascii=False, sort_keys=True),
            original_json,
        )

    def test_estimate_tokens_rounds_up(self) -> None:
        self.assertEqual(agent_data.estimate_tokens({"a": "1234"}), 3)
        self.assertEqual(agent_data.estimate_tokens({}), 1)


class SchemaRegistryTests(unittest.TestCase):
    def test_schema_registry_includes_event_feed(self) -> None:
        schema = agent_data.get_schema()
        self.assertEqual(schema["schema_version"], 1)
        self.assertTrue(schema["read_only"])
        self.assertIn("agent_events_feed", schema["views"])
        self.assertIn("agent_player_snapshot", schema["views"])
        feed_fields = {field["name"] for field in schema["views"]["agent_events_feed"]["fields"]}
        self.assertEqual(
            feed_fields,
            {"event_type", "citizenid", "payload", "schema_version", "created_at", "id"},
        )


@unittest.skipUnless(_DB_AVAILABLE, f"DB integration unavailable: {_DB_REASON}")
class DatabaseIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.players = agent_data.query_players(limit=2)

    def test_players_and_snapshot(self) -> None:
        self.assertIsInstance(self.players, list)
        self.assertLessEqual(len(self.players), 2)
        if not self.players:
            self.skipTest("no players in the local database")
        cid = self.players[0]["citizenid"]
        snapshot = agent_data.get_player_snapshot(cid)
        self.assertIsNotNone(snapshot)
        self.assertEqual(snapshot["citizenid"], cid)
        self.assertIn("bank", snapshot)

    def test_timeline_and_events(self) -> None:
        if not self.players:
            self.skipTest("no players in the local database")
        cid = self.players[0]["citizenid"]
        timeline = agent_data.get_player_timeline(cid, limit=5)
        self.assertIsInstance(timeline, list)
        self.assertLessEqual(len(timeline), 5)
        events = agent_data.list_events(limit=5)
        self.assertIsInstance(events, list)
        self.assertLessEqual(len(events), 5)
        if events:
            self.assertIn("id", events[0])
            self.assertIn("event_type", events[0])

    def test_world_economy_digest(self) -> None:
        world = agent_data.get_world_state(limit=1)
        self.assertTrue(world)
        self.assertIn("source_table", world[0])
        economy = agent_data.get_economy_metrics()
        self.assertIsInstance(economy, list)
        digest = agent_data.get_world_digest(window_minutes=1440, budget_tokens=500)
        self.assertEqual(digest["budget_tokens"], 500)
        self.assertLessEqual(agent_data.estimate_tokens(digest), 500)
        self.assertIn("players", digest)
        self.assertIn("online", digest["players"])
        self.assertIn("events", digest)
        self.assertIn("economy", digest)


if __name__ == "__main__":
    unittest.main(verbosity=2)
