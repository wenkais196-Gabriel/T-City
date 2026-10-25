"""CLI-01：客户端可观测性必须真的接上，而不只是写在文档里。

core-framework 的 client/shared.lua 提供两件事：

- ``CFShared.Report`` —— 客户端异常上行（带资源名、版本、去控制字符、限流）；
- 就绪信标 —— 资源加载后 1.5 秒发一行日志，用来回答"新代码到没到客户端"。

它靠**加载期包含**接入（``@core-framework/client/shared.lua`` 必须是 client_scripts
的第一项），因为每帧都可能调用的助手不能走 exports（调用开销 + 启动顺序耦合）。

闸门存在的理由：这份文档写了很久，但只有 custom-phone / custom-police 真接上了，
其余 20 多个资源的客户端错误根本没有上行通道 —— 文档在撒谎，而没人发现。
所以这里不是"检查有没有文档"，是"检查每个自己能改的资源有没有那一行"。

每条规则都自带**构造坏形状 → 断言能看见**的反向校验（闸门自己也要被检验），
同时对真实仓库跑一遍当前状态。
"""

from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
RESOURCES = BASE / "resources"
HELPER = "@core-framework/client/shared.lua"

#: 提供该助手的资源自己不包含（它就是这份文件的来源）。
PROVIDER = "core-framework"

#: 不迁移的第三方目录：改动会与上游升级冲突，且它们的错误上行不在我们掌控范围。
UPSTREAM_DIRS = ("[qb]", "[cfx-default]", "[voice]", "[defaultmaps]")

#: 放在 [standalone] 里的 vendored 库（作者不是本项目）：注入自家助手等于改第三方代码。
VENDORED = (
    "PolyZone",
    "bob74_ipl",
    "menuv",
    "safecracker",
    "oxmysql",
    "progressbar",
    "interact-sound",
    "cartel-gates",
)

#: 我们自己写、但暂时接不上的资源 → 必须写清"为什么还不能"。
EXCEPTIONS: dict[str, str] = {
    "atom_nodes": "启动早于 core-framework（cfg 第 2 位），@ 包含会在加载期找不到文件；要接入得先调整启动顺序",
    "aaa_silence": "启动早于 core-framework（cfg 第 1 位），同上",
    "production-freeze": "与 core-framework 成环：core-framework 依赖它（_L i18n 必须先于 bus.lua 加载），它不能反向包含 core-framework 的客户端文件",
    "monitor": "不在启动链里（运维用，手动 ensure），没有运行时就不需要就绪信标",
    "notify-test": "不在启动链里（压测/联调用，手动 ensure）",
}


# ---------------------------------------------------------------------------
# 纯函数：给定文本 / 资源表，返回问题清单（空 = 通过）
# ---------------------------------------------------------------------------


def parse_client_scripts(text: str) -> list[str] | None:
    """按出现顺序取 client 脚本条目。

    两种写法都要认：``client_scripts { 'a.lua', 'b.lua' }``（块，可单行）与
    ``client_script 'a.lua'``（单数）。只认块的话，资源改写成单数形式就能悄悄
    绕开这条闸门——那正是"规则有盲点，于是被盲点绕过去"的老问题。
    """
    entries: list[tuple[int, str]] = []

    for match in re.finditer(r"\bclient_scripts\s*\{", text):
        start = match.end() - 1
        depth = 0
        end = None
        for idx in range(start, len(text)):
            char = text[idx]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    end = idx
                    break
        if end is None:  # pragma: no cover - 语法错误由 test_manifest_syntax 负责报
            continue
        body = text[start + 1:end]
        for item in re.finditer(r"'([^']+)'|\"([^\"]+)\"", body):
            entries.append((start + item.start(), item.group(1) or item.group(2)))

    for match in re.finditer(r"\bclient_script\s+(['\"])([^'\"]+)\1", text):
        entries.append((match.start(), match.group(2)))

    if not entries and "client_script" not in text:
        return None
    entries.sort(key=lambda pair: pair[0])
    return [value for _, value in entries]


def missing_helpers(resources: dict[str, str]) -> list[str]:
    """{资源名: manifest 文本} → 缺包含且未登记豁免的资源名。"""
    out = []
    for name, text in resources.items():
        if name in EXCEPTIONS:
            continue
        if HELPER not in (parse_client_scripts(text) or []):
            out.append(name)
    return sorted(out)


def misordered_helpers(resources: dict[str, str]) -> list[str]:
    """{资源名: manifest 文本} → 包含存在但不在第一位的资源名。"""
    out = []
    for name, text in resources.items():
        scripts = parse_client_scripts(text) or []
        if HELPER in scripts and scripts[0] != HELPER:
            out.append(name)
    return sorted(out)


def stale_exceptions(resources: dict[str, str]) -> list[str]:
    """登记了豁免、但已经接入的资源（理由过期）。"""
    return sorted(
        name
        for name, text in resources.items()
        if name in EXCEPTIONS and HELPER in (parse_client_scripts(text) or [])
    )


def vanished_exceptions(known_names: set[str]) -> list[str]:
    """登记了豁免、但仓库里根本没有这个资源。"""
    return sorted(name for name in EXCEPTIONS if name not in known_names)


# ---------------------------------------------------------------------------
# 真实仓库的读取
# ---------------------------------------------------------------------------


@lru_cache(maxsize=1)
def own_client_texts() -> dict[str, str]:
    """我们自己的、带 client 脚本的资源 → manifest 文本。"""
    found: dict[str, str] = {}
    for manifest in RESOURCES.rglob("fxmanifest.lua"):
        parts = manifest.parent.relative_to(RESOURCES).parts
        if len(parts) < 2 or parts[0] in UPSTREAM_DIRS:
            continue
        name = parts[1]
        if name == PROVIDER or name in VENDORED:
            continue
        text = manifest.read_text(encoding="utf-8", errors="replace")
        if parse_client_scripts(text) is None:
            continue
        found[name] = text
    return found


@lru_cache(maxsize=1)
def all_resource_names() -> set[str]:
    return {p.name for p in RESOURCES.glob("*/*") if p.is_dir()}


@lru_cache(maxsize=1)
def started_resources() -> set[str]:
    """cfg 链里真正会被 ensure 的资源名（与接线闸门同一套解析）。"""
    import sys

    here = Path(__file__).resolve().parent
    if str(here) not in sys.path:
        sys.path.insert(0, str(here))
    import test_resource_wiring

    resources, _ = test_resource_wiring.configured_resources()
    return set(resources)


def started_own_texts() -> dict[str, str]:
    started = started_resources()
    return {name: text for name, text in own_client_texts().items() if name in started}


# ---------------------------------------------------------------------------
# 规则：每条都先构造坏形状证明能红，再看真实仓库
# ---------------------------------------------------------------------------

BAD_WITHOUT_HELPER = "client_scripts {\n    'client/main.lua'\n}\n"
GOOD = "client_scripts {\n    '%s',\n    'client/main.lua'\n}\n" % HELPER


def test_include_rule_detects_a_missing_helper():
    """构造一个不包含 helper 的资源 → 必须被点名；然后检查真实仓库。"""
    probe = {"ghost": BAD_WITHOUT_HELPER, "fine": GOOD}
    assert missing_helpers(probe) == ["ghost"], "规则看不见缺包含的资源"

    missing = missing_helpers(started_own_texts())
    assert not missing, (
        "这些资源的客户端错误没有上行通道（缺 " + HELPER + "）："
        + ", ".join(missing)
        + "\n接入方式见 docs/agent/CLIENT_OBSERVABILITY.md；接不上的登记到 EXCEPTIONS 并写清原因。"
    )


def test_order_rule_rejects_helper_that_is_not_first():
    """helper 排在别的脚本之后 → 必须被点名（加载期就调 CFShared 时会拿到 nil）。"""
    probe = {
        "late": "client_scripts {\n    'client/a.lua',\n    '%s'\n}\n" % HELPER,
        "fine": GOOD,
    }
    assert misordered_helpers(probe) == ["late"]

    wrong = misordered_helpers(started_own_texts())
    assert not wrong, "加载期包含必须排在第一位：" + ", ".join(wrong)


def test_exception_list_rejects_stale_and_vanished_entries():
    """豁免双向校验：已接入还登记着 → 红；登记的资源没了 → 红。"""
    stale_probe = {name: GOOD for name in EXCEPTIONS}
    assert stale_exceptions(stale_probe) == sorted(EXCEPTIONS), "已接入的资源仍被当成豁免"
    assert vanished_exceptions({"only-me"}) == sorted(EXCEPTIONS), "消失的资源没被告发"

    assert not stale_exceptions(own_client_texts()), "这些资源已经接入，EXCEPTIONS 里的理由过期了"
    assert not vanished_exceptions(all_resource_names()), "EXCEPTIONS 里的资源已不存在，删掉对应条目"


def test_parser_catches_both_block_and_singular_forms():
    """块写法（含单行）与单数写法都要认——否则换个写法就能绕过闸门。"""
    assert parse_client_scripts(GOOD) == [HELPER, "client/main.lua"]
    assert parse_client_scripts("client_script '%s'\nclient_script 'client/b.lua'\n" % HELPER) == [
        HELPER,
        "client/b.lua",
    ]
    assert parse_client_scripts("client_scripts { 'a.lua', 'b.lua' }\n") == ["a.lua", "b.lua"]
    assert parse_client_scripts("server_scripts {\n    'server/main.lua'\n}\n") is None
    # 单数写法漏了 helper，规则必须看得见
    assert missing_helpers({"single": "client_script 'client/main.lua'\n"}) == ["single"]


def test_scope_rule_catches_an_empty_registry():
    """防止"扫描范围为空 → 永远绿"。"""
    assert missing_helpers({}) == []
    checked = started_own_texts()
    assert len(checked) >= 20, f"只扫到 {len(checked)} 个自有客户端资源，范围被改坏了？"


def test_exemption_rot_rejects_touched_vendored_code():
    """结构性豁免（上游目录 / vendored 库）也要双向校验。"""
    missing_dirs = [d for d in UPSTREAM_DIRS if not (RESOURCES / d).is_dir()]
    assert not missing_dirs, "这些目录已经不存在，更新 UPSTREAM_DIRS：" + ", ".join(missing_dirs)

    gone, touched = [], []
    for name in VENDORED:
        hits = list(RESOURCES.glob(f"*/{name}"))
        if not hits:
            gone.append(name)
            continue
        for fx in hits:
            manifest = fx / "fxmanifest.lua"
            if manifest.is_file() and HELPER in manifest.read_text(encoding="utf-8", errors="replace"):
                touched.append(str(fx.relative_to(RESOURCES)))
    assert not gone, "这些 vendored 库已不存在，更新 VENDORED：" + ", ".join(gone)
    assert not touched, "第三方库里出现了自家助手的包含（不要在 vendored 代码里注入）：" + ", ".join(touched)


def test_allowlist_mirror_rejects_drift():
    """给工具/agent 读的镜像必须与测试里的名单一致（两边漂移就红）。"""
    data = json.loads((Path(__file__).resolve().parent / "client_observability.json").read_text(encoding="utf-8"))
    assert data["helper"] == HELPER
    assert sorted(data["exceptions"]) == sorted(EXCEPTIONS)
    assert data["upstream_dirs"] == list(UPSTREAM_DIRS)
    assert data["vendored"] == list(VENDORED)
