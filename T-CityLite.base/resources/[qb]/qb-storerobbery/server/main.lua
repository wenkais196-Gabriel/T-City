local QBCore = exports['qb-core']:GetCoreObject()
local SafeCodes = {}
local cashA = 250
local cashB = 450

-- ═══════════════════════════════════════════════════════════════
-- 良心点数系统 (简化版: 每次上线重置, 纯内存, 单局反馈)
-- ═══════════════════════════════════════════════════════════════
--
-- 四原则:
--   ① 即时反馈 — 每次抢劫结束右侧弹窗显示当前值
--   ② 清晰可见 — 可通过 /conscience 查看
--   ③ 有意义的选择 — 弹窗提供 G 键改过入口
--   ④ 可补救 — 自首 +50, 奖励系数临时上调

local ConscienceData = {}  -- citizenid → { points, crimeCount }

local function InitConscience(citizenid)
    if not ConscienceData[citizenid] then
        ConscienceData[citizenid] = {
            points = 100,      -- 0~200, 每次上线重置
            crimeCount = 0,    -- 当次游戏犯罪次数
        }
    end
    return ConscienceData[citizenid]
end

--- @param src number 触发玩家
--- @param delta number 正=加分, 负=扣分
--- @param reason string 日志原因
local function AdjustConscience(citizenid, delta, reason)
    local data = InitConscience(citizenid)
    data.points = math.max(0, math.min(200, data.points + delta))
    if delta < 0 then data.crimeCount = data.crimeCount + 1 end
    print(('[qb-storerobbery] ⚖️ 良心 %s%d (%s) → %d'):format(
        delta > 0 and '+' or '', delta, reason, data.points))
end

--- 获取良心数据（供外部读取，后续审判系统用）
--- @param citizenid string
--- @return table { points:number, crimeCount:number }
local function GetConscience(citizenid)
    return InitConscience(citizenid)
end
exports('GetConscience', GetConscience)

-- ═══════════════════════════════════════════════════════════════
-- 自首系统 (双认证: 玩家申请 → 警察到场确认)
-- ═══════════════════════════════════════════════════════════════
--
-- 流程:
--   1. 玩家在手机拨打自首热线 → 创建 PendingSurrender (5分钟超时)
--   2. 通知所有在值警察: 位置 + 玩家名 + blip
--   3. 警察赶到现场 → /acceptsurrender [id] 确认
--   4. 确认后: 良心+50, 奖励系数上调, 记录自首状态
--   5. 5分钟无警察确认 → 自动取消

local SurrenderRecords = {}    -- citizenid → { timestamp, jailed } (已确认的自首)
local PendingSurrenders = {}   -- id → { src, citizenid, name, coords, policeAcceptedBy, timer }
local nextSurrenderId = 1
local SURRENDER_COOLDOWN = 30 * 60  -- 30 分钟冷却
local SURRENDER_TIMEOUT = 5 * 60    -- 5 分钟超时

--- 玩家请求自首 (Phase 1: 创建待处理)
RegisterNetEvent('qb-storerobbery:server:surrender', function()
    local src = source
    if not src or src == 0 then return end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then
        TriggerClientEvent('QBCore:Notify', src, "自首失败：无法获取玩家数据", "error")
        return
    end
    local citizenid = Player.PlayerData.citizenid
    local charName = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname

    -- ═════════════════════════════════════════════════════════
    -- 防滥用校验
    -- ═════════════════════════════════════════════════════════

    -- 1. 冷却校验
    local lastRecord = SurrenderRecords[citizenid]
    if lastRecord then
        local elapsed = os.time() - lastRecord.timestamp
        if elapsed < SURRENDER_COOLDOWN then
            TriggerClientEvent('QBCore:Notify', src,
                ("自首冷却中，还需等待 %d 分钟"):format(math.ceil((SURRENDER_COOLDOWN - elapsed) / 60)), "error")
            return
        end
    end

    -- 2. 必须有犯罪行为
    local conscience = GetConscience(citizenid)
    if conscience.crimeCount == 0 then
        TriggerClientEvent('QBCore:Notify', src, "你没有需要自首的罪行。", "primary")
        return
    end

    -- 3. Rate limit
    if exports['custom-security'] and exports['custom-security'].CheckRateLimit then
        if not exports['custom-security']:CheckRateLimit(src, "surrender_call", 3000) then
            TriggerClientEvent('QBCore:Notify', src, "操作过于频繁，请稍后再试", "error")
            return
        end
    end

    -- 4. 检查是否已有待处理的自首
    for sid, ps in pairs(PendingSurrenders) do
        if ps.src == src then
            TriggerClientEvent('QBCore:Notify', src, "你已有一个待警察确认的自首请求，请耐心等待警察到场。", "primary")
            return
        end
    end

    -- ═════════════════════════════════════════════════════════
    -- 创建待处理自首
    -- ═════════════════════════════════════════════════════════
    local coords = GetEntityCoords(GetPlayerPed(src))
    local street1, street2 = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local streetName = GetStreetNameFromHashKey(street1)
    if street2 and GetStreetNameFromHashKey(street2) ~= "" then
        streetName = streetName .. " & " .. GetStreetNameFromHashKey(street2)
    end

    local surrenderId = nextSurrenderId
    nextSurrenderId = nextSurrenderId + 1

    PendingSurrenders[surrenderId] = {
        src = src,
        citizenid = citizenid,
        name = charName,
        coords = coords,
        streetName = streetName,
        policeAcceptedBy = nil,
        timer = nil,
    }

    -- 通知自首玩家
    TriggerClientEvent('QBCore:Notify', src,
        "⚖️ 自首请求已发出。请留在原地等待警察到场确认。5分钟内无人确认将自动取消。", "success")

    -- 广播给所有在线警察
    local policeOnline = 0
    for _, playerId in ipairs(QBCore.Functions.GetPlayers()) do
        local Target = QBCore.Functions.GetPlayer(playerId)
        if Target and Target.PlayerData.job.name == 'police' and Target.PlayerData.job.onduty then
            policeOnline = policeOnline + 1
            TriggerClientEvent('qb-storerobbery:client:surrenderAlert', playerId, {
                id = surrenderId,
                name = charName,
                coords = { x = coords.x, y = coords.y, z = coords.z },
                street = streetName,
            })
        end
    end

    -- 5 分钟超时自动取消
    PendingSurrenders[surrenderId].timer = SetTimeout(SURRENDER_TIMEOUT * 1000, function()
        if PendingSurrenders[surrenderId] and not PendingSurrenders[surrenderId].policeAcceptedBy then
            TriggerClientEvent('QBCore:Notify', src, "⏰ 自首请求已超时（5分钟无人确认）。如需自首请重新拨打热线。", "error")
            -- 通知所有警察移除 blip
            for _, playerId in ipairs(QBCore.Functions.GetPlayers()) do
                local Target = QBCore.Functions.GetPlayer(playerId)
                if Target and Target.PlayerData.job.name == 'police' and Target.PlayerData.job.onduty then
                    TriggerClientEvent('qb-storerobbery:client:clearSurrenderBlip', playerId, surrenderId)
                end
            end
            PendingSurrenders[surrenderId] = nil
        end
    end)

    print(('[qb-storerobbery] ⚖️ PENDING SURRENDER #%d: %s at %s'):format(surrenderId, charName, streetName))
end)

--- 警察确认自首 (Phase 2: 警察到场确认)
--- 用法: /acceptsurrender [surrenderId]
--- 警察必须在自首玩家 30 米范围内
QBCore.Commands.Add('acceptsurrender', '确认自首（需在自首者附近）', {{
    name = 'id',
    help = '自首编号'
}}, false, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 只有警察才能确认
    if Player.PlayerData.job.name ~= 'police' then
        TriggerClientEvent('QBCore:Notify', src, "只有执勤警察可以确认自首。", "error")
        return
    end

    local surrenderId = tonumber(args[1])
    if not surrenderId or not PendingSurrenders[surrenderId] then
        TriggerClientEvent('QBCore:Notify', src, "无效的自首编号。使用 /surrenders 查看当前待处理的自首。", "error")
        return
    end

    local ps = PendingSurrenders[surrenderId]

    -- 检查是否已被其他警察确认
    if ps.policeAcceptedBy then
        TriggerClientEvent('QBCore:Notify', src, "该自首已被其他警员确认。", "error")
        return
    end

    -- 检查距离: 警察必须在 30 米内
    local policeCoords = GetEntityCoords(GetPlayerPed(src))
    local dist = #(policeCoords - ps.coords)
    if dist > 30.0 then
        TriggerClientEvent('QBCore:Notify', src,
            ("距离自首者太远（%.1f米），请靠近到 30 米内。"):format(dist), "error")
        return
    end

    -- ═════════════════════════════════════════════════════════
    -- 确认自首: 正式生效
    -- ═════════════════════════════════════════════════════════
    ps.policeAcceptedBy = src

    -- 清除超时计时器
    if ps.timer then
        ClearTimeout(ps.timer)
        ps.timer = nil
    end

    -- 记录自首状态（供审判系统调用）
    SurrenderRecords[ps.citizenid] = {
        timestamp = os.time(),
        jailed = false,
        acceptedBy = GetPlayerName(src),
    }

    -- 良心 +50
    AdjustConscience(ps.citizenid, 50, "自首（警员 " .. GetPlayerName(src) .. " 确认）")

    -- 上调奖励系数 30 分钟
    RewardCoefficients[ps.citizenid] = os.time() + 1800

    -- 通知自首玩家
    TriggerClientEvent('QBCore:Notify', ps.src,
        "✅ 自首已被警员 " .. GetPlayerName(src) .. " 确认。良心 +50，奖励系数 +20%（30分钟）。后续审判减半处理。", "success")

    -- 通知确认的警察
    TriggerClientEvent('QBCore:Notify', src,
        ("✅ 已确认 %s 的自首。请将其送往警局或释放。"):format(ps.name), "success")

    -- 通知所有警察清除 blip
    for _, playerId in ipairs(QBCore.Functions.GetPlayers()) do
        local Target = QBCore.Functions.GetPlayer(playerId)
        if Target and Target.PlayerData.job.name == 'police' and Target.PlayerData.job.onduty then
            TriggerClientEvent('qb-storerobbery:client:clearSurrenderBlip', playerId, surrenderId)
        end
    end

    print(('[qb-storerobbery] ✅ SURRENDER #%d ACCEPTED by %s: %s'):format(surrenderId, GetPlayerName(src), ps.name))

    -- 清除待处理
    PendingSurrenders[surrenderId] = nil
end, 'user')  -- 'user' 权限允许所有玩家，但函数内会校验 job

--- 查看待处理自首列表
QBCore.Commands.Add('surrenders', '查看当前待警察确认的自首列表', {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or Player.PlayerData.job.name ~= 'police' then
        TriggerClientEvent('QBCore:Notify', src, "只有警察可以查看。", "error")
        return
    end

    local count = 0
    for sid, ps in pairs(PendingSurrenders) do
        count = count + 1
        local dist = 0
        local policePed = GetPlayerPed(src)
        if policePed then
            local policeCoords = GetEntityCoords(policePed)
            dist = math.floor(#(policeCoords - ps.coords))
        end
        TriggerClientEvent('QBCore:Notify', src,
            ("自首 #%d: %s | 位置: %s | 距离: %dm"):format(sid, ps.name, ps.streetName, dist), "primary")
    end
    if count == 0 then
        TriggerClientEvent('QBCore:Notify', src, "当前没有待处理的自首请求。", "primary")
    end
end, 'user')

--- 获取自首记录（供审判系统调用）
--- @param citizenid string
--- @return table|nil { timestamp:number, jailed:boolean, acceptedBy:string }
local function GetSurrenderRecord(citizenid)
    return SurrenderRecords[citizenid]
end
exports('GetSurrenderRecord', GetSurrenderRecord)

-- ═══════════════════════════════════════════════════════════════
-- 统一奖励系数
-- 影响: 金钱 × 系数、经验/声望 × 系数、物品掉落概率 × 系数
-- ═══════════════════════════════════════════════════════════════
local RewardCoefficients = {}  -- citizenid → expiry (os.time)

--- 获取玩家当前奖励系数
--- @param citizenid string
--- @return number 1.0 = 基准, >1.0 = 上调
local function GetRewardCoefficient(citizenid)
    local expiry = RewardCoefficients[citizenid]
    if expiry and os.time() < expiry then
        return 1.2  -- 自首后 +20%
    end
    return 1.0
end
exports('GetRewardCoefficient', GetRewardCoefficient)

CreateThread(function()
    while true do
        SafeCodes = {
            [1] = math.random(1000, 9999),
            [2] = { math.random(1, 149), math.random(500.0, 600.0), math.random(360.0, 400), math.random(600.0, 900.0) },
            [3] = { math.random(150, 359), math.random(-300.0, -60.0), math.random(0, 100), math.random(-500.0, -160.0) },
            [4] = math.random(1000, 9999),
            [5] = math.random(1000, 9999),
            [6] = { math.random(1, 149), math.random(150.0, 200.0), math.random(100, 140), math.random(150.0, 220.0), math.random(-100, 100), math.random(140, 300) },
            [7] = math.random(1000, 9999),
            [8] = math.random(1000, 9999),
            [9] = math.random(1000, 9999),
            [10] = { math.random(1, 149), math.random(300.0, 500.0), math.random(200, 260), math.random(500.0, 800.0), math.random(300, 440), math.random(650, 900) },
            [11] = math.random(1000, 9999),
            [12] = math.random(1000, 9999),
            [13] = math.random(1000, 9999),
            [14] = { math.random(150, 450), math.random(-360.0, 0.0), math.random(360, 720) },
            [15] = math.random(1000, 9999),
            [16] = math.random(1000, 9999),
            [17] = math.random(1000, 9999),
            [18] = { math.random(150, 450), math.random(1.0, 100.0), math.random(360, 450), math.random(300.0, 340.0), math.random(350, 400), math.random(320.0, 340.0), math.random(350, 600) },
            [19] = math.random(1000, 9999),
        }
        Wait((1000 * 60) * 40)
    end
end)

-- =============================================================
-- 服务端权威抢劫引擎（替代旧版客户端驱动模式）
--
-- 流程:
--   1. 客户端请求 startRobbery → 服务端校验 + 标记 robbed
--   2. 服务端启动 25 秒权威计时器（客户端无法加速）
--   3. 倒计时结束自动发放奖励
--   4. 移除了每 2 秒的中间 ping（减少 90% 网络事件）
-- =============================================================

-- 活跃抢劫任务池: registerId → { src, timer, startTime, cancelTime }
local activeRobberies = {}
local ROBBERY_DURATION_MS = 25000  -- 25 秒标准时长

--- 根据实际逗留时间计算奖励倍率（阶梯惩罚）
--- 满 25 秒 = 1.0x，每少 1 秒约扣 4%，最低 0.1x
local function calculateTimeMultiplier(startTime, cancelTime)
    local totalDuration = ROBBERY_DURATION_MS
    local timeStayed = (cancelTime or GetGameTimer()) - startTime
    if timeStayed >= totalDuration then return 1.0 end
    if timeStayed <= 0 then return 0.1 end
    local mult = timeStayed / totalDuration
    -- 阶梯保底：最少 10%
    return math.max(0.1, mult)
end

local function issueStoreReward(src, register)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then
        activeRobberies[register] = nil
        return
    end

    local job = activeRobberies[register]
    local timeMult = calculateTimeMultiplier(job.startTime, job.cancelTime)
    local bags = math.random(1, math.floor(3 * timeMult + 0.5) or 1)
    local scale = exports['custom-economy']:GetEconomyRewardScale()
    local baseValue = math.random(cashA, cashB)
    local worthValue = math.floor(baseValue * scale * timeMult + 0.5)
    if worthValue < 1 then worthValue = 1 end
    local info = { worth = worthValue }

    exports['qb-inventory']:AddItem(src, 'markedbills', bags, false, info, 'qb-storerobbery:server:takeMoney')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['markedbills'], 'add')

    -- 小纸条（保险箱密码提示）
    if math.random(1, 100) <= Config.stickyNoteChance then
        local code = SafeCodes[Config.Registers[register].safeKey]
        local label
        if Config.Safes[Config.Registers[register].safeKey].type == 'keypad' then
            label = Lang:t('text.safe_code') .. tostring(code)
        else
            label = Lang:t('text.safe_code') .. ' '
            for i = 1, #code do
                label = label .. tostring(math.floor((code[i] % 360) / 3.60)) .. ' - '
            end
            label = label:sub(1, -3)
        end
        exports['qb-inventory']:AddItem(src, 'stickynote', 1, false, { label = label }, 'qb-storerobbery:server:takeMoney')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['stickynote'], 'add')
    end

    -- 通知玩家结算信息
    local pct = math.floor(timeMult * 100 + 0.5)
    local totalReward = worthValue * bags
    TriggerClientEvent('QBCore:Notify', src,
        ("抢劫结算: 逗留时间 %d%%，实得 $%d × %d 袋"):format(pct, worthValue, bags), "success")

    -- 良心扣除 + 弹窗通知
    local citizenid = Player.PlayerData.citizenid
    AdjustConscience(citizenid, -10, "商店抢劫 #" .. tostring(register))

    local conscience = GetConscience(citizenid)
    TriggerClientEvent('qb-storerobbery:client:conscienceNotify', src, {
        points = conscience.points,
        crimeCount = conscience.crimeCount,
        reward = totalReward,
    })

    activeRobberies[register] = nil
    print(('[qb-storerobbery] ✅ Register %d reward: $%d×%d bags (time=%d%%) → %s'):format(
        register, worthValue, bags, pct, GetPlayerName(src)))
end

--- 客户端请求开始抢劫 → 服务端校验 + 启动权威计时器 + 报警检查
RegisterNetEvent('qb-storerobbery:server:startRobbery', function(register)
    local src = source
    if not src or src == 0 then return end

    -- 1. Rate Limit
    if exports['custom-security'] and exports['custom-security'].CheckRateLimit then
        if not exports['custom-security']:CheckRateLimit(src, "store_robbery_claim", 3000) then
            TriggerClientEvent('QBCore:Notify', src, "操作过于频繁，请稍后再试", "error")
            return
        end
    end

    -- 2. 防重入
    if activeRobberies[register] then
        TriggerClientEvent('QBCore:Notify', src, "该收银机正在被抢劫中", "error")
        return
    end

    -- 3. 综合安全校验
    if not exports['custom-crime']:CheckStoreRobbery(src, register, false) then
        return
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local maxDist = tonumber(GetConvar("security_max_interaction_distance", "10.0")) or 10.0
    if #(playerCoords - Config.Registers[register][1].xyz) > maxDist or Config.Registers[register].robbed then
        return DropPlayer(src, 'Attempted exploit abuse')
    end

    -- 4. 标记 robbed + 启动服务端 25 秒权威计时器
    Config.Registers[register].robbed = true
    Config.Registers[register].time = Config.resetTime
    TriggerClientEvent('qb-storerobbery:client:setRegisterStatus', -1, register, Config.Registers[register])

    local startTime = GetGameTimer()
    local timer = SetTimeout(ROBBERY_DURATION_MS, function()
        issueStoreReward(src, register)
        TriggerClientEvent('qb-storerobbery:client:robberyComplete', src, register)
    end)

    activeRobberies[register] = { src = src, timer = timer, startTime = startTime, cancelTime = nil }
    -- 🌐 Atmosphere: chase scene on robbery start
    if Bus and Bus.SafeCall then Bus.SafeCall('atmosphere', 'PlayScene', src, 'chase') end
    print(('[qb-storerobbery] 🔫 Register %d robbery started by %s (25s timer)'):format(register, GetPlayerName(src)))

    -- 5. 报警系统检查 → 2 星通缉
    -- 检查该收银机关联的保险箱是否有报警系统 (25% 概率)
    -- 用 random 模拟 Config 中未显式标注的报警概率
    if math.random(1, 100) <= 50 then
        SetPlayerWantedLevel(src, 2)  -- 原生 2 星, NPC 警察追捕
        TriggerClientEvent('QBCore:Notify', src, "🚨 商店的报警系统被触发了！警察正在赶来！", "error")
        print(('[qb-storerobbery] 🚨 Store #%d alarm triggered, wanted level 2 set for %s'):format(register, GetPlayerName(src)))
    end
end)

--- 玩家中途取消逃跑 → 记录 cancelTime，计时器继续跑
--- 结算时按实际逗留时间计算阶梯惩罚倍率
RegisterNetEvent('qb-storerobbery:server:cancelRobbery', function(register)
    local src = source
    if activeRobberies[register] and activeRobberies[register].src == src then
        -- 仅记录逃跑时间，不销毁计时器
        -- 25 秒到点时根据 startTime→cancelTime 计算奖励倍率
        activeRobberies[register].cancelTime = GetGameTimer()
        local stayedMs = activeRobberies[register].cancelTime - activeRobberies[register].startTime
        local pct = math.floor(math.min(100, stayedMs / ROBBERY_DURATION_MS * 100))
        print(('[qb-storerobbery] 🏃 Register %d player fled at %d%% time (timer continues)'):format(register, pct))
    end
end)

-- 玩家下线 → 清理活跃抢劫
AddEventHandler('playerDropped', function()
    local src = source
    for register, job in pairs(activeRobberies) do
        if job.src == src then
            if job.timer then ClearTimeout(job.timer) end
            activeRobberies[register] = nil
            print(('[qb-storerobbery] 🚪 Register %d robbery cleaned up (player dropped)'):format(register))
        end
    end
end)

RegisterNetEvent('qb-storerobbery:server:setSafeStatus', function(safe)
    Config.Safes[safe].robbed = true
    TriggerClientEvent('qb-storerobbery:client:setSafeStatus', -1, safe, true)

    SetTimeout(math.random(40, 80) * (60 * 1000), function()
        Config.Safes[safe].robbed = false
        TriggerClientEvent('qb-storerobbery:client:setSafeStatus', -1, safe, false)
    end)
end)

RegisterNetEvent('qb-storerobbery:server:SafeReward', function(safe)
    local src = source
    -- Rate Limit: 3 秒熔断，防保险箱高频刷取
    if exports['custom-security'] and exports['custom-security'].CheckRateLimit then
        if not exports['custom-security']:CheckRateLimit(src, "store_robbery_safe", 3000) then
            TriggerClientEvent('QBCore:Notify', src, "操作过于频繁，请稍后再试", "error")
            return
        end
    end
    if not exports['custom-crime']:CheckStoreRobbery(src, "safe_" .. safe, true) then
        return
    end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local maxDist = tonumber(GetConvar("security_max_interaction_distance", "10.0")) or 10.0
    if #(playerCoords - Config.Safes[safe][1].xyz) > maxDist or Config.Safes[safe].robbed then
        return DropPlayer(src, 'Attempted exploit abuse')
    end
    local bags = math.random(1, 3)
    local scale = exports['custom-economy']:GetEconomyRewardScale()
    local worthValue = math.floor(math.random(cashA, cashB) * scale + 0.5)
    local info = {
        worth = worthValue
    }
    exports['qb-inventory']:AddItem(src, 'markedbills', bags, false, info, 'qb-storerobbery:server:SafeReward')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['markedbills'], 'add')
    local luck = math.random(1, 100)
    local odd = math.random(1, 100)
    if luck <= 10 then
        exports['qb-inventory']:AddItem(src, 'rolex', math.random(3, 7), false, false, 'qb-storerobbery:server:SafeReward')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['rolex'], 'add')
        if luck == odd then
            Wait(500)
            exports['qb-inventory']:AddItem(src, 'goldbar', 1, false, false, 'qb-storerobbery:server:SafeReward')
            TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['goldbar'], 'add')
        end
    end
end)

RegisterNetEvent('qb-storerobbery:server:callCops', function(type, safe, streetLabel, coords)
    local cameraId
    if type == 'safe' then
        cameraId = Config.Safes[safe].camId
    else
        cameraId = Config.Registers[safe].camId
    end
    local alertData = {
        title = '10-33 | Shop Robbery',
        coords = { x = coords.x, y = coords.y, z = coords.z },
        description = Lang:t('email.someone_is_trying_to_rob_a_store', { street = streetLabel, cameraId1 = cameraId })
    }
    TriggerClientEvent('qb-storerobbery:client:robberyCall', -1, type, safe, streetLabel, coords)
    TriggerClientEvent('qb-phone:client:addPoliceAlert', -1, alertData)
end)

RegisterNetEvent('qb-storerobbery:server:removeAdvancedLockpick', function()
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    exports['qb-inventory']:RemoveItem(source, 'advancedlockpick', 1, false, 'qb-storerobbery:server:removeAdvancedLockpick')
end)

RegisterNetEvent('qb-storerobbery:server:removeLockpick', function()
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    exports['qb-inventory']:RemoveItem(source, 'lockpick', 1, false, 'qb-storerobbery:server:removeLockpick')
end)

CreateThread(function()
    while true do
        local toSend = {}
        for k in ipairs(Config.Registers) do
            if Config.Registers[k].time > 0 and (Config.Registers[k].time - Config.tickInterval) >= 0 then
                Config.Registers[k].time = Config.Registers[k].time - Config.tickInterval
            else
                if Config.Registers[k].robbed then
                    Config.Registers[k].time = 0
                    Config.Registers[k].robbed = false
                    toSend[#toSend + 1] = Config.Registers[k]
                end
            end
        end

        if #toSend > 0 then
            --The false on the end of this is redundant
            TriggerClientEvent('qb-storerobbery:client:setRegisterStatus', -1, toSend, false)
        end

        Wait(Config.tickInterval)
    end
end)

QBCore.Functions.CreateCallback('qb-storerobbery:server:isCombinationRight', function(_, cb, safe)
    cb(SafeCodes[safe])
end)

QBCore.Functions.CreateCallback('qb-storerobbery:server:getPadlockCombination', function(_, cb, safe)
    cb(SafeCodes[safe])
end)

QBCore.Functions.CreateCallback('qb-storerobbery:server:getRegisterStatus', function(_, cb)
    cb(Config.Registers)
end)

QBCore.Functions.CreateCallback('qb-storerobbery:server:getSafeStatus', function(_, cb)
    cb(Config.Safes)
end)

-- =============================================
-- 动态警察门槛回调（配合 /setrobbery 调试命令）
-- =============================================
QBCore.Functions.CreateCallback('qb-storerobbery:server:getMinPolice', function(_, cb)
    -- 优先级: GlobalState (/tccops 运行时调试) > Convar (cfg 文件) > 默认 2
    local minPolice = GlobalState and GlobalState.crime_min_police_storerobbery
        or tonumber(GetConvar("crime_min_police_storerobbery", "2")) or 2
    cb(minPolice)
end)

-- 当 /setrobbery 更改门槛时，广播到所有客户端
RegisterNetEvent('qb-storerobbery:server:syncMinPolice', function()
    local minPolice = tonumber(GetConvar("crime_min_police_storerobbery", "2")) or 2
    TriggerClientEvent('qb-storerobbery:client:updateMinPolice', -1, minPolice)
end)

-- =============================================
-- 良心/自首 客户端接口
-- =============================================

--- 获取良心数据
QBCore.Functions.CreateCallback('qb-storerobbery:server:getConscience', function(source, cb)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then cb(nil) return end
    cb(GetConscience(Player.PlayerData.citizenid))
end)

--- 自首入口（已迁移到上方双认证流程）
-- RegisterNetEvent('qb-storerobbery:server:surrender') 现在在上方定义

--- 获取奖励系数（供客户端展示）
QBCore.Functions.CreateCallback('qb-storerobbery:server:getRewardCoefficient', function(source, cb)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then cb(1.0) return end
    cb(GetRewardCoefficient(Player.PlayerData.citizenid))
end)
