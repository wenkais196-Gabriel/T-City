"""tests/unit/layer3_business/industry_harness.py — S1–S8 产业测试共用的离线 Lua harness。

每个 `test_industry_*.py` 只保留「选一条装配链 + 写断言」；路径常量、`lua5.4`
查找、`KEY|VALUE` 解析、fxmanifest 全加载接线、假 DB 探针的拼装都集中在这里。

为什么单独一个模块：这些装配代码原本在每个测试文件里各抄一遍（`run()` 的
模块链、`parse()`、`config_text()`、`WIRING_STUBS`、`server_script_files()`），
SonarCloud 把 PR #373 的新代码重复率算到 20.8%（issue #377）。

边界：helper 只负责**把 Lua 跑起来并回读输出**。断言必须留在各用例里——每条
规则仍要能单独变红，失败信息指向具体断言，而不是某个 helper。反向注入靶子
（周期守卫 / 配额截断 / 结算水位）也因此不受影响。

装配顺序按 fxmanifest（server_scripts）和既有用例的实际加载顺序照搬，没有
重新排序；探针共用的纯构造器在 `fixtures/industry_probe_common.lua`，由本模块
在探针前注入（**不要**直接 read_text 探针后拼脚本，否则公共构造器缺失）。

S8 的 `test_industry_prestige.py` 只需把本地的 `run()` 换成
`from industry_harness import run_full as run`：body / convars 签名一致，
完整模块链（含 settlement / commands_cycle）由 `FULL_MODULES` 提供。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

from lua_probe import BASE, DB_ADAPTER, parse_output

#: 产业资源根
RES = BASE / "resources" / "[custom]" / "custom-industry"
RESOURCES = BASE / "resources"

# ── 资源源码（路径只在这里写一次）──────────────────────────────────
CONFIG_SRC = RES / "config.lua"
FACILITY_CONFIG_SRC = RES / "config" / "facility.lua"
PRODUCTION_CONFIG_SRC = RES / "config" / "production.lua"
SALES_CONFIG_SRC = RES / "config" / "sales.lua"
CYCLE_CONFIG_SRC = RES / "config" / "cycle.lua"

ORG_ID_SRC = RES / "server" / "org_id.lua"
TREASURY_SRC = RES / "server" / "treasury.lua"
AUDIT_SRC = RES / "server" / "audit.lua"
ACCESS_SRC = RES / "server" / "access.lua"
ANNOUNCE_SRC = RES / "server" / "announce.lua"
CYCLE_SRC = RES / "server" / "cycle.lua"
SETTLEMENT_SRC = RES / "server" / "settlement.lua"
FACILITY_SRC = RES / "server" / "facility.lua"
PRODUCTION_SRC = RES / "server" / "production.lua"
SALE_SRC = RES / "server" / "sale.lua"
UI_SRC = RES / "server" / "ui.lua"
COMMANDS_SRC = RES / "server" / "commands.lua"
COMMANDS_SALES_SRC = RES / "server" / "commands_sales.lua"
COMMANDS_PRODUCTION_SRC = RES / "server" / "commands_production.lua"
COMMANDS_CYCLE_SRC = RES / "server" / "commands_cycle.lua"
MANIFEST = RES / "fxmanifest.lua"

# ── 其他被测资源 / 迁移 / fixture ──────────────────────────────────
DASHBOARD = BASE / "resources" / "[system]" / "economy-dashboard" / "server" / "main.lua"
PHONE = BASE / "resources" / "[custom]" / "custom-phone"
PHONE_REGISTRY = PHONE / "server" / "phone_apps.lua"
PHONE_APP = PHONE / "server" / "apps" / "industry.lua"
PHONE_MANIFEST = PHONE / "fxmanifest.lua"

MIGRATION_TREASURY = BASE / "migrations" / "v4.0_industry_treasury.sql"
MIGRATION_FACILITY = BASE / "migrations" / "v4.1_industry_facility.sql"
MIGRATION_SALES = BASE / "migrations" / "v4.3_industry_sales.sql"
MIGRATION_CYCLE = BASE / "migrations" / "v4.4_industry_cycle.sql"
SCHEMA_FIXTURE = BASE / "tests" / "fixtures" / "tcity_schema.sql"
TABLE_OWNERS = BASE / "tests" / "architecture" / "table_owners.json"

FIXTURES = Path(__file__).resolve().parent / "fixtures"
PROBE_COMMON = FIXTURES / "industry_probe_common.lua"
SALES_PROBE = FIXTURES / "industry_sales_probe.lua"
UI_PROBE = FIXTURES / "industry_ui_probe.lua"
CYCLE_PROBE = FIXTURES / "industry_cycle_probe.lua"
TREASURY_PROBE = FIXTURES / "industry_treasury_probe.lua"
FACILITY_PROBE = FIXTURES / "industry_facility_probe.lua"
PRODUCTION_PROBE = FIXTURES / "industry_production_probe.lua"

#: 断言里反复出现的协议字面量（Sonar 的重复字面量规则会盯 "true" / "nil"）。
TRUE = "true"
FALSE = "false"
NIL = "nil"

# ── 装配链（顺序 = 既有用例的实际加载顺序）─────────────────────────
CONFIG_MODULES = (
    CONFIG_SRC,
    FACILITY_CONFIG_SRC,
    PRODUCTION_CONFIG_SRC,
    SALES_CONFIG_SRC,
    CYCLE_CONFIG_SRC,
)

#: S4：配置 → org_id → cycle → treasury → audit → access → sale
SALES_MODULES = CONFIG_MODULES + (
    ORG_ID_SRC,
    CYCLE_SRC,
    TREASURY_SRC,
    AUDIT_SRC,
    ACCESS_SRC,
    SALE_SRC,
)

#: S6/S7/S8：配置 → org_id → treasury → audit → access → announce → cycle
#: → settlement → facility → production → sale → commands_cycle
FULL_MODULES = CONFIG_MODULES + (
    ORG_ID_SRC,
    TREASURY_SRC,
    AUDIT_SRC,
    ACCESS_SRC,
    ANNOUNCE_SRC,
    CYCLE_SRC,
    SETTLEMENT_SRC,
    FACILITY_SRC,
    PRODUCTION_SRC,
    SALE_SRC,
    COMMANDS_CYCLE_SRC,
)

#: S5：配置 → org_id → cycle → treasury → audit → access → facility → sale → ui
UI_MODULES = CONFIG_MODULES + (
    ORG_ID_SRC,
    CYCLE_SRC,
    TREASURY_SRC,
    AUDIT_SRC,
    ACCESS_SRC,
    FACILITY_SRC,
    SALE_SRC,
    UI_SRC,
)

#: S2：org_id/cycle 先于配置与 treasury（沿用 load_industry 的顺序）
FACILITY_MODULES = (
    ORG_ID_SRC,
    CYCLE_SRC,
    TREASURY_SRC,
    CONFIG_SRC,
    FACILITY_CONFIG_SRC,
    CYCLE_CONFIG_SRC,
    AUDIT_SRC,
    FACILITY_SRC,
)

#: S3：配置子集按生产测试原有顺序
PRODUCTION_MODULES = (
    ORG_ID_SRC,
    CYCLE_SRC,
    PRODUCTION_SRC,
    CONFIG_SRC,
    PRODUCTION_CONFIG_SRC,
    FACILITY_CONFIG_SRC,
    CYCLE_CONFIG_SRC,
)

#: S1：org_id/cycle → treasury → body
TREASURY_MODULES = (ORG_ID_SRC, CYCLE_SRC, TREASURY_SRC)
COMMAND_MODULES = (ORG_ID_SRC, CYCLE_SRC, AUDIT_SRC, COMMANDS_SRC)
GRANT_MODULES = (ORG_ID_SRC, CYCLE_SRC, TREASURY_SRC, AUDIT_SRC, COMMANDS_SRC)

#: S5 的玩家表：job / gang 各一个 Boss，source=2 是「无组织」对照。
UI_PLAYERS = """
local function boss()
    return { PlayerData = {
        citizenid = 'cid-boss',
        job = { name = 'miner', label = '洛圣都矿业公司',
                grade = { level = 4, name = 'Mine Owner' } },
    } }
end
local function member()
    return { PlayerData = {
        citizenid = 'cid-member',
        job = { name = 'miner', label = '洛圣都矿业公司',
                grade = { level = 1, name = '矿工' } },
    } }
end
local function outsider()
    return { PlayerData = {
        citizenid = 'cid-out',
        job = { name = 'police', label = '警察',
                grade = { level = 4, name = 'Chief' } },
    } }
end
local function gangBoss()
    return { PlayerData = {
        citizenid = 'cid-gang',
        gang = { name = 'cartel', label = '卡特尔',
                 grade = { level = 4, name = 'Boss' } },
    } }
end
"""

#: S3 纯函数用例的最小桩：只替掉 convar 与输出。
PRODUCTION_STUBS = """
function GetConvar(_, default) return default end

function __emit(key, value)
    io.write(tostring(key) .. '|' .. tostring(value) .. string.char(10))
end
"""

#: S1 命令注册桩：故意**不**定义全局 QBCore。真机事故：commands.lua 直接索引
#: 全局 QBCore，资源加载成功、日志一行 SCRIPT ERROR、四条命令全空。
#: 这里只提供 qb-core 的导出入口，让「惰性解析」成为唯一能通过的形状。
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

#: fxmanifest 全加载接线桩：命令表 / 回调 / 导出 / 事件 / 线程分桶计数。
#: `__wiringConvars` 由 run_wiring 在桩前注入（不同文件的调试 convar 不同）。
WIRING_STUBS = """
GetConvar = function(name, default)
    local value = __wiringConvars[name]
    if value == nil then return default end
    return value
end

__registered = {}
__native = {}
__callbacks = {}
__exportNames = {}
__events = 0
__threads = 0
local coreObject = {
    Commands = {
        Add = function(name) __registered[#__registered + 1] = name end,
    },
    Functions = {
        GetPlayer = function() return nil end,
        HasPermission = function() return false end,
        CreateCallback = function(name) __callbacks[#__callbacks + 1] = name end,
    },
}

-- 故意不定义全局 QBCore：所有命令文件都必须走 exports['qb-core']。
-- __call 也必须支持：S5 的 ui.lua 在加载期注册只读导出。
exports = setmetatable({}, {
    __index = function(_, resource)
        if resource ~= 'qb-core' then return nil end
        return { GetCoreObject = function() return coreObject end }
    end,
    __call = function(_, name)
        __exportNames[#__exportNames + 1] = name
    end,
})

MySQL = {}

AddEventHandler = function() __events = __events + 1 end
CreateThread = function() __threads = __threads + 1 end
Wait = function() end
RegisterCommand = function(name, _, restricted)
    __native[#__native + 1] = name .. ':' .. tostring(restricted)
end

function __emit(key, value)
    io.write(tostring(key) .. '|' .. tostring(value) .. string.char(10))
end
"""

_WIRING_EMIT = """
__emit('COUNT', tostring(#__registered))
__emit('QBCORE_COUNT', tostring(#__registered))
__emit('NAMES', table.concat(__registered, ','))
__emit('QBCORE_NAMES', table.concat(__registered, ','))
__emit('CALLBACKS', table.concat(__callbacks, ','))
__emit('EXPORTS', table.concat(__exportNames, ','))
__emit('NATIVE', table.concat(__native, ','))
__emit('EVENTS', tostring(__events))
__emit('THREADS', tostring(__threads))
__emit('HAS_GLOBAL', tostring(rawget(_G, 'QBCore') ~= nil))
"""

#: 金库迁移的幂等键：删掉它，幂等用例必须真的变红（探针开关由这个事实驱动）。
UNIQUE_REF_KEY = re.compile(
    r"UNIQUE\s+KEY\s+`uniq_org_ref`\s*\(\s*`org_id`\s*,\s*`ref`\s*\)", re.I
)


def lua() -> str:
    """返回可执行的 Lua 解释器；缺失时跳过（CI 的 ubuntu 镜像带 lua5.4）。"""
    for name in ("lua5.4", "lua"):
        exe = shutil.which(name)
        if exe:
            return exe
    pytest.skip("lua5.4 不可用")


def read_text(*paths: Path) -> str:
    return "\n".join(path.read_text(encoding="utf-8") for path in paths)


def lua_table(values: dict[str, str] | None) -> str:
    return "{ " + ", ".join(f"{key} = '{value}'" for key, value in (values or {}).items()) + " }"


def run_script(script: str) -> dict[str, str]:
    """跑一段拼好的 Lua 并解析 `KEY|VALUE` 输出。"""
    proc = subprocess.run(
        [lua(), "-"], input=script, capture_output=True, text=True, timeout=60
    )
    assert proc.returncode == 0, f"Lua 执行失败:\n{proc.stderr}\n{proc.stdout}"
    return parse_output(proc.stdout)


def strip_sql_comments(sql: str) -> str:
    return re.sub(r"--[^\n]*", "", re.sub(r"/\*.*?\*/", "", sql, flags=re.S))


def unique_ref_declared() -> bool:
    """幂等键是否真的写在迁移里 —— 金库探针的唯一性开关由这个事实驱动。"""
    sql = strip_sql_comments(MIGRATION_TREASURY.read_text(encoding="utf-8"))
    return UNIQUE_REF_KEY.search(sql) is not None


def _run(
    body: str,
    *,
    stubs: str,
    modules: tuple[Path, ...] = (),
    convars: dict[str, str] | None = None,
    default_convars: dict[str, str] | None = None,
    suffix: str = "",
    prefix: str = "",
) -> dict[str, str]:
    """fixture/stubs → db.lua → 可选 convar → 模块链 → suffix → body。"""
    prelude = ""
    if convars is not None or default_convars is not None:
        values = convars if convars is not None else default_convars
        prelude = f"__convars = {lua_table(values)}\n"
    chunks = [stubs, DB_ADAPTER.read_text(encoding="utf-8"), prelude]
    chunks.extend(path.read_text(encoding="utf-8") for path in modules)
    if suffix:
        chunks.append(suffix)
    chunks.append(prefix + textwrap.dedent(body))
    return run_script("\n".join(chunks))


def run_sales(body: str, convars: dict[str, str] | None = None) -> dict[str, str]:
    """S4：销售 / 配额（industry_sales_probe.lua）。"""
    return _run(
        body,
        stubs=read_text(PROBE_COMMON, SALES_PROBE),
        modules=SALES_MODULES,
        convars=convars,
    )


def run_full(body: str, convars: dict[str, str] | None = None) -> dict[str, str]:
    """S6/S7/S8：周期 / 结算 / 转生的完整模块链（industry_cycle_probe.lua）。"""
    return _run(
        body,
        stubs=read_text(PROBE_COMMON, CYCLE_PROBE),
        modules=FULL_MODULES,
        convars=convars,
    )


def run_ui(body: str, convars: dict[str, str] | None = None) -> dict[str, str]:
    """S5：快照 / 玩家入口（S4 假 DB + UI 扩展探针）。"""
    return _run(
        body,
        stubs=read_text(PROBE_COMMON, SALES_PROBE, UI_PROBE),
        modules=UI_MODULES,
        convars=convars,
        default_convars={"industry_enable": "true"},
        suffix=UI_PLAYERS,
    )


def run_facility(body: str) -> dict[str, str]:
    """S2：设施 / 工位（金库假 DB + facility 扩展探针）。"""
    stubs = read_text(PROBE_COMMON, TREASURY_PROBE, FACILITY_PROBE) + "\n"
    stubs += "function GetConvar(_, default) return default end\n"
    return _run(body, stubs=stubs, modules=FACILITY_MODULES)


def run_production(body: str) -> dict[str, str]:
    """S3 纯函数：Compute 的边界（不碰假 DB）。"""
    return _run(body, stubs=PRODUCTION_STUBS, modules=PRODUCTION_MODULES)


def run_production_db(body: str) -> dict[str, str]:
    """S3 写库：SettleFacility 的 CAS / produced_units。"""
    stubs = read_text(PROBE_COMMON, PRODUCTION_PROBE) + "\n"
    stubs += "function GetConvar(_, default) return default end\n"
    return _run(body, stubs=stubs, modules=PRODUCTION_MODULES)


def run_treasury(body: str) -> dict[str, str]:
    """S1：存款 / 取款 / 流水。"""
    flag = "true" if unique_ref_declared() else "false"
    return _run(
        body,
        stubs=read_text(PROBE_COMMON, TREASURY_PROBE),
        modules=TREASURY_MODULES,
        prefix=f"__uniqueRef = {flag}\n",
    )


def run_treasury_commands(body: str) -> dict[str, str]:
    """S1 命令注册：只加载 audit.lua + commands.lua，不提供全局 QBCore。"""
    return _run(body, stubs=COMMAND_STUBS, modules=COMMAND_MODULES)


def run_grant(body: str) -> dict[str, str]:
    """S1 /orgfundgrant：EnsureAccount → Deposit → 审计的整条路径。"""
    stubs = read_text(PROBE_COMMON, TREASURY_PROBE) + "\n" + COMMAND_STUBS
    return _run(body, stubs=stubs, modules=GRANT_MODULES)


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


def run_wiring(
    debug: bool = False,
    *,
    debug_convar: str = "industry_sales_debug",
    enabled: bool = True,
    pcall: bool = False,
    convars: dict[str, str] | None = None,
) -> dict[str, str]:
    """按 manifest 全加载资源（不提供全局 QBCore），回读命令 / 回调 / 导出面。

    `debug` 只控制 `debug_convar` 指向的后台入口；另一个调试 convar 固定 false，
    这样 S4/S3 的接线用例不会互相污染。`pcall=True` 用于 `industry_enable=false`
    的关闸分支：main.lua 顶层 `return` 会结束整个 chunk，包进函数才不会吞掉回读。
    """
    values = {
        "industry_enable": "true" if enabled else "false",
        "industry_sales_debug": "false",
        "industry_production_debug": "false",
    }
    values[debug_convar] = "true" if debug else "false"
    values.update(convars or {})

    stubs = f"__wiringConvars = {lua_table(values)}\n" + WIRING_STUBS
    files = read_text(*server_script_files())
    head = stubs + "\n" + DB_ADAPTER.read_text(encoding="utf-8") + "\n"
    emit = _WIRING_EMIT
    if pcall:
        script = head + "local __ok, __err = pcall(function()\n" + files + "\nend)\n"
        emit = "__emit('LOAD_OK', tostring(__ok) .. ':' .. tostring(__err))\n" + emit
    else:
        script = head + files + "\n"
    return run_script(script + emit)
