local PlayerInjuries = {}
local PlayerWeaponWounds = {}
local QBCore = exports['qb-core']:GetCoreObject()
local doctorCount = 0
local doctorCalled = false
local Doctors = {}

-- 床位占用：`<hospitalIndex>:<bedId>` → src。放在服务端才能判断"谁能把这张床放出来"。
local BedOccupant = {}
-- 待回执的急救：目标 src → 发起急救的 src（`CanHelp` 只认这条回执）。
local PendingAid = {}
-- 最近被服务端复活/送进院的玩家：`resetHungerThirst` 只在这个窗口内放行。
local RecentlyRevived = {}
-- `ambulanceAlert` / `SendDoctorAlert` 的按玩家冷却
local AlertCooldown = {}

local REVIVE_WINDOW_SECONDS = 180

local function bedKey(hospitalIndex, bedId)
	return tostring(hospitalIndex) .. ':' .. tostring(bedId)
end

-- 在职 EMS 的唯一判定入口（闸门按 net_event_guard_helpers.json 登记）
local function isOnDutyEMS(src, Player)
	Player = Player or QBCore.Functions.GetPlayer(src)
	if not Player then return false end
	local job = Player.PlayerData and Player.PlayerData.job
	if type(job) ~= 'table' then return false end
	return job.name == 'ambulance' and job.onduty == true
end

-- 只有服务端自己登记过的医生能注销。**不看 onduty**：qb-core 下班流程是
-- 先把 `job.onduty` 置 false、再通知客户端 -> 客户端才补发 RemoveDoctor，
-- 用 isOnDutyEMS 会把合法注销全挡掉，计数只增不减（只剩掉线那条路能减）。
local function isRegisteredDoctor(src)
	return Doctors[src] == true
end

local function markRevived(src)
	RecentlyRevived[src] = os.time()
end

local function inReviveWindow(src)
	local at = RecentlyRevived[src]
	if not at then return false end
	return (os.time() - at) <= REVIVE_WINDOW_SECONDS
end

-- Events

-- Compatibility with txAdmin Menu's heal options.
-- This is an admin only server side event that will pass the target player id or -1.
AddEventHandler('txAdmin:events:healedPlayer', function(eventData)
	if GetInvokingResource() ~= 'monitor' or type(eventData) ~= 'table' or type(eventData.id) ~= 'number' then
		return
	end

	if eventData.id == -1 then
		-- txAdmin 的 heal all：-1 不是一个玩家，得把所有人都标进窗口，
		-- 否则他们在客户端 `ResetAll()` 里的 resetHungerThirst 会被拒。
		for _, target in pairs(QBCore.Functions.GetQBPlayers()) do
			if target and target.PlayerData then markRevived(target.PlayerData.source) end
		end
	else
		markRevived(eventData.id)
	end
	TriggerClientEvent('hospital:client:Revive', eventData.id)
	TriggerClientEvent('hospital:client:HealInjuries', eventData.id, 'full')
end)

-- 复活权限的唯一判定入口（闸门按 net_event_guard_helpers.json 登记；
-- 调用点必须是 `if not CanRevive(Player, src) then ... return end` 形状）
local function CanRevive(Player, src)
	if not Player then return false end
	local isEMS = Player.PlayerData.job.name == 'ambulance' and Player.PlayerData.job.onduty
	if isEMS then return true end
	if not QBCore.Functions.HasItem(src, 'firstaid', 1) then return false end
	if not Config.RequireMedicalCert then return true end
	local certs = Player.PlayerData.metadata['cert_status'] or {}
	return certs['medical'] == 'held'
end

RegisterNetEvent('hospital:server:SendToBed', function(bedId, isRevive, hospitalIndex)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	-- 🔒 Security: 限流 — 防止客户端高频刷扣款
	if _bedCooldowns == nil then _bedCooldowns = {} end
	local now = os.time()
	if _bedCooldowns[src] and (now - _bedCooldowns[src]) < 30 then return end

	-- 🔒 索引校验：bedId / hospitalIndex 都是客户端传的，直接索引会把服务端打崩
	bedId = tonumber(bedId)
	hospitalIndex = tonumber(hospitalIndex)
	if not bedId or not hospitalIndex then return end
	local hospital = Config.Locations['hospital'][hospitalIndex]
	local bed = hospital and hospital['beds'] and hospital['beds'][bedId]
	if not bed then return end

	-- 只有校验通过才记冷却（非法索引不该把自己锁 30 秒）
	_bedCooldowns[src] = now

	BedOccupant[bedKey(hospitalIndex, bedId)] = src
	TriggerClientEvent('hospital:client:SendToBed', src, bedId, bed, isRevive)
	TriggerClientEvent('hospital:client:SetBed', -1, bedId, true, hospitalIndex)
	Player.Functions.RemoveMoney('bank', Config.BillCost, 'respawned-at-hospital')
	exports['qb-banking']:AddMoney('ambulance', Config.BillCost, 'Player treatment')
	TriggerClientEvent('hospital:client:SendBillEmail', src, Config.BillCost, Config.Locations['hospital'][hospitalIndex]['name'])
end)

RegisterNetEvent('hospital:server:RespawnAtHospital', function(hospitalIndex)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	-- 🔒 索引校验：客户端传的 hospitalIndex 只在合法范围内使用
	hospitalIndex = tonumber(hospitalIndex) or 1
	if not Config.Locations['hospital'][hospitalIndex] then hospitalIndex = 1 end
	markRevived(src)
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
				BedOccupant[bedKey(hospitalIndex, i)] = src
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
		BedOccupant[bedKey(hospitalIndex, 1)] = src
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
	if type(text) ~= 'string' then return end
	-- 🔒 文案来自客户端：截断 + 15 秒冷却，否则一个人能拿它刷屏所有在职 EMS
	text = text:sub(1, 200)
	local now = os.time()
	if AlertCooldown[src] and (now - AlertCooldown[src]) < 15 then return end
	AlertCooldown[src] = now
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
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	id = tonumber(id)
	hospitalIndex = tonumber(hospitalIndex)
	if not id or not hospitalIndex then return end
	local key = bedKey(hospitalIndex, id)
	local occupant = BedOccupant[key]
	-- 🔒 只有占用者本人（或收床的在职 EMS）能把这张床放出来；
	--    原来任何人传任意床号就能让全服的床显示空闲。
	if occupant and occupant ~= src then
		-- 收床要走"在职 EMS"这条独立判定（单独一行，闸门按 deny-early 形状核对）
		if not isOnDutyEMS(src, Player) then return end
	end
	BedOccupant[key] = nil
	-- 顺手清掉这个玩家残留的占用记录：客户端的 hospitalLocation 可能是旧值（换过院），
	-- 键对不上就会留下"永远被占"的床位。
	for otherKey, owner in pairs(BedOccupant) do
		if owner == src then BedOccupant[otherKey] = nil end
	end
	TriggerClientEvent('hospital:client:SetBed', -1, id, false, hospitalIndex)
end)

RegisterNetEvent('hospital:server:SyncInjuries', function(data)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	-- 🔒 只写**自己**的 metadata，但内容仍来自客户端：必须是表、字段必须有界，
	--    否则一次 `isBleeding = 1e9` 就能让 HUD 与后续治疗判定错乱，甚至把 metadata 撑爆。
	if type(data) ~= 'table' then return end
	if data.limbs ~= nil and type(data.limbs) ~= 'table' then return end
	local bleeding = tonumber(data.isBleeding) or 0
	if bleeding < 0 then bleeding = 0 elseif bleeding > 100 then bleeding = 100 end
	local sanitized = { limbs = data.limbs or {}, isBleeding = bleeding }
	Player.Functions.SetMetaData('injuries', sanitized)
	PlayerInjuries[src] = sanitized
end)

RegisterNetEvent('hospital:server:SetWeaponDamage', function(data)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	-- 🔒 同上：自己身上的弹伤，但数值必须有界
	if type(data) ~= 'table' then return end
	local sanitized = {}
	for bone, value in pairs(data) do
		if type(bone) == 'string' then
			local amount = tonumber(value)
			if amount and amount >= 0 and amount <= 1000 then
				sanitized[bone] = amount
			end
		end
	end
	Player.Functions.SetMetaData('weaponwounds', sanitized)
	PlayerWeaponWounds[Player.PlayerData.source] = sanitized
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
	if not Player then return end

	-- 🔒 deny-early：非在职 EMS 直接拒绝（闸门要求先拒绝后干活）
	if Player.PlayerData.job.name ~= 'ambulance' or not Player.PlayerData.job.onduty then
		TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_ems'), 'error')
		return
	end

	local Patient = QBCore.Functions.GetPlayer(playerId)
	if not Patient then return end

	-- 🔧 科室权限检查: 完全治愈（full）仅 SURGERY 科室可执行
	local dept = exports['custom-career']:GetPlayerIdentity(src)
	local deptName = dept and dept.department or Config.DefaultDepartment
	local deptConfig = Config.Departments[deptName]

	exports['qb-inventory']:RemoveItem(src, 'bandage', 1, false, 'hospital:server:TreatWounds')
	TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['bandage'], 'remove')

	-- 治疗也算"刚被服务端救过"：客户端 `HealInjuries('full')` 会走 ResetAll()，
	-- 里面包含 resetHungerThirst —— 不标记的话术后饥饿/口渴不会重置。
	markRevived(Patient.PlayerData.source)
	if deptConfig and deptConfig.allowSurgery then
		TriggerClientEvent('hospital:client:HealInjuries', Patient.PlayerData.source, 'full')
		print(('[EMS-TREAT] SURGERY doctor %s fully healed patient %s'):format(GetPlayerName(src), GetPlayerName(playerId)))
	else
		-- 急诊科 (EMERGENCY) 只能用绷带止血, 发送 partial 而非 full
		TriggerClientEvent('hospital:client:HealInjuries', Patient.PlayerData.source, 'partial')
		TriggerClientEvent('QBCore:Notify', src, ('[%s] 仅能实施紧急止血 — 完全治愈需 SURGERY 科室'):format(deptConfig and deptConfig.label or deptName), 'primary')
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
	-- 🔒 只认服务端自己数过的人：`Doctors[src]` 是 AddDoctor 时（已校验在职 EMS）登记的。
	--    原来只看客户端传的 `job == 'ambulance'`，任何玩家都能把 doctorCount 减到 0。
	if not isRegisteredDoctor(src) then return end
	Doctors[src] = nil
	doctorCount = doctorCount - 1
	if doctorCount < 0 then doctorCount = 0 end
	TriggerClientEvent('hospital:client:SetDoctorCount', -1, doctorCount)
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
	if not Player then return end
	local Patient = QBCore.Functions.GetPlayer(playerId)
	if not Patient then return end

	local oldMan = isOldMan or false

	-- 🔒 deny-early：既不是在职 EMS，也没有 firstaid + 医疗执照 → 拒绝
	if not CanRevive(Player, src) then
		local reason = '无 EMS 在职身份，且缺少 firstaid 或医疗执业执照 (medical_cert)'
		TriggerEvent('qb-log:server:CreateLog', 'ambulancejob', 'Revive Blocked', 'orange',
			string.format('%s (src=%s) tried to revive player %s — %s', GetPlayerName(src), src, GetPlayerName(playerId), reason))
		TriggerClientEvent('QBCore:Notify', src, ('你没有权限复活他人（%s）'):format(reason), 'error')
		return
	end

	if oldMan then
		if not Player.Functions.RemoveMoney('cash', 5000, 'revived-player') then
			TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_enough_money'), 'error')
			return
		end
	end

	exports['qb-inventory']:RemoveItem(src, 'firstaid', 1, false, 'hospital:server:RevivePlayer')
	TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['firstaid'], 'remove')
	markRevived(Patient.PlayerData.source)
	TriggerClientEvent('hospital:client:Revive', Patient.PlayerData.source)
end)

RegisterNetEvent('hospital:server:SendDoctorAlert', function(hospitalName)
	local src = source
	if type(hospitalName) ~= 'string' then return end
	-- 🔒 院名来自客户端：必须在配置里存在，否则这条广播就是伪造的
	local valid = false
	for _, hospital in pairs(Config.Locations['hospital'] or {}) do
		if type(hospital) == 'table' and hospital['name'] == hospitalName then
			valid = true
			break
		end
	end
	if not valid then return end
	-- 🔒 按玩家冷却：原来只有一个全局 `doctorCalled`，谁先按下谁就能把它锁住
	--    `Config.DocCooldown` 分钟，把真正的呼叫全挡掉。
	local now = os.time()
	if AlertCooldown['doctorCall:' .. tostring(src)] then
		if (now - AlertCooldown['doctorCall:' .. tostring(src)]) < 30 then return end
	end
	AlertCooldown['doctorCall:' .. tostring(src)] = now
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
	if not isOnDutyEMS(src, Player) and not QBCore.Functions.HasItem(src, 'firstaid', 1) then
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
	-- 记下"这次急救由谁发起"：`CanHelp` 只认这条回执，别的玩家不能替人回答
	PendingAid[tonumber(targetId)] = src
	TriggerClientEvent('hospital:client:CanHelp', targetId, src)
end)

RegisterNetEvent('hospital:server:CanHelp', function(helperId, canHelp)
	local src = source
	helperId = tonumber(helperId)
	if not helperId then return end
	-- 🔒 只有被 `UseFirstAid` 问过的那个人能回答：否则任何玩家都能凭空让服务端
	--    给任意 helper 发一条"可以施救"，配合客户端流程就能伪造治疗。
	if PendingAid[src] ~= helperId then return end
	PendingAid[src] = nil
	if canHelp then
		TriggerClientEvent('hospital:client:HelpPerson', helperId, src)
	else
		TriggerClientEvent('QBCore:Notify', helperId, Lang:t('error.cant_help'), 'error')
	end
end)

RegisterNetEvent('hospital:server:removeBandage', function()
	-- 只动 caller 自己的背包：source 不来自参数，越权面为零
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	exports['qb-inventory']:RemoveItem(src, 'bandage', 1, false, 'hospital:server:removeBandage')
end)

RegisterNetEvent('hospital:server:removeIfaks', function()
	-- 只动 caller 自己的背包：source 不来自参数，越权面为零
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	exports['qb-inventory']:RemoveItem(src, 'ifaks', 1, false, 'hospital:server:removeIfaks')
end)

RegisterNetEvent('hospital:server:removePainkillers', function()
	-- 只动 caller 自己的背包：source 不来自参数，越权面为零
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	exports['qb-inventory']:RemoveItem(src, 'painkillers', 1, false, 'hospital:server:removePainkillers')
end)

RegisterNetEvent('hospital:server:resetHungerThirst', function()
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	-- 🔒 这个事件等于把饥饿/口渴直接拉满：只允许"刚被服务端复活/送进院"的玩家调用，
	--    否则任何玩家随时发一次就等于免费吃饭喝水。
	if not inReviveWindow(src) and Player.PlayerData.metadata['isdead'] ~= true then
		return
	end

	Player.Functions.SetMetaData('hunger', 100)
	Player.Functions.SetMetaData('thirst', 100)

	TriggerClientEvent('hud:client:UpdateNeeds', source, 100, 100)
end)

RegisterNetEvent('qb-ambulancejob:server:stash', function()
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	if not Player then return end
	-- 🔒 客户端的 `job = 'ambulance'` 只是菜单过滤条件（可绕过）：
	--    服务端必须自己确认在职 EMS，否则任何玩家都能开一个"救护队储物柜"。
	if not isOnDutyEMS(src, Player) then return end
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
	if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
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
	-- 控制台 (source=0) 或玩家在本帧刚掉线时 GetPlayer 返回 nil；直接索引会抛
	-- "attempt to index a nil value (local 'Player')"。控制台没有可通知的客户端，
	-- 所以只打日志（TriggerClientEvent 传 0 会触发 native 参数 null 错误）。
	if not Player then
		print(('[qb-ambulancejob] 命令忽略了无玩家上下文的调用 (source=%s)'):format(tostring(src)))
		return
	end
	if Player.PlayerData.job.name == 'ambulance' then
		TriggerClientEvent('hospital:client:CheckStatus', src)
	else
		TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_ems'), 'error')
	end
end)

QBCore.Commands.Add('heal', Lang:t('info.heal_player'), {}, false, function(source, _)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	-- 控制台 (source=0) 或玩家在本帧刚掉线时 GetPlayer 返回 nil；直接索引会抛
	-- "attempt to index a nil value (local 'Player')"。控制台没有可通知的客户端，
	-- 所以只打日志（TriggerClientEvent 传 0 会触发 native 参数 null 错误）。
	if not Player then
		print(('[qb-ambulancejob] 命令忽略了无玩家上下文的调用 (source=%s)'):format(tostring(src)))
		return
	end
	if Player.PlayerData.job.name == 'ambulance' then
		TriggerClientEvent('hospital:client:TreatWounds', src)
	else
		TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_ems'), 'error')
	end
end)

QBCore.Commands.Add('revivep', Lang:t('info.revive_player'), {}, false, function(source, _)
	local src = source
	local Player = QBCore.Functions.GetPlayer(src)
	-- 控制台 (source=0) 或玩家在本帧刚掉线时 GetPlayer 返回 nil；直接索引会抛
	-- "attempt to index a nil value (local 'Player')"。控制台没有可通知的客户端，
	-- 所以只打日志（TriggerClientEvent 传 0 会触发 native 参数 null 错误）。
	if not Player then
		print(('[qb-ambulancejob] 命令忽略了无玩家上下文的调用 (source=%s)'):format(tostring(src)))
		return
	end
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
			-- 客户端 adminHeal 会调 resetHungerThirst，先进窗口
			markRevived(Player.PlayerData.source)
			TriggerClientEvent('hospital:client:adminHeal', Player.PlayerData.source)
		else
			TriggerClientEvent('QBCore:Notify', src, Lang:t('error.not_online'), 'error')
		end
	else
		markRevived(src)
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
