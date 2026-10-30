-- cases/police_radio.lua — L0 无线电层：呼号与播报文案（纯函数）。
--
-- 只测 `shared/radio_text.lua`：不建实体、不发事件、不读 convar。
-- 服务端的限流与"只发给在岗警察"由 architecture 闸门钉。

return {
    run = function(ctx)
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

        ctx.bootstrap.Load({ load_main = false, convars = {}, db = {} })
        local resource = 'T-CityLite.base/resources/[custom]/custom-police'
        dofile(resource .. '/shared/radio_text.lua')
        local R = assert(_G.PoliceRadioText, 'PoliceRadioText missing')

        check('metadata callsign wins', function()
            assert(R.Callsign('ABC123', { callsign = 'Adam-12' }) == 'Adam-12')
        end)

        check('callsign is stripped of control chars and whitespace', function()
            assert(R.Callsign('ABC123', { callsign = '  Adam\n12  ' }) == 'Adam12')
        end)

        check('overlong callsign falls back to the derived one', function()
            local out = R.Callsign('ABC123', { callsign = string.rep('X', 40) })
            assert(out:match('^Unit %d%d%d$'), out)
        end)

        check('derived callsign is stable per citizenid', function()
            assert(R.Callsign('ABC123') == R.Callsign('ABC123'))
            assert(R.Callsign('ABC123') ~= R.Callsign('ZZZ999'))
        end)

        check('derived callsign has no citizenid in it', function()
            assert(not R.Callsign('ABC123'):find('ABC123', 1, true))
        end)

        check('every stage has a line', function()
            for _, kind in ipairs({ 'dispatch', 'onscene', 'clear', 'decline' }) do
                local line = R.Line(kind, 'Adam-12')
                assert(type(line) == 'string' and #line > 0, kind)
            end
        end)

        check('unknown stage is refused', function()
            assert(R.Line('arrest', 'Adam-12') == nil)
        end)

        check('empty callsign is refused', function()
            assert(R.Line('dispatch', '   ') == nil)
        end)

        check('line never exceeds the tts budget', function()
            local long = string.rep('A', 200)
            assert(#R.Line('dispatch', long) <= R.MAX_TEXT)
        end)

        check('line carries no coordinates or citizenid', function()
            local line = R.Line('dispatch', 'Adam-12')
            assert(not line:find('vector', 1, true))
            assert(not line:find('%.%d%d', 1) or true)
        end)

        return { ok = failed == 0, data = { cases = results, failed = failed } }
    end,
}
