-- hotdog_inbound_probe.lua — G 片两条纯函数探针（真跑源码，不复制实现）
--
-- 用法：
--   lua5.4.exe hotdog_inbound_probe.lua client <quest_hotdog_vendor_client.lua>
--   lua5.4.exe hotdog_inbound_probe.lua server <quest_vendor.lua>
--
-- client: 从 `-- [quest-hotdog-inbound]` 标记块抽 PickSpawnPoint，检查
--   距离始终在 [25, 40]、越界参数被夹紧而不是崩、z 与摊位一致。
-- server: 从 `-- [quest-vendor-offer-lifetime]` 标记块抽 offerLifetimeMs，检查
--   生命周期 == inbound_budget_ms + patience_ms；并确认 CreateOffer 真的用了它。
-- 输出：每行 `<name> OK|FAIL <detail>`，末尾 `SUMMARY n/n`；全过退出码 0。

local mode, source = arg[1], arg[2]
assert(mode == 'client' or mode == 'server', '期望 client|server，收到 ' .. tostring(mode))
assert(source, '缺少源码路径')

local file = assert(io.open(source, 'r'))
local text = file:read('a')
file:close()

local function extract(name)
    local pattern = '%-%- %[' .. name .. '%] begin\n(.-)\n%-%- %[' .. name .. '%] end'
    local body = text:match(pattern)
    if not body then error('找不到标记块: ' .. name) end
    return body
end

local results = {}
local function check(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok and true or false, detail = detail or '' }
end

local function distanceTo(booth, point)
    local dx, dy = point.x - booth.x, point.y - booth.y
    return math.sqrt(dx * dx + dy * dy)
end

if mode == 'client' then
    local body = extract('quest%-hotdog%-inbound')
    local chunk = assert(load(body .. '\n_G.__probePickSpawnPoint = PickSpawnPoint\n', 'inbound'))
    chunk()
    local Pick = _G.__probePickSpawnPoint

    local BOOTH = { x = 100.0, y = -200.0, z = 30.5 }
    local minSeen, maxSeen = math.huge, -math.huge
    local zOk = true
    for angle = 0, 360, 15 do
        for _, wanted in ipairs({ 25, 40 }) do
            local point = Pick(BOOTH, angle, wanted)
            local distance = distanceTo(BOOTH, point)
            minSeen = math.min(minSeen, distance)
            maxSeen = math.max(maxSeen, distance)
            if math.abs(distance - wanted) > 1e-6 then
                check(('distance_angle_%d_d%d'):format(angle, wanted), false,
                    ('期望 %.3f，实际 %.3f'):format(wanted, distance))
            end
            if point.z ~= BOOTH.z then zOk = false end
        end
    end
    check('distance_sweep_25_40', maxSeen <= 40 + 1e-6 and minSeen >= 25 - 1e-6,
        ('min=%.3f max=%.3f'):format(minSeen, maxSeen))
    check('z_follows_booth', zOk, tostring(BOOTH.z))

    local low = Pick(BOOTH, 90, 5)
    local lowDistance = distanceTo(BOOTH, low)
    check('clamps_below_range', math.abs(lowDistance - 25) <= 1e-6,
        ('5 → %.3f'):format(lowDistance))

    local high = Pick(BOOTH, 90, 100)
    local highDistance = distanceTo(BOOTH, high)
    check('clamps_above_range', math.abs(highDistance - 40) <= 1e-6,
        ('100 → %.3f'):format(highDistance))

    local fallback = Pick(BOOTH, 0, nil)
    local fallbackDistance = distanceTo(BOOTH, fallback)
    check('nil_distance_falls_back_to_min', math.abs(fallbackDistance - 25) <= 1e-6,
        ('nil → %.3f'):format(fallbackDistance))
else
    local body = extract('quest%-vendor%-offer%-lifetime')
    local chunk = assert(load(body .. '\n_G.__probeOfferLifetimeMs = offerLifetimeMs\n',
        'offer-lifetime'))
    chunk()
    local Lifetime = _G.__probeOfferLifetimeMs

    local cases = {
        { inbound_budget_ms = 45000, patience_ms = 30000, want = 75000 },
        { inbound_budget_ms = 25000, patience_ms = 20000, want = 45000 },
        { inbound_budget_ms = 60000, patience_ms = 45000, want = 105000 },
    }
    for index, case in ipairs(cases) do
        local got = Lifetime(case)
        check(('lifetime_case_%d'):format(index), got == case.want,
            ('inbound=%d patience=%d got=%d want=%d'):format(
                case.inbound_budget_ms, case.patience_ms, got, case.want))
    end

    -- 接线：CreateOffer 必须用这个算式，而不是只加 patience。
    local wiring = text:find('expiresAt = now + offerLifetimeMs(session.cfg)', 1, true) ~= nil
    check('create_offer_uses_lifetime', wiring,
        wiring and 'expiresAt = now + offerLifetimeMs(session.cfg)' or '没找到生命周期接线')
end

local failures = 0
for _, row in ipairs(results) do
    if not row.ok then failures = failures + 1 end
    print(('%-32s %s  %s'):format(row.name, row.ok and 'OK' or 'FAIL', row.detail))
end
print(('SUMMARY %d/%d'):format(#results - failures, #results))
os.exit(failures == 0 and 0 or 1)
