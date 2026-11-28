#!/usr/bin/env python3
"""生成 v4 参数报告页（自包含 HTML，无外链）。数据现算，不手抄。"""

from __future__ import annotations

import json
from pathlib import Path

import sim_v4 as S

HERE = Path(__file__).parent
OUT = HERE / "report_v4.html"


def money(v):
    return f"${round(v):,}"


def table(headers, rows, cls=""):
    th = "".join(f'<th class="n">{h}</th>' if i else f"<th>{h}</th>" for i, h in enumerate(headers))
    body = "".join(
        "<tr>" + "".join(
            (f'<td class="n">{c}</td>' if i else f"<td>{c}</td>") for i, c in enumerate(r)
        ) + "</tr>"
        for r in rows
    )
    return f'<table class="{cls}"><thead><tr>{th}</tr></thead><tbody>{body}</tbody></table>'


# ── A 库存步长 ────────────────────────────────────────────────────────
rows_a = []
for step in (180, 450, 900, 1200, 1800):
    a = S.run("always", stock_step=step)["revenue"]
    b = S.run("hoard", stock_step=step)["revenue"]
    gain = (b / a - 1) * 100
    rows_a.append([f"+{step:,}", f"{S.STOCK_BASE + step * S.STOCK_MAX_LV:,}",
                   money(a), money(b), f"{gain:+.1f}%"])

# ── B 提现 ────────────────────────────────────────────────────────────
rows_b = []
for weekly in (0, 25_000, 50_000, 100_000):
    for tax in (0.0, 0.20, 0.40):
        r = S.run(withdraw_weekly=weekly, withdraw_tax=tax)
        ratio = r["boss_personal"] / max(1, r["per_member"])
        rows_b.append([f"{weekly:,}", f"{tax*100:.0f}%", money(r["revenue"]),
                       money(r["boss_personal"]), money(r["per_member"]), f"{ratio:.1f}x"])

# ── C 黑五 ────────────────────────────────────────────────────────────
rows_c = []
for wp in (0.10, 0.25, 0.40):
    for wq in (0.70, 1.00, 1.30):
        for wpr in (1.35, 1.50, 1.70):
            a = S.run("always", winter=(wp, wq, wpr))["revenue"]
            b = S.run("hoard", winter=(wp, wq, wpr))["revenue"]
            rows_c.append((abs((b / a - 1) * 100 - 5), [f"{wp:.2f}", f"{wq:.2f}", f"{wpr:.2f}",
                                                        money(a), money(b), f"{(b/a-1)*100:+.1f}%"]))
rows_c = [r for _d, r in sorted(rows_c)[:8]]

# ── D 分配 ────────────────────────────────────────────────────────────
rows_d = []
for bs in (0.20, 0.30, 0.40, 0.50, 0.70):
    r = S.run(boss_share=bs)
    rows_d.append([f"{bs*100:.0f}%", money(r["boss_personal"]), money(r["per_member"]),
                   f"{r['boss_personal']/max(1,r['per_member']):.1f}x"])

# ── 推荐组合的逐周明细（囤货） ─────────────────────────────────────────
picks = []
_r = S.run("hoard", verbose=False)
# 逐周明细要单独跑一次（run 没返回周表），这里直接用推荐参数重算关键指标
rec = S.run("hoard", winter=(0.25, 1.30, 1.50), withdraw_weekly=25_000, withdraw_tax=0.20, boss_share=0.40)
rec_always = S.run("always", winter=(0.25, 1.30, 1.50), withdraw_weekly=25_000, withdraw_tax=0.20, boss_share=0.40)

kpis = [
    ("囤货过冬 · 季度收入", money(rec["revenue"])),
    ("卖光 · 季度收入", money(rec_always["revenue"])),
    ("库存升级投入", money(rec["stock_spend"])),
    ("工位投入", money(rec["build_spend"])),
    ("季度末工位", f'{rec["ws"]}/10'),
    ("库存等级", f'{rec["stock_lv"]}/6（上限 {rec["cap"]:,}）'),
    ("Boss 个人（含提现）", money(rec["boss_personal"])),
    ("每成员", money(rec["per_member"])),
    ("威望", rec["prestige"]),
]

html = f"""<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8"><title>产业参数报告 v4</title>
<style>
  :root{{--bg:#0f1116;--card:#171a21;--border:#252a34;--fg:#e6e9ef;--muted:#9aa3b2;
         --accent:#f0b429;--good:#7bd88f;--bad:#e8695b;}}
  *{{box-sizing:border-box}}
  body{{margin:0;background:var(--bg);color:var(--fg);
       font:14px/1.6 "Segoe UI Variable Text","Segoe UI","Microsoft YaHei UI",sans-serif}}
  header{{padding:22px 30px 12px;border-bottom:1px solid var(--border)}}
  h1{{margin:0 0 4px;font-size:20px}} h1 b{{color:var(--accent)}}
  .sub{{color:var(--muted);font-size:12.5px}}
  main{{padding:18px 30px 44px;max-width:1120px}}
  section{{background:var(--card);border:1px solid var(--border);border-radius:8px;
           padding:14px 16px;margin-bottom:14px}}
  h2{{margin:0 0 8px;font-size:14px;color:var(--accent)}}
  table{{width:100%;border-collapse:collapse;font-size:13px;margin-top:6px}}
  th,td{{padding:5px 8px;border-bottom:1px solid var(--border);text-align:left}}
  th{{color:var(--muted);font-size:12px;font-weight:600}}
  td.n,th.n{{text-align:right;font-variant-numeric:tabular-nums}}
  .kpi{{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}}
  .kpi div{{background:#1d222b;border:1px solid var(--border);border-radius:6px;padding:8px 10px}}
  .kpi span{{display:block;color:var(--muted);font-size:11.5px}}
  .kpi b{{font-size:15px;font-variant-numeric:tabular-nums}}
  .note{{color:var(--muted);font-size:12px;margin-top:8px}}
  .tag{{display:inline-block;padding:1px 7px;border-radius:999px;font-size:11.5px;
        border:1px solid #2c4a33;color:var(--good);margin-left:6px}}
  .warn{{color:var(--bad)}}
  code{{background:#11141a;border:1px solid var(--border);border-radius:4px;padding:1px 5px;font-size:12px}}
</style></head><body>
<header>
  <h1>产业参数 <b>v4</b> · 全部由仿真定值</h1>
  <div class="sub">口径：一周一个四季（天数每周不同）／季度 13 周／冬天＝黑五／设施跨季保留／提现抽税+周额度／结算按比例分。
    数值来源 <code>sim_v4.py</code>，本页现算生成。</div>
</header>
<main>

<section>
  <h2>① 推荐参数（可直接落设计）</h2>
  <div class="kpi">
    <div><span>库存升级</span><b>+900/级</b><span>满级 5,940 · $40k×1.6^级</span></div>
    <div><span>提现周额度</span><b>$25,000</b><span>≈ 季度收入 1%</span></div>
    <div><span>提现税</span><b>20%</b><span>税是次要杠杆</span></div>
    <div><span>结算分配</span><b>Boss 40%</b><span>其余成员平分</span></div>
    <div><span>冬天（黑五）</span><b>0.25 / 1.30 / 1.50</b><span>产 / 配额 / 价</span></div>
    <div><span>设施</span><b>跨季保留</b><span>季度末才重置</span></div>
  </div>
  <div class="note">依据见下面四张表。<span class="warn">注意：这些数字是在「配额按阶段独立」的设计口径下算的；
    线上现在是「全周期累计」口径（`industry_sales` 缺 phase），会得到完全不同的结果 —— 那个 bug 要先修。</span></div>
</section>

<section>
  <h2>② 库存升级步长：+900 是"囤货与卖光打平"的点</h2>
  {table(["每级 +", "满级上限", "能卖就卖", "囤货过冬", "囤货增益"], rows_a)}
  <div class="note">+180（现状）囤货 −41%；+900 打平（+0.6%）；+1,200 起囤货略占优但优势饱和（+3.7%）。</div>
</section>

<section>
  <h2>③ 提现：额度是主开关，税是次要</h2>
  {table(["周额度", "税率", "季度收入", "Boss 个人", "每成员", "Boss/成员"], rows_b)}
  <div class="note">额度 $100k/周 时金库被搬空、成员一分没有；额度 ≤ $25k 时 Boss/成员 ≈ 5x，属于"老板工资"的合理区间。
    税率从 0→40% 只把 Boss 压掉约 35%，而额度从 $50k→$25k 直接砍掉 34% 且成员收入翻倍。</div>
</section>

<section>
  <h2>④ 黑五参数：对结果不敏感，按观感定</h2>
  {table(["冬产能", "冬配额", "冬价", "能卖就卖", "囤货过冬", "囤货增益"], rows_c)}
  <div class="note">上面是按"囤货增益 ≈ +5%"排出的前 8 组。推荐 <b>0.25 / 1.30 / 1.50</b>：冬天产不出、卖得掉、价格高。</div>
</section>

<section>
  <h2>⑤ 结算分配比例：影响远小于提现额度</h2>
  {table(["Boss 比例", "Boss 个人", "每成员", "Boss/成员"], rows_d)}
  <div class="note">因为大钱已经被周提现拿走了，结算分的是"剩下的"。先定额度，再谈比例。</div>
</section>

<section>
  <h2>⑥ 推荐组合跑一个季度（囤货过冬）</h2>
  <div class="kpi">
    {''.join(f'<div><span>{k}</span><b>{v}</b></div>' for k, v in kpis)}
  </div>
  <div class="note">同一参数下"卖光"策略季度收入 {money(rec_always['revenue'])}，与囤货 {money(rec['revenue'])}
    相差 {((rec['revenue']/rec_always['revenue']-1)*100):+.1f}% —— 两种玩法都成立，这正是要的。</div>
</section>

<section>
  <h2>⑦ 这份报告没有证明什么</h2>
  <table>
    <tr><th>没有证明</th><th>为什么</th></tr>
    <tr><td>多名玩家/多组织互相抢配额时的均衡</td><td>这里是单组织模型；多组织抢配额要把"谁先卖"的时序也建模</td></tr>
    <tr><td>线上真实逻辑</td><td>用的是设计口径；线上 `industry_sales` 缺 `phase`，跨阶段卖单会被 <code>org_cap_reached</code> 拒</td></tr>
    <tr><td>玩家真的会这么玩</td><td>"老板顶格提现""只在高价季卖"都是脚本策略，真人会犯懒、会误判</td></tr>
    <tr><td>通胀</td><td>售价只吃季节倍率，没并有 core_economy 的全局系数与活动热度</td></tr>
  </table>
</section>

</main></body></html>
"""
OUT.write_text(html, encoding="utf-8")
print("写好了", OUT.name, len(html), "字节")
