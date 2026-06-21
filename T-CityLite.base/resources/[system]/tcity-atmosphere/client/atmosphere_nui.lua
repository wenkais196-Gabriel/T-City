--[[
  tcity-atmosphere — Client bridge
  Receives server-validated events; pushes to NUI.
  No audio logic — all handled in Howler.js.
  NOTE: SendNUIMessage queues messages; no isReady guard needed.
--]]

RegisterNetEvent('tcity-atmosphere:playScene', function(data)
    SendNUIMessage({
        type  = 'playScene',
        track = data.track,
        volume = data.volume,
        loop   = data.loop,
        fadeInMs = data.fadeInMs,
    })
end)

RegisterNetEvent('tcity-atmosphere:stopBGM', function()
    SendNUIMessage({
        type = 'stopBGM',
    })
end)

RegisterNetEvent('tcity-atmosphere:setVolume', function(newVolume)
    SendNUIMessage({
        type   = 'setVolume',
        volume = newVolume,
    })
end)
