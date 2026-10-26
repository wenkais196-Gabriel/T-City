<script lang="ts">
  // 任务 App —— custom-quest 的 30 个任务模板第一次有了玩家入口。
  // 数据全部来自服务端（quests:list / quests:active），本组件不做任何准入判断：
  // 不可接的任务也照样显示，只是把 reason_text 摆出来（"缺警力""冷却中"），
  // 让玩家知道内容存在、以及差在哪，而不是面对一片空白。
  import { onMount } from 'svelte';
  import { queryApp, appAction } from '../stores/apps';

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
  let rows: Row[] = $state([]);
  let active: ActiveRow[] = $state([]);
  let loading = $state(false);
  let error = $state('');
  let feedback = $state('');
  let busyId: string | null = $state(null);

  const canAccept = (row: Row) => row.available !== false;
  // 不可接的任务不再摆出来：玩家要的是"我现在能做什么"，不是一张吃不到菜单。
  // 需求仍然逐条显示在可接的任务上（绿勾 = 这条线要身份/执照/警力，你满足了）。
  const acceptable = $derived(rows.filter(canAccept));

  function reasonText(row: Row): string {
    if (row.available !== false) return '';
    if (row.reason === 'cooldown' && row.remaining_minutes) return `冷却中 · 还需 ${row.remaining_minutes} 分钟`;
    return row.reason_text || '当前不可接';
  }

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

  onMount(refresh);
</script>

<div class="quests-app app-transition">
  <header class="quests-head">
    <span class="quests-icon">📜</span>
    <div>
      <h2>任务</h2>
      <p class="quests-sub">{acceptable.length} 条可接 · {active.length} 条进行中</p>
    </div>
    <button class="refresh-btn" onclick={refresh} disabled={loading}>刷新</button>
  </header>

  <div class="tabs">
    <button class:active={tab === 'available'} onclick={() => (tab = 'available')}>可接</button>
    <button class:active={tab === 'active'} onclick={() => (tab = 'active')}>进行中</button>
  </div>

  {#if error}
    <p class="err">{error}</p>
  {/if}
  {#if feedback}
    <p class="feedback">{feedback}</p>
  {/if}

  {#if loading}
    <p class="empty">加载中…</p>
  {:else if tab === 'available'}
    {#if acceptable.length === 0}
      <p class="empty">现在没有能接的任务 —— 换个身份、换个时间段再来看看</p>
    {:else}
      <ul class="list">
        {#each acceptable as row (row.id)}
          <li class:blocked={!canAccept(row)}>
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
            {#if canAccept(row)}
              <button class="primary" onclick={() => accept(row.id)} disabled={busyId === row.id}>
                {busyId === row.id ? '接取中…' : '接取'}
              </button>
            {:else}
              <p class="reason">{reasonText(row)}</p>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  {:else if active.length === 0}
    <p class="empty">没有进行中的任务</p>
  {:else}
    <ul class="list">
      {#each active as row (row.quest_id)}
        <li>
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
</div>

<style>
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
