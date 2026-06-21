--[[
  tcity-atmosphere — Server-side Bus Service
  Five-layer security chain: Source → Sanitize → Cooldown → Permission → Threshold
  Event-driven, zero Tick, zero disk IO.
--]]

-- Load scene config (safe: fallback to inline if require fails)
local ok, result = pcall(require, 'config.scenes')
local Scenes = ok and result or {
    ['default']  = { trackPool = { 'dusk_prelude', 'city_lights_pulse', 'last_call_reprise' }, volume = 0.08, loop = false, fadeInMs = 3000, silenceMin = 480, silenceMax = 900, trackDuration = 120 },
    ['silent']   = { track = nil,                    volume = 0,    loop = false, fadeInMs = 500  },
    ['chase']    = { track = 'concrete_shadows',     volume = 0.15, loop = true,  fadeInMs = 800  },
    ['danger']   = { track = 'glass_and_bone',        volume = 0.12, loop = true,  fadeInMs = 1500 },
    ['respawn']  = { track = 'dusk_prelude',          volume = 0.10, loop = false, fadeInMs = 2000 },
    ['complete'] = { track = 'last_call_reprise',     volume = 0.10, loop = false, fadeInMs = 1500 },
}

-- Per-player state: { scene, volume, lastRequestAt, requestCount, requestWindowStart }
local playerState = {}

-- Cooldowns per scene (ms) — prevents rapid scene switching
local SCENE_COOLDOWNS = {
    ['default']  = 15000,
    ['silent']   = 5000,
    ['chase']    = 60000,
    ['danger']   = 30000,
    ['respawn']  = 0,      -- no cooldown, always allowed
    ['complete'] = 30000,
}

-- Rate limit: max requests per window (ms)
local RATE_LIMIT_MAX   = 3
local RATE_LIMIT_WINDOW = 10000

-- Priority: higher number = cannot be interrupted by lower
local SCENE_PRIORITY = {
    ['default']  = 0,
    ['silent']   = 0,
    ['complete'] = 5,
    ['chase']    = 10,
    ['danger']   = 10,
    ['respawn']  = 20,  -- death always wins
}

-- ─── Internal helpers ────────────────────────────────────

local function getSceneConfig(sceneName)
    if not sceneName or not Scenes[sceneName] then return nil end
    return Scenes[sceneName]
end

local function getPlayerState(src)
    if not playerState[src] then
        playerState[src] = {
            scene              = 'default',
            volume             = nil,
            lastRequestAt      = 0,
            requestCount       = 0,
            requestWindowStart = 0,
            sceneTimeout       = nil,
            silenceTimer       = nil,  -- flag for silence-gap scheduling
        }
    end
    return playerState[src]
end

-- Auto-revert chase/danger → default after timeout
local SCENE_TIMEOUTS = {
    ['chase']  = 300000,  -- 5 minutes
    ['danger'] = 300000,  -- 5 minutes
}

-- Helper: pick a random track from config (supports track + trackPool)
local function pickTrack(cfg)
    if cfg.track then return cfg.track end
    if cfg.trackPool and #cfg.trackPool > 0 then
        return cfg.trackPool[math.random(#cfg.trackPool)]
    end
    return nil
end

-- Helper: push track to client (src ≤ 0 → broadcast to all)
local function pushTrackToClient(src, cfg, trackName)
    local target = (src > 0) and src or -1
    if not trackName then
        TriggerClientEvent('tcity-atmosphere:stopBGM', target)
        return
    end
    TriggerClientEvent('tcity-atmosphere:playScene', target, {
        track   = trackName,
        volume  = cfg.volume,
        loop    = cfg.loop or false,
        fadeInMs = cfg.fadeInMs or 1000,
    })
end

-- Player online check (prevents orphaned timers after disconnect)
local function isPlayerOnline(src)
    if src < 1 then return false end
    return GetPlayerName(src) ~= nil
end

-- Silence gap scheduler (Minecraft-style: silence between random tracks)
local function scheduleNextSilenceTrack(src)
    if src < 1 then return end
    if not isPlayerOnline(src) then return end
    local st = getPlayerState(src)
    if st.scene ~= 'default' then return end
    local cfg = getSceneConfig('default')
    if not cfg or not cfg.trackPool then return end

    if st.silenceTimer then
        st.silenceTimer = nil
    end

    local silenceMs = (cfg.silenceMin + math.random(0, cfg.silenceMax - cfg.silenceMin)) * 1000
    local totalWait = (cfg.trackDuration or 120) * 1000 + silenceMs

    st.silenceTimer = true
    SetTimeout(totalWait, function()
        if not isPlayerOnline(src) then return end  -- player dropped, abort chain
        local s = getPlayerState(src)
        if s.scene ~= 'default' or not s.silenceTimer then return end
        local picked = pickTrack(cfg)
        if picked then
            pushTrackToClient(src, cfg, picked)
            print(('[atmosphere] 🎲 %s: silence-gap → "%s" (after %ds silence)')
                :format(GetPlayerName(src), picked, silenceMs // 1000))
            scheduleNextSilenceTrack(src)
        end
    end)
end

local function cancelSilenceTimer(src)
    local st = getPlayerState(src)
    st.silenceTimer = nil  -- flag-based cancel (SetTimeout can't be cancelled in FiveM)
end

-- Chase/danger auto-revert
local function scheduleSceneTimeout(src, scene)
    local st = getPlayerState(src)
    st.sceneTimeout = nil
    local timeoutMs = SCENE_TIMEOUTS[scene]
    if not timeoutMs then return end
    st.sceneTimeout = true
    SetTimeout(timeoutMs, function()
        if not isPlayerOnline(src) then return end  -- player dropped, abort
        local s = getPlayerState(src)
        if s.scene == scene and s.sceneTimeout then
            s.scene = 'default'
            s.lastRequestAt = GetGameTimer()
            s.sceneTimeout = nil
            local cfg = getSceneConfig('default')
            local picked = pickTrack(cfg)
            pushTrackToClient(src, cfg, picked)
            print(('[atmosphere] ⏰ %s: "%s" 超时 → auto-revert to default')
                :format(GetPlayerName(src), scene))
            -- Start silence-gap chain
            scheduleNextSilenceTrack(src)
        end
    end)
end

-- ─── Layer 1: Validate Source ────────────────────────────

local function validateSource(src)
    if not src or type(src) ~= 'number' or src < 1 then
        return false, 'invalid_source'
    end
    if not GetPlayerName(src) then
        return false, 'player_offline'
    end
    return true
end

-- ─── Layer 2: Sanitize Input ─────────────────────────────

local function sanitizeScene(sceneName)
    if not sceneName or type(sceneName) ~= 'string' then
        return false, 'invalid_scene_type'
    end
    local cfg = getSceneConfig(sceneName)
    if not cfg then
        return false, 'unknown_scene'
    end
    return true, cfg
end

local function sanitizeVolume(vol)
    if vol == nil then return true, nil end
    if type(vol) ~= 'number' then return false, 'volume_not_number' end
    if vol < 0.0 or vol > 1.0 then return false, 'volume_out_of_range' end
    return true, vol
end

-- ─── Layer 3: Cooldown Check ─────────────────────────────

local function checkCooldown(src, sceneName, now)
    local st = getPlayerState(src)
    -- Only enforce cooldown when re-triggering the SAME scene (prevent spam)
    if st.scene ~= sceneName then return true end
    local cd = SCENE_COOLDOWNS[sceneName] or 5000
    if cd <= 0 then return true end
    local elapsed = now - st.lastRequestAt
    if elapsed < cd then
        return false, 'cooldown', cd - elapsed
    end
    return true
end

-- ─── Layer 4: Priority Gate ──────────────────────────────

local function checkPriority(src, newScene)
    local st = getPlayerState(src)
    local currentPriority = SCENE_PRIORITY[st.scene] or 0
    local newPriority     = SCENE_PRIORITY[newScene] or 0

    -- 'default' and 'silent' can always be overridden
    if currentPriority <= 0 then return true end

    -- Higher or equal priority can interrupt
    if newPriority >= currentPriority then return true end

    return false, 'blocked_by_priority', st.scene, currentPriority
end

-- ─── Layer 5: Rate Limit ─────────────────────────────────

local function checkRateLimit(src, now)
    local st = getPlayerState(src)

    -- Reset window if expired
    if now - st.requestWindowStart > RATE_LIMIT_WINDOW then
        st.requestCount = 0
        st.requestWindowStart = now
    end

    st.requestCount = st.requestCount + 1

    if st.requestCount > RATE_LIMIT_MAX then
        return false, 'rate_limited'
    end
    return true
end

-- ─── Full Security Chain ─────────────────────────────────

local function securityChain(src, sceneName, volume)
    local ok, err, detail = validateSource(src)
    if not ok then return false, err end

    ok, err = sanitizeScene(sceneName)
    if not ok then return false, err end

    ok, err = sanitizeVolume(volume)
    if not ok then return false, err end

    local now = GetGameTimer()  -- ms since server start
    ok, err, detail = checkCooldown(src, sceneName, now)
    if not ok then return false, err, detail end

    ok, err, detail = checkPriority(src, sceneName)
    if not ok then return false, err, detail end

    ok, err = checkRateLimit(src, now)
    if not ok then return false, err end

    return true
end

-- ─── Public API ──────────────────────────────────────────

local AtmosphereService = {}

--- PlayScene — trigger a scene change for a player.
--- @param source number  Player server ID
--- @param scene  string  Scene name (must exist in config/scenes.lua)
--- @param volume? number Optional override volume 0.0-1.0
--- @return boolean, string  success, error message
function AtmosphereService.PlayScene(source, scene, volume)
    local ok, err, detail = securityChain(source, scene, volume)
    if not ok then
        if err == 'cooldown' then
            -- silently skip cooldown, don't spam logs
            return false, err
        end
        -- Log security rejection for audit
        print('[^3atmosphere^7] Security: PlayScene rejected src=' .. tostring(source) ..
              ' scene=' .. tostring(scene) .. ' reason=' .. err .. ' detail=' .. tostring(detail))
        return false, err
    end

    local cfg = getSceneConfig(scene)
    if not cfg then
        return false, 'config_missing'
    end

    local finalVolume = volume or cfg.volume
    local st = getPlayerState(source)

    -- Cancel previous silence timer if switching to a different scene
    if st.scene ~= scene then
        cancelSilenceTimer(source)
    end

    -- Update state
    st.scene = scene
    st.volume = finalVolume
    st.lastRequestAt = GetGameTimer()

    -- Schedule auto-revert for timed scenes (chase/danger)
    scheduleSceneTimeout(source, scene)

    -- Pick track (supports single track or random pool)
    local trackName = pickTrack(cfg)
    pushTrackToClient(source, cfg, trackName)

    -- Minecraft-style silence gap for default scene
    if scene == 'default' then
        scheduleNextSilenceTrack(source)
    end

    -- Publish audit event
    if Bus and Bus.Plugin and Bus.Plugin.Publish then
        Bus.Plugin.Publish('atmosphere:scene_changed', {
            source = source,
            scene  = scene,
            track  = trackName,
            volume = finalVolume,
        })
    end

    return true
end

--- StopBGM — stop all BGM for a player (return to silence).
function AtmosphereService.StopBGM(source)
    if not validateSource(source) then
        return false
    end
    local st = getPlayerState(source)
    st.scene = 'silent'
    st.volume = 0
    TriggerClientEvent('tcity-atmosphere:stopBGM', source)
    return true
end

--- SetVolume — adjust volume for the current scene (player preference).
function AtmosphereService.SetVolume(source, volume)
    local ok, err = validateSource(source)
    if not ok then return false, err end

    ok, err = sanitizeVolume(volume)
    if not ok then return false, err end

    local st = getPlayerState(source)
    st.volume = volume

    TriggerClientEvent('tcity-atmosphere:setVolume', source, volume)
    return true
end

--- GetCurrentScene — query the active scene for a player.
function AtmosphereService.GetCurrentScene(source)
    if not validateSource(source) then
        return nil, 'invalid_source'
    end
    local st = getPlayerState(source)
    return st.scene, st.volume
end

-- ─── Debug Command: /atmos ────────────────────────────────

RegisterCommand('atmos', function(source, args)
    local src = source
    local isConsole = (src == 0)
    local sub = args[1] and args[1]:lower()
    local chatMsg = nil
    local playerName = (src > 0) and GetPlayerName(src) or 'CONSOLE'

    if sub == 'chase' or sub == 'danger' or sub == 'respawn' or
       sub == 'complete' or sub == 'default' or sub == 'silent' then
        -- Bypass security for console (admin)
        local ok, err
        if isConsole then
            ok = true
            local st = getPlayerState(src)
            cancelSilenceTimer(src)
            st.scene = sub
            st.lastRequestAt = GetGameTimer()
            local cfg = getSceneConfig(sub)
            if cfg then
                local trackName = pickTrack(cfg)
                pushTrackToClient(src, cfg, trackName)
                if sub == 'default' then scheduleNextSilenceTrack(src) end
            end
        else
            ok, err = AtmosphereService.PlayScene(src, sub)
        end
        if ok then
            chatMsg = ('🎵 Scene → %s'):format(sub)
            print(('[atmos] %s → scene "%s"'):format(playerName, sub))
        else
            chatMsg = ('❌ Scene "%s" rejected: %s'):format(sub, err)
            print(('[atmos] %s → "%s" rejected: %s'):format(playerName, sub, err))
        end
    elseif sub == 'stop' then
        if isConsole then
            TriggerClientEvent('tcity-atmosphere:stopBGM', -1)
        else
            AtmosphereService.StopBGM(src)
        end
        chatMsg = '🔇 BGM stopped'
        print(('[atmos] %s → BGM stopped'):format(playerName))
    elseif sub == 'vol' and args[2] then
        local vol = tonumber(args[2])
        if vol and vol >= 0.0 and vol <= 1.0 then
            if isConsole then
                TriggerClientEvent('tcity-atmosphere:setVolume', -1, vol)
            else
                AtmosphereService.SetVolume(src, vol)
            end
            chatMsg = ('🔊 Volume = %.2f'):format(vol)
            print(('[atmos] %s → volume = %.2f'):format(playerName, vol))
        else
            chatMsg = '❌ Volume must be 0.0 ~ 1.0'
            print(('[atmos] %s → invalid volume: %s'):format(playerName, tostring(args[2])))
        end
    elseif sub == 'reset' then
        -- Force reset: bypass priority, use PlayScene directly
        local st = getPlayerState(src)
        st.scene = 'silent'  -- clear current scene so priority gate passes
        local ok, err = AtmosphereService.PlayScene(src, 'default')
        if ok then
            chatMsg = '🔄 Force reset → default (silence-gap)'
            print(('[atmos] %s → force reset to default'):format(playerName))
        else
            chatMsg = ('❌ Reset failed: %s'):format(err)
            print(('[atmos] %s → reset failed: %s'):format(playerName, err))
        end
    elseif sub == 'info' then
        if isConsole then
            chatMsg = 'ℹ️ Console mode — /atmos info 仅对玩家可用'
        else
            local scene, vol = AtmosphereService.GetCurrentScene(src)
            if not scene then
                chatMsg = ('ℹ️ 未就绪 (err=%s)'):format(tostring(vol))
            else
                local volNum = tonumber(vol) or 0
                chatMsg = ('ℹ️ scene="%s" vol=%.2f'):format(scene, volNum)
            end
        end
        print(('[atmos] %s → %s'):format(playerName, chatMsg))
    else
        chatMsg = '用法: /atmos <chase|danger|respawn|complete|default|silent|reset|stop|info|vol>'
        print('[atmos] ' .. chatMsg)
    end

    -- Feedback: chat message for players, console gets print() only
    if chatMsg and src > 0 then
        TriggerClientEvent('chat:addMessage', src, {
            color = {255, 200, 100},
            multiline = false,
            args = {'[atmos]', chatMsg}
        })
    end
end, false)

-- ─── Lifecycle ────────────────────────────────────────────

-- Auto-start default BGM when player fully loads
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if Player and Player.PlayerData and Player.PlayerData.source then
        local src = Player.PlayerData.source
        AtmosphereService.PlayScene(src, 'default')
    end
end)

-- Cleanup on player drop
AddEventHandler('playerDropped', function(reason)
    local src = source
    if playerState[src] then
        playerState[src] = nil
    end
end)

-- ─── Register on Bus (with retry for restart resilience) ──

local function tryRegister()
    if not Bus or not Bus.RegisterService then return false end
    Bus.RegisterService('atmosphere', {
        PlayScene       = AtmosphereService.PlayScene,
        StopBGM         = AtmosphereService.StopBGM,
        SetVolume       = AtmosphereService.SetVolume,
        GetCurrentScene = AtmosphereService.GetCurrentScene,
    })
    print('[^2tcity-atmosphere^7] Service registered on Bus as ^4atmosphere^7')
    if Bus.Plugin and Bus.Plugin.Subscribe then
        Bus.Plugin.Subscribe('atmosphere:scene_change', function(payload)
            if not payload or not payload.source then return end
            AtmosphereService.PlayScene(payload.source, payload.scene, payload.volume)
        end, 'tcity-atmosphere')
    end
    return true
end

if not tryRegister() then
    print('[^3tcity-atmosphere^7] Bus not ready — retrying (max 30s)...')
    local attempts = 0
    Citizen.CreateThread(function()
        while attempts < 60 do
            Citizen.Wait(500)
            attempts = attempts + 1
            if tryRegister() then return end
        end
        print('[^1tcity-atmosphere^7] ERROR: Bus unavailable after 30s — NOT registered')
    end)
end
