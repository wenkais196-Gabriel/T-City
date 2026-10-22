-- server/main.lua — custom-director server action broker (issue #30/#32)
--
-- Scope of this first slice:
--   * accept action proposals from a trusted server-side caller / HTTP agent
--   * validate + preview + policy-check + persist (agent_actions)
--   * low-risk notify executes after policy; add_money / start_quest /
--     set_job / grant_item / remove_item / set_bucket / kick need approval
--   * approve/reject re-check policy, execute, and write the audit row
--
-- No client script exists. Nothing here trusts client input.

local QBCore = exports['qb-core']:GetCoreObject()
local AgentPolicy = _G.AgentPolicy

if not AgentPolicy then
    print('[custom-director] ❌ server/policy.lua was not loaded; resource disabled')
    return
end

local AgentActions = {}
_G.AgentActions = AgentActions

local DEFAULT_LIST_LIMIT = 20
local MAX_LIST_LIMIT = 100

-- ---------------------------------------------------------------------------
-- Convar configuration (read per request so the kill switch is live)
-- ---------------------------------------------------------------------------

local function convarString(name, default)
    local value = GetConvar(name, default)
    if type(value) ~= 'string' then return default end
    return value
end

local function convarInt(name, default, minimum, maximum)
    local raw = convarString(name, tostring(default))
    local value = tonumber(raw)
    if not value or value ~= value then value = default end
    value = math.floor(value)
    if value < minimum then value = minimum end
    if value > maximum then value = maximum end
    return value
end

local function Config()
    return {
        enabled = convarString('agent_actions_enabled', '0') == '1',
        token = AgentPolicy.Trim(convarString('agent_actions_token', '')),
        admin_token = AgentPolicy.Trim(convarString('agent_actions_admin_token', '')),
        max_money = convarInt('agent_actions_max_money', 1000, 0, 1000000000),
        daily_budget = convarInt('agent_actions_daily_budget', 5000, 0, 1000000000),
        max_notify_chars = convarInt('agent_actions_max_notify_chars', 300, 1, 2000),
        max_announce_chars = convarInt('agent_actions_max_announce_chars', 300, 1, 2000),
        max_item_amount = convarInt('agent_actions_max_item_amount', 50, 1, 1000),
        ttl_seconds = convarInt('agent_actions_ttl_seconds', 900, 30, 86400),
    }
end

-- ---------------------------------------------------------------------------
-- Small utilities
-- ---------------------------------------------------------------------------

local function truncate(value, limit)
    local text = tostring(value or '')
    if #text > limit then return text:sub(1, limit) end
    return text
end

local function nowDateTime()
    return os.date('%Y-%m-%d %H:%M:%S')
end

local function safeEncode(value)
    local ok, encoded = pcall(json.encode, value)
    if ok and type(encoded) == 'string' then return encoded end
    return '{}'
end

local function decodeJson(value)
    if type(value) ~= 'string' or value == '' then return nil end
    local ok, decoded = pcall(json.decode, value)
    if ok then return decoded end
    return nil
end

local function failure(code, message, extra)
    local result = {
        ok = false,
        error = message or code,
        code = code,
    }
    if type(extra) == 'table' then
        for key, value in pairs(extra) do result[key] = value end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- DB helpers (single place for error logging; never expose SQL to clients)
-- ---------------------------------------------------------------------------

local function dbQuery(sql, params)
    local ok, result = pcall(function()
        return MySQL.query.await(sql, params or {})
    end)
    if not ok then
        print(('[custom-director] DB query failed: %s'):format(truncate(result, 200)))
        return nil, tostring(result)
    end
    return result or {}, nil
end

local function dbSingle(sql, params)
    local ok, row = pcall(function()
        return MySQL.single.await(sql, params or {})
    end)
    if not ok then
        print(('[custom-director] DB single failed: %s'):format(truncate(row, 200)))
        return nil, tostring(row)
    end
    return row, nil
end

local function dbScalar(sql, params)
    local ok, value = pcall(function()
        return MySQL.scalar.await(sql, params or {})
    end)
    if not ok then
        print(('[custom-director] DB scalar failed: %s'):format(truncate(value, 200)))
        return nil, tostring(value)
    end
    return value, nil
end

local function dbInsert(sql, params)
    local ok, insertId = pcall(function()
        return MySQL.insert.await(sql, params or {})
    end)
    if not ok then
        print(('[custom-director] DB insert failed: %s'):format(truncate(insertId, 200)))
        return nil, tostring(insertId)
    end
    -- oxmysql may return a number or { affectedRows, insertId }
    if type(insertId) == 'string' then
        return nil, insertId
    end
    if type(insertId) == 'table' then
        insertId = insertId.insertId or insertId.affectedRows or 0
    end
    return tonumber(insertId) or 0, nil
end

local function dbUpdate(sql, params)
    local ok, affected = pcall(function()
        return MySQL.update.await(sql, params or {})
    end)
    if not ok then
        print(('[custom-director] DB update failed: %s'):format(truncate(affected, 200)))
        return 0, tostring(affected)
    end
    if type(affected) == 'string' then
        return 0, affected
    end
    if type(affected) == 'table' then
        affected = affected.affectedRows or 0
    end
    return tonumber(affected) or 0, nil
end

local function rowToApi(row)
    if type(row) ~= 'table' then return nil end
    return {
        id = tonumber(row.id) or row.id,
        agent_id = row.agent_id,
        action_type = row.action_type,
        params = decodeJson(row.params) or {},
        status = row.status,
        idempotency_key = row.idempotency_key,
        preview = decodeJson(row.preview),
        result = decodeJson(row.result),
        error = row.error,
        requested_at = row.requested_at,
        approved_by = row.approved_by,
        approved_at = row.approved_at,
        executed_at = row.executed_at,
        expires_at = row.expires_at,
    }
end

local function getActionRow(id)
    return dbSingle([[
        SELECT *, (expires_at IS NOT NULL AND expires_at < NOW()) AS expired
        FROM agent_actions
        WHERE id = ?
        LIMIT 1
    ]], { id })
end

local function findByIdempotencyKey(key)
    return dbSingle([[
        SELECT * FROM agent_actions WHERE idempotency_key = ? LIMIT 1
    ]], { key })
end

local function getDailySpent(excludeId)
    local value, err = dbScalar([[
        SELECT COALESCE(SUM(
            CASE WHEN JSON_VALID(params)
                 THEN CAST(JSON_UNQUOTE(JSON_EXTRACT(params, '$.amount')) AS DECIMAL(18,2))
                 ELSE 0 END
        ), 0)
        FROM agent_actions
        WHERE action_type = 'add_money'
          AND status IN ('pending_approval', 'approved', 'executed')
          AND requested_at >= CURDATE()
          AND id <> ?
    ]], { excludeId or 0 })
    if value == nil then return nil, err end
    return tonumber(value) or 0, nil
end

local function expirePendingApprovals()
    if not Config().enabled then return end
    dbUpdate([[
        UPDATE agent_actions
        SET status = 'rejected', error = 'expired', result = ?
        WHERE status = 'pending_approval'
          AND expires_at IS NOT NULL
          AND expires_at < NOW()
    ]], { safeEncode({ rejected = true, reason = 'expired' }) })
end

-- ---------------------------------------------------------------------------
-- Live game context
-- ---------------------------------------------------------------------------

local function getPlayerByCitizenId(citizenid)
    local ok, player = pcall(QBCore.Functions.GetPlayerByCitizenId, citizenid)
    if ok then return player end
    return nil
end

local function playerSource(player)
    if type(player) ~= 'table' then return nil end
    local source = player.PlayerData and player.PlayerData.source
    if not source then source = player.source end
    return tonumber(source)
end

local function playerMoney(player, account)
    if type(player) ~= 'table' then return nil end
    local money = player.PlayerData and player.PlayerData.money
    if type(money) ~= 'table' then return nil end
    local value = money[account]
    if type(value) == 'number' then return value end
    return nil
end

local function dbMoney(citizenid, account)
    local raw, err = dbScalar('SELECT money FROM players WHERE citizenid = ?', { citizenid })
    if not raw then return nil, err end
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then return nil, 'invalid_money_json' end
    local value = tonumber(decoded[account])
    if not value then return nil, 'account_unavailable' end
    return value, nil
end

local function playerJob(player)
    if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
    return player.PlayerData.job
end

local function playerItemCount(player, item)
    if type(player) ~= 'table' or type(player.Functions) ~= 'table' then return nil end
    local fn = player.Functions.GetItemByName
    if type(fn) ~= 'function' then return nil end
    local ok, itemData = pcall(fn, item)
    if not ok or type(itemData) ~= 'table' then return 0 end
    return tonumber(itemData.amount) or 0
end

-- Routing buckets live in the FXServer session only (no DB backing), so every
-- read is best-effort: a nil result means "unknown", not bucket 0.
local function playerBucket(source)
    if not source or type(GetPlayerRoutingBucket) ~= 'function' then return nil end
    local ok, bucket = pcall(GetPlayerRoutingBucket, source)
    if not ok then return nil end
    return tonumber(bucket)
end

-- GetPlayerPed returns 0 while the player is loading or already dropping, so
-- callers must treat a missing position as "unknown", not as (0, 0, 0).
local function playerPosition(source)
    if not source then return nil end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

-- delete_vehicle only ever targets the vehicle the player is currently in;
-- arbitrary entity ids are never accepted from the caller.
local function vehiclePlate(entity)
    if not entity or entity == 0 then return nil end
    local plate = GetVehicleNumberPlateText(entity)
    if type(plate) ~= 'string' then return nil end
    plate = plate:gsub('%s+', ''):upper()
    if plate == '' then return nil end
    return plate
end

local function playerVehicle(source)
    if not source then return nil end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil end
    local entity = GetVehiclePedIsIn(ped, false)
    if not entity or entity == 0 then return nil end
    return tonumber(entity) or entity
end

local function getQuestCatalog()
    local ok, catalog = pcall(function()
        return exports['custom-quest']:GetQuestCatalog()
    end)
    if not ok then
        print(('[custom-director] GetQuestCatalog failed: %s'):format(truncate(catalog, 200)))
        return nil, tostring(catalog)
    end
    return catalog, nil
end

local function buildContext(actionType, params)
    local context = {
        player = nil,
        executor_ready = GetResourceState('custom-agent-client') == 'started',
    }

    -- World actions have no target player; everything below is per-player.
    if not AgentPolicy.WORLD_ACTIONS[actionType] then
        local player = getPlayerByCitizenId(params.citizenid)
        if player then
            context.player = {
                source = playerSource(player),
                money = player.PlayerData and player.PlayerData.money or nil,
            }
            if actionType == 'teleport' or actionType == 'spawn_vehicle' then
                context.position = playerPosition(playerSource(player))
            elseif actionType == 'set_job' then
                context.player.job = playerJob(player)
            elseif actionType == 'grant_item' or actionType == 'remove_item' then
                context.player.item_count = playerItemCount(player, params.item) or 0
            elseif actionType == 'set_bucket' then
                context.player.bucket = playerBucket(context.player.source)
            elseif actionType == 'revive' then
                context.player.metadata = player.PlayerData and player.PlayerData.metadata or nil
            elseif actionType == 'delete_vehicle' then
                local entity = playerVehicle(context.player.source)
                if entity then
                    context.vehicle_entity = entity
                    context.vehicle_target = {
                        entity = entity,
                        model = GetEntityModel(entity),
                        plate = vehiclePlate(entity),
                    }
                end
            end
        end
    end

    if actionType == 'set_weather' or actionType == 'set_time_of_day' then
        context.weather_sync = GetResourceState('qb-weathersync') == 'started'
        if context.weather_sync then
            local ok, state = pcall(function()
                return exports['qb-weathersync']:getWeatherState()
            end)
            if ok and type(state) == 'string' then context.weather = state end
        end
    elseif actionType == 'start_quest' then
        local catalog, err = getQuestCatalog()
        if err then return nil, err end
        context.quests = catalog
    elseif actionType == 'set_job' then
        context.jobs = QBCore.Shared and QBCore.Shared.Jobs or nil
    elseif actionType == 'grant_item' or actionType == 'remove_item' then
        context.items = QBCore.Shared and QBCore.Shared.Items or nil
    end

    -- spawn_vehicle: resolve the model hash here so policy.lua keeps zero
    -- native dependencies.
    if actionType == 'spawn_vehicle' then
        context.model_hash = GetHashKey(params.model)
    end

    return context, nil
end

-- ---------------------------------------------------------------------------
-- Execution
-- ---------------------------------------------------------------------------

local function executeNotify(actionId, params)
    local player = getPlayerByCitizenId(params.citizenid)
    if not player then return false, 'player_offline', nil end
    local source = playerSource(player)
    if not source or source <= 0 then return false, 'player_source_unavailable', nil end

    local ok, err = pcall(function()
        if player.Functions and player.Functions.Notify then
            player.Functions.Notify(params.text, params.kind, 5000)
        else
            TriggerClientEvent('QBCore:Notify', source, params.text, params.kind, 5000)
        end
    end)
    if not ok then
        return false, ('notify_failed: %s'):format(truncate(err, 150)), nil
    end

    return true, nil, {
        delivered = true,
        citizenid = params.citizenid,
        source = source,
        kind = params.kind,
        at = os.time(),
    }
end

local function executeAddMoney(actionId, params)
    local player = getPlayerByCitizenId(params.citizenid)
    if not player then return false, 'player_offline', nil end

    -- 读 DB 而不是 player.PlayerData：跨资源拿到的 player 是副本，
    -- 内存里的 money 不会随 qb-core 的 AddMoney 更新。
    local before, beforeErr = dbMoney(params.citizenid, params.account)
    if not before then
        return false, 'account_unavailable: ' .. tostring(beforeErr or 'unknown'), nil
    end

    local reason = 'agent_action:' .. tostring(actionId)
    local fn = player.Functions.AddMoney
    local nparams = 3
    local infoOk, info = pcall(function() return debug.getinfo(fn, 'u') end)
    if infoOk and type(info) == 'table' and type(info.nparams) == 'number' then
        nparams = info.nparams
    end

    local ok, result
    if nparams >= 4 then
        -- core-framework/compat.lua wrapper: function(self, moneytype, amount, reason)
        ok, result = pcall(function()
            return fn(player, params.account, params.amount, reason)
        end)
    else
        -- qb-core original closure: function(moneytype, amount, reason)
        ok, result = pcall(function()
            return fn(params.account, params.amount, reason)
        end)
    end
    if not ok then
        return false, ('add_money_failed: %s'):format(truncate(result, 150)), nil
    end
    if result == false then
        return false, 'add_money_rejected_by_qbcore', nil
    end

    -- 强制单玩家刷盘后再从 DB 验证，避免读到跨资源副本的旧余额。
    pcall(function() player.Functions.Save(true) end)
    Wait(300)

    local after, afterErr = dbMoney(params.citizenid, params.account)
    if not after then
        return false, 'account_unavailable_after_add: ' .. tostring(afterErr or 'unknown'), nil
    end
    if math.abs((after - before) - params.amount) > 0.001 then
        -- Do not attempt an automatic rollback: a partial mutation is more
        -- dangerous than a loud failed audit row. Operators use the log/row.
        return false, ('amount_verification_failed before=%s after=%s expected=%s'):format(
            tostring(before), tostring(after), tostring(params.amount)), nil
    end

    return true, nil, {
        account = params.account,
        amount = params.amount,
        before = before,
        after = after,
        reason = params.reason,
        at = os.time(),
    }
end

local function executeStartQuest(actionId, params)
    local player = getPlayerByCitizenId(params.citizenid)
    if not player then return false, 'player_offline', nil end
    local source = playerSource(player)
    if not source or source <= 0 then return false, 'player_source_unavailable', nil end

    local callOk, success, message = pcall(function()
        return exports['custom-quest']:TriggerQuest(source, params.quest_id)
    end)
    if not callOk then
        return false, ('trigger_quest_failed: %s'):format(truncate(success, 150)), nil
    end
    if success ~= true then
        return false, truncate(message or 'trigger_quest_rejected', 255), nil
    end

    return true, nil, {
        quest_id = params.quest_id,
        citizenid = params.citizenid,
        source = source,
        message = message,
        at = os.time(),
    }
end

local function executeSetJob(actionId, params)
    local player = getPlayerByCitizenId(params.citizenid)
    if not player then return false, 'player_not_found', nil end

    local currentJob = playerJob(player) or {}
    local currentGrade = type(currentJob.grade) == 'table' and currentJob.grade.level or 0
    local before = { job = currentJob.name, grade = currentGrade }

    local callOk, result = pcall(function()
        return player.Functions.SetJob(params.job, params.grade)
    end)
    if not callOk then
        return false, ('set_job_failed: %s'):format(truncate(result, 150)), nil
    end
    if result ~= true then
        return false, 'execution_failed: SetJob returned non-true', nil
    end

    -- 回读同一个 player 对象；SetJob 成功后 PlayerData.job 必须已更新。
    local updatedJob = playerJob(player) or {}
    local updatedGrade = type(updatedJob.grade) == 'table' and updatedJob.grade.level or nil
    if updatedJob.name ~= params.job or tostring(updatedGrade) ~= tostring(params.grade) then
        return false, ('verification_failed before=%s/%s after=%s/%s expected=%s/%s'):format(
            tostring(before.job), tostring(before.grade),
            tostring(updatedJob.name), tostring(updatedGrade),
            tostring(params.job), tostring(params.grade)), nil
    end

    return true, nil, {
        before = before,
        after = { job = updatedJob.name, grade = updatedGrade },
        verify_result = true,
        at = os.time(),
    }
end

local function executeGrantItem(actionId, params)
    local player = getPlayerByCitizenId(params.citizenid)
    if not player then return false, 'player_not_found', nil end

    local before = playerItemCount(player, params.item)
    if before == nil then
        return false, 'item_api_unavailable', nil
    end

    local callOk, result = pcall(function()
        return player.Functions.AddItem(params.item, params.amount)
    end)
    if not callOk then
        return false, ('grant_item_failed: %s'):format(truncate(result, 150)), nil
    end
    if result ~= true then
        return false, 'execution_failed: AddItem returned non-true', nil
    end

    local after = playerItemCount(player, params.item)
    if after == nil then
        return false, 'item_api_unavailable_after_add', nil
    end
    if after - before ~= params.amount then
        -- No automatic rollback: same stance as add_money. A partial item
        -- mutation is more dangerous to "fix" blindly than to audit loudly.
        return false, ('verification_failed before=%s after=%s expected=%s'):format(
            tostring(before), tostring(after), tostring(params.amount)), nil
    end

    return true, nil, {
        item = params.item,
        amount = params.amount,
        before = before,
        after = after,
        reason = params.reason,
        verify_result = true,
        at = os.time(),
    }
end

local function executeRemoveItem(actionId, params)
    local player = getPlayerByCitizenId(params.citizenid)
    if not player then return false, 'player_not_found', nil end

    local before = playerItemCount(player, params.item)
    if before == nil then
        return false, 'item_api_unavailable', nil
    end

    local callOk, result = pcall(function()
        return player.Functions.RemoveItem(params.item, params.amount)
    end)
    if not callOk then
        return false, ('execution_failed: RemoveItem threw: %s'):format(truncate(result, 150)), nil
    end
    if result ~= true then
        return false, 'execution_failed: RemoveItem returned non-true', nil
    end

    local after = playerItemCount(player, params.item)
    if after == nil then
        return false, 'item_api_unavailable_after_remove', nil
    end
    if before - after ~= params.amount then
        -- No automatic rollback: a partial inventory mutation is safer to
        -- audit loudly than to "fix" blindly (same stance as grant_item).
        return false, ('verification_failed before=%s after=%s expected=%s'):format(
            tostring(before), tostring(after), tostring(params.amount)), nil
    end

    return true, nil, {
        item = params.item,
        amount = params.amount,
        before = before,
        after = after,
        reason = params.reason,
        verify_result = true,
        at = os.time(),
    }
end

local function executeSetBucket(actionId, params)
    local player = getPlayerByCitizenId(params.citizenid)
    if not player then return false, 'player_not_found', nil end

    local source = playerSource(player)
    if not source or source <= 0 then return false, 'player_source_unavailable', nil end

    local before = playerBucket(source)

    local setBucket = QBCore.Functions and QBCore.Functions.SetPlayerBucket
    if type(setBucket) ~= 'function' then
        return false, 'bucket_api_unavailable', nil
    end

    local callOk, result = pcall(setBucket, source, params.bucket)
    if not callOk then
        return false, ('execution_failed: SetPlayerBucket threw: %s'):format(truncate(result, 150)), nil
    end
    if result ~= true then
        return false, 'execution_failed: SetPlayerBucket returned non-true', nil
    end

    local after = playerBucket(source)
    if after ~= params.bucket then
        return false, ('verification_failed before=%s after=%s expected=%s'):format(
            tostring(before), tostring(after), tostring(params.bucket)), nil
    end

    return true, nil, {
        bucket = params.bucket,
        before = before,
        notes = 'routing bucket is session-scoped; it resets when the player reconnects',
        verify_result = true,
        at = os.time(),
    }
end

local function executeKick(actionId, params)
    local player = getPlayerByCitizenId(params.citizenid)
    if not player then return false, 'player_not_found', nil end

    local source = playerSource(player)
    if not source or source <= 0 then return false, 'player_source_unavailable', nil end

    local kick = QBCore.Functions and QBCore.Functions.Kick
    if type(kick) ~= 'function' then
        return false, 'kick_api_unavailable', nil
    end

    -- DropPlayer (inside QBCore.Functions.Kick) is asynchronous: the player may
    -- still be online when this returns. We deliberately do not verify that the
    -- player is gone; a successful call is the contract.
    local callOk, err = pcall(kick, source, params.reason)
    if not callOk then
        return false, ('execution_failed: Kick threw: %s'):format(truncate(err, 150)), nil
    end

    return true, nil, {
        kicked = true,
        reason = params.reason,
        at = os.time(),
    }
end

local function executeAnnounce(actionId, params)
    local listOk, players = pcall(QBCore.Functions.GetPlayers)
    if not listOk or type(players) ~= 'table' then
        return false, ('player_list_unavailable: %s'):format(truncate(players, 150)), nil
    end

    local delivered = 0
    for _, source in ipairs(players) do
        local src = tonumber(source)
        if src then
            local playerOk, player = pcall(QBCore.Functions.GetPlayer, src)
            if playerOk and type(player) == 'table'
                and type(player.Functions) == 'table'
                and type(player.Functions.Notify) == 'function' then
                if pcall(player.Functions.Notify, params.message, params.kind, 5000) then
                    delivered = delivered + 1
                end
            end
        end
    end

    -- Nobody online is a normal result, not a failure: the broadcast simply
    -- reached zero players. The audit row records the count.
    return true, nil, {
        delivered = delivered,
        kind = params.kind,
        at = os.time(),
    }
end

local function executeSetWeather(actionId, params)
    local before = nil
    local beforeOk, beforeState = pcall(function()
        return exports['qb-weathersync']:getWeatherState()
    end)
    if beforeOk and type(beforeState) == 'string' then before = beforeState end

    local callOk, result = pcall(function()
        return exports['qb-weathersync']:setWeather(params.weather)
    end)
    if not callOk then
        return false, ('set_weather_failed: %s'):format(truncate(result, 150)), nil
    end
    if result ~= true then
        return false, 'execution_failed: setWeather returned non-true', nil
    end

    local verifyOk, after = pcall(function()
        return exports['qb-weathersync']:getWeatherState()
    end)
    if not verifyOk then
        return false, ('verification_failed: getWeatherState failed: %s'):format(truncate(after, 150)), nil
    end
    if after ~= params.weather then
        return false, ('verification_failed before=%s after=%s expected=%s'):format(
            tostring(before), tostring(after), tostring(params.weather)), nil
    end

    return true, nil, {
        weather = params.weather,
        before = before,
        verify_result = true,
        at = os.time(),
    }
end

local function readWeatherTime()
    local ok, hour, minute = pcall(function()
        return exports['qb-weathersync']:getTime()
    end)
    if not ok or type(hour) ~= 'number' or type(minute) ~= 'number' then return nil end
    return { hour = hour, minute = minute }
end

local function executeSetTimeOfDay(actionId, params)
    local before = readWeatherTime()

    local callOk, result = pcall(function()
        return exports['qb-weathersync']:setTime(params.hour, params.minute)
    end)
    if not callOk then
        return false, ('set_time_of_day_failed: %s'):format(truncate(result, 150)), nil
    end
    if result ~= true then
        return false, 'execution_failed: setTime returned non-true', nil
    end

    -- qb-weathersync 的 setTime() 会冻结时钟并同步全服，getTime() 读的是同一
    -- 份 gameMinutes，所以可以回读比对。老版本没有 getTime 时退化为只信任
    -- setTime 的返回值（result.verify_result = nil）。
    local after = readWeatherTime()
    if after and (after.hour ~= params.hour or after.minute ~= params.minute) then
        return false, ('verification_failed: expected %02d:%02d, read %02d:%02d'):format(
            params.hour, params.minute, after.hour, after.minute), nil
    end

    return true, nil, {
        hour = params.hour,
        minute = params.minute,
        before = before,
        after = after,
        verify_result = after ~= nil,
        at = os.time(),
    }
end

local function executeTeleport(actionId, params)
    local player = getPlayerByCitizenId(params.citizenid)
    if not player then return false, 'player_offline', nil end

    local source = player.PlayerData and tonumber(player.PlayerData.source)
    if not source or source <= 0 then return false, 'player_source_unavailable', nil end

    -- Captured before dispatch so the audit row records where the player was,
    -- even when the client later acks with its own detail.
    local from = playerPosition(source)

    local callOk, ok, result, err = pcall(function()
        return exports['custom-agent-client']:Execute(source, 'teleport', {
            x = params.x,
            y = params.y,
            z = params.z,
            heading = params.heading,
        }, 5000, { agent_id = 'director:' .. tostring(actionId) })
    end)
    if not callOk then
        -- Missing export/resource: the pcall error must not be swallowed.
        return false, 'executor_unavailable', nil
    end
    if ok ~= true then
        local code = type(err) == 'table' and err.code or nil
        local message = type(err) == 'table' and err.message or nil
        code = code ~= nil and tostring(code) or 'unknown'
        if code == 'executor_disabled' then
            return false, 'executor_disabled', nil
        end
        if code == 'not_yieldable' then
            return false, 'not_yieldable: teleport must run inside a coroutine', nil
        end
        return false, ('execution_failed: %s: %s'):format(code, tostring(message or '')), nil
    end

    return true, nil, {
        ack = result,
        from = from,
        at = os.time(),
    }
end

-- Bounded server-side vehicle spawn. Deliberately not QBCore.Functions.SpawnVehicle:
-- its `while not DoesEntityExist(veh) do Wait(0) end` has no timeout and can
-- hang the approving thread forever on a model that never materialises.
local SPAWN_TIMEOUT_MS = 2000

local function executeSpawnVehicle(actionId, params)
    local player = getPlayerByCitizenId(params.citizenid)
    if not player then return false, 'player_offline', nil end

    local source = playerSource(player)
    if not source or source <= 0 then return false, 'player_source_unavailable', nil end

    -- GetPlayerPed is 0 while the player is loading or already dropping.
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false, 'player_offline', nil end

    local coords = GetEntityCoords(ped)
    local x, y, z = coords.x, coords.y, coords.z

    local heading = 0.0
    if type(GetEntityHeading) == 'function' then
        heading = GetEntityHeading(ped) or 0.0
    end

    -- Spawn 1.5 m in front of the ped. If the forward-vector native is not
    -- available, degrade to spawning at the ped's exact position.
    local forwardX, forwardY = nil, nil
    if type(GetEntityForwardVector) == 'function' then
        local forwardOk, forward = pcall(GetEntityForwardVector, ped)
        if forwardOk and forward then
            local readOk, read = pcall(function()
                return { x = forward.x, y = forward.y }
            end)
            if readOk and type(read.x) == 'number' and type(read.y) == 'number' then
                forwardX, forwardY = read.x, read.y
            end
        end
    end
    if forwardX ~= nil and forwardY ~= nil then
        x = x + forwardX * 1.5
        y = y + forwardY * 1.5
    end

    local veh
    if type(CreateVehicleServerSetter) == 'function' then
        veh = CreateVehicleServerSetter(params.model, 'automobile', x, y, z, heading)
    else
        veh = CreateVehicle(params.model, x, y, z, heading, true, false)
    end
    if not veh or veh == 0 then
        return false, 'vehicle_spawn_failed', nil
    end

    local deadline = GetGameTimer() + SPAWN_TIMEOUT_MS
    while not DoesEntityExist(veh) and GetGameTimer() < deadline do
        Wait(0)
    end
    if not DoesEntityExist(veh) then
        pcall(DeleteEntity, veh)
        return false, 'vehicle_spawn_timeout', nil
    end

    if params.plate then
        SetVehicleNumberPlateText(veh, params.plate)
        local readBack = GetVehicleNumberPlateText(veh)
        local readPlate = type(readBack) == 'string' and readBack:gsub('%s+', '') or ''
        if readPlate ~= params.plate then
            return false, ('verification_failed: plate read back %q, expected %q'):format(
                tostring(readBack), tostring(params.plate)), nil
        end
    end

    return true, nil, {
        entity = veh,
        model = params.model,
        plate = params.plate,
        coords = { x = x, y = y, z = z },
    }
end

-- qb-ambulancejob owns the actual resurrection (ped/health reset), but its
-- client event is fire-and-forget: the server metadata read-back is the
-- authority, so a stopped ambulancejob cannot crash the approval thread.
local function executeRevive(actionId, params)
    local player = getPlayerByCitizenId(params.citizenid)
    if not player then return false, 'player_not_found', nil end

    local source = playerSource(player)
    if not source or source <= 0 then return false, 'player_source_unavailable', nil end

    local current = player.PlayerData and player.PlayerData.metadata or {}
    local before = {
        isdead = current.isdead,
        inlaststand = current.inlaststand,
    }

    local setOk, setErr = pcall(function()
        player.Functions.SetMetaData('isdead', false)
        player.Functions.SetMetaData('inlaststand', false)
    end)
    if not setOk then
        return false, ('execution_failed: SetMetaData threw: %s'):format(truncate(setErr, 150)), nil
    end

    pcall(TriggerClientEvent, 'hospital:client:Revive', source)

    local updated = player.PlayerData and player.PlayerData.metadata or {}
    local after = {
        isdead = updated.isdead,
        inlaststand = updated.inlaststand,
    }
    if after.isdead ~= false or after.inlaststand ~= false then
        return false, ('verification_failed isdead=%s inlaststand=%s'):format(
            tostring(after.isdead), tostring(after.inlaststand)), nil
    end

    return true, nil, {
        before = before,
        after = after,
        at = os.time(),
    }
end

-- DeleteEntity returns nil even on success, so only DoesEntityExist is
-- trusted. The bounded wait keeps a stubborn entity from hanging the approval.
local DELETE_VERIFY_TIMEOUT_MS = 1000

local function executeDeleteVehicle(actionId, params)
    local player = getPlayerByCitizenId(params.citizenid)
    if not player then return false, 'player_not_found', nil end

    local source = playerSource(player)
    if not source or source <= 0 then return false, 'player_source_unavailable', nil end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false, 'player_offline', nil end

    local entity = GetVehiclePedIsIn(ped, false)
    if not entity or entity == 0 then return false, 'not_in_vehicle', nil end

    -- Re-read the plate at execution time: the approved preview may be stale.
    local plate = vehiclePlate(entity)
    if params.plate and plate ~= params.plate then
        return false, ('plate_mismatch: current %s, expected %s'):format(
            tostring(plate), tostring(params.plate)), nil
    end

    local model = GetEntityModel(entity)

    local ok, deleteErr = pcall(DeleteEntity, entity)
    if not ok then
        return false, ('execution_failed: DeleteEntity threw: %s'):format(
            truncate(deleteErr, 150)), nil
    end

    local deadline = GetGameTimer() + DELETE_VERIFY_TIMEOUT_MS
    while DoesEntityExist(entity) and GetGameTimer() < deadline do
        Wait(0)
    end
    if DoesEntityExist(entity) then
        return false, ('verification_failed: vehicle entity %s still exists'):format(
            tostring(entity)), nil
    end

    return true, nil, {
        entity = entity,
        model = model,
        plate = plate,
        at = os.time(),
    }
end

local function executeAction(actionId, actionType, params)
    if actionType == 'notify' then
        return executeNotify(actionId, params)
    elseif actionType == 'add_money' then
        return executeAddMoney(actionId, params)
    elseif actionType == 'start_quest' then
        return executeStartQuest(actionId, params)
    elseif actionType == 'set_job' then
        return executeSetJob(actionId, params)
    elseif actionType == 'grant_item' then
        return executeGrantItem(actionId, params)
    elseif actionType == 'remove_item' then
        return executeRemoveItem(actionId, params)
    elseif actionType == 'set_bucket' then
        return executeSetBucket(actionId, params)
    elseif actionType == 'kick' then
        return executeKick(actionId, params)
    elseif actionType == 'announce' then
        return executeAnnounce(actionId, params)
    elseif actionType == 'set_weather' then
        return executeSetWeather(actionId, params)
    elseif actionType == 'set_time_of_day' then
        return executeSetTimeOfDay(actionId, params)
    elseif actionType == 'teleport' then
        return executeTeleport(actionId, params)
    elseif actionType == 'spawn_vehicle' then
        return executeSpawnVehicle(actionId, params)
    elseif actionType == 'revive' then
        return executeRevive(actionId, params)
    elseif actionType == 'delete_vehicle' then
        return executeDeleteVehicle(actionId, params)
    end
    return false, 'unsupported_action', nil
end

-- Internal executors for the pure-Lua harness. Not a FiveM export; approval
-- still flows exclusively through Propose/Approve.
AgentActions._Execute = {
    set_job = executeSetJob,
    grant_item = executeGrantItem,
    remove_item = executeRemoveItem,
    set_bucket = executeSetBucket,
    kick = executeKick,
    announce = executeAnnounce,
    set_weather = executeSetWeather,
    set_time_of_day = executeSetTimeOfDay,
    teleport = executeTeleport,
    spawn_vehicle = executeSpawnVehicle,
    revive = executeRevive,
    delete_vehicle = executeDeleteVehicle,
}

-- Internal context builder for the pure-Lua harness (same contract as
-- _Execute): lets tests prove CheckPolicy receives live weathersync state.
AgentActions._Context = buildContext

-- ---------------------------------------------------------------------------
-- Audit transitions
-- ---------------------------------------------------------------------------

local function completeApproved(id, status, resultTable, errorMessage, preview)
    local affected, err = dbUpdate([[
        UPDATE agent_actions
        SET status = ?, result = ?, error = NULLIF(?, ''),
            preview = COALESCE(NULLIF(?, ''), preview), executed_at = NOW(3)
        WHERE id = ? AND status = 'approved'
    ]], {
        status,
        safeEncode(resultTable or {}),
        errorMessage and truncate(errorMessage, 255) or '',
        preview and safeEncode(preview) or '',
        id,
    })
    if affected ~= 1 then
        print(('[custom-director] ⚠️ final audit update missed id=%s status=%s err=%s'):format(
            tostring(id), tostring(status), tostring(err)))
        return false
    end
    return true
end

local function rejectPending(id, approver, code, message, preview)
    local affected, err = dbUpdate([[
        UPDATE agent_actions
        SET status = 'rejected', approved_by = ?, approved_at = NOW(3),
            error = ?, result = ?, preview = COALESCE(NULLIF(?, ''), preview)
        WHERE id = ? AND status = 'pending_approval'
    ]], {
        approver or 'system',
        truncate(message or code, 255),
        safeEncode({ rejected = true, reason = code, message = message }),
        preview and safeEncode(preview) or '',
        id,
    })
    if affected ~= 1 then
        print(('[custom-director] ⚠️ reject update missed id=%s err=%s'):format(tostring(id), tostring(err)))
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Public export: propose
-- ---------------------------------------------------------------------------

function AgentActions.Propose(agentId, actionType, params, idempotencyKey, dryRun)
    local cfg = Config()
    if not cfg.enabled then
        return failure('disabled', 'agent actions are disabled')
    end

    if dryRun == nil then dryRun = false end
    if type(dryRun) ~= 'boolean' then
        return failure('invalid_params', 'dry_run must be a boolean')
    end

    local normalizedAgentId, agentErr = AgentPolicy.NormalizeAgentId(agentId)
    if not normalizedAgentId then return failure(agentErr.code, agentErr.message) end

    local normalized, normalizeErr = AgentPolicy.Normalize(actionType, params, cfg)
    if not normalized then return failure(normalizeErr.code, normalizeErr.message) end

    local normalizedKey, keyErr = AgentPolicy.NormalizeIdempotencyKey(idempotencyKey)
    if not normalizedKey then return failure(keyErr.code, keyErr.message) end

    -- Idempotency: same key + same action/params returns the first row.
    local existing, existingErr = findByIdempotencyKey(normalizedKey)
    if existingErr then
        return failure('db_error', 'database unavailable')
    end
    if existing then
        local existingParams = decodeJson(existing.params) or {}
        if existing.action_type ~= actionType or not AgentPolicy.DeepEqual(existingParams, normalized) then
            return failure('idempotency_conflict', 'idempotency key was already used for a different action or params', {
                id = tonumber(existing.id),
                status = existing.status,
            })
        end
        return {
            ok = true,
            id = tonumber(existing.id) or existing.id,
            status = existing.status,
            preview = decodeJson(existing.preview),
            result = decodeJson(existing.result),
            idempotent = true,
        }
    end

    local context, contextErr = buildContext(actionType, normalized)
    if not context then
        return failure('quest_catalog_unavailable', 'quest catalog unavailable: ' .. truncate(contextErr, 120))
    end

    if actionType == 'add_money' then
        local spent = getDailySpent(nil)
        if spent == nil then
            return failure('db_error', 'database unavailable while checking daily budget')
        end
        context.daily_spent = spent
    end

    local preview, previewErr = AgentPolicy.Preview(actionType, normalized, context, cfg)
    if not preview then
        return failure(previewErr.code, previewErr.message)
    end

    local policyOk, policyErr = AgentPolicy.CheckPolicy(actionType, normalized, cfg, context)
    if not policyOk then
        -- Do not persist policy-rejected proposals: the key stays reusable
        -- after the operator raises a cap / the player reconnects.
        return failure(policyErr.code, policyErr.message, {
            status = 'rejected',
            preview = preview,
        })
    end

    local status = AgentPolicy.StatusFor(actionType, dryRun)
    local expiresAt = nil
    if status == 'pending_approval' then
        expiresAt = os.date('%Y-%m-%d %H:%M:%S', os.time() + cfg.ttl_seconds)
    end
    local approvedBy = nil
    local approvedAt = nil
    if status == 'approved' then
        approvedBy = 'auto'
        approvedAt = nowDateTime()
    end

    local insertId = dbInsert([[
        INSERT INTO agent_actions
            (agent_id, action_type, params, status, idempotency_key, preview,
             expires_at, approved_by, approved_at)
        VALUES (?, ?, ?, ?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''))
    ]], {
        normalizedAgentId,
        actionType,
        safeEncode(normalized),
        status,
        normalizedKey,
        safeEncode(preview),
        expiresAt or '',
        approvedBy or '',
        approvedAt or '',
    })
    if not insertId then
        -- A concurrent request may have won the unique-key race.
        local raced = findByIdempotencyKey(normalizedKey)
        if raced then
            local racedParams = decodeJson(raced.params) or {}
            if raced.action_type == actionType and AgentPolicy.DeepEqual(racedParams, normalized) then
                return {
                    ok = true,
                    id = tonumber(raced.id) or raced.id,
                    status = raced.status,
                    preview = decodeJson(raced.preview),
                    result = decodeJson(raced.result),
                    idempotent = true,
                }
            end
            return failure('idempotency_conflict', 'idempotency key was already used for a different action or params')
        end
        return failure('db_error', 'database insert failed')
    end

    if dryRun then
        return {
            ok = true,
            id = insertId,
            status = status,
            preview = preview,
            dry_run = true,
        }
    end

    if status == 'approved' then
        local execOk, execErr, execResult = executeAction(insertId, actionType, normalized)
        if execOk then
            completeApproved(insertId, 'executed', execResult, nil, preview)
            return {
                ok = true,
                id = insertId,
                status = 'executed',
                preview = preview,
                result = execResult,
            }
        end
        completeApproved(insertId, 'failed', { error = execErr }, execErr, preview)
        return failure('execution_failed', execErr, {
            id = insertId,
            status = 'failed',
            preview = preview,
        })
    end

    print(('[custom-director] approval required id=%s type=%s agent=%s'):format(
        tostring(insertId), actionType, normalizedAgentId))

    return {
        ok = true,
        id = insertId,
        status = 'pending_approval',
        preview = preview,
        expires_at = expiresAt,
    }
end

-- ---------------------------------------------------------------------------
-- Public export: approve / reject
-- ---------------------------------------------------------------------------

function AgentActions.Approve(id, approver)
    local cfg = Config()
    if not cfg.enabled then
        return failure('disabled', 'agent actions are disabled')
    end

    local actionId = tonumber(id)
    if not actionId or actionId < 1 or actionId ~= math.floor(actionId) then
        return failure('invalid_params', 'id must be a positive integer')
    end

    local normalizedApprover, approverErr = AgentPolicy.NormalizeApprover(approver)
    if not normalizedApprover then return failure(approverErr.code, approverErr.message) end

    local row, rowErr = getActionRow(actionId)
    if rowErr then return failure('db_error', 'database unavailable') end
    if not row then return failure('not_found', 'action not found', { id = actionId }) end
    if row.status ~= 'pending_approval' then
        return failure('invalid_status', 'action is not pending approval', {
            id = actionId,
            status = row.status,
        })
    end

    if tonumber(row.expired) == 1 then
        rejectPending(actionId, 'system:expired', 'expired', 'approval deadline passed', decodeJson(row.preview))
        return failure('expired', 'approval deadline passed', {
            id = actionId,
            status = 'rejected',
        })
    end

    local storedParams = decodeJson(row.params)
    local normalized, normalizeErr = AgentPolicy.Normalize(row.action_type, storedParams, cfg)
    if not normalized then
        rejectPending(actionId, normalizedApprover, normalizeErr.code, normalizeErr.message, decodeJson(row.preview))
        return failure(normalizeErr.code, normalizeErr.message, {
            id = actionId,
            status = 'rejected',
        })
    end

    local context, contextErr = buildContext(row.action_type, normalized)
    if not context then
        return failure('quest_catalog_unavailable', 'quest catalog unavailable: ' .. truncate(contextErr, 120), {
            id = actionId,
            status = 'pending_approval',
        })
    end

    if row.action_type == 'add_money' then
        local spent = getDailySpent(actionId)
        if spent == nil then
            return failure('db_error', 'database unavailable while checking daily budget', {
                id = actionId,
                status = 'pending_approval',
            })
        end
        context.daily_spent = spent
    end

    local preview, previewErr = AgentPolicy.Preview(row.action_type, normalized, context, cfg)
    if not preview then
        rejectPending(actionId, normalizedApprover, previewErr.code, previewErr.message, decodeJson(row.preview))
        return failure(previewErr.code, previewErr.message, {
            id = actionId,
            status = 'rejected',
        })
    end

    local policyOk, policyErr = AgentPolicy.CheckPolicy(row.action_type, normalized, cfg, context)
    if not policyOk then
        rejectPending(actionId, normalizedApprover, policyErr.code, policyErr.message, preview)
        return failure(policyErr.code, policyErr.message, {
            id = actionId,
            status = 'rejected',
            preview = preview,
        })
    end

    local approved, updateErr = dbUpdate([[
        UPDATE agent_actions
        SET status = 'approved', approved_by = ?, approved_at = NOW(3), preview = ?
        WHERE id = ? AND status = 'pending_approval'
    ]], {
        normalizedApprover,
        safeEncode(preview),
        actionId,
    })
    if approved ~= 1 then
        local current = getActionRow(actionId)
        return failure('invalid_status', 'action changed before approval', {
            id = actionId,
            status = current and current.status or 'unknown',
            detail = updateErr and 'db_error' or nil,
        })
    end

    local execOk, execErr, execResult = executeAction(actionId, row.action_type, normalized)
    if execOk then
        completeApproved(actionId, 'executed', execResult, nil, preview)
        print(('[custom-director] ✅ approved+executed id=%s type=%s by=%s'):format(
            tostring(actionId), row.action_type, normalizedApprover))
        return {
            ok = true,
            id = actionId,
            status = 'executed',
            preview = preview,
            result = execResult,
        }
    end

    completeApproved(actionId, 'failed', { error = execErr }, execErr, preview)
    print(('[custom-director] ❌ execution failed id=%s type=%s err=%s'):format(
        tostring(actionId), row.action_type, tostring(execErr)))
    return failure('execution_failed', execErr, {
        id = actionId,
        status = 'failed',
        preview = preview,
    })
end

function AgentActions.Reject(id, approver, reason)
    local cfg = Config()
    if not cfg.enabled then
        return failure('disabled', 'agent actions are disabled')
    end

    local actionId = tonumber(id)
    if not actionId or actionId < 1 or actionId ~= math.floor(actionId) then
        return failure('invalid_params', 'id must be a positive integer')
    end

    local normalizedApprover, approverErr = AgentPolicy.NormalizeApprover(approver)
    if not normalizedApprover then return failure(approverErr.code, approverErr.message) end

    local normalizedReason = nil
    if reason ~= nil then
        local reasonErr
        normalizedReason, reasonErr = AgentPolicy.NormalizeReason(reason, 255)
        if not normalizedReason then return failure(reasonErr.code, reasonErr.message) end
    end

    local row, rowErr = getActionRow(actionId)
    if rowErr then return failure('db_error', 'database unavailable') end
    if not row then return failure('not_found', 'action not found', { id = actionId }) end
    if row.status ~= 'pending_approval' then
        return failure('invalid_status', 'action is not pending approval', {
            id = actionId,
            status = row.status,
        })
    end

    local errorText = normalizedReason or 'rejected'
    local affected = dbUpdate([[
        UPDATE agent_actions
        SET status = 'rejected', approved_by = ?, approved_at = NOW(3),
            error = ?, result = ?
        WHERE id = ? AND status = 'pending_approval'
    ]], {
        normalizedApprover,
        errorText,
        safeEncode({ rejected = true, reason = errorText }),
        actionId,
    })
    if affected ~= 1 then
        return failure('invalid_status', 'action changed before rejection', { id = actionId })
    end

    print(('[custom-director] 🚫 rejected id=%s by=%s reason=%s'):format(
        tostring(actionId), normalizedApprover, errorText))
    return {
        ok = true,
        id = actionId,
        status = 'rejected',
        reason = errorText,
    }
end

-- ---------------------------------------------------------------------------
-- Public export: read surfaces
-- ---------------------------------------------------------------------------

function AgentActions.Get(id)
    local actionId = tonumber(id)
    if not actionId or actionId < 1 then return nil, 'invalid id' end
    local row, err = getActionRow(actionId)
    if err then return nil, 'database unavailable' end
    if not row then return nil end
    return rowToApi(row)
end

function AgentActions.List(status, limit, agentId)
    local normalizedStatus = nil
    if status ~= nil then
        local statusErr
        normalizedStatus, statusErr = AgentPolicy.NormalizeStatus(status)
        if not normalizedStatus then return nil, statusErr.message end
    end

    local normalizedLimit = AgentPolicy.NormalizeLimit(limit, DEFAULT_LIST_LIMIT, MAX_LIST_LIMIT)

    local normalizedAgentId = nil
    if agentId ~= nil then
        local agentErr
        normalizedAgentId, agentErr = AgentPolicy.NormalizeAgentId(agentId)
        if not normalizedAgentId then return nil, agentErr.message end
    end

    expirePendingApprovals()

    local sql = 'SELECT * FROM agent_actions WHERE 1 = 1'
    local params = {}
    if normalizedStatus then
        sql = sql .. ' AND status = ?'
        params[#params + 1] = normalizedStatus
    end
    if normalizedAgentId then
        sql = sql .. ' AND agent_id = ?'
        params[#params + 1] = normalizedAgentId
    end
    sql = sql .. ' ORDER BY id DESC LIMIT ' .. tostring(normalizedLimit)

    local rows, err = dbQuery(sql, params)
    if not rows then return nil, err end

    local actions = {}
    for _, row in ipairs(rows) do
        local action = rowToApi(row)
        if action then actions[#actions + 1] = action end
    end
    return actions
end

function AgentActions.Policy()
    local cfg = Config()
    local actions = {}
    for name, definition in pairs(AgentPolicy.ACTIONS) do
        actions[name] = {
            risk = definition.risk,
            requires_approval = definition.requires_approval,
            auto_execute = definition.auto_execute,
            blast_radius = definition.blast_radius,
            compensation = definition.compensation,
        }
    end
    actions.add_money.max_money = cfg.max_money
    actions.grant_item.max_amount = cfg.max_item_amount
    actions.remove_item.max_amount = cfg.max_item_amount

    local dailySpent = nil
    if cfg.enabled then
        local spent = getDailySpent(nil)
        if spent ~= nil then dailySpent = spent end
    end

    return {
        schema_version = 1,
        enabled = cfg.enabled,
        actions = actions,
        limits = {
            max_money = cfg.max_money,
            daily_budget = cfg.daily_budget,
            max_notify_chars = cfg.max_notify_chars,
            max_announce_chars = cfg.max_announce_chars,
            max_item_amount = cfg.max_item_amount,
            ttl_seconds = cfg.ttl_seconds,
        },
        daily_spent = dailySpent,
        daily_remaining = dailySpent and math.max(0, cfg.daily_budget - dailySpent) or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------

exports('Propose', function(agentId, actionType, params, idempotencyKey, dryRun)
    return AgentActions.Propose(agentId, actionType, params, idempotencyKey, dryRun)
end)

exports('Approve', function(id, approver)
    return AgentActions.Approve(id, approver)
end)

exports('Reject', function(id, approver, reason)
    return AgentActions.Reject(id, approver, reason)
end)

exports('Get', function(id)
    return AgentActions.Get(id)
end)

exports('List', function(status, limit, agentId)
    return AgentActions.List(status, limit, agentId)
end)

exports('Policy', function()
    return AgentActions.Policy()
end)

-- ---------------------------------------------------------------------------
-- HTTP adapter (pure routing/validation lives in server/http_api.lua)
-- ---------------------------------------------------------------------------

local AgentHttp = _G.AgentHttp
if not AgentHttp then
    print('[custom-director] ❌ server/http_api.lua missing')
    return
end

local function makeResponder(res)
    local sent = false
    return function(status, body, extraHeaders)
        if sent then return end
        sent = true

        local headers = {
            ['Content-Type'] = 'application/json; charset=utf-8',
            ['Cache-Control'] = 'no-store',
            ['X-Content-Type-Options'] = 'nosniff',
        }
        if type(extraHeaders) == 'table' then
            for key, value in pairs(extraHeaders) do headers[key] = value end
        end

        local payload
        local ok, encoded = pcall(json.encode, body or {})
        if ok and type(encoded) == 'string' then
            payload = encoded
        else
            payload = '{"error":"internal server error","code":"internal_error"}'
        end

        res.writeHead(status, headers)
        res.send(payload)
    end
end

local function fail(respond)
    respond(500, { error = 'internal server error', code = 'internal_error' })
end

SetHttpHandler(function(req, res)
    local respond = makeResponder(res)
    -- Read the live config once per request: probing and finishing must see the
    -- same token, otherwise a convar rotation mid-request can 401 a request
    -- that already passed the probe.
    local cfg = Config()
    -- Guards against FXServer invoking the data handler more than once, and
    -- against a late callback after a synchronous response.  Without it a
    -- duplicate callback would call Propose() twice for one HTTP request.
    local handled = false

    -- FXServer only invokes setDataHandler when the request carries a body, so
    -- first run Handle with body=nil. It returns need_body=true only after the
    -- same routing/auth checks the old dispatchHttp() did, and only for routes
    -- that actually read a body. Everything else (GET /policy, /actions, 404s,
    -- 405s, 401s, missing content-length) is answered synchronously as before.
    local function run(raw)
        return AgentHttp.Handle({
            method = tostring(req.method or ''):upper(),
            path = tostring(req.path or '/'),
            headers = req.headers,
            body = raw,
        }, {
            cfg = cfg,
            actions = AgentActions,
            policy = AgentPolicy,
            live = _G.LiveApi,
        })
    end

    local function finish(raw)
        if handled then return end
        handled = true

        local ok, err = pcall(function()
            local result = run(raw)
            -- raw == nil means FXServer called the handler without a body even
            -- though the route needs one; the old readJsonBody() answered 400.
            if result.need_body then
                respond(400, { error = 'request body required', code = 'missing_body' })
                return
            end
            respond(result.status, result.body, result.headers)
        end)
        if not ok then
            print(('[custom-director] HTTP error: %s'):format(truncate(err, 200)))
            fail(respond)
        end
    end

    local probeOk, probe = pcall(run, nil)
    if not probeOk then
        print(('[custom-director] HTTP error: %s'):format(truncate(probe, 200)))
        handled = true
        fail(respond)
        return
    end
    if not probe.need_body then
        handled = true
        local sent, sendErr = pcall(function()
            respond(probe.status, probe.body, probe.headers)
        end)
        if not sent then
            print(('[custom-director] HTTP error: %s'):format(truncate(sendErr, 200)))
            fail(respond)
        end
        return
    end

    if not pcall(function() req.setDataHandler(finish) end) then
        handled = true
        fail(respond)
    end
end)

-- ---------------------------------------------------------------------------
-- Console / admin command: /agentapprove <id>
-- Console (source 0) or players with qbcore.god. Resources cannot call it.
-- ---------------------------------------------------------------------------

RegisterCommand('agentapprove', function(source, args)
    if source ~= 0 then
        if not IsPlayerAceAllowed(source, 'qbcore.god') then
            print('[custom-director] /agentapprove denied: qbcore.god required')
            return
        end
    else
        local invoking = GetInvokingResource and GetInvokingResource() or nil
        if invoking then
            print('[custom-director] /agentapprove denied: console-only from FXServer console')
            return
        end
    end

    local id = tonumber(args[1])
    if not id then
        print('[custom-director] usage: /agentapprove <id>')
        return
    end

    local approver = source == 0 and 'console' or ('player:' .. tostring(source))
    local result = AgentActions.Approve(id, approver)
    print(('[custom-director] /agentapprove id=%s ok=%s status=%s error=%s'):format(
        tostring(id), tostring(result.ok), tostring(result.status), tostring(result.error)))
end, false)

print(('[custom-director] loaded (enabled=%s). Exports: Propose, Approve, Reject, Get, List, Policy'):format(
    tostring(Config().enabled)))
