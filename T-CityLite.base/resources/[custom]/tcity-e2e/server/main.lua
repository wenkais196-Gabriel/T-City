-- tcity-e2e/server/main.lua
-- 服务端端到端测试 Scenario DSL runner（无客户端）。
--
-- 仅在 convar tcity_e2e=1 时运行；生产环境不加载流程。
-- 启动方式（测试环境 server.cfg）：
--   setr tcity_e2e 1
--   setr tcity_e2e_scenario civilian_ch1   # 可选，默认 civilian_ch1
--   ensure tcity-e2e
--
-- 场景文件：config/scenarios/<name>.json
-- 报告文件：reports/agent-sim-<timestamp>.json（写失败时打印到 console）
--
-- DSL、断言与限制见 README.md。

if GetConvar('tcity_e2e', '0') ~= '1' then
    return
end

local QBCore = exports['qb-core']:GetCoreObject()
local RESOURCE = GetCurrentResourceName()
local SCENARIO_CONVAR = 'tcity_e2e_scenario'
local DEFAULT_SCENARIO = 'civilian_ch1'
local SOURCE_MIN, SOURCE_MAX = 9001, 9100
local MAX_PLAYERS = SOURCE_MAX - SOURCE_MIN + 1
local SUPPORTED_SCHEMA = 1

local results = {}
local players = {}       -- logical cid -> player record
local playerOrder = {}   -- deterministic iteration order
local stepLog = {}
local checkpoints = {}   -- step id -> { money = { [logical cid] = money table } }
local eventRecords = {}  -- event name -> { { args = table.pack(...) }, ... }
local registeredEvents = {}
local scenarioRef = nil
local scenarioName = nil
local cleaned = false
local finished = false
local runStartedAt = os.date('!%Y-%m-%dT%H:%M:%SZ')

-- 运行 ID 用于隔离固定 persona CID：SIM001 -> SIM001_ab12。
-- 注意：live DB 的 players.citizenid 是 VARCHAR(11)，所以 4 位十六进制后缀
-- 保证 `SIM001_ab12` 正好 11 字符（persona cid 最长 6 字符，见 validateScenario）。
-- story-engine 的 arc 完成缓存只在内存中，固定 CID 在同一 server 生命周期内
-- 第二次运行会被一次性门控拒绝；运行级后缀同时避免 DB 残留串数据。
local runId = ('%04x'):format(math.random(0, 65535))
local MAX_RUNTIME_CID_LEN = 11

local function check(name, ok, detail, cid)
    results[#results + 1] = {
        name = name,
        ok = ok and true or false,
        detail = detail ~= nil and tostring(detail) or '',
        cid = cid,
    }
    print(('[E2E] %s | %s | %s'):format(
        ok and 'PASS' or 'FAIL', name, detail ~= nil and tostring(detail) or ''))
end

local function callExport(resourceName, method, ...)
    local args = table.pack(...)
    local proxy = exports[resourceName]
    local fn = proxy[method]
    local callOk, a, b = pcall(function()
        -- 与 exports['res']:method(...) 等价；dot 调用会丢失 self，导致参数错位
        return fn(proxy, table.unpack(args, 1, args.n))
    end)
    if not callOk then
        return false, tostring(a)
    end
    return a, b
end

-- 单返回值 export（例如 PlayerMatchesTags）用这个，避免把返回值当成 (ok, value)
local function callExportBool(resourceName, method, ...)
    local args = table.pack(...)
    local proxy = exports[resourceName]
    local fn = proxy[method]
    local callOk, value = pcall(function()
        return fn(proxy, table.unpack(args, 1, args.n))
    end)
    if not callOk then
        return false, tostring(value)
    end
    return true, value
end

local function waitStarted(res)
    for _ = 1, 60 do
        if GetResourceState(res) == 'started' then return true end
        Wait(500)
    end
    return false
end

local function dbMoney(runtimeCid)
    local callOk, raw = pcall(function()
        return MySQL.scalar.await('SELECT money FROM players WHERE citizenid = ?', { runtimeCid })
    end)
    if not callOk or raw == nil then return nil end
    if type(raw) == 'table' then return raw end
    local ok, decoded = pcall(json.decode, raw)
    if ok and type(decoded) == 'table' then return decoded end
    return nil
end

local function questRow(runtimeCid, questId)
    local callOk, rows = pcall(function()
        return MySQL.query.await(
            'SELECT status,current_step,completion_count FROM player_quests WHERE citizenid = ? AND quest_id = ? ORDER BY id DESC LIMIT 1',
            { runtimeCid, questId })
    end)
    if not callOk or not rows then return nil end
    return rows[1]
end

local function saveAll()
    local any = false
    for _, p in ipairs(playerOrder) do
        if p.qb then
            any = true
            pcall(function() p.qb.Functions.Save(true) end)
        end
    end
    if any then Wait(350) end
end

local function snapshot(id)
    local snap = { money = {} }
    for _, p in ipairs(playerOrder) do
        snap.money[p.logicalCid] = dbMoney(p.runtimeCid)
    end
    checkpoints[id] = snap
end

-- ==============================================================
-- 清理
-- ==============================================================

local CLEANUP_QUERIES = {
    { table = 'player_quests', column = 'citizenid' },
    { table = 'player_choices', column = 'citizenid' },
    { table = 'quest_cooldowns', column = 'citizenid' },
    { table = 'quest_daily_limits', column = 'citizenid' },
    { table = 'players', column = 'citizenid' },
    { table = 'quest_event_log', column = 'citizenid', optional = true },
    { table = 'story_completions', column = 'citizenid', optional = true },
    { table = 'agent_events', column = 'citizenid', optional = true },
}

local function deleteRows(runtimeCid)
    local failures = {}
    for _, q in ipairs(CLEANUP_QUERIES) do
        local ok, err = pcall(function()
            MySQL.query.await(('DELETE FROM %s WHERE %s = ?'):format(q.table, q.column), { runtimeCid })
        end)
        if not ok and not q.optional then
            failures[#failures + 1] = ('%s: %s'):format(q.table, tostring(err))
        end
    end

    -- qb-inventory 的 inventories 主键是 identifier；部分旧库/自定义库用 citizenid。
    -- 只尝试第二个列名，避免正常 schema 下打印无意义的 Unknown column 错误。
    local deletedInventory = pcall(function()
        MySQL.query.await('DELETE FROM inventories WHERE identifier = ?', { runtimeCid })
    end)
    if not deletedInventory then
        deletedInventory = pcall(function()
            MySQL.query.await('DELETE FROM inventories WHERE citizenid = ?', { runtimeCid })
        end)
    end
    if not deletedInventory then
        failures[#failures + 1] = 'inventories: no identifier/citizenid column'
    end

    return #failures == 0, table.concat(failures, '; ')
end

local function countResidue(runtimeCid)
    local total = 0
    -- 只校验需求列出的六张表；quest_event_log / story_completions 会尽力删除，
    -- 但其写入是异步的，不作为硬失败条件，避免偶发竞态误报。
    local tables = {
        'players', 'player_quests', 'player_choices',
        'quest_cooldowns', 'quest_daily_limits',
    }
    for _, tbl in ipairs(tables) do
        local ok, n = pcall(function()
            return MySQL.scalar.await(('SELECT COUNT(*) FROM %s WHERE citizenid = ?'):format(tbl), { runtimeCid })
        end)
        if ok then total = total + (tonumber(n) or 0) end
    end
    for _, column in ipairs({ 'identifier', 'citizenid' }) do
        local ok, n = pcall(function()
            return MySQL.scalar.await(('SELECT COUNT(*) FROM inventories WHERE %s = ?'):format(column), { runtimeCid })
        end)
        if ok then
            total = total + (tonumber(n) or 0)
            break
        end
    end
    return total
end

local function cleanupAll()
    if cleaned then return end
    cleaned = true

    for _, p in ipairs(playerOrder) do
        if p.qb then
            pcall(function() p.qb.Functions.Save(true) end)
        end
        pcall(function() QBCore.Player.Logout(p.source) end)
    end
    if #playerOrder > 0 then Wait(400) end

    for _, p in ipairs(playerOrder) do
        local ok, err = deleteRows(p.runtimeCid)
        local residue = countResidue(p.runtimeCid)
        check(('cleanup.%s'):format(p.logicalCid), ok and residue == 0,
            ('cid=%s residue=%d%s'):format(
                p.runtimeCid, residue, err ~= '' and (' err=' .. err) or ''),
            p.logicalCid)
    end
    if #playerOrder > 0 then
        print('[E2E] cleanup done')
    end
end

-- ==============================================================
-- 场景加载与校验
-- ==============================================================

local function resolveScenarioName()
    local raw = GetConvar(SCENARIO_CONVAR, DEFAULT_SCENARIO) or DEFAULT_SCENARIO
    local name = tostring(raw):gsub('^%s+', ''):gsub('%s+$', '')
    name = name:gsub('%.json$', '')
    if name == '' then
        return nil, ('empty convar %s'):format(SCENARIO_CONVAR)
    end
    if not name:match('^[%w_%-]+$') then
        return nil, ('invalid scenario name %q (allowed: letters, digits, _ and -)'):format(name)
    end
    return name
end

local function loadScenario(name)
    local filename = ('config/scenarios/%s.json'):format(name)
    local content = LoadResourceFile(RESOURCE, filename)
    if not content then
        return nil, ('scenario not found: %s (set convar %s)'):format(filename, SCENARIO_CONVAR)
    end
    local ok, decoded = pcall(json.decode, content)
    if not ok then
        return nil, ('invalid JSON in %s: %s'):format(filename, tostring(decoded))
    end
    if type(decoded) ~= 'table' then
        return nil, ('%s must contain a JSON object'):format(filename)
    end
    return decoded
end

local VALID_ACTIONS = {
    accept_quest = true,
    complete_step = true,
    make_choice = true,
    add_money = true,
    advance_clock = true,
    wait = true,
}

local MAX_CLOCK_SECONDS = 7 * 24 * 60 * 60 -- 7 days

local VALID_ASSERTS = {
    db = true,
    db_scalar = true,
    quest_status = true,
    choice_count = true,
    money_delta = true,
    no_change = true,
    event = true,
}

local function isNonEmptyString(v)
    return type(v) == 'string' and v ~= ''
end

local function validateScenario(s, name)
    if type(s.schema_version) ~= 'number' or s.schema_version ~= SUPPORTED_SCHEMA then
        return false, ('schema_version must be %d (got %s)'):format(SUPPORTED_SCHEMA, tostring(s.schema_version))
    end
    if type(s.seed) ~= 'number' then
        return false, 'seed must be a number'
    end
    if s.name ~= nil and not isNonEmptyString(s.name) then
        return false, 'name must be a non-empty string when provided'
    end
    if s.ordering ~= nil and s.ordering ~= 'sequential' then
        return false, 'ordering must be "sequential" (only ordered steps are supported)'
    end
    if type(s.players) ~= 'table' or #s.players < 1 then
        return false, 'players must be a non-empty array'
    end
    if #s.players > MAX_PLAYERS then
        return false, ('too many players (%d > %d source pool)'):format(#s.players, MAX_PLAYERS)
    end

    local cids, sources = {}, {}
    for i, p in ipairs(s.players) do
        if type(p) ~= 'table' then
            return false, ('players[%d] must be an object'):format(i)
        end
        if not isNonEmptyString(p.cid) then
            return false, ('players[%d].cid must be a non-empty string'):format(i)
        end
        if not p.cid:match('^SIM[%w_%-]+$') then
            return false, ('players[%d].cid must start with SIM (got %q)'):format(i, p.cid)
        end
        if #p.cid > MAX_RUNTIME_CID_LEN - #runId - 1 then
            return false, ('players[%d].cid %q is too long: runtime CID must fit VARCHAR(%d)'
                .. ' (max %d chars before the "_%s" suffix)'):format(
                i, p.cid, MAX_RUNTIME_CID_LEN, MAX_RUNTIME_CID_LEN - #runId - 1, runId)
        end
        if cids[p.cid] then
            return false, ('duplicate player cid %q'):format(p.cid)
        end
        cids[p.cid] = true

        if not isNonEmptyString(p.job) then
            return false, ('players[%d].job must be a non-empty string'):format(i)
        end
        p.job = p.job:lower()
        if not QBCore.Shared.Jobs[p.job] then
            return false, ('players[%d].job %q is not a QBCore job'):format(i, p.job)
        end

        p.gang = isNonEmptyString(p.gang) and p.gang:lower() or 'none'
        if not QBCore.Shared.Gangs[p.gang] then
            return false, ('players[%d].gang %q is not a QBCore gang'):format(i, p.gang)
        end

        if p.grade ~= nil and (type(p.grade) ~= 'number' or p.grade < 0 or p.grade % 1 ~= 0) then
            return false, ('players[%d].grade must be a non-negative integer'):format(i)
        end

        if p.money ~= nil then
            if type(p.money) ~= 'table' then
                return false, ('players[%d].money must be an object'):format(i)
            end
            for account, amount in pairs(p.money) do
                if type(account) ~= 'string' or type(amount) ~= 'number' or amount < 0 then
                    return false, ('players[%d].money.%s must be a non-negative number'):format(i, tostring(account))
                end
            end
        end
        if p.charinfo ~= nil and type(p.charinfo) ~= 'table' then
            return false, ('players[%d].charinfo must be an object'):format(i)
        end

        if p.source ~= nil then
            if type(p.source) ~= 'number' or p.source % 1 ~= 0
                or p.source < SOURCE_MIN or p.source > SOURCE_MAX then
                return false, ('players[%d].source must be an integer in %d..%d'):format(i, SOURCE_MIN, SOURCE_MAX)
            end
        end
        local source = p.source or (SOURCE_MIN + i - 1)
        if sources[source] then
            return false, ('duplicate player source %d'):format(source)
        end
        sources[source] = true
    end

    if type(s.steps) ~= 'table' or #s.steps < 1 then
        return false, 'steps must be a non-empty array'
    end

    local stepIds = {}
    for i, step in ipairs(s.steps) do
        if type(step) ~= 'table' then
            return false, ('steps[%d] must be an object'):format(i)
        end
        if not VALID_ACTIONS[step.action] then
            return false, ('steps[%d].action %q is not supported'):format(i, tostring(step.action))
        end
        step._id = isNonEmptyString(step.id) and step.id or ('step_%d'):format(i)
        if step.id ~= nil and not isNonEmptyString(step.id) then
            return false, ('steps[%d].id must be a non-empty string'):format(i)
        end
        if stepIds[step._id] then
            return false, ('duplicate step id %q'):format(step._id)
        end
        stepIds[step._id] = true

        if step.action ~= 'wait' then
            if not isNonEmptyString(step.cid) then
                return false, ('steps[%d].cid is required for %s'):format(i, step.action)
            end
            if not cids[step.cid] then
                return false, ('steps[%d].cid %q is not declared in players'):format(i, step.cid)
            end
        end

        if step.action == 'accept_quest' or step.action == 'complete_step' or step.action == 'make_choice' then
            if not isNonEmptyString(step.quest) then
                return false, ('steps[%d].quest is required for %s'):format(i, step.action)
            end
        end
        if step.action == 'complete_step' or step.action == 'make_choice' then
            if not isNonEmptyString(step.step) then
                return false, ('steps[%d].step is required for %s'):format(i, step.action)
            end
        end
        if step.action == 'make_choice' then
            if not isNonEmptyString(step.decision) or not isNonEmptyString(step.option) then
                return false, ('steps[%d] make_choice requires decision and option'):format(i)
            end
        end
        if step.action == 'add_money' then
            if type(step.amount) ~= 'number' or step.amount <= 0 then
                return false, ('steps[%d].amount must be a positive number'):format(i)
            end
            if step.account ~= nil and not isNonEmptyString(step.account) then
                return false, ('steps[%d].account must be a non-empty string'):format(i)
            end
            if step.reason ~= nil and not isNonEmptyString(step.reason) then
                return false, ('steps[%d].reason must be a non-empty string'):format(i)
            end
            step.account = isNonEmptyString(step.account) and step.account:lower() or 'bank'
        end
        if step.action == 'advance_clock' then
            if type(step.seconds) ~= 'number' or step.seconds ~= step.seconds
                or step.seconds < 1 or step.seconds > MAX_CLOCK_SECONDS then
                return false, ('steps[%d].seconds must be 1..%d'):format(i, MAX_CLOCK_SECONDS)
            end
        end
        if step.action == 'wait' and step.ms ~= nil
            and (type(step.ms) ~= 'number' or step.ms < 0 or step.ms > 600000) then
            return false, ('steps[%d].ms must be 0..600000'):format(i)
        end
        if step.wait ~= nil and (type(step.wait) ~= 'number' or step.wait < 0) then
            return false, ('steps[%d].wait must be a non-negative number'):format(i)
        end
        if step.expect_fail ~= nil and type(step.expect_fail) ~= 'boolean' then
            return false, ('steps[%d].expect_fail must be a boolean'):format(i)
        end
    end

    local asserts = s['assert']
    if type(asserts) ~= 'table' or #asserts < 1 then
        return false, 'assert must be a non-empty array'
    end
    for i, a in ipairs(asserts) do
        if type(a) ~= 'table' then
            return false, ('assert[%d] must be an object'):format(i)
        end
        if not VALID_ASSERTS[a.type] then
            return false, ('assert[%d].type %q is not supported'):format(i, tostring(a.type))
        end
        if a.name ~= nil and not isNonEmptyString(a.name) then
            return false, ('assert[%d].name must be a non-empty string'):format(i)
        end
        if a.after ~= nil and not stepIds[a.after] then
            return false, ('assert[%d].after %q does not match a step id'):format(i, tostring(a.after))
        end
        if a.cid ~= nil and not cids[a.cid] then
            return false, ('assert[%d].cid %q is not declared in players'):format(i, tostring(a.cid))
        end

        if a.type == 'db' or a.type == 'db_scalar' then
            if not isNonEmptyString(a.sql) then
                return false, ('assert[%d].sql is required for %s'):format(i, a.type)
            end
            if not a.sql:match('^%s*[Ss][Ee][Ll][Ee][Cc][Tt]') then
                return false, ('assert[%d].sql must be a SELECT (read-only)'):format(i)
            end
            if a.expect == nil then
                return false, ('assert[%d].expect is required for %s'):format(i, a.type)
            end
            if a.params ~= nil and type(a.params) ~= 'table' then
                return false, ('assert[%d].params must be an array'):format(i)
            end
        elseif a.type == 'quest_status' then
            if a.cid == nil then
                return false, ('assert[%d].cid is required for quest_status'):format(i)
            end
            if not isNonEmptyString(a.quest) or not isNonEmptyString(a.expect) then
                return false, ('assert[%d] quest_status requires quest and expect'):format(i)
            end
            if a.completion_count ~= nil and type(a.completion_count) ~= 'number' then
                return false, ('assert[%d].completion_count must be a number'):format(i)
            end
        elseif a.type == 'choice_count' then
            if a.cid == nil then
                return false, ('assert[%d].cid is required for choice_count'):format(i)
            end
            if type(a.expect) ~= 'number' then
                return false, ('assert[%d].expect must be a number for choice_count'):format(i)
            end
            if a.decision ~= nil and type(a.decision) ~= 'string' then
                return false, ('assert[%d].decision must be a string'):format(i)
            end
        elseif a.type == 'money_delta' or a.type == 'no_change' then
            if a.cid == nil then
                return false, ('assert[%d].cid is required for %s'):format(i, a.type)
            end
            if a.account ~= nil and type(a.account) ~= 'string' then
                return false, ('assert[%d].account must be a string'):format(i)
            end
            local since = a.since or 'setup'
            if since ~= 'setup' and not stepIds[since] then
                return false, ('assert[%d].since %q does not match a step id'):format(i, tostring(since))
            end
            if a.type == 'no_change' and a.since == nil then
                return false, ('assert[%d].since is required for no_change'):format(i)
            end
            if a.type == 'money_delta' then
                if a.min == nil and a.max == nil then
                    return false, ('assert[%d] money_delta requires min and/or max'):format(i)
                end
                if (a.min ~= nil and type(a.min) ~= 'number')
                    or (a.max ~= nil and type(a.max) ~= 'number') then
                    return false, ('assert[%d] money_delta min/max must be numbers'):format(i)
                end
                if a.min ~= nil and a.max ~= nil and a.min > a.max then
                    return false, ('assert[%d] money_delta min must be <= max'):format(i)
                end
            end
        elseif a.type == 'event' then
            if not isNonEmptyString(a.event) then
                return false, ('assert[%d].event is required for event'):format(i)
            end
            if a.quest ~= nil and not isNonEmptyString(a.quest) then
                return false, ('assert[%d].quest must be a non-empty string'):format(i)
            end
            if a.expect ~= nil and type(a.expect) ~= 'boolean' then
                return false, ('assert[%d].expect must be a boolean for event'):format(i)
            end
        end
    end

    s.name = s.name or name
    return true
end

-- ==============================================================
-- Fake player 生命周期
-- ==============================================================

local function buildJob(jobName, gradeLevel)
    local def = QBCore.Shared.Jobs[jobName]
    local gradeKey = tostring(gradeLevel or 0)
    local grade = def.grades[gradeKey] or def.grades['0'] or {}
    return {
        name = jobName,
        label = def.label,
        onduty = def.defaultDuty ~= false,
        type = def.type or 'none',
        grade = {
            name = grade.name or 'No Grades',
            level = tonumber(gradeKey) or 0,
            payment = grade.payment or 30,
            isboss = grade.isboss or false,
        },
        isboss = grade.isboss or false,
    }
end

local function buildGang(gangName, gradeLevel)
    local def = QBCore.Shared.Gangs[gangName]
    local gradeKey = tostring(gradeLevel or 0)
    local grade = def.grades[gradeKey] or def.grades['0'] or {}
    return {
        name = gangName,
        label = def.label,
        grade = {
            name = grade.name or 'None',
            level = tonumber(gradeKey) or 0,
            isboss = grade.isboss or false,
        },
        isboss = grade.isboss or false,
    }
end

local function createOnePlayer(persona, index, scenario)
    local logicalCid = persona.cid
    local runtimeCid = ('%s_%s'):format(logicalCid, runId)
    if #runtimeCid > MAX_RUNTIME_CID_LEN then
        check(('db.create_test_character.%s'):format(logicalCid), false,
            ('runtime cid %s exceeds VARCHAR(%d)'):format(runtimeCid, MAX_RUNTIME_CID_LEN), logicalCid)
        return false
    end
    local source = persona.source or (SOURCE_MIN + index - 1)

    local moneyDefaults = (QBCore.Config and QBCore.Config.Money
        and QBCore.Config.Money.MoneyTypes) or { cash = 500, bank = 5000, crypto = 0 }
    local money = {}
    for account, amount in pairs(moneyDefaults) do money[account] = amount end
    for account, amount in pairs(persona.money or {}) do money[account:lower()] = amount end

    local charinfo = {}
    for k, v in pairs(persona.charinfo or {}) do charinfo[k] = v end
    charinfo.firstname = charinfo.firstname or 'Sim'
    charinfo.lastname = charinfo.lastname or logicalCid
    charinfo.birthdate = charinfo.birthdate or '1990-01-01'
    charinfo.gender = charinfo.gender or 0
    charinfo.nationality = charinfo.nationality or 'US'

    local p = {
        logicalCid = logicalCid,
        runtimeCid = runtimeCid,
        source = source,
        jobName = persona.job,
        gangName = persona.gang,
        money = money,
        charinfo = charinfo,
    }
    players[logicalCid] = p
    playerOrder[#playerOrder + 1] = p

    -- 预清理只针对带 runId 的合成 CID；即使同一秒重复运行也不会误删真实玩家。
    deleteRows(runtimeCid)

    local okInsert, insertErr = pcall(function()
        MySQL.query.await([[
            INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]], {
            runtimeCid, index, 'license:e2e:' .. runtimeCid,
            ('%s %s'):format(charinfo.firstname, charinfo.lastname),
            json.encode(money),
            json.encode(charinfo),
            json.encode(buildJob(persona.job, persona.grade)),
            json.encode(buildGang(persona.gang, persona.grade)),
            json.encode({ x = 0.0, y = 0.0, z = 0.0, heading = 0.0 }),
            json.encode({
                health = 200, armor = 0, hunger = 100, thirst = 100, stress = 0,
                isdead = false, inlaststand = false, callsign = logicalCid,
                criminalrecord = {}, licences = {}, phones = {}, rep = {},
                synthetic = true, e2e_scenario = scenario.name, e2e_seed = scenario.seed,
            }),
            json.encode({}),
        })
    end)
    check(('db.create_test_character.%s'):format(logicalCid), okInsert,
        ('cid=%s%s'):format(runtimeCid, insertErr and (' err=' .. tostring(insertErr)) or ''),
        logicalCid)
    if not okInsert then
        return false
    end

    local playerData = {
        citizenid = runtimeCid,
        cid = index,
        license = 'license:e2e:' .. runtimeCid,
        name = ('%s %s'):format(charinfo.firstname, charinfo.lastname),
        money = money,
        charinfo = charinfo,
        job = buildJob(persona.job, persona.grade),
        gang = buildGang(persona.gang, persona.grade),
        position = { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 },
        metadata = {
            health = 200, armor = 0, hunger = 100, thirst = 100, stress = 0,
            isdead = false, inlaststand = false, callsign = logicalCid,
            criminalrecord = {}, licences = {}, phones = {}, rep = {},
            synthetic = true, e2e_scenario = scenario.name, e2e_seed = scenario.seed,
        },
        items = {},
        source = source,
    }

    local okCreate, createErr = pcall(function()
        QBCore.Player.CreatePlayer(playerData, false)
    end)
    Wait(300)
    local Player = QBCore.Functions.GetPlayer(source)
    check(('qb.fake_player_created.%s'):format(logicalCid), okCreate and Player ~= nil,
        ('source=%d cid=%s%s'):format(
            source, Player and Player.PlayerData.citizenid or 'nil',
            createErr and (' err=' .. tostring(createErr)) or ''),
        logicalCid)
    if not Player then
        return false
    end
    p.qb = Player

    local okSave, saveErr = pcall(function() Player.Functions.Save(true) end)
    check(('qb.save_fake_player.%s'):format(logicalCid), okSave,
        saveErr and tostring(saveErr) or 'saved', logicalCid)
    return true
end

local function createPlayers(scenario)
    for i, persona in ipairs(scenario.players) do
        local source = persona.source or (SOURCE_MIN + i - 1)
        if QBCore.Functions.GetPlayer(source) then
            check(('db.create_test_character.%s'):format(persona.cid), false,
                ('source %d already in use by a QBCore player'):format(source), persona.cid)
        else
            createOnePlayer(persona, i, scenario)
        end
    end
    if #playerOrder > 0 then Wait(1000) end
end

local function runRoleChecks()
    for _, p in ipairs(playerOrder) do
        if p.qb then
            local job = p.jobName
            local hasGang = p.gangName ~= 'none'
            local expectCivilian = not hasGang
                and job ~= 'police' and job ~= 'ambulance'
                and job ~= 'judge' and job ~= 'lawyer'
            local expectUnemployed = job == 'unemployed'
            local expectPolice = job == 'police'

            local okCivilian, actualCivilian = callExportBool('custom-career', 'PlayerMatchesTags',
                p.source, { role = 'civilian' })
            check(('career.role_civilian.%s'):format(p.logicalCid),
                okCivilian and actualCivilian == expectCivilian,
                ('cid=%s job=%s actual=%s expected=%s'):format(
                    p.logicalCid, job, tostring(actualCivilian), tostring(expectCivilian)),
                p.logicalCid)

            local okUnemployed, actualUnemployed = callExportBool('custom-career', 'PlayerMatchesTags',
                p.source, { role = 'unemployed' })
            check(('career.role_unemployed.%s'):format(p.logicalCid),
                okUnemployed and actualUnemployed == expectUnemployed,
                ('cid=%s job=%s actual=%s expected=%s'):format(
                    p.logicalCid, job, tostring(actualUnemployed), tostring(expectUnemployed)),
                p.logicalCid)

            local okPolice, actualPolice = callExportBool('custom-career', 'PlayerMatchesTags',
                p.source, { job = 'police' })
            check(('career.job_police_rejected.%s'):format(p.logicalCid),
                okPolice and actualPolice == expectPolice,
                ('cid=%s job=%s actual=%s expected=%s'):format(
                    p.logicalCid, job, tostring(actualPolice), tostring(expectPolice)),
                p.logicalCid)
        end
    end
end

-- ==============================================================
-- Step 执行
-- ==============================================================

local function stepDetails(step, p)
    return ('cid=%s step=%s'):format(
        p and p.logicalCid or tostring(step.cid), step._id)
end

local function executeAddMoney(step, p)
    local account = step.account or 'bank'
    pcall(function() p.qb.Functions.Save(true) end)
    Wait(150)
    local before = dbMoney(p.runtimeCid)
    local callOk, added = pcall(function()
        return p.qb.Functions.AddMoney(account, step.amount, step.reason or 'e2e_income')
    end)
    Wait(200)
    pcall(function() p.qb.Functions.Save(true) end)
    Wait(300)
    local after = dbMoney(p.runtimeCid)

    local ok = callOk and added ~= false
        and before ~= nil and after ~= nil
        and tonumber(before[account]) ~= nil
        and tonumber(after[account]) == tonumber(before[account]) + step.amount
    check('economy.add_money_persisted', ok,
        ('%s account=%s before=%s after=%s delta=%s%s'):format(
            stepDetails(step, p), account,
            before and tostring(before[account]) or 'nil',
            after and tostring(after[account]) or 'nil',
            tostring(step.amount),
            callOk and '' or (' err=' .. tostring(added))),
        p.logicalCid)
    return ok, ok and 'add_money persisted' or 'add_money mismatch'
end

local function executeStep(step)
    if step.action == 'wait' then
        Wait(step.ms or 500)
        return true, ('waited %dms'):format(step.ms or 500)
    end

    local p = players[step.cid]
    if not p or not p.qb then
        check(('step.%s'):format(step._id), false,
            ('player %s is not available'):format(tostring(step.cid)), step.cid)
        return false, 'player unavailable'
    end

    if step.action == 'accept_quest' then
        local ok, msg = callExport('custom-quest', 'TriggerQuest', p.source, step.quest)
        if step.expect_fail then
            check('quest.trigger_rejected', ok == false,
                ('%s %s'):format(stepDetails(step, p), tostring(msg)), p.logicalCid)
            Wait(step.wait or 300)
            return ok == false, msg
        end

        check('quest.trigger', ok,
            ('%s %s'):format(stepDetails(step, p), tostring(msg)), p.logicalCid)
        Wait(step.wait or 500)
        local row = questRow(p.runtimeCid, step.quest)
        check('quest.db_in_progress', row ~= nil and row.status == 'in_progress',
            ('%s status=%s current_step=%s'):format(
                stepDetails(step, p),
                row and tostring(row.status) or 'no row',
                row and tostring(row.current_step) or 'nil'),
            p.logicalCid)
        return ok, msg
    end

    if step.action == 'complete_step' then
        local ok, msg = callExport('custom-quest', 'CompleteStep', p.source, step.quest, step.step)
        check(('quest.complete.%s'):format(step.step), ok,
            ('%s %s'):format(stepDetails(step, p), tostring(msg)), p.logicalCid)
        Wait(step.wait or 300)
        return ok, msg
    end

    if step.action == 'make_choice' then
        local ok, msg = callExport('story-engine', 'MakeChoice',
            p.source, step.quest, step.step, step.decision, step.option)
        if step.expect_fail then
            check('story.duplicate_choice_rejected', ok == false,
                ('%s %s'):format(stepDetails(step, p), tostring(msg)), p.logicalCid)
            Wait(step.wait or 300)
            return ok == false, msg
        end

        check('story.make_choice', ok,
            ('%s %s'):format(stepDetails(step, p), tostring(msg)), p.logicalCid)
        Wait(step.wait or 800)
        if ok then
            pcall(function() p.qb.Functions.Save(true) end)
            Wait(300)
        end
        return ok, msg
    end

    if step.action == 'add_money' then
        return executeAddMoney(step, p)
    end

    if step.action == 'advance_clock' then
        local ok, msg = callExport('custom-quest', 'DebugAdvanceClock', p.runtimeCid, step.seconds)
        -- Load() 重新读取 DB 冷却到内存是异步的，等它完成后再让后续步骤判定。
        Wait(step.wait or 500)
        check(('clock.advance.%s'):format(step._id), ok == true,
            ('%s seconds=%s %s'):format(
                stepDetails(step, p), tostring(step.seconds),
                ok == true and 'applied' or tostring(msg)),
            p.logicalCid)
        return ok == true, ok == true
            and ('advanced %s seconds'):format(tostring(step.seconds))
            or tostring(msg)
    end

    return false, 'unsupported action: ' .. tostring(step.action)
end

-- ==============================================================
-- 断言执行
-- ==============================================================

local function valuesEqual(actual, expected)
    if type(expected) == 'number' then
        local n = tonumber(actual)
        return n ~= nil and n == expected
    end
    if type(expected) == 'boolean' then
        return (actual == true or actual == 1 or actual == '1') == expected
    end
    return tostring(actual) == tostring(expected)
end

local function findRuntimeCid(logicalCid)
    local p = logicalCid and players[logicalCid]
    return p and p.runtimeCid or nil
end

local function eventMatches(record, a)
    if a.cid then
        local runtimeCid = findRuntimeCid(a.cid)
        local found = false
        for _, value in ipairs(record.args) do
            if type(value) == 'string' and (value == a.cid or value == runtimeCid) then
                found = true
                break
            end
        end
        if not found then return false end
    end
    if a.quest then
        local found = false
        for _, value in ipairs(record.args) do
            if value == a.quest then found = true; break end
        end
        if not found then return false end
    end
    return true
end

local function evalAssert(a, index)
    local cid = a.cid
    local defaultName = ('assert.%d.%s'):format(index, a.type)
    local name = isNonEmptyString(a.name) and a.name or defaultName
    local runtimeCid = findRuntimeCid(cid)

    if a.type == 'db' or a.type == 'db_scalar' then
        local params = {}
        if runtimeCid then params[#params + 1] = runtimeCid end
        for _, v in ipairs(a.params or {}) do params[#params + 1] = v end
        local callOk, value = pcall(function()
            return MySQL.scalar.await(a.sql, params)
        end)
        local ok = callOk and valuesEqual(value, a.expect)
        check(name, ok, ('cid=%s value=%s expect=%s%s'):format(
            tostring(cid or '-'), callOk and tostring(value) or 'error',
            tostring(a.expect), callOk and '' or (' err=' .. tostring(value))), cid)
        return
    end

    if a.type == 'quest_status' then
        local row = questRow(runtimeCid, a.quest)
        local ok = row ~= nil and row.status == a.expect
        if ok and a.completion_count ~= nil then
            ok = tonumber(row.completion_count) == a.completion_count
        end
        check(name, ok, ('cid=%s status=%s completion_count=%s expect=%s'):format(
            tostring(cid), row and tostring(row.status) or 'no row',
            row and tostring(row.completion_count) or 'nil', tostring(a.expect)), cid)
        return
    end

    if a.type == 'choice_count' then
        local sql = 'SELECT COUNT(*) FROM player_choices WHERE citizenid = ?'
        local params = { runtimeCid }
        if a.decision then
            sql = sql .. ' AND decision_id = ?'
            params[#params + 1] = a.decision
        end
        local callOk, count = pcall(function() return MySQL.scalar.await(sql, params) end)
        local ok = callOk and tonumber(count) == a.expect
        check(name, ok, ('cid=%s count=%s expect=%d%s'):format(
            tostring(cid), callOk and tostring(count) or 'error', a.expect,
            callOk and '' or (' err=' .. tostring(count))), cid)
        return
    end

    if a.type == 'money_delta' or a.type == 'no_change' then
        local since = a.since or 'setup'
        local snap = checkpoints[since]
        local base = snap and snap.money[cid]
        if not base then
            check(name, false, ('cid=%s missing checkpoint %q'):format(tostring(cid), since), cid)
            return
        end
        saveAll()
        local current = dbMoney(runtimeCid)
        local account = (a.account or 'bank'):lower()
        local before = tonumber(base[account])
        local after = current and tonumber(current[account])
        if before == nil or after == nil then
            check(name, false, ('cid=%s account=%s before=%s after=%s'):format(
                tostring(cid), account, tostring(before), tostring(after)), cid)
            return
        end
        local delta = after - before
        local ok = delta == 0
        if a.type == 'money_delta' then
            ok = true
            if a.min ~= nil and delta < a.min then ok = false end
            if a.max ~= nil and delta > a.max then ok = false end
        end
        check(name, ok, ('cid=%s account=%s since=%s before=%d after=%d delta=%d range=%s..%s'):format(
            tostring(cid), account, since, before, after, delta,
            tostring(a.min or (a.type == 'no_change' and 0) or '-'),
            tostring(a.max or (a.type == 'no_change' and 0) or '-')), cid)
        return
    end

    if a.type == 'event' then
        local records = eventRecords[a.event] or {}
        local expect = a.expect ~= false
        local matched = false
        for _, record in ipairs(records) do
            if eventMatches(record, a) then matched = true; break end
        end
        local ok = (matched == expect)
        check(name, ok, ('event=%s received=%d expect=%s'):format(
            a.event, #records, tostring(expect)), cid)
        return
    end

    check(name, false, ('unsupported assert type %q'):format(tostring(a.type)), cid)
end

local function registerEventAsserts(asserts)
    for _, a in ipairs(asserts) do
        if a.type == 'event' and not registeredEvents[a.event] then
            registeredEvents[a.event] = true
            eventRecords[a.event] = {}
            local eventName = a.event
            AddEventHandler(eventName, function(...)
                eventRecords[eventName][#eventRecords[eventName] + 1] = { args = table.pack(...) }
            end)
        end
    end
end

-- ==============================================================
-- 报告
-- ==============================================================

local function countResults()
    local pass, fail = 0, 0
    for _, r in ipairs(results) do
        if r.ok then pass = pass + 1 else fail = fail + 1 end
    end
    return pass, fail
end

local function buildReport(errorMessage)
    local pass, fail = countResults()
    local cidMap = {}
    for _, p in ipairs(playerOrder) do
        cidMap[p.logicalCid] = {
            citizenid = p.runtimeCid,
            source = p.source,
            job = p.jobName,
            gang = p.gangName,
            money = p.money,
        }
    end

    return {
        scenario = scenarioRef and scenarioRef.name or scenarioName,
        scenario_file = scenarioName and ('config/scenarios/%s.json'):format(scenarioName) or nil,
        schema_version = scenarioRef and scenarioRef.schema_version or nil,
        seed = scenarioRef and scenarioRef.seed or nil,
        resource = RESOURCE,
        started_at = runStartedAt,
        finished_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        error = errorMessage,
        cid_map = cidMap,
        steps = stepLog,
        checks = results,
        summary = { pass = pass, fail = fail, total = pass + fail },
    }
end

local function writeReport(report)
    local okEnc, encoded = pcall(json.encode, report)
    if not okEnc then
        print('[E2E] WARN | report encode failed | ' .. tostring(encoded))
        return
    end

    local timestamp = os.date('%Y%m%d-%H%M%S')
    local path = ('reports/agent-sim-%s.json'):format(timestamp)
    local okSave, saved = pcall(SaveResourceFile, RESOURCE, path, encoded, -1)
    local written = okSave and saved ~= false and LoadResourceFile(RESOURCE, path) ~= nil
    if written then
        print('[E2E] report saved | ' .. path)
    else
        print('[E2E] WARN | report file unavailable, printing inline')
        print('[E2E] report inline | ' .. encoded)
    end
end

local function finish(errorMessage)
    if finished then return end
    finished = true

    if not cleaned then
        local ok, err = pcall(cleanupAll)
        if not ok then
            print('[E2E] WARN | cleanup exception | ' .. tostring(err))
        end
    end

    local pass, fail = countResults()
    writeReport(buildReport(errorMessage))
    print(('[E2E] DONE | pass=%d fail=%d'):format(pass, fail))
end

-- ==============================================================
-- 主流程
-- ==============================================================

local function run()
    local name, nameErr = resolveScenarioName()
    if not name then
        check('scenario.load', false, nameErr)
        finish(nameErr)
        return
    end
    scenarioName = name

    local scenario, loadErr = loadScenario(name)
    if not scenario then
        check('scenario.load', false, loadErr)
        finish(loadErr)
        return
    end
    scenarioRef = scenario

    local valid, validateErr = validateScenario(scenario, name)
    if not valid then
        check('scenario.load', false, validateErr)
        finish(validateErr)
        return
    end
    check('scenario.load', true, ('%s seed=%s players=%d steps=%d'):format(
        name, tostring(scenario.seed), #scenario.players, #scenario.steps))

    math.randomseed(scenario.seed)

    local required = { 'qb-core', 'custom-quest', 'story-engine', 'custom-career' }
    local missing = {}
    for _, res in ipairs(required) do
        if not waitStarted(res) then missing[#missing + 1] = res end
    end
    if #missing > 0 then
        local msg = 'required resources not started: ' .. table.concat(missing, ', ')
        check('resources.started', false, msg)
        finish(msg)
        return
    end
    check('resources.started', true, table.concat(required, ', '))

    createPlayers(scenario)
    if #playerOrder == 0 then
        local msg = 'no fake players were created'
        check('runner.players', false, msg)
        finish(msg)
        return
    end

    runRoleChecks()
    saveAll()
    snapshot('setup')

    registerEventAsserts(scenario['assert'])

    local wantedSnapshots = { setup = true }
    for _, a in ipairs(scenario['assert']) do
        if (a.type == 'money_delta' or a.type == 'no_change') and a.since then
            wantedSnapshots[a.since] = true
        end
    end

    local afterAsserts, tailAsserts = {}, {}
    for index, a in ipairs(scenario['assert']) do
        local item = { index = index, def = a }
        if a.after then
            afterAsserts[a.after] = afterAsserts[a.after] or {}
            afterAsserts[a.after][#afterAsserts[a.after] + 1] = item
        else
            tailAsserts[#tailAsserts + 1] = item
        end
    end

    local function runAssert(item)
        local ok, err = pcall(evalAssert, item.def, item.index)
        if not ok then
            check(item.def.name or ('assert.%d.%s'):format(item.index, item.def.type), false,
                'assert exception: ' .. tostring(err), item.def.cid)
        end
    end

    for i, step in ipairs(scenario.steps) do
        local callOk, stepOk, detail = xpcall(function()
            return executeStep(step)
        end, function(err)
            return tostring(err) .. '\n' .. debug.traceback()
        end)
        if not callOk then
            detail = tostring(stepOk)
            stepOk = false
            check(('step.%s.exception'):format(step._id), false, detail, step.cid)
        end

        stepLog[#stepLog + 1] = {
            index = i,
            id = step._id,
            action = step.action,
            cid = step.cid,
            ok = stepOk and true or false,
            detail = detail ~= nil and tostring(detail) or '',
        }

        if wantedSnapshots[step._id] then
            saveAll()
            snapshot(step._id)
        end

        for _, item in ipairs(afterAsserts[step._id] or {}) do
            runAssert(item)
        end
    end

    for _, item in ipairs(tailAsserts) do
        runAssert(item)
    end

    finish(nil)
end

CreateThread(function()
    Wait(8000)
    local ok, err = xpcall(run, function(e)
        return tostring(e) .. '\n' .. debug.traceback()
    end)
    if not ok then
        if not finished then
            check('runner.exception', false, err)
        end
        finish(err)
    end
end)
