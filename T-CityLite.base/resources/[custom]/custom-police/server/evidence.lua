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
-- 掉落行保留多久（秒）。默认 30 分钟；运维/测试可用 convar 覆盖：
--   set tcity_evidence_ttl 60      -- 一分钟就清，方便现场验证
-- 每次清扫时才读 convar：这样改完不用重启资源，单测也能直接改。
local DEFAULT_TRACKED_TTL = 1800
local TTL_SWEEP_INTERVAL = 60      -- 清扫周期（秒）
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
    -- vector3 在 CfxLua 里是原生类型，不是 table：旧客户端（以及任何沿用原生 vector3
    -- 的调用者）会因为 type ~= 'table' 被整枪丢掉，所以这里两种形状都收。
    if type(coords) == 'vector3' then
        return { x = coords.x, y = coords.y, z = coords.z }
    end
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

---@return table|nil clean, string|nil reason
local function coordsNearSource(src, coords)
    local clean = sanitizeCoords(coords)
    if not clean then return nil, 'coords are not a {x,y,z} table' end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil, 'no ped for source' end
    local origin = GetEntityCoords(ped)
    if #(vector3(clean.x, clean.y, clean.z) - origin) > MAX_COORDS_DRIFT then
        return nil, 'coords too far from ped'
    end
    return clean, nil
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
--- 清掉老于 TTL 的行，并**广播**给所有客户端让它们删掉屏幕上的标记。
--- 只删本地表不广播 = 客户端留着一个"幽灵"标记，玩家走过去按 G 什么也换不到。
---@return number removed
local function pruneExpired(store, removeEvent, now)
    local ttl = GetConvarInt('tcity_evidence_ttl', DEFAULT_TRACKED_TTL)
    local removed = 0
    for id, row in pairs(store) do
        if type(row) == 'table' and row.at and now - row.at > ttl then
            store[id] = nil
            TriggerClientEvent(removeEvent, -1, id)
            removed = removed + 1
        end
    end
    return removed
end

local function pruneExpiredDrops()
    local now = os.time()
    local removed = 0
    removed = removed + pruneExpired(Casings, 'evidence:client:RemoveCasing', now)
    removed = removed + pruneExpired(BloodDrops, 'evidence:client:RemoveBlooddrop', now)
    removed = removed + pruneExpired(FingerDrops, 'evidence:client:RemoveFingerprint', now)
    if removed > 0 and GetConvarInt('tcity_evidence_debug', 0) == 1 then
        print(('[evidence] expired %d drops'):format(removed))
    end
    return removed
end

local function trackDrop(store, id, row, removeEvent)
    if countKeys(store) >= MAX_TRACKED_DROPS then
        pruneExpired(store, removeEvent, os.time())
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

--- 客户端唯一被允许提供的字段是**街道名**：只有客户端拿得到原生街道名。
--- 其余（weapon / serie / dna / bloodtype / fingerprint）一律用服务端自己的掉落记录，
--- 否则改过的客户端可以凭空造一个证据袋，或者把别人的 DNA 写进去。
---@return string|nil
local function streetFromClient(info)
    local clean = evidenceInfo(info, { 'street' })
    return clean and clean.street or nil
end

--- 与客户端 DnaHash 一致：把 citizenid 逐字节转成十六进制（只用于展示，不做校验）。
local function dnaHash(value)
    return (tostring(value or ''):gsub('.', function(c)
        return string.format('%02x', string.byte(c))
    end))
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
    if not trackDrop(BloodDrops, bloodId, { dna = dna, bloodtype = blood }, 'evidence:client:RemoveBlooddrop') then return end
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
    if not trackDrop(FingerDrops, fingerId, { fingerprint = fingerprint }, 'evidence:client:RemoveFingerprint') then return end
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
    local drop = BloodDrops[id]
    if type(drop) ~= 'table' then
        if GetConvarInt('tcity_evidence_debug', 0) == 1 then
            print(('[evidence] pickup refused: blood %s is not tracked here'):format(tostring(id)))
        end
        return
    end
    local info = {
        label = Lang:t('info.blood'),
        type = 'blood',
        street = streetFromClient(bloodInfo),
        dnalabel = dnaHash(drop.dna),
        bloodtype = drop.bloodtype,
    }
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
    local drop = FingerDrops[id]
    if type(drop) ~= 'table' then
        if GetConvarInt('tcity_evidence_debug', 0) == 1 then
            print(('[evidence] pickup refused: fingerprint %s is not tracked here'):format(tostring(id)))
        end
        return
    end
    local info = {
        label = Lang:t('info.fingerprint'),
        type = 'fingerprint',
        street = streetFromClient(fingerInfo),
        fingerprint = drop.fingerprint,
    }
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
    local where, why = coordsNearSource(src, coords)
    if not where then
        if debug then print(('[evidence] rejected casing: %s src=%s'):format(why, tostring(src))) end
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
    if not trackDrop(Casings, casingId, { weapon = weapon, serie = serieNumber }, 'evidence:client:RemoveCasing') then
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
    local drop = Casings[id]
    if type(drop) ~= 'table' then
        -- 服务端已经不记得这颗弹壳（清场 / 上限淘汰 / 资源重启）：客户端屏幕上可能还留着
        -- 一个幽灵标记，绝不能凭它发证据袋。
        if GetConvarInt('tcity_evidence_debug', 0) == 1 then
            print(('[evidence] pickup refused: casing %s is not tracked here'):format(tostring(id)))
        end
        return
    end
    local weaponInfo = QBCore.Shared.Weapons[drop.weapon]
    local ammotype = type(weaponInfo) == 'table' and weaponInfo.ammotype or nil
    local info = {
        label = Lang:t('info.casing'),
        type = 'casing',
        street = streetFromClient(casingInfo),
        ammolabel = ammotype and Config.AmmoLabels[ammotype] or nil,
        ammotype = drop.weapon,
        serie = drop.serie,
    }
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

-- ── 定时清扫 ─────────────────────────────────────────────────────────────────
-- 之前 TTL 只在"表满 500"时才顺手跑一次，于是没到上限的地面证据整局都不会消失：
-- 地上越积越多，而且客户端连一条移除消息都收不到。这里改成每分钟扫一次，
-- 过期就删并广播 Remove*，客户端屏幕上的箭头才会跟着消失。
--
-- 抽成 EvidenceMaintenance 是为了单测能直接驱动一次清扫（不用等线程/改系统时间）。
EvidenceMaintenance = {
    PruneExpired = pruneExpiredDrops,
}

CreateThread(function()
    while true do
        Wait(TTL_SWEEP_INTERVAL * 1000)
        pruneExpiredDrops()
    end
end)
