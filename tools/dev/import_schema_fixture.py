"""把 schema 基线 dump 灌进一个现成的 MariaDB（CI 的 DB 任务用它）。

为什么不用命令行客户端：
    ubuntu-latest 上的 `mariadb` 客户端会随 apt 漂移，曾漂移成"默认要求 TLS"，
    而 CI 的 `mariadb:10.11` 服务容器没开 TLS —— 直接报
    `SSL is required, but the server does not support it`，整条 DB 任务红。
    改用测试套件本来就在用的 `mysql-connector-python`，客户端库只有一份，不再受 CLI 版本影响。
    也不接受在命令行里关 TLS 或内联口令的写法（那既是不安全的形状，也会被安全闸门判红）。

用法：
    TCITY_DB_HOST=<host> TCITY_DB_PORT=<port> TCITY_DB_USER=<user> \
    TCITY_DB_PASS=<pass> TCITY_DB_NAME=<db> \
    python tools/dev/import_schema_fixture.py [schema.sql]

退出码：0 成功；2 连不上 / 执行失败（CI 直接红，不静默跳过 —— 跳过了 DB 用例会在没有表的情况下
跑出一堆假红，比缺表本身更难查）。
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_SQL = REPO / "T-CityLite.base" / "tests" / "fixtures" / "tcity_schema.sql"


def connect():
    import mysql.connector
    from mysql.connector.constants import ClientFlag

    return mysql.connector.connect(
        host=os.environ.get("TCITY_DB_HOST", "127.0.0.1"),
        port=int(os.environ.get("TCITY_DB_PORT", "3306")),
        user=os.environ.get("TCITY_DB_USER", "root"),
        password=os.environ.get("TCITY_DB_PASS", ""),
        database=os.environ.get("TCITY_DB_NAME", "tcity_ci"),
        # dump 里是几十条语句：一次多选题执行完，省掉"自己切分号"这种容易切坏注释的活。
        client_flags=[ClientFlag.MULTI_STATEMENTS],
        autocommit=True,
    )


def main(argv: list[str]) -> int:
    sql_path = Path(argv[1]) if len(argv) > 1 else DEFAULT_SQL
    if not sql_path.is_file():
        print(f"[import-schema] 找不到 {sql_path}", file=sys.stderr)
        return 2
    sql = sql_path.read_text(encoding="utf-8")

    try:
        connection = connect()
    except Exception as error:  # noqa: BLE001 - 连不上就是环境问题，原样打印给 CI 日志
        print(f"[import-schema] 连不上数据库：{error}", file=sys.stderr)
        return 2

    try:
        cursor = connection.cursor()
        # mysql-connector 26 起没有 `multi=True` 这个参数了：带 MULTI_STATEMENTS 标志时
        # 一次 execute 就会跑完全部语句，用 nextset() 把结果集逐个排空即可。
        # NOSONAR：SQL 来自仓库里被跟踪的 schema 基线文件（`tests/fixtures/tcity_schema.sql`），
        # 不是用户输入 —— 这个脚本的唯一用途就是把它灌进 CI 的临时库。
        cursor.execute(sql)  # NOSONAR
        while cursor.nextset():
            pass
        # 至少证明表真的建出来了：空库会让后续用例全红，但报错信息指向各个表而非导库这一步。
        cursor.execute("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()")
        tables = cursor.fetchone()[0]
        if not tables:
            print("[import-schema] 导入后库里一张表都没有", file=sys.stderr)
            return 2
        print(f"[import-schema] ok：{sql_path.name} → {tables} 张表")
        return 0
    finally:
        connection.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
