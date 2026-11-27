#!/usr/bin/env python3
"""真机周期验收：一条命令跑完 S6/S7 的四阶段、补推、重启续跑、个人层与结算幂等。

用法（服务端已起、没有玩家在线；脚本自己清理状态）::

    python3 tools/dev/industry_cycle_probe.py --scale 60 --cycles 2

它做什么：

1. 备份 `industry_state` / `industry_cycle_results` / `industry_demand` /
   `industry_facility` / `org_treasury`（以及四张个人表的 checksum），
   把 `industry_phase_seconds` 压到 `--scale`、心跳压到 2 秒，`restart custom-industry`；
2. 把状态写到一个**全新的周期号**（避开历史结果行），并种一个临时设施
   `probe_org`，让结算路径真的有东西可删；
3. 实时读 `industry_state` 验证四阶段依次推进，并用 `industry_audit` 的
   `cycle.advance` 序列做**不跳段**的权威判据；
4. 在竞争期 `restart custom-industry`，断言阶段/边界没有回退；
5. 在衰退期连续发两次 `industry_settle confirm <cycle>`，断言第二次被拒、
   结果表恰好一行 `applied=1`、审计 `cycle.settle` 恰好一条；
6. 第二个周期把 `phase_ends_at` 改到过去，验证补推仍按顺序一格一格走；
7. 结算前后 `CHECKSUM TABLE` 四张个人表（players / player_vehicles /
   inventories / player_houses）必须完全一致；
8. `stop custom-industry` 后按备份恢复所有产业层数据，再 `start`，恢复 convar。

硬约束：

* 脚本自己的 SQL 有静态守卫：任何写个人层的语句直接失败（只允许
  `CHECKSUM TABLE` / `SELECT` 读它们）。
* 有玩家在线、或库里已有设施/金库数据时默认拒绝启动（前者会干扰在玩的人，
  后者会被结算临时清空）。确认是空库验收后加 `--allow-industry-data`。

退出码：0 全部通过 / 1 有检查失败 / 2 环境不满足（缺 docker / server.cfg / 玩家在线等）。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
SERVER_CFG = BASE / "server.cfg"
CONTAINER_DEFAULT = "tcity-mariadb"
PLAYERS_URL = "http://127.0.0.1:30120/players.json"

PHASE_ORDER = ("expansion", "competition", "maturity", "recession")
PERSONAL_TABLES = ("players", "player_vehicles", "inventories", "player_houses")
PROBE_ORG = "probe_org"

#: 每个被探针修改的 convar 的默认值（server.cfg 里没写时按这个恢复）。
CONVAR_DEFAULTS = {
    "industry_phase_seconds": "0",
    "industry_tick_seconds": "30",
}


class ProbeError(RuntimeError):
    """环境/数据库不满足或脚本自身不变量被破坏。"""


# ══════════════════════════════════════════════════════════════════
# 纯函数（离线契约测试直接调用）
# ══════════════════════════════════════════════════════════════════


@dataclass(frozen=True)
class Transition:
    from_phase: str
    to_phase: str
    cycle_no: int


def expected_transitions(start_cycle: int, cycles: int) -> list[Transition]:
    """两个周期 = 8 次推进：每周期三次同周期，加一次跨周期。"""
    out: list[Transition] = []
    for offset in range(cycles):
        cycle = start_cycle + offset
        for index in range(len(PHASE_ORDER) - 1):
            out.append(Transition(PHASE_ORDER[index], PHASE_ORDER[index + 1], cycle))
        out.append(Transition(PHASE_ORDER[-1], PHASE_ORDER[0], cycle + 1))
    return out


def parse_advance_payload(payload: str) -> Transition | None:
    """`cycle.advance` 审计的 payload → Transition；坏行返回 None（不猜）。"""
    try:
        data = json.loads(payload)
        return Transition(str(data["from"]), str(data["to"]), int(data["cycle_no"]))
    except (TypeError, ValueError, KeyError, json.JSONDecodeError):
        return None


def validate_transitions(
    observed: list[Transition], start_cycle: int, cycles: int
) -> list[str]:
    """返回失败原因；空列表 = 完全按顺序、不跳段、不回退。"""
    expected = expected_transitions(start_cycle, cycles)
    failures: list[str] = []
    if len(observed) < len(expected):
        failures.append(f"只观察到 {len(observed)} 次推进，期望 {len(expected)} 次")
    elif len(observed) > len(expected):
        failures.append(f"观察到 {len(observed)} 次推进，多于期望的 {len(expected)} 次")
    for position, (got, want) in enumerate(zip(observed, expected), 1):
        if got != want:
            failures.append(
                f"第 {position} 次推进是 {got.cycle_no}:{got.from_phase}→{got.to_phase}，"
                f"期望 {want.cycle_no}:{want.from_phase}→{want.to_phase}"
            )
    return failures


def choose_start_cycle(*values: object) -> int:
    """新周期号 = 所有已知周期号（含结果/卖单/配额）的最大值 + 1。"""
    numbers: list[int] = [0]
    for value in values:
        if value is None:
            continue
        text = str(value).strip()
        if not text or text.upper() == "NULL":
            continue
        try:
            numbers.append(int(text))
        except ValueError:
            continue
    return max(numbers) + 1


PERSONAL_WRITE = re.compile(
    r"\b(?:INSERT(?:\s+IGNORE)?\s+INTO|REPLACE\s+INTO|UPDATE|DELETE\s+FROM|"
    r"ALTER\s+TABLE|DROP\s+TABLE|TRUNCATE(?:\s+TABLE)?)\s+"
    r"`?(players|player_vehicles|inventories|player_houses)\b",
    re.IGNORECASE,
)
PERSONAL_MENTION = re.compile(
    r"\b(players|player_vehicles|inventories|player_houses)\b", re.IGNORECASE
)
READ_ONLY_HEADS = {"SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "CHECKSUM"}


def guard_sql(sql: str) -> None:
    """探针自己的静态闸：个人层只能读（CHECKSUM/SELECT），一个写语句都不许发。"""
    if PERSONAL_WRITE.search(sql):
        raise ProbeError(f"探针拒绝写个人层：{sql.strip()[:120]}")
    if PERSONAL_MENTION.search(sql):
        head = sql.lstrip().split(None, 1)[0].upper() if sql.strip() else ""
        if head not in READ_ONLY_HEADS:
            raise ProbeError(f"探针只允许只读访问个人层：{sql.strip()[:120]}")


def parse_checksum_rows(text: str) -> dict[str, str]:
    """解析 `mariadb --batch` 的 CHECKSUM TABLE 输出：`db.players\\t123`。"""
    out: dict[str, str] = {}
    for line in text.splitlines():
        if "\t" not in line:
            continue
        table, _, checksum = line.partition("\t")
        name = table.strip().strip("`").split(".")[-1]
        if name.lower() in {"table", ""}:
            continue
        out[name.lower()] = checksum.strip()
    return out


def checksum_failures(
    before: dict[str, str], after: dict[str, str],
    before_counts: dict[str, int], after_counts: dict[str, int],
) -> list[str]:
    failures: list[str] = []
    for table in PERSONAL_TABLES:
        if before.get(table) != after.get(table):
            failures.append(
                f"{table}: checksum 变化 {before.get(table)} → {after.get(table)}"
            )
        if before_counts.get(table) != after_counts.get(table):
            failures.append(
                f"{table}: 行数变化 {before_counts.get(table)} → {after_counts.get(table)}"
            )
    return failures


def format_checksum_table(
    before: dict[str, str], after: dict[str, str],
    before_counts: dict[str, int], after_counts: dict[str, int],
) -> str:
    lines = [f"{'table':<20} {'rows(before→after)':<24} {'checksum(before→after)'}"]
    for table in PERSONAL_TABLES:
        lines.append(
            f"{table:<20} "
            f"{before_counts.get(table, '?'):>6} → {after_counts.get(table, '?'):<6}       "
            f"{before.get(table, '?'):>12} → {after.get(table, '?')}"
        )
    return "\n".join(lines)


def is_already_settled(text: str) -> bool:
    lowered = (text or "").lower()
    return "already settled" in lowered or "already_settled" in lowered


def past_due_lookback(phase: str, scale: int) -> int:
    """把当前阶段的结束时间往回拨多少秒，补推才会正好停在新周期的扩张期。

    expansion   → 3×scale + 5（快速推进 4 次）
    competition → 2×scale + 5（快速推进 3 次）
    maturity / recession 不是注入窗口（见 exercise）。
    """
    index = PHASE_ORDER.index(phase)
    return (len(PHASE_ORDER) - 1 - index) * int(scale) + 5


def restart_resume_ok(before: dict, after: dict) -> bool:
    """重启后续跑：原地不动，或同周期前进一格 / 衰退→下一轮扩张；其余都算失败。

    一次 tick 只推进一格，所以重启窗口内最多前进一格。跳段/回退必须判红——
    真正的权威判据仍是 `cycle.advance` 审计序列，这里只保护「重启没有重置状态」。
    """
    try:
        before_cycle = int(before.get("cycle_no") or 0)
        after_cycle = int(after.get("cycle_no") or 0)
        before_index = PHASE_ORDER.index(str(before.get("phase")))
        after_index = PHASE_ORDER.index(str(after.get("phase")))
    except (TypeError, ValueError):
        return False

    if before_cycle != after_cycle:
        return (
            after_cycle == before_cycle + 1
            and str(before.get("phase")) == "recession"
            and str(after.get("phase")) == "expansion"
        )
    return before_index <= after_index <= before_index + 1


# ══════════════════════════════════════════════════════════════════
# 环境读取
# ══════════════════════════════════════════════════════════════════


def parse_dsn(text: str) -> dict[str, str]:
    match = re.search(
        r'set\s+mysql_connection_string\s+"mysql://([^:]+):([^@]+)@([^/]+)/([^?"]+)',
        text,
    )
    if not match:
        raise ProbeError("server.cfg 里没有可解析的 mysql_connection_string")
    user, password, _hostport, database = match.groups()
    return {"user": user, "password": password, "database": database}


def convar_from_cfg(name: str, default: str) -> str:
    if not SERVER_CFG.exists():
        return default
    pattern = re.compile(
        rf'^\s*setr?\s+{re.escape(name)}\s+"?([^"\s]+)"?\s*$', re.IGNORECASE
    )
    for line in SERVER_CFG.read_text(encoding="utf-8", errors="ignore").splitlines():
        match = pattern.match(line)
        if match:
            return match.group(1)
    return default


def rcon_password() -> str:
    password = os.environ.get("FIVEM_RCON_PASSWORD", "").strip()
    if password:
        return password
    if not SERVER_CFG.exists():
        raise ProbeError("缺少 FIVEM_RCON_PASSWORD，且找不到 server.cfg")
    match = re.search(
        r'set\s+rcon_password\s+"([^"]+)"',
        SERVER_CFG.read_text(encoding="utf-8", errors="ignore"),
    )
    if not match:
        raise ProbeError("server.cfg 里没有 rcon_password")
    return match.group(1)


def live_players() -> list[dict] | None:
    """服务端 /players.json 的在线玩家；端点不可达返回 None（由调用方决定是否放行）。"""
    try:
        with urllib.request.urlopen(PLAYERS_URL, timeout=3) as response:
            data = json.loads(response.read().decode("utf-8"))
        return data if isinstance(data, list) else None
    except (urllib.error.URLError, OSError, json.JSONDecodeError):
        return None


# ══════════════════════════════════════════════════════════════════
# 数据库（docker exec + mariadb CLI；只用于验收与恢复）
# ══════════════════════════════════════════════════════════════════


def sql_literal(value: object) -> str:
    # mariadb --batch 把 SQL NULL 打成字面量 NULL；恢复时不能把它写成字符串 'NULL'。
    if value is None or (isinstance(value, str) and value.upper() == "NULL"):
        return "NULL"
    return "'" + str(value).replace("\\", "\\\\").replace("'", "''") + "'"


class Sql:
    def __init__(self, dsn: dict[str, str], container: str) -> None:
        self.dsn = dsn
        self.container = container

    def _run(self, sql: str) -> str:
        guard_sql(sql)
        if not shutil.which("docker"):
            raise ProbeError("找不到 docker")
        command = [
            "docker", "exec", "-i", "-e", "MYSQL_PWD", self.container,
            "mariadb", f"-u{self.dsn['user']}", "-D", self.dsn["database"],
            "--batch", "--raw",
        ]
        env = dict(os.environ)
        env["MYSQL_PWD"] = self.dsn["password"]
        result = subprocess.run(
            command, input=sql, capture_output=True, text=True, timeout=60, env=env,
        )
        if result.returncode != 0:
            raise ProbeError(f"SQL 失败：{result.stderr.strip()[:300]}")
        return result.stdout

    def query(self, sql: str) -> list[dict[str, str]]:
        text = self._run(sql)
        lines = [line for line in text.splitlines() if line != ""]
        if len(lines) < 2:
            return []
        header = lines[0].split("\t")
        return [dict(zip(header, line.split("\t"))) for line in lines[1:]]

    def scalar(self, sql: str, default: int = 0) -> int:
        rows = self.query(sql)
        if not rows:
            return default
        first = next(iter(rows[0].values()), default)
        try:
            return int(first)
        except (TypeError, ValueError):
            return default

    def execute(self, sql: str) -> None:
        self._run(sql)

    def insert_rows(self, table: str, columns: list[str], rows: list[dict[str, str]]) -> None:
        if not rows:
            return
        values = []
        for row in rows:
            values.append(
                "(" + ", ".join(sql_literal(row.get(column)) for column in columns) + ")"
            )
        self.execute(
            f"INSERT INTO {table} ({', '.join(columns)}) VALUES {', '.join(values)}"
        )


# ══════════════════════════════════════════════════════════════════
# 快照 / 恢复
# ══════════════════════════════════════════════════════════════════

STATE_COLUMNS = [
    "id", "cycle_no", "phase", "phase_started_at", "phase_ends_at",
    "warning_announced_at", "settled_cycle_no", "result_announced_cycle",
]
DEMAND_COLUMNS = ["cycle_no", "phase", "item_name", "quota_total", "quota_used"]
FACILITY_COLUMNS = [
    "org_id", "facility_type", "level", "workstations", "recipe_id",
    "stock", "produced_units", "last_tick_at", "created_at",
]
TREASURY_COLUMNS = ["org_id", "balance", "prestige", "cycle_no"]


@dataclass
class Snapshot:
    state: dict[str, str] | None = None
    demand: list[dict[str, str]] = field(default_factory=list)
    facilities: list[dict[str, str]] = field(default_factory=list)
    treasuries: list[dict[str, str]] = field(default_factory=list)
    max_audit_id: int = 0


def take_snapshot(sql: Sql) -> Snapshot:
    snapshot = Snapshot()
    rows = sql.query(
        "SELECT " + ", ".join(STATE_COLUMNS) + " FROM industry_state LIMIT 1"
    )
    snapshot.state = rows[0] if rows else None
    snapshot.demand = sql.query(
        "SELECT " + ", ".join(DEMAND_COLUMNS) + " FROM industry_demand LIMIT 10000"
    )
    snapshot.facilities = sql.query(
        "SELECT " + ", ".join(FACILITY_COLUMNS) + " FROM industry_facility LIMIT 10000"
    )
    snapshot.treasuries = sql.query(
        "SELECT " + ", ".join(TREASURY_COLUMNS) + " FROM org_treasury LIMIT 10000"
    )
    snapshot.max_audit_id = sql.scalar(
        "SELECT COALESCE(MAX(id), 0) AS max_id FROM industry_audit LIMIT 1"
    )
    return snapshot


def restore_snapshot(sql: Sql, snapshot: Snapshot, probe_cycles: list[int]) -> None:
    """恢复产业层与状态；个人层不碰。调用方应先 stop 资源。"""
    sql.execute("DELETE FROM industry_state")
    if snapshot.state:
        sql.insert_rows("industry_state", STATE_COLUMNS, [snapshot.state])

    sql.execute("DELETE FROM industry_demand")
    sql.insert_rows("industry_demand", DEMAND_COLUMNS, snapshot.demand)

    sql.execute("DELETE FROM industry_facility")
    sql.insert_rows("industry_facility", FACILITY_COLUMNS, snapshot.facilities)

    sql.execute("DELETE FROM org_treasury")
    sql.insert_rows("org_treasury", TREASURY_COLUMNS, snapshot.treasuries)

    if probe_cycles:
        cycle_list = ", ".join(str(int(cycle)) for cycle in probe_cycles)
        sql.execute(f"DELETE FROM industry_cycle_results WHERE cycle_no IN ({cycle_list})")
        sql.execute(f"DELETE FROM industry_sales WHERE cycle_no IN ({cycle_list})")
        sql.execute(
            "DELETE FROM org_ledger WHERE ref IN ("
            + ", ".join(sql_literal(f"settle:{int(cycle)}") for cycle in probe_cycles)
            + ")"
        )
    # 探针自己种的临时组织（结算会删设施、可能建金库行）。
    sql.execute(f"DELETE FROM industry_facility WHERE org_id = {sql_literal(PROBE_ORG)}")
    sql.execute(f"DELETE FROM org_treasury WHERE org_id = {sql_literal(PROBE_ORG)}")


# ══════════════════════════════════════════════════════════════════
# 真机控制台
# ══════════════════════════════════════════════════════════════════


class Console:
    """发命令；有 `--console-log` 时**同时**把服务端日志里新增的行读回来。

    为什么需要这个：RCON 只回"命令本身"的回显，资源里的 `print()` 是异步写进服务端日志的。
    例如 `industry_settle dry` 的 `settlement dry-run ...` 那一行永远不在 RCON 的返回值里，
    于是"输出里必须含 settlement dry-run"这种检查会永远失败 —— 看起来像功能没开，
    实际只是拿错了回显通道（2026-11-26 真机实测）。
    """

    def __init__(self, log_path: str | None = None) -> None:
        self.last_call = 0.0
        self.log_path = Path(log_path) if log_path else None
        self._offset = self.log_path.stat().st_size if self.log_path and self.log_path.exists() else 0
        if not os.environ.get("FIVEM_RCON_PASSWORD"):
            os.environ["FIVEM_RCON_PASSWORD"] = rcon_password()

    def _drain_log(self, wait_seconds: float = 3.0) -> str:
        if not self.log_path:
            return ""
        deadline = time.time() + wait_seconds
        while time.time() < deadline:
            try:
                size = self.log_path.stat().st_size
            except OSError:
                return ""
            if size > self._offset:
                with self.log_path.open("r", encoding="utf-8", errors="replace") as fh:
                    fh.seek(self._offset)
                    chunk = fh.read()
                self._offset = size
                return chunk
            time.sleep(0.2)
        return ""

    def __call__(self, command: str, timeout: float = 60.0) -> str:
        # fivem-mcp-server 的 server-side 限流约 5 次/秒；保守一点，逐条隔开。
        wait = 0.8 - (time.time() - self.last_call)
        if wait > 0:
            time.sleep(wait)
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import fivem_console
        rcon_out = ""
        try:
            rcon_out = fivem_console.call_tool(
                "server_command", {"command": command}, timeout
            )
        except SystemExit as error:
            raise ProbeError(f"控制台命令失败（{command}）：{error}") from error
        finally:
            self.last_call = time.time()
        log_tail = self._drain_log()
        if log_tail:
            return (rcon_out or "") + "\n" + log_tail
        return rcon_out


# ══════════════════════════════════════════════════════════════════
# 探针主体
# ══════════════════════════════════════════════════════════════════


class CycleProbe:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.console = Console(args.console_log)
        cfg = SERVER_CFG.read_text(encoding="utf-8", errors="ignore")
        self.sql = Sql(parse_dsn(cfg), args.container)
        self.snapshot: Snapshot | None = None
        self.checks: list[tuple[str, bool, str]] = []
        self.log_lines: list[str] = []
        self.start_cycle = 0
        self.cycle_count = args.cycles
        self.checksums_before: dict[str, str] = {}
        self.counts_before: dict[str, int] = {}
        self.checksums_after: dict[str, str] = {}
        self.counts_after: dict[str, int] = {}
        self.original_convars: dict[str, str] = {}
        self.console_modified = False
        self.modified = False
        self.resource_stopped = False
        self.restart_evidence: dict[str, object] = {}
        self.settlement_evidence: dict[str, object] = {}
        self.cleanup_errors: list[str] = []

    # ── 记录 ─────────────────────────────────────────────────────
    def check(self, name: str, ok: bool, detail: str = "") -> None:
        self.checks.append((name, ok, detail))

    def log(self, message: str) -> None:
        self.log_lines.append(message)
        print(f"[industry-cycle-probe] {message}", flush=True)

    # ── 读取 ─────────────────────────────────────────────────────
    def read_state(self) -> dict[str, str] | None:
        rows = self.sql.query(
            "SELECT cycle_no, phase, "
            "UNIX_TIMESTAMP(phase_started_at) AS started_epoch, "
            "UNIX_TIMESTAMP(phase_ends_at) AS ends_epoch, settled_cycle_no, "
            "UNIX_TIMESTAMP(warning_announced_at) AS warning_epoch "
            "FROM industry_state WHERE id = 1 LIMIT 1"
        )
        return rows[0] if rows else None

    def personal_checksums(self) -> tuple[dict[str, str], dict[str, int]]:
        text = self.sql._run(
            "CHECKSUM TABLE " + ", ".join(PERSONAL_TABLES)
        )
        checksums = parse_checksum_rows(text)
        counts: dict[str, int] = {}
        for table in PERSONAL_TABLES:
            counts[table] = self.sql.scalar(
                f"SELECT COUNT(*) AS n FROM {table} LIMIT 1"
            )
        return checksums, counts

    def read_transitions(self) -> list[Transition]:
        rows = self.sql.query(
            "SELECT id, payload FROM industry_audit "
            f"WHERE action = 'cycle.advance' AND id > {int(self.snapshot.max_audit_id)} "
            "ORDER BY id ASC LIMIT 1000"
        )
        transitions = []
        for row in rows:
            transition = parse_advance_payload(row.get("payload") or "")
            if transition:
                transitions.append(transition)
        return transitions

    def settlement_audit_count(self, cycle: int) -> int:
        rows = self.sql.query(
            "SELECT id, payload FROM industry_audit "
            f"WHERE action = 'cycle.settle' AND id > {int(self.snapshot.max_audit_id)} "
            "ORDER BY id ASC LIMIT 100"
        )
        count = 0
        for row in rows:
            try:
                payload = json.loads(row.get("payload") or "{}")
            except json.JSONDecodeError:
                continue
            if int(payload.get("cycle_no") or -1) == cycle:
                count += 1
        return count

    # ── 启动前检查 ───────────────────────────────────────────────
    def preflight(self) -> None:
        tables = self.sql.query("SHOW TABLES LIKE 'industry_state'")
        if not tables:
            raise ProbeError("库里没有 industry_state（先跑 v4.4 迁移并启动 custom-industry）")

        if not self.args.allow_players_online:
            players = live_players()
            if players:
                raise ProbeError(
                    f"有 {len(players)} 名玩家在线；验收会临时清空产业层。"
                    "请等人下线，或加 --allow-players-online"
                )
            if players is None:
                self.log("/players.json 不可达，无法确认在线人数（继续，但请自行确认）")

        # 就绪判据走 **DB 事实**，不靠控制台文本：
        # FXServer 的 stdout 重定向到文件是块缓冲，资源里 print() 的那行可能几秒后才落盘，
        # 而 `--console-log` 只等 3 秒 —— 用"输出里必须出现某行"作判据会在真机上误报
        # "industry_enable 未开"（2026-11-27 复现两次，两次功能都正常）。
        output = self.console("industry_settle dry")
        ready_by_db = False
        rows = self.sql.query("SELECT COUNT(*) AS n FROM industry_state")
        if rows:
            try:
                ready_by_db = int(rows[0].get("n", 0)) >= 1
            except (TypeError, ValueError):
                ready_by_db = False
        if "settlement dry-run" not in output.lower():
            if not ready_by_db:
                raise ProbeError(
                    "custom-industry 没就绪（industry_state 无行，或 industry_enable 关着）："
                    f"{output[:200]}"
                )
            self.log("控制台回显没到（块缓冲），已按 DB 事实判定 custom-industry 就绪")

        if not self.args.allow_industry_data:
            if self.snapshot.facilities or self.snapshot.treasuries:
                raise ProbeError(
                    "库里已有产业设施/金库数据；结算会临时清空它们（脚本会恢复，"
                    "但中途有玩家在卖货就会丢）。确认后可加 --allow-industry-data"
                )

    # ── 安装验收参数 / 重启 ───────────────────────────────────────
    def install_convars(self) -> None:
        self.modified = True
        self.console_modified = True
        for name in CONVAR_DEFAULTS:
            self.original_convars[name] = convar_from_cfg(name, CONVAR_DEFAULTS[name])
        self.console(f"set industry_phase_seconds {int(self.args.scale)}")
        self.console("set industry_tick_seconds 2")

    def restart_resource(self) -> None:
        output = self.console("restart custom-industry", timeout=90)
        self.log(f"restart custom-industry → {output.splitlines()[-1] if output else '(no output)'}")
        if "Started resource custom-industry" not in output:
            # restart 的 RCON 回包有时只带部分行；再给一次 ensure 并等启动。
            self.console("ensure custom-industry", timeout=90)
            time.sleep(3)
        if not self.sql.query("SHOW TABLES LIKE 'industry_state'"):
            raise ProbeError("custom-industry 重启后不可用")
        for _ in range(20):
            output = self.console("industry_settle dry")
            if "settlement dry-run" in output.lower():
                return
            time.sleep(1)
        raise ProbeError("重启后 industry_settle 仍不可用（看服务端控制台）")

    # ── 构造全新周期 ─────────────────────────────────────────────
    def prepare_cycle(self) -> None:
        state = self.read_state()
        max_result = self.sql.scalar(
            "SELECT COALESCE(MAX(cycle_no), 0) AS n FROM industry_cycle_results LIMIT 1"
        )
        max_sales = self.sql.scalar(
            "SELECT COALESCE(MAX(cycle_no), 0) AS n FROM industry_sales LIMIT 1"
        )
        max_demand = self.sql.scalar(
            "SELECT COALESCE(MAX(cycle_no), 0) AS n FROM industry_demand LIMIT 1"
        )
        self.start_cycle = choose_start_cycle(
            state and state.get("cycle_no"),
            state and state.get("settled_cycle_no"),
            max_result, max_sales, max_demand,
        )
        now = self.sql.scalar("SELECT UNIX_TIMESTAMP() AS n LIMIT 1")
        if now <= 0:
            raise ProbeError("数据库时钟不可用")
        starts = int(now)
        ends = starts + int(self.args.scale)

        probe_cycles = list(range(self.start_cycle, self.start_cycle + self.cycle_count))
        cycle_list = ", ".join(str(cycle) for cycle in probe_cycles)
        self.sql.execute(
            f"DELETE FROM industry_cycle_results WHERE cycle_no IN ({cycle_list})"
        )
        self.sql.execute(f"DELETE FROM industry_sales WHERE cycle_no IN ({cycle_list})")
        self.sql.execute(f"DELETE FROM industry_demand WHERE cycle_no IN ({cycle_list})")
        self.sql.execute(
            f"DELETE FROM industry_facility WHERE org_id = {sql_literal(PROBE_ORG)}"
        )
        self.sql.execute(
            f"DELETE FROM org_treasury WHERE org_id = {sql_literal(PROBE_ORG)}"
        )

        if state:
            self.sql.execute(
                "UPDATE industry_state SET "
                f"cycle_no = {int(self.start_cycle)}, phase = 'expansion', "
                f"phase_started_at = FROM_UNIXTIME({starts}), "
                f"phase_ends_at = FROM_UNIXTIME({ends}), warning_announced_at = NULL "
                "WHERE id = 1"
            )
        else:
            self.sql.execute(
                "INSERT INTO industry_state "
                "(id, cycle_no, phase, phase_started_at, phase_ends_at) VALUES "
                f"(1, {int(self.start_cycle)}, 'expansion', "
                f"FROM_UNIXTIME({starts}), FROM_UNIXTIME({ends}))"
            )

        self.sql.execute(
            "INSERT INTO industry_facility "
            "(org_id, facility_type, level, workstations, recipe_id, stock, "
            "produced_units, last_tick_at) VALUES ("
            f"{sql_literal(PROBE_ORG)}, 'mine', 1, 0, NULL, 0, 0, NOW())"
        )

        self.log(
            f"start_cycle={self.start_cycle} phase=expansion ends=+{self.args.scale}s "
            f"cycles={self.cycle_count}"
        )

    # ── 各项检查 ─────────────────────────────────────────────────
    def do_restart_resume(self, before: dict[str, str]) -> None:
        output = self.console("restart custom-industry", timeout=90)
        time.sleep(3)
        after = self.read_state() or {}
        same = (
            str(after.get("cycle_no")) == str(before.get("cycle_no"))
            and after.get("phase") == before.get("phase")
            and str(after.get("started_epoch")) == str(before.get("started_epoch"))
            and str(after.get("ends_epoch")) == str(before.get("ends_epoch"))
        )
        forward = restart_resume_ok(before, after)
        ok = same or forward
        detail = (
            f"before={before.get('cycle_no')}:{before.get('phase')}@{before.get('started_epoch')} "
            f"after={after.get('cycle_no')}:{after.get('phase')}@{after.get('started_epoch')}"
            f" resource={'started' if 'Started resource' in output else 'restart reply missing'}"
        )
        self.check("重启续跑（不回退/不重算边界）", ok, detail)
        self.restart_evidence = {"before": before, "after": after, "same": same}

    def do_idempotency(self, cycle: int) -> None:
        first = self.console(f"industry_settle confirm {int(cycle)}", timeout=90)
        time.sleep(0.5)
        second = self.console(f"industry_settle confirm {int(cycle)}", timeout=90)

        results = self.sql.query(
            "SELECT org_id, cycle_no, applied, prestige_awarded, revenue "
            f"FROM industry_cycle_results WHERE cycle_no = {int(cycle)} LIMIT 100"
        )
        probe_results = [row for row in results if row.get("org_id") == PROBE_ORG]
        residual = self.sql.scalar(
            "SELECT COUNT(*) AS n FROM industry_cycle_results "
            f"WHERE cycle_no IN ({int(cycle)}, {int(cycle) + 1}) AND applied = 0 LIMIT 1"
        )
        facility_left = self.sql.scalar(
            "SELECT COUNT(*) AS n FROM industry_facility "
            f"WHERE org_id = {sql_literal(PROBE_ORG)} LIMIT 1"
        )
        audit_count = self.settlement_audit_count(cycle)
        settled_after = self.sql.scalar(
            "SELECT settled_cycle_no AS n FROM industry_state WHERE id = 1 LIMIT 1"
        )

        applied_rows = [row for row in probe_results if str(row.get("applied")) == "1"]
        second_rejected = is_already_settled(second)
        ok = (
            len(probe_results) == 1
            and len(applied_rows) == 1
            and residual == 0
            and facility_left == 0
            and audit_count == 1
            and settled_after >= cycle
        )
        detail = (
            f"results={len(probe_results)} applied={len(applied_rows)} "
            f"residual={residual} facility={facility_left} audit={audit_count} "
            f"second={'already settled' if second_rejected else second.strip()[:60] or '(no output)'}"
        )
        self.check("结算幂等（第二次被拒、无残行）", ok, detail)
        self.settlement_evidence = {
            "first": first, "second": second, "results": results,
            "audit_count": audit_count, "settled_cycle_no": settled_after,
        }

    def inject_past_due(self, cycle: int, phase: str) -> None:
        # 回溯量必须让补推**正好停在新周期的扩张期**（终止状态）；再短一格会把
        # 新周期扩张期的边界也推成过去，探针就观察不到终止状态了。
        lookback = past_due_lookback(phase, int(self.args.scale))
        self.sql.execute(
            "UPDATE industry_state SET phase_ends_at = "
            f"FROM_UNIXTIME(UNIX_TIMESTAMP() - {int(lookback)}) "
            f"WHERE id = 1 AND cycle_no = {int(cycle)} AND phase = {sql_literal(phase)}"
        )
        self.log(
            f"cycle {cycle} {phase} 的 phase_ends_at 已改到过去 {lookback}s —— "
            "观察是否按顺序补推"
        )

    # ── 主循环 ───────────────────────────────────────────────────
    def exercise(self) -> None:
        timeout = self.args.timeout or max(300, int(self.args.scale) * (
            4 * self.cycle_count + 4) + 180)
        deadline = time.time() + timeout
        poll = 1.0

        restart_done = False
        idempotency_done = False
        catchup_done = False
        last_key: tuple[int, str] | None = None
        seen_phases: list[str] = []

        while time.time() < deadline:
            state = self.read_state()
            if not state:
                time.sleep(poll)
                continue
            cycle = int(state.get("cycle_no") or 0)
            phase = str(state.get("phase") or "")
            key = (cycle, phase)
            if key != last_key:
                seen_phases.append(f"{cycle}:{phase}")
                self.log(f"state {cycle}:{phase} ends={state.get('ends_epoch')}")
                last_key = key

            ends = int(float(state.get("ends_epoch") or 0))
            remaining = ends - int(time.time())

            if (
                not restart_done
                and cycle == self.start_cycle
                and phase == "competition"
                and remaining >= 15
            ):
                self.do_restart_resume(state)
                restart_done = True

            if (
                not idempotency_done
                and cycle == self.start_cycle
                and phase == "recession"
            ):
                self.do_idempotency(cycle)
                idempotency_done = True

            if (
                not catchup_done
                and cycle == self.start_cycle + 1
                and phase in ("expansion", "competition")
            ):
                self.inject_past_due(cycle, phase)
                catchup_done = True
            elif (
                not catchup_done
                and cycle == self.start_cycle + 1
                and phase in ("maturity", "recession")
            ):
                # 1 秒轮询仍错过窗口（例如资源重启拖长）：记失败，不要无限等。
                self.check(
                    "补推注入", False,
                    f"错过 cycle {cycle} expansion/competition 的注入窗口（当前 {phase}）",
                )
                catchup_done = True

            if cycle >= self.start_cycle + self.cycle_count and phase == "expansion":
                break

            # 资源重启后可能刚好错过一次边界：重试一次 restart 检查。
            if (
                not restart_done
                and cycle == self.start_cycle
                and phase in ("maturity", "recession")
            ):
                self.do_restart_resume(state)
                restart_done = True

            time.sleep(poll)
        else:
            raise ProbeError(
                f"等待周期推进超时（{timeout}s）；最后状态 {last_key}，"
                f"已观察 {seen_phases}"
            )

        self.log("observed phases: " + " → ".join(seen_phases))
        self.check("两项中途检查都执行", restart_done and idempotency_done and catchup_done,
                   f"restart={restart_done} idempotency={idempotency_done} "
                   f"catchup={catchup_done}")

    # ── 收尾 ─────────────────────────────────────────────────────
    def collect_results(self) -> None:
        transitions = self.read_transitions()
        failures = validate_transitions(
            transitions, self.start_cycle, self.cycle_count
        )
        self.check(
            "四阶段顺序 + 不跳段（含 phase_ends_at 在过去）",
            not failures,
            " → ".join(
                f"{item.cycle_no}:{item.from_phase}→{item.to_phase}"
                for item in transitions
            ) if transitions else "（没有 cycle.advance 审计）",
        )
        for failure in failures:
            self.log(f"序列失败：{failure}")

        self.checksums_after, self.counts_after = self.personal_checksums()
        personal_failures = checksum_failures(
            self.checksums_before, self.checksums_after,
            self.counts_before, self.counts_after,
        )
        detail = format_checksum_table(
            self.checksums_before, self.checksums_after,
            self.counts_before, self.counts_after,
        )
        if personal_failures:
            detail += "\n差异：" + "；".join(personal_failures)
        self.check("个人层零改动（CHECKSUM TABLE 前后一致）", not personal_failures, detail)

        residual = self.sql.scalar(
            "SELECT COUNT(*) AS n FROM industry_cycle_results "
            f"WHERE cycle_no BETWEEN {int(self.start_cycle)} AND "
            f"{int(self.start_cycle + self.cycle_count - 1)} AND applied = 0 LIMIT 1"
        )
        self.check("结果表无 applied=0 残行", residual == 0, f"residual={residual}")

        settled = self.sql.scalar(
            "SELECT settled_cycle_no AS n FROM industry_state WHERE id = 1 LIMIT 1"
        )
        expected_settled = self.start_cycle + self.cycle_count - 1
        self.check(
            "每个周期都完成结算",
            settled >= expected_settled,
            f"settled_cycle_no={settled}（期望 ≥ {expected_settled}）",
        )

    def restore_convars(self) -> None:
        for name, value in self.original_convars.items():
            self.console(f"set {name} {value}")
        self.console_modified = False

    def cleanup(self) -> None:
        """无论成功失败都恢复到跑之前；个人层一根手指都不碰。"""
        if not self.modified or self.snapshot is None:
            return

        try:
            self.console("stop custom-industry", timeout=90)
            time.sleep(1)
            self.resource_stopped = True
        except Exception as error:  # noqa: BLE001 - 收尾要尽力而为
            self.cleanup_errors.append(f"stop custom-industry: {error}")

        # start_cycle 只在 prepare_cycle 里选定（全新周期号）。没选过就说明还没动
        # 结果/卖单/配额，绝不能拿快照里的真实周期号去删历史行。
        probe_cycles = (
            list(range(self.start_cycle, self.start_cycle + max(1, self.cycle_count)))
            if self.start_cycle > 0 else []
        )

        try:
            restore_snapshot(self.sql, self.snapshot, probe_cycles)
            self.log("已恢复 industry_state / results / demand / facility / treasury")
        except Exception as error:  # noqa: BLE001
            self.cleanup_errors.append(f"restore: {error}")

        try:
            if self.console_modified:
                self.restore_convars()
        except Exception as error:  # noqa: BLE001
            self.cleanup_errors.append(f"restore convars: {error}")

        try:
            output = self.console("start custom-industry", timeout=90)
            if "Started resource custom-industry" not in output:
                raise ProbeError(output[:160] or "start 无回包")
            time.sleep(1)
        except Exception as error:  # noqa: BLE001
            self.cleanup_errors.append(f"start custom-industry: {error}")
            return

        # 资源启动时若把 legacy 状态重新初始化，最后再按快照覆盖一次（真实阶段不会被动）。
        try:
            current = self.read_state()
            if self.snapshot.state and current:
                same = all(
                    str(current.get(key)) == str(self.snapshot.state.get(key))
                    for key in ("cycle_no", "phase")
                )
                if not same:
                    self.sql.execute("DELETE FROM industry_state")
                    self.sql.insert_rows(
                        "industry_state", STATE_COLUMNS, [self.snapshot.state]
                    )
                    self.log("资源启动后状态与快照不一致，已按快照覆盖")
        except Exception as error:  # noqa: BLE001
            self.cleanup_errors.append(f"verify state: {error}")

    # ── 报告 ─────────────────────────────────────────────────────
    def run(self) -> int:
        self.snapshot = take_snapshot(self.sql)
        self.checksums_before, self.counts_before = self.personal_checksums()
        try:
            self.preflight()
            self.install_convars()
            self.restart_resource()
            self.prepare_cycle()
            try:
                self.exercise()
                self.collect_results()
            except ProbeError as error:
                # 运行期的超时/序列异常按「检查失败」报，不吞掉已完成的证据。
                self.check("执行", False, str(error))
        finally:
            self.cleanup()

        for error in self.cleanup_errors:
            self.check("清理", False, error)

        if self.args.json:
            print(json.dumps({
                "scale": self.args.scale,
                "cycles": self.cycle_count,
                "start_cycle": self.start_cycle,
                "checks": [
                    {"name": name, "ok": ok, "detail": detail}
                    for name, ok, detail in self.checks
                ],
                "cleanup_errors": self.cleanup_errors,
            }, ensure_ascii=False, indent=2))
        else:
            self.print_report()
        return 0 if all(ok for _, ok, _ in self.checks) else 1

    def print_report(self) -> None:
        width = 74
        print("=" * width)
        print(f" industry_cycle_probe  scale={self.args.scale}s/phase  "
              f"cycles={self.cycle_count}  start_cycle={self.start_cycle}")
        print("=" * width)
        for name, ok, detail in self.checks:
            mark = "✓" if ok else "✗"
            print(f" {mark} {name}")
            if detail:
                for line in str(detail).splitlines():
                    print(f"     {line}")
        print("-" * width)
        failed = [name for name, ok, _ in self.checks if not ok]
        if failed:
            print(f"结论: FAIL（{len(failed)} 项）")
        else:
            print("结论: PASS（周期推进、个人层、幂等全部通过）")
        if self.cleanup_errors:
            print("清理告警（需要人工看一眼）：")
            for error in self.cleanup_errors:
                print(f"  - {error}")
        print("=" * width)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="真机周期验收（四阶段/补推/重启/个人层/结算幂等）"
    )
    parser.add_argument(
        "--scale", type=int, default=60,
        help="每阶段真实秒数（写 industry_phase_seconds），默认 60",
    )
    parser.add_argument("--cycles", type=int, default=2, help="跑几个完整周期，默认 2")
    parser.add_argument(
        "--container", default=os.environ.get("TCITY_DB_CONTAINER", CONTAINER_DEFAULT),
        help="MariaDB 容器名（默认 tcity-mariadb）",
    )
    parser.add_argument(
        "--timeout", type=int, default=0,
        help="总超时秒数；0 = 按 scale × 周期数自动推导",
    )
    parser.add_argument(
        "--allow-industry-data", action="store_true",
        help="允许在已有设施/金库数据的库上跑（会临时清空并在结束时恢复）",
    )
    parser.add_argument(
        "--allow-players-online", action="store_true",
        help="允许有玩家在线时跑（不推荐：会临时清空产业层）",
    )
    parser.add_argument(
        "--console-log", default=os.environ.get("TCITY_CONSOLE_LOG"),
        help="服务端控制台日志文件；给了就把资源 print() 的回显也读回来（RCON 只有命令回显）",
    )
    parser.add_argument("--json", action="store_true", help="机读输出")
    args = parser.parse_args(argv)

    if args.cycles < 1:
        parser.error("--cycles 至少 1")
    if args.scale < 20:
        parser.error("--scale 至少 20（再短就来不及做中途重启检查）")
    if args.cycles > 10:
        parser.error("--cycles 最多 10（真机验收不是压力测试）")
    if not SERVER_CFG.exists():
        parser.error(f"找不到 {SERVER_CFG}（需要在服务器本机跑）")
    return args


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
    except SystemExit as error:
        return int(error.code or 0)

    try:
        probe = CycleProbe(args)
        return probe.run()
    except ProbeError as error:
        print(f"[industry-cycle-probe] 失败：{error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("[industry-cycle-probe] 中断；已尽力清理", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
