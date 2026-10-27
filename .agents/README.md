# `.agents/` — 给 agent 读的仓库内知识

这个目录放的是**随代码一起版本化**的 agent 知识。它不是文档站的副本，也不是给人看的
介绍：它是"在这台机器上怎么干活"的程序性知识——坑、流程、命令、验证方式。

## skills/

技能本体。仓库这份是**准的**，`~/.hermes/skills/` 下的是安装出来的副本。

```bash
python3 tools/dev/skills_sync.py --check        # 比对两边（漂移退出码 1）
python3 tools/dev/skills_sync.py --to-hermes    # 仓库 → Hermes（装/更新）
python3 tools/dev/skills_sync.py --from-hermes  # 在 Hermes 那边改完，收回仓库
```

为什么放进仓库：

- 技能描述的东西就在这个仓库里，两者一起改才有意义；
- 它要过 code review，而不是只活在某台机器的家目录里；
- 换机器/换 agent 时，技能跟着 clone 走，不需要口头交接。

闸门：`T-CityLite.base/tests/architecture/test_skills_copy.py`（SKILL-01）。它构造三种
漂移（内容不同、副本缺文件、副本多文件）验证检测器能看见，然后检查入库技能都有
`SKILL.md`——没有入口文件的技能会被同步工具静默跳过。

## 约定

- 新增技能：在 `.agents/skills/<name>/SKILL.md` 写，再跑 `--to-hermes`；
- 目录分类映射写在 `tools/dev/skills_sync.py` 的 `CATEGORY`（例如
  `fivem-resource-development` → `software-development`）；
- 技能里出现的路径按"安装后位置"写是允许的——文档断链闸门把 `.agents` 排除在外，
  因为那些路径不是相对仓库根解析的。
