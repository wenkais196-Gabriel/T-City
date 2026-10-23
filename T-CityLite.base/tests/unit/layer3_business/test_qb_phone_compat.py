"""
test_qb_phone_compat.py — custom-phone compatibility layer for qb-phone.

Covers:
- the compat script exists and is loaded before server/main.lua;
- the qb-phone exports / server event the enabled resources call are provided;
- the client bridges for RemoveBankMoney and addPoliceAlert exist and never
  move money locally;
- mail validation (missing fields, overlong fields, invalid source) and the
  citizenid-existence path run against a Lua mock of QBCore/MySQL;
- a net event can only fill the caller's own tray, even if the payload
  carries another citizenid;
- mails are mapped to phone_notifications as plain text (no HTML, no
  player_mails writes);
- the `[compat]/qb-phone` export shim keeps the `exports['qb-phone']`
  namespace alive after qb-phone moved to archive/.
"""

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
PHONE_DIR = BASE / 'resources' / '[custom]' / 'custom-phone'
COMPAT_LUA = PHONE_DIR / 'server' / 'qb_phone_compat.lua'
SMS_LUA = PHONE_DIR / 'server' / 'sms.lua'
CLIENT_LUA = PHONE_DIR / 'client' / 'main.lua'
MANIFEST = PHONE_DIR / 'fxmanifest.lua'

SHIM_DIR = BASE / 'resources' / '[compat]' / 'qb-phone'
SHIM_LUA = SHIM_DIR / 'server' / 'main.lua'
SHIM_MANIFEST = SHIM_DIR / 'fxmanifest.lua'
CUSTOM_CFG = BASE / 'configs' / 'modules' / 'custom.cfg'
ARCHIVED_PHONE = BASE.parent / 'archive' / 'qb-phone'

BRIDGE_MARKER = '-- qb-phone compatibility bridge'


# ---------------------------------------------------------------------------
# Lua mock harness
# ---------------------------------------------------------------------------

HARNESS_TEMPLATE = r'''
-- Minimal FiveM/QBCore/oxmysql mock for server/qb_phone_compat.lua.
local SMS_PATH = [[@@SMS@@]]
local COMPAT_PATH = [[@@COMPAT@@]]

local smsChunk = assert(loadfile(SMS_PATH))
smsChunk()
assert(type(Sms) == 'table', 'server/sms.lua did not define Sms')
assert(type(PhoneDb) == 'table', 'server/sms.lua did not define PhoneDb')

local State = {
    inserts = {},
    pushes = {},
    clientEvents = {},
    exports = {},
    events = {},
    nextId = 500,
}

local Players = {
    [7] = { PlayerData = { source = 7, citizenid = 'CID7' } },
    [8] = { PlayerData = { source = 8, citizenid = 'CID8' } },
}
local byCitizen = { CID7 = Players[7], CID8 = Players[8] }
local OfflineCitizens = { CIDOFF = true }

QBCore = {
    Functions = {
        GetPlayer = function(src) return Players[src] end,
        GetPlayerByCitizenId = function(citizenid) return byCitizen[citizenid] end,
    },
}

exports = setmetatable({}, {
    __call = function(_, name, fn) State.exports[name] = fn end,
    __index = function(_, name)
        if name == 'qb-core' then
            return { GetCoreObject = function() return QBCore end }
        end
        return nil
    end,
})

function RegisterNetEvent(name, fn) State.events[name] = fn end

function TriggerClientEvent(name, target, payload)
    State.clientEvents[#State.clientEvents + 1] =
        { name = name, target = target, payload = payload }
end

MySQL = {
    Async = {
        insert = function(query, params, cb)
            State.inserts[#State.inserts + 1] = { query = query, params = params }
            if cb then cb({ insertId = State.nextId, affectedRows = 1 }) end
        end,
    },
    query = {
        await = function(_, params)
            if OfflineCitizens[params[1]] then
                return { { citizenid = params[1] } }
            end
            return {}
        end,
    },
}

-- Production path: server/main.lua defines this after qb_phone_compat.lua
-- loads, so it is resolved at call time.
function PhoneNotify(src, notification)
    State.pushes[#State.pushes + 1] = { src = src, notification = notification }
end

assert(loadfile(COMPAT_PATH))()
'''


def run_lua(source: str) -> subprocess.CompletedProcess:
    if not shutil.which('lua5.4'):
        pytest.skip('lua5.4 not installed')
    with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as f:
        f.write(source)
        path = f.name
    try:
        return subprocess.run(
            ['lua5.4', path], capture_output=True, text=True, timeout=15
        )
    finally:
        Path(path).unlink(missing_ok=True)


def run_harness(body: str) -> subprocess.CompletedProcess:
    harness = (
        HARNESS_TEMPLATE
        .replace('@@SMS@@', str(SMS_LUA))
        .replace('@@COMPAT@@', str(COMPAT_LUA))
    )
    return run_lua(harness + '\n' + body + '\n')


# ---------------------------------------------------------------------------
# Static contracts
# ---------------------------------------------------------------------------

class TestStaticContracts:
    def test_compat_script_exists(self):
        assert COMPAT_LUA.is_file(), 'server/qb_phone_compat.lua is missing'
        assert COMPAT_LUA.stat().st_size > 0

    def test_manifest_loads_compat_before_main(self):
        manifest = MANIFEST.read_text(encoding='utf-8')
        block = re.search(r'server_scripts\s*\{(.*?)\}', manifest, re.S)
        assert block, 'server_scripts block not found'
        scripts = block.group(1)

        assert "'server/qb_phone_compat.lua'" in scripts
        compat_at = scripts.index("'server/qb_phone_compat.lua'")
        assert scripts.index("'server/sms.lua'") < compat_at, \
            'compat needs Sms/PhoneDb from server/sms.lua'
        assert compat_at < scripts.index("'server/main.lua'"), \
            'compat must register events before server/main.lua'

    def test_exports_and_event_are_declared(self):
        compat = COMPAT_LUA.read_text(encoding='utf-8')
        for needle in (
            "exports('sendNewMail'",
            "exports('sendNewMailToOffline'",
            "RegisterNetEvent('qb-phone:server:sendNewMail'",
            'phone_notifications',
        ):
            assert needle in compat, f'compat missing {needle}'

    def test_no_client_triggerable_police_alert_event(self):
        """qb-phone has no server-side police-alert variant; adding one would
        let any client broadcast fake police alerts to every officer."""
        compat = COMPAT_LUA.read_text(encoding='utf-8')
        assert "RegisterNetEvent('qb-phone:server:addPoliceAlert'" not in compat

    def test_client_bridges_exist(self):
        client = CLIENT_LUA.read_text(encoding='utf-8')
        for needle in (
            "RegisterNetEvent('qb-phone:client:RemoveBankMoney'",
            "RegisterNetEvent('qb-phone:client:addPoliceAlert'",
        ):
            assert needle in client, f'client bridge missing {needle}'

    def test_client_bridge_never_moves_money(self):
        block = _client_bridge_block()
        for forbidden in ('AddMoney', 'RemoveMoney', 'SetMoney', 'addMoney',
                          'removeMoney', 'SetPlayerMoney'):
            assert forbidden not in block, \
                f'client bridge must not call {forbidden}'
        assert "TriggerServerEvent('bank" not in block, \
            'client bridge must not trigger banking writes'

    def test_client_money_bridge_refetches_server_balance(self):
        block = _client_bridge_block()
        assert "'phone:server:getPhoneData'" in block, \
            'money bridge must re-read the authoritative balance'
        assert "action = 'phone:updateMoney'" in block

    def test_client_police_alert_becomes_a_notification(self):
        block = _client_bridge_block()
        assert "action = 'phone:newNotification'" in block
        assert 'qbPoliceAlertSeq' in block, \
            'transient alerts need ids that cannot collide with DB rows'
        # qb-phone's own NUI action / police app do not exist in custom-phone.
        assert "action = 'AddPoliceAlert'" not in block

    def test_client_police_alert_keeps_leo_duty_gate(self):
        """qb-storerobbery broadcasts to -1; qb-phone filtered on-duty cops on
        the client, and the tray is visible to every player here."""
        block = _client_bridge_block()
        assert "job.type ~= 'leo'" in block, \
            'police alerts must not reach non-LEO players'
        assert 'not job.onduty' in block, \
            'off-duty players must not receive police alerts'

    def test_compat_syntax(self):
        luac = shutil.which('luac5.4')
        if not luac:
            pytest.skip('luac5.4 not installed')
        result = subprocess.run(
            [luac, '-p', str(COMPAT_LUA)], capture_output=True, text=True
        )
        assert result.returncode == 0, result.stderr


def _client_bridge_block() -> str:
    client = CLIENT_LUA.read_text(encoding='utf-8')
    start = client.index(BRIDGE_MARKER)
    return client[start:]


# ---------------------------------------------------------------------------
# Lua behaviour: exports
# ---------------------------------------------------------------------------

def test_send_new_mail_valid_maps_to_notification():
    result = run_harness(r'''
assert(type(State.exports.sendNewMail) == 'function', 'sendNewMail export missing')
assert(type(State.exports.sendNewMailToOffline) == 'function',
       'sendNewMailToOffline export missing')

local ok, err = State.exports.sendNewMail(7, {
    sender = 'Maze Bank',
    subject = 'Statement',
    message = 'Hello <b>there</b><br>Balance: $10 &amp; fees',
})
assert(ok == true, 'valid mail rejected: ' .. tostring(err))
assert(#State.pushes == 1, 'online mail must push exactly once, got ' .. #State.pushes)
assert(State.pushes[1].src == 7, 'mail pushed to wrong source')
local n = State.pushes[1].notification
assert(n.title == 'Maze Bank: Statement', 'unexpected title: ' .. tostring(n.title))
assert(n.content == 'Hello there\nBalance: $10 & fees',
       'unexpected content: ' .. tostring(n.content))
assert(not n.content:find('<', 1, true), 'HTML leaked into notification content')
assert(#State.inserts == 0, 'online mail must not insert a second row')
''')
    assert result.returncode == 0, result.stderr


def test_send_new_mail_rejects_bad_params():
    result = run_harness(r'''
local cases = {
    { name = 'nil mail', mail = nil, err = 'invalid_mail' },
    { name = 'string mail', mail = 'nope', err = 'invalid_mail' },
    { name = 'missing sender', mail = { subject = 's', message = 'm' }, err = 'invalid_sender' },
    { name = 'blank sender', mail = { sender = '   ', subject = 's', message = 'm' }, err = 'invalid_sender' },
    { name = 'long sender', mail = { sender = string.rep('s', 65), subject = 's', message = 'm' }, err = 'invalid_sender' },
    { name = 'missing subject', mail = { sender = 'X', message = 'm' }, err = 'invalid_subject' },
    { name = 'long subject', mail = { sender = 'X', subject = string.rep('s', 121), message = 'm' }, err = 'invalid_subject' },
    { name = 'missing message', mail = { sender = 'X', subject = 's' }, err = 'invalid_message' },
    { name = 'blank message', mail = { sender = 'X', subject = 's', message = '  ' }, err = 'invalid_message' },
    { name = 'long message', mail = { sender = 'X', subject = 's', message = string.rep('m', 2001) }, err = 'invalid_message' },
}
for _, case in ipairs(cases) do
    local ok, err = State.exports.sendNewMail(7, case.mail)
    assert(ok == false, case.name .. ': expected rejection')
    assert(err == case.err, case.name .. ': expected ' .. case.err .. ', got ' .. tostring(err))
end
assert(#State.pushes == 0, 'rejected mails must not reach the UI')
assert(#State.inserts == 0, 'rejected mails must not reach the DB')

local ok, err = State.exports.sendNewMail(424242, { sender = 'X', subject = 's', message = 'm' })
assert(ok == false and err == 'invalid_source', 'unknown source must be rejected')
assert(#State.pushes == 0)
''')
    assert result.returncode == 0, result.stderr


def test_send_new_mail_truncates_long_body_to_notification_limit():
    result = run_harness(r'''
local ok = State.exports.sendNewMail(7, {
    sender = 'City',
    subject = 'Big',
    message = string.rep('x', 2000),
})
assert(ok == true)
local n = State.pushes[1].notification
assert(#n.content == 1000, 'content must be capped at 1000 chars, got ' .. #n.content)
''')
    assert result.returncode == 0, result.stderr


def test_send_new_mail_sanitises_labels_and_entities():
    result = run_harness(r'''
local ok = State.exports.sendNewMail(7, {
    sender = 'Bad\nSender',
    subject = '<i>Subject</i>',
    message = 'A &lt; B &amp; C',
})
assert(ok == true)
local n = State.pushes[1].notification
assert(n.title == 'Bad Sender: Subject',
       'control chars/markup not cleaned: ' .. tostring(n.title))
assert(n.content == 'A < B & C', 'entities not decoded: ' .. tostring(n.content))
''')
    assert result.returncode == 0, result.stderr


# ---------------------------------------------------------------------------
# Lua behaviour: sendNewMailToOffline
# ---------------------------------------------------------------------------

def test_send_new_mail_to_offline_requires_existing_citizenid():
    result = run_harness(r'''
local mail = {
    sender = 'Township',
    subject = 'Driving lessons request',
    message = 'Hello,<br><br>Please contact <strong>Bob</strong>.',
}

local ok, err = State.exports.sendNewMailToOffline('NOBODY', mail)
assert(ok == false, 'unknown citizenid accepted')
assert(err == 'unknown_citizenid', 'unexpected error: ' .. tostring(err))
assert(#State.inserts == 0, 'unknown citizenid must not insert')

ok, err = State.exports.sendNewMailToOffline("CID' OR 1=1 --", mail)
assert(ok == false and err == 'unknown_citizenid',
       'malformed citizenid must be rejected before SQL')
assert(#State.inserts == 0, 'malformed citizenid must not insert')

ok, err = State.exports.sendNewMailToOffline('CIDOFF', mail)
assert(ok == true, 'offline mail rejected: ' .. tostring(err))
assert(#State.inserts == 1, 'offline mail must be persisted')
local insert = State.inserts[1]
assert(insert.query:find('phone_notifications', 1, true),
       'offline mail must land in phone_notifications')
assert(insert.query:find('player_mails', 1, true) == nil,
       'must not write qb-phone player_mails')
assert(insert.params[1] == 'CIDOFF', 'wrong citizenid')
assert(insert.params[2] == 'Township: Driving lessons request',
       'unexpected title: ' .. tostring(insert.params[2]))
assert(not insert.params[3]:find('<', 1, true), 'HTML leaked into stored content')
assert(insert.params[3]:find('Please contact Bob.', 1, true),
       'message text lost: ' .. tostring(insert.params[3]))
assert(#State.pushes == 0, 'offline mail must not push to a client')
''')
    assert result.returncode == 0, result.stderr


def test_send_new_mail_to_offline_pushes_when_player_online():
    result = run_harness(r'''
local ok, err = State.exports.sendNewMailToOffline('CID8', {
    sender = 'City', subject = 'Hello', message = 'body',
})
assert(ok == true, 'online citizenid rejected: ' .. tostring(err))
assert(#State.pushes == 1, 'online citizenid must push once')
assert(State.pushes[1].src == 8, 'wrong target source')
assert(#State.inserts == 0, 'online delivery must rely on PhoneNotify')
''')
    assert result.returncode == 0, result.stderr


# ---------------------------------------------------------------------------
# Lua behaviour: qb-phone:server:sendNewMail event
# ---------------------------------------------------------------------------

def test_server_event_only_fills_the_callers_tray():
    result = run_harness(r'''
assert(type(State.events['qb-phone:server:sendNewMail']) == 'function',
       'qb-phone:server:sendNewMail event not registered')

source = 7
State.events['qb-phone:server:sendNewMail']({
    sender = 'Police',
    subject = 'Fine',
    message = 'Pay up',
    citizenid = 'CID8',                     -- attempted target override
    source = 8,
    PlayerData = { citizenid = 'CID8' },
    button = { type = 'invoice', id = 1 },
})
assert(#State.pushes == 1, 'event must deliver to the sender once')
assert(State.pushes[1].src == 7, 'event delivered to someone other than the sender')
assert(State.pushes[1].notification.title == 'Police: Fine',
       'unexpected title: ' .. tostring(State.pushes[1].notification.title))
for _, insert in ipairs(State.inserts) do
    assert(insert.params[1] ~= 'CID8',
           'payload citizenid must never select another tray')
end

local pushes = #State.pushes
source = 7
State.events['qb-phone:server:sendNewMail']({ sender = 'Police', subject = 'Broken' })
assert(#State.pushes == pushes, 'invalid event mail must be dropped')

source = 7
State.events['qb-phone:server:sendNewMail']({
    sender = 'X', subject = 's', message = string.rep('x', 2001),
})
assert(#State.pushes == pushes, 'overlong event mail must be dropped')

source = 424242
State.events['qb-phone:server:sendNewMail']({ sender = 'X', subject = 's', message = 'm' })
assert(#State.pushes == pushes, 'event from unknown source must be dropped')
''')
    assert result.returncode == 0, result.stderr


def test_delivery_falls_back_to_insert_without_phone_notify():
    result = run_harness(r'''
local saved = PhoneNotify
PhoneNotify = nil
local ok, err = State.exports.sendNewMail(8, {
    sender = 'City', subject = 'Fallback', message = 'db path',
})
PhoneNotify = saved
assert(ok == true, 'fallback delivery rejected: ' .. tostring(err))
assert(#State.inserts == 1, 'fallback must insert when PhoneNotify is unavailable')
assert(State.inserts[1].params[1] == 'CID8', 'fallback inserted for wrong citizenid')
assert(#State.pushes == 0)
''')
    assert result.returncode == 0, result.stderr


# ---------------------------------------------------------------------------
# exports['qb-phone'] namespace shim
# ---------------------------------------------------------------------------
# Exports are namespaced per resource, so registering sendNewMail on
# custom-phone alone does NOT satisfy `exports['qb-phone']:sendNewMail...`.
# After archiving qb-phone, a resource literally named `qb-phone` must remain
# loaded to answer that namespace; it forwards to custom-phone.

class TestExportShim:
    def test_shim_exists_and_has_no_duplicate_event_handlers(self):
        assert SHIM_LUA.is_file(), '[compat]/qb-phone shim is missing'
        shim = SHIM_LUA.read_text(encoding='utf-8')
        assert "exports['custom-phone']" in shim
        assert 'RegisterNetEvent' not in shim, \
            'net events are already handled by custom-phone; do not duplicate them'

    def test_shim_forwards_both_mail_exports(self):
        shim = SHIM_LUA.read_text(encoding='utf-8')
        for export in ('sendNewMail', 'sendNewMailToOffline'):
            assert f"exports('{export}'" in shim, f'shim missing export {export}'
            assert f":{export}(" in shim, f'shim does not forward {export}'

    def test_shim_manifest_depends_on_custom_phone(self):
        manifest = SHIM_MANIFEST.read_text(encoding='utf-8')
        assert "'server/main.lua'" in manifest
        assert "'custom-phone'" in manifest, \
            'shim must load after the real phone (dependencies)'

    def test_shim_is_ensured_after_custom_phone(self):
        cfg = CUSTOM_CFG.read_text(encoding='utf-8')
        assert re.search(r'^\s*ensure\s+custom-phone\b', cfg, re.M), \
            'custom-phone must be ensured'
        assert re.search(r'^\s*ensure\s+qb-phone\b', cfg, re.M), \
            'the qb-phone export shim must be ensured'
        assert cfg.index('ensure custom-phone') < cfg.index('ensure qb-phone'), \
            'shim needs custom-phone running first'

    def test_old_phone_is_out_of_the_resources_tree(self):
        assert not (BASE / 'resources' / '[qb]' / 'qb-phone').exists(), \
            'archived qb-phone must not be loadable from resources/'
        assert ARCHIVED_PHONE.is_dir(), 'archived qb-phone is missing'

    def test_shim_forwards_arguments_through_exports(self):
        if not shutil.which('lua5.4'):
            pytest.skip('lua5.4 not installed')
        lua = r'''
local State = { exports = {}, forwarded = {} }
exports = setmetatable({}, {
    __call = function(_, name, fn) State.exports[name] = fn end,
    __index = function(_, name)
        if name == 'custom-phone' then
            -- FiveM's export proxy is the implicit self of `proxy:fn(...)`;
            -- it is not forwarded to the Lua export function.
            return {
                sendNewMail = function(_, src, mail)
                    State.forwarded[#State.forwarded + 1] = { name = 'sendNewMail', src = src, mail = mail }
                    return true
                end,
                sendNewMailToOffline = function(_, cid, mail)
                    State.forwarded[#State.forwarded + 1] = { name = 'sendNewMailToOffline', cid = cid, mail = mail }
                    return true, nil
                end,
            }
        end
        return nil
    end,
})
assert(loadfile([[@@SHIM@@]]))()

local mail = { sender = 'City', subject = 'Sub', message = 'Body' }
assert(State.exports.sendNewMail(7, mail) == true)
assert(State.forwarded[1].name == 'sendNewMail')
assert(State.forwarded[1].src == 7)
assert(State.forwarded[1].mail == mail)

local ok, err = State.exports.sendNewMailToOffline('CID7', mail)
assert(ok == true and err == nil)
assert(State.forwarded[2].name == 'sendNewMailToOffline')
assert(State.forwarded[2].cid == 'CID7')
assert(State.forwarded[2].mail == mail)
'''.replace('@@SHIM@@', str(SHIM_LUA))
        result = run_lua(lua)
        assert result.returncode == 0, result.stderr
