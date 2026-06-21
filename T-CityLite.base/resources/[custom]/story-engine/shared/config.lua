-- shared/config.lua — story-engine 共享配置

StoryConfig = StoryConfig or {}

-- 决策超时（秒）— 玩家必须在此时间内做出选择
StoryConfig.DecisionTimeout = tonumber(GetConvar('story_decision_timeout', '120')) or 120

-- 调试模式
StoryConfig.Debug = GetConvar('story_debug', 'false') == 'true'
