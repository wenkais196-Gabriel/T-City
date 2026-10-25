"""NUI-BASELINE-01 — 把 2026-10-25 那次「MDT 永远查询失败」的教训钉成 CI 门槛。

离线、确定性、不需要 FXServer / DB / 网络。每条规则都对应一次**真实踩过**的故障，
不是风格偏好：

  ================================  =============================================
  check                              failing shape / 说明
  ================================  =============================================
  ``cb_guard_not_function``          ``if type(cb) ~= 'function' then return end``
                                     —— FiveM 的 NUI 应答通道可能是可调用表，
                                     这条守卫会把每次应答静默丢掉，前端只能拿到
                                     transport 兜底码（查询失败/操作失败）
  ``answer_channel_normalized``      ``PhoneBridge.AnswerFn`` 必须存在、覆盖
                                     ``function`` → ``__call`` 表 → CFX 函数引用，
                                     且 ``RegisterNui`` 必须走它而不是自己判 type
  ``diag_convar_not_int_gated``      ``GetConvarInt('phone_diag')`` —— convar 未定义
                                     时返回 0，会把"没配置"误判成"关闭"
  ``trace_slot_parity``              客户端 phase 表与服务端槽位映射的顺序必须一致
                                     （两处手写，错位会让 path 静默错段）
  ``trace_slot_observable_only``     判定里不得出现 NS/ND —— NUI 侧 resolve 在 Lua
                                     侧不可观测，留着会把健康请求判成 seg4
  ``diag_no_pii_projection``         诊断投影不得把 payload/文本字段带进日志
  ``nui_build_hashed``               Vite 产物必须带 ``[hash]``，且
                                     ``html/index.html`` 不得引用无 hash 的 bundle
                                     （CEF 会缓存页面，固定文件名 = 改了不生效）
  ``diag_field_isolation``           ``_diag`` 只能出现在边界三处（diag/bridge/main），
                                     不得漏进业务模块或 server/apps
  ================================  =============================================

反向校验：``_check_*`` 函数是纯文本判定，测试里同时用**错误形状**调用它们并断言
返回违规，确保规则本身有效（不是恒真断言）。

Run: ``python3 -m pytest -q tests/architecture/test_nui_baseline.py``
"""

from __future__ import annotations

import json
import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
RESOURCES = BASE / "resources"
PHONE = RESOURCES / "[custom]" / "custom-phone"
DIAG_CLIENT = PHONE / "client" / "core" / "diag.lua"
DIAG_SERVER = PHONE / "server" / "core" / "diag.lua"
BRIDGE = PHONE / "client" / "core" / "bridge.lua"
MAIN_CLIENT = PHONE / "client" / "main.lua"
VITE_CONFIG = PHONE / "web" / "vite.config.ts"
HTML_INDEX = PHONE / "html" / "index.html"

CB_GUARD_RE = re.compile(r"""type\s*\(\s*cb\s*\)\s*~=\s*['"]function['"]""")
CONVAR_INT_RE = re.compile(r"""GetConvarInt\s*\(\s*['"]phone_diag['"]\s*\)""")
HASHED_ASSET_RE = re.compile(r"""assets/[\w.-]+-[\w-]{6,}\.(?:js|css)""")
BARE_ASSET_RE = re.compile(r"""assets/index\.(?:js|css)""")
PHASE_LIST_RE = re.compile(r"-- 8 个请求域 phase")
SLOT_ARRAY_RE = re.compile(r"^(?P<indent>[ \t]*)(?P<arr>'(?:req\.[a-z]+\.[a-z]+',?\s*)+)$", re.M)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# 判定函数（纯文本，便于反向校验）
# ---------------------------------------------------------------------------


FUNC_HEADER_RE = re.compile(r"function\s*\(([^)]*)\)")


def _is_nui_handler_scope(text: str, position: int) -> bool:
    """守卫是否落在 NUI 回调处理器（`function(data, cb)`）里。

    只在这个作用域里 `cb` 才是"应答通道"。`PhoneBridge.Request(event, payload, cb,
    timeoutMs, …)` 的首个 `cb` 是调用方的完成回调，判 function 是合理的——所以规则
    不能对全仓的 `type(cb)` 一刀切。NUI 处理器的特征是：参数最多三个，且最后一个
    参数就叫 `cb`。
    """
    header = None
    for match in FUNC_HEADER_RE.finditer(text, 0, position):
        header = match
    if header is None:
        return False
    params = [part.strip() for part in header.group(1).split(",") if part.strip()]
    return bool(params) and len(params) <= 3 and params[-1] == "cb"


def check_cb_guard(text: str) -> list[str]:
    """禁止 NUI 回调处理器里 `type(cb) ~= 'function'` 这类会丢应答的守卫。"""
    return [
        m.group(0)
        for m in CB_GUARD_RE.finditer(text)
        if _is_nui_handler_scope(text, m.start())
    ]


def check_answer_channel(text: str) -> list[str]:
    """应答通道必须集中归一化，且覆盖三种形态。"""
    problems = []
    if "function PhoneBridge.AnswerFn" not in text:
        problems.append("missing PhoneBridge.AnswerFn")
    if "__cfx_functionReference" not in text:
        problems.append("AnswerFn does not handle a CFX function reference")
    if "__call" not in text:
        problems.append("AnswerFn does not handle a callable table (__call)")
    if "PhoneBridge.AnswerFn(cb)" not in text:
        problems.append("RegisterNui does not route the answer through AnswerFn")
    return problems


def check_convar_gate(text: str) -> list[str]:
    """`phone_diag` 的门禁不能用 GetConvarInt 判"是否设置"。"""
    return [m.group(0) for m in CONVAR_INT_RE.finditer(text)]


def check_trace_slot_parity(client_src: str, server_src: str) -> list[str]:
    """客户端 phase 顺序表与服务端映射表必须同序。

    客户端: `local REQ_PHASES = { 'req.nui.send', ... }`
    服务端: `slotsFromBatch` 里的 8 元数组
    """
    def phases(src: str) -> list[str]:
        block = re.search(r"local REQ_PHASES = \{(.*?)\}", src, re.S)
        if not block:
            return []
        return re.findall(r"'(req\.[a-z]+\.[a-z]+)'", block.group(1))

    def server_map(src: str) -> list[str]:
        block = re.search(r"slotsFromBatch[\s\S]{0,600}?\(\{(.*?)\}\)\[mark\[1\]\]", src, re.S)
        if not block:
            return []
        return re.findall(r"'(req\.[a-z]+\.[a-z]+)'", block.group(1))

    problems = []
    left, right = phases(client_src), server_map(server_src)
    if not left:
        problems.append("client REQ_PHASES not found")
    if not right:
        problems.append("server phase map not found")
    if left and right and left != right:
        problems.append(f"order mismatch: client={left} server={right}")
    return problems


def check_slots_observable(server_src: str) -> list[str]:
    """判定只允许使用 Lua 侧可观测的 6 个槽位。"""
    slot_line = re.search(r"local SLOT_ORDER = \{(.*?)\}", server_src)
    if not slot_line:
        return ["SLOT_ORDER not found"]
    slots = re.findall(r"'([A-Z]{2})'", slot_line.group(1))
    banned = [s for s in slots if s in {"NS", "ND"}]
    return [f"unobservable slot {s} in SLOT_ORDER" for s in banned]


def check_no_pii_projection(server_src: str) -> list[str]:
    """诊断投影不得透传业务 payload 或文本字段。"""
    banned_fields = ("payload", "citizenid", "message_body", "phone_number", "content")
    problems = []
    for field in banned_fields:
        if re.search(rf"msg\.{field}\b", server_src):
            problems.append(f"projection reads msg.{field}")
    return problems


def check_hashed_build(vite_src: str, html_src: str) -> list[str]:
    """产物必须内容哈希；index.html 不得引用无 hash 的 bundle。"""
    problems = []
    for key in ("entryFileNames", "chunkFileNames", "assetFileNames"):
        match = re.search(rf"{key}\s*:\s*['\"]([^'\"]+)['\"]", vite_src)
        if not match:
            problems.append(f"vite {key} missing")
        elif "[hash]" not in match.group(1):
            problems.append(f"vite {key} has no [hash]: {match.group(1)}")
    for bare in BARE_ASSET_RE.finditer(html_src):
        problems.append(f"index.html references unhashed {bare.group(0)}")
    if not HASHED_ASSET_RE.search(html_src):
        problems.append("index.html references no content-hashed asset")
    return problems


def check_diag_isolation(root: Path) -> list[str]:
    """`_diag` 是传输层保留字段：只允许出现在边界三处。"""
    allowed = {DIAG_CLIENT.resolve(), DIAG_SERVER.resolve(), BRIDGE.resolve(), MAIN_CLIENT.resolve()}
    problems = []
    for lua in root.rglob("*.lua"):
        if "node_modules" in lua.parts or lua.resolve() in allowed:
            continue
        try:
            text = lua.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if "_diag" in text:
            problems.append(str(lua.relative_to(root.parent)))
    return problems


# ---------------------------------------------------------------------------
# 仓库检查
# ---------------------------------------------------------------------------


def test_no_callback_type_guard_in_any_resource():
    offenders = []
    for lua in RESOURCES.rglob("*.lua"):
        if "node_modules" in lua.parts:
            continue
        try:
            text = lua.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for hit in check_cb_guard(text):
            offenders.append(f"{lua.relative_to(BASE)}: {hit}")
    assert not offenders, (
        "NUI 应答通道可能不是 function（可调用表 / CFX 函数引用），"
        "这类守卫会静默丢弃应答：\n" + "\n".join(offenders)
    )


def test_answer_channel_is_normalized():
    problems = check_answer_channel(read(BRIDGE))
    assert not problems, "PhoneBridge.AnswerFn 契约被破坏：" + "; ".join(problems)


def test_diag_gate_reads_the_convar_as_a_string():
    for path in (DIAG_CLIENT, DIAG_SERVER):
        problems = check_convar_gate(read(path))
        assert not problems, (
            f"{path.name}: convar 未定义时 GetConvarInt 返回 0，会被误判成关闭；"
            f"请用 GetConvar 读字符串：{problems}"
        )
        assert "GetConvar('phone_diag')" in read(path), f"{path.name}: 缺少 GetConvar 门禁"


def test_trace_slots_match_between_client_and_server():
    problems = check_trace_slot_parity(read(DIAG_CLIENT), read(DIAG_SERVER))
    assert not problems, "trace 相位表与服务端槽位映射不同序：" + "; ".join(problems)


def test_verdict_only_uses_observable_slots():
    problems = check_slots_observable(read(DIAG_SERVER))
    assert not problems, (
        "NUI 侧 NS/ND 无法在 Lua 侧证实，进判定会把成功请求误报成 seg4："
        + "; ".join(problems)
    )


def test_diag_projection_carries_no_business_payload():
    problems = check_no_pii_projection(read(DIAG_SERVER))
    assert not problems, "诊断投影不得读取业务字段：" + "; ".join(problems)


def test_nui_build_is_content_hashed():
    problems = check_hashed_build(read(VITE_CONFIG), read(HTML_INDEX))
    assert not problems, (
        "CEF 缓存资源页面，固定产物名会导致「改完不生效」：\n" + "\n".join(problems)
    )


def test_diag_reserved_field_stays_at_the_boundary():
    problems = check_diag_isolation(RESOURCES / "[custom]")
    assert not problems, "`_diag` 泄漏到边界之外的文件：" + ", ".join(problems)


def test_built_bundle_matches_the_committed_html():
    """`html/` 是提交进仓库的产物：不能指向一个已经不存在的文件。"""
    html = read(HTML_INDEX)
    refs = re.findall(r"""assets/([\w.-]+-[\w-]{6,}\.(?:js|css))""", html)
    assert refs, "index.html 没有引用任何 hashed 产物"
    for ref in set(refs):
        assert (PHONE / "html" / "assets" / ref).is_file(), f"index.html 指向不存在的产物：{ref}"


# ---------------------------------------------------------------------------
# 反向校验：规则本身必须能抓住错误形状
# ---------------------------------------------------------------------------


def test_rules_actually_fire_on_the_shapes_they_ban():
    # 1) 今天的根因
    handler_bad = "RegisterNUICallback('x', function(data, cb)\n    if type(cb) ~= 'function' then return end\nend)"
    assert check_cb_guard(handler_bad), "rule must fire inside a NUI handler"
    assert check_cb_guard("RegisterNUICallback('y', function(_, cb)\n  if type(cb) ~= \"function\" then return end\nend)")
    assert not check_cb_guard("local answer = PhoneBridge.AnswerFn(cb)")
    # 调用方完成回调（非应答通道）不在规则范围内
    assert not check_cb_guard("function PhoneBridge.Request(event, payload, cb, timeoutMs, responseEvent, trace)\n"
                              "    if type(cb) ~= 'function' then return nil end\nend")

    # 2) convar 误判
    assert check_convar_gate("local v = GetConvarInt('phone_diag')")
    assert not check_convar_gate("local raw = GetConvar('phone_diag')")

    # 3) 槽位不同序
    client_bad = "local REQ_PHASES = {\n    'req.cli.recv',\n    'req.nui.send',\n}"
    server_bad = "slotsFromBatch ... ({'req.nui.send', 'req.cli.recv'})[mark[1]]"
    assert check_trace_slot_parity(client_bad, server_bad)

    # 4) 不可观测槽位回归
    assert check_slots_observable("local SLOT_ORDER = { 'NS', 'CR', 'ND' }")
    assert not check_slots_observable("local SLOT_ORDER = { 'CR', 'CF', 'SR', 'SD', 'CP', 'CA' }")

    # 5) 产物名无 hash
    vite_bad = "entryFileNames: 'assets/[name].js', chunkFileNames: 'assets/[name].js', assetFileNames: 'assets/[name].[ext]'"
    html_bad = '<script type="module" src="./assets/index.js"></script>'
    assert check_hashed_build(vite_bad, html_bad)
    vite_ok = ("entryFileNames: 'assets/[name]-[hash].js', chunkFileNames: 'assets/[name]-[hash].js', "
               "assetFileNames: 'assets/[name]-[hash].[ext]'")
    html_ok = '<script type="module" src="./assets/index-AbCd12Ef.js"></script>'
    assert not check_hashed_build(vite_ok, html_ok)

    # 6) PII 投影
    assert check_no_pii_projection("out.payload = msg.payload")
    assert not check_no_pii_projection("out.tid = validTraceId(msg.tid)")


def test_allowlist_registries_are_valid_json():
    """同级目录的债务清单必须能被解析（避免 merge 冲突后的语法残留）。"""
    for path in Path(__file__).with_name("nui_client_allowlist.json").parent.glob("*.json"):
        json.loads(path.read_text(encoding="utf-8"))
