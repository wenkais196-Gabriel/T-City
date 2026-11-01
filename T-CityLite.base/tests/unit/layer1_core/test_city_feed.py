"""CityFeed 城市公告：纯规则 + 写路径契约。

这条链的玩家可见出口是手机 CityFeed。风险有三处，各有一条断言：
1. 玩家发帖能把自己变成「城市公告」→ 写路径必须把 `author_kind` 写死，不接受客户端传值；
2. 城市公告显示成 `@Anonymous` → 读路径必须按 `author_kind` 归类（LEFT JOIN 对 city 行只会给 NULL）；
3. 迁移不幂等 → 必须过 `information_schema` 守卫（可重复执行）。

    python3 -m pytest -q tests/unit/layer1_core/test_city_feed.py
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]  # T-CityLite.base/
PHONE = BASE / "resources" / "[custom]" / "custom-phone"
MODULE = PHONE / "server" / "city_feed.lua"
MAIN = PHONE / "server" / "main.lua"
MANIFEST = PHONE / "fxmanifest.lua"
MIGRATION = BASE / "migrations" / "v3.15_cityfeed_author_kind.sql"
LUA_BIN = shutil.which("lua5.4")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# 静态契约
# ---------------------------------------------------------------------------

def test_manifest_loads_city_feed_before_main():
    manifest = read(MANIFEST)
    assert "server/city_feed.lua" in manifest
    assert manifest.index("server/city_feed.lua") < manifest.index("server/main.lua")


def test_player_post_pins_author_kind_server_side():
    src = read(MAIN)
    # 玩家发帖的 INSERT 必须显式写 'citizen'，参数里只有 citizenid 与 content。
    assert (
        "INSERT INTO phone_cityfeed (citizenid, content, author_kind) VALUES (?, ?, 'citizen')"
        in src
    )
    # 回包也要带 author_kind，前端不必猜。
    assert "author_kind = 'citizen'," in src


def test_city_bulletin_uses_the_sentinel_author_and_the_city_kind():
    src = read(MAIN)
    assert "exports('PostCityBulletin'" in src
    assert "{ CityFeed.CITY_AUTHOR, cleaned, 'city' }" in src
    assert "INSERT INTO phone_cityfeed (citizenid, content, author_kind) VALUES (?, ?, ?)" in src
    # 文案校验必须走纯规则，而不是就地 if：#smoke 断言不可被注释绕过。
    assert "CityFeed.ValidateBulletin(content)" in src


def test_read_path_selects_author_kind_and_formats_through_the_module():
    src = read(MAIN)
    assert "f.author_kind" in src
    assert "CityFeed.FormatRow({" in src
    # 老写法（JOIN 不到就叫 Anonymous）必须消失，否则城市公告还是 @Anonymous。
    assert 'local name = "Anonymous"' not in src


def test_migration_is_idempotent_and_adds_the_enum():
    sql = read(MIGRATION)
    assert "author_kind ENUM('citizen','city') NOT NULL DEFAULT 'citizen'" in sql
    assert sql.count("information_schema.COLUMNS") >= 1
    assert "PREPARE stmt_author_kind FROM" in sql
    assert "DEALLOCATE PREPARE stmt_author_kind" in sql
    # 索引也要幂等
    assert "information_schema.STATISTICS" in sql


# ---------------------------------------------------------------------------
# 行为：真 Lua 文件
# ---------------------------------------------------------------------------

HARNESS = r"""
dofile(__MODULE__)

local function expect(cond, msg)
    if not cond then error(msg, 2) end
end

-- 1) 校验：空白 / 超长 / 控制字符 / 非字符串
local ok, err = CityFeed.ValidateBulletin('   ')
expect(ok == false and err == 'too_short', '纯空白必须拒绝')
ok, err = CityFeed.ValidateBulletin(nil)
expect(ok == false and err == 'too_short', 'nil 必须拒绝')
ok, err = CityFeed.ValidateBulletin(42)
expect(ok == false and err == 'too_short', '非字符串必须拒绝')

-- 长度按字符算：200 个汉字是 600 字节，用 # 判会误杀。
local exact = string.rep('字', CityFeed.MAX_LENGTH)
ok, err = CityFeed.ValidateBulletin(exact)
expect(ok == true, '200 字应当接受，实际: ' .. tostring(err))
expect(CityFeed.CharLength(err) == CityFeed.MAX_LENGTH, '长度按字符数，实际: ' .. tostring(CityFeed.CharLength(err)))

ok, err = CityFeed.ValidateBulletin(string.rep('字', CityFeed.MAX_LENGTH + 1))
expect(ok == false and err == 'too_long', '201 字必须拒绝')

ok, err = CityFeed.ValidateBulletin('  南区  警情\n已结案  ')
expect(ok == true and err == '南区  警情 已结案', '控制字符要被替换、首尾空白要 trim，实际: ' .. tostring(err))

-- 2) 行格式化：city 显示成「城市」，citizen 用玩家名，缺名字兜底 Anonymous
local cityRow = CityFeed.FormatRow({ id = 1, citizenid = 'city', content = 'x', likes = 0,
                                     author_kind = 'city' })
expect(cityRow.name == CityFeed.CITY_LABEL and cityRow.author_kind == 'city', 'city 行显示城市')
local citizenRow = CityFeed.FormatRow({ id = 2, citizenid = 'ABC', content = 'y', name = '张三',
                                        likes = nil, author_kind = 'citizen' })
expect(citizenRow.name == '张三' and citizenRow.likes == 0, 'citizen 行保留玩家名，likes 兜底 0')
local unknownKind = CityFeed.FormatRow({ id = 3, citizenid = 'ABC', content = 'z' })
expect(unknownKind.author_kind == 'citizen' and unknownKind.name == 'Anonymous',
       '缺 author_kind 按 citizen 处理')
expect(CityFeed.FormatRow(nil) == nil, 'nil 行返回 nil')

print('city_feed harness ok')
"""


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_city_feed_rules_under_lua(tmp_path: Path) -> None:
    harness = tmp_path / "city_feed_harness.lua"
    harness.write_text(HARNESS.replace("__MODULE__", json.dumps(str(MODULE))), encoding="utf-8")
    result = subprocess.run([LUA_BIN, str(harness)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "city_feed harness ok" in result.stdout
