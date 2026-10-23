"""
test_core_economy.py — core_economy 统一奖励网关测试

重点验证：TriggerReward 最终调用 EconomyService.AddMoney（而不是已删除的
custom-economy:AddScaledMoney），防止任务奖励静默丢失。
"""

import os
import subprocess
import tempfile
from pathlib import Path
import pytest


BASE = Path(__file__).resolve().parents[3]
CORE_ECONOMY_LUA = str(BASE / 'resources' / '[system]' / 'core_economy' / 'server' / 'main.lua')


MOCK = r'''
__calls = {}
EconomyService = {
    AddMoney = function(citizenid, account, amount, reason)
        table.insert(__calls, { citizenid = citizenid, account = account, amount = amount, reason = reason })
        return true
    end,
}

_G.QBCore = {
    Functions = {
        GetPlayer = function(src)
            if tonumber(src) == 99 then return nil end
            return {
                PlayerData = {
                    citizenid = 'CID_ECON',
                    metadata = {},
                },
            }
        end,
    },
}

exports = setmetatable({}, {
    __index = function(_, k)
        if k == 'qb-core' then
            return { GetCoreObject = function() return _G.QBCore end }
        end
        return nil
    end,
    __call = function() return true end,
})

GetConvarInt = function(_, default) return default end
GetConvar = function(_, default) return default or '' end
CreateThread = function() end
AddEventHandler = function() end
TriggerEvent = function() end
SetTimeout = function() end
print = function() end
EventTypes = nil
'''


def run_core_economy_test(test_code: str) -> dict:
    source = open(CORE_ECONOMY_LUA, encoding='utf-8').read()
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


def test_trigger_reward_calls_economy_service_add_money():
    result = run_core_economy_test("""
local ok, granted = TriggerReward(1, 'quest:test', 1000, { skipHeat = true, moneytype = 'bank' })
assert(ok == true, 'TriggerReward should succeed')
assert(granted == 1000, 'granted amount should be 1000, got ' .. tostring(granted))
assert(#__calls == 1, 'EconomyService.AddMoney should be called once')
assert(__calls[1].citizenid == 'CID_ECON')
assert(__calls[1].account == 'bank')
assert(__calls[1].amount == 1000)
""")
    assert result['ok'], f"Lua error: {result['stderr']}"


def test_trigger_reward_missing_player_returns_false():
    result = run_core_economy_test("""
local ok = TriggerReward(99, 'quest:test', 1000, { skipHeat = true })
assert(ok == false, 'missing player should return false')
assert(#__calls == 0, 'no money should be granted')
""")
    assert result['ok'], f"Lua error: {result['stderr']}"
