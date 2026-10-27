# AGENTS.md — T-City 入口索引

> 给新开对话/新 agent 的**唯一入口**。本页只做三件事：告诉你去哪读、红线是什么、命令怎么跑。
> 详细内容在分区文件里，本页**不超过 100 行**——超了就把内容下沉，不要在这里堆。

## 0. 这是什么

**QBCore / FiveM RP 服务器**（T-City Lite）+ 一套 LLM agent 接管栈：116 个资源、MariaDB、OneSync、
自研 Svelte 手机（`custom-phone`）、`custom-director` 动作代理（L1–L4 风险分级）。

## 1. 去哪读（按你的任务选一份，不要全读）

| 我要做的事 | 先读 | 再读 |
|---|---|---|
| **任何改动之前** | `docs/engineering/CONSTITUTION.md`（十条红线） | `docs/engineering/ARCHITECTURE.md`（四平面 + 依赖方向） |
| 判断该走多重的流程 | 本文件 §3 分级表 | `docs/engineering/templates/` 对应模板 |
| 改 `[custom]` 资源（手机 / 警务 / 剧情 / agent） | `T-CityLite.base/resources/[custom]/AGENTS.md` | `docs/client/PHONE_ARCHITECTURE.md`（手机） |
| 改 `[qb]` 上游框架 | `T-CityLite.base/resources/[qb]/AGENTS.md` | 对应资源自身的 README |
| 写/改测试 | `T-CityLite.base/tests/AGENTS.md` | 现有同类测试就是一个模板 |
| 改手机前端（Svelte/Vite） | `resources/[custom]/custom-phone/web/AGENTS.md` | `docs/client/research/nui-debug-playbook.md` |
| 新增 net event / 表 / 跨资源调用 | `ARCHITECTURE.md §4` | `tests/architecture/*.json` 三份登记表 |
| 想复用 / 合并重复实现 | `docs/engineering/REUSE.md` | `python3 tools/dev/reuse_scan.py --min 3` |
| 交付 / 发版 | `docs/engineering/templates/delivery.md` | `tools/dev/release_check.py` |

## 2. 十条红线（违反 = 打回，全文见 CONSTITUTION）

1. 服务端权威：客户端数据一律复验；NUI 隐藏 ≠ 权限。
2. 钱/物品只走 `Player.Functions.*` / `core_economy:TriggerReward`，不直接 SQL。
3. SQL 参数化 + 列白名单 + `LIMIT`；禁止 `SELECT *`。
4. 新 net event 要么鉴权，要么登记 `diagnostic` 并给投影/限流/预算。
5. 幂等：动作可重试、迁移可重复执行。
6. 表有唯一 owner（`table_owners.json`），跨资源写走 owner。
7. 诊断/遥测永不回包、永不落 PII。
8. 一次改动只动一个平面；跨平面必须声明契约变化。
9. 没有测试的修复不算完成（先红后绿）。
10. 交付三件套：代码 + 文档 + `CHANGELOG.md`；push 前跑 `release_check.py`。

## 3. 流程分级（避免"小改也写 spec"）

| 级别 | 判据 | 要做什么 |
|---|---|---|
| **L1 微改** | 注释、文案、单行 bug、资源重命名 | 直接改 + 跑相关测试 |
| **L2 常规** | 一个函数/一个回调/一个 app 页面 | 计划写在 commit message；测试必带 |
| **L3 结构** | 跨文件、跨平面、新增资源/事件/表 | 走完整五阶段（R/P/D/V/S），产物入库 |
| **L4 架构** | 鉴权模型、表结构、协议、依赖方向 | 五阶段 + 宪法对照 + 人审 |

模板：`docs/engineering/templates/{research,plan,tasks,verification,delivery}.md`。
判不准时按高一级走，并在计划里说明为什么。

## 4. 常用命令（照抄即可）

```bash
# 测试（仓库根，全部离线，不需要服务器/DB）
cd T-CityLite.base && /usr/bin/python3 -m pytest tests/unit tests/architecture -q
cd T-CityLite.base/resources/[custom]/custom-phone/web && node tests/nui/run.mjs
npx svelte-check --tsconfig ./tsconfig.app.json          # 前端类型

# 前端产物（改 web/src 后必须做）
cd T-CityLite.base/resources/[custom]/custom-phone/web && npm run build   # 输出到 ../../html

# Lua 语法（qb-core 例外：它用 CfxLua 扩展 `+=`，luac 无法解析）
luac5.4 -p <file.lua>

# Lua golden（13 suites，253 checks）
lua5.4 T-CityLite.base/tests/agent/lua/runner.lua

# 服务器（screen 会话 tcity；控制台用 tcity-cmd，见 ~/.local/bin）
screen -dmS tcity bash -c 'cd <repo> && ./start.sh > /tmp/tcity_console.log 2>&1'
tcity-cmd -w 8 "restart custom-phone"
tcity-cmd --page                                        # 当前控制台页
tail -40 /tmp/tcity_console.log                         # 服务端日志

# 交付前
python3 tools/dev/release_check.py
```

## 5. 环境事实（会变，但 agent 必须知道）

- 运行中的服务器 = **本仓库的 `T-CityLite.base`**，`start.sh` 拉起，端口 `30120/tcp+udp`。
- 控制台**没有 RCON**：走 `screen` 注入（`tcity-cmd`）。控制台是裸 stdin，没有行编辑；
  发送残留会和新命令拼成 `randomitemsrestart x`，工具会先发 80 个 DEL 清行。
- `server.cfg`、`alpine/`、`cache/`、`txData/` 均 gitignored；`server.cfg` 含 DB 密码、license、token，
  **永不提交**。凭据只放在 `~/.hermes/.tcity.env`（600）。
- 玩家重连后 server id 会变，按 id 操作前先查 `http://127.0.0.1:30120/players.json`。
- 改 `fxmanifest` **新增**脚本文件时必须 `refresh`（不是 `restart`），否则清单不重读。

## 6. 不要做

- 不要 `git add -A`（先 `git status`）；不要提交 `server.cfg` / token / `alpine/` / `cache/` / `txData/`。
- 不要在 `[qb]` 里做无关重排（会吞掉上游 diff，后续无法合并）。
- 不要把"应该做"写成"已经做"：文档里的状态要以代码和测试为准。
- 不要为了过闸门而改闸门：先判断是代码错还是规则错，改规则要写明理由与到期日。

**反引号里的路径必须能解析**：文档（含 `CHANGELOG.md`、`AGENTS.md`）里凡是写成`xxx/yyy.ext` 的反引号 token，断链闸门都会当成路径去解析；写不出来（比如只是 SQL 列名、资源内相对路径、manifest 的 `@resource/...` 写法）就不要用反引号，改成叙述。
