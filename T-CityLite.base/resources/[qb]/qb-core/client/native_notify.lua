-- native_notify.lua — GTA V 原生通知系统封装
-- 支持: The Feed 消息流 / 高级头像通知 / Help Text / Award / 浮动提示
-- 多语言: 所有文本通过 AddTextComponentSubstringPlayerName 传入
--         自动支持 CJK / 阿拉伯 / 西里尔 / 拉丁等全部 GTA V 内建字体字符集
--
-- 使用:
--   NativeNotify:Show('转账成功 $5,000')
--   NativeNotify:ShowAdvanced('银行', '转账', '收到 $5,000', 'CHAR_BANK_MAZE')
--   NativeNotify:ShowHelpText('按 ~INPUT_CONTEXT~ 打开', 5000)

-- ═══════════════════════════════════════════════════════════
-- 原生通知图标常量 (GTA V 内建)
-- ═══════════════════════════════════════════════════════════
local NOTIFY_ICONS = {
    -- 角色头像
    CHAR_BANK_MAZE       = 'CHAR_BANK_MAZE',
    CHAR_BANK_FLEECA     = 'CHAR_BANK_FLEECA',
    CHAR_LESTER          = 'CHAR_LESTER',
    CHAR_LESTER_DEATHWISH = 'CHAR_LESTER_DEATHWISH',
    CHAR_MICHAEL         = 'CHAR_MICHAEL',
    CHAR_FRANKLIN        = 'CHAR_FRANKLIN',
    CHAR_TREVOR          = 'CHAR_TREVOR',
    CHAR_SIMEON          = 'CHAR_SIMEON',
    CHAR_RON             = 'CHAR_RON',
    CHAR_MARTIN          = 'CHAR_MARTIN',
    CHAR_STRETCH         = 'CHAR_STRETCH',
    CHAR_LAMAR           = 'CHAR_LAMAR',
    CHAR_WADE            = 'CHAR_WADE',
    CHAR_DAVE            = 'CHAR_DAVE',
    CHAR_STEVE           = 'CHAR_STEVE',
    CHAR_AMANDA          = 'CHAR_AMANDA',
    CHAR_JIMMY           = 'CHAR_JIMMY',
    CHAR_TRACEY          = 'CHAR_TRACEY',
    CHAR_PATRICIA        = 'CHAR_PATRICIA',
    CHAR_MARNIE          = 'CHAR_MARNIE',
    CHAR_TAOCHENG        = 'CHAR_TAOCHENG',
    CHAR_MOLLY           = 'CHAR_MOLLY',
    CHAR_DEVIN           = 'CHAR_DEVIN',
    CHAR_STRIPPER_JULIET = 'CHAR_STRIPPER_JULIET',
    CHAR_STRIPPER_CHASTITY = 'CHAR_STRIPPER_CHASTITY',
    CHAR_STRIPPER_CHEETAH = 'CHAR_STRIPPER_CHEETAH',
    CHAR_STRIPPER_FUFU   = 'CHAR_STRIPPER_FUFU',
    CHAR_STRIPPER_INFERNUS = 'CHAR_STRIPPER_INFERNUS',
    CHAR_STRIPPER_NIKKI  = 'CHAR_STRIPPER_NIKKI',
    CHAR_STRIPPER_PEACH  = 'CHAR_STRIPPER_PEACH',
    CHAR_STRIPPER_SAPPHIRE = 'CHAR_STRIPPER_SAPPHIRE',
    -- 组织/帮派
    CHAR_CARSITE         = 'CHAR_CARSITE',
    CHAR_CARSITE2        = 'CHAR_CARSITE2',
    CHAR_LIFEINVADER     = 'CHAR_LIFEINVADER',
    CHAR_MERRYWEATHER    = 'CHAR_MERRYWEATHER',
    CHAR_LS_CUSTOMS      = 'CHAR_LS_CUSTOMS',
    CHAR_LS_TOURIST_BOARD = 'CHAR_LS_TOURIST_BOARD',
    CHAR_BAYVIEW_LODGE   = 'CHAR_BAYVIEW_LODGE',
    CHAR_BLOCK           = 'CHAR_BLOCK',
    CHAR_CREW            = 'CHAR_CREW',
    CHAR_FACEBOOK        = 'CHAR_FACEBOOK',
    CHAR_LOS_SANTOS_GAS  = 'CHAR_LOS_SANTOS_GAS',
    CHAR_MANUEL          = 'CHAR_MANUEL',
    CHAR_MP_FM_CONTACT   = 'CHAR_MP_FM_CONTACT',
    CHAR_MP_STRIPCLUB_PR = 'CHAR_MP_STRIPCLUB_PR',
    CHAR_MULTIPLAYER     = 'CHAR_MULTIPLAYER',
    CHAR_PROPERTY_MANAGEMENT = 'CHAR_PROPERTY_MANAGEMENT',
    CHAR_SOCIAL_CLUB     = 'CHAR_SOCIAL_CLUB',
    CHAR_CALL911         = 'CHAR_CALL911',
    -- 通用图标 (iconType)
    ICON_DEFAULT     = 0,
    ICON_STAR        = 1,
    ICON_WANTED      = 3,
    ICON_ARROW       = 4,
    ICON_CASH        = 8,
    ICON_BLANK       = 13,
    ICON_RANK_UP     = 6,
    ICON_RANK_DOWN   = 7,
}

-- ═══════════════════════════════════════════════════════════
-- 内部辅助: GTA 颜色标签处理
-- 支持 ~r~ (红) ~g~ (绿) ~b~ (蓝) ~y~ (黄) ~w~ (白) ~h~ (粗体) ~n~ (换行)
-- ═══════════════════════════════════════════════════════════
local function sanitizeText(text)
    if type(text) ~= 'string' then return tostring(text or '') end
    return text
end

-- ═══════════════════════════════════════════════════════════
-- 对外 API
-- ═══════════════════════════════════════════════════════════
_G.NativeNotify = {}  -- 跨资源全局暴露 (lua54 _ENV 隔离 → 显式 _G)
local NativeNotify = _G.NativeNotify  -- 文件内部快捷引用

--- 基础通知 — 黑色半透明底 + 白字，自动排队上滑
---@param text string    通知文本 (支持 GTA 颜色标签 ~r~~g~~b~~y~)
---@param duration? number 显示时长 (ms) — 注意: 原生 Feed 的时长控制有限
function NativeNotify.Show(text, duration)
    text = sanitizeText(text)
    local ok, err = pcall(function()
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(text)
        EndTextCommandThefeedPostTicker(false, true)
    end)
    if not ok then
        -- 回退: 使用更通用的 SetNotificationTextEntry + DrawNotification
        local ok2 = pcall(function()
            SetNotificationTextEntry('STRING')
            AddTextComponentSubstringPlayerName(text)
            DrawNotification(false, true)
        end)
        if not ok2 then
            print('[native_notify] ⚠️ Both ThefeedPost and DrawNotification failed, falling back to NUI')
            return false
        end
        -- DrawNotification 成功 → 不再触发 NUI 回退
        return true
    end
    return true
end

--- 高级通知 — 带头像/图标 + 标题 + 副标题
---@param title string    发送者/标题
---@param subject string  副标题/主题
---@param text string     正文
---@param icon string     图标 (CHAR_* 常量, 见 NOTIFY_ICONS)
---@param iconType? number 图标类型 (默认 0, ICON_CASH=8, ICON_STAR=1)
---@param flash? boolean   是否闪烁 (默认 false)
function NativeNotify.ShowAdvanced(title, subject, text, icon, iconType, flash)
    title = sanitizeText(title)
    subject = sanitizeText(subject)
    text = sanitizeText(text)
    icon = icon or 'CHAR_MULTIPLAYER'
    iconType = iconType or 0

    local ok, err = pcall(function()
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(text)
        EndTextCommandThefeedPostMessagetext(
            icon,          -- textureDict
            icon,          -- textureName
            flash or false,
            iconType,      -- iconType: 0=头像 4=纯图标
            title,         -- sender
            subject,       -- subject
            1.0,           -- fadeIn
            '___menu'      -- colorType
        )
    end)
    if not ok then
        -- 回退: 使用基础通知
        return NativeNotify.Show(text)
    end
    return true
end

--- 奖杯/Award 通知 — 小地图上方弹出成就
---@param awardTitle string  成就标题
---@param iconDict string    texture dictionary
---@param iconName string    texture name
---@param rpBonus number     RP 奖励数值
---@param colorOverlay string 颜色覆盖
function NativeNotify.ShowAward(awardTitle, iconDict, iconName, rpBonus, colorOverlay)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(awardTitle or '成就解锁')
    EndTextCommandThefeedPostAward(
        iconDict or 'CHAR_SOCIAL_CLUB',
        iconName or 'CHAR_SOCIAL_CLUB',
        rpBonus or 0,
        colorOverlay or 'HUD_COLOUR_GREEN',
        awardTitle or ''
    )
end

--- Help Text — 当前版本 DrawText 的替代方案
--- 显示在屏幕中上方的交互提示 (如 "按 E 打开")
---@param text string      提示文本
---@param duration? number  显示时长 (ms), 默认 5000
---@param beep? boolean     是否播放音效
---@param loop? boolean     是否循环显示
function NativeNotify.ShowHelpText(text, duration, beep, loop)
    text = sanitizeText(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, loop or false, beep or false, duration or 5000)
end

--- 任务帮助文本 — 显示在屏幕底部中央的任务提示
---@param text string      提示文本
---@param duration? number  显示时长 (ms)
function NativeNotify.ShowMissionText(text, duration)
    text = sanitizeText(text)
    BeginTextCommandPrint('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandPrint(duration or 5000, true)
end

--- 浮动 3D 帮助文本 — 在世界坐标位置显示提示
---@param text string      提示文本
---@param coords vector3   世界坐标 {x, y, z}
---@param duration? number  显示时长 (ms)
function NativeNotify.ShowFloatingHelpText(text, coords, duration)
    text = sanitizeText(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(2, false, false, duration or 5000)
    -- 注意: FloatingHelpText 需要配合 SET_FLOATING_HELP_TEXT_WORLD_POSITION 使用
    -- 当前简化实现使用 HelpText type=2 (3D 世界模式)
end

-- ═══════════════════════════════════════════════════════════
-- 导出: 图标常量
-- ═══════════════════════════════════════════════════════════
NativeNotify.ICONS = NOTIFY_ICONS

-- 模块加载完成
print('[qb-core] 🔔 NativeNotify module loaded — 6 notification APIs ready')

-- 导出心跳: 供跨资源验证模块是否加载 (lua54 _ENV 隔离下的安全通道)
exports('NativeNotifyReady', function() return true end)
exports('NativeNotifyShow', function(text) return NativeNotify.Show(text) end)
exports('NativeNotifyShowAdvanced', function(title, subject, text, icon, iconType, flash)
    return NativeNotify.ShowAdvanced(title, subject, text, icon, iconType, flash)
end)
exports('NativeNotifyShowHelpText', function(text, duration, beep, loop)
    NativeNotify.ShowHelpText(text, duration, beep, loop)
    return true
end)
