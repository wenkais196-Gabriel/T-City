-- tests/unit/layer3_business/fixtures/crypto_client_sync_probe.lua
-- 只抽取 qb-crypto 客户端里 `SyncReboot` / `GetRebootState` 两个 handler，
-- 放进沙箱里跑，验证「服务端广播 state=false 时客户端必须把本地状态清零」。
-- （整个 client/main.lua 依赖大量 FiveM 原生，无法整体加载，所以按 handler 抽取。）

local CLIENT = arg[1] or error('need client/main.lua path')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local source = assert(io.open(CLIENT, 'r')):read('a')

-- 按名字抽取 `RegisterNetEvent('name', function ... end)` 的整段（括号配对）
local function extract(name)
    -- 名字里有 `-`（`qb-crypto`）：在 Lua 模式里 `-` 是惰性量词，必须转义
    local escaped = name:gsub('([%-%.%%%(%)%[%]%*%+%?%^%$])', '%%%1')
    local start = source:find("RegisterNetEvent%s*%(%s*['\"]" .. escaped .. "['\"]", 1)
    if not start then return nil end
    local index = start
    local depth = 0
    local started = false
    while index <= #source do
        local char = source:sub(index, index)
        if char == '(' then
            depth = depth + 1
            started = true
        elseif char == ')' then
            depth = depth - 1
            if started and depth == 0 then
                return source:sub(start, index)
            end
        end
        index = index + 1
    end
    return nil
end

local state = { cooldownStarted = 0, rebootsStarted = 0 }

-- 被 load 的 handler 只能看到全局，所以这些 mock 也必须是全局
Crypto = { Exchange = { RebootInfo = { state = false, percentage = 0 } } }
SystemCrashCooldown = function() state.cooldownStarted = state.cooldownStarted + 1 end
TriggerServerEvent = function() end
TriggerClientEvent = function() end
CreateThread = function() end
Wait = function() end

local handlers = {}
-- load() 用的是全局环境，handler 必须能看见全局 RegisterNetEvent
RegisterNetEvent = function(name, fn) handlers[name] = fn end

local function loadHandler(name)
    local chunk = extract(name)
    assert(chunk, 'client 里找不到 handler: ' .. name)
    local fn, loadErr = load(chunk, '@client-' .. name)
    assert(fn, tostring(loadErr))
    local ok, runErr = pcall(fn)
    assert(ok, '加载 handler 失败: ' .. tostring(runErr))
    assert(handlers[name], 'handler 未注册: ' .. name)
    return handlers[name]
end

local syncReboot = loadHandler('qb-crypto:client:SyncReboot')
local getRebootState = loadHandler('qb-crypto:client:GetRebootState')

-- ── 1. 服务端广播 state=false（owner 收尾）→ 本地必须清零，且不启动重启循环 ──
Crypto.Exchange.RebootInfo.state = true
Crypto.Exchange.RebootInfo.percentage = 42
local cooldownBefore = state.cooldownStarted
syncReboot(false, 0)
emit('STATE_AFTER_FALSE_SYNC', tostring(Crypto.Exchange.RebootInfo.state))
emit('PCT_AFTER_FALSE_SYNC', tostring(Crypto.Exchange.RebootInfo.percentage))
emit('COOLDOWN_STARTED_AFTER_FALSE', tostring(state.cooldownStarted - cooldownBefore))

-- ── 2. 广播 state=true（开始/进行中）→ 本地置 true 并启动循环一次 ──
cooldownBefore = state.cooldownStarted
syncReboot(true, 10)
emit('STATE_AFTER_TRUE_SYNC', tostring(Crypto.Exchange.RebootInfo.state))
emit('COOLDOWN_STARTED_AFTER_TRUE', tostring(state.cooldownStarted - cooldownBefore))

-- ── 3. 首次同步 GetRebootState：false 也要落地（原来只在 true 时赋值） ──
Crypto.Exchange.RebootInfo.state = true
getRebootState({ state = false, percentage = 0 })
emit('STATE_AFTER_FALSE_GET', tostring(Crypto.Exchange.RebootInfo.state))

getRebootState({ state = true, percentage = 55 })
emit('STATE_AFTER_TRUE_GET', tostring(Crypto.Exchange.RebootInfo.state))
emit('PCT_AFTER_TRUE_GET', tostring(Crypto.Exchange.RebootInfo.percentage))

io.write(table.concat(OUT, '\n'), '\n')
