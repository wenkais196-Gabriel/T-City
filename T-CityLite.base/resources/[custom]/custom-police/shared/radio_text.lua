-- shared/radio_text.lua — L0 无线电层的**纯文本**部分（蓝图 §6.2 L0）。
--
-- 只做两件事：把公民身份变成一个稳定的呼号，把阶段变成一个短句。
-- 不碰实体、不碰事件、不读 convar —— 这样 golden 里可以直接测，不需要游戏。
--
-- 三条纪律：
--   * 文案里**永远没有坐标、车牌、citizenid**（无线电是广播，不是日志）；
--   * 控制字符一律剥掉（玩家可以把自己的 callsign 改成任意字节）；
--   * 单句上限 160 字符（TTS 播报太长会盖住真人语音）。

PoliceRadioText = PoliceRadioText or {}

local M = PoliceRadioText

M.MAX_TEXT = 160
M.MAX_CALLSIGN = 16

--- 呼号。QBCore metadata 里已有 `callsign`（见蓝图 §0.1），优先用它；
--- 没有就由 citizenid 稳定派生一个三位数——同一个警员每次都是同一个号，
--- 但不同警员不会撞号（模 900）。
---@param citizenid string|nil
---@param metadata table|nil
---@return string
function M.Callsign(citizenid, metadata)
    local given = metadata and metadata.callsign
    if type(given) == 'string' then
        given = given:gsub('%c', ''):gsub('^%s+', ''):gsub('%s+$', '')
        if #given > 0 and #given <= M.MAX_CALLSIGN then return given end
    end
    local text = tostring(citizenid or '')
    local hash = 0
    for i = 1, #text do
        hash = (hash * 31 + text:byte(i)) % 900
    end
    return ('Unit %d'):format(100 + hash)
end

-- 十码（ten-code）沿用北美警务口径：10-4 收到、10-8 恢复可用、10-23 到场、10-6 忙。
local TEMPLATES = {
    dispatch = '%s, copy 10-4, en route.',
    onscene = '%s is 10-23, on scene.',
    clear = '%s is 10-8, available.',
    decline = '%s, unable to respond, 10-6.',
}

--- 把阶段变成一句无线电。
---@param kind string dispatch|onscene|clear|decline
---@param callsign string
---@return string|nil
function M.Line(kind, callsign)
    local template = TEMPLATES[kind]
    if not template then return nil end
    local who = tostring(callsign or ''):gsub('%c', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if who == '' then return nil end
    if #who > M.MAX_CALLSIGN then who = who:sub(1, M.MAX_CALLSIGN) end
    local line = template:format(who)
    if #line > M.MAX_TEXT then line = line:sub(1, M.MAX_TEXT) end
    return line
end

return M
