-- ==========================================
--  custom-admin 客户端调试菜单修复
--  绕过 qb-adminmenu 可能存在的冲突
-- ==========================================

local QBCore = exports['qb-core']:GetCoreObject()

-- 监听服务器发来的打开菜单指令
RegisterNetEvent('custom-admin:client:OpenAdminMenu', function()
    -- 直接触发 qb-adminmenu 的打开事件
    TriggerEvent('qb-admin:client:openMenu')
end)

-- 也直接监听 qb-adminmenu 的菜单事件
-- 如果 qb-adminmenu 自己发的事件不工作，这里做备用
RegisterNetEvent('custom-admin:client:ForceOpenMenu', function()
    -- 尝试直接打开 MenuV 菜单（如果菜单变量存在）
    if menu1 then
        MenuV:OpenMenu(menu1)
    else
        -- 如果菜单未初始化，通过 qb-adminmenu 来触发
        TriggerEvent('qb-admin:client:openMenu')
    end
end)

-- 清除通缉状态（管理员命令 /clearme）
RegisterNetEvent('custom-admin:client:clearWanted', function()
    local player = PlayerId()
    SetPlayerWantedLevel(player, 0, false)
    SetMaxWantedLevel(0)
    -- 清除小地图上的警星闪烁
    ClearPlayerWantedLevel(player)
end)

-- ⚠️ 生产环境静默加载，避免 F8 泄露模块信息
if GetConvar('debug_client', 'false') == 'true' then
    print('[custom-admin][client] 调试菜单修复模块已加载')
end
