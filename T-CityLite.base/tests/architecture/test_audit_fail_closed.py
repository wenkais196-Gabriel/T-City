"""FIT-05 — a sensitive read must fail closed when the audit row cannot be written.

Static, offline contract over ``custom-police/server/*.lua``:

R1 (fail-open shape): a line whose first token is ``audit(`` / ``auditPlayer(``
    discards the boolean. Every audit call must consume it —
    ``if not audit(...) then ... end`` or ``local ok = audit(...)``. Writes may
    stay best-effort, but then they must log (``if not audit(...) then print``).
R2 (missing audit): a function that gates a sensitive read
    (``PolicePolicy.Can(actor, '<cap>.view' | '.detail' | '.chain')``) must audit
    that read and refuse it with ``false, 'audit_unavailable'`` when the audit
    write fails. Delegating to a verified gate helper (``lookupAllowed``) counts
    only when the helper itself is checked here.

Plus the three reads named by the FIT-05 brief: ``GetCitations`` / ``GetReports``
must audit *before* the query, and ``GetAudit`` must audit itself with a direct
INSERT (never by calling ``GetAudit`` again).

    python3 -m pytest -q tests/architecture/test_audit_fail_closed.py
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
POLICE_SERVER = BASE / "resources" / "[custom]" / "custom-police" / "server"

# A standalone `audit(...)` / `auditPlayer(...)` statement: the return value is
# thrown away. Consumed shapes (`if not audit(`, `local ok = audit(`) do not
# match because they do not start with the call.
DISCARDED_AUDIT_RE = re.compile(r"^\s*(?:audit|auditPlayer)\s*\(")

FUNCTION_RE = re.compile(r"^(?:local )?function\s+(?P<name>[A-Za-z_][\w.:]*)\s*\(")
END_RE = re.compile(r"^end\s*$")

CAN_RE = re.compile(r"PolicePolicy\.Can\(\s*[^,]+,\s*'(?P<cap>[\w.]+)'")
SENSITIVE_SUFFIXES = (".view", ".detail", ".chain")
SENSITIVE_PREFIXES = ("lookup.",)

# Gate helpers that perform the fail-closed audit on behalf of the caller.
# Verified in test_gate_helpers_are_really_fail_closed.
GATE_HELPERS = {
    "lookupAllowed": (POLICE_SERVER / "p0_read.lua", "local ok = audit("),
}

FAIL_CLOSED_RE = re.compile(
    r"if\s+not\s+audit\(|"
    r"local\s+\w+\s*=\s*audit\(|"
    r"local\s+\w+,\s*\w+\s*=\s*audit\("
)


@dataclass(frozen=True)
class Function:
    name: str
    path: Path
    line: int
    body: str

    @property
    def where(self) -> str:
        return f"{self.path.name}:{self.line} {self.name}"


def lua_files() -> list[Path]:
    assert POLICE_SERVER.is_dir(), f"missing {POLICE_SERVER}"
    return sorted(POLICE_SERVER.rglob("*.lua"))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def functions() -> list[Function]:
    found: list[Function] = []
    for path in lua_files():
        lines = read(path).splitlines()
        for index, line in enumerate(lines):
            match = FUNCTION_RE.match(line)
            if not match:
                continue
            body: list[str] = []
            cursor = index + 1
            while cursor < len(lines) and not END_RE.match(lines[cursor]):
                body.append(lines[cursor])
                cursor += 1
            found.append(
                Function(name=match.group("name"), path=path, line=index + 1,
                         body="\n".join(body))
            )
    return found


def discarded_audits() -> list[str]:
    findings: list[str] = []
    for path in lua_files():
        for index, line in enumerate(read(path).splitlines()):
            if DISCARDED_AUDIT_RE.match(line):
                findings.append(f"{path.name}:{index + 1} {line.strip()}")
    return findings


def sensitive_functions() -> list[Function]:
    out: list[Function] = []
    for func in functions():
        caps = CAN_RE.findall(func.body)
        sensitive = any(
            cap.endswith(SENSITIVE_SUFFIXES) or cap.startswith(SENSITIVE_PREFIXES)
            for cap in caps
        )
        # `lookupAllowed(source, 'lookup.citizen')` hides the capability behind
        # the gate helper, which is itself a sensitive-read gate.
        if sensitive or gate_helper_call(func.body):
            out.append(func)
    return out


def gate_helper_call(body: str) -> str | None:
    for helper in GATE_HELPERS:
        if re.search(rf"\b{re.escape(helper)}\(", body):
            return helper
    return None


def is_fail_closed(func: Function) -> bool:
    if not FAIL_CLOSED_RE.search(func.body):
        return False
    if "'audit_unavailable'" in func.body:
        return True
    # Delegated: the gate helper returns (nil, 'audit_unavailable') and the
    # caller propagates `err`.
    return gate_helper_call(func.body) is not None and "return false, err" in func.body


def get_citations() -> Function:
    for func in functions():
        if func.name == "P1.GetCitations":
            return func
    raise AssertionError("P1.GetCitations is gone — FIT-05 baseline moved")


def get_reports() -> Function:
    for func in functions():
        if func.name == "P1.GetReports":
            return func
    raise AssertionError("P1.GetReports is gone — FIT-05 baseline moved")


def get_audit() -> Function:
    for func in functions():
        if func.name == "P.GetAudit":
            return func
    raise AssertionError("P.GetAudit is gone — FIT-05 baseline moved")


def report() -> str:
    bad = discarded_audits()
    missing = [f.where for f in sensitive_functions() if not is_fail_closed(f)]
    lines = [f"FIT-05 audit-fail-closed  {'FAIL' if (bad or missing) else 'PASS'}"]
    lines += [f"  {finding}  audit_result_discarded" for finding in bad]
    lines += [f"  {finding}  sensitive_read_not_fail_closed" for finding in missing]
    lines.append(
        '  summary: {"rule":"FIT-05","sensitive_reads":%d,"discarded":%d,"violations":%d}'
        % (len(sensitive_functions()), len(bad), len(bad) + len(missing))
    )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# R1 — no audit call may silently drop its result
# ---------------------------------------------------------------------------

def test_no_audit_call_discards_its_result():
    findings = discarded_audits()
    assert findings == [], (
        "FIT-05: audit() result ignored — a DB hiccup would silently lose the "
        "forensic row. Wrap it as `if not audit(...) then return false, "
        "'audit_unavailable' end` (sensitive read) or "
        "`if not audit(...) then print(...) end` (best-effort write):\n  "
        + "\n  ".join(findings)
    )


def test_audit_helpers_delegate_to_the_single_writer():
    """审计只有一份实现（server/audit.lua），各文件的同名包装必须委派给它。

    历史：这里原本要求每个 helper 自己 `return pcall(...)`。那个形状正是 bug 的来源——
    oxmysql 把 SQL 错误当**返回值**（字符串）给，pcall 仍然返回 true，于是
    `if not audit(...)` 把失败当成功、审计行静默丢失。唯一写者改为检查返回类型后，
    这条规则就变成"包装必须委派 + 写者必须严格返回布尔"。
    """
    checked = 0
    for path in lua_files():
        if path.name == "audit.lua":
            continue                      # 写者本身，由 test_police_single_writer 检查
        source = read(path)
        for match in re.finditer(
            r"^(?:local )?function (audit|auditPlayer|auditNpc)\(.*?\n(.*?)^end\s*$",
            source,
            re.DOTALL | re.MULTILINE,
        ):
            body = match.group(2)
            assert "PoliceAudit.Write(" in body or "PoliceAudit.WriteAgent(" in body, (
                f"{path.name}: {match.group(1)}() 必须委派给 PoliceAudit（审计的唯一写者），"
                f"不要在本地重写 INSERT")
            checked += 1
    assert checked >= 7, f"只有 {checked} 个审计包装被检查到 —— 扫描器坏了？"

    owner = read(POLICE_SERVER / "audit.lua")
    assert "type(result) == 'string'" in owner, (
        "写者必须把数据库返回的错误字符串判为失败，否则审计仍然可以静默丢失")
    assert "return true" in owner and "return false" in owner


# ---------------------------------------------------------------------------
# R2 — sensitive reads audit themselves and fail closed
# ---------------------------------------------------------------------------

def test_every_sensitive_read_is_fail_closed():
    sensitive = sensitive_functions()
    assert len(sensitive) >= 8, (
        f"only {len(sensitive)} sensitive reads found — the scanner or the "
        f"capability table regressed"
    )
    broken = [func.where for func in sensitive if not is_fail_closed(func)]
    assert broken == [], (
        "FIT-05: these functions gate a sensitive read (case/evidence/audit "
        "view) but do not refuse the read when audit() fails:\n  "
        + "\n  ".join(broken)
    )


def test_gate_helpers_are_really_fail_closed():
    for helper, (path, token) in GATE_HELPERS.items():
        source = read(path)
        match = re.search(
            rf"(?:local )?function {re.escape(helper)}\([^)]*\)(.*?)^end\s*$",
            source,
            re.DOTALL | re.MULTILINE,
        )
        assert match, f"gate helper {helper} disappeared from {path.name}"
        assert token in match.group(1), (
            f"gate helper {helper} no longer consumes audit() — every read "
            f"delegating to it is fail-open again"
        )
        assert "'audit_unavailable'" in match.group(1), (
            f"gate helper {helper} no longer returns audit_unavailable"
        )


# ---------------------------------------------------------------------------
# The three reads named by the brief
# ---------------------------------------------------------------------------

def test_get_citations_and_reports_audit_before_the_query():
    for func, action in ((get_citations(), "citation.view"), (get_reports(), "report.view")):
        assert f"'{action}'" in func.body, f"{func.name} lost its {action} audit"
        audit_at = func.body.find("audit(")
        query_at = func.body.find("MySQL.")
        assert audit_at != -1, f"{func.name} has no audit at all"
        assert query_at != -1, f"{func.name} no longer queries anything?"
        assert audit_at < query_at, (
            f"{func.where}: the audit row is written after the query — audit "
            f"first so a failed write never releases the rows"
        )
        assert "'audit_unavailable'" in func.body, (
            f"{func.name} must return false, 'audit_unavailable' when audit fails"
        )


def test_get_audit_audits_itself_without_recursing():
    func = get_audit()
    # Self-audit lives in the handler; a call to GetAudit( inside its own body
    # would recurse forever.
    assert "GetAudit(" not in func.body, "P.GetAudit calls itself — recursion"
    assert "audit(" in func.body, "P.GetAudit is not audited"
    assert "'audit.view'" in func.body or "audit.view" in func.body, (
        "P.GetAudit must record an audit.view action"
    )
    assert "'audit_unavailable'" in func.body, (
        "P.GetAudit must fail closed when the audit write fails"
    )
    # The write goes through the file's audit() wrapper → the single writer
    # (server/audit.lua), never through GetAudit itself.
    source = read(func.path)
    # 拆分后 audit() 这个包装在 p0.lua（核心），读面模块按名字绑进来（I.audit）
    assert ("PoliceAudit.Write" in source or "local function audit(" in source
            or "I.audit" in source), (
        "P.GetAudit 的自审计必须经 audit() 包装 → PoliceAudit.Write")


def test_evidence_and_case_views_use_the_same_contract():
    """The evidence/case read paths must not drift back to fail-open."""
    wanted = {
        "EV.Get": "evidence.view",
        "EV.GetChain": "evidence.chain",
        "C.GetCaseDetail": "case.detail",
        "C.GetCases": "case.view",
        "C.GetBolos": "bolo.view",
        "C.GetWarrants": "warrant.view",
    }
    by_name = {func.name: func for func in functions()}
    for name, action in wanted.items():
        func = by_name[name]
        assert f"'{action}'" in func.body, f"{name} lost its {action} audit"
        assert is_fail_closed(func), f"{name} is fail-open again"


if __name__ == "__main__":  # pragma: no cover - manual runner
    print(report())
