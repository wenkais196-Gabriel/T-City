"""POL-EVD-01：拾取证据时，身份字段只能来自服务端记录。

背景（真实流程）：服务端把每一颗弹壳/每一摊血迹/每一个指纹都存在自己的内存表里
（`Casings` / `BloodDrops` / `FingerDrops`），拾取时客户端只发一个 id 加一段描述。

老代码直接采信客户端那段描述——`serie`（枪号）、`ammotype`（武器）、`bloodtype`（血型）、
`dnalabel`（DNA）、`fingerprint`（指纹）全部来自客户端。改过的客户端因此可以：

* 用一个从来不存在的 id 换出一个证据袋（服务端连 id 都没核对）；
* 把 `serie`/`fingerprint`/`bloodtype` 写成别人的，栽赃；
* 把血型写成任意值，鉴证结论直接失真。

规则：这三段 handler 必须先用 id 查自己的记录（`Casings[id]` …），并且**不得**出现
`<客户端参数>.<身份字段>`。唯一允许采信客户端的是 `street`（街道名只有客户端拿得到原生值）。

反向校验：给一段"采信客户端"的合成 handler，扫描器必须抓到。
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
SERVER = BASE / "resources" / "[custom]" / "custom-police" / "server" / "evidence.lua"

#: 拾取 handler → 它必须查的那张服务端记录表
HANDLERS = {
    "AddCasingToInventory": "Casings",
    "AddBlooddropToInventory": "BloodDrops",
    "AddFingerprintToInventory": "FingerDrops",
}

#: 身份类字段：这些只能取自服务端记录
IDENTITY_FIELDS = ("serie", "ammotype", "ammolabel", "bloodtype", "dnalabel", "fingerprint", "label", "type")

#: 客户端参数名（handler 的第二个入参）
_CLIENT_PARAM = re.compile(r"RegisterNetEvent\('evidence:server:(\w+)', function\(\w+,\s*(\w+)\)")


def handler_body(source: str, name: str) -> str:
    """取某个 handler 的完整函数体（按行缩进保守切到下一个 RegisterNetEvent）。"""
    start = source.index(f"RegisterNetEvent('evidence:server:{name}'")
    rest = source[start + 10:]
    nxt = rest.find("RegisterNetEvent(")
    return source[start:start + 10 + (nxt if nxt != -1 else len(rest))]


def violations(source: str) -> list[str]:
    found: list[str] = []
    for name, store in HANDLERS.items():
        if f"RegisterNetEvent('evidence:server:{name}'" not in source:
            found.append(f"{name}: handler 不见了")
            continue
        body = handler_body(source, name)

        # 1) 必须先按 id 查自己的记录
        if not re.search(rf"local \w+ = {store}\[id\]", body):
            found.append(f"{name}: 没有用 id 查 {store}（幽灵 id 也能换证据袋）")

        # 2) 身份字段不得来自客户端参数
        match = _CLIENT_PARAM.search(body)
        param = match.group(2) if match else "info"
        for field in IDENTITY_FIELDS:
            if re.search(rf"\b{re.escape(param)}\.{field}\b", body):
                found.append(f"{name}: 采信了客户端的 {param}.{field}（应取自 {store}）")
    return found


def test_identity_fields_come_from_the_server_record():
    found = violations(SERVER.read_text(encoding="utf-8"))
    assert not found, "拾取 handler 又信任客户端了：\n  " + "\n  ".join(found)


def test_scanner_catches_a_handler_that_trusts_the_client():
    """反向：合成一段"采信客户端"的 handler，扫描器必须点名。"""
    bad = """
RegisterNetEvent('evidence:server:AddCasingToInventory', function(casingId, casingInfo)
    local id = tonumber(casingId)
    if not id then return end
    local info = { serie = casingInfo.serie, ammotype = casingInfo.ammotype }
    if exports['qb-inventory']:RemoveItem(src, 'empty_evidence_bag', 1, false, 'x') then
        exports['qb-inventory']:AddItem(src, 'filled_evidence_bag', 1, false, info, 'x')
    end
end)
RegisterNetEvent('evidence:server:AddBlooddropToInventory', function(bloodId, bloodInfo)
    local id = tonumber(bloodId)
    local drop = BloodDrops[id]
    local info = { bloodtype = drop.bloodtype }
end)
RegisterNetEvent('evidence:server:AddFingerprintToInventory', function(fingerId, fingerInfo)
    local id = tonumber(fingerId)
    local drop = FingerDrops[id]
    local info = { fingerprint = drop.fingerprint }
end)
"""
    found = violations(bad)
    assert any("AddCasingToInventory" in item and "serie" in item for item in found), found
    assert any("AddCasingToInventory" in item and "Casings" in item for item in found), found
    # 另外两段是合规写法，不该被点名
    assert not any("AddBlooddropToInventory" in item for item in found), found
    assert not any("AddFingerprintToInventory" in item for item in found), found


# ── POL-EVD-02：清扫过期痕迹必须广播 ─────────────────────────────────────────

def prune_body(source: str) -> str:
    start = source.index("local function pruneExpired(")
    end = source.index("end\n", source.index("return removed", start))
    return source[start:end]


def missing_broadcast(source: str) -> list[str]:
    body = prune_body(source)
    problems = []
    if "store[id] = nil" not in body:
        problems.append("pruneExpired 没删任何东西")
    if "TriggerClientEvent(removeEvent, -1, id)" not in body:
        problems.append("删了但没广播 Remove*：客户端会留着一个换不出东西的幽灵标记")
    return problems


def test_expiring_a_drop_tells_the_clients():
    source = SERVER.read_text(encoding="utf-8")
    assert missing_broadcast(source) == [], "\n".join(missing_broadcast(source))

    # 反向：只删不广播必须被抓到
    bad = """
local function pruneExpired(store, removeEvent, now)
    local removed = 0
    for id, row in pairs(store) do
        store[id] = nil
        removed = removed + 1
    end
    return removed
end
"""
    assert missing_broadcast(bad), "扫描器抓不住「只删不广播」"


def test_the_sweep_runs_on_a_timer_not_only_when_the_table_fills():
    """TTL 必须由定时器驱动，不能只在表满 500 时才顺手清一次（那样等于不清）。"""
    source = SERVER.read_text(encoding="utf-8")
    assert "TTL_SWEEP_INTERVAL" in source, "清扫周期常量不见了"
    assert "CreateThread(function()" in source
    sweep = source[source.index("CreateThread(function()", source.index("EvidenceMaintenance")):]
    assert "Wait(TTL_SWEEP_INTERVAL * 1000)" in sweep, "清扫线程没有按周期等待"
    assert "pruneExpiredDrops()" in sweep, "清扫线程没有真的调用清扫"
