<script lang="ts">
  import { fetchNui } from '../../utils/nui';
  import { jobBoardTasks } from '../../stores/phone';

  let titleInput = $state('');
  let descInput = $state('');
  let rewardInput = $state('');

  let successMsg = $state('');
  let errorMsg = $state('');
  let isSubmitting = $state(false);

  const handlePostProject = async () => {
    successMsg = '';
    errorMsg = '';

    if (!titleInput.trim() || !descInput.trim() || !rewardInput.trim()) {
      errorMsg = 'All fields are required';
      return;
    }

    const rewardNum = parseFloat(rewardInput);
    if (isNaN(rewardNum) || rewardNum <= 0) {
      errorMsg = 'Reward must be a positive number';
      return;
    }

    isSubmitting = true;

    try {
      const res = await fetchNui('postJobBoardTask', {
        title: titleInput,
        description: descInput,
        reward: rewardNum
      });

      if (res.success) {
        successMsg = res.message || 'Urban Project posted successfully!';
        
        // Sync locally (normally server would push but this keeps Svelte preview in sync)
        if (res.job) {
          jobBoardTasks.update(list => [res.job, ...list]);
        }

        titleInput = '';
        descInput = '';
        rewardInput = '';
      } else {
        errorMsg = res.message || 'Failed to post project';
      }
    } catch (err) {
      errorMsg = 'Network error';
    } finally {
      isSubmitting = false;
    }
  };
</script>

<div class="mayor-app app-transition">
  <div class="app-header">
    <span class="app-title">🏛️ Executive Terminal</span>
  </div>

  <div class="app-content phone-scrollable">
    <div class="leader-banner glass-card">
      <span class="banner-title">Mayor Dashboard</span>
      <span class="banner-sub">City Infrastructure Management</span>
    </div>

    <!-- Post Project Form -->
    <div class="action-card glass-card">
      <h3>Create City Project</h3>
      {#if successMsg}
        <div class="success-banner">{successMsg}</div>
      {/if}
      {#if errorMsg}
        <div class="err-banner">{errorMsg}</div>
      {/if}

      <div class="form-group">
        <label for="projectTitle">Project Title</label>
        <input id="projectTitle" type="text" class="phone-input" placeholder="e.g. City Hall Expansion" bind:value={titleInput} />
      </div>

      <div class="form-group">
        <label for="projectDesc">Project Description & Guidelines</label>
        <textarea id="projectDesc" class="phone-input textarea-input" placeholder="Describe the cargo, routes, and tasks required for completion..." bind:value={descInput}></textarea>
      </div>

      <div class="form-group">
        <label for="projectReward">Payout Budget</label>
        <input id="projectReward" type="number" class="phone-input" placeholder="e.g. 2500" bind:value={rewardInput} />
      </div>

      <button class="phone-btn submit-btn" disabled={isSubmitting} onclick={handlePostProject}>
        {isSubmitting ? 'Posting...' : 'Publish Public Works'}
      </button>
    </div>
  </div>
</div>

<style>
  .mayor-app {
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
    background: linear-gradient(135deg, #1e3a8a 0%, #0f172a 100%);
    border-color: rgba(59, 130, 246, 0.3);
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
    color: #94a3b8;
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
