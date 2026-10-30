"""支援指标面板的离线契约。

面板本身是"把审计行折叠成数字"，所以最容易错的地方是**折叠规则**（reason 解析、
异常口径、平均值分母）。这里不碰数据库，只测纯函数与 SQL 形状。
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEV = REPO / "tools" / "dev"


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, DEV / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def row(action: str, target: str = "BU-1", detail: str = "", when: str = "2026-10-29 20:00:00"):
    return [action, target, detail, when]


def test_counts_and_rates():
    metrics = load("police_backup_metrics")
    rows = [
        row("backup.request", detail="DXI50064"),
        row("backup.spawned", detail="entities=3;took=0"),
        row("backup.ended", detail="reason=timeout;live=300"),
        row("backup.request", detail="DXI50064"),
        row("backup.expired", detail="phase=enroute;why=ttl;live=38"),
    ]

    result = metrics.summarize(rows)

    assert result["requests"] == 2
    assert result["spawned"] == 1
    assert result["spawn_rate"] == 0.5
    assert result["ended"] == 1
    assert result["expired"] == 1
    assert result["end_reasons"] == {"timeout": 1}
    assert result["expiry_whys"] == {"ttl": 1}
    assert result["expiry_phases"] == {"enroute": 1}
    # live 同时来自 ended 与 expired：300 与 38 的平均
    assert result["avg_live_seconds"] == 169.0
    assert result["avg_spawn_seconds"] == 0.0


def test_abnormal_rate_uses_a_fixed_denominator():
    metrics = load("police_backup_metrics")
    rows = [
        row("backup.request"),
        row("backup.request"),
        row("backup.request"),
        row("backup.request"),
        row("backup.ended", detail="reason=spawn_failed;live=1"),
        row("backup.ended", detail="reason=vehicle_lost;live=5"),
        row("backup.ended", detail="reason=timeout;live=300"),
        row("backup.ended", detail="reason=dismissed;live=12"),
    ]

    result = metrics.summarize(rows)

    # spawn_failed + vehicle_lost 算异常；timeout / dismissed 不算。
    assert result["abnormal_rate"] == 0.5


def test_player_side_endings_are_not_abnormal():
    metrics = load("police_backup_metrics")
    rows = [
        row("backup.request"),
        row("backup.request"),
        row("backup.request"),
        row("backup.request"),
        row("backup.ended", detail="reason=dead;live=20"),
        row("backup.ended", detail="reason=left;live=30"),
        row("backup.ended", detail="reason=dismissed;live=12"),
        row("backup.ended", detail="reason=escort_timeout;live=90"),
    ]
    result = metrics.summarize(rows)
    # 只有 escort_timeout 算"单位没干成事"；dead/left/dismissed 是玩家侧收尾。
    assert result["abnormal_rate"] == 0.25
    assert result["end_reasons"]["dismissed"] == 1


def test_unknown_reason_is_abnormal():
    metrics = load("police_backup_metrics")
    result = metrics.summarize([row("backup.request"), row("backup.ended", detail="reason=unknown;live=3")])
    assert result["abnormal_rate"] == 1.0


def test_empty_input_is_all_zero_and_no_division():
    metrics = load("police_backup_metrics")
    result = metrics.summarize([])
    assert result["requests"] == 0
    assert result["spawn_rate"] is None, "0 请求时不能除以 0"
    assert result["avg_live_seconds"] is None


def test_malformed_rows_are_skipped_not_crashed():
    metrics = load("police_backup_metrics")
    result = metrics.summarize([
        ["backup.request"],                      # 缺列
        row("backup.ended", detail="reason=timeout;live=not-a-number"),
        row("backup.spawned", detail="entities=3"),
    ])
    assert result["requests"] == 0
    # live 解析失败不进平均值，但计数仍然算一次结束
    assert result["ended"] == 1
    assert result["avg_live_seconds"] is None


def test_sql_is_bounded_and_windowed(monkeypatch):
    metrics = load("police_backup_metrics")
    seen: list[str] = []

    class Result:
        returncode = 0
        stdout = "action\ttarget\tdetail\tcreated_at\nbackup.request\tBU-1\t\t2026-10-29 20:00:00\n"
        stderr = ""

    def fake_run(argv, **kwargs):  # noqa: ANN001, ANN003
        seen.append(argv[-1])
        return Result()

    monkeypatch.setattr(metrics.subprocess, "run", fake_run)
    monkeypatch.setattr(metrics, "mysql_dsn", lambda: ("u", "p", "db"))

    rows = metrics.fetch_rows(48)

    sql = seen[0]
    assert "like 'backup.%'" in sql
    assert "interval 48 hour" in sql
    assert "limit 5000" in sql.lower()
    assert rows == [["backup.request", "BU-1", "", "2026-10-29 20:00:00"]]
