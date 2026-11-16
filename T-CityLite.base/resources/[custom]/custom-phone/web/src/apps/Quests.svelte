<script lang="ts">
  // 任务 App —— custom-quest 的 30 个任务模板第一次有了玩家入口。
  // 数据全部来自服务端（quests:list / quests:active），本组件不做任何准入判断。
  //
  // 列表只摆"现在能接的"（4615b03：菜单里点不了的菜不是内容）；服务端仍然返回全部行，
  // /listquests 与诊断保留完整画面。但"存在多少内容"必须可发现，所以头部保留一个计数：
  // 可操作性在列表里，可发现性在计数里，两件事分开。
  import { onMount } from 'svelte';
  import { reportAppState } from '../utils/nui';
  import { queryApp, appAction } from '../stores/apps';
  import AppSurface from '../components/AppSurface.svelte';
  import Pane from '../components/Pane.svelte';
  import { PANE_CONTRACT as QUESTS_PANES } from './contracts/quests.panes';

  type Row = {
    id: string;
    title?: string;
    description?: string;
    category?: string;
    level?: number;
    available?: boolean;
    reason?: string;
    reason_text?: string;
    remaining_minutes?: number;
    /** 服务端算好的需求清单：每一条都带"满足没有"，UI 只负责显示 */
    requirements?: { kind?: string; text?: string; met?: boolean }[];
  };
  type ActiveRow = {
    quest_id: string;
    title?: string;
    status?: string;
    current_step?: string;
  };
  // GetQuestReceipts 的 DTO：金额文本由服务端生成，前端只加 $ 与正负号。
  type ReceiptRow = {
    id?: string;
    label?: string;
    amount?: number;
    amount_text?: string;
    kind?: string;
    counted?: boolean;
    muted?: boolean;
  };
  type ReceiptContext = {
    quest_title?: string;
    minutes?: number;
    sold_count?: number;
    leftover?: { common?: number; rare?: number; exotic?: number };
    raw_count?: number;
    billable?: boolean;
  };
  type Receipt = {
    questId?: string;
    quest_id?: string;
    issuedAt?: number;
    issued_at?: number;
    net?: number;
    net_text?: string;
    rows?: ReceiptRow[];
    context?: ReceiptContext;
    replayed?: boolean;
  };

  let tab: 'available' | 'active' | 'settled' = $state('available');
  // 'stack'=单列（手机，行为与改造前一致）；'grid'=两栏（平板）
  let mode = $state<'stack' | 'grid'>('stack');
  // 平板上右栏看哪一条。手机不存在右栏，所以不影响手机的那一套。
  let selectedId = $state<string | null>(null);
  let rows: Row[] = $state([]);
  let active: ActiveRow[] = $state([]);
  let receipts: Receipt[] = $state([]);
  let receiptsError = $state('');
  // 手机上展开的是 list 内联账单卡（detail pane 在手机上不渲染）。
  let expandedReceiptId = $state<string | null>(null);
  let loading = $state(false);
  let error = $state('');
  let feedback = $state('');
  let busyId: string | null = $state(null);

  // 只认明确可接的：进行中的任务没有 available 字段，宽松判断会把它当可接（右栏就长出"接取"按钮）。
  const canAccept = (row: Row) => row.available === true;
  // 不可接的整行不摆出来（4615b03），但需求仍逐条摊在可接的任务上（绿勾 = 你满足了）。
  const acceptable = $derived(rows.filter(canAccept));
  // 可发现性：告诉玩家"还有内容，只是条件没满足"，而不是让他面对一片空白。
  const blockedCount = $derived(rows.length - acceptable.length);

  // 服务端行的 id → 短标签；没有映射时回落到服务端给的 label（不自己造词）。
  const RECEIPT_ROW_LABELS: Record<string, string> = {
    deposit: '押金退还',
    rent: '租金',
    sold: '售出收入',
    leftover: '成品回收',
    raw: '原料回收',
    tax: '税',
  };

  function receiptQuestId(receipt: Receipt): string {
    return String(receipt.questId ?? receipt.quest_id ?? '');
  }

  function receiptIssuedAt(receipt: Receipt): number | null {
    const value = Number(receipt.issuedAt ?? receipt.issued_at);
    return Number.isFinite(value) && value > 0 ? value : null;
  }

  // reportAppState 的 selected 走 client/main.lua 的 stateToken：≤48 字符、
  // 只收 [A-Za-z0-9_-:]。quest_id:issued_at 正常都装得下，长的截断 quest_id。
  function receiptKey(receipt: Receipt): string {
    const issued = receiptIssuedAt(receipt);
    const suffix = issued === null ? '' : `:${issued}`;
    const room = Math.max(1, 48 - suffix.length);
    const id = receiptQuestId(receipt).replace(/[^A-Za-z0-9_-]/g, '_').slice(0, room);
    return `${id || 'receipt'}${suffix}`.slice(0, 48);
  }

  function receiptDateText(receipt: Receipt): string {
    const issued = receiptIssuedAt(receipt);
    if (issued === null) return '时间未知';
    return new Date(issued * 1000).toLocaleString('zh-CN', {
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
    });
  }

  function receiptTitle(receipt: Receipt): string {
    const title = receipt.context?.quest_title;
    if (typeof title === 'string' && title.trim()) return title;
    return receiptQuestId(receipt) || '任务账单';
  }

  // net_text / amount_text 是服务端 QuestMoney 生成好的文本（不带 $）；
  // 前端只补 $ 与正负号（U+2212），**绝不对 rows 求和**。
  function receiptNetText(receipt: Receipt): string {
    if (typeof receipt.net_text !== 'string' || receipt.net_text === '') return '—';
    const net = Number(receipt.net);
    return `${Number.isFinite(net) && net < 0 ? '−' : ''}$${receipt.net_text}`;
  }

  function receiptRowAmount(row: ReceiptRow): string {
    if (row.muted === true) return '—';
    const amount = Number(row.amount);
    if (Number.isFinite(amount) && amount === 0) return '—';
    if (typeof row.amount_text !== 'string' || row.amount_text === '') return '—';
    const negative = Number.isFinite(amount) ? amount < 0 : row.kind === 'out';
    return `${negative ? '−' : '+'}$${row.amount_text}`;
  }

  function receiptRowTone(row: ReceiptRow): 'plus' | 'minus' | 'mute' {
    if (row.muted === true) return 'mute';
    const amount = Number(row.amount);
    if (Number.isFinite(amount)) return amount < 0 ? 'minus' : 'plus';
    return row.kind === 'out' ? 'minus' : 'plus';
  }

  function receiptRowNote(row: ReceiptRow, receipt: Receipt): string {
    if (row.muted === true) return '未启用';
    if (row.counted === false) {
      const sold = Number(receipt.context?.sold_count);
      const count = row.id === 'sold' && Number.isFinite(sold) && sold > 0 ? ` · ${sold} 份` : '';
      return `已付现 · 不计入净额${count}`;
    }
    switch (row.id) {
      case 'deposit':
        return '租赁点已确认归还';
      case 'rent': {
        const minutes = Number(receipt.context?.minutes);
        return Number.isFinite(minutes) && minutes > 0 ? `${minutes} 分钟` : '按时长计费';
      }
      case 'leftover': {
        const leftover = receipt.context?.leftover;
        if (!leftover) return '';
        const parts: string[] = [];
        if (Number(leftover.common) > 0) parts.push(`● ${leftover.common}`);
        if (Number(leftover.rare) > 0) parts.push(`◆ ${leftover.rare}`);
        if (Number(leftover.exotic) > 0) parts.push(`★ ${leftover.exotic}`);
        return parts.length > 0 ? `剩 ${parts.join(' · ')}` : '没有剩余成品';
      }
      case 'raw': {
        const raw = Number(receipt.context?.raw_count);
        return Number.isFinite(raw) && raw > 0 ? `${raw} 份未做` : '原料用完了';
      }
      default:
        return '';
    }
  }

  function receiptSub(receipt: Receipt): string {
    const minutes = Number(receipt.context?.minutes);
    const duration = Number.isFinite(minutes) && minutes > 0 ? `${minutes} 分钟 · ` : '';
    return `${duration}${receipt.replayed === true ? '已结算（重复查看）' : '已结算'}`;
  }

  async function refresh() {
    loading = true;
    error = '';
    const [list, running, bills] = await Promise.all([
      queryApp('quests', 'list'),
      queryApp('quests', 'active'),
      queryApp('quests', 'receipts'),
    ]);
    if (list && list.success && list.data && Array.isArray(list.data.rows)) {
      rows = list.data.rows as Row[];
    } else {
      rows = [];
      error = (list && list.error) || 'load_failed';
    }
    if (running && running.success && running.data && Array.isArray(running.data.rows)) {
      active = running.data.rows as ActiveRow[];
    } else {
      active = [];
    }
    if (bills && bills.success && bills.data && Array.isArray(bills.data.rows)) {
      receipts = bills.data.rows as Receipt[];
      // 导出缺失时服务端仍是 success=true，错误码放在 data.error 里，必须显示出来。
      receiptsError = typeof bills.data.error === 'string' ? bills.data.error : '';
    } else {
      receipts = [];
      receiptsError = (bills && bills.error) || 'receipt_unavailable';
    }
    loading = false;
  }

  async function accept(id: string) {
    busyId = id;
    feedback = '';
    const res = await appAction('quests', 'accept', { quest_id: id });
    if (res && res.success) {
      feedback = '已接取，打开地图看目标';
      await refresh();
    } else {
      const detail = (res && (res.detail || res.error)) || 'unknown';
      feedback = `接取失败：${detail}`;
    }
    busyId = null;
  }

  async function abandon(id: string) {
    busyId = id;
    feedback = '';
    const res = await appAction('quests', 'abandon', { quest_id: id });
    feedback = res && res.success ? '已放弃' : `取消失败：${(res && (res.detail || res.error)) || 'unknown'}`;
    if (res && res.success) await refresh();
    busyId = null;
  }

  // 右栏只看当前 tab 的集合：切到「进行中」时不能还挂着上一个可接任务（左下右上是两个世界）。
  const selectedAvailable = $derived(
    acceptable.find((row) => row.id === selectedId) ?? acceptable[0] ?? null,
  );
  const selectedActive = $derived(
    active.find((row) => row.quest_id === selectedId) ?? active[0] ?? null,
  );
  // 平板右栏默认看最新一张（服务端已按新的在前排序）；手机上不用它渲染。
  const selectedReceipt = $derived(
    receipts.find((receipt) => receiptKey(receipt) === selectedId) ?? receipts[0] ?? null,
  );
  const receiptsErrorText = $derived(
    receiptsError === 'receipt_unavailable'
      ? '账单暂时不可用（receipt_unavailable）'
      : receiptsError
        ? `账单加载失败：${receiptsError}`
        : '',
  );

  function switchTab(next: 'available' | 'active' | 'settled') {
    if (tab === next) return;
    tab = next;
    // 上一页的选中项在这一页并不存在，留着只会让右栏显示一条左栏没有的任务
    selectedId = null;
    expandedReceiptId = null;
  }

  function selectReceipt(receipt: Receipt) {
    const key = receiptKey(receipt);
    selectedId = key;
    // 手机：点同一行收起，点另一行换一张；平板：右栏跟着选中的账单走。
    if (mode !== 'grid') {
      expandedReceiptId = expandedReceiptId === key ? null : key;
    }
  }

  onMount(refresh);

  // 停在哪一页也告诉 Lua：agent 只能问"手机开着吗"，问不到"他在看哪一栏"。
  $effect(() => {
    reportAppState('quests', tab, selectedId);
  });
</script>

{#snippet receiptCard(receipt: Receipt)}
  <div class="bill-card">
    <div class="bill-head">
      <strong>{receiptTitle(receipt)}</strong>
      <span class="chip">{receipt.replayed === true ? '已结算（重复查看）' : '已结算'}</span>
    </div>
    <p class="bill-sub">{receiptSub(receipt)}</p>
    <ul class="bill-rows">
      {#each receipt.rows ?? [] as row, index (`${row.id ?? row.label ?? 'row'}#${index}`)}
        {@const tone = receiptRowTone(row)}
        {@const note = receiptRowNote(row, receipt)}
        <li class="bill-row" class:muted={row.muted === true} data-row-id={row.id}>
          <span class="bill-label">
            <span class="bill-name">{RECEIPT_ROW_LABELS[row.id ?? ''] ?? row.label ?? row.id ?? '—'}</span>
            {#if note}<small class:muted={row.muted === true}>{note}</small>{/if}
          </span>
          <span class="bill-amount" class:plus={tone === 'plus'} class:minus={tone === 'minus'}>
            {receiptRowAmount(row)}
          </span>
        </li>
      {/each}
    </ul>
    <div class="bill-sep"></div>
    <div class="bill-net-row">
      <span class="bill-net-key">本班净额</span>
      <span class="bill-net">{receiptNetText(receipt)}</span>
    </div>
  </div>
{/snippet}

<div class="quests-app app-transition">
  <header class="quests-head">
    <span class="quests-icon">📜</span>
    <div>
      <h2>任务</h2>
      <p class="quests-sub">
        {acceptable.length} 条可接{blockedCount > 0 ? ` · ${blockedCount} 条条件未满足` : ''} ·
        {active.length} 条进行中
      </p>
    </div>
    <button class="refresh-btn" onclick={refresh} disabled={loading}>刷新</button>
  </header>

  <div class="tabs">
    <button class:active={tab === 'available'} onclick={() => switchTab('available')}>可接</button>
    <button class:active={tab === 'active'} onclick={() => switchTab('active')}>进行中</button>
    <button class:active={tab === 'settled'} onclick={() => switchTab('settled')}>已结算</button>
  </div>

  {#if error}
    <p class="err">{error}</p>
  {/if}
  {#if feedback}
    <p class="feedback">{feedback}</p>
  {/if}

  <AppSurface spec={QUESTS_PANES} activePane="list" bind:mode>
    <Pane id="list">
        {#if loading}
          <p class="empty">加载中…</p>
        {:else if tab === 'available'}
          {#if acceptable.length === 0}
            <p class="empty">现在没有能接的任务 —— 换个身份、换个时间段再来看看</p>
          {:else}
            <ul class="list">
              {#each acceptable as row (row.id)}
                <li class:sel={selectedAvailable?.id === row.id}
            class:compact={mode === 'grid'}
            onclick={() => (selectedId = row.id)}>
                  <div class="row-head">
                    <strong>{row.title ?? row.id}</strong>
                    <span class="chip">{row.category ?? 'misc'} · L{row.level ?? 1}</span>
                  </div>
                  {#if row.description}<p class="desc">{row.description}</p>{/if}
                  {#if row.requirements && row.requirements.length > 0}
                    <ul class="reqs">
                      {#each row.requirements as req}
                        <li class="req" class:unmet={req.met === false}>
                          {req.met === false ? '✗' : '✓'} {req.text ?? req.kind}
                        </li>
                      {/each}
                    </ul>
                  {/if}
                  <button class="primary" onclick={() => accept(row.id)} disabled={busyId === row.id}>
                    {busyId === row.id ? '接取中…' : '接取'}
                  </button>
                </li>
              {/each}
            </ul>
          {/if}
        {:else if tab === 'settled'}
          {#if receiptsErrorText}
            <p class="err">{receiptsErrorText}</p>
          {:else if receipts.length === 0}
            <p class="empty">还没有已结算的班次</p>
            <p class="empty-sub">收摊结算后，这里会留下一张本班账单。</p>
          {:else}
            <ul class="list receipts-list">
              {#each receipts as receipt, index (`${receiptKey(receipt)}#${index}`)}
                {@const key = receiptKey(receipt)}
                <li data-receipt-id={key}
                    class:sel={selectedReceipt !== null && receiptKey(selectedReceipt) === key}
                    onclick={() => selectReceipt(receipt)}>
                  <div class="row-head">
                    <strong>{receiptTitle(receipt)}</strong>
                    <span class="chip">{receipt.replayed === true ? '已结算（重复查看）' : '已结算'}</span>
                  </div>
                  <div class="receipt-line">
                    <span class="receipt-date">{receiptDateText(receipt)}</span>
                    <span class="receipt-net">{receiptNetText(receipt)}</span>
                  </div>
                  <!-- 手机（stack）：账单卡在 list 内联展开；平板（grid）走右栏 -->
                  {#if mode !== 'grid' && expandedReceiptId === key}
                    {@render receiptCard(receipt)}
                  {/if}
                </li>
              {/each}
            </ul>
          {/if}
          {#if !receiptsErrorText}
            <p class="receipts-note">账单在本次服务器运行期间可回看</p>
          {/if}
        {:else if active.length === 0}
          <p class="empty">没有进行中的任务</p>
        {:else}
          <ul class="list">
            {#each active as row (row.quest_id)}
              <li class:sel={selectedActive?.quest_id === row.quest_id}
                  onclick={() => (selectedId = row.quest_id)}>
                <div class="row-head">
                  <strong>{row.title ?? row.quest_id}</strong>
                  <span class="chip">{row.status ?? 'active'}</span>
                </div>
                {#if row.current_step}<p class="desc">当前步骤：{row.current_step}</p>{/if}
                <button class="ghost" onclick={() => abandon(row.quest_id)} disabled={busyId === row.quest_id}>
                  {busyId === row.quest_id ? '处理中…' : '放弃'}
                </button>
              </li>
            {/each}
          </ul>
        {/if}
    </Pane>

    <Pane id="quest">
      <!-- 只在平板（grid）渲染：手机上这一栏不存在，DOM 里也不该留一份重复的需求列表 -->
      {#if mode === 'grid' && tab === 'available' && selectedAvailable}
        <div class="quest-detail">
          <div class="row-head">
            <strong>{selectedAvailable.title ?? selectedAvailable.id}</strong>
            <span class="chip">{selectedAvailable.category ?? 'misc'} · L{selectedAvailable.level ?? 1}</span>
          </div>
          {#if selectedAvailable.description}<p class="desc">{selectedAvailable.description}</p>{/if}
          {#if selectedAvailable.requirements && selectedAvailable.requirements.length > 0}
            <ul class="reqs">
              {#each selectedAvailable.requirements as req}
                <li class="req" class:unmet={req.met === false}>
                  {req.met === false ? '✗' : '✓'} {req.text ?? req.kind}
                </li>
              {/each}
            </ul>
          {/if}
          <button class="primary" onclick={() => accept(selectedAvailable.id)}
                  disabled={busyId === selectedAvailable.id}>
            {busyId === selectedAvailable.id ? '接取中…' : '接取'}
          </button>
        </div>
      {:else if mode === 'grid' && tab === 'active' && selectedActive}
        <div class="quest-detail">
          <div class="row-head">
            <strong>{selectedActive.title ?? selectedActive.quest_id}</strong>
            <span class="chip">{selectedActive.status ?? 'active'}</span>
          </div>
          {#if selectedActive.current_step}
            <p class="desc">当前步骤：{selectedActive.current_step}</p>
          {/if}
          <button class="ghost" onclick={() => abandon(selectedActive.quest_id)}
                  disabled={busyId === selectedActive.quest_id}>
            {busyId === selectedActive.quest_id ? '处理中…' : '放弃'}
          </button>
        </div>
      {:else if mode === 'grid' && tab === 'settled' && selectedReceipt}
        <div class="quest-detail receipt-detail">
          {@render receiptCard(selectedReceipt)}
        </div>
      {:else if mode === 'grid'}
        <p class="empty">左边选一个任务看详情</p>
      {/if}
    </Pane>
  </AppSurface>
</div>

<style>
  .quests-app { display: flex; flex-direction: column; overflow: hidden; }
  .quests-app :global(.app-surface) { padding: 0; }
  .quest-detail { padding: 12px 4px; }
  .list li.sel { outline: 1px solid rgba(59,130,246,.6); }
  /* 平板：列表收窄成"标题 + 状态"，详情在右栏，避免同一段文字渲染两遍 */
  .list li.compact .desc, .list li.compact .reqs, .list li.compact .reason { display: none; }
  /* 「接取」不隐藏：平板上一击能做的事，不该因为多了一栏就变成三击 */
  .quests-app { padding: 16px; color: #e8edf5; height: 100%; overflow-y: auto; }
  .quests-head { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; }
  .quests-icon { font-size: 26px; }
  .quests-head h2 { font-size: 16px; margin: 0; }
  .quests-sub { margin: 2px 0 0; font-size: 11px; opacity: 0.65; }
  .refresh-btn { margin-left: auto; font-size: 11px; padding: 6px 10px; border-radius: 8px; border: 1px solid rgba(255,255,255,.2); background: rgba(255,255,255,.08); color: inherit; }
  .tabs { display: flex; gap: 6px; margin: 8px 0 12px; }
  .tabs button { flex: 1; font-size: 12px; padding: 7px 0; border-radius: 9px; border: 1px solid rgba(255,255,255,.16); background: rgba(255,255,255,.04); color: inherit; }
  .tabs button.active { background: rgba(37,99,235,.35); border-color: rgba(37,99,235,.6); }
  .list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
  .list li { background: rgba(255,255,255,.06); border-radius: 12px; padding: 10px 12px; }
  .list li.blocked { opacity: 0.72; }
  .row-head { display: flex; align-items: center; gap: 8px; }
  .row-head strong { font-size: 13px; }
  .chip { margin-left: auto; font-size: 10px; padding: 2px 7px; border-radius: 999px; background: rgba(255,255,255,.12); }
  .desc { font-size: 11px; opacity: 0.75; margin: 6px 0 8px; line-height: 1.45; }
  .reason { font-size: 11px; color: #fbbf24; margin: 6px 0 0; }
  .reqs { list-style: none; margin: 6px 0 8px; padding: 0; display: flex; flex-wrap: wrap; gap: 4px 6px; }
  .req { font-size: 10px; padding: 2px 7px; border-radius: 6px; background: rgba(34,197,94,.14); color: #86efac; }
  .req.unmet { background: rgba(239,68,68,.16); color: #fca5a5; }
  .primary { border: 0; border-radius: 9px; padding: 7px 14px; background: #2563eb; color: #fff; font-size: 12px; }
  .primary:disabled { opacity: 0.55; }
  .ghost { border: 1px solid rgba(255,255,255,.2); border-radius: 9px; padding: 6px 12px; background: transparent; color: inherit; font-size: 12px; }
  .empty, .err { font-size: 12px; opacity: 0.7; }
  .err { color: #fca5a5; }
  .feedback { font-size: 11px; opacity: 0.85; margin: 6px 0 0; }

  /* ── 已结算账单（原型 P1）───────────────────────────────── */
  /* 字体先走系统回退：账单卡不复制 hotdog_ui.ttf，CEF 缺字形时退到雅黑。 */
  .receipts-list, .bill-card {
    font-family: "Inter", "Outfit", "Noto Sans SC", "Microsoft YaHei", system-ui, sans-serif;
  }
  .receipts-list li { cursor: pointer; }
  .receipt-line { display: flex; align-items: baseline; gap: 8px; margin-top: 4px; }
  .receipt-date { font-size: 11px; opacity: 0.6; }
  .receipt-net { margin-left: auto; font-size: 13px; font-weight: 600; font-variant-numeric: tabular-nums; }
  .receipts-note, .empty-sub { font-size: 11px; opacity: 0.55; line-height: 1.5; margin: 10px 0 0; }
  .empty-sub { margin-top: 4px; }
  .receipt-detail { padding: 12px 4px; }
  .bill-card {
    margin-top: 10px; padding: 12px; border-radius: 12px;
    background: linear-gradient(180deg, #121217, #0c0b0f 42%);
    border: 1px solid rgba(255, 255, 255, 0.08);
  }
  .receipt-detail .bill-card { margin-top: 0; }
  .bill-head { display: flex; align-items: center; gap: 8px; }
  .bill-head strong { font-size: 13px; }
  .bill-sub { font-size: 11px; opacity: 0.6; margin: 3px 0 8px; }
  .bill-rows { list-style: none; margin: 0; padding: 0; }
  .bill-row { display: flex; align-items: baseline; gap: 8px; padding: 6px 0; }
  .bill-label { display: flex; flex-direction: column; min-width: 0; }
  .bill-name { font-size: 12.5px; }
  .bill-label small { font-size: 10.5px; color: #a1a1aa; margin-top: 1px; }
  .bill-row.muted .bill-name,
  .bill-row.muted .bill-label small { color: #6b6b76; }
  .bill-amount { margin-left: auto; font-size: 13px; font-weight: 500; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .bill-amount.plus { color: #d7f5df; }
  .bill-amount.minus { color: #ffd9d9; }
  .bill-row.muted .bill-amount { color: #6b6b76; font-weight: 400; }
  .bill-sep { height: 1px; background: rgba(255, 255, 255, 0.08); margin: 8px 0; }
  .bill-net-row { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; }
  .bill-net-key { font-size: 11.5px; opacity: 0.65; }
  .bill-net { font-size: 20px; font-weight: 700; font-variant-numeric: tabular-nums; letter-spacing: 0.2px; }
</style>
