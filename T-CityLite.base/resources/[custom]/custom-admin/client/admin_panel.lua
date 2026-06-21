-- ==========================================
--  custom-admin 纯聊天框管理面板
--  不依赖 MenuV / NUI，用原生 chat 实现
-- ==========================================

local QBCore = exports['qb-core']:GetCoreObject()

-- 显示完整管理面板
RegisterCommand('apanel', function()
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        multiline = true,
        args = {
            "🛠️ 管理员面板 v2",
            [[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🚗 载具:
  /car [车型]       → 刷车
  /dv               → 删除当前载具
  /fix              → 修车
  /admincar         → 保存到车库
  /maxmods          → 满改

👤 玩家管理:
  /revive [ID]      → 复活
  /goto [ID]        → 传送到
  /bring [ID]       → 拉过来
  /kick [ID] [理由]  → 踢出
  /freeze [ID]      → 冻结
  /spectate [ID]    → 观察

🔧 开发者:
  /noclip           → 穿墙
  /coords           → 显示坐标
  /setmodel [模型]   → 换模型
  /setspeed [fast]  → 加速跑
  /vector3          → 复制坐标

🔰 系统:
  /givemelicense [driver/pilot/boat/heavy/weapon] → 给自己发执照
  /setleader [ID] [sheriff/mayor/gangboss]  → 指派领袖
  /demote [ID]      → 撤销领袖
  /settier [ID] [leader/mid/entry]  → 改层级
  /announce [消息]   → 全服公告
  /myid             → 查看标识符
  /apanel           → 重新显示此面板
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
]]
        }
    })
end, false)

-- 也注册 /menu 作为快捷入口
RegisterCommand('menu', function()
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        multiline = true,
        args = {
            "⚡ 快速菜单",
            [[
━━━━━━━━━━━━━━━━━━━━
/apanel   → 完整管理面板
/car      → 刷车
/dv       → 删车
/revive   → 复活
/goto     → 传送
/noclip   → 穿墙
/coords   → 坐标
/myid     → 标识符
━━━━━━━━━━━━━━━━━━━━
]]
        }
    })
end, false)

AddEventHandler('onClientResourceStart', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        TriggerEvent('chat:addSuggestion', '/apanel', '📋 打开管理员完整面板')
        TriggerEvent('chat:addSuggestion', '/menu', '⚡ 快速菜单')
    end
end)

-- custom-admin startup print removed (production mode)
