<script lang="ts">
  import { fetchNui } from '../utils/nui';
  import type { PlayerData, Account, Statement } from '../types';

  export let playerData: PlayerData;
  export let accounts: Account[] = [];
  export let statements: Statement[] = [];
  export let onClose: () => void;

  // Selected account and tab
  let selectedAccountName = 'checking';
  let activeTab: 'overview' | 'transfer' | 'manage' = 'overview';

  // Form states
  let depositAmount = '';
  let depositReason = '';
  let withdrawAmount = '';
  let withdrawReason = '';

  let transferType: 'internal' | 'external' = 'internal';
  let transferAmount = '';
  let transferReason = '';
  let targetAccountName = '';
  let targetCitizenId = '';

  // Account Management States
  let newAccountName = '';
  let newAccountType: 'shared' | 'savings' = 'shared';
  let initialDeposit = '';
  let newUserCitizenId = '';
  let renameNewName = '';
  let isCreatingAccount = false;

  const preventInvalidKeys = (event: KeyboardEvent) => {
    if (['e', 'E', '-', '+'].includes(event.key)) {
      event.preventDefault();
    }
  };

  // Toast Notification System
  let toast = { show: false, type: 'success' as 'success' | 'error', message: '' };
  let toastTimeout: number;

  function triggerToast(message: string, type: 'success' | 'error' = 'success') {
    window.clearTimeout(toastTimeout);
    toast = { show: true, type, message };
    toastTimeout = window.setTimeout(() => {
      toast.show = false;
    }, 4000);
  }

  // Get currently selected account
  $: selectedAccount = accounts.find(a => a.account_name === selectedAccountName) || accounts[0];
  $: selectedStatements = statements.filter(s => s.account_name === selectedAccountName);

  // Quick Amount Selector helper
  const setQuickAmount = (type: 'deposit' | 'withdraw' | 'transfer', amt: number) => {
    if (type === 'deposit') depositAmount = amt.toString();
    else if (type === 'withdraw') withdrawAmount = amt.toString();
    else if (type === 'transfer') transferAmount = amt.toString();
  };

  // NUI Actions
  const handleDeposit = async () => {
    const amt = parseFloat(depositAmount);
    if (isNaN(amt) || amt <= 0) return triggerToast('Please enter a valid amount', 'error');
    if (playerData.money.cash < amt) return triggerToast('Not enough cash in pocket', 'error');

    try {
      const res = await fetchNui<{ success: boolean; message: string }>('deposit', {
        accountName: selectedAccountName,
        amount: amt,
        reason: depositReason || 'Deposit'
      });

      if (res.success) {
        // Update local state
        playerData.money.cash -= amt;
        if (selectedAccountName === 'checking') {
          playerData.money.bank += amt;
          selectedAccount.account_balance = playerData.money.bank;
        } else {
          selectedAccount.account_balance += amt;
        }

        statements.unshift({
          id: Math.floor(Math.random() * 100000),
          citizenid: playerData.citizenid,
          account_name: selectedAccountName,
          amount: amt,
          reason: depositReason || 'Cash Deposit',
          statement_type: 'deposit',
          date: new Date().toISOString()
        });
        
        // Force reactivity update
        accounts = [...accounts];
        statements = [...statements];
        
        depositAmount = '';
        depositReason = '';
        triggerToast(res.message || 'Deposit successful!', 'success');
      } else {
        triggerToast(res.message || 'Deposit failed', 'error');
      }
    } catch (e) {
      triggerToast('Network error during deposit', 'error');
    }
  };

  const handleWithdraw = async () => {
    const amt = parseFloat(withdrawAmount);
    if (isNaN(amt) || amt <= 0) return triggerToast('Please enter a valid amount', 'error');
    if (selectedAccount.account_balance < amt) return triggerToast('Insufficient funds', 'error');

    try {
      const res = await fetchNui<{ success: boolean; message: string }>('withdraw', {
        accountName: selectedAccountName,
        amount: amt,
        reason: withdrawReason || 'Withdrawal'
      });

      if (res.success) {
        playerData.money.cash += amt;
        if (selectedAccountName === 'checking') {
          playerData.money.bank -= amt;
          selectedAccount.account_balance = playerData.money.bank;
        } else {
          selectedAccount.account_balance -= amt;
        }

        statements.unshift({
          id: Math.floor(Math.random() * 100000),
          citizenid: playerData.citizenid,
          account_name: selectedAccountName,
          amount: amt,
          reason: withdrawReason || 'ATM Withdrawal',
          statement_type: 'withdraw',
          date: new Date().toISOString()
        });

        accounts = [...accounts];
        statements = [...statements];

        withdrawAmount = '';
        withdrawReason = '';
        triggerToast(res.message || 'Withdrawal successful!', 'success');
      } else {
        triggerToast(res.message || 'Withdrawal failed', 'error');
      }
    } catch (e) {
      triggerToast('Network error during withdrawal', 'error');
    }
  };

  const handleTransfer = async () => {
    const amt = parseFloat(transferAmount);
    if (isNaN(amt) || amt <= 0) return triggerToast('Please enter a valid amount', 'error');
    if (selectedAccount.account_balance < amt) return triggerToast('Insufficient funds', 'error');

    if (transferType === 'internal') {
      if (!targetAccountName || targetAccountName === selectedAccountName) {
        return triggerToast('Please select a valid destination account', 'error');
      }

      try {
        const res = await fetchNui<{ success: boolean; message: string }>('internalTransfer', {
          fromAccountName: selectedAccountName,
          toAccountName: targetAccountName,
          amount: amt,
          reason: transferReason || 'Internal Transfer'
        });

        if (res.success) {
          selectedAccount.account_balance -= amt;
          const targetAcc = accounts.find(a => a.account_name === targetAccountName);
          if (targetAcc) {
            targetAcc.account_balance += amt;
            if (targetAccountName === 'checking') playerData.money.bank = targetAcc.account_balance;
          }
          if (selectedAccountName === 'checking') playerData.money.bank = selectedAccount.account_balance;

          statements.unshift({
            id: Math.floor(Math.random() * 100000),
            citizenid: playerData.citizenid,
            account_name: selectedAccountName,
            amount: amt,
            reason: transferReason || `Transfer to ${targetAccountName}`,
            statement_type: 'withdraw',
            date: new Date().toISOString()
          });

          statements.unshift({
            id: Math.floor(Math.random() * 100000),
            citizenid: playerData.citizenid,
            account_name: targetAccountName,
            amount: amt,
            reason: transferReason || `Transfer from ${selectedAccountName}`,
            statement_type: 'deposit',
            date: new Date().toISOString()
          });

          accounts = [...accounts];
          statements = [...statements];
          transferAmount = '';
          transferReason = '';
          triggerToast(res.message || 'Transfer completed successfully!', 'success');
        } else {
          triggerToast(res.message || 'Transfer failed', 'error');
        }
      } catch (e) {
        triggerToast('Network error during transfer', 'error');
      }
    } else {
      if (!targetCitizenId.trim()) return triggerToast('Please enter target Citizen ID', 'error');

      try {
        const res = await fetchNui<{ success: boolean; message: string }>('externalTransfer', {
          fromAccountName: selectedAccountName,
          toCitizenId: targetCitizenId,
          amount: amt,
          reason: transferReason || 'Wire Transfer'
        });

        if (res.success) {
          selectedAccount.account_balance -= amt;
          if (selectedAccountName === 'checking') playerData.money.bank = selectedAccount.account_balance;

          statements.unshift({
            id: Math.floor(Math.random() * 100000),
            citizenid: playerData.citizenid,
            account_name: selectedAccountName,
            amount: amt,
            reason: transferReason || `Wire transfer to ${targetCitizenId}`,
            statement_type: 'withdraw',
            date: new Date().toISOString()
          });

          accounts = [...accounts];
          statements = [...statements];
          transferAmount = '';
          transferReason = '';
          targetCitizenId = '';
          triggerToast(res.message || 'Wire transfer sent!', 'success');
        } else {
          triggerToast(res.message || 'Wire transfer failed', 'error');
        }
      } catch (e) {
        triggerToast('Network error during wire transfer', 'error');
      }
    }
  };

  const handleCreateAccount = async () => {
    if (isCreatingAccount) return;
    if (!newAccountName.trim()) return triggerToast('Please enter an account name', 'error');
    const depositAmt = parseFloat(initialDeposit) || 0;
    if (depositAmt > 0 && playerData.money.bank < depositAmt) {
      return triggerToast('Insufficient checking bank balance for initial deposit', 'error');
    }

    isCreatingAccount = true;
    try {
      const res = await fetchNui<{ success: boolean; message: string }>('openAccount', {
        accountName: newAccountName,
        accountType: newAccountType,
        amount: depositAmt
      });

      if (res.success) {
        if (depositAmt > 0) {
          playerData.money.bank -= depositAmt;
          const checking = accounts.find(a => a.account_name === 'checking');
          if (checking) checking.account_balance = playerData.money.bank;

          statements.unshift({
            id: Math.floor(Math.random() * 100000),
            citizenid: playerData.citizenid,
            account_name: 'checking',
            amount: depositAmt,
            reason: `Initial deposit for ${newAccountName}`,
            statement_type: 'withdraw',
            date: new Date().toISOString()
          });
        }

        accounts.push({
          id: Math.floor(Math.random() * 1000),
          citizenid: playerData.citizenid,
          account_name: newAccountName,
          account_balance: depositAmt,
          account_type: newAccountType as any,
          users: [playerData.citizenid]
        });

        accounts = [...accounts];
        statements = [...statements];
        newAccountName = '';
        initialDeposit = '';
        triggerToast(res.message || 'Account opened successfully!', 'success');
      } else {
        triggerToast(res.message || 'Failed to open account', 'error');
      }
    } catch (e) {
      triggerToast('Network error while opening account', 'error');
    } finally {
      isCreatingAccount = false;
    }
  };

  const handleOrderCard = async () => {
    try {
      const res = await fetchNui<{ success: boolean; message: string }>('orderCard', {
        accountName: selectedAccountName
      });
      if (res.success) {
        triggerToast(res.message || 'Card ordered successfully!', 'success');
      } else {
        triggerToast(res.message || 'Failed to order card', 'error');
      }
    } catch (e) {
      triggerToast('Network error ordering card', 'error');
    }
  };

  const handleAddUser = async () => {
    if (!newUserCitizenId.trim()) return triggerToast('Please enter Citizen ID', 'error');

    try {
      const res = await fetchNui<{ success: boolean; message: string }>('addUser', {
        accountName: selectedAccountName,
        citizenid: newUserCitizenId
      });

      if (res.success) {
        selectedAccount.users.push(newUserCitizenId);
        accounts = [...accounts];
        newUserCitizenId = '';
        triggerToast(res.message || 'User added successfully!', 'success');
      } else {
        triggerToast(res.message || 'Failed to add user', 'error');
      }
    } catch (e) {
      triggerToast('Network error adding user', 'error');
    }
  };

  const handleRemoveUser = async (usercid: string) => {
    if (usercid === playerData.citizenid) return triggerToast('You cannot remove yourself', 'error');

    try {
      const res = await fetchNui<{ success: boolean; message: string }>('removeUser', {
        accountName: selectedAccountName,
        citizenid: usercid
      });

      if (res.success) {
        selectedAccount.users = selectedAccount.users.filter(u => u !== usercid);
        accounts = [...accounts];
        triggerToast(res.message || 'User removed successfully!', 'success');
      } else {
        triggerToast(res.message || 'Failed to remove user', 'error');
      }
    } catch (e) {
      triggerToast('Network error removing user', 'error');
    }
  };

  const handleRenameAccount = async () => {
    if (!renameNewName.trim()) return triggerToast('Enter a valid account name', 'error');
    if (renameNewName === selectedAccountName) return triggerToast('New name is identical', 'error');

    try {
      const res = await fetchNui<{ success: boolean; message: string }>('renameAccount', {
        accountName: selectedAccountName,
        newName: renameNewName
      });

      if (res.success) {
        selectedAccount.account_name = renameNewName;
        selectedAccountName = renameNewName;
        accounts = [...accounts];
        renameNewName = '';
        triggerToast(res.message || 'Account renamed successfully!', 'success');
      } else {
        triggerToast(res.message || 'Failed to rename account', 'error');
      }
    } catch (e) {
      triggerToast('Network error renaming account', 'error');
    }
  };

  const handleDeleteAccount = async () => {
    if (selectedAccountName === 'checking') return triggerToast('Cannot close your primary checking account', 'error');

    try {
      const res = await fetchNui<{ success: boolean; message: string }>('deleteAccount', {
        accountName: selectedAccountName
      });

      if (res.success) {
        const balToRefund = selectedAccount.account_balance;
        accounts = accounts.filter(a => a.account_name !== selectedAccountName);
        playerData.money.bank += balToRefund;
        
        const checking = accounts.find(a => a.account_name === 'checking');
        if (checking) checking.account_balance = playerData.money.bank;

        statements.unshift({
          id: Math.floor(Math.random() * 100000),
          citizenid: playerData.citizenid,
          account_name: 'checking',
          amount: balToRefund,
          reason: `Account closure refund: ${selectedAccountName}`,
          statement_type: 'deposit',
          date: new Date().toISOString()
        });

        statements = [...statements];
        selectedAccountName = 'checking';
        activeTab = 'overview';
        triggerToast(res.message || 'Account closed and balance refunded!', 'success');
      } else {
        triggerToast(res.message || 'Failed to close account', 'error');
      }
    } catch (e) {
      triggerToast('Network error deleting account', 'error');
    }
  };

  // Helper formatting values
  const formatMoney = (val: number) => {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(val);
  };
</script>

<div class="bank-container animate-slide">
  <!-- Toast Notification Banner -->
  {#if toast.show}
    <div class="toast-notification {toast.type} animate-fade">
      <div class="toast-icon">
        {#if toast.type === 'success'}
          <i class="fas fa-check-circle"></i>
        {:else}
          <i class="fas fa-exclamation-circle"></i>
        {/if}
      </div>
      <div class="toast-body">
        <p>{toast.message}</p>
      </div>
    </div>
  {/if}

  <!-- Header -->
  <header class="bank-header">
    <div class="brand">
      <div class="brand-logo">
        <i class="fas fa-university"></i>
      </div>
      <div class="brand-meta">
        <h1>MAZE BANK</h1>
        <p>Premium Financial Solutions</p>
      </div>
    </div>
    
    <div class="user-meta">
      <div class="meta-item">
        <span class="label">POCKET CASH</span>
        <span class="value cash">{formatMoney(playerData.money.cash)}</span>
      </div>
      <div class="meta-item divider"></div>
      <div class="meta-item">
        <span class="label">CITIZEN NAME</span>
        <span class="value name">{playerData.charinfo.firstname} {playerData.charinfo.lastname}</span>
      </div>
      <button class="btn-close" on:click={onClose}>
        <i class="fas fa-sign-out-alt"></i>
      </button>
    </div>
  </header>

  <!-- Main Body Layout -->
  <div class="bank-body">
    <!-- Sidebar Account Selectors -->
    <aside class="bank-sidebar">
      <h2>ACCOUNTS</h2>
      <div class="accounts-list">
        {#each accounts as acc}
          <button 
            class="account-card-btn {selectedAccountName === acc.account_name ? 'active' : ''} {acc.account_type}"
            on:click={() => { selectedAccountName = acc.account_name; activeTab = 'overview'; }}
          >
            <div class="card-icon">
              {#if acc.account_type === 'checking'}
                <i class="fas fa-wallet"></i>
              {:else}
                <i class="fas fa-vault"></i>
              {/if}
            </div>
            <div class="card-meta">
              <span class="name">{acc.account_name}</span>
              <span class="type-badge">{acc.account_type.toUpperCase()}</span>
            </div>
            <span class="balance">{formatMoney(acc.account_balance)}</span>
          </button>
        {/each}
      </div>

      <!-- Quick Account Creator -->
      <div class="create-account-form">
        <h3>Create New Account</h3>
        <input type="text" placeholder="Account Name (e.g. Savings)" bind:value={newAccountName} disabled={isCreatingAccount} />
        <div class="type-selector">
          <label>
            <input type="radio" value="shared" bind:group={newAccountType} disabled={isCreatingAccount} />
            <span>Shared</span>
          </label>
          <label>
            <input type="radio" value="savings" bind:group={newAccountType} disabled={isCreatingAccount} />
            <span>Savings</span>
          </label>
        </div>
        <input type="number" placeholder="Initial Deposit ($)" bind:value={initialDeposit} on:keydown={preventInvalidKeys} disabled={isCreatingAccount} />
        <button class="btn-primary-glow" on:click={handleCreateAccount} disabled={isCreatingAccount}>
          {#if isCreatingAccount}
            <i class="fas fa-spinner fa-spin"></i> Opening...
          {:else}
            <i class="fas fa-plus"></i> Open Account
          {/if}
        </button>
      </div>
    </aside>

    <!-- Main Workspace -->
    <main class="bank-workspace">
      <!-- Account Visual Mockup & Sub-navigation -->
      <section class="account-showcase">
        <!-- Visual Credit Card Mockup -->
        <div class="card-mockup {selectedAccount.account_type}">
          <div class="card-glass"></div>
          <div class="card-header">
            <span class="bank-label">Maze Bank Platinum</span>
            <i class="fas fa-wifi card-contactless"></i>
          </div>
          <div class="card-chip"></div>
          <div class="card-body">
            <span class="balance-title">TOTAL BALANCE</span>
            <span class="balance-display">{formatMoney(selectedAccount.account_balance)}</span>
          </div>
          <div class="card-footer">
            <div class="card-holder">
              <span class="title">CARD HOLDER</span>
              <span class="value">{playerData.charinfo.firstname.toUpperCase()} {playerData.charinfo.lastname.toUpperCase()}</span>
            </div>
            <div class="card-info">
              <span class="title">CITIZEN ID</span>
              <span class="value">{selectedAccount.citizenid}</span>
            </div>
          </div>
        </div>

        <!-- Navigation Tabs -->
        <div class="tabs-navigation">
          <button class="tab-btn {activeTab === 'overview' ? 'active' : ''}" on:click={() => activeTab = 'overview'}>
            <i class="fas fa-exchange-alt"></i> Deposit & Withdraw
          </button>
          <button class="tab-btn {activeTab === 'transfer' ? 'active' : ''}" on:click={() => activeTab = 'transfer'}>
            <i class="fas fa-paper-plane"></i> Transfer & Wires
          </button>
          {#if selectedAccountName !== 'checking' && selectedAccount && selectedAccount.account_type === 'shared' && selectedAccount.citizenid === playerData.citizenid}
            <button class="tab-btn {activeTab === 'manage' ? 'active' : ''}" on:click={() => activeTab = 'manage'}>
              <i class="fas fa-users-cog"></i> Access Control
            </button>
          {/if}
        </div>
      </section>

      <!-- Operations Container -->
      <section class="tab-content">
        <!-- Tab 1: Deposit & Withdraw -->
        {#if activeTab === 'overview'}
          <div class="grid-two-cols animate-fade">
            <!-- Deposit Panel -->
            <div class="op-panel">
              <h3>DEPOSIT CASH</h3>
              <p class="description">Securely deposit physical bills into this account.</p>
              
              <div class="amount-presets">
                <button class="preset-btn" on:click={() => setQuickAmount('deposit', 100)}>$100</button>
                <button class="preset-btn" on:click={() => setQuickAmount('deposit', 500)}>$500</button>
                <button class="preset-btn" on:click={() => setQuickAmount('deposit', 1000)}>$1,000</button>
                <button class="preset-btn" on:click={() => setQuickAmount('deposit', 5000)}>$5,000</button>
                <button class="preset-btn" on:click={() => setQuickAmount('deposit', playerData.money.cash)}>Max</button>
              </div>

              <div class="input-group">
                <label>Amount ($)</label>
                <input type="number" placeholder="Enter amount to deposit" bind:value={depositAmount} on:keydown={preventInvalidKeys} />
              </div>

              <div class="input-group">
                <label>Reference / Reason</label>
                <input type="text" placeholder="Optional reference note" bind:value={depositReason} />
              </div>

              <button class="btn-success-glow" on:click={handleDeposit}>
                <i class="fas fa-arrow-down"></i> Confirm Deposit
              </button>
            </div>

            <!-- Withdraw Panel -->
            <div class="op-panel">
              <h3>WITHDRAW CASH</h3>
              <p class="description">Convert bank balance into physical wallet cash.</p>
              
              <div class="amount-presets">
                <button class="preset-btn" on:click={() => setQuickAmount('withdraw', 100)}>$100</button>
                <button class="preset-btn" on:click={() => setQuickAmount('withdraw', 500)}>$500</button>
                <button class="preset-btn" on:click={() => setQuickAmount('withdraw', 1000)}>$1,000</button>
                <button class="preset-btn" on:click={() => setQuickAmount('withdraw', 5000)}>$5,000</button>
                <button class="preset-btn" on:click={() => setQuickAmount('withdraw', selectedAccount.account_balance)}>Max</button>
              </div>

              <div class="input-group">
                <label>Amount ($)</label>
                <input type="number" placeholder="Enter amount to withdraw" bind:value={withdrawAmount} on:keydown={preventInvalidKeys} />
              </div>

              <div class="input-group">
                <label>Reference / Reason</label>
                <input type="text" placeholder="Optional reference note" bind:value={withdrawReason} />
              </div>

              <button class="btn-danger-glow" on:click={handleWithdraw}>
                <i class="fas fa-arrow-up"></i> Confirm Withdrawal
              </button>
            </div>
          </div>
        {/if}

        <!-- Tab 2: Wire Transfers -->
        {#if activeTab === 'transfer'}
          <div class="op-panel full-width animate-fade">
            <h3>FUNDS TRANSFER</h3>
            <p class="description">Move capital internally between your own portfolios or send wire transfers to other citizens.</p>

            <div class="transfer-toggle">
              <button class="toggle-btn {transferType === 'internal' ? 'active' : ''}" on:click={() => transferType = 'internal'}>
                Internal Transfer
              </button>
              <button class="toggle-btn {transferType === 'external' ? 'active' : ''}" on:click={() => transferType = 'external'}>
                External Wire Transfer
              </button>
            </div>

            <div class="grid-two-cols">
              <div class="form-side">
                {#if transferType === 'internal'}
                  <div class="input-group">
                    <label>Destination Account</label>
                    <select bind:value={targetAccountName}>
                      <option value="">-- Choose Account --</option>
                      {#each accounts as acc}
                        {#if acc.account_name !== selectedAccountName}
                          <option value={acc.account_name}>{acc.account_name} ({formatMoney(acc.account_balance)})</option>
                        {/if}
                      {/each}
                    </select>
                  </div>
                {:else}
                  <div class="input-group">
                    <label>Recipient Citizen ID (CID)</label>
                    <input type="text" placeholder="Enter recipient's Citizen ID" bind:value={targetCitizenId} />
                  </div>
                {/if}

                <div class="input-group">
                  <label>Transfer Amount ($)</label>
                  <input type="number" placeholder="Enter transfer amount" bind:value={transferAmount} on:keydown={preventInvalidKeys} />
                  <div class="amount-presets mini">
                    <button class="preset-btn" on:click={() => setQuickAmount('transfer', 100)}>$100</button>
                    <button class="preset-btn" on:click={() => setQuickAmount('transfer', 1000)}>$1k</button>
                    <button class="preset-btn" on:click={() => setQuickAmount('transfer', 10000)}>$10k</button>
                  </div>
                </div>
              </div>

              <div class="form-side">
                <div class="input-group">
                  <label>Reference Note</label>
                  <input type="text" placeholder="Optional transfer memo" bind:value={transferReason} />
                </div>

                <button class="btn-primary-glow" on:click={handleTransfer} style="margin-top: 30px;">
                  <i class="fas fa-paper-plane"></i> Execute Transfer
                </button>
              </div>
            </div>
          </div>
        {/if}

        <!-- Tab 3: Access Control & Operations -->
        {#if activeTab === 'manage' && selectedAccountName !== 'checking'}
          <div class="grid-two-cols animate-fade">
            <!-- User Access Management -->
            <div class="op-panel">
              <h3>SHARED USERS</h3>
              <p class="description">Grant and revoke account access for other citizens.</p>

              <div class="add-user-field">
                <input type="text" placeholder="Citizen ID" bind:value={newUserCitizenId} />
                <button class="btn-secondary" on:click={handleAddUser}>
                  <i class="fas fa-user-plus"></i> Add User
                </button>
              </div>

              <div class="users-list">
                <h4>AUTHORIZED CITIZENS ({selectedAccount.users.length})</h4>
                <div class="scroll-users">
                  {#each selectedAccount.users as user}
                    <div class="user-row">
                      <span class="user-cid"><i class="far fa-user"></i> {user}</span>
                      {#if user !== playerData.citizenid}
                        <button class="btn-remove-user" on:click={() => handleRemoveUser(user)}>
                          <i class="fas fa-trash-alt"></i> Revoke
                        </button>
                      {:else}
                        <span class="badge-owner">OWNER</span>
                      {/if}
                    </div>
                  {/each}
                </div>
              </div>
            </div>

            <!-- Danger Zone & Renames -->
            <div class="op-panel danger-panel">
              <h3>ACCOUNT ACTIONS</h3>
              <p class="description">Manage credentials or permanently terminate this shared vault.</p>

              <div class="input-group">
                <label>Rename Account</label>
                <div class="add-user-field">
                  <input type="text" placeholder="New Account Name" bind:value={renameNewName} />
                  <button class="btn-secondary" on:click={handleRenameAccount}>
                    Rename
                  </button>
                </div>
              </div>

              <div class="danger-zone">
                <h4>DANGER ZONE</h4>
                <p>Closing this account will immediately transfer the entire remaining balance back to your Checking account.</p>
                <button class="btn-danger-outline" on:click={handleDeleteAccount}>
                  <i class="fas fa-trash"></i> Close Account & Refund
                </button>
              </div>


            </div>
          </div>
        {/if}
      </section>

      <!-- Ledger Statements History -->
      <section class="ledger-statements">
        <h2>TRANSACTION STATEMENTS</h2>
        <div class="statements-list">
          {#if selectedStatements.length === 0}
            <div class="empty-statements animate-fade">
              <i class="fas fa-receipt"></i>
              <p>No recent transaction statements recorded for this account.</p>
            </div>
          {:else}
            <div class="scroll-statements">
              {#each selectedStatements as stmt}
                <div class="statement-row animate-fade">
                  <div class="status-marker {stmt.statement_type}">
                    {#if stmt.statement_type === 'deposit'}
                      <i class="fas fa-arrow-down"></i>
                    {:else}
                      <i class="fas fa-arrow-up"></i>
                    {/if}
                  </div>
                  
                  <div class="statement-meta">
                    <span class="reason">{stmt.reason}</span>
                    <span class="date">{new Date(stmt.date).toLocaleString()}</span>
                  </div>

                  <span class="amount {stmt.statement_type}">
                    {stmt.statement_type === 'deposit' ? '+' : '-'}{formatMoney(stmt.amount)}
                  </span>
                </div>
              {/each}
            </div>
          {/if}
        </div>
      </section>
    </main>
  </div>
</div>

<style>
  .bank-container {
    width: 1200px;
    height: 780px;
    display: flex;
    flex-direction: column;
    background: rgba(10, 15, 26, 0.85);
    backdrop-filter: blur(25px);
    -webkit-backdrop-filter: blur(25px);
    border: 1px solid rgba(255, 255, 255, 0.08);
    box-shadow: 0 20px 50px rgba(0, 0, 0, 0.5);
    border-radius: 24px;
    overflow: hidden;
    position: relative;
  }

  /* Toast Notification CSS */
  .toast-notification {
    position: absolute;
    top: 20px;
    left: 50%;
    transform: translateX(-50%);
    z-index: 999;
    display: flex;
    align-items: center;
    background: rgba(17, 24, 39, 0.95);
    border-radius: 12px;
    padding: 12px 24px;
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.35);
    border: 1px solid;
    gap: 12px;
    min-width: 320px;
  }

  .toast-notification.success {
    border-color: var(--accent-emerald);
    color: var(--accent-emerald);
  }

  .toast-notification.error {
    border-color: var(--accent-coral);
    color: var(--accent-coral);
  }

  .toast-notification p {
    color: var(--text-primary);
    font-size: 14px;
    font-weight: 500;
  }

  /* Header */
  .bank-header {
    height: 100px;
    background: rgba(17, 24, 39, 0.6);
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
    padding: 0 32px;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .bank-header .brand {
    display: flex;
    align-items: center;
    gap: 16px;
  }

  .bank-header .brand-logo {
    width: 48px;
    height: 48px;
    background: linear-gradient(135deg, var(--accent-indigo), #4f46e5);
    border-radius: 12px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 20px;
    color: white;
    box-shadow: 0 0 15px var(--accent-indigo-glow);
  }

  .bank-header .brand-meta h1 {
    font-family: 'Outfit', sans-serif;
    font-size: 22px;
    font-weight: 800;
    letter-spacing: 1px;
    background: linear-gradient(to right, #fff, #a5b4fc);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
  }

  .bank-header .brand-meta p {
    font-size: 11px;
    color: var(--text-muted);
    font-weight: 500;
    letter-spacing: 0.5px;
  }

  .bank-header .user-meta {
    display: flex;
    align-items: center;
    gap: 24px;
  }

  .bank-header .meta-item {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
  }

  .bank-header .meta-item.divider {
    width: 1px;
    height: 35px;
    background: rgba(255, 255, 255, 0.08);
  }

  .bank-header .meta-item .label {
    font-size: 10px;
    font-weight: 700;
    color: var(--text-muted);
    letter-spacing: 1px;
    margin-bottom: 2px;
  }

  .bank-header .meta-item .value {
    font-size: 16px;
    font-weight: 600;
  }

  .bank-header .meta-item .value.cash {
    color: var(--accent-emerald);
    text-shadow: 0 0 10px var(--accent-emerald-glow);
  }

  .bank-header .meta-item .value.name {
    color: var(--text-primary);
  }

  .bank-header .btn-close {
    background: rgba(239, 68, 68, 0.1);
    color: var(--accent-coral);
    width: 42px;
    height: 42px;
    border-radius: 10px;
    font-size: 16px;
    border: 1px solid rgba(239, 68, 68, 0.2);
  }

  .bank-header .btn-close:hover {
    background: var(--accent-coral);
    color: white;
    box-shadow: 0 0 15px var(--accent-coral-glow);
  }

  /* Body Layout */
  .bank-body {
    flex: 1;
    display: flex;
    overflow: hidden;
  }

  /* Sidebar */
  .bank-sidebar {
    width: 320px;
    background: rgba(17, 24, 39, 0.35);
    border-right: 1px solid rgba(255, 255, 255, 0.08);
    padding: 24px;
    display: flex;
    flex-direction: column;
    overflow-y: auto;
  }

  .bank-sidebar h2 {
    font-size: 12px;
    color: var(--text-muted);
    letter-spacing: 1px;
    font-weight: 700;
    margin-bottom: 16px;
  }

  .accounts-list {
    display: flex;
    flex-direction: column;
    gap: 12px;
    margin-bottom: 24px;
  }

  .account-card-btn {
    background: rgba(31, 41, 55, 0.3);
    border: 1px solid rgba(255, 255, 255, 0.04);
    padding: 16px;
    border-radius: 14px;
    display: flex;
    align-items: center;
    width: 100%;
    text-align: left;
    transition: var(--transition-smooth);
    color: var(--text-primary);
    position: relative;
  }

  .account-card-btn:hover {
    background: rgba(31, 41, 55, 0.5);
    border-color: rgba(255, 255, 255, 0.1);
  }

  .account-card-btn.active {
    background: linear-gradient(135deg, rgba(99, 102, 241, 0.15), rgba(99, 102, 241, 0.05));
    border-color: var(--accent-indigo);
    box-shadow: 0 0 15px var(--accent-indigo-glow);
  }

  .account-card-btn.active::after {
    content: '';
    position: absolute;
    left: 0;
    top: 50%;
    transform: translateY(-50%);
    width: 4px;
    height: 40px;
    background: var(--accent-indigo);
    border-radius: 0 4px 4px 0;
  }

  .account-card-btn .card-icon {
    width: 36px;
    height: 36px;
    background: rgba(17, 24, 39, 0.5);
    border-radius: 10px;
    display: flex;
    align-items: center;
    justify-content: center;
    margin-right: 14px;
    color: var(--text-secondary);
    font-size: 14px;
    transition: var(--transition-smooth);
  }

  .account-card-btn.active .card-icon {
    background: var(--accent-indigo);
    color: white;
  }

  .account-card-btn .card-meta {
    display: flex;
    flex-direction: column;
    flex-grow: 1;
  }

  .account-card-btn .card-meta .name {
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
    margin-bottom: 2px;
  }

  .account-card-btn .card-meta .type-badge {
    font-size: 9px;
    font-weight: 700;
    color: var(--text-muted);
  }

  .account-card-btn .balance {
    font-size: 14px;
    font-weight: 600;
    color: var(--text-primary);
  }

  /* Create Account Form */
  .create-account-form {
    background: rgba(31, 41, 55, 0.2);
    border: 1px solid rgba(255, 255, 255, 0.04);
    border-radius: 16px;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .create-account-form h3 {
    font-size: 12px;
    font-weight: 700;
    color: var(--text-secondary);
    letter-spacing: 0.5px;
  }

  .create-account-form input {
    padding: 10px 12px;
    font-size: 12px;
    width: 100%;
  }

  .create-account-form .type-selector {
    display: flex;
    gap: 12px;
  }

  .create-account-form .type-selector label {
    flex: 1;
    cursor: pointer;
  }

  .create-account-form .type-selector input[type="radio"] {
    display: none;
  }

  .create-account-form .type-selector span {
    display: block;
    text-align: center;
    background: rgba(17, 24, 39, 0.4);
    border: 1px solid rgba(255, 255, 255, 0.05);
    padding: 8px;
    border-radius: 8px;
    font-size: 11px;
    font-weight: 600;
    color: var(--text-secondary);
    transition: var(--transition-smooth);
  }

  .create-account-form .type-selector input[type="radio"]:checked + span {
    background: rgba(99, 102, 241, 0.15);
    border-color: var(--accent-indigo);
    color: var(--text-primary);
  }

  /* Main Workspace */
  .bank-workspace {
    flex: 1;
    padding: 24px;
    display: flex;
    flex-direction: column;
    gap: 20px;
    overflow-y: auto;
  }

  .account-showcase {
    display: flex;
    gap: 24px;
  }

  /* Physical Card Mockup */
  .card-mockup {
    width: 320px;
    height: 190px;
    border-radius: 18px;
    padding: 20px;
    position: relative;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    box-shadow: 0 15px 35px rgba(0, 0, 0, 0.35);
    border: 1px solid rgba(255, 255, 255, 0.1);
  }

  .card-mockup.checking {
    background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
  }

  .card-mockup.shared {
    background: linear-gradient(135deg, #78350f 0%, #451a03 100%);
    border-color: rgba(245, 158, 11, 0.2);
  }

  .card-mockup.job {
    background: linear-gradient(135deg, #1e3a8a 0%, #172554 100%);
    border-color: rgba(99, 102, 241, 0.2);
  }

  .card-mockup.savings {
    background: linear-gradient(135deg, #064e3b 0%, #022c22 100%);
    border-color: rgba(16, 185, 129, 0.2);
  }

  .card-glass {
    position: absolute;
    inset: 0;
    background: linear-gradient(135deg, rgba(255, 255, 255, 0.1) 0%, rgba(255, 255, 255, 0) 100%);
    z-index: 1;
  }

  .card-mockup .card-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    z-index: 2;
  }

  .card-mockup .bank-label {
    font-family: 'Outfit', sans-serif;
    font-weight: 800;
    font-size: 12px;
    letter-spacing: 1px;
    opacity: 0.8;
  }

  .card-mockup .card-contactless {
    font-size: 14px;
    opacity: 0.6;
  }

  .card-mockup .card-chip {
    width: 38px;
    height: 28px;
    background: linear-gradient(135deg, #fbbf24 0%, #d97706 100%);
    border-radius: 6px;
    z-index: 2;
    box-shadow: inset 0 1px 3px rgba(255, 255, 255, 0.3);
  }

  .card-mockup .card-body {
    display: flex;
    flex-direction: column;
    z-index: 2;
  }

  .card-mockup .balance-title {
    font-size: 9px;
    font-weight: 700;
    color: var(--text-muted);
    letter-spacing: 1px;
    margin-bottom: 2px;
  }

  .card-mockup .balance-display {
    font-family: 'Outfit', sans-serif;
    font-size: 24px;
    font-weight: 700;
    letter-spacing: 0.5px;
  }

  .card-mockup .card-footer {
    display: flex;
    justify-content: space-between;
    align-items: flex-end;
    z-index: 2;
  }

  .card-mockup .card-footer .title {
    font-size: 8px;
    font-weight: 700;
    color: var(--text-muted);
    display: block;
    margin-bottom: 2px;
    letter-spacing: 0.5px;
  }

  .card-mockup .card-footer .value {
    font-family: var(--font-mono);
    font-size: 11px;
    font-weight: 600;
    color: var(--text-primary);
  }

  /* Sub-Navigation Tabs */
  .tabs-navigation {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 12px;
    justify-content: center;
  }

  .tab-btn {
    background: rgba(31, 41, 55, 0.25);
    border: 1px solid rgba(255, 255, 255, 0.04);
    color: var(--text-secondary);
    padding: 14px 20px;
    font-size: 14px;
    font-weight: 600;
    width: 100%;
    justify-content: flex-start;
    gap: 12px;
  }

  .tab-btn:hover {
    background: rgba(31, 41, 55, 0.45);
    color: var(--text-primary);
  }

  .tab-btn.active {
    background: var(--accent-indigo);
    color: white;
    box-shadow: 0 0 15px var(--accent-indigo-glow);
    border-color: var(--accent-indigo);
  }

  /* Operation Panels */
  .op-panel {
    background: rgba(17, 24, 39, 0.4);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 18px;
    padding: 24px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .op-panel.full-width {
    width: 100%;
  }

  .op-panel.danger-panel {
    border-color: rgba(239, 68, 68, 0.15);
  }

  .op-panel h3 {
    font-family: 'Outfit', sans-serif;
    font-size: 16px;
    font-weight: 700;
    letter-spacing: 0.5px;
  }

  .op-panel p.description {
    font-size: 12px;
    color: var(--text-secondary);
    line-height: 1.5;
  }

  .amount-presets {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
  }

  .preset-btn {
    background: rgba(31, 41, 55, 0.35);
    border: 1px solid rgba(255, 255, 255, 0.05);
    padding: 8px 12px;
    font-size: 12px;
    font-weight: 600;
    border-radius: 8px;
    color: var(--text-secondary);
  }

  .preset-btn:hover {
    background: rgba(31, 41, 55, 0.6);
    color: var(--text-primary);
  }

  .input-group {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .input-group label {
    font-size: 11px;
    font-weight: 700;
    color: var(--text-secondary);
    letter-spacing: 0.5px;
  }

  .input-group input, .input-group select {
    width: 100%;
  }

  /* Grid layouts */
  .grid-two-cols {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 20px;
  }

  /* Buttons Custom */
  .btn-success-glow {
    background: var(--accent-emerald);
    color: white;
    font-weight: 600;
    padding: 14px;
    font-size: 14px;
    box-shadow: 0 4px 15px var(--accent-emerald-glow);
  }

  .btn-success-glow:hover {
    filter: brightness(1.1);
    box-shadow: 0 4px 20px rgba(16, 185, 129, 0.4);
  }

  .btn-danger-glow {
    background: var(--accent-coral);
    color: white;
    font-weight: 600;
    padding: 14px;
    font-size: 14px;
    box-shadow: 0 4px 15px var(--accent-coral-glow);
  }

  .btn-danger-glow:hover {
    filter: brightness(1.1);
    box-shadow: 0 4px 20px rgba(239, 68, 68, 0.4);
  }

  .btn-primary-glow {
    background: var(--accent-indigo);
    color: white;
    font-weight: 600;
    padding: 14px;
    font-size: 14px;
    box-shadow: 0 4px 15px var(--accent-indigo-glow);
  }

  .btn-primary-glow:hover {
    filter: brightness(1.1);
    box-shadow: 0 4px 20px rgba(99, 102, 241, 0.4);
  }

  /* Transfers style */
  .transfer-toggle {
    display: flex;
    background: rgba(17, 24, 39, 0.5);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: 12px;
    padding: 4px;
  }

  .toggle-btn {
    flex: 1;
    background: transparent;
    border: none;
    color: var(--text-secondary);
    padding: 10px;
    font-size: 13px;
    font-weight: 600;
    border-radius: 8px;
  }

  .toggle-btn.active {
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-primary);
  }

  .amount-presets.mini {
    margin-top: 8px;
    justify-content: flex-start;
  }

  .amount-presets.mini .preset-btn {
    padding: 4px 10px;
    font-size: 11px;
  }

  /* Shared Users Panel list styling */
  .add-user-field {
    display: flex;
    gap: 10px;
  }

  .add-user-field input {
    flex: 1;
  }

  .btn-secondary {
    background: rgba(55, 65, 81, 0.5);
    color: var(--text-primary);
    padding: 10px 16px;
    font-weight: 600;
    font-size: 13px;
    border: 1px solid rgba(255, 255, 255, 0.08);
  }

  .btn-secondary:hover {
    background: rgba(55, 65, 81, 0.8);
  }

  .users-list h4 {
    font-size: 11px;
    color: var(--text-muted);
    font-weight: 700;
    letter-spacing: 0.5px;
    margin-bottom: 8px;
    margin-top: 15px;
  }

  .scroll-users {
    max-height: 150px;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .user-row {
    background: rgba(17, 24, 39, 0.4);
    padding: 10px 14px;
    border-radius: 10px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    border: 1px solid rgba(255, 255, 255, 0.03);
  }

  .user-row .user-cid {
    font-family: var(--font-mono);
    font-size: 12px;
    color: var(--text-secondary);
  }

  .btn-remove-user {
    background: transparent;
    color: var(--accent-coral);
    font-size: 11px;
    font-weight: 600;
  }

  .btn-remove-user:hover {
    text-shadow: 0 0 10px var(--accent-coral-glow);
  }

  .badge-owner {
    font-size: 9px;
    background: rgba(16, 185, 129, 0.1);
    color: var(--accent-emerald);
    padding: 4px 8px;
    border-radius: 6px;
    font-weight: 700;
  }

  /* Danger zone */
  .danger-zone {
    border: 1px dashed rgba(239, 68, 68, 0.3);
    background: rgba(239, 68, 68, 0.03);
    border-radius: 12px;
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-top: 15px;
  }

  .danger-zone h4 {
    color: var(--accent-coral);
    font-size: 12px;
    font-weight: 700;
  }

  .danger-zone p {
    font-size: 11px;
    color: var(--text-secondary);
    line-height: 1.4;
  }

  .btn-danger-outline {
    background: transparent;
    border: 1px solid var(--accent-coral);
    color: var(--accent-coral);
    font-weight: 600;
    padding: 10px;
    font-size: 12px;
  }

  .btn-danger-outline:hover {
    background: var(--accent-coral);
    color: white;
    box-shadow: 0 0 15px var(--accent-coral-glow);
  }

  .btn-card-order {
    background: linear-gradient(135deg, rgba(99, 102, 241, 0.1), rgba(99, 102, 241, 0.05));
    border: 1px dashed rgba(99, 102, 241, 0.3);
    color: var(--accent-indigo);
    font-weight: 600;
    width: 100%;
    padding: 12px;
    font-size: 12px;
  }

  .btn-card-order:hover {
    background: var(--accent-indigo);
    color: white;
    box-shadow: 0 0 15px var(--accent-indigo-glow);
    border-style: solid;
  }

  /* Statements history style */
  .ledger-statements h2 {
    font-size: 12px;
    font-weight: 700;
    color: var(--text-secondary);
    letter-spacing: 0.5px;
    margin-bottom: 12px;
  }

  .statements-list {
    background: rgba(17, 24, 39, 0.4);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: 16px;
    overflow: hidden;
  }

  .empty-statements {
    padding: 40px;
    text-align: center;
    color: var(--text-muted);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 12px;
  }

  .empty-statements i {
    font-size: 32px;
  }

  .empty-statements p {
    font-size: 13px;
  }

  .scroll-statements {
    max-height: 220px;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
  }

  .statement-row {
    display: flex;
    align-items: center;
    padding: 14px 20px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    transition: var(--transition-smooth);
  }

  .statement-row:last-child {
    border-bottom: none;
  }

  .statement-row:hover {
    background: rgba(255, 255, 255, 0.02);
  }

  .status-marker {
    width: 32px;
    height: 32px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    margin-right: 16px;
    font-size: 12px;
  }

  .status-marker.deposit {
    background: rgba(16, 185, 129, 0.1);
    color: var(--accent-emerald);
  }

  .status-marker.withdraw {
    background: rgba(239, 68, 68, 0.1);
    color: var(--accent-coral);
  }

  .statement-meta {
    display: flex;
    flex-direction: column;
    flex-grow: 1;
  }

  .statement-meta .reason {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
    margin-bottom: 2px;
  }

  .statement-meta .date {
    font-size: 10px;
    color: var(--text-muted);
  }

  .statement-row .amount {
    font-family: var(--font-mono);
    font-size: 14px;
    font-weight: 600;
  }

  .statement-row .amount.deposit {
    color: var(--accent-emerald);
  }

  .statement-row .amount.withdraw {
    color: var(--accent-coral);
  }
</style>
