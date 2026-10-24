-- cases/police_outbox.lua — v3.12 police_outbox worker against the MySQL stub.
--
-- Drives the real `Outbox.Enqueue / Work` code from server/p2_system.lua:
--   * enqueue persists a pending row and kicks the worker;
--   * a delivered notification marks the row done (attempts+1, no next try);
--   * a rejected delivery increments attempts and schedules 30s/2m/10m;
--   * the 5th failure marks the row failed instead of retrying forever;
--   * an invalid payload fails immediately (no valid retry can fix it);
--   * cleanup deletes old done/failed rows.
--
-- The phone owner is faked through env.export_overrides['custom-phone'], so no
-- FXServer, player or real DB is needed.

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

        local env = ctx.bootstrap.Load({ load_main = false, convars = {} })
        dofile('T-CityLite.base/resources/[custom]/custom-police/shared/insert_id.lua')
        _G.Outbox = nil -- re-load a fresh table even when runner runs all cases
        dofile('T-CityLite.base/resources/[custom]/custom-police/server/p2_system.lua')
        local outbox = assert(_G.Outbox, 'Outbox global missing')

        local delivered = {}
        local notifyResult = true
        env.export_overrides['custom-phone'] = {
            Notify = function(citizenid, title, content, appId)
                if notifyResult == false then return false end
                delivered[#delivered + 1] = {
                    citizenid = citizenid, title = title, content = content, app_id = appId,
                }
                return true, 123
            end,
        }

        local function findLog(kind, needle)
            for _, entry in ipairs(env.mysql.log) do
                if entry.kind == kind and entry.sql:find(needle, 1, true) then
                    return entry
                end
            end
            return nil
        end

        local function queueRow(row)
            env.mysql.reset()
            env.mysql.log = {} -- isolate each check; the stub never clears it
            env.mysql.push({ match = 'SELECT id, topic, payload', result = { row } })
        end

        local function notificationRow(id, attempts, payload)
            return {
                id = id,
                topic = 'notification',
                payload = payload or
                    '{"citizenid":"ABC123","title":"911","content":"Shots fired","app_id":"police_mdt"}',
                attempts = attempts or 0,
            }
        end

        check('enqueue_persists_pending_and_kicks_worker', function()
            env.mysql.reset()
            local ok, id = env.exports.EnqueueOutbox('notification', {
                citizenid = 'ABC123', title = '911', content = 'Shots fired', app_id = 'police_mdt',
            })
            assert(ok == true and id == 1, 'enqueue should return true, id')
            local insert = findLog('insert', 'INSERT INTO police_outbox')
            assert(insert, 'police_outbox insert missing')
            assert(insert.params[1] == 'notification', 'topic param')
            assert(insert.params[2]:find('"citizenid":"ABC123"', 1, true), 'payload json')
            -- The Kick thread is queued; drain it so it cannot leak into the
            -- next check (no SELECT result queued -> it is a no-op).
            env.Drain()
        end)

        check('enqueue_rejects_unknown_topic_and_bad_payload', function()
            local ok, id = env.exports.EnqueueOutbox('bogus', { citizenid = 'ABC123' })
            assert(ok == false and id == nil, 'unknown topic')
            local ok2 = env.exports.EnqueueOutbox('notification', 'not-a-table')
            assert(ok2 == false, 'payload must be a table')
        end)

        check('delivery_marks_done_once', function()
            delivered = {}
            notifyResult = true
            queueRow(notificationRow(7, 0))
            local processed = outbox.Work()
            assert(processed == 1, 'one row processed')
            assert(#delivered == 1, 'phone Notify must be called once')
            assert(delivered[1].citizenid == 'ABC123', 'citizenid forwarded')
            assert(delivered[1].title == '911' and delivered[1].content == 'Shots fired', 'fields forwarded')
            assert(delivered[1].app_id == 'police_mdt', 'app_id forwarded')
            local done = findLog('update', "status = 'done'")
            assert(done, 'done update missing')
            assert(done.params[1] == 1 and done.params[2] == 7, 'attempts=1 for id 7')
            -- No pending retry row remains.
            assert(not findLog('update', "status = 'pending'"), 'done row must not be rescheduled')
        end)

        check('retry_backoff_30s_then_2m_then_10m', function()
            delivered = {}
            notifyResult = false
            for _, attempt in ipairs({ 0, 1, 2 }) do
                queueRow(notificationRow(8, attempt))
                outbox.Work()
                local pending = findLog('update', "status = 'pending'")
                assert(pending, 'retry update missing for attempt ' .. attempt)
                local expected = ({ 30, 120, 600 })[attempt + 1]
                assert(pending.params[1] == attempt + 1, 'attempts increment')
                assert(pending.params[2] == expected, ('backoff attempt %d: %s'):format(attempt + 1, tostring(pending.params[2])))
                assert(pending.params[3] == 8, 'row id')
            end
            assert(#delivered == 0, 'failed delivery must not count as sent')
        end)

        check('fifth_failure_marks_failed', function()
            notifyResult = false
            queueRow(notificationRow(9, 4))
            outbox.Work()
            local failedRow = findLog('update', "status = 'failed'")
            assert(failedRow, 'row must be marked failed after 5 attempts')
            assert(failedRow.params[1] == 5 and failedRow.params[2] == 9, 'attempts=5 for id 9')
            assert(not findLog('update', "status = 'pending'"), 'failed row must not retry')
        end)

        check('invalid_payload_fails_without_calling_phone', function()
            delivered = {}
            queueRow(notificationRow(10, 0, 'not-json'))
            outbox.Work()
            assert(#delivered == 0, 'invalid payload must not reach the phone')
            local pending = findLog('update', "status = 'pending'")
            assert(pending and pending.params[3] == 10, 'invalid payload retried once')
        end)

        check('cleanup_deletes_old_done_and_failed_rows', function()
            env.mysql.reset()
            outbox.Cleanup()
            local cleanup = findLog('update', 'DELETE FROM police_outbox')
            assert(cleanup, 'cleanup delete missing')
            assert(cleanup.sql:find("status IN ('done', 'failed')", 1, true), 'cleanup status filter')
            assert(cleanup.sql:find('INTERVAL 7 DAY', 1, true), 'cleanup retention')
        end)

        check('worker_is_reentrant_safe', function()
            delivered = {}
            notifyResult = true
            queueRow(notificationRow(11, 0))
            outbox.busy = true
            assert(outbox.Work() == 0, 'busy worker must not process')
            outbox.busy = false
            assert(outbox.Work() == 1, 'idle worker processes the row')
            assert(#delivered == 1)
        end)

        return { ok = failed == 0, error = failed == 0 and nil or ('outbox checks failed: ' .. failed), data = { results = results, failed = failed } }
    end,
}
