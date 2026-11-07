local QBCore = exports['qb-core']:GetCoreObject()

local LogQueue = {}

-- 高性能合并：批量清空写入
--
-- ⚠️ 2026-11-07 真机发现：原来这里用相对路径 `logs/`，而 FXServer 的进程 cwd **不是**
-- 数据目录（server.cfg 所在地），所以 `io.open("logs/…", "a")` 恒失败
-- （`No such file or directory`）；降级分支写的 `logs_fallback/…` 目录也不存在，
-- SaveResourceFile 同样失败 —— 结果是**所有审计静默丢弃**（连原有 LogEconomy/LogSecurity
-- 调用点也一样）。所以改成：
--   1) 绝对路径：`GetResourcePath()` 拿资源目录，写到 `<resource>/logs/`（目录不存在则跳过）；
--   2) 再降级到资源根目录（无子目录，SaveResourceFile 一定能建文件）。
local resourceName = GetCurrentResourceName()
-- ⚠️ GetResourcePath 返回**不带结尾斜杠**的目录（真机实测 `.../custom-logs`），
-- 直接拼文件名会得到 `...custom-logseconomy_audit-….log` —— 之前落盘/清理都栽在这。
local resourcePath = GetResourcePath(resourceName) or ''
if resourcePath ~= '' and resourcePath:sub(-1) ~= '/' then
    resourcePath = resourcePath .. '/'
end

local function AppendResourceFile(filename, chunk)
    local existing = LoadResourceFile(resourceName, filename) or ""
    return SaveResourceFile(resourceName, filename, existing .. chunk, -1)
end

local function FlushLogs()
    for filename, lines in pairs(LogQueue) do
        if #lines > 0 then
            local chunk = table.concat(lines)
            LogQueue[filename] = {} -- 立即清空缓冲区防止重复写入

            local written = false

            -- 1. 资源目录下的 logs/（绝对路径，避开 cwd 不确定）
            if resourcePath ~= '' then
                local file = io.open(resourcePath .. 'logs/' .. filename, "a")
                if file then
                    file:write(chunk)
                    file:close()
                    written = true
                end
            end

            -- 2. 降级：资源根目录（不依赖子目录存在）
            if not written then
                written = AppendResourceFile(filename, chunk) and true or false
            end

            -- 3. 两条都失败才抱怨一次（不再静默）
            if not written then
                print(('[custom-logs] ⚠️ 审计落盘失败（%s）—— 检查资源目录写权限'):format(filename))
            end
        end
    end
end

-- ── 留存策略（P1-6）────────────────────────────────────────────
-- 原来只有 `<type>_audit.log` 一个文件，永不轮转：跑上几个月就是几百 MB，
-- 每次 flush 都要 load + 拼接整个文件（`AppendResourceFile` 那条兜底路径尤其贵）。
-- 现在按天分片 + 保留 N 天 + 单文件体积上限滚动。
--   * 文件名：`<type>_audit-YYYY-MM-DD.log`，超上限变 `<type>_audit-YYYY-MM-DD-2.log`；
--   * 保留：`custom_logs_retention_days`（默认 30），每小时扫一次，**永不删当天**；
--   * 只按文件名里的日期判断，不做通配盲删。
local RETENTION_DAYS = math.max(1, tonumber(GetConvar('custom_logs_retention_days', '30')) or 30)
local MAX_FILE_BYTES = math.max(1024 * 1024, tonumber(GetConvar('custom_logs_max_bytes', '10485760')) or 10485760)
local fileSizes = {}
local oversizeWarned = false

local function DatedFilename(logType, suffix)
    local day = os.date('%Y-%m-%d')
    if suffix and suffix > 1 then
        return ('%s_audit-%s-%d.log'):format(logType, day, suffix)
    end
    return ('%s_audit-%s.log'):format(logType, day)
end

-- 当前分片：按已知体积滚动，避免写完才发现超限
local function PickFilename(logType)
    local index = 1
    while true do
        local name = DatedFilename(logType, index)
        local size = fileSizes[name]
        if size == nil then
            -- 首次见到：从磁盘读一次真实大小（之后靠累计值，不再 IO）
            local existing = LoadResourceFile(resourceName, name)
            size = existing and #existing or 0
            fileSizes[name] = size
        end
        if size < MAX_FILE_BYTES then
            return name
        end
        index = index + 1
        if index > 20 then
            -- 单日 20 个分片（≈200MB）。到顶后**继续写第 20 片**而不是新开文件，
            -- 避免刷屏时把磁盘塞满 inode；但会告警一次，让运维看得见。
            if not oversizeWarned then
                oversizeWarned = true
                print(('[custom-logs] ⚠️ %s 审计单日已超过 %d 片（%dMB），后续继续写入第 20 片：'
                    .. '请检查是否有刷屏来源'):format(logType, 20, (MAX_FILE_BYTES * 20) // (1024 * 1024)))
            end
            return DatedFilename(logType, 20)
        end
    end
end

-- 辅助函数：将审计日志压入缓冲区队列，保障主线程 0 微秒阻塞
local function WriteToLocalFile(logType, message)
    local filename = PickFilename(logType)
    local datePrefix = os.date("[%Y-%m-%d %H:%M:%S] ")
    local logLine = datePrefix .. message .. "\n"

    fileSizes[filename] = (fileSizes[filename] or 0) + #logLine

    if not LogQueue[filename] then
        LogQueue[filename] = {}
    end
    table.insert(LogQueue[filename], logLine)
end

-- 清理：删掉保留窗口之外的分片。只按**文件名里的日期**判断，永不删当天。
-- os.remove / os.rename 在本 build 可用（同仓 custom-agent-ops 的 AgentOps.RotateFile 就在用）。
local AUDIT_TYPES = { 'economy', 'security', 'system' }

local function SweepOldLogs(maxAgeDays)
    if resourcePath == '' then
        print('[custom-logs] ⚠️ 拿不到资源路径（GetResourcePath 返回空），跳过审计清理 —— 磁盘会持续增长')
        return 0
    end
    maxAgeDays = math.max(1, tonumber(maxAgeDays) or (RETENTION_DAYS + 2))

    local removed = 0
    local today = os.date('%Y-%m-%d')

    for _, logType in ipairs(AUDIT_TYPES) do
        -- 从昨天往前推 RETENTION_DAYS+2 天，探测 1..20 号分片
        for offset = 1, maxAgeDays do
            local day = os.date('%Y-%m-%d', os.time() - offset * 86400)
            -- 探测范围可以很宽（启动时扫 10 年清积压），但**删不删由 retention 决定**：
            -- 只删超出保留窗口的分片，窗口内的一律不动（否则一次宽扫就把近 30 天全删了）。
            if offset > RETENTION_DAYS and day ~= today then
                for suffix = 1, 20 do
                    local name = (suffix == 1)
                        and ('%s_audit-%s.log'):format(logType, day)
                        or ('%s_audit-%s-%d.log'):format(logType, day, suffix)
                    -- 落盘可能在 `<resource>/logs/`（首选）或资源根（兜底），两处都要扫
                    local absolute
                    for _, candidate in ipairs({ resourcePath .. 'logs/' .. name, resourcePath .. name }) do
                        local probe = io.open(candidate, 'rb')
                        if probe then
                            probe:close()
                            absolute = candidate
                            break
                        end
                    end
                    if not absolute then
                        if suffix > 1 then break end  -- 该天没有更多分片
                    else
                        if os.remove(absolute) then
                            fileSizes[name] = nil
                            removed = removed + 1
                        end
                    end
                end
            end
        end
    end

    return removed
end

-- 周期性异步批量刷盘协程（每 5 秒自动写入一次）
CreateThread(function()
    while true do
        Wait(5000)
        FlushLogs()
    end
end)

-- 留存清理：启动后先做一次**宽扫**（10 年，清历史积压 —— 窄扫永远碰不到比窗口更老的文件），
-- 之后每小时窄扫一次。
CreateThread(function()
    Wait(30000)
    local removed = SweepOldLogs(3650)
    if removed > 0 then
        print(('[custom-logs] 🧹 启动清理：删除 %d 个过期审计分片（保留 %d 天）'):format(removed, RETENTION_DAYS))
    end
    while true do
        Wait(3600 * 1000)
        SweepOldLogs(RETENTION_DAYS + 2)
    end
end)

exports('AuditSweepNow', function()
    SweepOldLogs()
    return { retentionDays = RETENTION_DAYS, maxBytes = MAX_FILE_BYTES }
end)

-- 资源卸载时强制进行数据扫尾刷盘，防止任何数据流失
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        FlushLogs()
    end
end)

-- 辅助函数：向 Discord 发送带有美观排版的嵌入式 Embed 消息
local function SendDiscordWebhook(webhookUrl, title, description, color)
    if not webhookUrl or webhookUrl == "" then return end

    local payload = {
        username = "T-City Lite v0.3 Audit",
        avatar_url = "https://raw.githubusercontent.com/qbcore-framework/qb-core/main/html/logo.png",
        embeds = {
            {
                title = title or "System Audit Notification",
                description = description or "",
                color = color or 16777215, -- 默认白色
                footer = {
                    text = "T-City Lite Security Framework • " .. os.date("%Y-%m-%d %H:%M:%S"),
                }
            }
        }
    }

    PerformHttpRequest(webhookUrl, function(statusCode, response, headers)
        -- 调试模式下可打印日志状态
        if QBConfig.Custom.General.EnableDebug and statusCode ~= 204 and statusCode ~= 200 then
            print(("[custom-logs][logs] Webhook HTTP Error: %s"):format(statusCode))
        end
    end, 'POST', json.encode(payload), { ['Content-Type'] = 'application/json' })
end

-- ==========================================
--                  公 开 导 出
-- ==========================================

-- 1. 经济系统日志统一接口
-- @param title string 标题
-- @param message string 详细日志内容
-- @param color number Discord Embed 边框颜色 (十进制)
local function LogEconomy(title, message, color)
    if not QBConfig.Custom.General.EnableCustomLogs then return end
    
    local defaultColor = 4289797 -- 翡翠绿 (十进制: #417505)
    local finalColor = color or defaultColor

    -- 本地审计记录
    WriteToLocalFile("economy", ("[%s] %s"):format(title, message))

    -- Webhook 送达
    local webhook = QBConfig.Custom.Webhooks.Money
    SendDiscordWebhook(webhook, "💰 经济审计: " .. title, message, finalColor)
end

exports('LogEconomy', LogEconomy)

-- 2. 安全与防刷日志统一接口
-- @param title string 标题
-- @param message string 异常细节
-- @param color number Discord Embed 边框颜色 (十进制)
local function LogSecurity(title, message, color)
    if not QBConfig.Custom.General.EnableCustomLogs then return end

    local defaultColor = 13631488 -- 警告红 (十进制: #D0021B)
    local finalColor = color or defaultColor

    -- 本地审计记录
    WriteToLocalFile("security", ("[%s] %s"):format(title, message))

    -- Webhook 送达
    local webhook = QBConfig.Custom.Webhooks.Security
    SendDiscordWebhook(webhook, "🛡️ 安全预警: " .. title, message, finalColor)
end

exports('LogSecurity', LogSecurity)

-- 3. 通用系统日志统一接口
-- @param title string 标题
-- @param message string 信息
-- @param color number Discord Embed 边框颜色 (十进制)
local function LogGeneric(title, message, color)
    if not QBConfig.Custom.General.EnableCustomLogs then return end

    local defaultColor = 7434190 -- 系统蓝 (十进制: #716FCE)
    local finalColor = color or defaultColor

    -- 本地审计记录
    WriteToLocalFile("system", ("[%s] %s"):format(title, message))

    -- Webhook 送达 (使用 JoinLeave 通道或 fallback)
    local webhook = QBConfig.Custom.Webhooks.JoinLeave ~= "" and QBConfig.Custom.Webhooks.JoinLeave or QBConfig.Custom.Webhooks.Security
    SendDiscordWebhook(webhook, "⚙️ 系统日志: " .. title, message, finalColor)
end

exports('LogGeneric', LogGeneric)

-- ==========================================================
-- qb-log 桥接：把 `[qb]` 侧那 47 处 TriggerEvent 接进来
-- ==========================================================
-- 背景（2026-11-07 调研）：全仓 47 处 `TriggerEvent('qb-log:server:CreateLog', …)`，
-- 唯一监听者在 `archive/` 里（不启动）→ 活跃服 **零消费者**，经济审计、反作弊、
-- 进出服日志全部丢失。这也是那个 `%d` 金额 bug 唯一可见症状只是报错的原因。
--
-- 为什么用 AddEventHandler 而不是 RegisterNetEvent：qb-ambulancejob 的客户端会
-- `TriggerServerEvent('qb-log:…')`，注册成 NetEvent 就等于让客户端伪造审计。
-- 这里只接**服务端可信**的 TriggerEvent。
--
-- message 是自由文本且带 PII（citizenid/license/ip/discord），必须先过 SanitizeLogText。
local LOG_TYPE_ROUTING = {
    playermoney = 'economy',
    economy = 'economy',
    anticheat = 'security',
    bans = 'security',
    security = 'security',
}

AddEventHandler('qb-log:server:CreateLog', function(logType, title, color, message, tagEveryone)
    if type(message) ~= 'string' then return end

    local kind = LOG_TYPE_ROUTING[logType] or 'system'
    local safeTitle = SanitizeLogText(tostring(title or logType or 'qb-log'))
    local safeMessage = SanitizeLogText(message)
    local embedColor = tonumber(color) or nil

    if kind == 'economy' then
        LogEconomy(safeTitle, safeMessage, embedColor)
    elseif kind == 'security' then
        LogSecurity(safeTitle, safeMessage, embedColor)
    else
        LogGeneric(safeTitle, safeMessage, embedColor)
    end
end)
