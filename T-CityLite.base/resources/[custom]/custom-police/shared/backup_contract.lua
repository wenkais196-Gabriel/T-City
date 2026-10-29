-- shared/backup_contract.lua — 支援单位（SM-06）的结束原因白名单。
--
-- 为什么要有这个文件：结束原因是**服务端判定**的枚举，客户端只是"报告它看到了什么"。
-- 以前客户端只发 requestId，服务端无法回答"这个单位为什么结束"，指标全是空白；
-- 但一旦让客户端随便发字符串，又会把审计污染成自由文本。
--
-- 纯数据 + 纯函数（P0）：不碰 native、不发事件、不读 IO，服务端/客户端/golden 测试
-- 共用同一份，避免两边各写一份枚举然后慢慢漂移。
--
-- 用法：
--   BackupContract.NormalizeReason('timeout')      -> 'timeout'
--   BackupContract.NormalizeReason('whatever')     -> 'unknown'
--   BackupContract.NormalizeReason(nil)            -> 'unknown'
--   BackupContract.IsServerOnlyReason('expired')   -> true（客户端不得自报）

BackupContract = BackupContract or {}

--- 客户端可以上报的结束原因。
BackupContract.CLIENT_REASONS = {
    timeout = true,        -- 客户端寿命到（v2 之前由客户端自计时）
    dead = true,           -- 请求者死亡 / 玩家 ped 消失
    left = true,           -- 请求者离开场景超过阈值
    resource_stop = true,  -- 资源停止（客户端 / 服务端重启）
    spawn_failed = true,   -- 模型/实体创建失败
    vehicle_lost = true,   -- 载具丢失或司机无效
    no_alive_ped = true,   -- 两名 NPC 都没了
    dismissed = true,      -- 警官主动撤掉（/backup dismiss）
    escort_timeout = true, -- 90s 内没能开到请求者身边（P3）
}

--- 只允许服务端产生的原因（客户端自报会被归一成 unknown）。
BackupContract.SERVER_REASONS = {
    expired = true,        -- 服务端 sweep 判定超时
    unknown = true,        -- 兜底：客户端没给或给了白名单外的值
}

--- 归一化：白名单内原样返回，否则 'unknown'。长度上限 24，避免审计被长字符串撑爆。
---@param reason any
---@return string
function BackupContract.NormalizeReason(reason)
    if type(reason) ~= 'string' then return 'unknown' end
    local trimmed = reason:match('^%s*(.-)%s*$') or ''
    if trimmed == '' or #trimmed > 24 then return 'unknown' end
    if BackupContract.CLIENT_REASONS[trimmed] then return trimmed end
    -- 服务端自己产生的原因不经这条路径；客户端报上来的一律当 unknown。
    return 'unknown'
end

--- 服务端路径用：同时接受 CLIENT_REASONS 与 SERVER_REASONS。
---@param reason any
---@return string
function BackupContract.NormalizeServerReason(reason)
    local normalized = BackupContract.NormalizeReason(reason)
    if normalized ~= 'unknown' then return normalized end
    if type(reason) == 'string' and BackupContract.SERVER_REASONS[reason] then return reason end
    return 'unknown'
end

-- ---------------------------------------------------------------------------
-- 阶段（S2）
--
-- 阶段是**服务端记录的状态**，客户端只上报"我这边到了哪一步"。所以阶段序必须
-- 在服务端与 golden 测试共用同一份表：两边各写一份，迟早会一边加了 engaged
-- 另一边还停在 onscene，然后 ack 被当成"倒退"丢掉，看起来像客户端没发。
--
-- requested 是服务端入口阶段（客户端不会上报它），ended 由 backupEnded 走，
-- 都不在客户端可上报的集合里。
-- ---------------------------------------------------------------------------

--- 阶段序；数值只用于比较先后，不要持久化。
BackupContract.PHASES = {
    requested = 1,
    spawning = 2,
    enroute = 3,
    onscene = 4,
    engaged = 5,
    ended = 6,
}

--- 客户端可以随 backupAck 上报的阶段（requested / ended 不在其中）。
BackupContract.CLIENT_PHASES = {
    spawning = true,
    enroute = true,
    onscene = true,
    engaged = true,
}

--- 上报的实体数上限：一次支援就是 1 车 + 2 人，留一点余量给将来的变体。
BackupContract.MAX_ENTITY_COUNT = 8

--- 归一化客户端上报的阶段：不在 CLIENT_PHASES 里的一律 nil（调用方丢弃并计数）。
---@param phase any
---@return string|nil
function BackupContract.NormalizePhase(phase)
    if type(phase) ~= 'string' or #phase > 16 then return nil end
    if BackupContract.CLIENT_PHASES[phase] then return phase end
    return nil
end

--- 阶段序数值；未知阶段返回 nil。
---@param phase any
---@return number|nil
function BackupContract.PhaseRank(phase)
    if type(phase) ~= 'string' then return nil end
    return BackupContract.PHASES[phase]
end

--- 只允许"同一阶段重复上报"或"向前推进"：倒退（onscene → enroute）一律 false。
--- 重复上报要为真，因为客户端可能重连后重新报一次当前阶段，服务端当成幂等刷新。
---@param from string|nil
---@param to string|nil
---@return boolean
function BackupContract.CanAdvance(from, to)
    local toRank = BackupContract.PhaseRank(to)
    if not toRank then return false end
    local fromRank = BackupContract.PhaseRank(from)
    if not fromRank then return false end
    return toRank >= fromRank
end

-- ---------------------------------------------------------------------------
-- 任务门控（S5）
--
-- 之前是"每 2.5 秒无条件重发一次 Task*"。两个问题：
--   1. 任务正在执行时重发是白花帧（TaskVehicleDriveToCoord 每次都会重建路径）；
--   2. 反过来，任务被别的系统（ClearPedTasks、上车、被击倒）清掉后，
--      下一次重发最多要等 2.5 秒，表现是"支援车停在原地发呆"。
-- GetScriptTaskStatus 让客户端能区分这两种情况：正在执行 → 只按心跳兜底重发；
-- 空闲/已完成/不可知 → 立刻重发。
-- ---------------------------------------------------------------------------

--- GetScriptTaskStatus 的返回码（官方枚举：1 performing / 3 vacant / 7 finished）。
BackupContract.TASK_STATUS = {
    performing = 1,
    vacant = 3,
    finished = 7,
}

--- 是否需要重新下发任务。
---
--- 判定是纯函数，客户端只负责把 native 的返回值传进来 —— 这样 golden 用例
--- 能覆盖三态（1/3/7）与"不可知"，不必去 stub 整车实体。
---
---@param status any GetScriptTaskStatus 的返回值（未知任务哈希会回 0）
---@param sinceMs number|nil 上次下发时刻（GetGameTimer 口径）
---@param nowMs number 当前时刻
---@param heartbeatMs number 即使正在执行，超过这个时长也重发一次（任务可能被别处清掉）
---@return boolean
function BackupContract.ShouldRetask(status, sinceMs, nowMs, heartbeatMs)
    local now = tonumber(nowMs) or 0
    local since = tonumber(sinceMs) or 0
    local heartbeat = tonumber(heartbeatMs) or 0

    -- 不可知（缺 native、未知任务哈希、拿到 nil）：按"该重发"处理。
    -- 重复下发一个同样的任务代价很小，卡在原地不动的代价很大。
    local code = tonumber(status)
    if not code or code == 0 then return true end

    if code == BackupContract.TASK_STATUS.performing then
        -- 正在执行：心跳兜底，别每帧重建路径。
        return heartbeat <= 0 or (now - since) >= heartbeat
    end

    -- vacant / finished / 其它异常码：任务已经不在跑了，立刻补。
    return true
end
