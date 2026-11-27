"""两条"下线/落盘"处理器的防御性契约（2026-11-27 真机日志实锤）。

两个坑的共性：**把不同返回形状当成一种**，于是抛错把整段处理器打断。

1. `custom-quest/server/quest_cache.lua` 的 `playerDropped`：
   `QuestRental.CloseOnDrop` 既可能返回 boolean 也可能返回表；`rentRes.idempotent`
   在 boolean 上索引 → 抛错 → 后面的 `ClearAllLogisticsBindings` 不再执行 →
   重连后旧 plate/netId 仍在内存里（"车没还但费率还在"）。
2. `custom-security/server/security.lua` 的落盘回调：
   oxmysql 定制版 update 可能回数字、也可能回 `{ affectedRows = n }`；
   `rowsChanged > 0` 拿表比数字 → 抛错 → 连锁 `nested ref call ... wasn't valid`。

这两条都是 1 行防御，没法用"跑一遍业务"证伪（需要整台服务器 + 掉线时序），
所以用静态契约 + 自证：守卫在 / 拿掉守卫 → 必须红。
"""

from __future__ import annotations

import pathlib

BASE = pathlib.Path(__file__).resolve().parents[2]
QUEST_CACHE = BASE / "resources" / "[custom]" / "custom-quest" / "server" / "quest_cache.lua"
SECURITY = BASE / "resources" / "[custom]" / "custom-security" / "server" / "security.lua"


def _code_only(source: str) -> str:
    """剥掉 `--` 行注释后再做形状判断。

    踩过两次：注释里为了解释坑，会原样写出坏形状（`rowsChanged > 0`、`rentRes.idempotent`），
    拿整段源码当判据就会命中注释 —— 代码改坏了闸门照样绿。
    """
    out = []
    for line in source.splitlines():
        cut = line.find("--")
        out.append(line if cut < 0 else line[:cut])
    return "\n".join(out)


def check_quest(source: str) -> list[str]:
    errors: list[str] = []
    code = _code_only(source)
    at = code.find("AddEventHandler('playerDropped'")
    if at < 0:
        return ["找不到 playerDropped 处理器"]
    body = code[at:at + 1800]
    if "type(rentRes)" not in body:
        errors.append("rentRes 没有判类型：boolean 返回值会在 `.idempotent` 上索引抛错")
    if "rentRes.idempotent" not in body:
        errors.append("找不到 rentRes.idempotent —— 契约漂移，请复核这段")
    return errors


def check_security(source: str) -> list[str]:
    errors: list[str] = []
    code = _code_only(source)
    at = code.find("UPDATE players SET metadata")
    if at < 0:
        return ["找不到 metadata 落盘语句"]
    body = code[max(0, at - 200):at + 900]
    # 合规形态只有一种：走 core-framework 的归一化出口（归一化只许在 db.lua 里，
    # 架构闸门 test_db_result_adapter.py 也是这么要求的）。
    if "Db.AffectedRows(rowsChanged)" not in body:
        errors.append("rowsChanged 没有走 Db.AffectedRows：oxmysql 可能回 { affectedRows }，拿表比数字会抛错")
    if "rowsChanged > 0" in body:
        errors.append("仍在直接比较 rowsChanged > 0（表 > 数字会抛错）")
    return errors


def test_drop_handlers_detects_both_return_shapes():
    """守卫必须在 + 形状归一必须在（`gate_coverage` 按名字认这条为"已证明"）。"""
    q = check_quest(QUEST_CACHE.read_text(encoding="utf-8"))
    s = check_security(SECURITY.read_text(encoding="utf-8"))
    assert not q and not s, "\n".join(q + s)


def test_drop_handlers_gate_detects_gutted_guards():
    """自证：把两处守卫拿掉，检查必须报错。"""
    qsrc = QUEST_CACHE.read_text(encoding="utf-8")
    ssrc = SECURITY.read_text(encoding="utf-8")
    assert not check_quest(qsrc) and not check_security(ssrc)

    q_gutted = qsrc.replace("type(rentRes) == 'table' and", "", 1)
    assert check_quest(q_gutted), "拿掉 rentRes 的类型守卫后闸门仍然全绿"

    # 必须拿掉代码里的那一处（注释里也有这个词，命中注释等于没注入）
    s_gutted = ssrc.replace("Db.AffectedRows(rowsChanged) > 0", "rowsChanged > 0", 1)
    assert check_security(s_gutted), "拿掉 affectedRows 归一后闸门仍然全绿"
