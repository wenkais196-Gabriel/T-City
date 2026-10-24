<script lang="ts">
  import { onMount } from 'svelte';
  import { playerData } from '../stores/phone';
  import { queryApp, appAction } from '../stores/apps';

  type Unit = { citizenid: string; name: string; callsign: string; dept: string; status: string; incident_id: number | null };
  type Incident = { id: number; code: string; title: string; description: string; priority: number; status: string; created_at: string; x?: number; y?: number; z?: number };
  type Charge = { id: number | string; label: string; minutes: number; fine: number };

  type Tab = 'home' | 'units' | 'incidents' | 'citizen' | 'vehicle' | 'citations' | 'reports' | 'evidence' | 'cases' | 'bolos' | 'warrants' | 'arrests' | 'audit';

  let tab = $state<Tab>('home');
  let units = $state<Unit[]>([]);
  let incidents = $state<Incident[]>([]);
  let loading = $state(false);
  let error = $state('');
  let notice = $state('');

  let citizenQuery = $state('');
  let vehicleQuery = $state('');
  let lookupRows = $state<Record<string, unknown>[]>([]);
  let lookupError = $state('');
  let auditRows = $state<Record<string, unknown>[]>([]);
  let auditError = $state('');
  let citationRows = $state<Record<string, unknown>[]>([]);
  let reportRows = $state<Record<string, unknown>[]>([]);
  let citationError = $state('');
  let citationForm = $state({ citizenid: '', amount: '500', reason: '', plate: '' });
  let reportForm = $state({ title: '', incident_id: '', case_id: '', citizenid: '', location: '', body: '' });
  let reportOpts = $state({
    evidence: false, evidence_label: '', evidence_description: '',
    bolo: false, bolo_kind: 'person', bolo_target: '', bolo_reason: '',
  });
  let reportSubmitting = $state(false);
  let reportError = $state('');
  let reportListError = $state('');
  let reportResult = $state<any>(null);
  let evidenceRows = $state<Record<string, unknown>[]>([]);
  let evidenceForm = $state({ label: '', description: '', incident_id: '', location: '' });
  let caseRows = $state<Record<string, unknown>[]>([]);
  let boloRows = $state<Record<string, unknown>[]>([]);
  let caseForm = $state({ title: '', summary: '' });
  let caseDetail = $state<any>(null);
  let caseDetailError = $state('');
  let boloForm = $state({ kind: 'person', target: '', reason: '' });
  let warrantRows = $state<Record<string, unknown>[]>([]);
  let arrestRows = $state<Record<string, unknown>[]>([]);
  let warrantForm = $state({ citizenid: '', reason: '' });
  let arrestForm = $state({ citizenid: '', charges: '', incident_id: '', case_id: '', location: '', details: '' });

  let arrestPick = $state('');
  let chargeRows = $state<Charge[]>([]);
  let chargesError = $state('');
  let selectedChargeIds = $state<string[]>([]);
  let arrestOpts = $state({
    create_citation: true, citation_pct: 100,
    create_evidence: false, evidence_label: '',
    bolo: false, bolo_kind: 'person', bolo_target: '',
    create_case: false,
  });
  let arrestSubmitting = $state(false);
  let arrestError = $state('');
  let arrestResult = $state<any>(null);

  const formatCharges = (raw: unknown): string => {
    if (Array.isArray(raw)) return raw.map((c: any) => c?.label ?? c?.id ?? '').filter(Boolean).join('、');
    if (typeof raw === 'string') {
      try {
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) return parsed.map((c: any) => c?.label ?? c?.id ?? '').filter(Boolean).join('、');
      } catch { /* plain text */ }
      return raw;
    }
    return String(raw ?? '');
  };

  const statusLabel: Record<string, string> = {
    off_duty: '10-7 下班', available: '10-8 在勤', busy: '10-6 忙碌',
    assigned: '已派单', enroute: '前往中', on_scene: '现场', unavailable: '不可用',
  };

  const me = $derived(units.find((u) => u.citizenid === $playerData.citizenid));
  const myStatus = $derived(me?.status ?? 'off_duty');
  const openIncidents = $derived(incidents.filter((i) => i.status !== 'closed' && i.status !== 'cleared').length);
  const selectedCharges = $derived(chargeRows.filter((c) => selectedChargeIds.includes(String(c.id))));
  const chargeMinutes = $derived(selectedCharges.reduce((sum, c) => sum + Number(c.minutes || 0), 0));
  const chargeFine = $derived(selectedCharges.reduce((sum, c) => sum + Number(c.fine || 0), 0));
  const citationLow = $derived(Math.ceil(chargeFine * 0.8));
  const citationHigh = $derived(Math.floor(chargeFine * 1.2));
  const citationAmount = $derived(
    Math.min(citationHigh, Math.max(citationLow, Math.floor((chargeFine * arrestOpts.citation_pct) / 100))),
  );

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
    reportListError = '';
    const res = await queryApp('police_mdt', 'reports', {});
    if (res?.success) reportRows = res.data?.rows ?? [];
    else reportListError = reportErrorFor(res?.error ?? 'report_view_denied');
  }

  function reportErrorFor(code: unknown): string {
    const reasons: Record<string, string> = {
      action_rejected: '服务端拒绝：请检查权限与参数',
      action_failed: '服务端处理失败，请稍后重试',
      app_forbidden: '无权限使用 MDT（需在勤警察）',
      player_not_found: '角色尚未加载',
      not_police: '仅限警察使用',
      not_on_duty: '请先上班（10-8 在勤）',
      rank_too_low: '职级不足',
      bolo_forbidden: 'BOLO 需要 Sergeant+（警长及以上）',
      case_not_found: '案件不存在',
      incident_not_found: '警情不存在',
      invalid_params: '参数无效',
      invalid_incident: '警情 id 无效',
      invalid_case: '案件 id 无效',
      invalid_title: '标题至少 3 字（≤160 字）',
      invalid_body: '正文至少 10 字（≤4000 字）',
      invalid_evidence_label: '证据名称至少 3 字',
      invalid_bolo_kind: 'BOLO 类型无效',
      invalid_bolo_target: 'BOLO 目标不能为空',
      db_error: '数据库错误，请重试',
      audit_unavailable: '审计不可用，请稍后重试',
      unavailable: '服务暂不可用，请稍后重试',
    };
    const key = String(code ?? '');
    return reasons[key] ?? (key || '提交失败');
  }

  function applyReportIncident(incidentId: string) {
    reportForm.incident_id = incidentId;
    if (!incidentId || reportForm.location.trim()) return;
    const incident = incidents.find((i) => String(i.id) === incidentId);
    const coords = [incident?.x, incident?.y, incident?.z].map(Number);
    if (coords.every((n) => Number.isFinite(n))) {
      reportForm.location = coords.map((n) => n.toFixed(1)).join(', ');
    }
  }

  async function createReport() {
    reportError = '';
    reportResult = null;
    const title = reportForm.title.trim();
    const body = reportForm.body.trim();
    if (!title) { reportError = '请填写标题'; return; }
    if (title.length < 3) { reportError = '标题至少 3 字'; return; }
    if (body.length < 10) { reportError = '正文至少 10 字'; return; }
    if (reportOpts.evidence && reportOpts.evidence_label.trim().length < 3) {
      reportError = '证据名称至少 3 字'; return;
    }
    if (reportOpts.bolo && !reportOpts.bolo_target.trim()) {
      reportError = 'BOLO 目标不能为空'; return;
    }
    reportSubmitting = true;
    const res = await appAction('police_mdt', 'report_submit', {
      title,
      body,
      citizenid: reportForm.citizenid.trim() || undefined,
      incident_id: reportForm.incident_id ? Number(reportForm.incident_id) : undefined,
      case_id: reportForm.case_id ? Number(reportForm.case_id) : undefined,
      location: reportForm.location.trim() || undefined,
      evidence: reportOpts.evidence,
      evidence_label: reportOpts.evidence ? reportOpts.evidence_label.trim() : undefined,
      evidence_description: reportOpts.evidence ? reportOpts.evidence_description.trim() : undefined,
      bolo: reportOpts.bolo,
      bolo_kind: reportOpts.bolo ? reportOpts.bolo_kind : undefined,
      bolo_target: reportOpts.bolo ? reportOpts.bolo_target.trim() : undefined,
      bolo_reason: reportOpts.bolo ? reportOpts.bolo_reason.trim() : undefined,
    });
    reportSubmitting = false;
    if (!res?.success) {
      reportError = reportErrorFor(res?.error);
      return;
    }
    reportResult = res.data ?? {};
    notice = `报告 #${reportResult.report_id ?? '—'}`;
    reportForm = { title: '', incident_id: '', case_id: '', citizenid: '', location: '', body: '' };
    reportOpts = {
      evidence: false, evidence_label: '', evidence_description: '',
      bolo: false, bolo_kind: 'person', bolo_target: '', bolo_reason: '',
    };
    await Promise.all([loadReports(), loadBolos()]);
  }

  async function loadWarrants() {
    const res = await queryApp('police_mdt', 'warrants', {});
    if (res?.success) warrantRows = res.data?.rows ?? [];
  }

  async function requestWarrant() {
    const res = await appAction('police_mdt', 'request_warrant', {
      citizenid: warrantForm.citizenid.trim(), reason: warrantForm.reason.trim(),
    });
    notice = res?.success ? '搜查令已提交审批' : `失败：${res?.error ?? 'unknown'}`;
    if (res?.success) { warrantForm.citizenid = ''; warrantForm.reason = ''; }
    await loadWarrants();
  }

  async function decideWarrant(row: Record<string, unknown>, approve: boolean) {
    const res = await appAction('police_mdt', 'decide_warrant', {
      warrant_id: Number(row.id), approve,
    });
    notice = res?.success ? (approve ? '已批准' : '已驳回') : `失败：${res?.error ?? 'unknown'}`;
    await loadWarrants();
  }

  async function loadArrests() {
    const res = await queryApp('police_mdt', 'arrests', {});
    if (res?.success) arrestRows = res.data?.rows ?? [];
  }

  async function registerArrest() {
    const res = await appAction('police_mdt', 'register_arrest', {
      citizenid: arrestForm.citizenid.trim(),
      charges: arrestForm.charges.trim(),
      incident_id: arrestForm.incident_id ? Number(arrestForm.incident_id) : undefined,
      case_id: arrestForm.case_id ? Number(arrestForm.case_id) : undefined,
    });
    notice = res?.success ? '逮捕已登记' : `失败：${res?.error ?? 'unknown'}`;
    if (res?.success) { arrestForm.citizenid = ''; arrestForm.charges = ''; }
    await loadArrests();
  }

  async function loadCharges() {
    chargesError = '';
    const res = await queryApp('police_mdt', 'charges');
    if (res?.success) chargeRows = res.data?.rows ?? [];
    else chargesError = res?.error ?? 'charges_failed';
  }

  function toggleCharge(id: number | string) {
    const key = String(id);
    selectedChargeIds = selectedChargeIds.includes(key)
      ? selectedChargeIds.filter((x) => x !== key)
      : [...selectedChargeIds, key];
  }

  function applyIncidentPick() {
    if (!arrestPick) return;
    arrestForm.incident_id = arrestPick;
    const incident = incidents.find((i) => String(i.id) === arrestPick);
    const coords = [incident?.x, incident?.y, incident?.z].map(Number);
    if (coords.every((n) => Number.isFinite(n))) {
      arrestForm.location = coords.map((n) => n.toFixed(1)).join(', ');
    }
  }

  async function submitArrest() {
    arrestError = '';
    arrestResult = null;
    if (!arrestForm.citizenid.trim()) { arrestError = '请填写目标 citizenid'; return; }
    if (selectedChargeIds.length === 0) { arrestError = '请至少选择一条罪名'; return; }
    arrestSubmitting = true;
    const res = await appAction('police_mdt', 'arrest_submit', {
      citizenid: arrestForm.citizenid.trim(),
      charge_ids: selectedChargeIds,
      incident_id: arrestForm.incident_id ? Number(arrestForm.incident_id) : undefined,
      case_id: arrestForm.case_id ? Number(arrestForm.case_id) : undefined,
      location: arrestForm.location.trim() || undefined,
      details: arrestForm.details.trim() || undefined,
      create_citation: arrestOpts.create_citation,
      citation_amount: arrestOpts.create_citation ? citationAmount : undefined,
      create_evidence: arrestOpts.create_evidence,
      evidence_label: arrestOpts.create_evidence ? arrestOpts.evidence_label.trim() : undefined,
      bolo: arrestOpts.bolo,
      bolo_kind: arrestOpts.bolo ? arrestOpts.bolo_kind : undefined,
      bolo_target: arrestOpts.bolo ? arrestOpts.bolo_target.trim() : undefined,
      create_case: arrestOpts.create_case,
    });
    arrestSubmitting = false;
    if (!res?.success) {
      const reasons: Record<string, string> = {
        action_rejected: '服务端拒绝：请检查目标是否在线、罪名与权限',
        target_not_cuffed: '目标没有上铐/倒地，先 /cuff',
        too_far: '目标距离超过 5 米',
        target_unavailable: '目标或你的角色尚未加载',
        already_jailed: '目标已在服刑',
        citizen_offline: '目标已离线',
        bolo_forbidden: 'BOLO 需要 Sergeant+',
        case_forbidden: '创建案件需要 Sergeant+',
        invalid_charges: '罪名无效或超过 8 条',
        jail_failed: '送监失败，已回滚记录',
      };
      arrestError = reasons[String(res?.error)] ?? (res?.error ?? 'arrest_failed');
      return;
    }
    arrestResult = res.data ?? {};
    notice = `逮捕已提交：报告 #${arrestResult.report_id ?? '—'}`;
    selectedChargeIds = [];
    arrestForm.citizenid = '';
    arrestForm.details = '';
    arrestForm.incident_id = '';
    arrestForm.case_id = '';
    arrestForm.location = '';
    arrestOpts.create_evidence = false;
    arrestOpts.evidence_label = '';
    arrestOpts.create_case = false;
    arrestPick = '';
    await Promise.all([loadArrests(), refresh()]);
  }

  async function loadCases() {
    const res = await queryApp('police_mdt', 'cases', {});
    if (res?.success) caseRows = res.data?.rows ?? [];
  }

  async function openCase(id: number) {
    caseDetail = null;
    caseDetailError = '';
    const res = await queryApp('police_mdt', 'case_detail', { case_id: id });
    if (res?.success && res.data?.rows?.length) caseDetail = res.data.rows[0];
    else caseDetailError = res?.error ?? 'not_found';
  }

  async function createCase() {
    const res = await appAction('police_mdt', 'create_case', {
      title: caseForm.title.trim(), summary: caseForm.summary.trim(),
    });
    notice = res?.success ? `案件已建立：${res.data?.case_no ?? ''}` : `失败：${res?.error ?? 'unknown'}`;
    if (res?.success) { caseForm.title = ''; caseForm.summary = ''; }
    await loadCases();
  }

  async function loadBolos() {
    const res = await queryApp('police_mdt', 'bolos');
    if (res?.success) boloRows = res.data?.rows ?? [];
  }

  async function createBolo() {
    const res = await appAction('police_mdt', 'create_bolo', {
      kind: boloForm.kind, target: boloForm.target.trim(), reason: boloForm.reason.trim(),
    });
    notice = res?.success ? 'BOLO 已发布' : `失败：${res?.error ?? 'unknown'}`;
    if (res?.success) { boloForm.target = ''; boloForm.reason = ''; }
    await loadBolos();
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
    {#each [['home','首页'],['units','单位'],['incidents','接警'],['citizen','人员'],['vehicle','车辆'],['citations','罚单'],['reports','报告'],['evidence','证据'],['cases','案件'],['bolos','BOLO'],['warrants','搜查令'],['arrests','逮捕'],['audit','审计']] as [id, label]}
      <button class:active={tab === id} onclick={() => { tab = id as Tab; if (tab === 'audit') loadAudit(); if (tab === 'citations') loadCitations(); if (tab === 'reports') loadReports(); if (tab === 'evidence') loadEvidence(); if (tab === 'cases') loadCases(); if (tab === 'bolos') loadBolos(); if (tab === 'warrants') loadWarrants(); if (tab === 'arrests') { loadCharges(); loadArrests(); } }}>{label}</button>
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

  {:else if tab === 'vehicle'}
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
        <input bind:value={reportForm.title} placeholder="标题（必填）" />
        <textarea class="wide" bind:value={reportForm.body} rows="4" placeholder="报告正文（必填，至少 10 字）"></textarea>
      </div>
      <div class="form">
        <select bind:value={reportForm.incident_id} onchange={(e) => applyReportIncident((e.currentTarget as HTMLSelectElement).value)}>
          <option value="">关联警情（可选）</option>
          {#each incidents as incident}
            <option value={String(incident.id)}>#{incident.id} [{incident.code}] {incident.title}</option>
          {/each}
        </select>
        <input bind:value={reportForm.case_id} placeholder="案件 id（可选）" />
        <input bind:value={reportForm.citizenid} placeholder="对象 citizenid（可选）" />
        <input bind:value={reportForm.location} placeholder="地点（可选）" />
      </div>

      <div class="opts">
        <label class="opt">
          <input type="checkbox" bind:checked={reportOpts.evidence} />
          <span>附证据</span>
        </label>
        {#if reportOpts.evidence}
          <div class="form">
            <input bind:value={reportOpts.evidence_label} placeholder="证据名称（≥3 字）" />
            <textarea class="wide" bind:value={reportOpts.evidence_description} rows="2" placeholder="证据描述（可选）"></textarea>
          </div>
        {/if}

        <label class="opt">
          <input type="checkbox" bind:checked={reportOpts.bolo} />
          <span>标记 BOLO</span>
        </label>
        {#if reportOpts.bolo}
          <p class="muted">BOLO 需要 Sergeant+ 权限，服务端最终裁定。</p>
          <div class="opt-row">
            <select bind:value={reportOpts.bolo_kind}>
              <option value="person">人员</option>
              <option value="vehicle">车辆</option>
            </select>
            <input bind:value={reportOpts.bolo_target} placeholder="citizenid / 车牌" />
          </div>
          <div class="opt-row">
            <input bind:value={reportOpts.bolo_reason} placeholder="BOLO 原因（可选）" />
          </div>
        {/if}
      </div>
      <p class="muted">证据 / BOLO 也可在此随报告一并附上，无需切换旧 tab。</p>

      <button class="submit" onclick={createReport} disabled={reportSubmitting}>
        {reportSubmitting ? '提交中…' : '提交报告'}
      </button>
      {#if reportError}<p class="err">提交失败：{reportError}</p>{/if}
      {#if reportResult}
        <p class="notice">
          报告 #{reportResult.report_id}{#if reportResult.evidence_id} · 证据 #{reportResult.evidence_id}{/if}{#if reportResult.bolo} · BOLO 已发布{/if}
        </p>
      {/if}

      <h3>最近报告</h3>
      {#if reportListError}<p class="err">{reportListError}</p>{/if}
      {#if reportRows.length === 0}<p class="empty">暂无报告</p>{/if}
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

  {:else if tab === 'cases'}
    <section class="card">
      <h3>新建案件（Sergeant+）</h3>
      <div class="form">
        <input bind:value={caseForm.title} placeholder="案件标题" />
        <input bind:value={caseForm.summary} placeholder="摘要" />
        <button onclick={createCase}>建档</button>
      </div>
      {#each caseRows as row}
        <div class="row">
          <p class="line"><b>{String(row.case_no ?? '')}</b> · {String(row.title)} <span class="muted">{String(row.status)}</span></p>
          <button class="step" onclick={() => openCase(Number(row.id))}>打开</button>
        </div>
      {/each}
      {#if caseDetailError}<p class="err">{caseDetailError}</p>{/if}
      {#if caseDetail}
        <div class="detail">
          <div class="row">
            <h3>{caseDetail.case.case_no} · {caseDetail.case.title}</h3>
            <button class="refresh" onclick={() => (caseDetail = null)}>关闭</button>
          </div>
          <p class="muted">{caseDetail.case.summary}</p>
          <p class="line">报告 {caseDetail.reports.length} · 证据 {caseDetail.evidence.length} · 逮捕 {caseDetail.arrests.length}</p>
          {#each caseDetail.reports as r}
            <p class="line">📄 #{String(r.id)} {String(r.title)}</p>
          {/each}
          {#each caseDetail.evidence as e}
            <p class="line">🧾 {String(e.exhibit_no ?? '')} {String(e.label)}</p>
          {/each}
          {#each caseDetail.arrests as a}
            <p class="line">🚔 {String(a.citizenid)} · {String(a.charges)}</p>
          {/each}
        </div>
      {/if}
    </section>

  {:else if tab === 'bolos'}
    <section class="card">
      <h3>发布 BOLO（Sergeant+）</h3>
      <div class="form">
        <select bind:value={boloForm.kind}><option value="person">人员</option><option value="vehicle">车辆</option></select>
        <input bind:value={boloForm.target} placeholder="citizenid / 车牌" />
        <input bind:value={boloForm.reason} placeholder="原因" />
        <button onclick={createBolo}>发布</button>
      </div>
      {#each boloRows as row}
        <p class="line">{String(row.kind)} · {String(row.target)} · {String(row.reason)}</p>
      {/each}
    </section>

  {:else if tab === 'warrants'}
    <section class="card">
      <h3>申请搜查令（Sergeant+）</h3>
      <div class="form">
        <input bind:value={warrantForm.citizenid} placeholder="citizenid" />
        <input bind:value={warrantForm.reason} placeholder="理由" />
        <button onclick={requestWarrant}>申请</button>
      </div>
      {#each warrantRows as row}
        <div class="row">
          <div>
            <b>{String(row.citizenid)}</b>
            <p class="muted">{String(row.reason)} · {String(row.status)}</p>
          </div>
          {#if row.status === 'requested'}
            <div class="actions">
              <button class="step" onclick={() => decideWarrant(row, true)}>批准</button>
              <button class="clear" onclick={() => decideWarrant(row, false)}>驳回</button>
            </div>
          {/if}
        </div>
      {/each}
    </section>

  {:else if tab === 'arrests'}
    <section class="card">
      <h3>一次逮捕提交</h3>
      <div class="form">
        <input bind:value={arrestForm.citizenid} placeholder="目标 citizenid" />
        <select value={arrestPick} onchange={(e) => { arrestPick = (e.currentTarget as HTMLSelectElement).value; applyIncidentPick(); }}>
          <option value="">从最近警情带入…</option>
          {#each incidents as incident}
            <option value={String(incident.id)}>#{incident.id} [{incident.code}] {incident.title}</option>
          {/each}
        </select>
      </div>
      <div class="form">
        <input bind:value={arrestForm.incident_id} placeholder="关联警情 id（自动带入）" />
        <input bind:value={arrestForm.case_id} placeholder="案件 id（可选）" />
        <input bind:value={arrestForm.location} placeholder="地点（自动/可改）" />
      </div>

      <h3>罪名（可多选）</h3>
      {#if chargesError}<p class="err">{chargesError}</p>{/if}
      {#if chargeRows.length === 0}<p class="empty">暂无可选罪名</p>{/if}
      <div class="charge-list">
        {#each chargeRows as charge (charge.id)}
          <label class="charge">
            <input type="checkbox" checked={selectedChargeIds.includes(String(charge.id))} onchange={() => toggleCharge(charge.id)} />
            <span>{charge.label}</span>
            <span class="muted">{Number(charge.minutes || 0)} 分钟 · ${Number(charge.fine || 0)}</span>
          </label>
        {/each}
      </div>
      <p class="line">合计：<b>{chargeMinutes}</b> 分钟 · <b>${chargeFine}</b> <span class="muted">实际以服务端裁定为准</span></p>

      <div class="form">
        <textarea bind:value={arrestForm.details} rows="3" placeholder="报告正文（可选）"></textarea>
      </div>

      <div class="opts">
        <label class="opt">
          <input type="checkbox" bind:checked={arrestOpts.create_citation} />
          <span>同时开罚单</span>
        </label>
        {#if arrestOpts.create_citation}
          <input type="range" min="80" max="120" step="5" bind:value={arrestOpts.citation_pct} disabled={chargeFine === 0} />
          <p class="muted">罚单金额 ${citationAmount}（基准 ${chargeFine}，0.8–1.2×；服务端最终 clamp）</p>
        {/if}
        <label class="opt">
          <input type="checkbox" bind:checked={arrestOpts.create_evidence} />
          <span>登记证据</span>
        </label>
        {#if arrestOpts.create_evidence}
          <input bind:value={arrestOpts.evidence_label} placeholder="证据 label（≥3 字）" />
        {/if}
        <label class="opt">
          <input type="checkbox" bind:checked={arrestOpts.create_case} />
          <span>创建案件</span>
        </label>
      </div>

      <button class="submit" onclick={submitArrest} disabled={arrestSubmitting}>
        {arrestSubmitting ? '提交中…' : '提交逮捕'}
      </button>
      {#if arrestError}<p class="err">提交失败：{arrestError}</p>{/if}
      {#if arrestResult}
        <p class="notice">报告 #{arrestResult.report_id} · 刑期 {arrestResult.minutes} 分钟 · 罚款 ${arrestResult.fine} · {arrestResult.jailed ? '已入狱' : '未入狱'}</p>
      {/if}

      <h3>最近逮捕</h3>
      {#if arrestRows.length === 0}<p class="empty">暂无</p>{/if}
      {#each arrestRows as row}
        <p class="line">#{String(row.id)} · {String(row.citizenid)} · {formatCharges(row.charges)} <span class="muted">{String(row.officer_citizenid)}</span></p>
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
  .detail { margin-top: 10px; padding-top: 8px; border-top: 1px solid rgba(255,255,255,.15); }
  .actions { display: flex; gap: 4px; }
  .step { font-size: 10px; border: 0; border-radius: 8px; padding: 5px 8px; background: #f59e0b; color: #111; }
  .clear { font-size: 10px; border: 0; border-radius: 8px; padding: 5px 8px; background: #b91c1c; color: #fff; }
  .lookup, .form { display: flex; gap: 6px; margin-bottom: 8px; flex-wrap: wrap; }
  .form input, .form textarea, .form select { flex: 1 1 45%; background: rgba(0,0,0,.3); border: 1px solid rgba(255,255,255,.15); color: inherit; border-radius: 8px; padding: 6px; font-size: 11px; }
  .form textarea.wide { flex-basis: 100%; }
  .form button { border: 0; border-radius: 8px; padding: 6px 10px; background: #2563eb; color: #fff; font-size: 11px; }
  .charge-list { max-height: 200px; overflow-y: auto; margin-bottom: 6px; }
  .charge { display: flex; align-items: center; gap: 6px; padding: 5px 0; border-bottom: 1px solid rgba(255,255,255,.06); }
  .charge .muted { margin-left: auto; white-space: nowrap; }
  .opts { display: flex; flex-direction: column; gap: 6px; margin: 8px 0; }
  .opt { display: flex; align-items: center; gap: 6px; }
  .opts input:not([type="checkbox"]):not([type="range"]) { background: rgba(0,0,0,.3); border: 1px solid rgba(255,255,255,.15); color: inherit; border-radius: 8px; padding: 6px; font-size: 11px; }
  .opts input[type="range"] { width: 100%; padding: 0; border: 0; background: transparent; accent-color: #2563eb; }
  .opt-row { display: flex; gap: 6px; }
  .opt-row select { background: rgba(0,0,0,.3); border: 1px solid rgba(255,255,255,.15); color: inherit; border-radius: 8px; padding: 6px; font-size: 11px; }
  .opt-row input { flex: 1; }
  .submit { width: 100%; font-size: 12px; border: 0; border-radius: 8px; padding: 8px 12px; background: #16a34a; color: #fff; }
  .submit:disabled { opacity: .5; }
  .line { margin: 3px 0; }
  .empty { opacity: 0.6; }
  .err { color: #fca5a5; font-size: 11px; }
  .notice { color: #86efac; font-size: 11px; }
</style>
