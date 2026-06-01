<script lang="ts">
  import { fetchNui } from '../../utils/nui';
  import { factionMessages } from '../../stores/phone';

  let zoneInput = $state('Downtown LS');
  let detailsInput = $state('');

  let successMsg = $state('');
  let errorMsg = $state('');
  let isSending = $state(false);

  const handleSendDispatch = async () => {
    successMsg = '';
    errorMsg = '';

    if (!detailsInput.trim()) {
      errorMsg = 'Patrol instructions are required';
      return;
    }

    isSending = true;

    try {
      const res = await fetchNui('sendSheriffPatrolOrder', {
        zone: zoneInput,
        details: detailsInput
      });

      if (res.success) {
        successMsg = 'Patrol order broadcast successfully! GPS waypoint dispatched.';
        
        // Auto add message to faction radio in local preview
        if (res.message) {
          factionMessages.update(list => [...list, res.message]);
        } else {
          factionMessages.update(list => [...list, {
            sender: 'Sheriff (Tactical Command)',
            content: `🚨 [PATROL ORDER] Active patrol ordered in ${zoneInput}: ${detailsInput}`,
            time: Math.floor(Date.now() / 1000)
          }]);
        }

        detailsInput = '';
      } else {
        errorMsg = res.message || 'Failed to dispatch patrol order';
      }
    } catch (err) {
      errorMsg = 'Network error';
    } finally {
      isSending = false;
    }
  };
</script>

<div class="sheriff-app app-transition">
  <div class="app-header">
    <span class="app-title">👮 Tactical Command</span>
  </div>

  <div class="app-content phone-scrollable">
    <div class="leader-banner glass-card">
      <span class="banner-title">Sheriff Terminal</span>
      <span class="banner-sub">LSPD / BCSO On-Duty Dispatch</span>
    </div>

    <!-- Dispatch Patrol Form -->
    <div class="action-card glass-card">
      <h3>Active Patrol Dispatch</h3>
      {#if successMsg}
        <div class="success-banner">{successMsg}</div>
      {/if}
      {#if errorMsg}
        <div class="err-banner">{errorMsg}</div>
      {/if}

      <div class="form-group">
        <label for="patrolZone">Target Patrol Zone</label>
        <select id="patrolZone" class="phone-input select-input" bind:value={zoneInput}>
          <option value="Downtown LS">Downtown LS (Mission Row)</option>
          <option value="Vinewood Hills">Vinewood Hills (Rich Areas)</option>
          <option value="Sandy Shores">Sandy Shores (County Patrol)</option>
          <option value="Paleto Bay">Paleto Bay (Highway Control)</option>
        </select>
      </div>

      <div class="form-group">
        <label for="patrolDetails">Dispatch Instructions</label>
        <textarea id="patrolDetails" class="phone-input textarea-input" placeholder="Enter target objective, speed traps, wanted priority, or checkpoint details..." bind:value={detailsInput}></textarea>
      </div>

      <button class="phone-btn submit-btn" disabled={isSending} onclick={handleSendDispatch}>
        {isSending ? 'Dispatching...' : 'Dispatch Tactical Order'}
      </button>
    </div>
  </div>
</div>

<style>
  .sheriff-app {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: #09090b;
  }

  .app-header {
    height: 55px;
    display: flex;
    align-items: center;
    padding: 0 18px;
    border-bottom: 1px solid #1f1f23;
  }

  .app-title {
    font-size: 14.5px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .app-content {
    flex: 1;
    overflow-y: auto;
    padding: 12px 16px;
    padding-bottom: 24px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .leader-banner {
    padding: 14px;
    background: linear-gradient(135deg, #1e3a8a 0%, #1e1b4b 100%);
    border-color: rgba(99, 102, 241, 0.3);
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  .banner-title {
    font-size: 15px;
    font-weight: 800;
    color: #fff;
    letter-spacing: 0.5px;
  }

  .banner-sub {
    font-size: 11px;
    color: #a5b4fc;
  }

  /* Form */
  .action-card {
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .action-card h3 {
    margin: 0;
    font-size: 14.5px;
    font-weight: 700;
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

  .err-banner {
    background: rgba(239, 68, 68, 0.15);
    border: 1px solid rgba(239, 68, 68, 0.3);
    color: #ef4444;
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

  .select-input {
    appearance: none;
    -webkit-appearance: none;
    background-image: url("data:image/svg+xml;utf8,<svg fill='white' height='24' viewBox='0 0 24 24' width='24' xmlns='http://www.w3.org/2000/svg'><path d='M7 10l5 5 5-5z'/><path d='M0 0h24v24H0z' fill='none'/></svg>");
    background-repeat: no-repeat;
    background-position: right 10px center;
    background-size: 16px;
    padding-right: 32px;
  }

  .textarea-input {
    height: 70px;
    resize: none;
    font-family: inherit;
    line-height: 1.45;
  }

  .phone-input {
    box-sizing: border-box;
    width: 100%;
  }

  .submit-btn {
    width: 100%;
    margin-top: 8px;
    padding: 11px 0;
  }
</style>
