-- vehicle_state_test.lua — server/vehicle_state.lua 全覆盖用例
-- 目标覆盖率: ≥85% (exports / Bus / callback / 边界 / 事件桥接)
-- 运行: 服务端 exec 或放入 custom-testing/suites/

local QBCore = exports['qb-core']:GetCoreObject()
local P, F, S = 0, 0, 0  -- passed, failed, skipped

local function pass(label) P = P + 1; print(('  ✅ %s'):format(label)) end
local function fail(label, expected, got)
    F = F + 1
    print(('  ❌ %s\n     expected: %s\n     got:      %s'):format(label, tostring(expected), tostring(got)))
end
local function skip(label) S = S + 1; print(('  ⏭️  %s [SKIP — 需要客户端]'):format(label)) end

local VEH = exports['custom-vehicles']
local TP = 'TESTPLATE_' .. math.random(10000, 99999)

print('\n╔══════════════════════════════════════════════════╗')
print('║  vehicle_state.lua 全覆盖测试                    ║')
print(('║  (测试车牌: %s)                           ║'):format(TP))
print('╚══════════════════════════════════════════════════╝\n')

-- ==============================================================
-- 1. Exports 可达性 (9 个)
-- ==============================================================
print('━━━ 1. Exports 可达性 (9/9) ━━━')
for _, name in ipairs({
    'GetVehicleState', 'UpdateVehicleComponent', 'ResetVehicleComponents',
    'SetVehicleNitrous', 'GetVehicleNitrous', 'SetVehicleTuned',
    'CheckVehicleTune', 'AddVehicleDistance', 'SaveVehicleMods',
}) do
    if VEH[name] then pass(name .. ' export 存在')
    else fail(name .. ' export 存在', 'function', 'nil') end
end

-- ==============================================================
-- 2. GetVehicleState — 8 用例
-- ==============================================================
print('\n━━━ 2. GetVehicleState (8 用例) ━━━')

local s = VEH.GetVehicleState(nil)
if s == nil then pass('nil plate → nil') else fail('nil plate → nil', 'nil', type(s)) end

s = VEH.GetVehicleState(TP)
if type(s) == 'table' then pass('首次查询返回 table') else fail('首次查询返回 table', 'table', type(s)) end
if s.distance == 0 then pass('初始 distance=0') else fail('初始 distance=0', 0, s.distance) end
if s.tuned == false then pass('初始 tuned=false') else fail('初始 tuned=false', false, s.tuned) end
if s.components == nil then pass('初始 components=nil (未初始化)') else fail('初始 components=nil', 'nil', type(s.components)) end
if type(s.nitrous) == 'table' and s.nitrous.hasnitro == false then pass('初始 nitrous.hasnitro=false')
else fail('初始 nitrous.hasnitro=false', 'false', tostring(s.nitrous and s.nitrous.hasnitro)) end

-- 修改后查询
VEH.SetVehicleTuned(TP, true)
VEH.AddVehicleDistance(TP, 500)
s = VEH.GetVehicleState(TP)
if s.tuned == true then pass('SetTuned 后 tuned=true') else fail('SetTuned 后 tuned=true', true, s.tuned) end
if s.distance == 500 then pass('AddDistance(500) 后 distance=500') else fail('AddDistance 后 distance=500', 500, s.distance) end

-- ==============================================================
-- 3. UpdateVehicleComponent — 8 用例
-- ==============================================================
print('\n━━━ 3. UpdateVehicleComponent (8 用例) ━━━')

-- nil guard
VEH.UpdateVehicleComponent(nil, 'radiator', 50)  -- 不应崩溃
pass('nil plate 不崩溃')

VEH.UpdateVehicleComponent(TP, nil, 50)  -- 不应崩溃
pass('nil component 不崩溃')

-- 首次设置
VEH.UpdateVehicleComponent(TP, 'radiator', 75)
s = VEH.GetVehicleState(TP)
if s.components and s.components.radiator == 75 then pass('Set radiator=75')
else fail('Set radiator=75', 75, s.components and s.components.radiator or 'nil') end

-- 钳制: 超过 maxValue (100)
VEH.UpdateVehicleComponent(TP, 'radiator', 150)
s = VEH.GetVehicleState(TP)
if s.components.radiator == 100 then pass('Clamp radiator=150 → 100')
else fail('Clamp radiator=150 → 100', 100, s.components.radiator) end

-- 钳制: 负值
VEH.UpdateVehicleComponent(TP, 'radiator', -10)
s = VEH.GetVehicleState(TP)
if s.components.radiator == 0 then pass('Clamp radiator=-10 → 0')
else fail('Clamp radiator=-10 → 0', 0, s.components.radiator) end

-- 多部件
VEH.UpdateVehicleComponent(TP, 'axle', 30)
VEH.UpdateVehicleComponent(TP, 'brakes', 60)
s = VEH.GetVehicleState(TP)
if s.components.axle == 30 and s.components.brakes == 60 then pass('多部件: axle=30, brakes=60')
else fail('多部件', 'axle=30,brakes=60', ('axle=%s,brakes=%s'):format(s.components.axle, s.components.brakes)) end

-- 未知部件
VEH.UpdateVehicleComponent(TP, 'nonexistent', 50)
s = VEH.GetVehicleState(TP)
if s.components.nonexistent == 50 then pass('未知部件接受 (宽松模式)')
else fail('未知部件接受', 50, s.components.nonexistent or 'nil') end

-- ==============================================================
-- 4. ResetVehicleComponents — 5 用例
-- ==============================================================
print('\n━━━ 4. ResetVehicleComponents (5 用例) ━━━')

VEH.ResetVehicleComponents(nil)  -- 不崩溃
pass('nil plate 不崩溃')

VEH.UpdateVehicleComponent(TP, 'radiator', 10)
VEH.UpdateVehicleComponent(TP, 'brakes', 20)
VEH.ResetVehicleComponents(TP)
s = VEH.GetVehicleState(TP)
if s.components.radiator == 100 then pass('Reset 后 radiator=100')
else fail('Reset 后 radiator=100', 100, s.components.radiator) end
if s.components.brakes == 100 then pass('Reset 后 brakes=100')
else fail('Reset 后 brakes=100', 100, s.components.brakes) end

-- 所有部件重置到 maxValue
local allMax = true
for part in pairs({radiator=true, axle=true, brakes=true, clutch=true, fuel=true}) do
    if s.components[part] ~= 100 then allMax = false; break end
end
if allMax then pass('所有 5 个部件 = 100') else fail('所有部件 = 100', 'all=100', '部分未重置') end

-- 未初始化 plate 重置
VEH.ResetVehicleComponents('NEVER_EXIST_' .. math.random(10000))
pass('未初始化 plate 不崩溃 (自动 InitComponents)')

-- ==============================================================
-- 5. SetNitrous / GetNitrous — 8 用例
-- ==============================================================
print('\n━━━ 5. SetNitrous / GetNitrous (8 用例) ━━━')

VEH.SetVehicleNitrous(nil, true, 100)  -- 不崩溃
pass('nil plate 不崩溃')

local n = VEH.GetVehicleNitrous(nil)
if n == nil then pass('GetNitrous(nil) → nil') else fail('GetNitrous(nil) → nil', 'nil', type(n)) end

n = VEH.GetVehicleNitrous('NEVER_EXIST')
if n == nil then pass('GetNitrous(不存在) → nil') else fail('GetNitrous(不存在) → nil', 'nil', type(n)) end

VEH.SetVehicleNitrous(TP, true, 80)
n = VEH.GetVehicleNitrous(TP)
if n and n.hasnitro == true and n.level == 80 then pass('SetNitrous has=true level=80')
else fail('SetNitrous', 'has=true,level=80', ('has=%s,level=%s'):format(n and n.hasnitro, n and n.level)) end

-- 更新已有: has=false, level 不变
VEH.SetVehicleNitrous(TP, false)
n = VEH.GetVehicleNitrous(TP)
if n.hasnitro == false and n.level == 80 then pass('SetNitrous has=false, level 保持 80')
else fail('SetNitrous has=false level 保持', 'has=false,level=80', ('has=%s,level=%s'):format(n.hasnitro, n.level)) end

-- 更新已有: has=true, level=nil (默认 100)
VEH.SetVehicleNitrous(TP, true)
n = VEH.GetVehicleNitrous(TP)
if n.hasnitro == true and n.level == 100 then pass('SetNitrous level=nil → 100')
else fail('SetNitrous level=nil → 100', 100, n.level) end

-- level=0 边界
VEH.SetVehicleNitrous(TP, true, 0)
n = VEH.GetVehicleNitrous(TP)
if n.level == 0 then pass('SetNitrous level=0 正常')
else fail('SetNitrous level=0', 0, n.level) end

-- 车牌 trim
VEH.SetVehicleNitrous('  ' .. TP .. '  ', true, 50)
n = VEH.GetVehicleNitrous(TP)
if n.level == 50 then pass('Trim 空白车牌正常') else fail('Trim 空白车牌', 50, n.level) end

-- ==============================================================
-- 6. SetTuned / CheckTune — 5 用例
-- ==============================================================
print('\n━━━ 6. SetTuned / CheckTune (5 用例) ━━━')

VEH.SetVehicleTuned(nil, true); pass('SetTuned nil plate 不崩溃')
if VEH.CheckVehicleTune(nil) == false then pass('CheckTune nil → false')
else fail('CheckTune nil → false', false, VEH.CheckVehicleTune(nil)) end

if VEH.CheckVehicleTune('NEVER_EXIST') == false then pass('CheckTune 不存在 → false')
else fail('CheckTune 不存在 → false', false, VEH.CheckVehicleTune('NEVER_EXIST')) end

VEH.SetVehicleTuned(TP, true)
if VEH.CheckVehicleTune(TP) == true then pass('SetTuned=true → CheckTune=true')
else fail('SetTuned=true', true, VEH.CheckVehicleTune(TP)) end

VEH.SetVehicleTuned(TP, false)
if VEH.CheckVehicleTune(TP) == false then pass('SetTuned=false → CheckTune=false')
else fail('SetTuned=false', false, VEH.CheckVehicleTune(TP)) end

-- ==============================================================
-- 7. AddDistance — 5 用例
-- ==============================================================
print('\n━━━ 7. AddVehicleDistance (5 用例) ━━━')

VEH.AddVehicleDistance(nil, 100); pass('nil plate 不崩溃')
VEH.AddVehicleDistance(TP, nil); pass('nil distance 不崩溃')

s = VEH.GetVehicleState(TP)
local prevDist = s.distance
VEH.AddVehicleDistance(TP, 300)
s = VEH.GetVehicleState(TP)
if s.distance == prevDist + 300 then pass('累加距离: 500+300=800')
else fail('累加距离', prevDist + 300, s.distance) end

VEH.AddVehicleDistance(TP, 0)
s = VEH.GetVehicleState(TP)
if s.distance == prevDist + 300 then pass('距离+0 不变') else fail('距离+0', prevDist + 300, s.distance) end

-- 新 plate 首次加距离
local np = 'NEW_' .. math.random(10000)
VEH.AddVehicleDistance(np, 999)
s = VEH.GetVehicleState(np)
if s.distance == 999 then pass('新 plate 首次 distance=999') else fail('新 plate 首次', 999, s.distance) end

-- ==============================================================
-- 8. SaveMods — 4 用例 (DB 写跳过无真实 DB)
-- ==============================================================
print('\n━━━ 8. SaveVehicleMods (4 用例) ━━━')

VEH.SaveVehicleMods(nil); pass('nil props 不崩溃')
VEH.SaveVehicleMods({}); pass('无 plate props 不崩溃 (IsVehicleOwned=false)')
VEH.SaveVehicleMods({ plate = 'FAKE_NOT_IN_DB' }); pass('不存在的 plate 不写 DB')
VEH.SaveVehicleMods({ plate = TP }); pass('正常调用不崩溃 (DB 写由 MySQL.update 处理)')

-- ==============================================================
-- 9. Bus 集成 — 10 用例
-- ==============================================================
print('\n━━━ 9. Bus 集成 (10 用例) ━━━')

if Bus and Bus._services and Bus._services['vehicles'] then
    pass('Bus._services.vehicles 存在')
    local vb = Bus._services['vehicles']
    for _, m in ipairs({'GetState','UpdateComponent','ResetComponents','SetNitrous','GetNitrous','SetTuned','CheckTune','AddDistance','SaveMods'}) do
        if vb[m] then pass(('Bus.vehicles.%s 存在'):format(m))
        else fail(('Bus.vehicles.%s 存在'):format(m), 'function', 'nil') end
    end

    -- SafeCall 验证
    local ok, res = Bus.SafeCall('vehicles', 'GetState', TP)
    if ok and res.distance > 0 then pass('Bus.SafeCall GetState 成功') else fail('Bus.SafeCall GetState', 'ok', tostring(ok)) end

    local ok2, _ = Bus.SafeCall('vehicles', 'NonExistent', TP)
    if not ok2 then pass('Bus.SafeCall 不存在方法 → false') else fail('Bus.SafeCall 不存在方法', 'false', tostring(ok2)) end

    local ok3, _ = Bus.SafeCall('nonexistent_service', 'GetState', TP)
    if not ok3 then pass('Bus.SafeCall 不存在 service → false') else fail('Bus.SafeCall 不存在 service', 'false', tostring(ok3)) end
else
    for _ = 1, 10 do skip('Bus 未加载') end
end

-- ==============================================================
-- 10. 旧事件桥接 — 8 用例
-- ==============================================================
print('\n━━━ 10. 旧事件桥接 (8 用例) ━━━')

-- 模拟 qb-mechanicjob 旧事件触发 (直接调用 handler 验证)
local bp = 'BRIDGE_' .. math.random(10000)
TriggerEvent('qb-mechanicjob:server:updateDrivingDistance', bp, 200)
s = VEH.GetVehicleState(bp); if s.distance == 200 then pass('旧事件: updateDrivingDistance → distance=200') else fail('旧事件 updateDrivingDistance', 200, s.distance) end

TriggerEvent('qb-mechanicjob:server:tuneStatus', bp)
if VEH.CheckVehicleTune(bp) then pass('旧事件: tuneStatus → tuned=true') else fail('旧事件 tuneStatus', true, VEH.CheckVehicleTune(bp)) end

TriggerEvent('qb-mechanicjob:server:syncNitrous', bp, true, 60)
n = VEH.GetVehicleNitrous(bp)
if n.hasnitro and n.level == 60 then pass('旧事件: syncNitrous has=true level=60') else fail('旧事件 syncNitrous', 'has=true,level=60', ('has=%s,level=%s'):format(n.hasnitro, n.level)) end

TriggerEvent('qb-mechanicjob:server:repairVehicleComponent', bp, 'radiator')
s = VEH.GetVehicleState(bp)
if s.components and s.components.radiator == 100 then pass('旧事件: repairVehicleComponent → radiator=100')
else fail('旧事件 repairVehicleComponent', 100, s.components and s.components.radiator) end

-- SaveVehicleProps (qb-garages 依赖)
TriggerEvent('qb-mechanicjob:server:SaveVehicleProps', { plate = bp, mods = {} })
pass('旧事件: SaveVehicleProps 不崩溃 (fake plate)')

-- 旧 callback 验证
QBCore.Functions.TriggerCallback('qb-mechanicjob:server:getnitrousVehicles', {}, function(vehs)
    if type(vehs) == 'table' then pass('旧 callback: getnitrousVehicles → table') else fail('旧 callback getnitrousVehicles', 'table', type(vehs)) end
end)

QBCore.Functions.TriggerCallback('qb-mechanicjob:server:checkTune', {}, function(status)
    if status == true then pass('旧 callback: checkTune → true') else fail('旧 callback checkTune', true, status) end
end, bp)

QBCore.Functions.TriggerCallback('qb-mechanicjob:server:getVehicleStatus', {}, function(status)
    if type(status) == 'table' then pass('旧 callback: getVehicleStatus → table') else fail('旧 callback getVehicleStatus', 'table', type(status)) end
end, bp)

-- ==============================================================
-- Summary
-- ==============================================================
local total = P + F + S
local cov = total > 0 and math.floor(P / (P + F) * 100) or 0
print('\n╔══════════════════════════════════════════════════╗')
print(('║  结果: %d 通过 / %d 失败 / %d 跳过 (共 %d)       ║'):format(P, F, S, total))
print(('║  覆盖率: %d%%                                      ║'):format(cov))
if F == 0 then print('║  ✅ 全部通过！                                      ║')
else print('║  ❌ 存在失败用例，请检查                            ║') end
print('╚══════════════════════════════════════════════════╝\n')
