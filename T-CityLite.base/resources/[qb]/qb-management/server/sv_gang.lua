local QBCore = exports['qb-core']:GetCoreObject()

-- 🔧 自愈: 安全审计日志（不再永久封禁）
local function SecurityAuditLog(src, action, detail)
    local playerName = GetPlayerName(src)
    print(('[SECURITY-GANG] %s (src=%s) attempted %s — %s'):format(playerName, src, action, detail))
    TriggerEvent('qb-log:server:CreateLog', 'gangmenu', 'Suspicious Activity', 'orange',
        string.format('%s (src=%s) attempted %s: %s', playerName, src, action, detail), false)
    TriggerClientEvent('QBCore:Notify', src, '你没有权限执行此操作', 'error')
end

-- Get Employees
QBCore.Functions.CreateCallback('qb-gangmenu:server:GetEmployees', function(source, cb, gangname)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)

	if not Player.PlayerData.gang.isboss then
		SecurityAuditLog(src, 'GetEmployees', '非帮派Boss尝试获取成员列表')
		return
	end

	local employees = {}
	-- 🔒 Security Fix: 参数化查询替代字符串拼接，消除 SQL 注入风险
	local players = MySQL.query.await('SELECT * FROM players WHERE JSON_UNQUOTE(JSON_EXTRACT(gang, "$.name")) = ?', { gangname })
	if players[1] ~= nil then
		for _, value in pairs(players) do
			local Target = QBCore.Functions.GetPlayerByCitizenId(value.citizenid) or QBCore.Functions.GetOfflinePlayerByCitizenId(value.citizenid)

			if Target then
				local isOnline = Target.PlayerData.source
				employees[#employees + 1] = {
					empSource = Target.PlayerData.citizenid,
					grade = Target.PlayerData.gang.grade,
					isboss = Target.PlayerData.gang.isboss,
					name = (isOnline and '🟢 ' or '❌ ') .. Target.PlayerData.charinfo.firstname .. ' ' .. Target.PlayerData.charinfo.lastname
				}
			end
		end
	end
	cb(employees)
end)

RegisterNetEvent('qb-gangmenu:server:stash', function()
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	local playerGang = Player.PlayerData.gang
	if not playerGang.isboss then return end
	local playerPed = GetPlayerPed(src)
	local playerCoords = GetEntityCoords(playerPed)
	if not Config.GangMenus[playerGang.name] then return end
	local bossCoords = Config.GangMenus[playerGang.name]
	for i = 1, #bossCoords do
		local coords = bossCoords[i]
		if #(playerCoords - coords) < 2.5 then
			local stashName = 'boss_' .. playerGang.name
			exports['qb-inventory']:OpenInventory(src, stashName, {
				maxweight = 4000000,
				slots = 25,
			})
			return
		end
	end
end)

-- Personal Stash for Non-Boss Gang Members
RegisterNetEvent('qb-gangmenu:server:personalStash', function()
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	local playerGang = Player.PlayerData.gang
	if playerGang.name == 'none' then return end
	local stashName = 'cartel_personal_' .. Player.PlayerData.citizenid
	exports['qb-inventory']:OpenInventory(src, stashName, {
		maxweight = 1000000, -- 1000kg
		slots = 15,
	})
end)

-- Grade Change
RegisterNetEvent('qb-gangmenu:server:GradeUpdate', function(data)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	local Employee = QBCore.Functions.GetPlayerByCitizenId(data.cid) or QBCore.Functions.GetOfflinePlayerByCitizenId(data.cid)

	-- 🔒 Security: 距离校验
	if not Config.GangMenus[Player.PlayerData.gang.name] then return end
	local bossCoords = Config.GangMenus[Player.PlayerData.gang.name]
	local playerPed = GetPlayerPed(src)
	local playerCoords = GetEntityCoords(playerPed)
	local nearBoss = false
	for i = 1, #bossCoords do
		local coords = bossCoords[i]
		if #(playerCoords - coords) < 5.0 then nearBoss = true; break end
	end
	if not nearBoss then
		SecurityAuditLog(src, 'GradeUpdate', '非帮派Boss菜单点操作 — 疑似远程发包')
		return
	end

	if not Player.PlayerData.gang.isboss then
		SecurityAuditLog(src, 'GradeUpdate', '非帮派Boss尝试晋升成员')
		return
	end
	if data.grade > Player.PlayerData.gang.grade.level then
		TriggerClientEvent('QBCore:Notify', src, 'You cannot promote to this rank!', 'error')
		return
	end

	if Employee then
		if Employee.Functions.SetGang(Player.PlayerData.gang.name, data.grade) then
			TriggerClientEvent('QBCore:Notify', src, 'Successfully promoted!', 'success')
			Employee.Functions.Save()

			if Employee.PlayerData.source then
				TriggerClientEvent('QBCore:Notify', Employee.PlayerData.source, 'You have been promoted to ' .. data.gradename .. '.', 'success')
			end
		else
			TriggerClientEvent('QBCore:Notify', src, 'Grade does not exist.', 'error')
		end
	end
	TriggerClientEvent('qb-gangmenu:client:OpenMenu', src)
end)

-- Fire Member
RegisterNetEvent('qb-gangmenu:server:FireMember', function(target)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	local Employee = QBCore.Functions.GetPlayerByCitizenId(target) or QBCore.Functions.GetOfflinePlayerByCitizenId(target)

	-- 🔒 Security: 距离校验
	if not Config.GangMenus[Player.PlayerData.gang.name] then return end
	local bossCoords = Config.GangMenus[Player.PlayerData.gang.name]
	local playerPed = GetPlayerPed(src)
	local playerCoords = GetEntityCoords(playerPed)
	local nearBoss = false
	for i = 1, #bossCoords do
		local coords = bossCoords[i]
		if #(playerCoords - coords) < 5.0 then nearBoss = true; break end
	end
	if not nearBoss then
		SecurityAuditLog(src, 'FireMember', '非帮派Boss菜单点操作 — 疑似远程发包')
		return
	end

	if not Player.PlayerData.gang.isboss then
		SecurityAuditLog(src, 'FireMember', '非帮派Boss尝试开除成员')
		return
	end

	if Employee then
		if target == Player.PlayerData.citizenid then
			TriggerClientEvent('QBCore:Notify', src, 'You can\'t kick yourself out of the gang!', 'error')
			return
		elseif Employee.PlayerData.gang.grade.level > Player.PlayerData.gang.grade.level then
			TriggerClientEvent('QBCore:Notify', src, 'You cannot fire this citizen!', 'error')
			return
		end
		if Employee.Functions.SetGang('none', '0') then
			Employee.Functions.Save()
			TriggerEvent('qb-log:server:CreateLog', 'gangmenu', 'Gang Fire', 'orange', Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname .. ' successfully fired ' .. Employee.PlayerData.charinfo.firstname .. ' ' .. Employee.PlayerData.charinfo.lastname .. ' (' .. Player.PlayerData.gang.name .. ')', false)
			TriggerClientEvent('QBCore:Notify', src, 'Gang Member fired!', 'success')

			if Employee.PlayerData.source then -- Player is online
				TriggerClientEvent('QBCore:Notify', Employee.PlayerData.source, 'You have been expelled from the gang!', 'error')
			end
		else
			TriggerClientEvent('QBCore:Notify', src, 'Error.', 'error')
		end
	end
	TriggerClientEvent('qb-gangmenu:client:OpenMenu', src)
end)

-- Recruit Player
RegisterNetEvent('qb-gangmenu:server:HireMember', function(recruit)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	local Target = QBCore.Functions.GetPlayer(recruit)

	-- 🔒 Security: 距离校验
	if not Config.GangMenus[Player.PlayerData.gang.name] then return end
	local bossCoords = Config.GangMenus[Player.PlayerData.gang.name]
	local playerPed = GetPlayerPed(src)
	local playerCoords = GetEntityCoords(playerPed)
	local nearBoss = false
	for i = 1, #bossCoords do
		local coords = bossCoords[i]
		if #(playerCoords - coords) < 5.0 then nearBoss = true; break end
	end
	if not nearBoss then
		SecurityAuditLog(src, 'HireMember', '非帮派Boss菜单点操作 — 疑似远程发包')
		return
	end

	if not Player.PlayerData.gang.isboss then
		SecurityAuditLog(src, 'HireMember', '非帮派Boss尝试招募成员')
		return
	end

	if Target and Target.Functions.SetGang(Player.PlayerData.gang.name, 0) then
		TriggerClientEvent('QBCore:Notify', src, 'You hired ' .. (Target.PlayerData.charinfo.firstname .. ' ' .. Target.PlayerData.charinfo.lastname) .. ' come ' .. Player.PlayerData.gang.label .. '', 'success')
		TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, 'You have been hired as ' .. Player.PlayerData.gang.label .. '', 'success')
		TriggerEvent('qb-log:server:CreateLog', 'gangmenu', 'Recruit', 'yellow', (Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname) .. ' successfully recruited ' .. Target.PlayerData.charinfo.firstname .. ' ' .. Target.PlayerData.charinfo.lastname .. ' (' .. Player.PlayerData.gang.name .. ')', false)
	end
	TriggerClientEvent('qb-gangmenu:client:OpenMenu', src)
end)

-- Get closest player sv
QBCore.Functions.CreateCallback('qb-gangmenu:getplayers', function(source, cb)
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
-- 🔑 向后兼容桥接: 帮派 Boss 退位交接
-- 事件名保留旧命名空间 qb-gangmenu:server:TransferOwnership
-- （与 sv_org.lua 中的 qb-orgmenu:server:TransferOwnership 并行工作）
-- ==============================================================

RegisterNetEvent('qb-gangmenu:server:TransferOwnership', function(data)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end

	-- 🔒 Security: 距离校验
	if not Config.GangMenus[Player.PlayerData.gang.name] then return end
	local bossCoords = Config.GangMenus[Player.PlayerData.gang.name]
	local playerPed = GetPlayerPed(src)
	local playerCoords = GetEntityCoords(playerPed)
	local nearBoss = false
	for i = 1, #bossCoords do
		local coords = bossCoords[i]
		if #(playerCoords - coords) < 5.0 then nearBoss = true; break end
	end
	if not nearBoss then
		SecurityAuditLog(src, 'TransferOwnership', '非帮派Boss菜单点操作 — 疑似远程发包')
		return
	end

	local gangName = data.orgName
	if not gangName or not QBCore.Shared.Gangs[gangName] then
		TriggerClientEvent('QBCore:Notify', src, 'Invalid gang.', 'error')
		return
	end

	-- 🔒 安全校验
	if not Player.PlayerData.gang.isboss then
		SecurityAuditLog(src, 'TransferOwnership', '非帮派Boss尝试转让所有权')
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

	if Successor.PlayerData.gang.name ~= gangName then
		TriggerClientEvent('QBCore:Notify', src, 'The designated successor is not in your gang!', 'error')
		return
	end

	if not Successor.PlayerData.source then
		TriggerClientEvent('QBCore:Notify', src, 'The designated successor must be online.', 'error')
		return
	end

	if Successor.PlayerData.gang.isboss then
		TriggerClientEvent('QBCore:Notify', src, 'This member is already a Boss!', 'error')
		return
	end

	-- 原子交接
	local step1Success = Successor.Functions.SetGang(gangName, 4)
	if not step1Success then
		TriggerClientEvent('QBCore:Notify', src, 'Failed to promote successor. Transfer aborted.', 'error')
		return
	end
	Successor.Functions.Save()

	local step2Success = Player.Functions.SetGang('none', 0)
	if not step2Success then
		Successor.Functions.SetGang(gangName, Successor.PlayerData.gang.grade.level)
		TriggerClientEvent('QBCore:Notify', src, 'Failed to complete transfer. Rolled back.', 'error')
		return
	end
	Player.Functions.Save()

	local gangLabel = QBCore.Shared.Gangs[gangName].label
	TriggerClientEvent('QBCore:Notify', src,
		'You have transferred ' .. gangLabel .. ' to '
		.. Successor.PlayerData.charinfo.firstname .. ' '
		.. Successor.PlayerData.charinfo.lastname .. '. You are now unaffiliated.', 'success')
	TriggerClientEvent('QBCore:Notify', Successor.PlayerData.source,
		'⚠️ You are now the new Boss of ' .. gangLabel .. '!', 'success')

	TriggerEvent('qb-log:server:CreateLog', 'gangmenu', 'Ownership Transfer', 'gold',
		Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
		.. ' transferred ' .. gangName .. ' to '
		.. Successor.PlayerData.charinfo.firstname .. ' '
		.. Successor.PlayerData.charinfo.lastname, false)

	TriggerClientEvent('qb-gangmenu:client:CloseMenu', src)
end)
