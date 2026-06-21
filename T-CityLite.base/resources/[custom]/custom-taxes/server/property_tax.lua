-- ============================================================================
-- PropertyTaxService — 房产税懒加载系统 (v1.0.0)
-- ============================================================================
-- 核心设计:
--   "拒绝全服死循环扣费" — 采用懒加载 (Lazy Evaluation):
--   仅在玩家登录或触发房产交互时，异步计算时间差并单次扣款。
--   全服 900 个下线玩家对主线程的消耗精确为零。
--
-- 阶梯税率:
--   第1套 0.3% → 第2套 0.5% → 第3套 1.0% → 第5套 2.0% → 5+套 5.0%
--   地段系数: tier1×0.8 / tier2×1.0 / tier3×1.5 / tier4×2.0
--
-- 欠费充公:
--   连续 3 次扣款失败 → 房产自动收回 (清空 citizenid + keyholders)
-- ============================================================================

local QBCore = exports['qb-core']:GetCoreObject()
local config = QBCore.Config.Taxes and QBCore.Config.Taxes.PropertyTax or {}

-- ── 内部: 获取玩家的房产列表 ──────────────────────────────────────────

---获取玩家全部房产 (含 houselocations 的价格和 tier)
---@param citizenid string
---@return table|nil houses [{houseId, price, tier, name, label}]
local function getPlayerHouses(citizenid)
    if not citizenid then return nil end
    if not MySQL then return nil end

    local result = MySQL.query.await(
        [[SELECT ph.house, hl.price, hl.tier, hl.label
          FROM player_houses ph
          LEFT JOIN houselocations hl ON ph.house = hl.name
          WHERE ph.citizenid = ?]],
        { citizenid }
    )
    return result
end

---获取房产的基础价格
---@param houseName string
---@return number price
local function getHousePrice(houseName)
    local result = MySQL.scalar.await(
        'SELECT price FROM houselocations WHERE name = ?',
        { houseName }
    )
    return tonumber(result) or 0
end

---获取房产的 tier
---@param houseName string
---@return number tier
local function getHouseTier(houseName)
    local result = MySQL.scalar.await(
        'SELECT tier FROM houselocations WHERE name = ?',
        { houseName }
    )
    return tonumber(result) or 1
end

-- ── 内部: 税率计算 ────────────────────────────────────────────────────

---根据房产数量获取阶梯税率
---@param houseCount number
---@return number rate
local function getTieredRate(houseCount)
    local tiers = config.tiers or {
        { count = 1, rate = 0.003 },
        { count = 2, rate = 0.005 },
        { count = 3, rate = 0.010 },
        { count = 5, rate = 0.020 },
        { count = 99, rate = 0.050 },
    }

    for _, tier in ipairs(tiers) do
        if houseCount <= tier.count then
            return tier.rate
        end
    end
    return 0.05 -- 兜底
end

---获取地段系数
---@param tier number
---@return number multiplier
local function getLocationMultiplier(tier)
    local multipliers = config.locationMultipliers or {
        [1] = 0.8, [2] = 1.0, [3] = 1.5, [4] = 2.0,
    }
    return multipliers[tier] or 1.0
end

---计算单套房产的周期税额
---@param housePrice number
---@param houseTier number
---@param houseCount number 该玩家总房产数
---@return number taxAmount
local function calculatePropertyTax(housePrice, houseTier, houseCount)
    local tierRate = getTieredRate(houseCount)
    local locationMult = getLocationMultiplier(houseTier)
    return math.floor(housePrice * tierRate * locationMult + 0.5)
end

-- ── 内部: 懒加载扣费 ──────────────────────────────────────────────────

---读取上次缴税时间
---@param citizenid string
---@param houseId string
---@return number|nil lastPaid (os.time) or nil
local function getLastTaxPaid(citizenid, houseId)
    -- 从 player_houses 表的 metadata JSON 列读取 (如果没有则尝试独立查询)
    -- fallback: 使用 player_houses 的 logout 列作为 proxy (存储上次登录时间)
    -- 最优: metadata 包含 last_tax_paid 字段
    local result = MySQL.scalar.await(
        [[SELECT JSON_UNQUOTE(JSON_EXTRACT(ph.metadata, '$.last_tax_paid'))
          FROM player_houses ph
          WHERE ph.citizenid = ? AND ph.house = ?]],
        { citizenid, houseId }
    )
    if result and result ~= '' and tonumber(result) then
        return tonumber(result)
    end
    return nil
end

---更新上次缴税时间
---@param citizenid string
---@param houseId string
---@param timestamp number
local function setLastTaxPaid(citizenid, houseId, timestamp)
    -- 尝试更新 metadata JSON
    local existing = MySQL.scalar.await(
        'SELECT metadata FROM player_houses WHERE citizenid = ? AND house = ?',
        { citizenid, houseId }
    )
    local meta = {}
    if existing then
        local ok, decoded = pcall(json.decode, existing)
        if ok and type(decoded) == 'table' then
            meta = decoded
        end
    end
    meta.last_tax_paid = timestamp

    MySQL.update(
        'UPDATE player_houses SET metadata = ? WHERE citizenid = ? AND house = ?',
        { json.encode(meta), citizenid, houseId }
    )
end

---获取连续欠费次数
---@param citizenid string
---@param houseId string
---@return number
local function getDelinquentCount(citizenid, houseId)
    local result = MySQL.scalar.await(
        [[SELECT JSON_UNQUOTE(JSON_EXTRACT(ph.metadata, '$.delinquent_count'))
          FROM player_houses ph
          WHERE ph.citizenid = ? AND ph.house = ?]],
        { citizenid, houseId }
    )
    return tonumber(result) or 0
end

---设置欠费次数
local function setDelinquentCount(citizenid, houseId, count)
    local existing = MySQL.scalar.await(
        'SELECT metadata FROM player_houses WHERE citizenid = ? AND house = ?',
        { citizenid, houseId }
    )
    local meta = {}
    if existing then
        local ok, decoded = pcall(json.decode, existing)
        if ok and type(decoded) == 'table' then
            meta = decoded
        end
    end
    meta.delinquent_count = count

    MySQL.update(
        'UPDATE player_houses SET metadata = ? WHERE citizenid = ? AND house = ?',
        { json.encode(meta), citizenid, houseId }
    )
end

---执行充公 (清空房产所有权)
---@param citizenid string
---@param houseId string
---@param houseName string
local function forecloseHouse(citizenid, houseId, houseName)
    MySQL.update(
        [[UPDATE player_houses SET citizenid = NULL, keyholders = '[]'
          WHERE citizenid = ? AND house = ?]],
        { citizenid, houseId }
    )

    MySQL.update(
        'UPDATE houselocations SET owned = 0 WHERE name = ?',
        { houseName }
    )

    -- 🔒 Security: citizenid 脱敏
    local maskedCid = citizenid:sub(1,4) .. "..." .. citizenid:sub(-4)
    print(('[PropertyTax] 🏚️ FORECLOSURE: %s lost house %s (%s)'):format(maskedCid, houseId, houseName))

    -- 触发充公事件 (供日志/通知)
    TriggerEvent('taxes:server:houseForeclosed', citizenid, houseId, houseName)
end

-- ── 公开 API: 登录时懒加载扣费 ────────────────────────────────────────

---处理单个玩家的房产税懒加载扣费
---@param source number 玩家 source
function ProcessPropertyTax(source)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    if not citizenid then return end

    local houses = getPlayerHouses(citizenid)
    if not houses or #houses == 0 then return end

    local houseCount = #houses
    local intervalHours = config.intervalHours or 72
    local intervalSeconds = intervalHours * 3600
    local now = os.time()
    local foreclosureThreshold = config.foreclosureThreshold or 3
    local taxDueTotal = 0
    local foreclosedAny = false

    for _, house in ipairs(houses) do
        local houseId = house.house
        local housePrice = tonumber(house.price) or 0
        local houseTier = tonumber(house.tier) or 1

        if housePrice > 0 then
            local lastPaid = getLastTaxPaid(citizenid, houseId)

            -- 首次购房或从未缴税: 从购房时间开始算 (默认当前时间)
            if not lastPaid then
                setLastTaxPaid(citizenid, houseId, now)
            else
                -- 计算经过了多少个计费周期
                local elapsedHours = (now - lastPaid) / 3600
                local cyclesDue = math.floor(elapsedHours / intervalHours)

                if cyclesDue > 0 then
                    local taxPerCycle = calculatePropertyTax(housePrice, houseTier, houseCount)
                    local totalDue = taxPerCycle * cyclesDue
                    taxDueTotal = taxDueTotal + totalDue

                    -- 尝试扣款
                    local playerMoney = Player.PlayerData.money['bank'] or 0

                    if playerMoney >= totalDue then
                        -- 足额扣款
                        if _G.Bus and _G.Bus.SinkService then
                            _G.Bus.SinkService.Withdraw(source, totalDue, 'housing_tax',
                                ('%s (cycles: %d)'):format(houseId, cyclesDue))
                        else
                            Player.Functions.RemoveMoney('bank', totalDue,
                                ('property_tax:%s'):format(houseId))
                        end

                        setLastTaxPaid(citizenid, houseId, now)
                        setDelinquentCount(citizenid, houseId, 0)

                        print(('[PropertyTax] %s paid $%d for %s (%d cycles × $%d)')
                            :format(citizenid, totalDue, houseId, cyclesDue, taxPerCycle))
                    else
                        -- 余额不足 → 递增欠费次数
                        local delinquent = getDelinquentCount(citizenid, houseId) + 1
                        setDelinquentCount(citizenid, houseId, delinquent)

                        if delinquent >= foreclosureThreshold then
                            -- 充公!
                            forecloseHouse(citizenid, houseId, house.label or houseId)
                            foreclosedAny = true
                        else
                            -- 通知玩家
                            local remaining = foreclosureThreshold - delinquent
                            TriggerClientEvent('QBCore:Notify', source,
                                ('⚠️ Property tax overdue for %s! $%d due. Foreclosure in %d cycles.')
                                    :format(house.label or houseId, totalDue, remaining),
                                'error')
                        end
                    end
                end
            end
        end
    end

    if taxDueTotal > 0 then
        TriggerClientEvent('QBCore:Notify', source,
            ('Property tax: $%d processed for %d house(s).'):format(taxDueTotal, houseCount),
            'primary')
    end

    if foreclosedAny then
        TriggerClientEvent('QBCore:Notify', source,
            '🏚️ One or more properties have been foreclosed due to unpaid taxes!', 'error')
    end
end

-- ── 生命周期 ──────────────────────────────────────────────────────────

-- 登录时懒加载
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local src = Player.PlayerData.source
    if not src then return end

    -- 延迟 3 秒，等玩家完全加载后再计算 (避免登录瞬间卡顿)
    SetTimeout(3000, function()
        ProcessPropertyTax(src)
    end)
end)

-- 管理员命令: 手动触发
RegisterCommand('proptax', function(source)
    local src = tonumber(source)
    if src <= 0 then return end
    ProcessPropertyTax(src)
    TriggerClientEvent('QBCore:Notify', src, 'Property tax processed (manual)', 'success')
end, true)

print('[PropertyTax] ✅ 房产税懒加载系统已启动')
print('[PropertyTax]   策略: Lazy Evaluation on login | 阶梯税率 × 地段系数 | 欠费3次充公')
