#!/usr/bin/env python3
"""Small MCP protocol regression tests (issue #24)."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_DIR = REPO_ROOT / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import agent_mcp  # noqa: E402


def _call(method: str, params: dict | None = None, request_id: int = 1) -> dict:
    response = agent_mcp.handle_message(
        {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}}
    )
    assert response is not None
    return response


class McpProtocolTests(unittest.TestCase):
    def test_initialize(self) -> None:
        result = _call(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "test", "version": "0.1"},
            },
        )["result"]
        self.assertEqual(result["protocolVersion"], "2024-11-05")
        self.assertEqual(result["serverInfo"]["name"], "t-city-agent")
        self.assertIn("tools", result["capabilities"])

    def test_tools_list(self) -> None:
        tools = _call("tools/list")["result"]["tools"]
        self.assertEqual(
            {tool["name"] for tool in tools},
            {"get_schema", "query_players", "get_player_snapshot", "list_events", "get_world_digest"},
        )
        for tool in tools:
            self.assertEqual(tool["inputSchema"]["type"], "object")

    def test_tool_result_uses_content_wrapper(self) -> None:
        result = _call("tools/call", {"name": "get_schema", "arguments": {}})["result"]
        self.assertFalse(result["isError"])
        self.assertEqual(result["content"][0]["type"], "text")
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["schema_version"], 1)
        self.assertIn("agent_events_feed", payload["data"]["views"])

    def test_tool_argument_error_is_mcp_error(self) -> None:
        result = _call(
            "tools/call",
            {"name": "get_schema", "arguments": {"unexpected": 1}},
        )["result"]
        self.assertTrue(result["isError"])
        payload = json.loads(result["content"][0]["text"])
        self.assertEqual(payload["code"], "bad_request")

    def test_unknown_tool_is_jsonrpc_error(self) -> None:
        response = _call("tools/call", {"name": "not_a_tool", "arguments": {}})
        self.assertEqual(response["error"]["code"], -32602)

    def test_initialized_notification_has_no_response(self) -> None:
        self.assertIsNone(
            agent_mcp.handle_message({"jsonrpc": "2.0", "method": "notifications/initialized"})
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
