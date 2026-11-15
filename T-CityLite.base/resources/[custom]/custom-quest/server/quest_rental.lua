-- server/quest_rental.lua — 租借原语（押金 / 计租 / 关闭 / 重启补退）
--
-- 为什么需要它（2026-11-14 调研结论）：
--   成熟职业脚本（garbage / tow / trucker / hotdog）全部是「取货时扣押金 → 干活 → 回到
--   固定点结算 → 退押金」。我们之前只有物流那半套：扣钱靠租赁行、任务这边只记一个绑定，
--   而且失败/放弃/断线都没有关闭路径（三个 bug，已在 fix/logistics-binding-lifecycle 修）。
--   这里把它做成**会话**：一个玩家同一条任务只能有一个，每条关闭路径都要退或没收，且幂等。
--
-- 职责边界（重要）：
--   * 本文件只管「押金、计时、退款额」这三件事，**不发钱给玩家以外的东西**，
--     不生成实体、不发网络事件、不碰任务进度。
--   * 钱的进出只走 Player.Functions.RemoveMoney / AddMoney（宪法：钱只走 Player.Functions）。
--   * 会话是内存态；重启后靠 quest_event_log 的两条最小日志（open / close）恢复：
--     启动时扫「有 open 无 close」→ 记进待退队列 → 玩家**下次登录**时补退。
--     离线玩家不给钱：没有合法的写入路径（跨 owner 写 players 表会破坏表所有权）。

QuestRental = QuestRental or {}

-- 内部状态：citizenid → session
local Sessions = {}
-- 待退押金：citizenid → { amount, questId, since, reason }
local PendingRefunds = {}

--- 计费与退款的计算结果（纯函数，测试要能直接喂数字）
---@class RentalReceipt
---@field minutes number   计费分钟数（已扣掉免租期、已封顶）
---@field rent number      租金总额
---@field refund number    应退给玩家的金额
---@field capped boolean   是否撞到了 max_minutes 上限

--- 计算账单：超过免租期才开始计费，按「满分钟」向上取整，封顶 max_minutes。
--- 用向上取整是因为玩家侧体验：59 秒按 1 分钟算，比按 0 分钟算更不容易被钻空子。
---@param session table 会话（含 startedAt / deposit / ratePerMin / graceSec / maxMinutes）
---@param now number 当前时间（os.time）
---@return RentalReceipt
function QuestRental.ComputeReceipt(session, now)
    local elapsed = math.max(0, (now or os.time()) - (session.startedAt or 0))
    local grace = tonumber(session.graceSec) or 0
    local billable = math.max(0, elapsed - grace)
    local minutes = math.ceil(billable / 60)
    local maxMinutes = tonumber(session.maxMinutes) or 0
    local capped = false
    if maxMinutes > 0 and minutes > maxMinutes then
        minutes = maxMinutes
        capped = true
    end
    local rate = tonumber(session.ratePerMin) or 0
    local rent = minutes * rate
    local deposit = tonumber(session.deposit) or 0
    -- 押金不足抵扣租金时退款为 0，绝不倒扣玩家余额（差额由调用方决定是否追缴）
    local refund = math.max(0, deposit - rent)
    return { minutes = minutes, rent = rent, refund = refund, capped = capped }
end

--- 取玩家的活跃会话
---@param citizenid string
---@return table|nil
function QuestRental.Get(citizenid)
    return Sessions[citizenid]
end

--- 是否已有未关闭会话
---@param citizenid string
---@return boolean
function QuestRental.IsOpen(citizenid)
    return Sessions[citizenid] ~= nil
end

--- 待退押金（登录时补退用）
---@param citizenid string
---@return table|nil
function QuestRental.GetPendingRefund(citizenid)
    return PendingRefunds[citizenid]
end

--- 开租：校验 → 扣押金 → 记会话 → 写 open 日志。
--- 任何一步失败都不留下半开状态（先扣钱后写会话，扣钱失败直接返回）。
---@param player table QBCore 的 Player 对象（要有 PlayerData.citizenid 与 Functions）
---@param questId string
---@param nodeId string
---@param cfg table { deposit, rate_per_min, grace_sec, max_minutes }
---@return boolean ok
---@return string|table reasonOrSession
function QuestRental.Open(player, questId, nodeId, cfg)
    if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then
        return false, 'no_player'
    end
    local citizenid = player.PlayerData.citizenid
    if type(citizenid) ~= 'string' or citizenid == '' then
        return false, 'no_citizenid'
    end
    if Sessions[citizenid] then
        return false, 'already_open'
    end

    cfg = cfg or {}
    local deposit = math.max(0, math.floor(tonumber(cfg.deposit) or 0))
    local now = tonumber(cfg.now) or os.time()

    if deposit > 0 then
        local ok, err = player.Functions.RemoveMoney('bank', deposit, 'quest-rental-deposit')
        if not ok then
            -- qb-core 的 RemoveMoney 在余额不足时返回 false；不同版本第二个返回值可能是 nil
            return false, 'not_enough_deposit: ' .. tostring(err or deposit)
        end
    end

    local session = {
        citizenid = citizenid,
        questId = questId,
        nodeId = nodeId,
        startedAt = now,
        deposit = deposit,
        ratePerMin = math.max(0, tonumber(cfg.rate_per_min) or 0),
        graceSec = math.max(0, tonumber(cfg.grace_sec) or 0),
        maxMinutes = math.max(0, tonumber(cfg.max_minutes) or 0),
    }
    Sessions[citizenid] = session

    -- 会话必须先落日志，再算「开好了」：日志里没有这条 open，服务器重启后扫描不到，
    -- 押金就永远退不回来。所以这里按「先扣钱 → 写日志 → 写失败就原路退回」的顺序，
    -- 并把 started_at 一起写进去（重启补退要靠它和 close 精确配对）。
    local function rollbackJournal()
        Sessions[citizenid] = nil
        if deposit > 0 then
            player.Functions.AddMoney('bank', deposit, 'quest-rental-rollback')
        end
        print(('[quest-rental] ⚠️ rental_open 落库失败，押金 $%s 已原路退回（%s / %s）')
            :format(tostring(deposit), tostring(citizenid), tostring(questId)))
    end

    if QuestDB and QuestDB.LogRentalEvent then
        QuestDB.LogRentalEvent(citizenid, questId, 'rental_open', nodeId, {
            deposit = session.deposit,
            rate_per_min = session.ratePerMin,
            grace_sec = session.graceSec,
            max_minutes = session.maxMinutes,
            started_at = session.startedAt,
        }, function(ok)
            if not ok then rollbackJournal() end
        end)
    else
        -- 没有 DB 层就当作「写不进去」处理：宁可不开租，也不要收一笔查不到的钱
        rollbackJournal()
        return false, 'journal_unavailable'
    end

    return true, session
end

--- 关租：算账 → 退款 → 清会话 → 写 close 日志。幂等：没有会话时返回 ok（reason='no_session'）。
---@param player table
---@param reason string 'returned' | 'abandoned' | 'failed' | 'dropped' | 'timeout'
---@param now number|nil
---@return boolean ok
---@return table result { refund, rent, minutes, idempotent }
---@param player table
---@param reason string
---@param now number|nil
---@param questId string|nil 只关这条任务的会话；传了但与会话不符时不关（见下）
function QuestRental.Close(player, reason, now, questId)
    if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then
        return false, { reason = 'no_player' }
    end
    local citizenid = player.PlayerData.citizenid
    local session = Sessions[citizenid]
    if not session then
        -- 幂等：重复关闭不重复退钱，也不报错（调用方可能是「失败」+「断线」两条路径同时触发）
        return true, { refund = 0, rent = 0, minutes = 0, idempotent = true, reason = reason }
    end
    -- 玩家身上只有**一个**会话，但结束的可能是另一条任务：
    -- 传了 questId 就对一下，不符时不要动它（否则 A 任务结束会把 B 任务的押金结掉）。
    if questId and session.questId and session.questId ~= questId then
        return true, { refund = 0, rent = 0, minutes = 0, idempotent = true, reason = 'quest_mismatch' }
    end

    local receipt = QuestRental.ComputeReceipt(session, now or os.time())
    if receipt.refund > 0 then
        player.Functions.AddMoney('bank', receipt.refund, 'quest-rental-refund')
    end

    Sessions[citizenid] = nil

    if QuestDB and QuestDB.LogEvent then
        QuestDB.LogRentalEvent(citizenid, session.questId, 'rental_close', session.nodeId, {
            reason = reason or 'unknown',
            minutes = receipt.minutes,
            rent = receipt.rent,
            refund = receipt.refund,
            capped = receipt.capped,
            started_at = session.startedAt,   -- 与 open 配对：同一任务多次租借也不会串
        })
    end

    return true, {
        refund = receipt.refund,
        rent = receipt.rent,
        minutes = receipt.minutes,
        capped = receipt.capped,
        idempotent = false,
        reason = reason,
    }
end

--- 断线时关租：此刻玩家实体已经不可用，**不能**直接 AddMoney（会写到已销毁的 Player 上）。
--- 所以算好应退金额塞进待退队列，等下次登录由 ClaimPendingRefund 补——与「重启」走同一条路径。
---@param citizenid string
---@param now number|nil
---@return boolean ok
---@return table result
function QuestRental.CloseOnDrop(citizenid, now)
    local session = Sessions[citizenid]
    if not session then
        return true, { refund = 0, rent = 0, minutes = 0, idempotent = true, reason = 'dropped' }
    end
    local receipt = QuestRental.ComputeReceipt(session, now or os.time())
    Sessions[citizenid] = nil
    if receipt.refund > 0 and not PendingRefunds[citizenid] then
        PendingRefunds[citizenid] = {
            amount = receipt.refund,
            rent = receipt.rent,
            questId = session.questId,
            since = now or os.time(),
            reason = 'dropped',
        }
    end
    if QuestDB and QuestDB.LogEvent then
        QuestDB.LogRentalEvent(citizenid, session.questId, 'rental_close', session.nodeId, {
            reason = 'dropped',
            started_at = session.startedAt,
            minutes = receipt.minutes,
            rent = receipt.rent,
            refund = receipt.refund,
            deferred = true,
        })
    end
    return true, { refund = receipt.refund, rent = receipt.rent, minutes = receipt.minutes, deferred = true }
end
--- 启动时把「有 open 无 close」的会话塞进待退队列。
--- 不在启动时转账：离线玩家没有合法写入路径；等他们下次登录由 ClaimPendingRefund 补。
---@param rows table[] 每行 { citizenid, quest_id, node_id, metadata(表), created_at(秒) }
---@param now number|nil 仅供测试注入「现在」
---@return number queued
function QuestRental.QueueUnclosedSessions(rows, now)
    local queued = 0
    local currentTime = now or os.time()
    for _, row in ipairs(rows or {}) do
        local cid = row.citizenid
        if type(cid) == 'string' and cid ~= '' and not Sessions[cid] and not PendingRefunds[cid] then
            local meta = row.metadata or {}
            -- oxmysql 有的版本把 LONGTEXT 原样返回成字符串，有的解成表；两种都要能跑，
            -- 否则补退会按 deposit=0 算出 0 元，还打一行「已排队」的成功日志。
            if type(meta) == 'string' then
                if type(json) == 'table' and json.decode then
                    local okDecode, decoded = pcall(json.decode, meta)
                    meta = (okDecode and type(decoded) == 'table') and decoded or {}
                else
                    meta = {}   -- 没有 json 库（离线探针）时当作空表，宁可少退也不要算错
                end
            end
            -- 重启时无法区分「玩家还在推着车」和「早就下线了」，一律按已用时长结算：
            -- 保守起见按 open 时记的 started_at 算到重启时刻。
            local fake = {
                startedAt = tonumber(meta.started_at) or tonumber(row.created_at) or currentTime,
                deposit = tonumber(meta.deposit) or 0,
                ratePerMin = tonumber(meta.rate_per_min) or 0,
                graceSec = tonumber(meta.grace_sec) or 0,
                maxMinutes = tonumber(meta.max_minutes) or 0,
            }
            local receipt = QuestRental.ComputeReceipt(fake, currentTime)
            PendingRefunds[cid] = {
                amount = receipt.refund,
                rent = receipt.rent,
                questId = row.quest_id,
                since = currentTime,
                reason = 'server_restart',
            }
            queued = queued + 1
        end
    end
    return queued
end

--- 玩家登录时补退。只发生一次：退完就把队列项删掉。
---@param player table
---@return number amount 实际补退的金额（没有待退返回 0）
function QuestRental.ClaimPendingRefund(player)
    if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return 0 end
    local citizenid = player.PlayerData.citizenid
    local pending = PendingRefunds[citizenid]
    if not pending then return 0 end
    PendingRefunds[citizenid] = nil

    local amount = math.max(0, math.floor(tonumber(pending.amount) or 0))
    if amount > 0 then
        player.Functions.AddMoney('bank', amount, 'quest-rental-restart-refund')
        -- 必须告诉玩家：这笔钱是「上次没结清」退回来的，不然他只会觉得银行多了个没来由的数字。
        local src = player.PlayerData and player.PlayerData.source
        if src then
            TriggerClientEvent('QBCore:Notify', src,
                ('💰 上次租借押金已退回银行：$%s'):format(tostring(amount)), 'success', 8000)
        end
    end
    if QuestDB and QuestDB.LogEvent then
        QuestDB.LogEvent(citizenid, pending.questId or 'unknown', 'rental_close', nil, {
            reason = 'server_restart',
            refund = amount,
            rent = pending.rent or 0,
            claimed_at = os.time(),
        })
    end
    return amount
end

--- 测试/运维用：清空内存态（不碰钱、不写库）
function QuestRental.Reset()
    Sessions = {}
    PendingRefunds = {}
end

-- ==============================================================
-- 接线：校验器 + 登录补退
-- ==============================================================

-- 步骤形状（配置侧）：
--   { id='step_rent', type='rental', data={ coords={...}, radius=3.0,
--       validator_id='validate_rental_open', validator_data={ deposit=250, rate_per_min=6,
--       grace_sec=60, max_minutes=60 } } }
-- 客户端把 rental 当 interact 处理（有 coords 就画交互点），推进走既有 nodeComplete 路径，
-- 因此**不需要新的 net event**。
local function validate_rental_open(source, stepData, questData)
    local Player = exports['qb-core']:GetPlayer(source)
    if not Player then return false, 'no_player' end

    local ok, sessionOrErr = QuestRental.Open(Player, questData.questId, stepData.nodeId or stepData.id, {
        deposit = stepData.deposit,
        rate_per_min = stepData.rate_per_min,
        grace_sec = stepData.grace_sec,
        max_minutes = stepData.max_minutes,
    })
    if not ok then
        local err = sessionOrErr
        if err == 'already_open' then
            return false, '你身上还有没结清的租借'
        elseif type(err) == 'string' and err:find('not_enough_deposit', 1, true) then
            return false, ('押金不足：需要 $%s'):format(tostring(stepData.deposit or 0))
        end
        return false, tostring(err)
    end
    return true, ('已扣押金 $%s'):format(tostring(sessionOrErr.deposit))
end

if QuestValidators and QuestValidators.Register then
    QuestValidators.Register('validate_rental_open', validate_rental_open)
    print('[quest-rental] ✅ validate_rental_open 已注册')
end

-- 登录补退：重启/断线留下的待退押金只在这里结清一次。
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if type(Player) ~= 'table' then return end
    local ok, amount = pcall(QuestRental.ClaimPendingRefund, Player)
    if ok and amount and amount > 0 then
        print(('[quest-rental] 💰 补退重启前押金 $%s → %s'):format(tostring(amount),
            tostring(Player.PlayerData and Player.PlayerData.citizenid)))
    end
end)

-- 启动扫描：上一次运行里「有 rental_open 没有 rental_close」的会话 → 塞进待退队列，等玩家下次登录补。
-- 这里只读日志、只写内存，不转账（离线玩家没有合法写入路径）。
CreateThread(function()
    Wait(3000)  -- 等 oxmysql 就绪；启动期抢跑会拿到空结果
    if not (QuestDB and QuestDB.FindUnclosedRentals) then return end
    QuestDB.FindUnclosedRentals(function(rows)
        local queued = QuestRental.QueueUnclosedSessions(rows or {})
        if queued > 0 then
            print(('[quest-rental] 🧾 发现 %d 个未关闭的租借会话 → 已排队等待玩家登录补退'):format(queued))
        end
    end)
end)
