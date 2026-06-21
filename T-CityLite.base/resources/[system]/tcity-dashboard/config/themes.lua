-- config/themes.lua — 6类载具 UI 主题定义 (v2.0)
--
-- 每个模板定义: 主色, 发光色, 风格标签, CSS变量覆盖
-- 发送给 NUI 用于动态切换主题

DashboardThemes = DashboardThemes or {}

DashboardThemes.Map = {
    -- 🏎️ 跑车/赛车 — 赛道竞技风
    sports = {
        label       = '赛道模式',
        accent      = '#FF2244',       -- 赛博朋克红
        accentGlow  = 'rgba(255,34,68,0.3)',
        bgPrimary   = 'rgba(0,0,0,0.65)',
        textPrimary = '#F0F0F5',
        textDim     = '#8899AA',
        danger      = '#FF3344',
        success     = '#22DD88',
        warning     = '#FFAA00',
        border      = 'rgba(255,255,255,0.08)',
        style       = 'racing',       -- CSS: theme-racing
        font        = 'monospace',     -- 数字等宽字体
    },
    -- 🚛 商用/重卡 — 硬朗实用风
    commercial = {
        label       = '商用模式',
        accent      = '#FF8C00',       -- 工业橙
        accentGlow  = 'rgba(255,140,0,0.2)',
        bgPrimary   = 'rgba(20,20,24,0.72)',
        textPrimary = '#EAEAEE',
        textDim     = '#778899',
        danger      = '#FF4400',
        success     = '#33CC66',
        warning     = '#FFAA00',
        border      = 'rgba(255,255,255,0.12)',
        style       = 'industrial',
        font        = 'system-ui',
    },
    -- 🚔 公共服务 — 战术应急风
    emergency = {
        label       = '应急模式',
        accent      = '#2266FF',       -- 警用蓝
        accentGlow  = 'rgba(34,102,255,0.3)',
        bgPrimary   = 'rgba(10,14,24,0.70)',
        textPrimary = '#F5F5FA',
        textDim     = '#667799',
        danger      = '#FF2244',
        success     = '#22DD88',
        warning     = '#FFAA00',
        border      = 'rgba(34,102,255,0.15)',
        style       = 'tactical',
        font        = 'system-ui',
    },
    -- ✈️ 固定翼飞机 — 玻璃座舱风
    plane = {
        label       = '航空模式',
        accent      = '#22DDBB',       -- 航空青
        accentGlow  = 'rgba(34,221,187,0.25)',
        bgPrimary   = 'rgba(8,16,24,0.60)',
        textPrimary = '#E0F0F5',
        textDim     = '#668899',
        danger      = '#FF4444',
        success     = '#22DD88',
        warning     = '#FFAA00',
        border      = 'rgba(34,221,187,0.12)',
        style       = 'glass-cockpit',
        font        = 'monospace',
    },
    -- 🚁 直升机 — 战术HUD风
    helicopter = {
        label       = '旋翼模式',
        accent      = '#44BB22',       -- 战术绿
        accentGlow  = 'rgba(68,187,34,0.28)',
        bgPrimary   = 'rgba(6,14,8,0.62)',
        textPrimary = '#DDFFDD',
        textDim     = '#558866',
        danger      = '#FF3344',
        success     = '#44FF44',
        warning     = '#FFAA00',
        border      = 'rgba(68,187,34,0.14)',
        style       = 'tactical-hud',
        font        = 'monospace',
    },
    -- 🚤 船只/游艇 — 航海仪器风
    boat = {
        label       = '航海模式',
        accent      = '#22AAFF',       -- 海洋蓝
        accentGlow  = 'rgba(34,170,255,0.22)',
        bgPrimary   = 'rgba(8,20,32,0.64)',
        textPrimary = '#E0EEF5',
        textDim     = '#6688AA',
        danger      = '#FF4444',
        success     = '#22DD88',
        warning     = '#FFAA00',
        border      = 'rgba(34,170,255,0.12)',
        style       = 'nautical',
        font        = 'system-ui',
    },
}

--- 默认主题 (fallback)
DashboardThemes.Default = DashboardThemes.Map.sports

--- 根据模板名获取主题
function DashboardThemes.Get(template)
    return DashboardThemes.Map[template] or DashboardThemes.Default
end

--- 生成发送给 NUI 的主题CSS变量
function DashboardThemes.ToNuiPayload(template)
    local t = DashboardThemes.Get(template)
    return {
        template   = template,
        label      = t.label,
        accent     = t.accent,
        accentGlow = t.accentGlow,
        style      = t.style,
        font       = t.font,
        cssVars    = {
            ['--tcity-accent']       = t.accent,
            ['--tcity-accent-glow']  = t.accentGlow,
            ['--tcity-bg-primary']   = t.bgPrimary,
            ['--tcity-text-primary'] = t.textPrimary,
            ['--tcity-text-dim']     = t.textDim,
            ['--tcity-danger']       = t.danger,
            ['--tcity-success']      = t.success,
            ['--tcity-warning']      = t.warning,
            ['--tcity-border']       = t.border,
            ['--tcity-style']        = t.style,
            ['--tcity-font']         = t.font,
        },
    }
end

print('[tcity-dashboard] 🎨 6类主题已加载')
