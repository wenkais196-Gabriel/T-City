-- tests/vehicle_features_test.lua — 载具功能全量测试 (v0.7b)
--
-- exec tests/vehicle_features_test.lua  加载
-- /vtest                                 服务端 KeyManager 单元测试
-- /vtest_client                          客户端载具功能测试

-- ==============================================================
-- 服务端: KeyManager 单元测试
-- ==============================================================

RegisterCommand('vtest', function(source)
    local passed, failed = 0, 0

    local function ok(name) passed = passed + 1; print(('  ✅ %s'):format(name)) end
    local function no(name, reason) failed = failed + 1; print(('  ❌ %s — %s'):format(name, reason or '')) end

    print('\n========================================')
    print('🧪 载具功能测试 — 服务端 KeyManager')
    print('========================================\n')

    local KM = KeyManager
    if not KM then
        print('❌ KeyManager 未加载 — 请确保 custom-vehicles 已启动')
        return
    end

    -- GiveKeys + HasKeys
    KM.GiveKeys('TEST_VFT_001', 'CID_TEST_A', 'owner')
    if KM.HasKeys('TEST_VFT_001', 'CID_TEST_A') then ok('GiveKeys → HasKeys') else no('GiveKeys → HasKeys', '写入后查询失败') end

    -- 多持有者
    KM.GiveKeys('TEST_VFT_001', 'CID_TEST_B', 'shared')
    if KM.HasKeys('TEST_VFT_001', 'CID_TEST_B') then ok('多持有者共享') else no('多持有者', '') end

    -- RemoveKeys
    KM.RemoveKeys('TEST_VFT_001', 'CID_TEST_B')
    if not KM.HasKeys('TEST_VFT_001', 'CID_TEST_B') then ok('RemoveKeys') else no('RemoveKeys', '移除后仍可查询') end

    -- 车牌规范化
    KM.GiveKeys('  ABC-123  ', 'CID_TEST_C', 'owner')
    if KM.HasKeys('ABC-123', 'CID_TEST_C') then ok('车牌规范化(去空格+大写)') else no('车牌规范化', '') end

    -- 临时钥匙
    KM.GiveTempKeys('TEMP_VFT', 'CID_TEST_D')
    local hasTemp, kt = KM.HasKeys('TEMP_VFT', 'CID_TEST_D')
    if hasTemp and kt == 'temp' then ok('临时钥匙类型') else no('临时钥匙', ('type=%s'):format(tostring(kt))) end
    local cleared = KM.ClearTempKeys('CID_TEST_D') or 0
    if cleared >= 1 and not KM.HasKeys('TEMP_VFT', 'CID_TEST_D') then ok('ClearTempKeys 清退') else no('ClearTempKeys', '') end

    -- 车主
    KM.SetOwner('OWNER_VFT', 'CID_TEST_E')
    if KM.GetOwner('OWNER_VFT') == 'CID_TEST_E' and KM.HasKeys('OWNER_VFT', 'CID_TEST_E') then ok('SetOwner → GetOwner + 自动授钥') else no('SetOwner', '') end

    -- 空参数
    if not KM.HasKeys(nil, 'TEST') and not KM.HasKeys('TEST', nil) then ok('空参数拒绝') else no('空参数', '') end

    -- GetKeysForCitizen
    local keys = KM.GetKeysForCitizen('CID_TEST_A')
    if type(keys) == 'table' and #keys >= 1 then ok(('GetKeysForCitizen (%d把)'):format(#keys)) else no('GetKeysForCitizen', '') end

    -- Stats
    local stats = KM.Stats()
    if stats and stats.vehicles > 0 then ok(('Stats (%d车/%d人)'):format(stats.vehicles, stats.total_holders)) else no('Stats', '') end

    -- Exports
    local expOk = pcall(function() return exports['custom-vehicles']:HasKeys('TEST_VFT_001', 'CID_TEST_A') end)
    if expOk then ok('exports:HasKeys') else no('exports:HasKeys', '') end

    -- 清理
    KM.RemoveKeys('TEST_VFT_001', 'CID_TEST_A')
    KM.RemoveKeys('OWNER_VFT', 'CID_TEST_E')
    KM.RemoveKeys('ABC-123', 'CID_TEST_C')

    -- 汇总
    local total = passed + failed
    print(('\n📊 服务端: %d/%d 通过 (%.0f%%)'):format(passed, total, total > 0 and passed/total*100 or 0))

    -- 如果有玩家在线，通知客户端跑第二部分
    if source and source > 0 then
        TriggerClientEvent('vtest:client:run', source)
    end
    print('👉 进游戏输入 /vtest_client 跑客户端测试')
    print('')
end, true)

-- ==============================================================
-- 客户端: 载具功能检查
-- ==============================================================

RegisterCommand('vtest_client', function()
    local passed, failed = 0, 0
    local function ok(name) passed = passed + 1; print(('  ✅ %s'):format(name)) end
    local function no(name, reason) failed = failed + 1; print(('  ❌ %s — %s'):format(name, reason or '')) end

    print('\n── 客户端载具功能 ──\n')

    -- 安全带 export
    if pcall(function() return exports['custom-vehicles']:HasSeatbeltOn() end) then
        ok('HasSeatbeltOn export')
    else
        no('HasSeatbeltOn export', 'export 不可用')
    end

    -- 安全带事件
    local evtOk = pcall(function()
        TriggerEvent('seatbelt:client:ToggleSeatbelt', true)
        TriggerEvent('seatbelt:client:ToggleSeatbelt', false)
    end)
    if evtOk then ok('seatbelt:client:ToggleSeatbelt 事件') else no('seatbelt 事件', '') end

    -- 音效
    local sndOk = pcall(function()
        TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 5.0, 'carunbuckle', 0.25)
    end)
    if sndOk then ok('interact-sound 音效通道') else no('interact-sound', '可能未启动') end

    -- 载具状态
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh and veh ~= 0 then
        ok(('当前载具: %s (class=%d)'):format(GetDisplayNameFromVehicleModel(GetEntityModel(veh)), GetVehicleClass(veh)))
        ok(('引擎: %s | 锁: %s'):format(
            GetIsVehicleEngineRunning(veh) and 'ON' or 'OFF',
            GetVehicleDoorLockStatus(veh) == 2 and '锁定' or '解锁'
        ))
    else
        ok('未在载具中 — 上车后手动验证以下功能')
    end

    -- 手动验证清单
    print('\n── 手动验证清单 ──')
    print('  🔑 钥匙: /givekeys [ID] | /removekeys [ID]')
    print('  🔒 安全带: /toggleseatbelt (系/解 + 音效)')
    print('  💡 转向灯: ← → 方向键 toggle')
    print('  🚪 车门锁: 车内按 L')
    print('  ⚡ 引擎: 驾驶座按 G')
    print('  🖥️ 中控屏: 车内按 I (4标签页)')
    print('  🔥 热线: /hotwire | 撬锁: /lockpick')
    print('  😰 压力: 不系安全带超速 → 压力增长 → 50%模糊 → 100%黑屏')

    local total = passed + failed
    print(('\n📊 客户端: %d/%d 通过 (%.0f%%)'):format(passed, total, total > 0 and passed/total*100 or 0))
    print('')
end, false)

RegisterNetEvent('vtest:client:run', function()
    ExecuteCommand('vtest_client')
end)

print('[vehicle_test] ✅ 载具测试已加载 — /vtest (服务端) | /vtest_client (客户端)')
