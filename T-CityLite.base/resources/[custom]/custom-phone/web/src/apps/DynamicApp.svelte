<script lang="ts">
  import { onMount } from 'svelte';
  import { dynamicApps, queryApp, appAction } from '../stores/apps';

  let { appId }: { appId: string } = $props();

  let rows: Record<string, unknown>[] = [];
  let loading = false;
  let error = '';
  let message = '';
  let feedback = '';
  let meta = $derived($dynamicApps.find((app) => app.id === appId));

  async function refresh() {
    if (!meta || !meta.queries.length) return;
    loading = true;
    error = '';
    const res = await queryApp(appId, meta.queries[0]);
    if (res && res.success && res.data && Array.isArray(res.data.rows)) {
      rows = res.data.rows;
    } else {
      error = (res && res.error) || 'query_failed';
      rows = [];
    }
    loading = false;
  }

  async function sendAlert() {
    if (!meta || !meta.actions.includes('alert')) return;
    const res = await appAction(appId, 'alert', { message });
    feedback = res && res.success
      ? `已发送给 ${res.data?.sent ?? 0} 名在勤警员`
      : `发送失败：${(res && res.error) || 'unknown'}`;
    if (res && res.success) message = '';
  }

  onMount(refresh);
</script>

<div class="dynamic-app app-transition">
  <header class="dynamic-head">
    <span class="dynamic-icon">{meta?.icon ?? '📱'}</span>
    <div>
      <h2>{meta?.label ?? appId}</h2>
      <p class="dynamic-sub">{rows.length} 条记录</p>
    </div>
    <button class="refresh-btn" onclick={refresh} disabled={loading}>刷新</button>
  </header>

  {#if error}
    <p class="dynamic-error">{error}</p>
  {/if}

  {#if loading}
    <p class="dynamic-empty">加载中…</p>
  {:else if rows.length === 0}
    <p class="dynamic-empty">暂无数据</p>
  {:else}
    <ul class="dynamic-list">
      {#each rows as row}
        <li>
          {#each Object.entries(row) as [key, value]}
            <span class="kv"><b>{key}</b>{String(value)}</span>
          {/each}
        </li>
      {/each}
    </ul>
  {/if}

  {#if meta?.actions.includes('alert')}
    <div class="dynamic-action">
      <input bind:value={message} maxlength="200" placeholder="发送给在勤警员…" />
      <button onclick={sendAlert} disabled={!message.trim()}>发送警报</button>
    </div>
    {#if feedback}<p class="dynamic-feedback">{feedback}</p>{/if}
  {/if}
</div>

<style>
  .dynamic-app { padding: 16px; color: #e8edf5; height: 100%; overflow-y: auto; }
  .dynamic-head { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; }
  .dynamic-icon { font-size: 28px; }
  .dynamic-head h2 { font-size: 16px; margin: 0; }
  .dynamic-sub { margin: 2px 0 0; font-size: 11px; opacity: 0.65; }
  .refresh-btn { margin-left: auto; font-size: 11px; padding: 6px 10px; border-radius: 8px; border: 1px solid rgba(255,255,255,.2); background: rgba(255,255,255,.08); color: inherit; }
  .dynamic-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
  .dynamic-list li { background: rgba(255,255,255,.06); border-radius: 10px; padding: 8px 10px; display: flex; flex-wrap: wrap; gap: 10px; font-size: 12px; }
  .kv b { opacity: 0.6; margin-right: 4px; font-weight: 500; }
  .dynamic-empty, .dynamic-error { font-size: 12px; opacity: 0.7; }
  .dynamic-error { color: #fca5a5; }
  .dynamic-action { display: flex; gap: 8px; margin-top: 14px; }
  .dynamic-action input { flex: 1; border-radius: 8px; border: 1px solid rgba(255,255,255,.18); background: rgba(0,0,0,.25); color: inherit; padding: 8px; font-size: 12px; }
  .dynamic-action button { border: 0; border-radius: 8px; padding: 8px 12px; background: #2563eb; color: #fff; font-size: 12px; }
  .dynamic-feedback { font-size: 11px; opacity: 0.75; margin-top: 8px; }
</style>
