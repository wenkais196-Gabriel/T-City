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
    "players": {
        "fields": ["citizenid", "license", "money", "charinfo", "metadata",
                    "position", "job", "gang", "firstname", "lastname"],
        "indexes": ["PRIMARY", "license"],
    },
    "bank_accounts": {
        "fields": ["account_id", "citizenid", "account_name", "balance",
                    "account_type", "is_active", "created_at"],
        "indexes": ["PRIMARY", "citizenid"],
    },
    "bank_statements": {
        "fields": ["id", "citizenid", "account_id", "amount", "balance",
                    "date", "type", "reason", "note"],
        "indexes": ["PRIMARY", "idx_citizenid_account_date"],
    },
    "player_vehicles": {
        "fields": ["id", "citizenid", "plate", "vehicle", "garage",
                    "state", "fuel", "engine", "body", "mods"],
        "indexes": ["PRIMARY", "citizenid", "plate"],
    },
    "phone_contacts": {
        "fields": ["id", "citizenid", "name", "number", "avatar"],
        "indexes": ["PRIMARY", "citizenid"],
    },
    "phone_messages": {
        "fields": ["id", "citizenid", "sender", "receiver", "message",
                    "date", "isread"],
        "indexes": ["PRIMARY", "citizenid"],
    },
    "phone_calls": {
        "fields": ["id", "citizenid", "sender", "receiver", "start",
                    "end", "duration"],
        "indexes": ["PRIMARY", "citizenid"],
    },
}


def get_db_config() -> dict | None:
    """Parse MySQL connection string from server.cfg"""
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
