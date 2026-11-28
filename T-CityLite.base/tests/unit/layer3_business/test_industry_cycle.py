"""S6 周期状态机：四阶段、guarded UPDATE、补推不跳段、倍率接线。

钉住的事：

1. **阶段顺序固定**（扩张 → 竞争 → 成熟 → 衰退），每个边界只推进一次；
2. **一次 tick 只推进一格**：停机跨多个边界时按顺序补推，不跳段；
3. **推进许可只有 guarded UPDATE 的 affected == 1**：读到旧状态后被别人改掉，本 tick
   不得推进、也不得做副作用（配额种子/公告）；
4. **重启从 DB 续跑**：阶段与边界全部从 industry_state 读，不依赖进程内状态；
5. **倍率接线到已有读点**：生产（S3）乘产能倍率，销售（S4）乘售价倍率并保留衰退期卖出，
   购置（S2）在衰退期返回 purchases_closed，配额种子按阶段倍率缩放；
6. **公告**：结算前 warning 只发一次，结算结果只发一次；
7. **industry_setphase 只能控制台**（restricted + source == 0），并写审计。

反例（先红后绿的靶子）：
  * `test_state_advance_rejects_when_guarded_update_affected_zero` —— 推进越权/跳段；
  * `test_downtime_catchup_is_sequential_and_never_skips_a_phase` —— 一次 tick 连推；
  * `test_recession_still_sells_but_blocks_purchases` —— 末期卡死。

反向注入：把 `TickOnce` 的 guarded WHERE 去掉，第 3 条必须红；把 `nextPhase` 换成
`order[#order]`，第 2 条必须红；把 `phasePrice` 从销售公式里删掉，第 5 条必须红。
"""

from __future__ import annotations

from industry_harness import FALSE, TRUE, run_full as run


# ══════════════════════════════════════════════════════════════════
# 1. 阶段顺序：每个边界只推进一次
# ══════════════════════════════════════════════════════════════════


def test_phase_order_advances_once_per_boundary():
    out = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'expansion', started_epoch = 940, ends_epoch = 1000 })

        local phases = {}
        local function tick(now)
            local ok, err, info = IndustryCycle.Tick(now)
            phases[#phases + 1] = tostring(ok) .. ':' .. tostring(err or 'nil')
                .. ':' .. tostring(info and info.to or 'none')
        end

        tick(1000)  -- expansion → competition
        tick(1000)  -- 同一时刻再 tick：competition 还没结束，不能推进
        tick(1060)  -- competition → maturity
        tick(1120)  -- maturity → recession
        tick(1180)  -- recession → 结算 → 下一轮 expansion

        __emit('TICKS', table.concat(phases, ','))
        local state = __stateRow()
        __emit('PHASE', state.phase)
        __emit('CYCLE', tostring(state.cycle_no))
        __emit('SETTLED', tostring(state.settled_cycle_no))
        __emit('RESULTS', tostring(__resultCount(1)))
    """, convars={"industry_phase_seconds": "60"})

    assert out["TICKS"] == (
        "true:nil:competition,true:nil:none,true:nil:maturity,"
        "true:nil:recession,true:nil:expansion"
    ), f"阶段推进序列不对：{out['TICKS']}"
    assert out["PHASE"] == "expansion"
    assert out["CYCLE"] == "2", "衰退结束必须进入下一轮（cycle_no + 1）"
    assert out["SETTLED"] == "1", "跨周期前必须完成 cycle 1 结算"
    assert out["RESULTS"] == "0", "无组织参与时不应凭空写结果行"


# ══════════════════════════════════════════════════════════════════
# 2. 停机补推：一次一格，不跳段
# ══════════════════════════════════════════════════════════════════


def test_downtime_catchup_is_sequential_and_never_skips_a_phase():
    out = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'expansion', started_epoch = 940, ends_epoch = 1000 })

        local seen = {}
        local function tick()
            local _, _, info = IndustryCycle.Tick(1300)
            if info and info.to then seen[#seen + 1] = info.to end
        end
        for _ = 1, 5 do tick() end

        __emit('SEEN', table.concat(seen, ','))
        __emit('CYCLE', tostring(__stateRow().cycle_no))
        __emit('SETTLED', tostring(__stateRow().settled_cycle_no))
    """, convars={"industry_phase_seconds": "60"})

    assert out["SEEN"] == (
        "competition,maturity,recession,expansion,competition"
    ), f"停机补推跳段或一次推多格：{out['SEEN']}"
    assert out["CYCLE"] == "2"
    assert out["SETTLED"] == "1", "补推跨周期前必须结算 cycle 1"


# ══════════════════════════════════════════════════════════════════
# 3. 反例：guarded UPDATE affected = 0 时不得推进（也不得播种配额）
# ══════════════════════════════════════════════════════════════════


def test_state_advance_rejects_when_guarded_update_affected_zero():
    out = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'expansion', started_epoch = 940, ends_epoch = 1000 })
        __raceBeforeStateUpdate = function()
            __state.phase = 'maturity' -- 另一个写者先改了阶段
        end

        local ok, err = IndustryCycle.Tick(1000)
        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('PHASE', __stateRow().phase)
        __emit('DEMAND_ROWS', tostring(__demandCount(1)))
    """, convars={"industry_phase_seconds": "60"})

    assert out["OK"] == FALSE, "guarded UPDATE 没拿到 affected=1，Tick 却报告成功"
    assert out["ERR"] == "conflict"
    assert out["PHASE"] == "maturity", "竞争写者改过的阶段被覆盖了"
    assert out["DEMAND_ROWS"] == "0", "推进失败却执行了副作用（配额种子）"


# ══════════════════════════════════════════════════════════════════
# 4. 重启续跑：阶段与边界只来自 DB
# ══════════════════════════════════════════════════════════════════


def test_restart_resumes_from_database_state_without_recalibration():
    out = run("""
        __reset()
        -- 模拟重启后的库：进程内没有任何状态，边界是上次写下的绝对时间。
        __seedState({ cycle_no = 3, phase = 'maturity', started_epoch = 4000, ends_epoch = 5000 })

        local before = IndustryCycle.Tick(4999)
        __emit('BEFORE', tostring(before))
        local after, err, info = IndustryCycle.Tick(5000)
        __emit('AFTER', tostring(after) .. ':' .. tostring(err or 'nil')
            .. ':' .. tostring(info and info.to or 'none'))
        __emit('PHASE', __stateRow().phase)
        __emit('CYCLE', tostring(__stateRow().cycle_no))
        __emit('ENDS', tostring(__stateRow().ends_epoch))
    """, convars={"industry_phase_seconds": "60"})

    assert out["BEFORE"] == TRUE, "未到边界就推进了"
    assert out["AFTER"] == "true:nil:recession"
    assert out["PHASE"] == "recession"
    assert out["CYCLE"] == "3", "重启后周期号被重置"
    assert out["ENDS"] == "5060", "新边界必须从 DB 里的旧结束时间继续算"


# ══════════════════════════════════════════════════════════════════
# 5. 反例：衰退期仍可卖出，但不可购置
# ══════════════════════════════════════════════════════════════════


def test_recession_still_sells_but_blocks_purchases():
    out = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'recession', started_epoch = 0, ends_epoch = 100000 })
        __seedTreasury('mining_co', 0)
        __seedFacility('mining_co', { stock = 10, workstations = 1, last_tick_epoch = 100000 })
        __seedDemand(1, 'recession', 'iron_ore', 4, 0)

        local sold, sellErr, result = IndustrySales.SettleSale(
            'mining_co', 'iron_ore', 2, 'recession-sale')
        __emit('SOLD', tostring(sold) .. ':' .. tostring(sellErr or 'nil'))
        __emit('REVENUE', tostring(result and result.revenue))
        __emit('STOCK', tostring(__facility('mining_co').stock))
        __emit('QUOTA', tostring(__demandRow(1, 'recession', 'iron_ore').quota_used))

        local built, buildErr = Facility.Build('mining_co', 'mine', { actor = 'cid1' })
        __emit('BUILD', tostring(built) .. ':' .. tostring(buildErr or 'nil'))
        local hired, hireErr = Facility.AddWorkstation('mining_co', { actor = 'cid1' })
        __emit('HIRE', tostring(hired) .. ':' .. tostring(hireErr or 'nil'))
    """, convars={"industry_phase_seconds": "60"})

    # floor(50 × 2 × 1.0 × 1.0 × 0.80) = 80
    assert out["SOLD"] == "true:nil", f"衰退期卖不出去（末期卡死）：{out}"
    assert out["REVENUE"] == "80", f"售价倍率没有进公式：{out}"
    assert out["STOCK"] == "8"
    assert out["QUOTA"] == "2"
    assert out["BUILD"] == "false:purchases_closed"
    assert out["HIRE"] == "false:purchases_closed"


# ══════════════════════════════════════════════════════════════════
# 6. S3 产能倍率 / S4 配额倍率
# ══════════════════════════════════════════════════════════════════


def test_production_uses_the_phase_multiplier():
    expansion = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'expansion', started_epoch = 0, ends_epoch = 100000 })
        __seedFacility('mining_co', { stock = 0, workstations = 10, last_tick_epoch = 0 })
        local ok, err = IndustryProduction.SettleFacility('mining_co', { now = 600 })
        __emit('OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('STOCK', tostring(__facility('mining_co').stock))
    """)

    recession = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'recession', started_epoch = 0, ends_epoch = 100000 })
        __seedFacility('mining_co', { stock = 0, workstations = 10, last_tick_epoch = 0 })
        local ok, err = IndustryProduction.SettleFacility('mining_co', { now = 600 })
        __emit('OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('STOCK', tostring(__facility('mining_co').stock))
    """)

    # 10 工位 × 4.5/h × 600s：扩张 1.25 → 9；衰退 0.70 → 5。
    assert expansion["OK"] == "true:nil", f"扩张期结算失败：{expansion}"
    assert expansion["STOCK"] == "9", f"扩张期产能倍率没生效：{expansion}"
    assert recession["OK"] == "true:nil", f"衰退期结算失败：{recession}"
    assert recession["STOCK"] == "5", f"衰退期产能倍率没生效：{recession}"


def test_phase_advance_seeds_demand_with_the_quota_multiplier():
    out = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'expansion', started_epoch = 940, ends_epoch = 1000 })
        IndustryCycle.Tick(1000)
        local row = __demandRow(1, 'competition', 'iron_ore')
        __emit('TOTAL', tostring(row and row.quota_total))
        __emit('USED', tostring(row and row.quota_used))
    """, convars={
        "industry_phase_seconds": "60",
        "industry_demand_seed": "10",
    })

    assert out["TOTAL"] == "8", f"竞争期配额应为 floor(10 × 0.85)=8：{out}"
    assert out["USED"] == "0"


# ══════════════════════════════════════════════════════════════════
# 7. 公告：warning 与 result 都只发一次
# ══════════════════════════════════════════════════════════════════


def test_warning_and_result_bulletins_are_each_published_once():
    out = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'recession', started_epoch = 0, ends_epoch = 1000 })

        IndustryCycle.Tick(900)  -- 距离结算 > 60s：不公告
        __emit('EARLY', tostring(__bulletinCount()))
        IndustryCycle.Tick(950)  -- 进入提前量：warning
        __emit('WARN', tostring(__bulletinCount()))
        __emit('WARN_AT', tostring(__stateRow().warning_epoch))
        IndustryCycle.Tick(960)  -- 不重复
        __emit('AGAIN', tostring(__bulletinCount()))
        IndustryCycle.Tick(1000) -- 结算 + 结果公告
        __emit('AFTER_SETTLE', tostring(__bulletinCount()))
        __emit('LAST', tostring(__lastBulletin()))
    """, convars={
        "industry_phase_seconds": "60",
        "industry_cycle_warn_seconds": "60",
        "industry_cycle_retry_seconds": "1",
    })

    assert out["EARLY"] == "0", "还没到提前量就公告了"
    assert out["WARN"] == "1", "结算前公告没有发出"
    assert out["WARN_AT"] == "950"
    assert out["AGAIN"] == "1", "结算前公告重复发送"
    assert out["AFTER_SETTLE"] == "2", "结算结果公告没有发出"
    assert "已结算" in out["LAST"], f"最后一条不是结算结果：{out['LAST']}"


# ══════════════════════════════════════════════════════════════════
# 8. industry_setphase：restricted + source == 0 + 审计
# ══════════════════════════════════════════════════════════════════


def test_setphase_is_console_only_and_writes_audit():
    out = run("""
        __reset()
        __seedState({ cycle_no = 4, phase = 'expansion', started_epoch = 100, ends_epoch = 1100 })
        os.time = function() return 5000 end

        IndustryCycleCommands.Register()
        local handler = __handlers['industry_setphase']
        __emit('RESTRICTED', tostring(__native[1].restricted))

        handler(1, { 'recession' })
        __emit('PLAYER_PHASE', __stateRow().phase)
        __emit('PLAYER_RESULT', __auditPayload('cycle.setphase'))

        handler(0, { 'maturity' })
        local state = __stateRow()
        __emit('CONSOLE_PHASE', state.phase)
        __emit('CONSOLE_CYCLE', tostring(state.cycle_no))
        __emit('CONSOLE_START', tostring(state.started_epoch))
        __emit('CONSOLE_END', tostring(state.ends_epoch))
        __emit('AUDIT_LAST', tostring(__lastAuditPayload('cycle.setphase')))

        handler(0, { 'not_a_phase' })
        __emit('AUDIT_COUNT', tostring(__auditCount('cycle.setphase')))
        __emit('BAD_PHASE', __stateRow().phase)
    """, convars={"industry_phase_seconds": "60"})

    assert out["RESTRICTED"] == TRUE, "industry_setphase 必须是 restricted 原生命令"
    assert out["PLAYER_PHASE"] == "expansion", "玩家调用改掉了阶段"
    assert 'not_console' in out["PLAYER_RESULT"], "玩家调用没有写拒绝审计"
    assert '"phase":"recession"' in out["PLAYER_RESULT"], (
        f"审计 JSON 的 phase 字段被 gsub 的第二个返回值挤错位：{out['PLAYER_RESULT']}"
    )
    assert out["CONSOLE_PHASE"] == "maturity"
    assert out["CONSOLE_CYCLE"] == "4", "未指定 cycle 时必须保持当前周期"
    assert out["CONSOLE_START"] == "5000"
    assert out["CONSOLE_END"] == "5060"
    assert out["AUDIT_COUNT"] == "3", f"每次调用（含拒绝）都要审计：{out}"
    assert '"result":"ok"' in out["AUDIT_LAST"]
    assert out["BAD_PHASE"] == "maturity", "非法阶段被写进状态"


# ══════════════════════════════════════════════════════════════════
# 8b. 压缩 convar 与默认 7 天公告窗口
# ══════════════════════════════════════════════════════════════════


def test_cycle_scale_convar_compresses_the_design_durations():
    out = run("""
        __emit('EXPANSION', tostring(IndustryCycle.PhaseSeconds('expansion')))
        __emit('COMPETITION', tostring(IndustryCycle.PhaseSeconds('competition')))
        __emit('MATURITY', tostring(IndustryCycle.PhaseSeconds('maturity')))
        __emit('RECESSION', tostring(IndustryCycle.PhaseSeconds('recession')))
    """, convars={"industry_cycle_scale": "86400"})

    # scale = 86400 → 每「设计天」压成 1 秒。
    assert out["EXPANSION"] == "10"
    assert out["COMPETITION"] == "10"
    assert out["MATURITY"] == "5"
    assert out["RECESSION"] == "3"


def test_default_warning_window_is_seven_days_before_the_cycle_end():
    out = run("""
        local state = {
            cycle_no = 1, phase = 'expansion', ends_epoch = 864000, -- 第 10 天
        }
        __emit('WARNING', tostring(IndustryCycle.WarningSeconds()))
        __emit('CYCLE_ENDS', tostring(IndustryCycle.CycleEndsAt(state)))
    """)

    assert out["WARNING"] == "604800", "默认公告提前量必须是 7 天"
    # 扩张第 10 天 + 竞争 10 天 + 成熟 5 天 + 衰退 3 天 = 第 28 天。
    assert out["CYCLE_ENDS"] == str(28 * 86400)


# ══════════════════════════════════════════════════════════════════
# 9. 验收口径：industry_phase_seconds=60 → 4 分钟走完 4 阶段
# ══════════════════════════════════════════════════════════════════


def test_compressed_cycle_completes_four_phases_in_four_minutes():
    """日志可直接贴进交付报告：每个阶段只推进一次，重启不重算边界。"""
    out = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'expansion', started_epoch = 0, ends_epoch = 60 })

        local lines = {}
        local function log(tag, now)
            local ok, err, info = IndustryCycle.Tick(now)
            local state = __stateRow()
            lines[#lines + 1] = ('[cycle-demo] %s now=%d ok=%s err=%s advanced=%s '
                .. 'phase=%s cycle=%d ends=%d settled=%d'):format(
                tag, now, tostring(ok), tostring(err or '-'),
                tostring(info and info.advanced or false), state.phase,
                state.cycle_no, state.ends_epoch, state.settled_cycle_no)
        end

        log('t+60', 60)    -- 扩张 → 竞争
        log('t+120', 120)  -- 竞争 → 成熟

        -- 模拟重启：Start()/Initialize() 只能在种子阶段写边界，已有真实阶段必须原样续跑。
        local before = __stateRow().ends_epoch
        IndustryCycle.Start()
        local restarted = __stateRow()
        lines[#lines + 1] = ('[cycle-demo] restart after t+120 phase=%s ends=%d '
            .. '(边界未重算=%s)'):format(
            restarted.phase, restarted.ends_epoch,
            tostring(restarted.ends_epoch == before))
        __emit('RESTART_UNCHANGED', tostring(restarted.ends_epoch == before))

        log('t+180', 180)  -- 成熟 → 衰退
        log('t+240', 240)  -- 衰退 → 结算 → 下一轮扩张

        local state = __stateRow()
        __emit('DEMO_LOG', table.concat(lines, ' ~ '))
        __emit('FINAL_PHASE', state.phase)
        __emit('FINAL_CYCLE', tostring(state.cycle_no))
        __emit('SETTLED', tostring(state.settled_cycle_no))
        __emit('RESULTS', tostring(__resultCount(1)))
    """, convars={"industry_phase_seconds": "60"})

    print("\n" + out["DEMO_LOG"].replace(" ~ ", "\n"))
    assert out["RESTART_UNCHANGED"] == TRUE, "重启把已运行阶段的边界重算了"
    assert out["FINAL_PHASE"] == "expansion"
    assert out["FINAL_CYCLE"] == "2"
    assert out["SETTLED"] == "1"
    assert out["RESULTS"] == "0", "无组织时应只推进、不写结果"


# ══════════════════════════════════════════════════════════════════
# P1 两时钟（#409）：周 = 四季，13 周 = 季度
# ══════════════════════════════════════════════════════════════════
#
# 探针文件 `fixtures/industry_cycle_probe.lua` 不在本片可改范围，所以两时钟
# 需要的「industry_state 多列 + 按季滚动 SQL」在测试体内补一层假 DB 扩展。
# 扩展只认本片真实写出来的 SQL 形状；形状对不上返回 affectedRows = 0（不兜底）。

TWO_CLOCK_HARNESS = r"""
local __tcBaseUpdate = MySQL.update.await
local __tcBaseSingle = MySQL.single.await

local function __tcIsStateUpdate(sql)
    return sql:find('UPDATE industry_state', 1, true) ~= nil
        and sql:find('season_no', 1, true) ~= nil
end

--- 两时钟状态的种子：字段名与真实表列一一对应（season 存 varchar 季名）。
function __seedTwoClock(values)
    values = values or {}
    local phases = {
        spring = 'expansion', summer = 'competition',
        autumn = 'maturity', winter = 'recession',
    }
    __state = {
        cycle_no = tonumber(values.cycle_no) or 1,
        phase = values.phase or phases[values.season or 'spring'] or 'expansion',
        started_epoch = tonumber(values.season_started_epoch) or 0,
        ends_epoch = tonumber(values.season_ends_epoch) or 0,
        warning_epoch = values.warning_epoch,
        settled_cycle_no = tonumber(values.settled_cycle_no) or 0,
        result_announced_cycle = tonumber(values.result_announced_cycle) or 0,
        quarter_no = tonumber(values.quarter_no) or 1,
        season = values.season or 'spring',
        season_no = tonumber(values.season_no) or 1,
        season_started_epoch = tonumber(values.season_started_epoch) or 0,
        season_ends_epoch = tonumber(values.season_ends_epoch) or 0,
        quarter_started_epoch = tonumber(values.quarter_started_epoch) or 0,
        quarter_ends_epoch = tonumber(values.quarter_ends_epoch) or 0,
    }
end

MySQL.single.await = function(sql, values)
    if __state and __state.season and sql:find('FROM industry_state', 1, true) then
        if sql:find('SELECT settled_cycle_no', 1, true) then
            return { settled_cycle_no = __state.settled_cycle_no }
        end
        if sql:find('SELECT result_announced_cycle', 1, true) then
            return { result_announced_cycle = __state.result_announced_cycle }
        end
        return {
            id = 1,
            cycle_no = __state.cycle_no,
            phase = __state.phase,
            started_epoch = __state.season_started_epoch,
            ends_epoch = __state.season_ends_epoch,
            warning_done = __state.warning_epoch ~= nil and 1 or 0,
            warning_epoch = __state.warning_epoch,
            settled_cycle_no = __state.settled_cycle_no,
            result_announced_cycle = __state.result_announced_cycle,
            quarter_no = __state.quarter_no,
            season = __state.season,
            season_no = __state.season_no,
            season_started_epoch = __state.season_started_epoch,
            season_ends_epoch = __state.season_ends_epoch,
            quarter_started_epoch = __state.quarter_started_epoch,
            quarter_ends_epoch = __state.quarter_ends_epoch,
        }
    end
    return __tcBaseSingle(sql, values)
end

MySQL.update.await = function(sql, values)
    if __tcIsStateUpdate(sql) then
        local row = __state
        if not row then return { affectedRows = 0 } end

        -- Initialize 的迁移接线（旧单时钟 → 两时钟），只允许写一次。
        if sql:find('season_started_at IS NULL', 1, true) then
            if row.season_started_epoch ~= nil then return { affectedRows = 0 } end
            row.phase = values[1]
            row.quarter_no = tonumber(values[2]) or 1
            row.season = values[3]
            row.season_no = tonumber(values[4]) or 1
            row.season_started_epoch = tonumber(values[5])
            row.season_ends_epoch = tonumber(values[6])
            row.quarter_started_epoch = tonumber(values[7])
            row.quarter_ends_epoch = tonumber(values[8])
            row.started_epoch = row.season_started_epoch
            row.ends_epoch = row.season_ends_epoch
            row.warning_epoch = nil
            row.settled_cycle_no = 0
            row.result_announced_cycle = 0
            return { affectedRows = 1 }
        end

        -- SetPhase 的两时钟覆盖：无到期闸门，只要求 season 已初始化。
        if sql:find('AND season_started_at IS NOT NULL', 1, true) then
            row.cycle_no = tonumber(values[1])
            row.phase = values[2]
            row.started_epoch = tonumber(values[3])
            row.ends_epoch = tonumber(values[4])
            row.quarter_no = tonumber(values[5])
            row.season = values[6]
            row.season_no = tonumber(values[7])
            row.season_started_epoch = tonumber(values[8])
            row.season_ends_epoch = tonumber(values[9])
            row.quarter_started_epoch = tonumber(values[10])
            row.quarter_ends_epoch = tonumber(values[11])
            return { affectedRows = 1 }
        end

        -- RollSeason：四道闸（cycle / phase / season_no / 到期时间）+ 可选结算水位。
        if sql:find('SET cycle_no = ?', 1, true) then
            if row.cycle_no ~= tonumber(values[12]) then return { affectedRows = 0 } end
            if row.phase ~= values[13] then return { affectedRows = 0 } end
            if row.season_no ~= tonumber(values[14]) then return { affectedRows = 0 } end
            if row.season_ends_epoch > tonumber(values[15]) then
                return { affectedRows = 0 }
            end
            if sql:find('settled_cycle_no >= ?', 1, true)
                and row.settled_cycle_no < tonumber(values[16]) then
                return { affectedRows = 0 }
            end
            row.cycle_no = tonumber(values[1])
            row.phase = values[2]
            row.started_epoch = tonumber(values[3])
            row.ends_epoch = tonumber(values[4])
            row.quarter_no = tonumber(values[5])
            row.season = values[6]
            row.season_no = tonumber(values[7])
            row.season_started_epoch = tonumber(values[8])
            row.season_ends_epoch = tonumber(values[9])
            row.quarter_started_epoch = tonumber(values[10])
            row.quarter_ends_epoch = tonumber(values[11])
            if sql:find('warning_announced_at = NULL', 1, true) then
                row.warning_epoch = nil
            end
            return { affectedRows = 1 }
        end
        return { affectedRows = 0 }
    end
    return __tcBaseUpdate(sql, values)
end
"""


def test_thirteen_weeks_make_one_quarter_and_reset_to_spring():
    """13 周 = 52 个季节：season_no 1→4 轮 13 次后 quarter_no +1、season 归 spring。"""
    out = run(TWO_CLOCK_HARNESS + """
        __reset()
        __seedTwoClock({
            cycle_no = 1, quarter_no = 1, season = 'spring', season_no = 1,
            season_started_epoch = 0, season_ends_epoch = 1,
            quarter_started_epoch = 0, quarter_ends_epoch = 52,
        })

        local seasons, seasonNos, weeks = {}, {}, {}
        for tick = 1, 52 do
            local ok, err = IndustryCycle.Tick(tick)
            if not ok then
                __emit('FAILED_AT', tostring(tick) .. ':' .. tostring(err))
                break
            end
            local state = __stateRow()
            seasons[#seasons + 1] = state.season
            seasonNos[#seasonNos + 1] = tostring(state.season_no)
            if state.season_no == 4 then weeks[#weeks + 1] = tostring(state.cycle_no) end
        end

        local state = __stateRow()
        __emit('SEASON_SEQ', table.concat(seasons, ','))
        __emit('SEASON_NO_SEQ', table.concat(seasonNos, ','))
        __emit('WINTER_WEEKS', table.concat(weeks, ','))
        __emit('QUARTER', tostring(state.quarter_no))
        __emit('SEASON', state.season)
        __emit('SEASON_NO', tostring(state.season_no))
        __emit('CYCLE', tostring(state.cycle_no))
        __emit('SETTLED', tostring(state.settled_cycle_no))
        __emit('QUARTER_START', tostring(state.quarter_started_epoch))
        __emit('QUARTER_END', tostring(state.quarter_ends_epoch))
        __emit('QUARTER_SECONDS', tostring(IndustryCycle.QuarterSeconds(1, 1)))
    """, convars={"industry_season_seconds": "1"})

    # 每 tick 记录的是**滚动之后**的状态：第一次 tick 已从 spring 滚到 summer。
    expected_seasons = ",".join(["summer", "autumn", "winter", "spring"] * 13)
    expected_numbers = ",".join(["2", "3", "4", "1"] * 13)
    assert out["SEASON_SEQ"] == expected_seasons, (
        f"13 周必须走完 13 个四季循环，实际：{out['SEASON_SEQ']}"
    )
    assert out["SEASON_NO_SEQ"] == expected_numbers, (
        f"season_no 必须 1→4 反复，实际：{out['SEASON_NO_SEQ']}"
    )
    assert out["WINTER_WEEKS"] == ",".join(str(week) for week in range(1, 14)), (
        f"每个冬天的周号应是 1..13：{out['WINTER_WEEKS']}"
    )
    assert out["QUARTER"] == "2", "13 周结束后 quarter_no 必须 +1"
    assert out["SEASON"] == "spring", "新季度必须从 spring 开始"
    assert out["SEASON_NO"] == "1"
    assert out["CYCLE"] == "14", "周号跨季度继续递增（第 14 周 = 季度 2 第 1 周）"
    assert out["SETTLED"] == "1", "跨季度前必须完成第 1 季度结算"
    assert out["QUARTER_START"] == "52", "新季度从旧季度边界开始（补推不重算）"
    assert out["QUARTER_END"] == "104", "季度长度 = 13 周 × 4 季（压缩后 52 秒）"
    assert out["QUARTER_SECONDS"] == "52"
    print({
        "WINTER_WEEKS": out["WINTER_WEEKS"],
        "QUARTER": out["QUARTER"],
        "SEASON": out["SEASON"],
        "SEASON_NO": out["SEASON_NO"],
        "CYCLE": out["CYCLE"],
        "SETTLED": out["SETTLED"],
        "QUARTER_START": out["QUARTER_START"],
        "QUARTER_END": out["QUARTER_END"],
    })


def test_season_rotation_is_deterministic_and_matches_the_seven_allocations():
    """7 组天数确定性轮转：第 n 周取 ROTATION[(n-1) % 7]，第 8 周回到第 1 组。"""
    out = run("""
        local function row(week)
            return table.concat({
                IndustryCycle.SeasonSeconds(week, 1),
                IndustryCycle.SeasonSeconds(week, 2),
                IndustryCycle.SeasonSeconds(week, 3),
                IndustryCycle.SeasonSeconds(week, 4),
            }, ',')
        end
        local rows = {}
        for week = 1, 8 do rows[#rows + 1] = row(week) end
        __emit('ROWS', table.concat(rows, '|'))
        __emit('ORDER', table.concat(IndustryCycle.SeasonOrder(), ','))
        local winter = IndustryCycle.SeasonMultipliers('winter')
        __emit('WINTER', ('%.2f,%.2f,%.2f'):format(
            winter.prod, winter.quota, winter.price))
    """, convars={"industry_cycle_scale": "86400"})

    assert out["ROWS"] == (
        "2,3,1,1|1,1,3,2|2,2,2,1|1,2,2,2|3,1,1,2|1,3,1,2|2,1,2,2|2,3,1,1"
    ), f"季节天数轮转不对：{out['ROWS']}"
    assert out["ORDER"] == "spring,summer,autumn,winter"
    assert out["WINTER"] == "0.25,1.30,1.50", (
        f"冬天（黑五）倍率必须读配置 0.25/1.30/1.50：{out['WINTER']}"
    )


def test_season_roll_keeps_facility_workstations_stock_and_treasury():
    """季节滚动只清本季配额；设施 / 工位 / 库存 / 库存等级 / 金库必须逐值不变。"""
    out = run(TWO_CLOCK_HARNESS + """
        __reset()
        __seedTwoClock({
            cycle_no = 5, quarter_no = 1, season = 'summer', season_no = 2,
            season_started_epoch = 100, season_ends_epoch = 200,
            quarter_started_epoch = 0, quarter_ends_epoch = 10000,
        })
        __seedTreasury('mining_co', 777, 3)
        __seedFacility('mining_co', {
            stock = 42, workstations = 4, level = 2,
            produced_units = 99, last_tick_epoch = 0,
        })
        -- 库存等级是 P3 才落库的字段；探针行构造器不认，但“季节滚动不动它”必须钉住。
        __facilities['mining_co'].stock_level = 5

        local facility = __facility('mining_co')
        local stockBefore, wsBefore = facility.stock, facility.workstations
        local levelBefore, stockLevelBefore = facility.level, facility.stock_level
        local producedBefore = facility.produced_units
        local balanceBefore = __treasury('mining_co').balance
        local prestigeBefore = __treasury('mining_co').prestige

        local ok, err, info = IndustryCycle.Tick(200)

        local after = __facility('mining_co')
        __emit('OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('FROM', tostring(info and info.from))
        __emit('TO', tostring(info and info.to))
        __emit('STOCK', tostring(stockBefore) .. ':' .. tostring(after and after.stock))
        __emit('WS', tostring(wsBefore) .. ':' .. tostring(after and after.workstations))
        __emit('LEVEL', tostring(levelBefore) .. ':' .. tostring(after and after.level))
        __emit('STOCK_LEVEL', tostring(stockLevelBefore) .. ':'
            .. tostring(after and after.stock_level))
        __emit('PRODUCED', tostring(producedBefore) .. ':'
            .. tostring(after and after.produced_units))
        __emit('BALANCE', tostring(balanceBefore) .. ':'
            .. tostring(__treasury('mining_co').balance))
        __emit('PRESTIGE', tostring(prestigeBefore) .. ':'
            .. tostring(__treasury('mining_co').prestige))
        __emit('FACILITY_ROWS', tostring(__facilityCount()))
        __emit('SEASON', __stateRow().season)
        local current = IndustryCycle.Current()
        -- sale.lua 写 industry_sales.season 时读的就是这个数字；不能再恒 0。
        __emit('SALE_SEASON', tostring(current and current.season))
        __emit('SEASON_NAME', tostring(current and current.season_name))
    """, convars={"industry_season_seconds": "1"})

    assert out["OK"] == "true:nil", f"季节滚动失败：{out}"
    assert out["FROM"] == "summer" and out["TO"] == "autumn"
    assert out["STOCK"] == "42:42", f"季节滚动改了库存：{out['STOCK']}"
    assert out["WS"] == "4:4", f"季节滚动改了工位：{out['WS']}"
    assert out["LEVEL"] == "2:2", f"季节滚动改了设施等级：{out['LEVEL']}"
    assert out["STOCK_LEVEL"] == "5:5", f"季节滚动改了库存等级：{out['STOCK_LEVEL']}"
    assert out["PRODUCED"] == "99:99", f"季节滚动改了累计产量：{out['PRODUCED']}"
    assert out["BALANCE"] == "777:777", f"季节滚动动了金库：{out['BALANCE']}"
    assert out["PRESTIGE"] == "3:3", f"季节滚动动了威望：{out['PRESTIGE']}"
    assert out["FACILITY_ROWS"] == "1", "季节滚动删了设施行"
    assert out["SEASON"] == "autumn"
    assert out["SALE_SEASON"] == "3", "industry_sales.season 仍是 0（销售维度没接线）"
    assert out["SEASON_NAME"] == "autumn"
    print({key: out[key] for key in (
        "STOCK", "WS", "LEVEL", "STOCK_LEVEL", "PRODUCED", "BALANCE",
        "PRESTIGE", "FACILITY_ROWS", "SEASON", "SALE_SEASON")})


def test_restart_resumes_season_clock_without_skipping_or_recalibrating():
    """重启续跑：已过季节边界但未滚动时，一次 Tick 只滚一格，边界从 DB 续算。"""
    out = run(TWO_CLOCK_HARNESS + """
        __reset()
        __seedTwoClock({
            cycle_no = 3, quarter_no = 1, season = 'spring', season_no = 1,
            season_started_epoch = 900, season_ends_epoch = 1000,
            quarter_started_epoch = 0, quarter_ends_epoch = 5000,
        })

        -- 模拟 restart custom-industry：Initialize 只能接时钟，不能重算边界。
        local started = IndustryCycle.Start()
        local seeded = __stateRow()
        __emit('INIT', tostring(started))
        __emit('INIT_UNCHANGED', tostring(seeded.season_ends_epoch == 1000
            and seeded.season_started_epoch == 900))

        local ok1, err1, info1 = IndustryCycle.Tick(1500)
        local first = __stateRow()
        __emit('ROLL1', tostring(ok1) .. ':' .. tostring(err1 or 'nil')
            .. ':' .. tostring(info1 and info1.to or 'none'))
        __emit('S1_SEASON_NO', tostring(first.season_no))
        __emit('S1_CYCLE', tostring(first.cycle_no))
        __emit('S1_START', tostring(first.season_started_epoch))
        __emit('S1_END', tostring(first.season_ends_epoch))

        local ok2, err2, info2 = IndustryCycle.Tick(1500)
        local second = __stateRow()
        __emit('ROLL2', tostring(ok2) .. ':' .. tostring(err2 or 'nil')
            .. ':' .. tostring(info2 and info2.to or 'none'))
        __emit('S2_SEASON_NO', tostring(second.season_no))
        __emit('S2_START', tostring(second.season_started_epoch))
        __emit('S2_END', tostring(second.season_ends_epoch))
    """, convars={"industry_season_seconds": "1"})

    assert out["INIT"] == TRUE, "Initialize 失败"
    assert out["INIT_UNCHANGED"] == TRUE, "重启把已运行季节的边界重算了"
    assert out["ROLL1"] == "true:nil:summer", f"第一次 Tick 没有只滚一格：{out}"
    assert out["S1_SEASON_NO"] == "2"
    assert out["S1_CYCLE"] == "3", "周内换季不得改周号"
    assert out["S1_START"] == "1000", "新季节必须从旧季节的计划结束时间开始（补推）"
    assert out["S1_END"] == "1001", "新季节长度必须按配置算，不按 now 重算"
    assert out["ROLL2"] == "true:nil:autumn", "第二次 Tick 没有继续补推下一格"
    assert out["S2_SEASON_NO"] == "3"
    assert out["S2_START"] == "1001"
    assert out["S2_END"] == "1002"
    print({key: out[key] for key in (
        "INIT", "INIT_UNCHANGED", "ROLL1", "S1_SEASON_NO", "S1_CYCLE",
        "S1_START", "S1_END", "ROLL2", "S2_SEASON_NO", "S2_START", "S2_END")})


def test_initialize_upgrades_single_clock_state_to_two_clocks_once():
    """迁移后首次启动：旧 phase 接上 season，已有 phase 边界原样保留。"""
    out = run(TWO_CLOCK_HARNESS + """
        __reset()
        __seedState({
            cycle_no = 3, phase = 'maturity', started_epoch = 4000, ends_epoch = 5000,
            settled_cycle_no = 2, result_announced_cycle = 1,
        })

        local ok, err = IndustryCycle.Initialize(4500)
        local state = __stateRow()
        __emit('OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('SEASON', state.season)
        __emit('SEASON_NO', tostring(state.season_no))
        __emit('STARTED', tostring(state.season_started_epoch))
        __emit('ENDS', tostring(state.season_ends_epoch))
        __emit('QUARTER', tostring(state.quarter_no))
        __emit('QUARTER_END', tostring(state.quarter_ends_epoch))
        -- 旧 cycle 水位不能带进新季度：否则 quarter_no=1 会被旧 settled=2 直接跳过。
        __emit('SETTLED_RESET', tostring(state.settled_cycle_no))
        __emit('ANNOUNCED_RESET', tostring(state.result_announced_cycle))

        IndustryCycle.Initialize(4600)
        __emit('ENDS_AGAIN', tostring(__stateRow().season_ends_epoch))
    """, convars={"industry_season_seconds": "1"})

    assert out["OK"] == "true:nil", f"旧单时钟状态接不上两时钟：{out}"
    assert out["SEASON"] == "autumn", "maturity 应映射到 autumn"
    assert out["SEASON_NO"] == "3"
    assert out["STARTED"] == "4000", "已有 phase 开始时间不能被重算"
    assert out["ENDS"] == "5000", "已有 phase 结束时间不能被重算"
    assert out["QUARTER"] == "1", "cycle_no=3 → 第 1 季度第 3 周"
    # 第 3 周剩 winter（1 秒）+ 第 4..13 周（40 秒）= 41 秒。
    assert out["QUARTER_END"] == "5041"
    assert out["SETTLED_RESET"] == "0", "旧 cycle 的 settled 水位带进了新季度"
    assert out["ANNOUNCED_RESET"] == "0", "旧 cycle 的公告水位带进了新季度"
    assert out["ENDS_AGAIN"] == "5000", "第二次 Initialize 又重写了边界"
    print({key: out[key] for key in (
        "OK", "SEASON", "SEASON_NO", "STARTED", "ENDS", "QUARTER",
        "QUARTER_END", "SETTLED_RESET", "ANNOUNCED_RESET", "ENDS_AGAIN")})
