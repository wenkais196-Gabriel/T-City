<script lang="ts">
  import { playerData } from '../stores/phone';
  import { fetchNui } from '../utils/nui';
  import { onMount } from 'svelte';

  let feedList = $state<any[]>([]);
  let postInput = $state('');
  let isPosting = $state(false);

  const loadFeed = async () => {
    try {
      const res = await fetchNui('getCityFeed');
      if (res.success) {
        feedList = res.feed;
      }
    } catch (err) {
      console.error(err);
    }
  };

  const handlePost = async () => {
    if (!postInput.trim() || isPosting) return;
    isPosting = true;
    const text = postInput;
    postInput = '';

    try {
      const res = await fetchNui('postCityFeed', { content: text });
      if (res.success) {
        feedList = [res.post, ...feedList];
      }
    } catch (err) {
      console.error(err);
    } finally {
      isPosting = false;
    }
  };

  const handleLike = async (id: number) => {
    try {
      const res = await fetchNui('likeCityFeed', { id });
      if (res.success) {
        feedList = feedList.map(post => {
          if (post.id === id) {
            return { ...post, likes: res.likes };
          }
          return post;
        });
      }
    } catch (err) {
      console.error(err);
    }
  };

  const formatTime = (timeStr: string) => {
    const d = new Date(timeStr);
    return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
  };

  onMount(() => {
    loadFeed();
  });
</script>

<div class="cityfeed-app app-transition">
  <!-- App Header -->
  <div class="app-header">
    <span class="app-title">🐦 CityFeed</span>
  </div>

  <div class="app-content phone-scrollable">
    <!-- Posting Box -->
    <div class="post-box glass-card">
      <textarea 
        class="phone-input post-textarea" 
        placeholder="What's happening in City?" 
        maxlength="200"
        bind:value={postInput}
      ></textarea>
      <div class="post-actions-row">
        <span class="char-count">{postInput.length}/200</span>
        <button class="phone-btn post-btn" disabled={!postInput.trim() || isPosting} onclick={handlePost}>
          {isPosting ? 'Posting...' : 'Post'}
        </button>
      </div>
    </div>

    <!-- Feed Timeline -->
    {#if feedList.length === 0}
      <div class="empty-state">No feeds yet. Be the first to post!</div>
    {:else}
      <div class="feed-timeline">
        {#each feedList as post (post.id)}
          <div class="feed-card glass-card">
            <div class="feed-header">
              <span class="feed-author">@{post.name}</span>
              <span class="feed-time">{formatTime(post.timestamp)}</span>
            </div>
            <p class="feed-body">{post.content}</p>
            <div class="feed-footer">
              <button class="like-btn" onclick={() => handleLike(post.id)} aria-label="Like Post">
                ❤️ <span class="like-count">{post.likes}</span>
              </button>
            </div>
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .cityfeed-app {
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
    color: hsl(var(--phone-accent));
  }

  .app-content {
    flex: 1;
    overflow-y: auto;
    padding: 12px 16px;
    padding-bottom: 24px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  /* Post Box */
  .post-box {
    padding: 12px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .post-textarea {
    width: 100%;
    height: 65px;
    resize: none;
    box-sizing: border-box;
    font-size: 13px;
    font-family: inherit;
    padding: 8px 12px;
  }

  .post-actions-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .char-count {
    font-size: 11px;
    color: #666;
  }

  .post-btn {
    padding: 6px 14px;
    font-size: 12px;
  }

  /* Timeline */
  .feed-timeline {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .feed-card {
    padding: 12px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid rgba(255, 255, 255, 0.05);
  }

  .feed-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .feed-author {
    font-size: 12.5px;
    font-weight: 700;
    color: hsl(var(--phone-accent));
  }

  .feed-time {
    font-size: 10.5px;
    color: #555;
  }

  .feed-body {
    margin: 0;
    font-size: 13px;
    line-height: 1.45;
    color: #eee;
    word-break: break-word;
  }

  .feed-footer {
    display: flex;
    justify-content: flex-start;
    margin-top: 4px;
    border-top: 1px solid rgba(255, 255, 255, 0.03);
    padding-top: 6px;
  }

  .like-btn {
    background: transparent;
    border: none;
    color: #ef4444;
    font-size: 12.5px;
    cursor: pointer;
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 4px 8px;
    border-radius: 6px;
    transition: background 0.2s;
  }

  .like-btn:hover {
    background: rgba(239, 68, 68, 0.08);
  }

  .like-count {
    color: #aaa;
    font-size: 11.5px;
    font-weight: 600;
  }

  .empty-state {
    text-align: center;
    padding: 40px 10px;
    color: #555;
    font-size: 13px;
  }
</style>
