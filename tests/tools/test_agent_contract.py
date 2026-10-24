#!/usr/bin/env python3
"""Pure-function tests for the shared envelope/identity contract (design 03 D4).

No IO: these tests exercise code mapping, envelope key snapshots, idempotency
key derivation and untrusted-text sanitisation.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_DIR = REPO_ROOT / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import agent_contract  # noqa: E402
import agent_gateway  # noqa: E402

# The full design 03 §5.2 table, including every legacy code value.
CODE_TABLE = {
    "bad_request": ("invalid_argument", False),
    "invalid_params": ("invalid_argument", False),
    "invalid_account": ("invalid_argument", False),
    "unsupported_action": ("invalid_argument", False),
    "text_too_long": ("invalid_argument", False),
    "money_cap_exceeded": ("invalid_argument", False),
    "daily_budget_exceeded": ("invalid_argument", False),
    "body_too_large": ("invalid_argument", False),
    "idempotency_key_required": ("invalid_argument", False),
    "unauthorized": ("unauthorized", False),
    "forbidden": ("unauthorized", False),
    "missing_agent_id": ("unauthorized", False),
    "agent_token_not_configured": ("unauthorized", False),
    "admin_token_not_configured": ("unauthorized", False),
    "not_found": ("not_found", False),
    "quest_not_found": ("not_found", False),
    "player_not_found": ("target_offline", True),
    "account_unavailable": ("target_unavailable", False),
    "disabled": ("policy_denied", False),
    "invalid_status": ("policy_denied", False),
    "expired": ("policy_denied", False),
    "unsupported_tool": ("policy_denied", False),
    "rate_limited": ("rate_limited", True),
    "gateway_timeout": ("timeout", True),
    "director_timeout": ("timeout", True),
    "write_outcome_unknown": ("timeout", False),
    "db_error": ("upstream_unavailable", True),
    "database_error": ("upstream_unavailable", True),
    "database_unavailable": ("upstream_unavailable", True),
    "schema_unavailable": ("upstream_unavailable", True),
    "quest_catalog_unavailable": ("upstream_unavailable", True),
    "circuit_open": ("upstream_unavailable", True),
    "gateway_unreachable": ("upstream_unavailable", True),
    "execution_failed": ("execution_failed", False),
    "trigger_quest_failed": ("execution_failed", False),
    "partial_success": ("partial_success", False),
    "internal_error": ("internal_error", True),
    "agent_data_error": ("internal_error", True),
}

EXPECTED_KINDS = {
    "ok",
    "approval_required",
    "idempotent_replay",
    "invalid_argument",
    "unauthorized",
    "not_found",
    "target_offline",
    "target_unavailable",
    "policy_denied",
    "rate_limited",
    "timeout",
    "upstream_unavailable",
    "execution_failed",
    "partial_success",
    "internal_error",
}


class ClassifyTests(unittest.TestCase):
    def test_full_code_table(self) -> None:
        for code, expected in CODE_TABLE.items():
            with self.subTest(code=code):
                self.assertEqual(
                    agent_contract.classify(code),
                    expected,
                    f"classify({code!r}) must match the design table",
                )

    def test_every_mapped_kind_is_canonical(self) -> None:
        self.assertEqual(set(agent_contract.KINDS), EXPECTED_KINDS)
        for code, kind in agent_contract.CODE_TO_KIND.items():
            with self.subTest(code=code, kind=kind):
                self.assertIn(kind, agent_contract.KINDS)

    def test_unknown_code_is_not_retried(self) -> None:
        self.assertEqual(agent_contract.classify("never_seen_before"), ("internal_error", False))
        self.assertEqual(agent_contract.classify(None), ("internal_error", False))


class EnvelopeTests(unittest.TestCase):
    def test_success_key_snapshot_without_cursor(self) -> None:
        payload = agent_contract.envelope_ok("get_schema", {"views": {}}, request_id="r1")
        self.assertEqual(
            set(payload),
            {"schema_version", "ok", "kind", "data", "warnings", "meta"},
            "success envelope key set is part of the wire snapshot",
        )
        self.assertEqual(payload["schema_version"], agent_contract.SCHEMA_VERSION)
        self.assertIs(payload["ok"], True)
        self.assertEqual(payload["kind"], "ok")
        self.assertEqual(payload["data"], {"views": {}})
        self.assertEqual(payload["warnings"], [])
        self.assertEqual(payload["meta"]["tool"], "get_schema")
        self.assertEqual(payload["meta"]["contract"], 1)
        self.assertEqual(payload["meta"]["request_id"], "r1")

    def test_success_key_snapshot_with_cursor(self) -> None:
        payload = agent_contract.envelope_ok(
            "list_events", [{"id": 1}], next_cursor=1, warnings=["trimmed"]
        )
        self.assertEqual(
            set(payload),
            {"schema_version", "ok", "kind", "data", "next_cursor", "warnings", "meta"},
        )
        self.assertEqual(payload["next_cursor"], 1)
        self.assertEqual(payload["warnings"], ["trimmed"])

    def test_error_key_snapshot_and_legacy_strings(self) -> None:
        payload = agent_contract.envelope_error(
            "add_player_money",
            "money_cap_exceeded",
            "amount exceeds cap",
            request_id="r2",
            meta={"risk": "L4"},
        )
        self.assertEqual(
            set(payload),
            {
                "schema_version",
                "ok",
                "kind",
                "data",
                "error",
                "code",
                "retryable",
                "meta",
            },
            "error envelope key set is part of the wire snapshot",
        )
        self.assertIs(payload["ok"], False)
        self.assertIsNone(payload["data"])
        self.assertEqual(payload["kind"], "invalid_argument")
        self.assertIs(payload["retryable"], False)
        self.assertIsInstance(payload["error"], str, "error must stay a string")
        self.assertIsInstance(payload["code"], str, "code must stay a string")
        self.assertEqual(payload["code"], "money_cap_exceeded")
        self.assertEqual(payload["meta"]["tool"], "add_player_money")
        self.assertEqual(payload["meta"]["risk"], "L4")

    def test_old_keys_are_unchanged(self) -> None:
        success = agent_contract.envelope_ok("query_players", [])
        self.assertIn("schema_version", success)
        self.assertIn("data", success)
        error = agent_contract.envelope_error("x", "disabled", "off")
        self.assertIn("error", error)
        self.assertIn("code", error)

    def test_unknown_kind_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            agent_contract.envelope_ok("x", {}, kind="not_a_kind")
        with self.assertRaises(ValueError):
            agent_contract.envelope_error("x", "disabled", "off", kind="not_a_kind")



class GatewayAdditiveEnvelopeTests(unittest.TestCase):
    """The HTTP gateway only adds keys; the four v1 keys stay byte-compatible."""

    def test_success_envelope_keeps_old_keys_and_adds_new(self) -> None:
        payload = agent_gateway._envelope(
            {"views": {}}, next_cursor=2, meta={"count": 1}, request_id="req-1"
        )
        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual(payload["data"], {"views": {}})
        self.assertEqual(payload["next_cursor"], 2)
        self.assertEqual(payload["meta"], {"count": 1})
        self.assertIs(payload["ok"], True)
        self.assertEqual(payload["kind"], "ok")
        self.assertIs(payload["retryable"], False)
        self.assertEqual(payload["request_id"], "req-1")
        self.assertEqual(payload["warnings"], [])

    def test_error_keeps_error_and_code_strings(self) -> None:
        captured: dict = {}

        class FakeHandler:
            def _send_json(self, status, body, headers=None):
                captured["status"] = status
                captured["body"] = body

        agent_gateway.AgentHandler._error(
            FakeHandler(), 503, "agent actions are disabled", "disabled"
        )
        self.assertEqual(captured["status"], 503)
        body = captured["body"]
        # The wire text is fixed per code; the detailed message is logged to
        # stderr instead of being reflected (reflected-input sink).
        self.assertIsInstance(body["error"], str)
        self.assertTrue(body["error"])
        self.assertNotEqual(body["error"], "agent actions are disabled")
        self.assertEqual(body["code"], "disabled")
        self.assertEqual(body["kind"], "policy_denied")
        self.assertIs(body["retryable"], False)

        agent_gateway.AgentHandler._error(
            FakeHandler(), 400, "<script>alert(1)</script>", "validation_error"
        )
        self.assertNotIn("<script>", captured["body"]["error"])
        self.assertEqual(captured["body"]["error"], "invalid request")
        self.assertNotIn("ok", body, "the error shape is only extended by kind/retryable")

    def test_tools_route_serves_the_runtime_registry(self) -> None:
        captured: dict = {}

        class FakeHandler:
            def _send_json(self, status, body, headers=None):
                captured["status"] = status
                captured["body"] = body

            def _error(self, status, message, code, headers=None):
                captured["status"] = status
                captured["body"] = {"error": message, "code": code}

        agent_gateway.AgentHandler._tools_registry(FakeHandler())
        self.assertEqual(captured["status"], 200)
        body = captured["body"]
        self.assertIs(body["ok"], True)
        self.assertEqual(body["kind"], "ok")
        data = body["data"]
        self.assertEqual(data["registry_version"], "1.5.0")
        self.assertEqual(len(data["tools"]), 32, "GET /agent/v1/tools must serve all 31 tools")
        self.assertEqual(body["meta"]["count"], 32)

class IdempotencyKeyTests(unittest.TestCase):
    def test_same_arguments_produce_the_same_key(self) -> None:
        first = agent_contract.derive_idempotency_key(
            "send_notify", {"text": "hi", "citizenid": "ABC123"}, "agent.7"
        )
        second = agent_contract.derive_idempotency_key(
            "send_notify", {"citizenid": "ABC123", "text": "hi"}, "agent.7"
        )
        self.assertEqual(first, second, "dict order must not change the derived key")
        self.assertRegex(first, r"^mcp/agent\.7/send_notify/[0-9a-f]{16}$")

    def test_changed_inputs_produce_different_keys(self) -> None:
        base = agent_contract.derive_idempotency_key("send_notify", {"text": "hi"}, "agent.7")
        self.assertNotEqual(
            base, agent_contract.derive_idempotency_key("send_notify", {"text": "bye"}, "agent.7")
        )
        self.assertNotEqual(
            base, agent_contract.derive_idempotency_key("send_notify", {"text": "hi"}, "agent.8")
        )
        self.assertNotEqual(
            base, agent_contract.derive_idempotency_key("add_player_money", {"text": "hi"}, "agent.7")
        )

    def test_explicit_key_argument_is_excluded(self) -> None:
        without = agent_contract.derive_idempotency_key("send_notify", {"text": "hi"}, "agent.7")
        with_key = agent_contract.derive_idempotency_key(
            "send_notify", {"text": "hi", "idempotency_key": "caller-key"}, "agent.7"
        )
        self.assertEqual(without, with_key, "the derived key must not depend on itself")

    def test_dry_run_gets_the_dry_suffix(self) -> None:
        key = agent_contract.derive_idempotency_key(
            "send_notify", {"text": "hi"}, "agent.7", dry_run=True
        )
        self.assertTrue(key.endswith("/dry"), key)
        self.assertEqual(key[:-4], agent_contract.derive_idempotency_key("send_notify", {"text": "hi"}, "agent.7"))

    def test_key_is_a_valid_actions_key(self) -> None:
        key = agent_contract.derive_idempotency_key(
            "start_player_quest", {"citizenid": "ABC123", "quest_id": "intro:1"}, "agent.7"
        )
        self.assertLessEqual(len(key), 128)
        self.assertRegex(key, r"^[!-~]{1,128}$", "derived key must satisfy the director %g pattern")
        empty_agent = agent_contract.derive_idempotency_key("send_notify", {}, "")
        self.assertTrue(empty_agent.startswith("mcp/mcp.local/"), empty_agent)


class SanitizeTests(unittest.TestCase):
    def test_zero_width_and_bidi_controls_are_removed(self) -> None:
        text = "a\u200bb\u200f\u202ac\u2066d\u2069e"
        cleaned, truncated = agent_contract.sanitize_untrusted(text)
        self.assertEqual(cleaned, "abcde", "zero-width/bidi controls must not survive")
        self.assertFalse(truncated)

    def test_c0_controls_are_removed_and_crlf_is_folded(self) -> None:
        cleaned, truncated = agent_contract.sanitize_untrusted(
            "line1\r\nline2\x00\x07\x7f\tend"
        )
        self.assertEqual(cleaned, "line1\nline2 end")
        self.assertFalse(truncated)

    def test_whitespace_and_blank_lines_are_folded(self) -> None:
        cleaned, truncated = agent_contract.sanitize_untrusted(
            "  a   b  \n\n\n\nc\t\t d  "
        )
        self.assertEqual(cleaned, "a b\n\nc d")
        self.assertFalse(truncated)

    def test_long_text_is_truncated_and_flagged(self) -> None:
        cleaned, truncated = agent_contract.sanitize_untrusted("x" * 250, max_chars=200)
        self.assertEqual(len(cleaned), 200)
        self.assertTrue(truncated, "truncation must be reported to the caller")

    def test_exactly_max_chars_is_not_truncated(self) -> None:
        cleaned, truncated = agent_contract.sanitize_untrusted("y" * 200, max_chars=200)
        self.assertEqual(cleaned, "y" * 200)
        self.assertFalse(truncated)

    def test_non_string_input_is_coerced_safely(self) -> None:
        self.assertEqual(agent_contract.sanitize_untrusted(None), ("", False))
        self.assertEqual(agent_contract.sanitize_untrusted(42), ("42", False))

    def test_zero_max_chars(self) -> None:
        cleaned, truncated = agent_contract.sanitize_untrusted("hello", max_chars=0)
        self.assertEqual(cleaned, "")
        self.assertTrue(truncated)


if __name__ == "__main__":
    unittest.main(verbosity=2)
