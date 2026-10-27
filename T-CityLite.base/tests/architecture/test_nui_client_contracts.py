"""NUI-CLIENT-01 — static NUI/client contracts for the FiveM client layer.

Offline, deterministic, no FXServer / no DB / no network. Exercises the rules in
``docs/client/CLIENT_AUDIT.md`` and `仓库里的 .agents/skills/fivem-client（尚未建立，见 docs/engineering/agent-operating-model.md 的缺口说明）` against every
``[custom]`` resource:

  ===========================  ===============================================
  check                        contract
  ===========================  ===============================================
  ``callback_cb``              every ``RegisterNUICallback`` / ``PhoneBridge.RegisterNui``
                               handler body calls ``cb(...)``
  ``callback_early_return``    no ``return`` / ``error()`` / ``assert()`` before the
                               first ``cb(...)`` (that branch would leave CEF
                               pending forever)
  ``callback_not_analyzable``  the handler must be an inline ``function`` so the
                               body can be inspected; otherwise it needs an
                               allowlist entry
  ``focus_unpaired``           a resource that calls ``SetNuiFocus(true`` must also
                               call ``SetNuiFocus(false``
  ``focus_keepinput_unpaired`` ``SetNuiFocusKeepInput(true`` must have a matching
                               ``SetNuiFocusKeepInput(false`` in the same resource
  ``focus_no_resource_stop``   a resource with ``ui_page`` that takes focus must
                               release it in ``onResourceStop``
  ``web_fetch``                only the fetch wrapper may call raw ``fetch``;
                               callers must use ``fetchNui``
  ``web_fetch_no_timeout``     the wrapper must abort (``AbortController``) —
                               a NUI callback can be dropped, an untimed fetch
                               stays pending forever
  ``nui_request_timeout``      NUI-side ``fetch`` / ``$.post`` / ``$.ajax`` must be
                               abortable or carry an explicit ``timeout``
  ``nui_origin_hardcoded``     the NUI request origin must be
                               ``GetParentResourceName()``, not a literal
                               ``https://<resource>/``
  ``nui_callback_unregistered`` every NUI request name (and every ``fetchNui('x')``
                               target) must be registered by the client
  ``nui_external_asset``       ``ui_page`` HTML must not pull script/style from a
                               public CDN — CEF is offline and the page dies with
                               ``$ is not defined``
  ``ui_page_missing``          ``ui_page`` target exists and is covered by ``files``
  ``ui_page_asset_unlisted``   every local ``src``/``href`` of the ``ui_page`` HTML
                               is covered by ``files`` (otherwise 404 inside CEF)
  ``ui_page_asset_absolute``   local asset refs are relative (Vite ``base: './'``)
  ``dead_nui_client_file``     a client Lua file that registers NUI callbacks or
                               takes focus must be listed in ``client_scripts``
  ===========================  ===============================================

``focus_unpaired`` is a presence/pairing check, not a balanced-count check:
one close path can legitimately serve several open paths (phone's open +
watchdog re-asserts), so counting ``true`` vs ``false`` would false-positive on
good code. What cannot be decided statically goes to the allowlist.

Everything the scanner cannot decide statically (or cannot fix because it is
business code we are auditing, not editing) is registered in
``nui_client_allowlist.json`` with ``reason`` / ``owner`` / ``expires``. The
registry is a debt register:

* an entry whose ``expires`` date passed fails the suite;
* an entry that no longer matches a real violation fails as stale, so a fix
  must delete the entry in the same commit;
* the entry key is ``(check, resource, file, name)`` — line numbers are never
  stored, so unrelated edits do not churn the registry.

Reverse checks inject the exact shapes the rules removed (a callback that
returns before ``cb``, an unpaired keepInput, a bare ``fetch``, a literal
``https://custom-phone/`` origin, an unlisted built asset, a dead NUI client
file) into a temporary ``resources/[custom]`` tree and require the scanner to go
red. A control injection with the corrected shapes must stay green.

Run: ``python3 -m pytest -q tests/architecture/test_nui_client_contracts.py``
"""
from __future__ import annotations

import fnmatch
import json
import re
import time
from dataclasses import dataclass
from datetime import date
from functools import lru_cache
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
RESOURCES = BASE / "resources"
REGISTRY = Path(__file__).with_name("nui_client_allowlist.json")

SCANNED_BRACKETS = ("[custom]",)
NUI_JS_SUFFIXES = (".js", ".mjs", ".ts", ".svelte", ".html")

REQUIRED_ENTRY_FIELDS = ("id", "check", "resource", "file", "reason", "owner", "added", "expires")
KNOWN_CHECKS = {
    "callback_cb",
    "callback_early_return",
    "callback_not_analyzable",
    "focus_unpaired",
    "focus_keepinput_unpaired",
    "focus_no_resource_stop",
    "web_fetch",
    "web_fetch_no_timeout",
    "nui_request_timeout",
    "nui_origin_hardcoded",
    "nui_callback_unregistered",
    "nui_external_asset",
    "ui_page_missing",
    "ui_page_asset_unlisted",
    "ui_page_asset_absolute",
    "dead_nui_client_file",
}

# ``PhoneBridge.RegisterNui`` is the client-core wrapper around
# ``RegisterNUICallback``; it is scanned exactly like a direct registration so
# moving a callback into client/core does not hide it from the contract.
CALLBACK_SIG_RE = re.compile(
    r"(?:RegisterNUICallback|PhoneBridge\.RegisterNui)\s*\(\s*(['\"])(?P<name>[^'\"]+)\1\s*,\s*"
)
NUIFOCUS_TRUE_RE = re.compile(r"\bSetNuiFocus\s*\(\s*true\b")
NUIFOCUS_FALSE_RE = re.compile(r"\bSetNuiFocus\s*\(\s*false\b")
KEEPINPUT_TRUE_RE = re.compile(r"\bSetNuiFocusKeepInput\s*\(\s*true\b")
KEEPINPUT_FALSE_RE = re.compile(r"\bSetNuiFocusKeepInput\s*\(\s*false\b")
CB_CALL_RE = re.compile(r"\bcb\s*\(")
BLOCK_OPEN_RE = re.compile(r"\b(?:function|if|repeat|do)\b")
BLOCK_CLOSE_RE = re.compile(r"\b(?:end|until)\b")
LONG_COMMENT_RE = re.compile(r"\[(=*)\[")
HTML_REF_RE = re.compile(r"(?:src|href)\s*=\s*[\"']([^\"']+)[\"']", re.I)
LOCAL_ORIGIN_RE = re.compile(
    r"""(?:fetch|\$\.post|\$\.get|\$\.ajax)\s*\(\s*['"]https?://(?P<host>[^'"/]+)(?P<path>/[^'"]*)['"]"""
)
FETCHNUI_RE = re.compile(r"fetchNui[^()\n]*\(\s*['\"]([^'\"]+)['\"]")
RAW_FETCH_RE = re.compile(r"(?<![\w.])fetch\s*\(")
JQ_REQUEST_RE = re.compile(r"\$\.(?:post|get|ajax)\s*\(")
TIMEOUT_HINT_RE = re.compile(r"AbortController|\.signal|timeout\s*:", re.I)
MANIFEST_UI_PAGE_RE = re.compile(r"ui_page\s*(?:\(\s*)?['\"]([^'\"]+)['\"]")


# ---------------------------------------------------------------------------
# data model
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Violation:
    check: str
    resource: str
    file: str
    line: int
    name: str = ""
    message: str = ""

    @property
    def key(self) -> tuple[str, str, str, str]:
        return (self.check, self.resource, self.file, self.name)

    @property
    def where(self) -> str:
        return f"{self.resource}/{self.file}:{self.line}"

    def render(self) -> str:
        suffix = f" [{self.name}]" if self.name else ""
        return f"NUI-CLIENT-01 {self.where}{suffix}: {self.message}"


@dataclass(frozen=True)
class Callback:
    name: str
    line: int
    end_line: int
    body: str
    analyzable: bool
    file: str
    resource: str


@dataclass(frozen=True)
class Manifest:
    ui_page: str | None
    files: tuple[str, ...]
    client_scripts: tuple[str, ...]

    @property
    def has_explicit_client_list(self) -> bool:
        # A glob makes the "is this file loaded" question undecidable; skip the
        # dead-file check instead of guessing.
        return bool(self.client_scripts) and not any("*" in item for item in self.client_scripts)


# ---------------------------------------------------------------------------
# Lua / manifest parsing
# ---------------------------------------------------------------------------


def mask_lua(text: str) -> str:
    """Blank Lua comments (short and long) while preserving offsets/newlines."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        if text.startswith("--", i):
            long = LONG_COMMENT_RE.match(text, i + 2)
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
        elif text[i] in "'\"":
            quote = text[i]
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
        else:
            i += 1
    return "".join(out)


def mask_strings(text: str) -> str:
    """Blank string literals so block keywords inside them do not count."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        if text[i] in "'\"":
            quote = text[i]
            start = i
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            for k in range(start, min(i, n)):
                if out[k] != "\n":
                    out[k] = " "
        else:
            i += 1
    return "".join(out)


def _expand_manifest_block(masked: str, keyword: str) -> list[str]:
    """Return quoted entries of a ``keyword { ... }`` block (or the one-liner form)."""
    match = re.search(rf"\b{keyword}\b", masked)
    if not match:
        return []
    tail = masked[match.end():]
    brace = tail.find("{")
    if brace < 0:
        single = re.match(r"\s*['\"]([^'\"]+)['\"]", tail)
        return [single.group(1)] if single else []
    depth, end = 0, len(tail)
    for offset, char in enumerate(tail[brace:], start=brace):
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end = offset
                break
    return re.findall(r"['\"]([^'\"]+)['\"]", tail[brace:end])


def parse_manifest(path: Path) -> Manifest:
    raw = path.read_text(encoding="utf-8", errors="ignore")
    masked = mask_lua(raw)
    files = _expand_manifest_block(masked, "files")
    client_scripts = _expand_manifest_block(masked, "client_scripts")
    if not client_scripts:
        client_scripts = _expand_manifest_block(masked, "client_script")
    ui_page_match = MANIFEST_UI_PAGE_RE.search(masked)
    return Manifest(
        ui_page=ui_page_match.group(1) if ui_page_match else None,
        files=tuple(files),
        client_scripts=tuple(client_scripts),
    )


def iter_resources(root: Path) -> list[tuple[str, Path, Manifest]]:
    resources_dir = root / "resources"
    found: list[tuple[str, Path, Manifest]] = []
    for bracket in sorted(resources_dir.iterdir()):
        if not bracket.is_dir() or bracket.name not in SCANNED_BRACKETS:
            continue
        for resource in sorted(bracket.iterdir()):
            manifest_path = resource / "fxmanifest.lua"
            if not manifest_path.is_file():
                continue
            found.append((resource.name, resource, parse_manifest(manifest_path)))
    return found


def _client_lua_files(resource_dir: Path, manifest: Manifest) -> list[Path]:
    files: dict[str, Path] = {
        path.relative_to(resource_dir).as_posix(): path
        for path in sorted((resource_dir / "client").rglob("*.lua"))
    }
    for entry in manifest.client_scripts:
        if entry.startswith("@") or "*" in entry:
            continue
        path = resource_dir / entry.replace("\\", "/")
        if path.is_file() and path.suffix == ".lua":
            files.setdefault(path.relative_to(resource_dir).as_posix(), path)
    return [files[key] for key in sorted(files)]


def _callback_blocks(path: Path, resource: str, resource_dir: Path) -> list[Callback]:
    raw = path.read_text(encoding="utf-8", errors="ignore")
    masked = mask_lua(raw)
    no_strings = mask_strings(masked)
    lines = masked.splitlines()
    no_string_lines = no_strings.splitlines()
    resource_file = path.relative_to(resource_dir).as_posix()
    blocks: list[Callback] = []
    for match in CALLBACK_SIG_RE.finditer(masked):
        name = match.group("name")
        start = masked.count("\n", 0, match.start())
        depth = 0
        end = start
        for index in range(start, min(start + 200, len(lines))):
            code = no_string_lines[index]
            depth += len(BLOCK_OPEN_RE.findall(code))
            depth -= len(BLOCK_CLOSE_RE.findall(code))
            end = index
            if depth <= 0 and BLOCK_CLOSE_RE.search(code) and ")" in code:
                break
        body = "\n".join(lines[start:end + 1])
        analyzable = "function" in mask_strings(body)
        blocks.append(
            Callback(
                name=name,
                line=start + 1,
                end_line=end + 1,
                body=body,
                analyzable=analyzable,
                file=resource_file,
                resource=resource,
            )
        )
    return blocks


def _on_resource_stop_blocks(masked: str) -> list[str]:
    blocks: list[str] = []
    lines = masked.splitlines()
    no_strings = mask_strings(masked).splitlines()
    for index, line in enumerate(lines):
        if "onResourceStop" not in line:
            continue
        depth = 0
        end = index
        for cursor in range(index, min(index + 80, len(lines))):
            code = no_strings[cursor]
            depth += len(BLOCK_OPEN_RE.findall(code))
            depth -= len(BLOCK_CLOSE_RE.findall(code))
            end = cursor
            if depth <= 0 and BLOCK_CLOSE_RE.search(code):
                break
        blocks.append("\n".join(lines[index:end + 1]))
    return blocks


# ---------------------------------------------------------------------------
# scanners
# ---------------------------------------------------------------------------


def scan_callbacks(root: Path) -> list[Violation]:
    violations: list[Violation] = []
    for resource, resource_dir, manifest in iter_resources(root):
        for path in _client_lua_files(resource_dir, manifest):
            for callback in _callback_blocks(path, resource, resource_dir):
                if not callback.analyzable:
                    violations.append(
                        Violation(
                            "callback_not_analyzable", resource, callback.file,
                            callback.line, callback.name,
                            "handler is not an inline function; cb cannot be verified statically",
                        )
                    )
                    continue
                cb_seen = False
                reported_early = False
                nested_functions = 0
                body_lines = callback.body.splitlines()
                no_string_body = mask_strings(callback.body).splitlines()
                for offset, line in enumerate(body_lines):
                    if CB_CALL_RE.search(line):
                        cb_seen = True
                    if offset > 0:
                        nested_functions += len(re.findall(r"\bfunction\b", no_string_body[offset]))
                    early = re.search(r"\b(?:return|error\s*\(|assert\s*\()", line) is not None
                    if (
                        early
                        and not cb_seen
                        and "cb" not in line
                        and not reported_early
                        and nested_functions == 0
                    ):
                        reported_early = True
                        violations.append(
                            Violation(
                                "callback_early_return", resource, callback.file,
                                callback.line + offset, callback.name,
                                "branch returns/raises before the first cb(...); CEF stays pending",
                            )
                        )
                if not CB_CALL_RE.search(callback.body):
                    violations.append(
                        Violation(
                            "callback_cb", resource, callback.file, callback.line,
                            callback.name, "body never calls cb(...)",
                        )
                    )
    return violations


def _resource_client_text(resource_dir: Path, manifest: Manifest) -> str:
    parts = []
    for path in _client_lua_files(resource_dir, manifest):
        parts.append(mask_lua(path.read_text(encoding="utf-8", errors="ignore")))
    return "\n".join(parts)


def scan_focus(root: Path) -> list[Violation]:
    violations: list[Violation] = []
    for resource, resource_dir, manifest in iter_resources(root):
        text = _resource_client_text(resource_dir, manifest)
        if not text:
            continue
        opens = len(NUIFOCUS_TRUE_RE.findall(text))
        closes = len(NUIFOCUS_FALSE_RE.findall(text))
        if opens and not closes:
            first = next(
                (path for path in _client_lua_files(resource_dir, manifest)
                 if NUIFOCUS_TRUE_RE.search(mask_lua(path.read_text(encoding="utf-8", errors="ignore")))),
                None,
            )
            rel = first.relative_to(resource_dir).as_posix() if first else "client/"
            line = _first_match_line(first, NUIFOCUS_TRUE_RE) if first else 1
            violations.append(
                Violation("focus_unpaired", resource, rel, line, "SetNuiFocus",
                          f"{opens} SetNuiFocus(true, ...) call(s) and 0 "
                          "SetNuiFocus(false, ...): focus is never released")
            )
        if len(KEEPINPUT_TRUE_RE.findall(text)) and not KEEPINPUT_FALSE_RE.findall(text):
            first = next(
                (path for path in _client_lua_files(resource_dir, manifest)
                 if KEEPINPUT_TRUE_RE.search(mask_lua(path.read_text(encoding="utf-8", errors="ignore")))),
                None,
            )
            rel = first.relative_to(resource_dir).as_posix() if first else "client/"
            line = _first_match_line(first, KEEPINPUT_TRUE_RE) if first else 1
            violations.append(
                Violation("focus_keepinput_unpaired", resource, rel, line, "SetNuiFocusKeepInput",
                          "SetNuiFocusKeepInput(true) is never reset; every later NUI inherits it")
            )
        if not opens or not manifest.ui_page:
            continue
        stop_blocks = _on_resource_stop_blocks(text)
        if not any(NUIFOCUS_FALSE_RE.search(block) for block in stop_blocks):
            first = next(
                (path for path in _client_lua_files(resource_dir, manifest)
                 if NUIFOCUS_TRUE_RE.search(mask_lua(path.read_text(encoding="utf-8", errors="ignore")))),
                None,
            )
            rel = first.relative_to(resource_dir).as_posix() if first else "client/"
            line = _first_match_line(first, NUIFOCUS_TRUE_RE) if first else 1
            violations.append(
                Violation("focus_no_resource_stop", resource, rel, line, "SetNuiFocus",
                          "resource takes NUI focus but onResourceStop never calls SetNuiFocus(false,false)")
            )
    return violations


def _first_match_line(path: Path | None, pattern: re.Pattern[str]) -> int:
    if path is None:
        return 1
    text = mask_lua(path.read_text(encoding="utf-8", errors="ignore"))
    match = pattern.search(text)
    return text.count("\n", 0, match.start()) + 1 if match else 1


def _registered_callbacks(resource_dir: Path, manifest: Manifest) -> set[str]:
    names: set[str] = set()
    for path in _client_lua_files(resource_dir, manifest):
        masked = mask_lua(path.read_text(encoding="utf-8", errors="ignore"))
        names.update(match.group("name") for match in CALLBACK_SIG_RE.finditer(masked))
    return names


def _nui_sources(resource_dir: Path, manifest: Manifest) -> list[Path]:
    """Files CEF can load: web/src sources plus everything the manifest exposes."""
    sources: list[Path] = []
    web_src = resource_dir / "web" / "src"
    if web_src.is_dir():
        sources.extend(
            path for path in sorted(web_src.rglob("*"))
            if path.is_file() and path.suffix in NUI_JS_SUFFIXES
        )
    candidates: list[Path] = []
    if manifest.ui_page:
        candidates.append(resource_dir / manifest.ui_page.replace("\\", "/"))
    for pattern in manifest.files:
        for path in sorted(resource_dir.glob(pattern)):
            if path.is_file():
                candidates.append(path)
    seen: set[Path] = set()
    for path in candidates:
        if path.suffix not in (".js", ".mjs", ".html") or path in seen or not path.is_file():
            continue
        seen.add(path)
        sources.append(path)
    return sources


def scan_web(root: Path) -> list[Violation]:
    violations: list[Violation] = []
    for resource, resource_dir, manifest in iter_resources(root):
        web_src = resource_dir / "web" / "src"
        if not web_src.is_dir():
            continue
        for path in sorted(web_src.rglob("*")):
            if not path.is_file() or path.suffix not in (".ts", ".js", ".svelte"):
                continue
            rel = path.relative_to(resource_dir).as_posix()
            text = path.read_text(encoding="utf-8", errors="ignore")
            defines_wrapper = re.search(r"export\s+(?:async\s+)?function\s+fetchNui\b", text) is not None
            raw_fetches = list(RAW_FETCH_RE.finditer(text))
            if raw_fetches and not defines_wrapper:
                line = text.count("\n", 0, raw_fetches[0].start()) + 1
                violations.append(
                    Violation("web_fetch", resource, rel, line, "",
                              "raw fetch(' outside the NUI wrapper; use fetchNui() so Timeout/error handling applies")
                )
            if defines_wrapper and not TIMEOUT_HINT_RE.search(text):
                violations.append(
                    Violation("web_fetch_no_timeout", resource, rel, 1, "",
                              "fetch wrapper has no AbortController/timeout; a dropped NUI callback hangs forever")
                )
        registered = _registered_callbacks(resource_dir, manifest)
        if not registered:
            continue
        for path in sorted(web_src.rglob("*")):
            if not path.is_file() or path.suffix not in (".ts", ".js", ".svelte"):
                continue
            rel = path.relative_to(resource_dir).as_posix()
            text = path.read_text(encoding="utf-8", errors="ignore")
            for match in FETCHNUI_RE.finditer(text):
                name = match.group(1)
                if name not in registered:
                    line = text.count("\n", 0, match.start()) + 1
                    violations.append(
                        Violation("nui_callback_unregistered", resource, rel, line, name,
                                  f"fetchNui('{name}') has no RegisterNUICallback('{name}') in client Lua")
                    )
    return violations


def scan_nui_origins(root: Path) -> list[Violation]:
    violations: list[Violation] = []
    for resource, resource_dir, manifest in iter_resources(root):
        registered = _registered_callbacks(resource_dir, manifest)
        for path in _nui_sources(resource_dir, manifest):
            rel = path.relative_to(resource_dir).as_posix()
            text = path.read_text(encoding="utf-8", errors="ignore")
            origins: dict[str, list[int]] = {}
            for match in LOCAL_ORIGIN_RE.finditer(text):
                host = match.group("host")
                if "." in host and not host.startswith("cfx-nui-"):
                    # Public CDN; nui_external_asset covers ui_page HTML.
                    continue
                line = text.count("\n", 0, match.start()) + 1
                origins.setdefault(host, []).append(line)
                callback_name = match.group("path").lstrip("/").split("/")[0].split("?")[0]
                if registered and callback_name and callback_name not in registered:
                    violations.append(
                        Violation("nui_callback_unregistered", resource, rel, line, callback_name,
                                  f"NUI posts to '{callback_name}' but no RegisterNUICallback('{callback_name}') exists")
                    )
            for host, lines in origins.items():
                suffix = f" ({len(lines)} call sites)" if len(lines) > 1 else ""
                violations.append(
                    Violation("nui_origin_hardcoded", resource, rel, lines[0], host,
                              f"literal origin 'https://{host}/' breaks on rename{suffix}; "
                              "use GetParentResourceName()")
                )
            if (RAW_FETCH_RE.search(text) or JQ_REQUEST_RE.search(text)) and not TIMEOUT_HINT_RE.search(text):
                match = RAW_FETCH_RE.search(text) or JQ_REQUEST_RE.search(text)
                line = text.count("\n", 0, match.start()) + 1
                violations.append(
                    Violation("nui_request_timeout", resource, rel, line, "",
                              "NUI request has no AbortController/timeout; a dropped callback leaves the UI pending")
                )
    return violations


def _covered_by_files(rel_asset: str, files: tuple[str, ...]) -> bool:
    return any(fnmatch.fnmatch(rel_asset, pattern) for pattern in files)


def scan_ui_page(root: Path) -> list[Violation]:
    violations: list[Violation] = []
    for resource, resource_dir, manifest in iter_resources(root):
        if not manifest.ui_page:
            continue
        ui_page = manifest.ui_page.replace("\\", "/")
        page_path = resource_dir / ui_page
        if not page_path.is_file():
            violations.append(
                Violation("ui_page_missing", resource, ui_page, 1, ui_page,
                          "ui_page target does not exist on disk")
            )
            continue
        if not _covered_by_files(ui_page, manifest.files):
            violations.append(
                Violation("ui_page_missing", resource, ui_page, 1, ui_page,
                          "ui_page target is not covered by files{}; CEF 404s the entry page")
            )
        html = page_path.read_text(encoding="utf-8", errors="ignore")
        page_dir = page_path.parent
        external: dict[str, list[int]] = {}
        for match in HTML_REF_RE.finditer(html):
            ref = match.group(1).strip()
            line = html.count("\n", 0, match.start()) + 1
            if not ref or ref.startswith(("#", "data:", "mailto:", "javascript:")):
                continue
            if re.match(r"https?://", ref, re.I):
                host = re.match(r"https?://([^/]+)", ref, re.I).group(1)
                external.setdefault(host, []).append(line)
                continue
            if ref.startswith("/"):
                violations.append(
                    Violation("ui_page_asset_absolute", resource, ui_page, line,
                              ref.split("?")[0],
                              "absolute asset path resolves outside the ui_page folder (Vite base must be './')")
                )
                continue
            clean = ref.split("?")[0].split("#")[0]
            asset_path = (page_dir / clean).resolve()
            try:
                rel_asset = asset_path.relative_to(resource_dir.resolve()).as_posix()
            except ValueError:
                rel_asset = clean.lstrip("./")
            if not _covered_by_files(rel_asset, manifest.files):
                violations.append(
                    Violation("ui_page_asset_unlisted", resource, ui_page, line, ref,
                              f"'{ref}' resolves to {rel_asset} which files{{}} does not list; CEF 404")
                )
        for host, lines in external.items():
            suffix = f" ({len(lines)} refs)" if len(lines) > 1 else ""
            violations.append(
                Violation("nui_external_asset", resource, ui_page, lines[0], host,
                          f"ui_page loads '{host}' from the public internet{suffix}; "
                          "CEF is offline and the page dies when it is unreachable")
            )
    return violations


def scan_dead_client_files(root: Path) -> list[Violation]:
    violations: list[Violation] = []
    for resource, resource_dir, manifest in iter_resources(root):
        if not manifest.has_explicit_client_list:
            continue
        listed = {item.replace("\\", "/") for item in manifest.client_scripts
                  if not item.startswith("@") and "*" not in item}
        for path in sorted((resource_dir / "client").rglob("*.lua")):
            rel = path.relative_to(resource_dir).as_posix()
            if rel in listed:
                continue
            masked = mask_lua(path.read_text(encoding="utf-8", errors="ignore"))
            if not (CALLBACK_SIG_RE.search(masked) or NUIFOCUS_TRUE_RE.search(masked)):
                continue
            first = CALLBACK_SIG_RE.search(masked) or NUIFOCUS_TRUE_RE.search(masked)
            violations.append(
                Violation("dead_nui_client_file", resource, rel,
                          masked.count("\n", 0, first.start()) + 1, "",
                          "registers NUI callbacks / takes focus but is not in client_scripts; never runs")
            )
    return violations


# ---------------------------------------------------------------------------
# registry + workspace scan
# ---------------------------------------------------------------------------


@lru_cache(maxsize=1)
def load_registry() -> dict:
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


def validate_registry(registry: dict, today: date | None = None, root: Path | None = None) -> list[str]:
    errors: list[str] = []
    today = today or date.today()
    root = root or RESOURCES.parent
    resources = {name: path for name, path, _manifest in iter_resources(root)}
    ids: set[str] = set()
    for entry in registry.get("entries", []):
        for fieldname in REQUIRED_ENTRY_FIELDS:
            if fieldname not in entry:
                errors.append(f"entry {entry.get('id', '?')}: missing {fieldname}")
        entry_id = entry.get("id")
        if entry_id in ids:
            errors.append(f"duplicate entry id {entry_id!r}")
        ids.add(entry_id)
        if entry.get("check") not in KNOWN_CHECKS:
            errors.append(f"{entry_id}: unknown check {entry.get('check')!r}")
        if not entry.get("reason") or not entry.get("owner"):
            errors.append(f"{entry_id}: reason and owner are required")
        if str(entry.get("file", "")).startswith("/"):
            errors.append(f"{entry_id}: file must be resource-relative")
        resource_dir = resources.get(entry.get("resource", ""))
        if resource_dir is None:
            errors.append(f"{entry_id}: unknown resource {entry.get('resource')!r}")
        elif entry.get("file") and not (resource_dir / entry["file"]).is_file():
            errors.append(f"{entry_id}: {entry.get('file')} does not exist in {entry.get('resource')}")
        expires = entry.get("expires")
        if expires is None:
            continue
        try:
            expiry = date.fromisoformat(str(expires))
        except ValueError:
            errors.append(f"{entry_id}: expires is not an ISO date")
            continue
        if expiry < today:
            errors.append(f"{entry_id}: expired on {expiry.isoformat()}")
    return errors


def _entry_matches(entry: dict, violation: Violation) -> bool:
    if (entry.get("check"), entry.get("resource"), entry.get("file")) != (
        violation.check, violation.resource, violation.file
    ):
        return False
    name = entry.get("name")
    return name in (None, "") or name == violation.name


def apply_registry(violations: list[Violation], registry: dict) -> tuple[list[Violation], list[str]]:
    entries = registry.get("entries", [])
    unmatched = [violation for violation in violations
                 if not any(_entry_matches(entry, violation) for entry in entries)]
    stale = [
        f"stale NUI allowlist entry {entry.get('id')!r}: "
        f"{entry.get('check')} {entry.get('resource')}/{entry.get('file')} "
        f"no longer matches a violation — delete it"
        for entry in entries
        if not any(_entry_matches(entry, violation) for violation in violations)
    ]
    return unmatched, stale


@lru_cache(maxsize=4)
def scan_workspace(root: Path = RESOURCES.parent) -> tuple[Violation, ...]:
    violations: list[Violation] = []
    violations.extend(scan_callbacks(root))
    violations.extend(scan_focus(root))
    violations.extend(scan_web(root))
    violations.extend(scan_nui_origins(root))
    violations.extend(scan_ui_page(root))
    violations.extend(scan_dead_client_files(root))
    unique = {(violation.check, violation.resource, violation.file, violation.line,
               violation.name): violation for violation in violations}
    return tuple(sorted(unique.values(), key=lambda item: (item.resource, item.file, item.line, item.check)))


def unregistered_violations(root: Path = RESOURCES.parent) -> tuple[list[Violation], list[str]]:
    return apply_registry(list(scan_workspace(root)), load_registry())


# ---------------------------------------------------------------------------
# pytest contract
# ---------------------------------------------------------------------------


def test_registry_is_well_formed():
    registry = load_registry()
    assert registry.get("version") == 1
    assert registry.get("rule") == "NUI-CLIENT-01"
    assert registry.get("entries") is not None
    errors = validate_registry(registry)
    assert not errors, "\n".join(errors)


def test_scanner_covers_the_client_layer():
    resources = [name for name, _path, _manifest in iter_resources(RESOURCES.parent)]
    assert len(resources) >= 20, f"only {len(resources)} [custom] resources discovered"
    callbacks = 0
    for resource, resource_dir, manifest in iter_resources(RESOURCES.parent):
        for path in (resource_dir / "client").rglob("*.lua"):
            callbacks += len(CALLBACK_SIG_RE.findall(
                mask_lua(path.read_text(encoding="utf-8", errors="ignore"))
            ))
    # 2026-10-25: 删掉 custom-vehicles 那份从未注册的死中控屏（15 个回调），下限随真实值落到 53。
    assert callbacks >= 53, f"only {callbacks} RegisterNUICallback blocks found"
    page_resources = [name for name, _path, manifest in iter_resources(RESOURCES.parent) if manifest.ui_page]
    assert len(page_resources) >= 5, f"only {len(page_resources)} resources with ui_page"


def test_no_unregistered_nui_violation():
    violations, stale = unregistered_violations()
    detail = [violation.render() for violation in violations] + stale
    assert not detail, "\n".join(detail)


def test_scanner_is_offline_and_fast():
    scan_workspace.cache_clear()
    started = time.perf_counter()
    scan_workspace()
    elapsed = time.perf_counter() - started
    assert elapsed < 2.0, f"scan took {elapsed:.2f}s; keep the scanner under 2s"


def test_allowlist_keys_are_stable_documents():
    """The registry may not store line numbers (they churn under unrelated edits)."""
    for entry in load_registry()["entries"]:
        assert "line" not in entry, f"{entry['id']}: do not pin line numbers in the allowlist"


# ---------------------------------------------------------------------------
# Reverse / control injection checks
# ---------------------------------------------------------------------------


def _write_resource(root: Path, resource: str, manifest: str, files: dict[str, str]) -> Path:
    resource_dir = root / "resources" / "[custom]" / resource
    resource_dir.mkdir(parents=True, exist_ok=True)
    (resource_dir / "fxmanifest.lua").write_text(manifest, encoding="utf-8")
    for rel, body in files.items():
        target = resource_dir / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body, encoding="utf-8")
    return resource_dir


def test_reverse_check_detects_a_callback_that_returns_before_cb(tmp_path: Path):
    _write_resource(
        tmp_path, "bad-phone",
        "client_scripts { 'client/main.lua' }\nui_page 'html/index.html'\nfiles { 'html/index.html' }\n",
        {
            "client/main.lua": (
                "RegisterNUICallback('getData', function(data, cb)\n"
                "    if not data then return end\n"
                "    QBCore.Functions.TriggerCallback('x:y', function(res) cb(res) end)\n"
                "end)\n"
            ),
            "html/index.html": "<html></html>",
        },
    )
    found = [violation for violation in scan_callbacks(tmp_path) if violation.check == "callback_early_return"]
    assert [violation.name for violation in found] == ["getData"]
    assert found[0].line == 2


def test_reverse_check_detects_a_callback_without_cb(tmp_path: Path):
    _write_resource(
        tmp_path, "bad-phone",
        "client_scripts { 'client/main.lua' }\n",
        {"client/main.lua": "RegisterNUICallback('noAnswer', function(_, cb)\n    DoSomething()\nend)\n"},
    )
    found = [violation for violation in scan_callbacks(tmp_path) if violation.check == "callback_cb"]
    assert [violation.name for violation in found] == ["noAnswer"]


def test_reverse_check_detects_an_unpaired_keepinput(tmp_path: Path):
    _write_resource(
        tmp_path, "bad-ui",
        "client_scripts { 'client/main.lua' }\n",
        {
            "client/main.lua": (
                "function Open()\n"
                "    SetNuiFocus(true, true)\n"
                "    SetNuiFocusKeepInput(true)\n"
                "end\n"
                "function Close()\n"
                "    SetNuiFocus(false, false)\n"
                "end\n"
            ),
        },
    )
    checks = {violation.check for violation in scan_focus(tmp_path)}
    assert "focus_keepinput_unpaired" in checks
    assert "focus_unpaired" not in checks


def test_reverse_check_detects_missing_focus_cleanup_on_stop(tmp_path: Path):
    _write_resource(
        tmp_path, "bad-ui",
        "client_scripts { 'client/main.lua' }\nui_page 'html/index.html'\nfiles { 'html/index.html' }\n",
        {
            "client/main.lua": "AddEventHandler('onResourceStop', function(name)\n    print(name)\nend)\n"
                               "function Open() SetNuiFocus(true, true) SetNuiFocus(false, false) end\n",
            "html/index.html": "<html></html>",
        },
    )
    found = [violation for violation in scan_focus(tmp_path) if violation.check == "focus_no_resource_stop"]
    assert len(found) == 1 and found[0].resource == "bad-ui"


def test_control_injection_with_the_corrected_shapes_stays_green(tmp_path: Path):
    """Same resource, corrected: guarded callback, paired focus, cleanup, no CDN."""
    _write_resource(
        tmp_path, "good-ui",
        "client_scripts { 'client/main.lua' }\nui_page 'html/index.html'\n"
        "files { 'html/index.html', 'html/assets/*' }\n",
        {
            "client/main.lua": (
                "RegisterNUICallback('getData', function(data, cb)\n"
                "    if type(data) ~= 'table' then return cb({ success = false }) end\n"
                "    cb({ success = true })\n"
                "end)\n"
                "AddEventHandler('onResourceStop', function(name)\n"
                "    if name ~= GetCurrentResourceName() then return end\n"
                "    SetNuiFocus(false, false)\n"
                "    SetNuiFocusKeepInput(false)\n"
                "end)\n"
                "function Open()\n"
                "    SetNuiFocus(false, false)\n"
                "    SetNuiFocus(true, true)\n"
                "    SetNuiFocusKeepInput(false)\n"
                "end\n"
            ),
            "html/index.html": '<html><head><script src="./assets/index.js"></script></head></html>',
            "html/assets/index.js": (
                "const controller = new AbortController();\n"
                "setTimeout(() => controller.abort(), 6000);\n"
                "fetch(`https://${GetParentResourceName()}/getData`, { signal: controller.signal });\n"
            ),
        },
    )
    found = [violation.render() for violation in scan_workspace(tmp_path)]
    assert found == [], "\n".join(found)


def test_reverse_check_detects_a_bare_fetch_and_a_hardcoded_origin(tmp_path: Path):
    _write_resource(
        tmp_path, "bad-phone",
        "client_scripts { 'client/main.lua' }\nui_page 'html/index.html'\nfiles { 'html/index.html' }\n",
        {
            "client/main.lua": "RegisterNUICallback('getData', function(_, cb) cb({}) end)\n",
            "html/index.html": "<html></html>",
            "web/src/App.svelte": (
                "<script>\n"
                "  async function load() {\n"
                "    const r = await fetch('https://bad-phone/getData', { method: 'POST' });\n"
                "  }\n"
                "</script>\n"
            ),
        },
    )
    checks = {violation.check for violation in scan_workspace(tmp_path)}
    assert "web_fetch" in checks
    assert "nui_origin_hardcoded" in checks
    assert "nui_request_timeout" in checks


def test_reverse_check_detects_an_unregistered_nui_callback(tmp_path: Path):
    _write_resource(
        tmp_path, "bad-police",
        "client_scripts { 'client/main.lua' }\nui_page 'html/index.html'\nfiles { 'html/index.html', 'html/*.js' }\n",
        {
            "client/main.lua": "RegisterNUICallback('closeFingerprint', function(_, cb) cb('ok') end)\n",
            "html/index.html": '<html><body><script src="script.js"></script></body></html>',
            "html/script.js": 'function Close() {\n  $.post("https://bad-police/closeDatabank");\n}\n',
        },
    )
    found = [violation for violation in scan_workspace(tmp_path) if violation.check == "nui_callback_unregistered"]
    assert [violation.name for violation in found] == ["closeDatabank"]


def test_reverse_check_detects_an_unlisted_built_asset(tmp_path: Path):
    _write_resource(
        tmp_path, "bad-phone",
        "client_scripts { 'client/main.lua' }\nui_page 'html/index.html'\n"
        "files { 'html/index.html', 'html/assets/*' }\n",
        {
            "client/main.lua": "RegisterNUICallback('x', function(_, cb) cb({}) end)\n",
            "html/index.html": '<html><head><link rel="icon" href="./favicon.svg"></head></html>',
            "html/assets/index.js": "console.log(1)",
            "html/favicon.svg": "<svg/>",
        },
    )
    found = [violation for violation in scan_ui_page(tmp_path) if violation.check == "ui_page_asset_unlisted"]
    assert [violation.name for violation in found] == ["./favicon.svg"]


def test_reverse_check_detects_a_dead_nui_client_file(tmp_path: Path):
    _write_resource(
        tmp_path, "bad-vehicles",
        "client_scripts {\n    'client/main.lua',\n}\n",
        {
            "client/main.lua": "print('loaded')\n",
            "client/dashboard.lua": (
                "RegisterNUICallback('closeDashboard', function(_, cb) cb('ok') end)\n"
            ),
        },
    )
    found = [violation for violation in scan_dead_client_files(tmp_path) if violation.check == "dead_nui_client_file"]
    assert [violation.file for violation in found] == ["client/dashboard.lua"]


def test_reverse_check_detects_a_cdn_dependency(tmp_path: Path):
    _write_resource(
        tmp_path, "bad-police",
        "client_scripts { 'client/main.lua' }\nui_page 'html/index.html'\nfiles { 'html/index.html' }\n",
        {
            "client/main.lua": "RegisterNUICallback('x', function(_, cb) cb({}) end)\n",
            "html/index.html": (
                '<html><head>'
                '<script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>'
                '</head></html>'
            ),
        },
    )
    found = [violation for violation in scan_ui_page(tmp_path) if violation.check == "nui_external_asset"]
    assert [violation.name for violation in found] == ["code.jquery.com"]
