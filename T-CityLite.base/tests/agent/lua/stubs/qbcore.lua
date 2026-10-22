-- tests/agent/lua/stubs/qbcore.lua — player objects for custom-director tests.
--
-- QBCore is reached through exports['qb-core']:GetCoreObject() in production;
-- the fivem stub routes that call to env.qb.

return function(env)
    env.players = env.players or {}
    env.players_by_citizenid = env.players_by_citizenid or {}
    env.notifications = env.notifications or {}
    env.money_log = env.money_log or {}

    local function makePlayer(source, citizenid, money)
        local player = {
            PlayerData = {
                source = source,
                citizenid = citizenid,
                money = money or { cash = 0, bank = 0, crypto = 0 },
                job = { name = 'unemployed', grade = { level = 0 } },
                items = {},
            },
            Functions = {},
        }

        function player.Functions.AddMoney(account, amount, reason)
            env.money_log[#env.money_log + 1] = {
                source = source,
                citizenid = citizenid,
                op = 'add',
                account = account,
                amount = amount,
                reason = reason,
            }
            return true
        end

        function player.Functions.RemoveMoney(account, amount, reason)
            env.money_log[#env.money_log + 1] = {
                source = source,
                citizenid = citizenid,
                op = 'remove',
                account = account,
                amount = amount,
                reason = reason,
            }
            return true
        end

        function player.Functions.Notify(text, kind, duration)
            env.notifications[#env.notifications + 1] = {
                source = source,
                citizenid = citizenid,
                text = text,
                kind = kind,
                duration = duration,
            }
            return true
        end

        function player.Functions.Save()
            env.log[#env.log + 1] = { save = citizenid }
            return true
        end

        -- Mirrors qb-core player.lua: an unknown job returns false, while an
        -- unknown grade still applies the job at level 0.
        function player.Functions.SetJob(job, grade)
            job = tostring(job):lower()
            local definition = (env.qb.Shared.Jobs or {})[job]
            if not definition then return false end
            local gradeKey = tostring(grade or '0')
            player.PlayerData.job = {
                name = job,
                grade = { level = 0, name = 'No Grades', payment = 30 },
            }
            local gradeInfo = definition.grades and definition.grades[gradeKey]
            if gradeInfo then
                player.PlayerData.job.grade = {
                    level = tonumber(gradeKey),
                    name = gradeInfo.name,
                    payment = gradeInfo.payment or 0,
                }
            end
            env.log[#env.log + 1] = {
                set_job = citizenid,
                job = job,
                grade = tonumber(gradeKey),
            }
            return true
        end

        -- qb-inventory AddPlayerMethod shape: GetItemByName returns nil when the
        -- player holds none, otherwise { amount = <count> }.
        function player.Functions.GetItemByName(item)
            local held = player.PlayerData.items[item]
            if held == nil then return nil end
            if type(held) == 'table' then return held end
            return { name = item, amount = held }
        end

        function player.Functions.AddItem(item, amount)
            local definition = (env.qb.Shared.Items or {})[tostring(item):lower()]
            if not definition then return false end
            local held = player.PlayerData.items[item]
            if type(held) == 'table' then
                held.amount = (held.amount or 0) + amount
            else
                player.PlayerData.items[item] = (held or 0) + amount
            end
            return true
        end

        env.players[source] = player
        env.players_by_citizenid[citizenid] = player
        return player
    end

    env.makePlayer = makePlayer

    env.qb = {
        Functions = {
            GetPlayer = function(source)
                return env.players[tonumber(source) or source]
            end,
            GetPlayers = function()
                local sources = {}
                for source in pairs(env.players) do
                    sources[#sources + 1] = source
                end
                table.sort(sources)
                return sources
            end,
            GetPlayerByCitizenId = function(citizenid)
                return env.players_by_citizenid[citizenid]
            end,
            Notify = function(source, text, kind)
                env.notifications[#env.notifications + 1] = {
                    source = source,
                    text = text,
                    kind = kind,
                }
                return true
            end,
        },
        Shared = {
            Round = function(value)
                return math.floor(value + 0.5)
            end,
        },
    }

    return env
end
