-- 10_police_e2e.lua — P0 警察核心流程真实服务端 E2E
--
-- 与 02_police_test.lua 的布尔模拟不同：本套件在真实 FXServer 中调用
-- custom-police / custom-justice / custom-phone 的系统 export，并直接断言
-- MySQL 中的 police_incidents / police_units / police_incident_units /
-- police_outbox / justice_sentences / police_audit。
--
-- 运行：服务器控制台 `/test run police_e2e`
-- 输出：每步一行；结束时打印 `E2E_RESULT {json}` 和 `E2E_EXIT <0|1>`。
--
-- 测试命名空间（可重复运行，不碰生产数据）：
--   citizenid: E2E_TEST_OFFICER / E2E_TEST_SUSPECT
--   incident:  title 前缀 `[E2E]` + created_by `agent:e2e`
--   outbox:    payload 含 E2E_TEST_
-- 清理策略：结束（含失败）后删除上述测试行；police_audit 永远保留。
--
-- 条件步骤（缺少在线玩家时输出 SKIP，不算失败）：
--   - incident.close: SetIncidentStatus 只接受真实玩家 source，没有系统 export
--   - duty.probe:     SetDutyForSource 只接受真实玩家 source
--
-- 该文件只依赖 export + SQL，不修改任何业务资源；测试写 SQL 只用于准备
-- police_units 测试行与清理 E2E_* 命名空间，生产资源仍走各自的 export。

local CITIZEN_OFFICER = 'E2E_TEST_OFFICER'
local CITIZEN_SUSPECT = 'E2E_TEST_SUSPECT'
local ACTOR = 'e2e'
local INCIDENT_PREFIX = '[E2E]'
local OUTBOX_WAIT_MS = 10000
local TEST_TIMEOUT_SECONDS = 180

-- ─── 小工具 ───

local function show(value)
    if type(value) == 'table' then
        local ok, encoded = pcall(json.encode, value)
        if ok and type(encoded) == 'string' then return encoded end
        return tostring(value)
    end
    return tostring(value)
end

--- 调用 export，保留多返回值；export 不存在/抛错时返回 false, 错误文本。
---@return boolean ok, any a, any b, any c
local function callExport(resource, method, ...)
    local args = table.pack(...)
    local called, a, b, c = pcall(function()
        local proxy = exports[resource]
        local fn = proxy and proxy[method]
        if type(fn) ~= 'function' then
            error(('export_missing:%s:%s'):format(resource, method), 0)
        end
        -- 与 exports['res']:method(...) 等价；dot 调用会丢 self 导致参数错位。
        return fn(proxy, table.unpack(args, 1, args.n))
    end)
    if not called then
        return false, tostring(a)
    end
    return true, a, b, c
end

Test.describe("police_e2e", function()

    Test.it_async("P0 警察核心流程（真实 exports + MySQL）", function()
        local QBCore = exports['qb-core']:GetCoreObject()

        local steps = {}
        local counts = { pass = 0, fail = 0, skip = 0 }
        local ctx = {
            current = nil,
            incidentId = nil,
            incidentTitle = nil,
            outboxId = nil,
            budget = nil,
            cleanupDone = false,
        }
        local ASSERT_FAILED = {}
        local STEP_SKIPPED = {}

        local function nowStamp()
            return os.date('%Y%m%d-%H%M%S')
        end

        local function expect(condition, label, expected, actual)
            local record = ctx.current
            record.checks = record.checks + 1
            record.expected = show(expected)
            record.actual = show(actual)
            if condition then return true end

            record.status = 'FAIL'
            local message = ('%s — expected=%s actual=%s'):format(
                label, show(expected), show(actual))
            record.failures[#record.failures + 1] = message
            Test._fail(('[E2E] %s'):format(message))
            error(ASSERT_FAILED, 0)
        end

        local function skip(reason)
            local record = ctx.current
            record.status = 'SKIP'
            record.reason = reason
            print(('[E2E] ⏭️ SKIP %s — %s'):format(record.name, reason))
            error(STEP_SKIPPED, 0)
        end

        local function runStep(name, fn)
            local record = {
                name = name,
                status = 'PASS',
                checks = 0,
                ms = 0,
                failures = {},
            }
            ctx.current = record
            local started = GetGameTimer()
            local ok, err = pcall(fn)
            record.ms = GetGameTimer() - started

            if not ok and err ~= ASSERT_FAILED and err ~= STEP_SKIPPED then
                record.status = 'FAIL'
                record.reason = tostring(err)
                Test._fail(('[E2E] %s 异常: %s'):format(name, tostring(err)))
            end

            ctx.current = nil
            steps[#steps + 1] = record

            if record.status == 'PASS' then
                counts.pass = counts.pass + 1
            elseif record.status == 'SKIP' then
                counts.skip = counts.skip + 1
            else
                counts.fail = counts.fail + 1
            end

            local marker = '✅'
            if record.status == 'SKIP' then marker = '⏭️'
            elseif record.status == 'FAIL' then marker = '❌' end
            local detail = record.failures[1] or record.reason or ''
            if record.status == 'PASS' then detail = '' end
            print(('[E2E] %s %-28s %5dms %s'):format(marker, name, record.ms, detail))
            return record.status
        end

        -- ─── DB / 审计辅助 ───

        local function scalar(sql, params)
            return tonumber(MySQL.scalar.await(sql, params)) or 0
        end

        local function auditCursor()
            return scalar('SELECT COALESCE(MAX(id), 0) AS max_id FROM police_audit')
        end

        local function auditRow(cursor, action, target)
            if target ~= nil then
                return MySQL.single.await([[
                    SELECT id, actor_citizenid, actor_kind, action, target, detail
                      FROM police_audit
                     WHERE id > ? AND action = ? AND target = ?
                     ORDER BY id DESC LIMIT 1
                ]], { cursor, action, tostring(target) })
            end
            return MySQL.single.await([[
                SELECT id, actor_citizenid, actor_kind, action, target, detail
                  FROM police_audit
                 WHERE id > ? AND action = ?
                 ORDER BY id DESC LIMIT 1
            ]], { cursor, action })
        end

        local function deleteIncident(id)
            if not id then return end
            MySQL.update.await('DELETE FROM police_incident_units WHERE incident_id = ?', { id })
            MySQL.update.await('DELETE FROM police_incidents WHERE id = ?', { id })
        end

        --- 删除上一次异常运行可能留下的 E2E 数据（审计保留）。
        local function prepareCleanup()
            local stale = MySQL.query.await([[
                SELECT id FROM police_incidents
                 WHERE title LIKE '[E2E]%' AND created_by = 'agent:e2e'
                 LIMIT 100
            ]], {}) or {}
            for _, row in ipairs(stale) do
                deleteIncident(tonumber(row.id))
            end

            MySQL.update.await(
                'DELETE FROM police_units WHERE citizenid IN (?, ?)',
                { CITIZEN_OFFICER, CITIZEN_SUSPECT })
            MySQL.update.await(
                'DELETE FROM justice_sentences WHERE citizenid IN (?, ?)',
                { CITIZEN_OFFICER, CITIZEN_SUSPECT })
            MySQL.update.await(
                "DELETE FROM police_outbox WHERE payload LIKE '%E2E_TEST_%' LIMIT 100", {})
            MySQL.update.await(
                'DELETE FROM phone_notifications WHERE citizenid IN (?, ?)',
                { CITIZEN_OFFICER, CITIZEN_SUSPECT })
            return #stale
        end

        --- 删除本次测试写入的 E2E_* 行，返回残留行数。
        local function finalCleanup()
            deleteIncident(ctx.incidentId)

            local stale = MySQL.query.await([[
                SELECT id FROM police_incidents
                 WHERE title LIKE '[E2E]%' AND created_by = 'agent:e2e'
                 LIMIT 100
            ]], {}) or {}
            for _, row in ipairs(stale) do
                deleteIncident(tonumber(row.id))
            end

            if ctx.outboxId then
                MySQL.update.await('DELETE FROM police_outbox WHERE id = ?', { ctx.outboxId })
            end
            MySQL.update.await(
                "DELETE FROM police_outbox WHERE payload LIKE '%E2E_TEST_%' LIMIT 100", {})
            MySQL.update.await(
                'DELETE FROM police_units WHERE citizenid IN (?, ?)',
                { CITIZEN_OFFICER, CITIZEN_SUSPECT })
            MySQL.update.await(
                'DELETE FROM justice_sentences WHERE citizenid IN (?, ?)',
                { CITIZEN_OFFICER, CITIZEN_SUSPECT })
            MySQL.update.await(
                'DELETE FROM phone_notifications WHERE citizenid IN (?, ?)',
                { CITIZEN_OFFICER, CITIZEN_SUSPECT })

            ctx.cleanupDone = true

            local residue = 0
            residue = residue + scalar([[
                SELECT COUNT(*) FROM police_incidents
                 WHERE title LIKE '[E2E]%' AND created_by = 'agent:e2e'
            ]], {})
            if ctx.incidentId then
                residue = residue + scalar(
                    'SELECT COUNT(*) FROM police_incidents WHERE id = ?', { ctx.incidentId })
            end
            residue = residue + scalar(
                'SELECT COUNT(*) FROM police_units WHERE citizenid IN (?, ?)',
                { CITIZEN_OFFICER, CITIZEN_SUSPECT })
            residue = residue + scalar(
                'SELECT COUNT(*) FROM justice_sentences WHERE citizenid IN (?, ?)',
                { CITIZEN_OFFICER, CITIZEN_SUSPECT })
            residue = residue + scalar(
                'SELECT COUNT(*) FROM phone_notifications WHERE citizenid IN (?, ?)',
                { CITIZEN_OFFICER, CITIZEN_SUSPECT })
            if ctx.outboxId then
                residue = residue + scalar(
                    'SELECT COUNT(*) FROM police_outbox WHERE id = ?', { ctx.outboxId })
            end
            return residue
        end

        local function findOnDutyOfficer()
            local best = nil
            for _, src in ipairs(QBCore.Functions.GetPlayers()) do
                local player = QBCore.Functions.GetPlayer(src)
                local data = player and player.PlayerData
                if data and type(data.job) == 'table'
                    and data.job.name == 'police' and data.job.onduty == true then
                    local grade = tonumber(data.job.grade and data.job.grade.level) or 0
                    if not best or grade > best.grade then
                        best = { source = src, data = data, grade = grade }
                    end
                end
            end
            return best
        end

        local function fetchBudget()
            local ok, budget = callExport('custom-police', 'GetNpcBudget')
            if not ok then return false, budget end
            return true, budget
        end

        local function sumBudgetSlots(budget)
            local total = 0
            for _, entry in ipairs(budget.entries or {}) do
                total = total + (tonumber(entry.slots) or 0)
            end
            return total
        end

        -- ─── 主流程 ───

        local mainOk, mainErr = pcall(function()

            runStep('cleanup.prepare', function()
                local removed = prepareCleanup()
                expect(type(removed) == 'number', 'pre-clean 可执行',
                    'number of removed rows', removed)
            end)

            runStep('npc_budget.baseline', function()
                expect(ctx.incidentId == nil, 'baseline 在 incident 之前',
                    'no incident yet', ctx.incidentId)
                local ok, budget = fetchBudget()
                expect(ok, 'GetNpcBudget 可调用', 'table', ok and 'table' or budget)
                expect(type(budget) == 'table', 'GetNpcBudget 返回 table',
                    'table', type(budget))
                expect(type(budget.used) == 'number' and type(budget.max) == 'number',
                    'budget.used/max 为数字', 'numbers',
                    ('used=%s max=%s'):format(show(budget.used), show(budget.max)))
                expect(budget.max >= budget.used, 'max >= used',
                    ('>= %s'):format(show(budget.used)), show(budget.max))
                local slots = sumBudgetSlots(budget)
                expect(slots == budget.used, 'used == sum(entries.slots)',
                    show(budget.used), show(slots))
                ctx.budget = {
                    used = budget.used,
                    max = budget.max,
                    entries = #(budget.entries or {}),
                }
            end)

            runStep('incident.create', function()
                local title = ('%s dispatch %s'):format(INCIDENT_PREFIX, nowStamp())
                local cursor = auditCursor()
                local ok, result = callExport('custom-police', 'CreateIncidentSystem', ACTOR, {
                    title = title,
                    code = 'E2E',
                    priority = 1,
                    details = 'E2E automated incident (safe to delete)',
                })
                expect(ok, 'CreateIncidentSystem 可调用', 'true, result', ok and 'ok' or result)
                expect(type(result) == 'table' and tonumber(result.id) ~= nil,
                    '返回 incident id', 'table with id', show(result))

                ctx.incidentId = tonumber(result.id)
                ctx.incidentTitle = title
                expect(result.status == 'open', 'export 返回 open', 'open', show(result.status))

                local row = MySQL.single.await([[
                    SELECT id, status, title, created_by
                      FROM police_incidents WHERE id = ? LIMIT 1
                ]], { ctx.incidentId })
                expect(row ~= nil, 'DB 中存在 incident', 'row', row and 'row' or 'nil')
                expect(row.status == 'open', 'DB status=open', 'open', show(row.status))
                expect(row.title == title, 'DB title 为测试标题', title, show(row.title))
                expect(row.created_by == ('agent:%s'):format(ACTOR), 'created_by 为测试 actor',
                    ('agent:%s'):format(ACTOR), show(row.created_by))

                local audit = MySQL.single.await([[
                    SELECT id, actor_kind, action, target, detail
                      FROM police_audit
                     WHERE id > ? AND action = 'incident.create'
                       AND actor_citizenid = 'e2e' AND detail = ?
                     ORDER BY id DESC LIMIT 1
                ]], { cursor, title })
                expect(audit ~= nil, 'police_audit 记录 incident.create',
                    'row', audit and ('id=' .. tostring(audit.id)) or 'nil')
                expect(audit.actor_kind == 'agent', 'audit actor_kind=agent',
                    'agent', show(audit.actor_kind))
            end)

            runStep('incident.assign', function()
                expect(ctx.incidentId ~= nil, 'incident 已创建',
                    'incident id', show(ctx.incidentId))

                MySQL.insert.await([[
                    INSERT INTO police_units (citizenid, callsign, status, incident_id)
                    VALUES (?, ?, 'available', NULL)
                    ON DUPLICATE KEY UPDATE callsign = ?, status = 'available', incident_id = NULL
                ]], { CITIZEN_OFFICER, 'E2E-1', 'E2E-1' })

                local unit = MySQL.single.await([[
                    SELECT citizenid, status, incident_id FROM police_units
                     WHERE citizenid = ? LIMIT 1
                ]], { CITIZEN_OFFICER })
                expect(unit ~= nil and unit.status == 'available',
                    '测试 unit 预置为 available', 'available',
                    unit and show(unit.status) or 'missing')

                local cursor = auditCursor()
                local ok, result, reason = callExport(
                    'custom-police', 'AssignUnitSystemForAgent',
                    ctx.incidentId, CITIZEN_OFFICER, ACTOR)
                expect(ok, 'AssignUnitSystemForAgent 可调用',
                    'true, result', ok and 'ok' or reason)
                expect(type(result) == 'table', 'assign 返回 table', 'table', show(result))
                expect(tonumber(result.id) == ctx.incidentId, 'assign 返回同一 incident',
                    show(ctx.incidentId), show(result.id))
                expect(result.status == 'assigned', 'export 返回 assigned',
                    'assigned', show(result.status))

                local incident = MySQL.single.await([[
                    SELECT id, status FROM police_incidents WHERE id = ? LIMIT 1
                ]], { ctx.incidentId })
                expect(incident ~= nil and incident.status == 'assigned',
                    'DB incident status=assigned', 'assigned',
                    incident and show(incident.status) or 'nil')

                local membership = MySQL.single.await([[
                    SELECT incident_id, citizenid FROM police_incident_units
                     WHERE incident_id = ? AND citizenid = ? LIMIT 1
                ]], { ctx.incidentId, CITIZEN_OFFICER })
                expect(membership ~= nil, 'police_incident_units 有测试成员',
                    'row', membership and 'row' or 'nil')

                local assignedUnit = MySQL.single.await([[
                    SELECT status, incident_id FROM police_units
                     WHERE citizenid = ? LIMIT 1
                ]], { CITIZEN_OFFICER })
                expect(assignedUnit ~= nil and assignedUnit.status == 'assigned',
                    'unit status=assigned', 'assigned',
                    assignedUnit and show(assignedUnit.status) or 'nil')
                expect(tonumber(assignedUnit.incident_id) == ctx.incidentId,
                    'unit 绑定测试 incident', show(ctx.incidentId),
                    show(assignedUnit.incident_id))

                local audit = auditRow(cursor, 'incident.assign', ctx.incidentId)
                expect(audit ~= nil, 'police_audit 记录 incident.assign',
                    'row', audit and ('id=' .. tostring(audit.id)) or 'nil')
                expect(audit.actor_citizenid == ACTOR, 'audit actor=e2e',
                    ACTOR, show(audit.actor_citizenid))
                expect(tostring(audit.detail) == CITIZEN_OFFICER, 'audit detail=测试 unit',
                    CITIZEN_OFFICER, show(audit.detail))
            end)

            runStep('incident.close', function()
                expect(ctx.incidentId ~= nil, 'incident 已创建',
                    'incident id', show(ctx.incidentId))

                local officer = findOnDutyOfficer()
                if not officer then
                    skip('无在线且上班的警察；SetIncidentStatus 只有玩家 source 入口，'
                        .. 'incident 留给 cleanup 删除')
                end
                if officer.grade < 1 then
                    skip(('在线警察 grade=%d，无 incident.update 权限'):format(officer.grade))
                end
                if officer.grade < 2 then
                    -- grade 1 只能通过 AssignUnit 自派单；不要抢占正在处理其他警情的 unit。
                    local unit = MySQL.single.await([[
                        SELECT status FROM police_units WHERE citizenid = ? LIMIT 1
                    ]], { officer.data.citizenid })
                    local status = unit and unit.status
                    if status and status ~= 'available' and status ~= 'off_duty' then
                        skip(('在线警察 unit.status=%s，grade<2 时避免抢占其警情'):format(
                            tostring(status)))
                    end
                end

                local cursor = auditCursor()
                local ok, result, reason = callExport(
                    'custom-police', 'SetIncidentStatus', officer.source,
                    ctx.incidentId, 'cleared', 'cleared', 'e2e_clear')

                if not ok or result == false then
                    -- grade 1 的警察需要先成为该 incident 的成员；用真实 export 补派单，
                    -- 不直接改 DB。grade >= 2 不需要这一步。
                    local assignOk, assigned, assignReason = callExport(
                        'custom-police', 'AssignUnit', officer.source,
                        ctx.incidentId, officer.data.citizenid)
                    expect(assignOk and assigned ~= false,
                        '在线警察可补派单（grade<2 时）', 'assigned table',
                        assignOk and show(assigned) or show(assignReason))
                    ok, result, reason = callExport(
                        'custom-police', 'SetIncidentStatus', officer.source,
                        ctx.incidentId, 'cleared', 'cleared', 'e2e_clear')
                end

                expect(ok, 'SetIncidentStatus 可调用',
                    'true, result', ok and 'ok' or reason)
                expect(type(result) == 'table', 'close 返回 table', 'table', show(result))
                expect(result.status == 'closed', 'export 返回 closed',
                    'closed', show(result.status))
                expect(result.disposition == 'cleared', 'export disposition=cleared',
                    'cleared', show(result.disposition))

                local row = MySQL.single.await([[
                    SELECT status, disposition, closed_by, closed_at
                      FROM police_incidents WHERE id = ? LIMIT 1
                ]], { ctx.incidentId })
                expect(row ~= nil, 'DB incident 仍存在（cleanup 前）',
                    'row', row and 'row' or 'nil')
                expect(row.status == 'closed', 'DB status=closed',
                    'closed', show(row.status))
                expect(row.disposition == 'cleared', 'DB disposition=cleared',
                    'cleared', show(row.disposition))
                expect(row.closed_by == officer.data.citizenid, 'DB closed_by=在线警察',
                    show(officer.data.citizenid), show(row.closed_by))
                expect(row.closed_at ~= nil, 'DB closed_at 非空',
                    'timestamp', show(row.closed_at))

                local releasedUnit = MySQL.single.await([[
                    SELECT status, incident_id FROM police_units
                     WHERE citizenid = ? LIMIT 1
                ]], { CITIZEN_OFFICER })
                expect(releasedUnit ~= nil and releasedUnit.status == 'available',
                    '关单后测试 unit 回到 available', 'available',
                    releasedUnit and show(releasedUnit.status) or 'nil')
                expect(releasedUnit.incident_id == nil, '关单后 unit 解除 incident 绑定',
                    'nil', show(releasedUnit.incident_id))

                local audit = auditRow(cursor, 'incident.close', ctx.incidentId)
                expect(audit ~= nil, 'police_audit 记录 incident.close',
                    'row', audit and ('id=' .. tostring(audit.id)) or 'nil')
                expect(audit.actor_citizenid == officer.data.citizenid,
                    'audit actor=关单警察', show(officer.data.citizenid),
                    show(audit.actor_citizenid))
                expect(tostring(audit.detail) == 'cleared', 'audit detail=cleared',
                    'cleared', show(audit.detail))
            end)

            runStep('npc_budget.unchanged', function()
                expect(ctx.budget ~= nil, 'baseline 已采集',
                    'budget snapshot', ctx.budget and 'present' or 'missing')
                local ok, budget = fetchBudget()
                expect(ok, 'GetNpcBudget 可再次调用', 'table', ok and 'table' or budget)
                expect(type(budget) == 'table', '返回 table', 'table', type(budget))
                expect(budget.used == ctx.budget.used, 'used 前后一致（无泄漏）',
                    ctx.budget.used, budget.used)
                expect(budget.max == ctx.budget.max, 'max 前后一致',
                    ctx.budget.max, budget.max)

                local owned = 0
                for _, entry in ipairs(budget.entries or {}) do
                    if entry.citizenid == CITIZEN_OFFICER
                        or entry.citizenid == CITIZEN_SUSPECT then
                        owned = owned + 1
                    end
                end
                expect(owned == 0, '没有 E2E 测试单位的 NPC budget 占用',
                    0, owned)
            end)

            runStep('outbox.delivery', function()
                local title = ('%s outbox %s'):format(INCIDENT_PREFIX, nowStamp())
                local ok, enqueued, id = callExport(
                    'custom-police', 'EnqueueOutbox', 'notification', {
                        citizenid = CITIZEN_SUSPECT,
                        title = title,
                        content = 'E2E outbox probe',
                        app_id = 'police_mdt',
                    })
                expect(ok, 'EnqueueOutbox 可调用',
                    'true, id', ok and 'ok' or enqueued)
                expect(enqueued == true, 'enqueue 返回 true', true, show(enqueued))
                expect(tonumber(id) ~= nil, 'enqueue 返回 outbox id',
                    'number', show(id))
                ctx.outboxId = tonumber(id)

                local row = nil
                local deadline = GetGameTimer() + OUTBOX_WAIT_MS
                repeat
                    row = MySQL.single.await([[
                        SELECT id, status, attempts, next_attempt_at
                          FROM police_outbox WHERE id = ? LIMIT 1
                    ]], { ctx.outboxId })
                    if row and row.status == 'done' then break end
                    Wait(250)
                until GetGameTimer() > deadline

                expect(row ~= nil, 'outbox 行存在', 'row', row and 'row' or 'nil')
                expect(row.status == 'done',
                    ('worker 在 %dms 内处理完成'):format(OUTBOX_WAIT_MS),
                    'done', ('status=%s attempts=%s'):format(
                        show(row.status), show(row.attempts)))

                local notification = MySQL.single.await([[
                    SELECT id, title, app_id FROM phone_notifications
                     WHERE citizenid = ? AND title = ? ORDER BY id DESC LIMIT 1
                ]], { CITIZEN_SUSPECT, title })
                expect(notification ~= nil, 'phone_notifications 已落库',
                    'row', notification and ('id=' .. tostring(notification.id)) or 'nil')
                expect(notification.app_id == 'police_mdt', 'app_id 透传',
                    'police_mdt', show(notification.app_id))
            end)

            runStep('sentence.apply', function()
                local ok, remaining, reason = callExport(
                    'custom-justice', 'ApplySentence', CITIZEN_SUSPECT, 1,
                    'E2E', 'E2E automated sentence', 'set', CITIZEN_OFFICER)
                expect(ok, 'ApplySentence 可调用',
                    'true, remaining', ok and 'ok' or reason)
                expect(type(remaining) == 'number' and remaining >= 1,
                    '剩余 1 分钟', '>= 1', show(remaining))

                local row = MySQL.single.await([[
                    SELECT id, status, case_id, minutes, created_by, ends_at
                      FROM justice_sentences WHERE citizenid = ?
                     ORDER BY id DESC LIMIT 1
                ]], { CITIZEN_SUSPECT })
                expect(row ~= nil, 'justice_sentences 有测试行',
                    'row', row and 'row' or 'nil')
                expect(row.status == 'active', 'DB status=active',
                    'active', show(row.status))
                expect(row.case_id == 'E2E', 'DB case_id=E2E',
                    'E2E', show(row.case_id))
                expect(tonumber(row.minutes) == 1, 'DB minutes=1',
                    1, show(row.minutes))
                expect(row.created_by == CITIZEN_OFFICER, 'DB created_by=测试警员',
                    CITIZEN_OFFICER, show(row.created_by))
            end)

            runStep('sentence.adjust', function()
                local ok, remaining = callExport(
                    'custom-justice', 'AdjustSentence', CITIZEN_SUSPECT, -1, 'e2e_adjust')
                expect(ok, 'AdjustSentence 可调用',
                    'true, remainingSeconds', ok and 'ok' or remaining)
                expect(tonumber(remaining) == 0, '调整后剩余 0 秒',
                    0, show(remaining))

                local row = MySQL.single.await([[
                    SELECT id, status, released_at FROM justice_sentences
                     WHERE citizenid = ? ORDER BY id DESC LIMIT 1
                ]], { CITIZEN_SUSPECT })
                expect(row ~= nil, 'justice_sentences 行存在',
                    'row', row and 'row' or 'nil')
                expect(row.status == 'expired', '用尽后 status=expired',
                    'expired', show(row.status))
                expect(row.released_at ~= nil, 'released_at 已写入',
                    'timestamp', show(row.released_at))

                -- 已过期时 ReleaseSentence 必须是幂等的 false，不能假装释放成功。
                local releaseOk, released = callExport(
                    'custom-justice', 'ReleaseSentence', CITIZEN_SUSPECT,
                    'e2e_already_expired')
                expect(releaseOk and released == false, '过期后 ReleaseSentence 幂等 false',
                    false, show(released))
            end)

            runStep('sentence.release', function()
                local ok, remaining = callExport(
                    'custom-justice', 'ApplySentence', CITIZEN_SUSPECT, 1,
                    'E2E', 'E2E release path', 'set', CITIZEN_OFFICER)
                expect(ok and tonumber(remaining) >= 1, '再次 ApplySentence 成功',
                    'active sentence', show(remaining))

                local releaseOk, released = callExport(
                    'custom-justice', 'ReleaseSentence', CITIZEN_SUSPECT, 'e2e_release')
                expect(releaseOk, 'ReleaseSentence 可调用',
                    'true', releaseOk and 'ok' or released)
                expect(released == true, 'ReleaseSentence 返回 true',
                    true, show(released))

                local row = MySQL.single.await([[
                    SELECT id, status, released_at FROM justice_sentences
                     WHERE citizenid = ? ORDER BY id DESC LIMIT 1
                ]], { CITIZEN_SUSPECT })
                expect(row ~= nil and row.status == 'released',
                    'DB status=released', 'released',
                    row and show(row.status) or 'nil')
                expect(row.released_at ~= nil, 'released_at 已写入',
                    'timestamp', row and show(row.released_at) or 'nil')
            end)

            runStep('duty.probe', function()
                local officer = findOnDutyOfficer()
                if not officer then
                    skip('无在线且上班的警察；SetDutyForSource 只有玩家 source 入口')
                end

                local onDuty = officer.data.job.onduty == true
                local prefix = onDuty and 'on:' or 'off:'
                local cursor = auditCursor()
                local ok, result, reason = callExport(
                    'custom-police', 'SetDutyForSource', officer.source,
                    onDuty, 'e2e_probe')
                expect(ok, 'SetDutyForSource 可调用',
                    'true', ok and 'ok' or reason)
                expect(result == true, '同值 duty 设置返回 true', true, show(result))

                local audit = auditRow(cursor, 'duty.set', officer.data.citizenid)
                expect(audit ~= nil, 'police_audit 记录 duty.set',
                    'row', audit and ('id=' .. tostring(audit.id)) or 'nil')
                expect(tostring(audit.detail):sub(1, #prefix) == prefix,
                    'audit detail 前缀正确', prefix .. '<reason>', show(audit.detail))
            end)

            runStep('cleanup.final', function()
                local residue = finalCleanup()
                expect(residue == 0, 'E2E_* 测试数据残留为 0', 0, residue)
                if ctx.incidentTitle then
                    local audit = MySQL.single.await([[
                        SELECT id FROM police_audit
                         WHERE action = 'incident.create'
                           AND actor_citizenid = 'e2e' AND detail = ?
                         ORDER BY id DESC LIMIT 1
                    ]], { ctx.incidentTitle })
                    expect(audit ~= nil, '清理后 police_audit 仍保留',
                        'row', audit and ('id=' .. tostring(audit.id)) or 'nil')
                end
            end)
        end)

        -- 兜底：主流程意外抛错时仍执行清理并输出结果，避免留下 E2E 数据。
        if not mainOk then
            runStep('harness.fatal', function()
                error(mainErr, 0)
            end)
        end
        if not ctx.cleanupDone then
            runStep('cleanup.final', function()
                local residue = finalCleanup()
                expect(residue == 0, '兜底清理后 E2E_* 残留为 0', 0, residue)
            end)
        end

        local summarySteps = {}
        for _, record in ipairs(steps) do
            local item = {
                name = record.name,
                status = record.status,
                ms = record.ms,
                checks = record.checks,
                expected = record.expected,
                actual = record.actual,
                reason = record.reason,
            }
            if #record.failures > 0 then item.failures = record.failures end
            summarySteps[#summarySteps + 1] = item
        end

        local ok = counts.fail == 0
        local payload = {
            suite = 'police_e2e',
            ok = ok,
            exit_code = ok and 0 or 1,
            pass = counts.pass,
            fail = counts.fail,
            skip = counts.skip,
            total = #steps,
            steps = summarySteps,
        }
        local encoded
        local encodedOk, value = pcall(json.encode, payload)
        if encodedOk and type(value) == 'string' then
            encoded = value
        else
            encoded = '{"suite":"police_e2e","ok":false,"error":"json_encode_failed"}'
        end

        print(('[E2E] ─── 结果: ✅ %d PASS | ❌ %d FAIL | ⏭️ %d SKIP ───')
            :format(counts.pass, counts.fail, counts.skip))
        print('E2E_RESULT ' .. encoded)
        print(('E2E_EXIT %d'):format(ok and 0 or 1))
    end, TEST_TIMEOUT_SECONDS)

end)

print('[test] ✅ police_e2e 真实 E2E 套件已注册 (1 个异步用例)')
