"""FIT-03 — every net event must be authenticated or explicitly registered.

Static, offline contract (no FXServer, no DB, no network):

* scan ``custom-police/server/**/*.lua`` and ``custom-phone/server/**/*.lua``;
* for every ``RegisterNetEvent('name', function ... end)`` extract the handler
  body up to the first top-level ``end)`` (this repo's indentation style);
* the body must contain a unified auth decision: ``PolicePolicy.Can``,
  ``PolicePolicy.Check``, ``hasCapability``, ``IsPlayerAceAllowed``, a
  system-source guard (``src == 0`` / ``src ~= 0 then return``) or one of the
  project helpers listed in ``AUTH_HELPERS`` (each helper is checked to really
  call ``PolicePolicy.Can`` below, so the indirection cannot rot);
* otherwise the event must be registered in ``net_events_allowlist.json`` with
  name / category / reason / owner / expires, and the category's claim must be
  visible in the handler body (a manual ``job.type`` check really exists, a
  civilian path really validates, a session path really binds to the caller).

Anything else fails, so a new unguarded net event cannot land silently.

    python3 -m pytest -q tests/architecture/test_net_event_auth.py
"""
from __future__ import annotations

import json
import re
from datetime import date
from pathlib import Path

from net_event_scan import (
    Event,
    auth_tokens as scan_auth_tokens,
    guard_helpers,
    helper_call_problems,
    is_client_path,
    is_guarded,
    non_literal_in_dir,
    read,
    scan_dir,
    strip_lua_noise,
)

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
RESOURCES = BASE / "resources"
CUSTOM = RESOURCES / "[custom]"
DIAG_MODULE = CUSTOM / "custom-phone" / "server" / "core" / "diag.lua"
SCAN_DIRS = (
    ("custom-police", CUSTOM / "custom-police" / "server"),
    ("custom-phone", CUSTOM / "custom-phone" / "server"),
    # 2026-10-25: 框架自己也有 net event（客户端诊断通道等），之前完全没被扫过
    ("core-framework", BASE / "resources" / "[standalone]" / "core-framework" / "server"),
    # P1-3 批次①：引擎层 100%。qb-core 的 15 个服务端 net event 之前不在任何闸门里
    ("qb-core", BASE / "resources" / "[qb]" / "qb-core" / "server"),
)
ALLOWLIST = Path(__file__).with_name("net_events_allowlist.json")

# `RegisterNetEvent('x', function ...)` 的解析统一在 net_event_scan 里（唯一实现），
# 这里只保留"这段 handler 里有没有鉴权证据"的项目级 helper 名单。


# Project helpers that wrap PolicePolicy.Can. Verified in
# test_auth_helpers_really_enforce_policypolicy so the allowlist cannot hide a
# helper that stopped checking.
AUTH_HELPERS = {
    "onDutyOfficer": (
        CUSTOM / "custom-police" / "server" / "evidence.lua",
        "onDutyOfficer",
        "PolicePolicy.Can(",
    ),
    "NPC.SubmitResult": (
        CUSTOM / "custom-police" / "server" / "p4_npc.lua",
        "NPC.SubmitResult",
        "PolicePolicy.Can(",
    ),
    # 事件的真正鉴权在模块里（PolicePolicy.Can），不在 handler 现场。
    # 这三个别名把"调用点 → 定义 → 执行点"钉在一起，改掉任何一环都会红。
    "PoliceDispatch.ArriveIncident": (
        CUSTOM / "custom-police" / "server" / "p0_lifecycle.lua",
        "P.ArriveIncident",
        "PolicePolicy.Can(",
    ),
    "PoliceDispatch.ClaimIncident": (
        CUSTOM / "custom-police" / "server" / "p0_lifecycle.lua",
        "P.ClaimIncident",
        "PolicePolicy.Can(",
    ),
    "AdoptDraft": (
        CUSTOM / "custom-police" / "server" / "p0_incidents.lua",
        "P.AdoptDraft",
        "PolicePolicy.Can(",
    ),
    "ListDrafts": (
        CUSTOM / "custom-police" / "server" / "p0_incidents.lua",
        "P.ListDrafts",
        "PolicePolicy.Can(",
    ),
}

#: handler 里出现的调用形态（调用点可能没有括号，例如 `pcall(PoliceDispatch.X, src, ...)`）
HELPER_PATTERNS = {
    name: re.compile(rf"\b{re.escape(name)}\b") for name in AUTH_HELPERS
}

# What each allowlist category promises, and the token that must back it up.
MANUAL_CHECK = re.compile(r"job\.type|[Ii]sPolice|onduty|hasCapability|GetItemByName")
CIVILIAN_GUARD = re.compile(
    r"type\(|tonumber\(|sanitize|COOLDOWN|cooldown|coordsNearSource|updatingCops|"
    r"metadata\[|evidenceInfo|diff\("
)
SESSION_BIND = re.compile(
    r"metadata|taken_by|receiver_number|units\[requestId\]|"
    r"(?:StoreNotification|PhoneNotify\.Store)\(source|"
    r"ResolveSource\(source\)|GetPlayer\(targetSrc|"
    # 只认"调用方自己的号码/身份"作为键：charinfo.phone 是本人资料里读出来的，
    # 客户端改不了（以前这条靠 SQL 字符串里的 receiver_number 蒙混过关）
    r"charinfo\.phone"
)
SELF_SCOPED = re.compile(
    # 只碰 caller 自己的数据：先 `local src = source`，后续只对这一侧读写
    r"local\s+src\s*=\s*source"
)
CALLBACK_RELAY = re.compile(
    # 公用回调分发器：按名字派发到服务端已注册的回调
    r"ServerCallbacks\[name\]"
)
DEPRECATED_BLOCKED = re.compile(
    # 硬阻断的**结构**证据：必须真的写安全日志（`print` 太弱，一条 print('hello') 就能满足）
    r"LogSecurity\("
)
#: self_scoped 的反面：handler 里出现了"拿客户端给的 id 去索引别人"的形状
SELF_SCOPED_FOREIGN = re.compile(
    r"Players\s*\[\s*(?!src\b|source\b)[A-Za-z_]"     # QBCore.Players[targetId] / Players [targetId]
    r"|GetPlayer\(\s*tonumber\("                       # GetPlayer(tonumber(arg))
    r"|GetPlayer\(\s*\(*\s*(?!src\b|source\b)[A-Za-z_]"   # GetPlayer(targetId) / GetPlayer((targetId)) / (x or 0)
    r"|GetPlayerByCitizenId\(\s*(?!src\b)[A-Za-z_]"    # 按别人的 cid 取玩家
    # 别名：`local P = QBCore.Players` 之后再 P[targetId]（静态只能拦一层）
    r"|\b[A-Za-z_]\w*\s*=\s*(?:QBCore\.)?Players\b"
)
#: deprecated_blocked 的反面：说日志但后面照样写
DEPRECATED_SIDE_EFFECT = re.compile(
    r"\b(AddItem|RemoveItem|AddMoney|RemoveMoney|SetMetaData|SetJob|SetJobDuty|"
    r"SetGang|SetMoney)\b|MySQL\.|exports\[[^\]]+\]:Set"
)
DIAGNOSTIC_GUARD = re.compile(
    # 2026-10-25: 框架的诊断通道走限流 owner，不叫 COOLDOWN 也不叫 PhoneDiag.Accept
    r"COOLDOWN|cooldown|diagRateLimited|PHASES|PhoneDiag\.Accept|"
    r"RateLimitWindow|RateLimitCooldown|RateLimitTokenBucket"
)

REQUIRED_FIELDS = ("name", "file", "category", "reason", "evidence", "owner", "expires")
DEBT_CATEGORIES = {"unchecked_debt"}


def lua_files() -> list[Path]:
    files: list[Path] = []
    for _, directory in SCAN_DIRS:
        assert directory.is_dir(), f"missing scan directory: {directory}"
        files.extend(sorted(directory.rglob("*.lua")))
    return files


def scan_events() -> tuple[list[Event], list[str]]:
    """扫描 SCAN_DIRS，返回 (events, problems)。解析器在 net_event_scan（唯一实现）。"""
    events: list[Event] = []
    problems: list[str] = []
    for resource, directory in SCAN_DIRS:
        assert directory.is_dir(), f"missing scan directory: {directory}"
        found, issues = scan_dir(resource, directory)
        events.extend(found)
        problems.extend(issues)
    return events, problems


def auth_tokens(body: str) -> list[str]:
    return scan_auth_tokens(body, HELPER_PATTERNS)


def load_allowlist() -> dict:
    with ALLOWLIST.open(encoding="utf-8") as handle:
        return json.load(handle)


def allowlist_entries() -> dict[str, dict]:
    data = load_allowlist()
    return {entry["name"]: entry for entry in data.get("entries", [])}


def unregistered(events: list[Event]) -> list[Event]:
    registered = allowlist_entries()
    return [
        event
        for event in events
        if not is_guarded(event, HELPER_PATTERNS) and event.name not in registered
    ]


def report() -> str:
    events, problems = scan_events()
    registered = allowlist_entries()
    bad = unregistered(events)
    guarded = sum(1 for event in events if is_guarded(event, HELPER_PATTERNS))
    lines = [
        f"FIT-03 net-event-auth  {'FAIL' if (bad or problems) else 'PASS'}  "
        f"{len(bad)}/{len(events)} unguarded",
    ]
    for event in bad:
        lines.append(f"  {event.where(RESOURCES)}  {event.name}  no_auth")
    for problem in problems:
        lines.append(f"  SKIP {problem}")
    lines.append(
        '  summary: {"rule":"FIT-03","events":%d,"strong_auth":%d,"allowlisted":%d,'
        '"violations":%d,"skipped":%d}'
        % (len(events), guarded, len(registered), len(bad), len(problems))
    )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Scanner sanity
# ---------------------------------------------------------------------------

def test_scanner_covers_both_resources_and_every_handler_terminates():
    events, problems = scan_events()
    assert problems == [], "unparsable handlers:\n" + "\n".join(problems)
    # A broken terminator heuristic would silently skip handlers, so pin the
    # shape: 40+ handlers across the two resources.
    assert len(events) >= 40, f"only {len(events)} net events found — scanner regression?"
    # 2026-10-25: 范围加了 core-framework（框架自己的 net event 之前没被扫过）
    assert {event.resource for event in events} == {
        "custom-police", "custom-phone", "core-framework", "qb-core"
    }
    assert all(event.name for event in events)
    assert all(len(event.body) > 0 for event in events)
    names = [event.name for event in events]
    assert len(names) == len(set(names)), "duplicate net event registration"


# ---------------------------------------------------------------------------
# The rule itself
# ---------------------------------------------------------------------------

def test_every_net_event_is_authenticated_or_registered():
    events, problems = scan_events()
    assert problems == [], "unparsable handlers:\n" + "\n".join(problems)
    bad = unregistered(events)
    if bad:
        detail = "\n".join(
            f"  {event.where(RESOURCES)}  {event.name}  no_auth — add PolicePolicy.Can(...) "
            f"inside the handler, or register it in "
            f"tests/architecture/net_events_allowlist.json"
            for event in bad
        )
        raise AssertionError(
            f"FIT-03: {len(bad)}/{len(events)} net events have no auth token:\n{detail}"
        )
    # Every allowlisted event must still exist (no dead exemption, no typo).
    names = {event.name for event in events}
    stale = sorted(set(allowlist_entries()) - names)
    assert stale == [], f"allowlist entries for events that no longer exist: {stale}"


def test_allowlist_entries_carry_a_reason_owner_and_expiry():
    data = load_allowlist()
    entries = data.get("entries", [])
    assert entries, "allowlist is empty — the rule would pass with no documentation"
    known_categories = set(data["categories"])
    today = date.today()
    seen: set[str] = set()
    for entry in entries:
        name = entry.get("name", "?")
        for field in REQUIRED_FIELDS:
            value = entry.get(field)
            assert isinstance(value, str) and value.strip(), f"{name}: missing {field}"
        assert name not in seen, f"duplicate allowlist entry: {name}"
        seen.add(name)
        assert entry["category"] in known_categories, (
            f"{name}: unknown category {entry['category']!r}"
        )
        # owner 的"必须是所属资源"由 test_allowlisted_events_* 里对 path/resource 的
        # 一致性检查覆盖（2026-10-25: 原来这里写死两个资源名，框架加进扫描范围后就登不了了）
        expires = date.fromisoformat(entry["expires"])
        assert expires >= today, (
            f"{name}: allowlist entry expired on {entry['expires']} — re-review the "
            f"handler and either fix it or renew with a new justification "
            f"(hard expiry is the point of the allowlist)"
        )



def allowlist_path(file_field: str) -> Path:
    """allowlist 里的 ``file`` 到真实路径。

    约定：[custom] 下的资源省略括号目录（``custom-police/server/x.lua``），
    其它分组必须带前缀（``[standalone]/core-framework/server/x.lua``）。
    2026-10-25 之前这里写死 ``CUSTOM / file``，于是框架资源没法登记。
    """
    return RESOURCES / file_field if file_field.startswith("[") else CUSTOM / file_field


def test_allowlisted_events_really_show_the_claim_in_their_body():
    """A category is a promise; check the handler still keeps it."""
    events = {event.name: event for event in scan_events()[0]}
    for name, entry in allowlist_entries().items():
        event = events[name]
        assert event.path == allowlist_path(entry["file"]), (
            f"{name}: allowlist says {entry['file']} but the handler is at {event.where(RESOURCES)}"
        )
        category = entry["category"]
        # 承诺检查一律在**剥掉注释与字符串**之后做：注释里写的检查不算检查
        code = strip_lua_noise(event.body)
        if category == "already_checked":
            assert MANUAL_CHECK.search(code), (
                f"{name}: registered as already_checked but no job/onduty/item check "
                f"in the handler body — fix the handler or change the category"
            )
        elif category == "civilian":
            assert CIVILIAN_GUARD.search(code), (
                f"{name}: registered as civilian but the handler does not validate or "
                f"rate limit anything"
            )
        elif category == "session":
            assert SESSION_BIND.search(code), (
                f"{name}: registered as session-bound but the handler never binds to "
                f"the caller's own session/ownership"
            )
        elif category == "self_scoped":
            assert SELF_SCOPED.search(code), (
                f"{name}: registered as self_scoped but the handler never binds to "
                f"`local src = source` — a self-scoped claim needs the caller identity"
            )
            targets = re.findall(r"GetPlayer\(\s*([A-Za-z_][\w.]*)\s*\)", code)
            foreign = [arg for arg in targets if arg not in ("src", "source")]
            assert not foreign, (
                f"{name}: registered as self_scoped but indexes another player "
                f"({foreign}) — that is a cross-player write, not self-scoped"
            )
            foreign_ref = SELF_SCOPED_FOREIGN.search(code)
            assert not foreign_ref, (
                f"{name}: registered as self_scoped but reaches another player via "
                f"{foreign_ref.group(0)!r} — 自作用域只能碰 src"
            )
        elif category == "callback_relay":
            assert CALLBACK_RELAY.search(code), (
                f"{name}: registered as callback_relay but does not dispatch through "
                f"QBCore.ServerCallbacks[name]"
            )
        elif category == "deprecated_blocked":
            assert DEPRECATED_BLOCKED.search(code), (
                f"{name}: registered as deprecated_blocked but the handler no longer "
                f"contains the BLOCKED guard — it may be executing again"
            )
            assert not DEPRECATED_SIDE_EFFECT.search(code), (
                f"{name}: registered as deprecated_blocked but the handler still calls "
                f"{DEPRECATED_SIDE_EFFECT.search(code).group(1)} — 说 BLOCKED 却照样写"
            )
        elif category == "diagnostic":
            assert DIAGNOSTIC_GUARD.search(code), (
                f"{name}: registered as diagnostic but no rate limit / field whitelist"
            )
        # unchecked_debt carries no claim beyond the reason + expiry.


def test_diag_helper_really_limits_and_sanitizes():
    """`PhoneDiag.Accept` satisfies the diagnostic guard by delegation, so the
    claim has to hold where the delegation lands — same idea as AUTH_HELPERS."""
    source = read(DIAG_MODULE)
    for token in (
        "function PhoneDiag.Accept",
        "PhoneDiag.Sanitize",
        "allowTrace",
        "allowUi",
        "printBudgetOk",
        "TRACE_PER_MIN = ",
        "TRACE_BURST = ",
        "UI_COOLDOWN_MS = ",
        "PRINT_BUDGET_PER_SEC = ",
    ):
        assert token in source, f"doc claims {token!r} but it is gone from {DIAG_MODULE.name}"


def test_auth_helpers_really_enforce_policypolicy():
    """The allowlist trusts helpers; verify each one still calls the policy."""
    for helper, (path, definition, token) in AUTH_HELPERS.items():
        source = read(path)
        pattern = re.compile(
            rf"(?:local )?function\s+{re.escape(definition)}\s*\([^)]*\)(.*?)^end\s*$",
            re.DOTALL | re.MULTILINE,
        )
        match = pattern.search(source)
        assert match, (
            f"auth helper {helper}: 定义 {definition} 在 {path.name} 里找不到了 "
            f"— handler 仍在调用它，等于没有鉴权"
        )
        assert token in match.group(1), (
            f"auth helper {helper}（{definition}，{path.name}）不再调用 {token} — "
            f"所有依赖它的事件都变成未鉴权"
        )


RELAY_VEHICLE_CALLBACKS = ("QBCore:Server:SpawnVehicle", "QBCore:Server:CreateVehicle")
SECURITY_WRAPPER = CUSTOM / "custom-security" / "server" / "security.lua"


def test_relay_callbacks_that_spawn_vehicles_are_guarded_somewhere():
    """`QBCore:Server:TriggerCallback` 是公用分发器，本身不鉴权 —— 那么它分发的**高危目标**
    必须有一条能被验证的守卫，而不是靠"回调自己会校验"的口头承诺。

    载具生成这两个回调在 qb-core 里没有任何权限判断（谁都能让服务端 CreateVehicle），
    实际守卫在 custom-security 的劫持里。这里钉四件事：
      ① 劫持仍然存在（是**赋值**成包装函数，不是只留一句 `local orig = ...`）；
      ② 权限判定与限频在**包装函数体内**（不是文件里别处的死代码）；
      ③ 开关 `security_check_vehicle_spawn` 没被关掉；
      ④ custom-security 在启动集里，且 qb-core 重启后会重挂（否则守卫静默失效）。
    """
    raw = read(SECURITY_WRAPPER)
    source = strip_lua_noise(raw)
    for callback in RELAY_VEHICLE_CALLBACKS:
        # 事件名本身在字符串里（剥噪声会把它变成 ''），所以定位用原文
        match = re.search(
            r"QBCore\.ServerCallbacks\['" + re.escape(callback) + r"'\]\s*=\s*function", raw
        )
        assert match, (
            f"{callback} 的守卫不见了：custom-security 不再劫持它，"
            f"任何客户端都能通过 QBCore:Server:TriggerCallback 让服务端刷车"
        )
        # 窗口只到下一个 ServerCallbacks 赋值（否则会把后一个 wrapper 的守卫算进来）
        nxt = raw.find("QBCore.ServerCallbacks['", match.end())
        end_at = nxt if nxt != -1 else match.start() + 6000
        wrapper = strip_lua_noise(raw[match.start():end_at])
        # `if false then <守卫> end; orig(...)` 能让"守卫存在"毫无意义：
        # 要求守卫出现在真正的转发调用之前，且 wrapper 里没有恒假分支。
        assert not re.search(r"if\s+false\s+then", wrapper), (
            f"{callback}: 守卫被包在 `if false then` 里 —— 写了但永远不执行"
        )
        forward = re.search(r"orig[A-Za-z]*\s*\(", wrapper)
        if forward:
            guard_at = min(
                [m.start() for m in re.finditer(r"HasPermission\(|CheckRateLimit\(", wrapper)] or [-1]
            )
            assert guard_at != -1 and guard_at < forward.start(), (
                f"{callback}: 守卫出现在转发调用之后（甚至没有）——先刷车再校验等于没校验"
            )
        assert re.search(r"HasPermission\(\s*source\s*,", wrapper), (
            f"{callback} 的包装函数里没有 admin 判定 —— 劫持还在但没校验（文件别处的同名调用不算）"
        )
        assert re.search(r"CheckRateLimit\(\s*source\s*,", wrapper), (
            f"{callback} 的包装函数里没有限频 —— 连点就能刷爆"
        )
    cfg = read(BASE / "configs" / "modules" / "security.cfg")
    assert 'security_check_vehicle_spawn "true"' in cfg, (
        "security_check_vehicle_spawn 被关掉了 —— custom-security 的刷车守卫会整段跳过"
    )
    custom = read(BASE / "configs" / "modules" / "custom.cfg")
    assert "ensure custom-security" in custom, (
        "custom-security 不在启动集里 —— 守卫压根不会挂载"
    )
    assert re.search(
        r"function\(resourceName\)[\s\S]{0,200}qb-core", raw
    ), (
        "qb-core 重启后没有重挂守卫（restart qb-core 会重建 ServerCallbacks，劫持丢失且无人发现）"
    )


def test_civilian_and_police_entry_points_exist_in_both_resources():
    """Guard against a rename that makes this suite silently vacuous."""
    events = {event.name: event for event in scan_events()[0]}
    for name in (
        "police:server:policeAlert",   # civilian report entry point
        "police:server:autoAlert",     # strong-auth reference implementation
        "evidence:server:CreateBloodDrop",
        "evidence:server:ClearBlooddrops",
        "phone:server:focusState",
        "phone:server:clientError",
    ):
        assert name in events, f"{name} disappeared — update the FIT-03 baseline"


def test_no_auth_token_is_smuggled_in_via_a_comment():
    """Tokens inside comments do not count... unless the body really checks.

    This is a cheap guard: a handler whose *only* strong token appears on a
    `--` line is reported, because a commented-out check is not a check.
    """
    offenders = []
    for event in scan_events()[0]:
        if not auth_tokens(event.body):
            continue
        code = "\n".join(
            line for line in event.body.splitlines() if not line.lstrip().startswith("--")
        )
        if not auth_tokens(code):
            offenders.append(event.where(RESOURCES) + " " + event.name)
    assert offenders == [], f"auth token only appears in comments: {offenders}"


if __name__ == "__main__":  # pragma: no cover - manual runner
    print(report())


# ---------------------------------------------------------------------------
# 注册形式本身也是一条规则：必须写字面量
# ---------------------------------------------------------------------------

def non_literal_registrations() -> list[str]:
    """返回"第一个参数不是字符串字面量"的注册点（与全仓基线的判定同一实现）。

    为什么必须钉这条：扫描器按字面量取事件名，`RegisterNetEvent(EVENT_NAME, ...)`
    会让整条事件对闸门不可见——而诊断类事件能往服务端日志写字，看不见就等于没管。
    """
    offenders: list[str] = []
    for _resource, directory in SCAN_DIRS:
        offenders.extend(non_literal_in_dir(directory))
    return offenders

def test_net_event_registration_uses_a_literal_name():
    offenders = non_literal_registrations()
    assert not offenders, (
        "这些 net event 用变量名注册，架构闸门看不见它们（等于没管）：\n  " + "\n  ".join(offenders))


def test_literal_rule_fires_on_the_variable_form(tmp_path: Path):
    """反向校验：把变量形式喂给判定函数，必须被抓到。"""
    spike = tmp_path / "spike.lua"
    spike.write_text("RegisterNetEvent(EVENT_NAME, function() end)\n", encoding="utf-8")
    original = globals()["SCAN_DIRS"]
    try:
        globals()["SCAN_DIRS"] = (("spike", tmp_path),)
        assert non_literal_registrations(), "变量名注册必须被判为违规"
        spike.write_text("RegisterNetEvent('x:server:y', function() end)\n", encoding="utf-8")
        assert not non_literal_registrations(), "字面量注册不该被误报"
    finally:
        globals()["SCAN_DIRS"] = original

# ---------------------------------------------------------------------------
# helper 登记表：让"本资源自己的校验函数"算作鉴权，但只算**证明过**的那几个
# ---------------------------------------------------------------------------


def _resource_dir(name: str) -> Path:
    hits = sorted(RESOURCES.rglob(f"{name}/fxmanifest.lua"))
    assert len(hits) == 1, f"{name}: 找到 {len(hits)} 个 fxmanifest，无法唯一定位资源"
    return hits[0].parent


def _function_block_raw(code: str, marker: str) -> str:
    """从 `marker` 截到顶层 `end`（列 0）。

    只看整个文件会被"同文件别的函数里的证据"满足，所以登记检查限定在函数体。
    """
    at = code.index(marker)
    lines = code[at:].splitlines()
    out = [lines[0]]
    for line in lines[1:]:
        out.append(line)
        if line.rstrip() in ("end", "end)"):
            break
    return chr(10).join(out)


def test_registered_guard_helpers_are_proven():
    """登记过的 helper 必须是真校验，且每一处调用都必须看它的返回值。

    为什么需要这张表：`custom-vehicles` 的 26 个事件里有 10 个靠 `CanModifyPlate` 挡着，
    扫描器只认固定 token 的话会把这 10 个当成裸奔（假红）。但"调用了一个叫 Can 的函数"
    本身不是证据 —— 所以这里对每一行登记做四件事：
      ① 定义恰好一处（不是同名死代码，也没有第二份实现互相覆盖）；
      ② **函数体内**含约定证据（剥注释/字符串后）+ 含字符串字面量的证据（原文）；
      ③ 资源内每一处调用都在 `if not H(...)` 的否定分支里，且该分支**真的 return**；
      ④ 登记了却没有任何调用点 → 死豁免，红。
    """
    registry = guard_helpers()
    assert registry, "helper 登记表为空 —— 这条规则等于没写"
    for resource, entries in registry.items():
        root = _resource_dir(resource)
        for name, spec in entries.items():
            rel = Path(spec["defined_at"])
            assert rel.parts and rel.parts[0] == resource, (
                f"{resource}/{name}: defined_at 必须以资源名开头（现在 {spec['defined_at']!r}）"
            )
            def_file = (root / Path(*rel.parts[1:])).resolve()
            assert def_file.is_file(), f"{resource}/{name}: defined_at 指向不存在的文件"
            assert root in def_file.parents, f"{resource}/{name}: defined_at 不在该资源内"
            raw = read(def_file)
            code = strip_lua_noise(raw)
            marker = spec.get("definition_marker", "function " + name + "(")
            assert code.count(marker) == 1, (
                f"{resource}/{name}: 必须恰好定义一次（现在 {code.count(marker)} 次）"
            )
            block = _function_block_raw(code, marker)
            for token in spec.get("requires_code", []):
                assert token in block, (
                    f"{resource}/{name}: **函数体**里找不到 {token!r}（同文件其它函数里的不算）"
                )
            for token in spec.get("requires_raw", []):
                assert token in _function_block_raw(raw, marker), (
                    f"{resource}/{name}: 原文函数体里找不到 {token!r}"
                )

            uses = 0
            problems: list[str] = []
            for lua in sorted(root.rglob("*.lua")):
                if is_client_path(lua):
                    continue  # 服务端事件的鉴权只可能写在服务端文件里
                found, bad = helper_call_problems(strip_lua_noise(read(lua)), name, spec)
                uses += found
                problems.extend(str(lua.relative_to(root)) + ":" + item for item in bad)
            assert not problems, (
                f"{resource}/{name}: 有调用点没走 `if not {name}(...) then ... return`："
                + chr(10) + "  " + (chr(10) + "  ").join(problems)
            )
            assert uses > 0, f"{resource}/{name}: 登记了但没有任何调用点（死豁免）"
