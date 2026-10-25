-- server/core/diag.lua — 四段往返诊断（服务端侧，唯一事实源）。
--
-- 客户端批次只说明"客户端看到了什么"；SR/SD 两槽只能由服务端自己写。
-- 判定优先级（设计 §5.2，最容易写错的一条）：
--   1) 内存环里没有该 tid              → seg2  no-server-recv
--   2) 有 tid 但没有 doneAt            → seg3-produce server-no-reply
--   3) 之后才允许看客户端/NUI 批次推断其余段
--
-- 依据: docs/client/research/client-observability-design.md §2/§4/§5/§6/§9.2
-- 约定:
--   * 永不回包：诊断通道不构成新的 RPC 面；
--   * 客户端 payload 一律不可信，先 Sanitize 再落日志；
--   * 打印有全局预算，超预算只加 dropped 计数，绝不无限刷；
--   * phone_diag=0 时 handler 首行 return（零日志、零开销）。
-- [phone-diag-server] begin (extracted by test_phone_diag_protocol.py)

PhoneDiag = PhoneDiag or {}

PhoneDiag.PROTOCOL = 1
PhoneDiag.RING_SIZE = 128
PhoneDiag.RING_TTL = 60
PhoneDiag.TRACE_PER_MIN = 20
PhoneDiag.TRACE_BURST = 5
PhoneDiag.UI_COOLDOWN_MS = 5000
PhoneDiag.PRINT_BUDGET_PER_SEC = 50

local SLOT_ORDER = { 'NS', 'CR', 'CF', 'SR', 'SD', 'CP', 'CA', 'ND' }
local PHASE_SLOT = {
    ['req.nui.send'] = 'NS',
    ['req.cli.recv'] = 'CR',
    ['req.cli.fwd'] = 'CF',
    ['req.srv.recv'] = 'SR',
    ['req.srv.done'] = 'SD',
    ['req.cli.resp'] = 'CP',
    ['req.cli.answer'] = 'CA',
    ['req.nui.done'] = 'ND',
}
local UI_PHASES = {
    ['ui.close-start'] = true, ['ui.close'] = true,
    ['ui.open-start'] = true, ['ui.open-nui-sent'] = true,
    ['ui.open-ack'] = true, ['ui.open-ack-timeout'] = true,
    ['ui.anim-timeout'] = true, ['ui.reassert'] = true,
    ['ui.loop-exit'] = true, ['ui.phonefix'] = true,
    ['ui.probe-start'] = true, ['ui.probe'] = true, ['ui.probe-end'] = true,
}

local LEVEL_CACHE_MS = 5000
local levelCache = { value = nil, at = 0 }
local ring = {}        -- ['src|tid'] = { src, tid, kind, recvAt, doneAt, code }
local ringCount = 0
local ringSeq = 0
local uiAt = {}        -- ['phase|src'] = ms
local counters = { traces = 0, slow = 0, fail = 0, dropped = 0, breaks = {}, lastBreak = nil }
local printWindow = { second = nil, count = 0 }

local function nowMs()
    if type(GetGameTimer) == 'function' then return GetGameTimer() end
    return math.floor(os.clock() * 1000)
end

--- 0|1|2，convar 缓存 5s。
---@return integer
function PhoneDiag.Level()
    local stamp = nowMs()
    if levelCache.value ~= nil and stamp - levelCache.at < LEVEL_CACHE_MS then
        return levelCache.value
    end
    -- 默认 1（开启）。注意不能用 GetConvarInt 判断"有没有设"：convar 未定义时
    -- 它返回 0，会把"没配置"误判成"显式关闭"，整条 trace 静默失效。
    local value = 1
    local raw
    if type(GetConvar) == 'function' then
        raw = GetConvar('phone_diag')
    end
    if type(raw) == 'string' and raw ~= '' then
        local parsed = tonumber(raw)
        if parsed then value = parsed end
    end
    if value < 0 then value = 0 elseif value > 2 then value = 2 end
    levelCache.value = value
    levelCache.at = stamp
    return value
end

local function cleanString(value, maxLength, pattern)
    if type(value) ~= 'string' or value == '' then return nil end
    if #value > maxLength then value = value:sub(1, maxLength) end
    if pattern and not value:match(pattern) then return nil end
    return value
end

local function validTraceId(value)
    if type(value) ~= 'string' or #value < 3 or #value > 64 then return nil end
    if not value:match('^[%w%-_%.:]+$') then return nil end
    return value
end

--- 白名单投影：未知字段一律丢弃。客户端已脱敏过不算数，这里重做一遍。
---@param msg table|nil
---@return table
function PhoneDiag.Sanitize(msg)
    if type(msg) ~= 'table' then return {} end
    local out = { mode = msg.mode == 'trace' and 'trace' or 'event' }
    out.tid = validTraceId(msg.tid)
    if out.mode == 'trace' then
        out.kind = cleanString(msg.kind, 12, '^%a+$')
        out.app = cleanString(msg.app, 32, '^[%w%_%-]+$')
        out.code = cleanString(msg.code, 32, '^[%w%_%-]+$')
        out.dur = math.floor(tonumber(msg.dur) or 0)
        if out.dur < 0 then out.dur = 0 end
        out.answered = msg.answered == true
        out.overflow = msg.overflow == true
        out.phases = {}
        if type(msg.phases) == 'table' then
            for index = 1, math.min(#msg.phases, 8) do
                local mark = msg.phases[index]
                if type(mark) == 'table' then
                    local order = tonumber(mark[1])
                    if order and order >= 1 and order <= 8 then
                        out.phases[#out.phases + 1] = {
                            math.floor(order),
                            math.max(0, math.floor(tonumber(mark[2]) or 0)),
                            cleanString(mark[3], 32, '^[%w%_%-]+$'),
                        }
                    end
                end
            end
        end
    else
        local phase = cleanString(msg.phase, 32)
        out.phase = phase and UI_PHASES[phase] and phase or nil
        out.attempt = math.floor(tonumber(msg.attempt) or 0)
        out.focused = msg.focused == true
        out.keepInput = msg.keepInput == true
        out.owner = cleanString(msg.owner, 16, '^[%w%-_]+$')
    end
    return out
end

local function allowTrace(src)
    local limiter = PhoneRateLimit
    if type(limiter) == 'table' and type(limiter.Allow) == 'function' then
        return limiter.Allow(('diag:%s'):format(tostring(src)), PhoneDiag.TRACE_PER_MIN, PhoneDiag.TRACE_BURST)
    end
    return true
end

local function allowUi(src, phase)
    local key = ('%s|%s'):format(phase, tostring(src))
    local stamp = nowMs()
    if uiAt[key] and stamp - uiAt[key] < PhoneDiag.UI_COOLDOWN_MS then return false end
    uiAt[key] = stamp
    return true
end

local function printBudgetOk()
    local second = math.floor(nowMs() / 1000)
    if printWindow.second ~= second then
        printWindow.second = second
        printWindow.count = 0
    end
    if printWindow.count >= PhoneDiag.PRINT_BUDGET_PER_SEC then
        counters.dropped = counters.dropped + 1
        return false
    end
    printWindow.count = printWindow.count + 1
    return true
end

local function ringKey(src, tid)
    return ('%s|%s'):format(tostring(src), tostring(tid))
end

local function sweepRing(stamp)
    if ringCount <= PhoneDiag.RING_SIZE then
        for key, entry in pairs(ring) do
            if entry.recvAt and stamp - entry.recvAt > PhoneDiag.RING_TTL * 1000 then
                ring[key] = nil
                ringCount = ringCount - 1
            end
        end
        return
    end
    -- 超出容量：丢掉最老的记录（按 recvAt）。
    local oldestKey, oldestAt = nil, math.huge
    for key, entry in pairs(ring) do
        if entry.recvAt and entry.recvAt < oldestAt then oldestKey, oldestAt = key, entry.recvAt end
    end
    if oldestKey then
        ring[oldestKey] = nil
        ringCount = ringCount - 1
    end
end

--- handler 第一行调用：写入内存环，供后续批次合并（SR 的唯一来源）。
---@param src number
---@param tid string|nil
---@param kind string
---@return boolean
function PhoneDiag.RecordRecv(src, tid, kind)
    if PhoneDiag.Level() == 0 then return false end
    tid = validTraceId(tostring(tid or ''))
    if not tid then return false end
    local stamp = nowMs()
    local key = ringKey(src, tid)
    if not ring[key] then
        ringCount = ringCount + 1
        ringSeq = ringSeq + 1
    end
    ring[key] = {
        src = src,
        tid = tid,
        kind = cleanString(kind, 12) or 'query',
        recvAt = stamp,
        seq = ringSeq,
    }
    sweepRing(stamp)
    return true
end

--- replyAppRequest 之前调用：补写 doneAt/code（SD 的唯一来源）。
---@param src number
---@param tid string|nil
---@param code string
function PhoneDiag.RecordDone(src, tid, code)
    if PhoneDiag.Level() == 0 then return end
    local entry = ring[ringKey(src, tid)]
    if not entry then return end
    entry.doneAt = nowMs()
    entry.code = cleanString(code, 32)
end

--- 按设计 §5.1 判定断点；返回 segment, reason（无断点返回 nil）。
---@param slots table { NS=,CR=,CF=,SR=,SD=,CP=,CA=,ND= }
---@param entry table|nil 内存环记录（SR/SD 的权威来源）
---@return string|nil segment
---@return string|nil reason
function PhoneDiag.Verdict(slots, entry)
    -- 1) 服务端环是 SR/SD 的唯一事实来源：客户端自述一律忽略。
    if not entry then return 'seg2', 'no-server-recv' end
    if not entry.doneAt then return 'seg3-produce', 'server-no-reply' end

    slots = slots or {}
    if not slots.CR and slots.NS then return 'seg1', 'nui-fetch-lost' end
    if slots.CR and not slots.CF then return 'seg1.5', 'handler-abort' end
    if slots.CF and not entry.recvAt then return 'seg2', 'no-server-recv' end
    if entry.recvAt and not entry.doneAt then return 'seg3-produce', 'server-no-reply' end
    if entry.doneAt and not slots.CP then return 'seg3-deliver', 'response-lost' end
    if slots.CP and not slots.CA then return 'seg3.5', 'answered-locally' end
    if slots.CA and not slots.ND then return 'seg4', 'nui-never-settled' end
    return nil, nil
end

local function pathString(slots)
    local parts = {}
    for index = 1, #SLOT_ORDER do
        local slot = SLOT_ORDER[index]
        parts[index] = slots[slot] and slot or '.'
    end
    return table.concat(parts, '|')
end

local function slotsFromBatch(batch, entry)
    local slots = { SR = entry and entry.recvAt or nil, SD = entry and entry.doneAt or nil }
    for _, mark in ipairs(batch.phases or {}) do
        local slot = PHASE_SLOT[({
            'req.nui.send', 'req.cli.recv', 'req.cli.fwd', 'req.srv.recv',
            'req.srv.done', 'req.cli.resp', 'req.cli.answer', 'req.nui.done',
        })[mark[1]]]
        if slot then slots[slot] = true end
    end
    return slots
end

local function deltaString(batch)
    local parts = {}
    for _, mark in ipairs(batch.phases or {}) do
        parts[#parts + 1] = tostring(mark[2])
    end
    return #parts > 0 and table.concat(parts, ',') or '-'
end

--- 唯一入口：校验 → 限流 → 合并内存环 → 打印。永不回包。
---@param src number
---@param msg table 客户端原始 payload（不可信）
---@return boolean accepted
function PhoneDiag.Accept(src, msg)
    if PhoneDiag.Level() == 0 then return false end
    local batch = PhoneDiag.Sanitize(msg)

    if batch.mode == 'trace' then
        if not batch.tid then return false end
        if not allowTrace(src) then
            counters.dropped = counters.dropped + 1
            return false
        end
        local entry = ring[ringKey(src, batch.tid)]
        local slots = slotsFromBatch(batch, entry)
        local segment, reason = PhoneDiag.Verdict(slots, entry)

        counters.traces = counters.traces + 1
        if (batch.dur or 0) >= 400 then counters.slow = counters.slow + 1 end
        if batch.code and batch.code ~= 'ok' then counters.fail = counters.fail + 1 end
        if segment then
            counters.breaks[segment] = (counters.breaks[segment] or 0) + 1
            counters.lastBreak = ('%s/%s'):format(segment, tostring(reason))
        end

        if not printBudgetOk() then return true end
        local why = segment and 'fail' or ((batch.dur or 0) >= 400 and 'slow' or 'ok')
        print(('[custom-phone][diag] src=%s tid=%s kind=%s app=%s code=%s why=%s path=%s break=%s%s dt=%s'):format(
            tostring(src), batch.tid, tostring(batch.kind or '-'), tostring(batch.app or '-'),
            tostring(batch.code or '-'), why, pathString(slots),
            tostring(segment or 'none'),
            reason and (' reason=' .. reason) or '',
            deltaString(batch)))
        return true
    end

    -- ui 域：等价旧 focusState 的单点事件（按 (phase, src) 5s 冷却）。
    if not batch.phase then return false end
    if not allowUi(src, batch.phase) then
        counters.dropped = counters.dropped + 1
        return false
    end
    if not printBudgetOk() then return true end
    print(('[custom-phone][diag] src=%s phase=%s attempt=%d focused=%s keepInput=%s%s'):format(
        tostring(src), batch.phase, batch.attempt or 0,
        tostring(batch.focused == true), tostring(batch.keepInput == true),
        batch.owner and (' owner=' .. batch.owner) or ''))
    return true
end

--- 旧通道 shim：与今天的 focusState handler 逐字段等价（迁移期用）。
---@param src number
---@param state table { phase, attempt, focused, keepInput, owner }
function PhoneDiag.LegacyFocus(src, state)
    if type(state) ~= 'table' then return end
    local phase = state.phase
    if type(phase) ~= 'string' then return end
    -- 旧通道只认 ui 域（去掉前缀比较），防止把 req.* 塞进来绕过 trace 限流。
    local uiPhase = phase:match('^ui%.') and phase or ('ui.' .. phase)
    if not UI_PHASES[uiPhase] then return end
    if PhoneDiag.Level() == 0 then
        -- level=0 时旧通道仍按历史行为工作：它的开关是它自己的限流器。
    end
    if not allowUi(src, uiPhase) then return end
    print(('[custom-phone][focus] src=%s phase=%s attempt=%d focused=%s keepInput=%s'):format(
        tostring(src), tostring(phase), math.floor(tonumber(state.attempt) or 0),
        tostring(state.focused == true), tostring(state.keepInput == true)))
end

--- /phonedoctor 用：按 src 汇总 counters。
---@param src number|nil nil = 全服
---@return table
function PhoneDiag.Summary(src)
    local result = {
        traces = counters.traces,
        slow = counters.slow,
        fail = counters.fail,
        dropped = counters.dropped,
        lastBreak = counters.lastBreak,
        ring = ringCount,
    }
    if src ~= nil then
        local mine = 0
        for _, entry in pairs(ring) do
            if tonumber(entry.src) == tonumber(src) then mine = mine + 1 end
        end
        result.ringForSrc = mine
    end
    return result
end

--- 测试与 /phonefix 用：清空全部状态（不触碰 convar）。
function PhoneDiag.Reset()
    ring = {}
    ringCount = 0
    uiAt = {}
    counters = { traces = 0, slow = 0, fail = 0, dropped = 0, breaks = {}, lastBreak = nil }
    printWindow = { second = nil, count = 0 }
    levelCache = { value = nil, at = 0 }
end

-- 自注册传输：模块自己拥有它的事件面，main.lua 不需要再写 wiring。
if type(RegisterNetEvent) == 'function' then
    RegisterNetEvent('phone:server:diag', function(msg)
        -- Accept 内部再做一遍 Sanitize 白名单 + trace 令牌桶 + ui COOLDOWN 限流。
        if type(msg) ~= 'table' then return end
        PhoneDiag.Accept(source, msg)
    end)
end

-- [phone-diag-server] end
