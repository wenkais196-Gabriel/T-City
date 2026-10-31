-- cases/police_dispatch_view.lua — 警情对外投影（D5）的纯函数用例。
--
-- 真机的痛：广播精确坐标等于给开图的人一个比调度还准的位置。
-- 投影必须满足三条：位置稳定（同一张单不会跳）、距离够远（不能还是原地）、
-- 且客户端拿到的结构里没有任何"真实坐标"字段。

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
        dofile('T-CityLite.base/resources/[custom]/custom-police/shared/dispatch_view.lua')
        local V = assert(_G.PoliceDispatchView, 'PoliceDispatchView missing')

        local X, Y, Z = 1000.0, 2000.0, 30.0

        check('the same incident always projects to the same point', function()
            local a = V.Fuzz(42, X, Y, Z)
            local b = V.Fuzz(42, X, Y, Z)
            assert(a.x == b.x and a.y == b.y and a.z == b.z, 'projection must be deterministic')
        end)

        check('different incidents do not stack on the same spot', function()
            local a = V.Fuzz(42, X, Y, Z)
            local b = V.Fuzz(43, X, Y, Z)
            local dx, dy = a.x - b.x, a.y - b.y
            assert(math.sqrt(dx * dx + dy * dy) > 1.0, 'two incidents must not share a point')
        end)

        check('the projected point is 60-95% of the radius away', function()
            for id = 1, 50 do
                local p = V.Fuzz(id, X, Y, Z)
                local dx, dy = p.x - X, p.y - Y
                local dist = math.sqrt(dx * dx + dy * dy)
                assert(dist >= V.FUZZ_RADIUS * 0.59, ('id %d too close: %.1f'):format(id, dist))
                assert(dist <= V.FUZZ_RADIUS * 1.0, ('id %d too far: %.1f'):format(id, dist))
                assert(p.z == Z, '高度不动（否则地面会穿模）')
            end
        end)

        check('Public() carries no raw coordinate and keeps the fields the UI needs', function()
            local row = { id = 7, code = '10-31', title = '抢劫', priority = 1, status = 'open',
                          x = X, y = Y, z = Z, created_at = 123 }
            local pub = V.Public(row)
            assert(pub.id == 7 and pub.code == '10-31' and pub.priority == 1)
            assert(pub.status == 'open' and pub.title == '抢劫')
            assert(pub.x ~= X and pub.y ~= Y, 'public payload must not carry the raw point')
            assert(pub.description == nil and pub.disposition == nil, '不应外泄内部字段')
        end)

        check('Public() tolerates a malformed row', function()
            assert(V.Public(nil) == nil)
        end)

        return { ok = failed == 0, data = { cases = results, failed = failed } }
    end,
}
