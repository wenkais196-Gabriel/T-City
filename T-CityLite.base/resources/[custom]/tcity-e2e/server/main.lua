-- tcity-e2e/server/main.lua
-- 服务端端到端测试：用 fake player 跑通 经济 → 任务 → 决策 → 奖励幂等 → DB 持久化
-- 仅在 convar tcity_e2e=1 时运行；不依赖真实客户端。
-- 启动方式：server.cfg 临时加
--   setr tcity_e2e 1
--   ensure tcity-e2e
-- 跑完看日志 [E2E] PASS/FAIL，然后移除这两行。

if GetConvar('tcity_e2e', '0') ~= '1' then
    return
end

local QBCore = exports['qb-core']:GetCoreObject()

local TEST_SOURCE = 9001
local CID = ('E2E%06d'):format(math.random(0, 999999))
local QUEST_ID = 'civilian_ch1_first_dollar'
local DECISION_ID = 'civilian_ch1_honest_or_shadow'
local DECISION_OPTION = 'honest_citizen'

local results = {}
local function check(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok and true or false, detail = detail }
    print(('[E2E] %s | %s%s'):format(
        ok and 'PASS' or 'FAIL', name, detail and (' | ' .. tostring(detail)) or ''))
end

local function waitStarted(res)
    for _ = 1, 60 do
        if GetResourceState(res) == 'started' then return true end
        Wait(500)
    end
    return false
end

local function dbMoney()
    local raw = MySQL.scalar.await('SELECT money FROM players WHERE citizenid = ?', { CID })
    if not raw then return nil end
    local ok, decoded = pcall(json.decode, raw)
    return ok and decoded or nil
end

local function cleanup()
    pcall(function()
        QBCore.Player.Logout(TEST_SOURCE)
    end)
    Wait(300)
    for _, sql in ipairs({
        'DELETE FROM player_quests WHERE citizenid = ?',
        'DELETE FROM player_choices WHERE citizenid = ?',
        'DELETE FROM quest_cooldowns WHERE citizenid = ?',
        'DELETE FROM quest_daily_limits WHERE citizenid = ?',
        'DELETE FROM inventories WHERE citizenid = ?',
        'DELETE FROM players WHERE citizenid = ?',
    }) do
        pcall(function() MySQL.query.await(sql, { CID }) end)
    end
end

CreateThread(function()
    Wait(8000)

    if not waitStarted('qb-core') or not waitStarted('custom-quest')
        or not waitStarted('story-engine') or not waitStarted('custom-career') then
        print('[E2E] FAIL | required resources not started')
        return
    end

    -- 1. 创建测试角色行（不用真实 client）
    local okInsert = pcall(function()
        MySQL.query.await([[
            INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]], {
            CID, 1, 'license:e2e:' .. CID, 'E2E Tester',
            json.encode({ cash = 1000, bank = 10000, crypto = 0 }),
            json.encode({ firstname = 'E2E', lastname = 'Tester', birthdate = '1990-01-01', gender = 0, nationality = 'US' }),
            json.encode({ name = 'unemployed', label = 'Civilian', onduty = true, type = 'none',
                          grade = { name = 'Freelancer', level = 0, payment = 10, isboss = false }, isboss = false }),
            json.encode({ name = 'none', label = 'No Gang', grade = { name = 'None', level = 0, isboss = false }, isboss = false }),
            json.encode({ x = 0.0, y = 0.0, z = 0.0, heading = 0.0 }),
            json.encode({ health = 200, armor = 0, hunger = 100, thirst = 100, stress = 0,
                          isdead = false, inlaststand = false, callsign = 'E2E',
                          criminalrecord = {}, licences = {}, phones = {}, rep = {} }),
            json.encode({}),
        })
    end)
    check('db.create_test_character', okInsert, 'cid=' .. CID)

    -- 2. 构造 fake player 并注册到 QBCore
    local playerData = {
        citizenid = CID, cid = 1, license = 'license:e2e:' .. CID, name = 'E2E Tester',
        money = { cash = 1000, bank = 10000, crypto = 0 },
        charinfo = { firstname = 'E2E', lastname = 'Tester', birthdate = '1990-01-01', gender = 0, nationality = 'US' },
        job = { name = 'unemployed', label = 'Civilian', onduty = true, type = 'none',
                grade = { name = 'Freelancer', level = 0, payment = 10, isboss = false }, isboss = false },
        gang = { name = 'none', label = 'No Gang', grade = { name = 'None', level = 0, isboss = false }, isboss = false },
        position = { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 },
        metadata = { health = 200, armor = 0, hunger = 100, thirst = 100, stress = 0,
                     isdead = false, inlaststand = false, callsign = 'E2E',
                     criminalrecord = {}, licences = {}, phones = {}, rep = {} },
        items = {},
        source = TEST_SOURCE,
    }

    local okCreate = pcall(function()
        QBCore.Player.CreatePlayer(playerData, false)
    end)
    Wait(500)
    local Player = QBCore.Functions.GetPlayer(TEST_SOURCE)
    check('qb.fake_player_created', okCreate and Player ~= nil, Player and Player.PlayerData.citizenid or 'nil')
    if not Player then cleanup(); return end

    local okSave = pcall(function() Player.Functions.Save(true) end)
    check('qb.save_fake_player', okSave)

    -- role 语义：unemployed 属于 civilian；job=police 必须拒绝
    check('career.role_civilian', exports['custom-career']:PlayerMatchesTags(TEST_SOURCE, { role = 'civilian' }) == true)
    check('career.role_unemployed', exports['custom-career']:PlayerMatchesTags(TEST_SOURCE, { role = 'unemployed' }) == true)
    check('career.job_police_rejected', exports['custom-career']:PlayerMatchesTags(TEST_SOURCE, { job = 'police' }) == false)

    -- 3. 经济：加钱并落库
    local before = dbMoney() or { bank = 0 }
    Player.Functions.AddMoney('bank', 250, 'e2e_income')
    pcall(function() Player.Functions.Save(true) end)
    Wait(300)
    local after = dbMoney() or { bank = 0 }
    check('economy.add_money_persisted', (after.bank or 0) == (before.bank or 0) + 250,
        ('before=%s after=%s'):format(tostring(before.bank), tostring(after.bank)))

    -- 4. 接任务：验证 required_tags(role=civilian) + story_arc 门控
    local okQuest, msgQuest = exports['custom-quest']:TriggerQuest(TEST_SOURCE, QUEST_ID)
    check('quest.trigger', okQuest, msgQuest)
    Wait(500)

    local row = MySQL.query.await(
        'SELECT quest_id,status,current_step,completion_count FROM player_quests WHERE citizenid = ? AND quest_id = ? ORDER BY id DESC LIMIT 1',
        { CID, QUEST_ID })
    local q = row and row[1]
    check('quest.db_in_progress', q ~= nil and q.status == 'in_progress', q and q.current_step or 'no row')
    if not q then cleanup(); return end

    -- 5. 推进到 decision 步骤
    for _, stepId in ipairs({ 'step_meet_tony', 'step_go_mine', 'step_mine_ore', 'step_go_bank' }) do
        local okStep, msgStep = exports['custom-quest']:CompleteStep(TEST_SOURCE, QUEST_ID, stepId)
        check('quest.complete.' .. stepId, okStep, msgStep)
        Wait(250)
    end

    local atDecision = MySQL.scalar.await(
        'SELECT current_step FROM player_quests WHERE citizenid = ? AND quest_id = ? AND status = ?',
        { CID, QUEST_ID, 'in_progress' })
    check('quest.at_decision_step', atDecision == 'step_decision', tostring(atDecision))

    -- 6. 决策：服务端 pending + MakeChoice
    Wait(300)
    local okChoice, msgChoice = exports['story-engine']:MakeChoice(
        TEST_SOURCE, QUEST_ID, 'step_decision', DECISION_ID, DECISION_OPTION)
    check('story.make_choice', okChoice, msgChoice)
    Wait(800)
    -- 奖励先写内存，强制刷盘后再查 DB
    pcall(function() Player.Functions.Save(true) end)
    Wait(300)

    local done = MySQL.query.await(
        'SELECT status,completion_count FROM player_quests WHERE citizenid = ? AND quest_id = ? ORDER BY id DESC LIMIT 1',
        { CID, QUEST_ID })
    local d = done and done[1]
    check('quest.completed', d ~= nil and d.status == 'completed', d and d.status or 'nil')
    check('quest.completion_count_once', d ~= nil and tonumber(d.completion_count) == 1,
        d and tostring(d.completion_count) or 'nil')

    local choiceCount = MySQL.scalar.await(
        'SELECT COUNT(*) FROM player_choices WHERE citizenid = ? AND decision_id = ?',
        { CID, DECISION_ID })
    check('story.choice_persisted', tonumber(choiceCount) == 1, tostring(choiceCount))

    local rewarded = dbMoney() or { bank = 0 }
    local delta = (rewarded.bank or 0) - (after.bank or 0)
    check('quest.reward_granted_once', delta >= 300 and delta <= 600, 'delta=' .. tostring(delta))

    -- 7. 幂等：再次提交同一决策/步骤，不应再发奖
    local okAgain, msgAgain = exports['story-engine']:MakeChoice(
        TEST_SOURCE, QUEST_ID, 'step_decision', DECISION_ID, DECISION_OPTION)
    check('story.duplicate_choice_rejected', okAgain == false, msgAgain)
    pcall(function()
        exports['custom-quest']:CompleteStep(TEST_SOURCE, QUEST_ID, 'step_decision')
    end)
    Wait(500)
    local afterDup = dbMoney() or { bank = 0 }
    check('quest.duplicate_complete_no_reward', (afterDup.bank or 0) == (rewarded.bank or 0),
        ('before=%s after=%s'):format(tostring(rewarded.bank), tostring(afterDup.bank)))

    -- 8. 汇总
    local pass, fail = 0, 0
    for _, r in ipairs(results) do
        if r.ok then pass = pass + 1 else fail = fail + 1 end
    end
    print(('[E2E] DONE | pass=%d fail=%d cid=%s'):format(pass, fail, CID))

    cleanup()
    print('[E2E] cleanup done')
end)
