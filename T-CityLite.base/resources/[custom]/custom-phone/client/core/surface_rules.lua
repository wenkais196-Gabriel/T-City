-- client/core/surface_rules.lua — 形态判定（纯函数，无 native、无副作用）。
-- 名字用 Decide 而不是 Resolve：仓库里已经有三个 Resolve（bridge/identity/decision_engine），
-- 再叫同一个名字会撞上重复实现预算闸门，也会让 grep 失去意义。
--
-- 为什么判定在 Lua 而不是 NUI：keepInput 是 focus 的一部分（手机不锁输入、平板锁），
-- 而 focus 必须在"打开"这一刻就定下来；NUI 在 CEF 加载期还收不到消息，
-- 让它算形态等于把开关的正确性押在"页面一定能答话"上。
--
-- 优先级（高 → 低）：
--   1. 入口强制        —— "在平板上打开"这种显式意图不能被窗口尺寸推翻
--   2. 来电            —— 来电必须是小窗，否则弹一个锁移动的整屏面板
--   3. 载具中          —— 行驶中不适合整屏面板（车载入口另算）
--   4. 玩家偏好        —— 选了 tablet 就照办，但窗口装不下时降回手机
--   5. 兜底            —— phone
--
-- **窗口大不等于要平板。** FiveM 的 NUI 视口永远是整个游戏窗口（1920×1080 起步），
-- 早先那版"窗口够大就上平板"的规则等于"每次按 M 都锁住移动"，这是拿阈值当意图。
-- 现在平板只能由**意图**触发（入口/偏好），视口只做一件事：显式要平板但窗口真的装不下时降级。
--
-- 这个文件可以被 tests 直接 dofile 断言，不需要 FXServer。

SurfaceRules = SurfaceRules or {}

SurfaceRules.PHONE = 'phone'
SurfaceRules.TABLET = 'tablet'
-- 与 web/src/core/surface.ts 的 Surface 联合类型逐字一致（闸门会比对）
SurfaceRules.KINDS = { 'phone', 'tablet' }

local function valid(kind)
    return kind == SurfaceRules.PHONE or kind == SurfaceRules.TABLET
end

---@param input table {
---  entry_surface = 'phone'|'tablet'|nil,
---  preference    = 'auto'|'phone'|'tablet'|nil,
---  viewport      = { width = number, height = number }|nil,  -- CSS px
---  in_vehicle    = boolean,
---  reason        = 'key'|'incoming_call'|'external'|nil,
---  limits        = { min_width = number, min_height = number }|nil,
--- }
---@return string kind, string why
function SurfaceRules.Decide(input)
    input = input or {}

    if valid(input.entry_surface) then
        return input.entry_surface, 'entry'
    end
    if input.reason == 'incoming_call' then
        return SurfaceRules.PHONE, 'incoming_call'
    end
    if input.in_vehicle then
        return SurfaceRules.PHONE, 'in_vehicle'
    end
    if input.preference == SurfaceRules.PHONE then
        return SurfaceRules.PHONE, 'preference'
    end
    if input.preference == SurfaceRules.TABLET then
        local limits = input.limits or {}
        local minW = tonumber(limits.min_width) or 900
        local minH = tonumber(limits.min_height) or 560
        local vp = input.viewport or {}
        local w, h = tonumber(vp.width) or 0, tonumber(vp.height) or 0
        -- 视口未知（CEF 还没上报）时不做判断：宁可按玩家说的来
        if w == 0 or h == 0 or (w >= minW and h >= minH) then
            return SurfaceRules.TABLET, 'preference'
        end
        return SurfaceRules.PHONE, 'preference_too_small'
    end
    return SurfaceRules.PHONE, 'default'
end
