-- tests/unit/layer3_business/fixtures/daily_limit_probe.lua
-- 真加载 custom-quest 的 server/quest_daily_limit.lua，用 MySQL / os.date 桩跑判定。
--
-- 要守住的不变量：
--   1. 上限生效：没到上限放行，到了就拒；
--   2. 完成一次计数 +1，且**内存立刻生效**（不等 DB）；
--   3. 跨周期归零（period 变了就重新读库，不沿用昨天的计数）；
--   4. DB 不可用时放行（一次抖动不能把所有人的任务锁死），但一旦读到就照常拦；
--   5. daily_limit <= 0 / nil 等于不限（既有模板不能被新闸误伤）。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

-- ── 桩：内存版 MySQL ──
local DbRows = {}      -- 'cid|quest|type|period' → count
local DbDown = false
local Writes = 0

local function rowKey(cid, quest, kind, period)
    return table.concat({ cid, quest, kind, period }, '|')
end

MySQL = {
    scalar = {
        await = function(_, params)
            if DbDown then error('connect ETIMEDOUT') end
            local cid, quest, kind, period = params[1], params[2], params[3], params[4]
            return DbRows[rowKey(cid, quest, kind, period)] or 0
        end,
    },
    insert = {
        await = function(_, params)
            if DbDown then error('connect ETIMEDOUT') end
            local cid, quest, kind, period = params[1], params[2], params[3], params[4]
            local k = rowKey(cid, quest, kind, period)
            DbRows[k] = (DbRows[k] or 0) + 1
            Writes = Writes + 1
            return 1
        end,
    },
}

-- ── 桩：可控日期（跨天测试）──
local FakeDay = 0
local realDate = os.date
os.date = function(fmt, t)
    if fmt == '*' then
        local base = realDate('*t', t)
        return { year = 2026, month = 11, day = 1 + FakeDay, wday = base.wday, yday = base.yday }
    end
    if fmt == '%Y-%m-%d' then
        return ('2026-11-%02d'):format(1 + FakeDay)
    end
    return realDate(fmt, t)
end

-- 连 quest_db 一起真加载：SQL 住在那边（DB owner），探针要顺带验证它真的被调用
GetConvar = function(_, default) return default end
local dbHandle = assert(io.open(RES .. '/server/quest_db.lua', 'r'))
local dbSource = dbHandle:read('a'); dbHandle:close()
assert(load(dbSource, '@quest_db.lua'))()

local handle = assert(io.open(RES .. '/server/quest_daily_limit.lua', 'r'))
local source = handle:read('a'); handle:close()
assert(load(source, '@quest_daily_limit.lua'))()

-- ── 1. 上限判定 ──
local allowed0, count0 = QuestDailyLimit.Allowed('CID1', 'garbage_v1_city', 2)
emit('UNDER_LIMIT_ALLOWED', tostring(allowed0 == true and count0 == 0))

QuestDailyLimit.Increment('CID1', 'garbage_v1_city')
QuestDailyLimit.Increment('CID1', 'garbage_v1_city')

local allowedAtLimit, countAtLimit = QuestDailyLimit.Allowed('CID1', 'garbage_v1_city', 2)
emit('AT_LIMIT_BLOCKED', tostring(allowedAtLimit == false and countAtLimit == 2))

-- 内存即时生效：DB 里确实写了两行，但判定不依赖它
emit('DB_WRITES', tostring(Writes == 2 and DbRows[rowKey('CID1', 'garbage_v1_city', 'daily', '2026-11-01')] == 2))

-- ── 2. 别的任务 / 别的玩家不受影响 ──
local otherQuest = QuestDailyLimit.Allowed('CID1', 'bus_v1_city', 2)
emit('OTHER_QUEST_INDEPENDENT', tostring(otherQuest == true))
local otherPlayer = QuestDailyLimit.Allowed('CID2', 'garbage_v1_city', 2)
emit('OTHER_PLAYER_INDEPENDENT', tostring(otherPlayer == true))

-- ── 3. 跨周期归零（第二天重新计数）──
FakeDay = 1
local nextDay = QuestDailyLimit.Allowed('CID1', 'garbage_v1_city', 2)
emit('NEW_PERIOD_RESETS', tostring(nextDay == true))

-- ── 4. DB 挂了：放行；恢复后照常拦 ──
DbDown = true
local duringOutage = QuestDailyLimit.Allowed('CID3', 'hotdog_vendor', 1)
emit('DB_DOWN_FAILS_OPEN', tostring(duringOutage == true))
DbDown = false
DbRows[rowKey('CID3', 'hotdog_vendor', 'daily', '2026-11-02')] = 1
local afterRecovery = QuestDailyLimit.Allowed('CID3', 'hotdog_vendor', 1)
emit('DB_BACK_ENFORCES', tostring(afterRecovery == false))

-- ── 5. limit <= 0 / nil 等于不限 ──
local noLimit = QuestDailyLimit.Allowed('CID1', 'garbage_v1_city', 0)
local nilLimit = QuestDailyLimit.Allowed('CID1', 'garbage_v1_city', nil)
emit('ZERO_LIMIT_MEANS_UNLIMITED', tostring(noLimit == true and nilLimit == true))

-- ── 6. weekly 类型的周期是本周一 ──
FakeDay = 3   -- 2026-11-04
local weeklyPeriod = QuestDailyLimit.PeriodStart('weekly')
emit('WEEKLY_PERIOD_IS_MONDAY', tostring(type(weeklyPeriod) == 'string' and #weeklyPeriod == 10))

io.write(table.concat(OUT, '\n'), '\n')
