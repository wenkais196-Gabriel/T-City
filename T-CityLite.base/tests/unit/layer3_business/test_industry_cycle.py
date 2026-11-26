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

import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

from lua_probe import BASE, DB_ADAPTER

RES = BASE / "resources" / "[custom]" / "custom-industry"
CONFIG_SRC = RES / "config.lua"
FACILITY_CONFIG_SRC = RES / "config" / "facility.lua"
PRODUCTION_CONFIG_SRC = RES / "config" / "production.lua"
SALES_CONFIG_SRC = RES / "config" / "sales.lua"
CYCLE_CONFIG_SRC = RES / "config" / "cycle.lua"
ORG_ID_SRC = RES / "server" / "org_id.lua"
TREASURY_SRC = RES / "server" / "treasury.lua"
AUDIT_SRC = RES / "server" / "audit.lua"
ACCESS_SRC = RES / "server" / "access.lua"
ANNOUNCE_SRC = RES / "server" / "announce.lua"
CYCLE_SRC = RES / "server" / "cycle.lua"
SETTLEMENT_SRC = RES / "server" / "settlement.lua"
FACILITY_SRC = RES / "server" / "facility.lua"
PRODUCTION_SRC = RES / "server" / "production.lua"
SALE_SRC = RES / "server" / "sale.lua"
COMMANDS_CYCLE_SRC = RES / "server" / "commands_cycle.lua"
PROBE = Path(__file__).resolve().parent / "fixtures" / "industry_cycle_probe.lua"

TRUE = "true"
FALSE = "false"
NIL = "nil"


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
        for path in (
            CONFIG_SRC, FACILITY_CONFIG_SRC, PRODUCTION_CONFIG_SRC,
            SALES_CONFIG_SRC, CYCLE_CONFIG_SRC,
        )
    )


def lua_table(values: dict[str, str]) -> str:
    return "{ " + ", ".join(f"{key} = '{value}'" for key, value in values.items()) + " }"


def run(body: str, convars: dict[str, str] | None = None) -> dict[str, str]:
    prelude = f"__convars = {lua_table(convars)}\n" if convars else "__convars = {}\n"
    script = (
        PROBE.read_text(encoding="utf-8")
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
        + ANNOUNCE_SRC.read_text(encoding="utf-8")
        + "\n"
        + CYCLE_SRC.read_text(encoding="utf-8")
        + "\n"
        + SETTLEMENT_SRC.read_text(encoding="utf-8")
        + "\n"
        + FACILITY_SRC.read_text(encoding="utf-8")
        + "\n"
        + PRODUCTION_SRC.read_text(encoding="utf-8")
        + "\n"
        + SALE_SRC.read_text(encoding="utf-8")
        + "\n"
        + COMMANDS_CYCLE_SRC.read_text(encoding="utf-8")
        + "\n"
        + textwrap.dedent(body)
    )
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}\n{proc.stdout}"
    return parse(proc.stdout)


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

    # 10 工位 × 12/h × 600s：扩张 1.25 → 25；衰退 0.70 → 14。
    assert expansion["OK"] == "true:nil", f"扩张期结算失败：{expansion}"
    assert expansion["STOCK"] == "25", f"扩张期产能倍率没生效：{expansion}"
    assert recession["OK"] == "true:nil", f"衰退期结算失败：{recession}"
    assert recession["STOCK"] == "14", f"衰退期产能倍率没生效：{recession}"


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
