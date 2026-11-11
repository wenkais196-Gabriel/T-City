local QBCore = exports['qb-core']:GetCoreObject()

--- 人事回执（J-5）：老板操作 → 屏上 feed/error；被操作的当事人 → 手机留档（离线也能回查）。
local function feedback(src, text, kind)
    if type(text) == 'table' then text = text.text or '' end
    local pushKind = (kind == 'error') and 'error' or 'feed'
    pcall(function() exports['custom-notify']:Push(src, pushKind, tostring(text)) end)
end

--- 当事人凭证（录用/晋升/开除/所有权转移）：只进手机，不打断对方屏幕
local function personnelNote(src, body)
    pcall(function() exports['custom-notify']:Push(src, 'phone', '人事变动', tostring(body)) end)
end


-- 帮派老板判定（闸门按 net_event_guard_helpers.json 登记，调用点必须是
-- `if not IsGangBoss(Player) then ... return end` 形状）
local function IsGangBoss(Player)
	if Player and Player.PlayerData and Player.PlayerData.gang and Player.PlayerData.gang.isboss == true then
		return true
	end
	return false
end

-- 🔧 自愈: 安全审计日志（不再永久封禁）
local function SecurityAuditLog(src, action, detail)
    local playerName = GetPlayerName(src)
    print(('[SECURITY-GANG] %s (src=%s) attempted %s — %s'):format(playerName, src, action, detail))
    TriggerEvent('qb-log:server:CreateLog', 'gangmenu', 'Suspicious Activity', 'orange',
        string.format('%s (src=%s) attempted %s: %s', playerName, src, action, detail), false)
    feedback(src, '你没有权限执行此操作', 'error')
end

-- Get Employees
QBCore.Functions.CreateCallback('qb-gangmenu:server:GetEmployees', function(source, cb, gangname)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)

	if not IsGangBoss(Player) then
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
	if not CanOpenBossStash(src, Player, 'gang', playerGang and playerGang.name) then return end
	exports['qb-inventory']:OpenInventory(src, 'boss_' .. playerGang.name, {
		maxweight = 4000000,
		slots = 25,
	})
end)

-- Personal Stash for Non-Boss Gang Members
RegisterNetEvent('qb-gangmenu:server:personalStash', function()
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	local playerGang = Player.PlayerData.gang
	-- 个人仓库只按**调用者自己的** citizenid 取，且必须有帮派（名字不能是 none）
	if type(playerGang) ~= 'table' or type(playerGang.name) ~= 'string' or playerGang.name == 'none' then return end
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

	if not IsGangBoss(Player) then
		SecurityAuditLog(src, 'GradeUpdate', '非帮派Boss尝试晋升成员')
		return
	end
	if data.grade > Player.PlayerData.gang.grade.level then
		feedback(src, '不能晋升到这个职级', 'error')
		return
	end

	if Employee then
		if Employee.Functions.SetGang(Player.PlayerData.gang.name, data.grade) then
			feedback(src, '已晋升该成员', 'success')
			Employee.Functions.Save()

			if Employee.PlayerData.source then
				personnelNote(Employee.PlayerData.source, ('你已被晋升为 ' .. tostring(data.gradename or '') .. ''))
			end
		else
			feedback(src, '该职级不存在', 'error')
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

	if not IsGangBoss(Player) then
		SecurityAuditLog(src, 'FireMember', '非帮派Boss尝试开除成员')
		return
	end

	if Employee then
		if target == Player.PlayerData.citizenid then
			feedback(src, '不能把自己踢出帮派', 'error')
			return
		elseif Employee.PlayerData.gang.grade.level > Player.PlayerData.gang.grade.level then
			feedback(src, '你不能开除这名成员', 'error')
			return
		end
		if Employee.Functions.SetGang('none', '0') then
			Employee.Functions.Save()
			TriggerEvent('qb-log:server:CreateLog', 'gangmenu', 'Gang Fire', 'orange', Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname .. ' successfully fired ' .. Employee.PlayerData.charinfo.firstname .. ' ' .. Employee.PlayerData.charinfo.lastname .. ' (' .. Player.PlayerData.gang.name .. ')', false)
			feedback(src, '已开除该帮派成员', 'success')

			if Employee.PlayerData.source then -- Player is online
				personnelNote(Employee.PlayerData.source, '你已被移出帮派')
			end
		else
			feedback(src, '操作失败', 'error')
		end
	end
	TriggerClientEvent('qb-gangmenu:client:OpenMenu', src)
end)

-- Recruit Player
RegisterNetEvent('qb-gangmenu:server:HireMember', function(recruit)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
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

	if not IsGangBoss(Player) then
		SecurityAuditLog(src, 'HireMember', '非帮派Boss尝试招募成员')
		return
	end

	-- 目标必须在附近：原来只校验 Boss 是否在菜单点，能隔地图把任意玩家塞进自己帮派
	if Target then
		local targetCoords = GetEntityCoords(GetPlayerPed(Target.PlayerData.source))
		if #(playerCoords - targetCoords) > 5.0 then
			SecurityAuditLog(src, 'HireMember', '招募目标不在附近 — 疑似远程发包')
			return
		end
	end

	if Target and Target.Functions.SetGang(Player.PlayerData.gang.name, 0) then
		feedback(src, '已录用 ' .. (Target.PlayerData.charinfo.firstname .. ' ' .. Target.PlayerData.charinfo.lastname) .. ' 加入 ' .. Player.PlayerData.gang.label .. '', 'success')
		personnelNote(Target.PlayerData.source, '你已被录用为 ' .. tostring(Player.PlayerData.gang.label or ''))
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
		feedback(src, '帮派无效', 'error')
		return
	end

	-- 🔒 安全校验
	if not IsGangBoss(Player) then
		SecurityAuditLog(src, 'TransferOwnership', '非帮派Boss尝试转让所有权')
		return
	end

	if data.successorCid == Player.PlayerData.citizenid then
		feedback(src, '不能把所有权转给自己', 'error')
		return
	end

	local Successor = QBCore.Functions.GetPlayerByCitizenId(data.successorCid)
	if not Successor then
		feedback(src, '指定的继承人不存在', 'error')
		return
	end

	if Successor.PlayerData.gang.name ~= gangName then
		feedback(src, '继承人不在本帮派', 'error')
		return
	end

	if not Successor.PlayerData.source then
		feedback(src, '继承人必须在线', 'error')
		return
	end

	if Successor.PlayerData.gang.isboss then
		feedback(src, '该成员已经是老板', 'error')
		return
	end

	-- 原子交接
	local step1Success = Successor.Functions.SetGang(gangName, 4)
	if not step1Success then
		feedback(src, '提升继承人失败，转移已中止', 'error')
		return
	end
	Successor.Functions.Save()

	local step2Success = Player.Functions.SetGang('none', 0)
	if not step2Success then
		Successor.Functions.SetGang(gangName, Successor.PlayerData.gang.grade.level)
		feedback(src, '转移失败，已回滚', 'error')
		return
	end
	Player.Functions.Save()

	local gangLabel = QBCore.Shared.Gangs[gangName].label
	feedback(src,
		'You have transferred ' .. gangLabel .. ' to '
		.. Successor.PlayerData.charinfo.firstname .. ' '
		.. Successor.PlayerData.charinfo.lastname .. '. 你已脱离组织。', 'success')
	personnelNote(Successor.PlayerData.source, '⚠️ 你已接管 ' .. gangLabel .. ' 的所有权')

	TriggerEvent('qb-log:server:CreateLog', 'gangmenu', 'Ownership Transfer', 'gold',
		Player.PlayerData.charinfo.firstname .. ' ' .. Player.PlayerData.charinfo.lastname
		.. ' transferred ' .. gangName .. ' to '
		.. Successor.PlayerData.charinfo.firstname .. ' '
		.. Successor.PlayerData.charinfo.lastname, false)

	TriggerClientEvent('qb-gangmenu:client:CloseMenu', src)
end)
