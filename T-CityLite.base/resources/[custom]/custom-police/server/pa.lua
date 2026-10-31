-- server/pa.lua — L3 反应层：扩音器喊话（蓝图 §6.2「TTS 喊话」）。
--
-- 为什么用手机的 TTS 通道：我们没有 3D 音频管线，而手机已经有
-- `phone:client:systemSpeech`（字幕 + 浏览器 TTS）。喊话是"现场听见"，
-- 所以按**距离**广播给附近玩家，而不是像无线电那样只发给在岗警察。
--
-- 边界：
--   1. 只有在岗警察能用；文本 3–120 字符，剥控制字符；
--   2. 每人 8 秒冷却（喊话不是刷屏工具）；
--   3. 审计只记"谁在什么时候喊了多长"，不记正文（宪法 §7：遥测不落 PII）；
--   4. 半径 40m：喊给自己听不算喊话。

local PA_RADIUS = 40.0
local PA_COOLDOWN_SECONDS = 8
local PA_MAX_LEN = 120
local lastPa = {}   -- [cid] = os.time()

local function paEnabled()
    return GetConvar('police_pa', '1') == '1'
end

local function clean(text)
    if type(text) ~= 'string' then return nil end
    local stripped = text:gsub('%c', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if #stripped < 3 or #stripped > PA_MAX_LEN then return nil end
    return stripped
end

local function audit(cid, target, detail)
    if type(PoliceAudit) ~= 'table' then return false end
    local ok, result = pcall(function()
        return PoliceAudit.Write(cid, 'police.pa', target, detail)
    end)
    if not ok or not result then
        print('[custom-police] police.pa audit failed')
        return false
    end
    return true
end

RegisterNetEvent('police:server:pa', function(text)
    if not paEnabled() then return end
    local src = tonumber(source) or 0
    local player = QBCore and QBCore.Functions and QBCore.Functions.GetPlayer(src)
    local data = player and player.PlayerData
    if not data or not PolicePolicy.Can(data, 'incident.update') then return end
    if not data.job or data.job.onduty ~= true then return end
    local cid = type(data.citizenid) == 'string' and data.citizenid or ''
    if cid == '' then return end

    local body = clean(text)
    if not body then return end
    if os.time() - (lastPa[cid] or 0) < PA_COOLDOWN_SECONDS then return end
    lastPa[cid] = os.time()

    local speaker = GetPlayerPed(src)
    if not speaker or speaker == 0 or not DoesEntityExist(speaker) then return end
    local origin = GetEntityCoords(speaker)

    local heard = 0
    for _, raw in ipairs(GetPlayers()) do
        local targetSrc = tonumber(raw)
        local targetPed = GetPlayerPed(targetSrc)
        if targetPed and targetPed ~= 0 and DoesEntityExist(targetPed) then
            if #(GetEntityCoords(targetPed) - origin) <= PA_RADIUS then
                TriggerClientEvent('phone:client:systemSpeech', targetSrc, {
                    text = ('[扩音器] %s'):format(body),
                })
                heard = heard + 1
            end
        end
    end

    if not audit(cid, 'pa', ('len=%d;heard=%d'):format(#body, heard)) then
        print('[custom-police] police.pa audit failed')
    end
end)

--- 封锁线授权：`/lockdown` 只放锥桶，但"谁能放"必须服务端说了算。
RegisterNetEvent('police:server:lockdownRequest', function()
    local src = tonumber(source) or 0
    local player = QBCore and QBCore.Functions and QBCore.Functions.GetPlayer(src)
    local data = player and player.PlayerData
    if not data or not PolicePolicy.Can(data, 'incident.update') then return end
    if not data.job or data.job.onduty ~= true then return end
    TriggerClientEvent('police:client:LockdownPlace', src)
end)
