-- server/main.lua — S1/S2/S3/S4 启动接线。
--
-- convar industry_enable 默认 false：关掉时本资源只打一行日志、不注册任何命令，
-- 现有玩法零影响（回滚 = 改回 false + restart custom-industry）。
-- 注意：S2 起新增命令必须在这里补 Register 调用（接线用例会按 manifest 全加载）。

if not Config.Industry.Enabled then
    print('[custom-industry] disabled: set industry_enable true to enable /orgfund* commands')
    return
end

IndustryCommands.Register()
IndustryFacilityCommands.Register()
IndustryProductionCommands.Register()
IndustrySalesCommands.Register()

-- QBCore 的 export 在**资源重启的瞬间可能还不可用**（实测：`restart qb-management` 紧接着
-- `restart custom-industry` 会打一行 "UI callbacks not registered: qb-core unavailable"，
-- 而资源照常 started —— 菜单从此静默失效，只有那一行日志能看出来）。
-- 这里做有界重试，别让一次瞬态把整块 UI 打死。
local uiAttempts = 0
local function registerUi()
    if IndustryUi.Register() then return end
    uiAttempts = uiAttempts + 1
    if uiAttempts >= 60 then
        print('[custom-industry] UI callbacks failed after 60 attempts (30s); industry menu unavailable')
        return
    end
    SetTimeout(500, registerUi)
end
registerUi()

IndustryProduction.Start()
-- 只做一次种子需求行校准（不新增调度）。
IndustrySales.Start()
