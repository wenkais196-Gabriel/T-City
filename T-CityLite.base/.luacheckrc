-- .luacheckrc — FiveM 项目忽略全局变量伪报
std = "lua54"

globals = {
    -- FiveM
    "exports", "RegisterNetEvent", "TriggerClientEvent", "TriggerServerEvent",
    "TriggerEvent", "AddEventHandler", "CreateThread", "Wait", "Player",
    "Entity", "GetConvar", "source",
    -- GTA Natives
    "GetVehicleNumberPlateText", "NetworkGetNetworkIdFromEntity",
    "PlayerPedId", "IsPedInAnyVehicle",
    "SetVehicleDoorShut", "SetVehicleDoorOpen", "GetVehicleDoorAngleRatio",
    "GetEntityCoords", "GetEntityBoneIndexByName", "GetWorldPositionOfEntityBone",
    "GetVehiclePedIsIn", "GetVehicleClass", "GetVehicleEngineHealth",
    "SetVehicleEngineHealth", "SetVehicleSteeringScale", "SetVehicleHandbrake",
    "SetVehicleEngineOn", "SetVehicleUndriveable", "GetEntitySpeed",
    "SetVehicleBoostActive", "SetVehicleCheatPowerIncrease",
    "AnimpostfxPlay", "AnimpostfxStop",
    "IsControlJustPressed", "IsControlJustReleased",
    "RequestNamedPtfxAsset", "HasNamedPtfxAssetLoaded",
    "NetworkDoesEntityExistWithNetworkId", "NetworkGetEntityFromNetworkId",
    "SetVehicleNitroEnabled",
    "SetVehicleFixed", "SetVehicleDeformationFixed", "SetVehicleDirtLevel",
    "SetVehicleTyreFixed", "FixVehicleWindow", "WashDecalsFromVehicle",
    "SetVehicleNumberPlateText", "SetEntityHeading", "SetVehicleFuelLevel",
    "TaskWarpPedIntoVehicle", "SetModelAsNoLongerNeeded",
    "IsModelInCdimage", "RequestModel", "HasModelLoaded",
    "CreateVehicle", "DeleteVehicle",
    "GetVehicleBodyHealth", "GetVehiclePetrolTankHealth",
    "SetVehicleBodyHealth", "SetVehiclePetrolTankHealth",
    "SetVehicleColours", "GetVehicleColours",
    "GetVehicleCustomPrimaryColour", "GetVehicleCustomSecondaryColour",
    "SetVehicleCustomPrimaryColour", "SetVehicleCustomSecondaryColour",
    "FreezeEntityPosition", "GetGameTimer",
    "GetVehicleMod", "GetNumVehicleMods", "SetVehicleMod",
    "ToggleVehicleMod", "IsToggleModOn", "GetVehicleModKit", "SetVehicleModKit",
    "GetVehiclePedIsUsing", "GetVehicleHandlingFloat", "GetVehicleHandlingInt",
    "SetVehicleHandlingFloat", "SetVehicleHandlingInt",
    "GetVehicleDoorLockStatus", "SetVehicleDoorsLocked",
    "GetPedInVehicleSeat", "GetVehicleNumberPlateText",
    "GetPlayerPed", "GetPlayers", "DropPlayer",
    "SetNuiFocus", "SendNUIMessage",
    "SetNuiFocusKeepInput",
    -- Libraries
    "QBCore", "Config", "Bus", "MySQL", "json", "vec3", "Lang",
    -- fxmanifest
    "fx_version", "game", "lua54", "author", "description", "version",
    "dependencies", "shared_scripts", "server_scripts", "client_scripts",
    "ui_page", "files", "data_file",
}

-- 忽略行长度 (FiveM 事件字符串较长)
ignore = { "631" }
