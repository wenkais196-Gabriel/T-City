"""双形态（手机 / 平板）的三道闸门。

这三条规则存在的理由只有一个：**不许手机和平板慢慢长成两个产品。**

A. 一个 app 只有一个组件 —— 出现 `*Tablet.svelte` 或改名不改体的副本就会红；
B. 用 AppSurface 的 app 必须有 pane 契约，且契约与 DOM 的 `data-pane` 双向相等；
C. surface 不许放大权限 —— 服务端不读 surface、app 不按 surface 取数、平板专属授权必须为空。

每个测试都**自带反向校验**：先在真实仓库上跑一遍（要求干净），再把坏形状写进 tmp 目录，
用同一个扫描函数断言它会红。一条不会红的闸门不是闸门，所以不允许"只扫真仓库"的写法。
"""
from __future__ import annotations

import re
from pathlib import Path

PHONE = Path(__file__).resolve().parents[2] / "resources" / "[custom]" / "custom-phone"
APPS = PHONE / "web/src/apps"
CONTRACTS = APPS / "contracts"
#: 只有**服务端**脚本不许读 surface；客户端正是做判定的地方（client/core/surface_rules.lua）
SERVERS = [
    PHONE / "server",
    Path(__file__).resolve().parents[2] / "resources" / "[custom]" / "custom-police/server",
]

FORBIDDEN_NAME = re.compile(r"(Tablet|Phone)(App)?\.svelte$", re.IGNORECASE)
PANE_ATTR = re.compile(r'data-pane="([\w-]+)"|id="([\w-]+)"\s*(?=[^>]*\bpane\b)', re.IGNORECASE)
CONTRACT_PANE = re.compile(r"\{\s*id:\s*'([\w-]+)'")
IMPORTER = re.compile(r"from\s+'\./contracts/([\w.-]+)\.panes'")


def _strip_lua_comments(text: str) -> str:
    return "\n".join(re.sub(r"--.*$", "", line) for line in text.split("\n"))


def _shingles(text: str, size: int = 5) -> set[str]:
    tokens = re.findall(r"[A-Za-z_][A-Za-z0-9_]*|[{}()<>=;]", text)
    return {" ".join(tokens[i:i + size]) for i in range(max(0, len(tokens) - size + 1))}


# ---------------------------------------------------------------------------
# A. 不许有按形态分叉的组件
# ---------------------------------------------------------------------------
def fork_violations(apps_dir: Path) -> list[str]:
    problems: list[str] = []
    files = sorted(apps_dir.rglob("*.svelte"))
    for path in files:
        if FORBIDDEN_NAME.search(path.name):
            problems.append(f"{path.name}: 按形态分叉的组件（一个 app 只能一个组件）")

    # 改名不改体：两个都含 appQuery/appAction 的组件，5-gram 相似度 ≥ 0.9 视为副本
    shingles = {p: _shingles(p.read_text(encoding="utf-8", errors="ignore")) for p in files}
    for index, left in enumerate(files):
        for right in files[index + 1:]:
            a, b = shingles[left], shingles[right]
            if not a or not b:
                continue
            union = len(a | b)
            if union == 0:
                continue
            similarity = len(a & b) / union
            if similarity >= 0.9:
                problems.append(f"{left.name} ≈ {right.name}: 相似度 {similarity:.2f}，疑似改名副本")
    return problems


# ---------------------------------------------------------------------------
# B. pane 契约与 DOM 必须对得上
# ---------------------------------------------------------------------------
def contract_violations(apps_dir: Path) -> list[str]:
    problems: list[str] = []
    contracts = apps_dir / "contracts"
    sources = {p: p.read_text(encoding="utf-8", errors="ignore") for p in apps_dir.rglob("*.svelte")}

    used = {}
    for path, text in sources.items():
        match = IMPORTER.search(text)
        if "AppSurface" in text and not match:
            problems.append(f"{path.name}: 用了 AppSurface 但没有 pane 契约（布局会长在组件里）")
            continue
        if not match:
            continue
        contract_file = contracts / f"{match.group(1)}.panes.ts"
        if not contract_file.is_file():
            problems.append(f"{path.name}: 引用的契约 {contract_file.name} 不存在")
            continue
        contract_text = contract_file.read_text(encoding="utf-8")
        contract_panes = set(CONTRACT_PANE.findall(contract_text))
        used[contract_file.name] = path.name

        dom_panes = set(re.findall(r'<Pane\s+id="([\w-]+)"', text))
        if dom_panes != contract_panes:
            problems.append(
                f"{path.name}: DOM 的 pane {sorted(dom_panes)} 与契约 {sorted(contract_panes)} 不一致")

    for contract in contracts.glob("*.panes.ts"):
        if contract.name not in used:
            problems.append(f"{contract.name}: 没有任何组件引用这份契约（孤儿契约）")
        if "TABLET_GRANTS" not in contract.read_text(encoding="utf-8"):
            problems.append(f"{contract.name}: 缺少 TABLET_GRANTS（必须显式声明平板不多拿任何东西）")
    return problems


def tablet_grants(contracts_dir: Path) -> list[str]:
    """TABLET_GRANTS 里任何非空数组都算"平板多要了东西"，必须走服务端注册与守卫。"""
    problems: list[str] = []
    for contract in contracts_dir.glob("*.panes.ts"):
        text = contract.read_text(encoding="utf-8")
        match = re.search(r"TABLET_GRANTS\s*=\s*\{(.*?)\}", text, re.S)
        if not match:
            continue
        for key, value in re.findall(r"(\w+)\s*:\s*\[([^\]]*)\]", match.group(1)):
            items = [item for item in re.split(r"[,\s]+", value) if item]
            if items:
                problems.append(f"{contract.name}: TABLET_GRANTS.{key} 非空 {items}（平板不许多拿数据）")
    return problems


# ---------------------------------------------------------------------------
# C. surface 不许出现在权限/取数路径上
# ---------------------------------------------------------------------------
def surface_leak_violations(server_dirs: list[Path], apps_dir: Path) -> list[str]:
    problems: list[str] = []
    for directory in server_dirs:
        if not directory.is_dir():
            continue
        for path in directory.rglob("*.lua"):
            code = _strip_lua_comments(path.read_text(encoding="utf-8", errors="ignore"))
            if re.search(r"\bsurface\b", code, re.IGNORECASE):
                problems.append(f"{path}: 服务端读了 surface（权限就会多出一个不可审计的维度）")
    for path in apps_dir.rglob("*.svelte"):
        text = path.read_text(encoding="utf-8", errors="ignore")
        # app 只能用 AppSurface 的 mode（容器宽度），不能自己判断形态
        if re.search(r"\bsurface\b", text) and "AppSurface" not in text:
            problems.append(f"{path.name}: app 直接引用 surface（应按容器宽度排布）")
    return problems


# ---------------------------------------------------------------------------
# pytest contract：每条闸门都自带反向校验
# ---------------------------------------------------------------------------
def test_app_fork_gate_catches_named_clones_and_near_duplicates(tmp_path: Path) -> None:
    assert fork_violations(APPS) == [], "真实仓库里出现了按形态分叉的 app 组件：\n" + "\n".join(fork_violations(APPS))

    clone = tmp_path / "PoliceMDTTablet.svelte"
    clone.write_text((APPS / "PoliceMDT.svelte").read_text(encoding="utf-8"), encoding="utf-8")
    assert any("分叉" in item for item in fork_violations(tmp_path)), "改名副本没有被抓到"

    # 改名不改体：两个不同文件名但内容相同的组件
    (tmp_path / "PoliceMDTTablet.svelte").unlink()
    (tmp_path / "Alpha.svelte").write_text(
        "<script>import { queryApp } from '../core/request';</script><button on:click={() => queryApp('a','b',{})}>x</button>",
        encoding="utf-8")
    (tmp_path / "Beta.svelte").write_text(
        "<script>import { queryApp } from '../core/request';</script><button on:click={() => queryApp('a','b',{})}>x</button>",
        encoding="utf-8")
    assert any("副本" in item for item in fork_violations(tmp_path)), "近重复副本没有被抓到"


def test_pane_contract_gate_detects_missing_contracts_and_undeclared_panes(tmp_path: Path) -> None:
    problems = contract_violations(APPS)
    assert problems == [], "pane 契约与 DOM 不一致：\n" + "\n".join(problems)
    assert tablet_grants(CONTRACTS) == [], "TABLET_GRANTS 必须为空：\n" + "\n".join(tablet_grants(CONTRACTS))

    sandbox = tmp_path / "apps"
    (sandbox / "contracts").mkdir(parents=True)
    (sandbox / "Ghost.svelte").write_text(
        "<script>import AppSurface from '../components/AppSurface.svelte';</script><AppSurface>{#snippet x()}{/snippet}</AppSurface>",
        encoding="utf-8")
    assert any("没有 pane 契约" in item for item in contract_violations(sandbox)), "缺契约没有被抓到"

    (sandbox / "Ghost.svelte").write_text(
        "<script>import AppSurface from '../components/AppSurface.svelte';\n"
        "import { PANE_CONTRACT as X } from './contracts/ghost.panes';</script>\n"
        '<AppSurface><Pane id="list"></Pane><Pane id="sneaky"></Pane></AppSurface>',
        encoding="utf-8")
    (sandbox / "contracts/ghost.panes.ts").write_text(
        "export const PANE_CONTRACT = { panes: [{ id: 'list' }] };\n"
        "export const TABLET_GRANTS = { queries: [], actions: [], fields: [] };\n",
        encoding="utf-8")
    assert any("不一致" in item for item in contract_violations(sandbox)), "DOM 多出来的 pane 没有被抓到"

    (sandbox / "contracts/ghost.panes.ts").write_text(
        "export const PANE_CONTRACT = { panes: [{ id: 'list' }] };\n"
        "export const TABLET_GRANTS = { queries: ['audit'], actions: [], fields: [] };\n",
        encoding="utf-8")
    assert tablet_grants(sandbox / "contracts"), "平板多拿数据没有被抓到"


def test_surface_guard_detects_server_branches_and_surface_gated_apps(tmp_path: Path) -> None:
    problems = surface_leak_violations(SERVERS, APPS)
    assert problems == [], "surface 泄漏进权限/取数路径：\n" + "\n".join(problems)

    server = tmp_path / "server"
    server.mkdir()
    (server / "rogue.lua").write_text(
        "if params.surface == 'tablet' then return { ok = true } end\n", encoding="utf-8")
    assert surface_leak_violations([server], APPS), "服务端按 surface 分支没有被抓到"

    apps = tmp_path / "apps"
    apps.mkdir()
    (apps / "Loose.svelte").write_text(
        "<script>const surface = 'tablet';</script>", encoding="utf-8")
    assert surface_leak_violations([], apps), "app 自己判断形态没有被抓到"

    # 注释里提到 surface 不算违规（说明"为什么不用"是允许的）
    (server / "rogue.lua").write_text("-- surface 只在客户端用\nreturn true\n", encoding="utf-8")
    assert surface_leak_violations([server], tmp_path / "empty") == [], "注释里的提及被误判"
