-- tests/unit/layer3_business/fixtures/bus_dirtyflush_probe.lua
-- 真加载 core-framework/bus.lua，验证 DirtyFlushStats 的两条路径：
--   * DirtyFlush 全局未定义（管线未接入）→ available=false（而不是一个永远为 0 的 dirty_count）
--   * DirtyFlush 已实现 → 原样透出，并补 available=true
-- 背景：custom-testing 的压测原来靠 dirty_count==0 判"池是空的"，而它其实是"管线没接"。

local RES = arg[1] or error('need resource dir')

local OUT = {}
local exports_table = {}

exports = function(name, fn) exports_table[name] = fn end
RegisterNetEvent = function() end
AddEventHandler = function() end
CreateThread = function(fn) return fn end
Wait = function() end
GetCurrentResourceName = function() return 'core-framework' end
print = function() end

local handle = assert(io.open(RES .. '/bus.lua', 'r'))
local source = handle:read('a')
handle:close()
assert(load(source, '@bus.lua'))()

local stats = assert(exports_table.DirtyFlushStats, 'DirtyFlushStats 没注册成 export')

-- 1) 管线未接入
_G.DirtyFlush = nil
local absent = stats()
OUT[#OUT + 1] = 'ABSENT_AVAILABLE|' .. tostring(absent.available == false)
OUT[#OUT + 1] = 'ABSENT_COUNT|' .. tostring(absent.dirty_count == 0)

-- 2) 管线已接入
_G.DirtyFlush = {
    Stats = function() return { dirty_count = 7, flushed = 3 } end,
    MarkDirty = function() end,
    FlushAll = function() end,
}
local present = stats()
OUT[#OUT + 1] = 'PRESENT_AVAILABLE|' .. tostring(present.available == true)
OUT[#OUT + 1] = 'PRESENT_COUNT|' .. tostring(present.dirty_count == 7)
OUT[#OUT + 1] = 'PRESENT_FIELDS_KEPT|' .. tostring(present.flushed == 3)

-- 3) Stats() 返回 nil 时也不该炸
_G.DirtyFlush = { Stats = function() return nil end }
local broken = stats()
OUT[#OUT + 1] = 'NIL_STATS_AVAILABLE|' .. tostring(broken.available == false)

io.write(table.concat(OUT, '\n'), '\n')
