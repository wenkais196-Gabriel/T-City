"""S5 产业 UI：服务端只读快照 + 玩家侧入口 + 手机 App 可见性。

这里钉住八件事（真跑 Lua + 离线假 DB，MySQL 之外不 mock）：

1. **Snapshot 逐字段来自 SQL/配置**：余额、设施、库存、配额、售价、`orgRemaining`
   与 `maxQty` 的算式（`min(stock, orgRemaining, globalRemaining)`）全部由服务端算好；
2. **未建厂**：`built=false`（facility/demand/sellable 省略），不抛错；
3. **EstimateSale 与 SettleSale 同金额**：同一组输入、同一套 core_economy 系数，
   且 Estimate 前后不写库、不占配额；
4. **鉴权**：非成员 `not_member`、成员非 Boss 的写操作 `not_boss`，均不写库；
5. **不可信 qty**：超过 maxQty 夹紧；负数/小数/非数字 `bad_qty` 且零写入；
6. **不可信价格字段**：price/revenue/multiplier 被忽略并记录，结果与不传完全一致；
7. **手机可见性**：`PhoneApps.ForPlayer` 只给 org 成员 industry 瓦片（job 与 gang 都覆盖）；
8. **接线**：manifest 全加载后 5 个 callback + 4 个 export 都在，且不新增事件/线程。

反向注入：把 Snapshot 的 `orgRemaining = info.org.remaining` 改成
`info.demand.remaining`，第 1 条必须变红。
"""

from __future__ import annotations

import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

from lua_probe import BASE, DB_ADAPTER

RES = BASE / "resources" / "[custom]" / "custom-industry"
PHONE = BASE / "resources" / "[custom]" / "custom-phone"
SALE_SRC = RES / "server" / "sale.lua"
FACILITY_SRC = RES / "server" / "facility.lua"
TREASURY_SRC = RES / "server" / "treasury.lua"
AUDIT_SRC = RES / "server" / "audit.lua"
ACCESS_SRC = RES / "server" / "access.lua"
ORG_ID_SRC = RES / "server" / "org_id.lua"
UI_SRC = RES / "server" / "ui.lua"
CONFIG_SRC = RES / "config.lua"
FACILITY_CONFIG_SRC = RES / "config" / "facility.lua"
PRODUCTION_CONFIG_SRC = RES / "config" / "production.lua"
SALES_CONFIG_SRC = RES / "config" / "sales.lua"
MANIFEST = RES / "fxmanifest.lua"

PHONE_REGISTRY = PHONE / "server" / "phone_apps.lua"
PHONE_APP = PHONE / "server" / "apps" / "industry.lua"
PHONE_MANIFEST = PHONE / "fxmanifest.lua"

FIXTURES = Path(__file__).resolve().parent / "fixtures"
SALES_PROBE = FIXTURES / "industry_sales_probe.lua"
UI_PROBE = FIXTURES / "industry_ui_probe.lua"


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


PLAYERS = """
local function boss()
    return { PlayerData = {
        citizenid = 'cid-boss',
        job = { name = 'miner', label = '洛圣都矿业公司',
                grade = { level = 4, name = 'Mine Owner' } },
    } }
end
local function member()
    return { PlayerData = {
        citizenid = 'cid-member',
        job = { name = 'miner', label = '洛圣都矿业公司',
                grade = { level = 1, name = '矿工' } },
    } }
end
local function outsider()
    return { PlayerData = {
        citizenid = 'cid-out',
        job = { name = 'police', label = '警察',
                grade = { level = 4, name = 'Chief' } },
    } }
end
local function gangBoss()
    return { PlayerData = {
        citizenid = 'cid-gang',
        gang = { name = 'cartel', label = '卡特尔',
                 grade = { level = 4, name = 'Boss' } },
    } }
end
"""


def run(body: str, convars: dict[str, str] | None = None) -> dict[str, str]:
    """S4 假 DB → S5 扩展 → db.lua → convar → 真实配置/模块 → body。"""
    prelude = f"__convars = {lua_table(convars)}\n" if convars else "__convars = { industry_enable = 'true' }\n"
    script = (
        SALES_PROBE.read_text(encoding="utf-8")
        + "\n"
        + UI_PROBE.read_text(encoding="utf-8")
        + "\n"
        + DB_ADAPTER.read_text(encoding="utf-8")
        + "\n"
        + prelude
        + config_text()
        + "\n"
        + ORG_ID_SRC.read_text(encoding="utf-8")
        + "\n"
        + TREASURY_SRC.read_text(encoding="utf-8")
        + "\n"
        + AUDIT_SRC.read_text(encoding="utf-8")
        + "\n"
        + ACCESS_SRC.read_text(encoding="utf-8")
        + "\n"
        + FACILITY_SRC.read_text(encoding="utf-8")
        + "\n"
        + SALE_SRC.read_text(encoding="utf-8")
        + "\n"
        + UI_SRC.read_text(encoding="utf-8")
        + "\n"
        + PLAYERS
        + "\n"
        + textwrap.dedent(body)
    )
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}\n{proc.stdout}"
    return parse(proc.stdout)


# ══════════════════════════════════════════════════════════════════
# 1. Snapshot：逐字段与假 DB 一致
# ══════════════════════════════════════════════════════════════════


def test_snapshot_fields_match_seeded_sql():
    """余额 47675 / 库存 45 / 配额 10-5、本组织 5-5 → orgRemaining 0、maxQty 0。"""
    out = run("""
        __reset()
        __seedOrg('mining_co', 47675)
        __seedFacilityRow('mining_co', 45, { workstations = 3, level = 1, produced_units = 777 })
        __seedDemand('iron_ore', 10, 5)
        __seedSale('mining_co', 'iron_ore', 5)

        local snap, err = IndustryUi.Snapshot(boss(), 'mining_co')
        __emit('OK', tostring(snap ~= nil))
        __emit('ERR', tostring(err or 'nil'))
        __emit('ORGID', tostring(snap and snap.orgId))
        __emit('ORG', tostring(snap and snap.orgLabel))
        __emit('GRADE', tostring(snap and snap.gradeName))
        __emit('ISBOSS', tostring(snap and snap.isBoss))
        __emit('BAL', tostring(snap and snap.balance))
        __emit('TYPE', tostring(snap and snap.facility and snap.facility.type))
        __emit('LABEL', tostring(snap and snap.facility and snap.facility.label))
        __emit('LEVEL', tostring(snap and snap.facility and snap.facility.level))
        __emit('MAXLEVEL', tostring(snap and snap.facility and snap.facility.maxLevel))
        __emit('WS', tostring(snap and snap.facility and snap.facility.workstations))
        __emit('WSCAP', tostring(snap and snap.facility and snap.facility.workstationCap))
        __emit('STOCK', tostring(snap and snap.facility and snap.facility.stock))
        __emit('STOCKCAP', tostring(snap and snap.facility and snap.facility.stockCap))
        __emit('NEXTCOST', tostring(snap and snap.facility and snap.facility.nextWorkstationCost))
        __emit('HIREBLOCK', tostring(snap and snap.facility and snap.facility.hireBlocked))
        __emit('ITEM', tostring(snap and snap.demand and snap.demand.item))
        __emit('UNIT', tostring(snap and snap.demand and snap.demand.unitPrice))
        __emit('GTOTAL', tostring(snap and snap.demand and snap.demand.globalTotal))
        __emit('GUSED', tostring(snap and snap.demand and snap.demand.globalUsed))
        __emit('GREM', tostring(snap and snap.demand and snap.demand.globalRemaining))
        __emit('ORGCAP', tostring(snap and snap.demand and snap.demand.orgCap))
        __emit('ORGUSED', tostring(snap and snap.demand and snap.demand.orgUsed))
        __emit('ORGREM', tostring(snap and snap.demand and snap.demand.orgRemaining))
        __emit('MAXQTY', tostring(snap and snap.sellable and snap.sellable.maxQty))
        __emit('SELLBLOCK', tostring(snap and snap.sellable and snap.sellable.blocked))
        __emit('PRODUCED', tostring(snap and snap.producedUnits))
    """)

    assert out["OK"] == "true" and out["ERR"] == "nil", f"Snapshot 失败：{out}"
    assert out["ORGID"] == "mining_co"
    assert out["ORG"] == "洛圣都矿业公司"
    assert out["GRADE"] == "Mine Owner"
    assert out["ISBOSS"] == "true"
    assert out["BAL"] == "47675"
    assert out["TYPE"] == "mine" and out["LABEL"] == "矿业设施"
    assert out["LEVEL"] == "1" and out["MAXLEVEL"] == "5"
    assert out["WS"] == "3" and out["WSCAP"] == "10"
    assert out["STOCK"] == "45" and out["STOCKCAP"] == "144"
    # floor(50000 × 1.35^3) = 123018
    assert out["NEXTCOST"] == "123018", "工位成本曲线变了"
    assert out["HIREBLOCK"] == "funds", "余额 47675 < 123018 时应置灰 + funds"
    assert out["ITEM"] == "iron_ore" and out["UNIT"] == "50"
    assert out["GTOTAL"] == "10" and out["GUSED"] == "5" and out["GREM"] == "5"
    assert out["ORGCAP"] == "5" and out["ORGUSED"] == "5" and out["ORGREM"] == "0"
    assert out["MAXQTY"] == "0", "maxQty 必须是 min(stock, orgRemaining, globalRemaining)"
    assert out["SELLBLOCK"] == "org_cap", "本组织配额用完时原因必须是 org_cap（不是 demand）"
    assert out["PRODUCED"] == "777"


# ══════════════════════════════════════════════════════════════════
# 2. 未建厂
# ══════════════════════════════════════════════════════════════════


def test_unbuilt_facility_returns_snapshot_without_subsections():
    out = run("""
        __reset()
        __seedOrg('mining_co', 500)

        local snap, err = IndustryUi.Snapshot(boss(), 'mining_co')
        __emit('OK', tostring(snap ~= nil))
        __emit('ERR', tostring(err or 'nil'))
        __emit('FACILITY', tostring(snap and snap.facility))
        __emit('DEMAND', tostring(snap and snap.demand))
        __emit('SELLABLE', tostring(snap and snap.sellable))
        __emit('PRODUCED', tostring(snap and snap.producedUnits))
        __emit('BAL', tostring(snap and snap.balance))
        __emit('ISBOSS', tostring(snap and snap.isBoss))
    """)
    assert out["OK"] == "true" and out["ERR"] == "nil", f"未建厂不应报错：{out}"
    assert out["FACILITY"] == "nil" and out["DEMAND"] == "nil" and out["SELLABLE"] == "nil"
    assert out["PRODUCED"] == "0" and out["BAL"] == "500" and out["ISBOSS"] == "true"


# ══════════════════════════════════════════════════════════════════
# 3. EstimateSale 与 SettleSale 金额一致，且 Estimate 只读
# ══════════════════════════════════════════════════════════════════


def test_estimate_sale_matches_settle_sale_revenue_and_writes_nothing():
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacilityRow('mining_co', 100, { workstations = 3 })
        __seedDemand('iron_ore', 20, 0)
        __globalMultiplier = 1.25
        __activityHeat = 1.2

        local estimate, err = IndustryUi.EstimateSale(boss(), 'mining_co', 10)
        __emit('EST_OK', tostring(estimate and estimate.ok))
        __emit('EST_ERR', tostring(err or 'nil'))
        __emit('EST_QTY', tostring(estimate and estimate.qty))
        __emit('EST_UNIT', tostring(estimate and estimate.unitPrice))
        __emit('EST_REV', tostring(estimate and estimate.revenue))
        __emit('EST_BLOCK', tostring(estimate and estimate.blocked))
        __emit('PRE_SALES', tostring(__salesCount()))
        __emit('PRE_STOCK', tostring(__stock('mining_co')))
        __emit('PRE_QUOTA', tostring(__demandRow('iron_ore').quota_used))
        __emit('PRE_BAL', tostring(__balance('mining_co')))

        local ok, settleErr, result = IndustrySales.SettleSale(
            'mining_co', 'iron_ore', 10, 'compare-ref')
        __emit('SETTLE_OK', tostring(ok))
        __emit('SETTLE_ERR', tostring(settleErr or 'nil'))
        __emit('SETTLE_REV', tostring(result and result.revenue))
    """)
    # floor(10 × 50 × 1.25 × 1.2) = 750
    assert out["EST_OK"] == "true" and out["EST_ERR"] == "nil", f"{out}"
    assert out["EST_QTY"] == "10" and out["EST_UNIT"] == "50" and out["EST_REV"] == "750"
    assert out["EST_BLOCK"] == "nil"
    assert out["PRE_SALES"] == "0" and out["PRE_STOCK"] == "100"
    assert out["PRE_QUOTA"] == "0" and out["PRE_BAL"] == "0", "EstimateSale 不能写库/占配额"
    assert out["SETTLE_OK"] == "true" and out["SETTLE_REV"] == "750", (
        "EstimateSale 与 SettleSale 不是同一套系数/取整")

    source = SALE_SRC.read_text(encoding="utf-8")
    assert "function IndustrySales.QuoteRevenue" in source
    assert "function IndustrySales.Inspect" in source
    assert "economyCoefficients" in source, "报价必须复用 S4 的 core_economy 系数"


# ══════════════════════════════════════════════════════════════════
# 4. 鉴权：非成员 / 非 Boss
# ══════════════════════════════════════════════════════════════════


def test_non_member_and_non_boss_are_rejected_without_writes():
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacilityRow('mining_co', 10, { workstations = 1 })
        __seedDemand('iron_ore', 20, 0)

        local snap, snapErr = IndustryUi.Snapshot(outsider(), 'mining_co')
        __emit('OUT_SNAP', tostring(snap))
        __emit('OUT_SNAP_ERR', tostring(snapErr or 'nil'))

        local ok1, err1 = IndustryUi.Sell(outsider(), 'mining_co', 1)
        local ok2, err2 = IndustryUi.Sell(member(), 'mining_co', 1)
        local ok3, err3 = IndustryUi.HireWorkstation(member(), 'mining_co')

        local memberSnap = IndustryUi.Snapshot(member(), 'mining_co')
        __emit('SELL_OUT', tostring(ok1) .. ':' .. tostring(err1))
        __emit('SELL_MEMBER', tostring(ok2) .. ':' .. tostring(err2))
        __emit('HIRE_MEMBER', tostring(ok3) .. ':' .. tostring(err3))
        __emit('MEMBER_ISBOSS', tostring(memberSnap and memberSnap.isBoss))
        __emit('SALES', tostring(__salesCount()))
        __emit('STOCK', tostring(__stock('mining_co')))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('WS', tostring(__facilityRows['mining_co'].workstations))
    """)
    assert out["OUT_SNAP"] == "nil" and out["OUT_SNAP_ERR"] == "not_member"
    assert out["SELL_OUT"] == "false:not_member"
    assert out["SELL_MEMBER"] == "false:not_boss"
    assert out["HIRE_MEMBER"] == "false:not_boss"
    assert out["MEMBER_ISBOSS"] == "false", "普通成员的快照必须带 isBoss=false"
    assert out["SALES"] == "0" and out["STOCK"] == "10"
    assert out["BAL"] == "0" and out["WS"] == "1", "被拒绝的请求写库了"


# ══════════════════════════════════════════════════════════════════
# 5. 不可信 qty
# ══════════════════════════════════════════════════════════════════


def test_forged_qty_is_clamped_or_rejected_without_extra_writes():
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacilityRow('mining_co', 10, { workstations = 3 })
        __seedDemand('iron_ore', 20, 0)

        local estimate = IndustryUi.EstimateSale(boss(), 'mining_co', 999)
        __emit('EST_QTY', tostring(estimate and estimate.qty))
        __emit('EST_REV', tostring(estimate and estimate.revenue))
        __emit('EST_BLOCK', tostring(estimate and estimate.blocked))

        local ok, err, result = IndustryUi.Sell(boss(), 'mining_co', 999)
        __emit('OVER_OK', tostring(ok))
        __emit('OVER_ERR', tostring(err or 'nil'))
        __emit('OVER_QTY', tostring(result and result.qty))
        __emit('OVER_REQUESTED', tostring(result and result.requested_qty))
        __emit('OVER_STOCK', tostring(__stock('mining_co')))
        __emit('OVER_BAL', tostring(__balance('mining_co')))

        __reset()
        __seedOrg('mining_co', 0)
        __seedFacilityRow('mining_co', 10, { workstations = 3 })
        __seedDemand('iron_ore', 20, 0)

        local okNeg, errNeg = IndustryUi.Sell(boss(), 'mining_co', -5)
        local okText, errText = IndustryUi.Sell(boss(), 'mining_co', 'abc')
        local okFloat, errFloat = IndustryUi.Sell(boss(), 'mining_co', 1.5)
        __emit('NEG', tostring(okNeg) .. ':' .. tostring(errNeg))
        __emit('TEXT', tostring(okText) .. ':' .. tostring(errText))
        __emit('FLOAT', tostring(okFloat) .. ':' .. tostring(errFloat))
        __emit('BAD_SALES', tostring(__salesCount()))
        __emit('BAD_STOCK', tostring(__stock('mining_co')))
        __emit('BAD_BAL', tostring(__balance('mining_co')))
        __emit('BAD_QUOTA', tostring(__demandRow('iron_ore').quota_used))
    """)
    assert out["EST_QTY"] == "10", "EstimateSale 没有按 maxQty 夹紧"
    assert out["EST_REV"] == "500"
    assert out["EST_BLOCK"] == "stock"
    assert out["OVER_OK"] == "true" and out["OVER_ERR"] == "nil"
    assert out["OVER_QTY"] == "10" and out["OVER_REQUESTED"] == "999"
    assert out["OVER_STOCK"] == "0" and out["OVER_BAL"] == "500"

    assert out["NEG"] == "false:bad_qty"
    assert out["TEXT"] == "false:bad_qty"
    assert out["FLOAT"] == "false:bad_qty"
    assert out["BAD_SALES"] == "0", "非法 qty 产生了卖单"
    assert out["BAD_STOCK"] == "10" and out["BAD_BAL"] == "0"
    assert out["BAD_QUOTA"] == "0"


# ══════════════════════════════════════════════════════════════════
# 6. 前端上送价格/倍率/收益 → 忽略
# ══════════════════════════════════════════════════════════════════


def test_client_supplied_price_fields_are_ignored():
    out = run("""
        __reset()
        __seedOrg('mining_co', 0)
        __seedFacilityRow('mining_co', 10, { workstations = 3 })
        __seedDemand('iron_ore', 20, 0)
        __globalMultiplier = 1.0
        __activityHeat = 1.0

        local ok1, err1, forged = IndustryUi.Sell(boss(), 'mining_co', 2, {
            price = 1, unit_price = 1, revenue = 999999,
            multiplier = 999, quota_used = 0,
        })
        __emit('FORGED_OK', tostring(ok1))
        __emit('FORGED_ERR', tostring(err1 or 'nil'))
        __emit('FORGED_REV', tostring(forged and forged.revenue))
        __emit('FORGED_UNIT', tostring(forged and forged.unit_price))
        __emit('FORGED_BAL', tostring(__balance('mining_co')))
        __emit('FORGED_QUOTA', tostring(__demandRow('iron_ore').quota_used))

        __reset()
        __seedOrg('mining_co', 0)
        __seedFacilityRow('mining_co', 10, { workstations = 3 })
        __seedDemand('iron_ore', 20, 0)
        __globalMultiplier = 1.0
        __activityHeat = 1.0

        local ok2, err2, plain = IndustryUi.Sell(boss(), 'mining_co', 2)
        __emit('PLAIN_OK', tostring(ok2))
        __emit('PLAIN_ERR', tostring(err2 or 'nil'))
        __emit('PLAIN_REV', tostring(plain and plain.revenue))
        __emit('PLAIN_UNIT', tostring(plain and plain.unit_price))
        __emit('PLAIN_BAL', tostring(__balance('mining_co')))
        __emit('PLAIN_QUOTA', tostring(__demandRow('iron_ore').quota_used))
    """)
    assert out["FORGED_OK"] == "true" and out["FORGED_ERR"] == "nil"
    assert out["PLAIN_OK"] == "true" and out["PLAIN_ERR"] == "nil"
    assert out["FORGED_REV"] == "100" and out["PLAIN_REV"] == "100"
    assert out["FORGED_UNIT"] == "50" and out["PLAIN_UNIT"] == "50"
    assert out["FORGED_BAL"] == out["PLAIN_BAL"] == "100"
    assert out["FORGED_QUOTA"] == out["PLAIN_QUOTA"] == "2"


# ══════════════════════════════════════════════════════════════════
# 7. 手机 App 可见性（job + gang）
# ══════════════════════════════════════════════════════════════════


def run_phone(body: str) -> dict[str, str]:
    """加载 custom-phone 注册表 + industry app，QBCore/exports 用最小桩。"""
    stub = """
_G.QBCore = {
  Functions = {
    GetPlayer = function(source)
      if source == 1 then
        return { PlayerData = { job = { name = 'miner', grade = { level = 4 } } } }
      end
      if source == 2 then
        return { PlayerData = { job = { name = 'police', grade = { level = 4 } } } }
      end
      if source == 3 then
        return { PlayerData = { gang = { name = 'cartel', grade = { level = 4 } } } }
      end
      return nil
    end,
  },
}
__calls = {}
_G.exports = {
  ['custom-industry'] = {
    CanAccessIndustry = function(_, source) return source == 1 or source == 3 end,
    GetIndustrySnapshot = function(_, source, orgId)
      return {
        orgLabel = '洛圣都矿业公司', gradeName = 'Mine Owner', isBoss = true, balance = 100,
        producedUnits = 7,
        facility = { label = '矿业设施', level = 1, workstations = 2, workstationCap = 10,
                     stock = 3, stockCap = 144 },
        demand = { unitPrice = 50, globalTotal = 10, globalUsed = 5, globalRemaining = 5,
                   orgCap = 5, orgUsed = 0, orgRemaining = 5 },
        sellable = { maxQty = 3, blocked = nil },
      }
    end,
    EstimateIndustrySale = function(_, source, orgId, qty)
      __calls[#__calls + 1] = 'estimate'
      return { ok = true, qty = tonumber(qty) or 1, unitPrice = 50, revenue = 50,
               blocked = nil, maxQty = 3 }
    end,
    SellIndustryStock = function(_, source, orgId, qty, params)
      __calls[#__calls + 1] = 'sell'
      return true, nil, { qty = tonumber(qty) or 1, revenue = 50, unit_price = 50 }
    end,
  },
}
function Money(value) return tostring(value) end
function GetResourceState(name) return name == 'custom-industry' and 'started' or 'missing' end
function __emit(key, value)
  io.write(tostring(key) .. '|' .. tostring(value) .. string.char(10))
end
"""
    # phone_apps.lua 以 `return PhoneApps` 结尾；拼进同一个 chunk 会让后面的
    # adapter 不可达。harness 里把它当独立文件：按 chunk 分隔，等价于 FiveM 的加载。
    registry = PHONE_REGISTRY.read_text(encoding="utf-8").rsplit("return PhoneApps", 1)[0]
    script = (
        stub
        + "\n"
        + registry
        + "\n"
        + PHONE_APP.read_text(encoding="utf-8")
        + "\n"
        + textwrap.dedent(body)
    )
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}\n{proc.stdout}"
    return parse(proc.stdout)


def run_phone_with_real_access(body: str) -> dict[str, str]:
    """同一 Lua state 里加载真实 config + IndustryAccess + IndustryUi，再装手机注册表。

    与 run_phone 的区别：`CanAccessIndustry` 不是桩，而是 ui.lua 注册的真实函数，
    因此这条用例覆盖「手机可见性 → IndustryAccess.OrgMembership → Config.OrgWhitelist」
    整条链，而不是只验证注册表调用了某个回调。
    """
    stub = """
GetConvar = function(name, default)
  if name == 'industry_enable' then return 'true' end
  return default
end
__industryExports = {}
local coreObject = {
  Functions = {
    GetPlayer = function(source)
      if source == 1 then
        return { PlayerData = { job = { name = 'miner', label = '洛圣都矿业公司',
                 grade = { level = 4, name = 'Mine Owner' } } } }
      end
      if source == 2 then
        return { PlayerData = { job = { name = 'police', grade = { level = 4 } } } }
      end
      if source == 3 then
        return { PlayerData = { gang = { name = 'cartel', grade = { level = 4 } } } }
      end
      return nil
    end,
  },
}
_G.QBCore = coreObject
exports = setmetatable({}, {
  __index = function(_, resource)
    if resource == 'qb-core' then return { GetCoreObject = function() return coreObject end } end
    if resource == 'custom-industry' then return __industryExports end
    return nil
  end,
  __call = function(_, name, fn) __industryExports[name] = fn end,
})
function Money(value) return tostring(value) end
function GetResourceState(name) return 'started' end
function __emit(key, value)
  io.write(tostring(key) .. '|' .. tostring(value) .. string.char(10))
end
"""
    registry = PHONE_REGISTRY.read_text(encoding="utf-8").rsplit("return PhoneApps", 1)[0]
    script = (
        stub
        + "\n"
        + CONFIG_SRC.read_text(encoding="utf-8")
        + "\n"
        + ORG_ID_SRC.read_text(encoding="utf-8")
        + "\n"
        + ACCESS_SRC.read_text(encoding="utf-8")
        + "\n"
        + UI_SRC.read_text(encoding="utf-8")
        # 模拟 FiveM 导出调用把 self 吃掉：adapter 用 `exports['x']:Fn(src)`。
        + "\n"
        + "local realCanAccess = __industryExports.CanAccessIndustry\n"
        + "__industryExports.CanAccessIndustry = function(_, source) return realCanAccess(source) end\n"
        + registry
        + "\n"
        + PHONE_APP.read_text(encoding="utf-8")
        + "\n"
        + textwrap.dedent(body)
    )
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}\n{proc.stdout}"
    return parse(proc.stdout)


def test_phone_app_is_visible_only_to_org_members():
    out = run_phone_with_real_access("""
        local function has(apps, id)
            for _, app in ipairs(apps) do
                if app.id == id then return true end
            end
            return false
        end
        __emit('MINER', tostring(has(PhoneApps.ForPlayer(1), 'industry')))
        __emit('POLICE', tostring(has(PhoneApps.ForPlayer(2), 'industry')))
        __emit('CARTEL', tostring(has(PhoneApps.ForPlayer(3), 'industry')))

        local ok, err = PhoneApps.Query(2, 'industry', 'snapshot', {})
        __emit('NON_MEMBER_QUERY', tostring(ok) .. ':' .. tostring(err))
    """)
    assert out["MINER"] == "true", "miner（job 型组织）成员看不到 industry 瓦片"
    assert out["POLICE"] == "false", "非组织成员拿到了 industry 瓦片"
    assert out["CARTEL"] == "true", "cartel（gang 型组织）成员看不到 industry 瓦片"
    assert out["NON_MEMBER_QUERY"] == "false:app_forbidden"


# ══════════════════════════════════════════════════════════════════
# 8. 手机适配层：快照投影 + 先 estimate 再 sell
# ══════════════════════════════════════════════════════════════════


def test_phone_snapshot_projection_and_sell_calls_estimate_first():
    out = run_phone("""
        local ok, data = PhoneApps.Query(1, 'industry', 'snapshot', {})
        __emit('SNAP_OK', tostring(ok))
        __emit('ROW_STOCK', tostring(data and data.rows and data.rows[1] and data.rows[1]['库存']))
        __emit('ROW_QUOTA', tostring(data and data.rows and data.rows[1] and data.rows[1]['配额']))
        __emit('RAW_BAL', tostring(data and data.snapshot and data.snapshot.balance))

        local okSell, result = PhoneApps.Action(1, 'industry', 'sell', { qty = 2 })
        __emit('SELL_OK', tostring(okSell))
        __emit('SELL_QTY', tostring(result and result.qty))
        __emit('CALLS', table.concat(__calls, ','))
    """)
    assert out["SNAP_OK"] == "true", f"{out}"
    assert out["ROW_STOCK"] == "3 / 144"
    assert out["ROW_QUOTA"] == "全服剩 5 / 10 · 本组织剩 5 / 5"
    assert out["RAW_BAL"] == "100", "手机查询必须把原始快照一起给专用皮肤"
    assert out["SELL_OK"] == "true" and out["SELL_QTY"] == "2"
    assert out["CALLS"] == "estimate,sell", "卖单必须先 EstimateSale 再 SellIndustryStock"


# ══════════════════════════════════════════════════════════════════
# 9. job / gang 两种组织走向同一套判定
# ══════════════════════════════════════════════════════════════════


def test_gang_org_uses_same_snapshot_and_access_rules():
    out = run("""
        __reset()
        __seedOrg('cartel', 250)
        __seedFacilityRow('cartel', 5, { workstations = 1, produced_units = 9 })
        __seedDemand('iron_ore', 20, 0)

        local snap, err = IndustryUi.Snapshot(gangBoss(), 'cartel')
        __emit('OK', tostring(snap ~= nil))
        __emit('ERR', tostring(err or 'nil'))
        __emit('ORG', tostring(snap and snap.orgLabel))
        __emit('GRADE', tostring(snap and snap.gradeName))
        __emit('ISBOSS', tostring(snap and snap.isBoss))
        __emit('BAL', tostring(snap and snap.balance))
        __emit('MAXQTY', tostring(snap and snap.sellable and snap.sellable.maxQty))
        __emit('PRODUCED', tostring(snap and snap.producedUnits))

        -- 用 job 型组织的 orgId 调 gang 玩家 → not_member（orgId 不可信）
        local cross, crossErr = IndustryUi.Snapshot(gangBoss(), 'mining_co')
        __emit('CROSS', tostring(cross) .. ':' .. tostring(crossErr))
    """)
    assert out["OK"] == "true" and out["ERR"] == "nil", f"{out}"
    assert out["ORG"] == "卡特尔" and out["GRADE"] == "Boss" and out["ISBOSS"] == "true"
    assert out["BAL"] == "250" and out["MAXQTY"] == "5" and out["PRODUCED"] == "9"
    assert out["CROSS"] == "nil:not_member"


# ══════════════════════════════════════════════════════════════════
# 10. industry_enable=false：整套 UI 入口都返回 disabled
# ══════════════════════════════════════════════════════════════════


def test_disabled_industry_returns_disabled_and_never_writes():
    out = run("""
        __reset()
        __seedOrg('mining_co', 1000)
        __seedFacilityRow('mining_co', 10, { workstations = 1 })
        __seedDemand('iron_ore', 20, 0)

        local snap, snapErr = IndustryUi.Snapshot(boss(), 'mining_co')
        local estimate, estimateErr = IndustryUi.EstimateSale(boss(), 'mining_co', 1)
        local okSell, sellErr = IndustryUi.Sell(boss(), 'mining_co', 1)
        local okHire, hireErr = IndustryUi.HireWorkstation(boss(), 'mining_co')
        __emit('SNAP', tostring(snap) .. ':' .. tostring(snapErr))
        __emit('ESTIMATE', tostring(estimate) .. ':' .. tostring(estimateErr))
        __emit('SELL', tostring(okSell) .. ':' .. tostring(sellErr))
        __emit('HIRE', tostring(okHire) .. ':' .. tostring(hireErr))
        __emit('CAN_ACCESS', tostring(IndustryUi.CanAccess(boss())))
        __emit('SALES', tostring(__salesCount()))
        __emit('STOCK', tostring(__stock('mining_co')))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('WS', tostring(__facilityRows['mining_co'].workstations))
    """, convars={"industry_enable": "false"})
    assert out["SNAP"] == "nil:disabled"
    assert out["ESTIMATE"] == "nil:disabled"
    assert out["SELL"] == "false:disabled"
    assert out["HIRE"] == "false:disabled"
    assert out["CAN_ACCESS"] == "false"
    assert out["SALES"] == "0" and out["STOCK"] == "10"
    assert out["BAL"] == "1000" and out["WS"] == "1", "关闭状态下写库了"


# ══════════════════════════════════════════════════════════════════
# 11. 接线：manifest 全加载后 callback / export 都存在
# ══════════════════════════════════════════════════════════════════


def test_ui_wiring_registers_callbacks_and_exports():
    import test_industry_sales as sales_tests

    out = sales_tests.run_wiring(False)
    callbacks = set(filter(None, out["CALLBACKS"].split(",")))
    exports = set(filter(None, out["EXPORTS"].split(",")))
    assert callbacks == {
        "industry:server:uiState",
        "industry:server:snapshot",
        "industry:server:estimate",
        "industry:server:sell",
        "industry:server:hire",
    }, f"callback 注册面变了：{sorted(callbacks)}"
    assert exports == {
        "CanAccessIndustry",
        "GetIndustrySnapshot",
        "EstimateIndustrySale",
        "SellIndustryStock",
    }, f"export 注册面变了：{sorted(exports)}"
    # S5 只加 callback/export，不新增服务端事件或线程。
    assert out["QBCORE_COUNT"] == "7"
    assert out["EVENTS"] == "1" and out["THREADS"] == "1"
    assert out["HAS_GLOBAL"] == "false"

    manifest = MANIFEST.read_text(encoding="utf-8")
    assert "server/ui.lua" in manifest, "ui.lua 没进 server_scripts"
    assert "client/main.lua" in manifest, "client/main.lua 没进清单"
    assert "server_only" not in manifest, "client_scripts 与 server_only 'yes' 冲突"

    phone_manifest = PHONE_MANIFEST.read_text(encoding="utf-8")
    assert "server/apps/industry.lua" in phone_manifest
    assert phone_manifest.index("server/apps/industry.lua") < phone_manifest.index("server/main.lua")
