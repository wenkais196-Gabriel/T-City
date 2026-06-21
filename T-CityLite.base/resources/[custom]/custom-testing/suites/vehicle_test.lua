-- suites/vehicle_test.lua — KeyManager 单元测试 (通过 exports)
-- /vtest

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

RegisterCommand('vtest', function(source)
    local passed, failed = 0, 0
    local function ok(name) passed = passed + 1; print(('^2  ✅ %s^7'):format(name)) end
    local function no(name, reason) failed = failed + 1; print(('^1  ❌ %s — %s^7'):format(name, reason or '')) end

    print('^3========================================^7')
    print('^3🧪 KeyManager 单元测试 (exports 方式)^7')
    print('^3========================================^7')

    local CV = exports['custom-vehicles']
    if not CV then
        print('^1❌ custom-vehicles exports 不可用^7')
        return
    end

    -- GiveKeys + HasKeys
    CV:GiveKeys('TEST_VFT_001', 'CID_TEST_A')
    if CV:HasKeys('TEST_VFT_001', 'CID_TEST_A') then ok('GiveKeys → HasKeys') else no('GiveKeys → HasKeys', '') end

    -- 多持有者
    CV:GiveKeys('TEST_VFT_001', 'CID_TEST_B')
    if CV:HasKeys('TEST_VFT_001', 'CID_TEST_B') then ok('多持有者共享') else no('多持有者', '') end

    -- RemoveKeys
    CV:RemoveKeys('TEST_VFT_001', 'CID_TEST_B')
    if not CV:HasKeys('TEST_VFT_001', 'CID_TEST_B') then ok('RemoveKeys') else no('RemoveKeys', '') end

    -- 车牌规范化
    CV:GiveKeys('  ABC-123  ', 'CID_TEST_C')
    if CV:HasKeys('ABC-123', 'CID_TEST_C') then ok('车牌规范化') else no('车牌规范化', '') end

    -- 临时钥匙
    CV:GiveTempKeys('TEMP_VFT', 'CID_TEST_D')
    if CV:HasKeys('TEMP_VFT', 'CID_TEST_D') then ok('临时钥匙 GiveTempKeys') else no('临时钥匙', '') end
    CV:ClearTempKeys('CID_TEST_D')
    if not CV:HasKeys('TEMP_VFT', 'CID_TEST_D') then ok('ClearTempKeys 清退') else no('ClearTempKeys', '') end

    -- 车主
    CV:SetOwner('OWNER_VFT', 'CID_TEST_E')
    local owner = CV:GetOwner('OWNER_VFT')
    if owner == 'CID_TEST_E' and CV:HasKeys('OWNER_VFT', 'CID_TEST_E') then ok('SetOwner → GetOwner') else no('SetOwner', ('owner=%s'):format(tostring(owner))) end

    -- GetKeyHolders
    local h = CV:GetKeyHolders('OWNER_VFT')
    if type(h) == 'table' then ok(('GetKeyHolders (%d人)'):format(count(h))) else no('GetKeyHolders', '') end

    -- Stats
    local s = CV:KeyManagerStats()
    if s and s.vehicles > 0 then ok(('Stats (%d车/%d人)'):format(s.vehicles, s.total_holders)) else no('Stats', '') end

    -- 清理
    CV:RemoveKeys('TEST_VFT_001', 'CID_TEST_A')
    CV:RemoveKeys('OWNER_VFT', 'CID_TEST_E')
    CV:RemoveKeys('ABC-123', 'CID_TEST_C')

    local total = passed + failed
    print(('^3📊 %d/%d 通过 (%.0f%%)^7'):format(passed, total, total > 0 and passed/total*100 or 0))

    if source and source > 0 then
        TriggerClientEvent('QBCore:Notify', source, ('KeyManager: %d/%d 通过'):format(passed, total), total == passed and 'success' or 'error')
    end
end, true)

print('[custom-testing] ✅ 载具测试已加载 — /vtest')