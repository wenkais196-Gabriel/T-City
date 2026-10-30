-- server/radio.lua — L0 无线电层（蓝图 §6.2）。
--
-- 空场时"有没有警力"取决于**听得到什么**，而不是看到什么。这一层只做播报：
-- 支援单位被派出、到场、撤离时，给所有在岗警察播一句 10-code。
--
-- 三条边界（写死在代码里，不写进 SOP）：
--   1. 只发给**在岗警察**（job = police 且 onduty），不发给平民、不发给自己；
--   2. 单人 6 秒内只播一条，全局 2 秒内只播一条 —— 连点十次不会变成复读机；
--   3. 文案由 `shared/radio_text.lua` 生成，不含坐标/车牌/citizenid。

PoliceRadio = PoliceRadio or {}

local M = PoliceRadio

local PER_UNIT_GAP_MS = 3000  -- 一句话的间隔：dispatch→onscene→clear 三句在几十秒内都要听得见
local GLOBAL_GAP_MS = 2000
local lastToUnit = {}
local lastGlobalAt = 0

--- 关掉：`setr police_radio_voice 0`。手机资源没起来时直接静默（播报不是关键路径）。
local function voiceEnabled()
    return GetConvar('police_radio_voice', '1') == '1'
end

local function phoneReady()
    return GetResourceState('custom-phone') == 'started'
end

--- 在岗警察（含 citizenid 与 metadata，呼号要用）。
---@return table[] {src, cid, metadata}
local function onDutyPolice()
    local out = {}
    if type(GetPlayers) ~= 'function' then return out end
    for _, raw in ipairs(GetPlayers()) do
        local src = tonumber(raw)
        local player = src and QBCore and QBCore.Functions and QBCore.Functions.GetPlayer(src)
        local data = player and player.PlayerData
        local job = data and data.job
        if job and job.name == 'police' and job.onduty == true then
            out[#out + 1] = { src = src, cid = data.citizenid, metadata = data.metadata }
        end
    end
    return out
end

--- 播一条无线电。返回真正发出去的人数（0 = 被门控/预算挡下）。
---@param kind string dispatch|onscene|clear|decline
---@param callsign string
---@return number
function M.Say(kind, callsign)
    if not voiceEnabled() or not phoneReady() then return 0 end
    local text = PoliceRadioText and PoliceRadioText.Line(kind, callsign)
    if not text then return 0 end

    local now = GetGameTimer()
    if now - lastGlobalAt < GLOBAL_GAP_MS then return 0 end

    local sent, sentAny = 0, false
    for _, unit in ipairs(onDutyPolice()) do
        local last = lastToUnit[unit.src] or 0
        if now - last >= PER_UNIT_GAP_MS then
            TriggerClientEvent('phone:client:systemSpeech', unit.src, { text = text })
            lastToUnit[unit.src] = now
            sent = sent + 1
            sentAny = true
        end
    end
    if sentAny then lastGlobalAt = now end

    -- 诊断只记"发了几个字给几个人"，不记正文（宪法 §7：遥测不落 PII）。
    if sent > 0 and GetConvar('police_radio_debug', '0') == '1' then
        print(('[custom-police] radio %s -> %d unit(s), %d chars'):format(kind, sent, #text))
    end
    return sent
end

--- 玩家掉线后清掉他的限流槽，避免 source 复用时误判成"刚播过"。
AddEventHandler('playerDropped', function()
    lastToUnit[source] = nil
end)

return M
