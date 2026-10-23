# 仓库整理总方案（合并三份提案）

> 分支：`chore/repo-cleanup`（基于 `99e0c27`，= master = dev）
> 输入：`ignore-proposal.md`（342 行）、`delete-proposal.md`、`structure-proposal.md`（548 行）
> 本文只定方案与顺序；**所有删除/移动都要按 Phase 逐批执行并单独提交**。

---

## 0. 一页结论

1. **先修安全**：`admins.json` 被跟踪，含 txAdmin bcrypt 哈希 + FiveM identifier，已进入历史。必须 `git rm --cached` + 加 ignore + **轮换密码**；历史清理（filter-repo）单独评估。
2. **ignore 不仅要加，还要"反向修"**：16 个已跟踪文件命中 ignore 规则（NUI 构建物 + `default/config.json`）；根 `dist/`/`build/` 与两个嵌套 `.gitignore` 过宽，dashboard 新 hash bundle 会被静默忽略 → 线上白屏。
3. **结构三个真问题**：两个 docs 根、两棵 `tests/agent/`、`[standalone]` 混入 8 个自研资源。都有低风险迁移路径（cfg 零改动 / CI 改 1 行）。
4. **删除要先分清"死"与"未迁移"**：`qb-phone` 没有 ensure，但仍有 **8 个已启用资源**调用它的 exports/events（现在就是静默失效）；删之前先迁移，否则只是把"静默失效"变成"永久没有"。
5. **真正零风险可删约 2.2M**：`.pytest_cache`/`__pycache__`（1.3M）、57 个资源内上游 `.github/` 样板（0.84M）、`fxmanifest_inventory.json`、0 字节 `tictactoe.css`。最多回收的候选是 `qb-phone`（3.2M）与 `monitor`（13M，建议保留）。

---

## Phase 0 — 安全（独立 PR，最优先）

| 项 | 动作 | 说明 |
|---|---|---|
| `admins.json` | `git rm --cached admins.json` + `.gitignore` 加 `/admins.json` | 本地文件保留；**立即轮换 txAdmin 密码** |
| 历史 | 评估 `git filter-repo`/BFG 清理 `1e39c45` 起的哈希 | 会改写历史，需全员重新 clone；单独决定 |
| `default/config.json` | 移出版本库 + ignore（含他人机器路径 `F:/t-city/...`） | 若仍需模板，提交 `config.example.json` |
| `simulation_report.json` | 移出版本库 + ignore | sandbox_simulator 默认输出 |
| `start_txadmin.bat` | 删除或改为相对路径 | 硬编码 `D:\server` |
| `fxmanifest_inventory.json` | 确认无引用后删除 | 64KB 过期生成物 |

验证：`git ls-files admins.json` 为空；`git status --ignored` 显示忽略；重启 txAdmin 用新密码登录。

---

## Phase 1 — 零运行时影响（1 个 PR，约 2.2M）

### 1.1 `.gitignore` 修正（来自 ignore 提案）

- **新增**（根）：`/admins.json`、`.pytest_cache/`、`.env.*`、`*.log`、`coverage/`、`.mypy_cache/`、`.venv/`、`*.sql.gz`、`*.dump`、`simulation_report.json`、`fxmanifest_inventory.json`；
- **修正嵌套**（关键）：
  - `T-CityLite.base/resources/[system]/tcity-dashboard/nui/.gitignore`：不要忽略 `dist/`（hash bundle 必须入库）；
  - `.../menuv/.gitignore`、`.../oxmysql/.gitignore` 同类规则按提案逐一核对；
- **删除冗余/失效 23 行**：重复 `cache/`/`logs/`/`yarn-cache/`、两条永久失效的 logs negation、过宽 `config.json`、`QBCore_CDB34E.base/`/`skills/`/`AI_SYNC_MEMO.md` 死路径、末尾重复 `logs/`；
- **保留跟踪**：`custom-phone/html/**`（7 文件）、全仓 614 个 NUI `html/` 文件、`tests/fixtures/tcity_schema.sql`、`custom-director/shared/agent_tools.lua`、`docs/agent/TOOLS.md`；
- **禁止**裸 `html/`、`assets/`、`dist/` 规则；不要 `git clean -X`。

验证：
```bash
git ls-files -z | git check-ignore --no-index --stdin -z | wc -l   # 期望 0（除有意保留）
git check-ignore -v T-CityLite.base/resources/'[system]'/tcity-dashboard/nui/dist/index-*.js  # 期望不忽略
```

### 1.2 安全删除（A 组，约 2.2M）

- `.pytest_cache/`、仓库内 `__pycache__/`（未跟踪，本地清）；
- 57 个资源内上游 `.github/` 样板（确认无 CI 引用）；
- `fxmanifest_inventory.json`、0 字节 `tictactoe.css`；
- 其余 A 组按 `delete-proposal.md` 表格逐项核对。

### 1.3 文档入口（零移动）

- 新增根 `README.md`（项目是什么、如何跑、目录导航、AGENTS.md 链接）；
- 新增 `docs/README.md`、`T-CityLite.base/docs/README.md`、`tests/README.md`、`T-CityLite.base/tests/agent/README.md`；
- 修 `AGENTS.md` 8 处路径：`docs/agent/*` → `T-CityLite.base/docs/agent/*`（或反之，见决策 D1）；
- 修 12 条真实失效链接；
- `docs-check` 从 advisory 改为阻断（Phase 3 后）。

---

## Phase 2 — 结构搬迁（1–2 个 PR，约 42 文件）

| 迁移 | 内容 | 引用影响 | 风险 |
|---|---|---|---|
| M1 | `docs/agent/phone/` → `T-CityLite.base/docs/agent/phone/` | AGENTS.md 8 处、9 条内部链接 | 低 |
| M2 | 根 `tests/agent/` → `tests/tools/`（8 py） | `ci.yml:67` 1 行；目录深度不变，`parents[2]` 不用改 | 低 |
| M3 | `[standalone]` 8 个自研资源 → `[custom]/` | `ensure`/fxmanifest 按资源名解析；cfg 零改动 | 低 |
| M4 | 重复文档合并 | Bus API 2 份、开发工作流 2 份、`design/` vs `docs/` 同名 2 组 | 需人定正本 |
| M5 | base `tests/` 根平铺文件收进子目录 | 4 个 `check_*.py` 的 `BASE_DIR` 写死层级；`conftest.py` 必须留根 | 中 |

**先做 M1/M2/M3**（低风险），M4/M5 等人决策后做。

验证：`python3 -m pytest -q tests/agent`、`pytest tests/unit`、`lua5.4 tests/agent/lua/runner.lua`、`tools/agent_tools.py --check`、CI 全绿；`grep -rn 'tests/agent' .github` 确认只剩预期。

---

## Phase 3 — 归档与删除（需负责人确认）

| 候选 | 建议 | 前置条件 |
|---|---|---|
| `[qb]/qb-phone`（3.2M） | **先迁移再归档**，不直接删 | 迁移 8 个已启用调用方（见下）到 `custom-phone` 兼容层 |
| `[system]/monitor`（13M） | 保留 | txAdmin 集成，删了影响管理 |
| 4 代 aviation 模拟/2 代 validate | 只留最高版本 | 人工确认 |
| `QBCore_Lite_versions/` | 归档到 `archive/` 或删 | 确认无部署引用 |
| 历史分支 `recons`/`v0.5-crime`/`feat/agent-takeover` | 仅给建议，不执行 | 未合并分支需 owner 确认 |
| 旧版文档（audit/report 草稿） | 归档 `docs/archive/` | 人工定正本 |

`qb-phone` 的 8 个调用方：
`qb-core`（RemoveBankMoney）、`qb-cityhall`（sendNewMail*）、`qb-weapons`、`qb-ambulancejob`、`qb-pawnshop`、`qb-policejob`（邮件/罚单/警讯）、`qb-prison`、`qb-storerobbery`（addPoliceAlert）。
→ 在 `custom-phone` 补兼容 exports/events 后，再 `git mv` 到 `archive/qb-phone/`。

---

## 决策点（需要你拍板）

- **D1 文档正本**：根 `docs/` 与 `T-CityLite.base/docs/` 谁为主？
  - 推荐：base/docs = 游戏/agent 技术文档正本；根 docs = 项目/流程/审计报告；phone 3 篇并入 base。AGENTS.md 用完整路径。
- **D2 同名文档**：`docs/04_call_reference/bus_api_reference.md` vs `base/docs/bus-api-reference.md`；`dev-workflow-guide.md` vs `standards/dev_workflow.md`；根 `design/` vs `docs/` 同名两组——保留哪份？
- **D3 qb-phone**：迁移 8 个调用方后归档 vs 现在就删（接受通知缺失）。
- **D4 aviation/validate 旧代**：保留最高版本即可，还是全留？
- **D5 历史清理**：是否执行 filter-repo 清 `admins.json` 历史（需全员 re-clone）。
- **D6 `[standalone]` 自研迁移**：是否同意 8 个资源移到 `[custom]/`（cfg 零改动，但目录语义变化）。

---

## 执行顺序与验证

```
Phase 0 安全      → 单独 PR，先合
Phase 1 ignore+删+入口 → 1 PR，约 2.2M
Phase 2 M1/M2/M3  → 1 PR
Phase 2 M4/M5     → 决策后 1 PR
Phase 3 归档      → 按 D3/D4/D5 分批
```

每个 Phase 结束跑：
```bash
cd T-City-agent
python3 -m pytest -q tests/agent
lua5.4 T-CityLite.base/tests/agent/lua/runner.lua
cd T-CityLite.base && python3 -m pytest -q tests/unit
cd .. && python3 tools/agent_tools.py --check
```
并在 `T-City` 重启 `custom-phone`/`custom-director` 做一次冒烟，确认资源迁移没有影响运行。

---

## 附：明细

三份审计明细（ignore/delete/structure proposal）已按要求删除，只保留本 PLAN；
如需追溯，`git log -- docs/cleanup` 仍可找回原始内容。
