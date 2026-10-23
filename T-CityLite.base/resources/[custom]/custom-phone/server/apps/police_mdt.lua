-- server/apps/police_mdt.lua — first registry app (police only, on duty).
local function core()
    if type(_G.QBCore) == 'table' then return _G.QBCore end
    local ok, value = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if ok and type(value) == 'table' then _G.QBCore = value return value end
    return nil
end

local function onDutyPolice()
    local qb = core()
    local result = {}
    if not qb then return result end
    for _, source in ipairs(qb.Functions.GetPlayers()) do
        local Player = qb.Functions.GetPlayer(source)
        local data = Player and Player.PlayerData
        if data and type(data.job) == 'table' and data.job.name == 'police' and data.job.onduty == true then
            local info = type(data.charinfo) == 'table' and data.charinfo or {}
            result[#result + 1] = {
                source = source,
                citizenid = data.citizenid,
                name = ('%s %s'):format(tostring(info.firstname or '?'), tostring(info.lastname or '?')),
                grade = type(data.job.grade) == 'table' and tonumber(data.job.grade.level) or 0,
            }
        end
    end
    table.sort(result, function(a, b) return tostring(a.citizenid) < tostring(b.citizenid) end)
    return result
end

PhoneApps.Register({
    id = 'police_mdt',
    label = 'MDT',
    icon = '🛡️',
    audience = { jobs = { 'police' }, onduty = true },
    queries = {
        officers = function(_source)
            local rows = {}
            for _, officer in ipairs(onDutyPolice()) do
                rows[#rows + 1] = {
                    name = officer.name,
                    grade = officer.grade,
                    citizenid = officer.citizenid,
                }
            end
            return { rows = rows, count = #rows, updated_at = os.time() }
        end,
    },
    actions = {
        alert = function(source, params)
            local message = type(params.message) == 'string' and params.message:sub(1, 200) or ''
            if not message:match('%S') then return false end
            local sender = core().Functions.GetPlayer(source)
            local senderName = 'Dispatch'
            if sender and type(sender.PlayerData.charinfo) == 'table' then
                local info = sender.PlayerData.charinfo
                senderName = ('%s %s'):format(tostring(info.firstname or ''), tostring(info.lastname or ''))
            end
            local title = ('MDT Alert — %s'):format(senderName:sub(1, 40))
            local sent = 0
            for _, officer in ipairs(onDutyPolice()) do
                MySQL.Async.insert(
                    'INSERT INTO phone_notifications (citizenid, title, content) VALUES (?, ?, ?)',
                    { officer.citizenid, title:sub(1, 200), message },
                    function() end
                )
                TriggerClientEvent('phone:client:newNotification', officer.source, {
                    id = 0,
                    title = title:sub(1, 200),
                    content = message,
                    timestamp = os.date('%Y-%m-%d %H:%M:%S'),
                    is_read = false,
                })
                sent = sent + 1
            end
            return { sent = sent }
        end,
    },
})

print('[custom-phone][apps] registered police_mdt')
