--[[
  tcity-atmosphere — Scene → Track mapping
  Extensible: add a new row to register a new scene.
  Third-party plugins: call Bus.Plugin.Publish('atmosphere:scene_change', {source=src, scene='...'})
--]]
return {
    ['default']  = {
        trackPool  = { 'dusk_prelude', 'city_lights_pulse', 'last_call_reprise' },
        volume     = 0.08,
        loop       = false,
        fadeInMs   = 3000,
        silenceMin = 480,   -- 8 minutes silence between tracks
        silenceMax = 900,   -- 15 minutes max silence
        trackDuration = 120, -- ~2 min per track
    },
    ['silent']   = { track = nil,                    volume = 0,    loop = false, fadeInMs = 500  },
    ['chase']    = { track = 'concrete_shadows',     volume = 0.15, loop = true,  fadeInMs = 800  },
    ['danger']   = { track = 'glass_and_bone',        volume = 0.12, loop = true,  fadeInMs = 1500 },
    ['respawn']  = { track = 'dusk_prelude',          volume = 0.10, loop = false, fadeInMs = 2000 },
    ['complete'] = { track = 'last_call_reprise',     volume = 0.10, loop = false, fadeInMs = 1500 },
}
