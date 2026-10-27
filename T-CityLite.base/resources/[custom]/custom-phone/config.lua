Config = {}

-- 默认开关按键（M键，五M映射为键盘的 "M" 键）
Config.OpenKey = 'M'

-- 形态判定的窗口阈值（CSS px）。判定方是客户端 Lua（client/core/surface_rules.lua），
-- 数值跟着判定方走：宽 ≥ 900 且 高 ≥ 560 且横向才用平板壳。
Config.Surface = {
    TabletMinWidth = 900,
    TabletMinHeight = 560,
}

-- 手机最大短信存储条数（超过会自动清理，保障DB性能）
Config.MaxMessagesPerNumber = 100

-- 系统通知最大留存时间（秒）
Config.NotificationExpiry = 3600 -- 1小时

-- Job Board 平民抢单冷却时间（秒）
Config.JobAcceptCooldown = 15

-- 调试模式
Config.Debug = false
