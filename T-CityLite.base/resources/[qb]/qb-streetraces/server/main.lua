local QBCore = exports['qb-core']:GetCoreObject()

local Races = {}

RegisterNetEvent('qb-streetraces:NewRace', function(RaceTable)
    local src = source
    if not src or src == 0 then return end
    local xPlayer = QBCore.Functions.GetPlayer(src)
    if not xPlayer then return end
    if type(RaceTable) ~= 'table' then return end

    -- [SECURITY] 只接受白名单字段，金额/奖池由服务端重建
    local stakeAmount = math.floor(tonumber(RaceTable.amount) or 0)
    if stakeAmount <= 0 or stakeAmount < Config.MinimumStake or stakeAmount > Config.MaximumStake then
        TriggerClientEvent('QBCore:Notify', src, 'Invalid stake amount', 'error')
        return
    end

    local sx, sy, sz = tonumber(RaceTable.startx), tonumber(RaceTable.starty), tonumber(RaceTable.startz)
    local ex, ey, ez = tonumber(RaceTable.endx), tonumber(RaceTable.endy), tonumber(RaceTable.endz)
    if not (sx and sy and sz and ex and ey and ez) then
        TriggerClientEvent('QBCore:Notify', src, 'Invalid race route', 'error')
        return
    end

    local startPos, endPos = vector3(sx, sy, sz), vector3(ex, ey, ez)
    if #(startPos - endPos) < Config.MinimumRaceDistance then
        TriggerClientEvent('QBCore:Notify', src, 'End Position Is Too Close', 'error')
        return
    end

    if not xPlayer.Functions.RemoveMoney('cash', stakeAmount, 'streetrace-created') then
        TriggerClientEvent('QBCore:Notify', src, 'You do not have ' .. Config.Currency .. stakeAmount .. '.', 'error')
        return
    end

    local RaceId = math.random(1000, 9999)
    while Races[RaceId] do RaceId = math.random(1000, 9999) end

    Races[RaceId] = {
        creator = src,
        started = false,
        startx = sx, starty = sy, startz = sz,
        endx = ex, endy = ey, endz = ez,
        amount = stakeAmount,
        pot = stakeAmount,
        joined = { src },
    }

    TriggerClientEvent('qb-streetraces:SetRace', -1, Races)
    TriggerClientEvent('qb-streetraces:SetRaceId', src, RaceId)
    TriggerClientEvent('QBCore:Notify', src, 'You joined the race for ' .. Config.Currency .. stakeAmount .. '.', 'success')
    UpdateRaceInfo(Races[RaceId])
end)

RegisterNetEvent('qb-streetraces:RaceWon', function(RaceId)
    local src = source
    if not src or src == 0 then return end
    local xPlayer = QBCore.Functions.GetPlayer(src)
    if not xPlayer then return end

    local race = Races[RaceId]
    if not race or not race.started then
        TriggerClientEvent('QBCore:Notify', src, 'Invalid race', 'error')
        return
    end

    local isInRace = false
    for _, joined in ipairs(race.joined) do
        if joined == src then isInRace = true; break end
    end
    if not isInRace then
        TriggerClientEvent('QBCore:Notify', src, 'You did not participate in this race', 'error')
        return
    end

    -- [SECURITY] 奖池由服务端按参赛人数重建，并先销毁赛局防重复领奖
    local pot = (tonumber(race.amount) or 0) * #race.joined
    Races[RaceId] = nil

    if pot <= 0 then return end
    xPlayer.Functions.AddMoney('cash', pot, 'race-won')
    TriggerClientEvent('QBCore:Notify', src, 'You won the race and ' .. Config.Currency .. pot .. ',- recieved', 'success')
    TriggerClientEvent('qb-streetraces:SetRace', -1, Races)
    TriggerClientEvent('qb-streetraces:RaceDone', -1, RaceId, GetPlayerName(src))
end)

RegisterNetEvent('qb-streetraces:JoinRace', function(RaceId)
    local src = source
    if not src or src == 0 then return end
    local xPlayer = QBCore.Functions.GetPlayer(src)
    if not xPlayer then return end

    local race = Races[RaceId]
    if not race or race.started then
        TriggerClientEvent('QBCore:Notify', src, 'Invalid race', 'error')
        return
    end

    -- 防止重复加入 / 重复扣款
    for _, joined in ipairs(race.joined) do
        if joined == src then
            TriggerClientEvent('QBCore:Notify', src, 'You are already in this race', 'error')
            return
        end
    end

    local zPlayer = QBCore.Functions.GetPlayer(race.creator)
    if zPlayer ~= nil then
        if xPlayer.Functions.RemoveMoney('cash', race.amount, 'streetrace-joined') then
            race.pot = race.pot + race.amount
            race.joined[#race.joined + 1] = src
            TriggerClientEvent('qb-streetraces:SetRace', -1, Races)
            TriggerClientEvent('qb-streetraces:SetRaceId', src, RaceId)
            TriggerClientEvent('QBCore:Notify', src, 'You joined the race', 'primary')
            TriggerClientEvent('QBCore:Notify', race.creator, GetPlayerName(src) .. ' Joined the race', 'primary')
            UpdateRaceInfo(race)
        else
            TriggerClientEvent('QBCore:Notify', src, 'You dont have enough cash', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, 'The person wo made the race is offline!', 'error')
        Races[RaceId] = nil
    end
end)

QBCore.Commands.Add(Config.Commands.CreateRace, 'Start A Street Race', { { name = 'amount', help = 'The Stake Amount For The Race.' } }, false, function(source, args)
    local src = source
    local amount = tonumber(args[1])

    if not amount then return TriggerClientEvent('QBCore:Notify', src, 'Usage: /' .. Config.Commands.CreateRace .. ' [AMOUNT]', 'error') end
    if amount < Config.MinimumStake then
        return TriggerClientEvent('QBCore:Notify', src, 'The minimum stake is ' .. Config.Currency .. Config.MinimumStake, 'error')
    end
    if amount > Config.MaximumStake then
        return TriggerClientEvent('QBCore:Notify', src, 'The maximum stake is ' .. Config.Currency .. Config.MaximumStake, 'error')
    end


    if GetJoinedRace(src) == 0 then
        TriggerClientEvent('qb-streetraces:CreateRace', src, amount)
    else
        TriggerClientEvent('QBCore:Notify', src, 'You Are Already In A Race', 'error')
    end
end)

QBCore.Commands.Add(Config.Commands.CancelRace, 'Stop The Race You Created', {}, false, function(source, _)
    CancelRace(source)
end)

QBCore.Commands.Add(Config.Commands.QuitRace, 'Leave A Race', {}, false, function(source, _)
    local src = source
    local RaceId = GetJoinedRace(src)
    if RaceId ~= 0 then
        if GetCreatedRace(src) ~= RaceId then
            local xPlayer = QBCore.Functions.GetPlayer(src)
            xPlayer.Functions.AddMoney('cash', Races[RaceId].amount, 'Race Quit')

            Races[RaceId].pot = Races[RaceId].pot - Races[RaceId].amount
            TriggerClientEvent('qb-streetraces:SetRace', -1, Races)

            TriggerClientEvent('qb-streetraces:StopRace', src)
            RemoveFromRace(src)
            TriggerClientEvent('QBCore:Notify', src, 'You Have Stepped Out Of The Race!', 'error')
            UpdateRaceInfo(Races[RaceId])
        else
            TriggerClientEvent('QBCore:Notify', src, '/' .. Config.Commands.CancelRace .. ' To Stop The Race', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, 'You Are Not In A Race ', 'error')
    end
end)

QBCore.Commands.Add(Config.Commands.StartRace, 'Start The Race', {}, false, function(source)
    local src = source
    local RaceId = GetCreatedRace(src)

    if RaceId ~= 0 then
        Races[RaceId].started = true
        TriggerClientEvent('qb-streetraces:SetRace', -1, Races)
        TriggerClientEvent('qb-streetraces:StartRace', -1, RaceId)
    else
        TriggerClientEvent('QBCore:Notify', src, 'You Have Not Started A Race', 'error')
    end
end)

function CancelRace(source)
    local RaceId = GetCreatedRace(source)
    local Player = QBCore.Functions.GetPlayer(source)

    if RaceId ~= 0 then
        for key in pairs(Races) do
            if Races[key] ~= nil and Races[key].creator == source then
                if not Races[key].started then
                    for _, iden in pairs(Races[key].joined) do
                        local xdPlayer = QBCore.Functions.GetPlayer(iden)
                        xdPlayer.Functions.AddMoney('cash', Races[key].amount, 'Race')
                        TriggerClientEvent('QBCore:Notify', xdPlayer.PlayerData.source, 'Race Has Ended, You Got Back ' .. Config.Currency .. Races[key].amount .. '', 'error')
                        TriggerClientEvent('qb-streetraces:StopRace', xdPlayer.PlayerData.source)
                    end
                else
                    TriggerClientEvent('QBCore:Notify', Player.PlayerData.source, 'The Race Has Already Started', 'error')
                end
                TriggerClientEvent('QBCore:Notify', source, 'Race Stopped!', 'error')
                Races[key] = nil
            end
        end
        TriggerClientEvent('qb-streetraces:SetRace', -1, Races)
    else
        TriggerClientEvent('QBCore:Notify', source, 'You Have Not Started A Race!', 'error')
    end
end

function UpdateRaceInfo(race)
    for _, src in pairs(race.joined) do
        TriggerClientEvent('qb-streetraces:UpdateRaceInfo', src, #race.joined, race.pot)
    end
end

function RemoveFromRace(identifier)
    for key in pairs(Races) do
        if Races[key] ~= nil and not Races[key].started then
            for i, iden in pairs(Races[key].joined) do
                if iden == identifier then
                    table.remove(Races[key].joined, i)
                end
            end
        end
    end
end

function GetJoinedRace(identifier)
    for key in pairs(Races) do
        if Races[key] ~= nil and not Races[key].started then
            for _, iden in pairs(Races[key].joined) do
                if iden == identifier then
                    return key
                end
            end
        end
    end
    return 0
end

function GetCreatedRace(identifier)
    for key in pairs(Races) do
        if Races[key] ~= nil and Races[key].creator == identifier and not Races[key].started then
            return key
        end
    end
    return 0
end
