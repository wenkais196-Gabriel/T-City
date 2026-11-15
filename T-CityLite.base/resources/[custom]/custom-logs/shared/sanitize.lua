-- sanitize.lua — 审计文本脱敏（custom-logs 唯一实现）
--
-- 宪法第 7 条：诊断/遥测永不回包、永不落 PII。
-- 而 `qb-log:server:CreateLog` 的 message 是**自由文本**，里面已经带着 PII：
--   * `qb-core` 的经济审计带玩家名 + 完整 citizenid；
--   * `qb-multicharacter` 的日志同时带 discordId、playerIp、license。
-- 所以桥接层不能直接落 message，必须先过这里。
--
-- 口径：**掩码而不是删除**，保留可排查性 ——
--   citizenid → 前4…后4（ABCD1234 → ABCD…1234，8 位以下的整体打码）；
--   license / ip / discord / steam 的值整体打码；
--   玩家名保留（客服排查要用，且不是可登录凭据）；控制字符清掉；正文截断 500。

local MAX_LEN = 500

local function MaskValue(value)
    if type(value) ~= 'string' or value == '' then return '***' end
    if #value <= 8 then return '***' end
    return value:sub(1, 4) .. '…' .. value:sub(-4)
end

---@param text string
---@return string
function SanitizeLogText(text)
    if type(text) ~= 'string' then return '' end

    local cleaned = text

    -- 带标签的凭据/标识：保留标签，值掩码
    cleaned = cleaned:gsub('(citizenid%s*[:=]%s*)([%w%-_]+)', function(label, value)
        return label .. MaskValue(value)
    end)
    cleaned = cleaned:gsub('(license%s*[:=]%s*)(%S+)', '%1***')
    cleaned = cleaned:gsub('(ip%s*[:=]%s*)(%S+)', '%1***')
    cleaned = cleaned:gsub('(discord%s*[:=]%s*)(%S+)', '%1***')
    cleaned = cleaned:gsub('(steam%s*[:=]%s*)(%S+)', '%1***')

    -- 控制字符（防止把换行注入本地日志行）
    cleaned = cleaned:gsub('%c', ' ')

    if #cleaned > MAX_LEN then
        cleaned = cleaned:sub(1, MAX_LEN) .. '…'
    end

    return cleaned
end
