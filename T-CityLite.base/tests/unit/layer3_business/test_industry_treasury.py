"""组织金库（S1）：真跑 Lua，桩只替换 MySQL。

这里钉四件在并发/故障下最容易写错的事：

1. **余额判断与扣减是一条 UPDATE**（affectedRows 是唯一裁决依据）。两个并发取款
   各自都"看起来够"，但守卫必须在数据库里，不能先 `Db.Single` 再比较。
2. **幂等键是数据库的 UNIQUE(org_id, ref)**。测试从迁移文件读这条约束是否还在；
   删掉迁移里的唯一键，幂等用例必须真的变红（桩不会替数据库撒谎）。
3. **先改余额、成功后才插流水**；插流水失败要把余额补偿回去，返回 db_error。
4. 守卫不能误伤正常流程：合法的第二个不同 ref 必须成功（正向控制）。

跑法：``uv run --with pytest python -m pytest tests/unit/layer3_business/test_industry_treasury.py -q``
"""

from __future__ import annotations

import re
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

from lua_probe import BASE, load_industry

RES = BASE / "resources" / "[custom]" / "custom-industry"
SRC = RES / "server" / "treasury.lua"
COMMANDS = RES / "server" / "commands.lua"
AUDIT = RES / "server" / "audit.lua"
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "industry_treasury_probe.lua"
MIGRATION = BASE / "migrations" / "v4.0_industry_treasury.sql"
SCHEMA_FIXTURE = BASE / "tests" / "fixtures" / "tcity_schema.sql"

TABLES = ("org_treasury", "org_ledger", "industry_audit")
UNIQUE_KEY = re.compile(
    r"UNIQUE\s+KEY\s+`uniq_org_ref`\s*\(\s*`org_id`\s*,\s*`ref`\s*\)", re.I
)


def _strip_sql_comments(sql: str) -> str:
    return re.sub(r"--[^\n]*", "", re.sub(r"/\*.*?\*/", "", sql, flags=re.S))


def _migration_sql() -> str:
    return _strip_sql_comments(MIGRATION.read_text(encoding="utf-8"))


def unique_ref_declared() -> bool:
    """幂等键是否真的写在迁移里 —— 桩的唯一性开关由这个事实驱动。"""
    return UNIQUE_KEY.search(_migration_sql()) is not None


def lua() -> str:
    exe = shutil.which("lua5.4") or shutil.which("lua")
    if not exe:
        pytest.skip("lua5.4 不可用")
    return exe


def run(body: str) -> dict[str, str]:
    """把探针桩 + db.lua + treasury.lua + body 拼成一次 Lua 运行。"""
    stubs = FIXTURE.read_text(encoding="utf-8")
    flag = "true" if unique_ref_declared() else "false"
    script = load_industry(stubs, SRC, f"__uniqueRef = {flag}\n" + textwrap.dedent(body))
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}\n{proc.stdout}"

    out: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        out.setdefault(key.strip(), value.strip())
    return out


# ══════════════════════════════════════════════════════════════════
# 存款 / 取款
# ══════════════════════════════════════════════════════════════════


def test_deposit_credits_balance_and_writes_one_ledger_row():
    out = run("""
        __reset()
        __seed('mining_co', 0)
        local ok, err = Treasury.Deposit('mining_co', 1000, 'deposit', { actor = 'cid1', ref = 'r1' })
        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEDGER', tostring(__ledgerCount()))
        __emit('DELTA', tostring(__ledger[1] and __ledger[1].delta))
        __emit('AFTER', tostring(__ledger[1] and __ledger[1].balance_after))
        __emit('REF', tostring(__ledger[1] and __ledger[1].ref))
    """)
    assert out["OK"] == "true", f"正常存款被拒了：{out}"
    assert out["ERR"] == "nil", "成功时不应带错误码"
    assert out["BAL"] == "1000", "组织余额没有 +1000"
    assert out["LEDGER"] == "1", "成功存款必须恰好写一行流水"
    assert out["DELTA"] == "1000", "流水 delta 与入账金额不一致"
    assert out["AFTER"] == "1000", "流水 balance_after 必须是入账后的余额"
    assert out["REF"] == "r1", "调用方给的合法 ref 必须原样落库（幂等键不能悄悄换掉）"


def test_withdraw_beyond_balance_is_rejected_without_moving_money():
    out = run("""
        __reset()
        __seed('mining_co', 500)
        local ok, err = Treasury.Withdraw('mining_co', 9999, 'withdraw', { actor = 'cid1', ref = 'w1' })
        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEDGER', tostring(__ledgerCount()))
        __emit('INSERTS', tostring(__calls.insert))
    """)
    assert out["OK"] == "false", "余额 500 取 9999 竟然成功 —— 余额守卫没生效"
    assert out["ERR"] == "insufficient_funds", f"错误码必须是 insufficient_funds，实际 {out['ERR']}"
    assert out["BAL"] == "500", "被拒绝的取款动了余额"
    assert out["LEDGER"] == "0", "被拒绝的取款写了流水"
    assert out["INSERTS"] == "0", "余额判断失败后不应再尝试插流水"


def test_deposit_to_missing_account_is_no_account_and_creates_nothing():
    out = run("""
        __reset()
        local ok, err = Treasury.Deposit('cartel', 1000, 'deposit', { ref = 'nc1' })
        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('BAL', tostring(__balance('cartel')))
        __emit('LEDGER', tostring(__ledgerCount()))
    """)
    assert out["OK"] == "false", "S1 不自动开户，入账到不存在的组织必须失败"
    assert out["ERR"] == "no_account", f"错误码必须是 no_account，实际 {out['ERR']}"
    assert out["BAL"] == "nil", "失败的入账不该凭空建出账户"
    assert out["LEDGER"] == "0", "失败的入账不该写流水"


# ══════════════════════════════════════════════════════════════════
# 幂等：同一 ref 只成功一次
# ══════════════════════════════════════════════════════════════════


def test_duplicate_ref_is_rejected_and_balance_is_rolled_back():
    out = run("""
        __reset()
        __seed('mining_co', 0)
        local ok1, err1 = Treasury.Deposit('mining_co', 1000, 'deposit', { actor = 'cid1', ref = 'same' })
        local ok2, err2 = Treasury.Deposit('mining_co', 1000, 'deposit', { actor = 'cid1', ref = 'same' })
        __emit('OK1', tostring(ok1))
        __emit('ERR1', tostring(err1 or 'nil'))
        __emit('OK2', tostring(ok2))
        __emit('ERR2', tostring(err2 or 'nil'))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEDGER', tostring(__ledgerCount()))
    """)
    assert out["OK1"] == "true", "第一次入账应当成功"
    assert out["ERR1"] == "nil"
    assert out["OK2"] == "false", "同一 ref 第二次入账竟然成功 —— 唯一键/idempotency 没生效"
    assert out["ERR2"] == "duplicate_ref", f"错误码必须是 duplicate_ref，实际 {out['ERR2']}"
    assert out["BAL"] == "1000", "重复入账的余额没有被补偿回去"
    assert out["LEDGER"] == "1", "重复 ref 不应产生第二行流水"


def test_opaque_driver_error_on_duplicate_still_maps_to_duplicate_ref():
    """有的 oxmysql 构建把唯一键冲突当字符串回包，db.lua 会丢掉原文。

    这种情况下仍要返回 duplicate_ref（靠一次失败后的存在性检查），不能报 db_error
    —— 否则调用方会把它当成可重试的故障，反复入账。
    """
    out = run("""
        __reset()
        __seed('mining_co', 0)
        local ok1 = Treasury.Deposit('mining_co', 1000, 'deposit', { actor = 'cid1', ref = 'same' })
        __opaqueInsertError = true
        local ok2, err2 = Treasury.Deposit('mining_co', 500, 'deposit', { actor = 'cid1', ref = 'same' })
        __emit('OK1', tostring(ok1))
        __emit('OK2', tostring(ok2))
        __emit('ERR2', tostring(err2 or 'nil'))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEDGER', tostring(__ledgerCount()))
    """)
    assert out["OK1"] == "true"
    assert out["OK2"] == "false", "驱动回包形态不同，重复 ref 也不能成功"
    assert out["ERR2"] == "duplicate_ref", (
        f"唯一键冲突被误报成 {out['ERR2']}（调用方会重试）"
    )
    assert out["BAL"] == "1000", "重复入账的余额没有补偿回去"
    assert out["LEDGER"] == "1"


def test_concurrent_same_ref_applies_exactly_once():
    """A 的 UPDATE 尚未落库时让 B 用同一 ref 插进来。"""
    out = run("""
        __reset()
        __seed('mining_co', 0)
        local results = {}
        __race = function()
            local ok, err = Treasury.Deposit('mining_co', 1000, 'deposit', { actor = 'cid1', ref = 'race' })
            results[#results + 1] = tostring(ok) .. ':' .. tostring(err or 'nil')
        end
        local ok, err = Treasury.Deposit('mining_co', 1000, 'deposit', { actor = 'cid1', ref = 'race' })
        results[#results + 1] = tostring(ok) .. ':' .. tostring(err or 'nil')
        table.sort(results)
        __emit('RESULTS', table.concat(results, ','))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEDGER', tostring(__ledgerCount()))
    """)
    assert out["RESULTS"] == "false:duplicate_ref,true:nil", (
        f"并发同 ref 必须一成一败，实际 {out['RESULTS']}"
    )
    assert out["BAL"] == "1000", "并发同 ref 只能入账一次"
    assert out["LEDGER"] == "1", "并发同 ref 只能留下一行流水"


def test_positive_control_second_distinct_ref_still_succeeds():
    """守卫不能把正常流程也拒了：换一个 ref 必须能继续入账。"""
    out = run("""
        __reset()
        __seed('mining_co', 0)
        local ok1, err1 = Treasury.Deposit('mining_co', 1000, 'deposit', { actor = 'cid1', ref = 'a' })
        local ok2, err2 = Treasury.Deposit('mining_co', 1000, 'deposit', { actor = 'cid1', ref = 'b' })
        __emit('OK1', tostring(ok1))
        __emit('ERR1', tostring(err1 or 'nil'))
        __emit('OK2', tostring(ok2))
        __emit('ERR2', tostring(err2 or 'nil'))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEDGER', tostring(__ledgerCount()))
    """)
    assert out["OK1"] == "true" and out["OK2"] == "true", (
        f"不同 ref 的第二次入账被误伤：{out}"
    )
    assert out["BAL"] == "2000", "两笔合法入账应累计到 2000"
    assert out["LEDGER"] == "2", "两笔合法入账应有两行流水"


# ══════════════════════════════════════════════════════════════════
# TOCTOU：两个取款交错，不能透支
# ══════════════════════════════════════════════════════════════════


def test_concurrent_withdrawals_cannot_overdraw():
    """余额 150，两笔各取 100：交错后必须只成功一笔，余额不得为负。

    这条用例专门咬「先 Db.Single 再比较」的写法：两边都读到 150、都判够，
    再把余额扣成 -50。把余额判断挪回一条带守卫的 UPDATE 才会绿。
    """
    out = run("""
        __reset()
        __seed('mining_co', 150)
        local results = {}
        __race = function()
            local ok, err = Treasury.Withdraw('mining_co', 100, 'withdraw', { actor = 'cid1', ref = 'race-b' })
            results[#results + 1] = tostring(ok) .. ':' .. tostring(err or 'nil')
        end
        local ok, err = Treasury.Withdraw('mining_co', 100, 'withdraw', { actor = 'cid1', ref = 'race-a' })
        results[#results + 1] = tostring(ok) .. ':' .. tostring(err or 'nil')
        table.sort(results)
        __emit('RESULTS', table.concat(results, ','))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEDGER', tostring(__ledgerCount()))
    """)
    assert out["RESULTS"] == "false:insufficient_funds,true:nil", (
        f"两笔各 100 的取款在余额 150 上只能成功一笔，实际 {out['RESULTS']}"
    )
    assert out["BAL"] == "50", f"余额被扣成 {out['BAL']}（透支了）"
    assert out["LEDGER"] == "1", "失败的那笔不应留下流水"


# ══════════════════════════════════════════════════════════════════
# 故障与输入校验
# ══════════════════════════════════════════════════════════════════


def test_ledger_insert_failure_rolls_balance_back():
    out = run("""
        __reset()
        __seed('mining_co', 0)
        __failLedgerInsert = true
        local ok, err = Treasury.Deposit('mining_co', 1000, 'deposit', { ref = 'f1' })
        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEDGER', tostring(__ledgerCount()))
    """)
    assert out["OK"] == "false", "流水写失败时不能向调用方报成功"
    assert out["ERR"] == "db_error", f"流水写失败应返回 db_error，实际 {out['ERR']}"
    assert out["BAL"] == "0", "流水写失败后余额必须补偿回原值（钱少了流水没记是禁区）"
    assert out["LEDGER"] == "0"


def test_input_validation_error_codes():
    out = run("""
        __reset()
        __seed('mining_co', 100)
        local _, e1 = Treasury.Deposit('', 1000, 'deposit', {})
        local _, e2 = Treasury.Deposit('mining_co', 0, 'deposit', {})
        local _, e3 = Treasury.Withdraw('mining_co', -5, 'withdraw', {})
        local _, e4 = Treasury.Deposit('mining_co', 'abc', 'deposit', {})
        __emit('E1', tostring(e1))
        __emit('E2', tostring(e2))
        __emit('E3', tostring(e3))
        __emit('E4', tostring(e4))
        __emit('BAL', tostring(__balance('mining_co')))
    """)
    assert out["E1"] == "bad_org", "空 orgId 必须是 bad_org"
    assert out["E2"] == "bad_amount", "0 金额必须是 bad_amount"
    assert out["E3"] == "bad_amount", "负数金额必须是 bad_amount"
    assert out["E4"] == "bad_amount", "非数字金额必须是 bad_amount"
    assert out["BAL"] == "100", "非法输入不应改动余额"


def test_malformed_ref_is_not_used_as_the_idempotency_key():
    out = run("""
        __reset()
        __seed('mining_co', 0)
        local ok = Treasury.Deposit('mining_co', 100, 'deposit', {
            ref = "evil'); DROP TABLE org_treasury; --",
        })
        local ref = tostring(__ledger[1] and __ledger[1].ref)
        __emit('OK', tostring(ok))
        __emit('REF', ref)
        __emit('USED_BAD_REF', tostring(ref:find('DROP', 1, true) ~= nil))
    """)
    assert out["OK"] == "true", "ref 形状不合法时应当改用服务端 ref，而不是让正常入账失败"
    assert out["USED_BAD_REF"] == "false", f"不合形状的 ref 被当成唯一键：{out['REF']}"
    assert out["REF"].startswith("sys:"), f"服务端生成的 ref 应以 sys: 开头，实际 {out['REF']}"


# ══════════════════════════════════════════════════════════════════
# 查询纪律 + 迁移契约
# ══════════════════════════════════════════════════════════════════


def test_get_ledger_uses_explicit_columns_and_limit():
    out = run("""
        __reset()
        __seed('mining_co', 0)
        Treasury.Deposit('mining_co', 100, 'deposit', { ref = 'l1' })
        Treasury.Deposit('mining_co', 200, 'deposit', { ref = 'l2' })
        Treasury.Deposit('mining_co', 300, 'deposit', { ref = 'l3' })
        local rows = Treasury.GetLedger('mining_co', 2)
        __emit('ROWS', tostring(rows and #rows or 'nil'))
        __emit('REF1', tostring(rows and rows[1] and rows[1].ref))
        __emit('SQL', tostring(__lastQuerySql))
    """)
    assert out["ROWS"] == "2", "GetLedger(limit=2) 没有按 LIMIT 截断"
    assert out["REF1"] == "l3", "流水应按新→旧返回"
    sql = out["SQL"]
    assert "LIMIT" in sql.upper(), f"列表查询必须带 LIMIT：{sql}"
    assert "SELECT *" not in sql.upper(), f"列表查询禁止 SELECT *：{sql}"
    for column in ("org_id", "delta", "balance_after", "reason", "ref", "cycle_no"):
        assert column in sql, f"GetLedger 缺少显式列 {column}：{sql}"


# ══════════════════════════════════════════════════════════════════
# 命令注册：不能依赖不存在的全局 QBCore
# ══════════════════════════════════════════════════════════════════

#: 故意**不**定义全局 QBCore。真机事故：commands.lua 直接索引全局 QBCore，
#: 资源加载成功、日志一行 SCRIPT ERROR、四条命令全空。这里只提供 qb-core
#: 的导出入口，让「惰性解析」成为唯一能通过的形状。
COMMAND_STUBS = """
Config = {
    Industry = {
        OrgWhitelist = {
            mining_co = { kind = 'job', name = 'miner' },
            cartel = { kind = 'gang', name = 'cartel' },
        },
        BossGrade = 4,
        LedgerDefaultLimit = 20,
        LedgerMaxLimit = 100,
    },
}

__registered = {}
__handlers = {}
__coreCalls = 0
local coreObject = {
    Commands = {
        Add = function(name, help, args, required, handler)
            __registered[#__registered + 1] = name
            __handlers[name] = handler
        end,
    },
    Functions = {
        GetPlayer = function() return nil end,
        HasPermission = function() return false end,
    },
}

exports = setmetatable({}, {
    __index = function(_, resource)
        if resource ~= 'qb-core' then return nil end
        return {
            GetCoreObject = function()
                __coreCalls = __coreCalls + 1
                return coreObject
            end,
        }
    end,
})

function __emit(key, value)
    io.write(tostring(key) .. '|' .. tostring(value) .. string.char(10))
end
"""


def run_commands(body: str) -> dict[str, str]:
    """stubs + db.lua + audit.lua（真加载）+ commands.lua（真加载）+ body。"""
    script = load_industry(
        COMMAND_STUBS,
        AUDIT,
        COMMANDS.read_text(encoding="utf-8") + "\n" + textwrap.dedent(body),
    )
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}\n{proc.stdout}"

    out: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        out.setdefault(key.strip(), value.strip())
    return out


#: 假 DB（fixture）+ 命令依赖（Config/exports）。两边都真加载 audit.lua / treasury.lua /
#: commands.lua，所以 grant 的整条路径（EnsureAccount → Deposit → 审计）都被覆盖。
GRANT_STUBS = FIXTURE.read_text(encoding="utf-8") + "\n" + COMMAND_STUBS


def run_grant(body: str) -> dict[str, str]:
    """fixture + db.lua + treasury.lua + audit.lua + commands.lua + body。"""
    script = load_industry(
        GRANT_STUBS,
        SRC,
        AUDIT.read_text(encoding="utf-8") + "\n"
        + COMMANDS.read_text(encoding="utf-8") + "\n"
        + textwrap.dedent(body),
    )
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}\n{proc.stdout}"

    out: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        out.setdefault(key.strip(), value.strip())
    return out


def test_ensure_account_creates_missing_row_and_keeps_existing_balance():
    """EnsureAccount：不存在则建行（余额 0），已存在则不动余额、不报错。"""
    out = run("""
        __reset()
        local ok1, err1, created1 = Treasury.EnsureAccount('mining_co')
        __emit('OK1', tostring(ok1))
        __emit('ERR1', tostring(err1 or 'nil'))
        __emit('CREATED1', tostring(created1))
        __emit('BAL1', tostring(__balance('mining_co')))
        local hasOpen = false
        for _, entry in ipairs(__sqlLog) do
            if entry:find('INSERT IGNORE INTO org_treasury', 1, true) then
                hasOpen = true
                break
            end
        end
        __emit('INSERT_IGNORE', tostring(hasOpen))

        __seed('mining_co', 500)
        local ok2, err2, created2 = Treasury.EnsureAccount('mining_co')
        __emit('OK2', tostring(ok2))
        __emit('ERR2', tostring(err2 or 'nil'))
        __emit('CREATED2', tostring(created2))
        __emit('BAL2', tostring(__balance('mining_co')))

        local ok3, err3 = Treasury.EnsureAccount('bad org!')
        __emit('OK3', tostring(ok3))
        __emit('ERR3', tostring(err3 or 'nil'))
    """)

    assert out["OK1"] == "true", f"开户失败：{out}"
    assert out["ERR1"] == "nil"
    assert out["CREATED1"] == "true", "首次开户必须报告 created=true（fund.open 审计依赖它）"
    assert out["BAL1"] == "0", "新账户余额必须是 0"
    assert out["INSERT_IGNORE"] == "true", "必须走 INSERT IGNORE（Db.Insert），不能先读后写建行"
    assert out["OK2"] == "true", "已存在的账户上再 Ensure 不应报错"
    assert out["CREATED2"] == "false", "已存在的账户被误报成新建 → 会重复写 fund.open"
    assert out["BAL2"] == "500", "EnsureAccount 不许重置已有余额"
    assert out["OK3"] == "false" and out["ERR3"] == "bad_org", f"非法 orgId 必须 bad_org：{out}"


def test_orgfundgrant_opens_account_before_first_deposit():
    """真机缺口：控制台 grant 到不存在的组织必须先开户，否则永远 no_account。

    SQL 序列断言「INSERT IGNORE org_treasury 在第一条 UPDATE 之前」；审计断言
    fund.open 只在首次建行时写一次。
    """
    out = run_grant("""
        __reset()
        IndustryCommands.Register()
        __handlers.orgfundgrant(0, { 'cartel', '1000', 'smoke_seed' })
        __emit('BAL1', tostring(__balance('cartel')))
        __emit('LEDGER1', tostring(__ledgerCount()))

        local actions = {}
        for _, entry in ipairs(__audits) do
            actions[#actions + 1] = entry.action
        end
        __emit('ACTIONS1', table.concat(actions, ','))

        local openAt, updateAt
        for index, entry in ipairs(__sqlLog) do
            if entry:find('INSERT IGNORE INTO org_treasury', 1, true) and not openAt then
                openAt = index
            end
            if entry:find('UPDATE org_treasury', 1, true) and not updateAt then
                updateAt = index
            end
        end
        __emit('OPEN_BEFORE_UPDATE', tostring(openAt ~= nil and updateAt ~= nil and openAt < updateAt))

        __handlers.orgfundgrant(0, { 'cartel', '500', 'second' })
        __emit('BAL2', tostring(__balance('cartel')))
        __emit('LEDGER2', tostring(__ledgerCount()))
        local openAudits = 0
        for _, entry in ipairs(__audits) do
            if entry.action == 'fund.open' then openAudits = openAudits + 1 end
        end
        __emit('OPEN_AUDITS', tostring(openAudits))
    """)

    assert out["BAL1"] == "1000", (
        f"grant 到不存在的组织没有开户/入账（真机表现：no_account）：{out}"
    )
    assert out["LEDGER1"] == "1", "grant 应写一条流水"
    assert out["ACTIONS1"] == "fund.open,fund.grant", (
        f"首次 grant 必须先记 fund.open 再记 fund.grant：{out['ACTIONS1']}"
    )
    assert out["OPEN_BEFORE_UPDATE"] == "true", (
        "开户 SQL 必须发生在第一笔余额更新之前，否则 Deposit 一定 no_account"
    )
    assert out["BAL2"] == "1500", "第二次 grant 应继续累加"
    assert out["LEDGER2"] == "2"
    assert out["OPEN_AUDITS"] == "1", "fund.open 只在首次建行时写，第二次 grant 不该重复"


def test_commands_register_without_a_global_qbcore():
    """真机 P0：资源里没有全局 QBCore，Register() 必须靠 exports['qb-core'] 解析。

    这条用例故意不提供全局 QBCore（stub 里只有 exports 入口）。如果 commands.lua
    退回直接索引全局 QBCore，Register() 会在第一条 Commands.Add 抛 nil，Lua 进程
    非零退出，用例红 —— 而不是"命令表为空"这种更容易被忽略的形状。
    """
    out = run_commands("""
        IndustryCommands.Register()
        __emit('COUNT', tostring(#__registered))
        __emit('NAMES', table.concat(__registered, ','))
        __emit('CORE_CALLS', tostring(__coreCalls))
        __emit('HAS_GLOBAL', tostring(rawget(_G, 'QBCore') ~= nil))
    """)

    expected = ["orgfund", "orgfunddeposit", "orgfundwithdraw", "orgfundgrant"]
    assert out["COUNT"] == "4", (
        f"命令没有全部注册（生产表现：资源 Started，但 /orgfund* 全部为空）：{out}"
    )
    assert sorted(out["NAMES"].split(",")) == sorted(expected), (
        f"注册的命令名不对：{out['NAMES']}"
    )
    assert out["CORE_CALLS"] == "1", (
        "GetCoreObject 应惰性解析一次并缓存；重复解析会在启动路径上制造额外导出调用"
    )
    assert out["HAS_GLOBAL"] == "false", (
        "用例自己定义了全局 QBCore —— 这样生产环境缺它的 bug 会被永远掩盖"
    )


def test_migration_and_fixture_declare_tables_and_idempotency_key():
    """迁移删掉 UNIQUE KEY 时，这条与幂等用例都应红（见 test_duplicate_ref...）。"""
    migration = _migration_sql()
    fixture = _strip_sql_comments(SCHEMA_FIXTURE.read_text(encoding="utf-8"))

    for table in TABLES:
        pattern = rf"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+`{table}`"
        assert re.search(pattern, migration, re.I), f"迁移里没有建 {table}"
        assert re.search(pattern, fixture, re.I), f"测试 fixture 里没有建 {table}"

    assert UNIQUE_KEY.search(migration), (
        "迁移缺少 UNIQUE(org_id, ref) —— 幂等就会退化成调用方自觉"
    )
    assert UNIQUE_KEY.search(fixture), "测试 fixture 与迁移不一致：缺少 uniq_org_ref"
