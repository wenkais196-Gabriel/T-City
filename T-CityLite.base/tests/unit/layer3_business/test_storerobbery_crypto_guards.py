"""qb-storerobbery / qb-crypto：两个 Lua 沙箱探针的运行级断言。

| 场景 | 旧实现（276f9efa） | 现在 |
|---|---|---|
| `ExchangeSuccess` 有 stick 但 `RemoveItem` 返回 false | **照样加钱**（白拿） | 不加钱 |
| 没有 cryptostick 就调 `ExchangeSuccess` | 不加钱（`GetItemByName` 挡住） | 不加钱 |
| `Rebooting('hax', 150)` | 原样写入全服状态 | 拒绝 |
| `callCops('register', 1, 'Fake', {9999,9999,9999})` | 把客户端编的坐标推给全警局 | 坐标取 Config |
| `callCops(nil, nil, …)` | `attempt to index a nil value` 崩 | 直接返回 |
| 站在 9999 米外 `setSafeStatus(1)` | **把全服保险箱标成已抢** | 拒绝（要求站在保险箱旁） |
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _run(resource: str, probe: str) -> dict[str, list[str]]:
    proc = subprocess.run(
        ["lua5.4", (FIXTURES / probe).as_posix(), (BASE / "resources" / "[qb]" / resource).as_posix()],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, f"probe 失败：\n{proc.stderr}\n{proc.stdout}"
    parsed: dict[str, list[str]] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        parsed.setdefault(key, []).append(value)
    assert "HANDLER_ERROR" not in parsed, f"handler 抛错：{parsed.get('HANDLER_ERROR')}"
    return parsed


def test_crypto_exchange_never_pays_when_the_stick_is_not_consumed():
    data = _run("qb-crypto", "crypto_probe.lua")
    assert data["MONEY_EVENTS"][0] == "0", "没有 cryptostick 也发了钱"
    assert data["MONEY_EVENTS"][1] == "0", "扣货失败（RemoveItem=false）仍然发钱 —— 等于白拿"
    assert data["MONEY_EVENTS"][2] == "1", "正常兑换没有发钱"
    assert data["STICKS_LEFT"][0] == "0", "正常兑换没有扣掉 cryptostick"

    assert data["STICKS_BACK_AFTER_PAY_FAIL"][0] == "1", "加钱失败后 cryptostick 没有还回去（玩家既丢物品又没钱）"
    assert data["REBOOT_STATE_AFTER_BAD"][0] == "false", "非 boolean 的 state 被写进全服重启状态"
    assert data["REBOOT_PCT_AFTER_BAD"][0] == "0", "越界进度（150）被写进全服状态"
    assert data["REBOOT_PCT_AFTER_GOOD"][0] == "42", "合法进度没写进去"
    assert data["REBOOT_STATE_REMOTE"][0] == "false", "站在 9999 米外也能把全服状态改成「重启中」"
    assert data["REBOOT_PCT_REMOTE"][0] == "0", "站在 9999 米外也能写全服重启进度"
    assert data["REBOOT_STATE_OWNER_FINISH"][0] == "false", "重启发起者走出范围后无法收尾（全服会卡在「重启中」）"
    assert data["REBOOT_PCT_AFTER_NON_OWNER"][0] == "10", "非发起者也能改全服重启进度"
    # 回补失败 → 挂账到 metadata → 上线重试补发
    assert data["OWED_AFTER_DOUBLE_FAIL"][0] == "1", "加钱+回补都失败时没有挂账"
    assert data["OWED_AFTER_RELOAD"][0] == "0", "上线补发后欠账没清"
    assert data["STICKS_AFTER_RELOAD"][0] == "1", "上线补发没有真的给出 cryptostick"


def test_storerobbery_alerts_use_server_coords_and_safes_need_proximity():
    data = _run("qb-storerobbery", "storerobbery_probe.lua")
    assert data["ALERT_SENT"][0] == "true", "合法请求没有发出警情"
    assert data["ALERT_COORDS_FROM_CLIENT"][0] == "false", "警情坐标仍然取客户端传的值"
    assert data["ALERT_COORDS_MATCH_CONFIG"][0] == "true", "警情坐标不是服务端配置的门店坐标"

    assert data["ACTIVE_SETUP"][0] == "true", "探针没能构造活跃抢劫（callcops 正例失效）"
    assert data["ALERTS_FROM_BAD_CALLS"][0] == "0", "坏 kind / 坏 key / 无抢劫记录 / 站在远处仍然发出了警情"
    assert data["SAFE_ROBBED_REMOTE"][0] == "false", "站在远处也能把保险箱标成已抢"
    assert data["SAFE_ROBBED_WITHOUT_ROBBERY"][0] == "false", "没在抢这家店也能把保险箱标成已抢"
    assert data["ACTIVE_TABLE_FOUND"][0] == "true", "探针拿不到 activeRobberies（构造失效）"
    assert data["SAFE_ROBBED_CLOSE"][0] == "true", "站在保险箱旁反而标不了"
    assert data["RECENT_TABLE_FOUND"][0] == "true", "探针拿不到 recentStoreRobberies（构造失效）"
    assert data["AFTER_DROP_ACTIVE"][0] == "true", "玩家掉线后 activeRobberies 没清（GetPlayer 为 nil 时）"
    assert data["AFTER_DROP_RECENT"][0] == "true", "玩家掉线后 recentStoreRobberies 没清（source 复用会继承）"
    assert data["SAFE_ROBBED_RECENT"][0] == "true", "收银机 25 秒计时结束后，同店保险箱就再也标不了（正常玩法被堵）"
