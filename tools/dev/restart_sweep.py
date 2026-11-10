"""restart 连带停掉依赖资源之后，按 boot.json 的顺序把缺的补回来。

用法：python tools/dev/restart_sweep.py --missing-only
"""

import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, (REPO / "tools" / "dev").as_posix())
import boot_cfg  # noqa: E402


def live_resources(port: int = 30130) -> set[str]:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/info.json", timeout=5) as response:
        return set(json.load(response)["resources"])


def console(command: str) -> str:
    env_password = subprocess.run(
        ["grep", "-oP", r'set rcon_password "\K[^"]+', str(REPO / "T-CityLite.base" / "server.cfg")],
        capture_output=True, text=True,
    ).stdout.strip()
    result = subprocess.run(
        [sys.executable, str(REPO / "tools" / "dev" / "fivem_console.py"), command],
        capture_output=True, text=True,
        env={**__import__("os").environ, "FIVEM_RCON_PASSWORD": env_password},
        timeout=60,
    )
    return (result.stdout or "") + (result.stderr or "")


def main() -> int:
    sequence = [resource for resource, _ in boot_cfg.startup_sequence()]
    running = live_resources()
    missing = [resource for resource in sequence if resource not in running]
    print(f"在线 {len(running)}，序列 {len(sequence)}，缺 {len(missing)}：{missing[:8]}...")
    for resource in missing:
        output = console(f"start {resource}")
        status = "ok" if "Could not" not in output and "does not exist" not in output else "FAILED"
        print(f"  start {resource}: {status}")
        time.sleep(0.4)
    time.sleep(5)
    after = live_resources()
    print(f"补完之后在线 {len(after)}；仍缺 {sorted(set(sequence) - after)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
