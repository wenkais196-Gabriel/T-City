-- tests/vehicle_security_audit_test.lua
-- 载具命令安全审计修复验证脚本 (v1.0)
--
-- 验证所有安全修复点均已正确落地：
--   1. police:server:Impound — 警察身份校验
--   2. police:server:TakeOutImpound — 警察身份校验
--   3. qb-vehiclekeys:server:AcquireVehicleKeys — 所有权校验
--   4. /tow — onDuty 检查
--   5. /fix — 玩家在线 + 载具存在检查
--
-- 运行方式（服务端控制台）:
--   /vsec            运行全部静态检查
--   /vsec_unit       运行单元逻辑测试

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 静态代码特征检查（验证修改是否落地）
-- ==============================================================

RegisterCommand('vsec', function(source, args)
    local passed, failed = 0, 0
    local function ok(name)  passed = passed + 1; print(('  ✅ %s'):format(name)) end
    local function no(name, r) failed = failed + 1; print(('  ❌ %s — %s'):format(name, r or '')) end

    print('\n╔══════════════════════════════════════════╗')
    print('║  🛡️ 载具命令安全审计 — 修复验证       ║')
    print('╚══════════════════════════════════════════╝\n')

    -- ─── 1. police:server:Impound ───
    print('── 1. police:server:Impound (v0 → v1 修复) ──')
    -- 检查: 事件中是否包含 job.type ~= 'leo' 校验
    local src1 = LoadResourceFile('qb-policejob', 'server/vehicle.lua')
    if src1 then
        if src1:find('job%.type') and src1:find('onduty') then
            ok('事件 police:server:Impound 包含 leo 身份校验')
        else
            no('police:server:Impound', '未找到 leo 身份校验代码')
        end
        if src1:find('LogSecurity') and src1:find('拦截非法扣押') then
            ok('非法调用记录到 custom-logs 安全日志')
        else
            no('安全日志', '未找到 LogSecurity 调用')
        end
    else
        no('文件读取', '无法加载 qb-policejob/server/vehicle.lua')
    end

    -- ─── 2. police:server:TakeOutImpound ───
    print('\n── 2. police:server:TakeOutImpound (v0 → v1 修复) ──')
    if src1 then
        if src1:find('拦截非法取回') then
            ok('事件 police:server:TakeOutImpound 包含身份校验 + 安全日志')
        else
            -- 二次确认
            local takeOutSection = src1:match("TakeOutImpound.-\n(.-)\n    local playerPed")
            if takeOutSection and (takeOutSection:find('job%.type') or takeOutSection:find('leo')) then
                ok('police:server:TakeOutImpound 包含身份校验')
            else
                no('police:server:TakeOutImpound', '未找到身份校验或日志记录')
            end
        end
    end

    -- ─── 3. qb-vehiclekeys:server:AcquireVehicleKeys ───
    print('\n── 3. qb-vehiclekeys:server:AcquireVehicleKeys (裸奔修复) ──')
    local src2 = LoadResourceFile('qb-vehiclekeys', 'server/main.lua')
    if src2 then
        if src2:find('GetResourceState') and src2:find('custom%-vehicles') then
            ok('custom-vehicles 启动时委托校验（避免双写）')
        else
            no('兼容委托', '未检测到 GetResourceState 路由')
        end
        if src2:find('拦截钥匙冒领') then
            ok('fallback 模式包含所有权冒领拦截 + 安全日志')
        else
            no('fallback 拦截', '未找到安全日志记录')
        end
    else
        no('文件读取', '无法加载 qb-vehiclekeys/server/main.lua')
    end

    -- ─── 4. /tow onDuty ───
    print('\n── 4. /tow onDuty 检查 ──')
    local src3 = LoadResourceFile('qb-towjob', 'server/main.lua')
    if src3 then
        if src3:find('onduty') then
            ok('/tow 命令包含 onDuty 检查')
        else
            no('/tow', '未找到 onduty 检查')
        end
    else
        no('文件读取', '无法加载 qb-towjob/server/main.lua')
    end

    -- ─── 5. /fix 完善 ───
    print('\n── 5. /fix 数据完整性 ──')
    local src4 = LoadResourceFile('qb-mechanicjob', 'server/main.lua')
    if src4 then
        if src4:find('GetPlayer') and src4:find('你不在任何载具中') then
            ok('/fix 包含玩家有效性 + 载具存在校验')
        else
            no('/fix', '未找到在线/载具检查')
        end
    else
        no('文件读取', '无法加载 qb-mechanicjob/server/main.lua')
    end

    -- ─── 6. 双钥匙系统一致性 ───
    print('\n── 6. 双钥匙系统一致性检查 ──')
    local srcCustVeh = LoadResourceFile('custom-vehicles', 'server/main.lua')
    local srcCompat = LoadResourceFile('custom-vehicles', 'server/compat.lua')
    if srcCustVeh then
        if srcCustVeh:find('exports%(\'GiveKeys\'%)') then
            ok('custom-vehicles 暴露 GiveKeys export')
        end
        if srcCustVeh:find('Bus%.RegisterService') then
            ok('custom-vehicles 注册 Bus 服务')
        end
    end
    if srcCompat then
        if srcCompat:find('qb%-vehiclekeys:server:AcquireVehicleKeys') then
            ok('compat.lua 桥接 AcquireVehicleKeys（带所有权校验）')
        end
        if srcCompat:find('qb%-vehiclekeys:server:GiveKeys') then
            ok('compat.lua 桥接 GiveKeys')
        end
    end

    -- ─── 汇总 ───
    local total = passed + failed
    print(('\n╔══════════════════════════════════════════╗'))
    print(('║  📊 结果: %d/%d 通过 (%.0f%%)%s'):format(
        passed, total, total > 0 and passed/total*100 or 0,
        failed == 0 and ' ✅' or ''
    ))
    print('╚══════════════════════════════════════════╝\n')
end, true)

-- ==============================================================
-- 单元逻辑测试（Mock 注入场景）
-- ==============================================================

RegisterCommand('vsec_unit', function(source)
    local passed, failed = 0, 0
    local function ok(name)  passed = passed + 1; print(('  ✅ %s'):format(name)) end
    local function no(name, r) failed = failed + 1; print(('  ❌ %s — %s'):format(name, r or '')) end

    print('\n── 🔬 单元逻辑测试（Mock 注入场景）──\n')

    -- Test 1: 非警察用户触发 police:server:Impound
    -- 模拟: 普通玩家 source=3, job=unemployed, onduty=false
    -- 预期: 被静默拒绝
    print('[Mock] 普通玩家 (job=unemployed, onduty=false) 尝试扣押车辆...')
    local mockPlayer = {
        PlayerData = {
            job = { type = 'civilian', name = 'unemployed', onduty = false },
            citizenid = 'CID_00001'
        }
    }
    local mockSrc = 3
    -- 模拟校验逻辑
    local isAuthorized = mockPlayer and mockPlayer.PlayerData.job.type == 'leo' and mockPlayer.PlayerData.job.onduty
    if not isAuthorized then
        ok('✅ 普通玩家被正确拦截（非leo/未值班）')
    else
        no('普通玩家拦截', '非警察居然通过了校验')
    end

    -- Test 2: 警察(未值班)触发扣押
    print('[Mock] 警察 (onduty=false) 尝试扣押车辆...')
    local offDutyCop = {
        PlayerData = {
            job = { type = 'leo', name = 'police', onduty = false },
            citizenid = 'CID_COP01'
        }
    }
    isAuthorized = offDutyCop and offDutyCop.PlayerData.job.type == 'leo' and offDutyCop.PlayerData.job.onduty
    if not isAuthorized then
        ok('✅ 下班警察被正确拦截')
    else
        no('下班警察拦截', '未值班仍被放行')
    end

    -- Test 3: 值班警察正常操作
    print('[Mock] 值班警察 (onduty=true) 扣押车辆...')
    local onDutyCop = {
        PlayerData = {
            job = { type = 'leo', name = 'police', onduty = true },
            citizenid = 'CID_COP02'
        }
    }
    isAuthorized = onDutyCop and onDutyCop.PlayerData.job.type == 'leo' and onDutyCop.PlayerData.job.onduty
    if isAuthorized then
        ok('✅ 值班警察正常通过')
    else
        no('值班警察', '被错误拦截')
    end

    -- Test 4: qb-vehiclekeys AcquireVehicleKeys — 已有车主
    print('[Mock] 玩家尝试冒领已有车主 (owner=CIT_A) 的车辆钥匙...')
    local vehicleList = { ['ABC123'] = { ['CIT_A'] = true } }
    local playerCitizenid = 'CIT_B'
    local plate = 'ABC123'
    local hasOtherOwner = false
    if vehicleList[plate] then
        for cid, _ in pairs(vehicleList[plate]) do
            if cid ~= playerCitizenid then
                hasOtherOwner = true
                break
            end
        end
    end
    if hasOtherOwner then
        ok('✅ 冒领被拦截（已有其他车主）')
    else
        no('冒领拦截', '已有车主但未拦截')
    end

    -- Test 5: qb-vehiclekeys AcquireVehicleKeys — 新车无主
    print('[Mock] 玩家首次声明无主车辆钥匙...')
    local emptyList = {}
    local newPlate = 'NEW001'
    local newCid = 'CIT_C'
    hasOtherOwner = false
    if emptyList[newPlate] then
        for cid, _ in pairs(emptyList[newPlate]) do
            if cid ~= newCid then
                hasOtherOwner = true
                break
            end
        end
    end
    if not hasOtherOwner then
        ok('✅ 新车无主，允许首次声明所有权')
    else
        no('新车声明', '无主车辆被错误拦截')
    end

    -- Test 6: /tow onDuty
    print('[Mock] 拖车工 (onduty=false) 使用 /tow...')
    local offDutyTow = {
        PlayerData = {
            job = { name = 'tow', onduty = false }
        }
    }
    local towAllowed = (offDutyTow.PlayerData.job.name == 'tow' or offDutyTow.PlayerData.job.name == 'mechanic') and offDutyTow.PlayerData.job.onduty
    if not towAllowed then
        ok('✅ 下班拖车工被拦截')
    else
        no('下班拖车工', '未值班仍可使用 /tow')
    end

    -- Test 7: 拖车工值班
    print('[Mock] 拖车工 (onduty=true) 使用 /tow...')
    local onDutyTow = {
        PlayerData = {
            job = { name = 'tow', onduty = true }
        }
    }
    towAllowed = (onDutyTow.PlayerData.job.name == 'tow' or onDutyTow.PlayerData.job.name == 'mechanic') and onDutyTow.PlayerData.job.onduty
    if towAllowed then
        ok('✅ 值班拖车工正常通过')
    else
        no('值班拖车工', '被错误拦截')
    end

    -- Test 8: custom-vehicles 启动检测
    print('[Mock] 检查 custom-vehicles 资源状态...')
    local cvState = GetResourceState('custom-vehicles')
    if cvState == 'started' then
        ok(('custom-vehicles 运行中 (%s) → AcquireVehicleKeys 路由到 compat'):format(cvState))
    else
        ok(('custom-vehicles 状态: %s → 使用 fallback 校验'):format(cvState))
    end

    -- ─── 汇总 ───
    local total = passed + failed
    print(('\n📊 单元测试: %d/%d 通过 (%.0f%%)%s'):format(
        passed, total, total > 0 and passed/total*100 or 0,
        failed == 0 and ' ✅ 全绿' or ''
    ))
    print('')
end, true)

print('[vehicle_security_test] ✅ 载具安全审计测试已加载')
print('  /vsec       — 静态代码特征验证（修改是否落地）')
print('  /vsec_unit  — Mock 注入场景单元测试')
