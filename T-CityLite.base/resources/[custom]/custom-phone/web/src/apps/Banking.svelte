<script lang="ts">
  import { onMount } from 'svelte';
  import { playerData } from '../stores/phone';
  import { fetchNui, isBrowser } from '../utils/nui';

  let amountInput = $state('');
  let transferTarget = $state('');
  let transferReason = $state('');
  
  let errorMsg = $state('');
  let successMsg = $state('');

  // Scanner modal states
  let showScanner = $state(false);
  let scannerLoading = $state(false);
  let scannerResults = $state<any[]>([]);

  // Citation ledger. Status is owned by custom-police; the client only
  // renders what getMyCitations returned and re-reads after a payment.
  type Citation = {
    id: number;
    amount: number;
    reason?: string;
    status?: string;
    plate?: string;
  };

  let citations = $state<Citation[]>([]);
  let citationsLoading = $state(false);
  let citationsError = $state('');
  let citationsNotice = $state('');
  let payingCitationId = $state<number | null>(null);

  const unpaidCitationCount = $derived(
    citations.filter(c => c.status === 'unpaid').length
  );

  const clearMessages = () => {
    errorMsg = '';
    successMsg = '';
  };

  const handleAction = async () => {
    clearMessages();
    const amountVal = parseFloat(amountInput);

    if (isNaN(amountVal) || amountVal <= 0) {
      errorMsg = 'Please enter a valid positive amount';
      return;
    }

    if (!transferTarget.trim()) {
      errorMsg = 'Please enter target phone number';
      return;
    }

    try {
      const res = await fetchNui('bankTransfer', {
        toPhoneNumber: transferTarget,
        amount: amountVal,
        reason: transferReason || 'Transfer from Mobile'
      });

      if (res.success) {
        playerData.update(pd => {
          pd.money = res.newBalances;
          return pd;
        });
        successMsg = res.message || 'Transfer completed!';
        amountInput = '';
        transferTarget = '';
        transferReason = '';
      } else {
        errorMsg = res.message || 'Failed to transfer';
      }
    } catch (err) {
      errorMsg = 'Transaction failed. Network error.';
    }
  };

  // Nearby Scanner function
  const scanNearbyCitizens = async () => {
    scannerLoading = true;
    showScanner = true;
    scannerResults = [];

    if (isBrowser()) {
      setTimeout(() => {
        scannerResults = [
          { id: 2, name: 'Sheriff Miller', phone: '1112223333' },
          { id: 5, name: 'Big Tony', phone: '9998887777' }
        ];
        scannerLoading = false;
      }, 800);
      return;
    }

    try {
      const results = await fetchNui<any[]>('getNearbyPlayers');
      scannerResults = results || [];
    } catch (err) {
      console.error(err);
    } finally {
      scannerLoading = false;
    }
  };

  const selectNearbyPlayer = (phone: string) => {
    transferTarget = phone;
    showScanner = false;
  };

  // Format currency helper
  const formatMoney = (val: number) => {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(val);
  };

  const citationReasonText = (code?: string) => {
    switch (code) {
      case 'insufficient_funds': return '银行余额不足 (Insufficient bank funds)';
      case 'not_owner': return '这不是你的罚单 (Not your citation)';
      case 'not_found': return '罚单不存在 (Citation not found)';
      case 'unavailable': return '罚单服务暂不可用 (Service unavailable)';
      default: return code ? code.replace(/_/g, ' ') : '未知错误 (Unknown error)';
    }
  };

  const loadCitations = async () => {
    citationsLoading = true;
    citationsError = '';
    try {
      const res = await fetchNui<any>('getMyCitations');
      if (res && res.success) {
        citations = Array.isArray(res.rows) ? res.rows : [];
      } else {
        citations = [];
        citationsError = citationReasonText(res && res.error);
      }
    } catch (err) {
      citations = [];
      citationsError = '无法加载罚单 (Failed to load citations)';
    } finally {
      citationsLoading = false;
    }
  };

  const payCitation = async (citation: Citation) => {
    citationsNotice = '';
    citationsError = '';
    payingCitationId = citation.id;
    try {
      const res = await fetchNui<any>('payCitation', { citationId: citation.id });
      if (res && res.success) {
        citationsNotice = `罚单 #${res.id ?? citation.id} 已支付 ${formatMoney(Number(res.amount ?? citation.amount) || 0)}`;
        await loadCitations();
      } else {
        citationsError = `支付失败：${citationReasonText(res && res.error)}`;
      }
    } catch (err) {
      citationsError = '支付失败：网络错误 (Network error)';
    } finally {
      payingCitationId = null;
    }
  };

  onMount(loadCitations);
</script>

<div class="banking-app app-transition">
  <!-- App Header -->
  <div class="app-header">
    <span class="app-title">🏦 Maze Bank Mobile</span>
  </div>

  <div class="app-content phone-scrollable">
    <!-- Premium Virtual Card Display -->
    <div class="card-display">
      <div class="card-chip"></div>
      <div class="card-brand">MAZE BANK</div>
      <div class="card-holder-row">
        <div class="holder-col">
          <span class="lbl">CARD HOLDER</span>
          <span class="val">{$playerData.name}</span>
        </div>
        <div class="holder-col text-right">
          <span class="lbl">CITIZEN ID</span>
          <span class="val">{$playerData.citizenid}</span>
        </div>
      </div>
      <div class="card-balance-row">
        <span class="lbl">BANK BALANCE</span>
        <span class="balance-val">{formatMoney($playerData.money.bank || 0)}</span>
      </div>
    </div>

    <!-- Quick Pocket Cash Display -->
    <div class="cash-card glass-card">
      <span class="cash-lbl">💵 Cash in Pocket</span>
      <span class="cash-val">{formatMoney($playerData.money.cash || 0)}</span>
    </div>

    <!-- My Citations (罚单) -->
    <div class="citations-card glass-card">
      <div class="form-header-title citations-title">
        <span>我的罚单 (MY CITATIONS)</span>
        {#if unpaidCitationCount > 0}
          <span class="citations-count">{unpaidCitationCount} 未支付</span>
        {/if}
      </div>

      {#if citationsNotice}
        <div class="success-banner">{citationsNotice}</div>
      {/if}
      {#if citationsError}
        <div class="err-banner">{citationsError}</div>
      {/if}

      {#if citationsLoading}
        <div class="citations-empty">加载中… (Loading citations)</div>
      {:else if citations.length === 0}
        <div class="citations-empty">没有罚单记录 (No citations on file)</div>
      {:else}
        <div class="citation-list">
          {#each citations as citation (citation.id)}
            <div class="citation-item">
              <div class="citation-info">
                <div class="citation-line">
                  <span class="citation-id">#{citation.id}</span>
                  <span class="citation-amount">{formatMoney(Number(citation.amount) || 0)}</span>
                </div>
                <span class="citation-reason">{citation.reason || '未提供原因 (No reason provided)'}</span>
              </div>
              <div class="citation-actions">
                <span class="citation-status {citation.status || 'unknown'}">
                  {citation.status === 'unpaid' ? 'UNPAID' : (citation.status || 'UNKNOWN')}
                </span>
                {#if citation.status === 'unpaid'}
                  <button
                    class="phone-btn citation-pay-btn"
                    onclick={() => payCitation(citation)}
                    disabled={payingCitationId === citation.id}
                  >
                    {payingCitationId === citation.id ? '支付中…' : '支付'}
                  </button>
                {/if}
              </div>
            </div>
          {/each}
        </div>
      {/if}
    </div>

    <!-- Quick Payment Scan Row -->
    <button class="phone-btn scan-btn" onclick={scanNearbyCitizens}>
      📶 Scan Nearby Citizens (面对面付款)
    </button>

    <!-- Action Form -->
    <div class="action-form glass-card">
      <div class="form-header-title">WIRE TRANSFER (转账汇款)</div>
      
      {#if errorMsg}
        <div class="err-banner">{errorMsg}</div>
      {/if}
      {#if successMsg}
        <div class="success-banner">{successMsg}</div>
      {/if}

      <div class="form-group">
        <label for="amountInput">Amount to Wire</label>
        <div class="input-with-symbol">
          <span class="currency-symbol">$</span>
          <input id="amountInput" type="number" class="phone-input amount-input" placeholder="e.g. 500" bind:value={amountInput} />
        </div>
      </div>

      <div class="form-group">
        <label for="targetInput">Target Phone Number</label>
        <input id="targetInput" type="text" class="phone-input" placeholder="e.g. 1112223333" bind:value={transferTarget} />
      </div>

      <div class="form-group">
        <label for="reasonInput">Reference Memo (Optional)</label>
        <input id="reasonInput" type="text" class="phone-input" placeholder="Rent payment, food, etc." bind:value={transferReason} />
      </div>

      <button class="phone-btn action-submit-btn" onclick={handleAction}>
        Confirm Wire Transfer
      </button>
    </div>
  </div>

  <!-- Scanner Modal Overlay -->
  {#if showScanner}
    <div class="scanner-modal glass-effect app-transition">
      <div class="modal-header">
        <span>📶 Scanning Citizens</span>
        <button class="close-modal-btn" onclick={() => showScanner = false}>✕</button>
      </div>

      <div class="modal-body">
        {#if scannerLoading}
          <div class="scanner-loading">
            <div class="radar-ping"></div>
            <span>Paging nearby signals...</span>
          </div>
        {:else if scannerResults.length === 0}
          <div class="scanner-empty">
            <span>📡</span>
            <p>No active citizens found in 8 meter radius.</p>
          </div>
        {:else}
          <div class="scanner-list">
            {#each scannerResults as p}
              <button class="scanner-item glass-card" onclick={() => selectNearbyPlayer(p.phone)}>
                <span class="item-name">{p.name}</span>
                <span class="item-phone">({p.phone})</span>
              </button>
            {/each}
          </div>
        {/if}
      </div>
    </div>
  {/if}
</div>

<style>
  .banking-app {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: #09090b;
    position: relative;
  }

  .app-header {
    height: 55px;
    display: flex;
    align-items: center;
    padding: 0 18px;
    border-bottom: 1px solid #1f1f23;
  }

  .app-title {
    font-size: 18px;
    font-weight: 700;
  }

  .app-content {
    flex: 1;
    overflow-y: auto;
    padding: 14px 16px;
    padding-bottom: 24px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  /* Premium Card Design */
  .card-display {
    position: relative;
    height: 160px;
    background: linear-gradient(135deg, #1e0b36 0%, #0f051c 50%, #020005 100%);
    border: 1px solid rgba(138, 43, 226, 0.35);
    border-radius: 20px;
    padding: 16px;
    box-sizing: border-box;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    box-shadow: 0 10px 20px rgba(0, 0, 0, 0.3), inset 0 1px 1px rgba(255, 255, 255, 0.1);
  }

  .card-chip {
    width: 32px;
    height: 24px;
    background: linear-gradient(135deg, #e5c060 0%, #b8860b 100%);
    border-radius: 4px;
    box-shadow: inset 0 1px 2px rgba(255,255,255,0.4);
  }

  .card-brand {
    position: absolute;
    top: 16px;
    right: 16px;
    font-size: 13.5px;
    font-weight: 800;
    letter-spacing: 1.5px;
    color: #e54444; /* Maze bank red */
    text-shadow: 0 1px 3px rgba(0,0,0,0.5);
  }

  .card-holder-row {
    display: flex;
    justify-content: space-between;
    margin-top: 10px;
  }

  .holder-col {
    display: flex;
    flex-direction: column;
  }

  .text-right {
    text-align: right;
  }

  .lbl {
    font-size: 8px;
    color: #888;
    letter-spacing: 0.8px;
  }

  .val {
    font-size: 12.5px;
    font-weight: 600;
    margin-top: 2px;
    letter-spacing: 0.2px;
  }

  .card-balance-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-top: 1px solid rgba(255, 255, 255, 0.08);
    padding-top: 10px;
    margin-top: 4px;
  }

  .balance-val {
    font-size: 20px;
    font-weight: 800;
    letter-spacing: -0.5px;
    background: linear-gradient(135deg, #ffffff 0%, #a855f7 100%);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
  }

  /* Cash Card Info */
  .cash-card {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 16px;
  }

  .cash-lbl {
    font-size: 13px;
    color: #bbb;
    font-weight: 500;
  }

  .cash-val {
    font-size: 15px;
    font-weight: 700;
    color: #22c55e;
  }

  /* My Citations */
  .citations-card {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .citations-title {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 0;
  }

  .citations-count {
    font-size: 9.5px;
    font-weight: 700;
    color: #ef4444;
    background: rgba(239, 68, 68, 0.12);
    border: 1px solid rgba(239, 68, 68, 0.25);
    border-radius: 8px;
    padding: 2px 8px;
    letter-spacing: 0.3px;
  }

  .citations-empty {
    font-size: 12px;
    color: #71717a;
    text-align: center;
    padding: 8px 0;
  }

  .citation-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .citation-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 10px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 12px;
    padding: 10px 12px;
  }

  .citation-info {
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }

  .citation-line {
    display: flex;
    align-items: baseline;
    gap: 8px;
  }

  .citation-id {
    font-size: 13px;
    font-weight: 800;
    color: hsl(var(--phone-accent));
  }

  .citation-amount {
    font-size: 13px;
    font-weight: 700;
    color: #fbbf24;
  }

  .citation-reason {
    font-size: 11px;
    color: #a1a1aa;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .citation-actions {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 6px;
    flex-shrink: 0;
  }

  .citation-status {
    font-size: 9px;
    font-weight: 800;
    letter-spacing: 0.6px;
    padding: 2px 7px;
    border-radius: 6px;
    color: #a1a1aa;
    background: rgba(255, 255, 255, 0.06);
  }

  .citation-status.unpaid {
    color: #ef4444;
    background: rgba(239, 68, 68, 0.12);
    border: 1px solid rgba(239, 68, 68, 0.3);
  }

  .citation-status.paid {
    color: #22c55e;
    background: rgba(34, 197, 94, 0.12);
    border: 1px solid rgba(34, 197, 94, 0.3);
  }

  .citation-pay-btn {
    padding: 6px 14px;
    font-size: 11.5px;
  }

  .citation-pay-btn:disabled {
    opacity: 0.55;
    cursor: wait;
  }

  .scan-btn {
    background: rgba(138, 43, 226, 0.15);
    border: 1px solid rgba(138, 43, 226, 0.3);
    color: #c084fc;
    padding: 12px;
    font-size: 12.5px;
  }

  .scan-btn:hover {
    background: rgba(138, 43, 226, 0.25);
  }

  /* Action Form Card */
  .action-form {
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .form-header-title {
    font-size: 11.5px;
    font-weight: bold;
    color: #bbb;
    letter-spacing: 0.8px;
    border-bottom: 1px solid rgba(255,255,255,0.06);
    padding-bottom: 6px;
    margin-bottom: 4px;
  }

  .err-banner {
    background: rgba(239, 68, 68, 0.15);
    border: 1px solid rgba(239, 68, 68, 0.3);
    color: #ef4444;
    padding: 8px 12px;
    border-radius: 8px;
    font-size: 12px;
    font-weight: 600;
  }

  .success-banner {
    background: rgba(34, 197, 94, 0.15);
    border: 1px solid rgba(34, 197, 94, 0.3);
    color: #22c55e;
    padding: 8px 12px;
    border-radius: 8px;
    font-size: 12px;
    font-weight: 600;
  }

  .form-group {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .form-group label {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: #999;
  }

  .input-with-symbol {
    position: relative;
    display: flex;
    align-items: center;
  }

  .currency-symbol {
    position: absolute;
    left: 14px;
    font-size: 16px;
    font-weight: 700;
    color: hsl(var(--phone-accent));
  }

  .amount-input {
    width: 100%;
    padding-left: 28px;
    box-sizing: border-box;
    font-size: 16px;
    font-weight: 700;
  }

  .phone-input {
    box-sizing: border-box;
    width: 100%;
  }

  .action-submit-btn {
    width: 100%;
    margin-top: 8px;
    padding: 12px 0;
  }

  /* Scanner Modal Overlay */
  .scanner-modal {
    position: absolute;
    inset: 0;
    z-index: 1000;
    display: flex;
    flex-direction: column;
    padding: 20px;
    padding-top: 40px;
  }

  .modal-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 1px solid rgba(255,255,255,0.08);
    padding-bottom: 10px;
    margin-bottom: 15px;
  }

  .modal-header span {
    font-size: 15px;
    font-weight: bold;
    color: #c084fc;
  }

  .close-modal-btn {
    background: transparent;
    border: none;
    color: #a1a1aa;
    font-size: 16px;
    cursor: pointer;
    outline: none;
  }

  .modal-body {
    flex: 1;
    display: flex;
    flex-direction: column;
    overflow-y: auto;
  }

  .scanner-loading {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 16px;
    color: #a1a1aa;
    font-size: 13px;
  }

  .radar-ping {
    width: 60px;
    height: 60px;
    border: 3px solid rgba(192, 132, 252, 0.4);
    border-radius: 50%;
    animation: radar 1.2s infinite;
  }

  @keyframes radar {
    0% { transform: scale(0.6); opacity: 1; }
    100% { transform: scale(1.3); opacity: 0; }
  }

  .scanner-empty {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    color: #71717a;
    text-align: center;
    padding: 20px;
  }

  .scanner-empty span {
    font-size: 32px;
  }

  .scanner-empty p {
    font-size: 12px;
    margin: 0;
  }

  .scanner-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .scanner-item {
    background: rgba(255,255,255,0.04);
    border: 1px solid rgba(255,255,255,0.07);
    padding: 14px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    text-align: left;
    cursor: pointer;
    width: 100%;
    outline: none;
  }

  .scanner-item:hover {
    background: rgba(138, 43, 226, 0.08);
    border-color: rgba(138, 43, 226, 0.3);
  }

  .item-name {
    font-size: 13.5px;
    font-weight: 700;
  }

  .item-phone {
    font-size: 11px;
    color: #a1a1aa;
    font-weight: bold;
  }
</style>
