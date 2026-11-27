<script lang="ts">
  // 产业 App —— custom-industry 的手机入口（S5 只读 + W1 卖出/雇工位）。
  //
  // 权限只有一个来源：服务端快照里的 isBoss。普通成员只读；Boss 才渲染按钮。
  // 但这只是展示：所有写动作仍由 custom-industry 复验成员身份 + Boss
  // （NUI 隐藏 ≠ 权限）。
  //
  // 钱只认服务端：卖出走 snapshot_estimate（只读）→ 确认 → sell；
  // 前端不乘单价、不猜收益，也不给服务端传价格/金额/工位号。
  import { onMount } from 'svelte';
  import { queryApp, appAction } from '../stores/apps';

  type Phase = {
    key: string;
    label: string;
    cycleNo: number;
    endsAt: number;
    productionMultiplier: number;
    priceMultiplier: number;
    quotaMultiplier: number;
    purchasable: boolean;
  };
  type Facility = {
    built: boolean;
    type: string;
    label: string;
    level: number;
    maxLevel: number;
    workstations: number;
    workstationCap: number;
    stock: number;
    stockCap: number;
    nextWorkstationCost: number | null;
    hireBlocked: string | null;
  };
  type Demand = {
    item: string;
    unitPrice: number;
    globalTotal: number;
    globalUsed: number;
    globalRemaining: number;
    orgCap: number;
    orgUsed: number;
    orgRemaining: number;
  };
  type Sellable = { maxQty: number; blocked: string | null };
  type Snapshot = {
    orgId: string;
    orgLabel: string;
    gradeName: string;
    isBoss: boolean;
    balance: number;
    producedUnits: number;
    phase?: Phase;
    facility?: Facility;
    demand?: Demand;
    sellable?: Sellable;
  };
  type SnapshotData = {
    rows: Record<string, unknown>[];
    count: number;
    snapshot?: Snapshot;
    error?: string;
  };
  type Estimate = {
    ok: boolean;
    qty: number;
    unitPrice: number;
    revenue: number;
    blocked: string | null;
    maxQty: number;
    error?: string;
  };
  type EstimateData = { ok: boolean; estimate?: Estimate; error?: string };
  type SellResult = { qty?: number; revenue?: number };
  type HireResult = { cost?: number; workstations?: number };

  // 与服务端错误码一一对应；未知码原样显示，不折叠成「失败」。
  const BLOCK_TEXT: Record<string, string> = {
    stock: '库存不足',
    org_cap: '本组织配额已用完',
    demand: '全服配额已用完',
    none: '当前不可卖出',
    cap: '工位已满',
    cap_reached: '工位已满',
    funds: '金库余额不足',
    insufficient_funds: '金库余额不足',
    phase: '当前阶段不可购置',
    purchases_closed: '当前阶段不可购置',
    not_built: '尚未建设施',
    not_boss: '只有 Boss 能操作',
    not_member: '不是该组织成员',
    conflict: '工位状态已变化，请重试',
    bad_org: '组织无效',
    bad_qty: '数量无效',
    stock_empty: '库存不足',
    org_cap_reached: '本组织配额已用完',
    demand_exhausted: '全服配额已用完',
    unavailable: '产业服务不可用',
    disabled: '产业未开放',
    db_error: '服务端读取失败',
    bad_request: '请求无效',
    timeout: '请求超时',
    no_response: '服务端未响应',
    resource_stopped: '资源已停止',
    action_failed: '服务端处理异常',
    action_rejected: '操作被拒绝',
  };

  let snapshot = $state<Snapshot | null>(null);
  let loading = $state(false);
  let error = $state('');
  let feedback = $state('');

  let sellQty = $state(1);
  let estimate = $state<Estimate | null>(null);
  let estimateFor = $state<number | null>(null);
  let estimating = $state(false);
  let selling = $state(false);
  let hiring = $state(false);

  const facility = $derived(snapshot?.facility ?? null);
  const demand = $derived(snapshot?.demand ?? null);
  const phase = $derived(snapshot?.phase ?? null);
  const isBoss = $derived(snapshot?.isBoss === true);
  const maxQty = $derived(Math.max(0, snapshot?.sellable?.maxQty ?? 0));
  const sellBlocked = $derived(snapshot?.sellable?.blocked ?? null);
  const hireBlocked = $derived(facility?.hireBlocked ?? null);
  const canConfirm = $derived(
    estimate !== null && estimate.ok === true && estimateFor === sellQty && !selling,
  );

  function blockText(code: string | null | undefined): string {
    if (!code) return '';
    return BLOCK_TEXT[code] ?? code;
  }

  // 只做千分位展示；金额本身全部来自服务端。
  function money(value: number | null | undefined): string {
    const amount = Number(value);
    return Number.isFinite(amount) ? `$${amount.toLocaleString('zh-CN')}` : '—';
  }

  function resetEstimate() {
    estimate = null;
    estimateFor = null;
  }

  async function load() {
    loading = true;
    error = '';
    const res = await queryApp('industry', 'snapshot');
    const data = res.data as SnapshotData | undefined;
    if (res.success && data?.snapshot) {
      const next = data.snapshot;
      snapshot = next;
      const nextMax = Math.max(0, next.sellable?.maxQty ?? 0);
      if (nextMax > 0 && sellQty > nextMax) sellQty = Math.max(1, nextMax);
      resetEstimate();
    } else {
      snapshot = null;
      error = res.error || data?.error || 'load_failed';
    }
    loading = false;
  }

  function onQtyInput(event: Event) {
    const value = Number((event.currentTarget as HTMLInputElement).value);
    sellQty = Number.isFinite(value) ? Math.max(1, Math.floor(value)) : 1;
    // 数量变了，旧报价作废，避免拿 A 的报价确认 B。
    resetEstimate();
  }

  async function requestEstimate() {
    if (!isBoss || !snapshot) return;
    estimating = true;
    feedback = '';
    resetEstimate();
    const qty = Math.max(1, Math.floor(sellQty));
    const res = await queryApp('industry', 'snapshot_estimate', {
      orgId: snapshot.orgId,
      qty,
    });
    const data = res.data as EstimateData | undefined;
    if (res.success && data?.estimate) {
      estimate = data.estimate;
      estimateFor = qty;
    } else {
      feedback = `估价失败：${blockText(res.error || data?.error)}`;
    }
    estimating = false;
  }

  async function confirmSale() {
    if (!canConfirm || !estimate || !snapshot) return;
    selling = true;
    feedback = '';
    const res = await appAction('industry', 'sell', {
      orgId: snapshot.orgId,
      qty: estimate.qty,
    });
    if (res.success) {
      const sold = res.data as SellResult;
      feedback = `已卖出 ${sold.qty ?? estimate.qty} 件，入账 ${money(sold.revenue)}`;
      resetEstimate();
      await load();
    } else {
      feedback = `卖出失败：${blockText(res.error)}`;
    }
    selling = false;
  }

  async function hire() {
    if (!isBoss || !snapshot || hiring || hireBlocked) return;
    hiring = true;
    feedback = '';
    const res = await appAction('industry', 'hire', { orgId: snapshot.orgId });
    if (res.success) {
      const hired = res.data as HireResult;
      feedback = `已雇工位 #${hired.workstations ?? '?'}，花费 ${money(hired.cost)}`;
      await load();
    } else {
      feedback = `雇工位失败：${blockText(res.error)}`;
    }
    hiring = false;
  }

  onMount(load);
</script>

<div class="industry-app app-transition">
  <header class="industry-head">
    <span class="industry-icon">⛏️</span>
    <div>
      <h2>{snapshot?.orgLabel ?? '产业'}</h2>
      <p class="industry-sub">
        {#if snapshot}
          {snapshot.gradeName || '成员'} · {snapshot.isBoss ? 'Boss' : '成员'}
          {#if phase} · 周期 {phase.cycleNo} · {phase.label}{/if}
        {:else}
          产业快照
        {/if}
      </p>
    </div>
    <button class="refresh-btn" onclick={load} disabled={loading}>刷新</button>
  </header>

  {#if loading && !snapshot}
    <p class="empty">加载中…</p>
  {:else if error}
    <p class="err">加载失败：{blockText(error)}</p>
  {:else if !snapshot}
    <p class="empty">暂时没有产业信息</p>
  {:else}
    <section class="card identity">
      <div class="kv"><span>组织</span><b>{snapshot.orgLabel}</b></div>
      <div class="kv"><span>职级</span><b>{snapshot.gradeName || '—'}</b></div>
      <div class="kv"><span>金库余额</span><b>{money(snapshot.balance)}</b></div>
      {#if phase}
        <div class="kv">
          <span>阶段</span>
          <b>{phase.label} · 生产 ×{phase.productionMultiplier} · 售价 ×{phase.priceMultiplier}</b>
        </div>
      {/if}
    </section>

    {#if !facility}
      <p class="empty">尚未建设施 —— 先在 Boss 菜单里建厂</p>
    {:else}
      <section class="card">
        <h3>{facility.label} L{facility.level}/{facility.maxLevel}</h3>
        <div class="kv"><span>工位</span><b>{facility.workstations} / {facility.workstationCap}</b></div>
        <div class="kv"><span>库存</span><b>{facility.stock} / {facility.stockCap}</b></div>
        <div class="kv"><span>累计产出</span><b>{snapshot.producedUnits}</b></div>
        {#if demand}
          <div class="kv"><span>单位售价</span><b>{money(demand.unitPrice)}</b></div>
          <div class="kv"><span>全服配额</span><b>剩 {demand.globalRemaining} / {demand.globalTotal}</b></div>
          <div class="kv"><span>本组织配额</span><b>剩 {demand.orgRemaining} / {demand.orgCap}</b></div>
        {/if}
      </section>

      {#if !isBoss}
        <p class="note">只有 Boss 可以卖出或雇工位。你可以查看当前库存与配额。</p>
      {:else}
        <section class="card action-card">
          <h3>卖出</h3>
          {#if maxQty <= 0}
            <p class="note">现在不可卖出：{blockText(sellBlocked) || '库存或配额不足'}</p>
          {:else}
            <div class="sell-row">
              <label for="industry-qty">数量</label>
              <input
                id="industry-qty"
                type="number"
                min="1"
                max={maxQty}
                value={sellQty}
                oninput={onQtyInput}
              />
              <span class="hint">最多 {maxQty} 件</span>
              <button class="estimate-btn" onclick={requestEstimate} disabled={estimating || selling}>
                {estimating ? '估价中…' : '估价'}
              </button>
            </div>
            {#if estimate}
              <div class="estimate">
                {#if estimate.ok}
                  <div class="kv">
                    <span>报价</span>
                    <b>{estimate.qty} 件 × {money(estimate.unitPrice)}</b>
                  </div>
                  <div class="kv">
                    <span>预计入账</span>
                    <b class="revenue">{money(estimate.revenue)}</b>
                  </div>
                  {#if estimate.blocked}
                    <p class="note">注意：{blockText(estimate.blocked)}，实际只能卖 {estimate.qty} 件</p>
                  {/if}
                  <button class="primary" onclick={confirmSale} disabled={!canConfirm}>
                    {selling ? '卖出中…' : '确认卖出'}
                  </button>
                {:else}
                  <p class="err">不可卖出：{blockText(estimate.blocked || estimate.error)}</p>
                {/if}
              </div>
            {/if}
          {/if}
        </section>

        <section class="card action-card">
          <h3>雇工位</h3>
          <div class="kv">
            <span>下一个工位</span>
            <b>{facility.nextWorkstationCost == null ? '—' : money(facility.nextWorkstationCost)}</b>
          </div>
          {#if hireBlocked}
            <p class="note">暂不可雇：{blockText(hireBlocked)}</p>
          {:else}
            <button class="primary hire-btn" onclick={hire} disabled={hiring}>
              {hiring ? '办理中…' : '雇工位'}
            </button>
          {/if}
        </section>
      {/if}
    {/if}
  {/if}

  {#if feedback}<p class="feedback">{feedback}</p>{/if}
</div>

<style>
  .industry-app { padding: 16px; color: #e8edf5; height: 100%; overflow-y: auto; box-sizing: border-box; }
  .industry-head { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; }
  .industry-icon { font-size: 26px; }
  .industry-head h2 { font-size: 16px; margin: 0; }
  .industry-sub { margin: 2px 0 0; font-size: 11px; opacity: 0.65; }
  .refresh-btn { margin-left: auto; font-size: 11px; padding: 6px 10px; border-radius: 8px; border: 1px solid rgba(255, 255, 255, 0.2); background: rgba(255, 255, 255, 0.08); color: inherit; }
  .card { background: rgba(255, 255, 255, 0.06); border-radius: 12px; padding: 10px 12px; margin-bottom: 10px; }
  .card h3 { font-size: 13px; margin: 0 0 8px; }
  .kv { display: flex; align-items: baseline; gap: 10px; padding: 3px 0; font-size: 12px; }
  .kv span { opacity: 0.6; }
  .kv b { margin-left: auto; font-weight: 600; text-align: right; }
  .revenue { color: #86efac; }
  .note { font-size: 11px; color: #fbbf24; margin: 6px 0 0; line-height: 1.45; }
  .sell-row { display: flex; align-items: center; gap: 8px; }
  .sell-row label { font-size: 12px; opacity: 0.75; }
  .sell-row input { width: 72px; border-radius: 8px; border: 1px solid rgba(255, 255, 255, 0.18); background: rgba(0, 0, 0, 0.25); color: inherit; padding: 7px 8px; font-size: 12px; }
  .hint { font-size: 11px; opacity: 0.55; }
  .estimate { margin-top: 8px; padding-top: 8px; border-top: 1px solid rgba(255, 255, 255, 0.08); }
  .primary { border: 0; border-radius: 9px; padding: 7px 14px; background: #2563eb; color: #fff; font-size: 12px; }
  .primary:disabled { opacity: 0.55; }
  .estimate-btn { margin-left: auto; border: 1px solid rgba(255, 255, 255, 0.2); border-radius: 9px; padding: 6px 12px; background: transparent; color: inherit; font-size: 12px; }
  .estimate .primary, .hire-btn { margin-top: 8px; }
  .empty, .err { font-size: 12px; opacity: 0.7; }
  .err { color: #fca5a5; }
  .feedback { font-size: 11px; opacity: 0.85; margin: 6px 0 0; }
</style>
