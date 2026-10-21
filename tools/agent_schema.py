#!/usr/bin/env python3
"""Introspect the agent read-layer views and emit a stable JSON contract.

The generator is intentionally dependency-free.  It prefers ``mysql.connector``
when that package is installed and otherwise shells out to the MariaDB/MySQL
CLI.  Credentials are read from the environment (``TCITY_DB_*``) or from the
repository ``.env`` file; no password is ever written to the output.

Output: T-CityLite.base/docs/agent/schema.json

Usage:
    set -a; . ./.env; set +a
    python3 tools/agent_schema.py
    python3 tools/agent_schema.py --output /tmp/schema.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = REPO_ROOT / "T-CityLite.base" / "docs" / "agent" / "schema.json"

VIEWS = (
    "agent_player_snapshot",
    "agent_player_timeline",
    "agent_world_state",
    "agent_economy_metrics",
    "agent_events_feed",
)

VIEW_DESCRIPTIONS = {
    "agent_player_snapshot": (
        "One flat row per player: citizenid, display name, job/gang names, "
        "cash/bank/crypto balances, character first/last name, last_updated. "
        "License, identifier, position, inventory, metadata and phone are excluded."
    ),
    "agent_player_timeline": (
        "Read-only UNION ALL of quest_event_log, player_choices and "
        "bank_statements. event_type is namespaced (quest.*, story.choice, "
        "economy.*); payload is a JSON object; source_table identifies the origin."
    ),
    "agent_world_state": (
        "world_state rows plus one summary row per world_events.event_type. "
        "When both source tables are empty, a single source_table='fallback' row "
        "is returned instead of an empty result."
    ),
    "agent_economy_metrics": (
        "Per-job aggregates from players: player_count, total_cash, total_bank, "
        "avg_bank and max_bank. Cash/bank are extracted from the players.money JSON."
    ),
    "agent_events_feed": (
        "Read-only, SECURITY DEFINER view over the append-only agent_events "
        "outbox. id is the monotonic cursor for since_id pagination; payload is a "
        "JSON object written by the v2.2.1 triggers. The view has no write path."
    ),
}

VIEW_SOURCES = {
    "agent_player_snapshot": ["players"],
    "agent_player_timeline": ["quest_event_log", "player_choices", "bank_statements"],
    "agent_world_state": ["world_state", "world_events"],
    "agent_economy_metrics": ["players"],
    "agent_events_feed": ["agent_events"],
}


def load_env_file(path: Path) -> None:
    """Load simple KEY=VALUE lines without overwriting the real environment."""
    if not path.is_file():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key or key in os.environ:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        os.environ[key] = value


def db_config() -> dict[str, str]:
    load_env_file(REPO_ROOT / ".env")
    required = ("TCITY_DB_HOST", "TCITY_DB_USER", "TCITY_DB_PASS", "TCITY_DB_NAME")
    missing = [key for key in required if not os.environ.get(key)]
    if missing:
        raise RuntimeError(
            "missing database settings: " + ", ".join(missing) +
            " (source .env or export them; see .env.example)"
        )
    return {
        "host": os.environ["TCITY_DB_HOST"],
        "port": os.environ.get("TCITY_DB_PORT", "3306"),
        "user": os.environ["TCITY_DB_USER"],
        "password": os.environ["TCITY_DB_PASS"],
        "database": os.environ["TCITY_DB_NAME"],
    }


def _rows_to_columns(rows: list[tuple[str, str, str, str]]) -> dict[str, list[tuple[str, str, str]]]:
    columns: dict[str, list[tuple[str, str, str]]] = {view: [] for view in VIEWS}
    for table_name, column_name, column_type, is_nullable in rows:
        if table_name in columns:
            columns[table_name].append((column_name, column_type, is_nullable))
    return columns


def introspect_with_connector(cfg: dict[str, str]):
    import mysql.connector  # type: ignore[import-not-found]

    placeholders = ", ".join(["%s"] * len(VIEWS))
    sql = (
        "SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE "
        "FROM information_schema.COLUMNS "
        f"WHERE TABLE_SCHEMA = %s AND TABLE_NAME IN ({placeholders}) "
        "ORDER BY TABLE_NAME, ORDINAL_POSITION"
    )
    conn = mysql.connector.connect(
        host=cfg["host"],
        port=int(cfg["port"]),
        user=cfg["user"],
        password=cfg["password"],
        database=cfg["database"],
        connection_timeout=10,
    )
    try:
        cursor = conn.cursor()
        cursor.execute(sql, (cfg["database"], *VIEWS))
        return _rows_to_columns([tuple(row) for row in cursor.fetchall()])
    finally:
        conn.close()


def introspect_with_cli(cfg: dict[str, str]):
    mysql = shutil.which("mysql") or shutil.which("mariadb")
    if not mysql:
        raise RuntimeError(
            "neither mysql.connector nor a mysql/mariadb CLI was found"
        )

    db = cfg["database"].replace("'", "''")
    quoted_views = ", ".join(f"'{view}'" for view in VIEWS)
    sql = (
        "SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE "
        "FROM information_schema.COLUMNS "
        f"WHERE TABLE_SCHEMA = '{db}' AND TABLE_NAME IN ({quoted_views}) "
        "ORDER BY TABLE_NAME, ORDINAL_POSITION;"
    )
    cmd = [
        mysql,
        "--default-character-set=utf8mb4",
        "--batch",
        "--skip-column-names",
        "--raw",
        "-h", cfg["host"],
        "-P", cfg["port"],
        "-u", cfg["user"],
        cfg["database"],
    ]
    env = os.environ.copy()
    env["MYSQL_PWD"] = cfg["password"]
    proc = subprocess.run(
        cmd, input=sql, text=True, capture_output=True, env=env, check=False
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or f"exit code {proc.returncode}"
        raise RuntimeError(f"mysql CLI introspection failed: {detail}")

    rows = []
    for line in proc.stdout.splitlines():
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 4:
            raise RuntimeError(f"unexpected mysql output row: {line!r}")
        rows.append(tuple(parts))
    return _rows_to_columns(rows)


def pii_reason(field_name: str) -> str | None:
    """Return a short reason when a field is personally identifying."""
    name = field_name.lower()
    if name == "license" or name.endswith("_license") or name.startswith("license_"):
        return "license"
    if name == "ip" or name.startswith("ip_") or name.endswith("_ip"):
        return "ip"
    if "identifier" in name:
        return "identifier"
    if (
        name == "position"
        or name.startswith("position_")
        or name.endswith("_position")
        or "_position_" in name
    ):
        return "position"
    if name in {"name", "firstname", "lastname"}:
        return "display_name"
    return None


def build_schema(columns: dict[str, list[tuple[str, str, str]]], database: str) -> dict:
    missing = [view for view in VIEWS if not columns.get(view)]
    if missing:
        raise RuntimeError(
            "missing or empty views: " + ", ".join(missing) +
            " (apply T-CityLite.base/migrations/v2.2_agent_read_layer.sql and "
            "v2.2.2_agent_events_view.sql first)"
        )

    views: dict[str, dict] = {}
    for view in VIEWS:
        fields = []
        for name, column_type, is_nullable in columns[view]:
            # MariaDB appends version markers such as
            # "datetime(3) /* mariadb-5.3 */"; keep the contract stable.
            column_type = re.sub(r"\s*/\*.*?\*/", "", column_type).strip()
            reason = pii_reason(name)
            field = {
                "name": name,
                "type": column_type,
                "nullable": is_nullable.upper() == "YES",
                "pii": reason is not None,
            }
            if reason is not None:
                field["pii_reason"] = reason
            fields.append(field)
        views[view] = {
            "description": VIEW_DESCRIPTIONS[view],
            "source_tables": VIEW_SOURCES[view],
            "pii_fields": [field["name"] for field in fields if field["pii"]],
            "fields": fields,
        }

    return {
        "schema_version": 1,
        "database": database,
        "generated_by": "tools/agent_schema.py",
        "views": views,
    }


def write_schema(schema: dict, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    tmp = output.with_name(output.name + ".tmp")
    tmp.write_text(
        json.dumps(schema, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    tmp.replace(output)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Introspect the agent_* views and write docs/agent/schema.json"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"output path (default: {DEFAULT_OUTPUT})",
    )
    args = parser.parse_args(argv)

    try:
        cfg = db_config()
        try:
            columns = introspect_with_connector(cfg)
            backend = "mysql.connector"
        except ImportError:
            columns = introspect_with_cli(cfg)
            backend = "mysql CLI"
        schema = build_schema(columns, cfg["database"])
    except (RuntimeError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    write_schema(schema, args.output)
    field_count = sum(len(view["fields"]) for view in schema["views"].values())
    print(
        f"Wrote {args.output} via {backend}: "
        f"{len(schema['views'])} views, {field_count} fields, "
        f"schema_version={schema['schema_version']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
