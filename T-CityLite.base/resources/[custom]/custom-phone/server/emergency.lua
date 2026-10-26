-- server/emergency.lua — 手机里的 911 入口
--
-- 在此之前，玩家只能靠聊天命令 /911 报警，而手机「热线」里的 911 只是一个拨号动画：
-- 新玩家根本不知道报警要走哪条路，而世界看着像是有报警系统的。
--
-- 设计约束：
-- * 权威仍在 custom-police：这里只做参数清洗 + 限流，然后调它的 CreateIncident，
--   不复制任何警情规则（不建表、不碰 police_incidents）。
-- * 坐标由警察侧从报警者 ped 上取，客户端只交一句原因——手机不该、也不能决定警情位置。
-- * 限流用手机自己的门面 PhoneRateLimit（与 appQuery/appAction 同一套语义）。

-- 每个文件各自解析 QBCore（本资源的既有约定：main/banking/faction 都是这么写的，
-- 全局名在别的文件里是 local，拿不到）。
local QBCore = exports['qb-core']:GetCoreObject()

local RATE_PER_MINUTE = 6
local RATE_BURST = 2
local MIN_REASON = 2
local MAX_REASON = 200

--- 清洗玩家输入：去掉控制字符（会被写进通知与日志），压掉首尾空白。
---@param value any
---@return string
local function cleanReason(value)
    if type(value) ~= 'string' then return '' end
    local text = value:gsub('[%c]', ' ')
    return text:match('^%s*(.-)%s*$') or ''
end

QBCore.Functions.CreateCallback('phone:server:report911', function(source, cb, payload)
    if not PhoneRateLimit.Allow(('911:%d'):format(source), RATE_PER_MINUTE, RATE_BURST) then
        return cb({ success = false, error = 'rate_limited' })
    end

    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false, error = 'player_not_found' }) end

    local reason = cleanReason(type(payload) == 'table' and payload.reason or nil)
    if #reason < MIN_REASON then return cb({ success = false, error = 'too_short' }) end
    if #reason > MAX_REASON then reason = reason:sub(1, MAX_REASON) end

    if type(exports) ~= 'table' or exports['custom-police'] == nil then
        return cb({ success = false, error = 'dispatch_offline' })
    end

    local ok, result = pcall(function()
        return exports['custom-police']:CreateIncident(source, {
            code = '911',
            title = reason,
            description = reason,
            priority = 2,
        })
    end)
    if not ok or type(result) ~= 'table' then
        print(('[phone][911] 建单失败: %s'):format(tostring(result)))
        return cb({ success = false, error = 'dispatch_failed' })
    end

    cb({
        success = true,
        incident_id = result.id,
        merged = result.merged == true,
    })
end)

print('[phone][911] ✅ 报警入口已就绪 (phone:server:report911 → custom-police:CreateIncident)')
