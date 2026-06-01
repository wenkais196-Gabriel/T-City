<script lang="ts">
  import { fetchNui } from '../../utils/nui';
  import { factionMessages } from '../../stores/phone';

  let objectiveInput = $state('');
  let quotaInput = $state('');

  let successMsg = $state('');
  let errorMsg = $state('');
  let isSending = $state(false);

  const handleSendObjective = async () => {
    successMsg = '';
    errorMsg = '';

    if (!objectiveInput.trim()) {
      errorMsg = 'Objective details are required';
      return;
    }

    isSending = true;

    try {
      const res = await fetchNui('sendGangObjective', {
        objective: objectiveInput,
        quota: quotaInput ? parseFloat(quotaInput) : 0
      });

      if (res.success) {
        successMsg = 'Secure objective broadcast successfully!';
        
        // Auto add message to faction radio in local preview
        if (res.message) {
          factionMessages.update(list => [...list, res.message]);
        } else {
          factionMessages.update(list => [...list, {
            sender: 'Godfather (Secure Encryption)',
            content: `👁️ [OBJECTIVE DISPATCH] ${objectiveInput}${quotaInput ? ` (Cash Quota Target: $${quotaInput})` : ''}`,
            time: Math.floor(Date.now() / 1000)
          }]);
        }

        objectiveInput = '';
        quotaInput = '';
      } else {
        errorMsg = res.message || 'Failed to dispatch gang objective';
      }
    } catch (err) {
      errorMsg = 'Network error';
    } finally {
      isSending = false;
    }
  };
</script>

<div class="gangboss-app app-transition">
  <div class="app-header">
    <span class="app-title">👁️ Underworld Command</span>
  </div>

  <div class="app-content phone-scrollable">
    <div class="leader-banner glass-card">
      <span class="banner-title">Godfather Terminal</span>
      <span class="banner-sub">Secure Encrypted Syndicate Frequency</span>
    </div>

    <!-- Dispatch Objective Form -->
    <div class="action-card glass-card">
      <h3>Syndicate Operations</h3>
      {#if successMsg}
        <div class="success-banner">{successMsg}</div>
      {/if}
      {#if errorMsg}
        <div class="err-banner">{errorMsg}</div>
      {/if}

      <div class="form-group">
        <label for="objectiveDetails">Syndicate Directive</label>
        <textarea id="objectiveDetails" class="phone-input textarea-input" placeholder="Enter target convenience store, drug deal pickup, or territorial defense orders..." bind:value={objectiveInput}></textarea>
      </div>

      <div class="form-group">
        <label for="cashQuota">Cash Quota Target (Optional)</label>
        <input id="cashQuota" type="number" class="phone-input" placeholder="e.g. 5000" bind:value={quotaInput} />
      </div>

      <button class="phone-btn submit-btn" disabled={isSending} onclick={handleSendObjective}>
        {isSending ? 'Transmitting...' : 'Transmit Encrypted Directive'}
      </button>
    </div>
  </div>
</div>

<style>
  .gangboss-app {
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
    background: linear-gradient(135deg, #7f1d1d 0%, #180000 100%);
    border-color: rgba(239, 68, 68, 0.3);
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
    color: #fca5a5;
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
