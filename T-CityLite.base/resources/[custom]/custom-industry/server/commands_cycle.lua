-- server/commands_cycle.lua — S6/S7 控制台入口（默认注册、restricted、仅 source == 0）。
--
-- 玩家没有任何延长/缩短周期的手段（spec §5）；这两条命令只给运营与验收：
--
--   industry_setphase <expansion|competition|maturity|recession> [cycle_no]
--       强制换阶段并把边界重置为 now → now + duration；写审计。
--   industry_settle [dry|confirm] [cycle_no]
--       默认 dry：只打印将删/将写行数；confirm 才真删。写审计。
--
-- RegisterCommand 的 restricted=true 已能挡住玩家，但 S1/S4 的约定是**再判一次**
-- source == 0：权限配置被改坏时，第二道闸仍然有效。
--
-- 本文件不新增 net event，也不碰玩家钱：只有状态、审计与结算。

IndustryCycleCommands = {}

local function audit(action, payload)
    if IndustryAudit and IndustryAudit.Write then
        IndustryAudit.Write('*', nil, action, payload)
    end
end

--- 注意：返回**单个**字符串。`gsub` 返回 `string, count`，直接 `return` 会给
--- `format(...)` 多塞一个参数（当它是最后一个实参时会被展开），把 JSON 的字段挤错位。
local function safeText(value)
    local text = tostring(value or ''):gsub('[^%w_%-]', '_')
    return text
end

---@param source number
---@param phase string
---@param cycleNo number|nil
---@param now number|nil
---@return boolean ok, string|nil errcode, table|nil info
function IndustryCycleCommands.SetPhase(source, phase, cycleNo, now)
    if tonumber(source) ~= 0 then
        audit('cycle.setphase', ('{"result":"not_console","phase":"%s"}'):format(
            safeText(phase)))
        return false, 'not_console'
    end

    local ok, err, info = IndustryCycle.SetPhase(phase, cycleNo, now)
    audit('cycle.setphase', ('{"result":"%s","phase":"%s","cycle_no":%d}'):format(
        ok and 'ok' or safeText(err or 'db_error'),
        safeText(phase),
        math.floor(tonumber(info and info.cycle_no or cycleNo) or 0)))
    return ok, err, info
end

---@param source number
---@param mode string|nil 'dry'（默认）或 'confirm'
---@param cycleNo number|nil
---@return boolean ok, string|nil errcode, table|nil result
function IndustryCycleCommands.Settle(source, mode, cycleNo, now)
    if tonumber(source) ~= 0 then
        audit('cycle.settle', '{"result":"not_console"}')
        return false, 'not_console'
    end

    local wanted = tostring(mode or 'dry'):lower()
    if wanted ~= 'dry' and wanted ~= 'confirm' then
        audit('cycle.settle', ('{"result":"bad_mode","mode":"%s"}'):format(safeText(wanted)))
        return false, 'bad_mode'
    end

    local state, stateErr = IndustryCycle.Current()
    if not state then return false, stateErr or 'db_error' end
    local finalCycle = tonumber(cycleNo) or state.cycle_no
    finalCycle = math.floor(finalCycle)
    if finalCycle < 0 then return false, 'bad_cycle' end
    -- 只能结算当前周期：settled_cycle_no 只增不减，结算旧周期会把历史数据清掉。
    if finalCycle ~= state.cycle_no then return false, 'stale_cycle' end

    if wanted == 'dry' then
        -- dry-run 的契约是「只打印、不动库」：连审计也不写（Preview 本身只读）。
        -- 真结算的审计由 SettleCycle 在清分成功后写。
        local report, err = IndustrySettlement.Preview(finalCycle)
        if not report then return false, err end
        return true, nil, report
    end

    -- SettleCycle 内部已经写 cycle.settle 审计（含真实删除行数），这里不重复。
    return IndustrySettlement.SettleCycle(finalCycle, { trigger = 'command' })
end

function IndustryCycleCommands.Register()
    RegisterCommand('industry_setphase', function(source, args)
        local phase = tostring(args and args[1] or '')
        local cycleNo = tonumber(args and args[2])
        if phase == '' then
            print('[custom-industry] 用法: industry_setphase <phase> [cycle_no]')
            return
        end
        local ok, err, info = IndustryCycleCommands.SetPhase(source, phase, cycleNo, os.time())
        if not ok then
            print(('[custom-industry] industry_setphase failed: %s'):format(tostring(err)))
            return
        end
        print(('[custom-industry] industry_setphase cycle=%d phase=%s ends=%d'):format(
            info.cycle_no, info.phase, info.ends_epoch))
    end, true)

    RegisterCommand('industry_settle', function(source, args)
        local mode = tostring(args and args[1] or 'dry')
        local cycleNo = tonumber(args and args[2])
        local ok, err, result = IndustryCycleCommands.Settle(
            source, mode, cycleNo, os.time())
        if not ok then
            print(('[custom-industry] industry_settle failed: %s'):format(tostring(err)))
            return
        end
        if result and result.already_settled then
            print(('[custom-industry] industry_settle cycle=%d already settled'):format(
                result.cycle_no))
        end
    end, true)
end
