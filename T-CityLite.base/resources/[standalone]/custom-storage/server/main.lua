-- main.lua — custom-storage 组织仓库服务 v2
--
-- 🏢 组织架构模型:
--   一个组织 = 多个职业共享同一个仓库
--   - /jobstorage  → 按职业查找所属组织，显示"组织名 | 职业名 | 等级"
--   - /gangstorage → 按帮派查找所属组织，显示"组织名 | 帮派名 | 等级"
--
-- 仓库标识符: orgstorage-{orgId}
--   例: orgstorage-lspd, orgstorage-cartel, orgstorage-mining_co

local QBCore = exports['qb-core']:GetCoreObject()
OrgStorage = {}

local function makeStorageId(orgId)
    return ('orgstorage-%s'):format(orgId)
end

-- ==============================================================
-- 公共 API
-- ==============================================================

function OrgStorage.GetStorageId(orgId)
    return makeStorageId(orgId)
end

function OrgStorage.CanAccess(source, orgId)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false, 'Player not found' end
    if QBCore.Functions.HasPermission(source, 'admin') or QBCore.Functions.HasPermission(source, 'god') then
        return true, nil
    end

    local org = GetOrgConfig(orgId)
    if not org then return false, '组织不存在: ' .. tostring(orgId) end

    if org.type == 'gang' then
        local gang = Player.PlayerData.gang
        if gang and gang.name == org.gang then return true, nil end
        return false, ('你不是 %s 的成员，无法访问帮派仓库'):format(org.label)
    elseif org.type == 'job' then
        local job = Player.PlayerData.job
        if job then
            for _, j in ipairs(org.jobs) do
                if j == job.name then return true, nil end
            end
        end
        return false, ('你不是 %s 的员工，无法访问组织仓库'):format(org.label)
    end
    return false, '未知组织类型'
end

function OrgStorage.OpenOrgStorage(source, orgId)
    local canAccess, err = OrgStorage.CanAccess(source, orgId)
    if not canAccess then
        TriggerClientEvent('QBCore:Notify', source, err, 'error')
        return false, err
    end

    local org = GetOrgConfig(orgId)
    if not org then return false, '组织不存在' end

    local invData = {
        maxweight = org.storage.maxWeight,
        slots = org.storage.maxSlots,
        label = org.label,
    }

    local inventoryId = makeStorageId(orgId)
    if exports['qb-inventory'] and exports['qb-inventory'].OpenInventoryById then
        exports['qb-inventory']:OpenInventoryById(source, inventoryId, invData)
    else
        TriggerClientEvent('qb-inventory:client:openInventory', source, inventoryId, invData)
    end
    return true, nil
end

function OrgStorage.GetOrgStorage(orgId)
    local org = GetOrgConfig(orgId)
    if not org then return nil end
    if exports['qb-inventory'] and exports['qb-inventory'].LoadInventory then
        local items = exports['qb-inventory']:LoadInventory(nil, makeStorageId(orgId))
        return { items = items or {}, maxSlots = org.storage.maxSlots, maxWeight = org.storage.maxWeight, label = org.label }
    end
    return { items = {}, maxSlots = org.storage.maxSlots, maxWeight = org.storage.maxWeight, label = org.label }
end

function OrgStorage.AddItem(orgId, itemName, amount, slot, info)
    if exports['qb-inventory'] and exports['qb-inventory'].AddItem then
        return exports['qb-inventory']:AddItem(makeStorageId(orgId), itemName, amount, slot, info, 'OrgStorage')
    end
    return false
end

function OrgStorage.RemoveItem(orgId, itemName, amount, slot)
    if exports['qb-inventory'] and exports['qb-inventory'].RemoveItem then
        return exports['qb-inventory']:RemoveItem(makeStorageId(orgId), itemName, amount, slot, 'OrgStorage')
    end
    return false
end

function OrgStorage.ListAllStorages()
    return GetAllOrgs()
end

function OrgStorage.ValidateAndGetCapacity(source, orgId)
    local canAccess, err = OrgStorage.CanAccess(source, orgId)
    if not canAccess then
        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('组织仓库未授权访问',
                ('**玩家**: %s | **组织**: %s | **错误**: %s'):format(GetPlayerName(source), orgId, err))
        end
        return nil, err
    end
    local org = GetOrgConfig(orgId)
    return org and org.storage, nil
end

-- ==============================================================
-- Bus 注册 (保持兼容: 增加 orgId 参数，orgType/orgName 废弃)
-- ==============================================================
if Bus and Bus.RegisterService then
    Bus.RegisterService('storage', {
        GetStorageId = OrgStorage.GetStorageId,
        CanAccess = OrgStorage.CanAccess,
        OpenOrgStorage = OrgStorage.OpenOrgStorage,
        GetOrgStorage = OrgStorage.GetOrgStorage,
        AddItem = OrgStorage.AddItem,
        RemoveItem = OrgStorage.RemoveItem,
        ListAllStorages = OrgStorage.ListAllStorages,
        ValidateAndGetCapacity = OrgStorage.ValidateAndGetCapacity,
        FindPlayerOrg = FindPlayerOrg,
        GetOrgConfig = GetOrgConfig,
    })
end

-- ==============================================================
-- 命令: /jobstorage — 职业组织仓库
-- ==============================================================
QBCore.Commands.Add('jobstorage', '按职业打开所属组织仓库', {}, false, function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local job = Player.PlayerData.job
    if not job or job.name == 'unemployed' then
        TriggerClientEvent('QBCore:Notify', source, _L(src, 'storage_no_job'), 'error')
        return
    end

    local orgId, org = FindOrgByJob(job.name)
    if not orgId then
        TriggerClientEvent('QBCore:Notify', source, _L(src, 'storage_no_org'), 'error')
        return
    end

    TriggerClientEvent('chat:addMessage', source, {
        color = { 100, 200, 255 }, multiline = true,
        args = { '🏢 组织仓库',
            ('组织: %s [%s]\n💼 职业: %s\n📊 等级: %s'):format(
                org.label, orgId,
                job.label,
                job.grade and job.grade.name or '?') }
    })
    OrgStorage.OpenOrgStorage(source, orgId)
end, 'user')

-- ==============================================================
-- 命令: /gangstorage — 帮派组织仓库
-- ==============================================================
QBCore.Commands.Add('gangstorage', '按帮派打开所属组织仓库', {}, false, function(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local gang = Player.PlayerData.gang
    if not gang or gang.name == 'none' then
        TriggerClientEvent('QBCore:Notify', source, _L(src, 'storage_no_gang'), 'error')
        return
    end

    local orgId, org = FindOrgByGang(gang.name)
    if not orgId then
        TriggerClientEvent('QBCore:Notify', source, _L(src, 'storage_no_gang_org'), 'error')
        return
    end

    TriggerClientEvent('chat:addMessage', source, {
        color = { 255, 150, 50 }, multiline = true,
        args = { '🏴 帮派仓库',
            ('组织: %s [%s]\n🏴 帮派: %s\n📊 等级: %s'):format(
                org.label, orgId,
                gang.label,
                gang.grade and gang.grade.name or '?') }
    })
    OrgStorage.OpenOrgStorage(source, orgId)
end, 'user')

-- ( /orgstorage 已删除，使用 /gangstorage 或 /jobstorage )

-- ==============================================================
-- 命令: /orgstoragelist — 管理员查看全部
-- ==============================================================
QBCore.Commands.Add('orgstoragelist', '列出所有组织仓库配置 (管理员)', {}, true, function(source)
    local all = GetAllOrgs()
    local jobOrgs, gangOrgs = {}, {}
    for _, o in ipairs(all) do
        if o.type == 'job' then table.insert(jobOrgs, o)
        elseif o.type == 'gang' then table.insert(gangOrgs, o) end
    end

    TriggerClientEvent('chat:addMessage', source, {
        color = { 0, 255, 255 }, multiline = true,
        args = { '📦 组织仓库配置', ('共 %d 个 (合法: %d | 帮派: %d)'):format(
            #all, #jobOrgs, #gangOrgs) }
    })

    if #jobOrgs > 0 then
        TriggerClientEvent('chat:addMessage', source, {
            color = { 50, 200, 255 }, args = { '── 合法组织 (🏢) ──', '' }
        })
        for _, o in ipairs(jobOrgs) do
            local jobList = table.concat(o.jobs, ', ')
            TriggerClientEvent('chat:addMessage', source, {
                color = { 180, 220, 255 },
                args = { '  ', ('🏢 %s [%s] | 职业: %s | %d格 / %.0fkg'):format(
                    o.label, o.id, jobList, o.maxSlots, o.maxWeight / 1000) }
            })
        end
    end

    if #gangOrgs > 0 then
        TriggerClientEvent('chat:addMessage', source, {
            color = { 255, 150, 50 }, args = { '── 非法组织 (🏴) ──', '' }
        })
        for _, o in ipairs(gangOrgs) do
            TriggerClientEvent('chat:addMessage', source, {
                color = { 255, 200, 150 },
                args = { '  ', ('🏴 %s [%s] | 帮派: %s | %d格 / %.0fkg'):format(
                    o.label, o.id, o.gang, o.maxSlots, o.maxWeight / 1000) }
            })
        end
    end

end, 'admin')

print('[custom-storage] 📦 组织仓库服务 v2 已注册到 Bus')
print('[custom-storage]   命令: /jobstorage /gangstorage /orgstoragelist')
