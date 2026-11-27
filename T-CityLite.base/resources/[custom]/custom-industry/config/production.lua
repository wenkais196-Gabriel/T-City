-- config/production.lua — S3 惰性生产参数（纯数据 + convar）。
--
-- 惰性结算：dt = now - last_tick_at；tick 只是「多久去看一眼」，
-- 不是「每秒生产一次」。停机期间的时间由 last_tick_at 一次性补算，
-- 单次最多补 max_catchup 秒（不跳段，超出部分留给下一次 tick）。
--
-- 离线通胀闸是**库存上限**（设施配置里的 stockCap），不是 max_catchup：
-- 库存满了就冻结，产出只进 industry_facility.stock，不进金库/银行。
--
-- 真机验收可以这样把时间压短：
--   set industry_tick_seconds 1
--   set industry_units_per_hour 3600   -- 1 单位/秒/工位，一两分钟就能看到库存冻结
--   set industry_max_catchup 60        -- 单次最多补 60 秒

local function numberConvar(name, default, minimum)
    local value = tonumber(GetConvar(name, tostring(default)))
    if not value or value ~= value then value = default end -- NaN 兜底
    if value < minimum then value = minimum end
    return value
end

Config.Industry.Production = {
    -- 单工位每小时产出多少单位（#387 数值卡：4.5）。
    -- 满建 10 工位 = 45 单位/小时，必须 ≥ 衰退期 50% 配额所需的 43.65 单位/小时
    -- （2,200 件 / (72 小时 × 0.70)）；否则满建也吃不掉自己那一半配额。
    -- 1 工位一个周期产 ≈ 3,196 单位（阶段倍率加权），单周期收入 ≈ $157,540。
    UnitsPerHour = numberConvar('industry_units_per_hour', 4.5, 0),

    -- 周期/阶段产能倍率。S6 之前恒为 1；先留成显式参数，结算函数是纯的。
    Multiplier = numberConvar('industry_production_multiplier', 1, 0),

    -- 结算心跳间隔（秒）。默认 30 秒；验收时压到 1 秒。
    TickSeconds = numberConvar('industry_tick_seconds', 30, 1),

    -- 单次结算最多追赶多少秒。停机再久，一次也只算这么多。
    MaxCatchupSeconds = numberConvar('industry_max_catchup', 3600, 1),

    -- 后台入口（`orgproduce`，restricted 原生命令，仅控制台）默认关闭。
    -- 真机验收卡在「需要在线玩家」；打开它仍然是调同一个 SettleFacility。
    DebugCommand = GetConvar('industry_production_debug', 'false') == 'true',
}
