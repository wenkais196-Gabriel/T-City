-- tests/agent/lua/cases/phone_sms.lua — pure SMS helpers from custom-phone.
--
-- The export itself needs QBCore/MySQL, so it cannot be loaded here; the
-- validation and label rules it relies on live in server/sms.lua and are
-- exactly what a mutation of "remove the sender check" would touch.

return {
    run = function(_ctx)
        local HERE = (debug.getinfo(1, 'S').source:sub(2))
        local root = HERE:match('^(.*)T%-CityLite%.base/tests/agent/lua/cases/')
        assert(root ~= nil, 'cannot locate the repository root from ' .. HERE)
        if root == '' then root = '.' end
        local Sms = dofile(root .. '/T-CityLite.base/resources/[custom]/custom-phone/server/sms.lua')
        assert(type(Sms) == 'table', 'sms.lua did not return the module')

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

        check('validate_accepts_boundary_values', function()
            local ok, err = Sms.Validate('123456789012345', string.rep('a', 500))
            assert(ok == true, tostring(err))
        end)

        check('validate_rejects_bad_receiver_and_message', function()
            for _, receiver in ipairs({ '', string.rep('1', 16) }) do
                local ok, err = Sms.Validate(receiver, 'hi')
                assert(ok == false and err == 'invalid_params', 'receiver ' .. #receiver)
            end
            for _, message in ipairs({ '', string.rep('a', 501) }) do
                local ok, err = Sms.Validate('123', message)
                assert(ok == false and err == 'invalid_params', 'message ' .. #message)
            end
            local ok = Sms.Validate(123, 'hi')
            assert(ok == false, 'non-string receiver must be rejected')
        end)

        check('sender_label_defaults_and_strips_controls', function()
            assert(Sms.SenderLabel(nil) == 'City Services')
            assert(Sms.SenderLabel(42) == 'City Services')
            assert(Sms.SenderLabel('') == 'City Services')
            assert(Sms.SenderLabel('City\0 Services') == 'City Services')
        end)

        check('sender_label_fits_the_varchar_column', function()
            local long = Sms.SenderLabel(string.rep('A', 40))
            assert(#long == 20, 'byte cap must be 20, got ' .. #long)
            local cjk = Sms.SenderLabel(string.rep('张', 10)) -- 30 bytes
            assert(#cjk <= 20, 'CJK label must respect the byte column')
            assert(utf8.len(cjk) ~= nil, 'label must stay valid UTF-8')
        end)

        check('truncate_chars_keeps_utf8_valid', function()
            local text = Sms.TruncateChars(string.rep('张', 250), 200)
            assert(utf8.len(text) == 200, 'char limit must count characters')
            assert(utf8.len(Sms.TruncateChars('abc', 10)) == 3)
        end)

        return {
            ok = failed == 0,
            data = { total = #results, failed = failed, cases = results },
        }
    end,
}
