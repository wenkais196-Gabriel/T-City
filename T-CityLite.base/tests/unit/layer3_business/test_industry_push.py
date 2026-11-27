"""W2 #389：产业周期公告的手机推送（警告 + 结果）。

钉住的事：

1. **只推在线组织成员**：`QBCore.Functions.GetQBPlayers()` 里属于
   `Config.Industry.OrgWhitelist` 的玩家各收一条；非成员不收。离线成员根本不在
   `GetQBPlayers()` 里——他们靠 CityFeed 的历史公告补看，本片不伪造离线推送。
2. **同一周期只推一次**：推送没有自己的水位，挂在 cycle.lua 既有的
   `warning_announced_at` / `result_announced_cycle` 水位之后。
3. **`industry_enable=false` → 0 条**：整套产业关闭时推送也必须安静。
4. **推送失败不阻断结算**：`Notify` 抛错只打日志；警告公告、结算、进入下一轮照常完成。
5. **深链与 PII**：`app_id` 固定 `industry`（`NOTIFY_APP_IDS` 必须放行，否则落库成
   NULL、点通知没有落点）；标题/正文只含周期号、组织名、金额、时间，不含 citizenid。

反向注入：删掉 `cycle.lua` `maybeWarn` 的 `if state.warning_done then return end`
→ `test_repeated_tick_in_the_same_cycle_pushes_nothing_more` 必须红；还原 → 绿。
"""

from __future__ import annotations

from pathlib import Path

from industry_harness import BASE, TRUE, run_full as run

PHONE = BASE / "resources" / "[custom]" / "custom-phone"
NOTIFY = PHONE / "server" / "core" / "notify.lua"

#: 推送接线：把全局 `exports` 换成「假的 qb-core + 能记账的 custom-phone Notify」。
#: `GetQBPlayers` 故意做成**可调用表**——本 build 的跨资源导出就是这种形状
#: （`type(fn) == 'table'`），用它证明实现里没有 `type(...) == 'function'` 的恒假守卫。
PUSH_WIRING = """
local __notifications = {}
local __pushMode = 'ok'      -- 'ok' | 'throw' | 'false'
local __baseExports = exports

local __core = {
    Functions = {
        GetQBPlayers = setmetatable({}, {
            __call = function() return __testPlayers or {} end,
        }),
    },
}

local __phone = {
    Notify = function(_, citizenid, title, content, appId, meta)
        if __pushMode == 'throw' then error('probe: notify exploded') end
        if __pushMode == 'false' then return false end
        __notifications[#__notifications + 1] = {
            citizenid = tostring(citizenid),
            title = tostring(title),
            content = tostring(content),
            app_id = tostring(appId),
            source = meta and tonumber(meta.source) or nil,
        }
        return true
    end,
    PostCityBulletin = __baseExports['custom-phone'].PostCityBulletin,
}

exports = setmetatable({}, {
    __index = function(_, resource)
        if resource == 'qb-core' then
            return { GetCoreObject = function() return __core end }
        end
        if resource == 'custom-phone' then return __phone end
        return __baseExports[resource]
    end,
})

function __pushCount() return #__notifications end

function __pushLog()
    local parts = {}
    for _, item in ipairs(__notifications) do
        parts[#parts + 1] = table.concat({
            item.citizenid, item.title, item.content, item.app_id,
            tostring(item.source or 'nil'),
        }, '|')
    end
    return table.concat(parts, ';;')
end
"""

#: 2 个 mining_co（job = miner）成员 + 1 个警察（非白名单组织，是「非成员」对照）。
#: source 故意与下标错开，证明推送用的是 PlayerData.source 而不是遍历下标。
TWO_MINERS_ONE_OFFICER = """
__testPlayers = {
    [1] = { PlayerData = {
        source = 1, citizenid = 'cid-miner-a',
        job = { name = 'miner', label = '矿业', grade = { level = 1, name = '矿工' } },
    } },
    [3] = { PlayerData = {
        source = 3, citizenid = 'cid-miner-b',
        job = { name = 'miner', label = '矿业', grade = { level = 2, name = '工头' } },
    } },
    [2] = { PlayerData = {
        source = 2, citizenid = 'cid-officer',
        job = { name = 'police', label = '警察', grade = { level = 4, name = 'Chief' } },
    } },
}
"""

#: 压缩周期：60 秒/阶段，提前量 60 秒，公告重试冷却 1 秒。
DEFAULT_CONVARS = {
    "industry_enable": "true",
    "industry_phase_seconds": "60",
    "industry_cycle_warn_seconds": "60",
    "industry_cycle_retry_seconds": "1",
}


def run_push(
    body: str,
    players: str = TWO_MINERS_ONE_OFFICER,
    convars: dict[str, str] | None = None,
) -> dict[str, str]:
    values = dict(DEFAULT_CONVARS)
    values.update(convars or {})
    return run(PUSH_WIRING + "\n" + players + "\n" + body, convars=values)


def _records(out: dict[str, str]) -> list[list[str]]:
    """`citizenid|title|content|app_id|source` 记录列表。"""
    raw = out.get("PUSHES", "")
    if not raw:
        return []
    return [record.split("|") for record in raw.split(";;")]


# ══════════════════════════════════════════════════════════════════
# 1. 只推在线组织成员：2 个成员 + 1 个非成员 → 恰好 2 条
# ══════════════════════════════════════════════════════════════════


def test_warning_pushes_exactly_the_online_org_members():
    out = run_push("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'recession', started_epoch = 0, ends_epoch = 1000 })

        IndustryCycle.Tick(950)  -- 进入结算前提前量：warning

        __emit('PUSH_COUNT', tostring(__pushCount()))
        __emit('BULLETINS', tostring(__bulletinCount()))
        __emit('PUSHES', __pushLog())
    """)

    assert out["BULLETINS"] == "1", "结算前 CityFeed 公告没有发出，推送用例失去意义"
    assert out["PUSH_COUNT"] == "2", f"2 个成员应各收一条，实际：{out['PUSHES']}"

    records = _records(out)
    # GetQBPlayers() 返回的是按 source 为键的哈希表，pairs 顺序不保证；只比集合。
    assert sorted(record[0] for record in records) == ["cid-miner-a", "cid-miner-b"], records
    assert all("cid-officer" not in record[0] for record in records), "非成员收到了产业推送"
    # meta.source 来自 PlayerData.source，不是遍历下标。
    assert sorted(record[4] for record in records) == ["1", "3"], records


# ══════════════════════════════════════════════════════════════════
# 2. 同一周期只推一次：重复 tick 不得再推（既有水位有效）
# ══════════════════════════════════════════════════════════════════


def test_repeated_tick_in_the_same_cycle_pushes_nothing_more():
    out = run_push("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'recession', started_epoch = 0, ends_epoch = 1000 })

        IndustryCycle.Tick(950)  -- warning：2 条
        __emit('AFTER_WARN', tostring(__pushCount()))

        -- 重试冷却 1 秒，960/970 已经越过节流；仍不得再发，因为水位已写。
        IndustryCycle.Tick(960)
        IndustryCycle.Tick(970)
        __emit('AFTER_REPEAT', tostring(__pushCount()))
        __emit('BULLETINS', tostring(__bulletinCount()))
    """)

    assert out["AFTER_WARN"] == "2", f"首次警告没有推送：{out}"
    assert out["AFTER_REPEAT"] == "2", (
        f"同一周期重复 tick 又推了一次，水位失效：{out['AFTER_REPEAT']}"
    )
    assert out["BULLETINS"] == "1", "CityFeed 公告重复发送"


# ══════════════════════════════════════════════════════════════════
# 3. industry_enable=false → 0 条
# ══════════════════════════════════════════════════════════════════


def test_disabled_industry_pushes_nothing():
    out = run_push("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'recession', started_epoch = 0, ends_epoch = 1000 })

        IndustryCycle.Tick(950)

        __emit('PUSH_COUNT', tostring(__pushCount()))
        __emit('BULLETINS', tostring(__bulletinCount()))
    """, convars={"industry_enable": "false"})

    # 公告本身仍发出（真机上关闭时 cycle 根本不会 tick；这里证明推送是唯一被关掉的东西）。
    assert out["BULLETINS"] == "1", "用例没有走到 warning 发布路径，0 条推送不说明问题"
    assert out["PUSH_COUNT"] == "0", f"industry_enable=false 仍然推送：{out['PUSHES']}"


# ══════════════════════════════════════════════════════════════════
# 4. 推送抛错不阻断公告 / 结算：结算照常完成并进入下一轮
# ══════════════════════════════════════════════════════════════════


def test_push_failure_never_blocks_the_bulletin_or_settlement():
    out = run_push("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'recession', started_epoch = 0, ends_epoch = 1000 })
        __pushMode = 'throw'  -- Notify 每次调用都抛错

        local warned = IndustryCycle.Tick(950)
        __emit('WARN_OK', tostring(warned))

        local ok, err = IndustryCycle.Tick(1000)  -- 衰退结束：结算 + 结果公告 + 下一轮
        __emit('SETTLE_OK', tostring(ok) .. ':' .. tostring(err or 'nil'))

        local state = __stateRow()
        __emit('PHASE', state.phase)
        __emit('CYCLE', tostring(state.cycle_no))
        __emit('SETTLED', tostring(state.settled_cycle_no))
        __emit('PUSH_COUNT', tostring(__pushCount()))
        __emit('BULLETINS', tostring(__bulletinCount()))
    """)

    assert out["WARN_OK"] == TRUE, "推送抛错让 warning 公告报告失败"
    assert out["SETTLE_OK"] == "true:nil", f"推送抛错阻断了结算：{out}"
    assert out["PHASE"] == "expansion", "结算后没有进入下一轮扩张期"
    assert out["CYCLE"] == "2"
    assert out["SETTLED"] == "1", "结算水位没有推进"
    assert out["PUSH_COUNT"] == "0", "抛错的 Notify 被当成了成功推送"
    assert out["BULLETINS"] == "2", "推送失败连 warning/result 两条 CityFeed 都吞掉了"


# ══════════════════════════════════════════════════════════════════
# 5. 深链参数与 PII：app_id = industry，正文不含 citizenid
# ══════════════════════════════════════════════════════════════════


def test_push_deeplinks_to_industry_without_pii():
    out = run_push("""
        __reset()
        __seedState({ cycle_no = 7, phase = 'recession', started_epoch = 0, ends_epoch = 1000 })

        IndustryCycle.Tick(950)
        __emit('PUSHES', __pushLog())
    """)

    records = _records(out)
    assert len(records) == 2, f"期望 2 条推送：{out['PUSHES']}"
    for citizenid, title, content, app_id, _source in records:
        assert app_id == "industry", f"app_id 不是 industry：{title}"
        assert citizenid not in title and citizenid not in content, (
            f"通知标题/正文泄露了 citizenid：{title} / {content}"
        )
        assert "cid-miner" not in title and "cid-miner" not in content, (
            f"通知标题/正文泄露了工号：{title} / {content}"
        )
        assert "#7" in title, f"标题没有周期号：{title}"
        assert "产业周期 #7" in content, f"正文没有周期号：{content}"


def test_notify_app_allowlist_accepts_industry():
    """`NOTIFY_APP_IDS` 不放行 industry 时 app_id 会落成 NULL，通知就没有深链。"""
    source = NOTIFY.read_text(encoding="utf-8")
    start = source.index("local NOTIFY_APP_IDS")
    block = source[start:source.index("}", start)]
    assert "industry = true" in block, "NOTIFY_APP_IDS 没有放行 industry"


# ══════════════════════════════════════════════════════════════════
# 6. 结果公告同样只推在线成员，且同一周期一次
# ══════════════════════════════════════════════════════════════════


def test_result_push_reaches_online_members_once():
    out = run_push("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'recession', started_epoch = 0, ends_epoch = 1000 })

        IndustryCycle.Tick(950)   -- warning：2 条
        IndustryCycle.Tick(1000)  -- 结算 + 结果公告：再 2 条
        IndustryCycle.Tick(1001)  -- 已公告水位：不得再推

        __emit('TOTAL', tostring(__pushCount()))
        __emit('PUSHES', __pushLog())
    """)

    assert out["TOTAL"] == "4", f"警告 2 + 结果 2，实际：{out['PUSHES']}"
    records = _records(out)
    result_titles = [
        record[1] for record in records
        if record[1].startswith("产业周期 #1 已结算")
    ]
    assert len(result_titles) == 2, f"结果推送条数不对：{result_titles}"
    assert all(record[0] != "cid-officer" for record in records), "非成员收到了结果推送"
