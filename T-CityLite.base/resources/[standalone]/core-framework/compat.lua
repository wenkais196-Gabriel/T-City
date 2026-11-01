-- compat.lua — 向后兼容层
-- 确保旧版 QBCore.Functions 调用在所有模块迁移到新 Service 前仍然可用
--
-- 工作原理:
--   1. 劫持 QBCore.Player 的 Functions 方法
--   2. 直接路由到 Bus.EconomyService（内存优先 + DirtyFlush 管道）
--   3. Bus.EconomyService 不可用时 fallback 到原始逻辑
--   4. 输出统计日志（不中断流程）
--
-- 调用链 (简化后):
--   Player.Functions.AddMoney → Bus.EconomyService.AddMoney → 内存操作 → DirtyFlush
--   （原 triple-hop: compat → custom-main:AddScaledMoney(不存在) → fallback → origAddMoney → Bus.EconomyService）

local QBCore = exports['qb-core']:GetCoreObject()
local compatStats = { shimmed_count = 0, fallback_count = 0 }

-- 在 QBCore.Player 创建后自动包装方法
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local cid = Player.PlayerData.citizenid

    -- 保存原始 AddMoney (已在 player.lua 中路由到 Bus.EconomyService)
    local origAddMoney = Player.Functions.AddMoney

    -- 包装 AddMoney: 直连 Bus.EconomyService，跳过不复存在的 custom-main:AddScaledMoney
    Player.Functions.AddMoney = function(self, moneytype, amount, reason)
        reason = reason or 'unknown'

        -- 优先走 Bus.EconomyService (内存优先，单跳直达)
        local ES = _G.Bus and _G.Bus.EconomyService
        if ES then
            local ok, result = pcall(ES.AddMoney, ES, self.PlayerData.citizenid, moneytype, amount, reason)
            if ok and result then
                compatStats.shimmed_count = compatStats.shimmed_count + 1
                return true
            end
        end

        -- fallback: 走原始逻辑 (player.lua 中已内置 EconomyService 路由)
        compatStats.fallback_count = compatStats.fallback_count + 1
        return origAddMoney(self, moneytype, amount, reason)
    end

    -- 输出首次路由提示（仅一次）
    if compatStats.shimmed_count + compatStats.fallback_count == 0 then
        print(('[compat] 🔄 Player.Functions.AddMoney → Bus.EconomyService routing active for %s'):format(cid))
    end
end)

-- 每 10 分钟打印兼容层统计
CreateThread(function()
    while true do
        Wait(10 * 60 * 1000)
        local total = compatStats.shimmed_count + compatStats.fallback_count
        if total > 0 then
            local pct = math.floor(compatStats.shimmed_count / total * 100)
            print(('[compat] 📊 兼容层统计: %d 次调用, %d%% 直连 Bus.EconomyService, %d 次 fallback'):format(
                total, pct, compatStats.fallback_count
            ))
        end
    end
end)

-- =============================================================
-- QBCore.Functions.GetPlayer —— **不再打补丁**
-- =============================================================
-- 2026-11-01（P1-4 阶段 B）：删掉这里原来的 playerCache + GetPlayerName 活性校验。
-- 三个理由：
--   1. qb-core 的 GetPlayer 本来就是 `QBCore.Players[tonumber(source)]` 一次表查，
--      套一层缓存命中时反而多一次 native 调用（GetPlayerName），未命中时是"两次查表 + 一次 native"；
--   2. 缓存不清登出：`QBCore.Player.Logout` → `OnPlayerUnload` → 200ms 后才把 Players[src] 置 nil，
--      而这里没监听 OnPlayerUnload，停在选人界面的玩家会被返回**已登出**的 Player 表
--      （`if not Player then return end` 全线失效）；
--   3. 本资源重启后旧的 funcref 留在 qb-core 的表里，新实例再包一层 → 悬空引用 + 叠层。
-- 需要按 source 查玩家 / 判在线，用 qb-core 的 GetPlayer + 自己判 GetPlayerName。

-- =============================================================
-- QBCore.Functions.Notify 桥接 → Bus.notify 服务
-- =============================================================
local origNotifyFn = QBCore.Functions.Notify

function QBCore.Functions.Notify(source, text, type, length)
    -- 优先走 Bus.notify (含限流 + Source校验 + 内容清洗)
    local notifySvc = _G.Bus and _G.Bus.notify
    if notifySvc and notifySvc.Send then
        compatStats.shimmed_count = compatStats.shimmed_count + 1
        return notifySvc.Send(source, text, type, length)
    end

    -- 回退到原始实现 (已有五层安全校验)
    compatStats.fallback_count = compatStats.fallback_count + 1
    return origNotifyFn(source, text, type, length)
end

-- compat startup prints removed (production mode)
