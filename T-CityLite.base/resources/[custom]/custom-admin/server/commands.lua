local QBCore = exports['qb-core']:GetCoreObject()

--- 管理员操作审计（A-3）。
--- 现状：custom-logs 有金额流水，但**没有操作者、没有旧值** —— "谁改了谁的钱"查不到；
--- custom-admin 全文 0 处审计调用。这里给每条特权动作补上：
---   操作者(名字+id) / 动作 / 目标 / 明细 / 时间
--- 三件事一起做：
---   1) 落 custom-logs（本地文件 + Discord）；
---   2) 执行者拿 feed 回执（含目标与明细，可截图留证）；
---   3) 审计写失败只 print，不影响业务（审计不能成为可用性单点）。
--- 权限层级（A-5）：不能对同级或更高级动手。
local RANK_LEVELS = { user = 0, mod = 1, admin = 2, god = 3 }
local function rankOf(src)
    local best = -1
    for level, weight in pairs(RANK_LEVELS) do
        if QBCore.Functions.HasPermission(src, level) then
            if weight > best then best = weight end
        end
    end
    return best
end

---@return boolean allowed, string|nil reason
local function canActOn(src, targetId)
    if src == targetId then return true end
    local mine, theirs = rankOf(src), rankOf(targetId)
    if mine < 0 then return false, '你没有管理权限' end
    if theirs >= mine then
        return false, ('对方权限不低于你（你 %s / 对方 %s）'):format(
            tostring(mine), tostring(theirs))
    end
    return true, nil
end

--- 二次确认（A-4）：第一次只输出摘要，10 秒内用同样的参数再执行一次才生效。
--- 为什么不做成通知：通知是事后单向，不能阻止误操作，也不构成"同意"。
local CONFIRM_WINDOW_MS = 10000
local pendingConfirm = {}
local function confirmStep(src, action, key, summary)
    local now = GetGameTimer()
    local slot = ('%s|%s|%s'):format(tostring(src), action, tostring(key))
    local entry = pendingConfirm[slot]
    if entry and now - entry.at <= CONFIRM_WINDOW_MS then
        pendingConfirm[slot] = nil
        return true
    end
    pendingConfirm[slot] = { at = now }
    -- 顺手清掉过期项，避免长跑积累
    for other, info in pairs(pendingConfirm) do
        if now - info.at > CONFIRM_WINDOW_MS then pendingConfirm[other] = nil end
    end
    pcall(function()
        exports['custom-notify']:Push(src, 'toast', '确认操作',
            ('%s · 10 秒内再执行一次以确认'):format(summary))
    end)
    return false
end

-- /tccops 用的 _L 从来没有定义过（custom-admin 也没加载 locale 文件），
-- 所以这条命令任何输入都会在 Lua 里 "attempt to call a nil value (_L)"。
-- 只有 4 个键，直接给中文，不留一个"看起来有 i18n"的空壳。
local THRESHOLD_TEXT = {
    current = '当前抢劫警察门槛：%s',
    reset   = '已恢复为 2（生产标准）',
    invalid = '只能填 0-10 的整数',
    set     = '门槛已设为 %s',
}
local function _L(_, key, arg)
    local template = THRESHOLD_TEXT[key]
    if not template then return tostring(key) end
    if arg == nil then return template end
    return (template:gsub('%%s', tostring(arg)))
end

--- 谁可以使用执照工具（合并后的唯一入口）：
---   admin/god —— 管理侧；
---   值班 LEO 且职级 ≥ 阈值 —— 执法侧（原 custom-police 的口径，阈值默认 2）。
--- 阈值用 convar 覆盖：setr license_rank 3
local LICENSE_RANK_FALLBACK = 2
local function licenseRankThreshold()
    return tonumber(GetConvar('license_rank', tostring(LICENSE_RANK_FALLBACK))) or LICENSE_RANK_FALLBACK
end

---@return boolean allowed, string|nil reason
local function canUseLicenseTool(src)
    if QBCore.Functions.HasPermission(src, 'admin') or QBCore.Functions.HasPermission(src, 'god') then
        return true, nil
    end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false, '玩家数据未加载' end
    local job = Player.PlayerData.job or {}
    if job.type ~= 'leo' then return false, '只有值班警察或管理员可以使用执照命令' end
    if not job.onduty then return false, '需要先上岗' end
    local grade = (job.grade and job.grade.level) or 0
    local threshold = licenseRankThreshold()
    if grade < threshold then
        return false, ('职级不足（需要 %d 级，你是 %d 级）'):format(threshold, grade)
    end
    return true, nil
end

local function auditAdmin(src, action, targetLabel, detail, kind)
    local executor = GetPlayerName(src) or ('#%s'):format(tostring(src))
    local line = ('%s | 操作者 %s(#%s) | 目标 %s | %s'):format(
        action, executor, tostring(src), tostring(targetLabel or '-'), tostring(detail or '-'))
    local ok, err = pcall(function()
        exports['custom-logs']:LogGeneric('管理员操作', line, 16744192)
    end)
    if not ok then print(('[custom-admin] ⚠️ 审计写入失败: %s'):format(tostring(err))) end
    pcall(function()
        exports['custom-notify']:Push(src, kind == 'error' and 'error' or 'feed', '管理员操作',
            ('%s · %s'):format(action, tostring(targetLabel or '')), { icon = '🛠' })
    end)
    return line
end


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
📚 完整清单（339 条，按权限分组，自动生成）：
   docs/client/ux/admin-commands.md
   改代码后重跑：python3 tools/dev/scan_commands.py
]]
        }
    })
end, 'admin')

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
        local previous = GlobalState and GlobalState.crime_min_police_storerobbery
        GlobalState:set('crime_min_police_storerobbery', 2, true)
        auditAdmin(source, '重置抢劫警察门槛', '全局', ('%s → 2'):format(tostring(previous)))
        QBCore.Functions.Notify(source, _L(source, 'admin_reset_to_2'), "success")
        return
    end

    local value = tonumber(args[1])
    if value == nil or value < 0 or value > 10 then
        QBCore.Functions.Notify(source, _L(source, 'admin_invalid_0_10'), "error")
        return
    end
    local previous = GlobalState and GlobalState.crime_min_police_storerobbery
    GlobalState:set('crime_min_police_storerobbery', value, true)
    auditAdmin(source, '调整抢劫警察门槛', '全局',
        ('%s → %s'):format(tostring(previous), tostring(value)))
    QBCore.Functions.Notify(source, _L(source, 'admin_threshold_set', value), "primary")
end, 'admin')
-- 🔒 A-2：这里原本是 'user' —— **任何玩家**都能把抢劫警察门槛改成 0，
--    等于关掉整条犯罪链的门禁。改门槛是玩法调参，必须是 admin。

-- 在 QBCore 中注册管理员身份（确保 setrobbery 等 admin 命令可用）
-- 🔒 默认关闭: 全量自动 admin 会让每个玩家获得管理命令与面板权限。
--    仅在本地开发/沙盒中通过 server.cfg 里 `set admin_autogrant "true"` 显式开启。
local AUTO_GRANT_ADMIN = GetConvar('admin_autogrant', 'false') == 'true'

if AUTO_GRANT_ADMIN then
    print('[custom-admin] ⚠️  admin_autogrant=true — 所有玩家都将被授予 admin 权限，仅限开发环境使用')

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
end

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

-- ==========================================
--        管 理 命 令 — 他人执 照 管 理
-- ==========================================
-- 用法: /givelicense [玩家ID] [类型]
--       /revokelicense [玩家ID] [类型]
--       /reinstatelicense [玩家ID] [类型]
--       /suspendlicense [玩家ID] [类型]
--       /checklicense [玩家ID]
local AdminLicenseTypes = { driver = true, pilot = true, boat = true, heavy = true, weapon = true }

QBCore.Commands.Add('givelicense', '授予玩家执照 (Admin)', {
    { name = 'id', help = '玩家 ID' },
    { name = 'type', help = 'driver / pilot / boat / heavy / weapon' }
}, false, function(source, args)
    do
        local allowed, reason = canUseLicenseTool(source)
        if not allowed then
            TriggerClientEvent('QBCore:Notify', source, reason, 'error')
            return
        end
    end
    local src = source
    local targetId = tonumber(args[1])
    local licenseType = args[2] and args[2]:lower()
    if not targetId or not AdminLicenseTypes[licenseType] then
        TriggerClientEvent('QBCore:Notify', src, '用法: /givelicense [ID] [driver|pilot|boat|heavy|weapon]', 'error')
        return
    end
    local target = QBCore.Functions.GetPlayer(targetId)
    if not target then
        TriggerClientEvent('QBCore:Notify', src, '玩家不在线', 'error')
        return
    end
    local allowed, reason = canActOn(src, targetId)
    if not allowed then
        TriggerClientEvent('QBCore:Notify', src, reason, 'error')
        return
    end
    if not confirmStep(src, '授予执照', ('%s:%s'):format(targetId, licenseType),
        ('授予 %s 的 %s 执照'):format(GetPlayerName(targetId), tostring(licenseType))) then
        return
    end
    local success, msg = exports['custom-certificates']:GrantLicense(targetId, licenseType)
    if success then
        auditAdmin(src, '授予执照', GetPlayerName(targetId), ('+%s'):format(tostring(licenseType)))
        TriggerClientEvent('custom-certificates:client:ForceRefreshCache', targetId)
        TriggerClientEvent('QBCore:Notify', src, ('✅ 已授予 %s %s 执照'):format(GetPlayerName(targetId), licenseType), 'success')
        TriggerClientEvent('QBCore:Notify', targetId, ('管理员授予了你 %s 执照'):format(licenseType), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src, msg or '授予失败', 'error')
    end
end, 'user')

QBCore.Commands.Add('revokelicense', '吊销玩家执照 (Admin)', {
    { name = 'id', help = '玩家 ID' },
    { name = 'type', help = 'driver / pilot / boat / heavy / weapon' }
}, false, function(source, args)
    do
        local allowed, reason = canUseLicenseTool(source)
        if not allowed then
            TriggerClientEvent('QBCore:Notify', source, reason, 'error')
            return
        end
    end
    local src = source
    local targetId = tonumber(args[1])
    local licenseType = args[2] and args[2]:lower()
    if not targetId or not AdminLicenseTypes[licenseType] then
        TriggerClientEvent('QBCore:Notify', src, '用法: /revokelicense [ID] [driver|pilot|boat|heavy|weapon]', 'error')
        return
    end
    local target = QBCore.Functions.GetPlayer(targetId)
    if not target then
        TriggerClientEvent('QBCore:Notify', src, '玩家不在线', 'error')
        return
    end
    local allowed, reason = canActOn(src, targetId)
    if not allowed then
        TriggerClientEvent('QBCore:Notify', src, reason, 'error')
        return
    end
    if not confirmStep(src, '吊销执照', ('%s:%s'):format(targetId, licenseType),
        ('吊销 %s 的 %s 执照'):format(GetPlayerName(targetId), tostring(licenseType))) then
        return
    end
    local success, msg = exports['custom-certificates']:RevokeLicense(targetId, licenseType)
    if success then
        auditAdmin(src, '吊销执照', GetPlayerName(targetId), ('-%s'):format(tostring(licenseType)))
        TriggerClientEvent('custom-certificates:client:ForceRefreshCache', targetId)
        TriggerClientEvent('QBCore:Notify', src, ('🗑️ 已吊销 %s 的 %s 执照'):format(GetPlayerName(targetId), licenseType), 'success')
        TriggerClientEvent('QBCore:Notify', targetId, ('你的 %s 执照已被吊销'):format(licenseType), 'error')
    else
        TriggerClientEvent('QBCore:Notify', src, msg or '吊销失败', 'error')
    end
end, 'user')

QBCore.Commands.Add('reinstatelicense', '恢复玩家执照 (Admin)', {
    { name = 'id', help = '玩家 ID' },
    { name = 'type', help = 'driver / pilot / boat / heavy / weapon' }
}, false, function(source, args)
    do
        local allowed, reason = canUseLicenseTool(source)
        if not allowed then
            TriggerClientEvent('QBCore:Notify', source, reason, 'error')
            return
        end
    end
    local src = source
    local targetId = tonumber(args[1])
    local licenseType = args[2] and args[2]:lower()
    if not targetId or not AdminLicenseTypes[licenseType] then
        TriggerClientEvent('QBCore:Notify', src, '用法: /reinstatelicense [ID] [driver|pilot|boat|heavy|weapon]', 'error')
        return
    end
    local target = QBCore.Functions.GetPlayer(targetId)
    if not target then
        TriggerClientEvent('QBCore:Notify', src, '玩家不在线', 'error')
        return
    end
    local allowed, reason = canActOn(src, targetId)
    if not allowed then
        TriggerClientEvent('QBCore:Notify', src, reason, 'error')
        return
    end
    if not confirmStep(src, '恢复执照', ('%s:%s'):format(targetId, licenseType),
        ('恢复 %s 的 %s 执照'):format(GetPlayerName(targetId), tostring(licenseType))) then
        return
    end
    local success, msg = exports['custom-certificates']:ReinstateLicense(targetId, licenseType)
    if success then
        auditAdmin(src, '恢复执照', GetPlayerName(targetId), ('~%s'):format(tostring(licenseType)))
        TriggerClientEvent('custom-certificates:client:ForceRefreshCache', targetId)
        TriggerClientEvent('QBCore:Notify', src, ('🔄 已恢复 %s 的 %s 执照'):format(GetPlayerName(targetId), licenseType), 'success')
        TriggerClientEvent('QBCore:Notify', targetId, ('你的 %s 执照已恢复'):format(licenseType), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src, msg or '恢复失败', 'error')
    end
end, 'user')

QBCore.Commands.Add('suspendlicense', '暂停玩家执照 (Admin)', {
    { name = 'id', help = '玩家 ID' },
    { name = 'type', help = 'driver / pilot / boat / heavy / weapon' }
}, false, function(source, args)
    do
        local allowed, reason = canUseLicenseTool(source)
        if not allowed then
            TriggerClientEvent('QBCore:Notify', source, reason, 'error')
            return
        end
    end
    local src = source
    local targetId = tonumber(args[1])
    local licenseType = args[2] and args[2]:lower()
    if not targetId or not AdminLicenseTypes[licenseType] then
        TriggerClientEvent('QBCore:Notify', src, '用法: /suspendlicense [ID] [driver|pilot|boat|heavy|weapon]', 'error')
        return
    end
    local target = QBCore.Functions.GetPlayer(targetId)
    if not target then
        TriggerClientEvent('QBCore:Notify', src, '玩家不在线', 'error')
        return
    end
    local allowed, reason = canActOn(src, targetId)
    if not allowed then
        TriggerClientEvent('QBCore:Notify', src, reason, 'error')
        return
    end
    if not confirmStep(src, '暂停执照', ('%s:%s'):format(targetId, licenseType),
        ('暂停 %s 的 %s 执照'):format(GetPlayerName(targetId), tostring(licenseType))) then
        return
    end
    local success, msg = exports['custom-certificates']:SuspendLicense(targetId, licenseType)
    if success then
        auditAdmin(src, '暂停执照', GetPlayerName(targetId), ('!%s'):format(tostring(licenseType)))
        TriggerClientEvent('custom-certificates:client:ForceRefreshCache', targetId)
        TriggerClientEvent('QBCore:Notify', src, ('⏸️ 已暂停 %s 的 %s 执照'):format(GetPlayerName(targetId), licenseType), 'success')
        TriggerClientEvent('QBCore:Notify', targetId, ('你的 %s 执照已被暂停'):format(licenseType), 'error')
    else
        TriggerClientEvent('QBCore:Notify', src, msg or '暂停失败', 'error')
    end
end, 'user')

QBCore.Commands.Add('checklicense', '查看玩家执照状态 (Admin)', {
    { name = 'id', help = '玩家 ID' }
}, false, function(source, args)
    local src = source
    local targetId = tonumber(args[1]) or source
    local target = QBCore.Functions.GetPlayer(targetId)
    if not target then
        TriggerClientEvent('QBCore:Notify', src, '玩家不在线', 'error')
        return
    end
    local licences = target.PlayerData.metadata['licences'] or {}
    local certStatus = target.PlayerData.metadata['cert_status'] or {}

    local msg = ('📋 %s 的执照状态:\\n'):format(GetPlayerName(targetId))
    local types = { 'driver', 'pilot', 'boat', 'heavy', 'weapon' }
    for _, t in ipairs(types) do
        local status = certStatus[t] or 'unclaimed'
        local has = licences[t] and '✅' or '❌'
        local statusIcon = ({ unclaimed = '⚪', held = '🟢', suspended = '🟡', revoked = '🔴' })[status] or '⚪'
        local label = ({ driver = '普通驾照', pilot = '飞行执照', boat = '船证', heavy = '重型驾照', weapon = '武器执照' })[t]
        msg = msg .. ('  %s%s %s: %s %s\\n'):format(has, statusIcon, label, t, status)
    end

    TriggerClientEvent('chat:addMessage', src, {
        color = { 0, 255, 255 },
        multiline = true,
        args = { '📋 执照检查', msg }
    })
    TriggerClientEvent('QBCore:Notify', src, '执照状态已打印到聊天窗口', 'success')
end, 'admin')

print('[custom-admin] ✅ 命令模块已加载 (myid + amenu + clearme + setrobbery + auto-admin + license管理)')

-- A-2：面板命令搬到服务端（admin 权限）。文本从原客户端搬过来，内容不变。
local PANEL_BODY = [[
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
  /amenu            → 简版面板
  /apanel           → 重新显示此面板
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
]]

local MENU_BODY = [[
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

QBCore.Commands.Add('apanel', '管理员完整面板', {}, false, function(source)
    TriggerClientEvent('custom-admin:client:printPanel', source, '🛠️ 管理员面板 v2', PANEL_BODY)
end, 'admin')

QBCore.Commands.Add('menu', '快速菜单', {}, false, function(source)
    TriggerClientEvent('custom-admin:client:printPanel', source, '⚡ 快速菜单', MENU_BODY)
end, 'admin')
