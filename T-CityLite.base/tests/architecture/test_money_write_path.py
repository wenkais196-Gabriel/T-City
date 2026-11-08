"""P1-5 二期闸门：金额写路径是否仍然收敛（三条判据 + 反向形状）。

跑在**去掉注释与字符串**的代码上（`-- PlayerData.money[x] = 5` 不算命中，
`print("PlayerData.money[x] = 1")` 也不算）—— 这条闸门上一轮吃过亏：纯文本匹配把
注释里的一句话算成写路径。
"""

from __future__ import annotations

import money_write_path_scan as scan

OWNER = scan.MONEY_OWNER


# ══════════════════════════════════════════════════════════════════
# 1. 直接写 money 表只允许在收敛层
# ══════════════════════════════════════════════════════════════════


def test_money_table_is_written_only_by_the_convergence_layer():
    report = scan.scan_repo()
    foreign = {path: lines for path, lines in report["assignments"].items() if path != OWNER}
    assert not foreign, (
        "以下文件绕过收敛层直接写 PlayerData.money（走 Player.Functions.AddMoney/RemoveMoney/SetMoney）："
        f"{foreign}"
    )
    # 反向保护：收敛层一处都不写说明扫描器坏了（或写路径被搬走却没登记）
    assert report["assignments"].get(OWNER), "收敛层里找不到任何 money 赋值，扫描器可能失效"


# ══════════════════════════════════════════════════════════════════
# 2. 单笔阈值只定义一次
# ══════════════════════════════════════════════════════════════════


def test_single_transaction_threshold_is_defined_exactly_once():
    report = scan.scan_repo()
    sites = [(path, lines) for path, lines in report["thresholds"].items()]
    total = sum(len(lines) for _, lines in sites)
    assert total == 1, f"MONEY_MAX_SINGLE_TRANSACTION 应当只定义一次，实际 {total} 处：{sites}"


# ══════════════════════════════════════════════════════════════════
# 3. 三个写入口都接同一条校验
# ══════════════════════════════════════════════════════════════════


def test_every_money_entry_calls_the_shared_validator():
    report = scan.scan_repo()
    entries = report["entries"]
    expected = {
        f"{path}:{name}"
        for path in scan.ENTRY_FILES
        for name in ("AddMoney", "RemoveMoney", "SetMoney")
    }
    missing = sorted(name for name in expected if not entries.get(name))
    assert not missing, f"这些写入口没有调用 ValidateAmount：{missing}"


# ══════════════════════════════════════════════════════════════════
# 反向形状：注入错误写法，每条判据都必须红
# ══════════════════════════════════════════════════════════════════

BAD_ASSIGN = """
local function give(player, amount)
    player.PlayerData.money['cash'] = amount
end
"""

GOOD_ASSIGN = """
local function give(player, amount)
    player.Functions.AddMoney('cash', amount)
end
"""

BAD_THRESHOLD_TWICE = """
SecurityService.MONEY_MAX_SINGLE_TRANSACTION = 5000000
OtherService.MONEY_MAX_SINGLE_TRANSACTION = 1000000
"""

BAD_ENTRY = """
function EconomyService.AddMoney(citizenid, moneytype, amount, reason)
    local player = getPlayerByCitizenId(citizenid)
    money[moneytype] = money[moneytype] + amount
    return true
end
"""

GOOD_ENTRY = """
function EconomyService.AddMoney(citizenid, moneytype, amount, reason)
    local ok, cleaned = Security.ValidateAmount(amount, { allowZero = false })
    if not ok then return false end
    return true
end
"""


def test_reverse_foreign_assignment_is_flagged():
    other = "[custom]/custom-shop/server/main.lua"
    assert scan.money_assignments(other, BAD_ASSIGN), "注入的跨资源写表没被识别出来"
    assert not scan.money_assignments("[qb]/qb-core/server/player.lua", GOOD_ASSIGN), (
        "走 Player.Functions 的正常写法被判成了直接写表"
    )


def test_reverse_comment_and_string_are_not_flagged():
    """注释/字符串里的同样文本不算命中 —— 这条是上一轮踩过的坑。"""
    source = """
-- player.PlayerData.money['cash'] = 5   ← 注释
local msg = "player.PlayerData.money['cash'] = 5"
"""
    assert not scan.money_assignments("[custom]/x/server/main.lua", source)


def test_reverse_second_threshold_definition_is_flagged():
    assert len(scan.threshold_definitions("[qb]/qb-core/x.lua", BAD_THRESHOLD_TWICE)) == 2


def test_reverse_entry_without_validator_is_flagged():
    bodies = scan.entry_bodies(BAD_ENTRY)
    assert "AddMoney" in bodies, "切不出函数体，后面所有判据都是假的"
    assert scan.VALIDATOR_CALL not in bodies["AddMoney"]

    good = scan.entry_bodies(GOOD_ENTRY)
    assert scan.VALIDATOR_CALL in good["AddMoney"], "正常写法没被识别成调用校验"
