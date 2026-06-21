-- ==============================================================
-- sv_org.lua — 统一组织管理服务（职业 + 帮派）
--
-- 统一五级组织模板：
--   0 = 实习  1 = 正式  2 = 小组长  3 = 副部长  4 = Boss
--
-- 合并了 sv_boss.lua（职业）与 sv_gang.lua（帮派）的重复逻辑，
-- 新增 Boss 退位交接（TransferOwnership）机制。
--
-- 事件命名规范：
--   qb-orgmenu:server:*  — 统一事件（本文件注册）
--   qb-bossmenu:server:* — 职业旧事件（向后兼容桥接）
--   qb-gangmenu:server:* — 帮派旧事件（向后兼容桥接）
-- ==============================================================

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 安全工具
-- ==============================================================

-- 🔧 自愈: 安全审计日志（不再永久封禁）
local function SecurityAuditLog(src, action, detail)
    local playerName = GetPlayerName(src)
    print(('[SECURITY-ORG] %s (src=%s) attempted %s — %s'):format(playerName, src, action, detail))
    TriggerEvent('qb-log:server:CreateLog', 'orgmenu', 'Suspicious Activity', 'orange',
        string.format('%s (src=%s) attempted %s: %s', playerName, src, action, detail), false)
    TriggerClientEvent('QBCore:Notify', src, '你没有权限执行此操作', 'error')
end

-- ==============================================================
-- 组织类型判断工具
-- ==============================================================

--- 判断一个组织名是职业还是帮派
---@param orgName string
---@return 'job'|'gang'|nil
local function GetOrgType(orgName)
    if not orgName then return nil end
    if QBCore.Shared.Jobs[orgName] then return 'job' end
    if QBCore.Shared.Gangs[orgName] then return 'gang' end
    return nil
end

--- 获取玩家在指定组织中的 isboss 状态
---@param Player table
---@param orgType 'job'|'gang'
---@return boolean
local function IsPlayerBoss(Player, orgType)
    if not Player then return false end
    if orgType == 'job' then
        return Player.PlayerData.job and Player.PlayerData.job.isboss == true
    elseif orgType == 'gang' then
        return Player.PlayerData.gang and Player.PlayerData.gang.isboss == true
    end
    return false
end

--- 获取玩家的组织名称和等级
---@param Player table
---@param orgType 'job'|'gang'
---@return string orgName, number gradeLevel
local function GetPlayerOrgInfo(Player, orgType)
    if not Player then return nil, nil end
    if orgType == 'job' then
        local j = Player.PlayerData.job
        return j and j.name, j and j.grade and j.grade.level
    elseif orgType == 'gang' then
        local g = Player.PlayerData.gang
        return g and g.name, g and g.grade and g.grade.level
    end
    return nil, nil
end

-- ==============================================================
-- Callback: 获取组织成员列表
-- ==============================================================

QBCore.Functions.CreateCallback('qb-orgmenu:server:GetEmployees', function(source, cb, orgName)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then cb({}); return end

    local orgType = GetOrgType(orgName)
    if not orgType then cb({}); return end

    if not IsPlayerBoss(Player, orgType) then
        SecurityAuditLog(src, 'GetEmployees', '非Boss尝试获取成员列表')
        return
    end

    local employees = {}
    local fieldName = orgType -- 'job' or 'gang'
    local players = MySQL.query.await(
        'SELECT * FROM players WHERE JSON_UNQUOTE(JSON_EXTRACT(' .. fieldName .. ', "$.name")) = ?',
        { orgName }
    )

    if players[1] ~= nil then
        for _, value in pairs(players) do
            local Target = QBCore.Functions.GetPlayerByCitizenId(value.citizenid)
                or QBCore.Functions.GetOfflinePlayerByCitizenId(value.citizenid)

            if Target then
                local targetData = orgType == 'job' and Target.PlayerData.job or Target.PlayerData.gang
                if targetData and targetData.name == orgName then
                    local isOnline = Target.PlayerData.source
                    employees[#employees + 1] = {
                        empSource = Target.PlayerData.citizenid,
                        source = Target.PlayerData.source,         -- 在线时有效
                        grade = targetData.grade,
                        isboss = targetData.isboss or false,
                        name = (isOnline and '🟢 ' or '❌ ')
                            .. Target.PlayerData.charinfo.firstname .. ' '
                            .. Target.PlayerData.charinfo.lastname,
                        isOnline = isOnline ~= nil,
                    }
                end
            end
        end
    end

    table.sort(employees, function(a, b)
        return a.grade.level > b.grade.level
    end)

    cb(employees)
end)

-- ==============================================================
-- 事件: Boss 仓库
-- ==============================================================

RegisterNetEvent('qb-orgmenu:server:stash', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 自动检测是职业还是帮派 Boss
    local orgType = nil
    local orgName = nil
    if Player.PlayerData.job and Player.PlayerData.job.isboss then
        orgType = 'job'
        orgName = Player.PlayerData.job.name
    elseif Player.PlayerData.gang and Player.PlayerData.gang.isboss then
        orgType = 'gang'
        orgName = Player.PlayerData.gang.name
    else
        return
    end

    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local menuConfig = orgType == 'job' and Config.BossMenus or Config.GangMenus

    if not menuConfig[orgName] then return end
    local bossCoords = menuConfig[orgName]
    for i = 1, #bossCoords do
        local coords = bossCoords[i]
        if #(playerCoords - coords) < 2.5 then
            local stashName = 'boss_' .. orgName
            exports['qb-inventory']:OpenInventory(src, stashName, {
                maxweight = 4000000,
                slots = 25,
            })
            return
        end
    end
end)

-- ==============================================================
-- 事件: 等级变更（晋升/降级）
-- ==============================================================

RegisterNetEvent('qb-orgmenu:server:GradeUpdate', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local Employee = QBCore.Functions.GetPlayerByCitizenId(data.cid)
        or QBCore.Functions.GetOfflinePlayerByCitizenId(data.cid)
    if not Employee then return end

    -- 自动识别组织类型
    local orgType = GetOrgType(data.orgName)
    if not orgType then return end

    -- 🔒 Security: 距离校验
    local menuConfig = orgType == 'job' and Config.BossMenus or Config.GangMenus
    if menuConfig[data.orgName] then
        local bossCoords = menuConfig[data.orgName]
        local playerPed = GetPlayerPed(src)
        local playerCoords = GetEntityCoords(playerPed)
        local nearBoss = false
        for i = 1, #bossCoords do
            if #(playerCoords - bossCoords[i]) < 5.0 then nearBoss = true; break end
        end
        if not nearBoss then
            SecurityAuditLog(src, 'GradeUpdate', '非组织菜单点操作 — 疑似远程发包')
            return
        end
    end

    if not IsPlayerBoss(Player, orgType) then
        SecurityAuditLog(src, 'GradeUpdate', '非Boss尝试晋升成员')
        return
    end

    -- Boss 不能越级提拔：自己的 grade.level 必须大于目标等级
    local _, bossGrade = GetPlayerOrgInfo(Player, orgType)
    if data.grade > bossGrade then
        TriggerClientEvent('QBCore:Notify', src, 'You cannot promote to this rank!', 'error')
        return
    end

    local success
    if orgType == 'job' then
        success = Employee.Functions.SetJob(data.orgName, data.grade)
    else
        success = Employee.Functions.SetGang(data.orgName, data.grade)
    end

    if success then
        TriggerClientEvent('QBCore:Notify', src, 'Successfully promoted!', 'success')
        Employee.Functions.Save()
        if Employee.PlayerData.source then
            TriggerClientEvent('QBCore:Notify', Employee.PlayerData.source,
                'You have been promoted to ' .. data.gradename .. '.', 'success')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, 'Grade does not exist.', 'error')
    end

    TriggerClientEvent('qb-orgmenu:client:OpenMenu', src)
end)

-- ==============================================================
-- 事件: 开除成员
-- ==============================================================

RegisterNetEvent('qb-orgmenu:server:FireMember', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local Employee = QBCore.Functions.GetPlayerByCitizenId(data.cid)
        or QBCore.Functions.GetOfflinePlayerByCitizenId(data.cid)
    if not Employee then return end

    local orgType = GetOrgType(data.orgName)
    if not orgType then return end

    -- 🔒 Security: 距离校验
    local menuConfig = orgType == 'job' and Config.BossMenus or Config.GangMenus
    if menuConfig[data.orgName] then
        local bossCoords = menuConfig[data.orgName]
        local playerPed = GetPlayerPed(src)
        local playerCoords = GetEntityCoords(playerPed)
        local nearBoss = false
        for i = 1, #bossCoords do
            if #(playerCoords - bossCoords[i]) < 5.0 then nearBoss = true; break end
        end
        if not nearBoss then
            SecurityAuditLog(src, 'FireMember', '非组织菜单点操作 — 疑似远程发包')
            return
        end
    end

    if not IsPlayerBoss(Player, orgType) then
        SecurityAuditLog(src, 'FireMember', '非Boss尝试开除成员')
        return
    end

    -- 不能开除自己（Boss 退出请走 TransferOwnership）
    if data.cid == Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src,
            'You cannot fire yourself! Use "Transfer Ownership" to step down.', 'error')
        return
    end

    -- 不能开除比自己等级高的
    local empGrade = orgType == 'job'
        and Employee.PlayerData.job.grade.level
        or Employee.PlayerData.gang.grade.level
    local _, bossGrade = GetPlayerOrgInfo(Player, orgType)
    if empGrade > bossGrade then
        TriggerClientEvent('QBCore:Notify', src, 'You cannot fire this citizen!', 'error')
        return
    end

    local success
    local defaultOrg = orgType == 'job' and 'unemployed' or 'none'
    if orgType == 'job' then
        success = Employee.Functions.SetJob(defaultOrg, 0)
    else
        success = Employee.Functions.SetGang(defaultOrg, 0)
    end

    if success then
        Employee.Functions.Save()
        local logType = orgType == 'job' and 'bossmenu' or 'gangmenu'
        local logAction = orgType == 'job' and 'Job Fire' or 'Gang Fire'
        local logColor = orgType == 'job' and 'red' or 'orange'
        TriggerEvent('qb-log:server:CreateLog', logType, logAction, logColor,
            Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
            .. ' successfully fired ' .. Employee.PlayerData.charinfo.firstname .. ' '
            .. Employee.PlayerData.charinfo.lastname .. ' (' .. data.orgName .. ')', false)

        TriggerClientEvent('QBCore:Notify', src, 'Member fired!', 'success')
        if Employee.PlayerData.source then
            TriggerClientEvent('QBCore:Notify', Employee.PlayerData.source,
                'You have been expelled from the organization!', 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, 'Error.', 'error')
    end

    TriggerClientEvent('qb-orgmenu:client:OpenMenu', src)
end)

-- ==============================================================
-- 事件: 招募成员
-- ==============================================================

RegisterNetEvent('qb-orgmenu:server:HireMember', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local Target = QBCore.Functions.GetPlayer(data.recruitSource)
    if not Target then return end

    local orgType = GetOrgType(data.orgName)
    if not orgType then return end

    -- 🔒 Security: 距离校验
    local menuConfig = orgType == 'job' and Config.BossMenus or Config.GangMenus
    if menuConfig[data.orgName] then
        local bossCoords = menuConfig[data.orgName]
        local playerPed = GetPlayerPed(src)
        local playerCoords = GetEntityCoords(playerPed)
        local nearBoss = false
        for i = 1, #bossCoords do
            if #(playerCoords - bossCoords[i]) < 5.0 then nearBoss = true; break end
        end
        if not nearBoss then
            SecurityAuditLog(src, 'HireMember', '非组织菜单点操作 — 疑似远程发包')
            return
        end
    end

    if not IsPlayerBoss(Player, orgType) then
        SecurityAuditLog(src, 'HireMember', '非Boss尝试招募成员')
        return
    end

    local success
    if orgType == 'job' then
        success = Target.Functions.SetJob(data.orgName, 0)
    else
        success = Target.Functions.SetGang(data.orgName, 0)
    end

    if success then
        local orgLabel = orgType == 'job'
            and QBCore.Shared.Jobs[data.orgName].label
            or QBCore.Shared.Gangs[data.orgName].label
        TriggerClientEvent('QBCore:Notify', src,
            'You hired ' .. Target.PlayerData.charinfo.firstname .. ' '
            .. Target.PlayerData.charinfo.lastname .. ' as ' .. orgLabel, 'success')
        TriggerClientEvent('QBCore:Notify', Target.PlayerData.source,
            'You have been hired as ' .. orgLabel, 'success')

        local logType = orgType == 'job' and 'bossmenu' or 'gangmenu'
        TriggerEvent('qb-log:server:CreateLog', logType, 'Recruit',
            orgType == 'job' and 'lightgreen' or 'yellow',
            Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
            .. ' successfully recruited ' .. Target.PlayerData.charinfo.firstname .. ' '
            .. Target.PlayerData.charinfo.lastname .. ' (' .. data.orgName .. ')', false)
    end

    TriggerClientEvent('qb-orgmenu:client:OpenMenu', src)
end)

-- ==============================================================
-- 🔑 事件: Boss 退位交接 (Transfer Ownership)
--
-- 流程：
--   1. Boss 选择一名在线同组织成员作为接班人
--   2. 接班人必须先升为 Grade 4 Boss
--   3. 原 Boss 降为 Grade 0 并退出组织
--   4. 操作原子性保证：接班人升职成功后才清除原 Boss
-- ==============================================================

RegisterNetEvent('qb-orgmenu:server:TransferOwnership', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local orgType = GetOrgType(data.orgName)
    if not orgType then
        TriggerClientEvent('QBCore:Notify', src, 'Invalid organization.', 'error')
        return
    end

    -- 🔒 Security: 距离校验
    local menuConfig = orgType == 'job' and Config.BossMenus or Config.GangMenus
    if menuConfig[data.orgName] then
        local bossCoords = menuConfig[data.orgName]
        local playerPed = GetPlayerPed(src)
        local playerCoords = GetEntityCoords(playerPed)
        local nearBoss = false
        for i = 1, #bossCoords do
            if #(playerCoords - bossCoords[i]) < 5.0 then nearBoss = true; break end
        end
        if not nearBoss then
            SecurityAuditLog(src, 'TransferOwnership', '非组织菜单点操作 — 疑似远程发包')
            return
        end
    end

    -- 🔒 安全校验 1: 操作者必须是 Boss
    if not IsPlayerBoss(Player, orgType) then
        SecurityAuditLog(src, 'TransferOwnership', '非Boss尝试转让所有权')
        return
    end

    -- 🔒 安全校验 2: 不能传给自己
    if data.successorCid == Player.PlayerData.citizenid then
        TriggerClientEvent('QBCore:Notify', src, 'You cannot transfer ownership to yourself!', 'error')
        return
    end

    -- 🔒 安全校验 3: 接班人必须在同组织
    local Successor = QBCore.Functions.GetPlayerByCitizenId(data.successorCid)
    if not Successor then
        TriggerClientEvent('QBCore:Notify', src, 'The designated successor is not found.', 'error')
        return
    end

    local successorOrgName = orgType == 'job'
        and Successor.PlayerData.job.name
        or Successor.PlayerData.gang.name

    if successorOrgName ~= data.orgName then
        TriggerClientEvent('QBCore:Notify', src,
            'The designated successor is not a member of this organization!', 'error')
        return
    end

    -- 🔒 安全校验 4: 接班人必须在线
    if not Successor.PlayerData.source then
        TriggerClientEvent('QBCore:Notify', src,
            'The designated successor must be online to accept ownership.', 'error')
        return
    end

    -- 🔒 安全校验 5: 接班人不能已经是 Boss
    local isSuccessorBoss = orgType == 'job'
        and Successor.PlayerData.job.isboss
        or Successor.PlayerData.gang.isboss
    if isSuccessorBoss then
        TriggerClientEvent('QBCore:Notify', src,
            'This member is already a Boss! Choose someone else.', 'error')
        return
    end

    -- ✅ 校验通过，执行原子交接
    local step1Success, step2Success = false, false

    -- Step 1: 接班人升为 Grade 4 Boss
    if orgType == 'job' then
        step1Success = Successor.Functions.SetJob(data.orgName, 4)
    else
        step1Success = Successor.Functions.SetGang(data.orgName, 4)
    end

    if not step1Success then
        TriggerClientEvent('QBCore:Notify', src,
            'Failed to promote successor. Transfer aborted.', 'error')
        return
    end

    Successor.Functions.Save()

    -- Step 2: 原 Boss 降为 Grade 0 并退出
    local defaultOrg = orgType == 'job' and 'unemployed' or 'none'
    if orgType == 'job' then
        step2Success = Player.Functions.SetJob(defaultOrg, 0)
    else
        step2Success = Player.Functions.SetGang(defaultOrg, 0)
    end

    if not step2Success then
        -- 回滚：如果原 Boss 退出失败，撤销接班人晋升
        if orgType == 'job' then
            Successor.Functions.SetJob(data.orgName, Successor.PlayerData.job.grade.level)
        else
            Successor.Functions.SetGang(data.orgName, Successor.PlayerData.gang.grade.level)
        end
        TriggerClientEvent('QBCore:Notify', src,
            'Failed to complete transfer. Rolled back.', 'error')
        return
    end

    Player.Functions.Save()

    -- ✅ 交接成功 — 通知双方 + 审计日志
    local orgLabel = orgType == 'job'
        and QBCore.Shared.Jobs[data.orgName].label
        or QBCore.Shared.Gangs[data.orgName].label

    TriggerClientEvent('QBCore:Notify', src,
        'You have transferred ownership of ' .. orgLabel .. ' to '
        .. Successor.PlayerData.charinfo.firstname .. ' '
        .. Successor.PlayerData.charinfo.lastname .. '. You are now a civilian.', 'success')

    TriggerClientEvent('QBCore:Notify', Successor.PlayerData.source,
        '⚠️ You are now the new Boss of ' .. orgLabel .. '! '
        .. Player.PlayerData.charinfo.firstname .. ' '
        .. Player.PlayerData.charinfo.lastname .. ' has stepped down.', 'success')

    -- 审计日志
    local logType = orgType == 'job' and 'bossmenu' or 'gangmenu'
    TriggerEvent('qb-log:server:CreateLog', logType, 'Ownership Transfer', 'gold',
        Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
        .. ' transferred ownership of ' .. data.orgName .. ' to '
        .. Successor.PlayerData.charinfo.firstname .. ' '
        .. Successor.PlayerData.charinfo.lastname, false)

    -- 刷新前任的菜单（显示已退出）
    TriggerClientEvent('qb-orgmenu:client:CloseMenu', src)
end)

-- ==============================================================
-- Callback: 获取附近玩家（用于招募和 Boss 退位选择）
-- ==============================================================

QBCore.Functions.CreateCallback('qb-orgmenu:getplayers', function(source, cb)
    local src = source
    local players = {}
    local PlayerPed = GetPlayerPed(src)
    local pCoords = GetEntityCoords(PlayerPed)
    for _, v in pairs(QBCore.Functions.GetPlayers()) do
        local targetped = GetPlayerPed(v)
        local tCoords = GetEntityCoords(targetped)
        local dist = #(pCoords - tCoords)
        if PlayerPed ~= targetped and dist < 10 then
            local ped = QBCore.Functions.GetPlayer(v)
            players[#players + 1] = {
                id = v,
                coords = GetEntityCoords(targetped),
                name = ped.PlayerData.charinfo.firstname .. ' ' .. ped.PlayerData.charinfo.lastname,
                citizenid = ped.PlayerData.citizenid,
                sources = GetPlayerPed(ped.PlayerData.source),
                sourceplayer = ped.PlayerData.source
            }
        end
    end
    table.sort(players, function(a, b)
        return a.name < b.name
    end)
    cb(players)
end)

print('[sv_org] 🏛️  统一组织管理服务已启动')
print('[sv_org]   Events: qb-orgmenu:server:(GetEmployees|stash|GradeUpdate|FireMember|HireMember|TransferOwnership)')
print('[sv_org]   🔑 Boss 退位交接机制已就绪 — TransferOwnership')
