"""A10 — 买家能看见别人的摊位（旁观者推送契约）。

背景（已核实）：`QuestVendorBridge.PushState` 只把摊位状态单播给摊主本人，
买家客户端永远没有别人的摊位记录，`[ALT]` 购买菜单因此不可达。

本片约定：
* 摊主状态（库存 / 收入 / 报价）仍只走 `PushState` 单播；
* 另开一条旁观者推送：复用事件名 `quest:client:vendorState`，payload 必须带
  `isOwner = false`，字段只允许 isOwner / boothNetId / state / coords / items；
* 受众用 `Broadcast.Scope({ coords, radius })`，禁止 `-1` 全服广播；
* 客户端按 `isOwner = false` 走买家分支，离开半径后清掉记录。

每条规则都带反向校验：把错误形状喂给同一个判定函数，必须红。

    python -m pytest -q tests/architecture/test_quest_vendor_bystander.py
"""
from __future__ import annotations

import re
from pathlib import Path

import lua_source

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
QUEST = BASE / "resources" / "[custom]" / "custom-quest"
BRIDGE = QUEST / "server" / "quest_vendor_bridge.lua"
CLIENT = QUEST / "client" / "quest_hotdog_vendor_client.lua"
MANIFEST = QUEST / "fxmanifest.lua"

BROADCAST = "@core-framework/server/broadcast.lua"
MYSQL = "@oxmysql/lib/MySQL.lua"
PUBLIC_EVENT = "quest:client:vendorState"

#: 旁观者 payload 的完整白名单。多一个键就是多一份摊主数据外泄面。
PAYLOAD_KEYS = {"isOwner", "boothNetId", "state", "coords", "items"}


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


# ---------------------------------------------------------------------------
# 解析助手（只做一件事：把源码形状变成可判定的输入）
# ---------------------------------------------------------------------------


def function_block(source: str, marker: str) -> str:
    """截取 `function <marker>(` 到列 0 的 `end`（本仓库的顶层函数写法）。"""
    at = source.find(marker)
    assert at != -1, f"找不到 {marker}"
    lines = source[at:].splitlines()
    body = [lines[0]]
    for line in lines[1:]:
        body.append(line)
        if line.rstrip() == "end":
            break
    else:
        raise AssertionError(f"{marker} 没有以列 0 的 end 收尾")
    return "\n".join(body)


def marked_block(source: str, name: str) -> str:
    match = re.search(
        rf"-- \[{re.escape(name)}\] begin\n(.*?)\n-- \[{re.escape(name)}\] end",
        source,
        re.S,
    )
    assert match, f"找不到标记块 {name}"
    return match.group(1)


def server_script_entries(manifest: str) -> list[str]:
    text = lua_source.blank_noise(manifest, keep_strings=True)
    match = re.search(r"\bserver_scripts\s*\{(?P<body>.*?)\}", text, re.S)
    assert match, "fxmanifest 里没有 server_scripts 块"
    return re.findall(r"['\"]([^'\"]+)['\"]", match.group("body"))


def returned_keys(block: str) -> set[str]:
    """取 `return { ... }` 的**顶层**键（嵌套表里的键不算）。"""
    code = lua_source.blank_noise(block)
    at = code.find("return {")
    assert at != -1, "payload 构造函数里没有 return { ... }"
    open_index = code.index("{", at)
    depth = 0
    keys: set[str] = set()
    for line in code[open_index:].splitlines():
        if depth == 1:
            match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*=", line.strip())
            if match:
                keys.add(match.group(1))
        depth += line.count("{") - line.count("}")
        if depth <= 0 and keys:
            break
    return keys


# ---------------------------------------------------------------------------
# 判定函数（正向与反向共用同一份，反向用例就是"规则会红"的证明）
# ---------------------------------------------------------------------------


def manifest_problems(entries: list[str]) -> list[str]:
    problems: list[str] = []
    if BROADCAST not in entries:
        problems.append(f"server_scripts 缺 {BROADCAST}：运行期 Broadcast.Scope 是 nil")
    elif MYSQL in entries and entries.index(BROADCAST) < entries.index(MYSQL):
        problems.append(f"{BROADCAST} 必须排在 {MYSQL} 之后（与 custom-police 写法一致）")
    return problems


def payload_problems(keys: set[str]) -> list[str]:
    problems: list[str] = []
    missing = sorted(PAYLOAD_KEYS - keys)
    extra = sorted(keys - PAYLOAD_KEYS)
    if missing:
        problems.append("旁观者 payload 缺字段：" + ", ".join(missing))
    if extra:
        problems.append("旁观者 payload 多出未登记字段：" + ", ".join(extra))
    return problems


def scope_problems(source: str) -> list[str]:
    """要求：Broadcast.Scope + { coords, radius } 受众 + 事件名；拒绝 -1。"""
    problems: list[str] = []
    code = lua_source.blank_noise(source)
    text = lua_source.blank_noise(source, keep_strings=True)

    call = re.search(r"\bBroadcast\s*\.\s*Scope\s*\(", text)
    if not call:
        problems.append("旁观者推送没有走 Broadcast.Scope")
    else:
        open_index = text.index("(", call.start())
        spans = lua_source.argument_spans(text, open_index)
        audience = text[slice(*spans[1])] if len(spans) >= 2 else ""
        if "coords" not in audience or "radius" not in audience:
            problems.append("Broadcast.Scope 的受众必须是 { coords, radius }")
        event = text[slice(*spans[0])].strip().strip("'\"")
        if event != PUBLIC_EVENT:
            problems.append(f"旁观者事件名应是 {PUBLIC_EVENT}，实际 {event!r}")

    if re.search(r"TriggerClientEvent\s*\([^)]*,\s*-1\s*,", code):
        problems.append("旁观者推送里出现了 -1 全服广播（broadcast_sites 预算 143/143）")
    return problems


def prune_problems(block: str) -> list[str]:
    code = lua_source.blank_noise(block)
    problems: list[str] = []
    if not re.search(r"if\s+not\s+booth\s*\.\s*isOwner\s+then", code):
        problems.append("清理循环没有只处理旁观者记录（not booth.isOwner）")
    if "PUBLIC_CLEAR_DISTANCE" not in code:
        problems.append("清理判据没有使用 PUBLIC_CLEAR_DISTANCE")
    if not re.search(r"Booths\s*\[\s*netId\s*\]\s*=\s*nil", code):
        problems.append("离开范围时没有清掉记录（Booths[netId] = nil）")
    if "ClearBuyMenu()" not in code:
        problems.append("清记录时没有收掉购买菜单")
    return problems


def client_problems(source: str) -> list[str]:
    code = lua_source.blank_noise(source)
    problems: list[str] = []
    if not re.search(r"if\s+not\s+isOwner\s+then", code):
        problems.append("客户端 vendorState 没有按 isOwner=false 走旁观者分支")
    if not re.search(r"\bpayload\s*\.\s*items\b", code):
        problems.append("旁观者分支没有从 payload.items 构建可买清单")
    if not re.search(r"isOwner\s*=\s*false\b", code):
        problems.append("旁观者记录没有显式标记 isOwner=false")
    if "PUBLIC_CLEAR_DISTANCE" not in code:
        problems.append("没有旁观者记录的清理距离常量")
    marker = "local function PruneBystanderBooths("
    if marker not in source:
        problems.append("没有 PruneBystanderBooths：离开范围后记录会永远留着")
    else:
        problems.extend(prune_problems(function_block(source, marker)))
    return problems


# ---------------------------------------------------------------------------
# 正向：真实仓库
# ---------------------------------------------------------------------------


def test_manifest_wiring_rejects_missing_broadcast_helper():
    entries = server_script_entries(read(MANIFEST))
    problems = manifest_problems(entries)
    assert not problems, "\n".join(problems)


def test_bystander_payload_rejects_owner_private_fields():
    block = marked_block(read(BRIDGE), "vendor-bystander")
    problems = payload_problems(returned_keys(block))
    assert not problems, "\n".join(problems)


def test_bystander_broadcast_scope_rejects_global_broadcast():
    block = function_block(read(BRIDGE), "function QuestVendorBridge.PushBystanders(")
    problems = scope_problems(block)
    assert not problems, "\n".join(problems)


def test_client_public_state_and_range_cleanup_detects_regressions():
    problems = client_problems(read(CLIENT))
    assert not problems, "\n".join(problems)


# ---------------------------------------------------------------------------
# 反向校验：把错误形状喂进同一份判定函数，必须红
# ---------------------------------------------------------------------------


def test_reverse_missing_or_misordered_broadcast_helper_is_rejected():
    assert manifest_problems([MYSQL, "server/quest_vendor_bridge.lua"])
    assert manifest_problems([BROADCAST, MYSQL])
    assert not manifest_problems([MYSQL, BROADCAST, "server/quest_vendor_bridge.lua"])


def test_reverse_owner_fields_in_bystander_payload_are_rejected():
    poisoned = PAYLOAD_KEYS | {"citizenid", "revenue", "stock", "raw", "sold", "offers"}
    assert payload_problems(poisoned)
    assert payload_problems(PAYLOAD_KEYS - {"isOwner"})


def test_reverse_global_broadcast_and_missing_coords_audience_are_rejected():
    assert scope_problems("TriggerClientEvent('quest:client:vendorState', -1, payload)\n")
    assert scope_problems(
        "Broadcast.Scope('quest:client:vendorState', { source = src }, payload)\n")
    assert not scope_problems(
        "Broadcast.Scope('quest:client:vendorState', "
        "{ coords = vector3(0.0, 0.0, 0.0), radius = 10.0 }, payload)\n")


def test_reverse_client_without_owner_split_or_prune_is_rejected():
    bad = (
        "local PUBLIC_CLEAR_DISTANCE = 12.0\n"
        "RegisterNetEvent('quest:client:vendorState', function(payload)\n"
        "    local isOwner = true\n"
        "end)\n"
        "local function PruneBystanderBooths(pedCoords)\n"
        "    return\n"
        "end\n"
    )
    assert client_problems(bad)

    good = (
        "local PUBLIC_CLEAR_DISTANCE = 12.0\n"
        "RegisterNetEvent('quest:client:vendorState', function(payload)\n"
        "    local isOwner = IsOwnPayload(payload)\n"
        "    if not isOwner then\n"
        "        local items = payload.items\n"
        "        local record = { isOwner = false, items = items }\n"
        "    end\n"
        "end)\n"
        "local function PruneBystanderBooths(pedCoords)\n"
        "    for netId, booth in pairs(Booths) do\n"
        "        if not booth.isOwner then\n"
        "            if #(pedCoords - booth.coords) > PUBLIC_CLEAR_DISTANCE then\n"
        "                Booths[netId] = nil\n"
        "                ClearBuyMenu()\n"
        "            end\n"
        "        end\n"
        "    end\n"
        "end\n"
    )
    assert not client_problems(good), client_problems(good)
