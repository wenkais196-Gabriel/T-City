<script lang="ts">
  import { jobBoardTasks, playerData } from '../stores/phone';
  import { fetchNui } from '../utils/nui';

  let successMsg = $state('');
  let errorMsg = $state('');
  let acceptingId = $state<number | null>(null);

  const clearMessages = () => {
    successMsg = '';
    errorMsg = '';
  };

  const handleAcceptJob = async (id: number) => {
    clearMessages();
    acceptingId = id;

    try {
      const res = await fetchNui('acceptJobBoardTask', { id });
      if (res.success) {
        // Sync status locally
        jobBoardTasks.update(list => list.map(j => {
          if (j.id === id) {
            return { ...j, status: 'taken', taken_by: $playerData.citizenid };
          }
          return j;
        }));
        successMsg = res.message || 'Job accepted! GPS routing activated.';
      } else {
        errorMsg = res.message || 'Failed to accept job';
      }
    } catch (err) {
      errorMsg = 'Failed to accept job. Network error.';
    } finally {
      acceptingId = null;
    }
  };

  const formatMoney = (val: number) => {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(val);
  };
</script>

<div class="jobboard-app app-transition">
  <!-- App Header -->
  <div class="app-header">
    <span class="app-title">📋 Job Board</span>
  </div>

  <div class="app-content phone-scrollable">
    {#if successMsg}
      <div class="success-banner">{successMsg}</div>
    {/if}
    {#if errorMsg}
      <div class="err-banner">{errorMsg}</div>
    {/if}

    <div class="info-tag glass-card">
      💡 Accept public works to earn pocket rewards. Drive safe!
    </div>

    <!-- Task List -->
    {#if $jobBoardTasks.length === 0}
      <div class="empty-state">No active projects available</div>
    {:else}
      <div class="tasks-list">
        {#each $jobBoardTasks as job (job.id)}
          <div class="task-card glass-card {job.status}">
            <div class="task-header">
              <span class="task-tag">{job.status.toUpperCase()}</span>
              <span class="task-reward">{formatMoney(job.reward)}</span>
            </div>
            <span class="task-title">{job.title}</span>
            <p class="task-desc">{job.description}</p>
            
            <div class="task-actions">
              {#if job.status === 'open'}
                <button 
                  class="phone-btn accept-btn" 
                  disabled={acceptingId !== null} 
                  onclick={() => handleAcceptJob(job.id)}
                >
                  {acceptingId === job.id ? 'Accepting...' : 'Accept Project'}
                </button>
              {:else if job.status === 'taken'}
                {#if job.taken_by === $playerData.citizenid}
                  <div class="status-indicator taken-by-me">GPS Active • En Route</div>
                {:else}
                  <div class="status-indicator taken-by-other">Taken by another citizen</div>
                {/if}
              {:else if job.status === 'completed'}
                <div class="status-indicator completed">Project Completed ✓</div>
              {/if}
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .jobboard-app {
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
    font-size: 18px;
    font-weight: 700;
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

  .info-tag {
    padding: 10px 14px;
    font-size: 11.5px;
    color: #bbb;
    line-height: 1.4;
    border-left: 3.5px solid hsl(var(--phone-accent));
    background: rgba(138, 43, 226, 0.04);
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

  /* List */
  .tasks-list {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .task-card {
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.05);
  }

  .task-card.taken {
    opacity: 0.8;
  }

  .task-card.completed {
    opacity: 0.6;
    border-color: rgba(34, 197, 94, 0.2);
  }

  .task-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .task-tag {
    font-size: 8px;
    font-weight: 800;
    letter-spacing: 0.8px;
    padding: 3px 8px;
    border-radius: 4px;
    background: rgba(255, 255, 255, 0.08);
  }

  .open .task-tag {
    background: rgba(245, 158, 11, 0.15);
    color: #f59e0b;
  }

  .taken .task-tag {
    background: rgba(59, 130, 246, 0.15);
    color: #3b82f6;
  }

  .completed .task-tag {
    background: rgba(34, 197, 94, 0.15);
    color: #22c55e;
  }

  .task-reward {
    font-size: 15px;
    font-weight: 700;
    color: #22c55e;
  }

  .task-title {
    font-size: 14.5px;
    font-weight: 700;
  }

  .task-desc {
    margin: 0;
    font-size: 12px;
    line-height: 1.45;
    color: #999;
  }

  .task-actions {
    margin-top: 6px;
  }

  .accept-btn {
    width: 100%;
    padding: 9px 0;
    font-size: 12.5px;
  }

  .status-indicator {
    padding: 8px 12px;
    border-radius: 10px;
    font-size: 12px;
    font-weight: 600;
    text-align: center;
    border: 1px solid rgba(255, 255, 255, 0.05);
  }

  .taken-by-me {
    background: rgba(59, 130, 246, 0.12);
    color: #3b82f6;
    border-color: rgba(59, 130, 246, 0.2);
  }

  .taken-by-other {
    background: rgba(255, 255, 255, 0.03);
    color: #666;
  }

  .completed {
    background: rgba(34, 197, 94, 0.1);
    color: #22c55e;
    border-color: rgba(34, 197, 94, 0.2);
  }

  .empty-state {
    text-align: center;
    padding: 40px 10px;
    color: #555;
    font-size: 13.5px;
  }
</style>
