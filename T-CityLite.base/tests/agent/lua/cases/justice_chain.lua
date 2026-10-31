-- cases/justice_chain.lua — 司法链的三条行为验收（AC-P1-02 / 05 / 06）。
--
-- 为什么用桩而不是开第二个客户端：
--   * 三条 AC 考的都是一段代码行为（循环发几次通知、刑期怎么夹、非警察怎么拒），
--     不是"客户端能不能渲染一条通知"；
--   * 桩能重跑、能造反例；双开客户端不可复现，而且 FiveM 同机双开常常抢 license。
--
-- 只加载需要的四份服务端文件：config / main（JusticeService）/ sentence / prison / arrest。

return {
    run = function(ctx)
        local results = {}
        local failed = 0

        local function check(name, fn)
            local record = { name = name, ok = true }
            local ok, err = pcall(fn)
            if not ok then
                record.ok = false
                record.error = tostring(err)
                failed = failed + 1
            end
            results[#results + 1] = record
        end

        local env = ctx.bootstrap.Load({ load_main = false, convars = {}, db = {} })
        local resource = 'T-CityLite.base/resources/[custom]/custom-justice'

        -- 向量桩：config.lua 里全是 vector3/vector4。
        _G.vector3 = function(x, y, z) return { x = x or 0.0, y = y or 0.0, z = z or 0.0 } end
        _G.vector4 = function(x, y, z, w) return { x = x or 0.0, y = y or 0.0, z = z or 0.0, w = w or 0.0 } end

        -- 服务端 `_L(source, key, ...)` 由 production-freeze 提供；桩里只回 key。
        _G._L = function(_, key) return tostring(key) end
        _G.GetPlayerName = function(src) return ('Player%d'):format(tonumber(src) or 0) end

        -- 律师名单由用例设定；没有 core-framework 时 arrest.lua 会当成 0 人在线。
        env.lawyers = {}
        env.resource_states['core-framework'] = 'started'   -- arrest.lua 靠它才去问律师名单
        env.resource_states['custom-logs'] = 'started'
        env.exports['common'] = env.exports['common'] or {}
        env.coreJobsCalls = 0

        -- QBCore 的 Commands/Callback 在桩里不存在；main.lua 会在加载期注册命令。
        env.qb = env.qb or {}
        env.qb.Commands = env.qb.Commands or { Add = function() end, Remove = function() end }
        env.qb.Functions = env.qb.Functions or {}
        env.qb.Functions.CreateCallback = env.qb.Functions.CreateCallback
            or function(name, fn) env.callbacks = env.callbacks or {}; env.callbacks[name] = fn end

        dofile(resource .. '/config.lua')
        dofile(resource .. '/server/main.lua')
        dofile(resource .. '/server/sentence.lua')
        dofile(resource .. '/server/prison.lua')
        dofile(resource .. '/server/arrest.lua')

        -- arrest.lua 用 exports['core-framework']:service_job_GetOnlinePlayersByJob('lawyer')
        env.exports['service_job_GetOnlinePlayersByJob'] = function(job)
            env.coreJobsCalls = env.coreJobsCalls + 1
            if job ~= 'lawyer' then return {} end
            return env.lawyers
        end

        local service = assert(_G.JusticeService, 'JusticeService missing')

        --- 造一个玩家并塞进 qb 桩。
        local function addPlayer(src, citizenid, job, grade, duty)
            local player = env.makePlayer(src, citizenid)
            player.PlayerData.job = { name = job, grade = { level = grade or 0 }, onduty = duty and true or false }
            env.players[src] = player
            return player
        end

        --- 触发一次 registerArrest（真实事件 handler）。
        local function registerArrest(suspectSrc, crimes, officerSrc)
            local handlers = env.event_handlers['justice:server:registerArrest'] or {}
            for _, handler in ipairs(handlers) do
                handler(suspectSrc, crimes, officerSrc)
            end
        end

        local function lawyerNotifies()
            local count = 0
            for _, event in ipairs(env.client_events) do
                if event.event == 'justice:client:lawyerNotify' then count = count + 1 end
            end
            return count
        end

        check('AC-P1-02: every online lawyer is notified exactly once', function()
            env.client_events = {}
            env.players = {}
            env.lawyers = { 2, 3 }
            addPlayer(1, 'CID-OFFICER', 'police', 2, true)
            addPlayer(2, 'CID-LAWYER-A', 'lawyer', 0, true)
            addPlayer(3, 'CID-LAWYER-B', 'lawyer', 0, true)
            addPlayer(4, 'CID-SUSPECT', 'unemployed', 0, false)

            registerArrest(4, { 'robbery', 'evasion' }, 1)
            assert(lawyerNotifies() == 2, ('expected 2 notifies, got %d'):format(lawyerNotifies()))
        end)

        check('AC-P1-02: a repeated arrest does not stack notifications', function()
            -- 同一嫌疑人再登记一次：应为新的案件、每个律师各再收到 1 次（不是叠加在同一张卡上）
            local before = lawyerNotifies()
            registerArrest(4, { 'robbery' }, 1)
            local after = lawyerNotifies()
            assert(after - before == 2, ('expected +2 notifies, got +%d'):format(after - before))
        end)

        check('AC-P1-02: no lawyer online still registers the case', function()
            env.client_events = {}
            env.lawyers = {}
            local before = #service.GetActiveCases()
            registerArrest(4, { 'assault' }, 1)
            assert(lawyerNotifies() == 0, 'no lawyer online must not notify anyone')
            local count = 0
            for _ in pairs(service.GetActiveCases()) do count = count + 1 end
            assert(count > before, 'case must still be created without a lawyer')
        end)

        check('AC-P1-05: sentence is clamped to MaxSentence', function()
            env.players = {}
            addPlayer(4, 'CID-CONVICT', 'unemployed', 0, false)
            env.mysql.log = {}
            service.Imprison('CID-CONVICT', 99999, { 'robbery' })
            local max = (Config.Justice and Config.Justice.MaxSentence) or 120
            local wrote = false
            for _, entry in ipairs(env.mysql.log) do
                local sql = tostring(entry.sql or '')
                if sql:find('justice_sentences', 1, true) then
                    for _, value in ipairs(entry.params or {}) do
                        if tonumber(value) == max then wrote = true end
                        assert(tonumber(value) ~= 99999, 'raw 99999 must never reach the DB')
                    end
                end
            end
            assert(wrote, ('expected a write carrying the clamp %d'):format(max))
        end)

        check('AC-P1-05: a non-positive sentence is rejected', function()
            local ok, err = service.Imprison('CID-CONVICT', 0, { 'robbery' })
            assert(ok == false, 'zero-minute sentence must be refused')
            assert(err == 'invalid_sentence', tostring(err))
        end)

        check('AC-P1-06: a civilian source cannot register an arrest', function()
            env.client_events = {}
            env.players = {}
            env.lawyers = {}
            addPlayer(9, 'CID-CIVILIAN', 'taxi', 0, true)
            addPlayer(10, 'CID-SUSPECT-2', 'unemployed', 0, false)
            local before = 0
            for _ in pairs(service.GetActiveCases()) do before = before + 1 end
            registerArrest(10, { 'robbery' }, 9)
            local after = 0
            for _ in pairs(service.GetActiveCases()) do after = after + 1 end
            assert(after == before, 'a civilian must not open a case')
            assert(lawyerNotifies() == 0, 'a civilian must not trigger lawyer notifications')
        end)

        check('AC-P1-06: off-duty police are rejected too', function()
            env.client_events = {}
            env.players = {}
            addPlayer(11, 'CID-OFFDUTY', 'police', 2, false)
            addPlayer(12, 'CID-SUSPECT-3', 'unemployed', 0, false)
            local before = 0
            for _ in pairs(service.GetActiveCases()) do before = before + 1 end
            registerArrest(12, { 'robbery' }, 11)
            local after = 0
            for _ in pairs(service.GetActiveCases()) do after = after + 1 end
            assert(after == before, 'off-duty officer must not open a case')
        end)

        return { ok = failed == 0, data = { cases = results, failed = failed } }
    end,
}
