-- Variables
local QBCore = exports['qb-core']:GetCoreObject()
local requiredItemsShowed = false
local requiredItems = { [1] = { name = QBCore.Shared.Items['cryptostick']['name'], image = QBCore.Shared.Items['cryptostick']['image'] } }

-- Functions

local function DrawText3Ds(coords, text)
	SetTextScale(0.35, 0.35)
	SetTextFont(4)
	SetTextProportional(1)
	SetTextColour(255, 255, 255, 215)
	BeginTextCommandDisplayText('STRING')
	SetTextCentre(true)
	AddTextComponentSubstringPlayerName(text)
	SetDrawOrigin(coords.x, coords.y, coords.z, 0)
	EndTextCommandDisplayText(0.0, 0.0)
	local factor = (string.len(text)) / 370
	DrawRect(0.0, 0.0 + 0.0125, 0.017 + factor, 0.03, 0, 0, 0, 75)
	ClearDrawOrigin()
end

local function ExchangeSuccess()
	TriggerServerEvent('qb-crypto:server:ExchangeSuccess', math.random(1, 10))
end

local function ExchangeFail()
	local Odd = 5
	local RemoveChance = math.random(1, Odd)
	local LosingNumber = math.random(1, Odd)
	if RemoveChance == LosingNumber then
		TriggerServerEvent('qb-crypto:server:ExchangeFail')
		TriggerServerEvent('qb-crypto:server:SyncReboot')
	end
end

local function SystemCrashCooldown()
	CreateThread(function()
		while Crypto.Exchange.RebootInfo.state do
			if (Crypto.Exchange.RebootInfo.percentage + 1) <= 100 then
				Crypto.Exchange.RebootInfo.percentage = Crypto.Exchange.RebootInfo.percentage + 1
				TriggerServerEvent('qb-crypto:server:Rebooting', true, Crypto.Exchange.RebootInfo.percentage)
			else
				Crypto.Exchange.RebootInfo.percentage = 0
				Crypto.Exchange.RebootInfo.state = false
				TriggerServerEvent('qb-crypto:server:Rebooting', false, 0)
			end
			Wait(1200)
		end
	end)
end

CreateThread(function()
	while true do
		local sleep = 5000
		if LocalPlayer.state.isLoggedIn then
			local ped = PlayerPedId()
			local pos = GetEntityCoords(ped)
			local dist = #(pos - Crypto.Exchange.coords)
			if dist < 15 then
				sleep = 5
				if dist < 1.5 then
					if not Crypto.Exchange.RebootInfo.state then
						DrawText3Ds(Crypto.Exchange.coords, Lang:t('text.enter_usb'))
						if not requiredItemsShowed then
							requiredItemsShowed = true
							TriggerEvent('qb-inventory:client:requiredItems', requiredItems, true)
						end

						if IsControlJustPressed(0, 38) then
							QBCore.Functions.TriggerCallback('qb-crypto:server:HasSticky', function(HasItem)
								if HasItem then
									local success = exports['qb-minigames']:Hacking(5, 30) -- code block size & seconds to solve
									if success then
										ExchangeSuccess()
									else
										ExchangeFail()
									end
								else
									QBCore.Functions.Notify(Lang:t('error.you_dont_have_a_cryptostick'), 'error')
								end
							end)
						end
					else
						DrawText3Ds(Crypto.Exchange.coords, Lang:t('text.system_is_rebooting', { rebootInfoPercentage = Crypto.Exchange.RebootInfo.percentage }))
					end
				else
					if requiredItemsShowed then
						requiredItemsShowed = false
						TriggerEvent('qb-inventory:client:requiredItems', requiredItems, false)
					end
				end
			end
		end
		Wait(sleep)
	end
end)

-- Events

RegisterNetEvent('qb-crypto:client:SyncReboot', function(state, percentage)
	-- 服务端广播现在带 state/percentage：false 表示"重启结束"，必须把本地状态一并清零，
	-- 否则 owner 收尾后其他客户端会把它当成"开始重启"，继续本地循环显示假重启。
	if type(state) == 'boolean' then
		Crypto.Exchange.RebootInfo.state = state
		Crypto.Exchange.RebootInfo.percentage = tonumber(percentage) or 0
	else
		-- 兼容旧调用（不带参数）＝ 开始重启
		Crypto.Exchange.RebootInfo.state = true
	end
	if Crypto.Exchange.RebootInfo.state then
		SystemCrashCooldown()
	end
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
	TriggerServerEvent('qb-crypto:server:FetchWorth')
	TriggerServerEvent('qb-crypto:server:GetRebootState')
end)

RegisterNetEvent('qb-crypto:client:UpdateCryptoWorth', function(crypto, amount, history)
	Crypto.Worth[crypto] = amount
	if history ~= nil then
		Crypto.History[crypto] = history
	end
end)

RegisterNetEvent('qb-crypto:client:GetRebootState', function(RebootInfo)
	-- 首次同步：true 与 false 都要落地（原来只在 true 时赋值，本地会残留"重启中"）
	if type(RebootInfo) ~= 'table' then return end
	Crypto.Exchange.RebootInfo.state = RebootInfo.state == true
	Crypto.Exchange.RebootInfo.percentage = tonumber(RebootInfo.percentage) or 0
	if Crypto.Exchange.RebootInfo.state then
		SystemCrashCooldown()
	end
end)
