-- server/quest_minigame.lua — 小游戏原语的服务端内核（热狗线 S3）
--
-- 为什么要有这一层：qb-minigames 的 KeyMinigame 只回 `{ quit, faults }`，
-- 客户端能编的也只有这两个字段。品质必须由服务端按 faults 映射成**物品 id**，
-- 否则就会重演上游热狗「客户端传 quality 字符串、服务端照单全收」的坑
-- （docs/plan/jobs-content/08-mature-scripts-survey.md §8.1）。
--
-- 本文件只做四件事：发 nonce、验 nonce、映射产出、清理会话。
-- 不注册 net event、不写库、不发网络事件、不碰钱与库存 —— 接线方拿到 Resolve
-- 的结果后再决定扣原料/发物品，产出路径只有一条，审计也只需要看一处。
--
-- 测试：tests/unit/layer3_business/fixtures/minigame_probe.lua 通过本文件里的
-- 标记块抽真实实现来跑；反向校验见同名 pytest。
-- 时间注入：Start 支持 config.now；测试也可设置 QuestMinigame._now（数字或函数），
-- 这样「过期」不用 sleep，也不会让测试依赖真实时间。

-- [quest-minigame] begin
QuestMinigame = QuestMinigame or {}

--- 未结算会话：nonce → session
local Sessions = {}
--- 已消费 nonce 的墓碑：nonce → 原 expiresAt。
--- 留墓碑是为了让重复上报返回 already_used 而不是 unknown_nonce，
--- 排查时能分清「重放」和「服务端根本没见过这个 nonce」。
local Used = {}
--- 同一玩家同一节点的打开索引：citizenid + questId + nodeId 拼成的键 → nonce。
--- 有它才能在 Start 时 O(1) 判 already_open，不必遍历所有会话。
local OpenByNode = {}

local DEFAULT_TTL = 30
local DEFAULT_MAX_FAULTS = 10
local DEFAULT_COUNT = 1

--- 统一取时间。测试把 _now 设成数字或函数即可冻结时钟；
--- 生产环境 _now 为 nil，回落到 os.time()。
---@return number
function QuestMinigame.Now()
    local injected = QuestMinigame._now
    if type(injected) == 'function' then
        local value = tonumber(injected())
        if value then return value end
    elseif type(injected) == 'number' then
        return injected
    end
    return os.time()
end

local function nodeKey(citizenid, questId, nodeId)
    -- 用不可见分隔符而不是 ':'：questId/nodeId 里未来可能出现冒号，
    -- 拼键碰撞会让两个节点互相挡住。
    return tostring(citizenid) .. '\31' .. tostring(questId) .. '\31' .. tostring(nodeId)
end

--- 校验并复制配置。
--- 复制而不是直接引用：配置表常被多个任务共享，调用方之后改表不能影响已开的会话。
---@return table|nil
local function normalizeConfig(config)
    if type(config) ~= 'table' then return nil end

    local ttl = config.ttl_sec
    if ttl == nil then ttl = DEFAULT_TTL end
    ttl = tonumber(ttl)
    if not ttl or ttl <= 0 then return nil end

    local maxFaults = config.max_faults
    if maxFaults == nil then maxFaults = DEFAULT_MAX_FAULTS end
    maxFaults = tonumber(maxFaults)
    if not maxFaults or maxFaults < 0 or maxFaults % 1 ~= 0 then return nil end

    local count = config.count
    if count == nil then count = DEFAULT_COUNT end
    count = tonumber(count)
    if not count or count < 0 or count % 1 ~= 0 then return nil end

    local sourceTiers = config.tiers
    if type(sourceTiers) ~= 'table' then return nil end

    local tiers = {}
    for _, entry in ipairs(sourceTiers) do
        if type(entry) ~= 'table'
            or type(entry.tier) ~= 'string' or entry.tier == ''
            or type(entry.item) ~= 'string' or entry.item == '' then
            return nil
        end
        local tierMax = tonumber(entry.max_faults)
        if not tierMax or tierMax < 0 or tierMax % 1 ~= 0 then return nil end
        tiers[#tiers + 1] = { max_faults = tierMax, tier = entry.tier, item = entry.item }
    end
    if #tiers == 0 then return nil end

    -- 调用方可能写反顺序；排序后「匹配第一个 max_faults >= faults」才稳定。
    table.sort(tiers, function(a, b) return a.max_faults < b.max_faults end)

    -- 这里不强制「最高档覆盖 max_faults」：档位怎么分是调用方的玩法配置，
    -- 只写 0/1/2 三档也应该能开局；真出现无档可落时 Resolve 返回 no_tier，
    -- 由调用方当作配置 bug 记日志，而不是让玩家在 Start 就被拒。
    return { ttl_sec = ttl, tiers = tiers, count = count, max_faults = maxFaults }
end

local nonceCounter = 0

--- 生成一次性 nonce。
--- 不追求密码学强度：它的作用是「把这次上报绑定到这次开始」，
--- 真正的防伪靠服务端映射与 citizenid 归属校验；但也不能可枚举，
--- 所以混入进程内计数与两个随机数，保证同一毫秒内多次开也唯一。
local function newNonce(now)
    nonceCounter = nonceCounter + 1
    local a = math.random(0, 0x7fffffff)
    local b = math.random(0, 0x7fffffff)
    return ('%s-%x-%x-%x'):format(tostring(math.floor(now)), nonceCounter, a, b)
end

--- 消费 nonce：删会话 + 留墓碑 + 清节点索引。
--- Resolve 里没有 Wait，Lua 服务端又只有一个线程，这三个动作不会被别的请求插队。
local function consume(nonce, session)
    Sessions[nonce] = nil
    Used[nonce] = session.expiresAt
    if OpenByNode[session.nodeKey] == nonce then
        OpenByNode[session.nodeKey] = nil
    end
end

--- 开一次小游戏会话。成功返回 nonce；失败返回 nil, 错误码。
---@param citizenid string
---@param questId string
---@param nodeId string
---@param config table { ttl_sec, tiers, count, max_faults?, now? }
---@return string|nil nonce
---@return string|nil err
function QuestMinigame.Start(citizenid, questId, nodeId, config)
    if citizenid == nil or questId == nil or nodeId == nil then
        return nil, 'bad_args'
    end

    local normalized = normalizeConfig(config)
    if not normalized then return nil, 'bad_config' end

    local now = tonumber(config.now) or QuestMinigame.Now()
    local key = nodeKey(citizenid, questId, nodeId)

    local existingNonce = OpenByNode[key]
    if existingNonce then
        local existing = Sessions[existingNonce]
        if existing and now < existing.expiresAt then
            -- 同一节点只允许一个未结算会话：防止并发开两个小游戏，
            -- 再用其中一次完美成绩顶掉另一次的结果。
            return nil, 'already_open'
        end
        -- 过期却没上报（玩家 Esc 后客户端崩了）不能让节点永久锁死：
        -- 这里顺手回收，定时 Sweep 只是兜底，不负责解锁。
        if existing then Sessions[existingNonce] = nil end
        OpenByNode[key] = nil
    end

    local nonce
    repeat
        nonce = newNonce(now)
    until not Sessions[nonce] and not Used[nonce]

    Sessions[nonce] = {
        citizenid = citizenid,
        questId = questId,
        nodeId = nodeId,
        startedAt = now,
        expiresAt = now + normalized.ttl_sec,
        config = normalized,
        nodeKey = key,
    }
    OpenByNode[key] = nonce
    return nonce
end

--- faults 是客户端唯一能编的数字，必须严格校验：
--- 字符串/负数/超上限/小数/NaN 全部视为非法，不给「四舍五入成 0 失误」的空间。
local function isBadFaults(faults, maxFaults)
    if type(faults) ~= 'number' then return true end
    if faults ~= faults then return true end                       -- NaN
    if faults == math.huge or faults == -math.huge then return true end
    if faults < 0 or faults > maxFaults then return true end
    if faults % 1 ~= 0 then return true end
    return false
end

--- 按 max_faults 升序找第一个接得住 faults 的档位。
local function matchTier(tiers, faults)
    for _, entry in ipairs(tiers) do
        if faults <= entry.max_faults then
            return entry
        end
    end
    return nil
end

--- 结算一次小游戏。成功返回 true, { tier, item, count, faults }；
--- 主动退出返回 true, { quit = true }（不产出、不扣原料由调用方处理）。
---@param citizenid string
---@param nonce string
---@param payload table { quit = boolean, faults = number }
---@return boolean|nil ok
---@return table|string result 成功时是结果表，失败时是错误码
function QuestMinigame.Resolve(citizenid, nonce, payload)
    if type(nonce) ~= 'string' or nonce == '' then
        return nil, 'unknown_nonce'
    end

    local session = Sessions[nonce]
    if not session then
        if Used[nonce] then return nil, 'already_used' end
        return nil, 'unknown_nonce'
    end

    -- 先验归属再消费：nonce 万一泄露，别人也不能靠一次错误上报把它烧掉
    -- （那会变成「知道 nonce 就能让对方的这份热狗作废」的拒绝服务）。
    if tostring(session.citizenid) ~= tostring(citizenid) then
        return nil, 'wrong_owner'
    end

    if QuestMinigame.Now() >= session.expiresAt then
        -- 过期也是一次消费：否则同一个 nonce 可以在超时后反复试探。
        consume(nonce, session)
        return nil, 'expired'
    end

    if type(payload) ~= 'table' then payload = {} end

    if payload.quit == true then
        consume(nonce, session) -- 退出也消耗：同一 nonce 不能反复「退出→重开」试探
        return true, { quit = true }
    end

    local faults = payload.faults
    if isBadFaults(faults, session.config.max_faults) then
        -- 非法上报同样消耗：不能让它变成「这次不算，重报一次」的免费重试。
        consume(nonce, session)
        return nil, 'bad_faults'
    end
    faults = math.tointeger(faults) or faults

    local matched = matchTier(session.config.tiers, faults)
    -- 成功路径也先消费再返回：任何一次 Resolve 都不允许留下可重放的会话。
    consume(nonce, session)
    if not matched then
        return nil, 'no_tier'
    end

    return true, {
        tier = matched.tier,
        item = matched.item,
        count = session.config.count,
        faults = faults,
    }
end

--- 任务终结（完成/放弃/失败）时清掉该节点的未结算会话。幂等。
---@return boolean removed 之前确实有会话时为 true
function QuestMinigame.Cancel(citizenid, questId, nodeId)
    local key = nodeKey(citizenid, questId, nodeId)
    local nonce = OpenByNode[key]
    if not nonce then return false end

    OpenByNode[key] = nil
    -- 不写墓碑：Cancel 之后这个 nonce 本来就该彻底失效，迟到上报拿
    -- unknown_nonce 与 already_used 的效果一样（都拒绝），没必要为它留内存。
    Sessions[nonce] = nil
    return true
end

--- 清理已过期的未结算会话，返回清掉的条数。
--- 定时器兜底用：玩家断线或被踢时不会走 Cancel，内存需要这条出口。
---@param now number|nil
---@return number removed
function QuestMinigame.Sweep(now)
    now = tonumber(now) or QuestMinigame.Now()

    local removed = 0
    for nonce, session in pairs(Sessions) do
        if now >= session.expiresAt then
            Sessions[nonce] = nil
            if OpenByNode[session.nodeKey] == nonce then
                OpenByNode[session.nodeKey] = nil
            end
            removed = removed + 1
        end
    end

    -- 墓碑只留到原过期时间：之后再上报本来就是拒绝，unknown_nonce 与
    -- already_used 对玩家没有区别，留着反而让内存随游戏次数线性涨。
    for nonce, expiresAt in pairs(Used) do
        if now >= expiresAt then Used[nonce] = nil end
    end

    return removed
end
-- [quest-minigame] end

print('[quest-minigame] ready')
