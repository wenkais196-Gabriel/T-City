"""OPS-01 — 启动自检脚本本身要被当成契约来测。

`tools/ops/healthcheck.py` 的意义是把「84 资源 / 0 SCRIPT ERROR」从人眼判断变成一条命令的
退出码。它一旦自己出错，最危险的失败模式是**假绿**：脚本说"服务器好着"，其实是它没解析
出来。所以这个文件里每条规则都是**反向形状**：喂坏输入，要求它红。

    python3 -m pytest -q tests/architecture/test_ops_healthcheck.py
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
TOOL = REPO / "tools" / "ops" / "healthcheck.py"


def _load_module():
    """从路径加载 tools/ops/healthcheck.py（tools/ 不是包）。"""
    assert TOOL.is_file(), f"缺少工具: {TOOL}"
    spec = importlib.util.spec_from_file_location("ops_healthcheck", TOOL)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("ops_healthcheck", module)
    spec.loader.exec_module(module)
    return module


GOOD_LOG = """\
[    script:qb-core] Started resource qb-core
[    script:qb-inventory] Started resource qb-inventory
[           resources] Started resource custom-phone
[ script:story-engine] ✅ 剧情引擎已启动 (v0.7.0)
[ script:custom-police] [dispatch] P0 dispatch layer loaded
[ script:custom-quest] [quest-registry] ✅ 任务注册器已加载 (v0.7.0)
[ script:custom-quest] [quest] ✅ 手机任务入口已就绪 (GetAvailableQuests / GetQuestDetail)
[ script:custom-phone] [phone-apps] ✅ quests app registered (audience = all jobs)
"""


def test_parse_console_detects_ansi_duplicates_and_script_errors():
    """解析器要能穿 ANSI、去重、并且真的数到错误——三者任缺其一都会造成假绿。"""
    mod = _load_module()
    log = (
        "\x1b[0m[  script:qb-core] Started resource qb-core\x1b[0m\n"
        "[  script:qb-core] Started resource qb-core\n"
        "[  script:qb-inventory] Started resource qb-inventory\n"
        "\x1b[31m[  script:x] SCRIPT ERROR: boom\x1b[0m\n"
    )
    stats = mod.parse_console(log)
    assert stats["started_count"] == 2, "重复的 Started 行只应算一次资源"
    assert stats["script_errors"] == 1, "被 ANSI 包住的 SCRIPT ERROR 也要数到"
    assert "\x1b" not in str(stats)


@pytest.mark.parametrize(
    "defect, expect_in_message",
    [
        ({"started_count": 83}, "83"),
        ({"script_errors": 2}, "SCRIPT ERROR"),
        ({"http_ok": False}, "30120"),
        ({"db_ok": False}, "数据库"),
        ({"tables": 70}, "表"),
    ],
)
def test_evaluate_detects_each_defect_on_bad_shapes(defect, expect_in_message):
    """五种缺陷各喂一次：脚本不能只在"某一种"坏掉时才报警。"""
    mod = _load_module()
    stats = dict(mod.parse_console(GOOD_LOG))
    kwargs = {"stats": stats, "http_ok": True, "db_ok": True, "tables": 74}
    if "started_count" in defect or "script_errors" in defect:
        stats.update(defect)
        kwargs["stats"] = stats
    else:
        kwargs.update(defect)

    failures = mod.evaluate(**kwargs)
    assert failures, f"缺陷 {defect} 必须让自检失败"
    assert any(expect_in_message in f for f in failures), (
        f"失败信息里要能看出原因（期望含 {expect_in_message!r}）: {failures}"
    )


def test_missing_marker_detects_exactly_which_one_disappeared():
    """逐个抽掉标记：每次只报这一项，并点名是哪个标记。"""
    mod = _load_module()
    stats = mod.parse_console(GOOD_LOG)
    assert mod.evaluate(stats, http_ok=True, db_ok=True, tables=74, min_resources=3) == []

    for marker in mod.MARKERS:
        broken = GOOD_LOG.replace(mod.MARKERS[marker], "")
        failures = mod.evaluate(
            mod.parse_console(broken), http_ok=True, db_ok=True, tables=74, min_resources=3
        )
        assert len(failures) == 1, f"抽掉 {marker} 应当只报一条，实际 {failures}"
        assert marker in failures[0], f"失败信息要指出是哪个标记: {failures[0]}"


def test_cli_rejects_bad_log_and_accepts_good_one(tmp_path, capsys):
    """好日志 → 0 且打印 OK；坏日志 → 1 且点名 SCRIPT ERROR。"""
    mod = _load_module()
    good = tmp_path / "good.log"
    good.write_text(GOOD_LOG, encoding="utf-8")
    bad = tmp_path / "bad.log"
    bad.write_text(GOOD_LOG + "[ script:x] SCRIPT ERROR: nope\n", encoding="utf-8")

    assert mod.main(["--log", str(good), "--skip-http", "--skip-db", "--min-resources", "3"]) == 0
    assert "OK" in capsys.readouterr().out, "通过的输出要有一眼能认出的 OK"

    assert mod.main(["--log", str(bad), "--skip-http", "--skip-db", "--min-resources", "3"]) == 1
    assert "SCRIPT ERROR" in capsys.readouterr().out, "失败输出要点名原因，而不是只说 failed"


def test_cli_json_report_detects_the_same_verdict(tmp_path):
    """`--json` 的结论必须和退出码一致，否则 agent 拿到的是另一套事实。"""
    mod = _load_module()
    good = tmp_path / "good.log"
    good.write_text(GOOD_LOG, encoding="utf-8")
    out = tmp_path / "report.json"

    code = mod.main(
        ["--log", str(good), "--skip-http", "--skip-db", "--min-resources", "3", "--json", str(out)]
    )
    assert code == 0
    report = json.loads(out.read_text(encoding="utf-8"))
    assert report["ok"] is True and report["failures"] == []
    assert report["stats"]["started_count"] == 3

    bad = tmp_path / "bad.log"
    bad.write_text(GOOD_LOG + "[ script:x] SCRIPT ERROR: nope\n", encoding="utf-8")
    code = mod.main(
        ["--log", str(bad), "--skip-http", "--skip-db", "--min-resources", "3", "--json", str(out)]
    )
    report = json.loads(out.read_text(encoding="utf-8"))
    assert code == 1 and report["ok"] is False and report["failures"]

def test_only_the_last_boot_counts():
    """systemd 的日志是追加的：上一次崩溃的 SCRIPT ERROR 不许把这次自检染红，反之亦然。"""
    mod = _load_module()
    good_tail = (
        "T-City Lite 开发服务器\n"
        + GOOD_LOG
    )
    stale = "[ script:old] SCRIPT ERROR: something from the previous boot\n" + good_tail
    stats = mod.parse_console(stale)
    assert stats["script_errors"] == 0, "上次启动留下的报错不该算到这次头上"

    fresh = good_tail + "[ script:new] SCRIPT ERROR: this boot is broken\n"
    stats = mod.parse_console(fresh)
    assert stats["script_errors"] == 1, "本次启动之后的报错必须抓到"

def test_license_rate_limit_is_reported_in_plain_words():
    """429 不是"资源没起来"，而是一个会自己续命的限流：必须直接说清楚，并给出等多久。"""
    mod = _load_module()
    log = (
        "T-City Lite 开发服务器\n"
        "[          svadhesive] Authenticating server license key...\n"
        "An error occurred while checking server license key: HTTP 429: Too Many Requests\n"
    )
    stats = mod.parse_console(log)
    assert stats["license_429"] is True

    failures = mod.evaluate(stats, http_ok=False, db_ok=True, tables=None)
    joined = " ".join(failures)
    assert "429" in joined, f"必须点名 429，实际: {failures}"
    assert "20-30 分钟" in joined, f"要给出等待建议，实际: {failures}"


def test_start_script_refuses_a_second_instance():
    """两个实例同时起时，第二个在 licence 校验之后才发现端口被占 —— 那次校验是白花的配额。"""
    start = REPO / "start.sh"
    text = start.read_text(encoding="utf-8")
    assert "flock -n 9" in text, "start.sh 缺少单实例锁：重复启动会烧掉 licence 配额"
    assert text.index("flock -n 9") < text.index("ld-musl-x86_64.so.1"), "锁必须在启动二进制之前"
