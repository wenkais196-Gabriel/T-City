#!/usr/bin/env python3
"""Live-runtime smoke checks for the T-City agent surfaces.

This is the bridge between the offline golden/stub suite and a real FXServer:
it performs a small, ordered set of HTTP probes against the gateway, the
director action API and the live-perception API, and reports one result per
probe.  It never touches the database and never imports a third-party package.

Safety defaults:

* read-only: no ``POST /agent/v1/act`` is sent unless ``--allow-write`` is set;
* dry-run: the one write probe that is always available (``notify``) carries
  ``"dry_run": true``;
* ``--allow-approve`` implies ``--allow-write`` and is the only way to call the
  admin approve endpoint;
* tokens are read from the environment but never printed; diagnostics only
  name a missing variable, never its value.

Environment (all optional; a check whose variables are missing is skipped):

    AGENT_GATEWAY_URL / AGENT_GATEWAY_TOKEN    read-only gateway
    AGENT_DIRECTOR_URL / AGENT_DIRECTOR_TOKEN  custom-director action API
    AGENT_LIVE_TOKEN                           /agent/v1/live/* credential
    AGENT_ADMIN_TOKEN                          optional approve credential
    AGENT_AGENT_ID                             default "smoke.local"
    AGENT_SMOKE_CITIZENID                      online player for write probes

Usage:

    python3 tools/agent_smoke.py                 # read-only, dry-run probe
    python3 tools/agent_smoke.py --allow-write   # + notify proposal
    python3 tools/agent_smoke.py --allow-approve # + approve (needs admin token)
    python3 tools/agent_smoke.py --json          # machine-readable report

Exit codes: 0 = every check passed or was skipped, 1 = at least one failed,
2 = invalid arguments.
"""

from __future__ import annotations

import argparse
import datetime as dt
import http.client
import json
import os
import secrets
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

DEFAULT_TIMEOUT_MS = 5000
DEFAULT_AGENT_ID = "smoke.local"
DEFAULT_CITIZENID = "SMOKE0001"
SMOKE_KEY_PREFIX = "smoke:"
READ_ONLY_REASON = "--allow-write not set (read-only default)"
HEALTH_STATES = ("ok", "degraded")
ACTION_STATUSES = ("proposed", "pending_approval", "approved", "executed")
ENV_VARS = (
    "AGENT_GATEWAY_URL",
    "AGENT_GATEWAY_TOKEN",
    "AGENT_DIRECTOR_URL",
    "AGENT_DIRECTOR_TOKEN",
    "AGENT_LIVE_TOKEN",
    "AGENT_ADMIN_TOKEN",
    "AGENT_AGENT_ID",
    "AGENT_SMOKE_CITIZENID",
)
TOKEN_VARS = (
    "AGENT_GATEWAY_TOKEN",
    "AGENT_DIRECTOR_TOKEN",
    "AGENT_LIVE_TOKEN",
    "AGENT_ADMIN_TOKEN",
)
CHECK_NAMES = (
    "gateway_health",
    "gateway_schema",
    "director_policy",
    "director_list_actions",
    "live_players",
    "notify_dry_run",
    "notify_propose",
    "notify_get",
    "notify_approve",
    "cleanup",
)


@dataclass(frozen=True)
class HttpResult:
    """One HTTP attempt.  ``error`` is set only for transport failures."""

    status: int | None
    body: dict[str, Any] | None
    error: str | None
    elapsed_ms: int


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
def http_request(
    method: str,
    url: str,
    *,
    token: str = "",
    agent_id: str = "",
    payload: dict[str, Any] | None = None,
    timeout_ms: int = DEFAULT_TIMEOUT_MS,
) -> HttpResult:
    """Perform one JSON request and turn every transport error into data.

    The caller decides whether a status/body is acceptable.  ``HTTPError`` is a
    normal response here (it carries the JSON error body); only connection,
    timeout and parsing-level problems set ``error``.
    """
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if agent_id:
        headers["X-Agent-Id"] = agent_id

    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    started = time.monotonic()
    status: int | None = None
    raw = b""
    error: str | None = None
    try:
        with urllib.request.urlopen(request, timeout=timeout_ms / 1000.0) as response:
            status = int(response.status)
            raw = response.read()
    except urllib.error.HTTPError as exc:
        status = int(exc.code)
        try:
            raw = exc.read()
        except OSError:
            raw = b""
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as exc:
        error = f"{type(exc).__name__}: {exc}"
    elapsed_ms = int(round((time.monotonic() - started) * 1000))

    body: dict[str, Any] | None = None
    if error is None and raw:
        try:
            decoded = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            decoded = None
        if isinstance(decoded, dict):
            body = decoded
    return HttpResult(status=status, body=body, error=error, elapsed_ms=elapsed_ms)


def _error_code(body: dict[str, Any] | None) -> str | None:
    if isinstance(body, dict):
        code = body.get("code")
        if isinstance(code, str) and code:
            return code
    return None


def _schema_version(body: dict[str, Any] | None) -> Any:
    if not isinstance(body, dict):
        return None
    if body.get("schema_version") is not None:
        return body["schema_version"]
    data = body.get("data")
    if isinstance(data, dict):
        return data.get("schema_version")
    return None


def _health_state(body: dict[str, Any] | None) -> Any:
    if not isinstance(body, dict):
        return None
    if body.get("status") is not None:
        return body["status"]
    data = body.get("data")
    if isinstance(data, dict):
        return data.get("status")
    return None


def _count(body: dict[str, Any] | None, list_key: str) -> int | None:
    if not isinstance(body, dict):
        return None
    count = body.get("count")
    if isinstance(count, int) and not isinstance(count, bool):
        return count
    rows = body.get(list_key)
    if isinstance(rows, list):
        return len(rows)
    return None


def _parse_action_id(value: Any) -> int | None:
    """Accept the integer the director emits, and a plain digit string."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value >= 1 else None
    if isinstance(value, str) and value.isdigit():
        parsed = int(value)
        return parsed if parsed >= 1 else None
    return None


def _describe(result: HttpResult) -> str:
    if result.error:
        return f"transport error: {result.error}"
    detail = f"HTTP {result.status}"
    code = _error_code(result.body)
    if code:
        detail += f" code={code}"
    return detail


def _with_hint(detail: str, hint: str | None) -> str:
    return f"{detail}; {hint}" if hint else detail


# ---------------------------------------------------------------------------
# Smoke runner
# ---------------------------------------------------------------------------
class Smoke:
    """Ordered probe set.  Construct, call :meth:`run`, read :meth:`report`."""

    def __init__(
        self,
        *,
        env: dict[str, str] | None = None,
        allow_write: bool = False,
        allow_approve: bool = False,
        timeout_ms: int = DEFAULT_TIMEOUT_MS,
    ) -> None:
        source = os.environ if env is None else env
        self.values = {name: (source.get(name) or "").strip() for name in ENV_VARS}
        self.allow_write = bool(allow_write or allow_approve)
        self.allow_approve = bool(allow_approve)
        self.timeout_ms = timeout_ms
        self.agent_id = self.values["AGENT_AGENT_ID"] or DEFAULT_AGENT_ID
        self.citizenid = self.values["AGENT_SMOKE_CITIZENID"]
        self.run_id = (
            "smoke-"
            + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
            + "-"
            + secrets.token_hex(3)
        )
        self.started_at = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
        self.checks: list[dict[str, Any]] = []
        self.action_id: int | None = None
        self.action_status: str | None = None
        self.propose_attempted = False
        self._secrets = tuple(
            value for value in (self.values[name] for name in TOKEN_VARS) if value
        )

    # -- report plumbing ----------------------------------------------------
    def _redact(self, text: str) -> str:
        text = str(text)
        for secret in self._secrets:
            if secret in text:
                text = text.replace(secret, "<redacted>")
        # A hostile upstream string must not break the one-line table or the
        # JSON report; lone surrogates are also made printable here.
        text = text.replace("\r", "\\r").replace("\n", "\\n").replace("\t", " ")
        return text.encode("utf-8", "backslashreplace").decode("utf-8")

    def _add(
        self,
        name: str,
        status: str,
        detail: str,
        http_status: int | None = None,
        elapsed_ms: int = 0,
    ) -> dict[str, Any]:
        check = {
            "name": name,
            "status": status,
            "detail": self._redact(detail),
            "http_status": http_status,
            "elapsed_ms": int(elapsed_ms),
        }
        self.checks.append(check)
        return check

    def _require_channel(self, name: str, variables: tuple[str, ...]) -> bool:
        missing = [variable for variable in variables if not self.values[variable]]
        if missing:
            self._add(name, "skip", "missing " + ", ".join(missing))
            return False
        return True

    def _director_url(self, path: str) -> str:
        return self.values["AGENT_DIRECTOR_URL"].rstrip("/") + path

    def _gateway_url(self, path: str) -> str:
        return self.values["AGENT_GATEWAY_URL"].rstrip("/") + path

    # -- checks -------------------------------------------------------------
    def check_gateway_health(self) -> None:
        name = "gateway_health"
        if not self._require_channel(name, ("AGENT_GATEWAY_URL", "AGENT_GATEWAY_TOKEN")):
            return
        result = http_request(
            "GET",
            self._gateway_url("/agent/v1/health"),
            token=self.values["AGENT_GATEWAY_TOKEN"],
            timeout_ms=self.timeout_ms,
        )
        if result.error:
            self._add(name, "fail", _describe(result), None, result.elapsed_ms)
            return
        if result.status != 200:
            self._add(
                name,
                "fail",
                _with_hint(
                    _describe(result),
                    "check AGENT_GATEWAY_TOKEN and that tools/agent_gateway.py is running",
                ),
                result.status,
                result.elapsed_ms,
            )
            return
        state = _health_state(result.body)
        if state not in HEALTH_STATES:
            self._add(
                name,
                "fail",
                f"health status is {state!r}, expected one of {', '.join(HEALTH_STATES)}",
                result.status,
                result.elapsed_ms,
            )
            return
        self._add(name, "pass", f"status={state}", result.status, result.elapsed_ms)

    def check_gateway_schema(self) -> None:
        name = "gateway_schema"
        if not self._require_channel(name, ("AGENT_GATEWAY_URL", "AGENT_GATEWAY_TOKEN")):
            return
        result = http_request(
            "GET",
            self._gateway_url("/agent/v1/schema"),
            token=self.values["AGENT_GATEWAY_TOKEN"],
            timeout_ms=self.timeout_ms,
        )
        if result.error:
            self._add(name, "fail", _describe(result), None, result.elapsed_ms)
            return
        if result.status != 200:
            self._add(
                name,
                "fail",
                _with_hint(
                    _describe(result),
                    "check AGENT_GATEWAY_TOKEN and that tools/agent_gateway.py is running",
                ),
                result.status,
                result.elapsed_ms,
            )
            return
        version = _schema_version(result.body)
        if version is None:
            self._add(name, "fail", "200 response has no schema_version", result.status, result.elapsed_ms)
            return
        self._add(name, "pass", f"schema_version={version}", result.status, result.elapsed_ms)

    def check_director_policy(self) -> None:
        name = "director_policy"
        if not self._require_channel(name, ("AGENT_DIRECTOR_URL", "AGENT_DIRECTOR_TOKEN")):
            return
        result = http_request(
            "GET",
            self._director_url("/agent/v1/policy"),
            token=self.values["AGENT_DIRECTOR_TOKEN"],
            timeout_ms=self.timeout_ms,
        )
        if result.error:
            self._add(name, "fail", _describe(result), None, result.elapsed_ms)
            return
        if result.status != 200:
            self._add(
                name,
                "fail",
                _with_hint(
                    _describe(result),
                    "check agent_actions_token / AGENT_DIRECTOR_TOKEN and agent_actions_enabled",
                ),
                result.status,
                result.elapsed_ms,
            )
            return
        version = _schema_version(result.body)
        detail = "policy reachable" + (f" (schema_version={version})" if version is not None else "")
        self._add(name, "pass", detail, result.status, result.elapsed_ms)

    def check_director_list_actions(self) -> None:
        name = "director_list_actions"
        if not self._require_channel(name, ("AGENT_DIRECTOR_URL", "AGENT_DIRECTOR_TOKEN")):
            return
        result = http_request(
            "GET",
            self._director_url("/agent/v1/actions?limit=1"),
            token=self.values["AGENT_DIRECTOR_TOKEN"],
            agent_id=self.agent_id,
            timeout_ms=self.timeout_ms,
        )
        if result.error:
            self._add(name, "fail", _describe(result), None, result.elapsed_ms)
            return
        if result.status != 200:
            hint = None
            if _error_code(result.body) == "missing_agent_id":
                hint = "set AGENT_AGENT_ID (X-Agent-Id is required on action routes)"
            else:
                hint = "check AGENT_DIRECTOR_TOKEN and agent_actions_enabled=1"
            self._add(name, "fail", _with_hint(_describe(result), hint), result.status, result.elapsed_ms)
            return
        count = _count(result.body, "actions")
        detail = "limit=1 accepted" + (f"; count={count}" if count is not None else "")
        self._add(name, "pass", detail, result.status, result.elapsed_ms)

    def check_live_players(self) -> None:
        name = "live_players"
        if not self._require_channel(name, ("AGENT_DIRECTOR_URL", "AGENT_LIVE_TOKEN")):
            return
        result = http_request(
            "GET",
            self._director_url("/agent/v1/live/players?limit=1"),
            token=self.values["AGENT_LIVE_TOKEN"],
            timeout_ms=self.timeout_ms,
        )
        if result.error:
            self._add(name, "fail", _describe(result), None, result.elapsed_ms)
            return
        if result.status != 200:
            code = _error_code(result.body)
            hint = "check AGENT_LIVE_TOKEN against the agent_live_token convar"
            if code == "live_disabled":
                hint = "set agent_live_enabled=1 in the server config and restart custom-director"
            elif code == "live_token_not_configured":
                hint = "set the agent_live_token convar, then export the same value as AGENT_LIVE_TOKEN"
            elif result.status == 401:
                hint = "check AGENT_LIVE_TOKEN (the live token is separate from the director token)"
            self._add(name, "fail", _with_hint(_describe(result), hint), result.status, result.elapsed_ms)
            return
        count = _count(result.body, "players")
        detail = "live channel reachable" + (f"; players={count}" if count is not None else "")
        self._add(name, "pass", detail, result.status, result.elapsed_ms)

    def check_notify_dry_run(self) -> None:
        name = "notify_dry_run"
        if not self._require_channel(name, ("AGENT_DIRECTOR_URL", "AGENT_DIRECTOR_TOKEN")):
            return
        payload = {
            "type": "notify",
            "args": {
                "citizenid": self.citizenid or DEFAULT_CITIZENID,
                "text": "agent smoke",
            },
            "dry_run": True,
            "idempotency_key": f"{SMOKE_KEY_PREFIX}dry:{self.run_id}",
        }
        result = http_request(
            "POST",
            self._director_url("/agent/v1/act"),
            token=self.values["AGENT_DIRECTOR_TOKEN"],
            agent_id=self.agent_id,
            payload=payload,
            timeout_ms=self.timeout_ms,
        )
        if result.error:
            self._add(name, "fail", _describe(result), None, result.elapsed_ms)
            return
        if result.status != 200:
            self._add(
                name,
                "fail",
                _with_hint(
                    _describe(result),
                    "check agent_actions_enabled=1, AGENT_AGENT_ID and AGENT_DIRECTOR_TOKEN",
                ),
                result.status,
                result.elapsed_ms,
            )
            return
        if not isinstance(result.body, dict) or result.body.get("ok") is not True:
            code = _error_code(result.body)
            self._add(
                name,
                "fail",
                f"200 response is not ok (code={code})" if code else "200 response is not ok",
                result.status,
                result.elapsed_ms,
            )
            return
        status = result.body.get("status")
        action_id = result.body.get("id")
        detail = f"dry_run accepted; status={status}"
        if action_id is not None:
            detail += f", id={action_id}"
        self._add(name, "pass", detail, result.status, result.elapsed_ms)

    def check_notify_propose(self) -> None:
        name = "notify_propose"
        if not self.allow_write:
            self._add(name, "skip", READ_ONLY_REASON)
            return
        if not self._require_channel(name, ("AGENT_DIRECTOR_URL", "AGENT_DIRECTOR_TOKEN")):
            return
        if not self.citizenid:
            self._add(
                name,
                "skip",
                "AGENT_SMOKE_CITIZENID is not set (an online player is required for write probes)",
            )
            return
        payload = {
            "type": "notify",
            "args": {"citizenid": self.citizenid, "text": "agent smoke"},
            "idempotency_key": f"{SMOKE_KEY_PREFIX}propose:{self.run_id}",
        }
        self.propose_attempted = True
        result = http_request(
            "POST",
            self._director_url("/agent/v1/act"),
            token=self.values["AGENT_DIRECTOR_TOKEN"],
            agent_id=self.agent_id,
            payload=payload,
            timeout_ms=self.timeout_ms,
        )
        if result.error:
            self._add(name, "fail", _describe(result), None, result.elapsed_ms)
            return
        if result.status not in (200, 202):
            self._add(
                name,
                "fail",
                _with_hint(
                    _describe(result),
                    "check agent_actions_enabled=1, AGENT_AGENT_ID and that the citizenid is online",
                ),
                result.status,
                result.elapsed_ms,
            )
            return
        body = result.body if isinstance(result.body, dict) else {}
        if body.get("ok") is not True:
            code = _error_code(result.body)
            self._add(
                name,
                "fail",
                (
                    f"HTTP {result.status} response is not ok (code={code})"
                    if code
                    else f"HTTP {result.status} response is not ok"
                ),
                result.status,
                result.elapsed_ms,
            )
            return
        raw_id = body.get("id")
        action_id = _parse_action_id(raw_id)
        if action_id is None:
            self._add(
                name,
                "fail",
                f"HTTP {result.status} ok response has no usable action id",
                result.status,
                result.elapsed_ms,
            )
            return
        self.action_id = action_id
        self.action_status = body.get("status") if isinstance(body.get("status"), str) else None
        self._add(
            name,
            "pass",
            f"HTTP {result.status}; id={raw_id}, status={self.action_status}",
            result.status,
            result.elapsed_ms,
        )

    def check_notify_get(self) -> None:
        name = "notify_get"
        if not self.allow_write:
            self._add(name, "skip", READ_ONLY_REASON)
            return
        if self.action_id is None:
            self._add(name, "skip", "no action id: notify_propose did not run")
            return
        if not self._require_channel(name, ("AGENT_DIRECTOR_URL", "AGENT_DIRECTOR_TOKEN")):
            return
        result = http_request(
            "GET",
            self._director_url(f"/agent/v1/actions/{self.action_id}"),
            token=self.values["AGENT_DIRECTOR_TOKEN"],
            agent_id=self.agent_id,
            timeout_ms=self.timeout_ms,
        )
        if result.error:
            self._add(name, "fail", _describe(result), None, result.elapsed_ms)
            return
        if result.status != 200:
            self._add(
                name,
                "fail",
                _with_hint(
                    _describe(result),
                    "GET /actions/{id} is scoped by X-Agent-Id; use the same AGENT_AGENT_ID",
                ),
                result.status,
                result.elapsed_ms,
            )
            return
        action = result.body.get("action") if isinstance(result.body, dict) else None
        if isinstance(action, dict):
            status = action.get("status")
        else:
            status = result.body.get("status") if isinstance(result.body, dict) else None
        if status not in ACTION_STATUSES:
            self._add(
                name,
                "fail",
                f"action status is {status!r}, expected one of {', '.join(ACTION_STATUSES)}",
                result.status,
                result.elapsed_ms,
            )
            return
        self.action_status = status
        self._add(name, "pass", f"status={status}", result.status, result.elapsed_ms)

    def check_notify_approve(self) -> None:
        name = "notify_approve"
        if not self.allow_approve:
            self._add(name, "skip", "--allow-approve not set")
            return
        if not self.values["AGENT_ADMIN_TOKEN"]:
            self._add(name, "skip", "missing AGENT_ADMIN_TOKEN")
            return
        if self.action_id is None:
            self._add(name, "skip", "no action id: notify_propose did not run")
            return
        if not self._require_channel(name, ("AGENT_DIRECTOR_URL",)):
            return
        result = http_request(
            "POST",
            self._director_url(f"/agent/v1/actions/{self.action_id}/approve"),
            token=self.values["AGENT_ADMIN_TOKEN"],
            payload={"approver": "smoke"},
            timeout_ms=self.timeout_ms,
        )
        if result.error:
            self._add(name, "fail", _describe(result), None, result.elapsed_ms)
            return
        if result.status == 200:
            body = result.body if isinstance(result.body, dict) else {}
            status = body.get("status")
            detail = f"approved id={self.action_id}" + (f"; status={status}" if status else "")
            self._add(name, "pass", detail, result.status, result.elapsed_ms)
            return
        code = _error_code(result.body)
        if code == "invalid_status" and self.action_status != "pending_approval":
            # notify auto-executes, so it never waits for approval.  This is a
            # correct 409 from the guard, not a broken approve endpoint.
            self._add(
                name,
                "skip",
                (
                    f"approve not applicable: action {self.action_id} is "
                    f"{self.action_status or 'already executed'}; notify auto-executes "
                    "(409 invalid_status)"
                ),
                result.status,
                result.elapsed_ms,
            )
            return
        self._add(
            name,
            "fail",
            _with_hint(
                _describe(result),
                "check AGENT_ADMIN_TOKEN (the admin token is separate from the director token)",
            ),
            result.status,
            result.elapsed_ms,
        )

    def check_cleanup(self) -> None:
        note = (
            "no data deleted; smoke rows remain in agent_actions with "
            "idempotency_key prefix 'smoke:' - filter them manually"
        )
        if self.propose_attempted:
            self._add("cleanup", "pass", note)
        else:
            self._add(
                "cleanup",
                "skip",
                "no data deleted; this read-only run wrote nothing, so only earlier "
                "smoke rows remain in agent_actions (idempotency_key prefix 'smoke:')",
            )

    # -- execution ----------------------------------------------------------
    def run(self) -> dict[str, Any]:
        for name in CHECK_NAMES:
            check = getattr(self, f"check_{name}")
            try:
                check()
            except Exception as exc:  # noqa: BLE001 - a probe must never crash the CLI
                self._add(name, "fail", f"internal error: {type(exc).__name__}: {exc}")
        return self.report()

    def report(self) -> dict[str, Any]:
        summary = {"pass": 0, "fail": 0, "skip": 0}
        for check in self.checks:
            summary[check["status"]] += 1
        return {
            "run_id": self.run_id,
            "started_at": self.started_at,
            "finished_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "read_only": not self.allow_write,
            "allow_write": self.allow_write,
            "allow_approve": self.allow_approve,
            "agent_id": self.agent_id,
            "checks": self.checks,
            "summary": summary,
        }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="agent_smoke.py",
        description="Smoke-check a running T-City FXServer through the agent HTTP surfaces.",
        epilog=(
            "Environment: AGENT_GATEWAY_URL/TOKEN, AGENT_DIRECTOR_URL/TOKEN, "
            "AGENT_LIVE_TOKEN, AGENT_ADMIN_TOKEN, AGENT_AGENT_ID, "
            "AGENT_SMOKE_CITIZENID. Missing variables skip the related checks. "
            "Tokens are never printed."
        ),
    )
    parser.add_argument(
        "--read-only",
        action="store_true",
        help="force read-only mode (default); conflicts with --allow-write/--allow-approve",
    )
    parser.add_argument(
        "--allow-write",
        action="store_true",
        help="send one non-dry-run notify proposal (requires AGENT_SMOKE_CITIZENID)",
    )
    parser.add_argument(
        "--allow-approve",
        action="store_true",
        help="also call the admin approve endpoint (implies --allow-write; needs AGENT_ADMIN_TOKEN)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit a machine-readable JSON report instead of a table",
    )
    parser.add_argument(
        "--timeout-ms",
        type=int,
        default=DEFAULT_TIMEOUT_MS,
        metavar="MS",
        help=f"per-request timeout in milliseconds (default {DEFAULT_TIMEOUT_MS})",
    )
    return parser


def format_human(report: dict[str, Any]) -> str:
    mode = "read-only (dry-run only)"
    if report["allow_approve"]:
        mode = "read/write + approve"
    elif report["allow_write"]:
        mode = "read/write"
    lines = [
        f"agent smoke {report['run_id']}  started_at={report['started_at']}  mode={mode}",
        "",
        f"{'STATUS':<6} {'CHECK':<22} {'HTTP':>5} {'MS':>6}  DETAIL",
    ]
    for check in report["checks"]:
        http_status = "-" if check["http_status"] is None else str(check["http_status"])
        lines.append(
            f"{check['status']:<6} {check['name']:<22} {http_status:>5} "
            f"{check['elapsed_ms']:>6}  {check['detail']}"
        )
    summary = report["summary"]
    lines.append("")
    lines.append(
        f"summary: {summary['pass']} pass, {summary['fail']} fail, {summary['skip']} skip"
    )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.timeout_ms <= 0:
        parser.error("--timeout-ms must be a positive integer")
    if args.read_only and (args.allow_write or args.allow_approve):
        parser.error("--read-only cannot be combined with --allow-write/--allow-approve")

    smoke = Smoke(
        allow_write=args.allow_write,
        allow_approve=args.allow_approve,
        timeout_ms=args.timeout_ms,
    )
    report = smoke.run()
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(format_human(report))
    return 0 if report["summary"]["fail"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
