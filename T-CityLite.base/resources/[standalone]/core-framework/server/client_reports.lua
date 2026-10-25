-- server/client_reports.lua — 客户端 → 服务端的可观测性通道
--
-- 为什么需要它：客户端的 `print` 只进玩家自己的 F8，**服务端日志永远看不到**。于是
-- "客户端到底有没有加载到新文件"这类问题在服务端无法回答，只能让玩家看 F8 截图。
-- 这个坑咬过两次：跨资源导出缺失（要等第一次调用才炸）、`@core-framework/client/shared.lua`
-- 包含失效（客户端静默降级成 no-op）。
--
-- 两个事件，都是**诊断类**（不收业务数据，只写服务端日志）：
--
--   core-framework:server:clientReady   客户端资源加载完成后发一次
--                                       → `[client-ready] <res> v<version> <player>`
--   core-framework:server:clientReport  客户端主动上报（CFShared.Report）
--                                       → `[client-report] <res> <kind> <player>: <msg>`
--
-- 安全约束（与 net_events_allowlist.json 的登记一致）：
--   * 只接受标量，去控制字符（**尤其是换行**：否则客户端能往服务端日志里伪造整行）+ 截断；
--   * kind / 资源名白名单式校验，版本号只留 `[%w._-]`；
--   * 每 source 限流，走 core-framework 自己的限流 owner（不手写第二份）。

-- 事件名用字面量写在 RegisterNetEvent 里：架构闸门是按字面量扫的，用变量名注册会让它
-- 完全看不见这个事件（诊断通道尤其危险，它可以写服务端日志）。
local KINDS = { error = true, warn = true, info = true }

--- 去控制字符、压空白、截断。返回 nil 表示这条不值得记。
---@param value any
---@param maxLen number
---@param pattern string|nil 允许的字符集（默认允许全部可打印字符）
---@return string|nil
local function clean(value, maxLen, pattern)
    if type(value) ~= 'string' then return nil end
    local text = value:gsub('%c', ' ')
    if pattern then
        text = text:gsub(pattern, '')
    end
    text = text:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then return nil end
    if #text > maxLen then text = text:sub(1, maxLen) .. '…' end
    return text
end

---@param src number
---@return string
local function who(src)
    local name = clean(GetPlayerName(src) or '?', 40) or '?'
    return ('%s(#%s)'):format(name, tostring(src))
end

RegisterNetEvent('core-framework:server:clientReady', function(resourceName, version)
    local src = source
    if not src or src == 0 then return end
    -- 一次客户端加载一条；3/60s 容得下重连抖动，又挡住循环刷屏
    local ok, allowed = pcall(function()
        return exports['core-framework']:RateLimitWindow(('cf:ready:%s'):format(src), 3, 60000)
    end)
    if not ok or not allowed then return end

    local res = clean(resourceName, 64, '[^%w%[%]_%-%./]')
    local ver = clean(version, 32, '[^%w%._%-]')
    print(('[client-ready] %s %s %s'):format(
        res or '?', ver and ('v' .. ver) or '', who(src)))
end)

RegisterNetEvent('core-framework:server:clientReport', function(kind, message)
    local src = source
    if not src or src == 0 then return end
    if not KINDS[kind] then return end
    local text = clean(message, 400)
    if not text then return end
    -- 每玩家 10 条/分钟：真出问题时几秒内会连着来，够用；被刷时会被掐掉
    local ok, allowed = pcall(function()
        return exports['core-framework']:RateLimitWindow(('cf:report:%s'):format(src), 10, 60000)
    end)
    if not ok or not allowed then return end
    print(('[client-report] %s %s: %s'):format(kind, who(src), text))
end)
