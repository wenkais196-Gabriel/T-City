QBCore = exports['qb-core']:GetCoreObject() -- Used Globally
inJail = false
jailTime = 0
currentJob = nil
CellsBlip = nil
GuideBlip = nil
TimeBlip = nil
ShopBlip = nil
local insidecanteen = false
local insidefreedom = false
local canteen_ped = 0
local freedom_ped = 0
local freedom
local canteen

-- Functions

--- This will create the blips for the cells, time check and shop
--- @return nil
local function CreateCellsBlip()
	if CellsBlip then
		RemoveBlip(CellsBlip)
	end
	CellsBlip = AddBlipForCoord(Config.Locations['yard'].x, Config.Locations['yard'].y, Config.Locations['yard'].z)

	SetBlipSprite(CellsBlip, 238)
	SetBlipDisplay(CellsBlip, 4)
	SetBlipScale(CellsBlip, 0.8)
	SetBlipAsShortRange(CellsBlip, true)
	SetBlipColour(CellsBlip, 4)
	BeginTextCommandSetBlipName('STRING')
	AddTextComponentSubstringPlayerName(Lang:t('info.cells_blip'))
	EndTextCommandSetBlipName(CellsBlip)

	if TimeBlip then
		RemoveBlip(TimeBlip)
	end
	TimeBlip = AddBlipForCoord(Config.Locations['freedom'].x, Config.Locations['freedom'].y, Config.Locations['freedom'].z)

	SetBlipSprite(TimeBlip, 466)
	SetBlipDisplay(TimeBlip, 4)
	SetBlipScale(TimeBlip, 0.8)
	SetBlipAsShortRange(TimeBlip, true)
	SetBlipColour(TimeBlip, 4)
	BeginTextCommandSetBlipName('STRING')
	AddTextComponentSubstringPlayerName(Lang:t('info.freedom_blip'))
	EndTextCommandSetBlipName(TimeBlip)
end

-- Add clothes to prisioner

local function ApplyClothes()
	local playerPed = PlayerPedId()
	if DoesEntityExist(playerPed) then
		Citizen.CreateThread(function()
			SetPedArmour(playerPed, 0)
			ClearPedBloodDamage(playerPed)
			ResetPedVisibleDamage(playerPed)
			ClearPedLastWeaponDamage(playerPed)
			ResetPedMovementClipset(playerPed, 0)
			local gender = QBCore.Functions.GetPlayerData().charinfo.gender
			if gender == 0 then
				TriggerEvent('qb-clothing:client:loadOutfit', Config.Uniforms.male)
			else
				TriggerEvent('qb-clothing:client:loadOutfit', Config.Uniforms.female)
			end
		end)
	end
end


-- Events

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
	QBCore.Functions.GetPlayerData(function(PlayerData)
		if PlayerData.metadata['injail'] > 0 then
			TriggerEvent('prison:client:Enter', PlayerData.metadata['injail'])
		end
	end)

	QBCore.Functions.TriggerCallback('prison:server:IsAlarmActive', function(active)
		if active then
			TriggerEvent('prison:client:JailAlarm', true)
		end
	end)

	if DoesEntityExist(canteen_ped) or DoesEntityExist(freedom_ped) then return end

	local pedModel = `s_m_m_armoured_01`

	RequestModel(pedModel)
	while not HasModelLoaded(pedModel) do
		Wait(0)
	end

	freedom_ped = CreatePed(0, pedModel, Config.Locations['freedom'].x, Config.Locations['freedom'].y, Config.Locations['freedom'].z, Config.Locations['freedom'].w, false, true)
	FreezeEntityPosition(freedom_ped, true)
	SetEntityInvincible(freedom_ped, true)
	SetBlockingOfNonTemporaryEvents(freedom_ped, true)
	TaskStartScenarioInPlace(freedom_ped, 'WORLD_HUMAN_CLIPBOARD', 0, true)

	if not Config.UseTarget then return end

	exports['qb-target']:AddTargetEntity(freedom_ped, {
		options = {
			{
				type = 'client',
				event = 'prison:client:Leave',
				icon = 'fas fa-clipboard',
				label = Lang:t('info.target_freedom_option'),
				canInteract = function()
					return inJail
				end
			}
		},
		distance = 2.5,
	})
end)

AddEventHandler('onResourceStart', function(resource)
	if resource ~= GetCurrentResourceName() then return end
	Wait(100)
	if LocalPlayer.state['isLoggedIn'] then
		QBCore.Functions.GetPlayerData(function(PlayerData)
			if PlayerData.metadata['injail'] > 0 then
				TriggerEvent('prison:client:Enter', PlayerData.metadata['injail'])
			end
		end)
	end

	QBCore.Functions.TriggerCallback('prison:server:IsAlarmActive', function(active)
		if not active then return end
		TriggerEvent('prison:client:JailAlarm', true)
	end)

	if DoesEntityExist(canteen_ped) or DoesEntityExist(freedom_ped) then return end

	local pedModel = `s_m_m_armoured_01`

	RequestModel(pedModel)
	while not HasModelLoaded(pedModel) do
		Wait(0)
	end

	freedom_ped = CreatePed(0, pedModel, Config.Locations['freedom'].x, Config.Locations['freedom'].y, Config.Locations['freedom'].z, Config.Locations['freedom'].w, false, true)
	FreezeEntityPosition(freedom_ped, true)
	SetEntityInvincible(freedom_ped, true)
	SetBlockingOfNonTemporaryEvents(freedom_ped, true)
	TaskStartScenarioInPlace(freedom_ped, 'WORLD_HUMAN_CLIPBOARD', 0, true)

	if not Config.UseTarget then return end

	exports['qb-target']:AddTargetEntity(freedom_ped, {
		options = {
			{
				type = 'client',
				event = 'prison:client:Leave',
				icon = 'fas fa-clipboard',
				label = Lang:t('info.target_freedom_option'),
				canInteract = function()
					return inJail
				end
			}
		},
		distance = 2.5,
	})
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
	inJail = false
	currentJob = nil
	RemoveBlip(currentBlip)
end)



--- 监狱工作 blip（电工岗位）
local jobBlips = {}
local function CreateJobBlip(create)
	for _, blip in ipairs(jobBlips) do RemoveBlip(blip) end
	jobBlips = {}
	if not create then return end
	local positions = Config.Locations.jobs[currentJob]
	if not positions then return end
	for _, pos in ipairs(positions) do
		local blip = AddBlipForCoord(pos.x, pos.y, pos.z)
		SetBlipSprite(blip, 566)
		SetBlipDisplay(blip, 4)
		SetBlipScale(blip, 0.7)
		SetBlipColour(blip, 5)
		SetBlipAsShortRange(blip, true)
		BeginTextCommandSetBlipName('STRING')
		AddTextComponentSubstringPlayerName('监狱工作（减刑）')
		EndTextCommandSetBlipName(blip)
		jobBlips[#jobBlips + 1] = blip
	end
end

--- 自由门指引 blip：让囚犯一眼看到出狱点
local function CreateGuideBlip()
	if GuideBlip then RemoveBlip(GuideBlip) end
	local c = Config.Locations.freedom
	GuideBlip = AddBlipForCoord(c.x, c.y, c.z)
	SetBlipSprite(GuideBlip, 1)
	SetBlipDisplay(GuideBlip, 4)
	SetBlipScale(GuideBlip, 1.0)
	SetBlipColour(GuideBlip, 3)
	SetBlipAsShortRange(GuideBlip, false)
	SetBlipRoute(GuideBlip, true)
	SetBlipRouteColour(GuideBlip, 3)
	BeginTextCommandSetBlipName('STRING')
	AddTextComponentSubstringPlayerName('出狱点（刑满后按 E）')
	EndTextCommandSetBlipName(GuideBlip)
end

RegisterCommand('prison', function()
	if not inJail then
		QBCore.Functions.Notify('你不在监狱中', 'error')
		return
	end
	QBCore.Functions.Notify(('剩余刑期：%d 分钟。刑满后到自由门按 E 出狱。'):format(jailTime), 'primary', 8000)
	SetNewWaypoint(Config.Locations.freedom.x, Config.Locations.freedom.y)
end, false)

RegisterNetEvent('prison:client:WorkReductionAck', function(remaining)
    remaining = math.max(0, math.floor(tonumber(remaining) or 0))
    jailTime = remaining
    QBCore.Functions.Notify(('完成工作：减刑 2 分钟，剩余 %d 分钟'):format(remaining), 'success', 8000)
    if remaining <= 0 and inJail then
        Wait(1500)
        if inJail then TriggerEvent('prison:client:Leave') end
    end
end)

RegisterNetEvent('prison:client:SyncJailTime', function(remaining)
    remaining = math.max(0, math.floor(tonumber(remaining) or 0))
    jailTime = remaining
    if remaining <= 0 and inJail then
        TriggerEvent('prison:client:Leave')
    end
end)

RegisterNetEvent('prison:client:Enter', function(time)
	local invokingResource = GetInvokingResource()
	if invokingResource and invokingResource ~= 'qb-policejob' and invokingResource ~= 'custom-police' and invokingResource ~= 'custom-justice' and invokingResource ~= 'qb-ambulancejob' and invokingResource ~= GetCurrentResourceName() then
		-- Use QBCore.Debug here for a quick and easy way to print to the console to grab your attention with this message
		QBCore.Debug({ ('Player with source %s tried to execute prison:client:Enter manually or from another resource which is not authorized to call this, invokedResource: %s'):format(GetPlayerServerId(PlayerId()), invokingResource) })
		return
	end

	QBCore.Functions.Notify(Lang:t('error.injail', { Time = time }), 'error')

	TriggerEvent('chat:addMessage', {
		color = { 3, 132, 252 },
		multiline = true,
		args = { 'SYSTEM', Lang:t('info.seized_property') }
	})
	DoScreenFadeOut(500)
	while not IsScreenFadedOut() do
		Wait(10)
	end
	local RandomStartPosition = Config.Locations.spawns[math.random(1, #Config.Locations.spawns)]
	SetEntityCoords(PlayerPedId(), RandomStartPosition.coords.x, RandomStartPosition.coords.y, RandomStartPosition.coords.z - 0.9, 0, 0, 0, false)
	SetEntityHeading(PlayerPedId(), RandomStartPosition.coords.w)
	Wait(500)

	inJail = true
	jailTime = time
	local tempJobs = {}
	local i = 1
	for k in pairs(Config.Locations.jobs) do
		tempJobs[i] = k
		i += 1
	end
	currentJob = tempJobs[math.random(1, #tempJobs)]
	CreateJobBlip(true)
	ApplyClothes()
	TriggerServerEvent('prison:server:SetJailStatus', jailTime)
	TriggerServerEvent('prison:server:SaveJailItems', jailTime)
	TriggerServerEvent('InteractSound_SV:PlayOnSource', 'jail', 0.5)
	CreateCellsBlip()
	CreateGuideBlip()
	SetNewWaypoint(Config.Locations.freedom.x, Config.Locations.freedom.y)
	TriggerEvent('chat:addMessage', {
		color = { 3, 132, 252 },
		multiline = true,
		args = { 'SYSTEM', ('你已被收监，刑期 %d 分钟。地图蓝色标记 = 自由门；刑满后走到那里按 E 出狱，刑满 5 秒后也会自动释放。/prison 可随时查看剩余刑期。'):format(time) }
	})
	QBCore.Functions.Notify('刑满后到自由门按 E，或等待自动释放', 'primary', 12000)
	Wait(2000)
	DoScreenFadeIn(1000)
	QBCore.Functions.Notify(Lang:t('error.do_some_work', { currentjob = Config.Jobs[currentJob] }), 'error')
end)

RegisterNetEvent('prison:client:Leave', function()
	if jailTime > 0 then
		-- The local minute tick can lag behind the DB clock (work reduction,
		-- restart, sweep). Ask the authority before refusing the exit.
		TriggerServerEvent('prison:server:RequestRelease')
		QBCore.Functions.Notify('正在核对刑期…', 'primary', 3000)
	else
		jailTime = 0
		TriggerServerEvent('prison:server:SetJailStatus', 0)
		TriggerServerEvent('prison:server:GiveJailItems')
		TriggerEvent('chat:addMessage', {
			color = { 3, 132, 252 },
			multiline = true,
			args = { 'SYSTEM', Lang:t('info.received_property') }
		})
		inJail = false
		RemoveBlip(currentBlip)
		RemoveBlip(CellsBlip)
		CellsBlip = nil
		RemoveBlip(TimeBlip)
		TimeBlip = nil
		RemoveBlip(ShopBlip)
		ShopBlip = nil
		if GuideBlip then RemoveBlip(GuideBlip) GuideBlip = nil end
		QBCore.Functions.Notify(Lang:t('success.free_'))
		DoScreenFadeOut(500)
		while not IsScreenFadedOut() do
			Wait(10)
		end
		TriggerServerEvent('qb-clothes:loadPlayerSkin')
		SetEntityCoords(PlayerPedId(), Config.Locations['outside'].x, Config.Locations['outside'].y, Config.Locations['outside'].z, false, false, false, false)
		SetEntityHeading(PlayerPedId(), Config.Locations['outside'].w)
		Wait(500)
		DoScreenFadeIn(1000)
	end
end)

RegisterNetEvent('prison:client:UnjailPerson', function()
	-- Server authority may expire/reduce the sentence before the local
	-- countdown does; release whenever the player is still flagged in jail.
	if inJail or jailTime > 0 then
		TriggerServerEvent('prison:server:SetJailStatus', 0)
		TriggerServerEvent('prison:server:GiveJailItems')
		TriggerEvent('chat:addMessage', {
			color = { 3, 132, 252 },
			multiline = true,
			args = { 'SYSTEM', Lang:t('info.received_property') }
		})
		inJail = false
		if GuideBlip then RemoveBlip(GuideBlip) GuideBlip = nil end
		RemoveBlip(currentBlip)
		RemoveBlip(CellsBlip)
		CellsBlip = nil
		RemoveBlip(TimeBlip)
		TimeBlip = nil
		RemoveBlip(ShopBlip)
		ShopBlip = nil
		QBCore.Functions.Notify(Lang:t('success.free_'))
		DoScreenFadeOut(500)
		while not IsScreenFadedOut() do
			Wait(10)
		end
		TriggerServerEvent('qb-clothes:loadPlayerSkin')
		SetEntityCoords(PlayerPedId(), Config.Locations['outside'].x, Config.Locations['outside'].y, Config.Locations['outside'].z, false, false, false, false)
		SetEntityHeading(PlayerPedId(), Config.Locations['outside'].w)
		Wait(500)
		DoScreenFadeIn(1000)
	end
end)

-- Threads

CreateThread(function()
	TriggerEvent('prison:client:JailAlarm', false)
	while true do
		local sleep = 1000
		if jailTime > 0 and inJail then
			Wait(1000 * 60)
			sleep = 0
			if jailTime > 0 and inJail then
				jailTime -= 1
				if jailTime <= 0 then
					jailTime = 0
					QBCore.Functions.Notify('刑期已满，5 秒后自动释放（也可走到自由门按 E）', 'success', 10000)
					TriggerServerEvent('prison:server:SetJailStatus', 0)
					Wait(5000)
					if inJail and jailTime <= 0 then
						TriggerEvent('prison:client:Leave')
					end
				else
					QBCore.Functions.Notify(('剩余刑期 %d 分钟 — 自由门按 E 出狱'):format(jailTime), 'primary', 6000)
					TriggerServerEvent('prison:server:SetJailStatus', jailTime)
				end
			end
		end
		Wait(sleep)
	end
end)


-- 监狱工作：走到电工岗位按 E，完成 8 秒工作减刑 2 分钟（60 秒冷却）
local lastWorkAt = 0
CreateThread(function()
	while true do
		local sleep = 1000
		if inJail and currentJob then
			local coords = GetEntityCoords(PlayerPedId())
			for _, pos in ipairs(Config.Locations.jobs[currentJob] or {}) do
				local target = vector3(pos.x, pos.y, pos.z)
				if #(coords - target) < 2.2 then
					sleep = 0
					DrawMarker(1, target.x, target.y, target.z - 0.9, 0, 0, 0, 0, 0, 0, 1.2, 1.2, 0.6, 0, 200, 0, 120, false, true, 2, false, nil, nil, false)
					if IsControlJustReleased(0, 38) then
						if GetGameTimer() - lastWorkAt < 60000 then
							QBCore.Functions.Notify('刚干过一轮，休息一下再来', 'error')
						else
							lastWorkAt = GetGameTimer()
							QBCore.Functions.Progressbar('prison_job', '修理监狱电路…', 8000, false, true, {
								disableMovement = true, disableCarMovement = true,
								disableMouse = false, disableCombat = true,
							}, {}, {}, {}, function()
								-- The server owns the clock; it confirms the remaining
								-- time after applying the reduction to ends_at.
								TriggerServerEvent('prison:server:WorkReduction', 2)
							end, function() end)
						end
					end
				end
			end
		end
		Wait(sleep)
	end
end)

CreateThread(function()
	if not Config.UseTarget then
		freedom = BoxZone:Create(vector3(Config.Locations['freedom'].x, Config.Locations['freedom'].y, Config.Locations['freedom'].z), 2.75, 2.75, {
			name = 'freedom',
			debugPoly = false,
		})
		freedom:onPlayerInOut(function(isPointInside)
			insidefreedom = isPointInside
			if isPointInside then
				CreateThread(function()
					while insidefreedom do
						if IsControlJustReleased(0, 38) then
							exports['qb-core']:KeyPressed()
							exports['qb-core']:HideText()
							TriggerEvent('prison:client:Leave')
							break
						end
						Wait(0)
					end
				end)
				exports['qb-core']:DrawText('[E] Check Time', 'left')
			else
				exports['qb-core']:HideText()
			end
		end)
	end
end)
