<script lang="ts">
  // 任务 App —— custom-quest 的 30 个任务模板第一次有了玩家入口。
  // 数据全部来自服务端（quests:list / quests:active），本组件不做任何准入判断。
  //
  // 列表只摆"现在能接的"（4615b03：菜单里点不了的菜不是内容）；服务端仍然返回全部行，
  // /listquests 与诊断保留完整画面。但"存在多少内容"必须可发现，所以头部保留一个计数：
  // 可操作性在列表里，可发现性在计数里，两件事分开。
  import { onMount } from 'svelte';
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

  let tab: 'available' | 'active' = $state('available');
  // 'stack'=单列（手机，行为与改造前一致）；'grid'=两栏（平板）
  let mode = $state<'stack' | 'grid'>('stack');
  // 平板上右栏看哪一条。手机不存在右栏，所以不影响手机的那一套。
  let selectedId = $state<string | null>(null);
  let rows: Row[] = $state([]);
  let active: ActiveRow[] = $state([]);
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

  async function refresh() {
    loading = true;
    error = '';
    const [list, running] = await Promise.all([
      queryApp('quests', 'list'),
      queryApp('quests', 'active'),
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

  function switchTab(next: 'available' | 'active') {
    if (tab === next) return;
    tab = next;
    // 上一页的选中项在这一页并不存在，留着只会让右栏显示一条左栏没有的任务
    selectedId = null;
  }

  onMount(refresh);
</script>

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
</style>
