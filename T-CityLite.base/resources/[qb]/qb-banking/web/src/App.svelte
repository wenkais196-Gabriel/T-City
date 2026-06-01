<script lang="ts">
  import { onMount } from 'svelte';
  import { registerNuiEvent, fetchNui, isBrowser, triggerMockLuaMessage } from './utils/nui';
  import type { PlayerData, Account, Statement } from './types';
  
  import BankDashboard from './components/BankDashboard.svelte';
  import ATMView from './components/ATMView.svelte';

  // Global Visibility
  let visible = false;
  let currentScreen: 'bank' | 'atm' = 'bank';

  // Bank Data States
  let playerData: PlayerData = {
    citizenid: '',
    charinfo: { firstname: '', lastname: '' },
    money: { cash: 0, bank: 0 }
  };
  let accounts: Account[] = [];
  let statements: Statement[] = [];
  let pinNumbers: string[] = []; // for ATM PIN validation

  // Event Receivers from Lua
  registerNuiEvent('openBank', (data) => {
    playerData = data.playerData;
    accounts = data.accounts;
    statements = data.statements;
    currentScreen = 'bank';
    visible = true;
  });

  registerNuiEvent('openATM', (data) => {
    playerData = data.playerData;
    accounts = data.accounts;
    pinNumbers = data.pinNumbers || data.acceptablePins || [];
    currentScreen = 'atm';
    visible = true;
  });

  // Safe Close Helper
  const closeNui = async () => {
    visible = false;
    try {
      await fetchNui('closeApp');
    } catch (e) {
      console.warn('Failed to call closeApp NUI callback (expected in browser)');
    }
  };

  // Keyboard Escape Handler
  const handleKeydown = (event: KeyboardEvent) => {
    if (event.key === 'Escape' && visible) {
      // Let ATM screen handle Escape itself when on PIN entry or transactions
      if (currentScreen === 'atm') {
        // If ATM is open, Escape will act as NUI close
        closeNui();
      } else {
        closeNui();
      }
    }
  };

  // Browser developer tools bootstrapping
  onMount(() => {
    if (isBrowser()) {
      console.log('[Dev Mode] Running in regular browser. Floating dev panel loaded.');
      // Auto open bank in browser so the page is not blank
      triggerMockLuaMessage('openBank');
    }
  });
</script>

<svelte:window on:keydown={handleKeydown} />

{#if visible}
  <div class="nui-overlay animate-fade">
    {#if currentScreen === 'bank'}
      <BankDashboard 
        {playerData} 
        bind:accounts 
        bind:statements 
        onClose={closeNui} 
      />
    {:else}
      <ATMView 
        {playerData} 
        {accounts} 
        {pinNumbers} 
        onClose={closeNui} 
      />
    {/if}
  </div>
{/if}

<!-- Browser Developer Helper (Hidden inside Game) -->
{#if isBrowser()}
  <div class="dev-toolbar">
    <div class="toolbar-header">
      <span class="dot"></span> NUI PREVIEW PANEL
    </div>
    <div class="toolbar-actions">
      <button on:click={() => triggerMockLuaMessage('openBank')}>
        <i class="fas fa-university"></i> Bank Branch
      </button>
      <button on:click={() => triggerMockLuaMessage('openATM')}>
        <i class="fas fa-cash-register"></i> ATM Screen
      </button>
      <button class="danger" on:click={() => visible = false}>
        <i class="fas fa-eye-slash"></i> Hide NUI
      </button>
    </div>
  </div>
{/if}

<style>
  /* Full screen transparent NUI container */
  .nui-overlay {
    width: 100vw;
    height: 100vh;
    display: flex;
    justify-content: center;
    align-items: center;
    background: rgba(4, 7, 13, 0.4);
  }

  /* Browser Dev Panel styling */
  .dev-toolbar {
    position: fixed;
    bottom: 20px;
    right: 20px;
    background: rgba(17, 24, 39, 0.95);
    border: 1px solid rgba(255, 255, 255, 0.15);
    border-radius: 12px;
    padding: 12px 16px;
    box-shadow: 0 10px 25px rgba(0, 0, 0, 0.4);
    z-index: 99999;
    display: flex;
    flex-direction: column;
    gap: 8px;
    font-family: var(--font-mono);
    width: 250px;
  }

  .dev-toolbar .toolbar-header {
    font-size: 10px;
    color: var(--text-secondary);
    display: flex;
    align-items: center;
    gap: 6px;
    letter-spacing: 1px;
    font-weight: 700;
  }

  .dev-toolbar .dot {
    width: 6px;
    height: 6px;
    background: var(--accent-emerald);
    border-radius: 50%;
    box-shadow: 0 0 8px var(--accent-emerald);
  }

  .dev-toolbar .toolbar-actions {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .dev-toolbar button {
    background: rgba(31, 41, 55, 0.6);
    border: 1px solid rgba(255, 255, 255, 0.05);
    color: var(--text-primary);
    padding: 8px 12px;
    font-size: 11px;
    font-weight: 600;
    justify-content: flex-start;
    gap: 8px;
    width: 100%;
  }

  .dev-toolbar button:hover {
    background: var(--accent-indigo);
    color: white;
    box-shadow: 0 0 10px var(--accent-indigo-glow);
  }

  .dev-toolbar button.danger {
    color: #ef4444;
    border-color: rgba(239, 68, 68, 0.2);
  }

  .dev-toolbar button.danger:hover {
    background: #ef4444;
    color: white;
    box-shadow: 0 0 10px rgba(239, 68, 68, 0.3);
  }
</style>
