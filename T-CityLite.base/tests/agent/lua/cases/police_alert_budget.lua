-- cases/police_alert_budget.lua — 警情通知预算层（P2-2）的纯函数用例。
--
-- 全部用假时钟：窗口边界（90 s 合并 / 5 s 突发）是最容易写错的地方，
-- 而真机上要等 90 秒才能验证一次。

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
        -- 限流原语是 core-framework 的 owner（RATE-01），这里原样加载它。
        dofile('T-CityLite.base/resources/[standalone]/core-framework/server/rate_limit.lua')
        RateLimit.Reset('')
        dofile('T-CityLite.base/resources/[custom]/custom-police/shared/alert_budget.lua')
        local B = assert(_G.PoliceAlertBudget, 'PoliceAlertBudget missing')

        local CID = 'CID-ALERT'
        local T0 = 1000000

        check('first alert of a code is sent', function()
            B.Reset()
            local action, count = B.Decide(CID, '10-31', 1, T0)
            assert(action == 'sent', action)
            assert(count == 1, tostring(count))
        end)

        check('same code within 90s is merged, not re-sent', function()
            B.Reset()
            assert(B.Decide(CID, '10-31', 1, T0) == 'sent')
            local action, count = B.Decide(CID, '10-31', 1, T0 + 1000)
            assert(action == 'merged', action)
            assert(count == 2, tostring(count))
        end)

        check('merges stay quiet until the 5th, then announce again', function()
            B.Reset()
            B.Decide(CID, '10-31', 1, T0)
            local seen = {}
            for i = 2, 6 do
                local action, count = B.Decide(CID, '10-31', 1, T0 + i * 1000)
                seen[count] = action
            end
            assert(seen[3] == 'suppressed', '3rd must be silent, got ' .. tostring(seen[3]))
            assert(seen[4] == 'suppressed', '4th must be silent, got ' .. tostring(seen[4]))
            assert(seen[5] == 'merged', '5th must announce, got ' .. tostring(seen[5]))
            assert(seen[6] == 'suppressed', '6th must be silent, got ' .. tostring(seen[6]))
        end)

        check('after the merge window the code speaks again', function()
            B.Reset()
            B.Decide(CID, '10-31', 1, T0)
            local action = B.Decide(CID, '10-31', 1, T0 + B.MERGE_WINDOW_MS + 1)
            assert(action == 'sent', action)
        end)

        check('non urgent alerts are capped at 3 per 5s', function()
            B.Reset()
            assert(B.Decide(CID, '10-20', 3, T0) == 'sent')
            assert(B.Decide(CID, '10-21', 3, T0 + 100) == 'sent')
            assert(B.Decide(CID, '10-22', 3, T0 + 200) == 'sent')
            local action = B.Decide(CID, '10-23', 3, T0 + 300)
            assert(action == 'throttled', action)
        end)

        check('urgent alerts pierce the rate cap', function()
            B.Reset()
            for i = 1, 3 do
                assert(B.Decide(CID, '10-2' .. i, 3, T0 + i) == 'sent')
            end
            local action = B.Decide(CID, '10-99', 1, T0 + 400)
            assert(action == 'sent', 'priority 1 must bypass the cap, got ' .. tostring(action))
        end)

        check('budget is per officer, not global', function()
            B.Reset()
            for i = 1, 3 do B.Decide('CID-A', '10-3' .. i, 3, T0 + i) end
            assert(B.Decide('CID-A', '10-39', 3, T0 + 500) == 'throttled')
            assert(B.Decide('CID-B', '10-39', 3, T0 + 500) == 'sent')
        end)

        check('decorate only shows the count when it is above one', function()
            assert(B.Decorate('#12 10-31: 抢劫', 1) == '#12 10-31: 抢劫')
            assert(B.Decorate('#12 10-31: 抢劫', 4) == '#12 10-31: 抢劫（×4）')
        end)

        return { ok = failed == 0, data = { cases = results, failed = failed } }
    end,
}
