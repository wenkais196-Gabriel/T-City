-- core-framework / shared/util.lua
-- 跨资源公共工具。这里只放"语义完全一致、与业务无关"的纯工具；
-- 带自己调试开关或前缀的 DebugPrint 故意不合并（见 docs/engineering/REUSE.md）。

--- 阻塞式加载动画字典。返回值只用于"加载成功没有"，调用方通常忽略。
-- 与各资源里那份循环版的差别：多了一个超时上限（默认 5s），避免字典缺失时
-- 把整个脚本线程永久卡死（原实现 while + Wait 无上限）。
-- @param dict string
-- @param timeoutMs number|nil 默认 5000
-- @return boolean loaded
local function LoadAnimDictBlocking(dict, timeoutMs)
    if type(dict) ~= 'string' or dict == '' then return false end
    if HasAnimDictLoaded(dict) then return true end

    RequestAnimDict(dict)
    local deadline = GetGameTimer() + (tonumber(timeoutMs) or 5000)
    while not HasAnimDictLoaded(dict) do
        if GetGameTimer() > deadline then
            return false
        end
        Wait(10)
    end
    return true
end

-- 只在客户端注册：服务端没有 RequestAnimDict/GetGameTimer 这套动画原生。
if not IsDuplicityVersion() then
    exports('LoadAnimDict', LoadAnimDictBlocking)
end
