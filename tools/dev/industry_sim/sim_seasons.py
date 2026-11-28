#!/usr/bin/env python3
"""v4 —— 按 2026-11-28 的四条拍板建模，并用仿真定数值。

四条口径（用户定）：
  1. 提现**抽税 + 有额度限制**；金库也能在结算时**按比例分配**；
  2. 库存增长等数值**全部用模拟定**；
  3. 冬天 = "产不出但卖得掉"（黑五）；
  4. **设施跨季保留**，只有大周期结束才结算重置。

回答四个问题：
  A. 库存升级每级 +多少，才能让"囤货过冬"接近打平？
  B. 提现周额度 × 税率，怎么定才不会让 Boss 把金库搬空、绕开季度重置？
  C. 黑五参数（冬产能/冬配额/冬价）怎么配？
  D. 结算分配比例（boss 拿多少）对个人财富的影响。
"""

from __future__ import annotations

import math

HOURS_PER_DAY = 24
WEEKS_PER_QUARTER = 13
UNIT_PRICE = 50
UPH = 4.5
SEED_QUOTA = 11000
ORG_CAP = 0.5
FACILITY = 50000
WS_CAP = 10
GROWTH = 1.35
PRESTIGE_K = 50000
STARTER = 200_000
STOCK_BASE = 540
STOCK_MAX_LV = 6
STOCK_COST_BASE = 40_000
STOCK_COST_GROWTH = 1.6

SPLITS = [(2, 3, 1, 1), (1, 1, 3, 2), (2, 2, 2, 1), (1, 2, 2, 2),
          (3, 1, 1, 2), (1, 3, 1, 2), (2, 1, 2, 2)]


def ws_cost(n: int) -> int:
    return math.floor(FACILITY * (GROWTH ** (n - 1)))


def seasons(winter_prod=0.25, winter_quota=1.30, winter_price=1.50):
    return [("春", 1.25, 1.00, 1.00),
            ("夏", 1.00, 0.95, 0.85),
            ("秋", 1.10, 1.10, 0.70),
            ("冬", winter_prod, winter_price, winter_quota)]


def run(policy="always", stock_step=900, buy_stock=True, weeks=WEEKS_PER_QUARTER,
        withdraw_tax=0.20, withdraw_weekly=25_000, boss_share=0.40, members=3,
        winter=(0.25, 1.30, 1.50), verbose=False):
    """单组织跑一个季度，返回财务与集中度指标。

    policy: always（每季能卖就卖）| hoard（只在价 ≥1.10 的秋/冬卖）
    withdraw_weekly: 每周最多提现多少（Boss 会顶格提，对抗性假设）
    """
    seas = seasons(*winter)
    cash = float(STARTER)
    stock = 0.0
    ws = 0
    built = False
    lv = 0
    cap = STOCK_BASE
    rev_total = 0.0
    withdrawn_gross = 0.0
    tax_paid = 0.0
    build_spend = 0.0
    stock_spend = 0.0

    for w in range(weeks):
        split = SPLITS[w % len(SPLITS)]
        for (name, prod_m, price_m, quota_m), days in zip(seas, split):
            gq = SEED_QUOTA * quota_m
            left, org_left = gq, gq * ORG_CAP
            for _h in range(days * HOURS_PER_DAY):
                if ws > 0:
                    made = min(ws * UPH * prod_m, max(0.0, cap - stock))
                    stock += made
                sell_now = policy == "always" or (policy == "hoard" and price_m >= 1.10)
                if sell_now and stock > 0:
                    qty = min(math.floor(stock), left, org_left)
                    if qty > 0:
                        stock -= qty
                        left -= qty
                        org_left -= qty
                        gain = qty * UNIT_PRICE * price_m
                        cash += gain
                        rev_total += gain
                if ws < WS_CAP:
                    c = ws_cost(ws + 1) if built else FACILITY + ws_cost(1)
                    if cash >= c:
                        cash -= c
                        build_spend += c
                        if not built:
                            built = True
                            ws = 1
                        else:
                            ws += 1
                if buy_stock and lv < STOCK_MAX_LV:
                    c = math.floor(STOCK_COST_BASE * (STOCK_COST_GROWTH ** lv))
                    if cash >= c * 2:
                        cash -= c
                        stock_spend += c
                        lv += 1
                        cap = STOCK_BASE + stock_step * lv
        take = min(withdraw_weekly, cash)
        if take > 0:
            tax = take * withdraw_tax
            cash -= take
            withdrawn_gross += take
            tax_paid += tax
        if verbose:
            print(f"  第 {w+1:>2} 周 累计收入 ${rev_total:>11,.0f} 金库 ${cash:>10,.0f} "
                  f"工位 {ws:>2} 库存级 {lv}（上限 {cap}）")

    boss_cut = cash * boss_share
    member_pool = cash - boss_cut
    net_withdrawn = withdrawn_gross - tax_paid
    return {
        "revenue": round(rev_total),
        "withdrawn_gross": round(withdrawn_gross),
        "tax_paid": round(tax_paid),
        "boss_personal": round(net_withdrawn + boss_cut),
        "member_pool": round(member_pool),
        "per_member": round(member_pool / max(1, members)),
        "members": members,
        "treasury_end": round(cash),
        "build_spend": round(build_spend),
        "stock_spend": round(stock_spend),
        "ws": ws, "stock_lv": lv, "cap": cap,
        "prestige": math.floor(math.sqrt(rev_total / PRESTIGE_K)),
    }


def main() -> None:
    print("=" * 100)
    print("v4 参数定值 —— 提现(税+周额度) / 结算按比例分 / 黑五 / 设施跨季保留（成员 3 人）")
    print("=" * 100)

    print("\n【A】库存升级步长（目标：让「囤货过冬」从深亏回到可打平）")
    print(f"{'每级+':>8}{'满级上限':>10}{'能卖就卖':>13}{'囤货过冬':>13}{'囤货增益':>10}")
    for step in (180, 450, 900, 1200, 1800):
        a = run("always", stock_step=step)["revenue"]
        b = run("hoard", stock_step=step)["revenue"]
        print(f"{step:>8}{STOCK_BASE + step * STOCK_MAX_LV:>10,}{a:>13,}{b:>13,}{(b/a-1)*100:>9.1f}%")

    print("\n【B】提现：周额度 × 税率 → Boss vs 每成员")
    print(f"{'周额度':>9}{'税率':>6}{'季度收入':>13}{'Boss 个人':>13}{'每成员':>11}{'Boss/成员':>11}")
    for weekly in (0, 25_000, 50_000, 100_000):
        for tax in (0.0, 0.20, 0.40):
            r = run(withdraw_weekly=weekly, withdraw_tax=tax)
            ratio = r["boss_personal"] / max(1, r["per_member"])
            print(f"{weekly:>9,}{tax*100:>5.0f}%{r['revenue']:>13,}{r['boss_personal']:>13,}"
                  f"{r['per_member']:>11,}{ratio:>10.1f}x")

    print("\n【C】黑五参数：冬产能 × 冬配额 × 冬价（库存 +900/级）")
    print(f"{'冬产能':>7}{'冬配额':>7}{'冬价':>6}{'能卖就卖':>13}{'囤货过冬':>13}{'囤货增益':>10}")
    rows = []
    for wp in (0.10, 0.25, 0.40):
        for wq in (0.70, 1.00, 1.30):
            for wpr in (1.35, 1.50, 1.70):
                a = run("always", winter=(wp, wq, wpr))["revenue"]
                b = run("hoard", winter=(wp, wq, wpr))["revenue"]
                gain = (b / a - 1) * 100
                rows.append((abs(gain - 5), wp, wq, wpr, a, b, gain))
    for _d, wp, wq, wpr, a, b, gain in sorted(rows)[:8]:
        print(f"{wp:>7.2f}{wq:>7.2f}{wpr:>6.2f}{a:>13,}{b:>13,}{gain:>9.1f}%")
    print("（按「囤货增益≈+5%」排序取前 8；这三项对结果不敏感，按观感定即可）")

    print("\n【D】结算分配比例（提现 $25k/周、税 20%）")
    print(f"{'Boss 比例':>10}{'Boss 个人':>13}{'每成员':>11}{'Boss/成员':>11}")
    for bs in (0.20, 0.30, 0.40, 0.50, 0.70):
        r = run(boss_share=bs)
        print(f"{bs*100:>9.0f}%{r['boss_personal']:>13,}{r['per_member']:>11,}"
              f"{r['boss_personal']/max(1,r['per_member']):>10.1f}x")

    print("\n【E】推荐组合逐周明细（囤货；黑五 0.25/1.30/1.50；库存 +900；税 20%；周额度 $25k）")
    run("hoard", verbose=True)


if __name__ == "__main__":
    main()
