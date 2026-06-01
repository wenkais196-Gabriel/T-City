local QBCore = exports['qb-core']:GetCoreObject()

local LogQueue = {}

-- 高性能合并：批量清空写入
local function FlushLogs()
    local folderPath = "logs/"
    local resourceName = GetCurrentResourceName()

    for filename, lines in pairs(LogQueue) do
        if #lines > 0 then
            local chunk = table.concat(lines)
            LogQueue[filename] = {} -- 立即清空缓冲区防止重复写入

            -- 1. 尝试使用标准 Lua I/O 批量追加写入主服务器 logs/ 目录
            local file, err = io.open(folderPath .. filename, "a")
            if file then
                file:write(chunk)
                file:close()
            else
                -- 2. 权限受限时降级写入资源内部（非阻塞/Cfx自带安全通道）
                local relativePath = ("logs_fallback/%s"):format(filename)
                local existing = LoadResourceFile(resourceName, relativePath) or ""
                SaveResourceFile(resourceName, relativePath, existing .. chunk, -1)
            end
        end
    end
end

-- 辅助函数：将审计日志压入缓冲区队列，保障主线程 0 微秒阻塞
local function WriteToLocalFile(logType, message)
    local filename = ("%s_audit.log"):format(logType)
    local datePrefix = os.date("[%Y-%m-%d %H:%M:%S] ")
    local logLine = datePrefix .. message .. "\n"

    if not LogQueue[filename] then
        LogQueue[filename] = {}
    end
    table.insert(LogQueue[filename], logLine)
end

-- 周期性异步批量刷盘协程（每 5 秒自动写入一次）
CreateThread(function()
    while true do
        Wait(5000)
        FlushLogs()
    end
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
            print(("[custom-main][logs] Webhook HTTP Error: %s"):format(statusCode))
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
