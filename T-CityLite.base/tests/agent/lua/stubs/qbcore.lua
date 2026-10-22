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
