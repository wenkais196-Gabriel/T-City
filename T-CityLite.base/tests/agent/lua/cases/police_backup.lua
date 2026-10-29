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

        return { ok = failed == 0, data = { cases = results, failed = failed } }
    end,
}
