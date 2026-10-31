-- client/player_target.lua — 对"人"的盘查入口（P3-1）
--
-- 以前要在街上盘查一个人，只能靠聊天命令或去 MDT 里手打 citizenid。
-- 这里把警员每天要用的四个动作挂到玩家身上：查证件 / 搜身 / 铐起 / 押送。
--
-- 边界：
--   * 只有**在岗警察**能看到选项（`canInteract`），平民对准别人不会出现靶心；
--   * 距离由服务端复验（既有的 SearchPlayer / CuffPlayer / EscortPlayer 都自己判 2.5 m，
--     超距直接拒绝或 DropPlayer）—— 客户端只负责"有没有这个入口"；
--   * 查证件走独立回调，只回公开资料（姓名 / citizenid / 执照），不回钱包与背包。

local TARGET_DISTANCE = 2.5

local function isOnDutyOfficer()
    local data = QBCore.Functions.GetPlayerData()
    local job = data and data.job
    return job ~= nil and job.name == 'police' and job.onduty == true
end

local function notify(text, kind)
    QBCore.Functions.Notify(text, kind or 'primary', 4000)
end

--- 当前对准的实体是不是真人玩家（不是自己的话才给选项）。
local function playerServerIdOf(entity)
    if not entity or entity == 0 then return nil end
    local owner = NetworkGetEntityOwner(entity)
    if not owner or owner == 0 then return nil end
    local serverId = GetPlayerServerId(owner)
    if not serverId or serverId == 0 or serverId == GetPlayerServerId(PlayerId()) then return nil end
    return serverId
end

CreateThread(function()
    if GetResourceState('qb-target') ~= 'started' then return end

    local ok = pcall(function()
        exports['qb-target']:AddGlobalPlayer({
            options = {
                {
                    num = 1,
                    icon = 'fa-solid fa-id-card',
                    label = '查证件',
                    canInteract = function() return isOnDutyOfficer() end,
                    action = function(entity)
                        local target = playerServerIdOf(entity)
                        if not target then return end
                        QBCore.Functions.TriggerCallback('police:server:showId', function(result)
                            if not result or not result.ok then
                                notify((result and result.reason) or '查证件失败', 'error')
                                return
                            end
                            notify(('证件：%s · %s · 驾照%s'):format(
                                tostring(result.name), tostring(result.citizenid),
                                result.license and '有效' or '无'), 'primary')
                        end, target)
                    end,
                },
                {
                    num = 2,
                    icon = 'fa-solid fa-hand',
                    label = '搜身',
                    canInteract = function() return isOnDutyOfficer() end,
                    action = function()
                        TriggerServerEvent('police:server:SearchPlayer')
                    end,
                },
                {
                    num = 3,
                    icon = 'fa-solid fa-handcuffs',
                    label = '铐起',
                    canInteract = function() return isOnDutyOfficer() end,
                    action = function(entity)
                        local target = playerServerIdOf(entity)
                        if target then TriggerServerEvent('police:server:CuffPlayer', target, false) end
                    end,
                },
                {
                    num = 4,
                    icon = 'fa-solid fa-person-walking-arrow-right',
                    label = '押送',
                    canInteract = function() return isOnDutyOfficer() end,
                    action = function(entity)
                        local target = playerServerIdOf(entity)
                        if target then TriggerServerEvent('police:server:EscortPlayer', target) end
                    end,
                },
            },
            distance = TARGET_DISTANCE,
        })
    end)

    if not ok then
        print('[custom-police] qb-target 玩家面板注册失败（qb-target 版本不支持 AddGlobalPlayer）')
    end
end)
