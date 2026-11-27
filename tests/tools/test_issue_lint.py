"""issue 合规检查器的离线契约（docs/engineering/ISSUE_STANDARD.md）。

检查器本身不连 GitHub —— 它吃 `gh issue list --json` 的导出，所以在 CI 里可跑、可测。
这里钉住三件事：标签三件套、标题格式、"有清单就必须有前序核验"。
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TOOL = REPO / "tools" / "dev" / "issue_lint.py"


def load():
    spec = importlib.util.spec_from_file_location("issue_lint", TOOL)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def issue(**over):
    base = {
        "number": 1,
        "title": "feat(industry): 数值卡与 28 天周期",
        "labels": [{"name": "type:feature"}, {"name": "priority:P1"}, {"name": "area:economy"}],
        "body": "## 前序核验\n\n- [ ] 确认前置\n",
    }
    base.update(over)
    return base


def test_compliant_issue_has_no_problems():
    module = load()
    assert module.problems_for(issue()) == []


def test_missing_label_groups_are_rejected():
    module = load()
    found = module.problems_for(issue(labels=[{"name": "type:feature"}]))
    assert any("priority:*" in p for p in found), found
    assert any("area:*" in p for p in found), found


def test_legacy_labels_are_rejected():
    module = load()
    found = module.problems_for(issue(labels=[
        {"name": "type:feature"}, {"name": "priority:P1"}, {"name": "area:economy"}, {"name": "enhancement"},
    ]))
    assert any("旧标签" in p for p in found), found


def test_title_shape_is_enforced():
    module = load()
    assert module.problems_for(issue(title="[Phase 1] 老格式标题")) != []


def test_checklist_without_prerequisite_is_rejected():
    """有任务清单却没有「前序核验」= 违规；没有清单的（例如一句话 issue）不判。"""
    module = load()
    no_prereq = issue(body="- [ ] 直接开干\n- [ ] 收尾\n")
    assert any("前序核验" in p for p in module.problems_for(no_prereq))
    prose_only = issue(body="背景说明，没有清单。\n")
    assert module.problems_for(prose_only) == []
