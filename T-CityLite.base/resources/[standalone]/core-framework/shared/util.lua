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


--- convar 读取助手族。语义对齐各资源里散落的那几份实现：
--  convar 为空/缺失 → 返回 default；非数字 → 也返回 default（而不是 nil）。
--- @param name string
--- @param default any
--- @return string|nil 原始值；未设置时 nil
function ConvarString(name, default)
    if type(name) ~= 'string' or name == '' then return default end
    local value = GetConvar(name, '')       -- 第二参必须是字符串，不能传 nil
    if type(value) ~= 'string' or value == '' then return default end
    return value
end

--- @param name string
--- @param default number
--- @param minimum number|nil 可选下界（含）
--- @param maximum number|nil 可选上界（含）
--- @return number
function ConvarInt(name, default, minimum, maximum)
    local raw = ConvarString(name, nil)
    if raw == nil then return default end
    local value = tonumber(raw)
    if not value or value ~= value then value = default end   -- 第二判式挡 NaN
    value = math.floor(value)
    if minimum and value < minimum then value = minimum end
    if maximum and value > maximum then value = maximum end
    return value
end

--- @return number
function ConvarFloat(name, default)
    local raw = ConvarString(name, nil)
    if raw == nil then return default end
    local value = tonumber(raw)
    if not value or value ~= value then return default end
    return value
end

--- @return boolean
function ConvarBool(name, default)
    local raw = ConvarString(name, nil)
    if raw == nil then return default end
    return raw == 'true' or raw == '1' or raw == 'TRUE'
end

-- 只在客户端注册：服务端没有 RequestAnimDict/GetGameTimer 这套动画原生。
if not IsDuplicityVersion() then
    exports('LoadAnimDict', LoadAnimDictBlocking)
    -- 启动自证：新增文件不会被 `restart` 交付给已连接的客户端（`restart` 只重读清单里
    -- 已有的文件），导出缺失会表现为"进游戏触发动画时才炸 No such export"。有这一行，
    -- 只要 refresh + restart 后没看到它，就知道客户端没拿到新脚本。
    print('[core-framework] client util ready (exports: LoadAnimDict, Convar*)')
end

-- convar 助手与业务无关、两端都要用（GetConvar 在客户端同样可用），所以不包侧别守卫。
exports('ConvarString', ConvarString)
exports('ConvarInt', ConvarInt)
exports('ConvarFloat', ConvarFloat)
exports('ConvarBool', ConvarBool)
