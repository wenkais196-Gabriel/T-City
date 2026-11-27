-- server/announce.lua — S7 公告出口（CityFeed + 手机推送）。
--
-- 做四件事：拼文案、调 custom-phone 的 PostCityBulletin、给在线组织成员推手机通知、
-- 把成败如实返回。公告/推送**不是业务结果的一部分**：失败只打日志，不阻断结算、
-- 不自动重试到死（重试节奏由 cycle.lua 的 RetryLogSeconds 控制）。
--
-- 不新增 net event：CityFeed 是手机 App 打开时拉取的持久公告；手机推送走
-- custom-phone 既有的 `Notify` 导出（写 phone_notifications 并按在线状态推送），
-- 所以 net_events_allowlist 零新增。
--
-- 推送边界（W2 #389）：只有**在线且属于 Config.Industry.OrgWhitelist** 的玩家会收到；
-- 离线成员靠 CityFeed 的历史公告补看。不做「全服广播」，也不伪造离线推送。
-- 推送没有自己的水位：只在既有公告水位（warning_announced_at /
-- result_announced_cycle）允许发布时才调用，所以同一周期天然只发一次。

IndustryAnnounce = {}

local MAX_CITYFEED_CHARS = 200

--- 剩余时间的人话：>= 1 小时按小时，否则按分钟（压缩验收时不会出现「7 天」）。
---@param seconds number
---@return string
function IndustryAnnounce.RemainingText(seconds)
    local value = math.max(0, math.floor(tonumber(seconds) or 0))
    if value >= 3600 then
        return ('约 %d 小时'):format(math.max(1, math.floor(value / 3600)))
    end
    return ('约 %d 分钟'):format(math.max(1, math.floor(value / 60)))
end

--- 结算前警告文案（<= 200 字符，CityFeed 的硬上限）。
---@param cycleNo number
---@param remainingSeconds number
---@return string
function IndustryAnnounce.WarningText(cycleNo, remainingSeconds)
    return ('产业周期 #%d 将在%s后结算：设施、库存、配额与金库余额将清零，'
        .. '威望按累计销售额折算。清库存、停购置，别把资产留到结算后。'):format(
        math.floor(tonumber(cycleNo) or 0),
        IndustryAnnounce.RemainingText(remainingSeconds))
end

--- 结算结果文案。top 为 nil 表示本周期没有组织产生结果。
---@param cycleNo number
---@param top table|nil { org_id, revenue, prestige_awarded }
---@return string
function IndustryAnnounce.ResultText(cycleNo, top)
    local cycle = math.floor(tonumber(cycleNo) or 0)
    if type(top) == 'table' and top.org_id ~= nil then
        -- `$%d` 是闸门 G-B1 的债形态（小数金额会抛 format 错）；这里先渲染成字符串。
        local revenueText = tostring(math.floor(tonumber(top.revenue) or 0))
        return ('产业周期 #%d 已结算：榜首 %s，累计销售额 $%s，威望 +%d。'
            .. '新一轮已开始，设施与配额已重置。'):format(
            cycle,
            tostring(top.org_id),
            revenueText,
            math.floor(tonumber(top.prestige_awarded) or 0))
    end
    return ('产业周期 #%d 已结算：本轮没有组织产生结算结果。新一轮已开始。'):format(cycle)
end

--- 发一条城市公告。返回 false 时调用方保留「未发布」状态，下一轮再试。
---@param text string
---@return boolean ok
function IndustryAnnounce.Publish(text)
    if type(text) ~= 'string' or text == '' or #text > MAX_CITYFEED_CHARS * 4 then
        -- 用字节上限做粗筛；真正的字符数校验在 custom-phone 的 CityFeed.ValidateBulletin。
        print('[custom-industry] city bulletin rejected: bad text length')
        return false
    end
    if type(exports) ~= 'table' then return false end

    local called, posted = pcall(function()
        return exports['custom-phone']:PostCityBulletin(text, { kind = 'industry_cycle' })
    end)
    if not called or posted ~= true then
        print(('[custom-industry] city bulletin failed: %s'):format(tostring(posted)))
        return false
    end
    return true
end

-- ── 手机推送（W2 #389）──────────────────────────────────────────
--
-- custom-phone 的 Notify(citizenid, title, content, appId, meta) 是通知的唯一写者：
-- 它负责持久化到 phone_notifications 并只推给在线玩家。本模块只决定「推给谁、说什么」。
-- 通知内容只放周期号 / 组织名 / 金额 / 时间；玩家名、坐标、citizenid、余额明细一律不进正文。

--- 玩家所属组织。规则与 IndustryUi.PlayerOrgId 一致（键排序后取第一个命中），
--- 但判定只走 IndustryAccess.OrgMembership —— 不复制任何 job/gang 或职级逻辑。
---@param Player table QBCore 玩家对象
---@return string|nil orgId
local function playerOrgId(Player)
    local whitelist = Config.Industry.OrgWhitelist or {}
    local orgIds = {}
    for orgId in pairs(whitelist) do orgIds[#orgIds + 1] = orgId end
    table.sort(orgIds)
    for _, orgId in ipairs(orgIds) do
        if IndustryAccess.OrgMembership(Player, orgId) then return orgId end
    end
    return nil
end

--- 按在线组织成员推送一条通知。返回成功推送的条数。
---
--- 只遍历 QBCore.Functions.GetQBPlayers()（= 在线玩家）；离线成员不在结果里，
--- 靠 CityFeed 的历史公告补看。
---@param cycleNo number
---@param title string
---@param content string
---@return number sent
function IndustryAnnounce.PushToMembers(cycleNo, title, content)
    local cycle = math.floor(tonumber(cycleNo) or 0)
    -- 内联而不是再定义一个 enabled()：同名函数到第 4 份会触发 reuse 预算闸门。
    if Config.Industry.Enabled ~= true then return 0 end
    if type(IndustryAccess) ~= 'table' then return 0 end

    local coreOk, core = pcall(function()
        return exports['qb-core']:GetCoreObject()
    end)
    local functions = coreOk and type(core) == 'table' and core.Functions or nil
    if type(functions) ~= 'table' then
        print(('[custom-industry] push skipped cycle=%d: qb-core unavailable'):format(cycle))
        return 0
    end

    -- ⚠️ 本 build 的跨资源导出函数是**可调用表**，`type(...) == 'function'` 恒假。
    -- 只判存在性并 pcall 调用（见 test_qbcore_callable_table_guards）。
    local called, players = pcall(function()
        return functions.GetQBPlayers()
    end)
    if not called or type(players) ~= 'table' then
        print(('[custom-industry] push skipped cycle=%d: GetQBPlayers unavailable'):format(cycle))
        return 0
    end

    local sent = 0
    for _, Player in pairs(players) do
        local data = type(Player) == 'table' and Player.PlayerData or nil
        if type(data) == 'table' and type(data.citizenid) == 'string' and data.citizenid ~= '' then
            local orgId = playerOrgId(Player)
            if orgId then
                local ok, pushed = pcall(function()
                    return exports['custom-phone']:Notify(
                        data.citizenid, title, content, 'industry',
                        { source = data.source })
                end)
                if ok and pushed == true then
                    sent = sent + 1
                else
                    -- 日志不带 citizenid：通知/诊断都不落 PII。
                    print(('[custom-industry] push failed cycle=%d org=%s err=%s'):format(
                        cycle, tostring(orgId), tostring(pushed)))
                end
            end
        end
    end
    return sent
end

--- 推送失败只打日志，绝不让它冒泡到公告/结算路径。
local function pushSafely(cycleNo, title, content)
    local called, sent = pcall(IndustryAnnounce.PushToMembers, cycleNo, title, content)
    if not called then
        print(('[custom-industry] push crashed cycle=%d: %s'):format(
            math.floor(tonumber(cycleNo) or 0), tostring(sent)))
    end
end

---@param cycleNo number
---@param remainingSeconds number
---@return boolean ok
function IndustryAnnounce.Warning(cycleNo, remainingSeconds)
    local cycle = math.floor(tonumber(cycleNo) or 0)
    local text = IndustryAnnounce.WarningText(cycle, remainingSeconds)
    if not IndustryAnnounce.Publish(text) then return false end

    -- 挂在既有 warning 水位的发布路径上：cycle.lua 只在 warning_done=false 时调用
    -- 本函数，发布成功后才写 warning_announced_at。下一 tick 不会再走到这里。
    pushSafely(cycle, ('产业周期 #%d 即将结算'):format(cycle), text)
    return true
end

--- 公告结算结果；成功后把 state.result_announced_cycle 推到该周期。
--- 读结果表失败/无结果都不算失败：文案会退化成「本轮没有组织参与」。
---@param cycleNo number
---@return boolean ok
function IndustryAnnounce.Result(cycleNo)
    local cycle = math.floor(tonumber(cycleNo) or 0)
    if cycle < 1 then return false end

    -- 幂等：同一周期的结果公告只发一次（结算重试/手工重跑都不该再喊一遍）。
    local stateRow, stateErr = Db.Single(
        'SELECT result_announced_cycle FROM industry_state WHERE id = 1 LIMIT 1', {})
    if not stateErr and stateRow
        and math.floor(tonumber(stateRow.result_announced_cycle) or 0) >= cycle then
        return true
    end

    local top
    local row, err = Db.Single(
        'SELECT org_id, revenue, prestige_awarded FROM industry_cycle_results '
            .. 'WHERE cycle_no = ? ORDER BY revenue DESC LIMIT 1',
        { cycle })
    if not err and row then top = row end

    local text = IndustryAnnounce.ResultText(cycle, top)
    if not IndustryAnnounce.Publish(text) then
        return false
    end

    -- 只增不减的已发布水位；重复调用不会覆盖更大的值。
    Db.Update(
        'UPDATE industry_state SET result_announced_cycle = ? '
            .. 'WHERE id = 1 AND result_announced_cycle < ?',
        { cycle, cycle })

    -- 先写水位再推送：下一次调用会在函数开头直接返回，不会重复推送同一周期。
    pushSafely(cycle, ('产业周期 #%d 已结算'):format(cycle), text)
    return true
end
