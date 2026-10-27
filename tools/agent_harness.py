#!/usr/bin/env python3
"""Local console harness (design 07): observe the FXServer and FiveM consoles.

Why this exists
---------------
`tools/agent_smoke.py` can only ask the server "did you do it?" over HTTP, and
the answer is a status code.  The consoles carry the real evidence: the
FXServer stdout log and the FiveM client's ``CitizenFX_log_*.log`` both end up
containing the line a resource printed when it did the thing.

This module is the read-only half of that: two log sources (server / client),
one cursor model, and one assertion primitive (:func:`wait`).  It performs no
network I/O and never accepts a path from the caller — both paths come from the
environment, so a model cannot turn it into an arbitrary file reader.

Design notes
------------
* ``seq`` is a **byte offset** (start of the line), not a line number.  Byte
  offsets survive appends without rescanning the file and make ``after_seq``
  paging a single ``seek``.  It is deliberately different from fivem-mcp's line
  counter, which cannot page the server log at all (measured: always 0).
* The server log is a real file with history, so :func:`observe` can read
  backwards; :func:`wait` still starts at the current end, because "wait for
  something to happen" means "after now".
* Client logs rotate per launch.  ``seq`` therefore resets when a new
  ``CitizenFX_log_*.log`` appears; every response names the file it read so a
  caller can notice the switch.

Environment
-----------
``TCITY_HARNESS=1``                     enable the harness route
``TCITY_HARNESS_SERVER_LOG``            path to FXServer's redirected stdout
``TCITY_HARNESS_CLIENT_LOG_DIR``        default: %LOCALAPPDATA%\\FiveM\\FiveM.app\\logs
``TCITY_HARNESS_CLIENT_LOG``            pin one client log file instead of "newest"
"""

from __future__ import annotations

import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator

MAX_LINES = 200
DEFAULT_LINES = 50
MAX_SCAN = 5000
TAIL_BYTES = 512 * 1024
READ_CHUNK = 4 * 1024 * 1024
POLL_SECONDS = 0.15
DEFAULT_TIMEOUT_MS = 5000
MIN_TIMEOUT_MS = 500
MAX_TIMEOUT_MS = 30_000

# FXServer writes ANSI colour codes around the channel tag.
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# ``[    c-scripting-core] Started resource chat``
# ``[rcon/script:zz-mcp-d] [zz-mcp-diag] zdiag from console``
_SERVER_LINE = re.compile(r"^\[\s*([^\]]{1,64})\]\s?(.*)$")
# ``[  78250] [b3258_GTAProce]             MainThrd/ [zz-mcp-diag] heartbeat #12``
_CLIENT_LINE = re.compile(
    r"^\[\s*\d+\]\s*\[([^\]]{1,64})\]\s*(?:([^\s/]{1,40})/)?\s?(.*)$"
)

TARGETS = ("server", "client")


class HarnessError(RuntimeError):
    """A harness failure with a stable code for the agent envelope."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def enabled() -> bool:
    """True when the harness route is explicitly switched on."""
    return os.environ.get("TCITY_HARNESS", "").strip().lower() in ("1", "true", "yes", "on")


# ---------------------------------------------------------------------------
# Path resolution (environment only — never an argument)
# ---------------------------------------------------------------------------
def _client_log_dir() -> Path:
    override = os.environ.get("TCITY_HARNESS_CLIENT_LOG_DIR", "").strip()
    if override:
        return Path(override).expanduser()
    local = os.environ.get("LOCALAPPDATA") or os.environ.get("XDG_DATA_HOME") or ""
    if local:
        return Path(local) / "FiveM" / "FiveM.app" / "logs"
    return Path.home() / ".local" / "share" / "FiveM" / "FiveM.app" / "logs"


def _newest_client_log(directory: Path | None) -> Path | None:
    if directory is None:
        return None
    try:
        candidates = sorted(
            directory.glob("CitizenFX_log_*.log"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
    except OSError:
        return None
    return candidates[0] if candidates else None


@dataclass(frozen=True)
class Sources:
    """Where the logs live.

    ``agent_smoke`` builds this from its own (injectable) environment, so the
    harness never has to read ``os.environ`` behind the caller's back.
    """

    server_log: Path | None = None
    client_log_dir: Path | None = None
    client_log: Path | None = None

    @classmethod
    def from_env(cls) -> "Sources":
        server = os.environ.get("TCITY_HARNESS_SERVER_LOG", "").strip()
        directory = os.environ.get("TCITY_HARNESS_CLIENT_LOG_DIR", "").strip()
        pinned = os.environ.get("TCITY_HARNESS_CLIENT_LOG", "").strip()
        return cls(
            server_log=Path(server).expanduser() if server else None,
            client_log_dir=Path(directory).expanduser() if directory else _client_log_dir(),
            client_log=Path(pinned).expanduser() if pinned else None,
        )


def _resolve(target: str, sources: Sources) -> Path:
    if target == "server":
        if sources.server_log is None:
            raise HarnessError(
                "harness_unconfigured",
                "set TCITY_HARNESS_SERVER_LOG to FXServer's redirected stdout log",
            )
        path = sources.server_log
    elif target == "client":
        if sources.client_log is None and sources.client_log_dir is None:
            raise HarnessError(
                "harness_unconfigured",
                "set TCITY_HARNESS_CLIENT_LOG_DIR or TCITY_HARNESS_CLIENT_LOG",
            )
        path = sources.client_log or _newest_client_log(sources.client_log_dir)
        if path is None:
            raise HarnessError(
                "log_not_found",
                f"no CitizenFX_log_*.log under {sources.client_log_dir}",
            )
    else:
        raise HarnessError("bad_request", f"target must be one of {list(TARGETS)}")
    if not path.is_file():
        raise HarnessError("log_not_found", f"{target} log not found at {path}")
    return path


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Line:
    seq: int          # byte offset where the line starts (also the paging cursor)
    end: int          # byte offset just past the newline
    channel: str
    message: str

    def as_dict(self) -> dict[str, Any]:
        return {"seq": self.seq, "channel": self.channel, "message": self.message}


def _parse(target: str, raw: str) -> tuple[str, str]:
    text = _ANSI.sub("", raw).rstrip("\r\n")
    if target == "server":
        match = _SERVER_LINE.match(text)
        if match:
            return match.group(1).strip(), match.group(2).strip()
        return "", text.strip()
    match = _CLIENT_LINE.match(text)
    if match:
        # ``channel`` is the thread that printed; fall back to the process tag
        # when the line has no ``Thread/`` prefix.
        thread = (match.group(2) or "").strip()
        return (thread or match.group(1).strip()), match.group(3).strip()
    return "", text.strip()


def _read(path: Path, target: str, cursor: int, limit: int) -> tuple[list[Line], int]:
    lines: list[Line] = []
    offset = cursor
    try:
        with path.open("rb") as handle:
            handle.seek(cursor)
            while len(lines) < limit:
                start = offset
                chunk = handle.readline(READ_CHUNK)
                if not chunk:
                    break
                offset += len(chunk)
                if not chunk.endswith(b"\n"):
                    offset = start
                    break
                channel, message = _parse(target, chunk.decode("utf-8", errors="replace"))
                lines.append(Line(start, offset, channel, message))
    except OSError as exc:
        raise HarnessError("internal_error", f"cannot read {path}: {exc}") from exc
    return lines, offset


def _size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError as exc:
        raise HarnessError("log_not_found", f"cannot stat {path}: {exc}") from exc


def _clamp(value: Any, low: int, high: int, default: int) -> int:
    if value is None:
        return default
    try:
        number = int(value)
    except (TypeError, ValueError) as exc:
        raise HarnessError("bad_request", f"expected an integer, got {value!r}") from exc
    return max(low, min(high, number))


def _compile(pattern: Any) -> re.Pattern[str] | None:
    if pattern is None or pattern == "":
        return None
    if not isinstance(pattern, str):
        raise HarnessError("bad_request", "pattern must be a string")
    try:
        return re.compile(pattern)
    except re.error as exc:
        raise HarnessError("bad_request", f"invalid pattern: {exc}") from exc


def _filtered(
    lines: list[Line], contains: Any, regex: re.Pattern[str] | None
) -> Iterator[Line]:
    needle = contains.strip() if isinstance(contains, str) else ""
    for line in lines:
        if needle and needle not in line.message:
            continue
        if regex is not None and not regex.search(line.message):
            continue
        yield line


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
def observe(
    target: str,
    *,
    limit: Any = DEFAULT_LINES,
    after_seq: Any = None,
    contains: Any = None,
    pattern: Any = None,
    sources: "Sources | None" = None,
) -> dict[str, Any]:
    """Return recent console lines for ``target`` (``server`` or ``client``)."""
    if target not in TARGETS:
        raise HarnessError("bad_request", f"target must be one of {list(TARGETS)}")
    path = _resolve(target, sources or Sources.from_env())
    count = _clamp(limit, 1, MAX_LINES, DEFAULT_LINES)
    regex = _compile(pattern)
    size = _size(path)
    if after_seq is None:
        cursor = max(0, size - TAIL_BYTES)
        scan = MAX_SCAN
    else:
        cursor = _clamp(after_seq, 0, size, 0)
        scan = min(MAX_SCAN, max(count * 10, count))

    raw_lines, scanned_to = _read(path, target, cursor, scan)
    hits = list(_filtered(raw_lines, contains, regex))
    # Tail mode ("show me what just happened") keeps the newest lines; cursor
    # mode ("continue from here") pages forward, so a caller can walk the log.
    matched = hits[:count] if after_seq is not None else hits[-count:]
    # Resume after the last line actually returned, so paging never repeats a
    # line the caller already saw (and never skips one it did not).
    next_seq = matched[-1].end if matched else scanned_to
    return {
        "target": target,
        "file": str(path),
        "lines": [line.as_dict() for line in matched],
        "next_seq": next_seq,
        "scanned": len(raw_lines),
    }


def wait(
    target: str,
    *,
    pattern: Any,
    timeout_ms: Any = DEFAULT_TIMEOUT_MS,
    after_seq: Any = None,
    contains: Any = None,
    sources: "Sources | None" = None,
) -> dict[str, Any]:
    """Block until a new line matches ``pattern``; time out with a stable code."""
    if target not in TARGETS:
        raise HarnessError("bad_request", f"target must be one of {list(TARGETS)}")
    regex = _compile(pattern)
    if regex is None:
        raise HarnessError("bad_request", "pattern is required")
    timeout = _clamp(timeout_ms, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS, DEFAULT_TIMEOUT_MS)
    path = _resolve(target, sources or Sources.from_env())
    cursor = _size(path) if after_seq is None else _clamp(after_seq, 0, _size(path), 0)
    deadline = time.monotonic() + timeout / 1000.0
    polled = 0
    while True:
        lines, cursor = _read(path, target, cursor, MAX_LINES)
        polled += len(lines)
        for line in _filtered(lines, contains, regex):
            return {
                "target": target,
                "file": str(path),
                "matched": line.as_dict(),
                "next_seq": line.end,
                "scanned": polled,
            }
        if time.monotonic() >= deadline:
            raise HarnessError(
                "timeout",
                f"no {target} console line matched /{regex.pattern}/ within {timeout}ms",
            )
        time.sleep(POLL_SECONDS)


def status(sources: "Sources | None" = None) -> dict[str, Any]:
    """Report which sources are configured; never raises for a missing log."""
    active = sources or Sources.from_env()
    report: dict[str, Any] = {"enabled": enabled(), "targets": {}}
    for target in TARGETS:
        entry: dict[str, Any] = {"configured": True}
        try:
            path = _resolve(target, active)
        except HarnessError as exc:
            entry.update({"configured": False, "code": exc.code, "error": exc.message})
            report["targets"][target] = entry
            continue
        entry["file"] = str(path)
        try:
            entry["bytes"] = path.stat().st_size
            entry["mtime"] = int(path.stat().st_mtime)
        except OSError:
            pass
        report["targets"][target] = entry
    return report
