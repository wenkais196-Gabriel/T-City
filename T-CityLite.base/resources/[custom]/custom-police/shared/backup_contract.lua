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
