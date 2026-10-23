"""
test_custom_ui.py — custom-ui 菜单焦点/关闭防误触工具测试
"""

import os
import subprocess
import tempfile
from pathlib import Path
import pytest


BASE = Path(__file__).resolve().parents[3]
UI_LUA = str(BASE / 'resources' / '[custom]' / 'custom-ui' / 'client' / 'main.lua')


MOCK = r'''
__exports = {}
function exports(name, fn) __exports[name] = fn end
__focus = false
__keepInput = false
function SetNuiFocus(focus, cursor) __focus = focus end
function SetNuiFocusKeepInput(v) __keepInput = v end
function GetGameTimer() return 0 end
function CreateThread(fn) end
function DisableControlAction() end
function PlayerPedId() return 1 end
function GetEntityCoords() return vector3(0, 0, 0) end
function vector3(x, y, z) return { x = x, y = y, z = z } end
print = function() end
'''

def run_ui_test(test_code: str) -> dict:
    source = open(UI_LUA, encoding='utf-8').read()
    script = MOCK + '\n' + source + '\n' + test_code
    with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as f:
        f.write(script)
        tmp = f.name
    try:
        result = subprocess.run(['lua5.4', tmp], capture_output=True, text=True, timeout=10)
        return {'ok': result.returncode == 0, 'stderr': result.stderr}
    finally:
        os.unlink(tmp)


def test_open_close_focus():
    result = run_ui_test("""
__exports.OpenMenu({ keepInput = true })
assert(__focus == true, 'focus should be true')
assert(__keepInput == true, 'keepInput should be true')
assert(__exports.IsMenuOpen() == true)
__exports.CloseMenu()
assert(__focus == false, 'focus should be false')
assert(__keepInput == false, 'keepInput should be false')
assert(__exports.IsMenuOpen() == false)
""")
    assert result['ok'], f"Lua error: {result['stderr']}"


def test_static_menu_disables_keep_input():
    result = run_ui_test("""
__exports.OpenMenu({ keepInput = false })
assert(__focus == true)
assert(__keepInput == false)
""")
    assert result['ok'], f"Lua error: {result['stderr']}"
