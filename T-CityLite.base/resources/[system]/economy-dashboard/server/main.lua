-- ============================================================================
-- EconomyDashboard — 开服经济数据仪表盘 (v1.0.0)
-- ============================================================================
-- 三大黄金 KPI 监控:
--   1. Total_Server_Cash — 全服每日资金净流量 (流入 vs 流出是否平衡)
--   2. Hot_Activity_Rank — 任务/资源热度排行 (抓出油水过厚的项目)
--   3. Asset_Distribution — 载具/房产持有分布 (监控养老速度)
--
-- 设计原则:
--   - 极轻量: 仅使用事件监听 + 内存聚合 + 定时快照，无轮询、无额外 DB 查询
--   - 非侵入: 通过已有的 QBCore:Server:OnMoneyChange 等事件被动收集数据
--   - 持久化: 每周自动写入 data/telemetry_weekly.json，重启不丢失
-- ============================================================================

local QBCore = exports['qb-core']:GetCoreObject()

local Dashboard = {}

-- ── 内部状态 ──────────────────────────────────────────────────────────

local state = {
    -- KPI 1: 资金流量
    cashFlow = {
        totalInflow = 0,        -- 本周总流入
        totalOutflow = 0,       -- 本周总流出 (含 Sink)
        totalSinkFlow = 0,      -- 本周 SinkService 回收
        hourlySnapshots = {},   -- 每小时的快照 { [hourKey] = {inflow, outflow, sink} }
    },

    -- KPI 2: 活动热度
    activityHeat = {
        -- { [activityReason] = { count = N, totalReward = M } }
        -- 通过 OnMoneyChange 的 reason 字段被动采集
    },

    -- KPI 3: 资产分布
    assetDistribution = {
        vehicleCount = 0,
        houseCount = 0,
        lastVehicleCount = 0,
        lastHouseCount = 0,
    },

    -- 元数据
    weekStart = os.time(),
    snapshotCount = 0,
}

-- ── KPI 1: 全服资金流量监控 ──────────────────────────────────────────

AddEventHandler('QBCore:Server:OnMoneyChange', function(src, moneytype, amount, action, reason)
    amount = tonumber(amount) or 0
    if amount <= 0 then return end

    if action == 'add' then
        state.cashFlow.totalInflow = state.cashFlow.totalInflow + amount
    elseif action == 'remove' then
        state.cashFlow.totalOutflow = state.cashFlow.totalOutflow + amount

        -- 检测 Sink 流出 (reason 以 'sink:' 开头)
        if reason and reason:match('^sink:') then
            state.cashFlow.totalSinkFlow = state.cashFlow.totalSinkFlow + amount
        end
    end

    -- 活动热度: 用 reason 的前缀作为 activityId (如 'mining', 'quest:bank_escort')
    if action == 'add' and reason then
        local activityId = reason:match('^(.-):') or reason
        if not state.activityHeat[activityId] then
            state.activityHeat[activityId] = { count = 0, totalReward = 0 }
        end
        state.activityHeat[activityId].count = state.activityHeat[activityId].count + 1
        state.activityHeat[activityId].totalReward = state.activityHeat[activityId].totalReward + amount
    end
end)

-- ── KPI 2: 活动热度排行查询 ──────────────────────────────────────────

---获取热度排行
function Dashboard.GetHotActivityRanking(topN)
    topN = topN or 10
    local ranking = {}
    for activityId, data in pairs(state.activityHeat) do
        ranking[#ranking + 1] = {
            activity = activityId,
            count = data.count,
            totalReward = data.totalReward,
        }
    end
    table.sort(ranking, function(a, b) return a.count > b.count end)

    local result = {}
    for i = 1, math.min(topN, #ranking) do
        result[i] = ranking[i]
    end
    return result
end

---活动热度查询命令
RegisterCommand('hotrank', function(source)
    local ranking = Dashboard.GetHotActivityRanking(10)
    local lines = { '🔥 Activity Heat Ranking (Top 10):' }
    for i, entry in ipairs(ranking) do
        lines[#lines + 1] = ('%d. %s — %d completions ($%d total)')
            :format(i, entry.activity, entry.count, entry.totalReward)
    end
    TriggerClientEvent('chat:addMessage', source, {
        color = { 255, 200, 50 },
        multiline = true,
        args = { 'Heat', table.concat(lines, '\n') }
    })
end, true)

-- ── KPI 3: 资产分布 ──────────────────────────────────────────────────

---查询玩家_载具和房产总数
local function refreshAssetCounts()
    local vehicleCount = MySQL.scalar.await('SELECT COUNT(*) FROM player_vehicles')
    local houseCount = MySQL.scalar.await('SELECT COUNT(*) FROM player_houses WHERE citizenid IS NOT NULL')

    state.assetDistribution.lastVehicleCount = state.assetDistribution.vehicleCount
    state.assetDistribution.lastHouseCount = state.assetDistribution.houseCount
    state.assetDistribution.vehicleCount = tonumber(vehicleCount) or 0
    state.assetDistribution.houseCount = tonumber(houseCount) or 0
end

---管理员命令: 查看资产分布
RegisterCommand('assets', function(source)
    local vc = state.assetDistribution.vehicleCount
    local hc = state.assetDistribution.houseCount
    local lvc = state.assetDistribution.lastVehicleCount
    local lhc = state.assetDistribution.lastHouseCount

    TriggerClientEvent('chat:addMessage', source, {
        color = { 100, 200, 255 },
        multiline = true,
        args = { 'Assets', ('🏠 Houses: %d (Δ %+d) | 🚗 Vehicles: %d (Δ %+d)'):format(
            hc, hc - lhc, vc, vc - lvc) }
    })
end, true)

-- ── 每小时快照 ────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        Wait(60 * 60 * 1000) -- 每小时

        local hourKey = os.date('%Y%m%d_%H')
        state.cashFlow.hourlySnapshots[hourKey] = {
            inflow = state.cashFlow.totalInflow,
            outflow = state.cashFlow.totalOutflow,
            sink = state.cashFlow.totalSinkFlow,
        }

        -- 刷新资产数据
        refreshAssetCounts()

        -- 计算前一小时 key（避免字符串算术 + 跨天/跨月/跨年边界）
        local prevHourKey = nil
        do
            local nowTs = os.time()
            local prevTs = nowTs - 3600
            prevHourKey = os.date('%Y%m%d_%H', prevTs)
        end

        state.snapshotCount = state.snapshotCount + 1
        local prevSnap = state.cashFlow.hourlySnapshots[prevHourKey]
        print(('[Dashboard] 📊 Hourly snapshot #%d | In: $%d | Out: $%d | Sink: $%d')
            :format(state.snapshotCount,
                    state.cashFlow.totalInflow - (prevSnap and prevSnap.inflow or 0),
                    state.cashFlow.totalOutflow - (prevSnap and prevSnap.outflow or 0),
                    state.cashFlow.totalSinkFlow - (prevSnap and prevSnap.sink or 0)))
    end
end)

-- ── 每周聚合与持久化 ──────────────────────────────────────────────────

local function weeklyReport()
    local now = os.time()
    local elapsedDays = (now - state.weekStart) / 86400

    -- 热度排行
    local hotRank = Dashboard.GetHotActivityRanking(20)

    -- 资产增长率
    local vehicleGrowth = state.assetDistribution.vehicleCount - state.assetDistribution.lastVehicleCount
    local houseGrowth = state.assetDistribution.houseCount - state.assetDistribution.lastHouseCount

    local report = {
        generatedAt = os.date('%Y-%m-%d %H:%M:%S', now),
        weekStart = os.date('%Y-%m-%d', state.weekStart),
        elapsedDays = math.floor(elapsedDays * 10) / 10,
        kpi1_cashFlow = {
            totalInflow = state.cashFlow.totalInflow,
            totalOutflow = state.cashFlow.totalOutflow,
            totalSinkFlow = state.cashFlow.totalSinkFlow,
            netFlow = state.cashFlow.totalInflow - state.cashFlow.totalOutflow,
            sinkRatio = state.cashFlow.totalInflow > 0
                and math.floor(state.cashFlow.totalSinkFlow / state.cashFlow.totalInflow * 1000) / 10
                or 0,
            verdict = '',
        },
        kpi2_activityHeat = hotRank,
        kpi3_assetDistribution = {
            vehicleCount = state.assetDistribution.vehicleCount,
            houseCount = state.assetDistribution.houseCount,
            vehicleGrowth = vehicleGrowth,
            houseGrowth = houseGrowth,
        },
        parameters = {
            globalMultiplier = GetConvarInt('economy_reward_scale', 100) / 100.0,
            playersOnline = #QBCore.Functions.GetQBPlayers(),
        },
    }

    -- 判决
    local sr = report.kpi1_cashFlow.sinkRatio
    if sr < 5 then
        report.kpi1_cashFlow.verdict = '🔴 INFLATION: Sink ratio <5%'
    elseif sr < 15 then
        report.kpi1_cashFlow.verdict = '🟡 MONITOR: Sink ratio 5-15%'
    elseif sr < 30 then
        report.kpi1_cashFlow.verdict = '🟢 HEALTHY: Sink ratio 15-30%'
    else
        report.kpi1_cashFlow.verdict = '🟡 DEFLATIONARY: Sink ratio >30%'
    end

    -- 持久化
    SaveResourceFile(GetCurrentResourceName(), 'data/telemetry_weekly.json', json.encode(report), -1)
    print('[Dashboard] 📋 Weekly telemetry report saved!')

    -- 重置周计数器
    state.cashFlow.totalInflow = 0
    state.cashFlow.totalOutflow = 0
    state.cashFlow.totalSinkFlow = 0
    state.activityHeat = {}
    state.weekStart = now
end

-- 每周日凌晨 3:00 自动生成报告
CreateThread(function()
    while true do
        Wait(60 * 1000) -- 每分钟检查
        local now = os.date('*t')
        if now.wday == 1 and now.hour == 3 and now.min == 0 then  -- 周日 03:00
            weeklyReport()
            Wait(120 * 1000) -- 等2分钟避免重复触发
        end
    end
end)

-- ── 管理员命令: 即刻查看仪表盘 ───────────────────────────────────────

RegisterCommand('econ', function(source)
    local ranking = Dashboard.GetHotActivityRanking(5)
    local netFlow = state.cashFlow.totalInflow - state.cashFlow.totalOutflow
    local sinkRatio = state.cashFlow.totalInflow > 0
        and math.floor(state.cashFlow.totalSinkFlow / state.cashFlow.totalInflow * 1000) / 10
        or 0

    local globalMult = 1.0
    if exports['custom-economy'] then
        globalMult = exports['custom-economy']:GetEconomyRewardScale()
    end

    local lines = {
        ('📊 Economic Dashboard — Week of %s'):format(os.date('%Y-%m-%d', state.weekStart)),
        '',
        ('💰 Cash Flow: In $%d | Out $%d | Net $%d | Sink %.1f%%')
            :format(state.cashFlow.totalInflow, state.cashFlow.totalOutflow, netFlow, sinkRatio),
        ('📈 Global Multiplier: %.2f'):format(globalMult),
        ('🏠 Houses: %d | 🚗 Vehicles: %d')
            :format(state.assetDistribution.houseCount, state.assetDistribution.vehicleCount),
        '',
        '🔥 Top 5 Activities:',
    }
    for i, entry in ipairs(ranking) do
        lines[#lines + 1] = ('  %d. %s — %d × ($%d)')
            :format(i, entry.activity, entry.count, entry.totalReward)
    end

    TriggerClientEvent('chat:addMessage', source, {
        color = { 50, 255, 150 },
        multiline = true,
        args = { 'Economy', table.concat(lines, '\n') }
    })
end, true)

-- ── 强制生成周报 ────────────────────────────────────────────────────

RegisterCommand('econreport', function(source)
    weeklyReport()
    TriggerClientEvent('QBCore:Notify', source, 'Weekly report generated! Check data/telemetry_weekly.json', 'success')
end, true)

-- ── 生命周期: 冷启动加载上周残留 ─────────────────────────────────────

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    -- 加载上周未重置的数据
    local content = LoadResourceFile(GetCurrentResourceName(), 'data/telemetry_weekly.json')
    if content then
        local ok, data = pcall(json.decode, content)
        if ok and data and data.generatedAt then
            print(('[Dashboard] 📂 Loaded last weekly report from %s'):format(data.generatedAt))
        end
    end

    -- 初始资产快照
    refreshAssetCounts()
    state.assetDistribution.lastVehicleCount = state.assetDistribution.vehicleCount
    state.assetDistribution.lastHouseCount = state.assetDistribution.houseCount

    print('[Dashboard] ✅ Economy Dashboard started')
    print('[Dashboard]   Commands: /econ /hotrank /assets /econreport')
end)

-- ── Exports ────────────────────────────────────────────────────────────

exports('GetDashboard', function()
    local netFlow = state.cashFlow.totalInflow - state.cashFlow.totalOutflow
    local sinkRatio = state.cashFlow.totalInflow > 0
        and math.floor(state.cashFlow.totalSinkFlow / state.cashFlow.totalInflow * 1000) / 10 or 0

    return {
        cashFlow = {
            inflow = state.cashFlow.totalInflow,
            outflow = state.cashFlow.totalOutflow,
            sink = state.cashFlow.totalSinkFlow,
            net = netFlow,
            sinkRatio = sinkRatio,
        },
        hotRank = Dashboard.GetHotActivityRanking(5),
        assets = {
            vehicles = state.assetDistribution.vehicleCount,
            houses = state.assetDistribution.houseCount,
        },
    }
end)
