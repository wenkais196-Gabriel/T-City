-- server/evidence.lua — legacy evidence:server:* handlers (FIT-03).
--
-- Every handler in this file is reachable by any connected client, so nothing
-- may trust what the client sends. Two rules:
--
--  * the "create" events are fired by the player who leaves the trace
--    (qb-ambulancejob bleeding, a robbery scene in qb-storerobbery /
--    qb-houserobbery, any shooter's casing), so they can NOT be police-only:
--    the identity is derived from the caller's own PlayerData and the drop must
--    be within MAX_COORDS_DRIFT of the caller's ped;
--  * the destructive paths (Clear*) and the evidence-bag pickups are on-duty
--    police only, rate limited and length capped.
--
-- The tables below are the server's memory of the drops it announced; they are
-- bounded (cap + TTL) so a client cannot grow them without limit.

local Casings = {}
local BloodDrops = {}
local FingerDrops = {}
local PlayerStatus = {}

local MAX_TRACKED_DROPS = 500      -- per table, bounds a spamming client's memory
local TRACKED_TTL = 1800           -- seconds a server-side drop row is kept
local MAX_CLEAR_LIST = 200        -- ids accepted per Clear* request
local MAX_COORDS_DRIFT = 25.0      -- metres between the caller's ped and the drop
local PICKUP_COOLDOWN = 1          -- seconds between Add*ToInventory per source
local MAX_STATUS_ENTRIES = 13      -- client/evidence.lua ships 13 status ids
local MAX_STATUS_TEXT = 64
local MAX_STATUS_TIME = 3600
local MAX_INFO_FIELD = 120

-- Functions

local function CreateBloodId()
    if BloodDrops then
        local bloodId = math.random(10000, 99999)
        while BloodDrops[bloodId] do
            bloodId = math.random(10000, 99999)
        end
        return bloodId
    else
        local bloodId = math.random(10000, 99999)
        return bloodId
    end
end

local function CreateFingerId()
    if FingerDrops then
        local fingerId = math.random(10000, 99999)
        while FingerDrops[fingerId] do
            fingerId = math.random(10000, 99999)
        end
        return fingerId
    else
        local fingerId = math.random(10000, 99999)
        return fingerId
    end
end

local function CreateCasingId()
    if Casings then
        local caseId = math.random(10000, 99999)
        while Casings[caseId] do
            caseId = math.random(10000, 99999)
        end
        return caseId
    else
        local caseId = math.random(10000, 99999)
        return caseId
    end
end

local function countKeys(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

--- A client may only report a drop where its own ped actually stands.
local function sanitizeCoords(coords)
    if type(coords) ~= 'table' then return nil end
    local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    if not x or not y or not z then return nil end
    -- NaN never compares equal to itself; infinities are rejected by the range.
    if x ~= x or y ~= y or z ~= z then return nil end
    if math.abs(x) > 10000.0 or math.abs(y) > 10000.0 or math.abs(z) > 10000.0 then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function coordsNearSource(src, coords)
    local clean = sanitizeCoords(coords)
    if not clean then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local origin = GetEntityCoords(ped)
    if #(vector3(clean.x, clean.y, clean.z) - origin) > MAX_COORDS_DRIFT then return nil end
    return clean
end

local function onlinePlayer(src)
    if not src or src == 0 then return nil end
    local player = QBCore.Functions.GetPlayer(src)
    if not player or type(player.PlayerData) ~= 'table' then return nil end
    return player
end

--- On-duty officer holding the capability, or nil. `PolicePolicy.Can` already
--- rejects a wrong job, an off-duty officer and a too-low grade.
local function onDutyOfficer(src, capability)
    local player = onlinePlayer(src)
    if not player then return nil end
    local allowed = PolicePolicy.Can(player.PlayerData, capability)
    if not allowed then return nil end
    return player
end

--- Remember a drop server-side. The TTL sweep keeps the table self-limiting;
--- the hard cap stops a burst before the sweep can run.
local function trackDrop(store, id, row)
    if countKeys(store) >= MAX_TRACKED_DROPS then
        local now = os.time()
        for key, value in pairs(store) do
            if type(value) == 'table' and value.at and now - value.at > TRACKED_TTL then
                store[key] = nil
            end
        end
        if countKeys(store) >= MAX_TRACKED_DROPS then return false end
    end
    row.at = os.time()
    store[id] = row
    return true
end

local pickupAt = {}
local pickupWrites = 0

--- One pickup per source per second.
local function pickupRateLimited(src)
    pickupWrites = pickupWrites + 1
    if pickupWrites % 64 == 0 then
        local now = os.time()
        for key, at in pairs(pickupAt) do
            if now - at > 60 then pickupAt[key] = nil end
        end
    end
    local now = os.time()
    local last = pickupAt[src]
    if last and now - last < PICKUP_COOLDOWN then return true end
    pickupAt[src] = now
    return false
end

--- Copy only the item fields the inventory UI knows about and cap every value,
--- so a client cannot smuggle an arbitrary blob into a filled evidence bag.
local function evidenceInfo(info, keys)
    if type(info) ~= 'table' then return nil end
    local clean = {}
    local kept = 0
    for _, key in ipairs(keys) do
        local value = info[key]
        if type(value) == 'string' then
            clean[key] = value:sub(1, MAX_INFO_FIELD)
            kept = kept + 1
        elseif type(value) == 'number' then
            clean[key] = value
            kept = kept + 1
        end
    end
    if kept == 0 then return nil end
    return clean
end

--- Validate an id list before touching it. A malformed element rejects the
--- request (no partial apply); a list longer than the cap is truncated, since
--- the list only ever comes from the caller's own client cache.
local function readIdList(list)
    if type(list) ~= 'table' then return nil end
    local ids = {}
    for _, id in pairs(list) do
        if type(id) ~= 'number' and type(id) ~= 'string' then return nil end
        ids[#ids + 1] = id
        if #ids >= MAX_CLEAR_LIST then break end
    end
    return ids
end

-- Callbacks

QBCore.Functions.CreateCallback('police:GetPlayerStatus', function(source, cb, playerId)
    -- Statuses (bloody hands, gunpowder, red eyes…) are PII-ish; only an
    -- on-duty officer may read another player's list.
    local viewer = onlinePlayer(source)
    if not viewer or not PolicePolicy.Can(viewer.PlayerData, 'lookup.citizen') then
        cb({})
        return
    end
    local Player = QBCore.Functions.GetPlayer(playerId)
    local statList = {}
    if Player then
        local rows = PlayerStatus[Player.PlayerData.source]
        if rows and next(rows) then
            for k in pairs(rows) do
                statList[#statList + 1] = rows[k].text
            end
        end
    end
    cb(statList)
end)

-- Events

--- Self-reported visible status list. The client owns this data, so the server
--- validates the shape and rebuilds a clean copy (bounded keys, text and
--- duration) instead of storing whatever table arrived.
RegisterNetEvent('evidence:server:UpdateStatus', function(data)
    local src = source
    if not onlinePlayer(src) then return end
    if type(data) ~= 'table' then return end
    local clean = {}
    local total = 0
    for statusId, entry in pairs(data) do
        total = total + 1
        if total > MAX_STATUS_ENTRIES then return end
        if type(statusId) ~= 'string' or #statusId == 0 or #statusId > 24 then return end
        if type(entry) ~= 'table' then return end
        local text = entry.text
        local time = tonumber(entry.time)
        if type(text) ~= 'string' or #text > MAX_STATUS_TEXT or not time then return end
        if time < 0 then time = 0 end
        if time > MAX_STATUS_TIME then time = MAX_STATUS_TIME end
        clean[statusId] = { text = text, time = math.floor(time) }
    end
    PlayerStatus[src] = clean
end)

--- A drop belongs to the player who bled, and only that player's own client can
--- report it. The citizenid the client sends is ignored on purpose.
RegisterNetEvent('evidence:server:CreateBloodDrop', function(citizenid, bloodtype, coords)
    local src = source
    local player = onlinePlayer(src)
    if not player then return end
    local where = coordsNearSource(src, coords)
    if not where then return end
    local dna = tostring(player.PlayerData.citizenid or '')
    if dna == '' then return end
    local metadata = type(player.PlayerData.metadata) == 'table' and player.PlayerData.metadata or {}
    local blood = metadata['bloodtype']
    if type(blood) ~= 'string' or blood == '' then
        blood = type(bloodtype) == 'string' and bloodtype:sub(1, 16) or nil
    end
    if not blood or blood == '' then return end
    local bloodId = CreateBloodId()
    if not trackDrop(BloodDrops, bloodId, { dna = dna, bloodtype = blood }) then return end
    TriggerClientEvent('evidence:client:AddBlooddrop', -1, bloodId, dna, blood, where)
end)

--- Same rule: the fingerprint is the caller's, never a value the caller picked.
RegisterNetEvent('evidence:server:CreateFingerDrop', function(coords)
    local src = source
    local player = onlinePlayer(src)
    if not player then return end
    local metadata = type(player.PlayerData.metadata) == 'table' and player.PlayerData.metadata or {}
    local fingerprint = metadata['fingerprint']
    if type(fingerprint) ~= 'string' or fingerprint == '' then return end
    local where = coordsNearSource(src, coords)
    if not where then return end
    local fingerId = CreateFingerId()
    if not trackDrop(FingerDrops, fingerId, { fingerprint = fingerprint }) then return end
    TriggerClientEvent('evidence:client:AddFingerPrint', -1, fingerId, fingerprint, where)
end)

--- Clearing evidence is destructive and is a police-only command
--- (server/commands.lua /clearcasings, /clearblood). The id list is capped and
--- validated before anything is removed.
RegisterNetEvent('evidence:server:ClearBlooddrops', function(blooddropList)
    local src = source
    if not onDutyOfficer(src, 'evidence.view') then return end
    local ids = readIdList(blooddropList)
    if not ids then return end
    for _, id in ipairs(ids) do
        TriggerClientEvent('evidence:client:RemoveBlooddrop', -1, id)
        BloodDrops[id] = nil
    end
end)

--- Pick up a blood drop into an evidence bag: on-duty police, an empty bag, and
--- one pickup per second.
RegisterNetEvent('evidence:server:AddBlooddropToInventory', function(bloodId, bloodInfo)
    local src = source
    if not onDutyOfficer(src, 'evidence.register') then return end
    if pickupRateLimited(src) then return end
    local id = tonumber(bloodId)
    if not id then return end
    local info = evidenceInfo(bloodInfo, { 'label', 'type', 'street', 'dnalabel', 'bloodtype' })
    if not info then return end
    if exports['qb-inventory']:RemoveItem(src, 'empty_evidence_bag', 1, false, 'evidence:server:AddBlooddropToInventory') then
        if exports['qb-inventory']:AddItem(src, 'filled_evidence_bag', 1, false, info, 'evidence:server:AddBlooddropToInventory') then
            TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['filled_evidence_bag'], 'add')
            TriggerClientEvent('evidence:client:RemoveBlooddrop', -1, id)
            BloodDrops[id] = nil
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.have_evidence_bag'), 'error')
    end
end)

RegisterNetEvent('evidence:server:AddFingerprintToInventory', function(fingerId, fingerInfo)
    local src = source
    if not onDutyOfficer(src, 'evidence.register') then return end
    if pickupRateLimited(src) then return end
    local id = tonumber(fingerId)
    if not id then return end
    local info = evidenceInfo(fingerInfo, { 'label', 'type', 'street', 'fingerprint' })
    if not info then return end
    if exports['qb-inventory']:RemoveItem(src, 'empty_evidence_bag', 1, false, 'evidence:server:AddFingerprintToInventory') then
        if exports['qb-inventory']:AddItem(src, 'filled_evidence_bag', 1, false, info, 'evidence:server:AddFingerprintToInventory') then
            TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['filled_evidence_bag'], 'add')
            TriggerClientEvent('evidence:client:RemoveFingerprint', -1, id)
            FingerDrops[id] = nil
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.have_evidence_bag'), 'error')
    end
end)

--- A bullet casing is dropped by whoever is shooting, so this must stay
--- available to every player; the serial number is read from the shooter's own
--- inventory, never from the payload.
RegisterNetEvent('evidence:server:CreateCasing', function(weapon, coords)
    local src = source
    -- 诊断开关（默认关）：把每条**拒绝**路径也打出来。否则"日志里没有 [evidence] 行"
    -- 既可能是客户端没发，也可能是服务端在下面某个 return 上静默丢掉了。
    local debug = GetConvarInt('tcity_evidence_debug', 0) == 1
    local Player = onlinePlayer(src)
    if not Player then
        if debug then print(('[evidence] rejected: no player src=%s'):format(tostring(src))) end
        return
    end
    if type(weapon) ~= 'number' then
        if debug then print(('[evidence] rejected: weapon not a number src=%s'):format(tostring(src))) end
        return
    end
    local where = coordsNearSource(src, coords)
    if not where then
        if debug then print(('[evidence] rejected: coords too far src=%s'):format(tostring(src))) end
        return
    end
    local casingId = CreateCasingId()
    local weaponInfo = QBCore.Shared.Weapons[weapon]
    local serieNumber = nil
    if weaponInfo then
        local weaponItem = Player.Functions.GetItemByName(weaponInfo['name'])
        if weaponItem then
            if weaponItem.info and weaponItem.info ~= '' then
                serieNumber = weaponItem.info.serie
            end
        end
    end
    if type(serieNumber) ~= 'string' then serieNumber = nil end
    if not trackDrop(Casings, casingId, { weapon = weapon, serie = serieNumber }) then
        if debug then print(('[evidence] rejected: casing table full src=%s'):format(tostring(src))) end
        return
    end
    -- 诊断开关（默认关）：`set tcity_evidence_debug 1` 打开后，每颗弹壳在服务端落一行。
    -- 这个开关的用途是**把"看不到弹壳"拆成两半**：服务端有行 = 客户端发了、问题只在客户端显示；
    -- 没行 = 客户端根本没发（枪不在白名单外、或 IsPedShooting 没触发）。
    if GetConvarInt('tcity_evidence_debug', 0) == 1 then
        print(('[evidence] casing %s weapon=%s src=%s serie=%s')
            :format(tostring(casingId), tostring(weapon), tostring(src), tostring(serieNumber)))
    end
    TriggerClientEvent('evidence:client:AddCasing', -1, casingId, weapon, where, serieNumber)
end)

RegisterNetEvent('evidence:server:ClearCasings', function(casingList)
    local src = source
    if not onDutyOfficer(src, 'evidence.view') then return end
    local ids = readIdList(casingList)
    if not ids then return end
    for _, id in ipairs(ids) do
        TriggerClientEvent('evidence:client:RemoveCasing', -1, id)
        Casings[id] = nil
    end
end)

RegisterNetEvent('evidence:server:AddCasingToInventory', function(casingId, casingInfo)
    local src = source
    if not onDutyOfficer(src, 'evidence.register') then return end
    if pickupRateLimited(src) then return end
    local id = tonumber(casingId)
    if not id then return end
    local info = evidenceInfo(casingInfo, { 'label', 'type', 'street', 'ammolabel', 'ammotype', 'serie' })
    if not info then return end
    if exports['qb-inventory']:RemoveItem(src, 'empty_evidence_bag', 1, false, 'evidence:server:AddCasingToInventory') then
        if exports['qb-inventory']:AddItem(src, 'filled_evidence_bag', 1, false, info, 'evidence:server:AddCasingToInventory') then
            TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['filled_evidence_bag'], 'add')
            TriggerClientEvent('evidence:client:RemoveCasing', -1, id)
            Casings[id] = nil
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.have_evidence_bag'), 'error')
    end
end)
