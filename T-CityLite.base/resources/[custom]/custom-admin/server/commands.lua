local QBCore = exports['qb-core']:GetCoreObject()

-- 辅助函数：输出调试日志
local function DebugPrint(msg)
    print(('[custom-admin][server] %s'):format(msg))
end

-- ==========================================
--            调 试 命 令 — 查 看 标 识 符
-- ==========================================
QBCore.Commands.Add('myid', '查看你当前的所有标识符', {}, false, function(source)
    local src = source
    if src == 0 or src == "console" then
        print("控制台没有标识符")
        return
    end
    local identifiers = GetPlayerIdentifiers(src)
    local msg = "你的标识符列表:\n"
    for _, id in ipairs(identifiers) do
        msg = msg .. "  " .. id .. "\n"
    end
    TriggerClientEvent('QBCore:Notify', src, "你的标识符已打印到聊天窗口", "success")
    TriggerClientEvent('chat:addMessage', src, {
        color = { 0, 255, 0 },
        multiline = true,
        args = { "🚀 你的标识符", msg }
    })
    -- 🔒 Security: 标识符脱敏 — 仅输出类型计数，不再打印完整 steam hex / license
    local idSummary = {}
    for _, v in ipairs(identifiers) do
        local prefix = v:match("^(%a+):") or "unknown"
        idSummary[prefix] = (idSummary[prefix] or 0) + 1
    end
    local summaryStr = ""
    for k, v in pairs(idSummary) do summaryStr = summaryStr .. k .. ":" .. v .. " " end
    print(("[custom-admin] Player %s identifiers: %s"):format(GetPlayerName(src), summaryStr))
end)

-- ==========================================
--            调 试 命 令 — 管 理 菜 单
-- ==========================================
QBCore.Commands.Add('amenu', '打开管理员菜单', {}, false, function(source)
    local src = source
    DebugPrint(("Player %s requested admin menu via /amenu"):format(GetPlayerName(src)))
    TriggerClientEvent('qb-admin:client:openMenu', src)
    TriggerClientEvent('chat:addMessage', src, {
        color = { 0, 255, 255 },
        multiline = true,
        args = {
            "🛠️ 管理员面板",
            [[
输入 /apanel 重新显示此面板
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 常用指令:
  /car [车型]      - 刷车
  /dv              - 删除载具
  /fix             - 修车
  /revive          - 复活自己
  /goto [ID]       - 传送到玩家
  /bring [ID]      - 拉取玩家
  /noclip          - 穿墙模式
  /coords          - 显示坐标
  /admincar        - 保存载具到车库
  /myid            - 查看标识符
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
]]
        }
    })
end)

-- ==========================================
--        调 试 命 令 — 抢 劫 警 察 门 槛
-- ==========================================
-- 用法:
--   /tccops 0    — 临时设为 0（随便抢）
--   /tccops 2    — 恢复为 2（生产标准）
--   /tccops      — 查看当前值
QBCore.Commands.Add('tccops', '调整抢劫警察门槛（调试）', { {
    name = 'value',
    help = '0-10，0=随便抢 2=生产标准'
} }, false, function(source, args)
    if not args[1] then
        local current = GlobalState and GlobalState.crime_min_police_storerobbery
            or GetConvar("crime_min_police_storerobbery", "2")
        QBCore.Functions.Notify(source, _L(source, 'admin_current_threshold', tostring(current)), "primary")
        return
    end

    if args[1]:lower() == 'reset' then
        GlobalState:set('crime_min_police_storerobbery', 2, true)
        QBCore.Functions.Notify(source, _L(source, 'admin_reset_to_2'), "success")
        return
    end

    local value = tonumber(args[1])
    if value == nil or value < 0 or value > 10 then
        QBCore.Functions.Notify(source, _L(source, 'admin_invalid_0_10'), "error")
        return
    end
    GlobalState:set('crime_min_police_storerobbery', value, true)
    QBCore.Functions.Notify(source, _L(source, 'admin_threshold_set', value), "primary")
end, 'user')

-- 在 QBCore 中注册管理员身份（确保 setrobbery 等 admin 命令可用）
CreateThread(function()
    Wait(3000)
    local players = QBCore.Functions.GetPlayers()
    for _, pid in ipairs(players) do
        local Player = QBCore.Functions.GetPlayer(pid)
        if Player and not QBCore.Functions.HasPermission(pid, 'admin') then
            QBCore.Functions.AddPermission(pid, 'admin')
            print(('[custom-admin] 🔑 Auto-granted admin to %s'):format(GetPlayerName(pid)))
        end
    end
end)

-- 新玩家上线自动授予 admin
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local src = Player.PlayerData.source
    if not QBCore.Functions.HasPermission(src, 'admin') then
        QBCore.Functions.AddPermission(src, 'admin')
    end
end)

-- ==========================================
--        调 试 命 令 — 清除通缉状态
-- ==========================================
QBCore.Commands.Add('clearme', '清除自己的通缉状态（管理员）', {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 1. 清除所有通缉相关元数据
    Player.Functions.SetMetaData('wanted', 0)
    Player.Functions.SetMetaData('ishandcuffed', false)
    local record = Player.PlayerData.metadata['criminalrecord'] or {}
    record.hasRecord = false
    record.date = nil
    Player.Functions.SetMetaData('criminalrecord', record)

    -- 2. 客户端：清除自定义通缉状态 + 恢复警星系统 + 清除警察雷达 blip
    TriggerClientEvent('custom-main:client:clearLocalWanted', src)
    for _, pid in ipairs(QBCore.Functions.GetPlayers()) do
        local cop = QBCore.Functions.GetPlayer(pid)
        if cop and cop.PlayerData.job.name == 'police' and cop.PlayerData.job.onduty then
            TriggerClientEvent('custom-main:client:clearSuspectBlip', pid, src)
        end
    end

    -- 3. 通知 custom-main 清除 WantedPlayers 缓存
    TriggerEvent('custom-main:server:adminClearWanted', Player.PlayerData.citizenid)

    TriggerClientEvent('QBCore:Notify', src, '通缉状态已完全清除（含元数据、雷达、犯罪记录）', 'success')
end, 'admin')

-- ==========================================
--        调 试 命 令 — 颁 发 执 照
-- ==========================================
-- 用法: /givemelicense pilot
--        /givemelicense driver
--        /givemelicense boat / weapon / heavy
QBCore.Commands.Add('givemelicense', '给自己颁发执照 (Admin)', { {
    name = 'type',
    help = 'driver / pilot / boat / heavy / weapon'
} }, false, function(source, args)
    local src = source
    local licenseType = args[1] and args[1]:lower()
    local validTypes = { driver = true, pilot = true, weapon = true, boat = true, heavy = true }

    if not validTypes[licenseType] then
        TriggerClientEvent('QBCore:Notify', src,
            '无效执照类型，可选: driver / pilot / boat / heavy / weapon', 'error')
        return
    end

    local success, msg = exports['custom-certificates']:GrantLicense(src, licenseType)
    if success then
        -- 🔧 强制客户端刷新证书缓存，消除 QBCore:Player:SetPlayerData 同步竞态
        TriggerClientEvent('custom-certificates:client:ForceRefreshCache', src)
        TriggerClientEvent('QBCore:Notify', src,
            ('✅ 已获得 %s 执照！'):format(licenseType), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src,
            msg or '授予失败', 'error')
    end
end, 'admin')

-- ==========================================
--        调 试 命 令 — 吊 销 执 照
-- ==========================================
-- 用法: /revokemelicense pilot
QBCore.Commands.Add('revokemelicense', '吊销自己的执照 (Admin)', { {
    name = 'type',
    help = 'driver / pilot / boat / heavy / weapon'
} }, false, function(source, args)
    local src = source
    local licenseType = args[1] and args[1]:lower()
    local validTypes = { driver = true, pilot = true, weapon = true, boat = true, heavy = true }

    if not validTypes[licenseType] then
        TriggerClientEvent('QBCore:Notify', src,
            '无效执照类型，可选: driver / pilot / boat / heavy / weapon', 'error')
        return
    end

    local success, msg = exports['custom-certificates']:RevokeLicense(src, licenseType)
    if success then
        TriggerClientEvent('custom-certificates:client:ForceRefreshCache', src)
        TriggerClientEvent('QBCore:Notify', src,
            ('🗑️ 已吊销 %s 执照！'):format(licenseType), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src,
            msg or '吊销失败', 'error')
    end
end, 'admin')

print('[custom-admin] ✅ 命令模块已加载 (myid + amenu + clearme + setrobbery + auto-admin)')
