"""S4 销售 / 配额：全仓唯一的「无对应玩家扣款」净增货币出口。

这里钉住九件事（真跑 Lua + 离线假 DB，MySQL 之外不 mock）：

1. **收入进组织金库**：`SettleSale` 的 revenue = `floor(qty × 服务端单价 × 全局倍率 × 热度)`，
   唯一净增点是 `Treasury.Deposit(ref = 'sale:' .. sale_id)`。
2. **全服配额**：卖满后第 11 件返回 `demand_exhausted`，库存与余额都不动。
3. **单组织 50% 上限**：`quota_total × 0.5`（向下取整）。请求超过自己的剩余份额
   直接 `org_cap_reached`，**不**截断；否则「第二家请求 6 件、全服只剩 5 件」会
   先被全服剩余截断成 5，正好绕过 50% 闸门。
4. **幂等**：同一 `ref` 第二次返回 `duplicate_ref`；`industry_sales` 只有一行，
   组织金库只入账一次（库存与配额也被退回）。
5. **库存不足**：明确选择「按库存截断」（不是拒绝）；测试断言 `result.qty` 与扣减量。
6. **Deposit 失败**：库存、配额、卖单行全部退回；余额与流水不变。
7. **客户端伪造字段无效**：价格/倍率/配额剩余只从服务端配置与 core_economy 拿。
8. **反向注入靶子**：配额 UPDATE 必须同时带
   `quota_used + ? <= quota_total` 与 `SUM(s.qty) ... FLOOR(quota_total * ?)`；
   删掉本组织条件时，第 3 条用例必须变红。
9. **静态证明**：扫 `resources/**/*.lua` 的 `Treasury.Deposit` 调用点，
   净增（非退款/非玩家存款）只有 `SettleSale` 一处；`Player.Functions.AddMoney`
   的合法列表不放宽。

关于「配额 10、卖 10」的口径冲突：单组织上限 = quota_total × 50% 是 #336 定死的
不变量，quota_total = 10 时任何一家组织最多只能卖 5。因此收入公式用例用
quota_total = 20（单组织上限 10）来验证 `10 × 50 × 倍率`；quota_total = 10 的
场景单独用于验证 50% 上限与全服耗尽。两件事不能塞进同一条用例。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

from lua_probe import BASE, DB_ADAPTER

# 复用架构闸门的 Lua 词法工具（剥注释但保留字符串），避免再抄一份扫描器。
sys.path.insert(0, str(BASE / "tests" / "architecture"))
import lua_source  # noqa: E402

RES = BASE / "resources" / "[custom]" / "custom-industry"
SALE_SRC = RES / "server" / "sale.lua"
COMMANDS_SALES_SRC = RES / "server" / "commands_sales.lua"
TREASURY_SRC = RES / "server" / "treasury.lua"
AUDIT_SRC = RES / "server" / "audit.lua"
ACCESS_SRC = RES / "server" / "access.lua"
CONFIG_SRC = RES / "config.lua"
SALES_CONFIG_SRC = RES / "config" / "sales.lua"
FACILITY_CONFIG_SRC = RES / "config" / "facility.lua"
PRODUCTION_CONFIG_SRC = RES / "config" / "production.lua"
MANIFEST = RES / "fxmanifest.lua"
DASHBOARD = BASE / "resources" / "[system]" / "economy-dashboard" / "server" / "main.lua"
MIGRATION = BASE / "migrations" / "v4.3_industry_sales.sql"
SCHEMA_FIXTURE = BASE / "tests" / "fixtures" / "tcity_schema.sql"
PROBE = Path(__file__).resolve().parent / "fixtures" / "industry_sales_probe.lua"

RESOURCES = BASE / "resources"


def lua() -> str:
    exe = shutil.which("lua5.4") or shutil.which("lua")
    if not exe:
        pytest.skip("lua5.4 不可用")
    return exe


def parse(out_text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in out_text.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        out.setdefault(key.strip(), value.strip())
    return out


def config_text() -> str:
    return "\n".join(
        path.read_text(encoding="utf-8")
        for path in (CONFIG_SRC, FACILITY_CONFIG_SRC, PRODUCTION_CONFIG_SRC, SALES_CONFIG_SRC)
    )


def lua_table(values: dict[str, str]) -> str:
    return "{ " + ", ".join(f"{key} = '{value}'" for key, value in values.items()) + " }"


def run(body: str, convars: dict[str, str] | None = None) -> dict[str, str]:
    """fixture（假 DB）→ db.lua → 可选 convar → 真实配置/模块 → body。"""
    prelude = f"__convars = {lua_table(convars)}\n" if convars else ""
    script = (
        PROBE.read_text(encoding="utf-8")
        + "\n"
        + DB_ADAPTER.read_text(encoding="utf-8")
        + "\n"
        + prelude
        + config_text()
        + "\n"
        + TREASURY_SRC.read_text(encoding="utf-8")
        + "\n"
        + AUDIT_SRC.read_text(encoding="utf-8")
        + "\n"
        + ACCESS_SRC.read_text(encoding="utf-8")
        + "\n"
        + SALE_SRC.read_text(encoding="utf-8")
        + "\n"
        + textwrap.dedent(body)
    )
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}\n{proc.stdout}"
    return parse(proc.stdout)


# ══════════════════════════════════════════════════════════════════
# 1. 正常卖单：收入进组织金库，配额/库存同步推进
# ══════════════════════════════════════════════════════════════════


def test_sale_credits_treasury_once_and_moves_quota_and_stock():
    """quota_total=20（单组织上限 10）→ 卖 10 件 × $50 × 1.25 = $625。"""
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacility('mining_co', 100)
        __seedDemand('iron_ore', 20, 0)
        __globalMultiplier = 1.25
        __activityHeat = 1.0

        local ok, err, result = IndustrySales.SettleSale(
            'mining_co', 'iron_ore', 10, 'sale-ref-1')
        local demand = __demandRow('iron_ore')
        local sale = __salesRows()[1]

        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('REVENUE', tostring(result and result.revenue))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('QUOTA', tostring(demand and demand.quota_used))
        __emit('STOCK', tostring(__stock('mining_co')))
        __emit('SALES', tostring(__salesCount()))
        __emit('UNIT', tostring(sale and sale.unit_price))
        __emit('QTY', tostring(sale and sale.qty))
        __emit('LEDGER', tostring(__ledgerCount()))
        __emit('LEDGER_REF', tostring(__ledger[1] and __ledger[1].ref))
        __emit('LEDGER_DELTA', tostring(__ledger[1] and __ledger[1].delta))
        __emit('AUDIT', tostring(__auditActions()))
        __emit('EVENTS', tostring(__saleEventCount()))
    """)
    assert out["OK"] == "true" and out["ERR"] == "nil", f"正常卖单失败：{out}"
    assert out["REVENUE"] == "625", f"收入不是 10×50×1.25：{out}"
    assert out["BAL"] == "625", "组织金库没有收到卖单收入"
    assert out["QUOTA"] == "10", "quota_used 没有 +10"
    assert out["STOCK"] == "90", "库存没有 -10"
    assert out["SALES"] == "1" and out["UNIT"] == "50" and out["QTY"] == "10"
    assert out["LEDGER"] == "1", "收入必须写且只写一条 org_ledger"
    assert out["LEDGER_REF"] == "sale:1", "流水 ref 必须是 'sale:' .. sale_id"
    assert out["LEDGER_DELTA"] == "625"
    assert out["AUDIT"] == "industry.sale", "成功卖单必须写审计"
    assert out["EVENTS"] == "1", "成功入账后必须发 industry:sale（dashboard 靠它）"


# ══════════════════════════════════════════════════════════════════
# 2. 全服配额耗尽：第 11 件不动任何状态
# ══════════════════════════════════════════════════════════════════


def test_eleventh_unit_is_demand_exhausted_and_changes_nothing():
    """quota_total=10，两家各卖 5（各占 50%）后，再卖 1 就是第 11 件。"""
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedOrg('cartel', 0)
        __seedFacility('mining_co', 100)
        __seedFacility('cartel', 100)
        __seedDemand('iron_ore', 10, 0)

        local ok1 = IndustrySales.SettleSale('mining_co', 'iron_ore', 5, 'a1')
        local ok2 = IndustrySales.SettleSale('cartel', 'iron_ore', 5, 'b1')
        local stockBefore = __stock('mining_co')
        local balanceBefore = __balance('mining_co')

        local ok, err = IndustrySales.SettleSale('mining_co', 'iron_ore', 1, 'a2')

        __emit('FIRST', tostring(ok1))
        __emit('SECOND', tostring(ok2))
        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('QUOTA', tostring(__demandRow('iron_ore').quota_used))
        __emit('SALES', tostring(__salesCount()))
        __emit('STOCK_SAME', tostring(__stock('mining_co') == stockBefore))
        __emit('BAL_SAME', tostring(__balance('mining_co') == balanceBefore))
    """)
    assert out["FIRST"] == "true" and out["SECOND"] == "true", f"前面 10 件没卖成：{out}"
    assert out["OK"] == "false" and out["ERR"] == "demand_exhausted", (
        f"第 11 件必须是 demand_exhausted：{out}"
    )
    assert out["QUOTA"] == "10" and out["SALES"] == "2", "拒绝时不能多扣配额/多写卖单"
    assert out["STOCK_SAME"] == "true" and out["BAL_SAME"] == "true", (
        "被拒绝的卖单动了库存或余额"
    )


# ══════════════════════════════════════════════════════════════════
# 3. 单组织 50% 上限（反向注入靶子）
# ══════════════════════════════════════════════════════════════════


def test_second_org_over_half_the_quota_is_org_cap_reached():
    """quota_total=10 → 每家上限 5；第二家请求 6 必须拒绝，不能截断成 5。

    反向注入：删掉配额 UPDATE 里的 `SUM(s.qty) ... FLOOR(quota_total * ?)`
    条件（或把它挪到全服剩余截断之后），本用例必须变红。
    """
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedOrg('cartel', 0)
        __seedFacility('mining_co', 100)
        __seedFacility('cartel', 100)
        __seedDemand('iron_ore', 10, 0)

        local okA = IndustrySales.SettleSale('mining_co', 'iron_ore', 5, 'a1')
        local stockBefore = __stock('cartel')
        local balanceBefore = __balance('cartel')

        local ok, err = IndustrySales.SettleSale('cartel', 'iron_ore', 6, 'b1')

        __emit('A', tostring(okA))
        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('QUOTA', tostring(__demandRow('iron_ore').quota_used))
        __emit('SALES', tostring(__salesCount()))
        __emit('STOCK_SAME', tostring(__stock('cartel') == stockBefore))
        __emit('BAL_SAME', tostring(__balance('cartel') == balanceBefore))
    """)
    assert out["A"] == "true", f"第一家 5 件应当成功：{out}"
    assert out["OK"] == "false" and out["ERR"] == "org_cap_reached", (
        f"第二家超 50% 必须 org_cap_reached：{out}"
    )
    assert out["QUOTA"] == "5" and out["SALES"] == "1", "被拒绝的第二家不能扣配额/写卖单"
    assert out["STOCK_SAME"] == "true" and out["BAL_SAME"] == "true"


def test_quota_update_carries_both_global_and_org_cap_cas():
    """静态钉子：两条 CAS 必须写在同一条 UPDATE 里。"""
    source = SALE_SRC.read_text(encoding="utf-8")
    assert "UPDATE industry_demand SET quota_used = quota_used + ?" in source
    assert "quota_used + ? <= quota_total" in source, "全服剩余 CAS 不见了"
    assert "SUM(s.qty)" in source and "FLOOR(quota_total * ?)" in source, (
        "本组织 50% 上限没有进同一条配额 UPDATE —— 并发下会被绕过"
    )
    assert "restoreStock" in source and "restoreQuota" in source, "失败补偿路径不见了"


# ══════════════════════════════════════════════════════════════════
# 4. 幂等：同一 ref 只入账一次
# ══════════════════════════════════════════════════════════════════


def test_same_ref_is_duplicate_and_rolls_back_stock_and_quota():
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacility('mining_co', 100)
        __seedDemand('iron_ore', 20, 0)

        local ok1, err1 = IndustrySales.SettleSale('mining_co', 'iron_ore', 2, 'same-ref')
        local ok2, err2 = IndustrySales.SettleSale('mining_co', 'iron_ore', 2, 'same-ref')

        __emit('OK1', tostring(ok1))
        __emit('ERR1', tostring(err1 or 'nil'))
        __emit('OK2', tostring(ok2))
        __emit('ERR2', tostring(err2 or 'nil'))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('QUOTA', tostring(__demandRow('iron_ore').quota_used))
        __emit('STOCK', tostring(__stock('mining_co')))
        __emit('SALES', tostring(__salesCount()))
        __emit('LEDGER', tostring(__ledgerCount()))
    """)
    assert out["OK1"] == "true" and out["ERR1"] == "nil"
    assert out["OK2"] == "false" and out["ERR2"] == "duplicate_ref", (
        f"同一 ref 第二次必须 duplicate_ref：{out}"
    )
    assert out["BAL"] == "100", "同一 ref 被入账了两次"
    assert out["QUOTA"] == "2", "重复卖单的配额没有退回"
    assert out["STOCK"] == "98", "重复卖单的库存没有退回"
    assert out["SALES"] == "1" and out["LEDGER"] == "1"


def test_concurrent_same_org_sale_is_serialized_by_the_inflight_lock():
    """同组织两个请求在 await 之间交错时，第二个必须看到 busy。

    50% 判据读的是 industry_sales，而当前卖单要到第 ③ 步才插入；没有 Lua 侧
    串行化时两个请求都会读到旧累计、各自通过 50% 闸门。这里在第一次扣库存
    落库前插入第二个同组织请求，断言它被 busy 挡住且只产生一笔卖单。
    """
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacility('mining_co', 10)
        __seedDemand('iron_ore', 20, 0)

        __raceResult = 'not-fired'
        __raceBeforeStockUpdate = function()
            local ok, err = IndustrySales.SettleSale('mining_co', 'iron_ore', 1, 'nested')
            __raceResult = tostring(ok) .. ':' .. tostring(err or 'nil')
        end

        local ok, err = IndustrySales.SettleSale('mining_co', 'iron_ore', 2, 'outer')

        __emit('OUTER', tostring(ok))
        __emit('OUTER_ERR', tostring(err or 'nil'))
        __emit('RACE', tostring(__raceResult))
        __emit('SALES', tostring(__salesCount()))
        __emit('LEDGER', tostring(__ledgerCount()))
        __emit('STOCK', tostring(__stock('mining_co')))
        __emit('QUOTA', tostring(__demandRow('iron_ore').quota_used))
        __emit('BAL', tostring(__balance('mining_co')))
    """)
    assert out["OUTER"] == "true" and out["OUTER_ERR"] == "nil", f"外层卖单失败：{out}"
    assert out["RACE"] == "false:busy", f"交错进来的同组织请求没有被挡：{out}"
    assert out["SALES"] == "1" and out["LEDGER"] == "1", "交错请求产生了第二笔卖单/入账"
    assert out["STOCK"] == "8" and out["QUOTA"] == "2" and out["BAL"] == "100"


# ══════════════════════════════════════════════════════════════════
# 5. 库存不足：明确按库存截断
# ══════════════════════════════════════════════════════════════════


def test_stock_shortage_truncates_to_available_stock():
    """本片的选择是**截断**（不是拒绝）：请求 5、库存 3 → 卖 3。

    二选一必须写清楚并断言；这里断言 `result.qty == 3`、库存归零、只按 3 件入账。
    """
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacility('mining_co', 3)
        __seedDemand('iron_ore', 20, 0)

        local ok, err, result = IndustrySales.SettleSale(
            'mining_co', 'iron_ore', 5, 'stock-short')

        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('QTY', tostring(result and result.qty))
        __emit('REVENUE', tostring(result and result.revenue))
        __emit('STOCK', tostring(__stock('mining_co')))
        __emit('QUOTA', tostring(__demandRow('iron_ore').quota_used))
        __emit('BAL', tostring(__balance('mining_co')))
    """)
    assert out["OK"] == "true" and out["ERR"] == "nil", f"有库存时不应拒绝：{out}"
    assert out["QTY"] == "3", "库存不足时没有截断到实际库存"
    assert out["REVENUE"] == "150", "收入按请求量算了，而不是按实际卖出量"
    assert out["STOCK"] == "0" and out["QUOTA"] == "3" and out["BAL"] == "150"


def test_no_stock_returns_stock_empty_and_changes_nothing():
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacility('mining_co', 0)
        __seedDemand('iron_ore', 20, 0)

        local ok, err = IndustrySales.SettleSale('mining_co', 'iron_ore', 1, 'empty')

        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('QUOTA', tostring(__demandRow('iron_ore').quota_used))
        __emit('BAL', tostring(__balance('mining_co')))
    """)
    assert out["OK"] == "false" and out["ERR"] == "stock_empty", f"{out}"
    assert out["QUOTA"] == "0" and out["BAL"] == "0"


# ══════════════════════════════════════════════════════════════════
# 6. Deposit 失败：库存、配额、卖单行全部退回
# ══════════════════════════════════════════════════════════════════


def test_deposit_failure_restores_stock_quota_and_sale_row():
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacility('mining_co', 10)
        __seedDemand('iron_ore', 20, 0)
        __failTreasuryUpdate = true

        local ok, err = IndustrySales.SettleSale('mining_co', 'iron_ore', 2, 'dep-fail')

        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('STOCK', tostring(__stock('mining_co')))
        __emit('QUOTA', tostring(__demandRow('iron_ore').quota_used))
        __emit('SALES', tostring(__salesCount()))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEDGER', tostring(__ledgerCount()))
        __emit('AUDIT', tostring(__auditActions()))
        __emit('EVENTS', tostring(__saleEventCount()))
    """)
    assert out["OK"] == "false" and out["ERR"] == "db_error", (
        f"Deposit 失败必须返回 db_error：{out}"
    )
    assert out["STOCK"] == "10", "Deposit 失败后库存没有退回（钱没进、货也没了）"
    assert out["QUOTA"] == "0", "Deposit 失败后配额没有退回"
    assert out["SALES"] == "0", "Deposit 失败后卖单行没有删除（会挡住同 ref 重试）"
    assert out["BAL"] == "0" and out["LEDGER"] == "0", "Deposit 失败却动了余额/流水"
    assert out["AUDIT"] == "industry.sale", "失败的卖单也要留审计"
    assert out["EVENTS"] == "0", "钱没进就不该发 industry:sale"


# ══════════════════════════════════════════════════════════════════
# 7. 客户端伪造价格/倍率/配额字段一律无效
# ══════════════════════════════════════════════════════════════════


def test_client_supplied_price_and_multiplier_are_ignored():
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacility('mining_co', 10)
        __seedDemand('iron_ore', 20, 0)
        __globalMultiplier = 1.0
        __activityHeat = 1.0

        -- 第 5 个参数在 SettleSale 的签名之外：传什么都进不了公式。
        local ok, err, result = IndustrySales.SettleSale(
            'mining_co', 'iron_ore', 2, 'forge',
            { price = 1, unit_price = 1, multiplier = 999, revenue = 999, quota_used = 0 })

        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('REVENUE', tostring(result and result.revenue))
        __emit('UNIT', tostring(result and result.unit_price))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('QUOTA', tostring(__demandRow('iron_ore').quota_used))
    """)
    assert out["OK"] == "true", f"{out}"
    assert out["REVENUE"] == "100", "客户端伪造的价格/倍率进了收入公式"
    assert out["UNIT"] == "50", "单价不是服务端配置"
    assert out["BAL"] == "100" and out["QUOTA"] == "2"


def test_multiplier_and_heat_come_from_core_economy_only():
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacility('mining_co', 10)
        __seedDemand('iron_ore', 20, 0)
        __globalMultiplier = 1.25
        __activityHeat = 1.2

        local ok, err, result = IndustrySales.SettleSale(
            'mining_co', 'iron_ore', 10, 'coeff')

        __emit('OK', tostring(ok))
        __emit('REVENUE', tostring(result and result.revenue))
    """)
    assert out["OK"] == "true"
    # floor(10 × 50 × 1.25 × 1.2) = 750
    assert out["REVENUE"] == "750", f"core_economy 的全局倍率/热度没有进公式：{out}"
    source = SALE_SRC.read_text(encoding="utf-8")
    assert "GetGlobalMultiplier" in source and "GetActivityHeat" in source
    assert "economy_reward_scale" not in source, (
        "sale.lua 自己读了全局倍率 convar —— 系数必须只从 core_economy 拿"
    )


# ══════════════════════════════════════════════════════════════════
# 7b. 玩家侧入口：只复用 IndustryAccess.IsOrgBoss（S5 调这个）
# ══════════════════════════════════════════════════════════════════


def test_player_entry_reuses_is_org_boss_and_sells_through_settle_sale():
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacility('mining_co', 10)
        __seedDemand('iron_ore', 20, 0)

        local boss = { PlayerData = { job = { name = 'miner', grade = { level = 4 } } } }
        local member = { PlayerData = { job = { name = 'miner', grade = { level = 1 } } } }

        local okBoss, errBoss = IndustrySales.SellForPlayer(
            boss, 'mining_co', 'iron_ore', 1, 'boss')
        local okMember, errMember = IndustrySales.SellForPlayer(
            member, 'mining_co', 'iron_ore', 1, 'member')
        local okNil, errNil = IndustrySales.SellForPlayer(
            nil, 'mining_co', 'iron_ore', 1, 'nil')

        __emit('BOSS', tostring(okBoss))
        __emit('BOSS_ERR', tostring(errBoss or 'nil'))
        __emit('MEMBER', tostring(okMember))
        __emit('MEMBER_ERR', tostring(errMember or 'nil'))
        __emit('NIL', tostring(okNil))
        __emit('NIL_ERR', tostring(errNil or 'nil'))
        __emit('SALES', tostring(__salesCount()))
        __emit('STOCK', tostring(__stock('mining_co')))
        __emit('BAL', tostring(__balance('mining_co')))
    """)
    assert out["BOSS"] == "true" and out["BOSS_ERR"] == "nil", f"Boss 卖单失败：{out}"
    assert out["MEMBER"] == "false" and out["MEMBER_ERR"] == "not_boss", (
        f"非 Boss 必须 not_boss：{out}"
    )
    assert out["NIL"] == "false" and out["NIL_ERR"] == "not_player"
    assert out["SALES"] == "1" and out["STOCK"] == "9" and out["BAL"] == "50", (
        "被拒绝的玩家请求动了库存/金库"
    )


# ══════════════════════════════════════════════════════════════════
# 8. 输入校验 / 需求行缺失
# ══════════════════════════════════════════════════════════════════


def test_invalid_inputs_and_missing_demand_change_nothing():
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacility('mining_co', 10)

        local _, e1 = IndustrySales.SettleSale('bad org!', 'iron_ore', 1, 'x1')
        local _, e2 = IndustrySales.SettleSale('mining_co', 'bad item!', 1, 'x2')
        local _, e3 = IndustrySales.SettleSale('mining_co', 'iron_ore', 0, 'x3')
        local _, e4 = IndustrySales.SettleSale('mining_co', 'iron_ore', 1.5, 'x4')
        local _, e5 = IndustrySales.SettleSale('mining_co', 'unpriced_item', 1, 'x5')
        local _, e6 = IndustrySales.SettleSale('mining_co', 'iron_ore', 1, 'x6')

        __emit('E1', tostring(e1))
        __emit('E2', tostring(e2))
        __emit('E3', tostring(e3))
        __emit('E4', tostring(e4))
        __emit('E5', tostring(e5))
        __emit('E6', tostring(e6))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('SALES', tostring(__salesCount()))
    """)
    assert out["E1"] == "bad_org"
    assert out["E2"] == "bad_item"
    assert out["E3"] == "bad_qty" and out["E4"] == "bad_qty"
    assert out["E5"] == "bad_price"
    assert out["E6"] == "no_demand", f"缺需求行必须是 no_demand：{out}"
    assert out["BAL"] == "0" and out["SALES"] == "0"


def test_missing_facility_is_not_built():
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedDemand('iron_ore', 20, 0)
        local ok, err = IndustrySales.SettleSale('mining_co', 'iron_ore', 1, 'nb')
        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
    """)
    assert out["OK"] == "false" and out["ERR"] == "not_built"


# ══════════════════════════════════════════════════════════════════
# 9. 种子需求行：迁移插入 + 启动时 convar 校准
# ══════════════════════════════════════════════════════════════════


def test_ensure_seed_uses_convar_and_never_shrinks_used_quota():
    out = run("""
        __reset()
        local ok, err = IndustrySales.EnsureSeed()
        local first = __demandRow('iron_ore')
        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('TOTAL1', tostring(first and first.quota_total))
        __emit('USED1', tostring(first and first.quota_used))

        -- 已经卖过 4 件：convar 再小也不能把 quota_total 改到 quota_used 以下。
        __seedDemand('iron_ore', 10, 4)
        local ok2 = IndustrySales.EnsureSeed()
        local second = __demandRow('iron_ore')
        __emit('OK2', tostring(ok2))
        __emit('TOTAL2', tostring(second and second.quota_total))
        __emit('USED2', tostring(second and second.quota_used))
    """, convars={"industry_demand_seed": "7"})
    assert out["OK"] == "true" and out["ERR"] == "nil", f"种子行写入失败：{out}"
    assert out["TOTAL1"] == "7", "quota_total 没有按 convar industry_demand_seed 校准"
    assert out["USED1"] == "0"
    assert out["OK2"] == "true"
    assert out["TOTAL2"] == "10", "quota_used > 0 时 EnsureSeed 改小了总量"
    assert out["USED2"] == "4"


def test_migration_and_schema_fixture_declare_tables_and_idempotency_key():
    def strip(sql: str) -> str:
        return re.sub(r"--[^\n]*", "", re.sub(r"/\*.*?\*/", "", sql, flags=re.S))

    migration = strip(MIGRATION.read_text(encoding="utf-8"))
    fixture = strip(SCHEMA_FIXTURE.read_text(encoding="utf-8"))

    for table in ("industry_demand", "industry_sales"):
        pattern = rf"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+`{table}`"
        assert re.search(pattern, migration, re.I), f"迁移里没有建 {table}"
        assert re.search(pattern, fixture, re.I), f"测试 fixture 里没有建 {table}"

    unique = re.compile(
        r"UNIQUE\s+KEY\s+`uniq_org_ref`\s*\(\s*`org_id`\s*,\s*`ref`\s*\)", re.I
    )
    assert unique.search(migration), "industry_sales 缺少 UNIQUE(org_id, ref) 幂等键"
    assert unique.search(fixture), "fixture 与迁移不一致：industry_sales 缺 uniq_org_ref"
    assert re.search(
        r"PRIMARY\s+KEY\s*\(\s*`cycle_no`\s*,\s*`phase`\s*,\s*`item_name`\s*\)",
        migration, re.I,
    ), "industry_demand 的主键必须是 (cycle_no, phase, item_name)"
    assert re.search(r"INSERT\s+IGNORE\s+INTO\s+`industry_demand`", migration, re.I), (
        "迁移没有插入 iron_ore 的种子需求行"
    )


# ══════════════════════════════════════════════════════════════════
# 10. 静态证明：全仓只有 SettleSale 一处净增货币点
# ══════════════════════════════════════════════════════════════════


DEPOSIT_CALL = re.compile(r"(?<!function )Treasury\.Deposit\s*\(")
ADD_MONEY_CALL = re.compile(r"Player\.Functions\.AddMoney\s*\(")

#: 冻结的 Treasury.Deposit 调用点 = (文件, 第 3 个参数)，含重复（facility 有两处回滚）。
#: 除了 sale 之外的每一条都有对应的「先扣」或「回滚」；`reason` 是 S1 的
#: /orgfundgrant 控制台注入（source == 0，不是玩法货币源），本片不放宽/不新增。
EXPECTED_DEPOSIT_SITES = [
    ("custom-industry/server/commands.lua", "deposit"),                  # 先 RemoveMoney 再存
    ("custom-industry/server/commands.lua", "reason"),                   # /orgfundgrant 控制台
    ("custom-industry/server/commands.lua", "withdraw-rollback"),        # 发放失败退回
    ("custom-industry/server/facility.lua", "facility-build-rollback"),  # 建施失败退回
    ("custom-industry/server/facility.lua", "workstation-rollback"),     # 工位 CAS 失败退回
    ("custom-industry/server/facility.lua", "workstation-rollback"),     # updateErr 分支
    ("custom-industry/server/sale.lua", "sale"),                         # S4 唯一净增
]


def _third_arguments(text: str, pattern: re.Pattern[str]) -> list[str]:
    """按顶层逗号取第 3 个参数（Deposit 的 reason / AddMoney 的 reason）。"""
    code = lua_source.blank_noise(text, keep_strings=True)
    found: list[str] = []
    for match in pattern.finditer(code):
        open_index = match.end() - 1
        close = lua_source.match_paren(code, open_index)
        spans = lua_source.argument_spans(code, open_index, close)
        if len(spans) < 3:
            continue
        found.append(code[spans[2][0]:spans[2][1]].strip())
    return found


def _literal(arg: str) -> str:
    match = re.fullmatch(r"'([^']*)'", arg)
    return match.group(1) if match else arg


def _resource_relative(path: Path) -> str:
    rel = path.relative_to(RESOURCES).as_posix()
    return re.sub(r"^\[[^\]]+\]/", "", rel)


def _deposit_sites() -> list[tuple[str, str]]:
    sites: list[tuple[str, str]] = []
    for path in sorted(RESOURCES.rglob("*.lua")):
        if "node_modules" in path.parts:
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for argument in _third_arguments(text, DEPOSIT_CALL):
            sites.append((_resource_relative(path), _literal(argument)))
    return sites


def test_only_settle_sale_is_a_net_organization_money_source():
    sites = _deposit_sites()
    assert sorted(sites) == sorted(EXPECTED_DEPOSIT_SITES), (
        "Treasury.Deposit 调用点变了。全仓净增组织货币点必须只有 SettleSale 一处；"
        f"新增/改名都要在这里显式登记：actual={sorted(sites)}"
    )
    assert [site for site in sites if site[1] == "sale"] == [
        ("custom-industry/server/sale.lua", "sale")
    ], "净增点必须且只能来自 sale.lua"

    sale_code = lua_source.blank_noise(SALE_SRC.read_text(encoding="utf-8"), keep_strings=True)
    body_start = sale_code.index("local function settleLocked(")
    assert "Treasury.Deposit" in sale_code[body_start:], (
        "净增点不在 SettleSale 的结算主体里"
    )
    assert "pcall(settleLocked" in sale_code[sale_code.index("function IndustrySales.SettleSale("):], (
        "公开入口没有走带组织锁的结算主体"
    )


def test_no_new_player_money_mint_in_custom_industry_or_dashboard():
    """`Player.Functions.AddMoney` 的合法列表不放宽：S4 不新增玩家侧造钱点。"""
    industry_add_money: list[tuple[str, str]] = []
    for path in sorted((RES / "server").glob("*.lua")):
        text = path.read_text(encoding="utf-8", errors="ignore")
        for argument in _third_arguments(text, ADD_MONEY_CALL):
            industry_add_money.append((path.name, _literal(argument)))

    assert sorted(industry_add_money) == [
        ("commands.lua", "orgfunddeposit-refund"),
        ("commands.lua", "orgfundwithdraw"),
    ], f"custom-industry 的 AddMoney 列表变了：{industry_add_money}"

    assert "Player.Functions.AddMoney" not in SALE_SRC.read_text(encoding="utf-8")
    assert "Player.Functions.AddMoney" not in COMMANDS_SALES_SRC.read_text(encoding="utf-8")
    assert "Player.Functions.AddMoney" not in DASHBOARD.read_text(encoding="utf-8")
    assert "TriggerReward" not in SALE_SRC.read_text(encoding="utf-8"), (
        "SettleSale 不能用 TriggerReward（组织没有 source，且它是玩家出口）"
    )


# ══════════════════════════════════════════════════════════════════
# 11. dashboard 必须看见组织入账
# ══════════════════════════════════════════════════════════════════


def test_dashboard_subscribes_to_industry_sale_inflow():
    dashboard = DASHBOARD.read_text(encoding="utf-8")
    sale = SALE_SRC.read_text(encoding="utf-8")

    assert "'industry:sale'" in sale, "S4 没有发 industry:sale 事件"
    assert "AddEventHandler('industry:sale'" in dashboard, (
        "economy-dashboard 没有订阅 industry:sale —— 组织入账会是看不见的钱源"
    )
    assert "industrySaleInflow" in dashboard, "dashboard 没有单独累计组织卖单流入"
    assert "industrySale = state.cashFlow.industrySaleInflow" in dashboard, (
        "GetDashboard 导出里看不到 industry sale 流入"
    )


# ══════════════════════════════════════════════════════════════════
# 12. 接线：manifest 全加载 + 后台入口默认关闭
# ══════════════════════════════════════════════════════════════════

WIRING_STUBS = """
GetConvar = function(name, default)
    if name == 'industry_enable' then return 'true' end
    if name == 'industry_sales_debug' then return '__DEBUG__' end
    if name == 'industry_production_debug' then return 'false' end
    return default
end

__registered = {}
__native = {}
__events = 0
__threads = 0
local coreObject = {
    Commands = {
        Add = function(name) __registered[#__registered + 1] = name end,
    },
    Functions = {
        GetPlayer = function() return nil end,
        HasPermission = function() return false end,
    },
}

exports = setmetatable({}, {
    __index = function(_, resource)
        if resource ~= 'qb-core' then return nil end
        return { GetCoreObject = function() return coreObject end }
    end,
})

MySQL = {}

AddEventHandler = function() __events = __events + 1 end
CreateThread = function() __threads = __threads + 1 end
Wait = function() end
RegisterCommand = function(name, _, restricted)
    __native[#__native + 1] = name .. ':' .. tostring(restricted)
end

function __emit(key, value)
    io.write(tostring(key) .. '|' .. tostring(value) .. string.char(10))
end
"""


def server_script_files() -> list[Path]:
    text = MANIFEST.read_text(encoding="utf-8")
    match = re.search(r"server_scripts\s*\{(.*?)\}", text, re.S)
    assert match, "fxmanifest 里找不到 server_scripts 块"
    entries = re.findall(r"['\"]([^'\"]+)['\"]", match.group(1))
    files = [RES / entry for entry in entries if not entry.startswith("@")]
    assert files, "server_scripts 里没有任何本地文件"
    for path in files:
        assert path.is_file(), f"manifest 列出的文件不存在：{path}"
    return files


def run_wiring(debug: bool) -> dict[str, str]:
    files = server_script_files()
    first, rest = files[0], files[1:]
    body = "\n".join(path.read_text(encoding="utf-8") for path in rest) + "\n" + """
        __emit('QBCORE_COUNT', tostring(#__registered))
        __emit('QBCORE_NAMES', table.concat(__registered, ','))
        __emit('NATIVE', table.concat(__native, ','))
        __emit('EVENTS', tostring(__events))
        __emit('THREADS', tostring(__threads))
        __emit('HAS_GLOBAL', tostring(rawget(_G, 'QBCore') ~= nil))
    """
    stubs = WIRING_STUBS.replace("__DEBUG__", "true" if debug else "false")
    script = (
        stubs
        + "\n"
        + DB_ADAPTER.read_text(encoding="utf-8")
        + "\n"
        + first.read_text(encoding="utf-8")
        + "\n"
        + body
    )
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}\n{proc.stdout}"
    return parse(proc.stdout)


def test_all_server_scripts_wire_without_global_qbcore_and_debug_command_is_off():
    out = run_wiring(debug=False)
    expected = {
        "orgfund", "orgfunddeposit", "orgfundwithdraw", "orgfundgrant",
        "orgbuild", "orghire", "orgfacility",
    }
    assert out["QBCORE_COUNT"] == "7", f"QBCore 命令表被 S4 污染了：{out}"
    assert sorted(filter(None, out["QBCORE_NAMES"].split(","))) == sorted(expected)
    assert out["NATIVE"] == "", (
        f"industry_sales_debug 默认必须关闭（orgsell 不该注册）：{out}"
    )
    assert out["EVENTS"] == "1", "S4 不该新增事件处理器（只有 S3 的 PlayerLoaded）"
    assert out["THREADS"] == "1", "S4 不该新增调度（只有 S3 的生产心跳）"
    assert out["HAS_GLOBAL"] == "false", "用例自己定义了全局 QBCore，会掩盖真机事故"


def test_debug_sale_command_registers_only_when_convar_is_on_and_is_console_only():
    out = run_wiring(debug=True)
    assert out["NATIVE"] == "orgsell:true", (
        f"后台入口必须是 restricted 原生命令（仅控制台）：{out}"
    )
    assert out["QBCORE_COUNT"] == "7", "后台入口不该污染 QBCore 命令表"
    assert out["EVENTS"] == "1" and out["THREADS"] == "1"

    commands = COMMANDS_SALES_SRC.read_text(encoding="utf-8")
    assert "source ~= 0" in commands, "orgsell 没有拒绝非控制台调用"
    assert "SettleSale" in commands, "orgsell 没有走 SettleSale（出现了第二条销售路径）"
