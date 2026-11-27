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


def check_quest(source: str) -> list[str]:
    errors: list[str] = []
    at = source.find("AddEventHandler('playerDropped'")
    if at < 0:
        return ["找不到 playerDropped 处理器"]
    body = source[at:at + 1800]
    if "type(rentRes)" not in body:
        errors.append("rentRes 没有判类型：boolean 返回值会在 `.idempotent` 上索引抛错")
    if "rentRes.idempotent" not in body:
        errors.append("找不到 rentRes.idempotent —— 契约漂移，请复核这段")
    return errors


def check_security(source: str) -> list[str]:
    errors: list[str] = []
    at = source.find("UPDATE players SET metadata")
    if at < 0:
        return ["找不到 metadata 落盘语句"]
    body = source[max(0, at - 200):at + 900]
    # 认代码里的 `rowsChanged.affectedRows`，不认注释里的词（注释里也有 affectedRows，
    # 用它当判据的话，把代码改坏也照样全绿）。
    if "rowsChanged.affectedRows" not in body:
        errors.append("rowsChanged 没有归一：oxmysql 可能回 { affectedRows }，拿表比数字会抛错")
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
    s_gutted = ssrc.replace("rowsChanged.affectedRows", "rowsChanged.affected_row", 1)
    assert check_security(s_gutted), "拿掉 affectedRows 归一后闸门仍然全绿"
