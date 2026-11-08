local QBCore = exports['qb-core']:GetCoreObject()

-- qb-core 重启后，上面这份快照里的函数引用会全部失效（P1-6，PR #196）：
-- 本资源没有声明 qb-core 依赖，不会被重启级联带走，所以在 qb-core 起来时重解析一次。
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= 'qb-core' then return end
    -- ⚠️ 不能在事件里同步调：真机实测此刻 export 引用可能还指向 qb-core 旧 script host，
    -- 会抛 `Execution of function reference in script host failed`。放线程里重试到拿到新表。
    CreateThread(function()
        for _ = 1, 30 do
            local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
            if ok and core then
                QBCore = core
                return
            end
            Wait(500)
        end
    end)
end)
local Races = {}
local AvailableRaces = {}
local LastRaces = {}
local NotFinished = {}

-- Functions

local function SecondsToClock(seconds)
    seconds = tonumber(seconds)
    local retval
    if seconds <= 0 then
        retval = "00:00:00";
    else
        local hours = string.format("%02.f", math.floor(seconds / 3600));
        local mins = string.format("%02.f", math.floor(seconds / 60 - (hours * 60)));
        local secs = string.format("%02.f", math.floor(seconds - hours * 3600 - mins * 60));
        retval = hours .. ":" .. mins .. ":" .. secs
    end
    return retval
end

local function IsWhitelisted(CitizenId)
    local retval = false
    for _, cid in pairs(Config.WhitelistedCreators) do
        if cid == CitizenId then
            retval = true
            break
        end
    end
    local Player = QBCore.Functions.GetPlayerByCitizenId(CitizenId)
    if Player then
        local Perms = QBCore.Functions.GetPermission(Player.PlayerData.source)
        if Perms == "admin" or Perms == "god" then
            retval = true
        end
    end
    return retval
end

local function IsNameAvailable(RaceName)
    local retval = true
    for RaceId, _ in pairs(Races) do
        if Races[RaceId].RaceName == RaceName then
            retval = false
            break
        end
    end
    return retval
end

local function HasOpenedRace(CitizenId)
    local retval = false
    for _, v in pairs(AvailableRaces) do
        if v.SetupCitizenId == CitizenId then
            retval = true
        end
    end
    return retval
end

local function GetOpenedRaceKey(RaceId)
    local retval = nil
    for k, v in pairs(AvailableRaces) do
        if v.RaceId == RaceId then
            retval = k
            break
        end
    end
    return retval
end

local function GetCurrentRace(MyCitizenId)
    local retval = nil
    for RaceId, _ in pairs(Races) do
        for cid, _ in pairs(Races[RaceId].Racers) do
            if cid == MyCitizenId then
                retval = RaceId
                break
            end
        end
    end
    return retval
end

local function GetRaceId(name)
    local retval = nil
    for k, v in pairs(Races) do
        if v.RaceName == name then
            retval = k
            break
        end
    end
    return retval
end

-- 比赛控制权：只有「当前开放中的那场比赛」的创建者能开始/取消/改状态。
local function IsRaceHost(CitizenId, RaceId)
    local key = GetOpenedRaceKey(RaceId)
    if not key then return false end
    local opened = AvailableRaces[key]
    if not opened then return false end
    return opened.SetupCitizenId == CitizenId
end

local function GenerateRaceId()
    local RaceId = "LR-" .. math.random(1111, 9999)
    while Races[RaceId] ~= nil do
        RaceId = "LR-" .. math.random(1111, 9999)
    end
    return RaceId
end

-- Events

RegisterNetEvent('qb-lapraces:server:FinishPlayer', function(RaceData, TotalTime, TotalLaps, BestLap)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(RaceData) ~= 'table' then return end
    local raceId = RaceData.RaceId
    if type(raceId) ~= 'string' or Races[raceId] == nil then return end
    -- 🔒 只有这场比赛的参赛者能报成绩；成绩必须是合理数字（原来客户端报 BestLap=0.001 就能刷赛道记录）
    local racer = Races[raceId].Racers[Player.PlayerData.citizenid]
    -- 🔒 防重放用独立的 FinishHandled；Finished 只由本函数（服务端）写
    if not racer or racer.FinishHandled then return end

    -- 🔒 没开赛不能报成绩：Started 与 StartedAt 都由 StartRace 在服务端写
    --    （重开旧赛道时 SetupRace 会把两个都清掉，所以只认 StartedAt 不够）
    local startedAt = Races[raceId].StartedAt
    if not startedAt or Races[raceId].Started ~= true then
        TriggerClientEvent('QBCore:Notify', src, '这场比赛还没有开始', 'error')
        return
    end
    local OpenedKey = GetOpenedRaceKey(raceId)
    local opened = (OpenedKey and AvailableRaces[OpenedKey]) or nil

    TotalTime = tonumber(TotalTime)
    TotalLaps = tonumber(TotalLaps)
    BestLap = tonumber(BestLap) or TotalTime
    if not TotalTime or TotalTime <= 0 or not TotalLaps or TotalLaps < 1 or TotalLaps % 1 ~= 0 then return end

    -- 圈数必须与服务端开放时登记的圈数一致（不能少报圈数压低单圈均值）
    local serverLaps = opened and tonumber(opened.Laps) or nil
    if serverLaps and TotalLaps ~= serverLaps then return end

    -- 服务端计时对账：上下界都要有
    local elapsed = (GetGameTimer() - startedAt) / 1000
    if TotalTime > elapsed + 5 then return end
    -- 下界贴近服务端计时（只留 10 秒容差），不再允许"半程完赛"
    if TotalTime < elapsed - 10 then return end

    -- 单圈均值下限（默认 5 秒，可用 Config.MinLapSeconds 覆盖）
    local minLap = tonumber(Config.MinLapSeconds) or 5
    local averageLap = TotalTime / TotalLaps
    if averageLap < minLap then return end
    -- 最佳圈必须落在 [下限, 平均圈速]：最佳圈不可能比平均圈还慢
    if BestLap < minLap or BestLap > averageLap then return end

    racer.Finished = true          -- 服务端权威完赛标记（PlayersFinished 只统计它）
    racer.FinishHandled = true
    local AvailableKey = GetOpenedRaceKey(raceId)
    local PlayersFinished = 0
    local AmountOfRacers = 0
    for _, v in pairs(Races[raceId].Racers) do
        if v.Finished then
            PlayersFinished = PlayersFinished + 1
        end
        AmountOfRacers = AmountOfRacers + 1
    end
    local BLap
    if TotalLaps < 2 then
        BLap = TotalTime
    else
        BLap = BestLap
    end
    if LastRaces[RaceData.RaceId] ~= nil then
        LastRaces[RaceData.RaceId][#LastRaces[RaceData.RaceId]+1] =  {
            TotalTime = TotalTime,
            BestLap = BLap,
            Holder = {
                [1] = Player.PlayerData.charinfo.firstname,
                [2] = Player.PlayerData.charinfo.lastname
            }
        }
    else
        LastRaces[RaceData.RaceId] = {}
        LastRaces[RaceData.RaceId][#LastRaces[RaceData.RaceId]+1] =  {
            TotalTime = TotalTime,
            BestLap = BLap,
            Holder = {
                [1] = Player.PlayerData.charinfo.firstname,
                [2] = Player.PlayerData.charinfo.lastname
            }
        }
    end
    if Races[RaceData.RaceId].Records ~= nil and next(Races[RaceData.RaceId].Records) ~= nil then
        if BLap < Races[RaceData.RaceId].Records.Time then
            Races[RaceData.RaceId].Records = {
                Time = BLap,
                Holder = {
                    [1] = Player.PlayerData.charinfo.firstname,
                    [2] = Player.PlayerData.charinfo.lastname
                }
            }
            MySQL.update('UPDATE lapraces SET records = ? WHERE raceid = ?',
                {json.encode(Races[RaceData.RaceId].Records), RaceData.RaceId})
            TriggerClientEvent('qb-phone:client:RaceNotify', src, 'You have won the WR from ' .. tostring(Races[raceId].RaceName or 'Unknown') ..
                ' disconnected with a time of: ' .. SecondsToClock(BLap) .. '!')
        end
    else
        Races[RaceData.RaceId].Records = {
            Time = BLap,
            Holder = {
                [1] = Player.PlayerData.charinfo.firstname,
                [2] = Player.PlayerData.charinfo.lastname
            }
        }
        MySQL.update('UPDATE lapraces SET records = ? WHERE raceid = ?',
            {json.encode(Races[RaceData.RaceId].Records), RaceData.RaceId})
        TriggerClientEvent('qb-phone:client:RaceNotify', src, 'You have won the WR from ' .. tostring(Races[raceId].RaceName or 'Unknown') ..
            ' put down with a time of: ' .. SecondsToClock(BLap) .. '!')
    end
    if AvailableKey and AvailableRaces[AvailableKey] then
        AvailableRaces[AvailableKey].RaceData = Races[raceId]
    end
    TriggerClientEvent('qb-lapraces:client:PlayerFinishs', -1, raceId, PlayersFinished, Player)
    if PlayersFinished == AmountOfRacers then
        if NotFinished ~= nil and next(NotFinished) ~= nil and NotFinished[RaceData.RaceId] ~= nil and
            next(NotFinished[RaceData.RaceId]) ~= nil then
            for _, v in pairs(NotFinished[RaceData.RaceId]) do
                LastRaces[RaceData.RaceId][#LastRaces[RaceData.RaceId]+1] = {
                    TotalTime = v.TotalTime,
                    BestLap = v.BestLap,
                    Holder = {
                        [1] = v.Holder[1],
                        [2] = v.Holder[2]
                    }
                }
            end
        end
        Races[raceId].LastLeaderboard = LastRaces[raceId]
        Races[raceId].Racers = {}
        Races[raceId].Started = false
        Races[raceId].Waiting = false
        if AvailableKey and AvailableRaces[AvailableKey] then
            table.remove(AvailableRaces, AvailableKey)
        end
        LastRaces[raceId] = nil
        NotFinished[raceId] = nil
    end
    TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
end)

RegisterNetEvent('qb-lapraces:server:CreateLapRace', function(RaceName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)

    if IsWhitelisted(Player.PlayerData.citizenid) then
        if IsNameAvailable(RaceName) then
            TriggerClientEvent('qb-lapraces:client:StartRaceEditor', source, RaceName)
        else
            TriggerClientEvent('QBCore:Notify', source, 'There is already a race with this name.', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', source, 'You have not been authorized to race\'s to create.', 'error')
    end
end)

RegisterNetEvent('qb-lapraces:server:JoinRace', function(RaceData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(RaceData) ~= 'table' then return end
    local RaceId = RaceData.RaceId
    if type(RaceId) ~= 'string' or Races[RaceId] == nil then return end
    local AvailableKey = GetOpenedRaceKey(RaceId)
    -- 🔒 RaceId 存在但没开放 → AvailableKey 为 nil。原来先改 Waiting/Racers 再索引 nil：
    --    既崩服务端，又把这条赛道卡成"已在运行"（作者再也开不了，取消也取消不掉）。
    if not AvailableKey or not AvailableRaces[AvailableKey] then return end
    local CurrentRace = GetCurrentRace(Player.PlayerData.citizenid)
    if CurrentRace ~= nil and Races[CurrentRace] then
        local AmountOfRacers = 0
        local PreviousRaceKey = GetOpenedRaceKey(CurrentRace)
        for _, _ in pairs(Races[CurrentRace].Racers) do
            AmountOfRacers = AmountOfRacers + 1
        end
        Races[CurrentRace].Racers[Player.PlayerData.citizenid] = nil
        if (AmountOfRacers - 1) == 0 then
            Races[CurrentRace].Racers = {}
            Races[CurrentRace].Started = false
            Races[CurrentRace].Waiting = false
            if PreviousRaceKey and AvailableRaces[PreviousRaceKey] then
                table.remove(AvailableRaces, PreviousRaceKey)
            end
            TriggerClientEvent('QBCore:Notify', src, 'You were the only one in the race, the race had ended', 'error')
            TriggerClientEvent('qb-lapraces:client:LeaveRace', src, Races[CurrentRace])
        elseif PreviousRaceKey and AvailableRaces[PreviousRaceKey] then
            AvailableRaces[PreviousRaceKey].RaceData = Races[CurrentRace]
            TriggerClientEvent('qb-lapraces:client:LeaveRace', src, Races[CurrentRace])
        end
        TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
    end
    -- 🔒 只有未开赛的比赛才标 Waiting：开赛后加入如果也置 true，SetupRace 的 5 分钟
    --    定时器会按 Waiting 把**运行中**的比赛清掉。
    if not Races[RaceId].Started then
        Races[RaceId].Waiting = true
    end
    Races[RaceId].Racers[Player.PlayerData.citizenid] = {
        Checkpoint = 0,
        Lap = 1,
        Finished = false,
        FinishHandled = false,
        ClientFinished = false,
    }
    AvailableRaces[AvailableKey].RaceData = Races[RaceId]
    TriggerClientEvent('qb-lapraces:client:JoinRace', src, Races[RaceId], AvailableRaces[AvailableKey].Laps)
    TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
    local host = QBCore.Functions.GetPlayerByCitizenId(AvailableRaces[AvailableKey].SetupCitizenId)
    if host and host.PlayerData.source ~= Player.PlayerData.source then
        TriggerClientEvent('qb-phone:client:RaceNotify', host.PlayerData.source,
            string.sub(Player.PlayerData.charinfo.firstname, 1, 1) .. '. ' .. Player.PlayerData.charinfo.lastname ..
                ' the race has been joined!')
    end
end)

RegisterNetEvent('qb-lapraces:server:LeaveRace', function(RaceData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(RaceData) ~= 'table' then return end
    local RaceName
    if RaceData.RaceData ~= nil then
        RaceName = RaceData.RaceData.RaceName
    else
        RaceName = RaceData.RaceName
    end
    local raceId = type(RaceData.RaceId) == 'string' and RaceData.RaceId or GetRaceId(RaceName)
    if not raceId or Races[raceId] == nil then return end
    local AvailableKey = GetOpenedRaceKey(raceId)
    local opened = AvailableKey and AvailableRaces[AvailableKey] or nil
    if opened then
        local host = QBCore.Functions.GetPlayerByCitizenId(opened.SetupCitizenId)
        if host and host.PlayerData.source ~= Player.PlayerData.source then
            TriggerClientEvent('qb-phone:client:RaceNotify', host.PlayerData.source,
                string.sub(Player.PlayerData.charinfo.firstname, 1, 1) .. '. ' .. Player.PlayerData.charinfo.lastname ..
                    ' the race has been delivered!')
        end
    end
    local leavingRacer = Races[raceId].Racers[Player.PlayerData.citizenid]
    -- 不在参赛名单里（比赛已结算 / 从未加入）：直接退出
    if not leavingRacer then return end

    -- 🔒 已服务端确认完赛的人离开不补 DNF，但**清理逻辑必须照走**：
    --    如果他是最后一名车手，比赛要从开放列表移除、状态复位，否则会永久卡在"运行中"。
    local skipDnf = leavingRacer.FinishHandled == true

    local AmountOfRacers = 0
    for _, _ in pairs(Races[raceId].Racers) do
        AmountOfRacers = AmountOfRacers + 1
    end

    if not skipDnf then
        if NotFinished[raceId] == nil then
            NotFinished[raceId] = {}
        end
        NotFinished[raceId][#NotFinished[raceId] + 1] = {
            TotalTime = "DNF",
            BestLap = "DNF",
            Holder = {
                [1] = Player.PlayerData.charinfo.firstname,
                [2] = Player.PlayerData.charinfo.lastname
            }
        }
    end

    Races[raceId].Racers[Player.PlayerData.citizenid] = nil

    if (AmountOfRacers - 1) == 0 then
        -- 最后一名车手离开：把 DNF 记录并进 LastLeaderboard 并复位比赛
        if NotFinished ~= nil and next(NotFinished) ~= nil and NotFinished[raceId] ~= nil
            and next(NotFinished[raceId]) ~= nil then
            for _, v in pairs(NotFinished[raceId]) do
                if LastRaces[raceId] == nil then
                    LastRaces[raceId] = {}
                end
                LastRaces[raceId][#LastRaces[raceId] + 1] = {
                    TotalTime = v.TotalTime,
                    BestLap = v.BestLap,
                    Holder = { v.Holder[1], v.Holder[2] }
                }
            end
        end
        Races[raceId].LastLeaderboard = LastRaces[raceId]
        Races[raceId].Racers = {}
        Races[raceId].Started = false
        Races[raceId].Waiting = false
        Races[raceId].StartedAt = nil
        if AvailableKey and AvailableRaces[AvailableKey] then
            table.remove(AvailableRaces, AvailableKey)
        end
        LastRaces[raceId] = nil
        NotFinished[raceId] = nil
        TriggerClientEvent('QBCore:Notify', src, 'You were the only one in the race.The race had ended.', 'error')
        TriggerClientEvent('qb-lapraces:client:LeaveRace', src, Races[raceId])
    else
        if opened then opened.RaceData = Races[raceId] end
        TriggerClientEvent('qb-lapraces:client:LeaveRace', src, Races[raceId])
    end
    TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
end)

RegisterNetEvent('qb-lapraces:server:SetupRace', function(RaceId, Laps)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or type(RaceId) ~= 'string' then return end
    Laps = tonumber(Laps)
    if not Laps or Laps < 1 or Laps > 99 then return end
    if Races[RaceId] ~= nil then
        -- 🔒 只有这条赛道的创建者能把它挂到「开放中」列表（原来任何玩家都能把别人的赛道开出去）
        if Races[RaceId].Creator ~= Player.PlayerData.citizenid then
            TriggerClientEvent('QBCore:Notify', source, '你不是这条赛道的作者', 'error')
            return
        end
        if not Races[RaceId].Waiting then
            if not Races[RaceId].Started then
                -- 🔒 重开旧赛道：上一场的 StartedAt / 车手状态必须清掉，
                --    否则在重新 StartRace 之前就能用旧 StartedAt 报成绩
                Races[RaceId].StartedAt = nil
                Races[RaceId].Racers = {}
                Races[RaceId].Waiting = true
                AvailableRaces[#AvailableRaces+1] = {
                    RaceData = Races[RaceId],
                    Laps = Laps,
                    RaceId = RaceId,
                    SetupCitizenId = Player.PlayerData.citizenid
                }
                TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
                SetTimeout(5 * 60 * 1000, function()
                    if Races[RaceId].Waiting then
                        local AvailableKey = GetOpenedRaceKey(RaceId)
                        for cid, _ in pairs(Races[RaceId].Racers) do
                            local RacerData = QBCore.Functions.GetPlayerByCitizenId(cid)
                            if RacerData ~= nil then
                                TriggerClientEvent('qb-lapraces:client:LeaveRace', RacerData.PlayerData.source,
                                    Races[RaceId])
                            end
                        end
                        if AvailableKey and AvailableRaces[AvailableKey] then
                            table.remove(AvailableRaces, AvailableKey)
                        end
                        Races[RaceId].LastLeaderboard = {}
                        Races[RaceId].Racers = {}
                        Races[RaceId].Started = false
                        Races[RaceId].Waiting = false
                        LastRaces[RaceId] = nil
                        TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
                    end
                end)
            else
                TriggerClientEvent('QBCore:Notify', source, 'The race is already running', 'error')
            end
        else
            TriggerClientEvent('QBCore:Notify', source, 'The race is already running', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', source, 'This race does not exist :(', 'error')
    end
end)

RegisterNetEvent('qb-lapraces:server:CancelRace', function(raceId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or type(raceId) ~= 'string' then return end
    local AvailableKey = GetOpenedRaceKey(raceId)

    TriggerClientEvent('QBCore:Notify', src, 'Stopping the race: ' .. raceId, 'error')
    if AvailableKey == nil or Races[raceId] == nil then
        TriggerClientEvent('QBCore:Notify', src, 'Race not open: ' .. tostring(raceId), 'error')
        return
    end
    -- 🔒 只有创建者能取消（原来判定在 AvailableRaces[key] 上，key 为 nil 时还会崩）
    if not IsRaceHost(Player.PlayerData.citizenid, raceId) then return end

    for cid, _ in pairs(Races[raceId].Racers) do
        local RacerData = QBCore.Functions.GetPlayerByCitizenId(cid)
        if RacerData ~= nil then
            TriggerClientEvent('qb-lapraces:client:LeaveRace', RacerData.PlayerData.source, Races[raceId])
        end
    end

    table.remove(AvailableRaces, AvailableKey)
    Races[raceId].LastLeaderboard = {}
    Races[raceId].Racers = {}
    Races[raceId].Started = false
    Races[raceId].Waiting = false
    LastRaces[raceId] = nil
    TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
end)

RegisterNetEvent('qb-lapraces:server:UpdateRaceState', function(RaceId, Started, Waiting)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(RaceId) ~= 'string' or Races[RaceId] == nil then return end
    -- 🔒 原来这四条语句没有任何校验：任何玩家改包即可把任意比赛开起来 / 停掉，RaceId 不存在还会崩
    if not IsRaceHost(Player.PlayerData.citizenid, RaceId) then return end
    Races[RaceId].Started = Started == true
    Races[RaceId].Waiting = Waiting == true
end)

RegisterNetEvent('qb-lapraces:server:UpdateRacerData', function(RaceId, Checkpoint, Lap, Finished)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(RaceId) ~= 'string' or Races[RaceId] == nil then return end
    local CitizenId = Player.PlayerData.citizenid
    -- 🔒 只改自己在**这场**比赛里的进度；原来 RaceId 坏值 / 没报名都是 nil 索引崩服务端
    if Races[RaceId].Racers[CitizenId] == nil then return end
    Checkpoint = tonumber(Checkpoint)
    Lap = tonumber(Lap)
    if not Checkpoint or not Lap or Checkpoint < 0 or Lap < 1 then return end

    Races[RaceId].Racers[CitizenId].Checkpoint = Checkpoint
    Races[RaceId].Racers[CitizenId].Lap = Lap
    -- 🔒 客户端只能影响 UI 标记；完赛计数只认 FinishPlayer 写的 Finished
    Races[RaceId].Racers[CitizenId].ClientFinished = Finished == true

    TriggerClientEvent('qb-lapraces:client:UpdateRaceRacerData', -1, RaceId, Races[RaceId])
end)

RegisterNetEvent('qb-lapraces:server:StartRace', function(RaceId)
    local src = source
    local MyPlayer = QBCore.Functions.GetPlayer(src)
    local AvailableKey = GetOpenedRaceKey(RaceId)

    if not MyPlayer or type(RaceId) ~= 'string' then return end
    if RaceId == nil or AvailableKey == nil or Races[RaceId] == nil then
        TriggerClientEvent('QBCore:Notify', src, 'You are not in a race..', 'error')
        return
    end
    -- 🔒 只有创建者能发车
    if not IsRaceHost(MyPlayer.PlayerData.citizenid, RaceId) then
        TriggerClientEvent('QBCore:Notify', src, 'You are not the creator of the race..', 'error')
        return
    end

    AvailableRaces[AvailableKey].RaceData.Started = true
    AvailableRaces[AvailableKey].RaceData.Waiting = false
    -- 服务端计时起点：FinishPlayer 用它对账客户端报的 TotalTime / BestLap
    AvailableRaces[AvailableKey].RaceData.StartedAt = GetGameTimer()
    for CitizenId, _ in pairs(Races[RaceId].Racers) do
        local RacePlayer = QBCore.Functions.GetPlayerByCitizenId(CitizenId)
        if RacePlayer ~= nil then
            TriggerClientEvent('qb-lapraces:client:RaceCountdown', RacePlayer.PlayerData.source)
        end
    end
    TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
end)

RegisterNetEvent('qb-lapraces:server:SaveRace', function(RaceData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(RaceData) ~= 'table' or type(RaceData.Checkpoints) ~= 'table' then return end
    -- 🔒 原来任何玩家都能凭空保存一条赛道（无限写 DB）；创建权限应与 CreateLapRace 一致
    if not IsWhitelisted(Player.PlayerData.citizenid) then return end
    if type(RaceData.RaceName) ~= 'string' or #RaceData.Checkpoints == 0 then return end
    local RaceId = GenerateRaceId()
    local Checkpoints = {}
    for k, v in pairs(RaceData.Checkpoints) do
        Checkpoints[k] = {
            offset = v.offset,
            coords = v.coords
        }
    end
    Races[RaceId] = {
        RaceName = RaceData.RaceName,
        Checkpoints = Checkpoints,
        Records = {},
        Creator = Player.PlayerData.citizenid,
        RaceId = RaceId,
        Started = false,
        Waiting = false,
        Distance = math.ceil(RaceData.RaceDistance),
        Racers = {},
        LastLeaderboard = {}
    }
    MySQL.insert('INSERT INTO lapraces (name, checkpoints, creator, distance, raceid) VALUES (?, ?, ?, ?, ?)',
        {RaceData.RaceName, json.encode(Checkpoints), Player.PlayerData.citizenid,
         math.ceil(tonumber(RaceData.RaceDistance) or 0), RaceId})
end)

-- Callbacks

QBCore.Functions.CreateCallback('qb-lapraces:server:GetRacingLeaderboards', function(_, cb)
    cb(Races)
end)

QBCore.Functions.CreateCallback('qb-lapraces:server:GetRaces', function(_, cb)
    cb(AvailableRaces)
end)

QBCore.Functions.CreateCallback('qb-lapraces:server:GetListedRaces', function(_, cb)
    cb(Races)
end)

QBCore.Functions.CreateCallback('qb-lapraces:server:GetRacingData', function(_, cb, RaceId)
    cb(Races[RaceId])
end)

QBCore.Functions.CreateCallback('qb-lapraces:server:HasCreatedRace', function(source, cb)
    cb(HasOpenedRace(QBCore.Functions.GetPlayer(source).PlayerData.citizenid))
end)

QBCore.Functions.CreateCallback('qb-lapraces:server:IsAuthorizedToCreateRaces', function(source, cb, TrackName)
    cb(IsWhitelisted(QBCore.Functions.GetPlayer(source).PlayerData.citizenid), IsNameAvailable(TrackName))
end)

QBCore.Functions.CreateCallback('qb-lapraces:server:CanRaceSetup', function(_, cb)
    cb(Config.RaceSetupAllowed)
end)

QBCore.Functions.CreateCallback('qb-lapraces:server:GetTrackData', function(_, cb, RaceId)
    local result = MySQL.query.await('SELECT * FROM players WHERE citizenid = ?', {Races[RaceId].Creator})
    if result[1] ~= nil then
        result[1].charinfo = json.decode(result[1].charinfo)
        cb(Races[RaceId], result[1])
    else
        cb(Races[RaceId], {
            charinfo = {
                firstname = "Unknown",
                lastname = "Unknown"
            }
        })
    end
end)

-- Commands

QBCore.Commands.Add("cancelrace", "Cancel going race..", {}, false, function(source, args)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil

    if IsWhitelisted(Player.PlayerData.citizenid) then
        local RaceName = table.concat(args, " ")
        if RaceName ~= nil then
            local RaceId = GetRaceId(RaceName)
            if Races[RaceId].Started then
                local AvailableKey = GetOpenedRaceKey(RaceId)
                for cid, _ in pairs(Races[RaceId].Racers) do
                    local RacerData = QBCore.Functions.GetPlayerByCitizenId(cid)
                    if RacerData ~= nil then
                        TriggerClientEvent('qb-lapraces:client:LeaveRace', RacerData.PlayerData.source, Races[RaceId])
                    end
                end
                table.remove(AvailableRaces, AvailableKey)
                Races[RaceId].LastLeaderboard = {}
                Races[RaceId].Racers = {}
                Races[RaceId].Started = false
                Races[RaceId].Waiting = false
                LastRaces[RaceId] = nil
                TriggerClientEvent('qb-phone:client:UpdateLapraces', -1)
            else
                TriggerClientEvent('QBCore:Notify', source, 'This race has not started yet.', 'error')
            end
        end
    else
        TriggerClientEvent('QBCore:Notify', source, 'You have not been authorized to do this.', 'error')
    end
end)

QBCore.Commands.Add("togglesetup", "Turn on / off racing setup", {}, false, function(source, _)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil

    if IsWhitelisted(Player.PlayerData.citizenid) then
        Config.RaceSetupAllowed = not Config.RaceSetupAllowed
        if not Config.RaceSetupAllowed then
            TriggerClientEvent('QBCore:Notify', source, 'No more races can be created!', 'error')
        else
            TriggerClientEvent('QBCore:Notify', source, 'Races can be created again!', 'success')
        end
    else
        TriggerClientEvent('QBCore:Notify', source, 'You have not been authorized to do this.', 'error')
    end
end)

-- Threads

CreateThread(function()
    local races = MySQL.query.await('SELECT * FROM lapraces', {})
    if races[1] ~= nil then
        for _, v in pairs(races) do
            local Records = {}
            if v.records ~= nil then
                Records = json.decode(v.records)
            end
            Races[v.raceid] = {
                RaceName = v.name,
                Checkpoints = json.decode(v.checkpoints),
                Records = Records,
                Creator = v.creator,
                RaceId = v.raceid,
                Started = false,
                Waiting = false,
                Distance = v.distance,
                LastLeaderboard = {},
                Racers = {}
            }
        end
    end
end)
