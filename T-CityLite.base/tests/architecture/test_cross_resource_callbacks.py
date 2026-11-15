"""闸门：MySQL 回调里不许调跨资源函数引用。

真机证据（2026-11-01 / 2026-11-07）：
- 进角色：`QBCore.Player.Save` → `exports['qb-inventory']:SaveInventory(source)`，callee 内
  `QBCore.Functions.GetPlayer(source)` → `Execution of function reference in script host failed`；
- 取抵押车：`qb-garages` 的 `MySQL.scalar` 回调里直接 `Player.Functions.RemoveMoney(...)`，
  同一形态（本闸门在修复前对它报 2 处：`main.lua:276`、`:279`）。

为什么必须闸门而不是一次性修：这类错误的写法看起来完全正常（就是在回调里调个函数），
上线后只在特定路径炸一次，日志里表现为一句 `Execution of function reference`，
定位成本极高。判据放在 CI 里才不会复发。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cross_resource_callback_scan as scan  # noqa: E402


def test_no_cross_resource_reference_inside_mysql_callbacks():
    hits = scan.scan_repo()
    assert hits == [], (
        "MySQL 回调里出现了跨资源函数引用（FiveM 的函数引用在 oxmysql 的异步回调里不可用）：\n  "
        + "\n  ".join(f"{h.file}:{h.line}  [{h.pattern}]  {h.snippet}" for h in hits)
        + "\n修法：把跨资源调用移到同步段（先把数据取回来，再在不带回调的代码里调），"
        "或者像 qb-inventory 那样改成传数据（offline 形态）。"
    )


def test_scanner_catches_the_real_shape_and_ignores_natives():
    """自证：闸门必须对真实形态变红、对原生调用保持绿（否则它会永远绿或永远红）。"""
    dangerous = """
        MySQL.scalar('SELECT depotprice FROM player_vehicles WHERE plate = ?', { plate }, function(result)
            if result then
                Player.Functions.RemoveMoney('cash', result, 'paid-depot')
            end
        end)
    """
    assert len(scan.scan_text(dangerous)) == 1, "没抓到「回调里 Player.Functions.*」这个真实形态"

    via_export = """
        MySQL.update('UPDATE players SET x = 1', {}, function()
            exports['qb-inventory']:SaveInventory(source)
        end)
    """
    assert len(scan.scan_text(via_export)) == 1, "没抓到「回调里 exports[...]」"

    natives_only = """
        MySQL.update('UPDATE t SET a = 1', {}, function()
            TriggerClientEvent('x:y', src)
            TriggerEvent('x:z')
            print(GetPlayerName(src))
        end)
    """
    assert scan.scan_text(natives_only) == [], "原生函数被误报成跨资源函数引用"


def test_scanner_ignores_strings_comments_and_await_calls():
    """文案里的 `Player.Functions.` 不算；`await` 形态没有回调括号，不归这条闸门管。"""
    in_string = """
        MySQL.query('SELECT 1', {}, function()
            TriggerClientEvent('x:notify', src, 'call Player.Functions.AddMoney next time')
        end)
    """
    assert scan.scan_text(in_string) == [], "字符串里的示例代码被误报"

    in_comment = """
        MySQL.query('SELECT 1', {}, function()
            -- Player.Functions.AddMoney 不能放这里
            TriggerClientEvent('x:notify', src)
        end)
    """
    assert scan.scan_text(in_comment) == [], "注释被误报"

    await_form = """
        local row = MySQL.scalar.await('SELECT 1')
        Player.Functions.RemoveMoney('cash', row, 'x')
    """
    assert scan.scan_text(await_form) == [], "await 形态不是本闸门的判定对象（见模块 docstring）"
