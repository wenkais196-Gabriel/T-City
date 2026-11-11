-- client/main.lua — 三层通知的唯一渲染入口（custom-notify）
--
-- 为什么单独一个资源：仓库里原本有 10 条"能对玩家说话"的通道（qb-core Notify 的 NUI/原生双轨、
-- NativeNotify、DrawText、qb-target、手机通知、短信、聊天框、决策模态……），
-- 但没有一条规则决定"哪条消息走哪条"。结果罚款、短信、NPC 台词、系统错误长一个样。
--
-- 这个资源只做一件事：接服务端 `Bus.notify.Push(src, kind, title, body)` 投递过来的
-- 结构化通知，按 kind 渲染：
--   feed  — 左下角（小地图上方），结果类，5s，最多 4 条
--   toast — 中央偏上，需要停一下的，2.5s，最多 2 条
--   error — 左下角红色，拒绝/失败，5s
--   phone 不走这里：由 notify_service 直接投到 custom-phone 的通知中心
--
-- 渲染在 NUI（html/index.html）里，Lua 只做校验与转发：NUI 侧没有权限，也不该有。

local KINDS = { feed = true, toast = true, error = true }
local MAX_LEN = 180

--- 去掉控制字符并截断：通知正文来自业务数据，可能带玩家输入
local function sanitize(value, limit)
    if type(value) ~= 'string' then return '' end
    local text = value:gsub('%c', ''):gsub('<[^>]*>', '')
    if #text > (limit or MAX_LEN) then text = text:sub(1, limit or MAX_LEN) .. '…' end
    return text
end

RegisterNetEvent('tcity:notify', function(payload)
    if type(payload) ~= 'table' then return end
    local kind = payload.kind
    if not KINDS[kind] then return end

    SendNUIMessage({
        action = 'notify',
        kind = kind,
        title = sanitize(payload.title, 48),
        body = sanitize(payload.body),
        icon = sanitize(payload.icon, 8),
        duration = math.max(800, math.min(tonumber(payload.duration) or 5000, 15000)),
    })
end)

-- 本地调试入口：`/notifytest feed|toast|error`
-- 只在开发 convar 打开时可用，且不接受任何参数注入（纯白名单）
RegisterCommand('notifytest', function(_, args)
    if GetConvar('notify_dev', '0') ~= '1' then
        print('[custom-notify] /notifytest 已关闭（setr notify_dev 1 打开）')
        return
    end
    local kind = tostring(args[1] or 'feed')
    if not KINDS[kind] then
        print('[custom-notify] kind 只能是 feed / toast / error')
        return
    end
    TriggerEvent('tcity:notify', {
        kind = kind,
        title = '测试通知',
        body = ('这是一条 %s 通知（/notifytest）'):format(kind),
        duration = 5000,
    })
end, false)

print('[custom-notify] 三层通知渲染器已就绪（feed / toast / error）')
