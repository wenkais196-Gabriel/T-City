"""ECON-01 — 钱的写路径只允许一条（宪法②的可执行落点）。

背景：`players.money` 曾经有三个地方直接写 SQL：
`core-framework` 的 Transfer 离线分支、`custom-phone` 的离线汇款、`qb-crypto` 的离线转账。
其中 qb-crypto 那份是 `SET money = ?` —— 先 SELECT 出整块 JSON 再写回，中间任何人动过
bank/cash 都会被静默回滚（丢更新），属于"丢钱/凭空生钱"那一类。

判据（四条，每条都配反向校验）：

1. 只有 owner（`qb-core/server/services/economy_service.lua`）可以写 `players.money`；
   同资源内的持久化层（player.lua / persistence_manager.lua 的整行 upsert）除外，
   因为它们写的是**整行**、且由 DirtyFlush 串行化，不属于"绕过内存的定点改钱"。
2. 任何地方都不准出现 `SET money = ?` 这种整块覆盖。
3. 需要给离线玩家入账的文件，必须走 owner 的 `EconomyAddMoneyOffline`。
4. `Bus.Plugin.GetEconomy()` 必须返回**原语层**（`Bus.EconomyService`）；分层便利方法
   走 `GetEconomyTools()`。两者方法集不同，混用会让调用方拿到没有 RemoveMoney 的对象。

Run: ``python3 -m pytest -q tests/architecture/test_economy_single_owner.py``
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
RESOURCES = BASE / "resources"
OWNER = RESOURCES / "[qb]" / "qb-core" / "server" / "services" / "economy_service.lua"
BUS = RESOURCES / "[standalone]" / "core-framework" / "bus.lua"

# 同属 qb-core 的持久化层：写整行（含 money 列），不是定点改钱
PERSISTENCE_ALLOWED = {
    RESOURCES / "[qb]" / "qb-core" / "server" / "player.lua",
    RESOURCES / "[qb]" / "qb-core" / "server" / "services" / "persistence_manager.lua",
}

# 会给离线玩家入账、必须走 owner 出口的文件
OFFLINE_CALLERS = [
    RESOURCES / "[custom]" / "custom-phone" / "server" / "banking.lua",
    RESOURCES / "[qb]" / "qb-crypto" / "server" / "main.lua",
    RESOURCES / "[standalone]" / "core-framework" / "services" / "economy_service.lua",
]

MONEY_SQL = re.compile(
    r"(UPDATE\s+players[^'\"]{0,400}?money|JSON_SET\s*\(\s*money|SET\s+money\s*=)", re.IGNORECASE | re.DOTALL
)
WHOLE_BLOB = re.compile(r"SET\s+money\s*=\s*\?\s*WHERE", re.IGNORECASE)
SINGLE_WRITE = re.compile(r"money\s*=\s*JSON_SET", re.IGNORECASE)


LINE_COMMENT = re.compile(r"--(?=\[\[).*?\]\]|--[^\n]*", re.DOTALL)


def strip_lua_comments(text: str) -> str:
    """去掉 `--[[ ]]` 与 `-- ...` 注释。

    不剥注释的后果实测过两次：规则会命中"原来是 SET money = ?"这类**说明性**注释，
    于是修好的文件仍然变红，接着就会有人去放宽正则——最后闸门形同虚设。
    """
    return LINE_COMMENT.sub("", text)


def lua_files() -> list[Path]:
    out = []
    for path in RESOURCES.rglob("*.lua"):
        if "node_modules" in path.parts:
            continue
        out.append(path)
    return out


def label(path: Path) -> str:
    try:
        return str(path.relative_to(BASE))
    except ValueError:
        return path.name


def offenders(files: list[Path], owner: Path, allowed: set[Path]) -> list[str]:
    """返回在 owner/allowed 之外写 players.money 的文件。"""
    hits = []
    for path in files:
        if path == owner or path in allowed:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if MONEY_SQL.search(strip_lua_comments(text)):
            hits.append(label(path))
    return sorted(hits)


def whole_blob_writers(files: list[Path]) -> list[str]:
    hits = []
    for path in files:
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if WHOLE_BLOB.search(strip_lua_comments(text)):
            hits.append(label(path))
    return sorted(hits)


def test_only_the_owner_writes_players_money():
    assert OWNER.is_file(), "owner 文件不见了？"
    assert SINGLE_WRITE.search(OWNER.read_text(encoding="utf-8")), (
        "owner 里应该有一处 JSON_SET 的离线入账实现")
    bad = offenders(lua_files(), OWNER, PERSISTENCE_ALLOWED)
    assert not bad, (
        "这些文件在 owner 之外直接改 players.money（钱有第二条写路径）：\n  "
        + "\n  ".join(bad)
        + "\n改成 exports['qb-core']:EconomyAddMoneyOffline(...) 或 Player.Functions.AddMoney/RemoveMoney")


def test_no_whole_blob_money_overwrite():
    bad = whole_blob_writers(lua_files())
    assert not bad, (
        "`SET money = ?` 整块覆盖：先读快照再写回，中间别人动过的 bank/cash 会被静默回滚：\n  "
        + "\n  ".join(bad))


def test_offline_credits_go_through_the_owner_exit():
    problems = []
    for path in OFFLINE_CALLERS:
        assert path.is_file(), f"缺少文件 {path.relative_to(BASE)}"
        text = path.read_text(encoding="utf-8")
        if "EconomyAddMoneyOffline" not in text:
            problems.append(f"{path.relative_to(BASE)}: 给离线玩家入账没走 owner 出口")
    assert not problems, "\n".join(problems)


def test_owner_exit_validates_its_inputs():
    text = OWNER.read_text(encoding="utf-8")
    body = text[text.index("function EconomyService.AddMoneyOffline"):]
    body = body[: body.index("\nend\n") + 5]
    for claim, why in [
        ("VALID_MONEY_TYPES", "货币类型必须走白名单，否则 SQL 里的列名可被拼进任意 JSON 路径"),
        ("amount <= 0", "非正数金额必须拒绝"),
        ("affectedRows", "必须检查影响行数，没命中就得让调用方回滚"),
    ]:
        assert claim in body, f"AddMoneyOffline 缺校验：{why}"


def test_get_economy_returns_the_primitive_first():
    text = BUS.read_text(encoding="utf-8")
    start = text.index("function Bus.Plugin.GetEconomy()")
    body = text[start: text.index("end", start)]
    assert "Bus.EconomyService" in body, "GetEconomy 必须返回原语层"
    assert "Bus.economy " not in body and "Bus.economy\n" not in body, (
        "GetEconomy 不能先返回分层便利层（它没有 RemoveMoney/SetMoney）")
    assert "function Bus.Plugin.GetEconomyTools()" in text, "分层便利层要有独立访问器"


def test_offline_credit_rounds_to_cents():
    """真实调用发现的：@amount 以 DOUBLE 绑定，DECIMAL + 浮点会漂成 100.5499999999999545。"""
    text = (BASE / "resources/[qb]/qb-core/server/services/economy_service.lua").read_text(encoding="utf-8")
    block = text[text.index("function EconomyService.AddMoneyOffline"):]
    block = block[:block.index("\nend\n")]
    assert "ROUND(" in block, "离线入账的 JSON_SET 必须 ROUND(..., 2)，否则金额会被浮点漂移污染"
    assert "ROUND(COALESCE(CAST(JSON_EXTRACT" in block, "ROUND 必须包住整个算术表达式"


# ---------------------------------------------------------------------------
# 反向校验：规则必须真的会红
# ---------------------------------------------------------------------------

def test_rules_fire_on_bad_shapes(tmp_path: Path):
    good = tmp_path / "ok.lua"
    good.write_text("MySQL.update('UPDATE players SET money = JSON_SET(money, \"$.bank\", 1) WHERE citizenid = ?')",
                    encoding="utf-8")
    bad = tmp_path / "bad.lua"
    bad.write_text("MySQL.update('UPDATE players SET money = ? WHERE citizenid = ?')", encoding="utf-8")
    other = tmp_path / "other.lua"
    other.write_text("MySQL.update('UPDATE players SET money = JSON_SET(money, \"$.cash\", 5) WHERE citizenid = ?')",
                     encoding="utf-8")

    assert offenders([other], good, set()) == ["other.lua"], "owner 之外写 money 必须被抓"
    assert not offenders([good], good, set()), "owner 自己写不算违规"
    assert whole_blob_writers([bad]), "整块覆盖必须被抓"
    assert not whole_blob_writers([other]), "JSON_SET 算术不算整块覆盖"
