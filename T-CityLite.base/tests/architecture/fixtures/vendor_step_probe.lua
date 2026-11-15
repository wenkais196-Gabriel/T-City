-- vendor_step_probe.lua — 把任务模板当真 Lua 表加载，报告每个 vendor 步骤的 data 键。
--
-- 为什么用真加载而不是正则：模板里有 local 变量、循环生成的步骤（quest_bus /
-- quest_garbage），正则切块会漏；loadfile 跑的是服务端将要加载的同一份表。
--
-- 用法: lua5.4 vendor_step_probe.lua <template.lua> [<template.lua> ...]
-- 输出: VENDOR|<path>|<quest id>|<step id>|<逗号分隔的 data 键>
-- 任一模板加载失败 → LOADERR/RUNERR 行 + exit 1（闸门不能因为看不见就变绿）。
--
-- quest_hotdog.lua 由 convar `quest_hotdog_dev` 控制，默认返回空表；
-- 这里桩成 1，否则热狗模板会被静默跳过，闸门等于没扫到任何东西。

GetConvar = function(name, default)
    if name == 'quest_hotdog_dev' then return '1' end
    return default
end

-- config/quests/lego/bank_escort.lua 在表构造里直接调用 vector3()。
-- 服务端有 FiveM 原生；离线探针给个同形状的桩即可（只用于读 step/node 形状）。
vector3 = function(x, y, z) return { x = x, y = y, z = z } end

local failures = 0

for _, path in ipairs(arg) do
    local chunk, err = loadfile(path)
    if not chunk then
        print('LOADERR|' .. path .. '|' .. tostring(err))
        failures = failures + 1
    else
        local ok, templates = pcall(chunk)
        if not ok then
            print('RUNERR|' .. path .. '|' .. tostring(templates))
            failures = failures + 1
        elseif type(templates) ~= 'table' then
            print('NOTTABLE|' .. path .. '|' .. type(templates))
            failures = failures + 1
        else
            -- 与 quest_registry.lua 的 NormalizeLoaded 同口径：
            -- 有的文件返回单个模板（有 id），有的返回模板数组。
            local list = {}
            if templates.id then
                list = { templates }
            else
                for _, candidate in ipairs(templates) do
                    if type(candidate) == 'table' and candidate.id then
                        list[#list + 1] = candidate
                    end
                end
            end
            for _, template in ipairs(list) do
                for _, step in ipairs(template.steps or {}) do
                    if step.type == 'vendor' then
                        -- ExecuteNode 的入参是 `nextStep.data or nextStep.payload`：
                        -- 两个来源都要看，否则换个字段名就能绕过闸门。
                        local keys, seen = {}, {}
                        for _, source in ipairs({ step.data or {}, step.payload or {} }) do
                            for key in pairs(source) do
                                if not seen[key] then
                                    seen[key] = true
                                    keys[#keys + 1] = tostring(key)
                                end
                            end
                        end
                        table.sort(keys)
                        print(table.concat({
                            'VENDOR',
                            path,
                            tostring(template.id),
                            tostring(step.id),
                            table.concat(keys, ','),
                        }, '|'))
                    end
                end
            end
        end
    end
end

if failures > 0 then
    os.exit(1)
end
