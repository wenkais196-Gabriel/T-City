-- Cartel Base Gate Doorlocks (Madrazo Ranch / La Fuente Blanca)
-- Spawns and controls the main security gates for Cartel gang members

Config.DoorList['cartel_gate_main'] = {
    textCoords = vec3(1316.76, 1106.17, 106.00),
    authorizedGangs = { ['cartel'] = 0 }, -- Only cartel members have the key to lock/unlock
    locked = true,
    pickable = false,
    distance = 12.0,
    doorType = 'doublesliding', -- Activates synchronized double automatic sliding!
    doorRate = 1.2,
    audioLock = { ['file'] = 'metal-locker.ogg', ['volume'] = 0.6 },    -- Solid heavy metal lock click
    audioUnlock = { ['file'] = 'metallic-creak.ogg', ['volume'] = 0.7 }, -- Satisfying iron sliding squeak/creak
    doors = {
        {
            objName = 'prop_lrggate_02',
            objYaw = 108.04,
            objCoords = vec3(1316.67, 1106.31, 104.97) -- Left Gate
        },
        {
            objName = 'prop_lrggate_02',
            objYaw = 288.62,
            objCoords = vec3(1316.86, 1106.04, 104.97) -- Right Gate
        }
    }
}

Config.DoorList['cartel_gate_back'] = {
    textCoords = vec3(1313.23, 1188.65, 108.00),
    authorizedGangs = { ['cartel'] = 0 }, -- Only cartel members have the key to lock/unlock
    locked = true,
    pickable = false,
    distance = 12.0,
    doorType = 'custom', -- Custom type: bypass native AddDoorToSystem to prevent falling underground!
    objCoords = vec3(1313.23, 1188.65, 107.10),
    objName = 'fake_gate_back_placeholder',
    audioLock = { ['file'] = 'metal-locker.ogg', ['volume'] = 0.6 },
    audioUnlock = { ['file'] = 'metallic-creak.ogg', ['volume'] = 0.7 }
}
