#!/usr/bin/env python3
"""Offline tests for the local console harness (design 07).

No FXServer, no client and no network: every source is a temporary file and the
MCP facade is driven through ``agent_mcp.handle_message``.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_DIR = REPO_ROOT / "tools"
for path in (TOOLS_DIR, REPO_ROOT / "tests" / "tools"):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

import agent_harness  # noqa: E402
import agent_mcp  # noqa: E402

SERVER_LINES = [
    "[           resources] Scanning resources.",
    "[    c-scripting-core] Started resource zz-mcp-diag",
    "[rcon/script:zz-mcp-d] [zz-mcp-diag] zdiag from console args=hello,world",
    "\x1b[38;5;202m[                rcon] \x1b[0m\x1b[0mRcon from [::ffff:127.0.0.1]:57538",
]

CLIENT_LINES = [
    "[     56171] [b3258_GTAProce]             MainThrd/ [zz-mcp-diag] heartbeat #1",
    "[     58187] [b3258_GTAProce]             MainThrd/ [zz-mcp-diag] heartbeat #2",
]


def _write(path: Path, lines: list[str]) -> None:
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


class HarnessParseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.server_log = self.root / "fxserver.log"
        self.client_dir = self.root / "client"
        self.client_dir.mkdir()
        self.client_log = self.client_dir / "CitizenFX_log_2026-01-01T00-00-00.log"
        _write(self.server_log, SERVER_LINES)
        _write(self.client_log, CLIENT_LINES)
        self.env = mock.patch.dict(
            os.environ,
            {
                "TCITY_HARNESS": "1",
                "TCITY_HARNESS_SERVER_LOG": str(self.server_log),
                "TCITY_HARNESS_CLIENT_LOG_DIR": str(self.client_dir),
            },
        )
        self.env.start()

    def tearDown(self) -> None:
        self.env.stop()
        self.tmp.cleanup()

    def test_server_lines_carry_channel_and_strip_ansi(self) -> None:
        data = agent_harness.observe("server", limit=10)
        self.assertEqual(data["target"], "server")
        self.assertEqual(data["file"], str(self.server_log))
        channels = [line["channel"] for line in data["lines"]]
        self.assertIn("c-scripting-core", channels)
        self.assertIn("rcon/script:zz-mcp-d", channels)
        last = data["lines"][-1]
        self.assertEqual(last["channel"], "rcon")
        self.assertNotIn("\x1b[", last["message"], "ANSI colour codes must be stripped")
        self.assertIn("Rcon from", last["message"])

    def test_client_lines_use_the_thread_as_channel(self) -> None:
        data = agent_harness.observe("client", limit=10)
        self.assertEqual(len(data["lines"]), 2)
        self.assertEqual(data["lines"][0]["channel"], "MainThrd")
        self.assertEqual(data["lines"][0]["message"], "[zz-mcp-diag] heartbeat #1")

    def test_tail_returns_the_last_lines_not_the_first(self) -> None:
        many = [f"[                rcon] line {index}" for index in range(60)]
        _write(self.server_log, many)
        data = agent_harness.observe("server", limit=5)
        self.assertEqual(len(data["lines"]), 5)
        self.assertEqual(data["lines"][-1]["message"], "line 59")

    def test_after_seq_pages_without_repeating(self) -> None:
        first = agent_harness.observe("server", limit=2, after_seq=0)
        self.assertTrue(first["lines"])
        cursor = first["next_seq"]
        self.assertGreater(cursor, 0)
        second = agent_harness.observe("server", limit=2, after_seq=cursor)
        first_seqs = {line["seq"] for line in first["lines"]}
        second_seqs = {line["seq"] for line in second["lines"]}
        self.assertFalse(first_seqs & second_seqs, "paging must not repeat lines")
        self.assertGreater(min(second_seqs), max(first_seqs))

    def test_contains_and_pattern_filters(self) -> None:
        by_text = agent_harness.observe("server", limit=10, contains="zdiag")
        self.assertEqual(len(by_text["lines"]), 1)
        self.assertIn("hello,world", by_text["lines"][0]["message"])

        by_regex = agent_harness.observe("client", limit=10, pattern=r"heartbeat #\d$")
        self.assertEqual(len(by_regex["lines"]), 2)

        none = agent_harness.observe("server", limit=10, contains="no-such-text")
        self.assertEqual(none["lines"], [])

    def test_partial_line_is_not_reported(self) -> None:
        with self.server_log.open("ab") as handle:
            handle.write(b"[                rcon] half-written")
        data = agent_harness.observe("server", limit=10, contains="half-written")
        self.assertEqual(data["lines"], [])
        with self.server_log.open("ab") as handle:
            handle.write(b" line\n")
        done = agent_harness.observe("server", limit=10, contains="half-written")
        self.assertEqual(len(done["lines"]), 1)

    def test_newest_client_log_wins(self) -> None:
        newer = self.client_dir / "CitizenFX_log_2026-01-02T00-00-00.log"
        _write(newer, ["[  1] [b3258_GTAProce]  MainThrd/ newer-file-line"])
        os.utime(self.client_log, (1_000_000, 1_000_000))
        data = agent_harness.observe("client", limit=5)
        self.assertEqual(data["file"], str(newer))
        self.assertIn("newer-file-line", data["lines"][0]["message"])

    def test_wait_returns_the_matching_line(self) -> None:
        timer = threading.Timer(
            0.2,
            lambda: self.server_log.open("a", encoding="utf-8").write(
                "[  script:zz-mcp-diag] ready after restart\n"
            ),
        )
        timer.start()
        try:
            result = agent_harness.wait("server", pattern="ready after restart", timeout_ms=4000)
        finally:
            timer.cancel()
        self.assertEqual(result["matched"]["channel"], "script:zz-mcp-diag")
        self.assertGreater(result["next_seq"], 0)

    def test_wait_times_out_with_a_stable_code(self) -> None:
        started = time.monotonic()
        with self.assertRaises(agent_harness.HarnessError) as raised:
            agent_harness.wait("server", pattern="never-printed", timeout_ms=500)
        self.assertLess(time.monotonic() - started, 5.0)
        self.assertEqual(raised.exception.code, "timeout")
        self.assertIn("within 500ms", raised.exception.message)

    def test_missing_log_is_reported_not_crashed(self) -> None:
        self.server_log.unlink()
        with self.assertRaises(agent_harness.HarnessError) as raised:
            agent_harness.observe("server")
        self.assertEqual(raised.exception.code, "log_not_found")

    def test_status_never_raises(self) -> None:
        self.server_log.unlink()
        report = agent_harness.status()
        self.assertTrue(report["enabled"])
        self.assertFalse(report["targets"]["server"]["configured"])
        self.assertTrue(report["targets"]["client"]["configured"])


class HarnessToolTests(unittest.TestCase):
    """The MCP facade: visibility gate, envelope shape and error codes."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.server_log = self.root / "fxserver.log"
        _write(self.server_log, SERVER_LINES)
        self.env = mock.patch.dict(
            os.environ,
            {
                "TCITY_HARNESS": "1",
                "TCITY_HARNESS_SERVER_LOG": str(self.server_log),
                "AGENT_TOOLSET": "all",
            },
        )
        self.env.start()

    def tearDown(self) -> None:
        self.env.stop()
        self.tmp.cleanup()

    def _call(self, name: str, arguments: dict) -> dict:
        response = agent_mcp.handle_message(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments},
            }
        )
        assert response is not None and "result" in response, response
        return json.loads(response["result"]["content"][0]["text"])

    def _names(self) -> set[str]:
        response = agent_mcp.handle_message({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        assert response is not None
        return {tool["name"] for tool in response["result"]["tools"]}

    def test_tools_are_hidden_without_the_env_gate(self) -> None:
        self.assertIn("get_console_lines", self._names())
        with mock.patch.dict(os.environ, {"TCITY_HARNESS": ""}):
            names = self._names()
        self.assertNotIn("get_console_lines", names)
        self.assertNotIn("get_console_match", names)
        self.assertNotIn("get_client_log", names)

    def test_console_lines_envelope_and_untrusted_notice(self) -> None:
        payload = self._call("get_console_lines", {"target": "server", "limit": 5})
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["meta"]["route"], "harness")
        self.assertEqual(payload["meta"]["risk"], "L0")
        self.assertEqual(payload["meta"]["target"], "server")
        self.assertTrue(payload["data"]["lines"])
        untrusted = payload["meta"].get("untrusted_fields", [])
        self.assertTrue(
            any(path.endswith(".message") for path in untrusted),
            f"console text is player-controlled, got {untrusted}",
        )

    def test_console_match_returns_the_line(self) -> None:
        payload = self._call(
            "get_console_match",
            {"target": "server", "pattern": "zdiag from console", "after_seq": 0},
        )
        self.assertTrue(payload["ok"])
        self.assertIn("zdiag from console", payload["data"]["matched"]["message"])

    def test_timeout_is_a_tool_error(self) -> None:
        payload = self._call(
            "get_console_match",
            {"target": "server", "pattern": "never-printed", "timeout_ms": 500},
        )
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["code"], "timeout")
        self.assertIsInstance(payload["error"], str)

    def test_missing_target_is_a_bad_request(self) -> None:
        payload = self._call("get_console_lines", {})
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["code"], "bad_request")


if __name__ == "__main__":
    unittest.main(verbosity=2)
