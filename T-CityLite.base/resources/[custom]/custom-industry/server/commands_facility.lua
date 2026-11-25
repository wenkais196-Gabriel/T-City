-- server/commands_facility.lua — S2 设施命令（全部服务端）。
--
-- 授权：
--   /orgbuild     该组织 Grade4（必须在线）
--   /orghire      该组织 Grade4（必须在线），一次 1..10 个
--   /orgfacility  该组织 Grade4 / 管理员 / 控制台
--
-- 与 S1 一样，本资源没有全局 QBCore：惰性解析 exports['qb-core']:GetCoreObject()
-- 并缓存。资金与设施写入都只发生在 Facility.* / Treasury.* 里。

IndustryFacilityCommands = {}

local QBCore
local function core()
    if not QBCore then
        QBCore = exports['qb-core']:GetCoreObject()
    end
    return QBCore
end

local refSeq = 0

local function makeRef(kind, orgId, n)
    refSeq = refSeq + 1
    return ('cmd:%s:%s:%d:%d:%d'):format(kind, orgId, n or 0, os.time(), refSeq)
end

local function reply(src, message)
    if src and src > 0 then
        TriggerClientEvent('chat:addMessage', src, {
            color = { 255, 200, 50 },
            args = { '产业', message },
        })
    else
        print('[custom-industry] ' .. message)
    end
end

--- 金额格式化只允许 core-framework 的 FormatMoney（Money 别名集中定义）。
local function moneyText(value)
    return Money(value)
end

local function workstationCap(facilityType)
    local config = Config.Industry.Facilities[facilityType]
    return config and config.workstationCap or 0
end

function IndustryFacilityCommands.Register()
    local QBCore = core()

    QBCore.Commands.Add('orgbuild', '建设组织设施（L1）', {
        { name = 'orgId', help = '组织名，例如 mining_co' },
        { name = 'facilityType', help = '设施类型，例如 mine' },
    }, false, function(source, args)
        local src = source
        if src < 1 then
            reply(src, '该命令只能由在线玩家执行')
            return
        end

        local Player = QBCore.Functions.GetPlayer(src)
        if not Player then
            reply(src, '玩家状态不可用，请稍后重试')
            return
        end
        local cid = Player.PlayerData.citizenid

        local orgId = tostring(args[1] or '')
        local facilityType = tostring(args[2] or '')
        if orgId == '' or facilityType == '' then
            reply(src, '用法: /orgbuild <orgId> <facilityType>')
            return
        end
        if not IndustryAccess.IsOrgBoss(Player, orgId) then
            reply(src, 'not_boss')
            return
        end

        local ok, err, cost = Facility.Build(orgId, facilityType, {
            actor = cid,
            ref = makeRef('build', orgId, 0),
        })
        if not ok then
            reply(src, ('建设失败: %s'):format(tostring(err)))
            return
        end
        reply(src, ('%s 已建成 %s，花费 $%s'):format(orgId, facilityType, moneyText(cost)))
    end, 'user')

    QBCore.Commands.Add('orghire', '雇佣工位（一次最多 10 个）', {
        { name = 'orgId', help = '组织名，例如 mining_co' },
        { name = 'count', help = '1..10，默认 1' },
    }, false, function(source, args)
        local src = source
        if src < 1 then
            reply(src, '该命令只能由在线玩家执行')
            return
        end

        local Player = QBCore.Functions.GetPlayer(src)
        if not Player then
            reply(src, '玩家状态不可用，请稍后重试')
            return
        end
        local cid = Player.PlayerData.citizenid

        local orgId = tostring(args[1] or '')
        if orgId == '' then
            reply(src, '用法: /orghire <orgId> [count]')
            return
        end

        local count = 1
        if args[2] ~= nil then
            count = tonumber(args[2])
            if not count or count ~= math.floor(count) or count < 1 or count > 10 then
                reply(src, 'count 必须是 1..10 的整数')
                return
            end
        end

        if not IndustryAccess.IsOrgBoss(Player, orgId) then
            reply(src, 'not_boss')
            return
        end

        local hired = 0
        local spent = 0
        local lastErr = nil
        for index = 1, count do
            local ok, err, cost = Facility.AddWorkstation(orgId, {
                actor = cid,
                ref = makeRef('hire', orgId, index),
            })
            if not ok then
                lastErr = err
                break
            end
            hired = hired + 1
            spent = spent + (tonumber(cost) or 0)
        end

        if hired == 0 then
            reply(src, ('雇佣失败: %s'):format(tostring(lastErr or 'unknown')))
            return
        end
        if lastErr then
            reply(src, ('已雇 %d 个工位，花费 $%s；后续失败: %s'):format(
                hired, moneyText(spent), tostring(lastErr)))
            return
        end
        reply(src, ('已雇 %d 个工位，花费 $%s'):format(hired, moneyText(spent)))
    end, 'user')

    QBCore.Commands.Add('orgfacility', '查看组织设施', {
        { name = 'orgId', help = '组织名，例如 mining_co' },
    }, false, function(source, args)
        local src = source
        local orgId = tostring(args[1] or '')
        if orgId == '' then
            reply(src, '用法: /orgfacility <orgId>')
            return
        end

        local allowed = false
        if src > 0 then
            local Player = QBCore.Functions.GetPlayer(src)
            if not Player then
                reply(src, '玩家状态不可用，请稍后重试')
                return
            end
            local admin = QBCore.Functions.HasPermission(src, 'admin')
                or QBCore.Functions.HasPermission(src, 'god')
            allowed = admin or IndustryAccess.IsOrgBoss(Player, orgId)
        else
            allowed = true
        end

        if not allowed then
            reply(src, 'not_boss')
            return
        end

        local row, err = Facility.Get(orgId)
        if not row then
            reply(src, ('查询失败: %s'):format(tostring(err)))
            return
        end

        local facilityType = tostring(row.facility_type)
        reply(src, ('%s 设施 %s L%d 工位 %d/%d 库存 %d'):format(
            orgId, facilityType,
            tonumber(row.level) or 0,
            tonumber(row.workstations) or 0,
            tonumber(workstationCap(facilityType)) or 0,
            tonumber(row.stock) or 0))
    end, 'user')
end
