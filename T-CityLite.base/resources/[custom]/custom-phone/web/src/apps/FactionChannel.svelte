<script lang="ts">
  import { factionMessages, playerData } from '../stores/phone';
  import { fetchNui } from '../utils/nui';
  import { onMount, tick } from 'svelte';

  let inputVal = $state('');
  let chatScrollEl = $state<HTMLDivElement | null>(null);

  const handleSendMessage = async () => {
    if (!inputVal.trim()) return;
    const textToSend = inputVal;
    inputVal = '';

    try {
      const res = await fetchNui('sendFactionMessage', { content: textToSend });
      if (res.success) {
        factionMessages.update(list => [...list, res.message]);
        scrollToBottom();
      }
    } catch (err) {
      console.error(err);
    }
  };

  const scrollToBottom = async () => {
    await tick();
    if (chatScrollEl) {
      chatScrollEl.scrollTop = chatScrollEl.scrollHeight;
    }
  };

  const formatTime = (epoch: number) => {
    const d = new Date(epoch * 1000);
    return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
  };

  onMount(() => {
    scrollToBottom();
  });

  // Auto-scroll on new messages
  $effect(() => {
    if ($factionMessages.length > 0) {
      scrollToBottom();
    }
  });

  // Get human readable faction name
  const getFactionLabel = (role: string) => {
    switch (role) {
      case 'police': return '👮 LSPD Tactical Radio';
      case 'medic': return '🚑 EMT Dispatch Frequency';
      case 'gang': return '🔫 Secure Gang Network';
      default: return '📢 Public Frequency';
    }
  };
</script>

<div class="faction-app app-transition">
  <!-- App Header -->
  <div class="app-header">
    <span class="app-title">{getFactionLabel($playerData.career.primary_role)}</span>
  </div>

  <!-- Messages Body -->
  <div class="chat-body phone-scrollable" bind:this={chatScrollEl}>
    {#if $factionMessages.length === 0}
      <div class="empty-chat">Channel is silent. Type below to broadcast to all members.</div>
    {:else}
      <div class="faction-msgs-container">
        {#each $factionMessages as msg}
          {@const isMe = msg.sender === $playerData.name}
          <div class="faction-msg-card glass-card {isMe ? 'me' : ''}">
            <div class="msg-header">
              <span class="msg-sender">{msg.sender}</span>
              <span class="msg-time">{formatTime(msg.time)}</span>
            </div>
            <p class="msg-content">{msg.content}</p>
          </div>
        {/each}
      </div>
    {/if}
  </div>

  <!-- Input Bar -->
  <form class="chat-input-bar" onsubmit={(e) => { e.preventDefault(); handleSendMessage(); }}>
    <input type="text" class="phone-input chat-input" placeholder="Broadcast to group..." bind:value={inputVal} />
    <button type="submit" class="send-btn" aria-label="Broadcast">➔</button>
  </form>
</div>

<style>
  .faction-app {
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
    font-size: 13.5px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.3px;
  }

  .chat-body {
    flex: 1;
    overflow-y: auto;
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    background: #09090b;
  }

  .faction-msgs-container {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .faction-msg-card {
    padding: 10px 12px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.05);
  }

  .faction-msg-card.me {
    border-left: 3px solid hsl(var(--phone-accent));
    background: rgba(138, 43, 226, 0.03);
  }

  .msg-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .msg-sender {
    font-size: 11.5px;
    font-weight: 700;
    color: #bbb;
  }

  .me .msg-sender {
    color: hsl(var(--phone-accent));
  }

  .msg-time {
    font-size: 9.5px;
    color: #555;
  }

  .msg-content {
    margin: 0;
    font-size: 13px;
    line-height: 1.4;
    color: #fff;
    word-break: break-word;
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
    padding: 60px 10px;
    color: #555;
    font-size: 13px;
  }
</style>
