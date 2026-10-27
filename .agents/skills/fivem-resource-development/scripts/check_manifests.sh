#!/usr/bin/env bash
# Parse every fxmanifest.lua under a FiveM server tree.
#
# Why: a manifest is Lua, and `restart <resource>` does NOT re-parse it — the server reuses the
# resource metadata it read at boot. So a manifest broken by a missing comma (the classic: an
# entry inserted after the previous last one, which had no trailing comma) reports success on
# restart and only explodes at the next `refresh` or full boot, as "N resources failed to load".
# Because `dependencies` is a hard start barrier, a broken *core* manifest takes every dependent
# down with it and the half-empty resource list reads like a server crash.
#
# Usage:
#   scripts/check_manifests.sh [resources-dir]      # default: ./resources
#
# Exit: 0 all parse, 1 at least one is invalid, 2 tooling missing.
set -uo pipefail

ROOT="${1:-resources}"
if [ ! -d "$ROOT" ]; then
    echo "no such directory: $ROOT" >&2
    exit 2
fi

if command -v luac5.4 >/dev/null 2>&1; then
    CHECK=(luac5.4 -p)
elif command -v lua5.4 >/dev/null 2>&1; then
    # Fallback: load without executing.
    CHECK=(lua5.4 -e 'assert(loadfile(arg[1]))' --)
elif command -v luac >/dev/null 2>&1; then
    CHECK=(luac -p)
else
    echo "need luac5.4 / lua5.4 / luac to parse manifests" >&2
    exit 2
fi

bad=0
total=0
while IFS= read -r -d '' manifest; do
    total=$((total + 1))
    if ! out=$("${CHECK[@]}" "$manifest" 2>&1); then
        printf 'INVALID  %s\n' "$manifest"
        printf '         %s\n' "$(printf '%s' "$out" | head -1)"
        bad=$((bad + 1))
    fi
done < <(find "$ROOT" -name fxmanifest.lua -not -path '*/node_modules/*' -print0)

if [ "$bad" -eq 0 ]; then
    printf 'ok: %d manifests parse\n' "$total"
    exit 0
fi
printf '\n%d of %d manifests are invalid Lua\n' "$bad" "$total" >&2
exit 1
