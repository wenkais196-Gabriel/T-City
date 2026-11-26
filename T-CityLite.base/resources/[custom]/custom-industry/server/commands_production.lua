-- server/commands_production.lua — S3 后台入口（默认关、仅控制台）。
--
-- 真机验收卡在「需要在线玩家」（S1/S2 的教训）。这个入口把验收从键盘前解放出来，
-- 但它**不是**第二条生产路径：调的仍是 IndustryProduction.SettleFacility，
-- 也就是 tick 与玩家上线用的同一个函数。
--
-- 门控：
--   * convar `industry_production_debug` 默认 false —— 关时命令根本不注册；
--   * RegisterCommand 的 restricted=true + 回调里 source ~= 0 直接返回 —— 只认控制台。
--   * 不接受任何时间/产量参数：now 永远由服务端 os.time() 决定。

IndustryProductionCommands = {}

local function formatResult(orgId, result)
    return ('%s: produced=%d stock=%s last_tick_at=%s blocked=%s'):format(
        orgId,
        tonumber(result.produced) or 0,
        tostring(result.stock),
        tostring(result.last_tick_at),
        tostring(result.blocked or 'none'))
end

function IndustryProductionCommands.Register()
    local production = Config.Industry.Production or {}
    if not production.DebugCommand then return end

    RegisterCommand('orgproduce', function(source, args)
        if source ~= 0 then return end -- 只允许控制台/RCON

        local orgId = tostring(args and args[1] or '')
        if orgId == '' then
            print('[custom-industry] 用法: orgproduce <orgId>')
            return
        end

        local ok, err, result = IndustryProduction.SettleFacility(orgId, { trigger = 'console' })
        if not ok then
            print(('[custom-industry] orgproduce %s failed: %s'):format(orgId, tostring(err)))
            return
        end
        print('[custom-industry] orgproduce ' .. formatResult(orgId, result))
    end, true)
end
