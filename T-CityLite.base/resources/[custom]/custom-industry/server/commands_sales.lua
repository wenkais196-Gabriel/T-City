-- server/commands_sales.lua — S4 后台入口（默认关、仅控制台）。
--
-- 真机验收卡在「需要在线玩家」（S1/S2/S3 的教训）。这个入口不是第二条销售路径：
-- 调的仍是 IndustrySales.SettleSale。玩家侧授权沿用 IndustryAccess.IsOrgBoss
-- （留给 S5 的菜单/回调，不在本片另写一套）；本命令只接受控制台。
--
-- 门控：
--   * convar `industry_sales_debug` 默认 false —— 关时命令根本不注册；
--   * RegisterCommand 的 restricted=true + 回调 source ~= 0 直接返回 —— 只认控制台。
--   * 只读 <orgId> <item> <qty> [ref]；价格/倍率/配额剩余一律不接受。

IndustrySalesCommands = {}

function IndustrySalesCommands.Register()
    local sales = Config.Industry.Sales or {}
    if not sales.DebugCommand then return end

    RegisterCommand('orgsell', function(source, args)
        if source ~= 0 then return end -- 只允许控制台/RCON

        local orgId = tostring(args and args[1] or '')
        local item = tostring(args and args[2] or '')
        local qty = tonumber(args and args[3])
        local ref = args and args[4]

        if orgId == '' or item == '' or not qty then
            print('[custom-industry] 用法: orgsell <orgId> <item> <qty> [ref]')
            return
        end

        local ok, err, result = IndustrySales.SettleSale(orgId, item, qty, ref)
        if not ok then
            print(('[custom-industry] orgsell %s %s x%s failed: %s'):format(
                orgId, item, tostring(qty), tostring(err)))
            return
        end

        print(('[custom-industry] orgsell %s %s qty=%d revenue=%s quota_used=%s ref=%s'):format(
            orgId, tostring(result.item), result.qty, tostring(result.revenue),
            tostring(result.quota_used), tostring(result.ref)))
    end, true)
end
