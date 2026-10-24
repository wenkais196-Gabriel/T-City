"""FIT-10 — resource wiring: cfg ↔ manifest ↔ files ↔ export consumers.

Static, offline contract (no FXServer, no DB, no network):

* parse the live ``T-CityLite.base/server.cfg`` when it exists, otherwise the
  tracked ``server.cfg.template``; follow its ``exec configs/modules/*.cfg``
  chain and collect every ``ensure`` / ``start`` resource;
* every started resource must resolve to a directory with an
  ``fxmanifest.lua`` (the FiveM built-ins in ``check_cfgs.BUILTIN_RESOURCES``
  are exempt);
* every literal file listed in a started manifest's ``shared_scripts`` /
  ``client_scripts`` / ``server_scripts`` / ``files`` blocks must exist.
  ``@resource/file.lua`` entries come from another resource and glob patterns
  are skipped — both are deliberately treated as "not this resource's file";
* every literal ``exports['<resource>']`` / ``exports["<resource>"]`` consumer
  in a started resource must name another started resource or an external
  dependency registered in ``resource_wiring_allowlist.json``;
* the existing ``tests/check_cfgs.py`` / ``check_dependencies.py`` parsers are
  reused in-process (no subprocess) for the cfg check, declared dependencies
  and startup order, so this test and ``tests/run_all.py`` cannot drift.

Reverse checks build a synthetic manifest/consumer and require the scanner to
go red, so a parser regression cannot silently turn this rule green.

    python3 -m pytest -q tests/architecture/test_resource_wiring.py
"""
from __future__ import annotations

import importlib.util
import json
import re
from functools import lru_cache
from dataclasses import dataclass
from datetime import date
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
REPO = BASE.parent
RESOURCES = BASE / "resources"
ALLOWLIST = Path(__file__).with_name("resource_wiring_allowlist.json")

MANIFEST_SECTIONS = ("shared_scripts", "client_scripts", "server_scripts", "files")
SINGULAR_SECTIONS = {
    "shared_script": "shared_scripts",
    "client_script": "client_scripts",
    "server_script": "server_scripts",
    "file": "files",
}
GLOB_CHARS = set("*?[]")
STRING_RE = re.compile(r"'([^']*)'|\"([^\"]*)\"")
EXPORT_RE = re.compile(r"exports\s*\[\s*(['\"])([^'\"]+)\1\s*\]")
LONG_OPEN = re.compile(r"\[(=*)\[")


@dataclass(frozen=True)
class ManifestEntry:
    section: str
    value: str
    line: int

    @property
    def where(self) -> str:
        return f"{self.section}:{self.line}"


# ---------------------------------------------------------------------------
# Config chain (server.cfg when present, otherwise the tracked template)
# ---------------------------------------------------------------------------

@lru_cache(maxsize=1)
def config_source() -> Path:
    live = BASE / "server.cfg"
    return live if live.is_file() else BASE / "server.cfg.template"


def _module_paths(exec_target: str) -> list[Path]:
    """Resolve one ``exec`` target, including a rare ``configs/modules/*.cfg``."""
    target = (BASE / exec_target).as_posix()
    if GLOB_CHARS & set(exec_target):
        return sorted(BASE.glob(exec_target))
    path = Path(target)
    return [path] if path.is_file() else []


@lru_cache(maxsize=1)
def configured_resources(source: Path | None = None) -> tuple[list[str], Path]:
    """Return (started resources, cfg file actually parsed).

    The live ``server.cfg`` is gitignored; CI and fresh clones only have
    ``server.cfg.template``. Both use the same ``exec configs/modules/*.cfg``
    chain, so following the chain gives the same resource set.
    """
    source = source or config_source()
    resources: list[str] = []
    seen: set[str] = set()
    visited: set[Path] = set()

    def add(name: str) -> None:
        key = name.strip().lower()
        if key and key not in seen:
            seen.add(key)
            resources.append(key)

    def parse(path: Path) -> None:
        path = path.resolve()
        if path in visited or not path.is_file():
            return
        visited.add(path)
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            ensure = re.match(r"^(?:ensure|start)\s+([^\s#;]+)", stripped, re.I)
            if ensure:
                add(re.split(r"[\s#;]", ensure.group(1))[0])
                continue
            execute = re.match(r"^exec\s+([^\s#;]+)", stripped, re.I)
            if execute:
                for module in _module_paths(execute.group(1)):
                    parse(module)

    parse(source)
    return sorted(resources), source


# ---------------------------------------------------------------------------
# Manifests
# ---------------------------------------------------------------------------

def mask_comments(text: str) -> str:
    """Blank Lua comments while keeping strings (manifest entries) intact."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        char = text[i]
        if char == "-" and text.startswith("--", i):
            long = LONG_OPEN.match(text, i + 2)
            if long:
                close = "]" + long.group(1) + "]"
                end = text.find(close, long.end())
                end = n if end < 0 else end + len(close)
            else:
                end = text.find("\n", i)
                end = n if end < 0 else end
            for k in range(i, end):
                if out[k] != "\n":
                    out[k] = " "
            i = end
        elif char in "'\"":
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == char:
                    i += 1
                    break
                i += 1
        else:
            i += 1
    return "".join(out)


def _line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def manifest_entries(text: str) -> list[ManifestEntry]:
    """Extract every literal entry from the four supported manifest blocks."""
    code = mask_comments(text)
    entries: list[ManifestEntry] = []
    for section in MANIFEST_SECTIONS:
        block_re = re.compile(rf"(?ms)^[ \t]*{section}[ \t]*\{{(.*?)\}}")
        for block in block_re.finditer(code):
            body = block.group(1)
            for string in STRING_RE.finditer(body):
                value = string.group(1) if string.group(1) is not None else string.group(2)
                entries.append(
                    ManifestEntry(section, value, _line_of(code, block.start(1) + string.start()))
                )
    for singular, section in SINGULAR_SECTIONS.items():
        single_re = re.compile(rf"(?m)^[ \t]*{singular}[ \t]+(?:{STRING_RE.pattern})")
        for match in single_re.finditer(code):
            value = match.group(1) if match.group(1) is not None else match.group(2)
            entries.append(ManifestEntry(section, value, _line_of(code, match.start())))
    return entries


def manifest_missing_files(resource_dir: Path, text: str, resource: str = "") -> list[str]:
    """Return ``resource/section:line`` for literal entries that do not exist."""
    missing: list[str] = []
    for entry in manifest_entries(text):
        value = entry.value.strip()
        if not value or value.startswith("@"):
            continue  # provided by another resource, resolved by FXServer
        if GLOB_CHARS & set(value):
            continue  # deterministic scanner: do not expand globs
        if value.startswith(("http://", "https://", "/")):
            continue
        if not (resource_dir / value).is_file():
            prefix = f"{resource} " if resource else ""
            missing.append(f"{prefix}{entry.where} {value} — file does not exist")
    return missing


@lru_cache(maxsize=1)
def manifest_index(root: Path = RESOURCES) -> dict[str, list[Path]]:
    index: dict[str, list[Path]] = {}
    for manifest in sorted(root.glob("**/fxmanifest.lua")):
        index.setdefault(manifest.parent.name.lower(), []).append(manifest)
    return index


def missing_manifests(
    resources: list[str], index: dict[str, list[Path]], builtin: set[str]
) -> list[str]:
    return [name for name in resources if name not in builtin and name not in index]


# ---------------------------------------------------------------------------
# Export consumers
# ---------------------------------------------------------------------------

def export_consumers_in_text(text: str) -> set[str]:
    return {match.group(2) for match in EXPORT_RE.finditer(text)}


def resource_of(path: Path, root: Path = RESOURCES) -> str:
    """Nearest ancestor with a fxmanifest.lua is the resource directory."""
    for parent in path.parents:
        if (parent / "fxmanifest.lua").is_file():
            return parent.relative_to(root).parts[-1]
        if parent == root:
            break
    return path.relative_to(root).parts[1] if len(path.relative_to(root).parts) > 1 else ""


@lru_cache(maxsize=1)
def scan_export_consumers(
    resources: tuple[str, ...], index_items: tuple[tuple[str, tuple[Path, ...]], ...]
) -> tuple[dict[str, set[str]], int]:
    """Return {referenced resource: {consumer file}} and files scanned."""
    consumers: dict[str, set[str]] = {}
    scanned = 0
    index = {name: list(paths) for name, paths in index_items}
    for resource in resources:
        manifests = index.get(resource)
        if not manifests:
            continue
        resource_dir = manifests[0].parent
        for path in sorted(resource_dir.rglob("*.lua")):
            scanned += 1
            for target in export_consumers_in_text(path.read_text(encoding="utf-8", errors="ignore")):
                consumers.setdefault(target.lower(), set()).add(
                    path.relative_to(RESOURCES).as_posix()
                )
    return consumers, scanned


def load_allowlist() -> dict:
    return json.loads(ALLOWLIST.read_text(encoding="utf-8"))


def validate_allowlist(registry: dict) -> list[str]:
    errors: list[str] = []
    seen_ids: set[str] = set()
    for entry in registry.get("external_dependencies", []):
        for field in ("id", "resource", "reason", "added", "expires"):
            if not entry.get(field):
                errors.append(f"allowlist entry missing {field}: {entry!r}")
        if entry.get("id") in seen_ids:
            errors.append(f"duplicate allowlist id: {entry.get('id')!r}")
        seen_ids.add(entry.get("id"))
        try:
            expiry = date.fromisoformat(str(entry.get("expires")))
        except ValueError:
            errors.append(f"{entry.get('id')}: expires is not an ISO date")
            continue
        if expiry < date.today():
            errors.append(f"{entry.get('id')}: expired on {expiry.isoformat()}")
    return [error for error in errors if error]


def evaluate_consumers(
    consumers: dict[str, set[str]], started: set[str], allowed: set[str]
) -> tuple[list[str], list[str]]:
    """Return (undeclared consumers, stale allowlist entries)."""
    undeclared = [
        f"{target}: referenced by {', '.join(sorted(files)[:3])}"
        for target, files in sorted(consumers.items())
        if target not in started and target not in allowed
    ]
    stale = sorted(allowed - set(consumers))
    return undeclared, stale


# ---------------------------------------------------------------------------
# Existing parser reuse (in-process, never a subprocess)
# ---------------------------------------------------------------------------

def _load_checker(name: str):
    path = BASE / "tests" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"_tcity_{name}", path)
    assert spec and spec.loader, f"cannot load {path}"
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CHECK_CFGS = _load_checker("check_cfgs")
CHECK_DEPS = _load_checker("check_dependencies")


# ---------------------------------------------------------------------------
# pytest contract
# ---------------------------------------------------------------------------

def test_started_resources_have_a_manifest():
    resources, source = configured_resources()
    assert len(resources) >= 50, f"{source.name}: parsed only {len(resources)} resources"
    index = manifest_index()
    missing = missing_manifests(resources, index, CHECK_CFGS.BUILTIN_RESOURCES)
    assert not missing, (
        f"FIT-10: {source.name} starts resources without resources/**/fxmanifest.lua: "
        + ", ".join(missing)
    )


def test_started_manifest_files_exist():
    resources, _ = configured_resources()
    index = manifest_index()
    findings: list[str] = []
    checked = 0
    for resource in resources:
        manifests = index.get(resource)
        if not manifests:
            continue
        for manifest in manifests:
            text = manifest.read_text(encoding="utf-8", errors="ignore")
            checked += sum(
                1
                for entry in manifest_entries(text)
                if not entry.value.startswith("@") and not (GLOB_CHARS & set(entry.value))
            )
            findings.extend(manifest_missing_files(manifest.parent, text, resource))
    assert checked >= 300, f"manifest parser only found {checked} literal entries"
    assert not findings, "FIT-10: manifest lists missing file(s):\n" + "\n".join(findings)


def test_export_consumers_are_started_or_allowlisted():
    resources, _ = configured_resources()
    started = set(resources)
    index = manifest_index()
    consumers, scanned = scan_export_consumers(
        tuple(resources), tuple((name, tuple(paths)) for name, paths in index.items())
    )
    assert scanned >= 300, f"export scan only read {scanned} Lua files"

    registry = load_allowlist()
    errors = validate_allowlist(registry)
    assert not errors, "\n".join(errors)
    allowed = {entry["resource"].lower() for entry in registry["external_dependencies"]}

    undeclared, stale = evaluate_consumers(consumers, started, allowed)
    detail = [f"FIT-10: {item}" for item in undeclared]
    detail += [f"FIT-10: stale external dependency allowlist entry {item!r}" for item in stale]
    assert not detail, "\n".join(detail)


def test_existing_cfg_and_dependency_parsers_agree():
    # ① the cfg → manifest check reuses check_cfgs' built-in set and the same
    # "manifest directory must exist" semantics; test_started_resources_have_a_manifest
    # applies it to the tracked server.cfg/template chain. (check_cfgs.scan_cfg_files
    # is intentionally not called here: it performs one recursive glob per
    # resource, which costs ~2 s on this checkout.)
    # ② declared dependencies exist and are started (or built-in/system)
    index = CHECK_DEPS.build_resource_index()
    started = {name.lower() for name in CHECK_DEPS.get_cfg_resource_list()}
    issues: list[str] = []
    for resource in sorted(started):
        manifest = index.get(resource)
        if not manifest:
            continue
        for dependency in CHECK_DEPS.parse_manifest(manifest)["dependencies"]:
            key = dependency.lower()
            if key.startswith("/") or key in CHECK_CFGS.BUILTIN_RESOURCES or key in started:
                continue
            issues.append(f"{resource} depends on unstarted/missing {dependency}")
    assert not issues, "FIT-10: " + "; ".join(issues)

    # ③ startup order follows the declared dependencies
    order_issues = CHECK_DEPS.check_startup_order(
        CHECK_DEPS.get_startup_sequence(), index
    )
    assert not order_issues, "FIT-10: " + "; ".join(
        issue["msg"] for issue in order_issues
    )


# ---------------------------------------------------------------------------
# Reverse checks (the scanner must not be a mute button)
# ---------------------------------------------------------------------------

def test_reverse_check_detects_missing_manifest(tmp_path: Path):
    index = manifest_index(tmp_path)  # empty index
    missing = missing_manifests(["ghost-resource"], index, set())
    assert missing == ["ghost-resource"]


def test_reverse_check_detects_missing_script_file(tmp_path: Path):
    resource = tmp_path / "ghost-resource"
    (resource / "server").mkdir(parents=True)
    (resource / "server" / "ok.lua").write_text("-- ok\n", encoding="utf-8")
    manifest = (
        "fx_version 'cerulean'\n"
        "shared_scripts { '@oxmysql/lib/MySQL.lua', 'server/ok.lua' }\n"
        "server_scripts {\n"
        "  'server/ok.lua',\n"
        "  'server/ghost.lua',\n"
        "}\n"
    )
    findings = manifest_missing_files(resource, manifest, "ghost-resource")
    assert len(findings) == 1
    assert "server/ghost.lua" in findings[0]
    # @-prefixed entries and globs are not this resource's literal files.
    assert "MySQL.lua" not in findings[0]


def test_reverse_check_detects_unstarted_export_consumer():
    sample = (
        "local target = exports['ghost-resource']:GetThing()\n"
        "exports[\"ghost-resource\"]:DoThing()\n"
    )
    assert export_consumers_in_text(sample) == {"ghost-resource"}
    undeclared, stale = evaluate_consumers(
        {"ghost-resource": {Path("custom-police/server/x.lua").as_posix()}},
        started={"custom-police"},
        allowed=set(),
    )
    assert undeclared and "ghost-resource" in undeclared[0]
    assert stale == []


def test_commented_manifest_entry_is_ignored():
    manifest = (
        "server_scripts {\n"
        "  -- 'server/ghost.lua',\n"
        "  'server/ok.lua',\n"
        "}\n"
    )
    entries = manifest_entries(manifest)
    assert [entry.value for entry in entries] == ["server/ok.lua"]
