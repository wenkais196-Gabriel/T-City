"""P1-3 — 全仓 net event 基线：存量可以是债，但债不许自己长大。

`test_net_event_auth.py` 只管四个资源（批次① qb-core 100% + custom-police / custom-phone /
core-framework）。全仓还有 400 多个服务端 net event，一次性全部加鉴权不现实，所以这里
用**基线 + 棘轮**：

* `net_events_baseline.json` 记下每个资源的事件数与未登记事件清单；
* 现在的未登记集合必须和基线**逐条相等** —— 新冒出一个未鉴权的 net event，闸门立刻红；
* 每个还有未登记事件的资源必须有一条 `owner` + `expires` 的债，过期即红；
* 变量名注册（闸门看不见）与解析失败的 handler 也在基线里，同样只许减少。

有意改变现状（修好了一个事件、新增了一个已鉴权的事件）时重新生成基线：

    python tests/architecture/net_event_baseline.py --write

diff 里能直接看到"未登记从 N 降到 M"。手改基线会被判红。
"""
from __future__ import annotations

from datetime import date
from pathlib import Path

import net_event_baseline as baseline
import net_event_scan as scan

REGEN = "python tests/architecture/net_event_baseline.py --write"


def current(resources: Path | None = None) -> dict:
    return baseline.build(resources or baseline.RESOURCES)


def diff_unguarded(before: dict[str, list[str]], after: dict[str, list[str]]) -> list[str]:
    """新增的未登记事件（after - before）。空 = 没有新债。"""
    problems = []
    for resource, names in after.items():
        known = set(before.get(resource, []))
        for name in names:
            if name not in known:
                problems.append(f"{resource}: {name}")
    return sorted(problems)


def diff_removed(before: dict[str, list[str]], after: dict[str, list[str]]) -> list[str]:
    """已修掉的未登记事件（before - after）—— 有减少就必须重生成基线。"""
    problems = []
    for resource, names in before.items():
        known = set(after.get(resource, []))
        for name in names:
            if name not in known:
                problems.append(f"{resource}: {name}")
    return sorted(problems)


def test_baseline_matches_live_inventory():
    """基线与实测必须逐条相等：新债要拦、还清的债也要反映进去。

    两个方向都重要：只拦"新增"会让数字永远停在旧值（债看起来还不完），
    只拦"减少"则新事件可以悄悄落地。
    """
    base = baseline.load()
    now = current()

    added = diff_unguarded(base["unguarded"], now["unguarded"])
    if added:
        raise AssertionError(
            "出现了新的未鉴权 net event —— 要么在 handler 里加鉴权"
            "（PolicePolicy.Can / HasPermission / ACE / 归属校验），要么登记进 "
            "net_events_allowlist.json，然后重新生成基线：" + "\n  ".join([""] + added)
            + "\n\n（" + REGEN + "）"
        )

    removed = diff_removed(base["unguarded"], now["unguarded"])
    if removed:
        raise AssertionError(
            "这些事件已经被鉴权/登记，但基线还记着它们未登记 —— 重新生成基线让债数字下降："
            + "\n  ".join([""] + removed) + "\n\n（" + REGEN + "）"
        )


def test_enforced_batch_has_zero_unguarded_events():
    data = current()
    offenders = [resource for resource in data["enforced"] if resource in data["unguarded"]]
    assert offenders == [], (
        f"批次①（引擎层）必须 100% 覆盖，但这些资源还有未登记事件：{offenders}"
    )


def test_every_resource_with_debt_has_an_owner_and_a_future_expiry():
    base = baseline.load()
    debt = {entry["resource"]: entry for entry in base["debt"]}
    assert set(debt) == set(base["unguarded"]), (
        "debt 条目必须与 unguarded 的资源集合一一对应："
        f"缺 {sorted(set(base['unguarded']) - set(debt))}，多 {sorted(set(debt) - set(base['unguarded']))}"
    )
    today = date.today()
    for resource, entry in debt.items():
        assert str(entry.get("owner", "")).strip(), f"{resource}: 债必须有 owner"
        assert date.fromisoformat(entry["expires"]) >= today, (
            f"{resource}: 债已在 {entry['expires']} 到期 —— 修掉它，或者续期并写清为什么"
        )
        assert entry["unguarded"] == len(base["unguarded"][resource]), (
            f"{resource}: debt.unguarded={entry['unguarded']} 与清单长度 "
            f"{len(base['unguarded'][resource])} 不一致（手改过基线？）"
        )


def test_batch_totals_add_up():
    base = baseline.load()
    for name, batch in base["batches"].items():
        assert batch["events"] == batch["guarded"] + batch["allowlisted"] + batch["unguarded"], (
            f"批次 {name} 的数字对不上：{batch}"
        )


def test_recorded_counts_match_the_live_scan():
    """`batches` / `resources` 的数字必须等于实测。

    只校验"批次内部相加相等"挡不住手改：把 events 和 guarded 一起改大，和仍然成立。
    所以这里跟 live 扫描逐字段比 —— 手改基线一定红。
    """
    base = baseline.load()
    now = current()
    assert now["batches"] == base["batches"], (
        "基线里的批次数字与实测不一致（手改过？）"
        + chr(10) + f"基线 {base['batches']}"
        + chr(10) + f"实测 {now['batches']}"
        + chr(10) + chr(10) + f"（{REGEN}）"
    )
    fields = ("batch", "events", "guarded", "allowlisted", "unguarded")
    live = {name: {key: stats[key] for key in fields} for name, stats in now["resources"].items()}
    recorded = {name: {key: stats[key] for key in fields} for name, stats in base["resources"].items()}
    assert live == recorded, (
        "基线里的每资源数字与实测不一致（手改过？或改了扫描器却没重生成）"
        + chr(10) + f"只在新基线: {sorted(set(live) - set(recorded))}"
        + chr(10) + f"只在旧基线: {sorted(set(recorded) - set(live))}"
        + chr(10) + chr(10) + f"（{REGEN}）"
    )

def test_non_literal_registrations_do_not_grow():
    base = baseline.load()
    now = current()
    added = sorted(set(now["non_literal"]) - set(base["non_literal"]))
    assert added == [], (
        "新增了变量名注册的 net event —— 闸门看不见它们。改成字面量：\n  "
        + "\n  ".join(added) + f"\n\n（{REGEN}）"
    )


def test_unparsed_handlers_do_not_grow():
    base = baseline.load()
    now = current()
    added = sorted(set(now["unparsed"]) - set(base["unparsed"]))
    assert added == [], (
        "扫描器解析不了这些 handler（等于没管）：\n  " + "\n  ".join(added)
    )


# ---------------------------------------------------------------------------
# 反向校验：新形状必须被抓到
# ---------------------------------------------------------------------------

def test_reverse_new_event_is_reported():
    assert diff_unguarded({"a": ["x"]}, {"a": ["x", "y"]}) == ["a: y"]
    assert diff_unguarded({"a": ["x"]}, {"a": ["x"]}) == []
    assert diff_unguarded({"a": ["x"]}, {}) == []


def test_reverse_fixed_event_is_reported():
    assert diff_removed({"a": ["x", "y"]}, {"a": ["x"]}) == ["a: y"]
    assert diff_removed({"a": ["x"]}, {"a": ["x"]}) == []


def test_reverse_scan_of_a_brand_new_unguarded_event(tmp_path: Path):
    """真的把一个未鉴权的 net event 放进临时 resources/，基线对比必须报出来。"""
    resource = tmp_path / "[custom]" / "spike-resource" / "server"
    resource.mkdir(parents=True)
    (resource / "main.lua").write_text(
        "RegisterNetEvent('spike:server:boom', function(payload)\n"
        "    print(payload)\n"
        "end)\n",
        encoding="utf-8",
    )
    events, problems = scan.scan_repo(tmp_path)
    assert problems == []
    assert [event.name for event in events] == ["spike:server:boom"]
    assert scan.auth_tokens(events[0].body) == [], "这个形状必须被判为未鉴权"

    after = {"spike-resource": ["spike:server:boom"]}
    assert diff_unguarded({}, after) == ["spike-resource: spike:server:boom"]

    # 同样的形状，补上鉴权之后必须不再算债
    (resource / "main.lua").write_text(
        "RegisterNetEvent('spike:server:boom', function(payload)\n"
        "    if not IsPlayerAceAllowed(source, 'spike.boom') then return end\n"
        "    print(payload)\n"
        "end)\n",
        encoding="utf-8",
    )
    events, _ = scan.scan_repo(tmp_path)
    assert scan.auth_tokens(events[0].body), "补了 ACE 之后必须算已鉴权"


def test_reverse_non_literal_registration_is_reported(tmp_path: Path):
    resource = tmp_path / "[custom]" / "spike-resource" / "server"
    resource.mkdir(parents=True)
    (resource / "main.lua").write_text(
        "RegisterNetEvent(EVENT_NAME, function() end)\n", encoding="utf-8"
    )
    offenders = scan.non_literal_registrations(tmp_path)
    assert len(offenders) == 1 and "EVENT_NAME" in offenders[0], offenders


def test_reverse_scanner_sees_registrations_with_a_space_before_the_paren(tmp_path: Path):
    """`RegisterNetEvent (` 多一个空格以前完全不可见（事件名都扫不到）。"""
    resource = tmp_path / "[custom]" / "spike-resource" / "server"
    resource.mkdir(parents=True)
    (resource / "main.lua").write_text(
        "RegisterNetEvent ('spike:server:space', function(payload)" + chr(10)
        + "    print(payload)" + chr(10) + "end)" + chr(10),
        encoding="utf-8",
    )
    events, problems = scan.scan_repo(tmp_path)
    assert problems == []
    assert [event.name for event in events] == ["spike:server:space"]
    assert scan.auth_tokens(events[0].body) == []


def test_reverse_auth_token_in_a_comment_does_not_count():
    """注释里写的检查不算检查 —— 否则"把检查注释掉"就能骗过闸门。"""
    body = chr(10).join([
        "local src = source",
        "-- PolicePolicy.Can(actor, 'incident.claim')  ← 已经注释掉了",
        "if not Player then return end",
    ])
    assert scan.auth_tokens(body) == []


def test_reverse_auth_token_in_a_string_does_not_count():
    """日志里印一句 PolicePolicy.Can( 也不等于真的校验。"""
    body = chr(10).join([
        "local src = source",
        "print('PolicePolicy.Can( 还没接')",
    ])
    assert scan.auth_tokens(body) == []


def test_system_source_token_only_counts_the_server_only_shape():
    """`src == 0` 只排除控制台，不等于"只允许服务端"；只有 `src ~= 0 then return` 才算。"""
    assert scan.auth_tokens("if src == 0 then return end") == []
    assert scan.auth_tokens("if src ~= 0 then return end") == ["system_source"]
    assert scan.auth_tokens("if source ~= 0 then return end") == ["system_source"]
