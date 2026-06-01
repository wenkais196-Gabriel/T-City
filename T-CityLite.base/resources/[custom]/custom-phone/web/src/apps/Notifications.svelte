<script lang="ts">
  import { notificationsList } from '../stores/phone';
  import { fetchNui } from '../utils/nui';

  const markAllRead = () => {
    notificationsList.update(list => list.map(n => ({ ...n, is_read: true })));
    fetchNui('markNotificationsRead').catch(err => console.error(err));
  };

  const clearAll = () => {
    notificationsList.set([]);
    fetchNui('clearNotifications').catch(err => console.error(err));
  };

  const handleDelete = (id: number) => {
    notificationsList.update(list => list.filter(n => n.id !== id));
    fetchNui('deleteNotification', { id }).catch(err => console.error(err));
  };

  const formatTime = (timeStr: string) => {
    const d = new Date(timeStr);
    return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
  };
</script>

<div class="notifications-app app-transition">
  <!-- App Header -->
  <div class="app-header">
    <span class="app-title">📢 Notifications</span>
    <div class="actions">
      {#if $notificationsList.length > 0}
        <button class="header-action-btn" onclick={markAllRead}>Read All</button>
        <button class="header-action-btn clear-btn" onclick={clearAll}>Clear</button>
      {/if}
    </div>
  </div>

  <div class="app-content phone-scrollable">
    {#if $notificationsList.length === 0}
      <div class="empty-state">
        <span class="bell-icon">🔔</span>
        <span class="txt">Your notification tray is empty</span>
      </div>
    {:else}
      <div class="notif-list">
        {#each $notificationsList as notif (notif.id)}
          <div class="notif-item glass-card {!notif.is_read ? 'unread' : ''}">
            <div class="notif-header">
              <span class="notif-tag">SYSTEM</span>
              <span class="notif-time">{formatTime(notif.timestamp)}</span>
            </div>
            <span class="notif-title">{notif.title}</span>
            <p class="notif-body">{notif.content}</p>
            <button class="delete-btn" onclick={() => handleDelete(notif.id)} aria-label="Delete Notification">✕</button>
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .notifications-app {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: #09090b;
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

  .actions {
    display: flex;
    gap: 10px;
  }

  .header-action-btn {
    background: transparent;
    border: none;
    color: hsl(var(--phone-accent));
    font-size: 11.5px;
    font-weight: 600;
    cursor: pointer;
  }

  .clear-btn {
    color: #ef4444;
  }

  .app-content {
    flex: 1;
    overflow-y: auto;
    padding: 12px 16px;
    padding-bottom: 24px;
  }

  /* List */
  .notif-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .notif-item {
    position: relative;
    padding: 12px;
    padding-right: 28px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.05);
  }

  .notif-item.unread {
    background: rgba(138, 43, 226, 0.03);
    border-left: 3px solid hsl(var(--phone-accent));
  }

  .notif-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .notif-tag {
    font-size: 8.5px;
    font-weight: 700;
    color: hsl(var(--phone-accent));
    letter-spacing: 0.5px;
    background: rgba(138, 43, 226, 0.15);
    padding: 2px 6px;
    border-radius: 4px;
  }

  .notif-time {
    font-size: 10.5px;
    color: #666;
  }

  .notif-title {
    font-size: 13.5px;
    font-weight: 700;
    margin-top: 2px;
  }

  .notif-body {
    margin: 0;
    font-size: 12px;
    line-height: 1.4;
    color: #bbb;
  }

  .delete-btn {
    position: absolute;
    top: 10px;
    right: 10px;
    background: transparent;
    border: none;
    color: #555;
    font-size: 11px;
    cursor: pointer;
    padding: 4px;
  }

  .delete-btn:hover {
    color: #ef4444;
  }

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 60px 10px;
    color: #555;
    gap: 8px;
  }

  .bell-icon {
    font-size: 32px;
  }

  .txt {
    font-size: 13px;
  }
</style>
