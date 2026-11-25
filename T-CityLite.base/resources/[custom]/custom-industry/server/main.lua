-- server/main.lua — S1 启动接线。
--
-- convar industry_enable 默认 false：关掉时本资源只打一行日志、不注册任何命令，
-- 现有玩法零影响（回滚 = 改回 false + restart custom-industry）。

if not Config.Industry.Enabled then
    print('[custom-industry] disabled: set industry_enable true to enable /orgfund* commands')
    return
end

IndustryCommands.Register()
