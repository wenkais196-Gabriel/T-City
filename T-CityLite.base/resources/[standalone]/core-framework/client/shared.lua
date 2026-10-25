-- core-framework/client/shared.lua — 客户端共享助手（被别的资源**包含**，不通过 exports 调用）
--
-- 为什么是"包含"而不是 exports：
--   `DrawText3D` 这类函数是**逐帧**调用的。跨资源 export 每次都要过一遍运行时边界，
--   在每帧 × 每个标记的调用密度下，这点开销会实打实地变成帧时间。而 `@resource/file.lua`
--   是加载期把文件拼进来（和 `@oxmysql/lib/MySQL.lua` 同一个机制）：零调用开销，
--   也不需要操心启动顺序—— 文件里的东西在资源加载时就已经存在了。
--
-- 用法（在调用方的 fxmanifest 里）：
--   client_scripts {
--       '@core-framework/client/shared.lua',
--       'client/main.lua',
--   }
--   建议同时声明 `dependencies { 'core-framework' }`，让加载顺序有据可查。
--
-- 这里只放**纯客户端、无状态、逐帧安全**的东西。有状态或要跨资源共享数据的，走 exports。

CFShared = CFShared or {}

local function debugLog(msg)
    -- 只在显式打开时才打印，避免刷客户端 F8
    if GetConvarInt and GetConvarInt('cf_client_debug', 0) == 1 then
        print(('[core-framework/shared] %s'):format(msg))
    end
end

--- 3D 文字（世界坐标）+ 半透明底衬。原来是 custom-police 里 evidence/objects 两份逐字节相同的副本。
---@param x number
---@param y number
---@param z number
---@param text string
function CFShared.DrawText3D(x, y, z, text)
    SetTextScale(0.35, 0.35)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextColour(255, 255, 255, 215)
    BeginTextCommandDisplayText('STRING')
    SetTextCentre(true)
    AddTextComponentSubstringPlayerName(text)
    SetDrawOrigin(x, y, z, 0)
    EndTextCommandDisplayText(0.0, 0.0)
    local factor = (string.len(text)) / 370
    DrawRect(0.0, 0.0 + 0.0125, 0.017 + factor, 0.03, 0, 0, 0, 75)
    ClearDrawOrigin()
end

--- 阻塞式加载模型，带超时。
--- 原来 custom-police 的 backup/npc_callouts 各有一份逐字节相同的实现：
--- 先 `IsModelInCdimage` 挡掉服务器没有的模型（否则没有自定义警车车队的服务器会直接硬失败），
--- 再等 `HasModelLoaded`，10 秒超时。
---@param modelHash number
---@param timeoutMs number|nil 默认 10000
---@return boolean loaded
function CFShared.LoadModel(modelHash, timeoutMs)
    if type(modelHash) ~= 'number' or modelHash == 0 then return false end
    if type(IsModelInCdimage) ~= 'function' or not IsModelInCdimage(modelHash) then
        debugLog(('model %s 不在 cdimage 里，跳过'):format(tostring(modelHash)))
        return false
    end
    if type(HasModelLoaded) ~= 'function' or type(RequestModel) ~= 'function' then return false end
    if HasModelLoaded(modelHash) then return true end

    RequestModel(modelHash)
    local deadline = GetGameTimer() + (timeoutMs or 10000)
    while not HasModelLoaded(modelHash) do
        if GetGameTimer() > deadline then
            debugLog(('model %s 加载超时'):format(tostring(modelHash)))
            return false
        end
        Citizen.Wait(10)
    end
    return true
end

--- 释放已加载的模型（配合 LoadModel 用；不释放会一直占着流式内存）。
---@param modelHash number
function CFShared.ReleaseModel(modelHash)
    if type(modelHash) == 'number' and modelHash ~= 0 then
        SetModelAsNoLongerNeeded(modelHash)
    end
end

-- 启动自证：F8 里能看到这一行，说明包含生效（服务端日志看不到客户端 print）
print('[core-framework] client shared ready (CFShared.DrawText3D, CFShared.LoadModel)')
