local PlayerInjuries = {}
local PlayerWeaponWounds = {}
local QBCore = exports['qb-core']:GetCoreObject()
local doctorCount = 0
local doctorCalled = false
local Doctors = {}

-- Events

-- Compatibility with txAdmin Menu's heal options.
-- This is an admin only server side event that will pass the target player id or -1.
AddEventHandler('txAdmin:events:healedPlayer', function(eventData)
	if GetInvokingResource() ~= 'monitor' or type(eventData) ~= 'table' or type(eventData.id) ~= 'number' then
		return
	end

	TriggerClientEvent('hospital:client:Revive', eventData.id)
	TriggerClientEvent('hospital:client:HealInjuries', eventData.id, 'full')
end)

RegisterNetEvent('hospital:server:SendToBed', function(bedId, isRevive, hospitalIndex)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	-- 🔒 Security: 限流 — 防止客户端高频刷扣款
	if _bedCooldowns == nil then _bedCooldowns = {} end
	local now = os.time()
	if _bedCooldowns[src] and (now - _bedCooldowns[src]) < 30 then return end
	_bedCooldowns[src] = now
	TriggerClientEvent('hospital:client:SendToBed', src, bedId, Config.Locations['hospital'][hospitalIndex]['beds'][bedId], isRevive)
	TriggerClientEvent('hospital:client:SetBed', -1, bedId, true, hospitalIndex)
	Player.Functions.RemoveMoney('bank', Config.BillCost, 'respawned-at-hospital')
	exports['qb-banking']:AddMoney('ambulance', Config.BillCost, 'Player treatment')
	TriggerClientEvent('hospital:client:SendBillEmail', src, Config.BillCost, Config.Locations['hospital'][hospitalIndex]['name'])
end)

RegisterNetEvent('hospital:server:RespawnAtHospital', function(hospitalIndex)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	-- 🌐 Atmosphere: return to default on respawn
	if Bus and Bus.SafeCall then Bus.SafeCall('atmosphere', 'PlayScene', src, 'default') end
	if Player.PlayerData.metadata['injail'] > 0 then
		for i = 1, #Config.Locations['jailbeds'] do
			local v = Config.Locations['jailbeds'][i]
			if not v.taken then
				TriggerClientEvent('hospital:client:SendToBed', src, i, v, true)
				TriggerClientEvent('hospital:client:SetBed2', -1, i, true)
				if Config.WipeInventoryOnRespawn then
					Player.Functions.ClearInventory()
					MySQL.Async.execute('UPDATE players SET inventory = ? WHERE citizenid = ?', { json.encode({}), Player.PlayerData.citizenid })
					TriggerClientEvent('QBCore:Notify', src, Lang:t('error.possessions_taken'), 'error')
				end
				Player.Functions.RemoveMoney('bank', Config.BillCost, 'respawned-at-hospital')
				exports['qb-banking']:AddMoney('ambulance', Config.BillCost, 'Player treatment')
				TriggerClientEvent('hospital:client:SendBillEmail', src, Config.BillCost)
				return
			end
		end

		TriggerClientEvent('hospital:client:SendToBed', src, 1, Config.Locations['jailbeds'][1], true)
		TriggerClientEvent('hospital:client:SetBed', -1, 1, true)
		if Config.WipeInventoryOnRespawn then
			Player.Functions.ClearInventory()
			MySQL.Async.execute('UPDATE players SET inventory = ? WHERE citizenid = ?', { json.encode({}), Player.PlayerData.citizenid })
			TriggerClientEvent('QBCore:Notify', src, Lang:t('error.possessions_taken'), 'error')
		end
		Player.Functions.RemoveMoney('bank', Config.BillCost, 'respawned-at-hospital')
		exports['qb-banking']:AddMoney('ambulance', Config.BillCost, 'Player treatment')
		TriggerClientEvent('hospital:client:SendBillEmail', src, Config.BillCost)
	else
		for i = 1, #Config.Locations['hospital'][hospitalIndex]['beds'] do
			local v = Config.Locations['hospital'][hospitalIndex]['beds'][i]
			if not v.taken then
				TriggerClientEvent('hospital:client:SendToBed', src, i, v, true)
				TriggerClientEvent('hospital:client:SetBed', -1, i, true, hospitalIndex)
				if Config.WipeInventoryOnRespawn then
					Player.Functions.ClearInventory()
					MySQL.update('UPDATE players SET inventory = ? WHERE citizenid = ?', { json.encode({}), Player.PlayerData.citizenid })
					TriggerClientEvent('QBCore:Notify', src, Lang:t('error.possessions_taken'), 'error')
				end
				Player.Functions.RemoveMoney('bank', Config.BillCost, 'respawned-at-hospital')
				exports['qb-banking']:AddMoney('ambulance', Config.BillCost, 'Player treatment')
				TriggerClientEvent('hospital:client:SendBillEmail', src, Config.BillCost, Config.Locations['hospital'][hospitalIndex]['name'])
				return
			end
		end
		-- All beds were full, placing in first bed as fallback
		TriggerClientEvent('hospital:client:SendToBed', src, 1, Config.Locations['hospital'][hospitalIndex]['beds'][1], true)
		TriggerClientEvent('hospital:client:SetBed', -1, 1, true, hospitalIndex)
		if Config.WipeInventoryOnRespawn then
			Player.Functions.ClearInventory()
			MySQL.update('UPDATE players SET inventory = ? WHERE citizenid = ?', { json.encode({}), Player.PlayerData.citizenid })
			TriggerClientEvent('QBCore:Notify', src, Lang:t('error.possessions_taken'), 'error')
		end
		Player.Functions.RemoveMoney('bank', Config.BillCost, 'respawned-at-hospital')
		exports['qb-banking']:AddMoney('ambulance', Config.BillCost, 'Player treatment')
		TriggerClientEvent('hospital:client:SendBillEmail', src, Config.BillCost, Config.Locations['hospital'][hospitalIndex]['name'])
	end
end)

RegisterNetEvent('hospital:server:ambulanceAlert', function(text)
	local src = source
	local ped = GetPlayerPed(src)
	local coords = GetEntityCoords(ped)
	local players = QBCore.Functions.GetQBPlayers()
	for _, v in pairs(players) do
		if v.PlayerData.job.name == 'ambulance' and v.PlayerData.job.onduty then
			TriggerClientEvent('hospital:client:ambulanceAlert', v.PlayerData.source, coords, text)
		end
	end
end)

RegisterNetEvent('hospital:server:LeaveBed', function(id, hospitalIndex)
	TriggerClientEvent('hospital:client:SetBed', -1, id, false, hospitalIndex)
end)

RegisterNetEvent('hospital:server:SyncInjuries', function(data)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if Player then
		Player.Functions.SetMetaData('injuries', data)
	end
	PlayerInjuries[src] = data
end)

RegisterNetEvent('hospital:server:SetWeaponDamage', function(data)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if Player then
		Player.Functions.SetMetaData('weaponwounds', data)
		PlayerWeaponWounds[Player.PlayerData.source] = data
	end
end)

RegisterNetEvent('hospital:server:RestoreWeaponDamage', function()
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if Player then
		Player.Functions.SetMetaData('weaponwounds', nil)
		PlayerWeaponWounds[Player.PlayerData.source] = nil
	end
end)

RegisterNetEvent('hospital:server:SetDeathStatus', function(isDead)
	local src = source
	-- 🔒 Security: 客户端发来的死亡状态仅接受 boolean 类型，且拒绝非受伤玩家自报死亡
	if type(isDead) ~= 'boolean' then return end
	local Player = QBCore.Functions.GetPlayer(src)
	if Player then
		-- 如果玩家声称自己死了但当前没有受伤记录，拒绝（防伪装死刷无敌）
		if isDead and not PlayerInjuries[src] then
			TriggerEvent('qb-log:server:CreateLog', 'ambulancejob', 'Suspicious Death Report', 'orange',
				string.format('%s (src=%s) 企图伪装死亡状态 — 无受伤记录', GetPlayerName(src), src), false)
			return
		end
		Player.Functions.SetMetaData('isdead', isDead)
		-- 🌐 Atmosphere: respawn scene on death
		if isDead and Bus and Bus.SafeCall then Bus.SafeCall('atmosphere', 'PlayScene', src, 'respawn') end
	end
end)

RegisterNetEvent('hospital:server:SetLaststandStatus', function(bool)
	local src = source
	-- 🔒 Security: 类型校验，防止客户端注入非布尔值
	if type(bool) ~= 'boolean' then return end
	local Player = QBCore.Functions.GetPlayer(src)
	if Player then
		Player.Functions.SetMetaData('inlaststand', bool)
	end
end)

RegisterNetEvent('hospital:server:SetArmor', function(amount)
	local src = source
	-- 🔒 Security: 数值校验 — 护甲值只能在 0-100 范围
	amount = tonumber(amount)
	if not amount or amount < 0 or amount > 100 then return end
	local Player = QBCore.Functions.GetPlayer(src)
	if Player then
		Player.Functions.SetMetaData('armor', amount)
	end
end)

RegisterNetEvent('hospital:server:TreatWounds', function(playerId)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	local Patient = QBCore.Functions.GetPlayer(playerId)
	if Patient then
		if Player.PlayerData.job.name == 'ambulance' and Player.PlayerData.job.onduty then
			-- 🔧 科室权限检查: 完全治愈（full）仅 SURGERY 科室可执行
			local dept = exports['custom-career']:GetPlayerIdentity(src)
			local deptName = dept and dept.department or Config.DefaultDepartment
			local deptConfig = Config.Departments[deptName]
			if deptConfig and deptConfig.allowSurgery then
				exports['qb-inventory']:RemoveItem(src, 'bandage', 1, false, 'hospital:server:TreatWounds')
				TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['bandage'], 'remove')
				TriggerClientEvent('hospital:client:HealInjuries', Patient.PlayerData.source, 'full')
				print(('[EMS-TREAT] SURGERY doctor %s fully healed patient %s'):format(GetPlayerName(src), GetPlayerName(playerId)))
			else
				-- 急诊科 (EMERGENCY) 只能用绷带止血, 发送 partial 而非 full
				exports['qb-inventory']:RemoveItem(src, 'bandage', 1, false, 'hospital:server:TreatWounds')
				TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['bandage'], 'remove')
				TriggerClientEvent('hospital:client:HealInjuries', Patient.PlayerData.source, 'partial')
				TriggerClientEvent('QBCore:Notify', src, ('[%s] 仅能实施紧急止血 — 完全治愈需 SURGERY 科室'):format(deptConfig and deptConfig.label or '急诊科'), 'primary')
			end
		else
			TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_ems'), 'error')
		end
	end
end)

RegisterNetEvent('hospital:server:AddDoctor', function(job)
	local src = source
	-- 🔒 Security: 服务端权威校验 — 禁止客户端自报职业
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	if Player.PlayerData.job.name ~= 'ambulance' or not Player.PlayerData.job.onduty then return end
	if job == 'ambulance' then
		doctorCount = doctorCount + 1
		TriggerClientEvent('hospital:client:SetDoctorCount', -1, doctorCount)
		Doctors[src] = true
	end
end)

RegisterNetEvent('hospital:server:RemoveDoctor', function(job)
	local src = source
	-- 🔒 Security: 服务端权威校验 — 禁止客户端自报职业
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then
		-- 玩家已离线，从 Doctors 表中清理
		if Doctors[src] then
			doctorCount = doctorCount - 1
			if doctorCount < 0 then doctorCount = 0 end
			TriggerClientEvent('hospital:client:SetDoctorCount', -1, doctorCount)
			Doctors[src] = nil
		end
		return
	end
	if job == 'ambulance' then
		doctorCount = doctorCount - 1
		if doctorCount < 0 then doctorCount = 0 end
		TriggerClientEvent('hospital:client:SetDoctorCount', -1, doctorCount)
		Doctors[src] = nil
	end
end)

AddEventHandler('playerDropped', function()
	local src = source
	if Doctors[src] then
		doctorCount = doctorCount - 1
		TriggerClientEvent('hospital:client:SetDoctorCount', -1, doctorCount)
		Doctors[src] = nil
	end
end)

RegisterNetEvent('hospital:server:RevivePlayer', function(playerId, isOldMan)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	local Patient = QBCore.Functions.GetPlayer(playerId)
	local oldMan = isOldMan or false
	if Patient then
		-- 🔧 权限检查: 必须是 EMS 值班人员，或持有 firstaid + medical_cert
		local isEMS = Player.PlayerData.job.name == 'ambulance' and Player.PlayerData.job.onduty
		local hasFirstAid = QBCore.Functions.HasItem(src, 'firstaid', 1)
		local hasMedicalCert = true -- 默认允许（向后兼容）
		if Config.RequireMedicalCert and not isEMS then
			-- 非 EMS 人员使用 firstaid 需持有 medical_cert
			local certs = Player.PlayerData.metadata['cert_status'] or {}
			hasMedicalCert = (certs['medical'] == 'held')
		end
		if isEMS or (hasFirstAid and hasMedicalCert) then
			if oldMan then
				if Player.Functions.RemoveMoney('cash', 5000, 'revived-player') then
					exports['qb-inventory']:RemoveItem(src, 'firstaid', 1, false, 'hospital:server:RevivePlayer')
					TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['firstaid'], 'remove')
					TriggerClientEvent('hospital:client:Revive', Patient.PlayerData.source)
				else
					TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_enough_money'), 'error')
				end
			else
				exports['qb-inventory']:RemoveItem(src, 'firstaid', 1, false, 'hospital:server:RevivePlayer')
				TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['firstaid'], 'remove')
				TriggerClientEvent('hospital:client:Revive', Patient.PlayerData.source)
			end
		else
			-- 🔧 安全审计日志（不再永久封禁，而是记录 + 通知）
			local reason = hasFirstAid and '缺少医疗执业执照 (medical_cert)' or '无 firstaid 物品或无 EMS 职业'
			TriggerEvent('qb-log:server:CreateLog', 'ambulancejob', 'Revive Blocked', 'orange', string.format('%s (src=%s) tried to revive player %s — %s', GetPlayerName(src), src, playerId, reason), false)
			TriggerClientEvent('QBCore:Notify', src, ('你没有权限复活他人（%s）'):format(reason), 'error')
		end
	end
end)

RegisterNetEvent('hospital:server:SendDoctorAlert', function(hospitalName)
	local src = source
	if not doctorCalled then
		doctorCalled = true
		local players = QBCore.Functions.GetQBPlayers()
		for _, v in pairs(players) do
			if v.PlayerData.job.name == 'ambulance' and v.PlayerData.job.onduty then
				TriggerClientEvent('QBCore:Notify', v.PlayerData.source, Lang:t('info.dr_needed', { hospital = hospitalName }), 'ambulance')
			end
		end
		SetTimeout(Config.DocCooldown * 60000, function()
			doctorCalled = false
		end)
	else
		TriggerClientEvent('QBCore:Notify', src, 'Doctor has already been notified', 'error')
	end
end)

RegisterNetEvent('hospital:server:UseFirstAid', function(targetId)
	local src = source
	-- 🛡️ Security: 调用者必须存在
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	-- 🛡️ Security: 目标必须存在
	local Target = QBCore.Functions.GetPlayer(tonumber(targetId))
	if not Target then return end
	-- 🛡️ Security: 不能对自己使用
	if src == tonumber(targetId) then return end
	-- 🛡️ Security: 必须是 EMS 值班人员，或持有 firstaid 物品
	local isEMS = Player.PlayerData.job.name == 'ambulance' and Player.PlayerData.job.onduty
	local hasFirstAid = QBCore.Functions.HasItem(src, 'firstaid', 1)
	if not isEMS and not hasFirstAid then
		-- 安全审计日志
		TriggerEvent('qb-log:server:CreateLog', 'ambulancejob', 'FirstAid Blocked', 'orange',
			string.format('%s (src=%s) tried to use firstaid on player %s — 无 EMS 职业且无 firstaid 物品',
				GetPlayerName(src), src, targetId), false)
		TriggerClientEvent('QBCore:Notify', src, '你没有急救权限（需要 EMS 值班或持有急救包）', 'error')
		return
	end
	-- 🛡️ Security: 距离校验（服务端权威，不信任客户端）
	local callerPed = GetPlayerPed(src)
	local targetPed = GetPlayerPed(targetId)
	local callerCoords = GetEntityCoords(callerPed)
	local targetCoords = GetEntityCoords(targetPed)
	if #(callerCoords - targetCoords) > 3.0 then
		TriggerClientEvent('QBCore:Notify', src, '目标距离太远，无法进行急救', 'error')
		return
	end
	TriggerClientEvent('hospital:client:CanHelp', targetId, src)
end)

RegisterNetEvent('hospital:server:CanHelp', function(helperId, canHelp)
	local src = source
	if canHelp then
		TriggerClientEvent('hospital:client:HelpPerson', helperId, src)
	else
		TriggerClientEvent('QBCore:Notify', helperId, Lang:t('error.cant_help'), 'error')
	end
end)

RegisterNetEvent('hospital:server:removeBandage', function()
	local Player = QBCore.Functions.GetPlayer(source)
	if not Player then return end
	exports['qb-inventory']:RemoveItem(source, 'bandage', 1, false, 'hospital:server:removeBandage')
end)

RegisterNetEvent('hospital:server:removeIfaks', function()
	local Player = QBCore.Functions.GetPlayer(source)
	if not Player then return end
	exports['qb-inventory']:RemoveItem(source, 'ifaks', 1, false, 'hospital:server:removeIfaks')
end)

RegisterNetEvent('hospital:server:removePainkillers', function()
	local Player = QBCore.Functions.GetPlayer(source)
	if not Player then return end
	exports['qb-inventory']:RemoveItem(source, 'painkillers', 1, false, 'hospital:server:removePainkillers')
end)

RegisterNetEvent('hospital:server:resetHungerThirst', function()
	local Player = QBCore.Functions.GetPlayer(source)

	if not Player then return end

	Player.Functions.SetMetaData('hunger', 100)
	Player.Functions.SetMetaData('thirst', 100)

	TriggerClientEvent('hud:client:UpdateNeeds', source, 100, 100)
end)

RegisterNetEvent('qb-ambulancejob:server:stash', function()
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	local citizenId = Player.PlayerData.citizenid
	local stashName = 'ambulancestash_' .. citizenId
	exports['qb-inventory']:OpenInventory(src, stashName)
end)

-- Callbacks

QBCore.Functions.CreateCallback('hospital:GetDoctors', function(_, cb)
	local amount = 0
	local players = QBCore.Functions.GetQBPlayers()
	for _, v in pairs(players) do
		if v.PlayerData.job.name == 'ambulance' and v.PlayerData.job.onduty then
			amount = amount + 1
		end
	end
	cb(amount)
end)

QBCore.Functions.CreateCallback('hospital:GetPlayerStatus', function(_, cb, playerId)
	local Player = QBCore.Functions.GetPlayer(playerId)
	local injuries = {}
	injuries['WEAPONWOUNDS'] = {}
	if Player then
		if PlayerInjuries[Player.PlayerData.source] then
			if (PlayerInjuries[Player.PlayerData.source].isBleeding > 0) then
				injuries['BLEED'] = PlayerInjuries[Player.PlayerData.source].isBleeding
			end
			for k, _ in pairs(PlayerInjuries[Player.PlayerData.source].limbs) do
				if PlayerInjuries[Player.PlayerData.source].limbs[k].isDamaged then
					injuries[k] = PlayerInjuries[Player.PlayerData.source].limbs[k]
				end
			end
		end
		if PlayerWeaponWounds[Player.PlayerData.source] then
			for k, v in pairs(PlayerWeaponWounds[Player.PlayerData.source]) do
				injuries['WEAPONWOUNDS'][k] = v
			end
		end
	end
	cb(injuries)
end)

QBCore.Functions.CreateCallback('hospital:GetPlayerBleeding', function(source, cb)
	local src = source
	if PlayerInjuries[src] and PlayerInjuries[src].isBleeding then
		cb(PlayerInjuries[src].isBleeding)
	else
		cb(nil)
	end
end)

-- Commands

-- 🔧 科室管理指令
QBCore.Commands.Add('setemsdept', '分配医护科室 (EMERGENCY/SURGERY/AIR_RESCUE)', { { name = 'id', help = Lang:t('info.player_id') }, { name = 'dept', help = 'EMERGENCY / SURGERY / AIR_RESCUE' } }, true, function(source, args)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	local targetId = tonumber(args[1])
	local dept = args[2] and args[2]:upper()
	-- 仅院长/外科主任 (grade >= 3) 可分配科室
	if Player.PlayerData.job.name ~= 'ambulance' or Player.PlayerData.job.grade.level < 3 then
		TriggerClientEvent('QBCore:Notify', src, '仅外科主任 (Surgeon) 及以上可分配科室', 'error')
		return
	end
	if not Config.Departments[dept] then
		TriggerClientEvent('QBCore:Notify', src, ('无效科室: %s (可选: EMERGENCY, SURGERY, AIR_RESCUE)'):format(dept or 'nil'), 'error')
		return
	end
	local Target = QBCore.Functions.GetPlayer(targetId)
	if not Target then TriggerClientEvent('QBCore:Notify', src, '目标玩家不在线', 'error'); return end
	if Target.PlayerData.job.name ~= 'ambulance' then TriggerClientEvent('QBCore:Notify', src, '目标不是医护人员', 'error'); return end
	local success = exports['custom-career']:SetPlayerDepartment(targetId, dept)
	if success then
		TriggerClientEvent('QBCore:Notify', src, ('已将 %s 分配至 %s'):format(Target.PlayerData.charinfo.firstname, Config.Departments[dept].label), 'success')
		TriggerClientEvent('QBCore:Notify', Target.PlayerData.source, ('你已被分配至 %s'):format(Config.Departments[dept].label), 'success')
	else
		TriggerClientEvent('QBCore:Notify', src, '操作失败', 'error')
	end
end)

QBCore.Commands.Add('911e', Lang:t('info.ems_report'), { { name = 'message', help = Lang:t('info.message_sent') } }, false, function(source, args)
	local src = source
	local message
	if args[1] then message = table.concat(args, ' ') else message = Lang:t('info.civ_call') end
	local ped = GetPlayerPed(src)
	local coords = GetEntityCoords(ped)
	local players = QBCore.Functions.GetQBPlayers()
	for _, v in pairs(players) do
		if v.PlayerData.job.name == 'ambulance' and v.PlayerData.job.onduty then
			TriggerClientEvent('hospital:client:ambulanceAlert', v.PlayerData.source, coords, message)
		end
	end
end)

QBCore.Commands.Add('status', Lang:t('info.check_health'), {}, false, function(source, _)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if Player.PlayerData.job.name == 'ambulance' then
		TriggerClientEvent('hospital:client:CheckStatus', src)
	else
		TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_ems'), 'error')
	end
end)

QBCore.Commands.Add('heal', Lang:t('info.heal_player'), {}, false, function(source, _)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if Player.PlayerData.job.name == 'ambulance' then
		TriggerClientEvent('hospital:client:TreatWounds', src)
	else
		TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_ems'), 'error')
	end
end)

QBCore.Commands.Add('revivep', Lang:t('info.revive_player'), {}, false, function(source, _)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if Player.PlayerData.job.name == 'ambulance' then
		TriggerClientEvent('hospital:client:RevivePlayer', src)
	else
		TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_ems'), 'error')
	end
end)

QBCore.Commands.Add('revive', Lang:t('info.revive_player_a'), { { name = 'id', help = Lang:t('info.player_id') } }, false, function(source, args)
	local src = source
	if args[1] then
		local Player = QBCore.Functions.GetPlayer(tonumber(args[1]))
		if Player then
			TriggerClientEvent('hospital:client:Revive', Player.PlayerData.source)
		else
			TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_online'), 'error')
		end
	else
		TriggerClientEvent('hospital:client:Revive', src)
	end
end, 'admin')

QBCore.Commands.Add('setpain', Lang:t('info.pain_level'), { { name = 'id', help = Lang:t('info.player_id') } }, false, function(source, args)
	local src = source
	if args[1] then
		local Player = QBCore.Functions.GetPlayer(tonumber(args[1]))
		if Player then
			TriggerClientEvent('hospital:client:SetPain', Player.PlayerData.source)
		else
			TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_online'), 'error')
		end
	else
		TriggerClientEvent('hospital:client:SetPain', src)
	end
end, 'admin')

QBCore.Commands.Add('kill', Lang:t('info.kill'), { { name = 'id', help = Lang:t('info.player_id') } }, false, function(source, args)
	local src = source
	if args[1] then
		local Player = QBCore.Functions.GetPlayer(tonumber(args[1]))
		if Player then
			TriggerClientEvent('hospital:client:KillPlayer', Player.PlayerData.source)
		else
			TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_online'), 'error')
		end
	else
		TriggerClientEvent('hospital:client:KillPlayer', src)
	end
end, 'admin')

QBCore.Commands.Add('aheal', Lang:t('info.heal_player_a'), { { name = 'id', help = Lang:t('info.player_id') } }, false, function(source, args)
	local src = source
	if args[1] then
		local Player = QBCore.Functions.GetPlayer(tonumber(args[1]))
		if Player then
			TriggerClientEvent('hospital:client:adminHeal', Player.PlayerData.source)
		else
			TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_online'), 'error')
		end
	else
		TriggerClientEvent('hospital:client:adminHeal', src)
	end
end, 'admin')

-- Items

QBCore.Functions.CreateUseableItem('ifaks', function(source, item)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if Player.Functions.GetItemByName(item.name) ~= nil then
		TriggerClientEvent('hospital:client:UseIfaks', src)
	end
end)

QBCore.Functions.CreateUseableItem('bandage', function(source, item)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if Player.Functions.GetItemByName(item.name) ~= nil then
		TriggerClientEvent('hospital:client:UseBandage', src)
	end
end)

QBCore.Functions.CreateUseableItem('painkillers', function(source, item)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if Player.Functions.GetItemByName(item.name) ~= nil then
		TriggerClientEvent('hospital:client:UsePainkillers', src)
	end
end)

QBCore.Functions.CreateUseableItem('firstaid', function(source, item)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if Player.Functions.GetItemByName(item.name) ~= nil then
		TriggerClientEvent('hospital:client:UseFirstAid', src)
	end
end)

exports('GetDoctorCount', function() return doctorCount end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
	local src = Player.PlayerData.source
	if Player.PlayerData.metadata['injuries'] then
		PlayerInjuries[src] = Player.PlayerData.metadata['injuries']
	end
	if Player.PlayerData.metadata['weaponwounds'] then
		PlayerWeaponWounds[src] = Player.PlayerData.metadata['weaponwounds']
	end
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
	PlayerInjuries[src] = nil
	PlayerWeaponWounds[src] = nil
end)
