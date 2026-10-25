"""SKILL-01：技能入库后，仓库那份和 Hermes 安装的那份不能各说各话。

技能是"这个项目怎么做"的程序性知识。它原本只活在 `~/.hermes/skills/` 里——不进 CI、
不进 code review、换机器就没了，而它描述的恰恰是这台机器上的服务器。现在仓库
`.agents/skills/` 是准的，Hermes 那份是安装出来的副本。

这条规则只做一件事：**让漂移可见**。检测器本身必须被检验，所以先在临时目录里构造
三种漂移（内容不同 / Hermes 缺文件 / Hermes 多文件），确认都能被点名。
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TOOL = REPO / "tools" / "dev" / "skills_sync.py"
REPO_SKILLS = REPO / ".agents" / "skills"


def run_check(hermes_skills: Path) -> tuple[int, str]:
    env = dict(os.environ, HERMES_SKILLS_DIR=str(hermes_skills))
    proc = subprocess.run(
        ["/usr/bin/python3", str(TOOL), "--check"], capture_output=True, text=True, env=env
    )
    return proc.returncode, proc.stdout + proc.stderr


def install_copy(tmp_path: Path) -> Path:
    """把仓库技能按 CATEGORY 约定铺到临时 Hermes 目录里。"""
    target_root = tmp_path / "hermes-skills"
    for name in sorted(p.name for p in REPO_SKILLS.iterdir() if (p / "SKILL.md").is_file()):
        shutil.copytree(REPO_SKILLS / name, target_root / "software-development" / name)
    return target_root


def test_skills_sync_detects_drift_and_rejects_missing_files(tmp_path):
    assert TOOL.is_file() and REPO_SKILLS.is_dir(), "技能同步工具或仓库技能目录不见了"

    hermes = install_copy(tmp_path)
    rc, out = run_check(hermes)
    assert rc == 0, f"一份全新拷贝应当一致：{out[-400:]}"

    name = next(p.name for p in REPO_SKILLS.iterdir() if (p / "SKILL.md").is_file())
    installed = hermes / "software-development" / name

    # ① 内容不同 → 必须点名
    skill_md = installed / "SKILL.md"
    skill_md.write_text(skill_md.read_text(encoding="utf-8") + "\n本地偷偷改了一行\n", encoding="utf-8")
    rc, out = run_check(hermes)
    assert rc == 1 and "内容不同" in out, f"内容漂移没被发现：{out[-400:]}"

    # ② Hermes 缺文件 → 必须点名
    hermes = install_copy(tmp_path / "second")
    installed = hermes / "software-development" / name
    references = sorted((installed / "references").glob("*.md")) if (installed / "references").is_dir() else []
    if references:
        references[0].unlink()
        rc, out = run_check(hermes)
        assert rc == 1 and "Hermes 缺" in out, f"缺文件没被发现：{out[-400:]}"

    # ③ Hermes 多出文件 → 必须点名（否则本地新写的参考文件会悄悄消失）
    hermes = install_copy(tmp_path / "third")
    installed = hermes / "software-development" / name
    (installed / "references" / "只存在于本地.md").write_text("x\n", encoding="utf-8")
    rc, out = run_check(hermes)
    assert rc == 1 and "仓库缺" in out, f"多出来的文件没被发现：{out[-400:]}"


def test_entry_point_rule_rejects_a_skill_without_skill_md(tmp_path):
    """入库的技能必须真的有 SKILL.md，否则同步工具会把它跳过而不报错。"""

    def missing_entry(dirs) -> list[str]:
        return sorted(d.name for d in dirs if not (d / "SKILL.md").is_file())

    bad = tmp_path / "no-entry"
    bad.mkdir()
    assert missing_entry([bad]) == ["no-entry"], "缺 SKILL.md 的技能没被发现"

    dirs = [p for p in REPO_SKILLS.iterdir() if p.is_dir()]
    assert dirs, "仓库里没有技能目录"
    assert missing_entry(dirs) == [], "这些技能目录缺 SKILL.md：" + ", ".join(missing_entry(dirs))
