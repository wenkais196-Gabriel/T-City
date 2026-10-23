#!/usr/bin/env python3
"""Read-only HTTP API for T-City agents (issue #24).

Run:
    AGENT_TOKEN=... python3 tools/agent_gateway.py

Environment:
    AGENT_TOKEN       required bearer token; the server refuses to start without it
    AGENT_HTTP_HOST   default 127.0.0.1
    AGENT_HTTP_PORT   default 8787
    AGENT_DB_*        read-only database settings (see tools/agent_data.py)

Every route is a GET and every database call is a SELECT against the agent_*
views.  There is deliberately no CORS, no unauthenticated mode and no write
endpoint.
"""

from __future__ import annotations

import datetime as dt
import hmac
import json
import os
import re
import secrets
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlsplit

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import agent_contract  # noqa: E402
import agent_data  # noqa: E402
import agent_tools  # noqa: E402

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8787
_BEARER_RE = re.compile(r"^\s*Bearer\s+(.+?)\s*$", re.IGNORECASE)

# Fixed wire text per error code. Validation details (which can quote request
# parameters) are logged to stderr instead of being reflected to the caller.
_SAFE_ERRORS = {
    "unauthorized": "missing or invalid bearer token",
    "not_found": "not found",
    "method_not_allowed": "method not allowed",
    "body_too_large": "request body too large",
    "schema_unavailable": "schema is unavailable",
    "database_error": "database is unavailable",
    "database_unavailable": "database is unavailable",
    "permission_denied": "permission denied",
    "internal_error": "internal server error",
}


# ---------------------------------------------------------------------------
# Response helpers
# ---------------------------------------------------------------------------
def _json_bytes(payload: Any) -> bytes:
    text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    # Defence in depth for a JSON API that can echo file content (the schema
    # registry). Escaping the HTML metacharacters keeps the bytes valid JSON
    # while making the body inert if a browser ever sniffs it as markup.
    text = text.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    return text.encode("utf-8")


def _envelope(
    data: Any,
    next_cursor: Any = None,
    meta: dict[str, Any] | None = None,
    *,
    request_id: str | None = None,
    warnings: list[str] | None = None,
) -> dict[str, Any]:
    """v1 success envelope plus the additive contract fields (design 03 §5.3 B).

    The four original keys keep their exact shape and are written first; the
    new fields are appended so pre-M0 clients can ignore them byte-for-byte.
    """
    payload: dict[str, Any] = {
        "schema_version": agent_data.SCHEMA_VERSION,
        "data": data,
    }
    if next_cursor is not None:
        payload["next_cursor"] = next_cursor
    if meta:
        payload["meta"] = meta
    payload["ok"] = True
    payload["kind"] = "ok"
    payload["retryable"] = False
    payload["request_id"] = request_id or secrets.token_hex(8)
    payload["warnings"] = list(warnings or [])
    return payload


def _get_param(query: dict[str, list[str]], name: str, default: Any = None) -> Any:
    values = query.get(name)
    if not values:
        return default
    if len(values) > 1:
        raise agent_data.ValidationError(f"duplicate query parameter: {name}")
    return values[0]


def _check_params(query: dict[str, list[str]], allowed: set[str]) -> None:
    unknown = sorted(set(query) - allowed)
    if unknown:
        raise agent_data.ValidationError("unknown query parameter(s): " + ", ".join(unknown))


class AgentHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address: tuple[str, int], token: str):
        self.agent_token = token
        super().__init__(server_address, AgentHandler)


class AgentHandler(BaseHTTPRequestHandler):
    server_version = "T-CityAgentGateway/1.0"
    protocol_version = "HTTP/1.1"

    # -- low-level responses -------------------------------------------------
    def _send_json(self, status: int, payload: Any, headers: dict[str, str] | None = None) -> None:
        body = _json_bytes(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
        self.send_header("Connection", "close")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.close_connection = True
        if self.command != "HEAD":
            try:
                # Reviewed exception: not an HTML sink. The body is JSON (application/json,
                # nosniff, default-src 'none' CSP) and every <, >, & is already
                # \uXXXX-escaped in _json_bytes, so it cannot be parsed as
                # markup even if a browser sniffs it. Sonar's taint model flags
                # any file-derived bytes written to wfile and cannot see the
                # content type; mark this instance as reviewed rather than
                # weakening the rule for the whole module.
                self.wfile.write(body)  # NOSONAR
            except (BrokenPipeError, ConnectionResetError):
                pass

    def _error(self, status: int, message: str, code: str, headers: dict[str, str] | None = None) -> None:
        # Never reflect the detailed message: ValidationError strings can
        # contain query parameter names/values, which makes the response a
        # reflected-input sink (Sonar: reflected XSS). The detail goes to
        # stderr for operators; the wire gets a fixed, code-derived text.
        if message:
            print(
                f"agent_gateway: {status} {code}: {message}",
                file=sys.stderr,
                flush=True,
            )
        kind, retryable = agent_contract.classify(code)
        self._send_json(
            status,
            {
                "error": _SAFE_ERRORS.get(code, "invalid request"),
                "code": code,
                "kind": kind,
                "retryable": retryable,
            },
            headers,
        )

    def _method_not_allowed(self) -> None:
        self._error(405, "method not allowed", "method_not_allowed", {"Allow": "GET"})

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        match = _BEARER_RE.fullmatch(header)
        if not match:
            return False
        token = getattr(self.server, "agent_token", "")
        if not token:
            return False
        return hmac.compare_digest(match.group(1).encode("utf-8"), token.encode("utf-8"))

    # -- routing -------------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        if not self._authorized():
            self._error(
                401,
                "missing or invalid bearer token",
                "unauthorized",
                {"WWW-Authenticate": 'Bearer realm="t-city-agent"'},
            )
            return
        try:
            self._route_get()
        except agent_data.ValidationError as exc:
            self._error(400, str(exc), exc.code)
        except agent_data.NotFoundError as exc:
            self._error(404, str(exc), exc.code)
        except agent_data.PermissionDeniedError as exc:
            self._error(403, str(exc), exc.code)
        except agent_data.SchemaUnavailableError as exc:
            self._error(503, str(exc), exc.code)
        except agent_data.DatabaseError as exc:
            self._error(503, str(exc), exc.code)
        except agent_data.AgentDataError as exc:
            self._error(500, str(exc), exc.code)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as exc:  # noqa: BLE001 - must never leak a traceback
            print(
                f"agent_gateway: unhandled {type(exc).__name__}: {exc}",
                file=sys.stderr,
                flush=True,
            )
            self._error(500, "internal server error", "internal_error")

    def do_HEAD(self) -> None:  # noqa: N802
        self._method_not_allowed()

    def do_POST(self) -> None:  # noqa: N802
        self._method_not_allowed()

    def do_PUT(self) -> None:  # noqa: N802
        self._method_not_allowed()

    def do_PATCH(self) -> None:  # noqa: N802
        self._method_not_allowed()

    def do_DELETE(self) -> None:  # noqa: N802
        self._method_not_allowed()

    def do_OPTIONS(self) -> None:  # noqa: N802
        # CORS is intentionally not enabled.
        self._method_not_allowed()

    def _route_get(self) -> None:
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query, keep_blank_values=True)
        segments = [unquote(part) for part in parsed.path.split("/") if part]

        if segments == ["agent", "v1", "health"]:
            self._check_no_params(query)
            self._health()
            return
        if segments == ["agent", "v1", "schema"]:
            self._check_no_params(query)
            self._send_json(200, _envelope(agent_data.get_schema()))
            return
        if segments == ["agent", "v1", "tools"]:
            self._check_no_params(query)
            self._tools_registry()
            return
        if segments == ["agent", "v1", "players"]:
            self._players(query)
            return
        if len(segments) == 4 and segments[:3] == ["agent", "v1", "players"]:
            self._player_snapshot(segments[3], query)
            return
        if len(segments) == 5 and segments[:3] == ["agent", "v1", "players"] and segments[4] == "timeline":
            self._player_timeline(segments[3], query)
            return
        if segments == ["agent", "v1", "events"]:
            self._events(query)
            return
        if segments == ["agent", "v1", "world"]:
            self._world(query)
            return
        if segments == ["agent", "v1", "economy"]:
            self._check_no_params(query)
            rows = agent_data.get_economy_metrics()
            self._send_json(200, _envelope(rows, meta={"count": len(rows)}))
            return
        if segments == ["agent", "v1", "world", "digest"]:
            self._digest(query)
            return
        self._error(404, "unknown endpoint", "not_found")

    def _check_no_params(self, query: dict[str, list[str]]) -> None:
        _check_params(query, set())

    def _tools_registry(self) -> None:
        """Serve the runtime tool registry (read from tools/agent_tools.json)."""
        try:
            registry = agent_tools.load_registry()
        except agent_tools.RegistryError:
            self._error(503, "tool registry unavailable", "registry_unavailable")
            return
        tools = registry.get("tools", [])
        self._send_json(
            200,
            _envelope(
                {
                    "registry_version": registry.get("registry_version"),
                    "tools": tools,
                },
                meta={"count": len(tools)},
            ),
        )

    # -- endpoints -----------------------------------------------------------
    def _health(self) -> None:
        reachable = agent_data.db_ping()
        data = {
            "status": "ok" if reachable else "degraded",
            "api_version": agent_data.API_VERSION,
            "schema_version": agent_data.SCHEMA_VERSION,
            "read_only": True,
            "database": {
                "backend": agent_data.backend_name(),
                "reachable": reachable,
            },
            "server_time": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        }
        self._send_json(200, _envelope(data))

    def _players(self, query: dict[str, list[str]]) -> None:
        _check_params(query, {"limit", "job", "gang", "updated_since", "fields", "order_by", "order"})
        filters: dict[str, Any] = {}
        for key in ("job", "gang", "updated_since"):
            value = _get_param(query, key)
            if value is not None:
                filters[key] = value
        limit = _get_param(query, "limit")
        fields = _get_param(query, "fields")
        order_by = _get_param(query, "order_by", "citizenid")
        order = _get_param(query, "order", "asc")

        rows = agent_data.query_players(
            filters,
            limit=limit,
            fields=fields,
            order_by=order_by,
            order=order,
        )
        self._send_json(
            200,
            _envelope(
                rows,
                meta={
                    "count": len(rows),
                    "limit": agent_data.clamp_limit(limit),
                    "order_by": order_by,
                    "order": str(order).lower(),
                },
            ),
        )

    def _player_snapshot(self, citizenid: str, query: dict[str, list[str]]) -> None:
        self._check_no_params(query)
        row = agent_data.get_player_snapshot(citizenid)
        if row is None:
            raise agent_data.NotFoundError("player not found")
        self._send_json(200, _envelope(row))

    def _player_timeline(self, citizenid: str, query: dict[str, list[str]]) -> None:
        _check_params(query, {"limit", "since"})
        limit = _get_param(query, "limit")
        since = _get_param(query, "since")
        rows = agent_data.get_player_timeline(citizenid, limit=limit, since=since)
        self._send_json(
            200,
            _envelope(
                rows,
                meta={
                    "count": len(rows),
                    "limit": agent_data.clamp_limit(limit),
                    "since": since,
                },
            ),
        )

    def _events(self, query: dict[str, list[str]]) -> None:
        _check_params(query, {"since_id", "type", "limit"})
        since_id = _get_param(query, "since_id", "0")
        event_type = _get_param(query, "type")
        limit = _get_param(query, "limit")
        rows = agent_data.list_events(since_id=since_id, type=event_type, limit=limit)
        if rows:
            next_cursor = rows[-1].get("id")
        else:
            try:
                next_cursor = int(str(since_id).strip()) if since_id not in (None, "") else 0
            except (TypeError, ValueError):
                raise agent_data.ValidationError("since_id must be a non-negative integer") from None
        self._send_json(
            200,
            _envelope(
                rows,
                next_cursor=next_cursor,
                meta={
                    "count": len(rows),
                    "limit": agent_data.clamp_limit(limit),
                    "since_id": since_id,
                    "type": event_type,
                },
            ),
        )

    def _world(self, query: dict[str, list[str]]) -> None:
        _check_params(query, {"limit"})
        limit = _get_param(query, "limit")
        rows = agent_data.get_world_state(limit=limit)
        self._send_json(
            200,
            _envelope(rows, meta={"count": len(rows), "limit": agent_data.clamp_limit(limit)}),
        )

    def _digest(self, query: dict[str, list[str]]) -> None:
        _check_params(query, {"window", "window_minutes", "budget_tokens"})
        window = _get_param(query, "window")
        window_minutes = _get_param(query, "window_minutes")
        if window is not None and window_minutes is not None:
            raise agent_data.ValidationError("use either window or window_minutes, not both")
        effective_window = window if window is not None else window_minutes
        budget_tokens = _get_param(query, "budget_tokens")
        digest = agent_data.get_world_digest(effective_window, budget_tokens)
        self._send_json(200, _envelope(digest))


def main() -> int:
    agent_data.load_env_file()

    token = (os.environ.get("AGENT_TOKEN") or "").strip()
    if not token:
        print(
            "agent_gateway: refusing to start: AGENT_TOKEN is not set "
            "(no unauthenticated default)",
            file=sys.stderr,
            flush=True,
        )
        return 2

    host = (os.environ.get("AGENT_HTTP_HOST") or DEFAULT_HOST).strip()
    port_raw = (os.environ.get("AGENT_HTTP_PORT") or str(DEFAULT_PORT)).strip()
    try:
        port = int(port_raw)
    except ValueError:
        print("agent_gateway: AGENT_HTTP_PORT must be an integer", file=sys.stderr, flush=True)
        return 2
    if not 1 <= port <= 65535:
        print("agent_gateway: AGENT_HTTP_PORT is out of range", file=sys.stderr, flush=True)
        return 2

    try:
        httpd = AgentHTTPServer((host, port), token)
    except OSError as exc:
        print(f"agent_gateway: cannot bind {host}:{port}: {exc}", file=sys.stderr, flush=True)
        return 1

    print(
        f"agent_gateway: read-only API listening on {host}:{port} "
        f"(schema_version={agent_data.SCHEMA_VERSION}, backend={agent_data.backend_name()}); "
        "this listener is plaintext and loopback-only - put a TLS proxy in front "
        "of it before exposing it beyond 127.0.0.1",
        file=sys.stderr,
        flush=True,
    )
    try:
        # Reviewed exception: deliberate cleartext listener. It binds 127.0.0.1 by
        # default, is read-only, and the startup banner tells operators to put
        # a TLS proxy in front before exposing it. Switching this to HTTPS
        # would require shipping and rotating a certificate for a loopback
        # sidecar, which is a larger operational risk than the one it removes.
        httpd.serve_forever(poll_interval=0.5)  # NOSONAR
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
