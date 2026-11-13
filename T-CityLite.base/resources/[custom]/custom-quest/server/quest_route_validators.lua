-- server/quest_route_validators.lua — 多站路线的服务端校验（R1：garbage / bus 共用）
--
-- 消费方是 quest 的 `validator` 步骤：`step.data.validator_id = 'validate_route_stop'`，
-- 由 `nodeComplete`（客户端到达）与 `dashboardStampDelivery`（电子印章）两条腿共用
-- （见 server/quest_step_gate.lua 与 main.lua 的 runStepValidator）。
--
-- 五条判据，顺序即实现顺序：
--   1 参数形状 → 2 玩家存在 → 3 站号合法 → 4 **顺序**（必须等于会话里的下一站）
--   → 5 职业/在岗 → 6 坐标存在 → 7 **距离** → 8 **载具**（可选）
-- 全部通过之后才写会话：先落账再校验会让「被拒的那一次」也推进进度，
-- 玩家跳一站就能把后面的站全顶掉。
--
-- 会话只放内存（0 新表）：键是 citizenid:questId，和 custom-quest 其它内存态
-- （PlayerBindings / TimeTrackers / CargoDamageRecords）同一套做法。

QuestRouteValidators = QuestRouteValidators or {}

--- key → { index = 下一站站号, startedAt = os.time() }
QuestRouteValidators.Sessions = QuestRouteValidators.Sessions or {}

local Sessions = QuestRouteValidators.Sessions

local function sessionKey(citizenid, questId)
    return tostring(citizenid) .. ':' .. tostring(questId)
end

--- 当前会话的下一站站号（没有会话时是第一站）
---@param citizenid string
---@param questId string
---@return number
function QuestRouteValidators.ExpectedIndex(citizenid, questId)
    local session = Sessions[sessionKey(citizenid, questId)]
    local index = session and tonumber(session.index)
    if not index or index < 1 then return 1 end
    return index
end

--- 清掉一个会话（任务完成 / 放弃 / 失败时调用；重复调用无害）
---@param citizenid string
---@param questId string
---@return boolean cleared
function QuestRouteValidators.ResetSession(citizenid, questId)
    local key = sessionKey(citizenid, questId)
    if Sessions[key] == nil then return false end
    Sessions[key] = nil
    return true
end

--- 校验器入口（签名与 QuestValidators.Register 的约定一致）
---@param source number
---@param stepData table  step.data 里声明的参数（由 QuestStepGate.ValidatorPayload 合成）
---@param questData table  { questId, citizenid, clientData }
---@return boolean passed
---@return string code
function QuestRouteValidators.ValidateStop(source, stepData, questData)
    if type(stepData) ~= 'table' then return false, 'invalid_step' end

    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not Player.PlayerData then return false, 'no_player' end

    local index = tonumber(stepData.index)
    if not index or index < 1 or index ~= math.floor(index) then return false, 'invalid_index' end

    local citizenid = Player.PlayerData.citizenid
    local questId = (type(questData) == 'table' and questData.questId) or 'unknown'

    -- 4. 顺序：只能完成"下一站"。
    -- 没有会话时（资源/服务器重启、或本趟第一次校验）以**这一步自己声明的站号**为准：
    -- 否则任务在 DB 里停在 N 站而内存会话丢了，第 N 站会被永久判成 out_of_order，
    -- 玩家只能放弃重接才能解开（CC 在 R1·P1 验收里抓到的死锁）。
    local session = Sessions[sessionKey(citizenid, questId)]
    local expected = (session and tonumber(session.index)) or index
    if expected < 1 then expected = index end
    if index ~= expected then
        return false, ('out_of_order: expected %d, got %d'):format(expected, index)
    end

    -- 5. 职业 / 在岗
    if stepData.job then
        local job = Player.PlayerData.job
        if type(job) ~= 'table' or job.name ~= stepData.job then
            return false, 'wrong_job'
        end
        if stepData.require_duty and not job.onduty then
            return false, 'off_duty'
        end
    end

    -- 6. 坐标（必须由服务端配置注入，不接受客户端坐标）
    local coords = stepData.coords
    if type(coords) ~= 'table' or coords.x == nil or coords.y == nil then
        return false, 'no_coords'
    end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false, 'no_ped' end

    -- 7. 距离
    local playerCoords = GetEntityCoords(ped)
    local distance = #(playerCoords - vector3(coords.x, coords.y, coords.z))
    local radius = tonumber(stepData.radius) or 10.0
    if distance > radius then
        return false, ('too_far: %.1f > %.1f'):format(distance, radius)
    end

    -- 8. 载具（可选）
    if stepData.require_vehicle then
        local vehicle = GetVehiclePedIsIn(ped, false)
        if not vehicle or vehicle == 0 then return false, 'no_vehicle' end
    end

    -- 全部判据通过之后才落账
    local key = sessionKey(citizenid, questId)
    Sessions[key] = {
        index = index + 1,
        startedAt = (session and session.startedAt) or os.time(),
    }
    return true, 'ok'
end

QuestValidators.Register('validate_route_stop', QuestRouteValidators.ValidateStop)
print('[quest-route-validators] ✅ validate_route_stop 已注册（多站路线：garbage / bus 共用）')
