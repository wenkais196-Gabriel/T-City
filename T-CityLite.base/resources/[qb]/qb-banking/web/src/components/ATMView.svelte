<script lang="ts">
  import { fetchNui } from '../utils/nui';
  import type { PlayerData, Account } from '../types';

  export let playerData: PlayerData;
  export let accounts: Account[] = [];
  export let pinNumbers: string[] = []; // acceptable PIN numbers passed from server
  export let onClose: () => void;

  // ATM Screen States
  // 'pin' -> enter PIN
  // 'menu' -> ATM main options
  // 'withdraw' -> standard withdraw
  // 'deposit' -> deposit cash
  // 'success' -> success screen
  let screen: 'pin' | 'menu' | 'withdraw' | 'deposit' | 'success' = 'pin';

  let currentPin = '';
  let pinError = '';
  let customAmount = '';
  let lastTransactionType = '';
  let lastTransactionAmount = 0;

  // Notification Toast
  let atmToast = { show: false, message: '' };
  let atmToastTimeout: number;

  const triggerAtmToast = (msg: string) => {
    window.clearTimeout(atmToastTimeout);
    atmToast = { show: true, message: msg };
    atmToastTimeout = window.setTimeout(() => {
      atmToast.show = false;
    }, 3000);
  };

  // Find Checking Account
  $: checkingAccount = accounts.find(a => a.account_name === 'checking') || accounts[0] || { account_balance: 0 };

  // Keypad Actions
  const handleKeyPress = (num: string) => {
    if (screen === 'pin') {
      pinError = '';
      if (currentPin.length < 4) {
        currentPin += num;
      }
    } else if (screen === 'withdraw' || screen === 'deposit') {
      customAmount += num;
    }
  };

  const handleClear = () => {
    if (screen === 'pin') {
      currentPin = '';
    } else {
      customAmount = '';
    }
  };

  const handleCancel = () => {
    if (screen === 'pin') {
      onClose();
    } else {
      screen = 'menu';
      customAmount = '';
    }
  };

  const handleEnter = () => {
    if (screen === 'pin') {
      validatePin();
    } else if (screen === 'withdraw') {
      executeATMWithdraw(parseFloat(customAmount));
    } else if (screen === 'deposit') {
      executeATMDeposit(parseFloat(customAmount));
    }
  };

  const validatePin = () => {
    if (pinNumbers.includes(currentPin)) {
      screen = 'menu';
      currentPin = '';
    } else {
      currentPin = '';
      pinError = 'INVALID SECURITY PIN CODE. TRY AGAIN.';
      triggerAtmToast('Incorrect PIN');
    }
  };

  // ATM Actions
  const executeATMWithdraw = async (amt: number) => {
    if (isNaN(amt) || amt <= 0) return triggerAtmToast('Invalid Amount');
    if (checkingAccount.account_balance < amt) return triggerAtmToast('Insufficient Account Funds');

    try {
      const res = await fetchNui<{ success: boolean; message: string }>('withdraw', {
        accountName: 'checking',
        amount: amt,
        reason: 'ATM Cash Withdrawal'
      });

      if (res.success) {
        // Update local state
        checkingAccount.account_balance -= amt;
        playerData.money.cash += amt;
        playerData.money.bank = checkingAccount.account_balance;

        lastTransactionType = 'WITHDRAWAL';
        lastTransactionAmount = amt;
        screen = 'success';
        customAmount = '';
      } else {
        triggerAtmToast(res.message || 'Withdrawal Failed');
      }
    } catch (e) {
      triggerAtmToast('ATM Connection Timeout');
    }
  };

  const executeATMDeposit = async (amt: number) => {
    if (isNaN(amt) || amt <= 0) return triggerAtmToast('Invalid Amount');
    if (playerData.money.cash < amt) return triggerAtmToast('Not enough cash in wallet');

    try {
      const res = await fetchNui<{ success: boolean; message: string }>('deposit', {
        accountName: 'checking',
        amount: amt,
        reason: 'ATM Cash Deposit'
      });

      if (res.success) {
        checkingAccount.account_balance += amt;
        playerData.money.cash -= amt;
        playerData.money.bank = checkingAccount.account_balance;

        lastTransactionType = 'DEPOSIT';
        lastTransactionAmount = amt;
        screen = 'success';
        customAmount = '';
      } else {
        triggerAtmToast(res.message || 'Deposit Failed');
      }
    } catch (e) {
      triggerAtmToast('ATM Connection Timeout');
    }
  };

  // Keyboard binding for keypad
  const handleKeydown = (event: KeyboardEvent) => {
    if (event.key >= '0' && event.key <= '9') {
      handleKeyPress(event.key);
    } else if (event.key === 'Backspace' || event.key === 'Delete') {
      handleClear();
    } else if (event.key === 'Enter') {
      handleEnter();
    } else if (event.key === 'Escape') {
      handleCancel();
    }
  };

  const formatMoney = (val: number) => {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(val);
  };
</script>

<svelte:window on:keydown={handleKeydown} />

<div class="atm-bezel animate-slide">
  <!-- ATM Terminal Outer frame -->
  <div class="atm-cabinet">
    <!-- CRT Green Neon Screen -->
    <div class="atm-screen-container">
      <div class="screen-glass"></div>
      <div class="scanlines"></div>
      
      <!-- Screen Display -->
      <div class="atm-screen-display">
        <!-- ATM Screen Header -->
        <header class="atm-screen-header">
          <span class="pulse-indicator"><i class="fas fa-network-wired"></i> SECURE CONNECTED</span>
          <span class="model-id">FLEECEATM SYS_v8.4</span>
        </header>

        {#if atmToast.show}
          <div class="atm-alert-bar animate-fade">
            <span class="alert-txt"><i class="fas fa-exclamation-triangle"></i> {atmToast.message.toUpperCase()}</span>
          </div>
        {/if}

        <!-- PIN Screen -->
        {#if screen === 'pin'}
          <div class="screen-pin animate-fade">
            <h2>MAZE CENTRAL SECURITY</h2>
            <p class="subtitle">PLEASE ENTER YOUR 4-DIGIT SECURITY PIN</p>
            
            <div class="pin-display">
              {#each Array(4) as _, i}
                <div class="pin-dot {i < currentPin.length ? 'filled' : ''}">
                  {i < currentPin.length ? '*' : ''}
                </div>
              {/each}
            </div>

            {#if pinError}
              <p class="error-msg">{pinError}</p>
            {:else}
              <p class="hint-msg">DEPOSIT BANK CARD TO INITIALIZE LOGIN</p>
            {/if}

            <div class="quick-help-menu">
              <span>[ENTER] CONFIRM</span>
              <span>[CLEAR] ERASE</span>
              <span>[CANCEL] CANCEL CARD</span>
            </div>
          </div>
        {/if}

        <!-- ATM Main Options Menu -->
        {#if screen === 'menu'}
          <div class="screen-menu animate-fade">
            <div class="menu-header">
              <h2>WELCOME CITIZEN</h2>
              <span class="user-name">{playerData.charinfo.firstname.toUpperCase()} {playerData.charinfo.lastname.toUpperCase()}</span>
            </div>

            <div class="balance-widget">
              <span class="lbl">SAVINGS BALANCE</span>
              <span class="val">{formatMoney(checkingAccount.account_balance)}</span>
            </div>

            <div class="atm-menu-layout">
              <div class="left-options">
                <button class="menu-option-btn" on:click={() => executeATMWithdraw(50)}>
                  <i class="fas fa-arrow-right"></i> QUICK CASH $50
                </button>
                <button class="menu-option-btn" on:click={() => executeATMWithdraw(100)}>
                  <i class="fas fa-arrow-right"></i> QUICK CASH $100
                </button>
                <button class="menu-option-btn" on:click={() => executeATMWithdraw(500)}>
                  <i class="fas fa-arrow-right"></i> QUICK CASH $500
                </button>
              </div>

              <div class="right-options">
                <button class="menu-option-btn text-right" on:click={() => screen = 'withdraw'}>
                  WITHDRAW AMOUNT <i class="fas fa-arrow-left"></i>
                </button>
                <button class="menu-option-btn text-right" on:click={() => screen = 'deposit'}>
                  DEPOSIT CASH <i class="fas fa-arrow-left"></i>
                </button>
                <button class="menu-option-btn text-right danger" on:click={handleCancel}>
                  TERMINATE & RETURN CARD <i class="fas fa-arrow-left"></i>
                </button>
              </div>
            </div>
          </div>
        {/if}

        <!-- Custom Withdrawal Screen -->
        {#if screen === 'withdraw'}
          <div class="screen-action animate-fade">
            <h2>CASH WITHDRAWAL</h2>
            <p class="subtitle">MAX SINGLE WITHDRAWAL ALLOWED: $20,000</p>

            <div class="terminal-input-display">
              <span class="symbol">$</span>
              <span class="amount-val">{customAmount || '0'}</span>
            </div>

            <p class="balance-check">CURRENT BALANCE: {formatMoney(checkingAccount.account_balance)}</p>

            <div class="action-footer">
              <button class="terminal-btn secondary" on:click={() => screen = 'menu'}>
                [BACK] MAIN MENU
              </button>
              <button class="terminal-btn primary" on:click={handleEnter}>
                [ENTER] CONFIRM CASHOUT
              </button>
            </div>
          </div>
        {/if}

        <!-- Custom Deposit Screen -->
        {#if screen === 'deposit'}
          <div class="screen-action animate-fade">
            <h2>CASH DEPOSIT</h2>
            <p class="subtitle">INSERT CASH BILLS INTO THE GREEN SLOT</p>

            <div class="terminal-input-display">
              <span class="symbol">$</span>
              <span class="amount-val">{customAmount || '0'}</span>
            </div>

            <p class="balance-check">POCKET WALLET CASH: {formatMoney(playerData.money.cash)}</p>

            <div class="action-footer">
              <button class="terminal-btn secondary" on:click={() => screen = 'menu'}>
                [BACK] MAIN MENU
              </button>
              <button class="terminal-btn primary" on:click={handleEnter}>
                [ENTER] DEPOSIT CASH
              </button>
            </div>
          </div>
        {/if}

        <!-- Success Screen -->
        {#if screen === 'success'}
          <div class="screen-success animate-fade">
            <div class="success-icon animate-fade">
              <i class="fas fa-check-double"></i>
            </div>
            <h2>TRANSACTION APPROVED</h2>
            <p class="approved-msg">{lastTransactionType} OF {formatMoney(lastTransactionAmount)} COMPLETED</p>
            <p class="new-bal">REMAINING ACCOUNT BALANCE: {formatMoney(checkingAccount.account_balance)}</p>

            <div class="success-actions">
              <button class="terminal-btn primary" on:click={() => screen = 'menu'}>
                NEW TRANSACTION
              </button>
              <button class="terminal-btn secondary" on:click={onClose}>
                FINISH & RETURN CARD
              </button>
            </div>
          </div>
        {/if}

      </div>
    </div>

    <!-- Metal Pad controls -->
    <div class="atm-keypad-panel">
      <div class="keypad-layout">
        <!-- Digits Grid -->
        <div class="digits-grid">
          {#each ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'] as key}
            <button class="key-btn digit" on:click={() => handleKeyPress(key)}>
              {key}
            </button>
          {/each}
        </div>

        <!-- Controls grid -->
        <div class="controls-grid">
          <button class="key-btn cancel" on:click={handleCancel}>CANCEL</button>
          <button class="key-btn clear" on:click={handleClear}>CLEAR</button>
          <button class="key-btn enter" on:click={handleEnter}>ENTER</button>
          <div class="key-btn disabled"></div>
        </div>
      </div>
    </div>
  </div>
</div>

<style>
  /* ATM Cabinet design */
  .atm-bezel {
    width: 680px;
    background: #27272a;
    border: 8px solid #3f3f46;
    border-radius: 30px;
    padding: 24px;
    box-shadow: 0 30px 60px rgba(0, 0, 0, 0.7);
    display: flex;
    justify-content: center;
  }

  .atm-cabinet {
    width: 100%;
    display: flex;
    flex-direction: column;
    gap: 24px;
  }

  /* Fluor CRT Neon Screen */
  .atm-screen-container {
    background: #022c22;
    border: 12px solid #18181b;
    border-radius: 16px;
    height: 400px;
    position: relative;
    overflow: hidden;
    box-shadow: inset 0 0 40px rgba(0, 0, 0, 1), 0 0 20px rgba(16, 185, 129, 0.15);
  }

  .screen-glass {
    position: absolute;
    inset: 0;
    background: linear-gradient(135deg, rgba(255, 255, 255, 0.05) 0%, rgba(255, 255, 255, 0.01) 50%, rgba(0, 0, 0, 0.2) 100%);
    pointer-events: none;
    z-index: 5;
  }

  .scanlines {
    position: absolute;
    inset: 0;
    background: linear-gradient(rgba(18, 16, 16, 0) 50%, rgba(0, 0, 0, 0.25) 50%);
    background-size: 100% 4px;
    pointer-events: none;
    z-index: 4;
  }

  .scanlines::after {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0; height: 100%;
    background: linear-gradient(transparent, rgba(16, 185, 129, 0.08), transparent);
    animation: scanline 6s linear infinite;
    pointer-events: none;
  }

  /* Screen interface core */
  .atm-screen-display {
    width: 100%;
    height: 100%;
    padding: 16px;
    display: flex;
    flex-direction: column;
    font-family: var(--font-mono);
    color: #10b981;
    text-shadow: 0 0 6px rgba(16, 185, 129, 0.8), 0 0 12px rgba(16, 185, 129, 0.4);
    box-sizing: border-box;
  }

  .atm-screen-header {
    display: flex;
    justify-content: space-between;
    font-size: 11px;
    font-weight: 600;
    border-bottom: 1px solid rgba(16, 185, 129, 0.3);
    padding-bottom: 8px;
    margin-bottom: 16px;
  }

  .pulse-indicator {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .pulse-indicator i {
    animation: pulseGlow 1.5s infinite;
  }

  /* Alert bar */
  .atm-alert-bar {
    background: rgba(239, 68, 68, 0.15);
    border: 1px solid rgba(239, 68, 68, 0.4);
    padding: 8px;
    border-radius: 6px;
    text-align: center;
    color: #f87171;
    text-shadow: 0 0 6px rgba(239, 68, 68, 0.8);
    font-size: 11px;
    font-weight: 700;
    margin-bottom: 12px;
  }

  /* PIN Panel style */
  .screen-pin {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 16px;
    text-align: center;
  }

  .screen-pin h2 {
    font-size: 18px;
    color: #34d399;
    letter-spacing: 1px;
    text-shadow: 0 0 10px rgba(52, 211, 153, 0.6);
  }

  .screen-pin .subtitle {
    font-size: 11px;
    color: #6ee7b7;
  }

  .pin-display {
    display: flex;
    gap: 14px;
    margin: 12px 0;
  }

  .pin-dot {
    width: 48px;
    height: 48px;
    border: 2px solid #10b981;
    border-radius: 8px;
    background: rgba(2, 44, 34, 0.5);
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 24px;
    font-weight: 700;
    box-shadow: 0 0 10px rgba(16, 185, 129, 0.2);
  }

  .pin-dot.filled {
    background: rgba(16, 185, 129, 0.1);
  }

  .error-msg {
    color: #f87171;
    text-shadow: 0 0 6px rgba(239, 68, 68, 0.8);
    font-size: 11px;
    font-weight: 700;
  }

  .hint-msg {
    font-size: 10px;
    color: #047857;
    text-shadow: none;
  }

  .quick-help-menu {
    display: flex;
    gap: 16px;
    font-size: 9px;
    margin-top: 15px;
    color: #34d399;
    opacity: 0.7;
  }

  /* ATM Main menu style */
  .screen-menu {
    display: flex;
    flex-direction: column;
    gap: 14px;
    height: 100%;
  }

  .menu-header {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .menu-header h2 {
    font-size: 16px;
    color: #34d399;
  }

  .menu-header .user-name {
    font-size: 12px;
    color: #a7f3d0;
  }

  .balance-widget {
    background: rgba(16, 185, 129, 0.05);
    border: 1px solid rgba(16, 185, 129, 0.2);
    border-radius: 8px;
    padding: 10px 14px;
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .balance-widget .lbl {
    font-size: 10px;
    color: #6ee7b7;
  }

  .balance-widget .val {
    font-size: 18px;
    font-weight: 700;
  }

  .atm-menu-layout {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
    margin-top: 10px;
  }

  .menu-option-btn {
    background: rgba(16, 185, 129, 0.05);
    border: 1px solid rgba(16, 185, 129, 0.2);
    color: #10b981;
    font-family: var(--font-mono);
    text-shadow: 0 0 6px rgba(16, 185, 129, 0.6);
    padding: 12px 14px;
    font-size: 11px;
    border-radius: 8px;
    width: 100%;
    justify-content: flex-start;
    gap: 8px;
  }

  .menu-option-btn:hover {
    background: rgba(16, 185, 129, 0.25);
    border-color: #34d399;
    box-shadow: 0 0 10px rgba(16, 185, 129, 0.2);
  }

  .menu-option-btn.text-right {
    justify-content: flex-end;
  }

  .menu-option-btn.danger {
    color: #f87171;
    border-color: rgba(239, 68, 68, 0.2);
    text-shadow: 0 0 6px rgba(239, 68, 68, 0.6);
  }

  .menu-option-btn.danger:hover {
    background: rgba(239, 68, 68, 0.25);
    border-color: #ef4444;
  }

  /* Operations ATM Input */
  .screen-action {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 16px;
    height: 100%;
  }

  .screen-action h2 {
    font-size: 16px;
    color: #34d399;
  }

  .screen-action .subtitle {
    font-size: 10px;
    color: #6ee7b7;
  }

  .terminal-input-display {
    width: 240px;
    background: rgba(2, 44, 34, 0.8);
    border: 2px solid #10b981;
    border-radius: 10px;
    padding: 14px;
    display: flex;
    justify-content: center;
    align-items: center;
    gap: 8px;
    box-shadow: 0 0 15px rgba(16, 185, 129, 0.1);
  }

  .terminal-input-display .symbol {
    font-size: 22px;
    font-weight: 700;
  }

  .terminal-input-display .amount-val {
    font-size: 24px;
    font-weight: 700;
  }

  .balance-check {
    font-size: 10px;
    color: #6ee7b7;
  }

  .action-footer {
    display: flex;
    gap: 12px;
    width: 100%;
    margin-top: 15px;
  }

  .terminal-btn {
    flex: 1;
    font-family: var(--font-mono);
    padding: 10px;
    font-size: 11px;
    font-weight: 600;
    border-radius: 6px;
  }

  .terminal-btn.primary {
    background: #10b981;
    color: #022c22;
    text-shadow: none;
  }

  .terminal-btn.primary:hover {
    background: #34d399;
    box-shadow: 0 0 15px rgba(52, 211, 153, 0.3);
  }

  .terminal-btn.secondary {
    background: transparent;
    border: 1px solid rgba(16, 185, 129, 0.4);
    color: #10b981;
    text-shadow: 0 0 6px rgba(16, 185, 129, 0.6);
  }

  .terminal-btn.secondary:hover {
    background: rgba(16, 185, 129, 0.15);
  }

  /* Success Screen style */
  .screen-success {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 14px;
    text-align: center;
    height: 100%;
  }

  .success-icon {
    font-size: 36px;
    color: #34d399;
  }

  .screen-success h2 {
    font-size: 16px;
    color: #34d399;
  }

  .approved-msg {
    font-size: 11px;
    color: #a7f3d0;
  }

  .new-bal {
    font-size: 10px;
    color: #6ee7b7;
  }

  .success-actions {
    display: flex;
    gap: 12px;
    margin-top: 15px;
  }

  /* Keypad Panel */
  .atm-keypad-panel {
    background: #3f3f46;
    border: 3px solid #18181b;
    border-radius: 12px;
    padding: 16px;
    box-shadow: inset 0 2px 5px rgba(255, 255, 255, 0.15), 0 5px 10px rgba(0, 0, 0, 0.4);
  }

  .keypad-layout {
    display: flex;
    gap: 16px;
    justify-content: center;
  }

  .digits-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 8px;
  }

  .controls-grid {
    display: flex;
    flex-direction: column;
    gap: 8px;
    width: 100px;
  }

  /* Metallic button styling */
  .key-btn {
    width: 54px;
    height: 44px;
    background: linear-gradient(135deg, #e4e4e7 0%, #a1a1aa 100%);
    border: 1px solid #71717a;
    border-radius: 6px;
    font-family: var(--font-sans);
    font-size: 16px;
    font-weight: 700;
    color: #27272a;
    box-shadow: 0 3px 0 #52525b, 0 4px 6px rgba(0, 0, 0, 0.3);
    text-shadow: 0 1px 0 rgba(255, 255, 255, 0.4);
    display: flex;
    align-items: center;
    justify-content: center;
    transition: none; /* Instant feedback */
  }

  .key-btn:active {
    transform: translateY(2px);
    box-shadow: 0 1px 0 #52525b, 0 1px 3px rgba(0, 0, 0, 0.3);
  }

  .key-btn.cancel {
    width: 100%;
    background: linear-gradient(135deg, #ef4444 0%, #991b1b 100%);
    color: white;
    font-size: 11px;
    border-color: #991b1b;
    box-shadow: 0 3px 0 #7f1d1d, 0 4px 6px rgba(0, 0, 0, 0.3);
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.3);
  }

  .key-btn.cancel:active {
    box-shadow: 0 1px 0 #7f1d1d, 0 1px 3px rgba(0, 0, 0, 0.3);
  }

  .key-btn.clear {
    width: 100%;
    background: linear-gradient(135deg, #f59e0b 0%, #92400e 100%);
    color: white;
    font-size: 11px;
    border-color: #92400e;
    box-shadow: 0 3px 0 #78350f, 0 4px 6px rgba(0, 0, 0, 0.3);
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.3);
  }

  .key-btn.clear:active {
    box-shadow: 0 1px 0 #78350f, 0 1px 3px rgba(0, 0, 0, 0.3);
  }

  .key-btn.enter {
    width: 100%;
    background: linear-gradient(135deg, #10b981 0%, #065f46 100%);
    color: white;
    font-size: 11px;
    border-color: #065f46;
    box-shadow: 0 3px 0 #064e3b, 0 4px 6px rgba(0, 0, 0, 0.3);
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.3);
  }

  .key-btn.enter:active {
    box-shadow: 0 1px 0 #064e3b, 0 1px 3px rgba(0, 0, 0, 0.3);
  }

  .key-btn.disabled {
    width: 100%;
    background: #27272a;
    border-color: #18181b;
    box-shadow: none;
    pointer-events: none;
  }
</style>
