"""Unit tests for custom-menu shared MenuSpec schema validation (runs in Lua 5.4)."""

from __future__ import annotations

import pathlib
import shutil
import subprocess

import pytest


def _find_repo_root() -> pathlib.Path:
    cur = pathlib.Path(__file__).resolve()
    for parent in cur.parents:
        if (parent / "resources" / "[custom]").is_dir():
            return parent
    raise RuntimeError(f"Could not locate T-CityLite.base root from {cur}")


REPO_ROOT = _find_repo_root()
MENU_SPEC_PATH = (
    REPO_ROOT / "resources" / "[custom]" / "custom-menu" / "shared" / "menu_spec.lua"
)


def _find_lua54() -> str:
    for candidate in ("lua5.4", "lua5.4.exe", "lua54"):
        found = shutil.which(candidate)
        if found:
            return found
    fallback = pathlib.Path(r"C:\Users\swkgb\bin\lua5.4.exe")
    if fallback.is_file():
        return str(fallback)
    pytest.skip("lua5.4 binary is not available on this host")
    raise AssertionError("unreachable")


def _run_lua(script_body: str) -> subprocess.CompletedProcess[str]:
    assert MENU_SPEC_PATH.is_file(), f"Missing MenuSpec module: {MENU_SPEC_PATH}"
    lua_bin = _find_lua54()
    spec_lua_path = MENU_SPEC_PATH.as_posix()
    harness = f"""
-- Run in a clean Lua 5.4 sandbox with zero FiveM runtime globals.
package.loaded['menu_spec'] = nil
dofile({spec_lua_path!r})
assert(type(MenuSpec) == 'table', 'MenuSpec global table must be defined')
assert(type(MenuSpec.Validate) == 'function', 'MenuSpec.Validate function must be defined')

local function expect_ok(spec, opts, label)
  local ok, err = MenuSpec.Validate(spec, opts)
  assert(ok == true and err == nil,
    string.format('[%s] expected ok, got ok=%s err=%s', label, tostring(ok), tostring(err)))
end

local function expect_fail(spec, opts, pattern, label)
  local ok, err = MenuSpec.Validate(spec, opts)
  assert(ok == false, string.format('[%s] expected fail, got ok=%s', label, tostring(ok)))
  assert(type(err) == 'string' and #err > 0, string.format('[%s] missing error message', label))
  if pattern then
    assert(string.find(string.lower(err), string.lower(pattern), 1, true),
      string.format('[%s] error %q did not contain %q', label, err, pattern))
  end
end

{script_body}
"""
    return subprocess.run(
        [lua_bin, "-e", harness],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=10,
    )


def test_menu_spec_exists() -> None:
    assert MENU_SPEC_PATH.is_file(), f"Missing {MENU_SPEC_PATH}"


def test_valid_all_surfaces_and_item_kinds() -> None:
    proc = _run_lua(
        """
local known = {
  ['shop:buy'] = true,
  ['settings:toggle_hud'] = true,
  ['settings:sub_audio'] = true,
  ['form:submit_plate'] = true,
  ['confirm:delete_vehicle'] = true,
  ['confirm:cancel'] = true,
  ['range:set_volume'] = true,
}

expect_ok({
  id = 'main_menu',
  title = 'City Terminal',
  subtitle = 'Citizen Services',
  surface = 'list',
  theme = 'noir',
  density = 'comfortable',
  breadcrumbs = { 'Home', 'Services' },
  items = {
    {
      id = 'act_buy',
      kind = 'action',
      label = 'Purchase License',
      description = 'Standard driver permit',
      icon = 'shield',
      badge = '$500',
      badgeTone = 'accent',
      group = 'Permits',
      intent = 'shop:buy',
      args = { item = 'driver_license', qty = 1 },
    },
    {
      id = 'tog_hud',
      kind = 'toggle',
      label = 'Minimal HUD',
      checked = true,
      intent = 'settings:toggle_hud',
    },
    {
      id = 'nav_audio',
      kind = 'nav',
      label = 'Audio Settings',
      disabled = true,
      disabledReason = 'Locked while in combat',
      intent = 'settings:sub_audio',
    },
    {
      id = 'info_id',
      kind = 'info',
      label = 'Citizen ID',
      description = 'LS-9042',
    },
    {
      id = 'prog_rep',
      kind = 'progress',
      label = 'Reputation',
      progress = 45,
      progressMax = 100,
    },
    {
      id = 'conf_wipe',
      kind = 'confirm',
      label = 'Impound Vehicle',
      tone = 'danger',
      danger = true,
      doubleConfirm = true,
      confirmMessage = 'Confirm permanent impound?',
      confirmLabel = 'Confirm Impound',
      cancelLabel = 'Abort',
      intent = 'confirm:delete_vehicle',
    },
  },
}, { knownIntents = known }, 'valid_list')

expect_ok({
  id = 'plate_form',
  title = 'Vehicle Registration',
  surface = 'form',
  theme = 'amber',
  density = 'compact',
  intent = 'form:submit_plate',
  submitLabel = 'Save Plate',
  cancelLabel = 'Back',
  items = {
    {
      id = 'plate_text',
      kind = 'input',
      label = 'Custom Plate',
      inputType = 'text',
      placeholder = 'TCITY01',
      required = true,
      minLength = 3,
      maxLength = 8,
      value = 'TCITY01',
    },
    {
      id = 'tax_slider',
      kind = 'range',
      label = 'Deposit Amount',
      min = 100,
      max = 5000,
      step = 50,
      value = 500,
      unit = '$',
    },
    {
      id = 'agree_tos',
      kind = 'toggle',
      label = 'Acknowledge Fee',
      checked = true,
    },
  },
}, { knownIntents = known }, 'valid_form')

expect_ok({
  id = 'danger_confirm',
  title = 'Terminate Contract',
  subtitle = 'Action cannot be undone',
  surface = 'confirm',
  theme = 'ice',
  danger = true,
  doubleConfirm = true,
  message = 'All stored inventory will be cleared.',
  confirmLabel = 'Terminate',
  cancelLabel = 'Keep Active',
  intent = 'confirm:delete_vehicle',
  cancelIntent = 'confirm:cancel',
  items = {
    { id = 'row_1', kind = 'info', label = 'Facility', description = 'Davis Quarry' },
  },
}, { knownIntents = known }, 'valid_confirm')

expect_ok({
  id = 'audio_range',
  title = 'Radio Volume',
  surface = 'range',
  intent = 'range:set_volume',
  submitLabel = 'Apply',
  items = {
    {
      id = 'vol',
      kind = 'range',
      label = 'Master Gain',
      min = 0,
      max = 100,
      step = 5,
      value = 70,
      unit = '%',
    },
  },
}, { knownIntents = known }, 'valid_range')
"""
    )
    assert proc.returncode == 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"


def test_rejects_missing_and_invalid_top_level_fields() -> None:
    proc = _run_lua(
        """
local base = {
  id = 'm1',
  title = 'Test',
  surface = 'list',
  items = { { id = 'i1', kind = 'info', label = 'Row' } },
}

expect_fail('not_table', nil, 'table', 'spec_not_table')
expect_fail({ title = 'T', surface = 'list', items = {} }, nil, 'id', 'missing_id')
expect_fail({ id = '', title = 'T', surface = 'list', items = {} }, nil, 'id', 'empty_id')
expect_fail({ id = 123, title = 'T', surface = 'list', items = {} }, nil, 'id', 'non_string_id')
expect_fail({ id = string.rep('a', 65), title = 'T', surface = 'list', items = {} }, nil, '64', 'id_too_long')
expect_ok({ id = string.rep('a', 64), title = 'T', surface = 'list', items = {} }, nil, 'id_exact_64')

expect_fail({ id = 'm1', surface = 'list', items = {} }, nil, 'title', 'missing_title')
expect_fail({ id = 'm1', title = '', surface = 'list', items = {} }, nil, 'title', 'empty_title')
expect_fail({ id = 'm1', title = 'T', items = {} }, nil, 'surface', 'missing_surface')
expect_fail({ id = 'm1', title = 'T', surface = 'grid', items = {} }, nil, 'surface', 'unknown_surface_grid')
expect_fail({ id = 'm1', title = 'T', surface = 'table', items = {} }, nil, 'surface', 'unknown_surface_table')
expect_fail({ id = 'm1', title = 'T', surface = 'list' }, nil, 'items', 'missing_items')
expect_fail({ id = 'm1', title = 'T', surface = 'list', items = 'nope' }, nil, 'items', 'items_not_array')
expect_fail({ id = 'm1', title = 'T', surface = 'list', items = { foo = { id = 'x', kind = 'info', label = 'L' } } }, nil, 'array', 'items_map')
expect_fail({ id = 'm1', title = 'T', surface = 'list', items = { [1] = { id = 'x', kind = 'info', label = 'L' }, [3] = { id = 'y', kind = 'info', label = 'M' } } }, nil, 'array', 'items_sparse')

-- Unknown top-level field must fail whitelist check
expect_fail({
  id = 'm1',
  title = 'T',
  surface = 'list',
  items = {},
  _selectedIndex = 2,
}, nil, 'unknown', 'unknown_top_field')
"""
    )
    assert proc.returncode == 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"


def test_rejects_item_errors_unknown_intents_and_closures() -> None:
    proc = _run_lua(
        """
local known = { ['known:ok'] = true }

expect_fail({
  id = 'm1', title = 'T', surface = 'list',
  items = { { kind = 'info', label = 'L' } },
}, nil, 'id', 'item_missing_id')

expect_fail({
  id = 'm1', title = 'T', surface = 'list',
  items = { { id = 'i1', label = 'L' } },
}, nil, 'kind', 'item_missing_kind')

expect_fail({
  id = 'm1', title = 'T', surface = 'list',
  items = { { id = 'i1', kind = 'info' } },
}, nil, 'label', 'item_missing_label')

expect_fail({
  id = 'm1', title = 'T', surface = 'list',
  items = { { id = 'i1', kind = 'dropdown', label = 'L' } },
}, nil, 'kind', 'item_unknown_kind')

-- Unknown item field rejected by whitelist
expect_fail({
  id = 'm1', title = 'T', surface = 'list',
  items = { { id = 'i1', kind = 'info', label = 'L', uiPrivate = true } },
}, nil, 'unknown', 'item_unknown_field')

-- Unknown intent rejected (item level, top level, cancelIntent, empty/nil knownIntents)
expect_fail({
  id = 'm1', title = 'T', surface = 'list',
  items = { { id = 'i1', kind = 'action', label = 'Act', intent = 'evil:run' } },
}, { knownIntents = known }, 'intent', 'item_unknown_intent')

expect_fail({
  id = 'm1', title = 'T', surface = 'form',
  intent = 'evil:form',
  items = { { id = 'i1', kind = 'input', label = 'Name' } },
}, { knownIntents = known }, 'intent', 'top_unknown_intent')

expect_fail({
  id = 'm1', title = 'T', surface = 'confirm',
  intent = 'known:ok',
  cancelIntent = 'evil:cancel',
  items = {},
}, { knownIntents = known }, 'cancelIntent', 'unknown_cancel_intent')

expect_fail({
  id = 'm1', title = 'T', surface = 'list',
  items = { { id = 'i1', kind = 'action', label = 'Act', intent = 'known:ok' } },
}, nil, 'knownIntents', 'missing_known_intents_with_intent')

-- Closures / functions rejected at top level, item level, and deeply nested args
expect_fail({
  id = 'm1', title = 'T', surface = 'list',
  items = { { id = 'i1', kind = 'action', label = 'Act', intent = 'known:ok', args = { cb = function() end } } },
}, { knownIntents = known }, 'function', 'nested_function_in_args')

expect_fail({
  id = 'm1', title = 'T', surface = 'list',
  items = { { id = 'i1', kind = 'action', label = 'Act', intent = 'known:ok', args = { deep = { deeper = { [function() end] = 1 } } } } },
}, { knownIntents = known }, 'function', 'nested_function_key')

expect_fail({
  id = 'm1', title = 'T', surface = 'list',
  items = { { id = 'i1', kind = 'action', label = 'Act', onSelect = function() end } },
}, { knownIntents = known }, 'function', 'item_closure_rejected')

-- Purity check: Validate does not mutate spec
local pureSpec = {
  id = 'pure_1',
  title = 'Pure',
  surface = 'list',
  items = {
    { id = 'i1', kind = 'action', label = 'Do', intent = 'known:ok', args = { count = 2 } },
  },
}
expect_ok(pureSpec, { knownIntents = known }, 'pure_first')
expect_ok(pureSpec, { knownIntents = known }, 'pure_second')
assert(pureSpec.items[1].args.count == 2 and pureSpec.extra == nil, 'Validate must not mutate spec')
"""
    )
    assert proc.returncode == 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
