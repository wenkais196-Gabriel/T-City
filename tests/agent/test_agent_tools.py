#!/usr/bin/env python3
"""Contract tests for the single-source tool registry (design 03 D1/D2/D3).

No database access and no network access: the registry is read from disk and
the generated files are byte-compared.
"""

from __future__ import annotations

import copy
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_DIR = REPO_ROOT / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import agent_tools  # noqa: E402

ACTIVE_NAMES = {
    "get_schema",
    "query_players",
    "get_player_snapshot",
    "get_player_timeline",
    "list_events",
    "get_world_digest",
    "get_world_state",
    "get_economy_metrics",
    "set_player_job",
    "grant_player_item",
    "send_announce",
    "set_weather",
    "set_time_of_day",
    "teleport_player",
    "spawn_vehicle",
    "remove_player_item",
    "set_player_bucket",
    "kick_player",
    "get_live_players",
    "get_live_player",
    "list_live_events",
    "get_action",
    "list_actions",
    "send_notify",
    "add_player_money",
    "start_player_quest",
}
PLANNED_NAMES = set()


def _registry() -> dict:
    return agent_tools.load_registry()


def _tool(registry: dict, name: str) -> dict:
    for tool in registry["tools"]:
        if tool["name"] == name:
            return tool
    raise AssertionError(f"tool {name!r} not found in registry")


def _errors(registry: dict) -> list[str]:
    return agent_tools.validate_registry(registry)


def _has(errors: list[str], needle: str) -> bool:
    return any(needle in error for error in errors)


class RegistryContentTests(unittest.TestCase):
    def test_registry_shape_and_status_counts(self) -> None:
        registry = _registry()
        self.assertEqual(registry["schema_version"], 1, "registry schema_version must be 1")
        self.assertRegex(registry["registry_version"], r"^\d+\.\d+\.\d+$")
        self.assertEqual(len(registry["tools"]), 26, "v1 ships exactly 26 tools")
        active = {tool["name"] for tool in registry["tools"] if tool["status"] == "active"}
        planned = {tool["name"] for tool in registry["tools"] if tool["status"] == "planned"}
        self.assertEqual(active, ACTIVE_NAMES, "all 26 tools are active for v1")
        self.assertEqual(planned, PLANNED_NAMES, "no tool remains planned")

    def test_every_tool_has_the_required_contract_fields(self) -> None:
        required = (
            "risk",
            "blast_radius",
            "requires_approval",
            "idempotency",
            "dry_run",
            "http",
            "inputSchema",
            "verify",
            "undo",
            "compensation",
        )
        for tool in _registry()["tools"]:
            for field in required:
                with self.subTest(tool=tool["name"], field=field):
                    self.assertIn(field, tool)
            for field in ("method", "path"):
                self.assertIn(field, tool["http"])

    def test_payload_tools_declare_untrusted_fields(self) -> None:
        for name in ("list_events", "get_player_timeline", "get_world_state", "get_world_digest"):
            with self.subTest(tool=name):
                fields = _tool(_registry(), name)["pii"]["untrusted_fields"]
                self.assertTrue(fields, f"{name} returns player-controlled text")

    def test_m0_write_tools_have_approval_and_verify(self) -> None:
        registry = _registry()
        add_money = _tool(registry, "add_player_money")
        self.assertEqual(add_money["risk"], "L4")
        self.assertTrue(add_money["requires_approval"])
        self.assertEqual(add_money["compensation"], "manual")
        self.assertEqual(add_money["verify"]["tool"], "get_player_snapshot")

        notify = _tool(registry, "send_notify")
        self.assertFalse(notify["requires_approval"])
        self.assertEqual(notify["risk"], "L1")
        self.assertEqual(notify["verify"]["tool"], "get_action")

        quest = _tool(registry, "start_player_quest")
        self.assertEqual(quest["risk"], "L3")
        self.assertTrue(quest["requires_approval"])
        self.assertEqual(quest["enum_source"]["source"], "quest_catalog")

    def test_live_tools_are_read_only_director_reads_with_live_auth(self) -> None:
        registry = _registry()
        for name in ("get_live_players", "get_live_player", "list_live_events"):
            with self.subTest(tool=name):
                tool = _tool(registry, name)
                self.assertEqual(tool["channel"], "read")
                self.assertEqual(tool["route"], "director")
                self.assertEqual(tool["risk"], "L0")
                self.assertEqual(tool["auth"], "live")
                self.assertIn("name", tool["pii"]["untrusted_fields"])
                self.assertEqual(tool["http"]["method"], "GET")


class RegistryInvariantTests(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = copy.deepcopy(_registry())
        self.assertEqual(_errors(self.registry), [], "the committed registry must be valid")

    def test_duplicate_name_is_rejected(self) -> None:
        duplicate = copy.deepcopy(self.registry["tools"][0])
        self.registry["tools"].append(duplicate)
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "duplicate tool name"), errors)

    def test_l0_must_be_read_only(self) -> None:
        tool = _tool(self.registry, "send_notify")
        tool["risk"] = "L0"
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "write/effect tools cannot be L0"), errors)

    def test_l3_and_l4_require_approval(self) -> None:
        _tool(self.registry, "add_player_money")["requires_approval"] = False
        _tool(self.registry, "start_player_quest")["requires_approval"] = False
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "L4 tools must require approval"), errors)
        self.assertTrue(_has(errors, "L3 tools must require approval"), errors)

    def test_l4_compensation_must_be_manual(self) -> None:
        _tool(self.registry, "add_player_money")["compensation"] = "none"
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "L4 tools must declare compensation=manual"), errors)

    def test_read_tool_cannot_require_idempotency(self) -> None:
        _tool(self.registry, "get_schema")["idempotency"] = "required"
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "read tools must use idempotency=none"), errors)

    def test_verify_must_reference_an_existing_read_tool(self) -> None:
        _tool(self.registry, "send_notify")["verify"]["tool"] = "get_missing_action"
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "unknown verify tool"), errors)

    def test_undo_must_reference_an_existing_undoable_tool(self) -> None:
        _tool(self.registry, "set_weather")["undo"]["tool"] = "set_missing_weather"
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "unknown undo tool"), errors)

    def test_dangerous_parameter_name_is_rejected(self) -> None:
        tool = _tool(self.registry, "send_notify")
        tool["inputSchema"]["properties"]["script"] = {"type": "string"}
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "dangerous parameter name"), errors)

    def test_volatile_source_identifier_is_rejected(self) -> None:
        tool = _tool(self.registry, "send_notify")
        tool["inputSchema"]["properties"]["source"] = {"type": "string"}
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "volatile source identifiers are forbidden"), errors)

    def test_wide_open_name_is_rejected(self) -> None:
        _tool(self.registry, "send_notify")["name"] = "run_command"
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "must match"), errors)

    def test_legacy_add_player_money_name_is_allowed(self) -> None:
        # Published names are immutable; add_ is the explicit legacy verb.
        self.assertEqual(_errors(self.registry), [])

    def test_legacy_add_prefix_is_not_a_wildcard(self) -> None:
        # Only the exact published name may keep the add_ prefix; a new add_*
        # tool would otherwise bypass the verb whitelist entirely.
        clone = copy.deepcopy(_tool(self.registry, "send_notify"))
        clone["name"] = "add_world_notice"
        clone["director_action"] = "add_world_notice"
        self.registry["tools"].append(clone)
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "must match"), errors)

    def test_l2_must_default_to_approval(self) -> None:
        _tool(self.registry, "send_announce")["requires_approval"] = False
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "L2 tools must default to approval"), errors)

    def test_live_auth_is_rejected_on_gateway_reads(self) -> None:
        _tool(self.registry, "get_schema")["auth"] = "live"
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "auth=live requires route=director"), errors)

    def test_live_auth_is_rejected_on_write_tools(self) -> None:
        _tool(self.registry, "send_notify")["auth"] = "live"
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "auth=live is only allowed for read tools"), errors)

    def test_unknown_auth_mode_is_rejected(self) -> None:
        _tool(self.registry, "get_live_players")["auth"] = "admin"
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, ".auth: must be one of"), errors)

    def test_effect_cannot_be_l1(self) -> None:
        _tool(self.registry, "send_announce")["risk"] = "L1"
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "effect tools must be L2, L3 or L4"), errors)

    def test_missing_required_field_is_rejected(self) -> None:
        del _tool(self.registry, "get_schema")["description"]
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "description: is required"), errors)

    def test_schema_version_is_pinned(self) -> None:
        self.registry["schema_version"] = 2
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "registry.schema_version: must be 1"), errors)

    def test_unknown_argument_is_rejected_at_runtime(self) -> None:
        tool = _tool(_registry(), "send_notify")
        errors = agent_tools.validate_arguments(
            tool, {"citizenid": "ABC123", "text": "hi", "unexpected": 1}
        )
        self.assertTrue(any("unknown argument" in error for error in errors), errors)

    def test_missing_required_argument_is_rejected_at_runtime(self) -> None:
        tool = _tool(_registry(), "send_notify")
        errors = agent_tools.validate_arguments(tool, {"citizenid": "ABC123"})
        self.assertTrue(any(error.startswith("text is required") for error in errors), errors)

    def test_argument_type_enum_pattern_and_bounds(self) -> None:
        money = _tool(_registry(), "add_player_money")
        cases = [
            ({"citizenid": "ABC123", "account": "bank", "amount": 10, "reason": "gift"}, []),
            (
                {"citizenid": "ABC123", "account": "wallet", "amount": 10, "reason": "gift"},
                "account must be one of",
            ),
            (
                {"citizenid": "ABC123", "account": "bank", "amount": 10.5, "reason": "gift"},
                "amount must be integer",
            ),
            (
                {"citizenid": "ABC123", "account": "bank", "amount": 0, "reason": "gift"},
                "amount must be >= 1",
            ),
            (
                {"citizenid": "bad citizen", "account": "bank", "amount": 10, "reason": "gift"},
                "citizenid has invalid characters",
            ),
        ]
        for arguments, expected in cases:
            with self.subTest(arguments=arguments):
                errors = agent_tools.validate_arguments(money, arguments)
                if expected == []:
                    self.assertEqual(errors, [], "valid arguments should pass")
                else:
                    self.assertTrue(any(expected in error for error in errors), errors)

    def test_validate_arguments_accepts_a_tool_name(self) -> None:
        self.assertEqual(
            agent_tools.validate_arguments(
                "send_notify", {"citizenid": "ABC123", "text": "hi"}
            ),
            [],
            "the helper must accept a tool name as well as a tool object",
        )
        self.assertTrue(
            any(
                "unknown tool" in error
                for error in agent_tools.validate_arguments("no_such_tool", {})
            )
        )

    def test_text_length_limit_is_enforced_at_runtime(self) -> None:
        tool = _tool(_registry(), "send_notify")
        errors = agent_tools.validate_arguments(
            tool, {"citizenid": "ABC123", "text": "x" * 301}
        )
        self.assertTrue(any("at most 300" in error for error in errors), errors)


    def test_auth_live_requires_a_live_path(self) -> None:
        # auth=live must not be a second credential path for arbitrary routes.
        tool = _tool(self.registry, "get_live_players")
        tool["http"]["path"] = "/agent/v1/actions"
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "auth=live requires a /agent/v1/live/ path"), errors)

    def test_auth_live_on_a_non_live_read_tool_is_rejected(self) -> None:
        _tool(self.registry, "get_action")["auth"] = "live"
        errors = _errors(self.registry)
        self.assertTrue(_has(errors, "auth=live requires a /agent/v1/live/ path"), errors)


class PatternConversionTests(unittest.TestCase):
    """The generated Lua validator must see the same rule as Python."""

    def test_expands_ranges_and_escaped_literals(self) -> None:
        chars, minimum, maximum = agent_tools.parse_simple_pattern(r"^[A-Za-z0-9_-]{1,11}$")
        self.assertEqual((minimum, maximum), (1, 11))
        self.assertIn("A", chars)
        self.assertIn("z", chars)
        self.assertIn("_", chars)
        self.assertIn("-", chars)
        self.assertNotIn(" ", chars)

        chars, minimum, maximum = agent_tools.parse_simple_pattern(r"^[0-9A-Za-z:+.,\- T]{1,64}$")
        self.assertEqual((minimum, maximum), (1, 64))
        self.assertIn("-", chars)
        self.assertIn(" ", chars)
        self.assertNotIn("\\", chars)

    def test_rejects_unsupported_regexes(self) -> None:
        for pattern in (r"^\d+$", r"^(a|b)$", r"^[a-z]+$", r"^[a-z]{2,}$", r"[a-z]{1,3}"):
            with self.subTest(pattern=pattern):
                self.assertIsNone(agent_tools.parse_simple_pattern(pattern))
                self.assertIsNone(agent_tools.parse_segmented_pattern(pattern))

    def test_expands_the_live_event_cursor(self) -> None:
        segments = agent_tools.parse_segmented_pattern(r"^\d{1,10}:\d{1,9}$")
        self.assertIsNotNone(segments)
        self.assertEqual(
            [(minimum, maximum, literal) for _chars, minimum, maximum, literal in segments],
            [(1, 10, False), (1, 1, True), (1, 9, False)],
        )

    def test_live_cursor_is_enforced_by_python(self) -> None:
        tool = _tool(_registry(), "list_live_events")
        self.assertEqual(
            agent_tools.validate_arguments(tool, {"since": "1761136800:8841"}), []
        )
        for cursor in ("12345678901:1", "1:1234567890", "1761136800-8841", "1:2:3"):
            with self.subTest(cursor=cursor):
                errors = agent_tools.validate_arguments(tool, {"since": cursor})
                self.assertTrue(
                    any("since has invalid characters" in error for error in errors), errors
                )

    def test_unsupported_pattern_fails_registry_validation(self) -> None:
        registry = copy.deepcopy(_registry())
        _tool(registry, "send_notify")["inputSchema"]["properties"]["text"]["pattern"] = r"^\d+$"
        errors = _errors(registry)
        self.assertTrue(_has(errors, "single char class"), errors)


class GeneratedArtifactTests(unittest.TestCase):
    def test_committed_artifacts_match_renderers(self) -> None:
        registry = _registry()
        self.assertEqual(
            agent_tools.TOOLS_MD_PATH.read_text(encoding="utf-8"),
            agent_tools.render_tools_md(registry),
            "TOOLS.md is stale; run python3 tools/agent_tools.py --write",
        )
        self.assertEqual(
            agent_tools.LUA_PATH.read_text(encoding="utf-8"),
            agent_tools.render_lua(registry),
            "agent_tools.lua is stale; run python3 tools/agent_tools.py --write",
        )

    def test_rendering_is_deterministic(self) -> None:
        md_first = agent_tools.render_tools_md(_registry())
        md_second = agent_tools.render_tools_md(_registry())
        lua_first = agent_tools.render_lua(_registry())
        lua_second = agent_tools.render_lua(_registry())
        self.assertEqual(md_first, md_second)
        self.assertEqual(lua_first, lua_second)

    def test_markdown_has_do_not_edit_header_and_tables(self) -> None:
        text = agent_tools.TOOLS_MD_PATH.read_text(encoding="utf-8")
        self.assertIn("DO NOT EDIT", text)
        self.assertIn("Routing table", text)
        self.assertIn("Risk and approval table", text)
        for name in ACTIVE_NAMES | PLANNED_NAMES:
            self.assertIn(f"`{name}`", text, f"{name} missing from generated TOOLS.md")

    def test_lua_has_get_and_validate(self) -> None:
        text = agent_tools.LUA_PATH.read_text(encoding="utf-8")
        self.assertIn("function AgentTools.get(name)", text)
        self.assertIn("function AgentTools.validate(name, args)", text)
        self.assertIn("AgentTools.TOOLS", text)
        self.assertIn("_G.AgentTools = AgentTools", text, "the table must be exposed to the resource")

    def test_check_detects_missing_and_drifted_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            md_path = Path(temp_dir) / "TOOLS.md"
            lua_path = Path(temp_dir) / "agent_tools.lua"
            with mock.patch.object(agent_tools, "TOOLS_MD_PATH", md_path), mock.patch.object(
                agent_tools, "LUA_PATH", lua_path
            ):
                self.assertEqual(
                    agent_tools.main(["--check"]), 1, "missing generated files must fail --check"
                )
                self.assertEqual(agent_tools.main(["--write"]), 0, "--write must succeed")
                self.assertEqual(
                    agent_tools.main(["--check"]), 0, "--write output must be check-clean"
                )
                md_path.write_text(md_path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
                self.assertEqual(
                    agent_tools.main(["--check"]), 1, "drift must fail --check"
                )

    def test_committed_artifacts_pass_check(self) -> None:
        self.assertEqual(
            agent_tools.main(["--check"]), 0, "the committed generated files must be check-clean"
        )

    def test_write_is_idempotent_in_a_temp_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            md_path = Path(temp_dir) / "TOOLS.md"
            lua_path = Path(temp_dir) / "agent_tools.lua"
            with mock.patch.object(agent_tools, "TOOLS_MD_PATH", md_path), mock.patch.object(
                agent_tools, "LUA_PATH", lua_path
            ):
                self.assertEqual(agent_tools.main(["--write"]), 0)
                first_md = md_path.read_text(encoding="utf-8")
                first_lua = lua_path.read_text(encoding="utf-8")
                self.assertEqual(agent_tools.main(["--write"]), 0)
                self.assertEqual(md_path.read_text(encoding="utf-8"), first_md)
                self.assertEqual(lua_path.read_text(encoding="utf-8"), first_lua)
                self.assertEqual(agent_tools.main(["--check"]), 0)

    @unittest.skipUnless(
        shutil.which("luac5.4") or shutil.which("luac"),
        "luac is not installed",
    )
    def test_generated_lua_compiles(self) -> None:
        luac = shutil.which("luac5.4") or shutil.which("luac")
        result = subprocess.run(
            [luac, "-p", str(agent_tools.LUA_PATH)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(
            result.returncode,
            0,
            msg=f"luac rejected {agent_tools.LUA_PATH}:\n{result.stderr}",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
