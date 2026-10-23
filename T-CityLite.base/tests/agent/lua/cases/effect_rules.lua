-- tests/agent/lua/cases/effect_rules.lua — pure EffectRules.Normalize contract.
--
-- Positive and negative payloads for every action in the M2 whitelist, plus
-- Redact/ClampLimit/NowMs/ExecutionSite. No FiveM native is touched.

return {
    run = function(ctx)
        local env = ctx.bootstrap.Load({ agent_client = true })
        local Rules = assert(env.effect_rules or _G.EffectRules, 'shared/effect_rules.lua was not loaded')

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

        local function expectValid(name, action, payload, inspect)
            check(name, function()
                local normalized, err = Rules.Normalize(action, payload)
                assert(normalized ~= nil, 'expected a normalized payload, got ' .. tostring(err and err.code))
                assert(err == nil, 'expected no error, got ' .. tostring(err and err.code))
                if inspect then inspect(normalized) end
            end)
        end

        local function expectInvalid(name, action, payload, code, cfg)
            check(name, function()
                local normalized, err = Rules.Normalize(action, payload, cfg)
                assert(normalized == nil, 'expected rejection, got a normalized payload')
                assert(type(err) == 'table', 'error must be a table')
                assert(err.ok == false, 'error must carry ok=false')
                assert(err.code == code,
                    ('expected code %s, got %s'):format(tostring(code), tostring(err.code)))
                assert(type(err.message) == 'string' and err.message ~= '', 'error must carry a message')
            end)
        end

        -- ------------------------------------------------------------------
        -- Valid payloads
        -- ------------------------------------------------------------------
        expectValid('notify_accepts_text_and_kind', 'send_notify',
            { text = '导演：今晚码头有动作', kind = 'primary' }, function(normalized)
                assert(normalized.text == '导演：今晚码头有动作')
                assert(normalized.kind == 'primary')
            end)

        expectValid('notify_kind_defaults_to_info', 'send_notify', { text = 'hello' },
            function(normalized) assert(normalized.kind == 'info') end)

        expectValid('notify_accepts_all_kinds', 'send_notify', { text = 'x', kind = 'warning' })

        expectValid('play_anim_accepts_whitelist_chars', 'play_anim', {
            dict = 'amb@world_human_smoking@male@male_a@idle_a',
            clip = 'idle_a',
            duration_ms = 6000,
        }, function(normalized)
            assert(normalized.dict == 'amb@world_human_smoking@male@male_a@idle_a')
            assert(normalized.clip == 'idle_a')
            assert(normalized.duration_ms == 6000)
        end)

        expectValid('clear_anim_accepts_empty_table', 'clear_anim', {})

        expectValid('clear_anim_accepts_nil_payload', 'clear_anim', nil)

        expectValid('teleport_accepts_map_coordinates', 'teleport',
            { x = -1023.5, y = -2748.2, z = 12.9 }, function(normalized)
                assert(normalized.x == -1023.5 and normalized.y == -2748.2 and normalized.z == 12.9)
                assert(normalized.heading == nil)
            end)

        expectValid('teleport_accepts_heading', 'teleport',
            { x = 0, y = 0, z = 100, heading = 180 }, function(normalized)
                assert(normalized.heading == 180)
            end)

        expectValid('screen_effect_accepts_whitelisted_name', 'screen_effect',
            { name = 'DrugsMichaelAliensFight', duration_ms = 4000 })

        expectValid('open_text_ui_accepts_title_body_timeout', 'open_text_ui',
            { title = '任务提示', body = '去码头找老陈，别带枪。', timeout_ms = 8000 })

        expectValid('give_vehicle_keys_accepts_plate', 'give_vehicle_keys', { plate = 'ABC123' })

        -- cfg can tighten (never raise) the built-in text cap.
        expectValid('cfg_can_tighten_notify_cap', 'send_notify', { text = 'abc' },
            function(normalized) assert(normalized.text == 'abc') end)

        -- ------------------------------------------------------------------
        -- Rejected payloads
        -- ------------------------------------------------------------------
        expectInvalid('unknown_action_is_rejected', 'drop_database', { text = 'x' }, 'action_not_allowed')

        expectInvalid('unknown_field_is_rejected', 'send_notify',
            { text = 'hi', event = 'QBCore:Notify' }, 'invalid_params')

        expectInvalid('reserved_source_field_is_rejected', 'send_notify',
            { text = 'hi', source = 1 }, 'invalid_params')

        expectInvalid('notify_text_over_300_is_rejected', 'send_notify',
            { text = string.rep('a', 301), kind = 'info' }, 'text_too_long')

        expectInvalid('notify_empty_text_is_rejected', 'send_notify',
            { text = '', kind = 'info' }, 'invalid_params')

        expectInvalid('notify_invalid_kind_is_rejected', 'send_notify',
            { text = 'hi', kind = 'exploit' }, 'invalid_params')

        expectInvalid('notify_control_chars_are_rejected', 'send_notify',
            { text = 'hi\0there', kind = 'info' }, 'invalid_params')

        expectInvalid('payload_must_be_a_table', 'send_notify', 'not-a-table', 'invalid_params')

        expectInvalid('play_anim_unknown_dict_chars_are_rejected', 'play_anim',
            { dict = 'evil dict!', clip = 'idle_a', duration_ms = 2000 }, 'anim_not_whitelisted')

        expectInvalid('play_anim_duration_too_short_is_rejected', 'play_anim',
            { dict = 'amb@world_human_smoking@male@male_a@idle_a', clip = 'idle_a', duration_ms = 999 },
            'invalid_params')

        expectInvalid('play_anim_unknown_field_is_rejected', 'play_anim',
            { dict = 'amb@world_human_smoking@male@male_a@idle_a', clip = 'idle_a',
                duration_ms = 2000, flags = 49 }, 'invalid_params')

        expectInvalid('clear_anim_rejects_parameters', 'clear_anim', { dict = 'x' }, 'invalid_params')

        expectInvalid('teleport_out_of_bounds_is_rejected', 'teleport',
            { x = 99999, y = 0, z = 100 }, 'invalid_params')

        expectInvalid('teleport_nan_is_rejected', 'teleport',
            { x = 0 / 0, y = 0, z = 100 }, 'invalid_params')

        expectInvalid('teleport_heading_out_of_range_is_rejected', 'teleport',
            { x = 0, y = 0, z = 100, heading = 400 }, 'invalid_params')

        expectInvalid('screen_effect_unknown_name_is_rejected', 'screen_effect',
            { name = 'NotARealEffect', duration_ms = 1000 }, 'invalid_params')

        expectInvalid('screen_effect_duration_too_short_is_rejected', 'screen_effect',
            { name = 'Rampage', duration_ms = 100 }, 'invalid_params')

        expectInvalid('open_text_ui_title_too_long_is_rejected', 'open_text_ui',
            { title = string.rep('t', 81), body = 'b', timeout_ms = 2000 }, 'text_too_long')

        expectInvalid('open_text_ui_body_too_long_is_rejected', 'open_text_ui',
            { title = 't', body = string.rep('b', 1001), timeout_ms = 2000 }, 'text_too_long')

        expectInvalid('open_text_ui_timeout_too_large_is_rejected', 'open_text_ui',
            { title = 't', body = 'b', timeout_ms = 30001 }, 'invalid_params')

        expectInvalid('plate_must_be_uppercase_alnum', 'give_vehicle_keys',
            { plate = 'abc123' }, 'invalid_params')

        expectInvalid('plate_over_8_chars_is_rejected', 'give_vehicle_keys',
            { plate = 'ABCDEFGHI' }, 'invalid_params')

        expectInvalid('cfg_can_tighten_notify_cap_rejection', 'send_notify',
            { text = 'abcdef' }, 'text_too_long', { max_notify_chars = 5 })

        -- ------------------------------------------------------------------
        -- Redaction / helpers
        -- ------------------------------------------------------------------
        check('redact_notify_keeps_only_length', function()
            local redacted = Rules.Redact({ text = 'secret text', kind = 'primary' })
            assert(redacted.text == nil, 'notify text must be removed')
            assert(redacted.text_len == #'secret text', 'text_len must be the character count')
            assert(redacted.kind == 'primary', 'non-sensitive fields are kept')
        end)

        check('redact_open_text_ui_hides_body', function()
            local redacted = Rules.Redact({ title = 'tip', body = 'secret body', timeout_ms = 2000 })
            assert(redacted.body == nil, 'ui body must be removed')
            assert(redacted.body_len == #'secret body')
            assert(redacted.title == 'tip')
            assert(redacted.timeout_ms == 2000)
        end)

        check('redact_leaves_other_actions_intact', function()
            local redacted = Rules.Redact({ dict = 'd', clip = 'c', duration_ms = 1000 })
            assert(redacted.dict == 'd' and redacted.clip == 'c' and redacted.duration_ms == 1000)
        end)

        check('action_sites_are_declared', function()
            assert(Rules.ExecutionSite('send_notify') == 'client')
            assert(Rules.ExecutionSite('play_anim') == 'client')
            assert(Rules.ExecutionSite('give_vehicle_keys') == 'server')
            assert(Rules.ExecutionSite('nope') == nil)
        end)

        check('clamp_limit_bounds_values', function()
            assert(Rules.ClampLimit(5, 1, 10) == 5)
            assert(Rules.ClampLimit(0, 1, 10) == 1)
            assert(Rules.ClampLimit(11, 1, 10) == 10)
            assert(Rules.ClampLimit(nil, 2, 4) == 2)
        end)

        check('now_ms_uses_injected_clock', function()
            assert(Rules.NowMs(function() return 1234.9 end) == 1234)
            local wall = Rules.NowMs()
            assert(type(wall) == 'number' and wall > 0)
        end)

        return {
            ok = failed == 0,
            error = failed == 0 and nil or ('%d effect rule case(s) failed'):format(failed),
            data = {
                total = #results,
                passed = #results - failed,
                failed = failed,
                cases = results,
            },
        }
    end,
}
