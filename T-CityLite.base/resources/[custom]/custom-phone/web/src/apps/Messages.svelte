<script lang="ts">
  import { smsThreads, messagesList, playerData, contactsList } from '../stores/phone';
  import { fetchNui } from '../utils/nui';
  import { onMount, tick } from 'svelte';

  let activeThreadNum = $state<string | null>(null);
  let activeThreadName = $state<string>('');
  let messageInput = $state('');
  let chatScrollEl = $state<HTMLDivElement | null>(null);

  // Check if a target phone number was pre-selected (from Contacts app)
  onMount(() => {
    const preNum = (window as any).phoneTargetNumber;
    if (preNum) {
      openThread(preNum);
      (window as any).phoneTargetNumber = null; // Clear pre-selection
    }
  });

  // Filter messages belonging to the active thread
  let threadMessages = $derived(
    activeThreadNum 
      ? $messagesList.filter(
          m => (m.sender_number === activeThreadNum && m.receiver_number === $playerData.phone) ||
               (m.sender_number === $playerData.phone && m.receiver_number === activeThreadNum)
        ).sort((a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime())
      : []
  );

  const openThread = (number: string) => {
    activeThreadNum = number;
    const contact = $contactsList.find(c => c.number === number);
    activeThreadName = contact ? contact.name : number;
    
    // Mark messages in this thread as read on the backend
    fetchNui('markMessagesRead', { sender_number: number }).then(() => {
      // Synchronize in local store
      messagesList.update(list => list.map(m => {
        if (m.sender_number === number && m.receiver_number === $playerData.phone) {
          return { ...m, is_read: true };
        }
        return m;
      }));
    }).catch(err => console.error(err));

    scrollToBottom();
  };

  const closeThread = () => {
    activeThreadNum = null;
  };

  const handleSendMessage = async () => {
    if (!messageInput.trim() || !activeThreadNum) return;
    const textToSend = messageInput;
    messageInput = ''; // Quick input reset

    try {
      const res = await fetchNui('sendMessage', {
        receiver_number: activeThreadNum,
        message: textToSend
      });

      if (res.success) {
        messagesList.update(list => [...list, res.message]);
        scrollToBottom();
      }
    } catch (err) {
      console.error('Failed to send SMS', err);
    }
  };

  const scrollToBottom = async () => {
    await tick();
    if (chatScrollEl) {
      chatScrollEl.scrollTop = chatScrollEl.scrollHeight;
    }
  };

  // Format time helper
  const formatTime = (timeStr: string) => {
    const d = new Date(timeStr);
    return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
  };

  // Auto-scroll when new messages arrive in open thread
  $effect(() => {
    if (threadMessages.length > 0) {
      scrollToBottom();
    }
  });
</script>

<div class="messages-app app-transition">
  {#if activeThreadNum === null}
    <!-- Thread List View -->
    <div class="app-header">
      <span class="app-title">💬 Messages</span>
    </div>

    <div class="app-content phone-scrollable">
      {#if $smsThreads.length === 0}
        <div class="empty-state">No conversations yet</div>
      {:else}
        <div class="threads-list">
          {#each $smsThreads as thread (thread.number)}
            <button class="thread-item glass-card" onclick={() => openThread(thread.number)}>
              <div class="avatar">{thread.name.charAt(0).toUpperCase()}</div>
              <div class="thread-details">
                <div class="thread-row">
                  <span class="thread-name">{thread.name}</span>
                  <span class="thread-time">{formatTime(thread.latestTime)}</span>
                </div>
                <div class="thread-row">
                  <span class="thread-snippet">{thread.latestMessage}</span>
                  {#if thread.hasUnread}
                    <span class="unread-dot"></span>
                  {/if}
                </div>
              </div>
            </button>
          {/each}
        </div>
      {/if}
    </div>
  {:else}
    <!-- Chat Thread View -->
    <div class="app-header chat-header">
      <button class="back-btn" onclick={closeThread} aria-label="Back">◀</button>
      <div class="header-avatar">{activeThreadName.charAt(0).toUpperCase()}</div>
      <div class="header-details">
        <span class="chat-title">{activeThreadName}</span>
        <span class="chat-status">{activeThreadNum}</span>
      </div>
    </div>

    <div class="chat-body phone-scrollable" bind:this={chatScrollEl}>
      {#if threadMessages.length === 0}
        <div class="empty-chat">No messages yet. Send a greeting!</div>
      {:else}
        <div class="messages-bubble-container">
          {#each threadMessages as msg (msg.id)}
            {@const isMe = msg.sender_number === $playerData.phone}
            <div class="message-bubble-wrapper {isMe ? 'me' : 'them'}">
              <div class="message-bubble">
                <p class="bubble-text">{msg.message}</p>
                {#if msg.gps && msg.gps.x}
                  {#if msg.status === 'active'}
                    <button class="gps-btn gps-active"
                      onclick={() => fetchNui('setGpsRoute', { x: msg.gps.x, y: msg.gps.y, label: msg.gps.label })}>
                      📍 设置导航: {msg.gps.label || '目的地'}
                    </button>
                  {:else if msg.status === 'done' || msg.status === 'expired'}
                    <span class="gps-done">📍 {msg.gps.label || '目的地'}（已完成）</span>
                  {:else}
                    <span class="gps-inactive">📍 {msg.gps.label || '目的地'}</span>
                  {/if}
                {/if}
                <span class="bubble-time">{formatTime(msg.timestamp || msg.date)}</span>
              </div>
            </div>
          {/each}
        </div>
      {/if}
    </div>

    <!-- Message Input Bar -->
    <form class="chat-input-bar" onsubmit={(e) => { e.preventDefault(); handleSendMessage(); }}>
      <input type="text" class="phone-input chat-input" placeholder="Type a message..." bind:value={messageInput} />
      <button type="submit" class="send-btn" aria-label="Send message">➔</button>
    </form>
  {/if}
</div>

<style>
  .messages-app {
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
  }

  /* Threads List */
  .threads-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .thread-item {
    display: flex;
    align-items: center;
    width: 100%;
    padding: 12px;
    text-align: left;
    color: #fff;
    cursor: pointer;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.05);
  }

  .avatar {
    width: 40px;
    height: 40px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.08);
    font-size: 16px;
    font-weight: 700;
    display: flex;
    align-items: center;
    justify-content: center;
    margin-right: 12px;
    border: 1px solid rgba(255, 255, 255, 0.1);
  }

  .thread-details {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  .thread-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .thread-name {
    font-size: 14.5px;
    font-weight: 600;
  }

  .thread-time {
    font-size: 11px;
    color: #666;
  }

  .thread-snippet {
    font-size: 12.5px;
    color: #999;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 190px;
  }

  .unread-dot {
    width: 8px;
    height: 8px;
    background: hsl(var(--phone-accent));
    border-radius: 50%;
  }

  /* Chat View Layout */
  .chat-header {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .back-btn {
    background: transparent;
    border: none;
    color: hsl(var(--phone-accent));
    font-size: 16px;
    cursor: pointer;
    padding: 4px;
  }

  .header-avatar {
    width: 32px;
    height: 32px;
    border-radius: 50%;
    background: hsl(var(--phone-accent));
    font-size: 14px;
    font-weight: 700;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .header-details {
    display: flex;
    flex-direction: column;
  }

  .chat-title {
    font-size: 14px;
    font-weight: 600;
  }

  .chat-status {
    font-size: 10.5px;
    color: #666;
  }

  .chat-body {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
    background: #09090b;
  }

  .messages-bubble-container {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .message-bubble-wrapper {
    display: flex;
    width: 100%;
  }

  .message-bubble-wrapper.me {
    justify-content: flex-end;
  }

  .message-bubble-wrapper.them {
    justify-content: flex-start;
  }

  .message-bubble {
    max-width: 75%;
    padding: 9px 13px;
    border-radius: 18px;
    display: flex;
    flex-direction: column;
    gap: 3px;
    box-shadow: 0 2px 4px rgba(0, 0, 0, 0.15);
  }

  .me .message-bubble {
    background: hsl(var(--phone-accent));
    color: #fff;
    border-bottom-right-radius: 4px;
  }

  .them .message-bubble {
    background: #1f1f23;
    color: #fff;
    border-bottom-left-radius: 4px;
  }

  .bubble-text {
    margin: 0;
    font-size: 13.5px;
    line-height: 1.45;
    word-break: break-word;
  }

  .bubble-time {
    font-size: 9.5px;
    align-self: flex-end;
    opacity: 0.6;
  }

  .chat-input-bar {
    height: 60px;
    border-top: 1px solid #1f1f23;
    padding: 10px 14px;
    display: flex;
    gap: 10px;
    align-items: center;
    box-sizing: border-box;
  }

  .chat-input {
    flex: 1;
    border-radius: 20px;
    box-sizing: border-box;
    font-size: 13px;
  }

  .send-btn {
    width: 38px;
    height: 38px;
    border-radius: 50%;
    background: hsl(var(--phone-accent));
    color: #fff;
    border: none;
    font-size: 15px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: background 0.2s, transform 0.2s;
  }

  .send-btn:hover {
    background: hsl(var(--phone-accent-hover));
  }

  .send-btn:active {
    transform: scale(0.92);
  }

  .empty-chat {
    text-align: center;
    padding: 50px 10px;
    color: #555;
    font-size: 13px;
  }

  .empty-state {
    text-align: center;
    padding: 50px 10px;
    color: #555;
    font-size: 13.5px;
  }

  /* GPS Route Button */
  .gps-btn {
    display: block;
    margin-top: 8px;
    padding: 7px 12px;
    border-radius: 12px;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
    border: none;
    width: 100%;
    text-align: center;
    transition: all 0.2s;
  }

  .gps-active {
    background: linear-gradient(135deg, hsl(var(--phone-accent)), color-mix(in srgb, hsl(var(--phone-accent)) 70%, #fff));
    color: #fff;
    box-shadow: 0 2px 8px rgba(168, 85, 247, 0.35);
  }

  .gps-active:hover {
    transform: scale(1.03);
    box-shadow: 0 3px 14px rgba(168, 85, 247, 0.5);
  }

  .gps-active:active {
    transform: scale(0.95);
  }

  .gps-done {
    display: block;
    margin-top: 6px;
    padding: 4px 8px;
    font-size: 11px;
    color: #666;
    text-decoration: line-through;
  }

  .gps-inactive {
    display: block;
    margin-top: 6px;
    padding: 4px 8px;
    font-size: 11px;
    color: #888;
  }
</style>
