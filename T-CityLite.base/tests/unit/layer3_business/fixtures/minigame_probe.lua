-- minigame_probe.lua — 真跑 quest_minigame.lua 的 nonce 生命周期
--
-- 用 `-- [quest-minigame] begin/end` 从源码里抽出**真实实现**（不复制一份），
-- 只依赖 Lua 5.4 标准库。时间全部注入，不 sleep、不依赖真实时钟。
--
-- 覆盖：
--   1. 0 / 1 / ≥2 失误 → exotic / rare / common
--   2. quit = true 不产出，且 nonce 被消费（第二次 already_used）
--   3. unknown / wrong_owner / already_used / expired 四个错误码
--   4. 非法 faults（字符串 / 负数 / 超上限）→ bad_faults，且失败也消费
--   5. 同一节点重复 Start → already_open
--   6. Cancel 清会话、幂等
--   7. Sweep 只清过期会话并返回条数
--
-- 用法:
--   lua5.4 tests/unit/layer3_business/fixtures/minigame_probe.lua \
--       "resources/[custom]/custom-quest/server/quest_minigame.lua"

local SOURCE = arg[1]
if not SOURCE then
    error('用法: lua5.4 minigame_probe.lua <quest_minigame.lua>')
end

local file = assert(io.open(SOURCE, 'r'))
local text = file:read('a')
file:close()

local function extract(name)
    -- 标记必须独占一行：源码别的注释里可能提到「标记块」这几个字，
    -- 不按行首锚定会从注释里的 begin 一直抽到文件末尾，load 直接语法错误。
    local pattern = '\r?\n%-%- %[' .. name .. '%] begin\r?\n(.-)\r?\n%-%- %[' .. name .. '%] end'
    local body = ('\n' .. text):match(pattern)
    if not body then
        error('找不到标记块: ' .. name)
    end
    return body
end

local chunk = assert(load(extract('quest%-minigame'), 'quest-minigame'))
chunk()

local NOW = 1000000

local function config(now, ttl)
    return {
        ttl_sec = ttl or 30,
        tiers = {
            { max_faults = 0, tier = 'exotic', item = 'hotdog_exotic' },
            { max_faults = 1, tier = 'rare', item = 'hotdog_rare' },
            { max_faults = 99, tier = 'common', item = 'hotdog_common' },
        },
        count = 1,
        now = now or NOW,
    }
end

local function setNow(value)
    QuestMinigame._now = value
end

local results = {}
local function check(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok and true or false, detail = detail or '' }
end

-- 1. 三档映射：0 失误异域、1 稀有、≥2 普通，9 仍在默认上限 10 内
setNow(NOW)
local tierOk = true
local tierSeen = {}
local tierCases = {
    { faults = 0, tier = 'exotic', item = 'hotdog_exotic' },
    { faults = 1, tier = 'rare', item = 'hotdog_rare' },
    { faults = 2, tier = 'common', item = 'hotdog_common' },
    { faults = 9, tier = 'common', item = 'hotdog_common' },
}
for i, case in ipairs(tierCases) do
    local nonce = QuestMinigame.Start('cid-tier', 'quest-1', 'tier-node-' .. i, config(NOW))
    local ok, res = QuestMinigame.Resolve('cid-tier', nonce, { quit = false, faults = case.faults })
    tierSeen[#tierSeen + 1] = tostring(case.faults) .. '->' .. tostring(ok and res and res.tier or 'nil')
    if not (ok and res
        and res.tier == case.tier and res.item == case.item
        and res.count == 1 and res.faults == case.faults) then
        tierOk = false
    end
end
check('tier_mapping_0_1_2', tierOk, table.concat(tierSeen, ', '))

-- 2. quit 不产出，且 nonce 立即作废（第二次 already_used）
local nonceQuit = QuestMinigame.Start('cid-quit', 'quest-1', 'quit-node', config(NOW))
local okQuit, quitResult = QuestMinigame.Resolve('cid-quit', nonceQuit, { quit = true })
local okReplay, replayErr = QuestMinigame.Resolve('cid-quit', nonceQuit, { quit = false, faults = 0 })
local quitOk = okQuit == true and type(quitResult) == 'table'
    and quitResult.quit == true
    and quitResult.tier == nil and quitResult.item == nil and quitResult.count == nil
    and okReplay == nil and replayErr == 'already_used'
check('quit_consumes_nonce', quitOk,
    ('quit=%s, replay=%s'):format(tostring(okQuit), tostring(replayErr)))

-- 3. 四个错误码：unknown / wrong_owner / already_used / expired
setNow(NOW)
local okUnknown, errUnknown = QuestMinigame.Resolve('cid-any', 'nope-nonce', { faults = 0 })

local nonceOwner = QuestMinigame.Start('cid-owner', 'quest-1', 'owner-node', config(NOW))
local okThief, errThief = QuestMinigame.Resolve('cid-thief', nonceOwner, { faults = 0 })
-- 归属不匹配**不消费**：原主紧接着还能正常结算（别人烧不掉你的 nonce）
local okOwner, ownerResult = QuestMinigame.Resolve('cid-owner', nonceOwner, { faults = 0 })
local okUsed, errUsed = QuestMinigame.Resolve('cid-owner', nonceOwner, { faults = 0 })

local nonceExpired = QuestMinigame.Start('cid-exp', 'quest-1', 'expired-node', config(NOW, 30))
setNow(NOW + 31)
local okExpired, errExpired = QuestMinigame.Resolve('cid-exp', nonceExpired, { faults = 0 })
-- 过期也算消费：重放不能再拿到第二次 expired
local okExpired2, errExpired2 = QuestMinigame.Resolve('cid-exp', nonceExpired, { faults = 0 })
setNow(NOW)

local codesOk = okUnknown == nil and errUnknown == 'unknown_nonce'
    and okThief == nil and errThief == 'wrong_owner'
    and okOwner == true and ownerResult ~= nil and ownerResult.tier == 'exotic'
    and okUsed == nil and errUsed == 'already_used'
    and okExpired == nil and errExpired == 'expired'
    and okExpired2 == nil and errExpired2 == 'already_used'
check('error_codes_unknown_wrong_used_expired', codesOk,
    ('%s / %s / %s / %s / %s'):format(
        tostring(errUnknown), tostring(errThief), tostring(errUsed),
        tostring(errExpired), tostring(errExpired2)))

-- 4. 非法 faults 三种形状；非法上报也必须消费 nonce
setNow(NOW)
local badCases = {
    { value = '3', label = 'string' },
    { value = -1, label = 'negative' },
    { value = 99, label = 'over_cap' },
}
local badOk = true
local badSeen = {}
for i, case in ipairs(badCases) do
    local nonce = QuestMinigame.Start('cid-bad', 'quest-1', 'bad-node-' .. i, config(NOW))
    local ok, err = QuestMinigame.Resolve('cid-bad', nonce, { quit = false, faults = case.value })
    local okReplay, replayErr = QuestMinigame.Resolve('cid-bad', nonce, { quit = false, faults = 0 })
    badSeen[#badSeen + 1] = case.label .. '=' .. tostring(err)
    if not (ok == nil and err == 'bad_faults'
        and okReplay == nil and replayErr == 'already_used') then
        badOk = false
    end
end
check('bad_faults_rejected', badOk, table.concat(badSeen, ', '))

-- 5. 同一节点重复 Start → already_open；结算后 / 过期后可以重开
setNow(NOW)
local nonceDup = QuestMinigame.Start('cid-dup', 'quest-1', 'dup-node', config(NOW))
local dupNonce, dupErr = QuestMinigame.Start('cid-dup', 'quest-1', 'dup-node', config(NOW))
local siblingNonce = QuestMinigame.Start('cid-dup', 'quest-1', 'sibling-node', config(NOW))
QuestMinigame.Resolve('cid-dup', nonceDup, { quit = true })
local reopened = QuestMinigame.Start('cid-dup', 'quest-1', 'dup-node', config(NOW))
-- 过期但还没 Sweep 的旧会话不能把节点永久锁死
local staleNonce = QuestMinigame.Start('cid-stale', 'quest-1', 'stale-node', config(NOW, 5))
setNow(NOW + 6)
local freshNonce = QuestMinigame.Start('cid-stale', 'quest-1', 'stale-node', config(NOW + 6, 30))
setNow(NOW)
check('duplicate_start_is_already_open',
    dupNonce == nil and dupErr == 'already_open'
        and siblingNonce ~= nil and reopened ~= nil
        and staleNonce ~= nil and freshNonce ~= nil,
    ('dup=%s, sibling=%s, reopened=%s, fresh=%s'):format(
        tostring(dupErr), tostring(siblingNonce ~= nil),
        tostring(reopened ~= nil), tostring(freshNonce ~= nil)))

-- 6. Cancel 清会话；第二次调用不报错（幂等）
setNow(NOW)
local nonceCancel = QuestMinigame.Start('cid-cancel', 'quest-1', 'cancel-node', config(NOW))
local removedFirst = QuestMinigame.Cancel('cid-cancel', 'quest-1', 'cancel-node')
local secondOk, removedSecond = pcall(QuestMinigame.Cancel, 'cid-cancel', 'quest-1', 'cancel-node')
local okCanceled, errCanceled = QuestMinigame.Resolve('cid-cancel', nonceCancel, { quit = true })
check('cancel_is_idempotent',
    removedFirst == true and secondOk and removedSecond == false
        and okCanceled == nil and errCanceled == 'unknown_nonce',
    ('first=%s, second=%s/%s, resolve=%s'):format(
        tostring(removedFirst), tostring(secondOk),
        tostring(removedSecond), tostring(errCanceled)))

-- 7. Sweep 只清过期会话并返回条数；未过期的那条仍能结算
setNow(NOW)
local sweepShort = QuestMinigame.Start('cid-sweep', 'quest-1', 'sweep-1', config(NOW, 10))
local sweepMedium = QuestMinigame.Start('cid-sweep', 'quest-1', 'sweep-2', config(NOW, 20))
local sweepLong = QuestMinigame.Start('cid-sweep', 'quest-1', 'sweep-3', config(NOW, 60))
setNow(NOW + 25)
local removedSweep = QuestMinigame.Sweep(NOW + 25)
local removedAgain = QuestMinigame.Sweep(NOW + 25)
local okAlive, aliveResult = QuestMinigame.Resolve('cid-sweep', sweepLong, { faults = 1 })
local okSwept, sweptErr = QuestMinigame.Resolve('cid-sweep', sweepShort, { faults = 0 })
setNow(NOW)
check('sweep_expired_sessions',
    removedSweep == 2 and removedAgain == 0
        and okAlive == true and aliveResult ~= nil and aliveResult.tier == 'rare'
        and okSwept == nil and sweptErr == 'unknown_nonce',
    ('removed=%s, again=%s, alive=%s, swept=%s'):format(
        tostring(removedSweep), tostring(removedAgain),
        tostring(okAlive), tostring(sweptErr)))

local failures = 0
for _, r in ipairs(results) do
    if not r.ok then failures = failures + 1 end
    print(('%-40s %s  %s'):format(r.name, r.ok and 'OK' or 'FAIL', r.detail))
end
print(('SUMMARY %d/%d'):format(#results - failures, #results))
os.exit(failures == 0 and 0 or 1)
