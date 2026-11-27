"""custom-prompt 去重守卫：Show 与 SetContext 同内容不重复刷 NUI。"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
PROMPT_MAIN = BASE / "resources" / "[custom]" / "custom-prompt" / "client" / "main.lua"
LUA_BIN = shutil.which("lua5.4")

HARNESS = r"""
local nui_messages = {}
local exported = {}

function SendNUIMessage(payload)
    nui_messages[#nui_messages + 1] = payload
end

function exports(name, fn)
    exported[name] = fn
end

function RegisterCommand() end
function GetConvar(_, default) return default or '0' end
function CreateThread() end
function Wait() end

dofile(__PROMPT_MAIN__)

assert(type(exported.SetContext) == 'function', 'SetContext must be exported')
assert(type(exported.ClearContext) == 'function', 'ClearContext must be exported')
assert(type(exported.Show) == 'function', 'Show must be exported')
assert(type(exported.Hide) == 'function', 'Hide must be exported')

-- 1) 相同上下文重复调用必须去重，只发 1 次 NUI
local first = {
    { key = 'E', label = '搜身' },
    { key = 'G', label = '呼叫验尸官' },
}
exported.SetContext(first)
assert(#nui_messages == 1, 'initial SetContext must send once, got ' .. #nui_messages)

exported.SetContext({
    { key = 'E', label = '搜身' },
    { key = 'G', label = '呼叫验尸官' },
})
assert(#nui_messages == 1, 'identical SetContext must deduplicate, got ' .. #nui_messages)

-- 调用方原地改表后再传同一张表，快照隔离仍应识别变化
first[1].label = '查看证件'
exported.SetContext(first)
assert(#nui_messages == 2, 'mutated caller table must be treated as a change, got ' .. #nui_messages)

-- 2) ClearContext 重置去重状态，随后再次 SetContext 同内容必须重发
exported.ClearContext()
assert(#nui_messages == 3 and #nui_messages[3].list == 0, 'ClearContext must clear list')
exported.SetContext(first)
assert(#nui_messages == 4 and #nui_messages[4].list == 2, 'SetContext after ClearContext must resend')

-- 3) 超过 3 条截断到 3 条，且截断后相等内容仍去重
exported.SetContext({
    { key = 'E', label = '1' },
    { key = 'G', label = '2' },
    { key = 'Q', label = '3' },
    { key = 'R', label = '4' },
})
assert(#nui_messages == 5 and #nui_messages[5].list == 3, 'context list must cap at 3 entries')
exported.SetContext({
    { key = 'E', label = '1' },
    { key = 'G', label = '2' },
    { key = 'Q', label = '3' },
})
assert(#nui_messages == 5, 'entries matching truncated 3 items must deduplicate, got ' .. #nui_messages)

-- 4) 空列表重复调用只发一次
exported.SetContext({})
assert(#nui_messages == 6 and #nui_messages[6].list == 0)
exported.SetContext(nil)
assert(#nui_messages == 6, 'repeated empty SetContext must deduplicate, got ' .. #nui_messages)

-- 5) Show / Hide 去重不回退
local before_show = #nui_messages
exported.Show({ key = 'E', label = '打开商店' })
exported.Show({ key = 'E', label = '打开商店' })
assert(#nui_messages == before_show + 1, 'Show must deduplicate identical prompt')
exported.Hide()
exported.Show({ key = 'E', label = '打开商店' })
assert(#nui_messages == before_show + 3, 'Hide must reset Show dedup state')

print('prompt dedup ok')
"""


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_custom_prompt_deduplicates_set_context_and_show(tmp_path: Path) -> None:
    harness = tmp_path / "prompt_harness.lua"
    harness.write_text(HARNESS.replace("__PROMPT_MAIN__", json.dumps(str(PROMPT_MAIN))), encoding="utf-8")
    result = subprocess.run([LUA_BIN, str(harness)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "prompt dedup ok" in result.stdout
