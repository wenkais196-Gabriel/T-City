-- 客户端可以传 indent，必须有硬上限，否则深层嵌套表会把 tPrint 递归到栈溢出
local MAX_DEBUG_INDENT = 8

local function tPrint(tbl, indent)
    indent = indent or 0
    if indent >= MAX_DEBUG_INDENT then
        -- 递归深度硬上限：只截断展示，不改变调用方拿到的数据
        print(('%s^3… (depth capped at %d)^0'):format(string.rep('  ', indent), MAX_DEBUG_INDENT))
        return
    end
    if type(tbl) == 'table' then
        for k, v in pairs(tbl) do
            local tblType = type(v)
            local formatting = ('%s ^3%s:^0'):format(string.rep('  ', indent), k)

            if tblType == 'table' then
                print(formatting)
                tPrint(v, indent + 1)
            elseif tblType == 'boolean' then
                print(('%s^1 %s ^0'):format(formatting, v))
            elseif tblType == 'function' then
                print(('%s^9 %s ^0'):format(formatting, v))
            elseif tblType == 'number' then
                print(('%s^5 %s ^0'):format(formatting, v))
            elseif tblType == 'string' then
                print(("%s ^2'%s' ^0"):format(formatting, v))
            else
                print(('%s^2 %s ^0'):format(formatting, v))
            end
        end
    else
        print(('%s ^0%s'):format(string.rep('  ', indent), tbl))
    end
end

RegisterServerEvent('QBCore:DebugSomething', function(tbl, indent, resource)
    -- 之前这里是裸的：任何客户端都能让服务端打印任意表（日志刷屏 + 深表放大内存）。
    -- 服务端自己调用 QBCore.Debug 时 GetInvokingResource() 有值，放行；
    -- 其余来源要求 ACE qb.debug（见 server.cfg.template 的 add_ace 示例）。
    local invoking = GetInvokingResource()
    if invoking == nil and source and source ~= 0 then
        if not IsPlayerAceAllowed(source, 'qb.debug') then return end
    end

    local depth = tonumber(indent) or 0
    if depth ~= depth or depth == math.huge or depth == -math.huge then depth = 0 end
    depth = math.max(0, math.min(depth, MAX_DEBUG_INDENT))
    print(('\x1b[4m\x1b[36m[ %s : DEBUG]\x1b[0m'):format(resource))
    tPrint(tbl, depth)
    print('\x1b[4m\x1b[36m[ END DEBUG ]\x1b[0m')
end)

function QBCore.Debug(tbl, indent)
    TriggerEvent('QBCore:DebugSomething', tbl, indent, GetInvokingResource() or 'qb-core')
end

function QBCore.ShowError(resource, msg)
    print('\x1b[31m[' .. resource .. ':ERROR]\x1b[0m ' .. msg)
end

function QBCore.ShowSuccess(resource, msg)
    print('\x1b[32m[' .. resource .. ':LOG]\x1b[0m ' .. msg)
end
