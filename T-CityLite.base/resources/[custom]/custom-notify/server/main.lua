-- server/main.lua — 三层分派的唯一服务端入口（custom-notify）
--
-- 为什么由这个资源拥有服务端：它同时是渲染方（NUI）和投递方（手机通知），
-- 把"分派规则 + 限流"放在它自己身上，调用方只需要一条 export：
--
--   exports['custom-notify']:Push(src, 'feed', '支付 −$2', '便利店 · 余额 $516')
--   exports['custom-notify']:Push(src, 'toast', '案件已建立', 'PC-2026-1104')
--   exports['custom-notify']:Push(src, 'error', '现金不足', '还差 $48')
--   exports['custom-notify']:Push(src, 'phone', '林警官', '值班室在三楼')
--
-- kind 语义（PO 2026-11-10 拍板 D1=B）：
--   feed  — 结果类（买了/收到/完成），左下角
--   toast — 需要停一下看的（案件/罚款/任务节点），中央
--   error — 拒绝/失败，左下角红色；**永不进 toast**
--   phone — 玩家之间的 IC 内容，只进手机通知中心，屏幕不弹

local KINDS = { feed = true, toast = true, error = true, phone = true }
local WINDOW_MS = 2000
local MAX_PER_WINDOW = 12 -- 6/s：比 qb-core Notify 的 5/s 宽，一次交易的多行结果够用

--- 限流走 core-framework 的唯一实现（RATE-01 闸门：全仓只许有一份限流）。
--- core-framework 不在时**放行**：通知不是安全边界，宁可多发也不要把消息吞掉。
local function allow(src)
    local ok, allowed = pcall(function()
        return exports['core-framework']:RateLimitWindow(
            ('notifypush:%d'):format(src), MAX_PER_WINDOW, WINDOW_MS)
    end)
    if not ok then return true end
    return allowed ~= false
end

local function clean(value, limit)
    if type(value) ~= 'string' then return '' end
    local text = value:gsub('%c', ''):gsub('<[^>]*>', '')
    if #text > limit then text = text:sub(1, limit) end
    return text
end

--- 三层分派入口
---@param source number
---@param kind string
---@param title string
---@param body string|nil
---@param opts table|nil { icon, duration, appId, meta }
---@return boolean sent
local function Push(source, kind, title, body, opts)
    if type(source) ~= 'number' or source <= 0 then return false end
    if not KINDS[kind] then return false end
    if type(title) ~= 'string' or title == '' then return false end
    if not allow(source) then return false end

    opts = opts or {}
    local safeTitle = clean(title, 300)
    local safeBody = clean(body, 600)

    if kind == 'phone' then
        -- IC 内容只进手机：屏幕不弹（屏幕上弹 IC 消息会毁掉世界观）
        local Player = QBCore and QBCore.Functions and QBCore.Functions.GetPlayer(source)
        local cid = Player and Player.PlayerData and Player.PlayerData.citizenid
        if not cid then return false end
        local ok = pcall(function()
            exports['custom-phone']:Notify(cid, safeTitle, safeBody, opts.appId or 'notify', {
                kind = 'ic', source = 'server',
            })
        end)
        return ok
    end

    TriggerClientEvent('tcity:notify', source, {
        kind = kind,
        title = safeTitle,
        body = safeBody,
        icon = opts.icon,
        duration = opts.duration,
    })
    return true
end

exports('Push', Push)
exports('Broadcast', function(kind, title, body, opts)
    for _, src in ipairs(GetPlayers()) do
        Push(tonumber(src), kind, title, body, opts)
    end
end)

print('[custom-notify] 三层分派入口已注册（exports: Push / Broadcast）')
