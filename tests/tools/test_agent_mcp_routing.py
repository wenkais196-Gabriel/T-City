#!/usr/bin/env python3
"""Routing tests for the MCP facade (design 03 D5/D8).

``urllib.request.urlopen`` is stubbed everywhere: these tests never touch the
network, a database or a real FXServer.
"""

from __future__ import annotations

import io
import json
import os
import socket
import sys
import time
import unittest
import urllib.error
import urllib.parse
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_DIR = REPO_ROOT / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import agent_contract  # noqa: E402
import agent_mcp  # noqa: E402

GATEWAY_ENV = {
    "AGENT_GATEWAY_URL": "http://gateway.test",
    "AGENT_GATEWAY_TOKEN": "read-token",
}
DIRECTOR_ENV = {
    "AGENT_DIRECTOR_URL": "http://director.test",
    "AGENT_DIRECTOR_TOKEN": "write-token",
}
LIVE_ENV = {
    "AGENT_DIRECTOR_URL": "http://director.test",
    "AGENT_LIVE_TOKEN": "live-token",
}


class FakeResponse:
    def __init__(self, payload: dict, status: int = 200) -> None:
        self.status = status
        self._body = json.dumps(payload).encode("utf-8")

    def read(self) -> bytes:
        return self._body

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *args: object) -> bool:
        return False


def _http_error(status: int, payload: dict) -> urllib.error.HTTPError:
    body = io.BytesIO(json.dumps(payload).encode("utf-8"))
    return urllib.error.HTTPError(
        "http://upstream.test/agent/v1/x", status, "upstream error", {}, body
    )


def _call(name: str, arguments: dict | None = None, *, dry_run: bool | None = None) -> tuple[dict, dict]:
    params: dict = {"name": name, "arguments": arguments or {}}
    if dry_run is not None:
        params["dry_run"] = dry_run
    response = agent_mcp.handle_message(
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params}
    )
    assert response is not None
    assert "result" in response, response
    result = response["result"]
    payload = json.loads(result["content"][0]["text"])
    return result, payload


def _tools() -> list[dict]:
    response = agent_mcp.handle_message(
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
    )
    assert response is not None
    return response["result"]["tools"]


def _request(mock_urlopen: mock.Mock, index: int = 0) -> urllib.request.Request:
    return mock_urlopen.call_args_list[index].args[0]


def _request_body(request: urllib.request.Request) -> dict:
    assert request.data is not None, "write requests must carry a JSON body"
    return json.loads(request.data.decode("utf-8"))


def _headers(request: urllib.request.Request) -> dict[str, str]:
    return {key.lower(): value for key, value in request.headers.items()}


class RoutingTestBase(unittest.TestCase):
    def setUp(self) -> None:
        agent_mcp._reset_circuit()

    def tearDown(self) -> None:
        agent_mcp._reset_circuit()

    def _env(self, *extras: dict) -> dict:
        env = {}
        for extra in extras:
            env.update(extra)
        return env


class ReadRoutingTests(RoutingTestBase):
    def test_read_tool_uses_gateway_get_and_bearer_token(self) -> None:
        with mock.patch.dict(os.environ, GATEWAY_ENV, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse(
                {"schema_version": 1, "data": {"views": {"agent_events_feed": {}}}, "meta": {"count": 1}}
            )
            result, payload = _call("get_schema")
        self.assertFalse(result["isError"])
        self.assertEqual(payload["kind"], "ok")
        self.assertIs(payload["ok"], True)
        self.assertEqual(payload["meta"]["tool"], "get_schema")
        self.assertEqual(payload["meta"]["route"], "gateway")
        self.assertEqual(mock_urlopen.call_count, 1)
        request = _request(mock_urlopen)
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(request.full_url, "http://gateway.test/agent/v1/schema")
        self.assertEqual(_headers(request)["authorization"], "Bearer read-token")

    def test_path_and_query_mapping(self) -> None:
        with mock.patch.dict(os.environ, GATEWAY_ENV, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse(
                {"schema_version": 1, "data": [], "next_cursor": 3, "meta": {"count": 0}}
            )
            _call("list_events", {"since_id": 2, "type": "quest.*", "limit": 10})
            request = _request(mock_urlopen)
            parsed = urllib.parse.urlsplit(request.full_url)
            self.assertEqual(parsed.path, "/agent/v1/events")
            self.assertEqual(
                urllib.parse.parse_qs(parsed.query),
                {"since_id": ["2"], "type": ["quest.*"], "limit": ["10"]},
            )

            mock_urlopen.reset_mock()
            mock_urlopen.return_value = FakeResponse(
                {"schema_version": 1, "data": {"citizenid": "ABC123"}}
            )
            _call("get_player_snapshot", {"citizenid": "ABC123"})
            request = _request(mock_urlopen)
            self.assertEqual(request.full_url, "http://gateway.test/agent/v1/players/ABC123")

    def test_read_timeout_setting_is_forwarded(self) -> None:
        env = dict(GATEWAY_ENV, AGENT_MCP_READ_TIMEOUT_MS="1234")
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse({"schema_version": 1, "data": {}})
            _call("get_schema")
        self.assertAlmostEqual(mock_urlopen.call_args.kwargs["timeout"], 1.234)

    def test_director_read_uses_x_agent_id(self) -> None:
        env = dict(DIRECTOR_ENV, AGENT_AGENT_ID="agent.7")
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse(
                {"action": {"id": 7, "status": "executed"}}
            )
            result, payload = _call("get_action", {"action_id": 7})
        self.assertFalse(result["isError"])
        self.assertEqual(payload["data"], {"id": 7, "status": "executed"})
        self.assertEqual(payload["meta"]["route"], "director")
        request = _request(mock_urlopen)
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(request.full_url, "http://director.test/agent/v1/actions/7")
        self.assertEqual(_headers(request)["x-agent-id"], "agent.7")

    def test_director_list_actions_maps_query(self) -> None:
        env = dict(DIRECTOR_ENV, AGENT_AGENT_ID="agent.7")
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse({"actions": [], "count": 0})
            result, payload = _call("list_actions", {"status": "pending_approval", "limit": 5})
        self.assertFalse(result["isError"])
        self.assertEqual(payload["data"], [])
        self.assertEqual(payload["meta"]["count"], 0)
        parsed = urllib.parse.urlsplit(_request(mock_urlopen).full_url)
        self.assertEqual(parsed.path, "/agent/v1/actions")
        self.assertEqual(
            urllib.parse.parse_qs(parsed.query),
            {"status": ["pending_approval"], "limit": ["5"]},
        )

    def test_live_players_use_live_token_and_keep_the_whole_body(self) -> None:
        env = dict(LIVE_ENV, AGENT_AGENT_ID="agent.7")
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse(
                {
                    "schema_version": 1,
                    "players": [{"citizenid": "ABC123", "name": "Bob", "job": "police"}],
                    "count": 1,
                    "sampled_at": 1761136800000,
                    "precision_m": 25,
                }
            )
            result, payload = _call("get_live_players", {"limit": 10, "job": "police"})
        self.assertFalse(result["isError"], payload)
        self.assertEqual(payload["kind"], "ok")
        self.assertEqual(payload["data"]["count"], 1)
        self.assertEqual(payload["data"]["precision_m"], 25)
        self.assertEqual(payload["data"]["players"][0]["name"], "Bob")
        self.assertEqual(payload["meta"]["count"], 1)
        self.assertEqual(payload["meta"]["route"], "director")
        self.assertEqual(payload["meta"]["tool"], "get_live_players")
        self.assertIn("players.0.name", payload["meta"]["untrusted_fields"])
        request = _request(mock_urlopen)
        self.assertEqual(request.get_method(), "GET")
        parsed = urllib.parse.urlsplit(request.full_url)
        self.assertEqual(parsed.path, "/agent/v1/live/players")
        self.assertEqual(
            urllib.parse.parse_qs(parsed.query), {"limit": ["10"], "job": ["police"]}
        )
        headers = _headers(request)
        self.assertEqual(headers["authorization"], "Bearer live-token")
        self.assertEqual(headers["x-agent-id"], "agent.7")

    def test_live_player_path_substitution(self) -> None:
        with mock.patch.dict(os.environ, LIVE_ENV, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse(
                {"schema_version": 1, "player": {"citizenid": "ABC123", "name": "Bob"}}
            )
            result, payload = _call("get_live_player", {"citizenid": "ABC123"})
        self.assertFalse(result["isError"], payload)
        self.assertEqual(payload["data"]["player"]["citizenid"], "ABC123")
        self.assertIn("player.name", payload["meta"]["untrusted_fields"])
        request = _request(mock_urlopen)
        self.assertEqual(request.full_url, "http://director.test/agent/v1/live/players/ABC123")
        headers = _headers(request)
        self.assertEqual(headers["authorization"], "Bearer live-token")
        self.assertEqual(headers["x-agent-id"], "mcp.local")

    def test_live_events_keep_cursor_and_report_errors(self) -> None:
        with mock.patch.dict(os.environ, LIVE_ENV, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse(
                {
                    "schema_version": 1,
                    "events": [{"seq": 8821, "type": "player.join", "name": "Bob"}],
                    "next_cursor": "1761136800:8821",
                    "dropped": 2,
                }
            )
            result, payload = _call(
                "list_live_events", {"since": "1761136800:8821", "limit": 25}
            )
            self.assertFalse(result["isError"], payload)
            self.assertEqual(payload["data"]["events"][0]["seq"], 8821)
            self.assertEqual(payload["data"]["next_cursor"], "1761136800:8821")
            self.assertEqual(payload["data"]["dropped"], 2)
            self.assertNotIn("count", payload["meta"])
            parsed = urllib.parse.urlsplit(_request(mock_urlopen).full_url)
            self.assertEqual(parsed.path, "/agent/v1/live/events")
            self.assertEqual(
                urllib.parse.parse_qs(parsed.query),
                {"since": ["1761136800:8821"], "limit": ["25"]},
            )

            mock_urlopen.reset_mock()
            mock_urlopen.return_value = FakeResponse(
                {"error": "cursor expired", "code": "invalid_cursor"}
            )
            result, payload = _call("list_live_events", {"since": "1:1"})
        self.assertTrue(result["isError"])
        self.assertEqual(payload["code"], "invalid_cursor")
        self.assertEqual(payload["error"], "cursor expired")

    def test_live_tool_is_not_callable_without_the_live_token(self) -> None:
        with mock.patch.dict(os.environ, DIRECTOR_ENV, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            response = agent_mcp.handle_message(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "tools/call",
                    "params": {"name": "get_live_players", "arguments": {}},
                }
            )
        self.assertIsNotNone(response)
        self.assertTrue(response["result"]["isError"], "a hidden live tool must not be callable")
        payload = json.loads(response["result"]["content"][0]["text"])
        self.assertEqual(payload["code"], "unauthorized")
        self.assertEqual(mock_urlopen.call_count, 0, "no write credential may be sent to live")

    def test_read_timeout_is_retried_and_reported(self) -> None:
        with mock.patch.dict(os.environ, GATEWAY_ENV, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen, mock.patch("agent_mcp.time.sleep"):
            mock_urlopen.side_effect = urllib.error.URLError(socket.timeout("timed out"))
            result, payload = _call("get_schema")
        self.assertTrue(result["isError"])
        self.assertEqual(payload["code"], "gateway_timeout")
        self.assertEqual(payload["kind"], "timeout")
        self.assertIs(payload["retryable"], True)
        self.assertEqual(mock_urlopen.call_count, 3, "read timeout gets two retries")

    def test_read_is_retried_twice_on_503(self) -> None:
        with mock.patch.dict(os.environ, GATEWAY_ENV, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen, mock.patch("agent_mcp.time.sleep"):
            mock_urlopen.side_effect = [
                _http_error(503, {"error": "db down", "code": "db_error"}),
                _http_error(503, {"error": "db down", "code": "db_error"}),
                FakeResponse({"schema_version": 1, "data": {"ok": True}}),
            ]
            result, payload = _call("get_schema")
        self.assertFalse(result["isError"], payload)
        self.assertEqual(payload["kind"], "ok")
        self.assertEqual(mock_urlopen.call_count, 3, "read = initial attempt + 2 retries")

    def test_read_does_not_retry_4xx(self) -> None:
        with mock.patch.dict(os.environ, GATEWAY_ENV, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.side_effect = _http_error(
                404, {"error": "player not found", "code": "player_not_found"}
            )
            result, payload = _call("get_player_snapshot", {"citizenid": "ABC123"})
        self.assertTrue(result["isError"])
        self.assertEqual(payload["code"], "player_not_found")
        self.assertEqual(payload["kind"], "target_offline")
        self.assertIs(payload["retryable"], True)
        self.assertEqual(mock_urlopen.call_count, 1, "4xx responses must not be retried")


class WriteRoutingTests(RoutingTestBase):
    def test_write_posts_to_director_with_agent_id_and_explicit_key(self) -> None:
        env = dict(GATEWAY_ENV, AGENT_AGENT_ID="agent.7", **DIRECTOR_ENV)
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse(
                {"ok": True, "id": 42, "status": "executed", "preview": {}, "result": {}}
            )
            result, payload = _call(
                "send_notify",
                {"citizenid": "ABC123", "text": "hello", "idempotency_key": "caller-key-1"},
            )
        self.assertFalse(result["isError"])
        self.assertEqual(payload["kind"], "ok")
        self.assertEqual(payload["data"]["id"], 42)
        self.assertEqual(mock_urlopen.call_count, 1)
        request = _request(mock_urlopen)
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.full_url, "http://director.test/agent/v1/act")
        headers = _headers(request)
        self.assertEqual(headers["authorization"], "Bearer write-token")
        self.assertEqual(headers["x-agent-id"], "agent.7")
        body = _request_body(request)
        self.assertEqual(body["type"], "notify")
        self.assertEqual(body["idempotency_key"], "caller-key-1")
        self.assertIs(body["dry_run"], False)
        self.assertEqual(body["args"], {"citizenid": "ABC123", "text": "hello"})

    def test_write_derives_a_stable_key_and_honours_dry_run(self) -> None:
        env = dict(GATEWAY_ENV, AGENT_AGENT_ID="agent.7", **DIRECTOR_ENV)
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse({"ok": True, "id": 1, "status": "executed"})
            arguments = {"citizenid": "ABC123", "text": "hello"}
            _call("send_notify", arguments)
            _call("send_notify", arguments)
            _call("send_notify", arguments, dry_run=True)
            bodies = [_request_body(_request(mock_urlopen, index)) for index in range(3)]
        expected = agent_contract.derive_idempotency_key("send_notify", arguments, "agent.7")
        self.assertEqual(bodies[0]["idempotency_key"], expected)
        self.assertEqual(bodies[1]["idempotency_key"], expected, "same args must reuse the key")
        self.assertTrue(bodies[2]["idempotency_key"].endswith("/dry"))
        self.assertIs(bodies[2]["dry_run"], True)

    def test_dry_run_may_be_passed_as_an_argument(self) -> None:
        env = dict(GATEWAY_ENV, AGENT_AGENT_ID="agent.7", **DIRECTOR_ENV)
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse({"ok": True, "id": 1, "status": "approved"})
            result, payload = _call(
                "send_notify",
                {"citizenid": "ABC123", "text": "hello", "dry_run": True},
            )
        self.assertFalse(result["isError"], payload)
        body = _request_body(_request(mock_urlopen))
        self.assertIs(body["dry_run"], True)
        self.assertTrue(body["idempotency_key"].endswith("/dry"))

    def test_write_timeout_does_not_resend(self) -> None:
        env = dict(GATEWAY_ENV, **DIRECTOR_ENV)
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen, mock.patch("agent_mcp.time.sleep"):
            mock_urlopen.side_effect = urllib.error.URLError(socket.timeout("timed out"))
            result, payload = _call("send_notify", {"citizenid": "ABC123", "text": "hello"})
        self.assertTrue(result["isError"])
        self.assertEqual(payload["kind"], "timeout")
        self.assertEqual(payload["code"], "write_outcome_unknown")
        self.assertIs(payload["retryable"], False)
        self.assertEqual(mock_urlopen.call_count, 1, "a timed-out write must never be resent")

    def test_write_retries_once_on_connection_refused_with_same_key(self) -> None:
        env = dict(GATEWAY_ENV, **DIRECTOR_ENV)
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen, mock.patch("agent_mcp.time.sleep"):
            mock_urlopen.side_effect = [
                urllib.error.URLError(ConnectionRefusedError(111, "Connection refused")),
                FakeResponse({"ok": True, "id": 9, "status": "executed"}),
            ]
            result, payload = _call("send_notify", {"citizenid": "ABC123", "text": "hello"})
        self.assertFalse(result["isError"], payload)
        self.assertEqual(mock_urlopen.call_count, 2, "connection refused gets exactly one retry")
        first = _request_body(_request(mock_urlopen, 0))
        second = _request_body(_request(mock_urlopen, 1))
        self.assertEqual(first["idempotency_key"], second["idempotency_key"])

    def test_write_does_not_retry_on_503(self) -> None:
        env = dict(GATEWAY_ENV, **DIRECTOR_ENV)
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.side_effect = _http_error(
                503, {"error": "agent actions are disabled", "code": "disabled"}
            )
            result, payload = _call("send_notify", {"citizenid": "ABC123", "text": "hello"})
        self.assertTrue(result["isError"])
        self.assertEqual(payload["code"], "disabled")
        self.assertEqual(payload["kind"], "policy_denied")
        self.assertIs(payload["retryable"], False)
        self.assertEqual(mock_urlopen.call_count, 1, "director 503 must not be retried")

    def test_pending_approval_is_not_a_failure(self) -> None:
        env = dict(GATEWAY_ENV, **DIRECTOR_ENV)
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse(
                {
                    "ok": True,
                    "id": 7,
                    "status": "pending_approval",
                    "preview": {"risk": "L4"},
                    "expires_at": "2026-01-01 00:00:00",
                }
            )
            result, payload = _call(
                "add_player_money",
                {"citizenid": "ABC123", "account": "bank", "amount": 10, "reason": "gift"},
            )
        self.assertFalse(result["isError"])
        self.assertEqual(payload["kind"], "approval_required")
        self.assertIs(payload["ok"], True)
        self.assertEqual(payload["data"]["action_id"], 7)
        self.assertEqual(payload["data"]["status"], "pending_approval")

    def test_idempotent_replay_is_not_a_failure(self) -> None:
        env = dict(GATEWAY_ENV, **DIRECTOR_ENV)
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse(
                {"ok": True, "id": 7, "status": "executed", "idempotent": True}
            )
            result, payload = _call("send_notify", {"citizenid": "ABC123", "text": "hello"})
        self.assertFalse(result["isError"])
        self.assertEqual(payload["kind"], "idempotent_replay")

    def test_write_timeout_setting_is_forwarded(self) -> None:
        env = dict(GATEWAY_ENV, AGENT_MCP_WRITE_TIMEOUT_MS="5678", **DIRECTOR_ENV)
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse({"ok": True, "id": 1, "status": "executed"})
            _call("send_notify", {"citizenid": "ABC123", "text": "hello"})
        self.assertAlmostEqual(mock_urlopen.call_args.kwargs["timeout"], 5.678)


class CircuitBreakerTests(RoutingTestBase):
    def test_sixth_read_makes_no_network_request(self) -> None:
        with mock.patch.dict(os.environ, GATEWAY_ENV, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen, mock.patch("agent_mcp.time.sleep"):
            mock_urlopen.side_effect = urllib.error.URLError(
                ConnectionRefusedError(111, "Connection refused")
            )
            for attempt in range(5):
                result, payload = _call("get_schema")
                self.assertTrue(result["isError"], f"call {attempt} should fail")
            calls_after_five = mock_urlopen.call_count
            self.assertEqual(
                calls_after_five,
                15,
                "each failed read makes 3 transport attempts (initial + 2 retries)",
            )
            result, payload = _call("get_schema")
        self.assertTrue(result["isError"])
        self.assertEqual(payload["code"], "circuit_open")
        self.assertEqual(payload["kind"], "upstream_unavailable")
        self.assertIs(payload["retryable"], True)
        self.assertGreater(payload["meta"]["retry_after_ms"], 0)
        self.assertEqual(
            mock_urlopen.call_count,
            calls_after_five,
            "an open circuit must short-circuit before urlopen",
        )

    def test_circuit_is_per_route(self) -> None:
        env = dict(GATEWAY_ENV, **DIRECTOR_ENV)
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen, mock.patch("agent_mcp.time.sleep"):
            mock_urlopen.side_effect = urllib.error.URLError(
                ConnectionRefusedError(111, "Connection refused")
            )
            for _ in range(5):
                _call("get_schema")
            gateway_calls = mock_urlopen.call_count
            # The director circuit is independent, so the write still hits the wire.
            _call("send_notify", {"citizenid": "ABC123", "text": "hello"})
        self.assertGreater(
            mock_urlopen.call_count,
            gateway_calls,
            "opening the gateway circuit must not disable the director route",
        )


class VisibilityTests(RoutingTestBase):
    def test_missing_director_token_hides_writes(self) -> None:
        with mock.patch.dict(os.environ, GATEWAY_ENV, clear=True):
            names = {tool["name"] for tool in _tools()}
        self.assertIn("get_schema", names)
        for hidden in ("send_notify", "add_player_money", "start_player_quest", "get_action", "list_actions"):
            self.assertNotIn(hidden, names, f"{hidden} must not be advertised without its token")

    def test_missing_gateway_token_hides_reads(self) -> None:
        with mock.patch.dict(
            os.environ, {"AGENT_GATEWAY_URL": "http://gateway.test"}, clear=True
        ):
            self.assertEqual(_tools(), [], "a partially configured gateway must advertise nothing")

    def test_toolset_all_lists_every_active_tool(self) -> None:
        env = {
            "AGENT_DIRECTOR_URL": "http://director.test",
            "AGENT_DIRECTOR_TOKEN": "x",
            "AGENT_LIVE_TOKEN": "y",
            "AGENT_TOOLSET": "all",
        }
        with mock.patch.dict(os.environ, env, clear=True):
            names = {tool["name"] for tool in _tools()}
        self.assertEqual(len(names), 42, "AGENT_TOOLSET=all lists the 42 non-harness active tools")
        self.assertIn("add_player_money", names, "debug mode lists writes but calls still need a token")

    def test_live_tools_need_the_live_token_to_be_advertised(self) -> None:
        env = dict(GATEWAY_ENV, AGENT_DIRECTOR_URL="http://director.test")
        with mock.patch.dict(os.environ, env, clear=True):
            names = {tool["name"] for tool in _tools()}
        self.assertIn("get_schema", names)
        for hidden in ("get_live_players", "get_live_player", "list_live_events"):
            self.assertNotIn(
                hidden, names, f"{hidden} must not be advertised without a live token"
            )

    def test_live_token_advertises_the_live_tools(self) -> None:
        with mock.patch.dict(os.environ, LIVE_ENV, clear=True):
            names = {tool["name"] for tool in _tools()}
        self.assertTrue(
            {"get_live_players", "get_live_player", "list_live_events"} <= names,
            "a configured live token must publish the live reads",
        )

    def test_debug_toolset_still_hides_live_tools_without_a_token(self) -> None:
        with mock.patch.dict(os.environ, {"AGENT_TOOLSET": "all"}, clear=True):
            names = {tool["name"] for tool in _tools()}
        self.assertIn("send_notify", names, "all lists every non-live active tool")
        for hidden in ("get_live_players", "get_live_player", "list_live_events"):
            self.assertNotIn(hidden, names, "the live grant is never implied by AGENT_TOOLSET=all")

    def test_director_token_alone_does_not_advertise_live_tools(self) -> None:
        # The live channel has its own credential. Falling back to the write
        # token would mean a single-token deployment silently equates "can
        # read" with "can spend", which is exactly what auth=live prevents.
        with mock.patch.dict(os.environ, DIRECTOR_ENV, clear=True):
            names = {tool["name"] for tool in _tools()}
        for hidden in ("get_live_players", "get_live_player", "list_live_events"):
            self.assertNotIn(hidden, names)
        self.assertIn("send_notify", names, "the write tools must still be visible")

    def test_live_token_alone_disables_the_local_fallback(self) -> None:
        # The live credential is a remote channel grant. If it were ignored,
        # a "read-only" agent holding only AGENT_LIVE_TOKEN would silently fall
        # back to unauthenticated local DB reads (the opposite of least data).
        with mock.patch.dict(os.environ, {"AGENT_LIVE_TOKEN": "LIVE-ONLY"}, clear=True):
            self.assertFalse(agent_mcp._standalone_mode())
            self.assertEqual(_tools(), [], "no channel is configured, so nothing is advertised")

    def test_toolset_read_filters_by_channel(self) -> None:
        with mock.patch.dict(
            os.environ, dict(GATEWAY_ENV, AGENT_TOOLSET="read"), clear=True
        ):
            tools = _tools()
        self.assertTrue(tools)
        for tool in tools:
            self.assertEqual(tool["_meta"]["t-city/channel"], "read", tool["name"])
        with mock.patch.dict(
            os.environ, dict(GATEWAY_ENV, **DIRECTOR_ENV, AGENT_TOOLSET="read"), clear=True
        ):
            names = {tool["name"] for tool in _tools()}
        self.assertIn("get_action", names)
        self.assertIn("list_actions", names)
        self.assertNotIn("send_notify", names)

    def test_all_registry_tools_are_advertised(self) -> None:
        with mock.patch.dict(os.environ, dict(GATEWAY_ENV, **DIRECTOR_ENV), clear=True):
            names = {tool["name"] for tool in _tools()}
        self.assertIn("spawn_vehicle", names, "the last planned tool is now active")

    def test_tool_descriptors_carry_annotations_and_meta(self) -> None:
        with mock.patch.dict(os.environ, dict(GATEWAY_ENV, **DIRECTOR_ENV), clear=True):
            tools = {tool["name"]: tool for tool in _tools()}
        notify = tools["send_notify"]
        self.assertEqual(
            notify["annotations"],
            {
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            },
        )
        self.assertEqual(notify["_meta"]["t-city/risk"], "L1")
        money = tools["add_player_money"]
        self.assertTrue(money["annotations"]["destructiveHint"])
        self.assertTrue(money["_meta"]["t-city/requiresApproval"])
        self.assertEqual(money["_meta"]["t-city/verify"], "get_player_snapshot")


class ProtocolAndValidationTests(RoutingTestBase):
    def test_unknown_tools_remain_jsonrpc_errors(self) -> None:
        with mock.patch.dict(os.environ, GATEWAY_ENV, clear=True):
            for name in ("not_a_tool", "delete_player"):
                response = agent_mcp.handle_message(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "tools/call",
                        "params": {"name": name, "arguments": {}},
                    }
                )
                self.assertEqual(response["error"]["code"], -32602, name)

    def test_invalid_arguments_fail_before_any_network_call(self) -> None:
        with mock.patch.dict(os.environ, dict(GATEWAY_ENV, **DIRECTOR_ENV), clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            result, payload = _call(
                "send_notify", {"citizenid": "ABC123", "text": "hello", "unexpected": 1}
            )
        self.assertTrue(result["isError"])
        self.assertEqual(payload["code"], "bad_request")
        self.assertEqual(payload["kind"], "invalid_argument")
        self.assertEqual(mock_urlopen.call_count, 0, "validation must happen before routing")

    def test_hidden_write_cannot_be_called(self) -> None:
        with mock.patch.dict(os.environ, GATEWAY_ENV, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            result, payload = _call("send_notify", {"citizenid": "ABC123", "text": "hello"})
        self.assertTrue(result["isError"])
        self.assertEqual(payload["code"], "unauthorized")
        self.assertEqual(mock_urlopen.call_count, 0)

    def test_hidden_live_tool_cannot_be_called(self) -> None:
        env = dict(GATEWAY_ENV, AGENT_DIRECTOR_URL="http://director.test")
        with mock.patch.dict(os.environ, env, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            result, payload = _call("get_live_players", {})
        self.assertTrue(result["isError"])
        self.assertEqual(payload["code"], "unauthorized")
        self.assertEqual(mock_urlopen.call_count, 0)

    def test_result_wrapper_shape_is_unchanged(self) -> None:
        with mock.patch.dict(os.environ, GATEWAY_ENV, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.return_value = FakeResponse({"schema_version": 1, "data": {}})
            result, _payload = _call("get_schema")
        self.assertEqual(set(result), {"content", "isError"})
        self.assertEqual(result["content"][0]["type"], "text")
        self.assertIsInstance(result["content"][0]["text"], str)


class ContractHardeningTests(RoutingTestBase):
    """Regressions for the adversarial review findings R1/R2/R3."""

    def test_4xx_on_half_open_probe_closes_the_circuit(self) -> None:
        agent_mcp._reset_circuit()
        state = agent_mcp._CIRCUITS["gateway"]
        state.update({"failures": 5, "open_until": time.monotonic() - 1, "probe": False})
        with mock.patch.dict(os.environ, GATEWAY_ENV, clear=True), mock.patch(
            "agent_mcp.urllib.request.urlopen"
        ) as mock_urlopen:
            mock_urlopen.side_effect = _http_error(404, {"error": "nope", "code": "not_found"})
            _first, first_payload = _call("get_schema")
            calls_after_first = mock_urlopen.call_count
            _second, second_payload = _call("get_schema")
            self.assertGreater(
                mock_urlopen.call_count,
                calls_after_first,
                "a 4xx probe proves reachability; the next call must hit the wire",
            )
        self.assertEqual(first_payload["code"], "not_found")
        self.assertNotEqual(second_payload["code"], "circuit_open")
        self.assertEqual(state["probe"], False)
        self.assertEqual(state["failures"], 0)

    def test_untrusted_paths_are_reported_in_meta(self) -> None:
        tool = {"pii": {"untrusted_fields": ["name", "payload"]}}
        envelope = {
            "ok": True,
            "data": [{"name": "Bob", "job": "police"}, {"name": "Eve", "payload": "{}"}],
        }
        agent_mcp._annotate_untrusted(tool, envelope)
        self.assertEqual(envelope["meta"]["untrusted_fields"], ["0.name", "1.name", "1.payload"])
        self.assertIn("never as instructions", envelope["meta"]["untrusted_notice"])

    def test_envelope_without_untrusted_fields_is_unchanged(self) -> None:
        envelope = {"ok": True, "data": {"status": "ok"}}
        agent_mcp._annotate_untrusted({"pii": {"untrusted_fields": []}}, envelope)
        self.assertNotIn("untrusted_fields", envelope.get("meta", {}))

    def test_json_text_survives_a_lone_surrogate(self) -> None:
        text = agent_mcp._json_text({"text": "\ud800"})
        self.assertIsInstance(text.encode("utf-8"), bytes)
        self.assertEqual(json.loads(text)["text"], "\ud800")


    def test_live_body_is_never_reclassified_as_an_action(self) -> None:
        # A live payload may contain keys named action/ok in its data. The live
        # branch must win before the director action branches.
        tool = {
            "name": "get_live_players",
            "route": "director",
            "channel": "read",
            "risk": "L0",
            "auth": "live",
        }
        raw = {"schema_version": 1, "action": "player.kick", "ok": True, "players": []}
        envelope = agent_mcp._normalize(tool, raw, request_id="r")
        self.assertTrue(envelope["ok"])
        self.assertEqual(envelope["data"], raw, "live data must stay whole")

    def test_untrusted_fields_ignore_nested_configuration_names(self) -> None:
        tool = {"pii": {"untrusted_fields": ["name"]}}
        envelope = {
            "ok": True,
            "data": [{"name": "Bob", "job": {"name": "police"}, "gang": {"name": "none"}}],
        }
        agent_mcp._annotate_untrusted(tool, envelope)
        self.assertEqual(envelope["meta"]["untrusted_fields"], ["0.name"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
