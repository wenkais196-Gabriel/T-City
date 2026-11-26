-- server/announce.lua — S7 公告出口（CityFeed）。
--
-- 只做三件事：拼文案、调 custom-phone 的 PostCityBulletin、把成败如实返回。
-- 公告**不是业务结果的一部分**：失败只打日志，不阻断结算、不自动重试到死
-- （重试节奏由 cycle.lua 的 RetryLogSeconds 控制）。
--
-- 不新增 net event：CityFeed 是手机 App 打开时拉取的持久公告，不是实时推送。
-- 没接「手机推送」是因为 custom-phone 没有全服推送导出；加一条就要登记
-- net_events_allowlist —— 与本片「不扩大客户端契约面」冲突，留给后续片。

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

---@param cycleNo number
---@param remainingSeconds number
---@return boolean ok
function IndustryAnnounce.Warning(cycleNo, remainingSeconds)
    return IndustryAnnounce.Publish(
        IndustryAnnounce.WarningText(cycleNo, remainingSeconds))
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

    if not IndustryAnnounce.Publish(IndustryAnnounce.ResultText(cycle, top)) then
        return false
    end

    -- 只增不减的已发布水位；重复调用不会覆盖更大的值。
    Db.Update(
        'UPDATE industry_state SET result_announced_cycle = ? '
            .. 'WHERE id = 1 AND result_announced_cycle < ?',
        { cycle, cycle })
    return true
end
