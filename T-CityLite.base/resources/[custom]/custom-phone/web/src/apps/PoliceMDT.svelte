<script lang="ts">
  import { onMount } from 'svelte';
  import { playerData } from '../stores/phone';
  import { queryApp, appAction } from '../stores/apps';

  type Unit = { citizenid: string; name: string; callsign: string; dept: string; status: string; incident_id: number | null };
  type Incident = { id: number; code: string; title: string; description: string; priority: number; status: string; created_at: string };

  type Tab = 'home' | 'units' | 'incidents' | 'citizen' | 'vehicle' | 'citations' | 'reports' | 'evidence' | 'audit';

  let tab: Tab = 'home';
  let units: Unit[] = [];
  let incidents: Incident[] = [];
  let loading = false;
  let error = '';
  let notice = '';

  let citizenQuery = '';
  let vehicleQuery = '';
  let lookupRows: Record<string, unknown>[] = [];
  let lookupError = '';
  let auditRows: Record<string, unknown>[] = [];
  let auditError = '';
  let citationRows: Record<string, unknown>[] = [];
  let reportRows: Record<string, unknown>[] = [];
  let citationError = '';
  let citationForm = { citizenid: '', amount: '500', reason: '', plate: '' };
  let reportForm = { title: '', incident_id: '', body: '' };
  let evidenceRows: Record<string, unknown>[] = [];
  let evidenceForm = { label: '', description: '', incident_id: '', location: '' };

  const statusLabel: Record<string, string> = {
    off_duty: '10-7 下班', available: '10-8 在勤', busy: '10-6 忙碌',
    assigned: '已派单', enroute: '前往中', on_scene: '现场', unavailable: '不可用',
  };

  const me = $derived(units.find((u) => u.citizenid === $playerData.citizenid));
  const myStatus = $derived(me?.status ?? 'off_duty');
  const openIncidents = $derived(incidents.filter((i) => i.status !== 'closed' && i.status !== 'cleared').length);

  async function refresh() {
    loading = true;
    error = '';
    const [u, i] = await Promise.all([
      queryApp('police_mdt', 'units'),
      queryApp('police_mdt', 'incidents'),
    ]);
    if (u?.success) units = u.data?.rows ?? [];
    else error = u?.error ?? 'units_failed';
    if (i?.success) incidents = i.data?.rows ?? [];
    else error = error || (i?.error ?? 'incidents_failed');
    loading = false;
  }

  async function setStatus(status: string) {
    const res = await appAction('police_mdt', 'set_status', { status });
    notice = res?.success ? `状态已切换：${statusLabel[status] ?? status}` : `失败：${res?.error ?? 'unknown'}`;
    await refresh();
  }

  async function assign(incident: Incident, unit: Unit) {
    const res = await appAction('police_mdt', 'assign', { incident_id: incident.id, citizenid: unit.citizenid });
    notice = res?.success ? `已派 ${unit.callsign || unit.name} → #${incident.id}` : `派单失败：${res?.error ?? 'unknown'}`;
    await refresh();
  }

  async function clearIncident(incident: Incident) {
    const res = await appAction('police_mdt', 'clear', { incident_id: incident.id, status: 'cleared' });
    notice = res?.success ? `警情 #${incident.id} 已清场` : `清场失败：${res?.error ?? 'unknown'}`;
    await refresh();
  }

  async function lookup(kind: 'citizen' | 'vehicle') {
    lookupRows = [];
    lookupError = '';
    const params = kind === 'citizen' ? { citizenid: citizenQuery.trim() } : { plate: vehicleQuery.trim() };
    const res = await queryApp('police_mdt', kind, params);
    if (res?.success) lookupRows = res.data?.rows ?? [];
    else lookupError = res?.error ?? 'not_found';
  }

  async function loadCitations() {
    citationError = '';
    const res = await queryApp('police_mdt', 'citations', {});
    if (res?.success) citationRows = res.data?.rows ?? [];
    else citationError = res?.error ?? 'citation_view_denied';
  }

  async function issueCitation() {
    const res = await appAction('police_mdt', 'issue_citation', {
      citizenid: citationForm.citizenid.trim(),
      amount: Number(citationForm.amount),
      reason: citationForm.reason.trim(),
      plate: citationForm.plate.trim(),
    });
    notice = res?.success ? '罚单已开具并通知当事人' : `开单失败：${res?.error ?? 'unknown'}`;
    if (res?.success) citationForm.reason = '';
    await loadCitations();
  }

  async function loadReports() {
    const res = await queryApp('police_mdt', 'reports', {});
    if (res?.success) reportRows = res.data?.rows ?? [];
    else citationError = res?.error ?? 'report_view_denied';
  }

  async function createReport() {
    const res = await appAction('police_mdt', 'create_report', {
      title: reportForm.title.trim(),
      body: reportForm.body.trim(),
      incident_id: reportForm.incident_id ? Number(reportForm.incident_id) : undefined,
    });
    notice = res?.success ? '报告已提交' : `提交失败：${res?.error ?? 'unknown'}`;
    if (res?.success) { reportForm.title = ''; reportForm.body = ''; }
    await loadReports();
  }

  async function loadEvidence() {
    const res = await queryApp('police_mdt', 'evidence', {});
    if (res?.success) evidenceRows = res.data?.rows ?? [];
  }

  async function registerEvidence() {
    const res = await appAction('police_mdt', 'register_evidence', {
      label: evidenceForm.label.trim(),
      description: evidenceForm.description.trim(),
      incident_id: evidenceForm.incident_id ? Number(evidenceForm.incident_id) : undefined,
      location: evidenceForm.location.trim(),
    });
    notice = res?.success ? `证据已登记：${res.data?.exhibit_no ?? ''}` : `登记失败：${res?.error ?? 'unknown'}`;
    if (res?.success) { evidenceForm.label = ''; evidenceForm.description = ''; }
    await loadEvidence();
  }

  async function showChain(row: Record<string, unknown>) {
    const res = await queryApp('police_mdt', 'evidence_chain', { evidence_id: Number(row.id) });
    const steps = res?.success ? (res.data?.rows ?? []) : [];
    notice = steps.length
      ? `#${row.exhibit_no} 保管链：` + steps.map((s: any) => `${s.action}@${s.created_at}`).join(' → ')
      : '暂无保管链记录';
  }

  async function loadAudit() {
    auditError = '';
    const res = await queryApp('police_mdt', 'audit');
    if (res?.success) auditRows = res.data?.rows ?? [];
    else auditError = res?.error ?? 'audit_forbidden';
  }

  async function updateIncident(incident: Incident, action: 'enroute' | 'on_scene') {
    const res = await appAction('police_mdt', action, { incident_id: incident.id });
    notice = res?.success ? `#${incident.id} ${action === 'enroute' ? '前往中' : '已到场'}` : `失败：${res?.error ?? 'unknown'}`;
    await refresh();
  }

  onMount(refresh);
</script>

<div class="mdt">
  <header class="mdt-head">
    <div>
      <h2>🛡️ Police MDT</h2>
      <p class="sub">{me ? `${me.callsign || '—'} · ${me.dept}` : '未在勤'}</p>
    </div>
    <span class="status-pill" class:on={myStatus === 'available'}>{statusLabel[myStatus] ?? myStatus}</span>
  </header>

  <nav class="tabs">
    {#each [['home','首页'],['units','单位'],['incidents','接警'],['citizen','人员'],['vehicle','车辆'],['citations','罚单'],['reports','报告'],['evidence','证据'],['audit','审计']] as [id, label]}
      <button class:active={tab === id} onclick={() => { tab = id as Tab; if (tab === 'audit') loadAudit(); if (tab === 'citations') loadCitations(); if (tab === 'reports') loadReports(); if (tab === 'evidence') loadEvidence(); }}>{label}</button>
    {/each}
  </nav>

  {#if error}<p class="err">{error}</p>{/if}
  {#if notice}<p class="notice">{notice}</p>{/if}

  {#if tab === 'home'}
    <section class="card">
      <h3>我的状态</h3>
      <div class="status-row">
        <button class:active={myStatus === 'available'} onclick={() => setStatus('available')}>10-8 在勤</button>
        <button class:active={myStatus === 'busy'} onclick={() => setStatus('busy')}>10-6 忙碌</button>
        <button class:active={myStatus === 'off_duty'} onclick={() => setStatus('off_duty')}>10-7 下班</button>
      </div>
      <button class="refresh" onclick={refresh} disabled={loading}>刷新</button>
    </section>
    <section class="card stats">
      <div><b>{units.length}</b><span>单位</span></div>
      <div><b>{openIncidents}</b><span>待处理警情</span></div>
    </section>
    <section class="card">
      <h3>最新警情</h3>
      {#if incidents.length === 0}<p class="empty">暂无</p>{/if}
      {#each incidents.slice(0, 4) as incident}
        <p class="line">#{incident.id} [{incident.code}] {incident.title} <span class="muted">{statusLabel[incident.status] ?? incident.status}</span></p>
      {/each}
    </section>

  {:else if tab === 'units'}
    <section class="card">
      {#if units.length === 0}<p class="empty">暂无在勤单位</p>{/if}
      {#each units as unit}
        <div class="row">
          <div>
            <b>{unit.callsign || unit.name || unit.citizenid}</b>
            <p class="muted">{unit.name} · {unit.dept}</p>
          </div>
          <span class="tag">{statusLabel[unit.status] ?? unit.status}</span>
        </div>
      {/each}
    </section>

  {:else if tab === 'incidents'}
    <section class="card">
      {#if incidents.length === 0}<p class="empty">暂无警情</p>{/if}
      {#each incidents as incident}
        <div class="incident">
          <div class="row">
            <div>
              <b>#{incident.id} [{incident.code}] {incident.title}</b>
              <p class="muted">P{incident.priority} · {statusLabel[incident.status] ?? incident.status} · {incident.created_at}</p>
            </div>
            <div class="actions">
              <button class="step" onclick={() => updateIncident(incident, 'enroute')}>前往</button>
              <button class="step" onclick={() => updateIncident(incident, 'on_scene')}>到场</button>
              <button class="clear" onclick={() => clearIncident(incident)}>清场</button>
            </div>
          </div>
          {#if incident.description}<p class="desc">{incident.description}</p>{/if}
          <div class="assign-row">
            <select id={`unit-${incident.id}`}>
              {#each units as unit}<option value={unit.citizenid}>{unit.callsign || unit.name || unit.citizenid}</option>{/each}
            </select>
            <button onclick={() => {
              const el = document.getElementById(`unit-${incident.id}`) as HTMLSelectElement;
              const unit = units.find((u) => u.citizenid === el?.value);
              if (unit) assign(incident, unit);
            }}>派单</button>
          </div>
        </div>
      {/each}
    </section>

  {:else if tab === 'citizen'}
    <section class="card">
      <h3>人员查询</h3>
      <div class="lookup">
        <input bind:value={citizenQuery} placeholder="citizenid" />
        <button onclick={() => lookup('citizen')}>查询</button>
      </div>
      {#if lookupError}<p class="err">{lookupError}</p>{/if}
      {#each lookupRows as row}
        {#each Object.entries(row) as [k, v]}<p class="line"><b>{k}</b> {String(v)}</p>{/each}
      {/each}
    </section>

  {:else}
    <section class="card">
      <h3>车辆查询</h3>
      <div class="lookup">
        <input bind:value={vehicleQuery} placeholder="车牌" />
        <button onclick={() => lookup('vehicle')}>查询</button>
      </div>
      {#if lookupError}<p class="err">{lookupError}</p>{/if}
      {#each lookupRows as row}
        {#each Object.entries(row) as [k, v]}<p class="line"><b>{k}</b> {String(v)}</p>{/each}
      {/each}
    </section>

  {:else if tab === 'citations'}
    <section class="card">
      <h3>开罚单</h3>
      <div class="form">
        <input bind:value={citationForm.citizenid} placeholder="citizenid" />
        <input bind:value={citationForm.amount} type="number" placeholder="金额" />
        <input bind:value={citationForm.plate} placeholder="车牌(可选)" />
        <input bind:value={citationForm.reason} placeholder="原因（至少 3 字）" />
        <button onclick={issueCitation}>开具</button>
      </div>
      {#if citationError}<p class="err">{citationError}</p>{/if}
      {#each citationRows as row}
        <p class="line">#{String(row.id)} · {String(row.citizenid)} · ${String(row.amount)} · {String(row.reason)} <span class="muted">{String(row.status)}</span></p>
      {/each}
    </section>

  {:else if tab === 'reports'}
    <section class="card">
      <h3>提交报告</h3>
      <div class="form">
        <input bind:value={reportForm.title} placeholder="标题" />
        <input bind:value={reportForm.incident_id} placeholder="警情 id(可选)" />
        <textarea bind:value={reportForm.body} rows="3" placeholder="报告正文（至少 10 字）"></textarea>
        <button onclick={createReport}>提交</button>
      </div>
      {#each reportRows as row}
        <p class="line">#{String(row.id)} · {String(row.title)} · {String(row.author_citizenid)}</p>
      {/each}
    </section>

  {:else if tab === 'evidence'}
    <section class="card">
      <h3>登记证据</h3>
      <div class="form">
        <input bind:value={evidenceForm.label} placeholder="证据名称（≥3 字）" />
        <input bind:value={evidenceForm.incident_id} placeholder="警情 id" />
        <input bind:value={evidenceForm.location} placeholder="发现地点(可选)" />
        <textarea bind:value={evidenceForm.description} rows="2" placeholder="描述"></textarea>
        <button onclick={registerEvidence}>登记</button>
      </div>
      {#each evidenceRows as row}
        <div class="row">
          <div>
            <b>{String(row.exhibit_no ?? '')}</b> {String(row.label)}
            <p class="muted">{String(row.description ?? '')}</p>
          </div>
          <button class="step" onclick={() => showChain(row)}>保管链</button>
        </div>
      {/each}
    </section>

  {:else if tab === 'audit'}
    <section class="card">
      <h3>审计（需 Lieutenant+）</h3>
      {#if auditError}<p class="err">{auditError}</p>{/if}
      {#each auditRows as row}
        <p class="line">{String(row.created_at)} · {String(row.actor_citizenid)} · {String(row.action)} {String(row.target ?? '')}</p>
      {/each}
    </section>
  {/if}
</div>

<style>
  .mdt { padding: 14px; height: 100%; overflow-y: auto; color: #e8edf5; font-size: 12px; }
  .mdt-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 10px; }
  .mdt-head h2 { margin: 0; font-size: 16px; }
  .sub, .muted { margin: 2px 0 0; opacity: 0.6; font-size: 11px; }
  .status-pill { font-size: 11px; padding: 4px 8px; border-radius: 999px; background: rgba(255,255,255,.1); }
  .status-pill.on { background: rgba(34,197,94,.25); color: #86efac; }
  .tabs { display: flex; gap: 4px; margin-bottom: 10px; overflow-x: auto; }
  .tabs button { flex: 1; font-size: 11px; padding: 6px 4px; border-radius: 8px; border: 1px solid rgba(255,255,255,.15); background: transparent; color: inherit; }
  .tabs button.active { background: #2563eb; border-color: #2563eb; }
  .card { background: rgba(255,255,255,.05); border-radius: 12px; padding: 10px; margin-bottom: 10px; }
  .card h3 { margin: 0 0 8px; font-size: 12px; opacity: 0.8; }
  .status-row { display: flex; gap: 6px; flex-wrap: wrap; }
  .status-row button { flex: 1; font-size: 11px; padding: 7px 4px; border-radius: 8px; border: 1px solid rgba(255,255,255,.15); background: transparent; color: inherit; }
  .status-row button.active { background: #16a34a; border-color: #16a34a; }
  .refresh { margin-top: 8px; font-size: 11px; background: transparent; border: 1px solid rgba(255,255,255,.2); color: inherit; border-radius: 8px; padding: 5px 10px; }
  .stats { display: flex; gap: 10px; text-align: center; }
  .stats div { flex: 1; }
  .stats b { display: block; font-size: 22px; }
  .stats span { font-size: 10px; opacity: 0.6; }
  .row { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 6px 0; border-bottom: 1px solid rgba(255,255,255,.06); }
  .tag { font-size: 10px; padding: 3px 7px; border-radius: 999px; background: rgba(255,255,255,.1); }
  .incident { padding: 8px 0; border-bottom: 1px solid rgba(255,255,255,.08); }
  .desc { font-size: 11px; opacity: 0.75; margin: 4px 0; }
  .assign-row { display: flex; gap: 6px; margin-top: 6px; }
  .assign-row select, .lookup input { flex: 1; background: rgba(0,0,0,.3); border: 1px solid rgba(255,255,255,.15); color: inherit; border-radius: 8px; padding: 6px; font-size: 11px; }
  .assign-row button, .lookup button { font-size: 11px; border: 0; border-radius: 8px; padding: 6px 10px; background: #2563eb; color: #fff; }
  .actions { display: flex; gap: 4px; }
  .step { font-size: 10px; border: 0; border-radius: 8px; padding: 5px 8px; background: #f59e0b; color: #111; }
  .clear { font-size: 10px; border: 0; border-radius: 8px; padding: 5px 8px; background: #b91c1c; color: #fff; }
  .lookup, .form { display: flex; gap: 6px; margin-bottom: 8px; flex-wrap: wrap; }
  .form input, .form textarea { flex: 1 1 45%; background: rgba(0,0,0,.3); border: 1px solid rgba(255,255,255,.15); color: inherit; border-radius: 8px; padding: 6px; font-size: 11px; }
  .form button { border: 0; border-radius: 8px; padding: 6px 10px; background: #2563eb; color: #fff; font-size: 11px; }
  .line { margin: 3px 0; }
  .empty { opacity: 0.6; }
  .err { color: #fca5a5; font-size: 11px; }
  .notice { color: #86efac; font-size: 11px; }
</style>
