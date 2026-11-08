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

QBCore.Functions.CreateCallback('qb-scoreboard:server:GetScoreboardData', function(_, cb)
    local totalPlayers = 0
    local policeCount = 0
    local players = {}
    for _, v in pairs(QBCore.Functions.GetQBPlayers()) do
        if v then
            totalPlayers += 1
            if v.PlayerData.job.name == 'police' and v.PlayerData.job.onduty then
                policeCount += 1
            end
            players[v.PlayerData.source] = {}
            players[v.PlayerData.source].optin = QBCore.Functions.IsOptin(v.PlayerData.source)
        end
    end
    cb(totalPlayers, policeCount, players)
end)

RegisterNetEvent('qb-scoreboard:server:SetActivityBusy', function(activity, bool)
    -- 全仓没有任何客户端调用点（只有 client 侧的接收 handler），这个事件只该由服务端触发。
    -- 原来任何玩家都能发：① 用坏 key 让 `Config.IllegalActions[activity].busy` 抛错打断事件线程；
    -- ② 直接改所有人的"非法活动占用"状态（等于全服抢劫开关）。
    if source ~= 0 then return end
    if type(activity) ~= 'string' or type(Config.IllegalActions[activity]) ~= 'table' then return end
    if type(bool) ~= 'boolean' then return end
    Config.IllegalActions[activity].busy = bool
    TriggerClientEvent('qb-scoreboard:client:SetActivityBusy', -1, activity, bool)
end)
