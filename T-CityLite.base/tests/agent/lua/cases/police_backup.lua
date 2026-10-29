-- cases/police_backup.lua — SM-06 支援单位的生命周期：结束原因与结束审计（切片 S1）。
--
-- 只碰服务端：名额在 NPCBudget 的 entries 里（kind='backup'），结束路径
-- police:server:backupEnded 负责释放 + 审计。这里不验证客户端生成/清理，
-- 那部分在 client harness 与真机验收里。

return {
    run = function(ctx)
        local results = {}
        local failed = 0

        local function check(name, fn)
            local record = { name = name, ok = true }
            local ok, err = pcall(fn)
            if not ok then
                record.ok = false
                record.error = tostring(err)
                failed = failed + 1
            end
            results[#results + 1] = record
        end

        local env = ctx.bootstrap.Load({ load_main = false, convars = {}, db = {} })
        local resource = 'T-CityLite.base/resources/[custom]/custom-police'
        dofile(resource .. '/shared/backup_contract.lua')
        dofile(resource .. '/shared/npc_budget.lua')
        dofile(resource .. '/shared/policy.lua')
        dofile(resource .. '/server/npc_budget.lua')
        dofile(resource .. '/server/audit.lua')
        dofile(resource .. '/server/p2_system.lua')

        local budget = assert(_G.NPCBudget, 'NPCBudget missing')

        --- 触发一次 backupEnded（真实环境里 source 是隐式全局）。
        local function ended(requestId, reason, source)
            _G.source = source
            local handlers = env.event_handlers['police:server:backupEnded'] or {}
            for _, handler in ipairs(handlers) do
                handler(requestId, reason)
            end
            _G.source = nil
        end

        --- 审计里最后一条 backup.* 的动作名与 detail。
        local function lastAudit(action, since)
            local log = env.mysql.log or {}
            for index = #log, (since or 0) + 1, -1 do
                local params = log[index].params or {}
                if params[3] == action then return params end
            end
            return nil
        end

        check('backup ended writes an audit row with the reason', function()
            env.mysql.reset()
            env.makePlayer(11, 'BACKUP001', { cash = 0, bank = 0, crypto = 0 })
            local admitted = budget.Acquire('backup', 'BU-11-1', 'BACKUP001')
            assert(admitted == true, 'budget acquire failed')
            env.mysql.push({ kind = 'query', result = {} })

            ended('BU-11-1', 'timeout', 11)

            local row = lastAudit('backup.ended')
            assert(row, 'no backup.ended audit row')
            assert(tostring(row[5]):find('timeout', 1, true), 'detail must carry the reason, got ' .. tostring(row[5]))
            assert(budget.Get().used == 0, 'slot must be released')
        end)

        check('unknown or missing reason is recorded as unknown', function()
            env.mysql.reset()
            env.makePlayer(12, 'BACKUP002', { cash = 0, bank = 0, crypto = 0 })
            assert(budget.Acquire('backup', 'BU-12-1', 'BACKUP002') == true)
            env.mysql.push({ kind = 'query', result = {} })

            ended('BU-12-1', 'definitely_not_a_reason', 12)

            local row = lastAudit('backup.ended')
            assert(row, 'no backup.ended audit row for an unknown reason')
            assert(tostring(row[5]):find('unknown', 1, true),
                'unknown reasons must be normalised, got ' .. tostring(row[5]))
            assert(budget.Get().used == 0, 'slot must still be released')
        end)

        check('a foreign request id is ignored', function()
            env.mysql.reset()
            env.makePlayer(13, 'BACKUP003', { cash = 0, bank = 0, crypto = 0 })
            env.makePlayer(14, 'BACKUP004', { cash = 0, bank = 0, crypto = 0 })
            assert(budget.Acquire('backup', 'BU-13-1', 'BACKUP003') == true)

            -- source 14 想释放 13 的单：既不能释放，也不能写审计
                local before = #(env.mysql.log or {})
                ended('BU-13-1', 'timeout', 14)

                assert(budget.Get().used == 1, 'foreign request must not release the slot')
                assert(lastAudit('backup.ended', before) == nil, 'foreign request must not write an audit row')
            end)

            -- ------------------------------------------------------------------
            -- S2：阶段 ack
            -- ------------------------------------------------------------------

            --- 触发一次 backupAck（source 同样是隐式全局）。
            local function ack(requestId, phase, entityCount, source)
                _G.source = source
                local handlers = env.event_handlers['police:server:backupAck'] or {}
                assert(#handlers > 0, 'police:server:backupAck is not registered')
                for _, handler in ipairs(handlers) do
                    handler(requestId, phase, entityCount, 1234)
                end
                _G.source = nil
            end

            --- 某条单当前阶段（GetBackupState 投影）。
            local function phaseOf(requestId)
                for _, unit in ipairs(GetBackupState()) do
                    if unit.request_id == requestId then return unit end
                end
                return nil
            end

            check('ack advances the phase and records the entity count', function()
                env.mysql.reset()
                env.makePlayer(21, 'BACKUP101', { cash = 0, bank = 0, crypto = 0 })
                assert(budget.Acquire('backup', 'BU-21-1', 'BACKUP101') == true)
                env.mysql.push({ kind = 'query', result = {} })

                ack('BU-21-1', 'spawning', 0, 21)
                ack('BU-21-1', 'enroute', 3, 21)

                local unit = phaseOf('BU-21-1')
                assert(unit, 'unit must be tracked')
                assert(unit.phase == 'enroute', 'phase must be enroute, got ' .. tostring(unit.phase))
                assert(unit.entity_count == 3, 'entity_count must be 3, got ' .. tostring(unit.entity_count))
                local row = lastAudit('backup.spawned')
                assert(row, 'enroute must write a backup.spawned audit row')
                assert(tostring(row[5]):find('entities=3', 1, true), 'detail must carry entity count')
                budget.Release('BU-21-1', 'test_cleanup')
            end)

            check('a backwards phase is rejected and sampled', function()
                env.mysql.reset()
                env.makePlayer(22, 'BACKUP102', { cash = 0, bank = 0, crypto = 0 })
                assert(budget.Acquire('backup', 'BU-22-1', 'BACKUP102') == true)

                ack('BU-22-1', 'onscene', 0, 22)
                env.mysql.push({ kind = 'query', result = {} })
                ack('BU-22-1', 'enroute', 3, 22)

                local unit = phaseOf('BU-22-1')
                assert(unit.phase == 'onscene', 'phase must not rewind, got ' .. tostring(unit.phase))
                local row = lastAudit('backup.ack_rejected')
                assert(row, 'a rejected ack must be sampled into backup.ack_rejected')
                assert(tostring(row[5]):find('backwards', 1, true),
                    'detail must say why, got ' .. tostring(row[5]))
                budget.Release('BU-22-1', 'test_cleanup')
            end)

            check('an unknown phase is rejected', function()
                env.mysql.reset()
                env.makePlayer(23, 'BACKUP103', { cash = 0, bank = 0, crypto = 0 })
                assert(budget.Acquire('backup', 'BU-23-1', 'BACKUP103') == true)
                env.mysql.push({ kind = 'query', result = {} })

                ack('BU-23-1', 'teleported_to_scene', 1, 23)

                local unit = phaseOf('BU-23-1')
                assert(unit == nil or unit.phase == 'requested',
                    'an unknown phase must not create or move an entry')
                local row = lastAudit('backup.ack_rejected')
                assert(row and tostring(row[5]):find('bad_phase', 1, true), 'must record bad_phase')
                budget.Release('BU-23-1', 'test_cleanup')
            end)

            check("another officer's unit cannot be acked", function()
                env.mysql.reset()
                env.makePlayer(24, 'BACKUP104', { cash = 0, bank = 0, crypto = 0 })
                env.makePlayer(25, 'BACKUP105', { cash = 0, bank = 0, crypto = 0 })
                assert(budget.Acquire('backup', 'BU-24-1', 'BACKUP104') == true)
                env.mysql.push({ kind = 'query', result = {} })

                ack('BU-24-1', 'onscene', 0, 25)

                local unit = phaseOf('BU-24-1')
                assert(unit == nil or unit.phase == 'requested',
                    'a foreign session must not move the unit')
                local row = lastAudit('backup.ack_rejected')
                assert(row and tostring(row[5]):find('not_owned', 1, true), 'must record not_owned')
                budget.Release('BU-24-1', 'test_cleanup')
            end)

            check('ending a unit clears its phase projection', function()
                env.mysql.reset()
                env.makePlayer(26, 'BACKUP106', { cash = 0, bank = 0, crypto = 0 })
                assert(budget.Acquire('backup', 'BU-26-1', 'BACKUP106') == true)
                env.mysql.push({ kind = 'query', result = {} })

                ack('BU-26-1', 'enroute', 3, 26)
                assert(phaseOf('BU-26-1'), 'unit must be tracked before ending')
                -- 前面的用例故意留了别的单（"外单不能释放"那条），所以这里比增量。
                local usedBefore = budget.Get().used

                ended('BU-26-1', 'timeout', 26)
                assert(phaseOf('BU-26-1') == nil, 'phase entry must be dropped when the unit ends')
                assert(budget.Get().used == usedBefore - 1,
                    ('exactly this slot must be released (%d -> %d)'):format(
                        usedBefore, budget.Get().used))
            end)

            check('the projection carries no identity fields', function()
                env.mysql.reset()
                env.makePlayer(27, 'BACKUP107', { cash = 0, bank = 0, crypto = 0 })
                assert(budget.Acquire('backup', 'BU-27-1', 'BACKUP107') == true)
                ack('BU-27-1', 'spawning', 0, 27)

                local unit = phaseOf('BU-27-1')
                assert(unit, 'unit must be tracked')
                for _, forbidden in ipairs({ 'citizenid', 'cid', 'name', 'coords', 'x', 'y', 'z' }) do
                    assert(unit[forbidden] == nil,
                        'GetBackupState must not expose ' .. forbidden)
                end
                budget.Release('BU-27-1', 'test_cleanup')
            end)

            -- ------------------------------------------------------------------
            -- S3：服务端 sweep（寿命 / ack 超时 / 先收再放）
            -- ------------------------------------------------------------------

            --- 把上一组用例留下的名额与阶段清干净。
            --- sweep 会把阶段表里的单走完宽限，剩下的"没有阶段条目"的残留名额
            --- （例如"外单不能释放"那条故意不还的）再逐个释放。
            local function drainAll()
                BackupSweep(os.time() + 100000)
                BackupSweep(os.time() + 100010)
                for _, entry in ipairs(budget.Get().entries) do
                    budget.Release(entry.id, 'test_drain')
                end
            end

            --- 造一个真正的警察玩家并发一次请求；返回 requestId。
            local function requestBackup(source, citizenid)
                local player = env.makePlayer(source, citizenid, { cash = 0, bank = 0, crypto = 0 })
                player.PlayerData.job = { name = 'police', onduty = true, grade = { level = 3 } }
                env.mysql.push({ kind = 'query', result = {} })
                local result = RequestBackup(source)
                assert(type(result) == 'table' and result.ok == true,
                    'request must be admitted, got ' .. tostring(result and result.error))
                return result.request_id
            end

            --- 清空客户端事件记录。
            local function resetClientEvents() env.client_events = {} end

            local function lastClientEvent(name)
                for index = #(env.client_events or {}), 1, -1 do
                    local item = env.client_events[index]
                    if item.event == name then return item end
                end
                return nil
            end

            check('the ttl asks the client to clean up first, then releases', function()
                env.mysql.reset()
                drainAll()
                resetClientEvents()
                local base = os.time()
                local requestId = requestBackup(31, 'BACKUP201')
                assert(budget.Get().used == 1, 'request must take a slot')

                -- 到点：先发 BackupEnd，名额还不能放（客户端要有时间删实体）
                local released = BackupSweep(base + 301)
                assert(released == 0, 'nothing may be released during the grace window')
                local event = lastClientEvent('police:client:BackupEnd')
                assert(event, 'the sweep must tell the client to clean up')
                assert(event.target == 31 and event.args[1] == requestId,
                    'BackupEnd must target the requesting client with the right id')
                assert(budget.Get().used == 1, 'the slot must survive the grace window')
                local unit = phaseOf(requestId)
                assert(unit and unit.ending == true, 'the unit must be marked as ending')

                -- 宽限结束：放名额 + 写 expired 审计
                env.mysql.push({ kind = 'query', result = {} })
                released = BackupSweep(base + 307)
                assert(released == 1, 'the slot must be released after the grace window')
                assert(budget.Get().used == 0, 'the slot must be gone')
                assert(phaseOf(requestId) == nil, 'the projection must drop the unit')
                local row = lastAudit('backup.expired')
                assert(row, 'expiry must be audited')
                assert(tostring(row[5]):find('why=ttl', 1, true), 'detail must say ttl, got ' .. tostring(row[5]))
                assert(tostring(row[5]):find('phase=requested', 1, true), 'detail must carry the last phase')
            end)

            check('a request that is never acked expires on the 10s timeout', function()
                env.mysql.reset()
                drainAll()
                resetClientEvents()
                local base = os.time()
                local requestId = requestBackup(32, 'BACKUP202')

                assert(BackupSweep(base + 5) == 0, 'no expiry before the ack timeout')
                assert(lastClientEvent('police:client:BackupEnd') == nil, 'and no BackupEnd either')

                BackupSweep(base + 11)
                local event = lastClientEvent('police:client:BackupEnd')
                assert(event and event.args[1] == requestId, 'the stalled unit must be ended')

                env.mysql.push({ kind = 'query', result = {} })
                assert(BackupSweep(base + 17) == 1, 'the slot must be released after the grace window')
                local row = lastAudit('backup.expired')
                assert(row and tostring(row[5]):find('why=ack_timeout:requested', 1, true),
                    'the reason must name the stalled phase, got ' .. tostring(row and row[5]))
                assert(budget.Get().used == 0)
            end)

            check('a spawning unit that never reaches enroute expires at 15s', function()
                env.mysql.reset()
                drainAll()
                resetClientEvents()
                local base = os.time()
                env.makePlayer(33, 'BACKUP203', { cash = 0, bank = 0, crypto = 0 })
                assert(budget.Acquire('backup', 'BU-33-1', 'BACKUP203') == true)
                ack('BU-33-1', 'spawning', 0, 33)

                assert(BackupSweep(base + 10) == 0, 'the spawning window is 15s')
                assert(lastClientEvent('police:client:BackupEnd') == nil)

                BackupSweep(base + 16)
                assert(lastClientEvent('police:client:BackupEnd'), 'the stalled spawn must be ended')
                env.mysql.push({ kind = 'query', result = {} })
                BackupSweep(base + 22)
                local row = lastAudit('backup.expired')
                assert(row and tostring(row[5]):find('why=ack_timeout:spawning', 1, true),
                    'the reason must name spawning, got ' .. tostring(row and row[5]))
            end)

            check('an enroute unit is only bounded by the ttl', function()
                env.mysql.reset()
                drainAll()
                resetClientEvents()
                local base = os.time()
                env.makePlayer(34, 'BACKUP204', { cash = 0, bank = 0, crypto = 0 })
                assert(budget.Acquire('backup', 'BU-34-1', 'BACKUP204') == true)
                ack('BU-34-1', 'enroute', 3, 34)

                local released = BackupSweep(base + 120)
                assert(released == 0, 'a driving unit must not be swept by the ack timeouts')
                assert(lastClientEvent('police:client:BackupEnd') == nil)
                local unit = phaseOf('BU-34-1')
                assert(unit and unit.phase == 'enroute', 'the unit must still be enroute')
                budget.Release('BU-34-1', 'test_cleanup')
            end)

            check('police_backup_v2 0 turns the sweep off', function()
                env.mysql.reset()
                drainAll()
                resetClientEvents()
                local base = os.time()
                local requestId = requestBackup(35, 'BACKUP205')

                env.convars['police_backup_v2'] = '0'
                local released = BackupSweep(base + 9999)
                env.convars['police_backup_v2'] = '1'

                assert(released == 0, 'the rollback switch must disable the sweep')
                assert(lastClientEvent('police:client:BackupEnd') == nil, 'and send nothing')
                assert(budget.Get().used == 1, 'the slot must stay (legacy behaviour)')
                assert(phaseOf(requestId), 'the unit must still be tracked')
                budget.Release(requestId, 'test_cleanup')
            end)

        -- ------------------------------------------------------------------
        -- S5：任务重发门控（P0 纯函数）
        -- ------------------------------------------------------------------

        check('a performing task is not retasked inside the heartbeat', function()
            assert(BackupContract.ShouldRetask(1, 1000, 3000, 5000) == false,
                'performing + 2s < 5s heartbeat must not retask')
        end)

        check('a performing task is retasked once the heartbeat expires', function()
            assert(BackupContract.ShouldRetask(1, 1000, 6500, 5000) == true,
                'performing + 5.5s must retask (the task may have been cleared elsewhere)')
        end)

        check('vacant and finished tasks are retasked immediately', function()
            assert(BackupContract.ShouldRetask(3, 1000, 1200, 5000) == true, 'vacant must retask')
            assert(BackupContract.ShouldRetask(7, 1000, 1200, 5000) == true, 'finished must retask')
        end)

        check('an unknown task status is treated as retask', function()
            assert(BackupContract.ShouldRetask(0, 1000, 1200, 5000) == true, 'status 0 must retask')
            assert(BackupContract.ShouldRetask(nil, 1000, 1200, 5000) == true, 'nil must retask')
            assert(BackupContract.ShouldRetask('nonsense', 1000, 1200, 5000) == true, 'garbage must retask')
        end)

        check('a zero heartbeat retasks every tick while performing', function()
            assert(BackupContract.ShouldRetask(1, 1000, 1000, 0) == true,
                'heartbeat 0 means "always" (used when debugging)')
        end)

        return { ok = failed == 0, data = { cases = results, failed = failed } }
    end,
}
