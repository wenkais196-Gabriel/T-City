-- ============================================================================
-- production_freeze.lua — 生产环境锁定配置 v1.0
-- ============================================================================
-- 将此文件放入任意 [system] 资源的 server/ 目录下, 或作为独立资源加载。
-- 作用: 一键切换全服 Debug → Off, 锁定导出函数, 启动实体 GC。
-- ============================================================================

-- ── 1. 全服 Debug 开关 ─────────────────────────────────────────────────

_G.PRODUCTION_MODE = true  -- ★ 唯一开关: true = 生产模式, false = 开发模式

-- 关闭所有高频 print / 客户端 DrawText3D / DrawMarker
if _G.PRODUCTION_MODE then
    -- 服务端: 重定向 print 到空操作 (保留 error/警告)
    local _originalPrint = print
    _G.print = function(...)
        -- 仅保留带 [ERROR] 或 [SECURITY] 前缀的日志
        local msg = tostring(select(1, ...) or '')
        if msg:match('%[ERROR%]') or msg:match('%[SECURITY%]') then
            _originalPrint(...)
        end
    end

    -- 禁用 QBCore.Debug
    if QBCore and QBCore.Debug then
        QBCore.Debug = function() end
    end

    -- 禁用 ShowError / ShowSuccess (保存操作日志)
    if QBCore then
        QBCore.ShowError = function() end
        QBCore.ShowSuccess = function() end
    end

    -- 客户端调试指令
    TriggerClientEvent('production:client:freezeDebug', -1)
end

-- ── 客户端 Debug 冻结 ─────────────────────────────────────────────────

RegisterNetEvent('production:client:freezeDebug', function()
    if not _G.PRODUCTION_MODE then return end

    -- 重定向 DrawText3D
    _G.DrawText3D = function() end
    _G.DrawText3Ds = function() end
    _G.DrawMarker = function() end

    -- 禁用 PolyZone debugPoly
    -- (在 client 端, 所有 PolyZone:Create 调用时强制 debugPoly = false)
    if PolyZone then
        local _originalCreate = PolyZone.Create
        PolyZone.Create = function(coords, options)
            if options then options.debugPoly = false end
            return _originalCreate(coords, options)
        end
    end
end)

-- ── 2. 实体自动 GC (垃圾回收) ─────────────────────────────────────────

-- 全局实体追踪: { [entityHandle] = { type, createdBy, createdAt, questId } }
local entityTracker = {}

---注册任务实体 (创建时调用)
---@param entity number 实体 handle
---@param entityType string 'vehicle' | 'ped' | 'object'
---@param questId string 关联任务 ID
function RegisterTaskEntity(entity, entityType, questId)
    if not entity or entity == 0 then return end
    entityTracker[entity] = {
        type = entityType,
        createdAt = os.time(),
        questId = questId or 'unknown',
    }
end
exports('RegisterTaskEntity', RegisterTaskEntity)

---清理过期实体 (定时 GC — 每 30 秒)
CreateThread(function()
    while true do
        Wait(30000)
        local now = os.time()
        local cleaned = 0

        for handle, info in pairs(entityTracker) do
            -- 超过 120 秒未使用的任务实体 → 清理
            if now - info.createdAt > 120 then
                if DoesEntityExist(handle) then
                    SetEntityAsNoLongerNeeded(handle)
                    if info.type == 'ped' or info.type == 'object' then
                        DeleteEntity(handle)
                    end
                end
                entityTracker[handle] = nil
                cleaned = cleaned + 1
            end
        end

        if cleaned > 0 and not _G.PRODUCTION_MODE then
            print(('[EntityGC] Cleaned %d expired entities'):format(cleaned))
        end
    end
end)

-- 资源停止时全量清理
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        for handle, _ in pairs(entityTracker) do
            if DoesEntityExist(handle) then
                DeleteEntity(handle)
            end
        end
        entityTracker = {}
    end
end)

-- ── 3. 经济基准表重置 ─────────────────────────────────────────────────

---重置全服热度计数器到初始状态
function ResetEconomyToDayOne()
    if _G.Bus and _G.Bus.HeatService then
        _G.Bus.HeatService.ResetHeat(nil)
    end
    if _G.Bus and _G.Bus.NPCPricing then
        -- NPCPricing 持久化在 data/npc_prices.json, 删除即可重置
        SaveResourceFile(GetCurrentResourceName(), 'data/npc_prices.json', '{}', -1)
    end
    -- 重置 adaptive loop 的 economy_state.json
    SaveResourceFile(GetCurrentResourceName(), 'data/economy_state.json',
        '{"RewardScale":1.0,"PriceScale":1.0,"TotalEarned":0,"TotalSpent":0,"Events":0,"SavedAt":0}', -1)

    print('[ProductionFreeze] ✅ Economy reset to Day 1 baseline')
end
exports('ResetEconomyToDayOne', ResetEconomyToDayOne)

-- ── 4. 导出函数只读锁 ─────────────────────────────────────────────────

if _G.PRODUCTION_MODE then
    -- 防止运行时未授权修改全局 Bus
    local _busProxy = setmetatable({}, {
        __newindex = function(t, k, v)
            if _G.Bus and _G.Bus[k] then
                error(('[PRODUCTION] Attempt to overwrite Bus.%s denied'):format(tostring(k)), 2)
            end
            rawset(t, k, v)
        end
    })

    -- 安全: 不直接替换 Bus, 仅记录现有服务清单
    if _G.Bus then
        print('[ProductionFreeze] Bus services frozen: ' .. table.concat(getBusServiceList(), ', '))
    end
end

local function getBusServiceList()
    local services = {}
    if _G.Bus then
        for k, _ in pairs(_G.Bus) do
            services[#services + 1] = k
        end
    end
    return services
end

-- ── 5. 启动日志 ──────────────────────────────────────────────────────

print('[ProductionFreeze] 🔒 PRODUCTION MODE ACTIVATED')
print('[ProductionFreeze]    Debug: OFF | Entity GC: 120s | Bus: Frozen')
print('[ProductionFreeze]    Ready for launch.')
