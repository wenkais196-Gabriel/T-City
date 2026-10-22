-- tests/agent/lua/cases/live_rules.lua — pure-function contract for live perception.
--
-- Focus: quantisation, plate masking, metadata allow-list, limit clamps and a
-- PII scan over the serialised projection (license / ip / identifier / phone /
-- inventory must never appear).

return {
    run = function(ctx)
        local LiveRules = assert(_G.LiveRules, 'server/live_rules.lua was not loaded')
        local json = assert(_G.json, 'tests/agent/lua/json.lua was not loaded')

        local results = {}
        local failed = 0

        local function check(name, fn)
            local record = { name = name, ok = true }
            local ok, err = pcall(fn)
            if not ok then
                record.ok = false
                record.error = tostring(err)
                failed = failed + 1
            end
            results[#results + 1] = record
        end

        local function fail(message)
            error(message, 0)
        end

        local function assertAllowedKeys(tableValue, allowed, label)
            for key in pairs(tableValue) do
                if allowed[key] ~= true then
                    fail(('%s has unexpected field %q'):format(label, tostring(key)))
                end
            end
        end

        local FORBIDDEN_WORDS = { 'license', 'ip', 'identifier', 'phone', 'inventory' }
        local FORBIDDEN_VALUES = { 'secret', 'deadbeef', '555-0100', 'serial', 'wallet' }

        local function assertNoPII(value, label)
            local text = json.encode(value)
            assert(type(text) == 'string', label .. ': projection did not encode')
            local lowered = text:lower()
            for _, word in ipairs(FORBIDDEN_WORDS) do
                if lowered:find(word, 1, true) then
                    fail(('%s leaks forbidden word %q: %s'):format(label, word, text))
                end
            end
            for _, word in ipairs(FORBIDDEN_VALUES) do
                if lowered:find(word, 1, true) then
                    fail(('%s leaks forbidden value %q: %s'):format(label, word, text))
                end
            end
        end

        -- 1. limit clamp ------------------------------------------------------
        check('clamp_limit_defaults_and_bounds', function()
            assert(LiveRules.clamp_limit(nil) == 48, 'nil limit must default to 48')
            assert(LiveRules.clamp_limit('abc') == 48, 'non-numeric limit must default')
            assert(LiveRules.clamp_limit(0) == 1, 'zero limit must clamp to 1')
            assert(LiveRules.clamp_limit(-10) == 1, 'negative limit must clamp to 1')
            assert(LiveRules.clamp_limit(999) == 48, 'limit must clamp to 48')
            assert(LiveRules.clamp_limit('10') == 10, 'numeric string must parse')
            assert(LiveRules.clamp_limit(10.9) == 10, 'fractional limit must floor')
            assert(LiveRules.clamp_limit(5, 50, 1, 200) == 5, 'explicit max must apply')
            assert(LiveRules.clamp_limit(500, 50, 1, 200) == 200, 'explicit max must clamp')
        end)

        -- 2. position quantisation -------------------------------------------
        check('quantize_position_coarse_grid', function()
            local position = LiveRules.quantize_position({ x = 123.4, y = -1040.2, z = 27.4 }, 25)
            assert(position.x == 125, 'x should snap to 125, got ' .. tostring(position.x))
            assert(position.y == -1050, 'y should snap to -1050, got ' .. tostring(position.y))
            assert(position.z == 25, 'z should snap to 25, got ' .. tostring(position.z))
        end)

        check('quantize_position_fine_is_identity', function()
            local source = { x = 123.4, y = -1040.2, z = 27.4 }
            local position = LiveRules.quantize_position(source, 0)
            assert(position.x == 123.4 and position.y == -1040.2 and position.z == 27.4,
                'precision 0 must not quantise')
            local untouched = LiveRules.quantize_position(source, nil)
            assert(untouched.x == 123.4, 'nil precision must not quantise')
            local invalid = LiveRules.quantize_position({ x = 'nope', y = 0, z = 0 }, 25)
            assert(invalid == nil, 'invalid coordinates must return nil')
        end)

        -- 3. plate masking ----------------------------------------------------
        check('mask_plate_keeps_only_edges', function()
            local masked = LiveRules.mask_plate('TC123AB')
            assert(masked == 'TC***AB', 'unexpected mask: ' .. tostring(masked))
            assert(masked ~= 'TC123AB', 'plate must not survive unmasked')
            assert(LiveRules.mask_plate('AB12CD') == 'AB**CD')
            assert(LiveRules.mask_plate('AB') == '**', 'short plates must be fully masked')
            assert(LiveRules.mask_plate(nil) == nil)
            assert(LiveRules.mask_plate('') == nil)
        end)

        -- 4. metadata allow-list ----------------------------------------------
        check('sanitize_metadata_whitelist', function()
            local metadata = LiveRules.sanitize_metadata({
                health = 172,
                armor = 35,
                hunger = '88',
                thirst = 71,
                stress = 12,
                isdead = true,
                inlaststand = false,
                handcuffed = true,
                injail = 1,
                fingerprint = 'FP-SECRET',
                walletid = 'WALLET-SECRET',
                phone = { number = '555-0100' },
                callsign = 'SECRET',
            })
            local allowed = assert(_G.LiveRules.METADATA_KEYS)
            assertAllowedKeys(metadata, allowed, 'metadata')
            assert(metadata.health == 172 and metadata.hunger == 88, 'numeric metadata must be copied')
            assert(metadata.isdead == true and metadata.inlaststand == false)
            assert(metadata.ishandcuffed == true, 'handcuffed alias must map to ishandcuffed')
            assert(metadata.injail == nil, 'injail must not be projected')
            assert(metadata.fingerprint == nil and metadata.walletid == nil and metadata.phone == nil)
        end)

        -- 5. player projection ------------------------------------------------
        local player = {
            PlayerData = {
                source = 12,
                citizenid = 'ABC12345',
                name = 'Vito Maretti',
                license = 'license:DEADBEEF',
                identifiers = { discord = 'discord:SECRET', steam = 'steam:SECRET' },
                charinfo = { firstname = 'Vito', lastname = 'Maretti', phone = '555-0100', account = 'SECRET' },
                money = { cash = 340, bank = 18220, crypto = 0 },
                job = { name = 'police', label = 'Police', grade = { level = 2, name = 'Officer' }, onduty = true },
                gang = { name = 'none', grade = { level = 0, name = 'none' } },
                metadata = {
                    health = 172,
                    armor = 35,
                    hunger = 88,
                    thirst = 71,
                    stress = 12,
                    isdead = false,
                    inlaststand = false,
                    ishandcuffed = false,
                    injail = 0,
                    fingerprint = 'FP-SECRET',
                    walletid = 'WALLET-SECRET',
                    phone = { number = '555-0100' },
                },
                items = { { name = 'bread', count = 3, info = { serial = 'SERIAL-SECRET' } } },
                inventory = { bread = 3 },
            },
        }

        local projected
        check('sanitize_player_field_allowlist', function()
            projected = assert(LiveRules.sanitize_player(player, {
                precision = 25,
                position = { x = 123.4, y = -1040.2, z = 27.4 },
                heading = 180.7,
                vehicle = { model = -1216765807, plate = 'TC123AB', seat = -1 },
                bucket = 0,
                ping = 42,
                now_ms = 1730000000000,
            }))

            local allowed = {
                citizenid = true, name = true, source = true, job = true, gang = true, money = true,
                metadata = true, position = true, heading = true, bucket = true,
                ping = true, vehicle = true, last_seen_ms = true,
            }
            assertAllowedKeys(projected, allowed, 'player')
            for key in pairs(allowed) do
                assert(projected[key] ~= nil, 'missing required field ' .. key)
            end

            assert(projected.citizenid == 'ABC12345')
            assert(projected.name == 'Vito Maretti', 'display name must survive sanitising')
            assert(projected.source == 12)
            assert(projected.last_seen_ms == 1730000000000)

            assertAllowedKeys(projected.job, { name = true, label = true, grade = true, onduty = true }, 'job')
            assert(projected.job.name == 'police' and projected.job.grade == 2 and projected.job.onduty == true)
            assertAllowedKeys(projected.gang, { name = true, grade = true }, 'gang')
            assert(projected.gang.name == 'none' and projected.gang.grade == 0)
            assertAllowedKeys(projected.money, { cash = true, bank = true, crypto = true }, 'money')
            assert(projected.money.cash == 340 and projected.money.bank == 18220)
            assertAllowedKeys(projected.position, { x = true, y = true, z = true }, 'position')
            assert(projected.position.x == 125, 'position must be quantised')
            assertAllowedKeys(projected.vehicle, { model = true, plate = true, seat = true }, 'vehicle')
            assert(projected.vehicle.plate == 'TC***AB', 'plate must be masked')
            assert(projected.vehicle.model == -1216765807 and projected.vehicle.seat == -1)
            assertAllowedKeys(projected.metadata, _G.LiveRules.METADATA_KEYS, 'metadata')
            assert(projected.metadata.health == 172 and projected.metadata.armor == 35)
        end)

        check('sanitize_player_pii_scan', function()
            assert(projected, 'projection fixture missing')
            assertNoPII(projected, 'player projection')
            local text = json.encode(projected)
            assert(not text:find('DEADBEEF', 1, true), 'license value leaked')
        end)

        check('sanitize_player_live_overrides', function()
            local live = assert(LiveRules.sanitize_player(player, {
                precision = 0,
                position = { x = 1.25, y = 2.5, z = 3.75 },
                health = 99,
                armor = 7,
                now_ms = 5,
            }))
            assert(live.metadata.health == 99, 'live health must override metadata')
            assert(live.metadata.armor == 7, 'live armour must override metadata')
            assert(live.position.x == 1.25 and live.position.y == 2.5 and live.position.z == 3.75)
        end)

        check('sanitize_player_rejects_missing_citizenid', function()
            assert(LiveRules.sanitize_player({ PlayerData = { source = 1 } }) == nil)
            assert(LiveRules.sanitize_player(nil) == nil)
        end)

        check('now_ms_injected_clock', function()
            assert(LiveRules.now_ms(function() return 12345 end) == 12345)
            local withClock = assert(LiveRules.sanitize_player(player, { clock = function() return 777 end }))
            assert(withClock.last_seen_ms == 777)
            assert(type(LiveRules.now_ms()) == 'number')
        end)

        return {
            ok = failed == 0,
            error = failed == 0 and nil or ('%d live_rules case(s) failed'):format(failed),
            data = {
                total = #results,
                passed = #results - failed,
                failed = failed,
                cases = results,
            },
        }
    end,
}
