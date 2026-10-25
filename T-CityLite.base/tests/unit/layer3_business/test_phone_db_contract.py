"""
test_phone_db_contract.py — custom-phone data-layer contracts

Covers:
- PhoneDb.InsertId / PhoneDb.AffectedRows accept both the stock oxmysql
  numeric results and the bundled backend's `{ insertId, affectedRows }`
  table results (B02), never returning a table.
- The test fixture ships the new phone_messages structure (B01).
- The v2.7 migration keeps old rows in phone_messages_legacy and creates the
  two composite indexes.
"""

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
SMS_LUA = BASE / 'resources' / '[custom]' / 'custom-phone' / 'server' / 'sms.lua'
MAIN_LUA = BASE / 'resources' / '[custom]' / 'custom-phone' / 'server' / 'main.lua'
IDENTITY_LUA = BASE / 'resources' / '[custom]' / 'custom-phone' / 'server' / 'core' / 'identity.lua'
SCHEMA = BASE / 'tests' / 'fixtures' / 'tcity_schema.sql'
MIGRATION = BASE / 'migrations' / 'v2.7_phone_messages.sql'


def run_lua(source: str) -> subprocess.CompletedProcess:
    if not shutil.which('lua5.4'):
        pytest.skip('lua5.4 not installed')
    with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as f:
        f.write(source)
        path = f.name
    try:
        return subprocess.run(
            ['lua5.4', path], capture_output=True, text=True, timeout=10
        )
    finally:
        Path(path).unlink(missing_ok=True)


def _table_block(sql: str, table: str) -> str:
    start = sql.index(f'CREATE TABLE `{table}`')
    end = sql.index(';', start)
    return sql[start:end]


class TestPhoneDbHelpers:
    def test_insert_id_accepts_table_and_number(self):
        result = run_lua(f'''
local chunk = assert(loadfile([[{SMS_LUA}]]))
chunk()
assert(PhoneDb.InsertId({{ insertId = 42, affectedRows = 1 }}) == 42)
assert(PhoneDb.InsertId(42) == 42)
assert(PhoneDb.InsertId(nil) == 0)
assert(PhoneDb.InsertId({{ affectedRows = 1 }}) == 0)
''')
        assert result.returncode == 0, result.stderr

    def test_affected_rows_accepts_table_and_number(self):
        result = run_lua(f'''
local chunk = assert(loadfile([[{SMS_LUA}]]))
chunk()
assert(PhoneDb.AffectedRows({{ affectedRows = 3 }}) == 3)
assert(PhoneDb.AffectedRows(3) == 3)
assert(PhoneDb.AffectedRows(nil) == 0)
assert(PhoneDb.AffectedRows({{ insertId = 7 }}) == 0)
''')
        assert result.returncode == 0, result.stderr


class TestPhoneMessagesFixture:
    def test_fixture_has_new_columns(self):
        block = _table_block(SCHEMA.read_text(), 'phone_messages')
        for column in ('sender_number', 'receiver_number', 'message',
                       'timestamp', 'is_read'):
            assert f'`{column}`' in block, f'fixture missing {column}'
        for legacy in ('`citizenid`', '`number`', '`messages`'):
            assert legacy not in block, f'fixture still has legacy column {legacy}'

    def test_fixture_has_composite_indexes(self):
        block = _table_block(SCHEMA.read_text(), 'phone_messages')
        assert 'KEY `idx_receiver` (`receiver_number`,`id`)' in block
        assert 'KEY `idx_sender` (`sender_number`,`id`)' in block


class TestPhoneMessagesMigration:
    def test_migration_keeps_legacy_rows(self):
        sql = MIGRATION.read_text()
        assert 'phone_messages_legacy' in sql
        assert 'information_schema.COLUMNS' in sql
        assert 'information_schema.TABLES' in sql

    def test_migration_creates_new_structure_and_indexes(self):
        sql = MIGRATION.read_text()
        for column in ('sender_number', 'receiver_number', 'message',
                       'timestamp', 'is_read'):
            assert f'`{column}`' in sql
        assert re.search(r'KEY\s+`idx_receiver`\s+\(`receiver_number`,\s*`id`\)', sql)
        assert re.search(r'KEY\s+`idx_sender`\s+\(`sender_number`,\s*`id`\)', sql)

    def test_migration_is_rerunnable(self):
        sql = MIGRATION.read_text()
        # No destructive statements against the live table: it is renamed, and
        # the procedure is dropped/recreated on every run.
        assert 'DROP TABLE' not in sql
        assert 'DROP PROCEDURE IF EXISTS tcity_migrate_phone_messages_v27' in sql


def test_phone_messages_columns_match_fixture():
    """The columns the server code writes must exist in the fixture."""
    server = (BASE / 'resources' / '[custom]' / 'custom-phone' / 'server' / 'main.lua').read_text()
    block = _table_block(SCHEMA.read_text(), 'phone_messages')
    for column in ('sender_number', 'receiver_number', 'message'):
        assert column in block
        assert column in server


def _identity_block() -> str:
    """Load the pure identity module (no FiveM globals at load time)."""
    return IDENTITY_LUA.read_text()


class TestPhoneIdentity:
    def test_job_name_is_mapped_to_nui_role(self):
        code = _identity_block()
        result = run_lua(f'''
local chunk = assert(load([==[
{code}
]==]))
chunk()

local police = PhoneIdentity.From({{ job_name = 'police', rank_tier = 'leader' }})
assert(police.primary_role == 'police')
assert(PhoneIdentity.IsLeader(police))

assert(PhoneIdentity.From({{ job_name = 'ambulance' }}).primary_role == 'medic')
assert(PhoneIdentity.From({{ job_name = 'mayor', rank_tier = 'leader' }}).primary_role == 'mayor')
assert(PhoneIdentity.From({{ job_name = 'mechanic' }}).primary_role == 'mechanic')

local gang = PhoneIdentity.From({{ job_name = 'unemployed', gang_name = 'ballas', rank_tier = 'boss' }})
assert(gang.primary_role == 'gang')
assert(PhoneIdentity.IsLeader(gang))
assert(not PhoneIdentity.IsLeader(PhoneIdentity.From({{ job_name = 'police', rank_tier = 'mid' }})))
''')
        assert result.returncode == 0, result.stderr

    def test_legacy_and_missing_identities_fall_back(self):
        code = _identity_block()
        result = run_lua(f'''
local chunk = assert(load([==[
{code}
]==]))
chunk()

-- Legacy custom-phone identities carried primary_role and no job_name.
assert(PhoneIdentity.From({{ primary_role = 'police' }}).primary_role == 'police')

-- Nothing at all: never nil, so FactionMessages[role] / playerJobs[role]
-- cannot throw "table index is nil".
local none = PhoneIdentity.From(nil)
assert(none.primary_role == 'none')
assert(none.job_name == 'unemployed')
assert(none.rank_tier == 'entry')
assert(type(none.certs) == 'table')

-- Missing export must not leak an error and must resolve to 'none'.
exports = {{ ['custom-career'] = {{ GetPlayerIdentity = function() error('no career') end }} }}
assert(PhoneIdentity.Resolve(1).primary_role == 'none')
''')
        assert result.returncode == 0, result.stderr
