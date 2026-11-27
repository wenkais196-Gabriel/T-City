"""S3 离线生产：惰性结算 + 库存上限（纯函数 + 离线假 DB 探针）。

这里钉八件事：

1. **dt = 0** → 产量 0，`last_tick_at` 不动（幂等的边界）。
2. **停机追赶上限**：`dt` 再大，一次结算也只按 `max_catchup` 算，不按真实停机时长。
3. **库存上限**：`cap = 0` / 库存已满 → 产量 0；生产模块里没有任何通知/回执代码。
4. **取整规则**：`produced = floor(workstations × unitsPerHour × 倍率 × dt / 3600)`；
   不足 1 单位的时间留在 `last_tick_at` 里继续累计（1 秒 tick 也不会永远产不出）。
5. **同一时刻重复结算** → 第二次产量 0（第一次已经推进了 `last_tick_at`）。
6. **客户端不参与**：多传 `dt` / `produced` / `reported` 等字段，结果逐字段不变；
   生产路径没有 net event。
7. **接线**：加载 fxmanifest 的全部 server 脚本（不提供全局 QBCore），
   PlayerLoaded 处理器与生产心跳都挂上了；后台入口默认不注册，开 convar 后才注册。
8. **写库 CAS**：`SettleFacility` 用 `last_tick_at` + `stock` 双条件 CAS；
   读到旧值后被别人结算时重读重算，不双算；`produced_units` 只增不减。

反向注入（交付报告里贴红/绿）：把 `Compute` 里的
`produced = min(expected, cap - stock)` 改成直接 `expected`，
`test_full_stock_or_zero_cap_produces_nothing` 必须红。
"""

from __future__ import annotations

from industry_harness import (
    COMMANDS_PRODUCTION_SRC,
    PRODUCTION_SRC,
    run_production as run,
    run_production_db as run_db,
    run_wiring as _run_wiring,
)


def run_wiring(debug: bool) -> dict[str, str]:
    """生产后台入口的 convar 是 industry_production_debug（S4 卖单的另一个开关不动）。"""
    return _run_wiring(debug, debug_convar="industry_production_debug")


# ══════════════════════════════════════════════════════════════════
# 0. 配置默认值（验收旋钮）
# ══════════════════════════════════════════════════════════════════


def test_production_config_defaults_and_mine_stock_cap():
    out = run("""
        local production = Config.Industry.Production
        __emit('UNITS', tostring(production.UnitsPerHour))
        __emit('MULT', tostring(production.Multiplier))
        __emit('TICK', tostring(production.TickSeconds))
        __emit('CATCHUP', tostring(production.MaxCatchupSeconds))
        __emit('DEBUG', tostring(production.DebugCommand))
        __emit('STOCK_CAP', tostring(Config.Industry.Facilities.mine.stockCap))
    """)
    assert out["UNITS"] == "4.5", "#387 数值卡：单工位速率默认值应为 4.5 单位/小时"
    assert out["MULT"] == "1"
    assert out["TICK"] == "30", "默认 30 秒心跳，不跑每秒循环"
    assert out["CATCHUP"] == "3600", "默认单次最多追赶 1 小时"
    assert out["DEBUG"] == "false", "后台入口默认必须关闭"
    assert out["STOCK_CAP"] == "540", "#387 数值卡：mine 库存上限 = 10 × 4.5 × 12h = 540"


# ══════════════════════════════════════════════════════════════════
# 1. 纯函数边界：dt = 0
# ══════════════════════════════════════════════════════════════════


def test_dt_zero_produces_nothing_and_does_not_move_last_tick():
    out = run("""
        local plan = IndustryProduction.Compute({
            now = 1000, lastTickAt = 1000, workstations = 10, stock = 0,
            cap = 144, unitsPerHour = 12, multiplier = 1, maxCatchup = 3600,
        })
        __emit('PRODUCED', tostring(plan.produced))
        __emit('NEW_LAST', tostring(plan.newLastTickAt))
        __emit('DT', tostring(plan.dt))
        __emit('ADVANCED', tostring(plan.advancedSeconds))
        __emit('BLOCKED', tostring(plan.blocked))
    """)
    assert out["PRODUCED"] == "0", "dt=0 时不能凭空产出"
    assert out["NEW_LAST"] == "1000", "dt=0 时 last_tick_at 必须原样不动"
    assert out["DT"] == "0"
    assert out["ADVANCED"] == "0"
    assert out["BLOCKED"] == "no_time"


# ══════════════════════════════════════════════════════════════════
# 2. 停机追赶上限
# ══════════════════════════════════════════════════════════════════


def test_huge_downtime_is_capped_at_max_catchup():
    """停机 100000 秒，单次结算只按 600 秒算 —— 不是按真实 dt。

    `max_catchup` 是「一次结算最多前进多少秒」，不是「离线总产量上限」；
    离线通胀闸是库存上限（cap）。这条只钉单次结算的截断。
    """
    out = run("""
        local plan = IndustryProduction.Compute({
            now = 100000, lastTickAt = 0, workstations = 10, stock = 0,
            cap = 1000000, unitsPerHour = 12, multiplier = 1, maxCatchup = 600,
        })
        __emit('PRODUCED', tostring(plan.produced))
        __emit('EXPECTED', tostring(plan.expected))
        __emit('DT', tostring(plan.dt))
        __emit('EFFECTIVE', tostring(plan.effectiveDt))
        __emit('NEW_LAST', tostring(plan.newLastTickAt))
        __emit('ADVANCED', tostring(plan.advancedSeconds))
        __emit('UNCAPPED', tostring(math.floor(10 * 12 * 100000 / 3600)))
    """)
    assert out["DT"] == "100000", "真实 dt 应当被记录（便于排查），但不能全额结算"
    assert out["EFFECTIVE"] == "600", f"单次结算必须截断到 max_catchup：{out}"
    # floor(10 工位 × 12 单位/小时 × 600 秒 / 3600) = 20
    assert out["EXPECTED"] == "20" and out["PRODUCED"] == "20", (
        f"产量不是按 max_catchup 截断的：{out}"
    )
    assert out["PRODUCED"] != out["UNCAPPED"], "产量按真实 dt 算出来了（停机追赶上限失效）"
    assert out["NEW_LAST"] == "600", "last_tick_at 前进幅度超过 max_catchup"
    assert int(out["ADVANCED"]) <= 600


# ══════════════════════════════════════════════════════════════════
# 3. 库存上限：cap = 0 / 已满 → 0，且不刷屏
# ══════════════════════════════════════════════════════════════════


def test_full_stock_or_zero_cap_produces_nothing():
    out = run("""
        local full = IndustryProduction.Compute({
            now = 10000, lastTickAt = 0, workstations = 10, stock = 144,
            cap = 144, unitsPerHour = 12, multiplier = 1, maxCatchup = 600,
        })
        local zero = IndustryProduction.Compute({
            now = 10000, lastTickAt = 0, workstations = 10, stock = 0,
            cap = 0, unitsPerHour = 12, multiplier = 1, maxCatchup = 600,
        })
        __emit('FULL_PRODUCED', tostring(full.produced))
        __emit('FULL_BLOCKED', tostring(full.blocked))
        __emit('FULL_ADVANCED', tostring(full.advancedSeconds))
        __emit('ZERO_PRODUCED', tostring(zero.produced))
        __emit('ZERO_BLOCKED', tostring(zero.blocked))
        __emit('HAS_NOTIFY_FIELD', tostring(full.notify ~= nil or zero.notify ~= nil))
        __emit('HAS_MESSAGE_FIELD', tostring(full.message ~= nil or zero.message ~= nil))
    """)
    assert out["FULL_PRODUCED"] == "0", "库存已满还能继续产出"
    assert out["FULL_BLOCKED"] == "stock_full"
    assert out["FULL_ADVANCED"] == "600", (
        "满仓期间必须推进 last_tick_at（否则 S4 卖出后会把满仓时间补算成新产出）"
    )
    assert out["ZERO_PRODUCED"] == "0", "cap=0 还能产出"
    assert out["ZERO_BLOCKED"] == "cap_zero"
    assert out["HAS_NOTIFY_FIELD"] == "false", "纯函数不应携带通知字段"
    assert out["HAS_MESSAGE_FIELD"] == "false", "纯函数不应携带回执字段"


def test_partial_stock_space_truncates_the_expected_output():
    """库存只剩 4 个单位、期望产出 20 → 只能产 4（截断必须真的生效）。

    这条是反向注入的靶子：把 `produced = min(expected, space)` 删掉时，
    这里会变 20 而不是 4，用例必须红。cap=0/已满的用例在更早的分支返回，
    碰不到这个截断，所以单独补一条「部分空间」的形状。
    """
    out = run("""
        local plan = IndustryProduction.Compute({
            now = 10000, lastTickAt = 0, workstations = 10, stock = 140,
            cap = 144, unitsPerHour = 12, multiplier = 1, maxCatchup = 600,
        })
        __emit('EXPECTED', tostring(plan.expected))
        __emit('SPACE', tostring(plan.space))
        __emit('PRODUCED', tostring(plan.produced))
        __emit('BLOCKED', tostring(plan.blocked))
        __emit('NEW_LAST', tostring(plan.newLastTickAt))
    """)
    assert out["EXPECTED"] == "20" and out["SPACE"] == "4", f"测试前提不对：{out}"
    assert out["PRODUCED"] == "4", (
        f"期望 20、只剩 4 空间，产量必须是 4（min 截断没生效）：{out}"
    )
    assert out["BLOCKED"] == "stock_full"
    assert out["NEW_LAST"] == "600", "被库存截断时要整段前进，避免满仓时间被补算"


def test_production_paths_have_no_notification_or_net_event():
    """满仓冻结时「不产生任何回执/通知」是代码形状，不是调用方自觉。"""
    production = PRODUCTION_SRC.read_text(encoding="utf-8")
    commands = COMMANDS_PRODUCTION_SRC.read_text(encoding="utf-8")
    forbidden = (
        "TriggerClientEvent",
        "RegisterNetEvent",
        "SendNUIMessage",
        "QBCore.Functions.Notify",
        "chat:addMessage",
    )
    for path, text in ((PRODUCTION_SRC, production), (COMMANDS_PRODUCTION_SRC, commands)):
        for token in forbidden:
            assert token not in text, f"{path.name} 里出现了通知/回执路径：{token}"
    assert "Treasury" not in production, (
        "S3 只物化库存、不货币化：生产路径不许碰 Treasury"
    )


# ══════════════════════════════════════════════════════════════════
# 4. 正常 dt：workstations × 单位速率 × dt，floor 取整
# ══════════════════════════════════════════════════════════════════


def test_normal_dt_uses_workstations_rate_and_floor_rounding():
    out = run("""
        local function settle(now, ws, rate, multiplier)
            return IndustryProduction.Compute({
                now = now, lastTickAt = 0, workstations = ws, stock = 0,
                cap = 1000000, unitsPerHour = rate, multiplier = multiplier or 1,
                maxCatchup = 86400,
            })
        end

        local hour = settle(3600, 3, 12)          -- 3 × 12 × 3600 / 3600 = 36
        local odd = settle(100, 3, 12)            -- floor(3 × 12 × 100 / 3600) = 1
        local tiny = settle(100, 1, 12)           -- floor(1 × 12 × 100 / 3600) = 0
        local unit = settle(300, 1, 12)           -- 300 秒够 1 单位
        local mult = settle(3600, 2, 12, 1.25)    -- 2 × 12 × 1.25 = 30

        __emit('HOUR', hour.produced .. ':' .. hour.newLastTickAt)
        __emit('ODD', odd.produced .. ':' .. odd.newLastTickAt)
        __emit('TINY', tiny.produced .. ':' .. tiny.newLastTickAt)
        __emit('UNIT', unit.produced .. ':' .. unit.newLastTickAt)
        __emit('MULT', mult.produced .. ':' .. mult.newLastTickAt)
    """)
    assert out["HOUR"] == "36:3600", f"正常一小时产量不对：{out['HOUR']}"
    assert out["ODD"] == "1:100", f"floor 取整/前进时间不对：{out['ODD']}"
    # 不足一个单位：不产出，也不前进 —— 时间留到下一次继续累计。
    assert out["TINY"] == "0:0", f"不足一单位时不该前进 last_tick_at：{out['TINY']}"
    assert out["UNIT"] == "1:300", f"累计 300 秒应产出 1 单位并前进 300 秒：{out['UNIT']}"
    assert out["MULT"] == "30:3600", f"倍率没有进公式：{out['MULT']}"


# ══════════════════════════════════════════════════════════════════
# 5. 同一时刻重复结算 → 第二次为 0
# ══════════════════════════════════════════════════════════════════


def test_repeated_settlement_at_the_same_instant_is_idempotent():
    out = run("""
        local first = IndustryProduction.Compute({
            now = 1000, lastTickAt = 0, workstations = 1, stock = 0,
            cap = 100000, unitsPerHour = 3600, multiplier = 1, maxCatchup = 3600,
        })
        local second = IndustryProduction.Compute({
            now = 1000, lastTickAt = first.newLastTickAt, workstations = 1,
            stock = first.produced, -- 第一次的产出已经物化进库存
            cap = 100000, unitsPerHour = 3600, multiplier = 1, maxCatchup = 3600,
        })
        __emit('FIRST', tostring(first.produced))
        __emit('FIRST_LAST', tostring(first.newLastTickAt))
        __emit('SECOND', tostring(second.produced))
        __emit('SECOND_LAST', tostring(second.newLastTickAt))
    """)
    assert out["FIRST"] == "1000" and out["FIRST_LAST"] == "1000", (
        f"第一次结算应产出 1000 并推进到 now：{out}"
    )
    assert out["SECOND"] == "0", "同一时刻第二次结算又产出了（幂等失效）"
    assert out["SECOND_LAST"] == "1000", "第二次结算不该再前进 last_tick_at"


# ══════════════════════════════════════════════════════════════════
# 6. 客户端伪造的数字不进公式
# ══════════════════════════════════════════════════════════════════


def test_client_supplied_dt_and_amount_cannot_change_the_result():
    out = run("""
        local opts = {
            now = 500, lastTickAt = 0, workstations = 2, stock = 0,
            cap = 1000, unitsPerHour = 120, multiplier = 1, maxCatchup = 3600,
        }
        local base = IndustryProduction.Compute(opts)
        local injected = IndustryProduction.Compute({
            now = opts.now, lastTickAt = opts.lastTickAt, workstations = opts.workstations,
            stock = opts.stock, cap = opts.cap, unitsPerHour = opts.unitsPerHour,
            multiplier = opts.multiplier, maxCatchup = opts.maxCatchup,
            dt = 999999, produced = 999999, reported = 999999,
            client_dt = 999999, client_produced = 999999,
        })
        __emit('BASE', tostring(base.produced))
        __emit('INJECTED', tostring(injected.produced))
        __emit('SAME_PRODUCED', tostring(base.produced == injected.produced))
        __emit('SAME_LAST', tostring(base.newLastTickAt == injected.newLastTickAt))
        __emit('SAME_EFFECTIVE', tostring(base.effectiveDt == injected.effectiveDt))
    """)
    # floor(2 × 120 × 500 / 3600) = 33
    assert out["BASE"] == "33", f"纯函数基准值不对：{out}"
    assert out["SAME_PRODUCED"] == "true", "客户端多传的 produced 字段改变了产量"
    assert out["SAME_LAST"] == "true", "客户端多传的 dt 字段改变了 last_tick_at"
    assert out["SAME_EFFECTIVE"] == "true"


# ══════════════════════════════════════════════════════════════════
# 6b. 写库路径：离线假 DB（CAS / produced_units / 满仓只前进时间）
# ══════════════════════════════════════════════════════════════════


def test_settle_facility_materializes_stock_and_produced_units_once():
    out = run_db("""
        __reset()
        __facilitySeed('mining_co', { workstations = 10, stock = 0, last_tick_epoch = 0 })

        local ok, err, first = IndustryProduction.SettleFacility('mining_co', { now = 600 })
        local row1 = __facility('mining_co')
        local ok2, err2, second = IndustryProduction.SettleFacility('mining_co', { now = 600 })
        local row2 = __facility('mining_co')

        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('FIRST_PRODUCED', tostring(first.produced))
        __emit('STOCK1', tostring(row1.stock))
        __emit('UNITS1', tostring(row1.produced_units))
        __emit('LAST1', tostring(row1.last_tick_epoch))
        __emit('SECOND_PRODUCED', tostring(second.produced))
        __emit('SECOND_SETTLED', tostring(second.settled))
        __emit('STOCK2', tostring(row2.stock))
        __emit('UNITS2', tostring(row2.produced_units))
        __emit('UPDATES', tostring(__productionUpdates))
    """)
    assert out["OK"] == "true" and out["ERR"] == "nil", f"正常结算失败：{out}"
    # 10 工位 × 4.5/h × 600 秒 = 7（向下取整）；7 件只消耗 560 秒。
    assert out["FIRST_PRODUCED"] == "7"
    assert out["STOCK1"] == "7" and out["UNITS1"] == "7", (
        f"产出必须同时进 stock 与 produced_units：{out}"
    )
    assert out["LAST1"] == "560"
    assert out["SECOND_PRODUCED"] == "0" and out["SECOND_SETTLED"] == "false", (
        f"同一时刻第二次结算又写库了：{out}"
    )
    assert out["STOCK2"] == "7" and out["UNITS2"] == "7"
    assert out["UPDATES"] == "1", f"第二次没有时间可结算时不该发 UPDATE：{out}"


def test_settle_facility_cas_retries_without_double_counting():
    """读到 last_tick=0 后被别人结算到 300：第一次 CAS 失败，重算后只产 3。"""
    out = run_db("""
        __reset()
        __facilitySeed('mining_co', { workstations = 10, stock = 0, last_tick_epoch = 0 })
        __raceBeforeUpdate = function()
            local row = __facility('mining_co')
            row.last_tick_epoch = 300
            row.stock = 10
            row.produced_units = 10
        end

        local ok, err, result = IndustryProduction.SettleFacility('mining_co', { now = 600 })
        local row = __facility('mining_co')
        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('PRODUCED', tostring(result.produced))
        __emit('STOCK', tostring(row.stock))
        __emit('UNITS', tostring(row.produced_units))
        __emit('LAST', tostring(row.last_tick_epoch))
        __emit('UPDATES', tostring(__productionUpdates))
    """)
    assert out["OK"] == "true" and out["ERR"] == "nil", f"CAS 冲突重试失败：{out}"
    # 45 单位/小时 × 300 秒 = 3（向下取整）。
    assert out["PRODUCED"] == "3", f"重算后的产量不对（应只补 300 秒）：{out}"
    assert out["STOCK"] == "13" and out["UNITS"] == "13", (
        f"CAS 冲突后双算了：{out}"
    )
    assert out["LAST"] == "540"
    assert out["UPDATES"] == "2", f"第一次 CAS 失败后没有重试：{out}"


def test_settle_facility_full_stock_advances_time_without_touching_units():
    out = run_db("""
        __reset()
        __facilitySeed('mining_co', {
            workstations = 10, stock = 540, produced_units = 50, last_tick_epoch = 0,
        })
        local ok, err, result = IndustryProduction.SettleFacility('mining_co', { now = 600 })
        local row = __facility('mining_co')
        __emit('OK', tostring(ok))
        __emit('PRODUCED', tostring(result.produced))
        __emit('BLOCKED', tostring(result.blocked))
        __emit('STOCK', tostring(row.stock))
        __emit('UNITS', tostring(row.produced_units))
        __emit('LAST', tostring(row.last_tick_epoch))
        __emit('UPDATES', tostring(__productionUpdates))
    """)
    assert out["OK"] == "true" and out["PRODUCED"] == "0"
    assert out["BLOCKED"] == "stock_full"
    assert out["STOCK"] == "540" and out["UNITS"] == "50", (
        f"满仓时 stock / produced_units 都不能动：{out}"
    )
    assert out["LAST"] == "600", "满仓也要推进 last_tick_at，避免卖出后补算"
    assert out["UPDATES"] == "1"


# ══════════════════════════════════════════════════════════════════
# 7. 接线：加载全部 server 脚本，不提供全局 QBCore
# ══════════════════════════════════════════════════════════════════

def test_all_server_scripts_wire_player_loaded_and_tick_without_global_qbcore():
    out = run_wiring(debug=False)
    expected = {
        "orgfund", "orgfunddeposit", "orgfundwithdraw", "orgfundgrant",
        "orgbuild", "orghire", "orgfacility",
    }
    assert out["COUNT"] == "7", f"QBCore 命令没有全部注册：{out}"
    assert sorted(out["NAMES"].split(",")) == sorted(expected)
    assert out["EVENTS"] == "1", (
        f"必须挂且只挂一个 PlayerLoaded 处理器（离线补产走同一条惰性结算）：{out}"
    )
    assert out["THREADS"] == "1", (
        f"生产心跳线程没有启动（周期 tick 必须挂到同一条线程，不能新增线程）：{out}"
    )
    assert out["NATIVE"] == "industry_setphase:true,industry_settle:true", (
        f"S6/S7 控制台命令必须常驻且 restricted；调试卖出/生产入口默认关闭：{out}"
    )
    assert out["HAS_GLOBAL"] == "false", (
        "用例自己定义了全局 QBCore —— 生产环境缺它的 bug 会被永远掩盖"
    )


def test_console_entry_registers_only_when_the_convar_is_on():
    out = run_wiring(debug=True)
    assert out["NATIVE"] == (
        "orgproduce:true,industry_setphase:true,industry_settle:true"
    ), f"后台入口必须是 restricted 的原生命令（仅控制台）：{out}"
    assert out["COUNT"] == "7", "后台入口不该污染 QBCore 命令表"
    assert out["EVENTS"] == "1" and out["THREADS"] == "1"
