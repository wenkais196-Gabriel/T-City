QBConfig = QBConfig or {}
QBConfig.Custom = QBConfig.Custom or {}

-- 实用工具函数：从系统 Convars 中读取配置，支持后备默认值
local function GetStrConvar(name, default)
    local val = GetConvar(name, "")
    if val ~= "" then return val end
    return default
end

-- 通用常规配置
QBConfig.Custom.General = {
    EnableDebug = true,          -- 是否开启调试信息输出
    EnableCustomLogs = true      -- 是否启用本地审计与 Discord Webhook
}

-- Webhook 连接池
-- Webhook 连接池
-- 通过 Convar 动态读取，fallback 为空字符串禁止硬编码
-- 实际 webhook URL 在 configs/modules/economy.cfg 和 security.cfg 中配置
QBConfig.Custom.Webhooks = {
    DefaultLog = '',
    JoinLeave  = GetStrConvar('economy_discord_webhook', ''),    -- 登录退出 + 通用
    Money      = GetStrConvar('economy_discord_webhook', ''),    -- 资金变动
    Security   = GetStrConvar('security_discord_webhook', ''),   -- 安全审计
    Custom     = '',
}
