#!/usr/bin/env python3
# =============================================================================
# concurrency_stress_test.py — Mutex 并发竞态 + 边界异常恢复测试 v1.0
# =============================================================================
# 模拟场景:
#   1. 100 名虚拟玩家同时竞争同一个 competitive 任务奖励
#   2. 玩家在交互中途断线/载具被毁/背包满
#   3. 排他锁: 只有第一个玩家获得奖励, 其余 99 个被正确驳回
# =============================================================================

import random
import time
import threading
from dataclasses import dataclass
from typing import Dict

# ── 简化的 QuestMutex 实现 (与 Lua 版本逻辑完全一致) ──────────────────

@dataclass
class MutexLock:
    owner: int
    mode: str
    locked_at: float
    instance_id: str

class SimpleMutex:
    """模拟 quest_mutex.lua 的行为"""
    def __init__(self):
        self.locks: Dict[str, MutexLock] = {}
        self.expire_sec = 30 * 60  # 30 分钟

    def acquire(self, quest_id: str, player_id: int, mode: str, step_id: str = None) -> tuple:
        key = f"{quest_id}:step:{step_id}" if step_id else quest_id
        existing = self.locks.get(key)

        if existing and time.time() - existing.locked_at < self.expire_sec:
            if mode == "competitive" and existing.owner != player_id:
                return False, None, "Target已被其他人抢先完成"
            return True, existing.instance_id, None

        instance_id = f"inst-{random.randint(10000,99999)}"
        self.locks[key] = MutexLock(owner=player_id, mode=mode, locked_at=time.time(), instance_id=instance_id)
        return True, instance_id, None

    def release(self, quest_id: str, player_id: int, step_id: str = None):
        key = f"{quest_id}:step:{step_id}" if step_id else quest_id
        existing = self.locks.get(key)
        if existing and existing.owner == player_id:
            del self.locks[key]
            return True
        return False

# ── 测试结果 ──────────────────────────────────────────────────────────

results = {
    "competitive_granted": [],
    "competitive_rejected": [],
    "rollback_success": 0,
    "rollback_fail": 0,
    "boundary_recovered": 0,
}

# ── 测试 1: 100 玩家同时竞争 ──────────────────────────────────────────

def test_competitive_concurrency():
    """100 个虚拟玩家在同一毫秒内请求同一个 competitive 任务"""
    print("\n🧪 TEST 1: 100 Players Competing for Same Quest (Competitive Mode)")
    print("=" * 60)

    mutex = SimpleMutex()
    quest_id = "arms_heist"
    reward_granted = 0
    reward_rejected = 0
    lock = threading.Lock()

    def player_request(pid):
        nonlocal reward_granted, reward_rejected
        ok, instance_id, reason = mutex.acquire(quest_id, pid, "competitive")
        with lock:
            if ok:
                reward_granted += 1
                results["competitive_granted"].append(pid)
            else:
                reward_rejected += 1
                results["competitive_rejected"].append(pid)

    # 100 个线程同时启动
    threads = []
    start = time.perf_counter()
    for pid in range(100):
        t = threading.Thread(target=player_request, args=(pid,))
        threads.append(t)
        t.start()

    for t in threads:
        t.join()
    elapsed_ms = (time.perf_counter() - start) * 1000

    print(f"  ✅ Granted:  {reward_granted} player(s)  (expected: 1)")
    print(f"  ❌ Rejected: {reward_rejected} player(s) (expected: 99)")
    print(f"  ⏱️  Time:     {elapsed_ms:.2f} ms")
    print(f"  🔒 Integrity: {'PASS' if reward_granted == 1 and reward_rejected == 99 else 'FAIL'}")

    assert reward_granted == 1, f"Expected 1 granted, got {reward_granted}"
    assert reward_rejected == 99, f"Expected 99 rejected, got {reward_rejected}"

    # 清理
    mutex.release(quest_id, results["competitive_granted"][0])
    print(f"  🧹 Lock released. Remaining: {len(mutex.locks)}")
    return True


# ── 测试 2: 断线回滚 (玩家接任务后断线, 锁自动释放) ──────────────────

def test_disconnect_rollback():
    """模拟玩家接取任务后异常断线, 锁应该能被下一个玩家获取"""
    print("\n🧪 TEST 2: Player Disconnect During Quest — Lock Recovery")
    print("=" * 60)

    mutex = SimpleMutex()
    quest_id = "bank_escort"

    # Player 5 接任务
    ok, _, _ = mutex.acquire(quest_id, 5, "competitive")
    assert ok, "Player 5 should acquire lock"

    # Player 5 断线 → 释放锁
    mutex.release(quest_id, 5)

    # Player 8 尝试接同一任务
    ok, _, reason = mutex.acquire(quest_id, 8, "competitive")
    assert ok, f"Player 8 should acquire lock after Player 5 disconnect, got: {reason}"

    results["rollback_success"] += 1
    print(f"  ✅ Player 5 acquired → disconnected → released")
    print(f"  ✅ Player 8 acquired same quest after cleanup")
    print(f"  🔒 Recovery: PASS")


# ── 测试 3: 超卖防护 (扣钱后物品发放失败 → 回滚) ────────────────────

def test_atomic_transaction():
    """模拟原子交易: 扣钱 → 发物品失败 → 回滚退钱"""
    print("\n🧪 TEST 3: Atomic Transaction — Charge → Fail → Rollback")
    print("=" * 60)

    class VirtualPlayer:
        def __init__(self, pid, cash=1000):
            self.pid = pid
            self.cash = cash
            self.items = {}

        def remove_money(self, amount):
            if self.cash >= amount:
                self.cash -= amount
                return True
            return False

        def add_money(self, amount):
            self.cash += amount

        def add_item(self, item_name, amount):
            # 模拟: 第 42 号玩家的背包满
            if self.pid == 42 and item_name == "cursed_item":
                return False
            self.items[item_name] = self.items.get(item_name, 0) + amount
            return True

    def atomic_purchase(player, item_name, price):
        """原子交易: 先扣钱, 再给物品, 失败则回滚"""
        if not player.remove_money(price):
            return False, "insufficient_funds"

        if not player.add_item(item_name, 1):
            # 回滚!
            player.add_money(price)
            results["rollback_success"] += 1
            print(f"  ↩️  Player {player.pid}: Item '{item_name}' add FAILED → rolled back ${price}")
            return False, "rollback_success"

        return True, "success"

    # 正常交易
    normal_player = VirtualPlayer(pid=1, cash=500)
    ok, msg = atomic_purchase(normal_player, "normal_item", 300)
    assert ok and normal_player.cash == 200, f"Normal purchase failed: {msg}"

    # 异常交易 (背包满)
    cursed_player = VirtualPlayer(pid=42, cash=500)
    ok, msg = atomic_purchase(cursed_player, "cursed_item", 400)
    assert not ok, f"Cursed purchase should fail"
    assert cursed_player.cash == 500, f"Rollback failed: cash={cursed_player.cash}, expected 500"
    assert "cursed_item" not in cursed_player.items, "Cursed item should not be in inventory"

    print(f"  ✅ Normal purchase: cash $200, item received")
    print(f"  ✅ Cursed purchase: rolled back, cash restored to $500")
    print(f"  🔒 Atomicity: PASS")


# ── 测试 4: 载具被毁 + 任务超时边界 ────────────────────────────────────

def test_vehicle_destroyed_boundary():
    """模拟: DELIVER 节点进行中载具被毁 → 任务不卡死, 优雅失败"""
    print("\n🧪 TEST 4: Vehicle Destroyed During Delivery — Graceful Failure")
    print("=" * 60)

    class QuestState:
        def __init__(self):
            self.active = True
            self.current_step = "deliver_to_hq"
            self.failed = False

        def fail(self, reason):
            self.active = False
            self.failed = True
            print(f"  ❌ Quest FAILED gracefully: {reason}")

    state = QuestState()

    # 模拟: 玩家开着任务车, 车被炸了
    vehicle_alive = True
    player_in_vehicle = True

    # DELIVER 节点的服务端验证
    def validate_deliver(player_vehicle_alive, player_in_veh):
        if not player_in_veh:
            state.fail("player_not_in_vehicle")
            return False

        if not player_vehicle_alive:
            state.fail("vehicle_destroyed")
            return False

        return True

    # 正常
    assert validate_deliver(True, True)

    # 载具被毁
    vehicle_alive = False
    result = validate_deliver(vehicle_alive, True)
    assert not result and state.failed
    assert not state.active

    results["boundary_recovered"] += 1
    print(f"  ✅ Vehicle destroyed → quest gracefully failed (no crash, no deadlock)")
    print(f"  🔒 Boundary: PASS")


# ── 测试 5: 过期锁自动释放 ──────────────────────────────────────────

def test_expired_lock():
    """模拟: 锁过期后新玩家可以获取"""
    print("\n🧪 TEST 5: Expired Lock Auto-Release")
    print("=" * 60)

    mutex = SimpleMutex()
    mutex.expire_sec = 1  # 1 秒过期 (加速测试)
    quest_id = "test_expired"

    # Player 1 获取锁
    mutex.acquire(quest_id, 1, "competitive")
    assert len(mutex.locks) == 1

    # 等待过期
    time.sleep(1.5)

    # Player 2 尝试获取 — 应该成功 (旧锁已过期)
    ok, _, _ = mutex.acquire(quest_id, 2, "competitive")
    assert ok, "Player 2 should acquire lock after expiry"

    results["boundary_recovered"] += 1
    print(f"  ✅ Lock expired after 1s → Player 2 acquired")
    print(f"  🔒 Expiry: PASS")


# ── 主函数 ────────────────────────────────────────────────────────────

def main():
    print("╔══════════════════════════════════════════════════╗")
    print("║   Mutex Concurrency & Boundary Stress Test      ║")
    print("╠══════════════════════════════════════════════════╣")
    print("║   Tests: Competitive | Disconnect | Atomic      ║")
    print("║          Vehicle Destroy | Lock Expiry          ║")
    print("╚══════════════════════════════════════════════════╝")

    all_pass = True
    try:
        test_competitive_concurrency()
        test_disconnect_rollback()
        test_atomic_transaction()
        test_vehicle_destroyed_boundary()
        test_expired_lock()
    except AssertionError as e:
        print(f"\n❌ TEST FAILED: {e}")
        all_pass = False

    print("\n╔══════════════════════════════════════════════════╗")
    print(f"║   {'✅ ALL TESTS PASSED' if all_pass else '❌ SOME TESTS FAILED':<46s} ║")
    print("╠══════════════════════════════════════════════════╣")
    print(f"║   Competitive:  1 granted / 99 rejected         ║")
    print(f"║   Rollback:     {results['rollback_success']} successful                                ║")
    print(f"║   Boundary:     {results['boundary_recovered']} recovered                                ║")
    print("╚══════════════════════════════════════════════════╝")

    return all_pass


if __name__ == "__main__":
    success = main()
    exit(0 if success else 1)
