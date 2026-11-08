local QBCore = exports['qb-core']:GetCoreObject()

-- 老板权限的唯一判定入口（闸门按 net_event_guard_helpers.json 登记，
-- 调用点必须是 `if not IsJobBoss(Player) then ... return end` 形状）
local function IsJobBoss(Player)
	if Player and Player.PlayerData and Player.PlayerData.job and Player.PlayerData.job.isboss == true then
		return true
	end
	return false
end

-- 🔧 安全审计：不再永久封禁，改为记录 + 通知
local function SecurityAuditLog(src, action, detail)
	local playerName = GetPlayerName(src)
	print(('[SECURITY-MANAGEMENT] %s (src=%s) attempted %s — %s'):format(playerName, src, action, detail))
	TriggerEvent('qb-log:server:CreateLog', 'bossmenu', 'Suspicious Activity', 'orange',
		string.format('%s (src=%s) attempted %s: %s', playerName, src, action, detail), false)
	TriggerClientEvent('QBCore:Notify', src, '你没有权限执行此操作', 'error')
end

-- Get Employees
QBCore.Functions.CreateCallback('qb-bossmenu:server:GetEmployees', function(source, cb, jobname)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)

	if not IsJobBoss(Player) then
		SecurityAuditLog(src, 'GetEmployees', '非 Boss 尝试获取员工列表')
		return
	end

	local employees = {}

	-- 🔒 Security Fix: 参数化查询替代字符串拼接，消除 SQL 注入风险
	local players = MySQL.query.await('SELECT * FROM players WHERE JSON_UNQUOTE(JSON_EXTRACT(job, "$.name")) = ?', { jobname })

	if players[1] ~= nil then
		for _, value in pairs(players) do
			local Target = QBCore.Functions.GetPlayerByCitizenId(value.citizenid) or QBCore.Functions.GetOfflinePlayerByCitizenId(value.citizenid)

			if Target and Target.PlayerData.job.name == jobname then
				local isOnline = Target.PlayerData.source
				employees[#employees + 1] = {
					empSource = Target.PlayerData.citizenid,
					grade = Target.PlayerData.job.grade,
					isboss = Target.PlayerData.job.isboss,
					name = (isOnline and '🟢 ' or '❌ ') .. Target.PlayerData.charinfo.firstname .. ' ' .. Target.PlayerData.charinfo.lastname
				}
			end
		end
		table.sort(employees, function(a, b)
			return a.grade.level > b.grade.level
		end)
	end
	cb(employees)
end)

-- 仓库开门条件：本人是这个组织（职业/帮派）的 boss，且站在对应菜单点 2.5 米内。
-- 三个模块（sv_boss / sv_gang / sv_org）共用；抽出来也让闸门能按 `if not CanOpenBossStash(...)`
-- 的 deny-early 形状核对（原来的 `if not playerJob.isboss then return end` 闸门认不出来）。
function CanOpenBossStash(src, Player, orgType, orgName)
	if not Player or type(orgType) ~= 'string' or type(orgName) ~= 'string' then return false end
	local data = orgType == 'gang' and Player.PlayerData.gang or Player.PlayerData.job
	if type(data) ~= 'table' or not data.isboss or data.name ~= orgName then return false end
	local menuConfig = orgType == 'gang' and Config.GangMenus or Config.BossMenus
	local bossCoords = menuConfig and menuConfig[orgName] or nil
	if type(bossCoords) ~= 'table' then return false end
	local ped = GetPlayerPed(src)
	if not ped or ped == 0 then return false end
	local playerCoords = GetEntityCoords(ped)
	for index = 1, #bossCoords do
		local coords = bossCoords[index]
		if coords and #(playerCoords - coords) < 2.5 then return true end
	end
	return false
end

RegisterNetEvent('qb-bossmenu:server:stash', function()
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	local playerJob = Player.PlayerData.job
	if not CanOpenBossStash(src, Player, 'job', playerJob and playerJob.name) then return end
	exports['qb-inventory']:OpenInventory(src, 'boss_' .. playerJob.name, {
		maxweight = 4000000,
		slots = 25,
	})
end)

-- Grade Change
RegisterNetEvent('qb-bossmenu:server:GradeUpdate', function(data)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	local Employee = QBCore.Functions.GetPlayerByCitizenId(data.cid) or QBCore.Functions.GetOfflinePlayerByCitizenId(data.cid)

	-- 🔒 Security: 距离校验 — Boss 必须在对应 Boss 菜单点附近
	if not Config.BossMenus[Player.PlayerData.job.name] then return end
	local bossCoords = Config.BossMenus[Player.PlayerData.job.name]
	local playerPed = GetPlayerPed(src)
	local playerCoords = GetEntityCoords(playerPed)
	local nearBoss = false
	for i = 1, #bossCoords do
		local coords = bossCoords[i]
		if #(playerCoords - coords) < 5.0 then nearBoss = true; break end
	end
	if not nearBoss then
		SecurityAuditLog(src, 'GradeUpdate', '非 Boss 菜单点操作 — 疑似远程发包')
		return
	end

	if not IsJobBoss(Player) then
		SecurityAuditLog(src, 'GradeUpdate', '非 Boss 尝试晋升员工')
		return
	end
	if data.grade > Player.PlayerData.job.grade.level then
		TriggerClientEvent('QBCore:Notify', src, 'You cannot promote to this rank!', 'error')
		return
	end

	if Employee then
		if Employee.Functions.SetJob(Player.PlayerData.job.name, data.grade) then
			TriggerClientEvent('QBCore:Notify', src, 'Sucessfully promoted!', 'success')
			Employee.Functions.Save()

			if Employee.PlayerData.source then -- Player is online
				TriggerClientEvent('QBCore:Notify', Employee.PlayerData.source, 'You have been promoted to ' .. data.gradename .. '.', 'success')
			end
		else
			TriggerClientEvent('QBCore:Notify', src, 'Promotion grade does not exist.', 'error')
		end
	end
	TriggerClientEvent('qb-bossmenu:client:OpenMenu', src)
end)

-- Fire Employee
RegisterNetEvent('qb-bossmenu:server:FireEmployee', function(target)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	local Employee = QBCore.Functions.GetPlayerByCitizenId(target) or QBCore.Functions.GetOfflinePlayerByCitizenId(target)

	-- 🔒 Security: 距离校验
	if not Config.BossMenus[Player.PlayerData.job.name] then return end
	local bossCoords = Config.BossMenus[Player.PlayerData.job.name]
	local playerPed = GetPlayerPed(src)
	local playerCoords = GetEntityCoords(playerPed)
	local nearBoss = false
	for i = 1, #bossCoords do
		local coords = bossCoords[i]
		if #(playerCoords - coords) < 5.0 then nearBoss = true; break end
	end
	if not nearBoss then
		SecurityAuditLog(src, 'FireEmployee', '非 Boss 菜单点操作 — 疑似远程发包')
		return
	end

	if not IsJobBoss(Player) then
		SecurityAuditLog(src, 'FireEmployee', '非 Boss 尝试解雇员工')
		return
	end

	if Employee then
		if target == Player.PlayerData.citizenid then
			TriggerClientEvent('QBCore:Notify', src, 'You can\'t fire yourself', 'error')
			return
		elseif Employee.PlayerData.job.grade.level > Player.PlayerData.job.grade.level then
			TriggerClientEvent('QBCore:Notify', src, 'You cannot fire this citizen!', 'error')
			return
		end
		if Employee.Functions.SetJob('unemployed', '0') then
			Employee.Functions.Save()
			TriggerClientEvent('QBCore:Notify', src, 'Employee fired!', 'success')
			TriggerEvent('qb-log:server:CreateLog', 'bossmenu', 'Job Fire', 'red', Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname .. ' successfully fired ' .. Employee.PlayerData.charinfo.firstname .. ' ' .. Employee.PlayerData.charinfo.lastname .. ' (' .. Player.PlayerData.job.name .. ')', false)

			if Employee.PlayerData.source then -- Player is online
				TriggerClientEvent('QBCore:Notify', Employee.PlayerData.source, 'You have been fired! Good luck.', 'error')
			end
		else
			TriggerClientEvent('QBCore:Notify', src, 'Error..', 'error')
		end
	end
	TriggerClientEvent('qb-bossmenu:client:OpenMenu', src)
end)

-- Recruit Player
RegisterNetEvent('qb-bossmenu:server:HireEmployee', function(recruit)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	local Target = QBCore.Functions.GetPlayer(recruit)

	-- 🔒 Security: 距离校验
	if not Config.BossMenus[Player.PlayerData.job.name] then return end
	local bossCoords = Config.BossMenus[Player.PlayerData.job.name]
	local playerPed = GetPlayerPed(src)
	local playerCoords = GetEntityCoords(playerPed)
	local nearBoss = false
	for i = 1, #bossCoords do
		local coords = bossCoords[i]
		if #(playerCoords - coords) < 5.0 then nearBoss = true; break end
	end
	if not nearBoss then
		SecurityAuditLog(src, 'HireEmployee', '非 Boss 菜单点操作 — 疑似远程发包')
		return
	end

	if not IsJobBoss(Player) then
		SecurityAuditLog(src, 'HireEmployee', '非 Boss 尝试招募员工')
		return
	end

	-- 目标必须在 Boss 附近：原来只看 Boss 是否在菜单点，能隔着地图把任意玩家塞进自己职业
	if Target then
		local targetCoords = GetEntityCoords(GetPlayerPed(Target.PlayerData.source))
		if #(playerCoords - targetCoords) > 5.0 then
			SecurityAuditLog(src, 'HireEmployee', '招募目标不在附近 — 疑似远程发包')
			return
		end
	end

	if Target and Target.Functions.SetJob(Player.PlayerData.job.name, 0) then
		TriggerClientEvent('QBCore:Notify', src, 'You hired ' .. (Target.PlayerData.charinfo.firstname .. ' ' .. Target.PlayerData.charinfo.lastname) .. ' come ' .. Player.PlayerData.job.label .. '', 'success')
		TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, 'You were hired as ' .. Player.PlayerData.job.label .. '', 'success')
		TriggerEvent('qb-log:server:CreateLog', 'bossmenu', 'Recruit', 'lightgreen', (Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname) .. ' successfully recruited ' .. (Target.PlayerData.charinfo.firstname .. ' ' .. Target.PlayerData.charinfo.lastname) .. ' (' .. Player.PlayerData.job.name .. ')', false)
	end
	TriggerClientEvent('qb-bossmenu:client:OpenMenu', src)
end)

-- Get closest player sv
QBCore.Functions.CreateCallback('qb-bossmenu:getplayers', function(source, cb)
	local src = source
	local players = {}
	local PlayerPed = GetPlayerPed(src)
	local pCoords = GetEntityCoords(PlayerPed)
	for _, v in pairs(QBCore.Functions.GetPlayers()) do
		local targetped = GetPlayerPed(v)
		local tCoords = GetEntityCoords(targetped)
		local dist = #(pCoords - tCoords)
		if PlayerPed ~= targetped and dist < 10 then
			local ped = QBCore.Functions.GetPlayer(v)
			players[#players + 1] = {
				id = v,
				coords = GetEntityCoords(targetped),
				name = ped.PlayerData.charinfo.firstname .. ' ' .. ped.PlayerData.charinfo.lastname,
				citizenid = ped.PlayerData.citizenid,
				sources = GetPlayerPed(ped.PlayerData.source),
				sourceplayer = ped.PlayerData.source
			}
		end
	end
	table.sort(players, function(a, b)
		return a.name < b.name
	end)
	cb(players)
end)

-- ==============================================================
-- 🔑 向后兼容桥接: 职业 Boss 退位交接
-- 事件名保留旧命名空间 qb-bossmenu:server:TransferOwnership
-- （与 sv_org.lua 中的 qb-orgmenu:server:TransferOwnership 并行工作）
-- ==============================================================

RegisterNetEvent('qb-bossmenu:server:TransferOwnership', function(data)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end

	-- 🔒 Security: 距离校验
	if not Config.BossMenus[Player.PlayerData.job.name] then return end
	local bossCoords = Config.BossMenus[Player.PlayerData.job.name]
	local playerPed = GetPlayerPed(src)
	local playerCoords = GetEntityCoords(playerPed)
	local nearBoss = false
	for i = 1, #bossCoords do
		local coords = bossCoords[i]
		if #(playerCoords - coords) < 5.0 then nearBoss = true; break end
	end
	if not nearBoss then
		SecurityAuditLog(src, 'TransferOwnership', '非 Boss 菜单点操作 — 疑似远程发包')
		return
	end

	local jobName = data.orgName
	if not jobName or not QBCore.Shared.Jobs[jobName] then
		TriggerClientEvent('QBCore:Notify', src, 'Invalid job.', 'error')
		return
	end

	-- 🔒 安全校验
	if not IsJobBoss(Player) then
		SecurityAuditLog(src, 'TransferOwnership', '非 Boss 尝试转让所有权')
		return
	end

	if data.successorCid == Player.PlayerData.citizenid then
		TriggerClientEvent('QBCore:Notify', src, 'You cannot transfer ownership to yourself!', 'error')
		return
	end

	local Successor = QBCore.Functions.GetPlayerByCitizenId(data.successorCid)
	if not Successor then
		TriggerClientEvent('QBCore:Notify', src, 'The designated successor is not found.', 'error')
		return
	end

	if Successor.PlayerData.job.name ~= jobName then
		TriggerClientEvent('QBCore:Notify', src, 'The designated successor is not in your organization!', 'error')
		return
	end

	if not Successor.PlayerData.source then
		TriggerClientEvent('QBCore:Notify', src, 'The designated successor must be online.', 'error')
		return
	end

	if Successor.PlayerData.job.isboss then
		TriggerClientEvent('QBCore:Notify', src, 'This member is already a Boss!', 'error')
		return
	end

	-- 原子交接
	local step1Success = Successor.Functions.SetJob(jobName, 4)
	if not step1Success then
		TriggerClientEvent('QBCore:Notify', src, 'Failed to promote successor. Transfer aborted.', 'error')
		return
	end
	Successor.Functions.Save()

	local step2Success = Player.Functions.SetJob('unemployed', 0)
	if not step2Success then
		Successor.Functions.SetJob(jobName, Successor.PlayerData.job.grade.level)
		TriggerClientEvent('QBCore:Notify', src, 'Failed to complete transfer. Rolled back.', 'error')
		return
	end
	Player.Functions.Save()

	local jobLabel = QBCore.Shared.Jobs[jobName].label
	TriggerClientEvent('QBCore:Notify', src,
		'You have transferred ' .. jobLabel .. ' to '
		.. Successor.PlayerData.charinfo.firstname .. ' '
		.. Successor.PlayerData.charinfo.lastname .. '. You are now a civilian.', 'success')
	TriggerClientEvent('QBCore:Notify', Successor.PlayerData.source,
		'⚠️ You are now the new Boss of ' .. jobLabel .. '!', 'success')

	TriggerEvent('qb-log:server:CreateLog', 'bossmenu', 'Ownership Transfer', 'gold',
		Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
		.. ' transferred ' .. jobName .. ' to '
		.. Successor.PlayerData.charinfo.firstname .. ' '
		.. Successor.PlayerData.charinfo.lastname, false)

	TriggerClientEvent('qb-bossmenu:client:CloseMenu', src)
end)
