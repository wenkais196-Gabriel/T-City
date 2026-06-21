-- quest_manager.lua — 任务核心状态机  v0.7.0
--
-- 7 状态流转:
--   Not Started → [TriggerQuest] → In Progress (Step 0)
--     → [AdvanceStep] → In Progress (Step 1..N)
--     → [CompleteQuest] → Completed
--     → [FailQuest] → Failed
--     → [AbandonQuest] → Abandoned
--
-- 状态机保证:
--   - 同一 quest_id 同一时间只能有一个 'in_progress' (DB UNIQUE 约束)
--   - 步骤严格顺序执行（可配置 EnforceStepOrder）
--   - 每步完成后自动推进到下一步
--   - 最后一步完成后自动触发 CompleteQuest
--

-- 🔒 Security: 调试日志开关 — 生产环境设为 false
local QUEST_DEBUG = GetConvar('quest_debug', 'false') == 'true'
local function QuestPrint(msg, ...)
    if QUEST_DEBUG then
        print(string.format('[quest-manager] %s', ... and string.format(msg, ...) or msg))
    end
end
-- v0.7.0 增强:
--   - 修复 TriggerQuest 冷却/活跃检查的异步竞态
--   - script_trigger 步骤类型执行路径
--   - 步骤完成后广播全局事件（供外部脚本监听）
--   - custom_event 步骤自动建立 eventName 反向索引

QuestManager = QuestManager or {}

-- v0.8b: 地址池解析后模板缓存 — citizenid_questId → resolved_template
QuestManager._resolvedTemplates = {}

-- ══════════════════════════════════════════════════════════════
-- v0.8a: QuestNodes 兼容层 — 原 quest_nodes.lua 已移除，
-- atom_nodes 使用不同事件名。此 shim 将旧 API 桥接到客户端现有事件。
-- ══════════════════════════════════════════════════════════════
QuestNodes = {
    --- 节点类型 → 客户端事件名映射
    _eventMap = {
        GOTO      = 'quest:client:nodeGoto',
        INTERACT  = 'quest:client:nodeInteract',
        VALIDATOR = 'quest:client:nodeValidator',
        DELIVER   = 'quest:client:nodeDeliver',
        COMBAT    = 'quest:client:nodeCombat',
        WAIT      = 'quest:client:nodeWait',
        PLACEMENT = 'quest:client:nodePlacement',   -- v0.10: 实体放置回收节点
        DECISION  = 'story:client:offerDecision', -- v0.7 story-engine: 决策弹窗
    },

    --- 向客户端下发原子节点
    ExecuteNode = function(source, questId, stepId, nodeType, payload)
        -- 规范化: 模板中使用小写 (validator/interact)，映射表使用大写
        local normalizedType = nodeType and string.upper(tostring(nodeType))
        local eventName = QuestNodes._eventMap[normalizedType]
        if not eventName then
            print(('[quest-nodes] ⚠️ Unknown node type: %s → %s (quest=%s, step=%s)'):format(
                tostring(nodeType), normalizedType, questId, stepId))
            return
        end
        -- 将 questId/stepId 注入 payload，客户端事件处理器自行解构
        local data = { questId = questId, stepId = stepId }
        if payload then
            for k, v in pairs(payload) do data[k] = v end
        end
        TriggerClientEvent(eventName, source, data)
    end,

    --- 清理客户端所有节点（客户端自行管理 activeNode 生命周期）
    CancelAllNodes = function(source, questId)
        -- 客户端通过 ClearZone / ClearBlip 自行清理
        -- 此处发送一个清理事件作为兜底
        TriggerClientEvent('quest:client:clearAllNodes', source, { questId = questId })
    end,

    --- 服务端节点验证（stub — 实际验证在各 quest 的 validator 步骤中完成）
    ValidateNode = function(source, questId, stepId, clientData)
        return true, 'ok'
    end,
}

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 内部辅助
-- ==============================================================

--- 通过 source 获取 citizenid
local function getCidFromSource(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not Player.PlayerData then return nil end
    return Player.PlayerData.citizenid
end

--- 通过 citizenid 获取 source
local function getSourceFromCid(citizenid)
    local Player = QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if not Player then return nil end
    return Player.PlayerData.source
end

-- ==============================================================
-- 任务生命周期 API
-- ==============================================================

--- 接取任务（v0.7.0: 修复异步竞态）
---@param source number
---@param questId string
---@return boolean success
---@return string message
function QuestManager.TriggerQuest(source, questId)
    local citizenid = getCidFromSource(source)
    if not citizenid then
        return false, 'Player not found'
    end

    -- 1. 系统开关
    if not Config.Quest.Enabled then
        return false, 'Quest system is disabled'
    end

    -- 2. 模板存在性
    local template = QuestRegistry.GetTemplate(questId)
    if not template then
        return false, ('Quest not found: %s'):format(questId)
    end

    -- v0.8b: 地址池解析 — 如果模板有 address_pool 引用，深克隆并替换为真实坐标
    local hasAddressPools = false
    for _, step in ipairs(template.steps) do
        if step.data and step.data.address_pool then
            hasAddressPools = true
            break
        end
    end
    if hasAddressPools then
        -- 深克隆模板（避免污染原始注册模板）
        local cloned = {}
        for k, v in pairs(template) do
            if k == 'steps' then
                cloned.steps = {}
                for i, step in ipairs(v) do
                    cloned.steps[i] = {}
                    for sk, sv in pairs(step) do
                        if sk == 'data' and type(sv) == 'table' then
                            cloned.steps[i].data = {}
                            for dk, dv in pairs(sv) do cloned.steps[i].data[dk] = dv end
                        else
                            cloned.steps[i][sk] = sv
                        end
                    end
                end
            elseif k == 'rewards' and type(v) == 'table' then
                cloned.rewards = {}
                for rk, rv in pairs(v) do cloned.rewards[rk] = rv end
            elseif k == 'conditions' and type(v) == 'table' then
                cloned.conditions = {}
                for ck, cv in pairs(v) do cloned.conditions[ck] = cv end
            elseif k == 'logistics_ext' and type(v) == 'table' then
                cloned.logistics_ext = {}
                for lk, lv in pairs(v) do cloned.logistics_ext[lk] = lv end
            else
                cloned[k] = v
            end
        end

        -- 使用第一个 validator 步骤的坐标作为取货点
        local pickupCoords = { x = 0, y = 0, z = 0 }
        for _, step in ipairs(cloned.steps) do
            if step.data and step.data.coords then
                pickupCoords = step.data.coords
                break
            end
        end
        QuestAddressResolver.ResolveQuestAddresses(cloned, pickupCoords)
        template = cloned
        QuestManager._resolvedTemplates[citizenid .. '_' .. questId] = cloned
        print(('[quest-manager] 📍 Address pools resolved for quest: %s'):format(questId))
    end

    -- 2b. v0.11: Mixed 航空路线 — 根据玩家载具 class 选择 airport/helipad 路线
    if template.aviation_routes then
        local selectedRoute = nil

        -- 服务端获取载具 class（GetVehicleClass 可能不可用，用 model hash 推断）
        local ped = GetPlayerPed(source)
        local veh = ped ~= 0 and IsPedInAnyVehicle(ped, false) and GetVehiclePedIsIn(ped, false) or 0
        local vehClass = nil
        if veh and veh ~= 0 then
            -- 尝试 GetVehicleClass (服务端可用则直接取)
            local ok, cls = pcall(GetVehicleClass, veh)
            if ok and type(cls) == 'number' and cls > 0 then
                vehClass = cls
            else
                -- fallback: 用 model hash 推断
                -- 注: 部分服务端 GetVehicleClass 不可用，用 hash 表兜底
                -- airplane hash → 15 或 16 (匹配 vehicle_classes {15,16})
                -- helicopter hash → 17, 18, 19 (匹配 vehicle_classes {17,18,19})
                local model = GetEntityModel(veh)
                local airplanes = {
                    [GetHashKey('duster')] = 16,     [GetHashKey('stunt')] = 16,
                    [GetHashKey('mammatus')] = 15,   [GetHashKey('velum')] = 15,
                    [GetHashKey('velum2')] = 15,     [GetHashKey('nimbus')] = 16,
                    [GetHashKey('shamal')] = 16,     [GetHashKey('luxor')] = 16,
                    [GetHashKey('luxor2')] = 16,     [GetHashKey('miljet')] = 16,
                    [GetHashKey('titan')] = 16,      [GetHashKey('cuban800')] = 15,
                    [GetHashKey('jet')] = 15,        [GetHashKey('besra')] = 16,
                    [GetHashKey('cargoplane')] = 16, [GetHashKey('howard')] = 15,
                    [GetHashKey('alphaz1')] = 15,    [GetHashKey('mogul')] = 15,
                    [GetHashKey('rogue')] = 15,      [GetHashKey('seabreeze')] = 15,
                    [GetHashKey('microlight')] = 15, [GetHashKey('nokota')] = 15,
                    [GetHashKey('pyro')] = 16,       [GetHashKey('starling')] = 15,
                    [GetHashKey('bombushka')] = 16,  [GetHashKey('volatol')] = 16,
                    [GetHashKey('tula')] = 15,       [GetHashKey('avenger')] = 16,
                    -- 新增: 之前缺失的固定翼
                    [GetHashKey('dodo')] = 16,       [GetHashKey('lazer')] = 16,
                    [GetHashKey('hydra')] = 16,      [GetHashKey('molotok')] = 16,
                    [GetHashKey('vestra')] = 16,     [GetHashKey('blimp')] = 16,
                    [GetHashKey('blimp2')] = 16,     [GetHashKey('blimp3')] = 16,
                }
                local helicopters = {
                    [GetHashKey('maverick')] = 17,   [GetHashKey('frogger')] = 17,
                    [GetHashKey('frogger2')] = 17,   [GetHashKey('buzzard')] = 17,
                    [GetHashKey('buzzard2')] = 17,   [GetHashKey('annihilator')] = 18,
                    [GetHashKey('cargobob')] = 19,   [GetHashKey('cargobob2')] = 19,
                    [GetHashKey('cargobob3')] = 19,  [GetHashKey('cargobob4')] = 19,
                    [GetHashKey('supervolito')] = 17,[GetHashKey('supervolito2')] = 17,
                    [GetHashKey('swift')] = 17,      [GetHashKey('swift2')] = 17,
                    [GetHashKey('volatus')] = 17,    [GetHashKey('seasparrow')] = 17,
                    [GetHashKey('valkyrie')] = 18,   [GetHashKey('valkyrie2')] = 18,
                    [GetHashKey('skylift')] = 19,    [GetHashKey('havok')] = 17,
                    [GetHashKey('hunter')] = 18,     [GetHashKey('akula')] = 18,
                    [GetHashKey('savage')] = 18,     [GetHashKey('seasparrow2')] = 17,
                    [GetHashKey('seasparrow3')] = 17,[GetHashKey('annihilator2')] = 18,
                }
                vehClass = airplanes[model] or helicopters[model]
            end
        end

        if vehClass then
            QuestPrint('🔍 Vehicle detected: class=%d, model=%s', vehClass, veh and GetEntityModel(veh) or 0)
            for routeName, route in pairs(template.aviation_routes) do
                if route.vehicle_classes then
                    for _, cls in ipairs(route.vehicle_classes) do
                        if cls == vehClass then
                            selectedRoute = route
                            template._selectedAviationRoute = routeName
                            break
                        end
                    end
                end
                if selectedRoute then break end
            end
        end

        if not selectedRoute then
            -- 玩家不在载具中或载具类型不匹配 → 尝试 fallback
            -- 如果只有一个 route，默认选中
            local routeNames = {}
            for k, _ in pairs(template.aviation_routes) do table.insert(routeNames, k) end
            if #routeNames == 1 then
                selectedRoute = template.aviation_routes[routeNames[1]]
                template._selectedAviationRoute = routeNames[1]
            else
                return false, 'You must be in a valid aircraft (airplane or helicopter) to start this quest'
            end
        end

        if selectedRoute then
            -- 解析 departure + arrival (一次性，供航路点动态计算)
            local depCoords = selectedRoute.departure
                and QuestAddressResolver.ResolveSingleAddress(selectedRoute.departure) or nil
            local arrCoords = selectedRoute.arrival
                and QuestAddressResolver.ResolveSingleAddress(selectedRoute.arrival) or nil

            -- v0.11: 防止同机场内互飞 (LSIA→LSIA无意义)
            -- same_airport_allowed=false 时 arrival 池排除 departure 所在机场
            if selectedRoute.same_airport_allowed == false and depCoords then
                local depPrefix = depCoords.label and depCoords.label:match('^(%S+)')
                if depPrefix then
                    arrCoords = QuestAddressResolver.ResolveSingleAddress(
                        selectedRoute.arrival, depPrefix)
                    QuestPrint('🛬 Arrival: %s (excluded prefix: %s)',
                        arrCoords and arrCoords.label or 'nil', depPrefix)
                end
            end

            -- 注入 departure → 第一个 validator (绑定载具) + 紧随的 interact (装载)
            if depCoords then
                local foundValidator = false
                for _, step in ipairs(template.steps) do
                    if step.type == 'validator' and step.data and step.data.validator_id == 'validate_logistics_vehicle' then
                        step.data.coords = { x = depCoords.x, y = depCoords.y, z = depCoords.z }
                        step.data.validator_data = step.data.validator_data or {}
                        if selectedRoute.vehicle_classes then
                            step.data.validator_data.allowed_classes = selectedRoute.vehicle_classes
                        end
                        foundValidator = true
                    elseif foundValidator and step.type == 'interact' and step.data then
                        -- 紧随 validator 的 interact = 装载步骤，坐标跟随 departure
                        step.data.coords = { x = depCoords.x, y = depCoords.y, z = depCoords.z }
                        break
                    end
                end
            end

            -- 注入 arrival → validator (送达校验)
            if arrCoords then
                for _, step in ipairs(template.steps) do
                    if step.type == 'validator' and step.data and step.data.validator_id == 'validate_delivery_arrival' then
                        step.data.coords = { x = arrCoords.x, y = arrCoords.y, z = arrCoords.z }
                        step.data.validator_data = step.data.validator_data or {}
                        step.data.validator_data.destCoords = { x = arrCoords.x, y = arrCoords.y, z = arrCoords.z }
                        break
                    end
                end
            end

            -- v0.11: 动态航路点 — 根据 dep→arr 直线 + pct/alt 计算实际坐标
            if selectedRoute.waypoints and #selectedRoute.waypoints > 0 and depCoords and arrCoords then
                local wpIndex = 1
                for _, step in ipairs(template.steps) do
                    if step.type == 'reach' and wpIndex <= #selectedRoute.waypoints then
                        local wp = selectedRoute.waypoints[wpIndex]
                        local px = depCoords.x + (arrCoords.x - depCoords.x) * wp.pct
                        local py = depCoords.y + (arrCoords.y - depCoords.y) * wp.pct
                        local pz = wp.alt
                        if pz < 0 then
                            -- alt=-1 标记: 使用 arrival 高度 + 5m (着陆区上方)
                            pz = arrCoords.z + 5
                        end
                        step.data.coords = { x = px, y = py, z = pz }
                        if wp.checkpoint then
                            step.data.checkpoint = wp.checkpoint
                        end
                        QuestPrint('  📍 Waypoint %d: (%.0f, %.0f, %.0f) pct=%.2f alt=%.0f',
                            wpIndex, px, py, pz, wp.pct, wp.alt)
                        wpIndex = wpIndex + 1
                    end
                end
            end

            -- 注入归还步骤 (回到 departure)
            if depCoords then
                for _, step in ipairs(template.steps) do
                    if step.type == 'validator' and step.data and step.data.validator_id == 'validate_rental_cleanup' then
                        step.data.coords = { x = depCoords.x, y = depCoords.y, z = depCoords.z }
                        step.data.validator_data = step.data.validator_data or {}
                        step.data.validator_data.returnCoords = { x = depCoords.x, y = depCoords.y, z = depCoords.z }
                        break
                    end
                end
            end

            -- 注入卸载步骤坐标 (跟随 arrival)
            if arrCoords then
                local foundDelivery = false
                for _, step in ipairs(template.steps) do
                    if step.type == 'validator' and step.data and step.data.validator_id == 'validate_delivery_arrival' then
                        foundDelivery = true
                    elseif foundDelivery and step.type == 'interact' and step.data then
                        step.data.coords = { x = arrCoords.x, y = arrCoords.y, z = arrCoords.z }
                        break
                    end
                end
            end

            -- 奖励差异化
            if selectedRoute.rewards then
                template.rewards = selectedRoute.rewards
            end

            QuestPrint('🛩️ Aviation route selected: %s → %s',
                template._selectedAviationRoute, selectedRoute.departure and selectedRoute.departure.pool or '?')
            TriggerEvent('quest:server:onRouteSelected', citizenid, questId, template._selectedAviationRoute)
        end
    end

    -- 3. 职业/标签条件检查（同步，尽早失败）
    if template.required_tags then
        local Player = QBCore.Functions.GetPlayer(source)
        if Player and exports['custom-career'] then
            local ok, matchResult = pcall(function()
                return exports['custom-career']:PlayerMatchesTags(source, template.required_tags)
            end)
            if not ok or not matchResult then
                return false, 'You do not meet the requirements for this quest'
            end
        end
    end

    -- 4. 警察数量条件（同步）
    if template.conditions and template.conditions.min_police then
        local policeCount = QBCore.Functions.GetDutyCount('police')
        if policeCount < template.conditions.min_police then
            return false, ('Requires at least %d police officers on duty'):format(template.conditions.min_police)
        end
    end

    -- 4b. 🔧 P0 修复: 执照准入守卫（对接 custom-certificates）
    if template.conditions and template.conditions.min_license then
        local licenseType = template.conditions.min_license
        local hasLicense = false
        if exports['custom-certificates'] then
            local ok, result = pcall(function()
                return exports['custom-certificates']:HasLicense(source, licenseType)
            end)
            if ok then hasLicense = result end
        end
        if not hasLicense then
            local licenseLabels = { heavy = '重型载具执照', pilot = '飞行执照', boat = '船舶执照', driver = '驾照' }
            local label = licenseLabels[licenseType] or licenseType
            return false, ('接单失败：你需要持有 %s 且处于激活状态！'):format(label)
        end
    end

    -- 4c. v0.7 story-engine: 一次性门控 — 已完成剧情线禁止重玩
    if template.conditions and template.conditions.story_arc then
        local arcId = template.conditions.story_arc
        if exports['story-engine'] then
            local ok, completed = pcall(function()
                return exports['story-engine']:IsArcCompleted(source, arcId)
            end)
            if ok and completed then
                local arcNames = { cartel = '洛圣都地下帝国', police = '蓝墙内外', civilian = '洛圣都浮世绘' }
                local name = arcNames[arcId] or arcId
                return false, ('你已完成剧情线「%s」。创建新角色可重新体验。'):format(name)
            end
        end
    end

    -- 4c2. v0.7 DLC 框架: Arc 总开关检查
    if template.conditions and template.conditions.story_arc then
        local arcId = template.conditions.story_arc
        if exports['story-engine'] then
            local ok, enabled = pcall(function()
                return exports['story-engine']:IsArcEnabled(arcId)
            end)
            if ok and enabled == false then
                return false, '此剧情线暂未开放。'
            end
        end
    end

    -- 4c3. v0.7 DLC 框架: 前置 arc 依赖检查
    if template.conditions and template.conditions.prerequisite_arc then
        local prereqArc = template.conditions.prerequisite_arc
        if exports['story-engine'] then
            local ok, prereqCompleted = pcall(function()
                return exports['story-engine']:IsArcCompleted(source, prereqArc)
            end)
            if ok and not prereqCompleted then
                local arcNames = { cartel = '洛圣都地下帝国', police = '蓝墙内外', civilian = '洛圣都浮世绘' }
                local name = arcNames[prereqArc] or prereqArc
                return false, ('你需要先完成剧情线「%s」。'):format(name)
            end
        end
    end

    -- 4d. v0.7 story-engine: 剧情抉择条件检查（同步，读取 metadata story_flag_*）
    if template.conditions and template.conditions.player_choices then
        local Player = QBCore.Functions.GetPlayer(source)
        if Player then
            for _, pc in ipairs(template.conditions.player_choices) do
                local metaKey = ('story_flag_%s'):format(pc.flag)
                if Player.PlayerData.metadata[metaKey] ~= true then
                    local flagLabels = {
                        cartel_mercy = '饶恕 Aztecas 头目',
                        cartel_ruthless = '赶尽杀绝',
                        cartel_calculated = '搜集证据后再行动',
                        cartel_paranoid = '宁可错杀',
                        police_justice = '提交证据给 IA',
                        police_pragmatic = '保留证据当筹码',
                        police_whistleblower = '向媒体曝光',
                        police_insider = '接受交易',
                        civ_defiant = '拒绝交保护费',
                        civ_pragmatic = '交了保护费',
                        civ_ambitious = '贷款扩张',
                        civ_cautious = '稳扎稳打',
                    }
                    local label = flagLabels[pc.flag] or pc.flag
                    return false, ('剧情条件未满足：需要先做出选择「%s」'):format(label)
                end
            end
        end
    end

    -- 5. 活跃任务数 + 重复检查（缓存优先，异步 DB fallback）
    local activeQuests = QuestCache.GetActiveQuests(citizenid, function(cid)
        local result = {}
        QuestDB.GetActiveQuests(cid, function(quests)
            result = quests or {}
        end)
        return result
    end)

    if activeQuests then
        -- 最大活跃数检查
        if #activeQuests >= Config.Quest.MaxActiveQuests then
            return false, ('Maximum active quests reached (%d)'):format(Config.Quest.MaxActiveQuests)
        end

        -- 重复接取检查
        for _, q in ipairs(activeQuests) do
            if q.quest_id == questId then
                return false, 'Quest already in progress'
            end
        end
    end

    -- 6. v0.7.0: 冷却检查（通过 DB 异步回调处理）
    local cooldownHours = template.conditions and template.conditions.cooldown_hours or 0
    if cooldownHours > 0 then
        local onCooldown, remaining = QuestCooldown.IsOnCooldown(citizenid, questId)
        if onCooldown then
            local remainingMinutes = math.ceil(remaining / 60)
            return false, ('Quest on cooldown for %d more minutes'):format(remainingMinutes)
        end
    end

    -- 7. 创建任务记录
    local firstStep = template.steps[1] and template.steps[1].id or nil
    QuestDB.CreateQuest(citizenid, questId, firstStep)

    -- 8. 记录事件
    QuestDB.LogEvent(citizenid, questId, 'trigger', firstStep, {
        action = 'start',
        category = template.category,
        steps_total = #template.steps,
    })

    -- 8b. v1.0.0: 竞争/组队模式 → 获取排他锁
    if template.mode == 'competitive' then
        local acquired, _, rejectReason = QuestMutex.AcquireLock(questId, source, 'competitive')
        if not acquired then
            return false, rejectReason or 'Quest target already locked'
        end
    elseif template.mode == 'group' then
        -- 组队模式: 暂以单人创建 (队员通过 QuestGroup.AddMember 加入)
        local acquired, instanceId, rejectReason = QuestMutex.AcquireLock(questId, source, 'group')
        if not acquired then
            return false, rejectReason or 'Failed to create group'
        end
        -- 创建组队实例 (记录 instanceId 以便奖励阶段遍历队员)
        QuestGroup.CreateGroupInstance(source, questId)
        print(('[quest-manager] Group instance created: %s'):format(instanceId or 'unknown'))
    end

    -- 9. v0.7.0: 为 custom_event 步骤建立反向索引
    for _, step in ipairs(template.steps) do
        if step.type == 'custom_event' and step.data and step.data.event_name then
            QuestCache.IndexEvent(citizenid, questId, step.id, step.data.event_name)
        end
    end

    -- 10. v0.7.2: 更新缓存而非清空（支持无 MySQL 环境下运行）
    -- 将新创建的任务直接注入缓存，后续 ValidateStepOrder 可命中
    QuestCache.SetActiveQuests(citizenid, {{
        quest_id = questId,
        status = 'in_progress',
        current_step = firstStep,
        progress_data = '{}',
        started_at = os.date('%Y-%m-%d %H:%M:%S'),
    }})

    -- 10b. v1.0.0: 如果第一步是节点类型，初始化节点
    if firstStep then
        local firstNodeType = template.steps[1] and template.steps[1].type
        local firstPayload = template.steps[1] and template.steps[1].data
        if firstNodeType and QuestNodes then
            -- v0.7 story-engine: 解析 decision 步骤（从 decisions.lua 注入 prompt/options）
            local effectivePayload = firstPayload or {}
            if firstNodeType == 'decision' and effectivePayload.decision_id then
                local resolved = nil
                if exports['story-engine'] then
                    local ok, result = pcall(function()
                        return exports['story-engine']:GetDecision(effectivePayload.decision_id)
                    end)
                    if ok and result then resolved = result end
                end
                if resolved then
                    effectivePayload.prompt = resolved.prompt
                    effectivePayload.options = resolved.options
                    effectivePayload.timeout = effectivePayload.timeout or resolved.timeout or 120
                end
            end
            print(('[quest-manager] 🔗 ExecuteNode (first): quest=%s, step=%s, type=%s'):format(
                questId, firstStep, firstNodeType))
            QuestNodes.ExecuteNode(source, questId, firstStep, firstNodeType, effectivePayload)
        end
    end

    -- 11. 通知客户端
    local src = getSourceFromCid(citizenid)
    if src then
        TriggerClientEvent(Config.Quest.Events.QUEST_ACCEPTED, src, {
            quest_id = questId,
            title = template.title,
            description = template.description,
            steps = template.steps,
            current_step = firstStep,
        })
    end

    QuestPrint('🚀 Quest started: %s → %s', citizenid, questId)
    return true, ('Quest accepted: %s'):format(template.title)
end

--- 推进任务到下一步（v0.7.0: 新增 script_trigger 处理 + 事件广播）
---@param citizenid string
---@param questId string
---@param stepId string 当前（刚完成）的步骤 ID
---@param data table|nil 步骤相关数据
---@return boolean success
---@return string message
function QuestManager.AdvanceStep(citizenid, questId, stepId, data)
    -- v0.8b: 优先使用地址池解析后的模板（坐标已替换为真实地址）
    local template = QuestManager._resolvedTemplates[citizenid .. '_' .. questId]
        or QuestRegistry.GetTemplate(questId)
    if not template then
        return false, 'Quest template not found'
    end

    -- 1. 找到当前步骤索引
    local currentIndex = nil
    local currentStep = nil
    for i, step in ipairs(template.steps) do
        if step.id == stepId then
            currentIndex = i
            currentStep = step
            break
        end
    end
    if not currentIndex then
        return false, ('Step not found: %s'):format(stepId)
    end

    -- 2. 判断下一步
    local nextIndex = currentIndex + 1
    local nextStep = template.steps[nextIndex]

    -- 3. 更新进度数据
    local progressData = '{}'
    if data then
        progressData = json.encode(data)
    end

    -- v0.7.2: 如果下一步是 reward 类型，直接跳过到完成（reward是透明步骤）
    if nextStep and nextStep.type == 'reward' then
        nextStep = nil
    end

    -- 4. 如果没有下一步 → 任务完成
    if not nextStep then
        -- 触发完成
        QuestDB.CompleteQuest(citizenid, questId)
        QuestDB.LogEvent(citizenid, questId, 'complete', stepId, data)

        -- 发放奖励
        local src = getSourceFromCid(citizenid)
        print(('[quest-manager] 🏁 COMPLETING quest: %s, citizenid=%s, src=%s'):format(questId, citizenid, tostring(src)))
        if src then
            TriggerClientEvent(Config.Quest.Events.QUEST_COMPLETED, src, {
                quest_id = questId,
                title = template.title,
                rewards = template.rewards,
            })

            -- v0.7.2: 奖励在完成事件之后发放，避免奖励异常阻断客户端清理
            pcall(QuestRewards.GrantRewards, src, template.rewards, questId)

            TriggerClientEvent('QBCore:Notify', src,
                ('Quest completed: %s!'):format(template.title), 'success')
        else
            print('[quest-manager] ❌ getSourceFromCid returned nil — cannot send completion to client!')
        end

        -- 设置冷却
        local cooldownHours = template.conditions and template.conditions.cooldown_hours or 0
        if cooldownHours > 0 then
            QuestDB.SetCooldown(citizenid, questId, cooldownHours)
            QuestCache.InvalidateCooldowns(citizenid)
        end

        -- v0.7.0: 清理事件反向索引
        QuestCache.UnindexEvent(citizenid, questId)

        -- v1.0.0: 释放排他锁 + 清理节点
        local template = QuestRegistry.GetTemplate(questId)
        if template then
            if template.mode == 'competitive' or template.mode == 'group' then
                local src = getSourceFromCid(citizenid)
                if src then QuestMutex.ReleaseLock(questId, src) end
            end
            -- 清理客户端节点
            if src then QuestNodes.CancelAllNodes(src, questId) end
        end

        -- 缓存失效
        QuestCache.InvalidateActive(citizenid)
        QuestManager._resolvedTemplates[citizenid .. '_' .. questId] = nil

        -- v0.7.0: 广播任务完成事件
        TriggerEvent('quest:server:onQuestCompleted', citizenid, questId)
        TriggerEvent(('quest:server:onQuestCompleted:%s'):format(questId), citizenid)

        QuestPrint('✅ Quest completed: %s → %s', citizenid, questId)
        return true, 'Quest completed'
    end

    -- 5. 更新 DB 进度到下一步
    QuestDB.UpdateProgress(citizenid, questId, nextStep.id, progressData)
    QuestDB.LogEvent(citizenid, questId, 'advance', stepId, {
        from_step = stepId,
        to_step = nextStep.id,
        data = data,
    })

    -- v0.10: 已移除 InvalidateActive — 改为直接更新缓存，避免无 MySQL 环境下缓存空窗期

    -- 6. v0.7.0: 广播步骤完成事件（供外部脚本监听）
    TriggerEvent('quest:server:onStepCompleted', citizenid, questId, stepId, nextStep.id)
    TriggerEvent(('quest:server:onStepCompleted:%s:%s'):format(questId, stepId), citizenid)

    -- 6b. v1.0.0: 初始化下一步的原子节点 (如果适用)
    if nextStep and nextStep.type then
        local nodeType = nextStep.type:upper()
        local nodePayload = nextStep.data or nextStep.payload or {}
        -- v0.7.2: validator → interact 自动触发（装货/卸货无需再按E）
        if currentStep and currentStep.type == 'validator' and nextStep.type == 'interact' then
            local orig = nodePayload
            nodePayload = {}
            for k, v in pairs(orig) do nodePayload[k] = v end
            nodePayload.autoTrigger = true
        end
        -- v0.10: placement 节点预处理 — 生成回收区坐标
        if nodeType == 'PLACEMENT' then
            local dropzoneCfg = nodePayload.dropzone
            if dropzoneCfg and dropzoneCfg.relative_to_step then
                -- 从模板中查找参考步骤的坐标
                local originCoords = nil
                for _, s in ipairs(template.steps) do
                    if s.id == dropzoneCfg.relative_to_step and s.data and s.data.coords then
                        originCoords = s.data.coords
                        break
                    end
                end
                if originCoords then
                    local zone = QuestEntityPlacement.GenerateDropZone(
                        originCoords,
                        dropzoneCfg.search_radius and dropzoneCfg.search_radius.min or 15,
                        dropzoneCfg.search_radius and dropzoneCfg.search_radius.max or 40,
                        dropzoneCfg.zone_radius or 10.0
                    )
                    if zone then
                        nodePayload.dropzone = {
                            x = zone.x, y = zone.y, z = zone.z,
                            heading = zone.heading,
                            radius = zone.radius,
                        }
                        QuestEntityPlacement.CacheDropZone(citizenid, questId, zone)
                        print(('[quest-manager] 📍 DropZone cached for %s | %s'):format(citizenid, questId))
                    end
                end
            end
            -- 注入 action 字段（客户端需要知道做什么操作）
            nodePayload.action = nodePayload.action or 'detach_trailer'
        end

        local atomTypes = { GOTO = true, INTERACT = true, DELIVER = true, COMBAT = true, WAIT = true, VALIDATOR = true, PLACEMENT = true, DECISION = true }
        if atomTypes[nodeType] and QuestNodes then
            local src = getSourceFromCid(citizenid)
            if src then
                -- v0.7 story-engine: 解析 decision 步骤（从 decisions.lua 注入 prompt/options）
                if nodeType == 'DECISION' and nodePayload.decision_id then
                    local resolved = nil
                    if exports['story-engine'] then
                        local ok, result = pcall(function()
                            return exports['story-engine']:GetDecision(nodePayload.decision_id)
                        end)
                        if ok and result then resolved = result end
                    end
                    if resolved then
                        nodePayload.prompt = resolved.prompt
                        nodePayload.options = resolved.options
                        nodePayload.timeout = nodePayload.timeout or resolved.timeout or 120
                    end
                end
                print(('[quest-manager] 🔗 ExecuteNode: src=%d, quest=%s, step=%s, type=%s, auto=%s'):format(
                    src, questId, nextStep.id, nodeType, tostring(nodePayload.autoTrigger)))
                QuestNodes.ExecuteNode(src, questId, nextStep.id, nodeType, nodePayload)
            end
        end
    end

    -- 7. v0.7.0: 处理 script_trigger 类型步骤
    if nextStep.type == 'script_trigger' and nextStep.data and nextStep.data.export_path then
        local exportPath = nextStep.data.export_path
        local exportArgs = nextStep.data.args or {}

        -- 安全检查：export 路径白名单
        if not QuestSecurity.IsExportAllowed(exportPath) then
            print(('[quest-manager] ⚠️ Script trigger blocked: %s not in whitelist'):format(exportPath))
            return false, 'Script trigger not allowed'
        end

        local resource, method = exportPath:match('^(.-):(.+)$')
        if not resource or not exports[resource] then
            print(('[quest-manager] ⚠️ Script trigger failed: resource %s not available'):format(tostring(resource)))
            return false, 'Export resource not available'
        end

        -- 异步调用外部 export，等待外部脚本通过 CompleteStep 回传完成信号
        local src = getSourceFromCid(citizenid)
        pcall(function()
            exports[resource][method](src, table.unpack(exportArgs))
        end)

        print(('[quest-manager] 🔗 Script trigger fired: %s → %s'):format(exportPath, nextStep.id))
        -- 不自动推进！等待外部脚本回调 CompleteStep
    end

    -- 8. 通知客户端步骤变更
    local src = getSourceFromCid(citizenid)
    if src then
        TriggerClientEvent(Config.Quest.Events.QUEST_STEP_ADVANCED, src, {
            quest_id = questId,
            from_step = stepId,
            to_step = nextStep.id,
            next_step_title = nextStep.title,
            next_step_description = nextStep.description,
            next_step_type = nextStep.type,
            next_step_data = nextStep.data,
        })

        TriggerClientEvent('QBCore:Notify', src,
            ('Step completed: %s → %s'):format(currentStep.title, nextStep.title), 'primary')
    end

    -- v0.8b: 更新缓存为新的当前步骤（缓存过期/无MySQL 时兜底重建）
    local quests = QuestCache.GetActiveQuests(citizenid)
    if quests and #quests > 0 then
        for _, q in ipairs(quests) do
            if q.quest_id == questId then
                q.current_step = nextStep.id
                q.progress_data = progressData
                break
            end
        end
        QuestCache.SetActiveQuests(citizenid, quests)
    else
        -- 缓存空窗期兜底：直接写入最小条目，确保 ValidateStepOrder 不失败
        QuestCache.SetActiveQuests(citizenid, {{
            quest_id = questId,
            status = 'in_progress',
            current_step = nextStep.id,
            progress_data = progressData,
            started_at = os.date('%Y-%m-%d %H:%M:%S'),
        }})
    end

    return true, ('Advanced to step: %s'):format(nextStep.title)
end

--- 直接完成指定步骤（外部脚本调用）
---@param source number
---@param questId string
---@param stepId string
---@return boolean success
---@return string message
function QuestManager.CompleteStep(source, questId, stepId)
    local citizenid = getCidFromSource(source)
    if not citizenid then
        return false, 'Player not found'
    end

    return QuestManager.AdvanceStep(citizenid, questId, stepId)
end

--- 强制失败任务
---@param source number
---@param questId string
---@param reason string
---@return boolean success
---@return string message
function QuestManager.FailQuest(source, questId, reason)
    local citizenid = getCidFromSource(source)
    if not citizenid then
        return false, 'Player not found'
    end

    QuestDB.FailQuest(citizenid, questId, reason)
    QuestDB.LogEvent(citizenid, questId, 'fail', nil, { reason = reason })

    -- v1.0.0: 释放排他锁 + 清理节点
    local template = QuestRegistry.GetTemplate(questId)
    if template then
        if template.mode == 'competitive' or template.mode == 'group' then
            QuestMutex.ReleaseLock(questId, source)
        end
        QuestNodes.CancelAllNodes(source, questId)
    end

    -- v0.7.0: 清理事件反向索引
    QuestCache.UnindexEvent(citizenid, questId)
    QuestCache.InvalidateActive(citizenid)
    QuestManager._resolvedTemplates[citizenid .. '_' .. questId] = nil

    local src = getSourceFromCid(citizenid)
    if src then
        TriggerClientEvent(Config.Quest.Events.QUEST_FAILED, src, {
            quest_id = questId,
            reason = reason,
        })
    end

    -- v0.7.0: 广播任务失败事件
    TriggerEvent('quest:server:onQuestFailed', citizenid, questId, reason)

    QuestPrint('❌ Quest failed: %s → %s (%s)', citizenid, questId, reason)
    return true, ('Quest failed: %s'):format(reason)
end

--- 放弃任务
---@param source number
---@param questId string
---@return boolean success
---@return string message
function QuestManager.AbandonQuest(source, questId)
    local citizenid = getCidFromSource(source)
    if not citizenid then
        return false, 'Player not found'
    end

    QuestDB.AbandonQuest(citizenid, questId)
    QuestDB.LogEvent(citizenid, questId, 'abandon', nil, {})

    -- v1.0.0: 释放排他锁 + 清理节点
    local template = QuestRegistry.GetTemplate(questId)
    if template then
        if template.mode == 'competitive' or template.mode == 'group' then
            QuestMutex.ReleaseLock(questId, source)
        end
        QuestNodes.CancelAllNodes(source, questId)
    end

    -- v0.7.0: 清理事件反向索引
    QuestCache.UnindexEvent(citizenid, questId)
    QuestCache.InvalidateActive(citizenid)
    QuestManager._resolvedTemplates[citizenid .. '_' .. questId] = nil

    local src = getSourceFromCid(citizenid)
    if src then
        TriggerClientEvent(Config.Quest.Events.QUEST_ABANDONED, src, {
            quest_id = questId,
        })
    end

    QuestPrint('🏳️ Quest abandoned: %s → %s', citizenid, questId)
    return true, 'Quest abandoned'
end

-- ==============================================================
-- 查询 API
-- ==============================================================

--- 获取玩家活跃任务列表
---@param source number
---@return table[] quests
function QuestManager.GetActiveQuests(source)
    local citizenid = getCidFromSource(source)
    if not citizenid then return {} end

    local quests = QuestCache.GetActiveQuests(citizenid, function(cid)
        local result = {}
        QuestDB.GetActiveQuests(cid, function(rows)
            for _, row in ipairs(rows or {}) do
                local tmpl = QuestRegistry.GetTemplate(row.quest_id)
                table.insert(result, {
                    quest_id = row.quest_id,
                    title = tmpl and tmpl.title or row.quest_id,
                    status = row.status,
                    current_step = row.current_step,
                    progress_data = row.progress_data,
                    started_at = row.started_at,
                })
            end
        end)
        return result
    end)

    return quests or {}
end

--- 获取指定任务进度
---@param source number
---@param questId string
---@return table|nil progress
function QuestManager.GetQuestProgress(source, questId)
    local citizenid = getCidFromSource(source)
    if not citizenid then return nil end

    local template = QuestRegistry.GetTemplate(questId)
    local progress = nil

    QuestDB.GetQuestProgress(citizenid, questId, function(row)
        if not row then return end

        local steps = {}
        if template then
            local currentStepId = row.current_step
            local passedCurrent = false
            for _, step in ipairs(template.steps) do
                table.insert(steps, {
                    id = step.id,
                    title = step.title,
                    done = passedCurrent,
                    current = step.id == currentStepId,
                })
                if step.id == currentStepId then
                    passedCurrent = true
                end
            end
        end

        progress = {
            quest_id = row.quest_id,
            title = template and template.title or row.quest_id,
            status = row.status,
            current_step = row.current_step,
            progress_data = row.progress_data,
            started_at = row.started_at,
            completed_at = row.completed_at,
            steps = steps,
        }
    end)

    return progress
end

--- v0.7.0: 检查玩家是否有指定活跃任务
---@param source number
---@param questId string
---@return boolean
function QuestManager.IsQuestActive(source, questId)
    local citizenid = getCidFromSource(source)
    if not citizenid then return false end

    local quests = QuestCache.GetActiveQuests(citizenid, function(cid)
        local result = {}
        QuestDB.GetActiveQuests(cid, function(rows)
            result = rows or {}
        end)
        return result
    end)

    if quests then
        for _, q in ipairs(quests) do
            if q.quest_id == questId then
                return true
            end
        end
    end
    return false
end

--- v0.7.0: 获取指定任务的当前步骤 ID
---@param source number
---@param questId string
---@return string|nil stepId
function QuestManager.GetQuestStep(source, questId)
    local citizenid = getCidFromSource(source)
    if not citizenid then return nil end

    local quests = QuestCache.GetActiveQuests(citizenid, function(cid)
        local result = {}
        QuestDB.GetActiveQuests(cid, function(rows)
            result = rows or {}
        end)
        return result
    end)

    if quests then
        for _, q in ipairs(quests) do
            if q.quest_id == questId then
                return q.current_step
            end
        end
    end
    return nil
end

print('[quest-manager] ✅ 任务状态机已加载 (v0.7.0)')
print('[quest-manager]   7-State FSM: Not Started → In Progress → Completed / Failed / Abandoned')
print('[quest-manager]   script_trigger + 步骤事件广播 + 事件反向索引')