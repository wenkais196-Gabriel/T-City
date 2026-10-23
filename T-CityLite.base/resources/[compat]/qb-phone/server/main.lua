-- qb-phone was archived; several enabled resources still call its exports.
-- This tiny shim keeps the export namespace alive and forwards to the live
-- phone. Client event names (qb-phone:client:*) are already handled by
-- custom-phone/client/main.lua and need no shim.
local function phone()
    return exports['custom-phone']
end

exports('sendNewMail', function(source, mail)
    return phone():sendNewMail(source, mail)
end)

exports('sendNewMailToOffline', function(citizenid, mail)
    return phone():sendNewMailToOffline(citizenid, mail)
end)

print('[qb-phone-shim] legacy exports forward to custom-phone')
