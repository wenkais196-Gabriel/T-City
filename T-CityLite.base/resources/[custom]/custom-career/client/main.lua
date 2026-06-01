local function GetPlayerIdentity()
    return LocalPlayer.state.career_identity
end

exports('GetPlayerIdentity', GetPlayerIdentity)

-- 监听状态包发生变化时抛出客户端事件（方便未来 NUI 界面或 Svelte 手机系统接收信号进行刷新）
AddStateBagChangeHandler("career_identity", ("player:%s"):format(GetPlayerServerId()), function(bagName, key, value, reserved, replicated)
    if value then
        TriggerEvent("custom-career:client:IdentityUpdated", value)
    end
end)
