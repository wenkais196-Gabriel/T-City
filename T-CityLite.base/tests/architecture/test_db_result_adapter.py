"""ARCH — `insertId` / `affectedRows` 的归一化只许在 core-framework/server/db.lua。

为什么这条规则值得单独存在：本服打包的 oxmysql 的 `insert.await` / `update.await`
可能返回裸数字，也可能返回 `{ insertId = n, affectedRows = n }`（见
`tests/unit/layer0_js/test_oxmysql.cjs` 的真实回包）。每个调用点自己解形状，
就会长出两种事故：

* `affectedRows` 被当成记录 id（director 的 `agent_actions` 曾这样，INSERT 只回
  `{ affectedRows = 1 }` 时后续 UPDATE 会打到 id=1 的无关行）；
* 只认 `.insertId` 的 helper 在 stock build 返回数字时拿到 0。

S4 把这些形状收口到 `Db.InsertId/Inserted/AffectedRows/...`。本文件做两件事：

1. 前向闸门：`[custom]/**/server/**/*.lua` + `core-framework/server/**/*.lua` +
   `custom-police/shared/insert_id.lua` 里，除了适配器本身，不许再出现
   `type(x) == 'table'` 包着 `.insertId/.affectedRows/.affected_rows` 的形状；
2. 适配器契约单测：用 lua5.4 真加载 `db.lua` + stub `MySQL`，逐条钉住文件头契约
   （四种返回形状、`affectedRows` 不当 id、错误截断 160、纯归一化不碰 SQL）。

    python3 -m pytest -q tests/architecture/test_db_result_adapter.py
"""
from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[2]
RESOURCES = BASE / "resources"
CUSTOM = RESOURCES / "[custom]"
CORE = RESOURCES / "[standalone]" / "core-framework"
DB_LUA = CORE / "server" / "db.lua"
POLICE_INSERT_ID = CUSTOM / "custom-police" / "shared" / "insert_id.lua"

#: 计划 §1.3 明确不迁移的文件：回调式 MySQL.Async，迁到 await 会改异步语义。
#: 条目消失（文件被收口）时前向测试会红，逼着把例外删掉。
OUT_OF_SCOPE = {
    "[custom]/custom-quest/server/quest_db.lua": (
        "计划 §1.3：回调式 MySQL.Async，迁到 await 会改异步语义；S4 不迁移"
    ),
}

TYPE_TABLE = re.compile(r"type\s*\(\s*[A-Za-z_]\w*\s*\)\s*==\s*(['\"])table\1")
FIELD = re.compile(r"\.(insertId|affectedRows|affected_rows)\b")
INSERT_ID = re.compile(r"\.insertId\b")
_LONG_BRACKET = re.compile(r"\[(=*)\[")


def _blank(text: str) -> str:
    """用空格替换注释/字符串，保留换行（行号仍然对得上）。"""
    return "".join("\n" if char == "\n" else " " for char in text)


def strip_lua_noise(source: str) -> str:
    """去掉 Lua 的注释与字符串字面量，只留代码。"""
    out: list[str] = []
    index, size = 0, len(source)
    while index < size:
        if source.startswith("--", index):
            match = _LONG_BRACKET.match(source, index + 2)
            if match:
                close = "]" + match.group(1) + "]"
                end = source.find(close, match.end())
                end = size if end == -1 else end + len(close)
                out.append(_blank(source[index:end]))
                index = end
                continue
            end = source.find("\n", index)
            end = size if end == -1 else end
            out.append(_blank(source[index:end]))
            index = end
            continue
        if source[index] == "[":
            match = _LONG_BRACKET.match(source, index)
            if match:
                close = "]" + match.group(1) + "]"
                end = source.find(close, match.end())
                end = size if end == -1 else end + len(close)
                out.append(_blank(source[index:end]))
                index = end
                continue
        if source[index] in "\"'":
            quote = source[index]
            cursor = index + 1
            while cursor < size:
                if source[cursor] == "\\":
                    cursor += 2
                    continue
                if source[cursor] == quote:
                    cursor += 1
                    break
                cursor += 1
            literal = source[index:cursor]
            # `type(x) == 'table'` 的判据本身就是字符串；只保留这一种，
            # 其余字面量（包括文档里的示例代码）一律抹掉。
            out.append(literal if literal[1:-1] == "table" else _blank(literal))
            index = cursor
            continue
        out.append(source[index])
        index += 1
    return "".join(out)


def normalisation_lines(source: str) -> list[int]:
    """返回自己归一化 oxmysql 结果的行号（1 起）。"""
    hits: list[int] = []
    guard_on_previous_line = False
    for number, line in enumerate(strip_lua_noise(source).splitlines(), 1):
        if INSERT_ID.search(line):
            hits.append(number)
        elif FIELD.search(line) and (TYPE_TABLE.search(line) or guard_on_previous_line):
            hits.append(number)
        stripped = line.strip()
        guard_on_previous_line = bool(TYPE_TABLE.search(line)) and not stripped.endswith("end")
    return hits


def _label(path: Path) -> str:
    return path.relative_to(RESOURCES).as_posix()


def scanned_files() -> list[Path]:
    files = [
        path for path in CUSTOM.rglob("*.lua")
        if "server" in path.relative_to(CUSTOM).parts
    ]
    files += list((CORE / "server").rglob("*.lua"))
    files.append(POLICE_INSERT_ID)
    return sorted(set(files))


def test_result_normalisation_only_in_db_adapter():
    """前向：除适配器外，任何服务端文件都不许自己解 insertId/affectedRows。"""
    problems = []
    if not DB_LUA.is_file():
        problems.append(
            "缺少 core-framework/server/db.lua —— 归一化没有唯一 owner，"
            "所有调用点只能各自解形状")

    stale_exclusions = []
    for relative in OUT_OF_SCOPE:
        path = RESOURCES / relative
        if not path.is_file() or not normalisation_lines(path.read_text(encoding="utf-8")):
            stale_exclusions.append(relative)

    hits = []
    for path in scanned_files():
        relative = _label(path)
        if relative == _label(DB_LUA) or relative in OUT_OF_SCOPE:
            continue
        for line in normalisation_lines(path.read_text(encoding="utf-8", errors="ignore")):
            hits.append(f"{relative}:{line}")

    if stale_exclusions:
        problems.append(
            "这些文件已经不再自己归一化（被收口或删除了），请从 OUT_OF_SCOPE 删掉：\n  "
            + "\n  ".join(stale_exclusions))
    if hits:
        problems.append(
            "DB 结果归一化只能出现在 core-framework/server/db.lua；以下位置自己解 "
            "insertId/affectedRows（改用 Db.Insert/Db.Update 或 Db.InsertId/Db.AffectedRows）：\n  "
            + "\n  ".join(hits))

    assert not problems, "\n".join(problems)


def test_reverse_result_normalisation_is_rejected():
    """反向：坏形状必须报；注释/字符串/门面转调不许报。"""
    assert normalisation_lines(
        "local id = type(res) == 'table' and (res.affectedRows or res[1]) or res")
    assert normalisation_lines(
        "if type(result) == 'table' then\n    return result.insertId\nend")
    assert normalisation_lines("local id = result.insertId")
    assert normalisation_lines(
        "if type(affected) == 'table' then affected = affected.affectedRows or 0 end")

    assert not normalisation_lines(
        "-- type(result) == 'table' and result.affectedRows\nlocal ok = true")
    assert not normalisation_lines(
        "local text = \"type(result) == 'table' and result.affectedRows\"")
    assert not normalisation_lines(
        "function InsertId(result)\n    return Db.InsertId(result)\nend")
    assert not normalisation_lines("local affected = Db.AffectedRows(result)")


# ---------------------------------------------------------------------------
# 适配器契约（lua5.4 真加载 db.lua + stub MySQL）
# ---------------------------------------------------------------------------

LUA_BIN = shutil.which("lua5.4")


def run_lua(body: str) -> subprocess.CompletedProcess:
    if not LUA_BIN:
        pytest.skip("lua5.4 is not installed")
    script = (
        f"local chunk = assert(loadfile([[{DB_LUA}]]))\nchunk()\n"
        + body
    )
    with tempfile.NamedTemporaryFile(
            mode="w", suffix=".lua", delete=False, encoding="utf-8") as handle:
        handle.write(script)
        path = handle.name
    try:
        return subprocess.run(
            [LUA_BIN, path], capture_output=True, text=True, timeout=20)
    finally:
        Path(path).unlink(missing_ok=True)


def _assert_lua(result: subprocess.CompletedProcess) -> None:
    assert result.returncode == 0, result.stderr


def _manifest_section(text: str, name: str) -> str:
    start = text.index(f"{name} {{")
    end = text.index("}", start)
    return text[start:end]


class TestDbAdapterContract:
    def test_insert_result_shapes(self):
        result = run_lua("""
local calls = {}
local function stubInsert(value)
    MySQL = { insert = { await = function(sql, params)
        calls[#calls + 1] = { sql = sql, params = params }
        if type(value) == 'function' then error(value(), 0) end
        return value
    end } }
end

local accepted = {
    { 42, 42 },
    { { insertId = 7, affectedRows = 1 }, 7 },
    { { [1] = 9 }, 9 },
    { { id = 5 }, 5 },
}
for _, case in ipairs(accepted) do
    stubInsert(case[1])
    local id, err = Db.Insert('INSERT INTO probe (x) VALUES (?)', { 'p' })
    assert(id == case[2], 'insert id mismatch: ' .. tostring(id))
    assert(err == nil, 'insert error: ' .. tostring(err))
end

-- 适配器不拼 SQL、不改列名、不动参数。
assert(calls[1].sql == 'INSERT INTO probe (x) VALUES (?)')
assert(calls[1].params[1] == 'p')

-- 只有 affectedRows：绝不能当 id 返回。
stubInsert({ affectedRows = 1 })
local id, err = Db.Insert('INSERT INTO probe (x) VALUES (?)', {})
assert(id == nil and err == 'no_insert_id',
    'affectedRows must not become an id, got ' .. tostring(id) .. '/' .. tostring(err))

stubInsert(0)
id, err = Db.Insert('INSERT INTO probe (x) VALUES (?)', {})
assert(id == nil and err == 'no_insert_id', '0 must be no_insert_id')

stubInsert('Duplicate entry')
id, err = Db.Insert('INSERT INTO probe (x) VALUES (?)', {})
assert(id == nil and err == 'db_error', 'string result must be db_error')

MySQL = { insert = { await = function() error(('E'):rep(300), 0) end } }
id, err = Db.Insert('INSERT INTO probe (x) VALUES (?)', {})
assert(id == nil and type(err) == 'string' and #err == 160,
    'pcall errors are truncated to 160 bytes')
""")
        _assert_lua(result)

    def test_update_result_shapes(self):
        result = run_lua("""
local function stubUpdate(value)
    MySQL = { update = { await = function()
        if type(value) == 'function' then error(value(), 0) end
        return value
    end } }
end

local accepted = {
    { { affectedRows = 1 }, 1 },
    { { affected_rows = 2 }, 2 },
    { { 3 }, 3 },
    { 5, 5 },
    { 0, 0 },
}
for _, case in ipairs(accepted) do
    stubUpdate(case[1])
    local affected, err = Db.Update('UPDATE probe SET x = ? WHERE id = ?', { 1, 1 })
    assert(affected == case[2], 'affected mismatch: ' .. tostring(affected))
    assert(err == nil, 'update error: ' .. tostring(err))
end

stubUpdate('ERROR 1146')
local affected, err = Db.Update('UPDATE probe SET x = ?', { 1 })
assert(affected == nil and err == 'db_error', 'string result must be db_error')

stubUpdate(function() return ('U'):rep(400) end)
affected, err = Db.Update('UPDATE probe SET x = ?', { 1 })
assert(affected == nil and type(err) == 'string' and #err == 160)
""")
        _assert_lua(result)

    def test_query_single_scalar_shapes_and_error_truncation(self):
        result = run_lua("""
MySQL = { query = { await = function() return { { id = 1 } } end } }
local rows, err = Db.Query('SELECT id FROM probe', {})
assert(type(rows) == 'table' and rows[1].id == 1 and err == nil)

MySQL = { query = { await = function() return 'ERROR 1146' end } }
rows, err = Db.Query('SELECT id FROM probe', {})
assert(rows == nil and err == 'ERROR 1146')

MySQL = { query = { await = function() error(('Q'):rep(400), 0) end } }
rows, err = Db.Query('SELECT id FROM probe', {})
assert(rows == nil and type(err) == 'string' and #err == 160)

MySQL = { single = { await = function() return nil end } }
local row, err = Db.Single('SELECT id FROM probe LIMIT 1', {})
assert(row == nil and err == nil, 'not-found is not an error')

MySQL = { single = { await = function() return { id = 2 } end } }
row, err = Db.Single('SELECT id FROM probe LIMIT 1', {})
assert(type(row) == 'table' and row.id == 2 and err == nil)

MySQL = { scalar = { await = function() return 7 end } }
local value, err = Db.Scalar('SELECT COUNT(*) FROM probe', {})
assert(value == 7 and err == nil)

MySQL = { scalar = { await = function() error('down', 0) end } }
value, err = Db.Scalar('SELECT COUNT(*) FROM probe', {})
assert(value == nil and err == 'down')
""")
        _assert_lua(result)

    def test_pure_normalisers_do_not_touch_sql(self):
        result = run_lua("""
MySQL = nil
assert(Db.InsertId(42) == 42)
assert(Db.InsertId(nil) == 0)
assert(Db.InsertId({ insertId = 7, affectedRows = 1 }) == 7)
assert(Db.InsertId({ [1] = 9 }) == 9)
assert(Db.InsertId({ id = 5 }) == 5)
assert(Db.InsertId({ affectedRows = 1 }) == 0,
    'affectedRows is not an insert id')
assert(Db.AffectedRows({ affectedRows = 3 }) == 3)
assert(Db.AffectedRows({ affected_rows = 4 }) == 4)
assert(Db.AffectedRows({ 5 }) == 5)
assert(Db.AffectedRows(6) == 6)
assert(Db.AffectedRows({ insertId = 7 }) == 0)
assert(Db.AffectedRows(nil) == 0)
""")
        _assert_lua(result)

    def test_adapter_owns_no_sql_retry_or_waiting(self):
        """文件头契约的硬边界：不拼 SQL、不重试、不超时、不用 Citizen.Await。"""
        code = strip_lua_noise(DB_LUA.read_text(encoding="utf-8"))
        assert not re.search(r"\b(SELECT|INSERT|UPDATE|DELETE|REPLACE)\b", code), (
            "db.lua 不许拼 SQL / 改列名")
        assert "Citizen.Await" not in code
        assert not re.search(r"\bWait\s*\(", code)
        assert not re.search(r"\bwhile\b|\bfor\b", code), "适配器不做重试/超时循环"
        assert "pcall" in code, "Query/Single/Scalar 必须 pcall 包裹"

    def test_facades_delegate_to_the_adapter(self):
        insert_id = POLICE_INSERT_ID.read_text(encoding="utf-8")
        assert "function InsertId(result)" in insert_id
        assert "return Db.InsertId(result)" in insert_id
        assert not FIELD.search(strip_lua_noise(insert_id))

        sms = (CUSTOM / "custom-phone" / "server" / "sms.lua").read_text(encoding="utf-8")
        assert "return Db.InsertId(result)" in sms
        assert "return Db.AffectedRows(result)" in sms
        assert not FIELD.search(strip_lua_noise(sms))

    def test_manifests_load_the_adapter_after_oxmysql(self):
        core = (CORE / "fxmanifest.lua").read_text(encoding="utf-8")
        assert "server_scripts {" in core
        assert core.index("'@oxmysql/lib/MySQL.lua'") < core.index("'server/db.lua'")

        for resource in ("custom-director", "custom-phone", "custom-police"):
            text = (CUSTOM / resource / "fxmanifest.lua").read_text(encoding="utf-8")
            section = _manifest_section(text, "server_scripts")
            assert "'@oxmysql/lib/MySQL.lua'" in section, resource
            assert "'@core-framework/server/db.lua'" in section, resource
            assert (
                section.index("'@oxmysql/lib/MySQL.lua'")
                < section.index("'@core-framework/server/db.lua'")
            ), f"{resource}: db.lua 必须排在 oxmysql 之后"

        police = (CUSTOM / "custom-police" / "fxmanifest.lua").read_text(encoding="utf-8")
        shared = _manifest_section(police, "shared_scripts")
        server = _manifest_section(police, "server_scripts")
        assert "'shared/insert_id.lua'" not in shared, "insert_id.lua 必须移出 shared_scripts"
        assert (
            server.index("'@core-framework/server/db.lua'")
            < server.index("'shared/insert_id.lua'")
            < server.index("'server/citations.lua'")
        ), "insert_id.lua 必须在 db.lua 之后、citations.lua 之前"
