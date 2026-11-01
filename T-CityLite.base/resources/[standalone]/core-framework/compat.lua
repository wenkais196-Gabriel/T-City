-- compat.lua — core-framework 剩下的**唯一**兼容层：QBCore.Functions.Notify
-- （GetPlayer / AddMoney 的猴补已在 P1-4 阶段 B/C 删除，见各自位置的说明）
--
-- P1-4 阶段 D 会把这一层也删掉，届时本文件整体下线。

local QBCore = exports['qb-core']:GetCoreObject()
local compatStats = { shimmed_count = 0, fallback_count = 0 }

-- =============================================================
-- Player.Functions.AddMoney —— **不再打补丁**
-- =============================================================
-- 2026-11-01（P1-4 阶段 C）：整段删除，**一行不修**。它今天本来就是死代码：
--   * `_G.Bus.EconomyService` 是 qb-core 在自己状态里注册的；FiveM 每个资源一个 Lua 状态，
--     `_G` 不跨资源 —— core-framework 这边 `_G.Bus.EconomyService` 恒为 nil，ES 分支整段跳过；
--   * 即便可见，`pcall(ES.AddMoney, ES, ...)` 多传了一个 `ES`，而 qb-core 的 ES 是 dot 定义
--     （签名 `(citizenid, moneytype, amount, reason)`）→ 参数整体错位，`tonumber('cash')` 为 nil → 恒 false；
--   * 即便传参正确，本文件的形参是 `function(self, moneytype, amount, reason)`，而全仓 60 处调用点
--     都是 3 参 dot 调用 → `self = 'cash'`，`self.PlayerData` 为 nil → 每个加钱点直接 SCRIPT ERROR。
-- 所以"修好再删"才是危险动作：修好会把这些错位从死代码变成生产故障，或者让 pcall 回落与原函数
-- 都调一次 ES → 双倍加钱。qb-core 的 player.lua 本来就已经路由 `_G.Bus.EconomyService`。

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
