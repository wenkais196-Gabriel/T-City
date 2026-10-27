#!/usr/bin/env python3
"""Tests for the live-runtime smoke CLI (``tools/agent_smoke.py``).

``urllib.request.urlopen`` is stubbed for every test: nothing here touches the
network, a database or a running FXServer.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import unittest
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_DIR = REPO_ROOT / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import agent_smoke  # noqa: E402

GATEWAY_ENV = {
    "AGENT_GATEWAY_URL": "http://gateway.test",
    "AGENT_GATEWAY_TOKEN": "gateway-token-secret",
}
DIRECTOR_ENV = {
    "AGENT_DIRECTOR_URL": "http://director.test/custom-director",
    "AGENT_DIRECTOR_TOKEN": "director-token-secret",
}
LIVE_ENV = {"AGENT_LIVE_TOKEN": "live-token-secret"}
ALL_ENV = {
    **GATEWAY_ENV,
    **DIRECTOR_ENV,
    **LIVE_ENV,
    "AGENT_AGENT_ID": "smoke.test",
}
WRITE_ENV = {**ALL_ENV, "AGENT_SMOKE_CITIZENID": "ABC12345"}
APPROVE_ENV = {**WRITE_ENV, "AGENT_ADMIN_TOKEN": "admin-token-secret"}


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


@dataclass
class Call:
    method: str
    path: str
    raw_path: str
    query: dict[str, list[str]]
    headers: dict[str, str]
    body: object


class FakeServer:
    """Tiny path router standing in for a running FXServer.

    The director base URL in these tests includes ``/custom-director`` (the
    production shape), so routes are matched after stripping that prefix.
    """

    def __init__(self, prefix: str = "/custom-director") -> None:
        self.prefix = prefix
        self.routes: dict[tuple[str, str], object] = {}
        self.calls: list[Call] = []

    def json(self, method: str, path: str, payload: dict, status: int = 200) -> "FakeServer":
        def handler(request: object, body: object) -> FakeResponse:
            if status >= 400:
                raise _http_error(status, payload)
            return FakeResponse(payload, status)

        self.routes[(method.upper(), path)] = handler
        return self

    def handler(self, method: str, path: str, fn: object) -> "FakeServer":
        self.routes[(method.upper(), path)] = fn
        return self

    def __call__(self, request: urllib.request.Request, timeout: float | None = None) -> FakeResponse:
        parsed = urllib.parse.urlsplit(request.full_url)
        raw_path = parsed.path
        path = raw_path
        if self.prefix and path.startswith(self.prefix):
            path = path[len(self.prefix):]
        raw_body = request.data
        body = json.loads(raw_body.decode("utf-8")) if raw_body else None
        headers = {key.lower(): value for key, value in request.headers.items()}
        self.calls.append(
            Call(
                method=request.get_method(),
                path=path,
                raw_path=raw_path,
                query=urllib.parse.parse_qs(parsed.query),
                headers=headers,
                body=body,
            )
        )
        handler = self.routes.get((request.get_method(), path))
        if handler is None:
            raise AssertionError(f"unexpected request {request.get_method()} {raw_path}")
        return handler(request, body)  # type: ignore[operator]

    def calls_for(self, method: str, path: str | None = None) -> list[Call]:
        return [
            call
            for call in self.calls
            if call.method == method.upper() and (path is None or call.path == path)
        ]


def _happy_server(*, flow: str = "executed") -> FakeServer:
    server = FakeServer()
    server.json(
        "GET",
        "/agent/v1/health",
        {"schema_version": 1, "data": {"status": "ok", "database": {"reachable": True}}},
    )
    server.json("GET", "/agent/v1/schema", {"schema_version": 1, "data": {"views": {}}})
    server.json("GET", "/agent/v1/policy", {"schema_version": 1, "actions": []})
    server.json("GET", "/agent/v1/actions", {"actions": [{"id": 1}], "count": 1})
    server.json(
        "GET",
        "/agent/v1/live/players",
        {"schema_version": 1, "players": [], "count": 0},
    )

    def act(request: object, body: dict) -> FakeResponse:
        if body.get("dry_run") is True:
            return FakeResponse({"ok": True, "id": 10, "status": "proposed", "dry_run": True})
        if flow == "pending_202":
            return FakeResponse(
                {"ok": True, "id": 7, "status": "pending_approval"}, status=202
            )
        if flow == "pending":
            return FakeResponse({"ok": True, "id": 7, "status": "pending_approval"})
        return FakeResponse({"ok": True, "id": 42, "status": "executed"})

    server.handler("POST", "/agent/v1/act", act)
    server.json("GET", "/agent/v1/actions/42", {"action": {"id": 42, "status": "executed"}})
    server.json(
        "GET",
        "/agent/v1/actions/7",
        {"action": {"id": 7, "status": "pending_approval"}},
    )
    server.json(
        "POST",
        "/agent/v1/actions/7/approve",
        {"ok": True, "id": 7, "status": "approved"},
    )
    return server


class SmokeTestBase(unittest.TestCase):
    def _run(
        self,
        server: object,
        argv: tuple[str, ...] = ("--json",),
        env: dict[str, str] | None = None,
    ) -> tuple[int, str, str]:
        with mock.patch.dict(os.environ, env or {}, clear=True), mock.patch(
            "agent_smoke.urllib.request.urlopen", side_effect=server
        ):
            out = io.StringIO()
            err = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = agent_smoke.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def _report(self, server: object, argv: tuple[str, ...], env: dict[str, str]) -> dict:
        code, out, _err = self._run(server, argv, env)
        self.assertEqual(code, 0, out)
        return json.loads(out)

    def _check(self, report: dict, name: str) -> dict:
        matches = [check for check in report["checks"] if check["name"] == name]
        self.assertEqual(len(matches), 1, name)
        return matches[0]


class ReadOnlyTests(SmokeTestBase):
    def test_read_only_all_endpoints_pass(self) -> None:
        server = _happy_server()
        report = self._report(server, ("--json",), ALL_ENV)
        self.assertEqual(
            [check["name"] for check in report["checks"]],
            list(agent_smoke.CHECK_NAMES),
        )
        read_checks = (
            "gateway_health",
            "gateway_schema",
            "director_policy",
            "director_list_actions",
            "live_players",
            "notify_dry_run",
        )
        for name in read_checks:
            self.assertEqual(self._check(report, name)["status"], "pass", name)
        for name in ("notify_propose", "notify_get", "notify_approve", "cleanup"):
            self.assertEqual(self._check(report, name)["status"], "skip", name)
        self.assertEqual(report["summary"], {"pass": 6, "fail": 0, "skip": 7})

    def test_json_report_shape_and_timing(self) -> None:
        report = self._report(_happy_server(), ("--json",), ALL_ENV)
        self.assertTrue(report["run_id"])
        self.assertTrue(report["started_at"])
        self.assertEqual(set(report["checks"][0]), {"name", "status", "detail", "http_status", "elapsed_ms"})
        self.assertIs(report["read_only"], True)
        self.assertIs(report["allow_write"], False)
        self.assertEqual(sum(report["summary"].values()), len(report["checks"]))
        for check in report["checks"]:
            self.assertIn(check["status"], ("pass", "fail", "skip"))
            self.assertGreaterEqual(check["elapsed_ms"], 0)
            if check["status"] == "pass":
                self.assertEqual(check["http_status"], 200)

    def test_no_environment_variables_means_all_skipped(self) -> None:
        server = FakeServer()
        code, out, _err = self._run(server, ("--json",), {})
        self.assertEqual(code, 0)
        report = json.loads(out)
        self.assertEqual(server.calls, [], "no request may be sent without configuration")
        self.assertEqual(report["summary"], {"pass": 0, "fail": 0, "skip": 13})
        self.assertTrue(all(check["status"] == "skip" for check in report["checks"]))

    def test_health_500_fails_with_exit_1(self) -> None:
        server = _happy_server()
        server.json(
            "GET",
            "/agent/v1/health",
            {"error": "db down", "code": "database_unavailable"},
            status=500,
        )
        code, out, _err = self._run(server, ("--json",), ALL_ENV)
        self.assertEqual(code, 1)
        report = json.loads(out)
        health = self._check(report, "gateway_health")
        self.assertEqual(health["status"], "fail")
        self.assertEqual(health["http_status"], 500)
        self.assertIn("database_unavailable", health["detail"])

    def test_missing_gateway_token_skips_only_gateway_checks(self) -> None:
        server = _happy_server()
        env = {**DIRECTOR_ENV, **LIVE_ENV}
        code, out, _err = self._run(server, ("--json",), env)
        self.assertEqual(code, 0)
        report = json.loads(out)
        for name in ("gateway_health", "gateway_schema"):
            check = self._check(report, name)
            self.assertEqual(check["status"], "skip")
            self.assertIn("AGENT_GATEWAY_TOKEN", check["detail"])
        self.assertEqual(self._check(report, "director_policy")["status"], "pass")
        self.assertEqual(self._check(report, "live_players")["status"], "pass")
        self.assertEqual(server.calls_for("GET", "/agent/v1/health"), [])
        self.assertEqual(server.calls_for("GET", "/agent/v1/schema"), [])

    def test_live_503_disabled_is_a_failure_with_code(self) -> None:
        server = _happy_server()
        server.json(
            "GET",
            "/agent/v1/live/players",
            {"error": "live perception is disabled", "code": "live_disabled"},
            status=503,
        )
        code, out, _err = self._run(server, ("--json",), ALL_ENV)
        self.assertEqual(code, 1)
        check = self._check(json.loads(out), "live_players")
        self.assertEqual(check["status"], "fail")
        self.assertEqual(check["http_status"], 503)
        self.assertIn("live_disabled", check["detail"])
        self.assertIn("agent_live_enabled", check["detail"])

    def test_live_401_is_a_failure_with_unauthorized_code(self) -> None:
        server = _happy_server()
        server.json(
            "GET",
            "/agent/v1/live/players",
            {"error": "unauthorized", "code": "unauthorized"},
            status=401,
        )
        code, out, _err = self._run(server, ("--json",), ALL_ENV)
        self.assertEqual(code, 1)
        check = self._check(json.loads(out), "live_players")
        self.assertEqual(check["status"], "fail")
        self.assertEqual(check["http_status"], 401)
        self.assertIn("unauthorized", check["detail"])
        self.assertIn("AGENT_LIVE_TOKEN", check["detail"])

    def test_health_accepts_a_flat_status_field(self) -> None:
        server = _happy_server()
        server.json("GET", "/agent/v1/health", {"status": "degraded"})
        report = self._report(server, ("--json",), ALL_ENV)
        self.assertEqual(self._check(report, "gateway_health")["status"], "pass")
        self.assertIn("degraded", self._check(report, "gateway_health")["detail"])

    def test_transport_error_becomes_fail_not_traceback(self) -> None:
        def refused(request: object, timeout: float | None = None) -> FakeResponse:
            raise urllib.error.URLError(ConnectionRefusedError(111, "Connection refused"))

        code, out, err = self._run(refused, ("--json",), ALL_ENV)
        self.assertEqual(code, 1)
        report = json.loads(out)
        health = self._check(report, "gateway_health")
        self.assertEqual(health["status"], "fail")
        self.assertIsNone(health["http_status"])
        self.assertIn("transport error", health["detail"])
        self.assertNotIn("Traceback", err)


class DryRunAndWriteTests(SmokeTestBase):
    def test_default_never_sends_a_non_dry_run_request(self) -> None:
        server = _happy_server()
        self._report(server, ("--json",), WRITE_ENV)
        act_calls = server.calls_for("POST", "/agent/v1/act")
        self.assertEqual(len(act_calls), 1)
        self.assertIs(act_calls[0].body["dry_run"], True)
        self.assertTrue(act_calls[0].body["idempotency_key"].startswith("smoke:dry:"))
        self.assertEqual(server.calls_for("POST", "/agent/v1/actions/42/approve"), [])

    def test_dry_run_body_and_headers(self) -> None:
        server = _happy_server()
        self._report(server, ("--json",), ALL_ENV)
        call = server.calls_for("POST", "/agent/v1/act")[0]
        self.assertIs(call.body["dry_run"], True)
        self.assertEqual(call.body["type"], "notify")
        self.assertEqual(call.body["args"], {"citizenid": "SMOKE0001", "text": "agent smoke"})
        self.assertTrue(call.body["idempotency_key"].startswith("smoke:dry:"))
        self.assertEqual(call.headers["authorization"], "Bearer director-token-secret")
        self.assertEqual(call.headers["x-agent-id"], "smoke.test")
        self.assertEqual(
            call.headers["content-type"],
            "application/json",
        )

    def test_allow_write_proposes_and_reads_the_action_back(self) -> None:
        server = _happy_server()
        report = self._report(server, ("--allow-write", "--json"), WRITE_ENV)
        self.assertEqual(self._check(report, "notify_propose")["status"], "pass")
        self.assertEqual(self._check(report, "notify_get")["status"], "pass")
        self.assertEqual(self._check(report, "notify_approve")["status"], "skip")

        propose = [
            call
            for call in server.calls_for("POST", "/agent/v1/act")
            if call.body.get("dry_run") is not True
        ]
        self.assertEqual(len(propose), 1)
        self.assertNotIn("dry_run", propose[0].body)
        self.assertTrue(propose[0].body["idempotency_key"].startswith("smoke:propose:"))
        self.assertEqual(propose[0].body["args"]["citizenid"], "ABC12345")

        get_calls = server.calls_for("GET")
        action_reads = [call for call in get_calls if call.path == "/agent/v1/actions/42"]
        self.assertEqual(len(action_reads), 1)
        self.assertEqual(action_reads[0].headers["x-agent-id"], "smoke.test")

    def test_allow_write_without_citizenid_skips_the_proposal(self) -> None:
        server = _happy_server()
        report = self._report(server, ("--allow-write", "--json"), ALL_ENV)
        propose = self._check(report, "notify_propose")
        self.assertEqual(propose["status"], "skip")
        self.assertIn("AGENT_SMOKE_CITIZENID", propose["detail"])
        self.assertEqual(self._check(report, "notify_get")["status"], "skip")
        self.assertEqual(len(server.calls_for("POST", "/agent/v1/act")), 1, "only the dry run may fire")

    def test_allow_approve_implies_write_and_calls_approve(self) -> None:
        server = _happy_server(flow="pending")
        code, out, _err = self._run(server, ("--allow-approve", "--json"), APPROVE_ENV)
        self.assertEqual(code, 0, out)
        report = json.loads(out)
        self.assertIs(report["allow_write"], True, "--allow-approve implies --allow-write")
        self.assertEqual(self._check(report, "notify_propose")["status"], "pass")
        self.assertEqual(self._check(report, "notify_approve")["status"], "pass")

        approve_calls = server.calls_for("POST", "/agent/v1/actions/7/approve")
        self.assertEqual(len(approve_calls), 1)
        self.assertEqual(approve_calls[0].body, {"approver": "smoke"})
        self.assertEqual(approve_calls[0].headers["authorization"], "Bearer admin-token-secret")

    def test_approve_is_not_called_without_allow_approve(self) -> None:
        server = _happy_server()
        self._report(server, ("--allow-write", "--json"), APPROVE_ENV)
        self.assertEqual(server.calls_for("POST", "/agent/v1/actions/42/approve"), [])

    def test_approve_on_an_already_executed_notify_is_a_skip(self) -> None:
        server = _happy_server(flow="executed")
        server.json(
            "POST",
            "/agent/v1/actions/42/approve",
            {"error": "invalid status", "code": "invalid_status"},
            status=409,
        )
        code, out, _err = self._run(server, ("--allow-approve", "--json"), APPROVE_ENV)
        self.assertEqual(code, 0, out)
        check = self._check(json.loads(out), "notify_approve")
        self.assertEqual(check["status"], "skip")
        self.assertIn("invalid_status", check["detail"])

    def test_unexpected_action_status_fails(self) -> None:
        server = _happy_server()
        server.json("GET", "/agent/v1/actions/42", {"action": {"id": 42, "status": "gone"}})
        code, out, _err = self._run(server, ("--allow-write", "--json"), WRITE_ENV)
        self.assertEqual(code, 1)
        check = self._check(json.loads(out), "notify_get")
        self.assertEqual(check["status"], "fail")
        self.assertIn("gone", check["detail"])

    def test_propose_202_pending_approval_is_accepted(self) -> None:
        server = _happy_server(flow="pending_202")
        report = self._report(server, ("--allow-write", "--json"), WRITE_ENV)
        propose = self._check(report, "notify_propose")
        self.assertEqual(propose["status"], "pass")
        self.assertIn("202", propose["detail"])
        self.assertIn("pending_approval", propose["detail"])
        self.assertEqual(self._check(report, "notify_get")["status"], "pass")


class ReportingAndSafetyTests(SmokeTestBase):
    def test_tokens_are_never_printed(self) -> None:
        tokens = ["gateway-token-secret", "director-token-secret", "live-token-secret"]
        server = _happy_server()
        server.json("GET", "/agent/v1/health", {"error": "denied", "code": "unauthorized"}, status=401)
        server.json("GET", "/agent/v1/actions", {"error": "denied", "code": "unauthorized"}, status=401)
        code, out, err = self._run(server, (), ALL_ENV)
        self.assertEqual(code, 1)
        combined = out + err
        for token in tokens:
            self.assertNotIn(token, combined)
        self.assertIn("summary:", out)

    def test_human_output_is_a_table(self) -> None:
        code, out, _err = self._run(_happy_server(), (), ALL_ENV)
        self.assertEqual(code, 0)
        self.assertIn("STATUS", out)
        self.assertIn("gateway_health", out)
        self.assertIn("summary: 6 pass, 0 fail, 7 skip", out)

    def test_invalid_timeout_exits_2(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                agent_smoke.main(["--timeout-ms", "0"])
        self.assertEqual(caught.exception.code, 2)

    def test_unknown_argument_exits_2(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                agent_smoke.main(["--nope"])
        self.assertEqual(caught.exception.code, 2)

    def test_read_only_conflicts_with_write_flags(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                agent_smoke.main(["--read-only", "--allow-write"])
        self.assertEqual(caught.exception.code, 2)

    def test_timeout_is_forwarded_per_request(self) -> None:
        server = _happy_server()
        with mock.patch.dict(os.environ, ALL_ENV, clear=True), mock.patch(
            "agent_smoke.urllib.request.urlopen", side_effect=server
        ) as urlopen:
            agent_smoke.main(["--json", "--timeout-ms", "1234"])
        self.assertAlmostEqual(urlopen.call_args.kwargs["timeout"], 1.234)


if __name__ == "__main__":
    unittest.main(verbosity=2)


class HarnessTests(SmokeTestBase):
    """``--harness``: console assertions on top of the HTTP probes (design 07)."""

    def setUp(self) -> None:
        import tempfile
        import threading  # noqa: F401  (used by individual tests)

        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.server_log = self.root / "fxserver.log"
        self.server_log.write_text("[  script:dev] booted\n", encoding="utf-8")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _no_http(self, *args, **kwargs):  # pragma: no cover - must not be called
        raise AssertionError("harness-only runs must not touch the network")

    def _checks(self, report: dict, name: str) -> list[dict]:
        return [check for check in report["checks"] if check["name"] == name]

    def test_harness_checks_skip_without_the_flag(self) -> None:
        code, out, _err = self._run(self._no_http, ("--json",), {})
        self.assertEqual(code, 0, out)
        report = json.loads(out)
        for name in ("harness_server", "harness_client", "harness_expect"):
            self.assertEqual(self._check(report, name)["status"], "skip")

    def test_server_log_is_reported_as_pass(self) -> None:
        env = {"TCITY_HARNESS_SERVER_LOG": str(self.server_log)}
        code, out, _err = self._run(self._no_http, ("--json", "--harness"), env)
        self.assertEqual(code, 0, out)
        report = json.loads(out)
        server = self._check(report, "harness_server")
        self.assertEqual(server["status"], "pass")
        self.assertIn("fxserver.log", server["detail"])
        # The client log is not configured on this run, so it is a skip.
        self.assertEqual(self._check(report, "harness_client")["status"], "skip")

    def test_configured_but_missing_server_log_fails(self) -> None:
        env = {"TCITY_HARNESS_SERVER_LOG": str(self.root / "nope.log")}
        code, out, _err = self._run(self._no_http, ("--json", "--harness"), env)
        self.assertEqual(code, 1, out)
        report = json.loads(out)
        check = self._check(report, "harness_server")
        self.assertEqual(check["status"], "fail")
        self.assertIn("not found", check["detail"])

    def test_expect_matches_a_line_printed_after_the_wait_starts(self) -> None:
        import threading

        def append() -> None:
            with self.server_log.open("a", encoding="utf-8") as handle:
                handle.write("[  script:dev] smoke target settled\n")

        env = {"TCITY_HARNESS_SERVER_LOG": str(self.server_log)}
        timer = threading.Timer(0.3, append)
        timer.start()
        try:
            code, out, _err = self._run(
                self._no_http,
                ("--json", "--harness", "--expect-server", "smoke target settled",
                 "--harness-timeout-ms", "5000"),
                env,
            )
        finally:
            timer.cancel()
        self.assertEqual(code, 0, out)
        report = json.loads(out)
        check = self._check(report, "harness_expect_server")
        self.assertEqual(check["status"], "pass")
        self.assertIn("smoke target settled", check["detail"])

    def test_expect_timeout_is_a_failure(self) -> None:
        env = {"TCITY_HARNESS_SERVER_LOG": str(self.server_log)}
        code, out, _err = self._run(
            self._no_http,
            ("--json", "--harness", "--expect-server", "never-printed",
             "--harness-timeout-ms", "500"),
            env,
        )
        self.assertEqual(code, 1, out)
        report = json.loads(out)
        check = self._check(report, "harness_expect_server")
        self.assertEqual(check["status"], "fail")
        self.assertIn("no server console line matched", check["detail"])

    def test_expect_without_harness_is_a_usage_error(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                agent_smoke.main(["--expect-server", "x"])
        self.assertEqual(raised.exception.code, 2)
