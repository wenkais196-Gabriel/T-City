#!/usr/bin/env python3
"""Shared response/identity contract for the T-City agent surfaces (design 03 §5).

Pure functions only: no filesystem, network, environment or database access.
``tools/agent_gateway.py`` and ``tools/agent_mcp.py`` both import this module so
the wire contract cannot drift between the HTTP and MCP facades.

Wire compatibility rules (non-negotiable):

* ``schema_version``, ``data``, ``next_cursor`` and ``meta`` keep their v1
  shape; new fields are only *added*.
* ``error`` and ``code`` stay strings.  The canonical class lives in the new
  ``kind`` field so old clients never see a changed ``code`` value.
* ``CODE_TO_KIND`` is append-only: a code is never remapped.
"""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any, Iterable

SCHEMA_VERSION = 1

# Canonical error classes from design 03 §5.2, in table order.
KINDS: tuple[str, ...] = (
    "ok",
    "approval_required",
    "idempotent_replay",
    "invalid_argument",
    "unauthorized",
    "not_found",
    "target_offline",
    "target_unavailable",
    "policy_denied",
    "rate_limited",
    "timeout",
    "upstream_unavailable",
    "execution_failed",
    "partial_success",
    "internal_error",
)

# Legacy `code` -> canonical `kind`.  Append only; never reuse a code.
CODE_TO_KIND: dict[str, str] = {
    # invalid_argument
    "bad_request": "invalid_argument",
    "invalid_params": "invalid_argument",
    "invalid_account": "invalid_argument",
    "unsupported_action": "invalid_argument",
    "text_too_long": "invalid_argument",
    "money_cap_exceeded": "invalid_argument",
    "daily_budget_exceeded": "invalid_argument",
    "body_too_large": "invalid_argument",
    "idempotency_key_required": "invalid_argument",
    "idempotency_conflict": "invalid_argument",
    "missing_body": "invalid_argument",
    "invalid_cursor": "invalid_argument",
    "cursor_epoch_mismatch": "invalid_argument",
    "plate_mismatch": "invalid_argument",
    "method_not_allowed": "invalid_argument",
    # unauthorized
    "unauthorized": "unauthorized",
    "forbidden": "unauthorized",
    "missing_agent_id": "unauthorized",
    "agent_token_not_configured": "unauthorized",
    "live_token_not_configured": "unauthorized",
    "admin_token_not_configured": "unauthorized",
    # not_found
    "not_found": "not_found",
    "quest_not_found": "not_found",
    "job_not_found": "not_found",
    "grade_not_found": "not_found",
    "item_not_found": "not_found",
    "model_not_found": "not_found",
    # target_offline
    "player_not_found": "target_offline",
    # target_unavailable
    "account_unavailable": "target_unavailable",
    "job_unavailable": "target_unavailable",
    "not_in_vehicle": "target_unavailable",
    # policy_denied
    "disabled": "policy_denied",
    "invalid_status": "policy_denied",
    "expired": "policy_denied",
    "unsupported_tool": "policy_denied",
    "cursor_expired": "policy_denied",
    "live_disabled": "policy_denied",
    # rate_limited
    "rate_limited": "rate_limited",
    # timeout
    "gateway_timeout": "timeout",
    "director_timeout": "timeout",
    "write_outcome_unknown": "timeout",
    # upstream_unavailable
    "db_error": "upstream_unavailable",
    "database_error": "upstream_unavailable",
    "database_unavailable": "upstream_unavailable",
    "schema_unavailable": "upstream_unavailable",
    "quest_catalog_unavailable": "upstream_unavailable",
    "circuit_open": "upstream_unavailable",
    "gateway_unreachable": "upstream_unavailable",
    "director_unreachable": "upstream_unavailable",
    "executor_unavailable": "upstream_unavailable",
    "weather_sync_unavailable": "upstream_unavailable",
    "registry_unavailable": "upstream_unavailable",
    # execution_failed
    "execution_failed": "execution_failed",
    "trigger_quest_failed": "execution_failed",
    "verification_failed": "execution_failed",
    "not_yieldable": "execution_failed",
    # partial_success
    "partial_success": "partial_success",
    # internal_error
    "internal_error": "internal_error",
    "agent_data_error": "internal_error",
}

# Default retryability per canonical kind; per-code overrides below.
_KIND_RETRYABLE: dict[str, bool] = {
    "ok": False,
    "approval_required": False,
    "idempotent_replay": False,
    "invalid_argument": False,
    "unauthorized": False,
    "not_found": False,
    "target_offline": True,
    "target_unavailable": False,
    "policy_denied": False,
    "rate_limited": True,
    "timeout": False,
    "upstream_unavailable": True,
    "execution_failed": False,
    "partial_success": False,
    "internal_error": True,
}

# Per-code overrides: timeouts depend on the code, and an unknown code must not
# cause the facade to hammer an upstream.
_CODE_RETRYABLE: dict[str, bool] = {
    "player_not_found": True,
    "rate_limited": True,
    "gateway_timeout": True,
    "director_timeout": True,
    "write_outcome_unknown": False,
    "db_error": True,
    "database_error": True,
    "database_unavailable": True,
    "schema_unavailable": True,
    "quest_catalog_unavailable": True,
    "circuit_open": True,
    "gateway_unreachable": True,
    "director_unreachable": True,
    "registry_unavailable": True,
    "internal_error": True,
    "agent_data_error": True,
}

_ZERO_WIDTH_AND_BIDI = frozenset(
    [chr(codepoint) for codepoint in range(0x200B, 0x2010)]
    + [chr(codepoint) for codepoint in range(0x202A, 0x202F)]
    + [chr(codepoint) for codepoint in range(0x2066, 0x206A)]
)
_AGENT_ID_SAFE_RE = re.compile(r"[^A-Za-z0-9_.:-]")
_WHITESPACE_RUN_RE = re.compile(r"[^\S\n]+")
_MULTI_NEWLINE_RE = re.compile(r"\n{3,}")


def classify(code: Any) -> tuple[str, bool]:
    """Map a legacy ``code`` to ``(kind, retryable)``.

    Unknown codes degrade to ``internal_error`` and are *not* retryable: an
    unrecognised failure should be investigated, not retried in a loop.
    """
    if code is None:
        return "internal_error", False
    key = str(code)
    kind = CODE_TO_KIND.get(key)
    if kind is None:
        return "internal_error", False
    return kind, _CODE_RETRYABLE.get(key, _KIND_RETRYABLE[kind])


def _meta(
    tool: str,
    meta: dict[str, Any] | None,
    request_id: str | None,
    extra: dict[str, Any],
) -> dict[str, Any]:
    merged: dict[str, Any] = dict(meta or {})
    merged.setdefault("tool", tool)
    merged.setdefault("contract", SCHEMA_VERSION)
    if request_id is not None:
        merged.setdefault("request_id", request_id)
    for key, value in extra.items():
        if value is not None:
            merged.setdefault(key, value)
    return merged


def envelope_ok(
    tool: str,
    data: Any,
    *,
    kind: str = "ok",
    next_cursor: Any = None,
    warnings: Iterable[str] | None = None,
    meta: dict[str, Any] | None = None,
    request_id: str | None = None,
    **extra: Any,
) -> dict[str, Any]:
    """Build a successful v1 envelope with the additive fields from §5.1."""
    if kind not in KINDS:
        raise ValueError(f"unknown envelope kind: {kind!r}")
    payload: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "ok": True,
        "kind": kind,
        "data": data,
    }
    if next_cursor is not None:
        payload["next_cursor"] = next_cursor
    payload["warnings"] = list(warnings or [])
    payload["meta"] = _meta(tool, meta, request_id, extra)
    return payload


def envelope_error(
    tool: str,
    code: str,
    message: str,
    *,
    kind: str | None = None,
    retryable: bool | None = None,
    data: Any = None,
    meta: dict[str, Any] | None = None,
    request_id: str | None = None,
    **extra: Any,
) -> dict[str, Any]:
    """Build a failed envelope; ``error``/``code`` remain strings (§5.2)."""
    resolved_kind, resolved_retryable = classify(code)
    if kind is not None:
        if kind not in KINDS:
            raise ValueError(f"unknown envelope kind: {kind!r}")
        resolved_kind = kind
    if retryable is not None:
        resolved_retryable = bool(retryable)
    return {
        "schema_version": SCHEMA_VERSION,
        "ok": False,
        "kind": resolved_kind,
        "data": data,
        "error": str(message),
        "code": str(code),
        "retryable": resolved_retryable,
        "meta": _meta(tool, meta, request_id, extra),
    }


def _canonical_args(args: dict[str, Any]) -> str:
    stripped = {key: value for key, value in args.items() if key != "idempotency_key"}
    return json.dumps(
        stripped,
        sort_keys=True,
        ensure_ascii=False,
        separators=(",", ":"),
        default=str,
    )


def derive_idempotency_key(
    tool: str,
    args: dict[str, Any],
    agent_id: str,
    *,
    dry_run: bool = False,
) -> str:
    """Derive a stable write key: ``mcp/<agent>/<tool>/<sha256(args)[:16]>[/dry]``.

    The explicit ``idempotency_key`` argument (if any) is excluded so a caller
    cannot make the derived key depend on itself.
    """
    safe_agent = _AGENT_ID_SAFE_RE.sub("_", str(agent_id or ""))[:64] or "mcp.local"
    safe_tool = _AGENT_ID_SAFE_RE.sub("_", str(tool or "unknown"))[:48] or "unknown"
    digest = hashlib.sha256(_canonical_args(dict(args or {})).encode("utf-8")).hexdigest()[:16]
    key = f"mcp/{safe_agent}/{safe_tool}/{digest}"
    if dry_run:
        key += "/dry"
    return key[:128]


def sanitize_untrusted(text: Any, max_chars: int = 200) -> tuple[str, bool]:
    """Neutralise player/database text before it enters a model context.

    Removes C0 controls (except ``\\n``/``\\t``), zero-width and bidi control
    characters, folds whitespace, caps blank runs at two newlines and truncates
    to ``max_chars``.  Returns ``(clean_text, truncated)``.
    """
    if text is None:
        return "", False
    if not isinstance(text, str):
        text = str(text)
    if not isinstance(max_chars, int) or isinstance(max_chars, bool):
        raise TypeError("max_chars must be an integer")
    if max_chars < 0:
        max_chars = 0

    kept: list[str] = []
    for char in text:
        codepoint = ord(char)
        if char in _ZERO_WIDTH_AND_BIDI:
            continue
        if (codepoint < 32 and char not in ("\n", "\t")) or codepoint == 127:
            continue
        kept.append(char)
    cleaned = "".join(kept)
    lines = [
        _WHITESPACE_RUN_RE.sub(" ", line).strip()
        for line in cleaned.split("\n")
    ]
    cleaned = _MULTI_NEWLINE_RE.sub("\n\n", "\n".join(lines)).strip()
    truncated = len(cleaned) > max_chars
    if truncated:
        cleaned = cleaned[:max_chars].rstrip()
    return cleaned, truncated
