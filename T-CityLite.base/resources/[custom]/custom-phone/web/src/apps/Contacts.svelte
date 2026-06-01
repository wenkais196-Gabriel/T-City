<script lang="ts">
  import { contactsList, activeApp, playerData } from '../stores/phone';
  import { fetchNui, isBrowser } from '../utils/nui';

  let searchQuery = $state('');
  let isAddOpen = $state(false);
  let newName = $state('');
  let newNumber = $state('');
  let errorMsg = $state('');

  // AirDrop Sharing state
  let showAirDrop = $state(false);
  let shareLoading = $state(false);
  let nearbyCitizens = $state<any[]>([]);

  // Filtered contacts list
  let filteredContacts = $derived(
    $contactsList.filter(c => 
      c.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
      c.number.includes(searchQuery)
    )
  );

  const openChatWith = (number: string) => {
    activeApp.set('messages');
    (window as any).phoneTargetNumber = number;
  };

  const handleAddContact = async () => {
    if (!newName.trim() || !newNumber.trim()) {
      errorMsg = 'Name and Number are required';
      return;
    }

    try {
      const res = await fetchNui('addContact', { name: newName, number: newNumber });
      if (res.success) {
        contactsList.update(list => [...list, res.contact]);
        newName = '';
        newNumber = '';
        errorMsg = '';
        isAddOpen = false;
      } else {
        errorMsg = res.message || 'Failed to add contact';
      }
    } catch (err) {
      errorMsg = 'Networking error';
    }
  };

  const handleDeleteContact = async (id: number) => {
    try {
      const res = await fetchNui('deleteContact', { id });
      if (res.success) {
        contactsList.update(list => list.filter(c => c.id !== id));
      }
    } catch (err) {
      console.error(err);
    }
  };

  // AirDrop sharing logic
  const openAirDrop = async () => {
    shareLoading = true;
    showAirDrop = true;
    nearbyCitizens = [];

    if (isBrowser()) {
      setTimeout(() => {
        nearbyCitizens = [
          { id: 2, name: 'Sheriff Miller', phone: '1112223333' },
          { id: 5, name: 'Big Tony', phone: '9998887777' }
        ];
        shareLoading = false;
      }, 700);
      return;
    }

    try {
      const results = await fetchNui<any[]>('getNearbyPlayers');
      nearbyCitizens = results || [];
    } catch (err) {
      console.error(err);
    } finally {
      shareLoading = false;
    }
  };

  const shareMyCard = async (targetId: number) => {
    try {
      const res = await fetchNui<any>('shareContactNearby', {
        targetId,
        name: $playerData.name,
        number: $playerData.phone
      });
      if (res.success) {
        alert(res.message);
        showAirDrop = false;
      } else {
        alert(res.message);
      }
    } catch (err) {
      alert('Failed to transmit名片');
    }
  };
</script>

<div class="contacts-app app-transition">
  <!-- App Header -->
  <div class="app-header">
    <span class="app-title">👤 Contacts</span>
    <button class="add-btn" onclick={() => isAddOpen = !isAddOpen} aria-label="Add Contact">
      {isAddOpen ? '✕' : '＋'}
    </button>
  </div>

  <div class="app-content phone-scrollable">
    {#if isAddOpen}
      <!-- Add New Contact Form -->
      <div class="add-contact-card">
        <h3>New Contact</h3>
        {#if errorMsg}
          <div class="err-banner">{errorMsg}</div>
        {/if}
        <div class="form-group">
          <label for="nameInput">Name</label>
          <input id="nameInput" type="text" class="phone-input" placeholder="e.g. Sheriff Miller" bind:value={newName} />
        </div>
        <div class="form-group">
          <label for="numInput">Phone Number</label>
          <input id="numInput" type="text" class="phone-input" placeholder="e.g. 1112223333" bind:value={newNumber} />
        </div>
        <div class="form-actions">
          <button class="phone-btn phone-btn-secondary" onclick={() => isAddOpen = false}>Cancel</button>
          <button class="phone-btn" onclick={handleAddContact}>Save</button>
        </div>
      </div>
    {:else}
      <!-- iOS Style My Card -->
      <div class="my-card glass-card">
        <div class="my-card-left">
          <div class="my-card-avatar">👤</div>
          <div class="my-card-info">
            <span class="my-card-name">{$playerData.name}</span>
            <span class="my-card-phone">My Number: {$playerData.phone || '000000'}</span>
          </div>
        </div>
        <button class="share-card-btn" onclick={openAirDrop} aria-label="AirDrop Card">📤 Share</button>
      </div>

      <!-- Search Input -->
      <div class="search-container">
        <input type="text" class="phone-input search-input" placeholder="Search contacts..." bind:value={searchQuery} />
      </div>

      <!-- Contacts List -->
      {#if filteredContacts.length === 0}
        <div class="empty-state">No contacts found</div>
      {:else}
        <div class="contacts-list">
          {#each filteredContacts as contact (contact.id)}
            <div class="contact-item glass-card">
              <div class="avatar">{contact.name.charAt(0).toUpperCase()}</div>
              <div class="contact-info">
                <span class="contact-name">{contact.name}</span>
                <span class="contact-number">{contact.number}</span>
              </div>
              <div class="contact-actions">
                <button class="action-btn chat-btn" onclick={() => openChatWith(contact.number)} aria-label="Chat">💬</button>
                <button class="action-btn del-btn" onclick={() => handleDeleteContact(contact.id)} aria-label="Delete">🗑️</button>
              </div>
            </div>
          {/each}
        </div>
      {/if}
    {/if}
  </div>

  <!-- AirDrop Card Modal Overlay -->
  {#if showAirDrop}
    <div class="airdrop-modal glass-effect app-transition">
      <div class="airdrop-header">
        <span>📤 AirDrop My Card</span>
        <button class="close-airdrop-btn" onclick={() => showAirDrop = false}>✕</button>
      </div>

      <div class="airdrop-body">
        {#if shareLoading}
          <div class="airdrop-loading">
            <div class="radar-ping"></div>
            <span>Searching for nearby citizens...</span>
          </div>
        {:else if nearbyCitizens.length === 0}
          <div class="airdrop-empty">
            <span>📡</span>
            <p>No nearby players found to share contact card.</p>
          </div>
        {:else}
          <div class="airdrop-list">
            {#each nearbyCitizens as p}
              <button class="airdrop-item glass-card" onclick={() => shareMyCard(p.id)}>
                <span class="airdrop-item-name">Transmit to: {p.name}</span>
                <span class="airdrop-item-sub">Citizen ID matches</span>
              </button>
            {/each}
          </div>
        {/if}
      </div>
    </div>
  {/if}
</div>

<style>
  .contacts-app {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: #09090b;
    position: relative;
  }

  .app-header {
    height: 55px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 18px;
    border-bottom: 1px solid #1f1f23;
  }

  .app-title {
    font-size: 18px;
    font-weight: 700;
  }

  .add-btn {
    background: rgba(255, 255, 255, 0.08);
    border: none;
    color: #fff;
    width: 32px;
    height: 32px;
    border-radius: 50%;
    font-size: 16px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
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

  /* My Card iOS style */
  .my-card {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 14px;
  }

  .my-card-left {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .my-card-avatar {
    width: 40px;
    height: 40px;
    border-radius: 50%;
    background: linear-gradient(135deg, #3f3f46 0%, #18181b 100%);
    border: 1px solid rgba(255,255,255,0.08);
    font-size: 18px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .my-card-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .my-card-name {
    font-size: 13.5px;
    font-weight: 800;
  }

  .my-card-phone {
    font-size: 10.5px;
    color: #a1a1aa;
    font-weight: 500;
  }

  .share-card-btn {
    background: rgba(138, 43, 226, 0.15);
    border: 1px solid rgba(138, 43, 226, 0.3);
    color: #c084fc;
    border-radius: 8px;
    font-size: 11px;
    font-weight: bold;
    padding: 6px 12px;
    cursor: pointer;
    outline: none;
  }

  .share-card-btn:hover {
    background: rgba(138, 43, 226, 0.25);
  }

  .search-container {
    width: 100%;
    margin-bottom: 4px;
  }

  .search-input {
    width: 100%;
    box-sizing: border-box;
    font-size: 13px;
  }

  /* Add Contact Card */
  .add-contact-card {
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 16px;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .add-contact-card h3 {
    margin: 0;
    font-size: 16px;
    font-weight: 600;
  }

  .err-banner {
    background: rgba(239, 68, 68, 0.15);
    border: 1.5px solid rgba(239, 68, 68, 0.4);
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

  .form-group input {
    font-size: 13.5px;
  }

  .form-actions {
    display: flex;
    gap: 10px;
    margin-top: 8px;
  }

  .form-actions button {
    flex: 1;
  }

  /* Contacts List */
  .contacts-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .contact-item {
    display: flex;
    align-items: center;
    padding: 12px;
  }

  .avatar {
    width: 38px;
    height: 38px;
    border-radius: 50%;
    background: hsl(var(--phone-accent));
    font-size: 15px;
    font-weight: 700;
    display: flex;
    align-items: center;
    justify-content: center;
    margin-right: 12px;
  }

  .contact-info {
    flex: 1;
    display: flex;
    flex-direction: column;
  }

  .contact-name {
    font-size: 14px;
    font-weight: 600;
  }

  .contact-number {
    font-size: 11.5px;
    color: #888;
    margin-top: 1px;
  }

  .contact-actions {
    display: flex;
    gap: 8px;
  }

  .action-btn {
    border: none;
    color: #fff;
    width: 32px;
    height: 32px;
    border-radius: 10px;
    font-size: 13px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .chat-btn {
    background: rgba(255, 255, 255, 0.08);
  }

  .chat-btn:hover {
    background: rgba(255, 255, 255, 0.15);
  }

  .del-btn {
    background: rgba(239, 68, 68, 0.15);
    color: #ef4444;
  }

  .del-btn:hover {
    background: rgba(239, 68, 68, 0.25);
  }

  .empty-state {
    text-align: center;
    padding: 30px 10px;
    color: #666;
    font-size: 13px;
  }

  /* AirDrop Modal Overlay */
  .airdrop-modal {
    position: absolute;
    inset: 0;
    z-index: 1000;
    display: flex;
    flex-direction: column;
    padding: 20px;
    padding-top: 40px;
  }

  .airdrop-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 1px solid rgba(255,255,255,0.08);
    padding-bottom: 10px;
    margin-bottom: 15px;
  }

  .airdrop-header span {
    font-size: 15px;
    font-weight: bold;
    color: #c084fc;
  }

  .close-airdrop-btn {
    background: transparent;
    border: none;
    color: #a1a1aa;
    font-size: 16px;
    cursor: pointer;
    outline: none;
  }

  .airdrop-body {
    flex: 1;
    display: flex;
    flex-direction: column;
    overflow-y: auto;
  }

  .airdrop-loading {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 16px;
    color: #a1a1aa;
    font-size: 13px;
  }

  .radar-ping {
    width: 60px;
    height: 60px;
    border: 3px solid rgba(192, 132, 252, 0.4);
    border-radius: 50%;
    animation: radar 1.2s infinite;
  }

  @keyframes radar {
    0% { transform: scale(0.6); opacity: 1; }
    100% { transform: scale(1.3); opacity: 0; }
  }

  .airdrop-empty {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    color: #71717a;
    text-align: center;
    padding: 20px;
  }

  .airdrop-empty span {
    font-size: 32px;
  }

  .airdrop-empty p {
    font-size: 12px;
    margin: 0;
  }

  .airdrop-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .airdrop-item {
    background: rgba(255,255,255,0.04);
    border: 1px solid rgba(255,255,255,0.07);
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 2px;
    text-align: left;
    cursor: pointer;
    width: 100%;
    outline: none;
  }

  .airdrop-item:hover {
    background: rgba(138, 43, 226, 0.08);
    border-color: rgba(138, 43, 226, 0.3);
  }

  .airdrop-item-name {
    font-size: 13.5px;
    font-weight: 700;
  }

  .airdrop-item-sub {
    font-size: 10.5px;
    color: #71717a;
    font-weight: 500;
  }
</style>
