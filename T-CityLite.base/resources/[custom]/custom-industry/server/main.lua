-- server/main.lua — S1/S2/S3/S4 启动接线。
--
-- convar industry_enable 默认 false：关掉时本资源只打一行日志、不注册任何命令，
-- 现有玩法零影响（回滚 = 改回 false + restart custom-industry）。
-- 注意：S2 起新增命令必须在这里补 Register 调用（接线用例会按 manifest 全加载）。

if not Config.Industry.Enabled then
    -- 「产业开没开」这个问题必须在**关闭**时也能回答：客户端启动会问一次
    -- industry:server:uiState，服务端没有这个回调时 qb-core 会打
    -- `SCRIPT ERROR: Execution of function reference in script host failed`（每次上线一条）。
    -- 所以这里只注册这一个回答器，其余命令 / 回调 / 生产循环仍然整片不注册。
    local attempts = 0
    local function registerDisabledProbe()
        local coreObject
        local ok = pcall(function() coreObject = exports['qb-core']:GetCoreObject() end)
        local createCallback = ok and coreObject and coreObject.Functions
            and coreObject.Functions.CreateCallback
        if not createCallback then
            attempts = attempts + 1
            if attempts >= 60 then
                print('[custom-industry] uiState probe not registered (qb-core unavailable)')
                return
            end
            SetTimeout(500, registerDisabledProbe)
            return
        end
        createCallback('industry:server:uiState', function(_source, cb)
            cb({ ok = true, enabled = false })
        end)
    end
    registerDisabledProbe()

    print('[custom-industry] disabled: set industry_enable true to enable /orgfund* commands')
    return
end

IndustryCommands.Register()
IndustryFacilityCommands.Register()
IndustryProductionCommands.Register()
IndustrySalesCommands.Register()
-- S6/S7：控制台换阶段 / 结算（restricted + source == 0）。
IndustryCycleCommands.Register()

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

-- 周期状态先初始化（缺失/种子行 → cycle 1 expansion；已有真实阶段则原样续跑）。
IndustryCycle.Start()
-- 周期 tick 挂到 S3 已有的生产心跳上：one scheduler, 30 秒一次；不新增线程。
IndustryProduction.Start({ onTick = IndustryCycle.Tick })
-- 只做一次种子需求行校准（不新增调度）；此时 cycle 状态已可用。
IndustrySales.Start()
