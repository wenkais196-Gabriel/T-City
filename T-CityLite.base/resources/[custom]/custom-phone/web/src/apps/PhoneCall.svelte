<script lang="ts">
  import { playerData } from '../stores/phone';
  import { fetchNui } from '../utils/nui';
  
  let dialNumber = $state('');
  let isCalling = $state(false);
  let callStatus = $state('Dialing...');

  const appendNumber = (num: string) => {
    if (dialNumber.length < 15) {
      dialNumber += num;
    }
  };

  const deleteLast = () => {
    dialNumber = dialNumber.slice(0, -1);
  };

  const startCall = async () => {
    if (!dialNumber) return;
    isCalling = true;
    callStatus = 'Dialing...';
    
    // Simulate ringtone and mock connection after 2 seconds
    setTimeout(() => {
      callStatus = 'Connected';
    }, 2000);
  };

  const endCall = () => {
    isCalling = false;
    dialNumber = '';
  };
</script>

<div class="phone-call-app app-transition">
  <!-- App Header -->
  <div class="app-header">
    <span class="app-title">📞 Phone</span>
  </div>

  <div class="app-content phone-scrollable">
    {#if !isCalling}
      <!-- My Card Display -->
      <div class="my-card-header glass-card">
        <div class="my-avatar">👤</div>
        <div class="my-details">
          <span class="my-name">{$playerData.name}</span>
          <span class="my-phone">My Number: {$playerData.phone || '000000'}</span>
          <span class="my-cid">Citizen ID: {$playerData.citizenid || 'N/A'}</span>
        </div>
      </div>

      <!-- Dialer input -->
      <div class="dial-input-container">
        <input type="text" class="dial-display" bind:value={dialNumber} readonly placeholder="Enter number..." />
        {#if dialNumber}
          <button class="delete-btn" onclick={deleteLast} aria-label="Backspace">⌫</button>
        {/if}
      </div>

      <!-- Dial Keypad Grid -->
      <div class="dialpad-grid">
        {#each ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'] as key}
          <button class="dial-key" onclick={() => appendNumber(key)}>{key}</button>
        {/each}
      </div>

      <!-- Action call trigger -->
      {#if dialNumber}
        <div class="call-trigger-container">
          <button class="call-btn-trigger dial-call-btn" onclick={startCall} aria-label="Start Call">📞</button>
        </div>
      {/if}
    {:else}
      <!-- Active Call Screen Interface -->
      <div class="active-call-screen">
        <div class="calling-avatar">👤</div>
        <span class="calling-number">{dialNumber}</span>
        <span class="calling-status">{callStatus}</span>
        
        <div class="calling-timer">00:08</div>

        <!-- Call controls panel -->
        <button class="call-btn-trigger end-call-btn" onclick={endCall} aria-label="End Call">❌</button>
      </div>
    {/if}
  </div>
</div>

<style>
  .phone-call-app {
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
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 15px;
  }

  /* My Card */
  .my-card-header {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 12px 16px;
  }

  .my-avatar {
    width: 48px;
    height: 48px;
    background: linear-gradient(135deg, #27272a 0%, #18181b 100%);
    border: 1px solid rgba(255,255,255,0.08);
    font-size: 20px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .my-details {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .my-name {
    font-size: 14px;
    font-weight: 700;
  }

  .my-phone {
    font-size: 11px;
    color: #a1a1aa;
    font-weight: 500;
  }

  .my-cid {
    font-size: 9px;
    color: #71717a;
    font-weight: 600;
    letter-spacing: 0.5px;
  }

  /* Display */
  .dial-input-container {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    margin-top: 10px;
  }

  .dial-display {
    width: 100%;
    background: transparent;
    border: none;
    text-align: center;
    font-size: 26px;
    font-weight: 800;
    color: #fff;
    outline: none;
    letter-spacing: 1px;
  }

  .delete-btn {
    position: absolute;
    right: 15px;
    background: transparent;
    border: none;
    color: #a1a1aa;
    font-size: 18px;
    cursor: pointer;
    outline: none;
  }

  /* Dialer Grid */
  .dialpad-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    grid-gap: 16px;
    margin-top: 15px;
    justify-items: center;
  }

  .dial-key {
    width: 60px;
    height: 60px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.06);
    color: #fff;
    font-size: 22px;
    font-weight: 600;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: background 0.2s, transform 0.2s;
    outline: none;
  }

  .dial-key:hover {
    background: rgba(255, 255, 255, 0.1);
  }

  .dial-key:active {
    transform: scale(0.92);
  }

  .call-trigger-container {
    display: flex;
    justify-content: center;
    margin-top: 10px;
  }

  .call-btn-trigger {
    width: 62px;
    height: 62px;
    border-radius: 50%;
    border: none;
    font-size: 24px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    box-shadow: 0 4px 10px rgba(0, 0, 0, 0.35);
    transition: transform 0.2s;
    outline: none;
  }

  .call-btn-trigger:active {
    transform: scale(0.92);
  }

  .dial-call-btn {
    background: #22c55e;
    color: #fff;
  }

  /* Active Call Screen */
  .active-call-screen {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 14px;
    padding-bottom: 50px;
  }

  .calling-avatar {
    width: 90px;
    height: 90px;
    background: linear-gradient(135deg, #27272a 0%, #111115 100%);
    border: 1px solid rgba(255,255,255,0.06);
    border-radius: 50%;
    font-size: 40px;
    display: flex;
    align-items: center;
    justify-content: center;
    box-shadow: 0 10px 25px rgba(0,0,0,0.5);
  }

  .calling-number {
    font-size: 22px;
    font-weight: 800;
  }

  .calling-status {
    font-size: 13px;
    color: #a1a1aa;
    font-weight: 500;
  }

  .calling-timer {
    font-size: 15px;
    font-weight: bold;
    color: #22c55e;
    background: rgba(34, 197, 94, 0.1);
    padding: 4px 12px;
    border-radius: 20px;
    margin-top: 5px;
  }

  .end-call-btn {
    background: #ef4444;
    color: #fff;
    margin-top: 40px;
  }
</style>
