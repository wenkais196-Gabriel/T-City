-- 声音参数全部来自客户端：文件名只允许 [A-Za-z0-9_]，音量 0..1，
-- 并按玩家限流（转向灯/上铐音的客户端调用频率高，限 10 次/秒）。
-- 原来的实现没有任何校验，`InteractSound_SV:PlayOnAll` / `PlayOnOne` 还能被任意客户端
-- 拿来给全服或指定玩家刷声；而且 `PlayWithinDistance` 被注册了两次（后一个覆盖前一个）。
local _lastPlay = {}

local function canPlay(src, soundFile, soundVolume)
    if type(soundFile) ~= 'string' or #soundFile == 0 or #soundFile > 64 then return false end
    if not soundFile:match('^[A-Za-z0-9_%-]+$') then return false end
    local volume = tonumber(soundVolume)
    if not volume or volume <= 0 or volume > 1 then return false end
    local now = GetGameTimer()
    local key = tostring(src) .. '|' .. soundFile
    if _lastPlay[key] and (now - _lastPlay[key]) < 100 then return false end
    _lastPlay[key] = now
    return true
end

RegisterNetEvent('InteractSound_SV:PlayOnOne', function(clientNetId, soundFile, soundVolume)
    -- 🔒 仓库内没有任何客户端调用点（只有服务端脚本才该用它）：
    --    原来任何玩家都能给任意玩家客户端推一条播放指令。
    if source ~= 0 then return end
    TriggerClientEvent('InteractSound_CL:PlayOnOne', clientNetId, soundFile, soundVolume)
end)

RegisterNetEvent('InteractSound_SV:PlayOnSource', function(soundFile, soundVolume)
    local src = source
    -- 🔒 客户端自播（警用上铐音、车辆转向灯等）：只播给**调用者自己**，
    --    但参数来自客户端，得校验，并且按人限流（转向灯频率高，限到 10 次/秒）。
    if not canPlay(src, soundFile, soundVolume) then return end
    TriggerClientEvent('InteractSound_CL:PlayOnOne', src, soundFile, soundVolume)
end)

RegisterNetEvent('InteractSound_SV:PlayOnAll', function(soundFile, soundVolume)
    -- 🔒 全服广播：仓库内没有调用点，只允许服务端触发（否则任何人可以全服刷声）
    if source ~= 0 then return end
    TriggerClientEvent('InteractSound_CL:PlayOnAll', -1, soundFile, soundVolume)
end)

RegisterNetEvent('InteractSound_SV:PlayWithinDistance', function(maxDistance, soundFile, soundVolume)
    local src = source
    local DistanceLimit = 300
    maxDistance = tonumber(maxDistance)
    if not maxDistance or maxDistance <= 0 then return end
    if maxDistance >= DistanceLimit then
        print(('[interact-sound] [^3WARNING^7] %s attempted to trigger InteractSound_SV:PlayWithinDistance over the distance limit (300)'):format(GetPlayerName(src) or 'unknown'))
        return
    end
    if not canPlay(src, soundFile, soundVolume) then return end
    TriggerClientEvent('InteractSound_CL:PlayWithinDistance', -1, GetEntityCoords(GetPlayerPed(src)), maxDistance, soundFile, soundVolume)
end)
