"""
test_quest_rewards.py — QuestRewards 统一奖励出口测试

覆盖:
- 优先走 core_economy:TriggerReward
- 网关缺失时回退 Player.Functions.AddMoney
- 不重复发放（网关成功时不再走 fallback）
"""

import os
import subprocess
import tempfile
from pathlib import Path
import pytest


BASE = Path(__file__).resolve().parents[3]
REWARDS_LUA = str(BASE / 'resources' / '[custom]' / 'custom-quest' / 'server' / 'quest_rewards.lua')


MOCK = r'''
__gatewayCalls = {}
__moneyCalls = {}
__gateway = {
    TriggerReward = function(_, source, activity, amount, options)
        table.insert(__gatewayCalls, { source = source, activity = activity, amount = amount, options = options })
        return true
    end,
}

_G.QBCore = {
    Functions = {
        GetPlayer = function(src)
            return {
                PlayerData = { citizenid = 'CID_TEST', source = src },
                Functions = {
                    AddMoney = function(account, amount, reason)
                        table.insert(__moneyCalls, { account = account, amount = amount, reason = reason })
                        return true
                    end,
                    AddItem = function() return true end,
                    AddRep = function() return true end,
                },
            }
        end,
    },
}

_G.Config = {
    Quest = {
        Rewards = {
            UseAddScaledMoney = true,
            DefaultAccountType = 'bank',
        },
    },
}

exports = setmetatable({}, {
    __index = function(_, k)
        if k == 'qb-core' then
            return { GetCoreObject = function() return _G.QBCore end }
        end
        if k == 'core_economy' then return __gateway end
        if k == 'custom-logs' then return nil end
        return {}
    end,
})

GetPlayerName = function() return 'Tester' end
TriggerClientEvent = function() end
RegisterNetEvent = function() end
AddEventHandler = function() end
GetLogisticsBinding = nil
CalculateCargoDamagePenalty = nil
CalculateTimeBonus = nil
print = function() end
'''


def run_rewards_test(test_code: str) -> dict:
    source = open(REWARDS_LUA, encoding='utf-8').read()
    source = source.replace("exports['qb-core']:GetCoreObject()", "QBCore")
    script = MOCK + '\n' + source + '\n' + test_code

    with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as f:
        f.write(script)
        tmp = f.name

    try:
        result = subprocess.run(['lua5.4', tmp], capture_output=True, text=True, timeout=10)
        return {'ok': result.returncode == 0, 'stderr': result.stderr}
    finally:
        os.unlink(tmp)


def test_gateway_used_when_available():
    result = run_rewards_test("""
QuestRewards.GrantRewards(1, { money = { min = 1000, max = 1000, type = 'bank' } }, 'quest_test')
assert(#__gatewayCalls == 1, 'core_economy gateway should be called once')
assert(__gatewayCalls[1].amount == 1000, 'gateway amount wrong')
assert(__gatewayCalls[1].options.skipHeat == true, 'quest rewards should skip heat')
assert(#__moneyCalls == 0, 'fallback AddMoney must not run when gateway succeeds')
""")
    assert result['ok'], f"Lua error: {result['stderr']}"


def test_fallback_when_gateway_missing():
    result = run_rewards_test("""
__gateway = nil
QuestRewards.GrantRewards(1, { money = { min = 2500, max = 2500, type = 'cash' } }, 'quest_fallback')
assert(#__gatewayCalls == 0, 'gateway should be unavailable')
assert(#__moneyCalls == 1, 'fallback AddMoney should run once')
assert(__moneyCalls[1].account == 'cash', 'fallback account wrong')
assert(__moneyCalls[1].amount == 2500, 'fallback amount wrong')
""")
    assert result['ok'], f"Lua error: {result['stderr']}"
