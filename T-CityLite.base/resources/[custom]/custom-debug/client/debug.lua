-- =====================================================
--  custom-debug: 黑屏诊断 + 强制修复工具
--  指令一览:
--    /debugscreen  — 打印完整屏幕/相机/NUI 状态
--    /nuioff        — 强制关闭所有 NUI（发送隐藏消息给 multicharacter + spawn）
--    /camreset      — 强制停止脚本相机，切回游戏相机
--    /fullfix       — 综合修复：关NUI + 停相机 + 淡入 + 显示实体
--    /watchscreen   — 启动监控线程，每2秒打印一次状态（出现黑屏时实时追踪）
-- =====================================================

local watching = false

-- ===================================================
--  工具函数：收集完整状态快照
-- ===================================================
local function GetScreenSnapshot()
    local ped       = PlayerPedId()
    local fadedIn   = IsScreenFadedIn()
    local fadedOut  = IsScreenFadedOut()
    local fading    = IsScreenFadingIn() or IsScreenFadingOut()
    local camCount  = GetNumberOfActiveScriptCams and GetNumberOfActiveScriptCams() or -1
    local renderCam = IsCamRendering and IsCamRendering() or -1
    local pedVisible = IsEntityVisible(ped)
    local pedFrozen  = IsEntityPositionFrozen(ped)
    local nuiFocus   = IsNuiFocused and IsNuiFocused() or -1
    local coords     = GetEntityCoords(ped)
    local health     = GetEntityHealth(ped)
    local loggedIn   = LocalPlayer.state.isLoggedIn

    return {
        fadedIn    = fadedIn,
        fadedOut   = fadedOut,
        fading     = fading,
        camCount   = camCount,
        renderCam  = renderCam,
        pedVisible = pedVisible,
        pedFrozen  = pedFrozen,
        nuiFocus   = nuiFocus,
        health     = health,
        loggedIn   = loggedIn,
        coordsZ    = coords.z,
    }
end

local function PrintSnapshot(label, s)
    print(('^3[custom-debug] === %s ===^7'):format(label))
    print(('^3[custom-debug]  屏幕淡入: %s  |  屏幕淡出: %s  |  正在渐变: %s^7')
        :format(tostring(s.fadedIn), tostring(s.fadedOut), tostring(s.fading)))
    print(('^3[custom-debug]  脚本相机数: %s  |  渲染中: %s^7')
        :format(tostring(s.camCount), tostring(s.renderCam)))
    print(('^3[custom-debug]  Ped可见: %s  |  Ped冻结: %s  |  血量: %s  |  Z轴: %.2f^7')
        :format(tostring(s.pedVisible), tostring(s.pedFrozen), tostring(s.health), s.coordsZ))
    print(('^3[custom-debug]  NUI焦点: %s  |  已登录: %s^7')
        :format(tostring(s.nuiFocus), tostring(s.loggedIn)))
end

-- ===================================================
--  /debugscreen — 一次性诊断
-- ===================================================
RegisterCommand('debugscreen', function()
    local s = GetScreenSnapshot()
    PrintSnapshot('DEBUGSCREEN 快照', s)

    -- 同时发 NUI 消息给 debug 页面，显示覆盖层
    SendNUIMessage({
        action = 'showDebug',
        fadedIn    = s.fadedIn,
        fadedOut   = s.fadedOut,
        pedVisible = s.pedVisible,
        pedFrozen  = s.pedFrozen,
        nuiFocus   = s.nuiFocus,
        health     = s.health,
        coordsZ    = s.coordsZ,
        loggedIn   = s.loggedIn,
    })

    -- 5秒后自动隐藏 debug 覆盖层
    SetTimeout(5000, function()
        SendNUIMessage({ action = 'hideDebug' })
    end)
end, false)

-- ===================================================
--  /nuioff — 强制关闭 multicharacter + spawn 的 NUI
-- ===================================================
RegisterCommand('nuioff', function()
    print('^2[custom-debug] 正在强制关闭所有 NUI 层...^7')

    -- 关闭 qb-multicharacter 的 NUI
    SendNUIMessage({ action = 'ui', toggle = false })  -- 发给自己（无效，但不报错）

    -- 通过 TriggerEvent 让 multicharacter 自己关闭
    -- qb-multicharacter 的 openCharMenu(false) 会关闭 NUI
    -- 这里直接向 multicharacter 的 NUI context 发消息需要用 exports 或事件

    -- 方法：用 SetNuiFocus 解除焦点，然后通知各 resource
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)

    -- 通知 multicharacter 关闭（通过 Lua 事件触发客户端函数）
    TriggerEvent('qb-multicharacter:client:closeNUI')

    print('^2[custom-debug] NuiFocus 已强制释放，closeNUI 事件已触发^7')

    -- 延迟 500ms 再触发一次 spawn UI 关闭
    SetTimeout(500, function()
        SendNUIMessage({ action = 'showUi', status = false })
        print('^2[custom-debug] qb-spawn NUI showUi=false 已发送^7')
    end)
end, false)

-- ===================================================
--  /camreset — 强制停止所有脚本相机
-- ===================================================
RegisterCommand('camreset', function()
    print('^2[custom-debug] 正在停止所有脚本相机...^7')
    RenderScriptCams(false, false, 0, true, true)
    DestroyAllCams(true)
    print('^2[custom-debug] 脚本相机已全部停止并销毁^7')
end, false)

-- ===================================================
--  /fullfix — 综合修复（按顺序执行所有修复步骤）
-- ===================================================
RegisterCommand('fullfix', function()
    print('^2[custom-debug] === 开始综合修复 ===^7')

    local s1 = GetScreenSnapshot()
    PrintSnapshot('修复前状态', s1)

    -- Step 1: 关闭 NUI 焦点
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    TriggerEvent('qb-multicharacter:client:closeNUI')

    -- Step 2: 强制关闭多角色 NUI（用 SendNUIMessage 发到 multicharacter）
    -- 注意：SendNUIMessage 只能发给当前 resource 的 NUI
    -- multicharacter 的 NUI 需要它自己接收消息
    -- 下面用 exports 方式尝试
    if GetResourceState('qb-multicharacter') == 'started' then
        -- 触发 closeNUI 事件让 multicharacter 自己处理
        TriggerEvent('qb-multicharacter:client:closeNUI')
        print('^2[custom-debug] Step1: qb-multicharacter closeNUI 触发完成^7')
    end

    -- Step 3: 停止脚本相机
    Wait(100)
    RenderScriptCams(false, false, 0, true, true)
    DestroyAllCams(true)
    print('^2[custom-debug] Step2: 脚本相机已停止^7')

    -- Step 4: 显示和解冻 Ped
    Wait(100)
    local ped = PlayerPedId()
    SetEntityVisible(ped, true, false)
    FreezeEntityPosition(ped, false)
    print('^2[custom-debug] Step3: Ped 可见性和冻结状态已重置^7')

    -- Step 5: 强制淡入
    Wait(100)
    DoScreenFadeIn(500)
    print('^2[custom-debug] Step4: DoScreenFadeIn 已调用^7')

    -- Step 6: 验证结果
    Wait(700)
    local s2 = GetScreenSnapshot()
    PrintSnapshot('修复后状态', s2)

    if s2.fadedIn then
        print('^2[custom-debug] ✓ 修复成功！屏幕已淡入^7')
    else
        print('^1[custom-debug] ✗ 警告：屏幕仍未淡入！问题可能来自 NUI 覆盖层，请检查 F8 日志^7')
        print('^1[custom-debug]   → 尝试执行 /nuioff 关闭 NUI，或查看是否有 NUI 页面遮挡^7')
    end
end, false)

-- ===================================================
--  /watchscreen — 持续监控（每2秒输出一次状态）
-- ===================================================
RegisterCommand('watchscreen', function()
    if watching then
        watching = false
        print('^3[custom-debug] 屏幕监控已停止^7')
        return
    end

    watching = true
    print('^3[custom-debug] 屏幕监控已启动（再次输入 /watchscreen 停止）^7')

    CreateThread(function()
        local tick = 0
        while watching do
            tick = tick + 1
            local s = GetScreenSnapshot()
            -- 只在状态异常时打印（fadedIn=false 且不在渐变中）
            if not s.fadedIn then
                PrintSnapshot('WATCH #' .. tick .. ' ⚠️ 检测到黑屏！', s)
            else
                print(('[custom-debug] WATCH #%d: OK (fadedIn=true, pedVisible=%s, nuiFocus=%s)')
                    :format(tick, tostring(s.pedVisible), tostring(s.nuiFocus)))
            end
            Wait(2000)
        end
    end)
end, false)

-- ===================================================
--  NUI 回调（接收调试 NUI 页面的关闭请求）
-- ===================================================
RegisterNUICallback('closeDebug', function(_, cb)
    SendNUIMessage({ action = 'hideDebug' })
    cb('ok')
end)

-- ===================================================
--  /colortest — 红色覆盖层测试
--  如果能看到红色 → 黑屏来自游戏底层（非NUI）
--  如果仍然黑色 → 有更高层的NUI覆盖了我们
-- ===================================================
RegisterCommand('colortest', function()
    print('^3[custom-debug] 正在显示红色测试覆盖层（5秒）...^7')
    print('^3[custom-debug] 如果能看到红色 = 黑屏来自游戏引擎层（相机/渲染问题）^7')
    print('^3[custom-debug] 如果仍然黑屏 = 有NUI层在我们上面覆盖（其他resource的NUI）^7')
    SendNUIMessage({ action = 'colorTest', color = '#ff0000' })
    SetTimeout(5000, function()
        SendNUIMessage({ action = 'colorTest', color = 'transparent' })
        print('^3[custom-debug] 红色覆盖层已关闭^7')
    end)
end, false)

-- ===================================================
--  /gamecam — 检查游戏相机状态
-- ===================================================
RegisterCommand('gamecam', function()
    local isGameplayCamRendering = IsGameplayCamRendering and IsGameplayCamRendering() or 'native不存在'
    local camActive = GetActiveCamCoord and GetActiveCamCoord() or 'N/A'
    print(('^3[custom-debug] IsGameplayCamRendering: %s^7'):format(tostring(isGameplayCamRendering)))
    -- 用 pcall 调用，防止 native 不存在崩溃
    local ok1, v1 = pcall(IsGameplayCamRendering)
    local ok2, v2 = pcall(GetFollowPedCamZoomLevel)
    local ok3, v3 = pcall(GetGameplayCamRot, 2)
    print(('^3[custom-debug] pcall IsGameplayCamRendering: ok=%s val=%s^7'):format(tostring(ok1), tostring(v1)))
    print(('^3[custom-debug] pcall GetFollowPedCamZoomLevel: ok=%s val=%s^7'):format(tostring(ok2), tostring(v2)))
    print(('^3[custom-debug] pcall GetGameplayCamRot: ok=%s val=%s^7'):format(tostring(ok3), tostring(v3)))
    -- 额外检查：TimecycleModifier（黑屏可能来自过度的 blur/dark modifier）
    local ok4, v4 = pcall(GetTimecycleModifierName)
    print(('^3[custom-debug] TimecycleModifier: ok=%s val=%s^7'):format(tostring(ok4), tostring(v4)))
end, false)

print('^2[custom-debug] 黑屏诊断工具已加载！^7')
print('^2[custom-debug] 指令: /debugscreen | /nuioff | /camreset | /fullfix | /watchscreen^7')
print('^2[custom-debug] 新增: /colortest（红色NUI层测试）| /gamecam（相机+Timecycle诊断）^7')

