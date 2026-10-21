#!/usr/bin/env python3
"""Read-only data access for the T-City agent HTTP API and MCP sidecar.

Design rules (issue #24):

* Every query is a SELECT against the curated ``agent_*`` views.  This module
  never writes to the database.
* ``agent_ro`` credentials come from the environment / ``.env``.  No password
  is ever printed, put on a command line, or written to a response.
* ``mysql.connector`` is used when it is importable.  Otherwise the MariaDB /
  MySQL CLI is used with ``MYSQL_PWD`` in the child environment (never in
  argv), and XML output is parsed so tabs/newlines in JSON cannot corrupt rows.
* User-supplied identifiers, field lists and order clauses are strictly
  whitelisted.  Limits are clamped to ``HARD_LIMIT`` (200).
* ``get_world_digest`` fits its answer into ``budget_tokens`` (4 chars/token).
"""

from __future__ import annotations

import datetime as dt
import json
import math
import os
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
from decimal import Decimal
from pathlib import Path
from typing import Any, Mapping, Sequence

REPO_ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = REPO_ROOT / ".env"
SCHEMA_PATH = REPO_ROOT / "T-CityLite.base" / "docs" / "agent" / "schema.json"

SCHEMA_VERSION = 1
API_VERSION = "v1"
DEFAULT_LIMIT = 50
HARD_LIMIT = 200

DEFAULT_DIGEST_WINDOW_MINUTES = 5
MAX_DIGEST_WINDOW_MINUTES = 1440
DEFAULT_DIGEST_BUDGET = 2000
MIN_DIGEST_BUDGET = 1
MAX_DIGEST_BUDGET = 20000

PLAYER_FIELDS = (
    "citizenid",
    "name",
    "job",
    "gang",
    "cash",
    "bank",
    "crypto",
    "firstname",
    "lastname",
    "last_updated",
    "schema_version",
)
PLAYER_ORDER_FIELDS = (
    "citizenid",
    "name",
    "job",
    "gang",
    "cash",
    "bank",
    "crypto",
    "last_updated",
    "schema_version",
)
PLAYER_FILTER_KEYS = frozenset({"job", "gang", "updated_since"})

TIMELINE_FIELDS = (
    "citizenid",
    "event_type",
    "occurred_at",
    "payload",
    "source_table",
    "schema_version",
)

EVENT_FIELDS = (
    "event_type",
    "citizenid",
    "payload",
    "schema_version",
    "created_at",
    "id",
)

WORLD_FIELDS = (
    "region_id",
    "state_key",
    "state_value",
    "changed_at",
    "source_table",
    "schema_version",
)

ECONOMY_FIELDS = (
    "job",
    "player_count",
    "total_cash",
    "total_bank",
    "avg_bank",
    "max_bank",
    "schema_version",
)

JSON_FIELDS = frozenset({"payload", "state_value"})
INT_FIELDS = frozenset(
    {
        "id",
        "schema_version",
        "player_count",
        "event_count",
        "job_groups",
        "recently_active",
        "stale_24h",
        "low_liquidity",
        "total",
        "count",
        "minutes_ago",
        "ok",
    }
)
FLOAT_FIELDS = frozenset(
    {
        "cash",
        "bank",
        "crypto",
        "amount",
        "total_cash",
        "total_bank",
        "avg_bank",
        "max_bank",
    }
)

IMPORTANT_EVENT_TYPES = (
    "quest.completed",
    "quest.failed",
    "quest.abandoned",
    "story.choice",
    "vehicle.acquired",
)
TERMINAL_QUEST_EVENT_TYPES = frozenset(
    {"quest.complete", "quest.completed", "quest.failed", "quest.abandoned"}
)

_CITIZENID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_FILTER_VALUE_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
_EVENT_TYPE_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
_DB_NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")
_RELATIVE_SINCE_RE = re.compile(r"^([0-9]{1,6})([mhd])$", re.IGNORECASE)

_SELECT_RE = re.compile(r"^\s*SELECT\b", re.IGNORECASE)
_FORBIDDEN_SQL_RE = re.compile(
    r"\b(?:INSERT|UPDATE|DELETE|REPLACE|DROP|ALTER|CREATE|TRUNCATE|GRANT|"
    r"REVOKE|CALL|DO|HANDLER|LOAD_FILE|OUTFILE|DUMPFILE|FOR\s+UPDATE)\b",
    re.IGNORECASE,
)


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------
class AgentDataError(Exception):
    """Base class for safe-to-report agent data errors."""

    code = "agent_data_error"

    def __init__(self, message: str, *, code: str | None = None) -> None:
        super().__init__(message)
        if code:
            self.code = code


class ValidationError(AgentDataError, ValueError):
    code = "bad_request"


class NotFoundError(AgentDataError):
    code = "not_found"


class SchemaUnavailableError(AgentDataError):
    code = "schema_unavailable"


class PermissionDeniedError(AgentDataError):
    code = "forbidden"


class DatabaseError(AgentDataError):
    code = "database_error"


# ---------------------------------------------------------------------------
# Environment / connection configuration
# ---------------------------------------------------------------------------
def load_env_file(path: Path | str = ENV_FILE) -> None:
    """Load simple KEY=VALUE lines from ``.env`` without overriding the env."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("export "):
            line = line[len("export ") :].lstrip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        if key in os.environ:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        os.environ[key] = value


def db_config(load_env: bool = True) -> dict[str, Any]:
    """Return the read-only DB connection settings.

    ``AGENT_DB_*`` wins over ``TCITY_DB_*``.  The password is deliberately
    required: there is no fallback that silently uses the admin account.
    """
    if load_env:
        load_env_file(ENV_FILE)

    host = os.environ.get("AGENT_DB_HOST") or os.environ.get("TCITY_DB_HOST") or "127.0.0.1"
    port_raw = os.environ.get("AGENT_DB_PORT") or os.environ.get("TCITY_DB_PORT") or "3306"
    user = os.environ.get("AGENT_DB_USER") or "agent_ro"
    password = os.environ.get("AGENT_DB_PASS")
    database = os.environ.get("AGENT_DB_NAME") or os.environ.get("TCITY_DB_NAME") or "TCityLite"

    try:
        port = int(port_raw)
    except (TypeError, ValueError):
        raise DatabaseError("AGENT_DB_PORT/TCITY_DB_PORT must be an integer", code="config_error")
    if not 1 <= port <= 65535:
        raise DatabaseError("database port is out of range", code="config_error")
    if not password:
        raise DatabaseError(
            "AGENT_DB_PASS is not set; source .env or export it (see .env.example)",
            code="config_error",
        )
    if not _DB_NAME_RE.fullmatch(database):
        raise DatabaseError("database name contains unsupported characters", code="config_error")

    return {
        "host": host,
        "port": port,
        "user": user,
        "password": password,
        "database": database,
    }


def backend_name() -> str:
    """Report which DB backend would be used, without connecting."""
    try:
        import mysql.connector  # noqa: F401  (optional dependency)

        return "mysql.connector"
    except ImportError:
        if shutil.which("mysql") or shutil.which("mariadb"):
            return "mysql-cli"
        return "unavailable"


# ---------------------------------------------------------------------------
# Validation / small helpers
# ---------------------------------------------------------------------------
def clamp_limit(value: Any = None, default: int = DEFAULT_LIMIT, hard: int = HARD_LIMIT) -> int:
    """Clamp a user limit to ``1..hard``.

    Missing/empty values use ``default``.  Non-integers raise ValidationError;
    out-of-range integers are clamped rather than rejected.
    """
    if value is None or value == "":
        return default
    try:
        number = int(str(value).strip())
    except (TypeError, ValueError):
        raise ValidationError(f"limit must be an integer, got {value!r}") from None
    if number < 1:
        return 1
    if number > hard:
        return hard
    return number


def clamp_int(value: Any, default: int, minimum: int, maximum: int, name: str = "value") -> int:
    if value is None or value == "":
        return default
    try:
        number = int(str(value).strip())
    except (TypeError, ValueError):
        raise ValidationError(f"{name} must be an integer, got {value!r}") from None
    return max(minimum, min(maximum, number))


def validate_fields(
    fields: Any,
    allowed: Sequence[str],
    default: Sequence[str] | None = None,
) -> list[str]:
    """Validate a field selector against a whitelist.

    Accepts ``None``/empty (all/default fields), ``"*"`` (all fields), a
    comma-separated string, or a sequence of names.  Unknown names, ``*``
    mixed with other names, and punctuation are rejected before any SQL runs.
    """
    allowed_list = list(allowed)
    if fields is None or fields == "" or fields == [] or fields == ():
        return list(default if default is not None else allowed_list)
    if isinstance(fields, str):
        parts = [part.strip() for part in fields.split(",")]
    elif isinstance(fields, (list, tuple, set, frozenset)):
        parts = [str(part).strip() for part in fields]
    else:
        raise ValidationError("fields must be a comma-separated string or a list")

    if any(part == "" for part in parts):
        raise ValidationError("fields contains an empty name")
    if "*" in parts:
        if len(parts) != 1:
            raise ValidationError("'*' must be used alone in fields")
        return allowed_list

    unknown = [part for part in parts if part not in allowed_list]
    if unknown:
        raise ValidationError("unknown field(s): " + ", ".join(unknown))

    result: list[str] = []
    for part in parts:
        if part not in result:
            result.append(part)
    return result


def validate_order(order_by: Any, allowed: Sequence[str], default: str) -> str:
    value = default if order_by is None or order_by == "" else str(order_by)
    if value not in allowed:
        raise ValidationError(f"unknown order_by field: {value!r}")
    return value


def validate_order_direction(order: Any, default: str = "asc") -> str:
    value = default if order is None or order == "" else str(order).strip().lower()
    if value not in {"asc", "desc"}:
        raise ValidationError("order must be 'asc' or 'desc'")
    return value


def validate_citizenid(citizenid: Any) -> str:
    if not isinstance(citizenid, str):
        raise ValidationError("citizenid must be a string")
    value = citizenid.strip()
    if not _CITIZENID_RE.fullmatch(value):
        raise ValidationError("citizenid contains unsupported characters")
    return value


def validate_event_type(event_type: Any) -> str | None:
    if event_type is None or event_type == "" or event_type == "*":
        return None
    if not isinstance(event_type, str):
        raise ValidationError("type must be a string")
    value = event_type.strip()
    if value == "*":
        return None
    if value.endswith("*"):
        prefix = value[:-1]
        if not prefix or not _EVENT_TYPE_RE.fullmatch(prefix):
            raise ValidationError("type prefix contains unsupported characters")
        return value
    if not _EVENT_TYPE_RE.fullmatch(value):
        raise ValidationError("type contains unsupported characters")
    return value


def parse_since(value: Any, now: dt.datetime | None = None) -> dt.datetime | None:
    """Parse an ISO date/time or a relative ``15m`` / ``5h`` / ``7d`` value.

    The returned datetime is naive local time, matching MariaDB DATETIME
    columns.  Invalid input raises ValidationError.
    """
    if value is None or value == "":
        return None
    if isinstance(value, dt.datetime):
        parsed = value
    elif isinstance(value, dt.date):
        parsed = dt.datetime.combine(value, dt.time.min)
    else:
        text = str(value).strip()
        relative = _RELATIVE_SINCE_RE.fullmatch(text)
        if relative:
            amount, unit = int(relative.group(1)), relative.group(2).lower()
            base = now or dt.datetime.now()
            delta = {
                "m": dt.timedelta(minutes=amount),
                "h": dt.timedelta(hours=amount),
                "d": dt.timedelta(days=amount),
            }[unit]
            try:
                relative_dt = base - delta
            except OverflowError:
                raise ValidationError("relative since value is too large") from None
            if relative_dt.tzinfo is not None:
                relative_dt = relative_dt.astimezone().replace(tzinfo=None)
            return relative_dt
        iso = text[:-1] + "+00:00" if text.endswith("Z") else text
        try:
            parsed = dt.datetime.fromisoformat(iso)
        except ValueError:
            raise ValidationError(
                "since/updated_since must be ISO 8601 or a relative value like 15m, 5h, 7d"
            ) from None

    if parsed.tzinfo is not None:
        parsed = parsed.astimezone().replace(tzinfo=None)
    return parsed


def _format_db_datetime(value: dt.datetime) -> str:
    value = value.replace(tzinfo=None)
    if value.microsecond:
        return value.strftime("%Y-%m-%d %H:%M:%S.%f")
    return value.strftime("%Y-%m-%d %H:%M:%S")


def _json_default(value: Any) -> Any:
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, (dt.datetime, dt.date, dt.time)):
        return value.isoformat()
    if isinstance(value, (set, frozenset, tuple)):
        return list(value)
    return str(value)


def _json_dumps(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        default=_json_default,
    )


def estimate_tokens(value: Any, chars_per_token: int = 4) -> int:
    """Rough token estimate: 4 JSON characters per token, rounded up."""
    length = len(_json_dumps(value))
    return (length + chars_per_token - 1) // chars_per_token


# ---------------------------------------------------------------------------
# SELECT-only DB execution
# ---------------------------------------------------------------------------
def _assert_select_only(sql: str) -> None:
    stripped = sql.strip()
    if not _SELECT_RE.match(stripped):
        raise DatabaseError("only SELECT statements are allowed", code="write_blocked")
    if ";" in stripped:
        raise DatabaseError("multiple statements are not allowed", code="write_blocked")
    if _FORBIDDEN_SQL_RE.search(stripped):
        raise DatabaseError("statement contains a forbidden SQL keyword", code="write_blocked")


def _sql_literal(value: Any) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValidationError("non-finite numeric parameter")
        return repr(value)
    if isinstance(value, Decimal):
        return format(value, "f")
    if isinstance(value, dt.datetime):
        return "'" + _format_db_datetime(value) + "'"
    if isinstance(value, dt.date):
        return "'" + value.isoformat() + "'"
    if isinstance(value, (list, tuple)):
        return "(" + ", ".join(_sql_literal(item) for item in value) + ")"
    if isinstance(value, bytes):
        return "X'" + value.hex() + "'"
    if isinstance(value, str):
        escaped = (
            value.replace("\\", "\\\\")
            .replace("\x00", "\\0")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\x1a", "\\Z")
            .replace("'", "\\'")
        )
        return "'" + escaped + "'"
    raise ValidationError(f"unsupported SQL parameter type: {type(value).__name__}")


def _render_cli_sql(sql: str, params: Sequence[Any]) -> str:
    if not params:
        return sql
    parts = sql.split("%s")
    if len(parts) != len(params) + 1:
        raise DatabaseError("SQL parameter count mismatch", code="database_error")
    rendered = [parts[0]]
    for value, suffix in zip(params, parts[1:]):
        rendered.append(_sql_literal(value))
        rendered.append(suffix)
    return "".join(rendered)


def _map_db_error(errno: int | None) -> AgentDataError:
    if errno in (1142, 1143, 1044):
        return PermissionDeniedError("database permission denied")
    if errno == 1045:
        return DatabaseError("database authentication failed", code="database_auth")
    if errno == 1146:
        return SchemaUnavailableError(
            "a required agent view is missing; apply the v2.2 migrations",
            code="schema_unavailable",
        )
    if errno in (2002, 2003):
        return DatabaseError("database is unreachable", code="database_unavailable")
    if errno:
        return DatabaseError(f"database query failed (code {errno})")
    return DatabaseError("database query failed")


def _execute_cli(sql: str, params: Sequence[Any]) -> list[dict[str, Any]]:
    cfg = db_config()
    mysql = shutil.which("mysql") or shutil.which("mariadb")
    if not mysql:
        raise DatabaseError(
            "neither mysql.connector nor the mysql/mariadb CLI is available",
            code="database_unavailable",
        )

    rendered = _render_cli_sql(sql, params)
    command = [
        mysql,
        "--no-defaults",
        "--default-character-set=utf8mb4",
        "--xml",
        "--connect-timeout=10",
        "-h",
        str(cfg["host"]),
        "-P",
        str(cfg["port"]),
        "-u",
        str(cfg["user"]),
        str(cfg["database"]),
    ]
    env = os.environ.copy()
    env["MYSQL_PWD"] = str(cfg["password"])  # never placed in argv
    env["LANG"] = "C"

    try:
        proc = subprocess.run(
            command,
            input=rendered,
            text=True,
            capture_output=True,
            env=env,
            timeout=20,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise DatabaseError("database query timed out", code="database_timeout") from None
    except OSError:
        raise DatabaseError("could not run the mysql CLI", code="database_unavailable") from None

    if proc.returncode != 0:
        match = re.search(r"ERROR\s+(\d+)", proc.stderr or "")
        errno = int(match.group(1)) if match else None
        raise _map_db_error(errno)

    if not proc.stdout.strip():
        return []
    try:
        root = ET.fromstring(proc.stdout)
    except ET.ParseError:
        raise DatabaseError("could not parse mysql CLI output", code="database_error") from None

    rows: list[dict[str, Any]] = []
    for row_el in root.findall("row"):
        row: dict[str, Any] = {}
        for field_el in row_el.findall("field"):
            name = field_el.get("name") or ""
            row[name] = field_el.text
        rows.append(row)
    return rows


def _execute_connector(sql: str, params: Sequence[Any]) -> list[dict[str, Any]]:
    try:
        import mysql.connector  # type: ignore[import-not-found]
    except ImportError:  # pragma: no cover - caller falls back to CLI
        raise DatabaseError("mysql.connector is not available", code="database_unavailable") from None

    cfg = db_config()
    conn = None
    cursor = None
    try:
        conn = mysql.connector.connect(
            host=cfg["host"],
            port=cfg["port"],
            user=cfg["user"],
            password=cfg["password"],
            database=cfg["database"],
            charset="utf8mb4",
            use_unicode=True,
            connection_timeout=10,
        )
        cursor = conn.cursor(dictionary=True)
        cursor.execute(sql, tuple(params) if params else None)
        return [dict(row) for row in cursor.fetchall()]
    except mysql.connector.Error as exc:  # type: ignore[attr-defined]
        raise _map_db_error(getattr(exc, "errno", None)) from None
    finally:
        if cursor is not None:
            try:
                cursor.close()
            except Exception:
                pass
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass


def _coerce_value(key: str, value: Any) -> Any:
    if value is None:
        return None
    if key in JSON_FIELDS and isinstance(value, str):
        try:
            return json.loads(value)
        except (TypeError, ValueError):
            return value
    if key in INT_FIELDS:
        try:
            return int(value)
        except (TypeError, ValueError):
            return value
    if key in FLOAT_FIELDS:
        try:
            return float(value)
        except (TypeError, ValueError):
            return value
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, dt.datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S.%f") if value.microsecond else value.strftime(
            "%Y-%m-%d %H:%M:%S"
        )
    if isinstance(value, dt.date):
        return value.isoformat()
    if isinstance(value, (bytes, bytearray)):
        return value.decode("utf-8", errors="replace")
    return value


def _coerce_row(row: Mapping[str, Any]) -> dict[str, Any]:
    return {key: _coerce_value(key, value) for key, value in row.items()}


def _execute(sql: str, params: Sequence[Any] = ()) -> list[dict[str, Any]]:
    """Run one SELECT and return normalized rows.

    ``mysql.connector`` is preferred; the CLI is a dependency-free fallback.
    """
    _assert_select_only(sql)
    try:
        import mysql.connector  # noqa: F401

        rows = _execute_connector(sql, params)
    except ImportError:
        rows = _execute_cli(sql, params)
    return [_coerce_row(row) for row in rows]


def db_ping() -> bool:
    """Return True when a simple read-only ``SELECT 1`` succeeds."""
    try:
        rows = _execute("SELECT 1 AS ok")
    except AgentDataError:
        return False
    return bool(rows and rows[0].get("ok") == 1)


# ---------------------------------------------------------------------------
# Schema registry
# ---------------------------------------------------------------------------
def get_schema() -> dict[str, Any]:
    """Return the versioned JSON schema contract from docs/agent/schema.json."""
    try:
        text = SCHEMA_PATH.read_text(encoding="utf-8")
    except OSError:
        raise SchemaUnavailableError(
            "schema contract not found at T-CityLite.base/docs/agent/schema.json",
            code="schema_unavailable",
        ) from None
    try:
        schema = json.loads(text)
    except json.JSONDecodeError:
        raise SchemaUnavailableError("schema contract is not valid JSON", code="schema_unavailable") from None
    if not isinstance(schema, dict) or not isinstance(schema.get("views"), dict):
        raise SchemaUnavailableError("schema contract has no views registry", code="schema_unavailable")
    schema.setdefault("schema_version", SCHEMA_VERSION)
    schema["read_only"] = True
    schema["api_version"] = API_VERSION
    return schema


# ---------------------------------------------------------------------------
# Read helpers
# ---------------------------------------------------------------------------
def query_players(
    filters: Mapping[str, Any] | None = None,
    *,
    limit: Any = DEFAULT_LIMIT,
    fields: Any = None,
    order_by: Any = "citizenid",
    order: Any = "asc",
) -> list[dict[str, Any]]:
    """Return player snapshots with whitelisted filters/fields/order.

    ``filters`` may contain only ``job``, ``gang`` and ``updated_since``.
    ``limit``/``fields``/``order_by``/``order`` may also appear in the mapping
    and override the keyword defaults.
    """
    filters = dict(filters or {})
    limit = filters.pop("limit", limit)
    fields = filters.pop("fields", fields)
    order_by = filters.pop("order_by", order_by)
    order = filters.pop("order", order)

    unknown = [key for key in filters if key not in PLAYER_FILTER_KEYS]
    if unknown:
        raise ValidationError("unknown player filter(s): " + ", ".join(sorted(unknown)))

    selected = validate_fields(fields, PLAYER_FIELDS, default=PLAYER_FIELDS)
    order_field = validate_order(order_by, PLAYER_ORDER_FIELDS, "citizenid")
    direction = validate_order_direction(order)
    row_limit = clamp_limit(limit)

    clauses: list[str] = []
    params: list[Any] = []
    for key in ("job", "gang"):
        value = filters.get(key)
        if value is None or value == "":
            continue
        if not isinstance(value, str) or not _FILTER_VALUE_RE.fullmatch(value.strip()):
            raise ValidationError(f"{key} contains unsupported characters")
        clauses.append(f"`{key}` = %s")
        params.append(value.strip())

    updated_since = filters.get("updated_since")
    if updated_since is not None and updated_since != "":
        since = parse_since(updated_since)
        if since is not None:
            clauses.append("`last_updated` >= %s")
            params.append(_format_db_datetime(since))

    sql = "SELECT " + ", ".join(f"`{name}`" for name in selected) + " FROM `agent_player_snapshot`"
    if clauses:
        sql += " WHERE " + " AND ".join(clauses)
    sql += f" ORDER BY `{order_field}` {direction.upper()} LIMIT %s"
    params.append(row_limit)
    return _execute(sql, params)


def get_player_snapshot(citizenid: Any) -> dict[str, Any] | None:
    cid = validate_citizenid(citizenid)
    rows = _execute(
        "SELECT " + ", ".join(f"`{name}`" for name in PLAYER_FIELDS)
        + " FROM `agent_player_snapshot` WHERE `citizenid` = %s LIMIT 1",
        (cid,),
    )
    return rows[0] if rows else None


def get_player_timeline(citizenid: Any, limit: Any = DEFAULT_LIMIT, since: Any = None) -> list[dict[str, Any]]:
    cid = validate_citizenid(citizenid)
    row_limit = clamp_limit(limit)
    since_dt = parse_since(since)

    sql = (
        "SELECT "
        + ", ".join(f"`{name}`" for name in TIMELINE_FIELDS)
        + " FROM `agent_player_timeline` WHERE `citizenid` = %s"
    )
    params: list[Any] = [cid]
    if since_dt is not None:
        sql += " AND `occurred_at` >= %s"
        params.append(_format_db_datetime(since_dt))
    sql += " ORDER BY `occurred_at` DESC, `event_type` ASC, `source_table` ASC LIMIT %s"
    params.append(row_limit)
    return _execute(sql, params)


def list_events(since_id: Any = 0, type: Any = None, limit: Any = DEFAULT_LIMIT) -> list[dict[str, Any]]:
    """Return the append-only event feed ordered by the numeric cursor."""
    try:
        cursor = int(str(since_id).strip()) if since_id not in (None, "") else 0
    except (TypeError, ValueError):
        raise ValidationError("since_id must be a non-negative integer") from None
    if cursor < 0:
        raise ValidationError("since_id must be a non-negative integer")

    row_limit = clamp_limit(limit)
    event_type = validate_event_type(type)

    sql = (
        "SELECT "
        + ", ".join(f"`{name}`" for name in EVENT_FIELDS)
        + " FROM `agent_events_feed` WHERE `id` > %s"
    )
    params: list[Any] = [cursor]
    if event_type:
        if event_type.endswith("*"):
            prefix = event_type[:-1]
            sql += " AND LEFT(`event_type`, %s) = %s"
            params.extend([len(prefix), prefix])
        else:
            sql += " AND `event_type` = %s"
            params.append(event_type)
    sql += " ORDER BY `id` ASC LIMIT %s"
    params.append(row_limit)
    return _execute(sql, params)


def get_world_state(limit: Any = DEFAULT_LIMIT) -> list[dict[str, Any]]:
    row_limit = clamp_limit(limit)
    rows = _execute(
        "SELECT " + ", ".join(f"`{name}`" for name in WORLD_FIELDS)
        + " FROM `agent_world_state`"
        + " ORDER BY `changed_at` DESC, `region_id` ASC, `state_key` ASC LIMIT %s",
        (row_limit,),
    )
    return rows


def get_economy_metrics() -> list[dict[str, Any]]:
    return _execute(
        "SELECT " + ", ".join(f"`{name}`" for name in ECONOMY_FIELDS)
        + " FROM `agent_economy_metrics`"
        + " ORDER BY `total_bank` DESC, `job` ASC LIMIT %s",
        (HARD_LIMIT,),
    )


# ---------------------------------------------------------------------------
# World digest
# ---------------------------------------------------------------------------
def _optional_rows(sql: str, params: Sequence[Any] = ()) -> tuple[list[dict[str, Any]], bool]:
    """Run an optional view query; return ([], False) if the view is absent."""
    try:
        return _execute(sql, params), True
    except SchemaUnavailableError:
        return [], False


def _trim_last(container: dict[str, Any], key: str) -> bool:
    value = container.get(key)
    if isinstance(value, list) and value:
        value.pop()
        return True
    return False


def fit_digest_budget(digest: Mapping[str, Any], budget_tokens: int) -> dict[str, Any]:
    """Return a copy of ``digest`` whose JSON fits ``budget_tokens`` (4 chars/token).

    The function trims optional detail lists before dropping whole optional
    sections.  It never mutates the input.
    """
    budget = max(1, int(budget_tokens))
    budget_chars = budget * 4
    result = json.loads(_json_dumps(digest))
    result.setdefault("truncated", False)

    def fits() -> bool:
        return len(_json_dumps(result)) <= budget_chars

    def mark() -> None:
        result["truncated"] = True

    # 1. Trim detail lists, least important first.
    list_paths: tuple[tuple[str, ...], ...] = (
        ("risk", "stuck_quest_candidates"),
        ("recent_events",),
        ("events", "top_types"),
        ("economy", "top_jobs"),
        ("risk", "low_liquidity_players"),
    )
    for path in list_paths:
        parent: Any = result
        for key in path[:-1]:
            parent = parent.get(key) if isinstance(parent, dict) else None
        if not isinstance(parent, dict):
            continue
        while not fits() and _trim_last(parent, path[-1]):
            mark()

    # 2. Drop whole optional sections if the summary still does not fit.
    for key in ("recent_events", "risk", "events", "economy"):
        if fits():
            break
        if key in result:
            result.pop(key, None)
            mark()

    # 3. Last-resort compact summary.
    if not fits():
        compact = {
            "digest_version": result.get("digest_version", 1),
            "window_minutes": result.get("window_minutes"),
            "players": result.get("players", {}),
            "truncated": True,
        }
        if isinstance(compact["players"], dict):
            compact["players"] = {
                key: compact["players"].get(key)
                for key in ("total", "online", "online_is_estimate", "online_estimate", "recently_active")
                if key in compact["players"]
            }
        result = compact
        mark()

    # Keep the reported estimate consistent with the final serialized body.
    for _ in range(6):
        probe = {key: value for key, value in result.items() if key != "estimated_tokens"}
        estimate = estimate_tokens(probe)
        candidate = dict(result)
        candidate["estimated_tokens"] = estimate
        if len(_json_dumps(candidate)) <= budget_chars:
            result = candidate
            break
        # The estimate field itself pushed us over: remove optional data.
        if not _trim_last(result, "recent_events") and "risk" in result:
            result.pop("risk", None)
            mark()

    # A pathologically small budget must still be respected.  These fallbacks
    # are only reachable with budgets well below a useful digest (~50 tokens).
    if not fits():
        for minimal in (
            {"digest_version": result.get("digest_version", 1), "truncated": True},
            {"truncated": True},
            {},
        ):
            if len(_json_dumps(minimal)) <= budget_chars:
                result = minimal
                break

    return result


def get_world_digest(window_minutes: Any = DEFAULT_DIGEST_WINDOW_MINUTES, budget_tokens: Any = DEFAULT_DIGEST_BUDGET) -> dict[str, Any]:
    """Aggregate a small, budgeted world snapshot for an agent's first look.

    Data comes only from the agent views.  ``online_estimate`` is derived from
    ``agent_player_snapshot.last_updated`` because the read layer deliberately
    does not expose live session state.
    """
    window = clamp_int(
        window_minutes,
        DEFAULT_DIGEST_WINDOW_MINUTES,
        1,
        MAX_DIGEST_WINDOW_MINUTES,
        "window_minutes",
    )
    budget = clamp_int(
        budget_tokens,
        DEFAULT_DIGEST_BUDGET,
        MIN_DIGEST_BUDGET,
        MAX_DIGEST_BUDGET,
        "budget_tokens",
    )

    player_rows = _execute(
        "SELECT COUNT(*) AS total, "
        "COALESCE(SUM(CASE WHEN `last_updated` >= NOW() - INTERVAL "
        f"{window} MINUTE THEN 1 ELSE 0 END), 0) AS recently_active, "
        "COALESCE(SUM(CASE WHEN `last_updated` < NOW() - INTERVAL 24 HOUR "
        "THEN 1 ELSE 0 END), 0) AS stale_24h, "
        "COALESCE(SUM(CASE WHEN `cash` + `bank` < 100 THEN 1 ELSE 0 END), 0) AS low_liquidity "
        "FROM `agent_player_snapshot`"
    )
    player_stats = player_rows[0] if player_rows else {}

    economy_rows = _execute(
        "SELECT COUNT(*) AS job_groups, "
        "COALESCE(SUM(`player_count`), 0) AS players, "
        "COALESCE(SUM(`total_cash`), 0) AS total_cash, "
        "COALESCE(SUM(`total_bank`), 0) AS total_bank "
        "FROM `agent_economy_metrics`"
    )
    economy_stats = economy_rows[0] if economy_rows else {}
    top_jobs, _ = _optional_rows(
        "SELECT `job`, `player_count`, `total_bank` FROM `agent_economy_metrics` "
        "ORDER BY `total_bank` DESC, `job` ASC LIMIT 3"
    )

    event_rows, events_available = _optional_rows(
        "SELECT COUNT(*) AS total FROM `agent_events_feed` "
        f"WHERE `created_at` >= NOW() - INTERVAL {window} MINUTE"
    )
    event_total = int(event_rows[0].get("total", 0)) if event_rows else 0

    top_types: list[dict[str, Any]] = []
    recent_events: list[dict[str, Any]] = []
    if events_available:
        top_types, _ = _optional_rows(
            "SELECT `event_type` AS `type`, COUNT(*) AS `count` FROM `agent_events_feed` "
            f"WHERE `created_at` >= NOW() - INTERVAL {window} MINUTE "
            "GROUP BY `event_type` ORDER BY `count` DESC, `event_type` ASC LIMIT 5"
        )
        placeholders = ", ".join(["%s"] * len(IMPORTANT_EVENT_TYPES))
        # Use LEFT(...) rather than LIKE 'economy.%' so the query contains no
        # literal percent sign; mysql.connector treats '%' specially when
        # parameters are present.
        important_sql = (
            "SELECT `id`, `event_type`, `citizenid`, `created_at`, "
            "LEFT(COALESCE(`payload`, ''), 200) AS `payload_preview` "
            "FROM `agent_events_feed` "
            f"WHERE `created_at` >= NOW() - INTERVAL {window} MINUTE "
            f"AND (`event_type` IN ({placeholders}) OR LEFT(`event_type`, %s) = %s) "
            "ORDER BY `id` DESC LIMIT 5"
        )
        important_params = list(IMPORTANT_EVENT_TYPES) + [len("economy."), "economy."]
        recent_events, _ = _optional_rows(important_sql, important_params)
        if not recent_events:
            recent_events, _ = _optional_rows(
                "SELECT `id`, `event_type`, `citizenid`, `created_at`, "
                "LEFT(COALESCE(`payload`, ''), 200) AS `payload_preview` "
                "FROM `agent_events_feed` "
                f"WHERE `created_at` >= NOW() - INTERVAL {window} MINUTE "
                "ORDER BY `id` DESC LIMIT 5"
            )

    low_liquidity_players, _ = _optional_rows(
        "SELECT `citizenid`, `job`, `cash`, `bank` FROM `agent_player_snapshot` "
        "WHERE `cash` + `bank` < 100 ORDER BY (`cash` + `bank`) ASC, `citizenid` ASC LIMIT 5"
    )

    stuck: list[dict[str, Any]] = []
    stuck_available = True
    quest_rows, stuck_available = _optional_rows(
        "SELECT `citizenid`, `event_type`, `occurred_at`, "
        "TIMESTAMPDIFF(MINUTE, `occurred_at`, NOW()) AS `minutes_ago` "
        "FROM `agent_player_timeline` "
        "WHERE `source_table` = 'quest_event_log' AND `citizenid` IS NOT NULL "
        "AND `occurred_at` >= NOW() - INTERVAL 7 DAY "
        "ORDER BY `occurred_at` DESC, `event_type` ASC LIMIT 200"
    )
    if stuck_available:
        latest: dict[str, dict[str, Any]] = {}
        for row in quest_rows:
            cid = row.get("citizenid")
            if cid and cid not in latest:
                latest[cid] = row
        for cid, row in latest.items():
            minutes_ago = row.get("minutes_ago")
            if not isinstance(minutes_ago, int):
                continue
            if row.get("event_type") in TERMINAL_QUEST_EVENT_TYPES:
                continue
            if minutes_ago >= 30:
                stuck.append(
                    {
                        "citizenid": cid,
                        "event_type": row.get("event_type"),
                        "occurred_at": row.get("occurred_at"),
                        "minutes_ago": minutes_ago,
                    }
                )
        stuck = sorted(stuck, key=lambda item: item.get("minutes_ago", 0), reverse=True)[:5]

    digest: dict[str, Any] = {
        "digest_version": 1,
        "generated_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "window_minutes": window,
        "budget_tokens": budget,
        "players": {
            "total": int(player_stats.get("total", 0) or 0),
            "online": int(player_stats.get("recently_active", 0) or 0),
            "online_is_estimate": True,
            "online_estimate": int(player_stats.get("recently_active", 0) or 0),
            "online_estimate_note": (
                "derived from agent_player_snapshot.last_updated; true session "
                "state is not exposed by the read layer"
            ),
            "recently_active": int(player_stats.get("recently_active", 0) or 0),
            "stale_24h": int(player_stats.get("stale_24h", 0) or 0),
        },
        "events": {
            "available": events_available,
            "total": event_total,
            "top_types": top_types,
        },
        "recent_events": recent_events,
        "economy": {
            "job_groups": int(economy_stats.get("job_groups", 0) or 0),
            "players": int(economy_stats.get("players", 0) or 0),
            "total_cash": economy_stats.get("total_cash", 0),
            "total_bank": economy_stats.get("total_bank", 0),
            "top_jobs": top_jobs,
        },
        "risk": {
            "low_liquidity_count": int(player_stats.get("low_liquidity", 0) or 0),
            "low_liquidity_players": low_liquidity_players,
            "stuck_quest_available": stuck_available,
            "stuck_quest_candidates": stuck,
        },
        "truncated": False,
    }
    return fit_digest_budget(digest, budget)


if __name__ == "__main__":
    # Tiny manual smoke helper; the real surfaces are agent_gateway.py and
    # agent_mcp.py.  It never prints credentials.
    import argparse

    parser = argparse.ArgumentParser(description="Read-only agent data smoke check")
    parser.add_argument("--digest", action="store_true", help="print the world digest")
    parser.add_argument("--window", type=int, default=DEFAULT_DIGEST_WINDOW_MINUTES)
    parser.add_argument("--budget", type=int, default=DEFAULT_DIGEST_BUDGET)
    args = parser.parse_args()
    if args.digest:
        print(json.dumps(get_world_digest(args.window, args.budget), indent=2, ensure_ascii=False))
    else:
        print(
            json.dumps(
                {
                    "backend": backend_name(),
                    "database_reachable": db_ping(),
                    "schema_version": get_schema().get("schema_version"),
                    "views": sorted(get_schema().get("views", {})),
                },
                indent=2,
                ensure_ascii=False,
            )
        )
