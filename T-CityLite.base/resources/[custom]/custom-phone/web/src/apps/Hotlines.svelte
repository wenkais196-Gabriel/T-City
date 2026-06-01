<script lang="ts">
  import { onMount } from 'svelte';
  import { fetchNui, isBrowser } from '../utils/nui';

  // Hotline categories config list
  let hotlineDirectories = $state<any[]>([
    { name: '🚨 Police Dispatch Emergency', job: 'police', label: 'Emergency Transfer', phone: '911', icon: '👮', agents: 0 },
    { name: '🚑 Pillbox Medical Emergency', job: 'ambulance', label: 'EMS Dispatch', phone: '912', icon: '🏥', agents: 0 },
    { name: '🔧 LS Auto Repair Services', job: 'mechanic', label: 'Mechanical Repair', phone: '444-TOW', icon: '⚙️', agents: 0 },
    { name: '🏛️ Municipal Public Services', job: 'mayor', label: 'Government Line', phone: '311-GOV', icon: '🏛️', agents: 0 },
    { name: '🏦 Maze Bank Financial Line', job: 'bank', label: 'Finance & Loan Desk', phone: '555-MAZE', icon: '🏦', agents: 0 }
  ]);

  let isCalling = $state(false);
  let callerJob = $state('');
  let callStatus = $state('Ringing...');
  let callerName = $state('');
  
  // Interactive Voice Response (IVR) panel states
  let showIvr = $state(false);
  let ivrTitle = $state('Interactive Voice Response');
  let ivrContent = $state('Fetching service details...');
  let isLoadingIvr = $state(false);

  onMount(async () => {
    // Dynamic Query for Active Workers (🟢 Agent presence checker)
    for (let i = 0; i < hotlineDirectories.length; i++) {
      const entry = hotlineDirectories[i];
      if (isBrowser()) {
        entry.agents = entry.job === 'mechanic' ? 0 : Math.floor(Math.random() * 3);
        continue;
      }
      try {
        const count = await fetchNui<number>('getHotlineStatus', { jobType: entry.job });
        entry.agents = count || 0;
      } catch (err) {
        console.error(err);
      }
    }
  });

  const triggerCall = async (entry: any) => {
    isCalling = true;
    callerJob = entry.job;
    callerName = entry.name;
    callStatus = 'Connecting to switchboard...';
    showIvr = false;

    if (isBrowser()) {
      setTimeout(() => {
        if (entry.agents > 0) {
          callStatus = 'Line Inbound Connected';
        } else {
          callStatus = 'Re-routed to IVR Auto-Desk';
          setTimeout(() => {
            enterIvrMode(entry.job);
          }, 1500);
        }
      }, 1500);
      return;
    }

    try {
      const res = await fetchNui<any>('triggerHotlineCall', { jobType: entry.job });
      if (res.success) {
        if (res.active) {
          callStatus = 'Ringing Agent Desk...';
        } else {
          callStatus = 'Rerouting to IVR Automated Service...';
          setTimeout(() => {
            enterIvrMode(entry.job);
          }, 1500);
        }
      } else {
        callStatus = 'Call failed. Busy tone.';
      }
    } catch (err) {
      callStatus = 'Network error.';
    }
  };

  const enterIvrMode = (job: string) => {
    showIvr = true;
    ivrTitle = `${callerName} Automated Helpdesk`;
    
    if (job === 'police' || job === 'ambulance') {
      ivrContent = 'Automated Dispatch: Emergency lines are currently busy. Local authorities have been paged. Please wait or call 911 again in emergency.';
    } else if (job === 'mechanic') {
      ivrContent = 'Automated Tow Services: No on-duty mechanics are online. Would you like to request an AI Tow Flatbed Truck to tow your current vehicle to the nearest impound? (Fee: $500)';
    } else if (job === 'mayor') {
      ivrContent = 'Automated Cityhall Line: Welcome to Government Automated Desk. Please select from below to query city parameters.';
    } else if (job === 'bank') {
      ivrContent = 'Maze Bank Auto-Desk: Base Mortgage Lending Rate: 4.8% APR | Inbound deposits are subject to 0.1% processing transaction taxes.';
    }
  };

  const executeIvrAction = async (action: string) => {
    isLoadingIvr = true;
    ivrContent = 'Processing transaction query...';

    if (isBrowser()) {
      setTimeout(() => {
        isLoadingIvr = false;
        if (action === 'economy') {
          ivrContent = 'QUERY STATUS: Wage Multiplier active: 1.0x. Inflation margin: Stable.';
        } else if (action === 'licenses') {
          ivrContent = 'CERTIFIED RETRIEVAL: Active Licenses: DRIVER, WEAPON';
        } else if (action === 'aitow') {
          ivrContent = 'AI TOWING: Flatbed dispatching active. Truck en-route to your vehicle. $500 debited from checking account.';
        }
      }, 1200);
      return;
    }

    try {
      if (action === 'aitow') {
        // Trigger server side towing deduction
        const res = await fetchNui('bankWithdraw', { amount: 500 });
        if (res.success) {
          ivrContent = 'AI Tow Truck has been paged and is heading to your GPS coordinates. $500 debited.';
        } else {
          ivrContent = 'Transaction failed. Insufficient funds in Bank account to pay AI dispatch fee.';
        }
      } else {
        const data = await fetchNui<any>('queryAutomatedIvr', { actionType: action });
        if (data) {
          ivrContent = `${data.title}: ${data.info}`;
        } else {
          ivrContent = 'No data paged from government databases.';
        }
      }
    } catch (err) {
      ivrContent = 'Failed to sync IVR databases.';
    } finally {
      isLoadingIvr = false;
    }
  };

  const hangUp = () => {
    isCalling = false;
    showIvr = false;
  };
</script>

<div class="hotlines-app app-transition">
  <!-- App Header -->
  <div class="app-header">
    <span class="app-title">📞 Service Hotlines</span>
  </div>

  <div class="app-content phone-scrollable">
    {#if !isCalling}
      <!-- Directory List -->
      <div class="directory-list">
        {#each hotlineDirectories as dir}
          <div class="hotline-card glass-card">
            <div class="hotline-left">
              <span class="hotline-icon">{dir.icon}</span>
              <div class="hotline-info">
                <span class="hotline-name">{dir.name}</span>
                <span class="hotline-phone">Dial: {dir.phone}</span>
                <span class="agent-badge" style="color: {dir.agents > 0 ? '#22c55e' : '#71717a'};">
                  {dir.agents > 0 ? `🟢 ${dir.agents} Agent(s) Active` : '🔴 Automated IVR Only'}
                </span>
              </div>
            </div>
            
            <button class="call-btn-icon dial-call-btn" onclick={() => triggerCall(dir)} aria-label={`Call ${dir.name}`}>📞</button>
          </div>
        {/each}
      </div>
    {:else}
      <!-- Active Call Panel -->
      <div class="active-call-panel">
        {#if !showIvr}
          <!-- In-Call Ringing screen -->
          <div class="ivr-loading-screen">
            <div class="ringing-pulse">📞</div>
            <span class="calling-name">{callerName}</span>
            <span class="calling-status">{callStatus}</span>
          </div>
        {:else}
          <!-- IVR Automated Helpdesk Screen -->
          <div class="ivr-interactive-screen glass-card app-transition">
            <span class="ivr-title-header">{ivrTitle}</span>
            
            <div class="ivr-speech-bubble">
              {#if isLoadingIvr}
                <div class="small-spinner"></div>
              {/if}
              <p>{ivrContent}</p>
            </div>

            <!-- Contextual IVR buttons -->
            <div class="ivr-options-grid">
              {#if callerJob === 'mechanic'}
                <button class="phone-btn ivr-opt-btn" onclick={() => executeIvrAction('aitow')} disabled={isLoadingIvr}>🛠️ Summon AI Tow ($500)</button>
              {/if}

              {#if callerJob === 'mayor'}
                <button class="phone-btn ivr-opt-btn" onclick={() => executeIvrAction('economy')} disabled={isLoadingIvr}>📊 Economy Wage Index</button>
                <button class="phone-btn ivr-opt-btn" onclick={() => executeIvrAction('licenses')} disabled={isLoadingIvr}>🪪 Check My Licenses</button>
              {/if}

              {#if callerJob === 'bank'}
                <button class="phone-btn ivr-opt-btn" onclick={() => executeIvrAction('economy')} disabled={isLoadingIvr}>💵 Interest Rates</button>
              {/if}
            </div>
          </div>
        {/if}

        <button class="phone-btn hangup-btn" onclick={hangUp}>❌ Hang Up</button>
      </div>
    {/if}
  </div>
</div>

<style>
  .hotlines-app {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: #09090b;
    color: #fff;
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
  }

  .directory-list {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .hotline-card {
    padding: 14px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
  }

  .hotline-left {
    display: flex;
    align-items: center;
    gap: 12px;
    flex: 1;
  }

  .hotline-icon {
    font-size: 24px;
    width: 44px;
    height: 44px;
    background: rgba(255,255,255,0.03);
    border: 1px solid rgba(255,255,255,0.06);
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .hotline-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .hotline-name {
    font-size: 13.5px;
    font-weight: 700;
    letter-spacing: -0.1px;
  }

  .hotline-phone {
    font-size: 11px;
    color: #a1a1aa;
    font-weight: 500;
  }

  .agent-badge {
    font-size: 9.5px;
    font-weight: 800;
    letter-spacing: 0.2px;
    text-transform: uppercase;
    margin-top: 2px;
  }

  .call-btn-icon {
    width: 38px;
    height: 38px;
    border-radius: 50%;
    border: none;
    font-size: 16px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: transform 0.2s;
    outline: none;
    box-shadow: 0 4px 6px rgba(0,0,0,0.25);
  }

  .call-btn-icon:active {
    transform: scale(0.92);
  }

  .dial-call-btn {
    background: #22c55e;
    color: #fff;
  }

  /* Active Call Panel */
  .active-call-panel {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: space-between;
    padding: 30px 10px 40px 10px;
  }

  .ivr-loading-screen {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 15px;
    margin-top: 60px;
  }

  .ringing-pulse {
    width: 80px;
    height: 80px;
    background: #22c55e;
    border-radius: 50%;
    font-size: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    animation: pulse 1.5s infinite;
  }

  @keyframes pulse {
    0% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0.4); }
    70% { box-shadow: 0 0 0 15px rgba(34, 197, 94, 0); }
    100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0); }
  }

  .calling-name {
    font-size: 16px;
    font-weight: 800;
    text-align: center;
  }

  .calling-status {
    font-size: 12px;
    color: #a1a1aa;
    font-weight: 500;
  }

  /* IVR Screen */
  .ivr-interactive-screen {
    width: 100%;
    padding: 16px;
    box-sizing: border-box;
    display: flex;
    flex-direction: column;
    gap: 16px;
    margin-top: 10px;
  }

  .ivr-title-header {
    font-size: 14px;
    font-weight: 800;
    color: hsl(var(--phone-accent));
    border-bottom: 1px solid rgba(255,255,255,0.06);
    padding-bottom: 8px;
    text-align: center;
  }

  .ivr-speech-bubble {
    background: rgba(255,255,255,0.03);
    border: 1px solid rgba(255,255,255,0.05);
    border-radius: 12px;
    padding: 12px 14px;
    font-size: 12px;
    line-height: 1.5;
    color: #e4e4e7;
    position: relative;
    min-height: 50px;
    display: flex;
    align-items: center;
  }

  .ivr-speech-bubble p {
    margin: 0;
  }

  .small-spinner {
    position: absolute;
    right: 12px;
    top: 12px;
    width: 12px;
    height: 12px;
    border: 1.5px solid rgba(255,255,255,0.08);
    border-top-color: hsl(var(--phone-accent));
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  .ivr-options-grid {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .ivr-opt-btn {
    width: 100%;
    padding: 10px;
    font-size: 12px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.08);
  }

  .ivr-opt-btn:hover {
    background: rgba(255, 255, 255, 0.1);
  }

  .hangup-btn {
    background: #ef4444;
    width: 80%;
    padding: 12px 0;
  }
</style>
