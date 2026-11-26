"""S2 设施 / 工位：真跑 Lua，桩只替换 MySQL。

这里钉：

1. **成本曲线** `floor(base × 1.35^(n-1))`（第 1/2/3 个工位）。
2. **上限**：`workstations < ?` 必须在 UPDATE 的 WHERE 里；到上限不扣钱、不加行。
3. **钱与设施成对**：先扣钱、再改行；改行失败/冲突必须退回。
4. **CAS 冲突**：预读后被别人改了工位 → `conflict`，余额回到原值。
5. **接线**：加载 fxmanifest 里的全部 server 脚本（不提供全局 QBCore），
   断言 S1 四个 + S2 三个命令都注册了 —— S1 真机 P0 的教训。

跑法：``uv run --with pytest python -m pytest tests/unit/layer3_business/test_industry_facility.py -q``
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
TREASURY_SRC = RES / "server" / "treasury.lua"
AUDIT_SRC = RES / "server" / "audit.lua"
FACILITY_SRC = RES / "server" / "facility.lua"
CONFIG_SRC = RES / "config.lua"
FACILITY_CONFIG_SRC = RES / "config" / "facility.lua"
MANIFEST = RES / "fxmanifest.lua"
TREASURY_FIXTURE = Path(__file__).resolve().parent / "fixtures" / "industry_treasury_probe.lua"
FACILITY_FIXTURE = Path(__file__).resolve().parent / "fixtures" / "industry_facility_probe.lua"
MIGRATION = BASE / "migrations" / "v4.1_industry_facility.sql"
SCHEMA_FIXTURE = BASE / "tests" / "fixtures" / "tcity_schema.sql"

STUBS = (
    TREASURY_FIXTURE.read_text(encoding="utf-8")
    + "\n"
    + FACILITY_FIXTURE.read_text(encoding="utf-8")
    + "\nfunction GetConvar(_, default) return default end\n"
)


def lua() -> str:
    exe = shutil.which("lua5.4") or shutil.which("lua")
    if not exe:
        pytest.skip("lua5.4 不可用")
    return exe


def parse(out_text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in out_text.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        out.setdefault(key.strip(), value.strip())
    return out


def run(body: str) -> dict[str, str]:
    """stubs + db.lua + treasury.lua + config/audit/facility + body。"""
    script = load_industry(
        STUBS,
        TREASURY_SRC,
        CONFIG_SRC.read_text(encoding="utf-8")
        + "\n"
        + FACILITY_CONFIG_SRC.read_text(encoding="utf-8")
        + "\n"
        + AUDIT_SRC.read_text(encoding="utf-8")
        + "\n"
        + FACILITY_SRC.read_text(encoding="utf-8")
        + "\n"
        + textwrap.dedent(body),
    )
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}\n{proc.stdout}"
    return parse(proc.stdout)


# ══════════════════════════════════════════════════════════════════
# Q2 配置
# ══════════════════════════════════════════════════════════════════


def test_mine_facility_and_recipe_config():
    out = run("""
        local mine = Config.Industry.Facilities.mine
        local recipe = mine.recipes[1]
        __emit('BASE', tostring(mine.baseCost))
        __emit('CAP', tostring(mine.workstationCap))
        __emit('MAXLEVEL', tostring(mine.maxLevel))
        __emit('RECIPES', tostring(#mine.recipes))
        __emit('RECIPE_ID', tostring(recipe.id))
        __emit('INPUT', tostring(recipe.inputs[1].name) .. ':' .. tostring(recipe.inputs[1].count))
        __emit('OUTPUT', tostring(recipe.output.name) .. ':' .. tostring(recipe.output.count))
        __emit('DURATION', tostring(recipe.duration))
    """)
    assert out["BASE"] == "50000"
    assert out["CAP"] == "10"
    assert out["MAXLEVEL"] == "5"
    assert out["RECIPES"] == "1"
    assert out["RECIPE_ID"] == "iron_smelt"
    assert out["INPUT"] == "iron_ore:3", f"配方输入不对：{out['INPUT']}"
    assert out["OUTPUT"] == "iron_ingot:1", f"配方输出不对：{out['OUTPUT']}"
    assert out["DURATION"] == "60"


# ══════════════════════════════════════════════════════════════════
# Q3 成本曲线
# ══════════════════════════════════════════════════════════════════


def test_workstation_cost_curve_is_exponential():
    """第 1/2/3 个工位：base / floor(base×1.35) / floor(base×1.35²)。"""
    out = run("""
        __reset()
        __seed('mining_co', 1000000)

        local ok0, _, buildCost = Facility.Build('mining_co', 'mine', { actor = 'cid1', ref = 'b1' })
        local ok1, e1, c1 = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h1' })
        local ok2, e2, c2 = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h2' })
        local ok3, e3, c3 = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h3' })

        __emit('OKS', table.concat({
            tostring(ok0), tostring(ok1), tostring(ok2), tostring(ok3),
        }, ','))
        __emit('ERRORS', table.concat({
            tostring(e1 or 'nil'), tostring(e2 or 'nil'), tostring(e3 or 'nil'),
        }, ','))
        __emit('BUILD_COST', tostring(buildCost))
        __emit('COSTS', table.concat({ tostring(c1), tostring(c2), tostring(c3) }, ','))
        __emit('HELPER', table.concat({
            tostring(Facility.WorkstationCost('mine', 0)),
            tostring(Facility.WorkstationCost('mine', 1)),
            tostring(Facility.WorkstationCost('mine', 2)),
        }, ','))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('WS', tostring(__facility('mining_co').workstations))
    """)
    assert out["OKS"] == "true,true,true,true", f"建造/雇工位失败：{out}"
    assert out["ERRORS"] == "nil,nil,nil"
    assert out["BUILD_COST"] == "50000", "建设施固定扣 baseCost"
    assert out["COSTS"] == "50000,67500,91125", (
        f"工位成本不是 floor(base×1.35^(n-1))：{out['COSTS']}"
    )
    assert out["HELPER"] == "50000,67500,91125", (
        f"WorkstationCost 的曲线不对：{out['HELPER']}"
    )
    assert out["BAL"] == "741375", f"余额扣减与成本曲线不一致：{out['BAL']}"
    assert out["WS"] == "3"


# ══════════════════════════════════════════════════════════════════
# Q3 上限 / 并发
# ══════════════════════════════════════════════════════════════════


def test_cap_reached_does_not_charge_or_add():
    """到上限返回 cap_reached：余额与流水都不动，工位数不变。

    同时断言实际执行的 UPDATE 带 `workstations < ?` —— 顺序执行时预读上限
    已经先拦住，但守卫仍必须留在 SQL 里（注入删掉它时这条断言必须红）。
    """
    out = run("""
        __reset()
        -- 余额足够覆盖到上限时的成本，注入「先扣钱后判上限」时才能真的扣到钱。
        __seed('mining_co', 100000000)
        __facilitySeed('mining_co', { workstations = 9 })

        local ok1, e1 = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h9' })
        local sql = tostring(__lastFacilityUpdateSql)
        local balanceBefore = __balance('mining_co')
        local ledgerBefore = __ledgerCount()

        local ok2, e2 = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h10' })

        __emit('OK1', tostring(ok1))
        __emit('ERR1', tostring(e1 or 'nil'))
        __emit('WS1', tostring(__facility('mining_co').workstations))
        __emit('SQL', sql)
        __emit('OK2', tostring(ok2))
        __emit('ERR2', tostring(e2 or 'nil'))
        __emit('WS2', tostring(__facility('mining_co').workstations))
        __emit('BAL_DELTA', tostring(__balance('mining_co') - balanceBefore))
        __emit('LEDGER_DELTA', tostring(__ledgerCount() - ledgerBefore))
    """)
    assert out["OK1"] == "true" and out["WS1"] == "10", f"第 10 个工位应成功：{out}"
    assert "workstations < ?" in out["SQL"], (
        "上限守卫必须写在 UPDATE 的 WHERE 里；删掉它顺序执行也可能被预读掩盖："
        f"{out['SQL']}"
    )
    assert out["OK2"] == "false", "到上限后还能继续雇"
    assert out["ERR2"] == "cap_reached", f"上限错误码不对：{out['ERR2']}"
    assert out["WS2"] == "10", "cap_reached 仍改动了工位数"
    assert out["BAL_DELTA"] == "0", "cap_reached 扣了钱"
    assert out["LEDGER_DELTA"] == "0", "cap_reached 产生了资金流水（应先判上限再扣钱）"


def test_cas_conflict_refunds_and_keeps_the_concurrent_value():
    """预读 0 后别人把工位改成 1：CAS 失败 → conflict，余额回到原值。"""
    out = run("""
        __reset()
        __seed('mining_co', 1000000)
        __facilitySeed('mining_co', { workstations = 0 })

        __facilityRace = function()
            __facilities['mining_co'].workstations = 1
        end

        local ok, err = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h1' })

        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('WS', tostring(__facility('mining_co').workstations))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEDGER', tostring(__ledgerCount()))
        local deltas = {}
        for _, row in ipairs(__ledger) do deltas[#deltas + 1] = tostring(row.delta) end
        __emit('DELTAS', table.concat(deltas, ','))
        local last = __audits[#__audits]
        __emit('AUDIT_RESULT', last and last.payload:match('"result":"([^"]+)"') or 'nil')
    """)
    assert out["OK"] == "false", "CAS 冲突时必须失败"
    assert out["ERR"] == "conflict", f"错误码必须是 conflict，实际 {out['ERR']}"
    assert out["WS"] == "1", "冲突后不能覆盖别人写入的工位数"
    assert out["BAL"] == "1000000", "冲突后扣款没有退回"
    assert out["LEDGER"] == "2", "应先扣款再补偿（两条流水）"
    assert out["DELTAS"] == "-50000,50000", f"补偿流水不对：{out['DELTAS']}"
    assert out["AUDIT_RESULT"] == "conflict"


# ══════════════════════════════════════════════════════════════════
# Q3 余额不足 / Build 幂等 / 回滚
# ══════════════════════════════════════════════════════════════════


def test_insufficient_funds_leaves_no_facility_and_no_charge():
    out = run("""
        __reset()
        __seed('mining_co', 49999)

        local ok1, e1 = Facility.Build('mining_co', 'mine', { actor = 'cid1', ref = 'b1' })
        __emit('BUILD_OK', tostring(ok1))
        __emit('BUILD_ERR', tostring(e1 or 'nil'))
        __emit('FACILITIES', tostring(__facilityCount()))
        __emit('BAL1', tostring(__balance('mining_co')))
        __emit('LEDGER1', tostring(__ledgerCount()))

        __facilitySeed('mining_co', { workstations = 0 })
        local ok2, e2 = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h1' })
        __emit('HIRE_OK', tostring(ok2))
        __emit('HIRE_ERR', tostring(e2 or 'nil'))
        __emit('WS', tostring(__facility('mining_co').workstations))
        __emit('BAL2', tostring(__balance('mining_co')))
        __emit('LEDGER2', tostring(__ledgerCount()))
    """)
    assert out["BUILD_OK"] == "false" and out["BUILD_ERR"] == "insufficient_funds", (
        f"余额不足应返回 insufficient_funds：{out}"
    )
    assert out["FACILITIES"] == "0", "余额不足时仍建了设施行"
    assert out["BAL1"] == "49999" and out["LEDGER1"] == "0", "余额不足时动了钱"
    assert out["HIRE_OK"] == "false" and out["HIRE_ERR"] == "insufficient_funds"
    assert out["WS"] == "0" and out["BAL2"] == "49999" and out["LEDGER2"] == "0"


def test_build_is_idempotent_and_audits_both_attempts():
    out = run("""
        __reset()
        __seed('mining_co', 1000000)

        local ok1 = Facility.Build('mining_co', 'mine', { actor = 'cid1', ref = 'b1' })
        local balanceAfterFirst = __balance('mining_co')
        local ok2, e2 = Facility.Build('mining_co', 'mine', { actor = 'cid1', ref = 'b2' })

        __emit('OK1', tostring(ok1))
        __emit('OK2', tostring(ok2))
        __emit('ERR2', tostring(e2 or 'nil'))
        __emit('FACILITIES', tostring(__facilityCount()))
        __emit('BAL_UNCHANGED', tostring(__balance('mining_co') == balanceAfterFirst))

        local results = {}
        for _, entry in ipairs(__audits) do
            if entry.action == 'facility.build' then
                results[#results + 1] = entry.payload:match('"result":"([^"]+)"') or '?'
            end
        end
        __emit('RESULTS', table.concat(results, ','))
    """)
    assert out["OK1"] == "true", "第一次建设施失败"
    assert out["OK2"] == "false" and out["ERR2"] == "already_built", (
        f"重复建设施应返回 already_built：{out}"
    )
    assert out["FACILITIES"] == "1", "一组织一设施：不能产生第二行"
    assert out["BAL_UNCHANGED"] == "true", "重复建设施又扣了一次钱"
    assert out["RESULTS"] == "ok,already_built", (
        f"成功与失败都必须写审计：{out['RESULTS']}"
    )


def test_build_rolls_the_payment_back_when_the_insert_fails():
    out = run("""
        __reset()
        __seed('mining_co', 1000000)
        __failFacilityInsert = true

        local ok, err = Facility.Build('mining_co', 'mine', { actor = 'cid1', ref = 'b1' })

        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('FACILITIES', tostring(__facilityCount()))
        __emit('LEDGER', tostring(__ledgerCount()))
        local deltas = {}
        for _, row in ipairs(__ledger) do deltas[#deltas + 1] = tostring(row.delta) end
        __emit('DELTAS', table.concat(deltas, ','))
        local last = __audits[#__audits]
        __emit('AUDIT_RESULT', last and last.payload:match('"result":"([^"]+)"') or 'nil')
    """)
    assert out["OK"] == "false" and out["ERR"] == "db_error", (
        f"设施行写失败应返回 db_error：{out}"
    )
    assert out["BAL"] == "1000000", "设施行写失败后钱没有退回（钱少了、设施没建）"
    assert out["FACILITIES"] == "0"
    assert out["LEDGER"] == "2" and out["DELTAS"] == "-50000,50000", (
        f"回滚流水不对：{out['DELTAS']}"
    )
    assert out["AUDIT_RESULT"] == "db_error"


# ══════════════════════════════════════════════════════════════════
# Q1 迁移 / fixture
# ══════════════════════════════════════════════════════════════════


def test_migration_and_fixture_declare_industry_facility():
    for label, path in (("迁移", MIGRATION), ("fixture", SCHEMA_FIXTURE)):
        text = path.read_text(encoding="utf-8")
        assert re.search(r"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+`industry_facility`", text, re.I), (
            f"{label}里没有建 industry_facility：{path}"
        )
        assert "PRIMARY KEY (`org_id`)" in text, f"{label}缺少 org_id 主键"
        assert "idx_facility_type" in text, f"{label}缺少 idx_facility_type"


# ══════════════════════════════════════════════════════════════════
# Q5 接线：加载 fxmanifest 的全部 server 脚本，不提供全局 QBCore
# ══════════════════════════════════════════════════════════════════

WIRING_STUBS = """
GetConvar = function(name, default)
    if name == 'industry_enable' then return 'true' end
    return default
end

__registered = {}
local coreObject = {
    Commands = {
        Add = function(name) __registered[#__registered + 1] = name end,
    },
    Functions = {
        GetPlayer = function() return nil end,
        HasPermission = function() return false end,
        CreateCallback = function() end,
    },
}

-- 故意不定义全局 QBCore：两个命令文件都必须走 exports['qb-core']。
-- __call 也必须支持：S5 的 ui.lua 在加载期注册只读导出。
exports = setmetatable({}, {
    __index = function(_, resource)
        if resource ~= 'qb-core' then return nil end
        return { GetCoreObject = function() return coreObject end }
    end,
    __call = function() end,
})

MySQL = {}

-- S3 起 main.lua 会启动生产心跳并挂 PlayerLoaded；这里只要求「能加载」，
-- 不执行线程体（否则 while true 会卡住 Lua）。
AddEventHandler = function() end
CreateThread = function() end
Wait = function() end

function __emit(key, value)
    io.write(tostring(key) .. '|' .. tostring(value) .. string.char(10))
end
"""


def server_script_files() -> list[Path]:
    """按 fxmanifest 的 server_scripts 顺序返回本资源的本地脚本。"""
    text = MANIFEST.read_text(encoding="utf-8")
    match = re.search(r"server_scripts\s*\{(.*?)\}", text, re.S)
    assert match, "fxmanifest 里找不到 server_scripts 块"
    entries = re.findall(r"['\"]([^'\"]+)['\"]", match.group(1))
    files = [RES / entry for entry in entries if not entry.startswith("@")]
    assert files, "server_scripts 里没有任何本地文件"
    for path in files:
        assert path.is_file(), f"manifest 列出的文件不存在：{path}"
    return files


def test_all_server_scripts_register_all_commands_without_global_qbcore():
    """S1 真机教训：只加载单个文件看不见跨脚本作用域；这里按 manifest 全加载。"""
    files = server_script_files()
    first, rest = files[0], files[1:]
    body = "\n".join(path.read_text(encoding="utf-8") for path in rest) + "\n" + """
        __emit('COUNT', tostring(#__registered))
        __emit('NAMES', table.concat(__registered, ','))
        __emit('HAS_GLOBAL', tostring(rawget(_G, 'QBCore') ~= nil))
    """
    script = load_industry(WIRING_STUBS, first, body)
    proc = subprocess.run([lua(), "-"], input=script, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}\n{proc.stdout}"
    out = parse(proc.stdout)

    expected = {
        "orgfund", "orgfunddeposit", "orgfundwithdraw", "orgfundgrant",
        "orgbuild", "orghire", "orgfacility",
    }
    assert out["COUNT"] == "7", f"命令没有全部注册（生产表现：资源 Started、命令为空）：{out}"
    assert sorted(out["NAMES"].split(",")) == sorted(expected), (
        f"注册的命令名不对：{out['NAMES']}"
    )
    assert out["HAS_GLOBAL"] == "false", (
        "用例自己定义了全局 QBCore —— 生产环境缺它的 bug 会被永远掩盖"
    )
