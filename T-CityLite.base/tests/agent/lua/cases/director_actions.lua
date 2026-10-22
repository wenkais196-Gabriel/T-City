-- tests/agent/lua/cases/director_actions.lua — executor contract for
-- custom-director's set_job (L3) and grant_item (L4) actions.
--
-- The executors live in server/main.lua; main exposes them on the internal
-- AgentActions._Execute table so this harness can drive them against the stub
-- QBCore player object. Approval still flows exclusively through
-- Propose/Approve, which this file does not exercise (policy.lua owns that).

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

        local function newEnv(convars)
            return ctx.bootstrap.Load({
                load_main = true,
                convars = convars or {},
            })
        end

        local function newPlayer(env, citizenid)
            local player = env.makePlayer(7, citizenid, { cash = 0, bank = 0, crypto = 0 })
            env.qb.Shared.Jobs = {
                police = {
                    label = 'Police',
                    defaultDuty = true,
                    grades = {
                        ['0'] = { name = 'Cadet', payment = 30 },
                        ['2'] = { name = 'Officer', payment = 50 },
                    },
                },
            }
            env.qb.Shared.Items = {
                bread = { name = 'bread', label = 'Bread', weight = 100, unique = false },
            }
            return player
        end

        local function setJob(env, citizenid, job, grade)
            return env.actions._Execute.set_job(1, {
                citizenid = citizenid,
                job = job,
                grade = grade,
            })
        end

        local function grantItem(env, citizenid, item, amount)
            return env.actions._Execute.grant_item(1, {
                citizenid = citizenid,
                item = item,
                amount = amount,
                reason = 'test reward',
            })
        end

        check('executors_exposed', function()
            local env = newEnv()
            assert(type(env.actions._Execute) == 'table', '_Execute table missing')
            assert(type(env.actions._Execute.set_job) == 'function', 'set_job executor missing')
            assert(type(env.actions._Execute.grant_item) == 'function', 'grant_item executor missing')
        end)

        check('set_job_success_records_before_after', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            local ok, err, result = setJob(env, 'ABC12345', 'police', 2)
            assert(ok == true, tostring(err))
            assert(result.before.job == 'unemployed' and result.before.grade == 0,
                'before must capture the previous job')
            assert(result.after.job == 'police' and result.after.grade == 2,
                'after must capture the applied job')
            assert(result.verify_result == true, 'verify_result must be true')
            assert(player.PlayerData.job.name == 'police', 'PlayerData.job was not updated')
            assert(player.PlayerData.job.grade.level == 2, 'grade level was not updated')
        end)

        check('set_job_returns_false_when_setjob_fails', function()
            local env = newEnv()
            newPlayer(env, 'ABC12345')
            local ok, err = setJob(env, 'ABC12345', 'ghostjob', 0)
            assert(ok == false, 'unknown job must fail')
            assert(tostring(err):match('^execution_failed'), tostring(err))
        end)

        check('set_job_readback_mismatch_is_verification_failed', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.Functions.SetJob = function() return true end -- lies: no mutation
            local ok, err = setJob(env, 'ABC12345', 'police', 2)
            assert(ok == false, 'unchanged job must fail verification')
            assert(tostring(err):match('^verification_failed'), tostring(err))
        end)

        check('set_job_offline_player', function()
            local env = newEnv()
            local ok, err = setJob(env, 'OFFLINE01', 'police', 0)
            assert(ok == false, 'offline target must fail')
            assert(err == 'player_not_found', tostring(err))
        end)

        check('grant_item_success_records_before_after', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            local ok, err, result = grantItem(env, 'ABC12345', 'bread', 3)
            assert(ok == true, tostring(err))
            assert(result.item == 'bread' and result.amount == 3, 'result item/amount mismatch')
            assert(result.before == 0 and result.after == 3, 'before/after mismatch')
            assert(result.reason == 'test reward', 'reason missing from result')
            assert(result.verify_result == true, 'verify_result must be true')
            assert(player.PlayerData.items['bread'] == 3, 'inventory was not mutated')

            local secondOk, secondErr, second = grantItem(env, 'ABC12345', 'bread', 2)
            assert(secondOk == true, tostring(secondErr))
            assert(second.before == 3 and second.after == 5, 'second grant before/after mismatch')
        end)

        check('grant_item_returns_false_when_additem_fails', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.Functions.AddItem = function() return false end
            local ok, err = grantItem(env, 'ABC12345', 'bread', 1)
            assert(ok == false, 'AddItem false must fail')
            assert(tostring(err):match('^execution_failed'), tostring(err))
        end)

        check('grant_item_delta_mismatch_is_verification_failed', function()
            local env = newEnv()
            local player = newPlayer(env, 'ABC12345')
            player.Functions.AddItem = function(item, amount)
                player.PlayerData.items[item] = (player.PlayerData.items[item] or 0) + amount - 1
                return true
            end
            local ok, err = grantItem(env, 'ABC12345', 'bread', 2)
            assert(ok == false, 'partial add must fail verification')
            assert(tostring(err):match('^verification_failed'), tostring(err))
        end)

        check('grant_item_offline_player', function()
            local env = newEnv()
            local ok, err = grantItem(env, 'OFFLINE01', 'bread', 1)
            assert(ok == false, 'offline target must fail')
            assert(err == 'player_not_found', tostring(err))
        end)

        check('grant_item_cap_comes_from_convar', function()
            local env = newEnv({ agent_actions_max_item_amount = '7' })
            assert(env.actions.Policy().limits.max_item_amount == 7, 'convar cap not read')
            assert(env.actions.Policy().actions.grant_item.max_amount == 7, 'action cap not exposed')

            local clamped = newEnv({ agent_actions_max_item_amount = '9999' })
            assert(clamped.actions.Policy().limits.max_item_amount == 1000, 'convar clamp failed')

            local fallback = newEnv()
            assert(fallback.actions.Policy().limits.max_item_amount == 50, 'default cap failed')
        end)

        return {
            ok = failed == 0,
            data = { total = #results, failed = failed, cases = results },
            error = failed == 0 and nil or 'executor cases failed',
        }
    end,
}
