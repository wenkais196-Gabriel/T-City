-- mock_events.lua — T-City Lite 单人模式模拟工具
-- 在 SinglePlayerMode = true 时，用服务端 Lua 模拟多角色交互
--
-- 不需要真人客户端登录即可测试"2 名警察在线才能抢劫"这类逻辑

Mock = Mock or {}

-- 模拟玩家表
Mock._players = {}

-- ─── 模拟玩家管理 ───

--- 创建一个模拟玩家
---@param id string 标识符（如 "罪犯A", "警察B"）
---@param data table 玩家数据覆盖 {job, onduty, citizenid, cash, bank}
---@return table 模拟玩家对象
function Mock.createPlayer(id, data)
    data = data or {}
    local player = {
        source = -10000 - #Mock._players,  -- 用负数 source 表示模拟玩家
        name = id,
        state = {
            citizenid = data.citizenid or ("MOCK_" .. #Mock._players + 1),
            job = data.job or "unemployed",
            job_grade = data.job_grade or 0,
            onduty = data.onduty ~= false,  -- 默认上班
            cash = data.cash or 5000,
            bank = data.bank or 2000,
            gang = data.gang or "none",
            metadata = data.metadata or {},
        }
    }
    Mock._players[id] = player
    print(("[mock] ✅ 创建模拟玩家 '%s' (job=%s, onduty=%s)"):format(
        id, player.state.job, player.state.onduty))
    return player
end

--- 获取模拟玩家
function Mock.getPlayer(id)
    return Mock._players[id]
end

--- 删除模拟玩家
function Mock.removePlayer(id)
    Mock._players[id] = nil
    print(("[mock] 🗑️ 删除模拟玩家 '%s'"):format(id))
end

--- 清空所有模拟玩家
function Mock.clearAll()
    Mock._players = {}
    print("[mock] 🗑️ 清空所有模拟玩家")
end

-- ─── 状态控制 ───

--- 设置在岗警察人数（快速创建/移除警察模拟玩家）
---@param count number 需要的在岗警察数量
function Mock.setPoliceOnDuty(count)
    -- 先清除现有警察
    for id, player in pairs(Mock._players) do
        if player.state.job == "police" then
            Mock._players[id] = nil
        end
    end
    -- 创建新警察
    for i = 1, count do
        Mock.createPlayer(("警察%d号"):format(i), {
            job = "police",
            onduty = true,
            job_grade = 1,
        })
    end
    print(("[mock] 👮 在岗警察人数设为: %d"):format(count))
end

-- ─── 查询模拟数据 ───

--- 计算在岗警察数量（模拟 + 真人）
---@param source number|nil 请求者 source（可选）
---@return number
function Mock.getOnDutyPoliceCount(source)
    local count = 0

    -- 统计模拟玩家
    for _, player in pairs(Mock._players) do
        if player.state.job == "police" and player.state.onduty then
            count = count + 1
        end
    end

    -- 统计真人玩家（当前在线，通过 QBCore 遍历）
    if QBCore then
        for _, playerId in ipairs(QBCore.Functions.GetPlayers()) do
            local Player = QBCore.Functions.GetPlayer(playerId)
            if Player and Player.PlayerData.job.name == 'police' and Player.PlayerData.job.onduty then
                count = count + 1
            end
        end
    end

    return count
end

--- 获取模拟概览
function Mock.summary()
    print("[mock] 当前模拟玩家:")
    if next(Mock._players) == nil then
        print("  (无)")
        return
    end
    for id, player in pairs(Mock._players) do
        print(("  %s → job=%s, onduty=%s"):format(id, player.state.job, player.state.onduty))
    end
end

-- ─── 初始化 ───
print("[mock] ✅ 模拟工具已加载（单人模式可用）")
