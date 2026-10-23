#!/usr/bin/env python3
# =============================================================================
# Economic Sandbox Simulator — 时空加速经济沙盒模拟器 v1.0
# =============================================================================
# 用途:
#   模拟 100 名虚拟玩家在 10000 次循环中的经济行为，
#   快进透视全服开服一个月后的长线经济健康度。
#
# 玩法:
#   python sandbox_simulator.py              → 默认参数运行
#   python sandbox_simulator.py --cycles 50000 --players 200  → 自定义参数
#   python sandbox_simulator.py --baseline economy_baseline.json  → 指定基准表
#
# 输出:
#   - 终端实时进度条 + 最终经济体检报告
#   - simulation_report.json (完整数据)
# =============================================================================

import json
import random
import math
import sys
import os
from dataclasses import dataclass, field
from typing import Dict, List, Tuple

# ── 配置 ────────────────────────────────────────────────────────────────
DEFAULT_CYCLES = 10000          # 模拟循环数 (~1 个月, 每循环 ≈ 4.3 分钟)
DEFAULT_PLAYERS = 100           # 虚拟玩家数
EARN_CYCLE_INTERVAL = 6         # 每个玩家每 N 个循环有一次收入事件
SINK_CYCLE_INTERVAL = 72        # 消耗口触发间隔 (房产税/保险等)
REPORT_INTERVAL = 1000          # 每 N 次循环输出一次里程碑

# ── 玩家画像 ───────────────────────────────────────────────────────────

PLAYER_PROFILES = {
    "civilian_grinder": {
        "weight": 45,           # 45% 的玩家是平民刷子
        "hourly_income_range": (800, 2000),
        "sink_multiplier": 0.8,  # 消费倾向偏低
        "save_rate": 0.3,        # 存 30%
        "vehicle_buy_interval": 200,  # 每 200 循环可能买车
        "house_buy_interval": 500,
        "illegal_ratio": 0.0,   # 不碰非法
    },
    "skilled_worker": {
        "weight": 25,
        "hourly_income_range": (1800, 3500),
        "sink_multiplier": 1.0,
        "save_rate": 0.25,
        "vehicle_buy_interval": 150,
        "house_buy_interval": 350,
        "illegal_ratio": 0.05,
    },
    "high_roller": {
        "weight": 10,
        "hourly_income_range": (3000, 8000),
        "sink_multiplier": 2.5,  # 高消费
        "save_rate": 0.1,
        "vehicle_buy_interval": 80,
        "house_buy_interval": 200,
        "illegal_ratio": 0.15,
    },
    "criminal": {
        "weight": 15,
        "hourly_income_range": (2000, 12000),  # 高风险高波动
        "sink_multiplier": 1.5,
        "save_rate": 0.15,
        "vehicle_buy_interval": 100,
        "house_buy_interval": 300,
        "illegal_ratio": 0.8,
    },
    "passive_investor": {
        "weight": 5,
        "hourly_income_range": (100, 500),
        "sink_multiplier": 0.3,
        "save_rate": 0.8,        # 高储蓄率，极少消费
        "vehicle_buy_interval": 500,
        "house_buy_interval": 1000,
        "illegal_ratio": 0.0,
    },
}

# ── 活动定义 ──────────────────────────────────────────────────────────

ACTIVITIES = [
    {"id": "mining",         "base_per_hour": 1500, "heat_sensitive": True},
    {"id": "fishing",        "base_per_hour": 1200, "heat_sensitive": True},
    {"id": "taxi_mission",   "base_per_hour": 1400, "heat_sensitive": True},
    {"id": "truck_delivery", "base_per_hour": 1600, "heat_sensitive": True},
    {"id": "store_robbery",  "base_per_hour": 5000, "heat_sensitive": True, "illegal": True},
    {"id": "bank_heist",     "base_per_hour": 8000, "heat_sensitive": True, "illegal": True},
    {"id": "drug_sale",      "base_per_hour": 6000, "heat_sensitive": True, "illegal": True},
    {"id": "mechanic_repair","base_per_hour": 2500, "heat_sensitive": False},
    {"id": "ems_rescue",     "base_per_hour": 2200, "heat_sensitive": False},
    {"id": "police_patrol",  "base_per_hour": 2000, "heat_sensitive": False},  # salary, not reward-gated
]

# ── 消耗口定义 ─────────────────────────────────────────────────────────

SINKS = [
    {"id": "vehicle_purchase_tax",  "rate": 0.08, "trigger_per_player_cycle": 200},
    {"id": "vehicle_insurance",     "base": 500,  "rate": 0.001, "interval": 200},
    {"id": "vehicle_overhaul",      "base": 1500, "rate": 0.002, "interval": 350},
    {"id": "housing_tax",           "rate": 0.005, "interval": 300},
    {"id": "atm_fee",               "rate": 0.02, "trigger_freq": 0.3},
    {"id": "transaction_tax",       "rate": 0.05, "threshold": 100000},
    {"id": "weapon_repair",         "base": 500,  "trigger_freq": 0.15},
]

# ── 虚拟玩家 ────────────────────────────────────────────────────────────

@dataclass
class VirtualPlayer:
    pid: int
    profile: dict
    cash: float = 500.0
    bank: float = 5000.0
    vehicles: int = 0
    houses: int = 0
    total_earned: float = 0.0
    total_spent: float = 0.0
    total_taxed: float = 0.0
    cycle_born: int = 0

    @property
    def total_money(self):
        return self.cash + self.bank

    def earn(self, amount: float):
        self.cash += amount
        self.total_earned += amount

    def spend(self, amount: float, is_tax: bool = False):
        if self.bank >= amount:
            self.bank -= amount
        elif self.cash >= amount:
            self.cash -= amount
        else:
            self.cash = 0
            self.bank = 0
        self.total_spent += amount
        if is_tax:
            self.total_taxed += amount

    def deposit_to_bank(self, ratio: float):
        move = self.cash * ratio
        self.cash -= move
        self.bank += move


# ── 模拟引擎 ────────────────────────────────────────────────────────────

class EconomySimulator:
    def __init__(self, num_players: int = DEFAULT_PLAYERS, num_cycles: int = DEFAULT_CYCLES):
        self.num_players = num_players
        self.num_cycles = num_cycles
        self.players: List[VirtualPlayer] = []
        self.heat_tracker: Dict[str, List[int]] = {}  # activity_id → [recent_completions]
        self.sink_tracker: Dict[str, float] = {}      # sink_id → total collected
        self.cycle_log: List[dict] = []

        # 全局经济乘数 (模拟自适应调节)
        self.global_multiplier = 1.0
        self.total_money_supply_history: List[float] = []

    def spawn_players(self):
        """根据权重分配玩家画像"""
        profiles = []
        for name, prof in PLAYER_PROFILES.items():
            count = int(self.num_players * prof["weight"] / 100)
            for _ in range(count):
                profiles.append((name, prof))

        # 补齐剩余
        while len(profiles) < self.num_players:
            profiles.append(("civilian_grinder", PLAYER_PROFILES["civilian_grinder"]))

        random.shuffle(profiles)
        for i, (name, prof) in enumerate(profiles):
            self.players.append(VirtualPlayer(pid=i, profile=prof, cycle_born=0))

        # 初始资金: 每人 $500 cash + $5000 bank
        print(f"  🎮 {len(self.players)} players spawned ({len(set(p.pid for p in self.players))} unique)")

    def simulate_earnings(self, cycle: int):
        """模拟收入事件"""
        for player in self.players:
            if cycle % EARN_CYCLE_INTERVAL != player.pid % EARN_CYCLE_INTERVAL:
                continue

            prof = player.profile
            # 选择活动
            if random.random() < prof["illegal_ratio"]:
                pool = [a for a in ACTIVITIES if a.get("illegal")]
            else:
                pool = [a for a in ACTIVITIES if not a.get("illegal")]

            if not pool:
                continue

            activity = random.choice(pool)
            base_per_hour = activity["base_per_hour"]

            # 热度系数
            heat_coeff = 1.0
            if activity["heat_sensitive"]:
                recent = self.heat_tracker.get(activity["id"], [])
                if recent:
                    avg = sum(recent[-20:]) / min(len(recent), 20)
                    # 高频 → 降系数 (0.5~1.5)
                    heat_coeff = max(0.5, min(1.5, 1.0 - (avg - 5) * 0.05))

            # 随机波动 ±30%
            rand_factor = random.uniform(0.7, 1.3)

            # 最终收益 (每循环 ≈ 4.3 分钟, 所以 / 14 ≈ 小时换算)
            cycle_hours = EARN_CYCLE_INTERVAL / 14.0
            earned = base_per_hour * cycle_hours * self.global_multiplier * heat_coeff * rand_factor
            earned = max(1, math.floor(earned))

            player.earn(earned)

            # 热度追踪
            if activity["id"] not in self.heat_tracker:
                self.heat_tracker[activity["id"]] = []
            self.heat_tracker[activity["id"]].append(1)

    def simulate_sinks(self, cycle: int):
        """模拟消耗口 (v2: 修正触发频率, 对齐真实经济参数)"""
        for player in self.players:
            prof = player.profile
            pid = player.pid

            # 车辆保险: 每 200 循环触发, 按玩家 ID 分散
            if player.vehicles > 0 and cycle % 200 == pid % 200:
                vehicle_value = random.randint(5000, 150000)
                insurance = 500 + int(vehicle_value * 0.001)
                player.spend(insurance * prof["sink_multiplier"], is_tax=True)
                self.sink_tracker["vehicle_insurance"] = self.sink_tracker.get("vehicle_insurance", 0) + insurance

            # 房产税: 每 300 循环, 按玩家 ID 分散
            if player.houses > 0 and cycle % 300 == pid % 300:
                house_value = random.randint(25000, 500000)
                tax = int(house_value * 0.005)  # 0.5% per cycle
                player.spend(tax * prof["sink_multiplier"], is_tax=True)
                self.sink_tracker["housing_tax"] = self.sink_tracker.get("housing_tax", 0) + tax

            # 引擎大修: 每 350 循环
            if player.vehicles > 1 and cycle % 350 == pid % 350:
                ov_value = random.randint(5000, 150000)
                overhaul = 1500 + int(ov_value * 0.002)
                player.spend(overhaul * prof["sink_multiplier"], is_tax=True)
                self.sink_tracker["vehicle_overhaul"] = self.sink_tracker.get("vehicle_overhaul", 0) + overhaul

            # ATM 手续费: 低频
            if random.random() < 0.05:
                fee = int(player.cash * 0.02 * 0.1)
                if fee > 0:
                    player.spend(fee, is_tax=True)
                    self.sink_tracker["atm_fee"] = self.sink_tracker.get("atm_fee", 0) + fee

            # 武器维修: 低频
            if random.random() < 0.05:
                cost = int(500 * prof["sink_multiplier"])
                player.spend(cost, is_tax=True)
                self.sink_tracker["weapon_repair"] = self.sink_tracker.get("weapon_repair", 0) + cost

    def simulate_purchases(self, cycle: int):
        """模拟消费行为"""
        for player in self.players:
            prof = player.profile

            # 买车
            if random.random() < 1.0 / prof["vehicle_buy_interval"]:
                price = random.randint(5000, 100000)
                if player.bank >= price * 0.3:  # 30% 首付
                    player.spend(price * 0.3)
                    player.vehicles += 1
                    # 8% 购置税
                    tax = int(price * 0.08)
                    player.spend(tax, is_tax=True)
                    self.sink_tracker["vehicle_purchase_tax"] = self.sink_tracker.get("vehicle_purchase_tax", 0) + tax

            # 买房
            if random.random() < 1.0 / prof["house_buy_interval"]:
                price = random.randint(25000, 500000)
                if player.bank >= price * 0.2:  # 20% 首付
                    player.spend(price * 0.2)
                    player.houses += 1

            # 存款
            if player.cash > 1000:
                player.deposit_to_bank(prof["save_rate"])

    def adapt_global_multiplier(self, cycle: int):
        """模拟自适应经济调节"""
        if cycle % 500 != 0:
            return

        total_money = sum(p.total_money for p in self.players)
        self.total_money_supply_history.append(total_money)

        if len(self.total_money_supply_history) >= 3:
            recent = self.total_money_supply_history[-3:]
            growth_rate = (recent[-1] - recent[0]) / max(recent[0], 1)

            if growth_rate > 0.15:  # 通胀 > 15% → 降
                self.global_multiplier = max(0.5, self.global_multiplier - 0.05)
            elif growth_rate < 0.02:  # 几乎不增长 → 升
                self.global_multiplier = min(2.0, self.global_multiplier + 0.05)

    def run(self) -> dict:
        print("\n╔══════════════════════════════════════════════════╗")
        print("║   Economic Sandbox Simulator v1.0               ║")
        print("╠══════════════════════════════════════════════════╣")
        print(f"║   Players: {self.num_players:<4}   Cycles: {self.num_cycles:<6}              ║")
        print("╚══════════════════════════════════════════════════╝\n")

        print("  🎮 Spawning players...")
        self.spawn_players()

        initial_money = sum(p.total_money for p in self.players)

        for cycle in range(1, self.num_cycles + 1):
            self.simulate_earnings(cycle)
            self.simulate_sinks(cycle)
            self.simulate_purchases(cycle)
            self.adapt_global_multiplier(cycle)

            # 里程碑报告
            if cycle % REPORT_INTERVAL == 0:
                total_money = sum(p.total_money for p in self.players)
                total_taxed = sum(p.total_taxed for p in self.players)
                avg_money = total_money / self.num_players
                pct = cycle / self.num_cycles * 100
                print(f"  [{pct:5.1f}%] Cycle {cycle:>6} | Total: ${total_money:>12,.0f} | "
                      f"Avg: ${avg_money:>8,.0f} | Taxed: ${total_taxed:>10,.0f} | Mult: {self.global_multiplier:.2f}")

        # ── 最终报告 ──────────────────────────────────────────────────
        final_money = sum(p.total_money for p in self.players)
        final_taxed = sum(p.total_taxed for p in self.players)
        final_earned = sum(p.total_earned for p in self.players)
        final_spent = sum(p.total_spent for p in self.players)

        # 基尼系数 (简化)
        moneys = sorted([p.total_money for p in self.players])
        n = len(moneys)
        gini = sum((2 * i - n - 1) * m for i, m in enumerate(moneys, 1)) / (n * sum(moneys)) if sum(moneys) > 0 else 0

        # 热度排行
        heat_ranking = sorted(self.heat_tracker.items(), key=lambda x: sum(x[1]), reverse=True)

        report = {
            "parameters": {
                "players": self.num_players,
                "cycles": self.num_cycles,
                "simulated_days": round(self.num_cycles * 4.3 / 60 / 24, 1),
            },
            "summary": {
                "initial_total_money": initial_money,
                "final_total_money": final_money,
                "money_growth": final_money - initial_money,
                "money_growth_pct": round((final_money - initial_money) / max(initial_money, 1) * 100, 1),
                "avg_money_per_player": round(final_money / self.num_players),
                "total_earned": final_earned,
                "total_spent": final_spent,
                "total_taxed": final_taxed,
                "sink_ratio": round(final_taxed / max(final_earned, 1) * 100, 1),
                "final_global_multiplier": round(self.global_multiplier, 2),
                "gini_coefficient": round(gini, 3),
                "verdict": "",
            },
            "wealth_distribution": {
                "top_5_pct_avg": round(sum(p.total_money for p in sorted(self.players, key=lambda x: x.total_money, reverse=True)[:5]) / 5),
                "bottom_20_pct_avg": round(sum(p.total_money for p in sorted(self.players, key=lambda x: x.total_money)[:20]) / 20),
                "median": round(sorted(moneys)[len(moneys)//2]),
            },
            "heat_ranking": [
                {"activity": aid, "total_completions": sum(counts)}
                for aid, counts in heat_ranking[:10]
            ],
            "sink_distribution": {
                sid: round(total) for sid, total in
                sorted(self.sink_tracker.items(), key=lambda x: x[1], reverse=True)
            },
        }

        # 判决
        growth_pct = report["summary"]["money_growth_pct"]
        sink_ratio = report["summary"]["sink_ratio"]
        gini_val = report["summary"]["gini_coefficient"]

        if sink_ratio < 5:
            verdict = "🔴 DANGER: Sink ratio too low (<5%). Server WILL inflate. Increase taxes or add more sinks."
        elif sink_ratio < 15:
            verdict = "🟡 WARNING: Sink ratio moderate (5-15%). Monitor closely after launch."
        elif sink_ratio < 30:
            verdict = "🟢 HEALTHY: Sink ratio 15-30%. Well-balanced economy."
        else:
            verdict = "🟡 DEFLATIONARY: Sink ratio >30%. Players may feel punished. Consider easing taxes."

        if gini_val > 0.6:
            verdict += " ⚠️ Gini >0.6: Wealth inequality is extreme. Add progressive taxation."
        if growth_pct > 500:
            verdict += " ⚠️ Money supply grew >500% — severe inflation risk."

        report["summary"]["verdict"] = verdict

        # ── 终端输出 ──────────────────────────────────────────────────
        print(f"\n╔══════════════════════════════════════════════════╗")
        print(f"║   📊 FINAL ECONOMIC HEALTH REPORT               ║")
        print(f"╠══════════════════════════════════════════════════╣")
        print(f"║   Simulated: {report['parameters']['simulated_days']:.1f} days ({self.num_cycles} cycles)         ║")
        print(f"║   Initial money:  ${initial_money:>12,.0f}                ║")
        print(f"║   Final money:    ${final_money:>12,.0f}  (+{growth_pct:.0f}%)         ║")
        print(f"║   Avg/player:     ${report['summary']['avg_money_per_player']:>12,}                  ║")
        print(f"║   Total taxed:    ${final_taxed:>12,.0f}  ({sink_ratio:.0f}%)            ║")
        print(f"║   Gini:           {gini_val:.3f}                            ║")
        print(f"║   Final mult:     {self.global_multiplier:.2f}                            ║")
        print(f"╠══════════════════════════════════════════════════╣")
        print(f"║   {verdict[:46]:<46s} ║")
        print(f"╚══════════════════════════════════════════════════╝")

        # 热度排行
        print(f"\n  🔥 Top 5 Hottest Activities:")
        for i, (aid, counts) in enumerate(heat_ranking[:5]):
            print(f"     {i+1}. {aid:<20s}  {sum(counts):>6} completions")

        # Sink 分布
        print(f"\n  💰 Sink Distribution:")
        for sid, total in sorted(self.sink_tracker.items(), key=lambda x: x[1], reverse=True):
            print(f"     {sid:<25s}  ${total:>10,.0f}")

        return report


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Economic Sandbox Simulator")
    parser.add_argument("--cycles", type=int, default=DEFAULT_CYCLES)
    parser.add_argument("--players", type=int, default=DEFAULT_PLAYERS)
    parser.add_argument("--output", type=str, default="simulation_report.json")
    args = parser.parse_args()

    sim = EconomySimulator(num_players=args.players, num_cycles=args.cycles)
    report = sim.run()

    # 持久化
    with open(args.output, "w") as f:
        json.dump(report, f, indent=2)
    print(f"\n  💾 Full report saved to: {args.output}")


if __name__ == "__main__":
    main()
