local QBCore = exports['qb-core']:GetCoreObject()

-- 辅助函数：输出调试日志
local function DebugPrint(msg)
    print(('[custom-admin][server] %s'):format(msg))
end

-- ==========================================
--            命 令 登 记 与 权 限 审 计
-- ==========================================

-- 1. 指派领袖指令 (/setleader [id] [role])
QBCore.Commands.Add('setleader', '指派玩家为特定领域的领袖 (Admin Only)', {
    { name = 'id', help = '玩家服务器 ID' },
    { name = 'role', help = '领袖角色 (sheriff/mayor/gangboss)' }
}, true, function(source, args)
    local callerName = (not source or source == 0 or source == "" or source == "console") and "Console" or GetPlayerName(source)
    local targetId = tonumber(args[1])
    local role = tostring(args[2]):lower()
    
    -- 参数完整性校验
    if not targetId or not role or (role ~= "sheriff" and role ~= "mayor" and role ~= "gangboss") then
        if source ~= 0 then
            TriggerClientEvent('QBCore:Notify', source, "参数错误。用法: /setleader [id] [sheriff/mayor/gangboss]", "error")
        else
            print("参数错误。用法: setleader [id] [sheriff/mayor/gangboss]")
        end
        return
    end

    local Player = QBCore.Functions.GetPlayer(targetId)
    if not Player then
        if source ~= 0 then
            TriggerClientEvent('QBCore:Notify', source, "该玩家未在线", "error")
        else
            print("该玩家未在线")
        end
        return
    end

    local targetCid = Player.PlayerData.citizenid
    local targetName = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname
    
    -- 1. 先清除目标玩家之前可能拥有的任何领袖角色，保障 unique 索引不冲突
    MySQL.Async.execute(
        "DELETE FROM leader_roles WHERE citizenid = ?",
        { targetCid },
        function()
            -- 2. 写入数据库 leader_roles (异步，保证性能)
            MySQL.Async.execute(
                "INSERT INTO leader_roles (role, citizenid, name) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE citizenid = ?, name = ?",
                { role, targetCid, targetName, targetCid, targetName },
                function(rowsChanged)
                    if rowsChanged and rowsChanged > 0 then
                -- 2. 调用 custom-career export 将玩家层级晋升为 leader
                local success = exports['custom-career']:SetPlayerTier(targetId, 'leader')
                if success then
                    -- 设置关联部门和地区（可选）
                    if role == "sheriff" then
                        exports['custom-career']:SetPlayerDepartment(targetId, "sheriff_office")
                    elseif role == "mayor" then
                        exports['custom-career']:SetPlayerDepartment(targetId, "city_hall")
                    end

                    -- 3. 联动向客户端触发事件，解锁手机领袖 APP (v0.4)
                    TriggerClientEvent('custom-phone:client:UnlockLeaderApp', targetId, role)
                    
                    -- 通知提示
                    TriggerClientEvent('QBCore:Notify', targetId, ("您已被指派为领袖岗位: %s"):format(role), "success")
                    if source ~= 0 then
                        TriggerClientEvent('QBCore:Notify', source, ("成功指派 %s 为领袖岗位: %s"):format(targetName, role), "success")
                    end
                    
                    -- 4. 发送 Discord #admin-log 审计记录
                    local text = ("**指派操作**: 领袖岗位指派\n**执行管理员**: %s\n**目标玩家**: %s (%s)\n**领袖角色**: %s\n**状态**: 晋升 Tier='leader' 且解锁领袖App成功"):format(
                        callerName, targetName, targetCid, role
                    )
                    exports['custom-logs']:LogGeneric("管理员指派领袖", text, 65280) -- 绿色
                else
                    if source ~= 0 then
                        TriggerClientEvent('QBCore:Notify', source, "职业层级晋升失败，请检查 custom-career 状态", "error")
                    end
                end
            end
        end
    )
end)
end, 'admin')

-- 2. 撤销领袖指令 (/demote [id])
QBCore.Commands.Add('demote', '撤销玩家的领袖职位并剥夺头衔 (Admin Only)', {
    { name = 'id', help = '玩家服务器 ID' }
}, true, function(source, args)
    local callerName = (not source or source == 0 or source == "" or source == "console") and "Console" or GetPlayerName(source)
    local targetId = tonumber(args[1])
    
    if not targetId then
        if source ~= 0 then
            TriggerClientEvent('QBCore:Notify', source, "参数错误。用法: /demote [id]", "error")
        else
            print("参数错误。用法: demote [id]")
        end
        return
    end

    local Player = QBCore.Functions.GetPlayer(targetId)
    if not Player then
        if source ~= 0 then
            TriggerClientEvent('QBCore:Notify', source, "该玩家未在线", "error")
        else
            print("该玩家未在线")
        end
        return
    end

    local targetCid = Player.PlayerData.citizenid
    local targetName = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname
    
    -- 1. 从 leader_roles 数据库中删除
    MySQL.Async.execute(
        "DELETE FROM leader_roles WHERE citizenid = ?",
        { targetCid },
        function(rowsChanged)
            -- 2. 调用 custom-career export 将层级降为 entry 基层
            local success = exports['custom-career']:SetPlayerTier(targetId, 'entry')
            if success then
                exports['custom-career']:SetPlayerDepartment(targetId, nil)
                
                -- 通知提示
                TriggerClientEvent('QBCore:Notify', targetId, "您的领袖职位已被剥夺，退回至基层岗位", "error")
                if source ~= 0 then
                    TriggerClientEvent('QBCore:Notify', source, ("成功剥夺 %s 的所有领袖头衔并降职"):format(targetName), "success")
                end
                
                -- 3. 发送 Discord 审计
                local text = ("**指派操作**: 领袖剥夺降职\n**执行管理员**: %s\n**目标玩家**: %s (%s)\n**状态**: 彻底移除领袖身份，重置 Tier='entry'"):format(
                    callerName, targetName, targetCid
                )
                exports['custom-logs']:LogGeneric("管理员剥夺领袖", text, 13631488) -- 红色
            else
                if source ~= 0 then
                    TriggerClientEvent('QBCore:Notify', source, "层级修改失败", "error")
                end
            end
        end
    )
end, 'admin')

-- 3. 修改职业层级 (/settier [id] [tier])
QBCore.Commands.Add('settier', '直接设置玩家职业阶层等级 (Admin Only)', {
    { name = 'id', help = '玩家服务器 ID' },
    { name = 'tier', help = '职业阶层 (leader/mid/entry)' }
}, true, function(source, args)
    local callerName = (not source or source == 0 or source == "" or source == "console") and "Console" or GetPlayerName(source)
    local targetId = tonumber(args[1])
    local tier = tostring(args[2]):lower()
    
    if not targetId or not tier or (tier ~= "leader" and tier ~= "mid" and tier ~= "entry") then
        if source ~= 0 then
            TriggerClientEvent('QBCore:Notify', source, "参数错误。用法: /settier [id] [leader/mid/entry]", "error")
        else
            print("参数错误。用法: settier [id] [leader/mid/entry]")
        end
        return
    end

    local Player = QBCore.Functions.GetPlayer(targetId)
    if not Player then
        if source ~= 0 then
            TriggerClientEvent('QBCore:Notify', source, "该玩家未在线", "error")
        else
            print("该玩家未在线")
        end
        return
    end

    local success = exports['custom-career']:SetPlayerTier(targetId, tier)
    if success then
        TriggerClientEvent('QBCore:Notify', targetId, ("您的职业层级已被变更为: %s"):format(tier), "success")
        if source ~= 0 then
            TriggerClientEvent('QBCore:Notify', source, ("成功修改 %s 的职业层级为 %s"):format(Player.PlayerData.name, tier), "success")
        end
        
        -- 审计
        local text = ("**指派操作**: 职业层级变动\n**执行管理员**: %s\n**目标玩家**: %s (%s)\n**新层级**: %s"):format(
            callerName, Player.PlayerData.name, Player.PlayerData.citizenid, tier
        )
        exports['custom-logs']:LogGeneric("管理员层级变更", text, 10079487)
    else
        if source ~= 0 then
            TriggerClientEvent('QBCore:Notify', source, "修改失败，请确保输入合法的层级", "error")
        end
    end
end, 'admin')

-- 4. 修改职业部门 (/setdept [id] [dept])
QBCore.Commands.Add('setdept', '设置玩家在当前职业下的独立部门 (Admin Only)', {
    { name = 'id', help = '玩家服务器 ID' },
    { name = 'dept', help = '独立部门标识' }
}, true, function(source, args)
    local callerName = (not source or source == 0 or source == "" or source == "console") and "Console" or GetPlayerName(source)
    local targetId = tonumber(args[1])
    local dept = tostring(args[2])
    
    if not targetId or not dept then
        if source ~= 0 then
            TriggerClientEvent('QBCore:Notify', source, "参数错误。用法: /setdept [id] [dept]", "error")
        else
            print("参数错误。用法: setdept [id] [dept]")
        end
        return
    end

    local Player = QBCore.Functions.GetPlayer(targetId)
    if not Player then
        if source ~= 0 then
            TriggerClientEvent('QBCore:Notify', source, "该玩家未在线", "error")
        else
            print("该玩家未在线")
        end
        return
    end

    local success = exports['custom-career']:SetPlayerDepartment(targetId, dept)
    if success then
        TriggerClientEvent('QBCore:Notify', targetId, ("您的职业部门已被变更为: %s"):format(dept), "success")
        if source ~= 0 then
            TriggerClientEvent('QBCore:Notify', source, ("成功修改 %s 的部门为 %s"):format(Player.PlayerData.name, dept), "success")
        end
        
        -- 审计
        local text = ("**指派操作**: 职业部门变动\n**执行管理员**: %s\n**目标玩家**: %s (%s)\n**新部门**: %s"):format(
            callerName, Player.PlayerData.name, Player.PlayerData.citizenid, dept
        )
        exports['custom-logs']:LogGeneric("管理员部门变更", text, 10079487)
    else
        if source ~= 0 then
            TriggerClientEvent('QBCore:Notify', source, "修改失败", "error")
        end
    end
end, 'admin')
