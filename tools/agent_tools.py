#!/usr/bin/env python3
"""Single source of truth for the T-City agent tool surface (design 03, M0).

``tools/agent_tools.json`` is the only hand-edited file.  This module loads it,
enforces the v1 contract invariants and renders the two generated mirrors:

* ``T-CityLite.base/docs/agent/TOOLS.md``
* ``T-CityLite.base/resources/[custom]/custom-director/shared/agent_tools.lua``

Usage::

    python3 tools/agent_tools.py --check   # exit 1 on drift or invalid registry
    python3 tools/agent_tools.py --write   # validate + regenerate both files

Standard library only.  No database or network access.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable

REPO_ROOT = Path(__file__).resolve().parents[1]
REGISTRY_PATH = REPO_ROOT / "tools" / "agent_tools.json"
TOOLS_MD_PATH = REPO_ROOT / "T-CityLite.base" / "docs" / "agent" / "TOOLS.md"
LUA_PATH = (
    REPO_ROOT
    / "T-CityLite.base"
    / "resources"
    / "[custom]"
    / "custom-director"
    / "shared"
    / "agent_tools.lua"
)

SCHEMA_VERSION = 1
MAX_TOOLS = 40

# Design 03 §4 whitelists these broad-but-static verbs.
VERBS = (
    "get",
    "list",
    "query",
    "count",
    "send",
    "apply",
    "set",
    "start",
    "grant",
    "revoke",
    "spawn",
    "teleport",
    "cancel",
)
NAME_RE = re.compile(
    r"^(?:" + "|".join(VERBS) + r")_[a-z][a-z0-9_]{2,48}$",
    re.ASCII,
)
# Names published before the verb rule existed are immutable (§3.2 rule 1), so
# they are grandfathered by exact name only.  Never widen this into a prefix
# rule: an ``add_*`` wildcard would let any future verb bypass the invariant.
LEGACY_NAMES = frozenset({"add_player_money"})


def is_valid_name(name: str) -> bool:
    """True for a whitelisted verb_name, or a grandfathered exact legacy name."""
    return name in LEGACY_NAMES or NAME_RE.fullmatch(name) is not None
DIRECTOR_ACTION_RE = re.compile(r"^[a-z][a-z0-9_]{2,40}$", re.ASCII)
SEMVER_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$", re.ASCII)
PARAM_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$", re.ASCII)
CITIZENID_PATTERN = r"^[A-Za-z0-9_-]{1,11}$"
IDEMPOTENCY_PATTERN = r"^[!-~]{1,128}$"
DANGEROUS_PARAM_RE = re.compile(
    r"(sql|query|script|lua|event|command|cmd|exec|eval|payload_?raw|effect)",
    re.IGNORECASE,
)
# Source identifiers are volatile slots, never stable targets (design 03 §4).
FORBIDDEN_PARAM_NAMES = frozenset({"source", "playerid", "serverid", "netid", "slot"})
BUILTIN_REF_NAMES = frozenset({"action_id"})
RISK_ORDER = {"L0": 0, "L1": 1, "L2": 2, "L3": 3, "L4": 4}
CHANNELS = ("read", "write", "effect")
ROUTES = ("gateway", "director")
RISKS = ("L0", "L1", "L2", "L3", "L4")
BLAST_RADII = ("single", "group", "world")
IDEMPOTENCY_MODES = ("required", "optional", "none")
DRY_RUN_MODES = ("supported", "unsupported", "not_applicable")
STATUSES = ("active", "planned", "deprecated")
COMPENSATIONS = ("inverse", "manual", "none")
AUTH_MODES = ("default", "live")
VERIFY_OPS = ("eq", "neq", "delta_eq", "gte", "lte", "contains", "exists")
CHANNEL_RATE_CAP = {"read": 60, "write": 10, "effect": 2}

# The registry only uses ``^[chars]{m,n}$`` patterns so the generated Lua
# validator can enforce exactly the same rule as Python's re.fullmatch without
# shipping a regex engine or depending on Lua's different pattern dialect.
SIMPLE_PATTERN_PREFIX = "^["
SIMPLE_PATTERN_SUFFIX = "}$"


def parse_simple_pattern(pattern: str) -> tuple[str, int, int] | None:
    """Expand ``^[chars]{m,n}$`` into (charset, min, max), or None.

    Parsing is done by hand rather than with a regex: the pattern itself is
    full of brackets and backslashes, and a second layer of escaping is exactly
    the kind of thing that silently stops matching.

    ``charset`` is the literal set of accepted characters, so the Lua side can
    do a plain byte lookup instead of interpreting ranges or escapes.
    """
    if not (pattern.startswith(SIMPLE_PATTERN_PREFIX) and pattern.endswith(SIMPLE_PATTERN_SUFFIX)):
        return None
    inner = pattern[len(SIMPLE_PATTERN_PREFIX) : -len(SIMPLE_PATTERN_SUFFIX)]
    if "]{" not in inner:
        return None
    body, bounds = inner.rsplit("]{", 1)
    if not body:
        return None
    pieces = bounds.split(",")
    if len(pieces) == 1:
        minimum = maximum = pieces[0]
    elif len(pieces) == 2:
        minimum, maximum = pieces
    else:
        return None
    if not (minimum.isdigit() and maximum.isdigit()):
        return None
    chars: set[str] = set()
    index = 0
    while index < len(body):
        char = body[index]
        if char == "\\":
            if index + 1 >= len(body):
                return None
            chars.add(body[index + 1])
            index += 2
            continue
        if index + 2 < len(body) and body[index + 1] == "-":
            low, high = ord(body[index]), ord(body[index + 2])
            if low > high:
                return None
            chars.update(chr(code) for code in range(low, high + 1))
            index += 3
            continue
        chars.add(char)
        index += 1
    if not chars:
        return None
    return "".join(sorted(chars)), int(minimum), int(maximum)


def parse_segmented_pattern(pattern: str) -> list[tuple[str, int, int, bool]] | None:
    """Expand ``^[0-9]{m,n}:[0-9]{m,n}$`` into (charset, min, max, literal) runs.

    The strict live-event cursor is the one pattern in the registry that a
    single char class cannot express.  Supporting exactly "digit runs joined
    by a literal ``:``" keeps the generated Lua validator byte-equivalent to
    Python's ``re.fullmatch`` without shipping a regex engine to Lua.

    Two adjacent digit runs are rejected: ``^\\d{1,2}\\d{1,2}$`` is expressible
    in Python but has no unambiguous Lua equivalent, and a generated validator
    that can never match would be worse than refusing the pattern.
    """
    if not (pattern.startswith("^") and pattern.endswith("$")):
        return None
    body = pattern[1:-1]
    segments: list[tuple[str, int, int, bool]] = []
    index = 0
    previous_was_digit = False
    while index < len(body):
        digit_open = None
        if body.startswith("\\d", index):
            digit_open = index + 2
        elif body.startswith("[0-9]", index):
            digit_open = index + 5
        if digit_open is not None:
            if previous_was_digit:
                # Adjacent digit runs have no unambiguous Lua equivalent.
                return None
            if not body.startswith("{", digit_open):
                return None
            close = body.find("}", digit_open + 1)
            if close < 0:
                return None
            bounds = body[digit_open + 1 : close].split(",")
            if len(bounds) != 2 or not all(piece.isdigit() for piece in bounds):
                return None
            minimum, maximum = int(bounds[0]), int(bounds[1])
            if minimum < 1 or maximum < minimum or maximum > 999:
                return None
            segments.append(("0123456789", minimum, maximum, False))
            index = close + 1
            previous_was_digit = True
            continue
        if body[index] == ":":
            segments.append((":", 1, 1, True))
            index += 1
            previous_was_digit = False
            continue
        return None
    if len(segments) < 2 or not any(literal for _chars, _low, _high, literal in segments):
        return None
    return segments


TOOL_KEYS = frozenset(
    {
        "name",
        "title",
        "description",
        "channel",
        "route",
        "director_action",
        "risk",
        "blast_radius",
        "requires_approval",
        "idempotency",
        "dry_run",
        "undo_supported",
        "status",
        "since",
        "auth",
        "rate_limit",
        "http",
        "inputSchema",
        "verify",
        "undo",
        "compensation",
        "limits",
        "pii",
        "enum_source",
        "deprecated",
    }
)
TOOL_REQUIRED_KEYS = (
    "name",
    "title",
    "description",
    "channel",
    "route",
    "director_action",
    "risk",
    "blast_radius",
    "requires_approval",
    "idempotency",
    "dry_run",
    "undo_supported",
    "status",
    "since",
    "http",
    "inputSchema",
    "verify",
    "undo",
    "compensation",
)
HTTP_KEYS = frozenset({"method", "path", "external_path", "query"})
SCHEMA_KEYS = frozenset({"type", "properties", "required", "additionalProperties"})
PROPERTY_KEYS = frozenset(
    {
        "type",
        "description",
        "enum",
        "const",
        "minimum",
        "maximum",
        "minLength",
        "maxLength",
        "pattern",
        "default",
        "items",
        "maxItems",
        "minItems",
        "uniqueItems",
    }
)
PROPERTY_TYPES = ("string", "integer", "number", "boolean", "array")
VERIFY_KEYS = frozenset({"tool", "args", "assert", "within_seconds", "on_mismatch"})
UNDO_KEYS = frozenset({"tool", "args", "window_seconds"})
ASSERT_KEYS = frozenset({"field", "op", "value", "tolerance"})


class RegistryError(Exception):
    """Raised when the registry cannot be loaded or violates the contract."""


# ---------------------------------------------------------------------------
# Loading / validation helpers
# ---------------------------------------------------------------------------
def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _err(errors: list[str], path: str, message: str) -> None:
    errors.append(f"{path}: {message}")


def _check_str(
    errors: list[str],
    path: str,
    value: Any,
    *,
    min_length: int = 0,
    max_length: int | None = None,
    pattern: re.Pattern[str] | None = None,
) -> bool:
    if not isinstance(value, str):
        _err(errors, path, f"must be a string, got {type(value).__name__}")
        return False
    if len(value) < min_length:
        _err(errors, path, f"must be at least {min_length} characters")
    if max_length is not None and len(value) > max_length:
        _err(errors, path, f"must be at most {max_length} characters")
    if pattern is not None and not pattern.fullmatch(value):
        _err(errors, path, f"does not match {pattern.pattern!r}")
    return True


def load_registry(path: Path | str | None = None) -> dict[str, Any]:
    """Load and validate the registry, raising :class:`RegistryError`."""
    registry_path = Path(path) if path is not None else REGISTRY_PATH
    try:
        text = registry_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RegistryError(f"cannot read {registry_path}: {exc}") from None
    try:
        registry = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RegistryError(f"{registry_path} is not valid JSON: {exc}") from None
    if not isinstance(registry, dict):
        raise RegistryError(f"{registry_path} must contain a JSON object")
    errors = validate_registry(registry)
    if errors:
        raise RegistryError(
            f"{registry_path} violates the tool contract:\n  - " + "\n  - ".join(errors)
        )
    return registry


# ---------------------------------------------------------------------------
# Registry invariants (design 03 §3.2, §4, §6, §10.1)
# ---------------------------------------------------------------------------
def validate_registry(registry: Any = None) -> list[str]:
    """Return a list of contract violations; an empty list means valid.

    With no argument the committed ``tools/agent_tools.json`` is validated.
    """
    if registry is None:
        try:
            registry = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            return [f"registry: cannot load {REGISTRY_PATH}: {exc}"]
    errors: list[str] = []
    if not isinstance(registry, dict):
        return ["registry: must be a JSON object"]

    allowed_top = {"$schema", "schema_version", "registry_version", "generated", "tools"}
    for key in sorted(set(registry) - allowed_top):
        _err(errors, f"registry.{key}", "unknown top-level field")

    if registry.get("schema_version") != SCHEMA_VERSION:
        _err(errors, "registry.schema_version", f"must be {SCHEMA_VERSION}")
    if "$schema" in registry:
        _check_str(errors, "registry.$schema", registry["$schema"], min_length=1, max_length=200)
    _check_str(
        errors,
        "registry.registry_version",
        registry.get("registry_version"),
        min_length=5,
        max_length=20,
        pattern=SEMVER_RE,
    )
    generated = registry.get("generated")
    if generated is not None and isinstance(generated, str):
        try:
            dt.datetime.fromisoformat(generated.replace("Z", "+00:00"))
        except ValueError:
            _err(errors, "registry.generated", "must be an ISO 8601 date-time")

    tools = registry.get("tools")
    if not isinstance(tools, list):
        _err(errors, "registry.tools", "must be an array")
        return errors
    if not 1 <= len(tools) <= MAX_TOOLS:
        _err(errors, "registry.tools", f"must contain 1..{MAX_TOOLS} tools")
        return errors

    by_name: dict[str, dict[str, Any]] = {}
    action_owner: dict[str, str] = {}
    tool_errors_start = len(errors)
    for index, tool in enumerate(tools):
        name = _validate_tool(errors, tool, index)
        if name is None:
            continue
        if name in by_name:
            _err(errors, f"registry.tools[{index}].name", f"duplicate tool name {name!r}")
            continue
        by_name[name] = tool
        action = tool.get("director_action")
        if isinstance(action, str):
            previous = action_owner.get(action)
            if previous is not None:
                _err(
                    errors,
                    f"registry.tools[{index}].director_action",
                    f"action {action!r} is already used by {previous!r}",
                )
            else:
                action_owner[action] = name

    # Cross references can only be checked once every tool name is known.
    for index, tool in enumerate(tools):
        if not isinstance(tool, dict):
            continue
        _validate_references(errors, tool, by_name, index)

    # Avoid a wall of cascading errors when the structure itself is broken.
    if len(errors) > tool_errors_start + 80:
        errors = errors[: tool_errors_start + 80] + ["... further errors omitted"]
    return errors


def _validate_tool(errors: list[str], tool: Any, index: int) -> str | None:
    path = f"registry.tools[{index}]"
    if not isinstance(tool, dict):
        _err(errors, path, "must be an object")
        return None

    for key in TOOL_REQUIRED_KEYS:
        if key not in tool:
            _err(errors, f"{path}.{key}", "is required")
    for key in sorted(set(tool) - TOOL_KEYS):
        _err(errors, f"{path}.{key}", "unknown tool field")

    name = tool.get("name")
    name_ok = False
    if not isinstance(name, str):
        _err(errors, f"{path}.name", "must be a string")
    elif not is_valid_name(name):
        _err(errors, f"{path}.name", f"must match {NAME_RE.pattern!r} (or be a legacy name)")
    else:
        name_ok = True

    _check_str(errors, f"{path}.title", tool.get("title"), min_length=1, max_length=60)
    _check_str(
        errors, f"{path}.description", tool.get("description"), min_length=20, max_length=400
    )

    channel = tool.get("channel")
    if channel not in CHANNELS:
        _err(errors, f"{path}.channel", f"must be one of {list(CHANNELS)}")
        channel = None
    route = tool.get("route")
    if route not in ROUTES:
        _err(errors, f"{path}.route", f"must be one of {list(ROUTES)}")
    risk = tool.get("risk")
    if risk not in RISKS:
        _err(errors, f"{path}.risk", f"must be one of {list(RISKS)}")
        risk = None
    blast = tool.get("blast_radius")
    if blast not in BLAST_RADII:
        _err(errors, f"{path}.blast_radius", f"must be one of {list(BLAST_RADII)}")
    if not isinstance(tool.get("requires_approval"), bool):
        _err(errors, f"{path}.requires_approval", "must be a boolean")
    idempotency = tool.get("idempotency")
    if idempotency not in IDEMPOTENCY_MODES:
        _err(errors, f"{path}.idempotency", f"must be one of {list(IDEMPOTENCY_MODES)}")
    dry_run = tool.get("dry_run")
    if dry_run not in DRY_RUN_MODES:
        _err(errors, f"{path}.dry_run", f"must be one of {list(DRY_RUN_MODES)}")
    if not isinstance(tool.get("undo_supported"), bool):
        _err(errors, f"{path}.undo_supported", "must be a boolean")
    status = tool.get("status")
    if status not in STATUSES:
        _err(errors, f"{path}.status", f"must be one of {list(STATUSES)}")
    _check_str(
        errors, f"{path}.since", tool.get("since"), min_length=5, max_length=20, pattern=SEMVER_RE
    )
    compensation = tool.get("compensation")
    if compensation not in COMPENSATIONS:
        _err(errors, f"{path}.compensation", f"must be one of {list(COMPENSATIONS)}")

    # ``auth`` selects the live-perception credential instead of the default one.
    # Only read tools may use it, and only on the director route that serves
    # /agent/v1/live/*; anything else would widen the live token's reach.
    auth = tool.get("auth", "default")
    if auth not in AUTH_MODES:
        _err(errors, f"{path}.auth", f"must be one of {list(AUTH_MODES)}")
    elif auth == "live":
        if channel != "read":
            _err(errors, f"{path}.auth", "auth=live is only allowed for read tools")
        if route != "director":
            _err(errors, f"{path}.auth", "auth=live requires route=director")
        live_path = (tool.get("http") or {}).get("path")
        if not isinstance(live_path, str) or not live_path.startswith("/agent/v1/live/"):
            _err(errors, f"{path}.auth", "auth=live requires a /agent/v1/live/ path")

    # Channel / risk / approval / idempotency / dry-run matrix (§4, §6).
    if channel == "read":
        if risk != "L0":
            _err(errors, f"{path}.risk", "read tools must be L0 (L0 ⇔ read)")
        if tool.get("requires_approval") is not False:
            _err(errors, f"{path}.requires_approval", "read tools must not require approval")
        if idempotency != "none":
            _err(errors, f"{path}.idempotency", "read tools must use idempotency=none")
        if dry_run != "not_applicable":
            _err(errors, f"{path}.dry_run", "read tools must use dry_run=not_applicable")
        if compensation != "none":
            _err(errors, f"{path}.compensation", "read tools must use compensation=none")
    elif channel in ("write", "effect"):
        if risk == "L0":
            _err(errors, f"{path}.risk", "write/effect tools cannot be L0")
        # Design 03 §6 says effect ⇒ L3/L4, but its own §7.3 matrix marks the
        # L2 world-atmosphere tools (send_announce/set_weather/set_time_of_day)
        # as effect.  The concrete tool matrix wins; effect still may not be L1,
        # because an L1 effect would be a destructive-free but unapproved write.
        if channel == "effect" and risk == "L1":
            _err(errors, f"{path}.risk", "effect tools must be L2, L3 or L4")
        if idempotency != "required":
            _err(errors, f"{path}.idempotency", "write/effect tools must require idempotency")
        if dry_run != "supported":
            _err(errors, f"{path}.dry_run", "write/effect tools must support dry_run")
    # L2 is "default approval" (design 03 §6); the runtime convar may downgrade
    # it to auto only when the tool also declares an undo.  A registry that
    # starts at requires_approval=false would silently bypass that gate.
    if risk == "L2" and tool.get("requires_approval") is not True:
        _err(errors, f"{path}.requires_approval", "L2 tools must default to approval")
    if risk in ("L3", "L4") and tool.get("requires_approval") is not True:
        _err(errors, f"{path}.requires_approval", f"{risk} tools must require approval")
    if blast == "world" and tool.get("requires_approval") is not True:
        _err(errors, f"{path}.requires_approval", "world-scoped tools must require approval")
    if risk == "L4" and compensation != "manual":
        _err(errors, f"{path}.compensation", "L4 tools must declare compensation=manual")

    action = tool.get("director_action")
    if channel == "read":
        if action is not None:
            _err(errors, f"{path}.director_action", "read tools must set director_action=null")
    elif channel in ("write", "effect"):
        if not isinstance(action, str):
            _err(errors, f"{path}.director_action", "write/effect tools require a director action")
        else:
            _check_str(errors, f"{path}.director_action", action, pattern=DIRECTOR_ACTION_RE)

    props = _validate_input_schema(errors, tool, path)
    _validate_http(errors, tool, path, channel, props)
    _validate_rate_limit(errors, tool, path, channel)
    _validate_limits(errors, tool, path)
    _validate_pii(errors, tool, path)
    _validate_enum_source(errors, tool, path, props)
    _validate_verify(errors, tool, path, channel)
    _validate_undo(errors, tool, path, channel)
    _validate_deprecated(errors, tool, path, status, by_name=None)

    if isinstance(name, str) and not is_valid_name(name):
        return None
    return name if name_ok and isinstance(name, str) else None


def _validate_input_schema(
    errors: list[str], tool: dict[str, Any], path: str
) -> dict[str, Any]:
    schema = tool.get("inputSchema")
    tool_name = tool.get("name") if isinstance(tool.get("name"), str) else "?"
    if not isinstance(schema, dict):
        _err(errors, f"{path}.inputSchema", "must be an object")
        return {}
    for key in sorted(set(schema) - SCHEMA_KEYS):
        _err(errors, f"{path}.inputSchema.{key}", "unknown schema field")
    if schema.get("type") != "object":
        _err(errors, f"{path}.inputSchema.type", "must be 'object'")
    if schema.get("additionalProperties") is not False:
        _err(errors, f"{path}.inputSchema.additionalProperties", "must be false")
    props = schema.get("properties")
    if not isinstance(props, dict):
        _err(errors, f"{path}.inputSchema.properties", "must be an object")
        return {}
    if len(props) > 12:
        _err(errors, f"{path}.inputSchema.properties", "maxProperties must be <= 12")
    required = schema.get("required", [])
    if not isinstance(required, list) or any(not isinstance(item, str) for item in required):
        _err(errors, f"{path}.inputSchema.required", "must be an array of strings")
        required = []
    elif len(set(required)) != len(required):
        _err(errors, f"{path}.inputSchema.required", "must not contain duplicates")
    for name in required:
        if name not in props:
            _err(
                errors,
                f"{path}.inputSchema.required",
                f"required property {name!r} is not declared in properties",
            )

    for prop_name, spec in props.items():
        prop_path = f"{path}.inputSchema.properties.{prop_name}"
        if not isinstance(prop_name, str) or not PARAM_NAME_RE.fullmatch(prop_name):
            _err(errors, prop_path, "property names must match ^[a-z][a-z0-9_]{0,63}$")
            continue
        if prop_name.lower() in FORBIDDEN_PARAM_NAMES:
            _err(errors, prop_path, "volatile source identifiers are forbidden")
        if DANGEROUS_PARAM_RE.search(prop_name):
            _err(errors, prop_path, "dangerous parameter name (command/SQL/event/eval class)")
        if not isinstance(spec, dict):
            _err(errors, prop_path, "must be an object")
            continue
        for key in sorted(set(spec) - PROPERTY_KEYS):
            _err(errors, f"{prop_path}.{key}", "unknown property keyword")
        prop_type = spec.get("type")
        if prop_type not in PROPERTY_TYPES:
            _err(errors, f"{prop_path}.type", f"must be one of {list(PROPERTY_TYPES)}")
            continue
        if prop_type == "object":
            _err(errors, f"{prop_path}.type", "nested objects are not allowed in v1")
        if "enum" in spec:
            enum = spec["enum"]
            if not isinstance(enum, list) or not enum:
                _err(errors, f"{prop_path}.enum", "must be a non-empty array")
            elif len(set(map(repr, enum))) != len(enum):
                _err(errors, f"{prop_path}.enum", "must not contain duplicates")
            elif prop_type == "string" and any(not isinstance(item, str) for item in enum):
                _err(errors, f"{prop_path}.enum", "string properties need string enum values")
            elif prop_type == "integer" and any(not _is_int(item) for item in enum):
                _err(errors, f"{prop_path}.enum", "integer properties need integer enum values")
        if "pattern" in spec:
            if not isinstance(spec["pattern"], str) or prop_type != "string":
                _err(errors, f"{prop_path}.pattern", "only string properties may declare a pattern")
            else:
                try:
                    re.compile(spec["pattern"])
                except re.error as exc:
                    _err(errors, f"{prop_path}.pattern", f"invalid regex: {exc}")
                else:
                    # The generated Lua validator must enforce the same rule as
                    # Python. That is only possible for the simple
                    # ``^[chars]{m,n}$`` subset and the bounded
                    # ``^\d{m,n}:\d{m,n}$`` cursor, so anything else is
                    # rejected here rather than silently ignored on the Lua side.
                    if (
                        parse_simple_pattern(spec["pattern"]) is None
                        and parse_segmented_pattern(spec["pattern"]) is None
                    ):
                        _err(
                            errors,
                            f"{prop_path}.pattern",
                            "pattern must be a single char class with {m,n} bounds "
                            "or a bounded digit:digit cursor "
                            "(the Lua validator cannot express other regexes)",
                        )
        if "minimum" in spec and not _is_number(spec["minimum"]):
            _err(errors, f"{prop_path}.minimum", "must be a number")
        if "maximum" in spec and not _is_number(spec["maximum"]):
            _err(errors, f"{prop_path}.maximum", "must be a number")
        if "minLength" in spec and not _is_int(spec["minLength"]):
            _err(errors, f"{prop_path}.minLength", "must be an integer")
        if "maxLength" in spec and not _is_int(spec["maxLength"]):
            _err(errors, f"{prop_path}.maxLength", "must be an integer")
        if "minItems" in spec and not _is_int(spec["minItems"]):
            _err(errors, f"{prop_path}.minItems", "must be an integer")
        if "maxItems" in spec and not _is_int(spec["maxItems"]):
            _err(errors, f"{prop_path}.maxItems", "must be an integer")
        if spec.get("uniqueItems") not in (None, True, False):
            _err(errors, f"{prop_path}.uniqueItems", "must be a boolean")

        if prop_type == "array":
            if not prop_name.endswith("_ids"):
                _err(errors, prop_path, "v1 arrays must be named *_ids")
            max_items = spec.get("maxItems")
            if not _is_int(max_items) or not 1 <= max_items <= 50:
                _err(errors, f"{prop_path}.maxItems", "arrays must declare maxItems in 1..50")
            items = spec.get("items")
            if not isinstance(items, dict) or items.get("type") not in ("string", "integer"):
                _err(errors, f"{prop_path}.items", "must describe string/integer items")
        else:
            if "items" in spec:
                _err(errors, f"{prop_path}.items", "only array properties may declare items")
            if "maxItems" in spec or "minItems" in spec or "uniqueItems" in spec:
                _err(errors, prop_path, "array keywords on a non-array property")

        # Hard limits from §4.
        if prop_name == "citizenid" and spec.get("pattern") != CITIZENID_PATTERN:
            _err(
                errors,
                f"{prop_path}.pattern",
                f"citizenid must use {CITIZENID_PATTERN!r}",
            )
        if prop_name == "idempotency_key" and spec.get("pattern") != IDEMPOTENCY_PATTERN:
            _err(
                errors,
                f"{prop_path}.pattern",
                f"idempotency_key must use {IDEMPOTENCY_PATTERN!r}",
            )
        if tool_name == "send_notify" and prop_name == "text":
            if spec.get("maxLength") != 300:
                _err(errors, f"{prop_path}.maxLength", "notify.text must cap at 300 characters")
        if prop_name == "reason" and isinstance(spec.get("maxLength"), int) and spec["maxLength"] > 128:
            _err(errors, f"{prop_path}.maxLength", "reason must cap at 128 characters")
        if prop_name == "limit":
            maximum = spec.get("maximum")
            if not _is_int(maximum) or not 1 <= maximum <= 200:
                _err(errors, f"{prop_path}.maximum", "limit maximum must be 1..200")
    return props


def _validate_http(
    errors: list[str],
    tool: dict[str, Any],
    path: str,
    channel: Any,
    props: dict[str, Any],
) -> None:
    http = tool.get("http")
    if not isinstance(http, dict):
        _err(errors, f"{path}.http", "must be an object")
        return
    for key in sorted(set(http) - HTTP_KEYS):
        _err(errors, f"{path}.http.{key}", "unknown http field")
    method = http.get("method")
    if method not in ("GET", "POST"):
        _err(errors, f"{path}.http.method", "must be GET or POST")
    route_path = http.get("path")
    if not isinstance(route_path, str) or not route_path.startswith("/agent/v1/"):
        _err(errors, f"{path}.http.path", "must start with /agent/v1/")
        route_path = ""
    external = http.get("external_path")
    if external is not None and not isinstance(external, str):
        _err(errors, f"{path}.http.external_path", "must be a string")
    if channel == "read" and method != "GET":
        _err(errors, f"{path}.http.method", "read tools must use GET")
    if channel in ("write", "effect") and method != "POST":
        _err(errors, f"{path}.http.method", "write/effect tools must use POST")
    for placeholder in re.findall(r"\{([a-z][a-z0-9_]*)\}", route_path):
        if placeholder not in props:
            _err(
                errors,
                f"{path}.http.path",
                f"path placeholder {{{placeholder}}} has no matching argument",
            )
    query = http.get("query")
    if query is not None:
        if not isinstance(query, dict):
            _err(errors, f"{path}.http.query", "must be an object")
        else:
            for arg_name, query_name in query.items():
                if arg_name not in props:
                    _err(
                        errors,
                        f"{path}.http.query.{arg_name}",
                        "query mapping refers to an unknown argument",
                    )
                if not isinstance(query_name, str) or not PARAM_NAME_RE.fullmatch(query_name):
                    _err(
                        errors,
                        f"{path}.http.query.{arg_name}",
                        "query parameter names must match ^[a-z][a-z0-9_]{0,63}$",
                    )


def _validate_rate_limit(
    errors: list[str], tool: dict[str, Any], path: str, channel: Any
) -> None:
    rate = tool.get("rate_limit")
    if rate is None:
        return
    if not isinstance(rate, dict):
        _err(errors, f"{path}.rate_limit", "must be an object")
        return
    for key in sorted(set(rate) - {"per_minute", "burst"}):
        _err(errors, f"{path}.rate_limit.{key}", "unknown rate limit field")
    per_minute = rate.get("per_minute")
    burst = rate.get("burst")
    if not _is_int(per_minute) or not 1 <= per_minute <= 60:
        _err(errors, f"{path}.rate_limit.per_minute", "must be an integer in 1..60")
    if not _is_int(burst) or not 1 <= burst <= 10:
        _err(errors, f"{path}.rate_limit.burst", "must be an integer in 1..10")
    if channel in CHANNEL_RATE_CAP and _is_int(per_minute):
        cap = CHANNEL_RATE_CAP[channel]
        if per_minute > cap:
            _err(
                errors,
                f"{path}.rate_limit.per_minute",
                f"{channel} tools must stay at or below {cap}/min",
            )
    if _is_int(per_minute) and _is_int(burst) and burst > per_minute:
        _err(errors, f"{path}.rate_limit.burst", "burst must not exceed per_minute")


def _validate_limits(errors: list[str], tool: dict[str, Any], path: str) -> None:
    limits = tool.get("limits")
    if limits is not None and not isinstance(limits, dict):
        _err(errors, f"{path}.limits", "must be an object")


def _validate_pii(errors: list[str], tool: dict[str, Any], path: str) -> None:
    pii = tool.get("pii")
    if pii is None:
        return
    if not isinstance(pii, dict):
        _err(errors, f"{path}.pii", "must be an object")
        return
    for key in sorted(set(pii) - {"returns_pii", "untrusted_fields"}):
        _err(errors, f"{path}.pii.{key}", "unknown pii field")
    if not isinstance(pii.get("returns_pii"), bool):
        _err(errors, f"{path}.pii.returns_pii", "must be a boolean")
    fields = pii.get("untrusted_fields")
    if not isinstance(fields, list) or any(not isinstance(item, str) for item in fields):
        _err(errors, f"{path}.pii.untrusted_fields", "must be an array of strings")


def _validate_enum_source(
    errors: list[str], tool: dict[str, Any], path: str, props: dict[str, Any]
) -> None:
    source = tool.get("enum_source")
    if source is None:
        return
    if not isinstance(source, dict):
        _err(errors, f"{path}.enum_source", "must be an object")
        return
    for key in sorted(set(source) - {"param", "source"}):
        _err(errors, f"{path}.enum_source.{key}", "unknown enum_source field")
    param = source.get("param")
    if param not in props:
        _err(errors, f"{path}.enum_source.param", "must name a declared argument")
    _check_str(errors, f"{path}.enum_source.source", source.get("source"), min_length=1, max_length=64)


def _validate_verify(
    errors: list[str], tool: dict[str, Any], path: str, channel: Any
) -> None:
    verify = tool.get("verify")
    if channel == "read":
        if verify is not None:
            _err(errors, f"{path}.verify", "read tools must set verify=null")
        return
    if not isinstance(verify, dict):
        _err(errors, f"{path}.verify", "write/effect tools must declare a verify object")
        return
    for key in sorted(set(verify) - VERIFY_KEYS):
        _err(errors, f"{path}.verify.{key}", "unknown verify field")
    _check_str(errors, f"{path}.verify.tool", verify.get("tool"), min_length=1, max_length=64)
    args = verify.get("args", {})
    if not isinstance(args, dict):
        _err(errors, f"{path}.verify.args", "must be an object")
        args = {}
    for arg_name in args:
        if not isinstance(arg_name, str) or not PARAM_NAME_RE.fullmatch(arg_name):
            _err(errors, f"{path}.verify.args", f"invalid argument name {arg_name!r}")
    assertions = verify.get("assert")
    if not isinstance(assertions, list) or not assertions:
        _err(errors, f"{path}.verify.assert", "must be a non-empty array")
        assertions = []
    for index, assertion in enumerate(assertions):
        assertion_path = f"{path}.verify.assert[{index}]"
        if not isinstance(assertion, dict):
            _err(errors, assertion_path, "must be an object")
            continue
        for key in sorted(set(assertion) - ASSERT_KEYS):
            _err(errors, f"{assertion_path}.{key}", "unknown assertion field")
        _check_str(errors, f"{assertion_path}.field", assertion.get("field"), min_length=1, max_length=64)
        if assertion.get("op") not in VERIFY_OPS:
            _err(errors, f"{assertion_path}.op", f"must be one of {list(VERIFY_OPS)}")
        if "value" not in assertion:
            _err(errors, f"{assertion_path}.value", "is required")
        tolerance = assertion.get("tolerance")
        if tolerance is not None and (not _is_number(tolerance) or tolerance < 0):
            _err(errors, f"{assertion_path}.tolerance", "must be a non-negative number")
    within = verify.get("within_seconds")
    if not _is_int(within) or within <= 0:
        _err(errors, f"{path}.verify.within_seconds", "must be a positive integer")
    if verify.get("on_mismatch") not in ("failed", "rejected"):
        _err(errors, f"{path}.verify.on_mismatch", "must be 'failed' or 'rejected'")


def _validate_undo(
    errors: list[str], tool: dict[str, Any], path: str, channel: Any
) -> None:
    undo = tool.get("undo")
    supported = tool.get("undo_supported")
    if undo is None:
        if supported is True:
            _err(errors, f"{path}.undo_supported", "true requires an undo definition")
        return
    if not isinstance(undo, dict):
        _err(errors, f"{path}.undo", "must be an object or null")
        return
    if supported is not True:
        _err(errors, f"{path}.undo_supported", "must be true when undo is declared")
    for key in sorted(set(undo) - UNDO_KEYS):
        _err(errors, f"{path}.undo.{key}", "unknown undo field")
    _check_str(errors, f"{path}.undo.tool", undo.get("tool"), min_length=1, max_length=64)
    args = undo.get("args")
    if not isinstance(args, dict):
        _err(errors, f"{path}.undo.args", "must be an object")
    window = undo.get("window_seconds")
    if not _is_int(window) or window <= 0:
        _err(errors, f"{path}.undo.window_seconds", "must be a positive integer")
    if channel == "read":
        _err(errors, f"{path}.undo", "read tools cannot declare undo")


def _validate_deprecated(
    errors: list[str],
    tool: dict[str, Any],
    path: str,
    status: Any,
    by_name: dict[str, Any] | None,
) -> None:
    deprecated = tool.get("deprecated")
    if status == "deprecated":
        if not isinstance(deprecated, dict):
            _err(errors, f"{path}.deprecated", "deprecated tools must declare a deprecated block")
            return
        if "SUNSET" not in str(tool.get("description", "")):
            _err(errors, f"{path}.description", "deprecated tools must mention SUNSET")
        _check_str(errors, f"{path}.deprecated.since", deprecated.get("since"), min_length=1, max_length=20)
        _check_str(errors, f"{path}.deprecated.sunset", deprecated.get("sunset"), min_length=1, max_length=20)
        if by_name is not None:
            replaced = deprecated.get("replaced_by")
            if replaced is not None and replaced not in by_name:
                _err(errors, f"{path}.deprecated.replaced_by", "must name an existing tool")
    elif deprecated is not None:
        _err(errors, f"{path}.deprecated", "only deprecated tools may declare this block")


def _validate_references(
    errors: list[str],
    tool: dict[str, Any],
    by_name: dict[str, dict[str, Any]],
    index: int,
) -> None:
    path = f"registry.tools[{index}]"
    own_props = set()
    schema = tool.get("inputSchema")
    if isinstance(schema, dict) and isinstance(schema.get("properties"), dict):
        own_props = set(schema["properties"])

    verify = tool.get("verify")
    if isinstance(verify, dict):
        target_name = verify.get("tool")
        target = by_name.get(target_name) if isinstance(target_name, str) else None
        if target is None:
            _err(errors, f"{path}.verify.tool", f"unknown verify tool {target_name!r}")
        elif target.get("channel") != "read":
            _err(errors, f"{path}.verify.tool", "verify must reference a read tool")
        else:
            target_props = set(
                (target.get("inputSchema") or {}).get("properties") or {}
            )
            args = verify.get("args") or {}
            if isinstance(args, dict):
                for arg_name, value in args.items():
                    if arg_name not in target_props:
                        _err(
                            errors,
                            f"{path}.verify.args.{arg_name}",
                            f"{target_name!r} has no such argument",
                        )
                    _check_reference(errors, f"{path}.verify.args.{arg_name}", value, own_props)
            for assert_index, assertion in enumerate(verify.get("assert") or []):
                if not isinstance(assertion, dict):
                    continue
                field = assertion.get("field")
                if isinstance(field, str) and field.startswith("$"):
                    ref = field[1:]
                    if ref not in own_props and ref not in BUILTIN_REF_NAMES:
                        _err(
                            errors,
                            f"{path}.verify.assert[{assert_index}].field",
                            f"unknown reference ${ref}",
                        )
                value = assertion.get("value")
                _check_reference(
                    errors, f"{path}.verify.assert[{assert_index}].value", value, own_props
                )

    undo = tool.get("undo")
    if isinstance(undo, dict):
        target_name = undo.get("tool")
        target = by_name.get(target_name) if isinstance(target_name, str) else None
        if target is None:
            _err(errors, f"{path}.undo.tool", f"unknown undo tool {target_name!r}")
        else:
            if target.get("undo_supported") is not True:
                _err(errors, f"{path}.undo.tool", "undo target must declare undo_supported=true")
            own_risk = RISK_ORDER.get(str(tool.get("risk")), 99)
            target_risk = RISK_ORDER.get(str(target.get("risk")), 99)
            if target_risk > own_risk:
                _err(errors, f"{path}.undo.tool", "undo target risk must be <= this tool's risk")
            target_props = set((target.get("inputSchema") or {}).get("properties") or {})
            args = undo.get("args")
            if isinstance(args, dict):
                for arg_name, value in args.items():
                    if arg_name not in target_props:
                        _err(
                            errors,
                            f"{path}.undo.args.{arg_name}",
                            f"{target_name!r} has no such argument",
                        )
                    if isinstance(value, str) and value.startswith("$before."):
                        field_name = value[len("$before.") :]
                        if not PARAM_NAME_RE.fullmatch(field_name):
                            _err(
                                errors,
                                f"{path}.undo.args.{arg_name}",
                                "invalid $before reference",
                            )
                    else:
                        _check_reference(errors, f"{path}.undo.args.{arg_name}", value, own_props)


def _check_reference(
    errors: list[str], path: str, value: Any, own_props: set[str]
) -> None:
    if not isinstance(value, str) or not value.startswith("$"):
        return
    if value == "$before" or value.startswith("$before."):
        _err(errors, path, "$before references are only valid in undo args")
        return
    ref = value[1:]
    if ref not in own_props and ref not in BUILTIN_REF_NAMES:
        _err(errors, path, f"unknown reference ${ref}")


# ---------------------------------------------------------------------------
# Argument validation (shared by the MCP facade)
# ---------------------------------------------------------------------------
def validate_arguments(tool: dict[str, Any] | str, args: Any) -> list[str]:
    """Validate ``args`` against a registry tool's ``inputSchema``.

    ``tool`` may be a registry tool object or a tool name.  Returns a list of
    human-readable violations (empty means valid).  Never coerces or mutates
    the caller's arguments.
    """
    if isinstance(tool, str):
        for candidate in load_registry().get("tools", []):
            if candidate.get("name") == tool:
                tool = candidate
                break
        else:
            return [f"unknown tool: {tool}"]
    if not isinstance(tool, dict):
        return ["tool must be a registry object"]
    schema = tool.get("inputSchema")
    if not isinstance(schema, dict):
        return ["tool has no inputSchema"]
    if not isinstance(args, dict):
        return ["arguments must be an object"]
    props = schema.get("properties") or {}
    errors: list[str] = []
    if any(not isinstance(key, str) for key in args):
        return ["argument names must be strings"]

    unknown = sorted(set(args) - set(props))
    if unknown:
        errors.append("unknown argument(s): " + ", ".join(str(item) for item in unknown))
    for name in schema.get("required", []):
        if name not in args or args[name] is None:
            errors.append(f"{name} is required")
    for name, value in args.items():
        if name not in props or value is None:
            continue
        spec = props[name]
        if not isinstance(spec, dict):
            continue
        expected = spec.get("type")
        if not _type_matches(expected, value):
            errors.append(f"{name} must be {expected}")
            continue
        if "enum" in spec and value not in spec["enum"]:
            errors.append(f"{name} must be one of {spec['enum']}")
        if expected == "string":
            length = len(value)
            if "minLength" in spec and length < spec["minLength"]:
                errors.append(f"{name} must be at least {spec['minLength']} characters")
            if "maxLength" in spec and length > spec["maxLength"]:
                errors.append(f"{name} must be at most {spec['maxLength']} characters")
            if "pattern" in spec and not re.fullmatch(spec["pattern"], value):
                errors.append(f"{name} has invalid characters")
        if expected in ("integer", "number"):
            if "minimum" in spec and value < spec["minimum"]:
                errors.append(f"{name} must be >= {spec['minimum']}")
            if "maximum" in spec and value > spec["maximum"]:
                errors.append(f"{name} must be <= {spec['maximum']}")
    return errors


def _type_matches(expected: Any, value: Any) -> bool:
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return _is_int(value)
    if expected == "number":
        return _is_number(value)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "array":
        return isinstance(value, list)
    return True


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
GENERATED_MARKER = "@generated by tools/agent_tools.py from tools/agent_tools.json; DO NOT EDIT."


def _md_cell(value: Any) -> str:
    text = "" if value is None else str(value)
    return text.replace("|", "\\|").replace("\n", " ")


def _tool_rows(registry: dict[str, Any]) -> Iterable[dict[str, Any]]:
    for tool in registry.get("tools", []):
        if isinstance(tool, dict):
            yield tool


def render_tools_md(registry: dict[str, Any] | None = None) -> str:
    if registry is None:
        registry = load_registry()
    tools = list(_tool_rows(registry))
    active = [tool for tool in tools if tool.get("status") == "active"]
    planned = [tool for tool in tools if tool.get("status") == "planned"]
    deprecated = [tool for tool in tools if tool.get("status") == "deprecated"]

    lines: list[str] = [
        f"<!-- {GENERATED_MARKER} -->",
        "# T-City Agent Tool Surface (v1)",
        "",
        "**Generated file — DO NOT EDIT.** "
        f"Source: `tools/agent_tools.json` (registry_version "
        f"`{registry.get('registry_version', '?')}`, schema_version "
        f"`{registry.get('schema_version', '?')}`).",
        "",
        f"{len(tools)} tools: {len(active)} active, {len(planned)} planned, "
        f"{len(deprecated)} deprecated. Only `active` tools are advertised to agents.",
        "",
        "## Routing table",
        "",
        "| # | Tool | Status | Channel | Route | Auth | HTTP | Risk | Approval | Idempotency | Dry run | Verify | Undo |",
        "|---:|:---|:---|:---|:---|:---|:---|:---|:---:|:---|:---|:---|:---|",
    ]
    for index, tool in enumerate(tools, start=1):
        http = tool.get("http") or {}
        route_text = f"{http.get('method', '?')} `{http.get('path', '?')}`"
        verify = tool.get("verify")
        undo = tool.get("undo")
        lines.append(
            "| {index} | `{name}` | {status} | {channel} | {route} | {auth} | {http} | {risk} | "
            "{approval} | {idempotency} | {dry_run} | {verify} | {undo} |".format(
                index=index,
                name=_md_cell(tool.get("name")),
                status=_md_cell(tool.get("status")),
                channel=_md_cell(tool.get("channel")),
                route=_md_cell(tool.get("route")),
                auth=_md_cell(tool.get("auth", "default")),
                http=_md_cell(route_text),
                risk=_md_cell(tool.get("risk")),
                approval="yes" if tool.get("requires_approval") else "no",
                idempotency=_md_cell(tool.get("idempotency")),
                dry_run=_md_cell(tool.get("dry_run")),
                verify=_md_cell(verify.get("tool") if isinstance(verify, dict) else "—"),
                undo=_md_cell(undo.get("tool") if isinstance(undo, dict) else "—"),
            )
        )

    lines.extend(
        [
            "",
            "## Risk and approval table",
            "",
            "| Tool | Risk | Blast radius | Requires approval | Compensation | Rate limit |",
            "|:---|:---|:---|:---:|:---|:---|",
        ]
    )
    for tool in tools:
        rate = tool.get("rate_limit") or {}
        rate_text = (
            f"{rate.get('per_minute')}/min burst {rate.get('burst')}"
            if rate
            else "—"
        )
        lines.append(
            "| `{name}` | {risk} | {blast} | {approval} | {compensation} | {rate} |".format(
                name=_md_cell(tool.get("name")),
                risk=_md_cell(tool.get("risk")),
                blast=_md_cell(tool.get("blast_radius")),
                approval="yes" if tool.get("requires_approval") else "no",
                compensation=_md_cell(tool.get("compensation")),
                rate=_md_cell(rate_text),
            )
        )

    lines.extend(
        [
            "",
            "## Contract notes",
            "",
            "- `L0` ⇔ channel `read`; `effect` tools are `L3`/`L4`; `L3`/`L4` always require approval.",
            "- Read tools use `idempotency=none` and `dry_run=not_applicable`; write/effect tools "
            "require an idempotency key (derived by the facade when omitted) and support dry-run.",
            "- `verify` always references an existing read tool; `undo` (when present) references an "
            "existing tool with `undo_supported=true` and risk no higher than the caller.",
            "- `L4` compensation is always `manual`: money and permanent assets are never silently rolled back.",
            "- Regenerate with `python3 tools/agent_tools.py --write`; CI runs `--check` and fails on drift.",
            "",
        ]
    )
    return "\n".join(lines)


def _lua_string(value: str) -> str:
    out = ['"']
    for char in value:
        if char == "\\":
            out.append("\\\\")
        elif char == '"':
            out.append('\\"')
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif char == "\t":
            out.append("\\t")
        elif ord(char) < 32 or ord(char) == 127:
            out.append(f"\\x{ord(char):02x}")
        else:
            out.append(char)
    out.append('"')
    return "".join(out)


def _lua_literal(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return _lua_string(value)
    if value is None:
        return "nil"
    raise TypeError(f"cannot render {type(value).__name__} as a Lua literal")


def _lua_string_list(values: Iterable[str]) -> str:
    rendered = ", ".join(_lua_string(value) for value in values)
    return "{ " + rendered + " }" if rendered else "{ }"


def render_lua(registry: dict[str, Any] | None = None) -> str:
    if registry is None:
        registry = load_registry()
    tools = list(_tool_rows(registry))
    lines: list[str] = [
        f"-- {GENERATED_MARKER}",
        "-- Read-only mirror of the Python tool contract for Lua consumers.",
        "-- It deliberately does not enforce policy; server/policy.lua remains authoritative.",
        "",
        "local AgentTools = {}",
        "",
        f"AgentTools.SCHEMA_VERSION = {int(registry.get('schema_version', SCHEMA_VERSION))}",
        f"AgentTools.REGISTRY_VERSION = {_lua_string(str(registry.get('registry_version', '')))}",
        "",
        "AgentTools.TOOLS = {",
    ]
    for tool in tools:
        schema = tool.get("inputSchema") or {}
        props = schema.get("properties") or {}
        required = schema.get("required") or []
        name = str(tool.get("name", ""))
        lines.append(f"  [{_lua_string(name)}] = {{")
        for field in (
            "name",
            "title",
            "channel",
            "route",
            "risk",
            "blast_radius",
            "status",
            "idempotency",
            "dry_run",
        ):
            lines.append(f"    {field} = {_lua_string(str(tool.get(field, '')))},")
        lines.append(
            f"    requires_approval = {_lua_literal(bool(tool.get('requires_approval')))},"
        )
        lines.append(
            f"    undo_supported = {_lua_literal(bool(tool.get('undo_supported')))},"
        )
        director_action = tool.get("director_action")
        if isinstance(director_action, str):
            lines.append(f"    director_action = {_lua_string(director_action)},")
        else:
            lines.append("    director_action = false,")
        lines.extend(
            [
                f"    auth = {_lua_string(str(tool.get('auth', 'default')))},",
                f"    params = {_lua_string_list(props.keys())},",
                f"    required = {_lua_string_list(required)},",
            ]
        )
        if props:
            lines.append("    schema = {")
            for prop_name, spec in props.items():
                rule = [f'type = {_lua_string(str(spec.get("type", "")))}']
                effective = dict(spec)
                if "enum" in spec:
                    rule.append(f"enum = {_lua_string_list([str(item) for item in spec['enum']])}")
                if isinstance(spec.get("pattern"), str):
                    parsed = parse_simple_pattern(spec["pattern"])
                    if parsed is not None:
                        chars, pattern_min, pattern_max = parsed
                        effective.setdefault("minLength", pattern_min)
                        effective.setdefault("maxLength", pattern_max)
                        rule.append(f"chars = {_lua_string(chars)}")
                    else:
                        segments = parse_segmented_pattern(spec["pattern"])
                        if segments is None:
                            raise ValueError(
                                f"{tool.get('name')}.{prop_name}: pattern is not Lua-validatable"
                            )
                        rendered = []
                        for chars, pattern_min, pattern_max, literal in segments:
                            if literal:
                                rendered.append(
                                    "{ literal = true, chars = "
                                    f"{_lua_string(chars)} }}"
                                )
                            else:
                                rendered.append(
                                    "{ chars = "
                                    f"{_lua_string(chars)}, min_length = {pattern_min}, "
                                    f"max_length = {pattern_max} }}"
                                )
                        rule.append("segments = { " + ", ".join(rendered) + " }")
                for keyword, lua_key in (
                    ("minimum", "minimum"),
                    ("maximum", "maximum"),
                    ("minLength", "min_length"),
                    ("maxLength", "max_length"),
                    ("maxItems", "max_items"),
                ):
                    if keyword in effective and isinstance(effective[keyword], (int, float)):
                        rule.append(f"{lua_key} = {_lua_literal(effective[keyword])}")
                lines.append(
                    f"      [{_lua_string(str(prop_name))}] = {{ "
                    + ", ".join(rule)
                    + " },"
                )
            lines.append("    },")
        else:
            lines.append("    schema = {},")
        lines.append("  },")
    lines.extend(
        [
            "}",
            "",
            "function AgentTools.get(name)",
            "  if type(name) ~= 'string' then return nil end",
            "  return AgentTools.TOOLS[name]",
            "end",
            "",
            "local function typeMatches(expected, value)",
            "  if expected == 'string' then return type(value) == 'string' end",
            "  if expected == 'integer' then",
            "    return type(value) == 'number' and value % 1 == 0",
            "  end",
            "  if expected == 'number' then return type(value) == 'number' end",
            "  if expected == 'boolean' then return type(value) == 'boolean' end",
            "  if expected == 'array' then return type(value) == 'table' end",
            "  return true",
            "end",
            "",
            "local function segmentsMatch(segments, value)",
            "  local pos = 1",
            "  for index = 1, #segments do",
            "    local segment = segments[index]",
            "    if segment.literal then",
            "      if value:sub(pos, pos) ~= segment.chars then return false end",
            "      pos = pos + 1",
            "    else",
            "      local stop",
            "      local next_segment = segments[index + 1]",
            "      if next_segment and next_segment.literal then",
            "        stop = string.find(value, next_segment.chars, pos, true)",
            "      else",
            "        stop = #value + 1",
            "      end",
            "      if not stop then return false end",
            "      local length = stop - pos",
            "      if length < segment.min_length or length > segment.max_length then",
            "        return false",
            "      end",
            "      for i = pos, stop - 1 do",
            "        local char = value:sub(i, i)",
            "        if not string.find(segment.chars, char, 1, true) then",
            "          return false",
            "        end",
            "      end",
            "      pos = stop",
            "    end",
            "  end",
            "  return pos == #value + 1",
            "end",
            "",
            "--- Minimal contract validation.  Returns true, nil or false, code.",
            "function AgentTools.validate(name, args)",
            "  local tool = AgentTools.get(name)",
            "  if not tool then return false, 'unsupported_tool' end",
            "  if type(args) ~= 'table' then return false, 'invalid_params' end",
            "  for key in pairs(args) do",
            "    if tool.schema[key] == nil then return false, 'invalid_params' end",
            "  end",
            "  for _, key in ipairs(tool.required) do",
            "    if args[key] == nil then return false, 'invalid_params' end",
            "  end",
            "  for key, rule in pairs(tool.schema) do",
            "    local value = args[key]",
            "    if value ~= nil then",
            "      if not typeMatches(rule.type, value) then",
            "        return false, 'invalid_params'",
            "      end",
            "      if rule.enum then",
            "        local matched = false",
            "        for _, allowed in ipairs(rule.enum) do",
            "          if value == allowed then matched = true break end",
            "        end",
            "        if not matched then return false, 'invalid_params' end",
            "      end",
            "      if rule.minimum ~= nil and value < rule.minimum then",
            "        return false, 'invalid_params'",
            "      end",
            "      if rule.maximum ~= nil and value > rule.maximum then",
            "        return false, 'invalid_params'",
            "      end",
            "      if rule.min_length ~= nil and #value < rule.min_length then",
            "        return false, 'invalid_params'",
            "      end",
            "      if rule.max_length ~= nil and #value > rule.max_length then",
            "        return false, 'invalid_params'",
            "      end",
            "      if rule.chars then",
            "        for i = 1, #value do",
            "          local char = value:sub(i, i)",
            "          if not string.find(rule.chars, char, 1, true) then",
            "            return false, 'invalid_params'",
            "          end",
            "        end",
            "      end",
            "      if rule.segments and not segmentsMatch(rule.segments, value) then",
            "        return false, 'invalid_params'",
            "      end",
            "    end",
            "  end",
            "  return true, nil",
            "end",
            "",
            "-- FiveM loads script files for their side effects; expose the table",
            "-- so server/policy.lua can read it without a require() shim.",
            "_G.AgentTools = AgentTools",
            "",
            "return AgentTools",
            "",
        ]
    )
    return "\n".join(lines)


def render_all(registry: dict[str, Any] | None = None) -> dict[Path, str]:
    if registry is None:
        registry = load_registry()
    return {
        TOOLS_MD_PATH: render_tools_md(registry),
        LUA_PATH: render_lua(registry),
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _write_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    tmp.replace(path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate tools/agent_tools.json and render its generated mirrors."
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true", help="fail if generated files drift")
    group.add_argument("--write", action="store_true", help="validate and regenerate both files")
    args = parser.parse_args(argv)

    try:
        registry = load_registry()
    except RegistryError as exc:
        print(f"agent_tools: {exc}", file=sys.stderr)
        return 1

    outputs = render_all(registry)
    drift: list[str] = []
    if args.check:
        for path, expected in outputs.items():
            try:
                actual = path.read_text(encoding="utf-8")
            except OSError as exc:
                drift.append(f"{path}: cannot read generated file ({exc})")
                continue
            if actual != expected:
                drift.append(f"{path}: generated file is stale (run --write)")
        if drift:
            for line in drift:
                print(f"agent_tools: {line}", file=sys.stderr)
            return 1
        print(
            f"agent_tools: OK ({len(registry['tools'])} tools, "
            f"{len(outputs)} generated files match)"
        )
        return 0

    for path, content in outputs.items():
        _write_atomic(path, content)
        try:
            display = path.relative_to(REPO_ROOT)
        except ValueError:
            display = path
        print(f"agent_tools: wrote {display}")
    active = sum(1 for tool in registry["tools"] if tool.get("status") == "active")
    print(
        f"agent_tools: {len(registry['tools'])} tools validated "
        f"({active} active, {len(registry['tools']) - active} not active)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
