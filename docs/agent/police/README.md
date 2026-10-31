# 警察系统 · 入口与沉淀（2026-10-31）

> 一页索引：谁该读哪份、现在做到哪、踩过哪些坑（别再踩）。
> 状态以代码与真机证据为准，本页只做导航与结论。

## 1. 该读哪份

| 你要做的事 | 先读 | 再读 |
|---|---|---|
| 接手这个模块 | 本页 | `docs/agent/police/STATUS-2026-10-31.md`（Phase 状态 + 缺口） |
| 加/改一个 agent 动作 | `docs/agent/police/ATOOLS-DISCIPLINE.md` §2 | `docs/agent/police/STATUS-2026-10-31.md` §1.1 |
| 改调度/警情 | `docs/police/plans/2026-10-31-p2-dispatch-audit.md` | `T-CityLite.base/resources/[custom]/custom-police/shared/dispatch_view.lua` |
| 改证据 / 化验 | `docs/police/plans/2026-10-31-p4-evidence-binding.md` | `T-CityLite.base/resources/[custom]/custom-police/server/p2_evidence.lua` |
| 让 AI 去解析报案文本 | `docs/agent/police/DISPATCHER-MVP.md` | `tools/agent/dispatch_mvp.py` |
| 验收判据 | `docs/agent/police/ACCEPTANCE.md` | — |
| 上游设计意图 | `docs/agent/police/BLUEPRINT.md` | — |

## 2. 现在的状态（一句话版）

| Phase | 状态 | 一句话 |
|---|---|---|
| P0 地基 | ✅ | 表 / 权限矩阵 / 手机 App 注册表就位 |
| P1 司法链 | ✅ | 案卷落库、判决回写、律师通知；golden `justice_chain` 覆盖 3 条 AC |
| P2 调度总线 | ✅ | 建单/合并/状态机/坐标脱敏/通知预算/车机警情页 |
| P3 盘查与文书 | ✅ | 六动作靶心、酒测药检（有数据源）、报告与 BOLO |
| P4 证据 | 🟡 | 链只增不改、绑定与延迟绑定已通；bodycam 明确不做 |
| P5 AI 支援分层 | ✅ | L0 无线电 → L3 到场/包围/喊话；布景与后勤齐 |
| P6 Agent 动作 | ✅ | 读案卷 + 起草报告 / 申请逮捕令 / call 卡草稿 + 草稿箱 |
| 调度员 MVP | ✅ | 脚本取内容 + agent 解析 + 草稿进箱（真机 3 条短信） |
| 指纹 / DNA | 🟡 MVP | 采样记现场候选，比对只认名单；缺样本袋等玩法 |

## 3. 踩过的坑（每条都有闸门兜底）

| 坑 | 症状 | 现在的护栏 |
|---|---|---|
| **单一写者** | 我在新模块里自己写 `INSERT`/`UPDATE`，闸门红 | `test_police_single_writer`；写之前先找 owner（`records.lua` / `p0_incidents.lua` / `p2_evidence.lua`） |
| **Lua pattern 没有 `{n,m}`** | `^[A-Za-z0-9_%-]{1,11}$` 永不匹配，合法 citizenid 被判非法 | `test_p6_agent_stack.py` 扫 policy 里的量化词 |
| **新增动作要接四处** | 只接 ACTIONS/Normalize 会在 propose 静默 `unsupported_action` | 同文件逐动作核对 ACTIONS / Normalize / Preview / CheckPolicy |
| **`exports[...]` 是代理表** | 索引未注册导出会**抛错**，`type(target[m])` 这种"守卫"本身就是崩溃点 | `callExport` 把索引也包 `pcall`；缺资源时返回 nil = 跳过 |
| **审批会重放归一化** | 回填字段（如 `code_fallback`）没进白名单 → approve 阶段 `unknown field` | 回填字段必须同时进 `rejectUnknownFields` 白名单 |
| **`{#snippet}` 位置** | 写在组件子节点里会被当成组件的 snippet prop | 放顶层普通元素内 |
| **Sonar 新代码重复** | 多个测试文件复制样板 → Maintainability 掉到 C/B | 合并成一个 `test_p6_agent_stack.py`，共用 `read()/block()` |
| **`restart <资源>` 连坐** | 依赖它的资源被停掉（`custom-director` 就这么消失过） | 改完补 `ensure`；或 `tools/dev/resync_modules.sh` |
| **文档路径反引号** | 资源内相对路径（例如 server 下的 Lua 文件）写成反引号会被断链闸门当成仓库路径判错 | 相对路径改成不加反引号的叙述 |

## 4. 常用命令

```bash
# 全量离线测试
cd T-CityLite.base && /usr/bin/python3 -m pytest tests/unit tests/architecture -q
# Lua golden（18 suites）
lua5.4 T-CityLite.base/tests/agent/lua/runner.lua
# 交付前
python3 tools/dev/release_check.py

# 真机：改完重启 + 看脚本错误
python3 tools/dev/fivem_console.py "restart custom-police"
tail -40 /tmp/tcity_console.log | grep -i "SCRIPT ERROR"

# 调度员 MVP
python tools/agent/dispatch_mvp.py fetch --limit 10
python tools/agent/dispatch_mvp.py submit parsed.json
```

## 5. 还没做（按优先级）

| # | 项 | 门槛 |
|---|---|---|
| 1 | 调度员常驻（cron 拉短信自动出草稿） | 无，可直接做 |
| 2 | 多机验收：P2-01/04/06/07、P3 靶心六动作 | 需要第二个客户端 |
| 3 | 指纹/DNA 的样本袋玩法（多场景采集） | 需要采集物与 UI |
| 4 | 保释 / 假释 | 依赖法院侧 |
| 5 | bodycam | 已决定不做（显存与体积代价） |
