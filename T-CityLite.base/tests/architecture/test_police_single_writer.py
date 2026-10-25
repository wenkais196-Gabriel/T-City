"""POL-01 — police 的每张表只能有一个写者。

为什么：`police_incidents` 曾经有三个写入点（p0 的 911/玩家路径、p2_system 的 agent 路径、
p4_npc 的 NPC callout），`police_audit` 有**八份**各自实现的 INSERT。后果不是风格问题：

- 审计的八份实现里，有六份在 `detail = nil` 时会构造出"参数数组末尾有洞"的调用，
  oxmysql 把数组截断 → MariaDB 报语法错误 → 但 `pcall` 返回 **true**（错误以字符串返回），
  于是 `if not audit(...)` 把失败当成成功，**审计行静默丢失**。已在真库上实测确认。
- 同一张表多个写者时，列集合/默认值/审计字段各自演化，"为什么这行长这样"没有唯一答案。

判据：每张 `police_*` 表在 `[custom]/custom-police/server/` 下只能有一个文件出现
`INSERT INTO <table>` 或 `UPDATE <table>`。未收口的表必须登记在 `EXCEPTIONS` 里，
并给出**它现在为什么还不能收口**以及一条"痕迹"（该文件里仍能看到的多写者证据）；
痕迹消失说明这条例外已经失效，要删掉——和限流闸门是同一套双向校验。
"""

from __future__ import annotations

import json
import re
from collections import defaultdict
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
SERVER = BASE / "resources" / "[custom]" / "custom-police" / "server"

WRITE = re.compile(r"\b(INSERT\s+INTO|UPDATE)\s+`?([a-z_]+)`?", re.I)

#: 已收口的表 → 唯一允许写它的文件。
OWNERS = {
    "police_audit": "audit.lua",
    "police_incidents": "p0.lua",
    "police_units": "p0.lua",
    "police_incident_units": "p0.lua",
    # 下面四张本来就是单写者，闸门把它们钉住，防止以后又长出第二个写者
    "police_bolos": "p3_cases.lua",
    "police_warrants": "p3_cases.lua",
    "police_outbox": "p2_system.lua",
    "police_write_intents": "p2_system.lua",
    # 2026-10-25: 罚单收口。金额政策与列集合都进了写者，
    # p1 那个"不带车牌就开不出罚单"的洞随之消失
    "police_citations": "citations.lua",
    # 2026-10-25: 证据 + 链收口。收口时发现登记路径本身是坏的（参数数组前导 nil → 语法错），
    # 修好后 agent 的两条 child 路径也改走同一个写者
    "police_evidence": "p2_evidence.lua",
    "police_evidence_chain": "p2_evidence.lua",
}

#: 还没收口的表：表名 → (为什么还不能收口, 仍在多写的证据痕迹)
EXCEPTIONS: dict[str, tuple[str, str]] = {
    "police_cases": (
        "案卷由 p2_system（agent 写意图路径）与 p3_cases（玩家案卷）各自写入，"
        "两条路径的列集合还没对齐（p2 走 write_intents 幂等表）",
        "INSERT INTO police_cases",
    ),
    "police_arrests": (
        "逮捕记录 p2_system（agent）与 p3_cases（玩家）双写，审计动作名也尚未统一",
        "INSERT INTO police_arrests",
    ),
    "police_reports": (
        "报告 p1（玩家）、p2_system（agent）、p3_cases（案卷归档）三写，"
        "p3 只 UPDATE 归档状态、p1/p2 负责 INSERT，语义不同需先定义状态机",
        "UPDATE police_reports",
    ),
}

#: 正则的假阳性词（SQL 片段里出现的普通英文单词，不是表名）
NOT_TABLES = {
    "the", "a", "its", "this", "here", "double", "pushing", "matches", "qb",
    "player_vehicles", "players", "phone_invoices", "callsign", "joined_at",
}


def writers() -> dict[str, set[str]]:
    found: dict[str, set[str]] = defaultdict(set)
    for path in sorted(SERVER.glob("*.lua")):
        text = re.sub(r"--[^\n]*", "", path.read_text(encoding="utf-8", errors="ignore"))
        for match in WRITE.finditer(text):
            table = match.group(2).lower()
            if not table.startswith("police_"):
                continue
            found[table].add(path.name)
    return dict(found)


def test_owned_tables_have_exactly_one_writer():
    found = writers()
    offenders = []
    for table, owner in OWNERS.items():
        actual = found.get(table, set())
        if actual != {owner}:
            offenders.append(f"{table}: 期望只有 {owner}，实际 {sorted(actual) or '无人写入'}")
    assert not offenders, "\n".join(offenders)


def test_every_police_table_is_either_owned_or_excepted():
    found = writers()
    unclassified = sorted(set(found) - set(OWNERS) - set(EXCEPTIONS))
    assert not unclassified, (
        "这些表有写入点但既没定 owner 也没登记例外——先决定它归谁：\n  "
        + "\n  ".join(f"{t}: {sorted(found[t])}" for t in unclassified))


def test_exceptions_still_describe_the_truth():
    """例外不是永久豁免：痕迹消失说明表已经收口，这条例外必须删掉。"""
    found = writers()
    stale = []
    for table, (reason, trace) in EXCEPTIONS.items():
        actual = found.get(table, set())
        if len(actual) <= 1:
            stale.append(f"{table}: 现在只有 {sorted(actual)} 在写，例外应删除")
            continue
        if table in OWNERS:
            stale.append(f"{table}: 同时出现在 OWNERS 和 EXCEPTIONS")
        if not reason.strip():
            stale.append(f"{table}: 没写清为什么还不能收口")
    assert not stale, "\n".join(stale)


def test_exception_trace_is_still_visible_in_the_code():
    """登记的证据必须还能在源码里看到，否则说明例外是凭记忆写的。"""
    missing = []
    for table, (_, trace) in EXCEPTIONS.items():
        haystack = "\n".join(
            p.read_text(encoding="utf-8", errors="ignore") for p in SERVER.glob("*.lua"))
        if trace not in haystack:
            missing.append(f"{table}: 找不到痕迹 {trace!r}")
    assert not missing, "\n".join(missing)


def test_owner_files_are_loaded_by_the_manifest():
    manifest = (SERVER.parent / "fxmanifest.lua").read_text(encoding="utf-8")
    missing = [owner for owner in set(OWNERS.values()) if f"server/{owner}" not in manifest]
    assert not missing, f"owner 文件没被 fxmanifest 加载：{missing}"


def test_audit_writer_has_no_nil_holes_and_checks_error_strings():
    """审计写者的两条硬要求，来自真库实测（见 server/audit.lua 头注释）。"""
    src = (SERVER / "audit.lua").read_text(encoding="utf-8")
    assert "NULL" in src, "target/detail 为 nil 时必须把 NULL 写进 SQL，不能留参数洞"
    assert "type(result) == 'string'" in src, (
        "oxmysql 把 SQL 错误当返回值给，不检查它就等于审计可以静默丢失")


def test_scanner_reverse_check(tmp_path: Path):
    """反向校验：喂一份"非 owner 也写同一张表"的源码，必须被抓到。"""
    global SERVER
    original = SERVER
    try:
        SERVER = tmp_path
        (tmp_path / "p0.lua").write_text("UPDATE police_incidents SET status = ?", encoding="utf-8")
        (tmp_path / "rogue.lua").write_text("INSERT INTO police_incidents (code) VALUES (?)", encoding="utf-8")
        found = writers()
        assert found["police_incidents"] == {"p0.lua", "rogue.lua"}
        assert found["police_incidents"] != {OWNERS["police_incidents"]}, "多写者必须与 owner 判定不符"

        (tmp_path / "rogue.lua").unlink()
        assert writers()["police_incidents"] == {OWNERS["police_incidents"]}
    finally:
        SERVER = original
