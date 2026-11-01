#!/usr/bin/env python3
"""闸门变异冒烟测试 — 证明"这些闸门真的会红"。

背景：`gate_stats --report` 会列出"从未失败过"的规则。从未失败有两种含义——
规则保护的东西已经不存在（该删），或者**它根本没被检验过**（让人误以为安全）。
这个工具把后者变成可重复的事实：往仓库里塞一个"该被拦住的形状"，跑那条闸门，
确认它变红，再把注入删掉；同时跑一次"不注入"的对照，证明它不是永远红。

用法::

    python3 tools/dev/gate_mutation_smoke.py            # 跑全部用例，出表
    python3 tools/dev/gate_mutation_smoke.py --dry-run  # 只列用例
    python3 tools/dev/gate_mutation_smoke.py --only economy
    python3 tools/dev/gate_mutation_smoke.py --json

退出码：0 = 每条用例都"注入后红、对照绿"；1 = 有用例没红（闸门失效）；2 = 环境不对。

注意：这个工具**会临时改工作区**（写入一个注入文件，跑完立即删除）。不要在有未提交
改动的树上跑它来排查别的问题——`--dry-run` 可以先看清它会写哪些路径。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
ARCH = BASE / "tests" / "architecture"


@dataclass(frozen=True)
class Mutation:
    gate: str          # pytest nodeid（相对 T-CityLite.base）
    path: str          # 注入文件（相对 T-CityLite.base）
    content: str | None  # 注入内容；None = 就地篡改 path 指向的已有文件
    what: str          # 这条注入代表什么错误形状
    replace_from: str | None = None  # 就地篡改时的原文片段（None = 旧的追加式篡改）
    replace_to: str = ""             # 用它替换 replace_from

    @property
    def target(self) -> Path:
        return BASE / self.path


MUTATIONS: list[Mutation] = [
    Mutation(
        gate=("tests/architecture/test_backup_lifetime_owner.py::"
              "test_client_lifetime_requires_the_server_owner_guard"),
        path="resources/[custom]/custom-police/client/backup.lua",
        content=None,
        replace_from="if not serverOwnsLifetime() and now - state.createdAt >= UNIT_LIFETIME_MS then",
        replace_to="if now - state.createdAt >= UNIT_LIFETIME_MS then",
        what="支援单位把客户端 5 分钟自计时加回去（寿命变成两个主人，服务端 sweep 白做）",
    ),
    Mutation(
        gate="tests/architecture/test_no_sri_on_local_vendor.py::test_custom_html_has_no_integrity_attributes",
        path="resources/[custom]/custom-phone/html/__mutant_sri.html",
        content=(
            '<!-- 变异注入：对本地 vendor 文件写 integrity -->'
            '<script src="vendor/x.js" integrity="sha384-deadbeef" crossorigin="anonymous"></script>'
        ),
        what="自定义资源对本地文件用 SRI（换行符一变哈希就错，CEF 直接拦掉脚本）",
    ),

    Mutation(
        gate="tests/architecture/test_export_contracts.py::test_every_export_has_a_permission_or_source_gate",
        path="resources/[custom]/custom-police/server/__mutant_export.lua",
        content=(
            "-- 变异注入：一个不做任何权限判定的导出\n"
            "local function probeNoGate(actor)\n"
            "    return { ok = true, citizenid = actor.citizenid }\n"
            "end\n"
            "exports('ProbeNoGate', probeNoGate)\n"
        ),
        what="没有权限判定的导出（谁都能调，且直接回显公民 ID）",
    ),


    Mutation(
        gate="tests/architecture/test_client_observability.py::test_include_rule_detects_a_missing_helper",
        path="resources/[custom]/custom-quest/fxmanifest.lua",
        content=None,
        replace_from="    '@core-framework/client/shared.lua',\n",
        replace_to="",
        what="自有客户端资源删掉了客户端共享助手（错误上行通道断掉）",
    ),

    Mutation(
        gate="tests/architecture/test_evidence_authority.py::test_identity_fields_come_from_the_server_record",
        path="resources/[custom]/custom-police/server/evidence.lua",
        content=None,
        replace_from="        ammotype = drop.weapon,\n        serie = drop.serie,\n",
        replace_to="        ammotype = casingInfo.ammotype,\n        serie = casingInfo.serie,\n",
        what="弹壳拾取又变回采信客户端声称的 weapon/serie（改过的客户端可伪造证据）",
    ),

    Mutation(
        gate="tests/architecture/test_economy_single_owner.py::test_only_the_owner_writes_players_money",
        path="resources/[custom]/custom-phone/server/__mutant_money.lua",
        content=("-- 变异注入：在 owner 之外直接改 players.money\n"
                 "local function sneaky()\n"
                 "    MySQL.update('UPDATE players SET money = ? WHERE citizenid = ?', { 1, 'abc' })\n"
                 "end\n"),
        what="第二条钱的写路径（整块覆盖）",
    ),
    Mutation(
        gate="tests/architecture/test_economy_single_owner.py::test_no_whole_blob_money_overwrite",
        path="resources/[custom]/custom-phone/server/__mutant_blob.lua",
        content="local q = 'UPDATE players SET money = ? WHERE citizenid = ?'\n",
        what="整块覆盖 money 列的 SQL",
    ),
    Mutation(
        gate="tests/architecture/test_rate_limit_single_owner.py::test_no_new_rate_limiter_grows",
        path="resources/[custom]/custom-vehicles/server/__mutant_ratelimit.lua",
        content=("-- 变异注入：又写一份限流\n"
                 "local UserCooldowns = {}\n"
                 "local function rl(src, action, ms) return true end\n"),
        what="自建限流表",
    ),
    Mutation(
        gate="tests/architecture/test_plane_boundaries.py::test_planes_do_not_leak_across_boundaries",
        path="resources/[custom]/custom-vehicles/client/__mutant_plane.lua",
        content="-- 变异注入：客户端直连数据库\nlocal x = MySQL.Async.fetchAll('SELECT 1', {})\n",
        what="client 里碰 DB",
    ),
    Mutation(
        gate="tests/architecture/test_reuse_budget.py::test_no_new_duplication_and_budget_is_tight",
        path="resources/[custom]/custom-police/client/__mutant_dup.lua",
        content=("local function loadAnimDict(dict)\n"
                 "    RequestAnimDict(dict)\n"
                 "    while not HasAnimDictLoaded(dict) do Wait(5) end\n"
                 "end\n"),
        what="又抄一份 loadAnimDict",
    ),
    Mutation(
        gate="tests/architecture/test_docs_links.py::test_active_docs_have_no_broken_paths",
        path="../docs/engineering/__mutant_link.md",
        content="# 变异注入\n\n参见 `docs/engineering/does-not-exist-42.md`。\n",
        what="约束区文档里的断链",
    ),
    Mutation(
        gate="tests/architecture/test_agent_docs.py::test_no_orphan_agents_doc_exists",
        path="resources/[custom]/custom-police/client/AGENTS.md",
        content=("# 未登记的分区文件\n\n## 唯一入口\n## 禁止\n## 改动前必读\n## 验收命令\n"),
        what="新增一份没人登记的 AGENTS.md",
    ),
    Mutation(
        gate="tests/architecture/test_manifest_syntax.py::test_every_manifest_parses",
        path="resources/[custom]/custom-vehicles/fxmanifest.lua",
        content=None,   # 特殊处理：在现有 manifest 末尾追加一条缺逗号的依赖
        what="manifest 语法错误（缺逗号）",
    ),
]



MUTATIONS += [
    Mutation(
        gate="tests/architecture/test_net_event_auth.py::test_every_net_event_is_authenticated_or_registered",
        path="resources/[custom]/custom-police/server/__mutant_netevent.lua",
        content=("-- 变异注入：注册一个没有鉴权 token 的 net event\n"
                 "RegisterNetEvent('probe:server:evil', function(amount)\n"
                 "    print(amount)\n"
                 "end)\n"),
        what="无鉴权的 net event",
    ),
    Mutation(
        gate="tests/architecture/test_state_writers.py::test_no_unregistered_state_writer",
        path="resources/[custom]/custom-police/server/__mutant_statewrite.lua",
        # 必须是规则跟踪的列（police_incidents.status）；写别的列会被 classify() 判为"不归它管"，
        # 于是注入不触发——第一版就是用 title 写的，跑出"没红"。
        content=("-- 变异注入：绕过 service 直接写别人拥有的状态表\n"
                 "CreateThread(function()\n"
                 "    MySQL.update('UPDATE police_incidents SET status = ? WHERE id = ?', { 'x', 1 })\n"
                 "end)\n"),
        what="未登记的状态写路径（规则跟踪的列）",
    ),
    Mutation(
        gate="tests/architecture/test_query_discipline.py::test_no_query_discipline_violations",
        path="resources/[custom]/custom-police/server/__mutant_selectstar.lua",
        content=("-- 变异注入：SELECT * 与无 LIMIT 的全表拉取\n"
                 "CreateThread(function()\n"
                 "    MySQL.query.await('SELECT * FROM players')\n"
                 "end)\n"),
        what="SELECT * / 无 LIMIT",
    ),
    Mutation(
        gate="tests/architecture/test_command_guards.py::test_command_handlers_guard_missing_player",
        path="resources/[custom]/custom-police/server/__mutant_command.lua",
        content=("-- 变异注入：命令处理函数直接索引玩家，不判空\n"
                 "QBCore.Commands.Add('probeunguarded', 'probe', {}, false, function(source)\n"
                 "    local Player = QBCore.Functions.GetPlayer(source)\n"
                 "    print(Player.PlayerData.citizenid)\n"
                 "end)\n"),
        what="命令处理器没守 source == 0 / 离线玩家",
    ),
    Mutation(
        gate="tests/architecture/test_duty_writer.py::test_scan_passes_with_zero_unregistered_writers",
        path="resources/[custom]/custom-police/server/__mutant_duty.lua",
        content=("-- 变异注入：模块作用域直接写值勤状态\n"
                 "CreateThread(function()\n"
                 "    local Player = QBCore.Functions.GetPlayer(1)\n"
                 "    if Player then Player.Functions.SetJobDuty(true) end\n"
                 "end)\n"),
        what="未经 owner 的 SetJobDuty 写路径",
    ),
]



MUTATIONS += [
    Mutation(
        gate="tests/architecture/test_cross_resource_writes.py::test_no_unregistered_cross_resource_writes",
        path="resources/[custom]/custom-police/server/__mutant_crosswrite.lua",
        # 用 player_houses（owner=qb-houses）：custom-police 对 player_vehicles 有已登记的
        # 豁免（拖车），写那张表是合规的——第一版就是撞在这条豁免上，跑出"没红"。
        content=("-- 变异注入：直接写别的资源拥有的表（player_houses 归 qb-houses）\n"
                 "CreateThread(function()\n"
                 "    MySQL.update('UPDATE player_houses SET owned = ? WHERE house = ?', { 1, 'x' })\n"
                 "end)\n"),
        what="跨资源直接写别人的表",
    ),
    Mutation(
        gate="tests/architecture/test_agent_docs.py::test_area_docs_keep_the_fixed_sections",
        path="resources/[custom]/custom-police/client/AGENTS.md",
        content=("# 分区说明（缺章节）\n\n随便写点东西，四节一个都没有。\n"),
        what="分区 AGENTS.md 缺固定章节",
    ),
]



MUTATIONS += [
    Mutation(
        gate="tests/architecture/test_police_single_writer.py::test_owned_tables_have_exactly_one_writer",
        path="resources/[custom]/custom-police/server/__mutant_incident_writer.lua",
        content=("-- 变异注入：绕过 p0 的唯一写者，直接建单\n"
                 "CreateThread(function()\n"
                 "    MySQL.insert.await('INSERT INTO police_incidents (code, title) VALUES (?, ?)', { 'X', 'y' })\n"
                 "end)\n"),
        what="police_incidents 出现第二个写者",
    ),
    Mutation(
        gate="tests/architecture/test_police_single_writer.py::test_owned_tables_have_exactly_one_writer",
        path="resources/[custom]/custom-police/server/__mutant_audit.lua",
        content=("-- 变异注入：绕过审计的唯一写者，自己 INSERT 审计行（旧写法：参数数组带洞）\n"
                 "local function rogueAudit(cid, action, target, detail)\n"
                 "    MySQL.insert.await('INSERT INTO police_audit (actor_citizenid, actor_kind, action, target, detail)'\n"
                 "        .. ' VALUES (?, \"player\", ?, ?, ?)', { cid, action, target, detail })\n"
                 "end\n"),
        what="police_audit 出现第二个写者",
    ),
]



MUTATIONS += [
    Mutation(
        gate="tests/architecture/test_client_hot_paths.py::test_no_duplicate_per_frame_control_polling",
        path="resources/[custom]/custom-police/client/__mutant_poll.lua",
        content=("-- 变异注入：手写逐帧按键轮询（该走 PoliceInteract.Watch）\n"
                 "CreateThread(function()\n"
                 "    while true do\n"
                 "        Wait(0)\n"
                 "        if IsControlJustReleased(0, 38) then TriggerEvent('x') end\n"
                 "    end\n"
                 "end)\n"),
        what="手写逐帧按键轮询",
    ),
]

# P1-3：全仓 net event 基线（批次① 100% + 存量棘轮）
MUTATIONS += [
    Mutation(
        gate=("tests/architecture/test_net_event_inventory.py::"
              "test_baseline_matches_live_inventory"),
        path="resources/[custom]/__mutant_net/server/__mutant.lua",
        content="""-- 变异注入：全仓范围内新冒出一个未鉴权的 net event
RegisterNetEvent('mutant:server:verb', function(payload)
    print(payload)
end)
""",
        what="未鉴权 net event 悄悄落进某个非强制资源（基线棘轮必须拦住）",
    ),
    Mutation(
        gate=("tests/architecture/test_net_event_inventory.py::"
              "test_enforced_batch_has_zero_unguarded_events"),
        path="resources/[qb]/qb-core/server/__mutant_net.lua",
        content="""-- 变异注入：引擎层出现未鉴权的 net event
RegisterNetEvent('QBCore:Server:MutantVerb', function(payload)
    print(payload)
end)
""",
        what="批次①（引擎层）从 100% 掉下来",
    ),
    Mutation(
        gate=("tests/architecture/test_net_event_inventory.py::"
              "test_non_literal_registrations_match_the_baseline"),
        path="resources/[custom]/__mutant_net/server/__mutant_literal.lua",
        content="""-- 变异注入：变量名注册（闸门看不见事件名）
local EVENT_NAME = 'mutant:server:hidden'
RegisterNetEvent(EVENT_NAME, function() end)
""",
        what="变量名注册的 net event（对扫描器不可见）",
    ),
    Mutation(
        gate=("tests/architecture/test_net_event_inventory.py::"
              "test_unparsed_handlers_match_the_baseline"),
        path="resources/[custom]/__mutant_net/server/__mutant_unparsed.lua",
        content="""-- 变异注入：handler 没有行首 end)，扫描器解析不了
RegisterNetEvent('mutant:server:unparsed', function()
    if true then print('x') end
end
""",
        what="解析不了的 handler（等于没有任何闸门看得见它）",
    ),
    Mutation(
        gate=("tests/architecture/test_net_event_inventory.py::"
              "test_every_resource_with_debt_has_an_owner_and_a_future_expiry"),
        path="tests/architecture/net_events_baseline.json",
        content=None,
        replace_from='"expires": "2027-03-31"',
        replace_to='"expires": "2020-01-01"',
        what="债的到期日已经过去（清单变成永不过期的白名单）",
    ),
    Mutation(
        gate="tests/architecture/test_net_event_inventory.py::test_batch_totals_add_up",
        path="tests/architecture/net_events_baseline.json",
        content=None,
        replace_from='"events": 15,',
        replace_to='"events": 99,',
        what="批次数字与清单对不上（被手改过）",
    ),
]

# P1-3 第二批：回调分发器的高危目标 + 基线数字的可信度
MUTATIONS += [
    Mutation(
        gate=("tests/architecture/test_net_event_auth.py::"
              "test_relay_callbacks_that_spawn_vehicles_are_guarded_somewhere"),
        path="resources/[custom]/custom-security/server/security.lua",
        content=None,
        replace_from="QBCore.ServerCallbacks['QBCore:Server:SpawnVehicle'] = function(source, cb, model, coords, warp)",
        replace_to="QBCore.ServerCallbacks['SpawnVehicle'] = function(source, cb, model, coords, warp)",
        what="custom-security 不再劫持刷车回调（任何客户端都能通过 TriggerCallback 让服务端 CreateVehicle）",
    ),
    Mutation(
        gate=("tests/architecture/test_net_event_inventory.py::"
              "test_recorded_counts_match_the_live_scan"),
        path="tests/architecture/net_events_baseline.json",
        content=None,
        replace_from='"guarded": 19,',
        replace_to='"guarded": 20,',
        what="手改基线里的 guarded 数字（批次和仍然成立，但和实测对不上）",
    ),
]

# P1-3 第三批：`src == 0` 不是鉴权
MUTATIONS += [
    Mutation(
        gate=("tests/architecture/test_net_event_inventory.py::"
              "test_system_source_token_only_counts_the_server_only_shape"),
        path="tests/architecture/net_event_scan.py",
        content=None,
        replace_from='"system_source": re.compile(r"\\bsrc\\s*~=\\s*0\\s+then\\s+return\\b|\\bsource\\s*~=\\s*0\\s+then\\s+return\\b"),',
        replace_to='"system_source": re.compile(r"\\bsrc\\s*==?\\s*0\\b"),',
        what="把 src == 0（只排除控制台）又当成鉴权 token —— 任何玩家照样能触发",
    ),
]

# P1-3 第四批：helper 登记表只认"看了返回值的调用"
MUTATIONS += [
    Mutation(
        gate=("tests/architecture/test_net_event_auth.py::"
              "test_registered_guard_helpers_are_proven"),
        path="resources/[custom]/custom-vehicles/server/vehicle_state.lua",
        content=None,
        replace_from="    if not CanModifyPlate(source, plate) then return end",
        replace_to="    CanModifyPlate(source, plate) -- 变异：调用了但忽略返回值",
        what="鉴权 helper 被调用但不看返回值（等于没有任何保护）",
    ),
    Mutation(
        gate=("tests/architecture/test_net_event_auth.py::"
              "test_shapes_that_look_like_guards_are_not_counted"),
        path="tests/architecture/net_event_scan.py",
        content=None,
        replace_from='if inner.startswith("return"):',
        replace_to='if False:',
        what="否定分支不再要求 return（‘判了但没拦住’会被当成已鉴权）",
    ),
]


def run_gate(nodeid: str) -> tuple[bool, str]:
    """返回 (passed, 最后一行输出)。passed=True 表示这条闸门**没红**。"""
    # Linux 布局用 /usr/bin/python3；Windows 上没这个路径，退回当前解释器
    # （否则整个工具在这台机器上直接 FileNotFoundError，连 --dry-run 都跑不通）。
    interpreter = "/usr/bin/python3" if Path("/usr/bin/python3").exists() else sys.executable
    proc = subprocess.run(
        [interpreter, "-m", "pytest", nodeid, "-q", "--tb=no", "-p", "no:cacheprovider"],
        cwd=BASE, capture_output=True, text=True,
    )
    tail = (proc.stdout or proc.stderr).strip().splitlines()
    return proc.returncode == 0, (tail[-1] if tail else "")


def run_once(mutation: Mutation) -> dict:
    target = mutation.target
    if mutation.content is not None and target.exists():
        return {"gate": mutation.gate, "what": mutation.what, "status": "skipped",
                "detail": f"目标文件已存在，不覆盖：{target.relative_to(REPO)}"}
    if mutation.content is None and not target.exists():
        return {"gate": mutation.gate, "what": mutation.what, "status": "skipped",
                "detail": f"要篡改的文件不存在：{target.relative_to(REPO)}"}

    backup = None
    created: list[Path] = []
    if mutation.content is None and mutation.replace_from:   # 就地替换片段
        backup = target.read_text(encoding="utf-8")
        if mutation.replace_from not in backup:
            return {"gate": mutation.gate, "what": mutation.what, "status": "skipped",
                    "detail": f"要替换的片段在 {target.relative_to(REPO)} 里找不到（代码变了，更新用例）"}
        target.write_text(backup.replace(mutation.replace_from, mutation.replace_to, 1), encoding="utf-8")
    elif mutation.content is None:          # 就地追加（历史形状）
        backup = target.read_text(encoding="utf-8")
        target.write_text(backup.rstrip("\n") + "\n\n    'core-framework'\nend\n", encoding="utf-8")
    else:
        # 记下这次真正新建的目录层级，撤注入后要删掉 —— 空目录会让
        # `test_no_orphan_scripts`（每个 [custom] 目录必须有 fxmanifest）误红。
        parent = target.parent
        while not parent.exists() and parent != BASE.parent:
            created.append(parent)
            parent = parent.parent
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(mutation.content, encoding="utf-8")

    try:
        passed_after_injection, injected_line = run_gate(mutation.gate)
    finally:
        if backup is not None:
            target.write_text(backup, encoding="utf-8")
        else:
            target.unlink(missing_ok=True)
            for directory in created:          # 由深到浅，只删空目录
                try:
                    directory.rmdir()
                except OSError:
                    break

    passed_after_cleanup, control_line = run_gate(mutation.gate)   # 对照：撤掉注入必须恢复绿
    if (not passed_after_injection) and passed_after_cleanup:
        status = "ok"
    elif passed_after_injection:
        status = "gate-dead"          # 注入后仍然通过 → 规则没生效
    else:
        status = "always-red"         # 撤掉注入还红 → 规则本身坏了，或有别的脏东西

    return {"gate": mutation.gate, "what": mutation.what, "status": status,
            "injected": injected_line, "control": control_line}


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--only", default=None, help="只跑 gate 路径里含该子串的用例")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv[1:])

    if not ARCH.is_dir():
        print(f"找不到架构闸门目录：{ARCH}", file=sys.stderr)
        return 2

    cases = [m for m in MUTATIONS if not args.only or args.only in m.gate]
    if not cases:
        print(f"没有匹配 {args.only!r} 的用例", file=sys.stderr)
        return 2

    if args.dry_run:
        for m in cases:
            print(f"{m.gate}\n    注入 {m.path}\n    {m.what}")
        return 0

    results = [run_once(m) for m in cases]
    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    else:
        width = max(len(r["gate"].split("::")[-1]) for r in results)
        print(f"{'闸门用例'.ljust(width)}  注入后   对照   判定")
        for r in results:
            verdict = {"ok": "会红 ✓", "gate-dead": "没红 ✗（规则失效）",
                       "always-red": "常红 ✗（规则坏了）", "skipped": "跳过"}[r["status"]]
            inj = "红" if "failed" in str(r.get("injected", "")) else "绿"
            ctl = "绿" if "passed" in str(r.get("control", "")) else "红"
            print(f"{r['gate'].split('::')[-1].ljust(width)}  {inj:^6}  {ctl:^4}   {verdict}")
        dead = [r for r in results if r["status"] in ("gate-dead", "always-red")]
        print(f"\n{len(results)} 条用例：{len(results)-len(dead)} 条证明会红，{len(dead)} 条有问题")
        for r in dead:
            print(f"  ! {r['gate']}: {r['status']} — {r.get('injected') or r.get('detail')}")

    return 0 if all(r["status"] in ("ok", "skipped") for r in results) else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except BrokenPipeError:          # `| head` 之类的下游提前关闭管道
        sys.exit(0)
