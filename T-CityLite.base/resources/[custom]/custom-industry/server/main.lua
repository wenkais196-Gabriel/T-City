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
IndustryUi.Register()

IndustryProduction.Start()
-- 只做一次种子需求行校准（不新增调度）。
IndustrySales.Start()
