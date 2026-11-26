-- 适配层开关的**服务端**侧：把 convar 落到 GlobalState。
--
-- 为什么需要这一层：客户端 `GetConvar` 在部分情况下读不到服务端 `setr` 设的值
-- （2026-11-26 真机：服务端确认 true，客户端仍走老路径）。GlobalState 是随实体/状态
-- 同步下发的，客户端读它最可靠；适配层因此「GlobalState 优先、convar 兜底」。
--
-- 运维开关流程：`setr qb_menu_use_custom_menu true` → `restart qb-menu`（本文件在启动时重读）。

local function publish()
    local enabled = GetConvar('qb_menu_use_custom_menu', 'false') == 'true'
    GlobalState.qb_menu_use_custom_menu = enabled
    print(('[qb-menu] adapter enabled=%s (convar qb_menu_use_custom_menu)'):format(tostring(enabled)))
end

publish()

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    publish()
end)
