"""SM-03 outbox + intent TTL contracts (v3.12).

Two layers:

* the pure-Lua harness drives the real ``Outbox.Enqueue/Work`` code from
  ``custom-police/server/p2_system.lua`` against the MySQL stub
  (``tests/agent/lua/cases/police_outbox.lua``): enqueue, success, backoff,
  attempt cap, invalid payload and cleanup;
* static assertions pin the SQL semantics that need a live DB: a ``done``
  intent replays for 7 days, a ``pending`` intent is retryable after 10
  minutes, and the migration stays idempotent.

No FXServer, no MySQL, no network.

    python3 -m pytest -q tests/unit/layer3_business/test_police_outbox.py
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]  # T-CityLite.base/
REPO_ROOT = BASE.parent
RUNNER = BASE / "tests" / "agent" / "lua" / "runner.lua"
P2 = BASE / "resources" / "[custom]" / "custom-police" / "server" / "p2_system.lua"
P0 = BASE / "resources" / "[custom]" / "custom-police" / "server" / "p0.lua"
P1 = BASE / "resources" / "[custom]" / "custom-police" / "server" / "p1.lua"
P4 = BASE / "resources" / "[custom]" / "custom-police" / "server" / "p4_npc.lua"
PHONE = BASE / "resources" / "[custom]" / "custom-phone" / "server" / "core" / "notify.lua"
PHONE_MDT = BASE / "resources" / "[custom]" / "custom-phone" / "server" / "apps" / "police_mdt.lua"
MIGRATION = BASE / "migrations" / "v3.12_police_outbox.sql"
LUA_BIN = shutil.which("lua5.4")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _run_lua_case(tmp_path: Path) -> dict:
    out_file = tmp_path / "police_outbox.json"
    result = subprocess.run(
        [
            LUA_BIN,
            str(RUNNER),
            "--case",
            "police_outbox",
            "--out",
            str(out_file),
        ],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=30,
        env={**os.environ, "TCITY_ROOT": str(REPO_ROOT), "TZ": "UTC"},
    )
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    return json.loads(out_file.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Behaviour (Lua harness)
# ---------------------------------------------------------------------------

@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_outbox_case_passes(tmp_path: Path) -> None:
    payload = _run_lua_case(tmp_path)
    assert payload["ok"] is True, payload
    assert payload["data"]["failed"] == 0
    names = {item["name"] for item in payload["data"]["results"]}
    assert {
        "enqueue_persists_pending_and_kicks_worker",
        "delivery_marks_done_once",
        "retry_backoff_30s_then_2m_then_10m",
        "fifth_failure_marks_failed",
        "invalid_payload_fails_without_calling_phone",
        "cleanup_deletes_old_done_and_failed_rows",
    } <= names


# ---------------------------------------------------------------------------
# Migration
# ---------------------------------------------------------------------------

def test_v312_migration_is_guarded_and_idempotent():
    sql = read(MIGRATION)

    # Both new intent columns are information_schema-guarded.
    assert sql.count("information_schema.COLUMNS") == 2
    assert "COLUMN_NAME = 'expires_at'" in sql
    assert "COLUMN_NAME = 'completed_at'" in sql
    assert "ADD COLUMN expires_at DATETIME NULL AFTER result_json" in sql
    assert "ADD COLUMN completed_at DATETIME NULL AFTER expires_at" in sql

    # The outbox table and its worker index are creation-guarded too.
    assert sql.count("information_schema.TABLES") == 1
    assert "TABLE_NAME = 'police_outbox'" in sql
    assert "CREATE TABLE IF NOT EXISTS police_outbox" in sql
    for column in ("id", "topic", "payload", "status", "attempts",
                   "next_attempt_at", "created_at", "updated_at"):
        assert column in sql, f"police_outbox missing {column}"
    assert "ENUM(''pending'',''done'',''failed'')" in sql
    assert "KEY idx_status_next (status, next_attempt_at)" in sql
    assert "information_schema.STATISTICS" in sql

    # Re-runnable and non-destructive.
    for statement in ("DROP TABLE", "TRUNCATE", "DELETE FROM"):
        assert statement not in sql
    assert len(re.findall(r"^PREPARE stmt_", sql, re.M)) == 4
    assert sql.count("DEALLOCATE PREPARE") == 4


# ---------------------------------------------------------------------------
# Intent TTL
# ---------------------------------------------------------------------------

def test_done_intent_replays_for_seven_days():
    src = read(P2)
    assert "expires_at = NOW() + INTERVAL 7 DAY" in src
    assert "completed_at = NOW()" in src
    # Both the success path and the "committed but unencodable" path set a TTL.
    assert src.count("expires_at = NOW() + INTERVAL 7 DAY") == 2
    assert "COALESCE(expires_at, created_at + INTERVAL 7 DAY) < NOW()" in src
    # A done row is only replayed while it has not expired.
    assert "if dbFlag(existing.expired) then" in src
    assert "deleteIntent(key)" in src


def test_pending_intent_is_retryable_after_ten_minutes():
    src = read(P2)
    assert "created_at < NOW() - INTERVAL 10 MINUTE" in src
    assert "AS stale_pending" in src
    assert "if dbFlag(existing.stale_pending) then" in src
    # The stale row is freed instead of blocking the key forever.
    block = src[src.index("local function withIntent("):]
    block = block[: block.index("\nend\n", block.index("return fail('in_progress')"))]
    assert "deleteIntent(key)" in block
    assert "return fail('in_progress')" in block


def test_intent_sweep_runs_on_start_and_on_every_claim():
    src = read(P2)
    start = src.index("local function sweepIntents()")
    sweep = src[start: src.index("AddEventHandler('onResourceStart'", start)]
    # Expired done, stale pending and failed rows are all swept.
    assert "(status = 'done'" in sweep
    assert "(status = 'pending' AND created_at < NOW() - INTERVAL 10 MINUTE)" in sweep
    assert "OR status = 'failed'" in sweep
    assert "LIMIT 200" in sweep
    handler = src.index("AddEventHandler('onResourceStart'", start)
    assert "sweepIntents()" in src[handler:]
    assert src.index("sweepIntents()", src.index("local function withIntent(")) > 0


# ---------------------------------------------------------------------------
# Outbox worker
# ---------------------------------------------------------------------------

def test_outbox_worker_interval_batch_and_backoff():
    src = read(P2)
    assert "local OUTBOX_INTERVAL_MS = 30000" in src
    assert "local OUTBOX_MAX_ATTEMPTS = 5" in src
    assert "OUTBOX_BACKOFF_SECONDS = { 30, 120, 600 }" in src
    assert "LIMIT 50" in src
    assert "ORDER BY id ASC" in src
    assert "next_attempt_at IS NULL OR next_attempt_at <= NOW()" in src
    assert "DATE_ADD(NOW(), INTERVAL ? SECOND)" in src
    assert "INTERVAL 60 SECOND" in src  # delivery lease
    assert "exports('EnqueueOutbox'" in src
    assert "exports['custom-phone']:Notify(" in src
    assert "status = 'done'" in src
    assert "status = 'failed'" in src
    # The loop is 30s, not a busy spin.
    assert "Wait(OUTBOX_INTERVAL_MS)" in src


def test_police_notification_sites_never_write_the_phone_table():
    for path in (P0, P1, P2, P4):
        src = read(path)
        assert "INSERT INTO phone_notifications" not in src, path
        assert "phone:client:newNotification" not in src, path
        if path != P2:
            assert "Outbox.Enqueue('notification'" in src, path
            # Degraded fallback still goes through the owner export.
            assert "exports['custom-phone']:Notify(" in src, path
    # p2_system enqueues with the shared topic constant.
    assert "Outbox.Enqueue(OUTBOX_TOPIC_NOTIFICATION" in read(P2)


def test_phone_owner_export_validates_and_pushes():
    src = read(PHONE)
    block = src[src.index("exports('Notify'"):]
    block = block[: block.index("\nend)", block.index("return true, id"))]
    assert "NOTIFY_APP_IDS" in src
    assert "banking = true" in src and "police_mdt = true" in src
    assert "Sms.TruncateBytes(title, 200)" in src
    assert "Sms.TruncateChars(content, 1000)" in src
    assert "invalidateCache(citizenid)" in block
    assert "PushStoredNotification(targetSrc, normalised, id)" in block
    assert "MySQL.insert.await(" in block
    assert "PhoneDb.InsertId(result)" in block

    mdt = read(PHONE_MDT)
    assert "INSERT INTO phone_notifications" not in mdt
    assert "exports['custom-phone']:Notify(officer.citizenid, title, message" in mdt
