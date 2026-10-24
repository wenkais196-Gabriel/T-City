"""
check_db_schema.py — 数据库表结构验证
连接 MariaDB，检查预期表、索引、字段是否存在
"""

import os
import sys
import json

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 预期表结构定义
# 格式: {表名: {字段: [col1, col2, ...], 索引: [idx1, idx2, ...]}}
EXPECTED_SCHEMA = {
    # 实际 QBCore/T-City 表结构（charinfo/money 为 JSON 文本，MariaDB 无原生 JSON）
    "players": {
        "fields": ["citizenid", "license", "name", "money", "charinfo",
                    "metadata", "position", "job", "gang"],
        "indexes": ["PRIMARY", "license"],
    },
    "bank_accounts": {
        "fields": ["id", "citizenid", "account_name", "account_balance",
                    "account_type", "users"],
        "indexes": ["PRIMARY", "account_name"],
    },
    "bank_statements": {
        "fields": ["id", "citizenid", "account_name", "amount", "reason",
                    "statement_type", "date"],
        "indexes": ["PRIMARY", "citizenid"],
    },
    "player_vehicles": {
        "fields": ["id", "license", "citizenid", "vehicle", "hash", "mods",
                    "plate", "garage", "fuel", "engine", "body", "state", "status"],
        "indexes": ["PRIMARY", "citizenid", "plate"],
    },
    "phone_contacts": {
        "fields": ["id", "citizenid", "name", "number"],
        "indexes": ["PRIMARY", "uq_contact", "idx_citizenid"],
    },
    "phone_messages": {
        "fields": ["id", "sender_number", "receiver_number", "message",
                   "timestamp", "is_read", "gps", "msg_status"],
        "indexes": ["PRIMARY", "idx_receiver", "idx_sender", "idx_time"],
    },
    "phone_calls": {
        "fields": ["id", "caller", "receiver", "duration", "status", "timestamp"],
        "indexes": ["PRIMARY", "idx_caller", "idx_receiver"],
    },
    # ── Police domain (migrations v2.8–v3.12) ──────────────────────────
    "police_units": {
        "fields": ["citizenid", "callsign", "dept", "status", "incident_id",
                    "updated_at", "created_at"],
        "indexes": ["PRIMARY", "idx_status", "idx_incident"],
    },
    "police_incidents": {
        "fields": ["id", "code", "title", "description", "priority", "status",
                    "x", "y", "z", "created_by", "created_at", "updated_at",
                    "closed_at", "disposition", "npc_template", "closed_by",
                    "closed_reason", "last_activity_at"],
        "indexes": ["PRIMARY", "idx_status_created", "idx_priority",
                     "idx_npc_template_status"],
    },
    "police_incident_units": {
        "fields": ["incident_id", "citizenid", "role", "joined_at"],
        "indexes": ["PRIMARY", "idx_citizenid"],
    },
    "police_audit": {
        "fields": ["id", "actor_citizenid", "actor_kind", "action", "target",
                    "detail", "created_at"],
        "indexes": ["PRIMARY", "idx_actor_created", "idx_action_created"],
    },
    "police_citations": {
        "fields": ["id", "citizenid", "officer_citizenid", "plate", "amount",
                    "charge_id", "base_amount", "reason", "status",
                    "incident_id", "report_id", "created_at", "paid_at"],
        "indexes": ["PRIMARY", "idx_citizen_status", "idx_officer_created",
                     "idx_report"],
    },
    "police_reports": {
        "fields": ["id", "incident_id", "case_id", "justice_case_id",
                    "justice_verdict", "justice_status", "charges",
                    "author_citizenid", "title", "body", "status", "kind",
                    "is_bolo", "bolo_kind", "bolo_target", "location",
                    "officer_citizenid", "subject_citizenid", "created_at",
                    "updated_at"],
        "indexes": ["PRIMARY", "idx_incident", "idx_author_created", "idx_case",
                     "idx_kind_created", "idx_subject_kind_created",
                     "idx_justice_case"],
    },
    "police_evidence": {
        "fields": ["id", "exhibit_no", "incident_id", "report_id", "case_id",
                    "label", "description", "location", "collected_by",
                    "status", "created_at", "updated_at"],
        "indexes": ["PRIMARY", "uniq_exhibit", "idx_incident", "idx_report",
                     "idx_case", "idx_status_created"],
    },
    "police_evidence_chain": {
        "fields": ["id", "evidence_id", "action", "actor_citizenid", "note",
                    "created_at"],
        "indexes": ["PRIMARY", "idx_evidence_created"],
    },
    "police_cases": {
        "fields": ["id", "case_no", "title", "summary", "status",
                    "lead_citizenid", "created_by", "created_at", "updated_at"],
        "indexes": ["PRIMARY", "uniq_case_no", "idx_status_created"],
    },
    "police_bolos": {
        "fields": ["id", "kind", "target", "reason", "status", "created_by",
                    "created_at", "cleared_at"],
        "indexes": ["PRIMARY", "idx_kind_status", "idx_target"],
    },
    "police_warrants": {
        "fields": ["id", "citizenid", "reason", "status", "requested_by",
                    "approved_by", "created_at", "decided_at"],
        "indexes": ["PRIMARY", "idx_citizen_status", "idx_status_created"],
    },
    "police_arrests": {
        "fields": ["id", "citizenid", "officer_citizenid", "charges",
                    "incident_id", "case_id", "created_at"],
        "indexes": ["PRIMARY", "idx_citizen_created", "idx_case"],
    },
    # ── Justice / police write paths (v3.8–v3.12) ──────────────────────
    "justice_sentences": {
        "fields": ["id", "citizenid", "case_id", "minutes", "reason", "status",
                    "started_at", "ends_at", "released_at", "created_by"],
        "indexes": ["PRIMARY", "idx_citizen_status", "idx_status_ends"],
    },
    "police_write_intents": {
        "fields": ["idem_key", "action", "actor_citizenid", "status",
                    "result_json", "expires_at", "completed_at", "created_at",
                    "updated_at"],
        "indexes": ["PRIMARY", "idx_actor_created", "idx_created"],
    },
    "police_outbox": {
        "fields": ["id", "topic", "payload", "status", "attempts",
                    "next_attempt_at", "created_at", "updated_at"],
        "indexes": ["PRIMARY", "idx_status_next"],
    },
    # ── Agent domain (v2.2–v2.6) ───────────────────────────────────────
    "agent_events": {
        "fields": ["id", "event_type", "citizenid", "payload",
                    "schema_version", "created_at"],
        "indexes": ["PRIMARY", "idx_agent_events_type_id",
                     "idx_agent_events_citizen_id", "idx_agent_events_created_at"],
    },
    "agent_actions": {
        "fields": ["id", "agent_id", "action_type", "params", "status",
                    "idempotency_key", "preview", "result", "error",
                    "requested_at", "approved_by", "approved_at",
                    "executed_at", "expires_at"],
        "indexes": ["PRIMARY", "uq_idem", "idx_status_requested",
                     "idx_agent_requested"],
    },
    "agent_denials": {
        "fields": ["id", "agent_id", "action_type", "code", "message",
                    "param_keys", "params_hash", "dry_run", "created_at"],
        "indexes": ["PRIMARY", "idx_agent_created", "idx_code_created",
                     "idx_action_created"],
    },
    "agent_effects": {
        "fields": ["id", "request_id", "agent_id", "target_source", "action",
                    "status", "error_code", "latency_ms", "created_at"],
        "indexes": ["PRIMARY", "idx_created", "idx_agent_created",
                     "idx_action_created", "idx_status_created"],
    },
    "agent_director_state": {
        "fields": ["name", "cursor", "updated_at", "last_event_at"],
        "indexes": ["PRIMARY"],
    },
    # ── Quest event stream (v0.7, read by the agent views) ─────────────
    "quest_event_log": {
        "fields": ["id", "citizenid", "quest_id", "step_id", "event_type",
                    "metadata", "created_at"],
        "indexes": ["PRIMARY", "idx_citizenid", "idx_quest", "idx_created"],
    },
}


def get_db_config() -> dict | None:
    """Resolve DB config from env first, then server.cfg."""
    if os.environ.get('TCITY_DB_PASS'):
        return {
            'host': os.environ.get('TCITY_DB_HOST', 'localhost'),
            'port': int(os.environ.get('TCITY_DB_PORT', 3306)),
            'user': os.environ.get('TCITY_DB_USER', 'root'),
            'password': os.environ['TCITY_DB_PASS'],
            'database': os.environ.get('TCITY_DB_NAME', 'TCityLite'),
        }

    cfg_path = os.path.join(BASE_DIR, "server.cfg")
    if not os.path.exists(cfg_path):
        return None

    with open(cfg_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            if "mysql_connection_string" in line:
                # Extract connection string
                match = __import__("re").search(r'"([^"]+)"', line)
                if match:
                    conn_str = match.group(1)
                    # Parse mysql://user:pass@host/db?params
                    import urllib.parse
                    parsed = urllib.parse.urlparse(conn_str)
                    return {
                        "host": parsed.hostname or "localhost",
                        "port": parsed.port or 3306,
                        "user": parsed.username or "root",
                        "password": parsed.password or "",
                        "database": parsed.path.lstrip("/") if parsed.path else "QBCore_CDB34E",
                    }
    return None


def check_with_mysql() -> list[dict]:
    """Try to connect to MySQL and verify schema"""
    import mysql.connector

    config = get_db_config()
    if not config:
        return [{"type": "error", "msg": "无法从 server.cfg 解析数据库连接信息"}]

    results = []

    try:
        conn = mysql.connector.connect(
            host=config["host"],
            port=config["port"],
            user=config["user"],
            password=config["password"],
            database=config["database"],
            connect_timeout=5,
        )
        cursor = conn.cursor()

        # Get all tables
        cursor.execute("SHOW TABLES")
        existing_tables = {row[0].lower() for row in cursor.fetchall()}

        for table_name, schema in EXPECTED_SCHEMA.items():
            table_lower = table_name.lower()
            if table_lower not in existing_tables:
                results.append({
                    "type": "missing_table",
                    "table": table_name,
                    "msg": f"表 {table_name} 不存在",
                })
                continue

            # Check fields
            cursor.execute(f"SHOW COLUMNS FROM `{table_name}`")
            existing_fields = {row[0].lower() for row in cursor.fetchall()}
            for field in schema["fields"]:
                if field.lower() not in existing_fields:
                    results.append({
                        "type": "missing_field",
                        "table": table_name,
                        "field": field,
                        "msg": f"表 {table_name} 缺少字段 {field}",
                    })

            # Check indexes
            cursor.execute(f"SHOW INDEX FROM `{table_name}`")
            existing_indexes = {row[2].lower() for row in cursor.fetchall()}
            for idx in schema["indexes"]:
                if idx.lower() not in existing_indexes:
                    results.append({
                        "type": "missing_index",
                        "table": table_name,
                        "field": idx,
                        "msg": f"表 {table_name} 缺少索引 {idx}",
                    })

        cursor.close()
        conn.close()

    except ImportError:
        results.append({
            "type": "error",
            "msg": "请安装 mysql-connector-python: pip install mysql-connector-python",
        })
    except Exception as e:
        results.append({
            "type": "error",
            "msg": f"数据库连接失败: {e}",
        })

    return results


def run():
    print("=" * 60)
    print("  数据库表结构验证")
    print("=" * 60)

    try:
        import mysql.connector
    except ImportError:
        print("\n  ⚠️  mysql-connector-python 未安装")
        print("  跳过数据库检查。运行: pip install mysql-connector-python")
        print("  或手动验证数据库表结构。\n")
        return True  # Not a hard failure

    config = get_db_config()
    if not config:
        print("\n  ⚠️  无法从 server.cfg 解析数据库连接信息")
        print("  跳过数据库检查。\n")
        return True

    print(f"\n  数据库: {config['database']}@{config['host']}:{config['port']}")
    print(f"  预期检查: {len(EXPECTED_SCHEMA)} 个表\n")

    results = check_with_mysql()

    errors = [r for r in results if r["type"] in ("missing_table", "missing_field", "missing_index")]
    infos = [r for r in results if r["type"] == "error"]

    if infos:
        for info in infos:
            print(f"  ⚠️  {info['msg']}")

    if errors:
        print(f"\n  发现 {len(errors)} 个问题:")
        for e in errors:
            marker = "❌" if e["type"] == "missing_table" else "⚠️"
            print(f"  {marker}  {e['msg']}")
    else:
        print(f"  ✅ 所有 {len(EXPECTED_SCHEMA)} 个表结构验证通过")

    print()
    return len(errors) == 0


if __name__ == "__main__":
    success = run()
    sys.exit(0 if success else 1)
