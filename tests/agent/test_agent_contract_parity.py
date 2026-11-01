#!/usr/bin/env python3
"""Cross-check the tool registry against the director action table.

The final review found drift that no existing test could catch: the registry
allowed teleport coordinates outside the map bounds, and a documented
``heading`` parameter was missing from the tool schema entirely. Both are
"two sources of truth moved apart" bugs, so this test reads policy.lua
directly and compares it with agent_tools.json.
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_DIR = REPO_ROOT / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import agent_tools  # noqa: E402

POLICY_PATH = (
    REPO_ROOT
    / "T-CityLite.base/resources/[custom]/custom-director/server/policy.lua"
)
ACTIONS_DOC = REPO_ROOT / "T-CityLite.base/docs/agent/ACTIONS.md"


def _parse_actions() -> dict[str, dict]:
    text = POLICY_PATH.read_text(encoding="utf-8")
    block = text.split("AgentPolicy.ACTIONS = {", 1)[1].split("\n}", 1)[0]
    actions: dict[str, dict] = {}
    for match in re.finditer(r"^    (\w+) = \{(.*?)^    \},", block, re.S | re.M):
        name, body = match.group(1), match.group(2)
        risk_match = re.search(r"risk = '(L\d)'", body)
        approval_match = re.search(r"requires_approval = (true|false)", body)
        actions[name] = {
            "risk": risk_match.group(1) if risk_match else None,
            "requires_approval": (
                approval_match.group(1) == "true" if approval_match else None
            ),
        }
    return actions


def _active_tools() -> list[dict]:
    registry = json.loads(
        (TOOLS_DIR / "agent_tools.json").read_text(encoding="utf-8")
    )
    return [tool for tool in registry["tools"] if tool["status"] == "active"]


class RegistryPolicyParityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.actions = _parse_actions()
        self.tools = _active_tools()

    def test_every_action_has_exactly_one_tool(self) -> None:
        by_action: dict[str, list[str]] = {}
        for tool in self.tools:
            if tool.get("channel") == "read":
                continue
            by_action.setdefault(tool["director_action"], []).append(tool["name"])
        for action in sorted(self.actions):
            with self.subTest(action=action):
                self.assertIn(action, by_action, "no tool exposes this action")
                self.assertEqual(
                    len(by_action[action]), 1, f"{action} is exposed by several tools"
                )

    def test_every_tool_maps_to_an_action(self) -> None:
        for tool in self.tools:
            if tool.get("channel") == "read":
                continue
            with self.subTest(tool=tool["name"]):
                self.assertIn(
                    tool["director_action"],
                    self.actions,
                    f"{tool['name']} points at an action policy.lua does not know",
                )

    def test_risk_and_approval_match(self) -> None:
        by_action = {
            tool["director_action"]: tool
            for tool in self.tools
            if tool.get("channel") != "read"
        }
        for action, definition in sorted(self.actions.items()):
            tool = by_action.get(action)
            if tool is None:
                continue
            with self.subTest(action=action):
                self.assertEqual(definition["risk"], tool["risk"])
                self.assertEqual(
                    definition["requires_approval"], tool["requires_approval"]
                )

    def test_action_and_tool_counts_are_pinned(self) -> None:
        # If this fails, update the number on purpose in the same commit that
        # adds/removes an action; silent growth is what this test prevents.
        self.assertEqual(len(self.actions), 18)
        self.assertEqual(len(self.tools), 34)

    def test_l3_and_l4_never_auto_execute(self) -> None:
        for action, definition in self.actions.items():
            if definition["risk"] in ("L3", "L4"):
                with self.subTest(action=action):
                    self.assertTrue(definition["requires_approval"])

    def test_actions_doc_lists_every_action(self) -> None:
        doc = ACTIONS_DOC.read_text(encoding="utf-8")
        for action in self.actions:
            with self.subTest(action=action):
                self.assertIn(f"`{action}`", doc)


if __name__ == "__main__":
    unittest.main(verbosity=2)
