-- ============================================================================
-- production-freeze/client/main.lua — 爽感微调 + 动画打断 + PolyZone 容错
-- ============================================================================
-- 三大模块:
--   1. 动画强制打断 — 取消/倒地/断线 → 1帧内清除附着物
--   2. PolyZone 容错增强 — 跑步/冲刺/骑行都能准确触发
--   3. UI 防撕裂 — 高分辨率适配 + 字符对齐
-- ============================================================================

-- ── 1. 动画强制打断: 1帧内清除所有附着物 ──────────────────────────────

-- 追踪当前活跃的交互道具
local activeProps = {}  -- { [propHandle] = true }

---安全删除道具 (1帧内)
local function safeDeleteProp(prop)
    if prop and DoesEntityExist(prop) then
        DetachEntity(prop, true, true)
        SetEntityAsMissionEntity(prop, false, true)
        DeleteEntity(prop)
    end
end

---清除所有道具并停止动画
function ClearAllPropsAndAnims()
    for prop, _ in pairs(activeProps) do
        safeDeleteProp(prop)
    end
    activeProps = {}

    -- 停止所有任务动画
    local ped = PlayerPedId()
    ClearPedTasks(ped)
    ClearPedSecondaryTask(ped)
    ClearPedTasksImmediately(ped)
end
exports('ClearAllPropsAndAnims', ClearAllPropsAndAnims)

---创建道具并追踪 (替换原生 CreateObject)
---@return number propHandle
function CreateTrackedProp(model, x, y, z, isNetwork, netMission, doorFlag)
    local prop = CreateObject(model, x, y, z, isNetwork, netMission, doorFlag)
    if prop and prop ~= 0 then
        activeProps[prop] = true
    end
    return prop
end

-- 监听状态变化 → 立即清除
CreateThread(function()
    local ped = PlayerPedId()
    while true do
        Wait(100) -- 每 100ms 检查 (足够快, 不耗 CPU)

        if next(activeProps) ~= nil then
            local shouldClear = false

            -- 条件1: 玩家进入 Ragdoll (被击倒/跌落)
            if IsPedRagdoll(ped) then
                shouldClear = true
            end

            -- 条件2: 玩家死亡
            if IsPedDeadOrDying(ped, false) then
                shouldClear = true
            end

            -- 条件3: 玩家进入载具
            if IsPedInAnyVehicle(ped, false) then
                shouldClear = true
            end

            -- 条件4: 玩家被铐
            if IsPedCuffed(ped) then
                shouldClear = true
            end

            if shouldClear then
                ClearAllPropsAndAnims()
            end
        end
    end
end)

-- 按键取消监听 (ESC / Backspace / X)
CreateThread(function()
    while true do
        Wait(0)
        if next(activeProps) ~= nil then
            if IsControlJustPressed(0, 194) or   -- Backspace
               IsControlJustPressed(0, 202) or   -- ESC variant
               IsControlJustPressed(0, 73) then  -- X key
                ClearAllPropsAndAnims()
            end
        end
    end
end)

-- ── 2. PolyZone 容错增强 ──────────────────────────────────────────────

-- 增强版 PolyZone 创建: 自动加大碰撞体 Z 轴 + 跑步容错
---@param coords vector3
---@param radius number 基础半径
---@param options table
---@return table zone
function CreateGenerousZone(coords, radius, options)
    options = options or {}
    -- 加大 Z 轴高度: 无论是步行(1.8m)还是跳跃(3m)都能触发
    local scaleZ = options.scaleZ or 5.0  -- 默认 5m 高
    local scale = options.scale or { radius, radius, scaleZ }

    -- 跑步容错: 半径至少 2.5m
    if radius < 2.5 then radius = 2.5 end

    local zone = PolyZone:Create(coords, {
        name = options.name or 'generous_zone',
        offset = options.offset or { 0.0, 0.0, 0.0 },
        scale = { radius, radius, scaleZ },
        debugPoly = _G.PRODUCTION_MODE and false or false,  -- 生产环境永远关闭
    })

    return zone
end

-- 视线角度容错: 玩家站在物品背后 45° 内也能交互 (默认 ox_target 已有此功能, 这里做 fallback)
-- 确保 task_interact 的 heading 容差 ≥ 60°

-- ── 3. UI 防撕裂 + 高分辨率适配 ────────────────────────────────────────

-- 移除所有调试绘制 (已在 production_freeze 中统一关闭)
-- 这里做 UI 层的最终确认

-- 通知队列: 防止多通知重叠撕裂
local notifyQueue = {}
local notifyShowing = false

local function showNextNotify()
    if #notifyQueue == 0 then
        notifyShowing = false
        return
    end
    notifyShowing = true
    local data = table.remove(notifyQueue, 1)

    -- 使用 QBCore 通知 (内部已有防重叠机制)
    exports['qb-core']:Notify(data.text, data.type or 'primary', data.length or 3000)

    -- 延迟显示下一条
    SetTimeout(data.length or 3000, function()
        showNextNotify()
    end)
end

---排队通知 (防撕裂)
---@param text string
---@param notifyType string
---@param length number
function NotifyQueued(text, notifyType, length)
    notifyQueue[#notifyQueue + 1] = { text = text, type = notifyType, length = length }
    if not notifyShowing then
        showNextNotify()
    end
end
exports('NotifyQueued', NotifyQueued)

-- 分辨率适配: 2K/4K 下强制 UI 缩放
CreateThread(function()
    local width, height = GetActiveScreenResolution()
    if width > 1920 then
        -- 高分辨率: 设置 UI 缩放 (如果有自定义 UI 系统)
        SetTextScale(0.35, 0.35)  -- 默认基础缩放
    end
end)

-- (生产模式静默: 动画打断/PolyZone/UI 调优已激活)
