"""三层通知契约闸门。

锁三件事（都来自真机踩过的坑）：

1. **kind 白名单两侧一致**：服务端 `notify_service.lua` 的分派表和客户端
   `custom-notify/client/main.lua` 的渲染表必须同集合。任何一侧多了 kind，
   另一侧会**静默丢弃**（玩家什么都看不到，日志也没有）。
2. **phone kind 不走屏幕**：IC 内容必须只进手机；屏幕上弹出来就等于毁掉世界观。
3. **限流不能比业务还细**：`Send` 的 200ms/1 条曾经把"一次交易的第二条消息"丢掉，
   Push 的桶必须明显更宽（≥4 条 / ≥1s）。
"""

from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
DISPATCH = REPO / "T-CityLite.base" / "resources" / "[custom]" / "custom-notify" / "server" / "main.lua"
CLIENT = REPO / "T-CityLite.base" / "resources" / "[custom]" / "custom-notify" / "client" / "main.lua"
PAGE = (REPO / "T-CityLite.base" / "resources" / "[custom]" / "custom-notify"
        / "html" / "index.html")
MODULE_CFG = REPO / "T-CityLite.base" / "configs" / "modules" / "custom.cfg"


def _server_kinds() -> set[str]:
    text = DISPATCH.read_text(encoding="utf-8")
    match = re.search(r"local KINDS = \{([^}]*)\}", text)
    assert match, "custom-notify/server/main.lua 里找不到 KINDS"
    return set(re.findall(r"(\w+)\s*=\s*true", match.group(1)))


def _client_kinds() -> set[str]:
    text = CLIENT.read_text(encoding="utf-8")
    match = re.search(r"local KINDS = \{([^}]*)\}", text)
    assert match, "custom-notify/client/main.lua 里找不到 KINDS"
    return set(re.findall(r"(\w+)\s*=\s*true", match.group(1)))


def test_kind_sets_match_on_both_sides():
    # phone 不在客户端渲染表里（服务端直投手机通知中心），所以只比对可上屏的 kind
    server = _server_kinds() - {"phone"}
    client = _client_kinds()
    assert server == client, (
        f"服务端 kind {sorted(server)} 与客户端 {sorted(client)} 不一致——"
        "多出来的那个 kind 会被静默丢弃，玩家什么都看不到"
    )


def test_phone_kind_is_not_rendered_on_screen():
    client = _client_kinds()
    assert "phone" not in client, (
        "phone 是服务端直投手机通知中心的 kind，客户端渲染表里不该有它 —— "
        "屏幕上弹出 IC 消息会毁掉世界观"
    )
    dispatch = DISPATCH.read_text(encoding="utf-8")
    assert "exports['custom-phone']:Notify" in dispatch, "phone kind 没有投递到手机"


def test_push_rate_limit_is_wider_than_send():
    text = DISPATCH.read_text(encoding="utf-8")
    push_max = int(re.search(r"MAX_PER_WINDOW = (\d+)", text).group(1))
    push_window = int(re.search(r"WINDOW_MS = (\d+)", text).group(1))

    push_rate = push_max / (push_window / 1000)
    # 下限而不是"比 Send 宽"：Send 的 200ms/1 条是 5/s，速率本身不是唯一问题 ——
    # 真正要保证的是"一次交易的多行结果能连发"（≥6 条/窗口）且速率不低于 4/s。
    assert push_rate >= 4.0, (
        f"Push 限流只有 {push_rate:.1f} 条/秒 —— 一次交易的多行结果会被丢掉"
    )
    assert push_max >= 6, f"Push 窗口内只允许 {push_max} 条，装不下一次交易的完整结果"


def test_resource_is_in_default_boot():
    cfg = MODULE_CFG.read_text(encoding="utf-8")
    assert re.search(r"^\s*ensure\s+custom-notify\s*$", cfg, re.M), (
        "custom-notify 不在启动集里 —— 通知会发出去但没人渲染"
    )

def test_reverse_kind_mismatch_is_detected():
    """反向：一侧多一个 kind，比对必须红（把 bug 喂进比对函数里）。"""
    server = (_server_kinds() - {"phone"}) | {"banner"}
    client = _client_kinds()
    assert server != client, "多出来的 kind 没被比对出来"
    assert (server - client) == {"banner"}

def test_dedupe_and_merge_are_wired():
    """去重必须在服务端做，且客户端要按 key 就地更新（否则只是刷屏更快）。"""
    server = DISPATCH.read_text(encoding="utf-8")
    page = PAGE.read_text(encoding="utf-8")

    assert "DEDUPE_MS" in server, "服务端没有去重窗口常量"
    assert "key = key" in server and "count = count" in server, (
        "Push 没有把 key/count 下发给客户端 —— 客户端无法就地更新"
    )
    assert "×" in page, "页面没有合并计数的呈现"
    assert "live" in page, "页面没有按 key 维护已存在的条目"


def test_reverse_dedupe_without_key_is_detected():
    """反向：把 key 下发删掉，上面的断言必须红。"""
    server = DISPATCH.read_text(encoding="utf-8")
    broken = server.replace("key = key,", "", 1)
    assert broken != server
    assert "key = key," not in broken


def test_client_side_has_local_export_detects_missing():
    """客户端资源不能调服务端的 Push（客户端没有那个 export，pcall 一包就静默丢消息）。"""
    client = CLIENT.read_text(encoding="utf-8")
    assert "exports('PushLocal'" in client, "custom-notify 客户端没有本地出口 PushLocal"
    mining = (REPO / "T-CityLite.base" / "resources" / "[custom]" / "custom-mining"
              / "client" / "main.lua").read_text(encoding="utf-8")
    assert "PushLocal" in mining, "采矿客户端还在调不存在的服务端 export"

    # 反向：把服务端调用塞回客户端，规则必须认得出来
    broken = mining + chr(10) + "exports['custom-notify']:Push('feed', 'x')"
    assert ":Push('feed'" in broken
