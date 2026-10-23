<script lang="ts">
  import { playerData } from '../stores/phone';
  import {
    callPhase,
    callPeerName,
    callPeerNumber,
    callStatusText,
    callDuration,
    placeCall,
    answerIncomingCall,
    rejectIncomingCall,
    endActiveCall
  } from '../stores/call';

  // Call events (incoming/answered/ended) are registered globally in App.svelte,
  // so the call state is received even when this app is not mounted.
  let dialNumber = $state('');

  const appendNumber = (num: string) => {
    if (dialNumber.length < 15) {
      dialNumber += num;
    }
  };

  const deleteLast = () => {
    dialNumber = dialNumber.slice(0, -1);
  };

  const startCall = () => {
    if (!dialNumber) return;
    void placeCall(dialNumber);
  };

  const answerCall = () => {
    void answerIncomingCall();
  };

  const rejectCall = () => {
    void rejectIncomingCall();
    dialNumber = '';
  };

  const endCall = () => {
    void endActiveCall();
    dialNumber = '';
  };

  const formatDuration = (sec: number) => {
    const m = Math.floor(sec / 60);
    const s = sec % 60;
    return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
  };
</script>

<div class="phone-call-app app-transition">
  <!-- App Header -->
  <div class="app-header">
    <span class="app-title">📞 Phone</span>
  </div>

  <div class="app-content phone-scrollable">
    {#if $callPhase === 'incoming'}
      <!-- Incoming Call Screen -->
      <div class="incoming-call-screen">
        <div class="caller-avatar-large">👤</div>
        <div class="caller-name">{$callPeerName}</div>
        <div class="caller-number">{$callPeerNumber}</div>
        <div class="call-status-ringing">Incoming Call...</div>
        <div class="call-actions">
          <button class="call-btn answer-btn" onclick={answerCall} aria-label="Answer">
            <span class="btn-icon">📞</span>
            Answer
          </button>
          <button class="call-btn reject-btn" onclick={rejectCall} aria-label="Reject">
            <span class="btn-icon">📵</span>
            Reject
          </button>
        </div>
      </div>
    {:else if $callPhase === 'ongoing'}
      <!-- Ongoing Call Screen -->
      <div class="ongoing-call-screen">
        <div class="caller-avatar-large">👤</div>
        <div class="caller-name">{$callPeerName || $callPeerNumber}</div>
        <div class="call-timer">{formatDuration($callDuration)}</div>
        <div class="call-status-active">Connected</div>
        <div class="call-actions">
          <button class="call-btn end-call-btn" onclick={endCall} aria-label="End Call">
            <span class="btn-icon">🔴</span>
            End Call
          </button>
        </div>
      </div>
    {:else if $callPhase === 'dialing' || $callPhase === 'ringing'}
      <!-- Outgoing Call Screen -->
      <div class="outgoing-call-screen">
        <div class="caller-avatar-large">👤</div>
        <div class="caller-name">{$callPeerNumber || dialNumber}</div>
        <div class="call-status-ringing">{$callStatusText}</div>
        <div class="call-actions">
          <button class="call-btn end-call-btn" onclick={endCall} aria-label="Cancel Call">
            <span class="btn-icon">🔴</span>
            Cancel
          </button>
        </div>
      </div>
    {:else}
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

      <!-- Dial Pad -->
      <div class="dial-pad-grid">
        {#each ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'] as num}
          <button class="dial-key" onclick={() => appendNumber(num)}>
            {num}
          </button>
        {/each}
      </div>

      <!-- Green Call Button -->
      <div class="call-action-row">
        <button class="dial-call-btn" onclick={startCall} disabled={!dialNumber} aria-label="Call">
          📞 Call
        </button>
      </div>
    {/if}
  </div>
</div>

<style>
  .my-card-header {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 14px;
    margin-bottom: 18px;
  }
  .my-avatar {
    font-size: 38px;
  }
  .my-details {
    display: flex;
    flex-direction: column;
    gap: 3px;
  }
  .my-name {
    font-size: 16px;
    font-weight: 700;
  }
  .my-phone, .my-cid {
    font-size: 11px;
    color: #aaa;
  }

  .dial-input-container {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 16px;
  }
  .dial-display {
    flex: 1;
    background: #1c1c1e;
    border: 1px solid #333;
    border-radius: 10px;
    color: #fff;
    font-size: 22px;
    padding: 12px 16px;
    text-align: center;
    outline: none;
    font-family: 'Outfit', monospace;
    letter-spacing: 3px;
  }
  .delete-btn {
    background: #333;
    color: #fff;
    border: none;
    border-radius: 10px;
    width: 44px;
    height: 48px;
    font-size: 18px;
    cursor: pointer;
  }

  .dial-pad-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 10px;
    margin-bottom: 16px;
  }
  .dial-key {
    background: #2c2c2e;
    color: #fff;
    border: 1px solid #444;
    border-radius: 50%;
    width: 56px;
    height: 56px;
    font-size: 20px;
    margin: 0 auto;
    cursor: pointer;
    transition: background 0.15s;
  }
  .dial-key:hover { background: #444; }
  .dial-key:active { background: #555; }

  .call-action-row {
    display: flex;
    justify-content: center;
  }
  .dial-call-btn {
    background: #22c55e;
    color: #fff;
    border: none;
    border-radius: 30px;
    padding: 14px 48px;
    font-size: 18px;
    font-weight: 700;
    cursor: pointer;
  }
  .dial-call-btn:disabled {
    background: #333;
    color: #666;
    cursor: not-allowed;
  }

  /* Call screens */
  .incoming-call-screen, .outgoing-call-screen, .ongoing-call-screen {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    height: 100%;
    padding: 20px;
    text-align: center;
  }
  .caller-avatar-large {
    font-size: 64px;
    margin-bottom: 16px;
  }
  .caller-name {
    font-size: 22px;
    font-weight: 700;
    margin-bottom: 4px;
  }
  .caller-number {
    font-size: 14px;
    color: #aaa;
    margin-bottom: 12px;
  }
  .call-status-ringing {
    font-size: 13px;
    color: #f59e0b;
    margin-bottom: 20px;
    animation: pulse 1.5s infinite;
  }
  .call-status-active {
    font-size: 13px;
    color: #22c55e;
    margin-bottom: 20px;
  }
  .call-timer {
    font-size: 28px;
    font-weight: 300;
    font-family: 'Outfit', monospace;
    margin-bottom: 8px;
  }
  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.4; }
  }
  .call-actions {
    display: flex;
    gap: 20px;
    margin-top: 10px;
  }
  .call-btn {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 6px;
    border: none;
    border-radius: 16px;
    padding: 14px 28px;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    color: #fff;
  }
  .btn-icon { font-size: 24px; }
  .answer-btn { background: #22c55e; }
  .reject-btn { background: #ef4444; }
  .end-call-btn { background: #ef4444; }
</style>
