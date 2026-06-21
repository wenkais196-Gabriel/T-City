-- client/quest_checkpoint.lua — Native Checkpoint 管理器 v0.11
--
-- 职责:
--   1. 创建/管理 GTA Native Checkpoint (ring / cylinder / arrow)
--   2. 3D 文字标签 (步骤标题 + 距离)
--   3. 轻量距离轮询线程 (200ms) — 自动检测到达
--   4. debounce 防重复触发 + Nonce 请求
--
-- 3 种 checkpoint 类型:
--   ring     → CP_TYPE_RING (3)    — 空中航路点 (fly-through)
--   cylinder → CP_TYPE_CYLINDER (0) — 地面目的地
--   arrow    → CP_TYPE_ARROW (4)    — 任务起始/交互点
--
-- 轮询线程统一处理所有步骤类型的到达检测:
--   - reach 步骤: 3D 距离 ≤ radius → 触发 quest:server:reach
--   - 其他步骤: checkpoint 仅做视觉指引，交互由各自的 node 事件处理

CheckpointManager = CheckpointManager or {}

local QBCore = exports['qb-core']:GetCoreObject()

local activeCheckpoint = nil
local activeThread = nil
local triggeredMap = {}   -- questId_stepId → boolean (debounce)
local heightTolerance = 50.0   -- 垂直容差默认值
local pollInterval = 200       -- 轮询间隔 ms

-- ═══════════════════════════════════════════════════════════
-- Checkpoint 类型常量
-- ═══════════════════════════════════════════════════════════

-- GTA Native checkpoint type enums
local CP_TYPE_CYLINDER          = 0
local CP_TYPE_RING              = 3
local CP_TYPE_ARROW             = 4
local CP_TYPE_CYLINDER_DIRECTION = 2

-- 类型推断: 步骤类型 → 默认 checkpoint 类型
local DEFAULT_CHECKPOINT_TYPE = {
    reach     = 'ring',
    ['goto']  = 'ring',    -- Lua 5.4 关键字
    validator = 'cylinder',
    interact  = 'arrow',
    deliver   = 'cylinder',
}

-- 类型名 → native 类型 ID
local CP_NATIVE_ID = {
    ring     = CP_TYPE_RING,
    cylinder = CP_TYPE_CYLINDER,
    arrow    = CP_TYPE_ARROW,
}

-- 类型名 → 默认检测半径
local DEFAULT_RADIUS = {
    ring     = 30.0,
    cylinder = 15.0,
    arrow    = 10.0,
}

-- ═══════════════════════════════════════════════════════════
-- 公开 API
-- ═══════════════════════════════════════════════════════════

--- 创建一个活跃 checkpoint 并启动轮询检测
---@param questId string
---@param stepId string
---@param stepType string  步骤类型 (reach/goto/validator/interact/deliver)
---@param stepData table   步骤 data (含 coords, checkpoint 配置等)
function CheckpointManager.Create(questId, stepId, stepType, stepData)
    CheckpointManager.Clear()

    local coords = stepData.coords or stepData.destCoords
    if not coords then return end

    -- 解析 checkpoint 配置
    local cpCfg = stepData.checkpoint or {}
    local cpTypeName = cpCfg.type or DEFAULT_CHECKPOINT_TYPE[stepType] or 'cylinder'
    local nativeType = CP_NATIVE_ID[cpTypeName] or CP_TYPE_CYLINDER
    local radius = cpCfg.radius or DEFAULT_RADIUS[cpTypeName] or 15.0
    local ht = cpCfg.height_tolerance or heightTolerance
    local color = cpCfg.color or { 0, 255, 0 }  -- 默认绿色
    local label = cpCfg.label or (stepData.label or stepData.title or 'Checkpoint')

    -- 适配圆柱体 checkpoint 的高度参数
    local nearHeight = 5.0
    local farHeight = 100.0
    if cpTypeName == 'ring' then
        -- 环型 checkpoint: 视觉上显示环的直径
        nearHeight = radius * 0.8
        farHeight = radius * 2.0
    elseif cpTypeName == 'cylinder' then
        nearHeight = 3.0
        farHeight = 10.0
    end

    -- 创建 native checkpoint
    local cpHandle = CreateCheckpoint(
        nativeType,
        coords.x, coords.y, coords.z - 1.0,  -- 稍微下沉让视觉更准确
        coords.x, coords.y, coords.z,         -- 指向点 (同一点)
        radius,
        color[1], color[2], color[3], 180,    -- RGBA
        0                                      -- reserved
    )

    if cpHandle == 0 or cpHandle == -1 then
        print(('[quest-checkpoint] ⚠️ Failed to create checkpoint: %s/%s'):format(questId, stepId))
        return
    end

    -- 设置圆柱体高度
    if cpTypeName == 'cylinder' or cpTypeName == 'arrow' then
        SetCheckpointCylinderHeight(cpHandle, nearHeight, farHeight, radius)
    end

    activeCheckpoint = {
        handle = cpHandle,
        questId = questId,
        stepId = stepId,
        stepType = stepType,
        coords = coords,
        radius = radius,
        heightTolerance = ht,
        cpType = cpTypeName,
        label = label,
        color = color,
    }

    -- 重置 debounce
    local key = questId .. '_' .. stepId
    triggeredMap[key] = false

    -- 启动轮询线程
    CheckpointManager._startPolling(activeCheckpoint)

    print(('[quest-checkpoint] ✅ Created: %s/%s type=%s radius=%.0f ht=%.0f'):format(
        questId, stepId, cpTypeName, radius, ht))
end

--- 清除当前 checkpoint 和轮询线程
function CheckpointManager.Clear()
    if activeCheckpoint then
        if activeCheckpoint.handle and activeCheckpoint.handle ~= 0 then
            DeleteCheckpoint(activeCheckpoint.handle)
        end
        activeCheckpoint = nil
    end
    if activeThread then
        activeThread = nil
    end
end

--- 清除指定 quest 的触发记录
function CheckpointManager.ClearTrigger(questId, stepId)
    local key = questId .. '_' .. stepId
    triggeredMap[key] = nil
end

--- 获取当前活跃 checkpoint 信息
function CheckpointManager.GetActive()
    return activeCheckpoint
end

--- 更新高度容差 (全局)
function CheckpointManager.SetHeightTolerance(ht)
    heightTolerance = ht
end

--- 更新轮询间隔
function CheckpointManager.SetPollInterval(ms)
    pollInterval = ms
end

-- ═══════════════════════════════════════════════════════════
-- 内部: 轮询检测线程
-- ═══════════════════════════════════════════════════════════

function CheckpointManager._startPolling(cp)
    -- 杀掉旧线程
    activeThread = nil

    Citizen.CreateThread(function()
        local threadRef = {}
        activeThread = threadRef

        local qId = cp.questId
        local sId = cp.stepId
        local key = qId .. '_' .. sId
        local targetVec = vector3(cp.coords.x, cp.coords.y, cp.coords.z)
        local r = cp.radius
        local ht = cp.heightTolerance
        local stepType = cp.stepType

        -- 注册清理事件
        RegisterNetEvent('quest:client:clearAllNodes', function()
            activeThread = nil
        end)

        while activeThread == threadRef and activeCheckpoint == cp do
            Citizen.Wait(pollInterval)

            -- 防御: 如果被外部清理了就退出
            if activeCheckpoint ~= cp then break end

            local ped = PlayerPedId()
            local pCoords = GetEntityCoords(ped)
            local dist3D = #(pCoords - targetVec)

            -- 检查是否在检测范围内 (3D 距离 + 垂直宽松)
            local inside = dist3D <= r

            -- 对于 ring 类型: 垂直也要在容差范围内
            if inside and stepType == 'reach' then
                local vertDist = math.abs(pCoords.z - targetVec.z)
                if vertDist > ht then
                    inside = false
                end
            end

            -- 进入 → 触发
            if inside and not triggeredMap[key] then
                triggeredMap[key] = true
                print(('[quest-checkpoint] 🎯 TRIGGERED: %s/%s dist=%.1f'):format(qId, sId, dist3D))

                -- 根据步骤类型触发不同事件
                if stepType == 'reach' or stepType == 'goto' then
                    -- reach 步骤: 请求 Nonce 后调服务端
                    QBCore.Functions.TriggerCallback(
                        'quest:server:requestNonce',
                        function(nonce)
                            if nonce then
                                TriggerServerEvent('quest:server:reach', qId, sId, nonce)
                            end
                        end
                    )
                end
                -- 其他类型 (validator/interact/deliver) 的到达由各自的 node 事件处理
                -- checkpoint 只负责 visual 指引
            end

            -- 离开区域 → 重置 debounce (允许再次进入触发)
            if not inside and triggeredMap[key] then
                -- 不立即重置，等完全离开 + 短暂冷却 (防止边界抖动)
                Citizen.Wait(1000)
                if activeCheckpoint ~= cp then break end
                local newDist = #(GetEntityCoords(PlayerPedId()) - targetVec)
                if newDist > r * 1.5 then
                    triggeredMap[key] = false
                    print(('[quest-checkpoint] 🔄 Debounce reset: %s/%s'):format(qId, sId))
                end
            end
        end
    end)
end

-- ═══════════════════════════════════════════════════════════
-- 清理事件挂钩
-- ═══════════════════════════════════════════════════════════

RegisterNetEvent('quest:client:clearAllNodes', function()
    CheckpointManager.Clear()
end)

-- 任务完成/失败时清理
AddEventHandler('quest:client:checkpointCleanup', function()
    CheckpointManager.Clear()
end)

print('[quest-checkpoint] ✅ CheckpointManager 已加载 (ring/cylinder/arrow)')
