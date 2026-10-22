#!/usr/bin/env python3
"""Regression test for the remote vehicle-ownership claim vulnerability.

`qb-vehiclekeys:server:AcquireVehicleKeys` used to accept any plate string from
any client and grant owner keys for it. Because a FiveM client can fire any
registered net event with arbitrary arguments, this let an attacker claim
vehicles they had never touched.

The behavioural assertions live in a dependency-free Lua harness so they can
also run without Python:

    lua5.4 T-CityLite.base/tests/vehiclekeys/test_vehiclekeys_claim.lua

Run with pytest:

    python3 -m pytest -q tests/unit/layer3_business/test_vehiclekeys_claim.py
"""

from __future__ import annotations

import shutil
import subprocess
import unittest
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parents[3]  # T-CityLite.base/
REPO_ROOT = BASE_DIR.parent
LUA_TEST = BASE_DIR / "tests" / "vehiclekeys" / "test_vehiclekeys_claim.lua"
LUA_BIN = shutil.which("lua5.4")

RESOURCE_DIR = BASE_DIR / "resources" / "[custom]" / "custom-vehicles"


class VehicleKeysClaimTests(unittest.TestCase):
    """Run the standalone Lua ownership-claim suite."""

    @unittest.skipUnless(LUA_BIN, "lua5.4 is not installed")
    def test_claim_suite_passes(self) -> None:
        result = subprocess.run(
            [LUA_BIN, str(LUA_TEST), str(RESOURCE_DIR)],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(
            result.returncode,
            0,
            msg=f"Lua suite failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        self.assertIn("[VEHICLEKEYS-CLAIM-TEST] RESULT", result.stdout)
        self.assertNotIn("FAIL", result.stdout)
        self.assertRegex(
            result.stdout,
            r"\[VEHICLEKEYS-CLAIM-TEST\] RESULT passed=\d+ failed=0",
        )


class ClaimHandlerContractTests(unittest.TestCase):
    """Static guardrails so the validation cannot be silently removed."""

    def setUp(self) -> None:
        self.compat = (RESOURCE_DIR / "server" / "compat.lua").read_text(encoding="utf-8")
        self.key_manager = (RESOURCE_DIR / "server" / "key_manager.lua").read_text(encoding="utf-8")
        self.config = (RESOURCE_DIR / "config.lua").read_text(encoding="utf-8")

    def test_claim_handler_uses_db_owner_and_proximity(self) -> None:
        handler = self.compat.split("AcquireVehicleKeys", 1)[1]
        self.assertIn("NormalizePlate", handler)
        self.assertIn("player_vehicles", handler)
        self.assertIn("IsNearVehicleWithPlate", handler)

    def test_key_manager_rejects_non_string_plates(self) -> None:
        for fn in ("GiveKeys", "RemoveKeys", "HasKeys", "GetOwner", "SetOwner", "GetKeyHolders"):
            with self.subTest(function=fn):
                body = self.key_manager.split(f"function KeyManager.{fn}", 1)[1]
                self.assertIn("type(plate) ~= 'string'", body.split("end", 1)[0])

    def test_claim_distance_is_configurable(self) -> None:
        self.assertIn("vehicles_claim_max_dist", self.config)


if __name__ == "__main__":
    unittest.main()
