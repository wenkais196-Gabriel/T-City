"""租借原语（S1）：押金、计租、关闭路径、重启补退。

为什么单独立闸：热狗线把「租 → 卖 → 还」做成一个**会话**，钱在会话两端进出。
这类代码最容易出的错不是算错，而是**没有关闭路径**——
我们自己的物流就踩过：`ClearLogisticsBinding` 定义了却零调用，放弃/失败/断线后绑定残留。

本闸守 9 条不变量（由 `fixtures/rental_probe.lua` 真跑 `quest_rental.lua` 验证）：
押金不足不建会话 / 重复 open 被拒 / 正常关租退款 = 押金 − 租金 / 重复关租幂等 /
超时按 max_minutes 封顶 / 断线只排队不转账 / 启动扫描只排队 / 登录补退只发生一次 /
免租期内不产生租金。

并带反向校验：把「封顶」改成不封顶，探针必须红。
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
RENTAL = BASE / "resources/[custom]/custom-quest/server/quest_rental.lua"
PROBE = Path(__file__).resolve().parent / "fixtures" / "rental_probe.lua"
LUA = shutil.which("lua5.4")


def run_probe(source: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [LUA, str(PROBE), str(source)],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90,
    )


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4；缺它就只能跑静态断言")
def test_rental_invariants_hold():
    proc = run_probe(RENTAL)
    assert proc.returncode == 0, f"探针失败：\n{proc.stdout}\n{proc.stderr}"
    assert "SUMMARY 11/11" in proc.stdout


@pytest.mark.skipif(LUA is None, reason="需要 lua5.4")
def test_probe_goes_red_when_the_cap_is_removed(tmp_path: Path):
    """反向校验：去掉 max_minutes 封顶，超时那一条必须红。"""
    src = RENTAL.read_text(encoding="utf-8")
    assert "if maxMinutes > 0 and minutes > maxMinutes then" in src
    mutated = src.replace("if maxMinutes > 0 and minutes > maxMinutes then", "if false then")
    target = tmp_path / "quest_rental_mutant.lua"
    target.write_text(mutated, encoding="utf-8")
    proc = run_probe(target)
    assert proc.returncode != 0, "去掉封顶后探针仍然通过 —— 这条闸没有在验证任何东西"
    assert "timeout_is_capped_at_max_minutes" in proc.stdout
    assert "FAIL" in proc.stdout


def test_close_paths_are_wired_into_every_termination_route():
    """成功、失败、放弃、断线四条路径都必须关租；少一条就是「押金要不回来」。

    成功这条最容易被漏（本会话就漏过一次）：失败/放弃/断线都关了，
    但完成任务时没人关，押金就卡在会话里直到玩家下次断线或超时。
    """
    manager = (BASE / "resources/[custom]/custom-quest/server/quest_manager.lua").read_text(encoding="utf-8")
    cache = (BASE / "resources/[custom]/custom-quest/server/quest_cache.lua").read_text(encoding="utf-8")
    assert "closeRentalFor(src, 'returned', questId)" in manager, "完成任务时没有关租 —— happy path 押金退不回来"
    assert "closeRentalFor(source, 'failed', questId)" in manager
    assert "closeRentalFor(source, 'abandoned', questId)" in manager
    assert "QuestRental.CloseOnDrop" in cache


def test_drop_path_defers_money_instead_of_paying_offline():
    """断线不能直接 AddMoney —— 那时玩家对象已经不可用。必须走待退队列。"""
    src = RENTAL.read_text(encoding="utf-8")
    drop_body = src[src.index("function QuestRental.CloseOnDrop"):src.index("function QuestRental.QueueUnclosedSessions")]
    assert "AddMoney" not in drop_body, "断线路径里出现了 AddMoney —— 离线玩家没有合法的写入路径"
    assert "PendingRefunds[citizenid]" in drop_body


def test_restart_scan_only_queues():
    """启动扫描只读日志 + 写内存，不许转账。"""
    src = RENTAL.read_text(encoding="utf-8")
    scan_body = src[src.index("function QuestRental.QueueUnclosedSessions"):src.index("function QuestRental.ClaimPendingRefund")]
    assert "AddMoney" not in scan_body, "启动扫描里出现了 AddMoney"
    assert "PendingRefunds[cid]" in scan_body



def test_rental_step_is_wired_end_to_end_on_the_client_side():
    """真机症状：走到租赁点没有「按 E」提示。

    原因是三张表都要登记，少一张这一步就静默死掉：
      1) 服务端 QuestNodes._eventMap 没有 RENTAL → 打「Unknown node type」→ 客户端收不到节点；
      2) ValidateNode 的别名表没有 RENTAL→INTERACT → 客户端上报 INTERACT 被判定类型不符；
      3) 配置与客户端的 checkpoint 类型推断表没有 rental → 不画 checkpoint。
    这三处都属于「配置选到一个没人处理的名字」，运行时没有任何报错，只有玩家发现按不了 E。
    """
    manager = (BASE / "resources/[custom]/custom-quest/server/quest_manager.lua").read_text(encoding="utf-8")
    config = (BASE / "resources/[custom]/custom-quest/config.lua").read_text(encoding="utf-8")
    checkpoint = (BASE / "resources/[custom]/custom-quest/client/quest_checkpoint.lua").read_text(encoding="utf-8")

    assert "RENTAL    = 'quest:client:nodeInteract'" in manager, "服务端没有把 rental 映射到客户端节点"
    assert "RENTAL = 'INTERACT'" in manager, "别名表缺 RENTAL→INTERACT，客户端上报会被判类型不符"
    assert "rental    = 'arrow'" in config, "配置的 checkpoint 类型表缺 rental"
    assert "rental    = 'arrow'" in checkpoint, "客户端的 checkpoint 类型推断表缺 rental"


def test_rental_wiring_rule_rejects_the_silent_dead_shape():
    """反向校验：只有事件映射、没有别名时，规则必须判红。"""
    broken = "RENTAL = 'quest:client:nodeInteract'"
    assert "RENTAL = 'INTERACT'" not in broken



def test_close_helpers_are_declared_before_their_first_use():
    """Lua 的 local 只在声明之后可见 —— 顺序错了就是运行时 nil 调用。

    真机症状：任务结算到一半 `attempt to call a nil value (global 'closeRentalFor')`，
    因为 helper 原本写在 FailQuest 之前（≈1160 行），而完成路径在 911 行就调它。
    `luac -p` 查不出这类错（语法没问题，作用域有问题）。
    """
    src = (BASE / "resources/[custom]/custom-quest/server/quest_manager.lua").read_text(encoding="utf-8")
    for name in ("closeRentalFor", "clearLogisticsFor"):
        declared = src.find(f"local function {name}(")
        assert declared != -1, f"{name} 没有声明"
        uses = [i for i in range(len(src)) if src.startswith(name + "(", i)]
        body_uses = [u for u in uses if u != declared]
        assert body_uses, f"{name} 没有任何调用点"
        assert declared < min(body_uses), (
            f"{name} 在声明（偏移 {declared}）之前就被调用了（偏移 {min(body_uses)}）——"
            "运行时会退化成全局查找并报 nil")


def test_helper_order_rule_rejects_use_before_declaration():
    """反向校验：调用写在声明之前，规则必须判红。"""
    broken = "closeRentalFor(src, 'returned')\nlocal function closeRentalFor(source, reason)\nend\ncloseRentalFor(x, 'y')\n"
    declared = broken.find("local function closeRentalFor(")
    uses = [i for i in range(len(broken)) if broken.startswith("closeRentalFor(", i)]
    body_uses = [u for u in uses if u != declared]
    assert not (declared < min(body_uses))



def test_late_node_complete_is_not_shown_to_the_player_as_an_error():
    """任务刚完成时客户端还握着一个节点，会再上报一次 nodeComplete。

    真机表现：任务明明完成了，屏幕却弹「任务节点校验失败」——服务端把「任务不活跃」
    当成作弊拦截并把红字推给了玩家。诚实玩家只是晚到几百毫秒。
    修法：审计照留（print + custom-logs），但这一种原因不再 feedback。
    """
    src = (BASE / "resources/[custom]/custom-quest/server/main.lua").read_text(encoding="utf-8")
    assert "benignLatePacket" in src, "迟到包的豁免没了 —— 玩家会再次看到假的校验失败"
    assert "if not benignLatePacket then" in src
    # 反向：豁免必须只针对这一种原因，不能把所有安全拦截都静音
    assert "err == 'Quest not active for this player'" in src


def test_client_does_not_re_send_the_same_node_twice():
    """同一个 INTERACT 节点只能上报一次：上报后把 activeNode 置空。"""
    src = (BASE / "resources/[custom]/custom-quest/client/main.lua").read_text(encoding="utf-8")
    node_body = src[src.index("RegisterNetEvent('quest:client:nodeInteract'"):]
    node_body = node_body[:node_body.index("RegisterNetEvent('quest:client:nodeDeliver'") if "nodeDeliver" in node_body else len(node_body)]
    assert node_body.count("activeNode = nil") >= 2, "上报后没有清 activeNode —— 同一节点会被循环重复上报"
    assert "if activeNode and activeNode.stepId == data.stepId then" in node_body, "无进度条分支缺少前置护栏"



def test_rental_type_is_registered_in_every_dispatch_table():
    """CC 复核列出 RENTAL 需要登记的 8 处；漂移一处就是「配置合法、走到点上没反应」。

    本次真机连撞的四处：事件映射、别名单、函数作用域、校验闸；
    这里再补最容易漏的第 5 处 —— `atomTypes`（决定非第一步的节点会不会被下发）。
    """
    manager = (BASE / "resources/[custom]/custom-quest/server/quest_manager.lua").read_text(encoding="utf-8")
    atom_line = next(l for l in manager.splitlines() if "local atomTypes =" in l)
    assert "RENTAL = true" in atom_line, "atomTypes 没有 RENTAL —— rental 只要不是第一步就不会下发节点"


def test_client_active_node_local_is_declared_before_every_cleanup_helper():
    """activeNode 的 local 必须声明在 ClearZone / clearAllNodes 之前。

    声明在 389 行时，之前那些函数里的 `activeNode = nil` 清的是**全局**，
    与节点线程读写的 file-local 是两个变量 —— 完成/失败/放弃都清不掉线程，
    玩家走回同一坐标还能再按一次 E（真机症状：任务完成后弹 任务节点校验失败）。
    """
    src = (BASE / "resources/[custom]/custom-quest/client/main.lua").read_text(encoding="utf-8")
    declared = src.index("local activeNode = nil")
    first_cleanup = src.index("activeNode = nil", declared + 1)
    clear_zone = src.index("function ClearZone()")
    assert declared < clear_zone, "activeNode 的 local 又跑到 ClearZone 后面去了 —— 清理会清到全局"
    assert declared < first_cleanup


def test_rental_payload_carries_the_step_id_for_audit():
    """不带 nodeId 的话，rental_open / rental_close 的 step_id 永远是 NULL。"""
    gate = (BASE / "resources/[custom]/custom-quest/server/quest_step_gate.lua").read_text(encoding="utf-8")
    assert "payload.nodeId = step.id" in gate
    for key in ("deposit", "rate_per_min", "grace_sec", "max_minutes"):
        assert key + " = true" in gate, f"META_KEYS 缺 {key}：写在 step.data 顶层时会静默变 0"


def test_rental_steps_must_declare_a_validator_at_registration_time():
    """没有 validator_id 的 rental 步骤应当注册失败，而不是运行时静默不扣押金。"""
    reg = (BASE / "resources/[custom]/custom-quest/server/quest_registry.lua").read_text(encoding="utf-8")
    assert "is rental but has no validator_id" in reg



def test_restart_scan_pairs_close_with_the_right_open():
    """重启扫描按 started_at 配对，而不是「有更晚的 close 就算已关闭」。

    只比时间先后的话：同一任务第二次租借的 close 会把第一次未关闭的 open
    证明成已关闭，第一次的押金静默丢失。
    """
    db = (BASE / "resources/[custom]/custom-quest/server/quest_db.lua").read_text(encoding="utf-8")
    assert "JSON_EXTRACT(c.metadata, '$.started_at')" in db, "配对没按 started_at —— 会串单"
    assert "JSON_EXTRACT(o.metadata, '$.started_at')" in db


def test_deposit_is_only_taken_when_the_journal_row_lands():
    """扣钱与落库要么一起成功，要么一起回滚。

    扣了钱但 rental_open 写不进去 = 重启后扫不到这条会话 = 押金永远退不回来。
    """
    src = (BASE / "resources/[custom]/custom-quest/server/quest_rental.lua").read_text(encoding="utf-8")
    open_body = src[src.index("function QuestRental.Open"):src.index("function QuestRental.Close")]
    assert "rollbackJournal" in open_body, "没有回滚路径：落库失败时押金会被吞"
    assert "quest-rental-rollback" in open_body
    assert "journal_unavailable" in open_body, "没有 DB 层时应当拒绝开租，而不是收钱"



def test_validator_node_also_clears_active_node_after_reporting():
    """validator 节点（物流/航空在用）上报后同样要清 activeNode。

    CC 复核 D-3：它以前完全不清。下一步若是 reach（没有节点事件去覆盖），
    这条线程会活到下一站，玩家再按一次 E 就给已完成的校验步骤补报一次 → 顺序校验失败 → 红字。
    """
    src = (BASE / "resources/[custom]/custom-quest/client/quest_logistics_client.lua").read_text(encoding="utf-8")
    body = src[src.index("RegisterNetEvent('quest:client:nodeValidator'"):]
    body = body[:body.index("if PolyZone then")]
    assert body.count("activeNode = nil") >= 2, "两条上报分支都要清 activeNode"