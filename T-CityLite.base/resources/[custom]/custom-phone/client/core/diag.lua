-- client/core/diag.lua — 四段往返诊断（客户端侧）。
--
-- 一次 NUI→Lua→Server→NUI 的请求断在哪一段，今天只能靠猜：前端只看到
-- `query_failed`/`timeout`，服务端要嘛没日志、要嘛被 per-phase 5s 冷却吞掉。
-- 这里把请求当一条 trace 记录：NUI 在边缘生成 tid（随 payload 的 `_diag` 传下来），
-- 客户端在每个边界记一个 phase，链尾按采样策略一次性上报（不是每个 phase 一条事件）。
--
-- 设计依据: docs/client/research/client-observability-design.md §2/§4/§9.1
-- 约定:
--   * level=0 时 StartTrace 返回 nil，后续 Phase/Finish 全部空转（零分配、零事件）；
--   * 快且成功的请求不上报（除非 level=2 / warmup / 随机采样），避免日志淹没与 tick 抖动；
--   * 本模块不创建任何计时器，也不发起请求。
-- [phone-diag-client] begin (extracted by test_phone_diag_protocol.py)

PhoneDiag = PhoneDiag or {}

PhoneDiag.PROTOCOL = 1
PhoneDiag.MAX_PHASES = 8
PhoneDiag.SLOW_MS = 400
PhoneDiag.WARMUP = 3

-- 8 个请求域 phase：恰好四对，一对对应一段边界（NS↔CR↔CF↔SR↔SD↔CP↔CA↔ND）。
local REQ_PHASES = {
    'req.nui.send',   -- NS  NUI 即将 fetch
    'req.cli.recv',   -- CR  NUI callback 进入
    'req.cli.fwd',    -- CF  即将 TriggerServerEvent
    'req.srv.recv',   -- SR  服务端 handler 进入（服务端权威，客户端只做占位）
    'req.srv.done',   -- SD  服务端即将回包（同上）
    'req.cli.resp',   -- CP  response 命中了 pending 槽
    'req.cli.answer', -- CA  即将调用 NUI cb()
    'req.nui.done',   -- ND  NUI fetch resolve
}

local REQ_PHASE_SET = {}
for index = 1, #REQ_PHASES do REQ_PHASE_SET[REQ_PHASES[index]] = index end

-- ui 域（开/关手机、焦点）—— 语义与旧 focusState 的 phase 一一对应，只加前缀。
local UI_PHASES = {
    'ui.close-start', 'ui.close', 'ui.open-start', 'ui.open-nui-sent',
    'ui.open-ack', 'ui.open-ack-timeout', 'ui.anim-timeout', 'ui.reassert',
    'ui.loop-exit', 'ui.phonefix', 'ui.probe-start', 'ui.probe', 'ui.probe-end',
}
local UI_PHASE_SET = {}
for index = 1, #UI_PHASES do UI_PHASE_SET[UI_PHASES[index]] = true end

local LEVEL_CACHE_MS = 5000
local levelCache = { value = nil, at = 0 }
local tracesSinceStart = 0
local openTraces = 0

--- 单调毫秒。FiveM 里用 GetGameTimer（受 pause 影响但足够），离线 harness 用 os.clock。
---@return number
local function nowMs()
    if type(GetGameTimer) == 'function' then return GetGameTimer() end
    return math.floor(os.clock() * 1000)
end

--- 0|1|2，convar 结果缓存 5s：热路径不做 syscall。
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

--- 读取并剥离 payload 的保留字段 `_diag`，返回 tid 供 request_id 复用。
--- 业务层永远看不到 `_diag`：这是唯一允许就地修改 payload 的地方。
---@param payload table|nil
---@return string|nil
function PhoneDiag.TakeTraceId(payload)
    if type(payload) ~= 'table' then return nil end
    local diag = payload._diag
    payload._diag = nil
    if type(diag) ~= 'table' then return nil end
    return PhoneDiag.ValidTraceId(diag.tid)
end

--- tid 只允许 `[%w%-%_%.:]` 且 3..64 字节（服务端会重新校验一遍）。
---@param tid any
---@return string|nil
function PhoneDiag.ValidTraceId(tid)
    if type(tid) ~= 'string' then return nil end
    if #tid < 3 or #tid > 64 then return nil end
    if not tid:match('^[%w%-_%.:]+$') then return nil end
    return tid
end

--- 开启一条 trace。level=0 返回 nil，调用方后续 Phase/Finish 全部空转。
---@param tid string|nil
---@param kind string 'query'|'action'|'probe'
---@param app string|nil
---@return table|nil
function PhoneDiag.StartTrace(tid, kind, app)
    if PhoneDiag.Level() == 0 then return nil end
    tid = PhoneDiag.ValidTraceId(tid)
    if not tid then return nil end
    if openTraces >= 32 then return nil end -- 防泄漏：调用方忘了 Finish 也不会无限增长
    tracesSinceStart = tracesSinceStart + 1
    openTraces = openTraces + 1
    return {
        tid = tid,
        kind = type(kind) == 'string' and kind:sub(1, 12) or 'query',
        app = type(app) == 'string' and app:sub(1, 32) or nil,
        t0 = nowMs(),
        marks = {},
        overflow = false,
        closed = false,
    }
end

--- 记录一个 phase（不发送）。超过 MAX_PHASES 时丢弃并标记 overflow。
---@param trace table|nil
---@param phase string
---@param code string|nil
---@return boolean
function PhoneDiag.Phase(trace, phase, code)
    if type(trace) ~= 'table' or trace.closed then return false end
    if not REQ_PHASE_SET[phase] then return false end
    if #trace.marks >= PhoneDiag.MAX_PHASES then
        trace.overflow = true
        return false
    end
    local entry = { order = REQ_PHASE_SET[phase], t = nowMs() }
    if type(code) == 'string' and code ~= '' then entry.code = code:sub(1, 32) end
    trace.marks[#trace.marks + 1] = entry
    return true
end

--- 结束 trace，按采样策略决定是否上报（最多 1 条事件）。
---@param trace table|nil
---@param code string|nil 终态码
---@param opts table|nil { answered = boolean }
---@return boolean sent
function PhoneDiag.Finish(trace, code, opts)
    if type(trace) ~= 'table' or trace.closed then return false end
    trace.closed = true
    openTraces = math.max(0, openTraces - 1)

    local level = PhoneDiag.Level()
    if level == 0 then return false end

    local finish = nowMs()
    local duration = math.max(0, finish - trace.t0)
    local finalCode = type(code) == 'string' and code:sub(1, 32) or 'ok'
    local answered = type(opts) == 'table' and opts.answered == true

    -- 采样判据一次性在链尾判断：快且成功的请求默认 0 条日志。
    local slow = duration >= PhoneDiag.SLOW_MS
    local failed = finalCode ~= 'ok'
    local warm = tracesSinceStart <= PhoneDiag.WARMUP
    local send = level >= 2 or slow or failed or warm
    if not send then return false end

    local phases = {}
    for index = 1, #trace.marks do
        local mark = trace.marks[index]
        phases[index] = { mark.order, mark.t - trace.t0, mark.code }
    end

    TriggerServerEvent('phone:server:diag', {
        v = PhoneDiag.PROTOCOL,
        mode = 'trace',
        tid = trace.tid,
        kind = trace.kind,
        app = trace.app,
        code = finalCode,
        answered = answered,
        dur = duration,
        overflow = trace.overflow or nil,
        phases = phases,
    })
    return true
end

--- ui 域单点事件（等价旧 focusState）。限流在服务端按 (phase, src) 5s 做，
--- 客户端不再自建第二套窗口，避免两处状态互相不一致。
---@param phase string 'ui.*'
---@param fields table|nil { attempt, focused, keepInput, owner }
---@return boolean sent
function PhoneDiag.Emit(phase, fields)
    if PhoneDiag.Level() == 0 then return false end
    if type(phase) ~= 'string' or not UI_PHASE_SET[phase] then return false end
    local msg = {
        v = PhoneDiag.PROTOCOL,
        mode = 'event',
        phase = phase,
        t = nowMs(),
    }
    if type(fields) == 'table' then
        msg.attempt = tonumber(fields.attempt)
        msg.focused = fields.focused == true
        msg.keepInput = fields.keepInput == true
        msg.owner = type(fields.owner) == 'string' and fields.owner:sub(1, 16) or nil
    end
    TriggerServerEvent('phone:server:diag', msg)
    return true
end

--- 白名单投影：未知字段一律丢弃，字符串按字符集/长度收敛。
--- 客户端过一遍只是减少带宽，服务端会独立重做（不信任客户端脱敏）。
---@param msg table
---@return table
function PhoneDiag.Sanitize(msg)
    if type(msg) ~= 'table' then return {} end
    local out = { v = PhoneDiag.PROTOCOL, mode = msg.mode == 'trace' and 'trace' or 'event' }
    out.tid = PhoneDiag.ValidTraceId(msg.tid)
    if out.mode == 'trace' then
        out.kind = type(msg.kind) == 'string' and msg.kind:sub(1, 12) or nil
        out.app = type(msg.app) == 'string' and msg.app:sub(1, 32) or nil
        out.code = type(msg.code) == 'string' and msg.code:sub(1, 32) or nil
        out.dur = tonumber(msg.dur) and math.floor(tonumber(msg.dur)) or nil
        out.phases = type(msg.phases) == 'table' and msg.phases or nil
    else
        out.phase = type(msg.phase) == 'string' and msg.phase:sub(1, 32) or nil
        out.attempt = tonumber(msg.attempt)
        out.focused = msg.focused == true
        out.keepInput = msg.keepInput == true
        out.owner = type(msg.owner) == 'string' and msg.owner:sub(1, 16) or nil
    end
    return out
end

--- 服务端/客户端的 request_id 与 trace id 同一个值：这样内存环里的记录能和客户端
--- 批次拼上。没有 NUI 传入的 tid 时用它兜底（阶段 3 的过渡形态）。
---@return string
function PhoneDiag.NewTraceId()
    local stamp = math.floor(nowMs()) % 0xFFFFFFFF
    return ('c%08x%03d'):format(stamp, math.random(0, 999))
end

--- 四段探针 id（NUI 侧发起 phoneProbe 时使用）。
---@return string
function PhoneDiag.NewProbeId()
    local stamp = math.floor(nowMs()) % 0xFFFFFF
    return ('p%06x%s'):format(stamp, tostring(math.random(1000, 9999)))
end

---@return table 只读快照，供 /phonefix 与测试断言
function PhoneDiag.State()
    return {
        level = PhoneDiag.Level(),
        open = openTraces,
        traces = tracesSinceStart,
    }
end

-- [phone-diag-client] end
