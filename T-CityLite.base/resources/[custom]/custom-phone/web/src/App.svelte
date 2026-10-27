<script lang="ts">
  import DeviceShell from './components/DeviceShell.svelte';
  import Contacts from './apps/Contacts.svelte';
  import Messages from './apps/Messages.svelte';
  import Banking from './apps/Banking.svelte';
  import Notifications from './apps/Notifications.svelte';
  import JobBoard from './apps/JobBoard.svelte';
  import FactionChannel from './apps/FactionChannel.svelte';
  import CityFeed from './apps/CityFeed.svelte';
  import Settings from './apps/Settings.svelte';
  import DynamicApp from './apps/DynamicApp.svelte';
  import { dynamicApps, loadDynamicApps } from './stores/apps';
  import { getApp } from './core/appRegistry';

  // v0.4.2 Premium features
  import PhoneCall from './apps/PhoneCall.svelte';
  import Garage from './apps/Garage.svelte';
  import Hotlines from './apps/Hotlines.svelte';

  // Leader Apps
  import MayorApp from './apps/leader/MayorApp.svelte';
  import SheriffApp from './apps/leader/SheriffApp.svelte';
  import GangBossApp from './apps/leader/GangBossApp.svelte';

  import { registerNuiEvent, isBrowser, fetchNui } from './utils/nui';
  if (typeof window !== 'undefined') {
    window.addEventListener('error', (event) => {
      void fetchNui('clientError', { message: String(event.message), stack: String(event.error?.stack ?? '') }).catch(() => {});
    });
    window.addEventListener('unhandledrejection', (event) => {
      void fetchNui('clientError', { message: String(event.reason), stack: '' }).catch(() => {});
    });
  }

  import {
    isPhoneOpen,
    surface,
    activeApp,
    playerData,
    messagesList,
    notificationsList,
    jobBoardTasks,
    factionMessages,
    unreadMessagesCount,
    unreadNotificationsCount,
    gameTime,
    loadPhoneData,
    closePhone
  } from './stores/phone';
  import { showSubtitle, clearSubtitle } from './stores/callSpeech';
  import { speakDispatch, stopDispatchSpeech } from './utils/tts';
  import {
    callPhase,
    handleIncomingCall,
    handleCallAnswered,
    handleCallEnded,
    endActiveCall
  } from './stores/call';
  import { get } from 'svelte/store';
  import { isSurface } from './core/surface';
  import { onMount } from 'svelte';

  // Background Wallpaper: a themed CSS gradient defined in app.css (no remote
  // image request, so opening the phone stays instant).

  // Game Time 由 phone:updateTime 写入共享 store
  let gameDayName = $state('Sunday');
  let gameDate = $state('May 31');

  onMount(() => {
    // 视口上报：surface 的阈值判定在 Lua，但只有 CEF 知道真实 CSS px。
    const reportViewport = () => {
      void fetchNui('surfaceInfo', { width: window.innerWidth, height: window.innerHeight }).catch(() => {});
    };
    reportViewport();
    window.addEventListener('resize', reportViewport);

    // 1. Listen for Phone Open signal from Lua
    registerNuiEvent('phone:open', (data) => {
      // 外壳形态由 Lua 决定；UI 只是照做。非法值一律退回手机，绝不猜。
      surface.set(isSurface(data?.surface) ? data.surface : 'phone');
      isPhoneOpen.set(true);
      // Keep the call screen if a call is still ringing/ongoing when reopened.
      activeApp.set(get(callPhase) === 'idle' ? 'home' : 'phonecall');
      loadPhoneData();
      void loadDynamicApps();
      // Prove to the client that this frame exists: it resends phone:open until
      // this answer arrives, because SendNUIMessage into a loading CEF page is
      // silently dropped.
      void fetchNui('phoneOpenAck').catch(() => {});
    });

    // Dispatch / agent voice line: CEF speaks it locally, subtitle mirrors it.
    registerNuiEvent('phone:systemSpeech', (data) => {
      const text = data && typeof data.text === 'string' ? data.text : '';
      if (!text) return;
      showSubtitle(text);
      speakDispatch(text);
    });

    // 2. Listen for Phone Close signal
    registerNuiEvent('phone:close', (data) => {
      isPhoneOpen.set(false);
      // reason='switch' 是"换形态"而不是"退出"：别把玩家从 MDT 里踢回桌面。
      if (data?.reason !== 'switch') activeApp.set('home');
      stopDispatchSpeech();
      clearSubtitle();
      // The screen is gone, so end/decline any active call instead of leaving a
      // zombie call ringing until the timeout.
      if (get(callPhase) !== 'idle') void endActiveCall();
    });

    // Money real-time updates
    registerNuiEvent('phone:updateMoney', (data) => {
      if (data && data.money) {
        playerData.update(pd => {
          pd.money = data.money;
          return pd;
        });
      }
    });

    // 3. New SMS message pushes
    registerNuiEvent('phone:newMessage', (data) => {
      if (data && data.message) {
        messagesList.update(list => [...list, data.message]);
      }
    });

    // 4. New System Notifications
    registerNuiEvent('phone:newNotification', (data) => {
      if (data && data.notification) {
        notificationsList.update(list => [data.notification, ...list]);
      }
    });

    // 5. New Job Board tasks published
    registerNuiEvent('phone:jobboard:newJob', (data) => {
      if (data && data.job) {
        jobBoardTasks.update(list => [data.job, ...list]);
      }
    });

    // 6. Faction group chat message receive
    registerNuiEvent('phone:faction:receive', (data) => {
      if (data && data.message) {
        factionMessages.update(list => [...list, data.message]);
      }
    });

    // 6b. Call events are global: App.svelte is always mounted, while PhoneCall
    // only exists inside the phone, so receiving them there lost every call
    // that arrived from Home or while the phone was closed (audit B04).
    registerNuiEvent('phone:incomingCall', (data) => {
      handleIncomingCall(data?.callData);
    });
    registerNuiEvent('phone:callAnswered', (data) => {
      handleCallAnswered(data);
    });
    registerNuiEvent('phone:callEnded', (data) => {
      handleCallEnded(data);
    });

    // 7. Dynamic Leader registration updates
    registerNuiEvent('phone:registerLeaderApp', (data) => {
      playerData.update(pd => {
        pd.career.rank_tier = 'leader';
        pd.career.primary_role = data.role;
        return pd;
      });
    });

    registerNuiEvent('phone:removeLeaderApp', () => {
      playerData.update(pd => {
        pd.career.rank_tier = 'entry';
        return pd;
      });
      // Force exit leader app if player was currently in it
      activeApp.update(app => app.startsWith('leader_') ? 'home' : app);
    });

    // 8. Game Time sync from Lua (GTA V native clock)
    registerNuiEvent('phone:updateTime', (data) => {
      if (data) {
        gameTime.set({ hour: data.hour ?? 0, minute: data.minute ?? 0 });
        gameDayName = data.dayName;
        gameDate = data.date;
      }
    });

    // Global keydown: ESC closes the phone, M toggles it closed — but only while
    // the phone is open, without ctrl/meta/alt, and never while typing in a form
    // field. Typing "me"/"message" used to close the phone mid-word (audit B05).
    const isEditableTarget = (target: EventTarget | null) => {
      const el = target as HTMLElement | null;
      if (!el) return false;
      if (el.isContentEditable) return true;
      const tag = el.tagName;
      return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
    };

    const handleKeyDown = (e: KeyboardEvent) => {
      if (!get(isPhoneOpen)) return;
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.key === 'Escape') {
        closePhone();
        return;
      }
      // M 不在这里处理：它是 Lua 的 key mapping，开/关状态机归 Surface/PhoneFocus 保管。
      // keepInput=true 意味着这一下按键**同时**到达游戏和 CEF —— 两边都"关一次"的结果
      // 是：开着的时候按 M，Lua 关、CFE 也关（幂等）；但刚打开的那一帧 CEF 已经挂好了，
      // keydown 又把它关掉，表现就是"按 M 有时开有时不开"。实测 2026-10-27：真机按 M
      // 出现 open-start → close-start 成对出现，手机闪一下就没。所以 M 只留给 Lua。
    };
    window.addEventListener('keydown', handleKeyDown);

    // Right-click closes the phone (previously a client control check; CEF
    // consumes the context menu when NUI has focus, so handle it here too).
    const handleContextMenu = (e: MouseEvent) => {
      if (!get(isPhoneOpen)) return;
      e.preventDefault();
      closePhone();
    };
    window.addEventListener('contextmenu', handleContextMenu);

    // If running in browser, auto open for preview and set modern background
    if (isBrowser()) {
      isPhoneOpen.set(true);
      loadPhoneData();
      document.body.style.background = '#111115';
    }

    return () => {
      window.removeEventListener('keydown', handleKeyDown);
      window.removeEventListener('contextmenu', handleContextMenu);
    };
  });

  const getLeaderAppIcon = (role: string) => {
    switch (role) {
      case 'mayor': return { name: 'Executive', icon: '🏛️', app: 'leader_mayor' };
      case 'police': return { name: 'Command', icon: '👮', app: 'leader_sheriff' };
      case 'gang': return { name: 'Syndicate', icon: '👁️', app: 'leader_gangboss' };
      default: return null;
    }
  };

  let leaderApp = $derived(
    $playerData.career.rank_tier === 'leader' 
      ? getLeaderAppIcon($playerData.career.primary_role) 
      : null
  );
</script>

{#if $isPhoneOpen}
  <DeviceShell surface={$surface}>
    <!-- Background Wallpaper -->
    <div class="phone-wallpaper">
      <div class="wallpaper-dim"></div>
    </div>

    {#if $activeApp === 'home'}
      <!-- iOS-Style Premium Home Screen -->
      <div class="home-screen app-transition">
        <!-- Widget Area (Game Time Sync) -->
        <div class="widget-area glass-effect">
          <div class="widget-time-row">
            <span class="widget-time">{String($gameTime.hour).padStart(2, '0')}:{String($gameTime.minute).padStart(2, '0')}</span>
            <span class="widget-day">{gameDayName} · {gameDate}</span>
          </div>
          <div class="widget-details">
            <span class="widget-temp">72°F</span>
            <span class="widget-cond">☀️ Sunny</span>
          </div>
        </div>

        <!-- Apps Grid -->
        <div class="apps-grid">
          <button class="app-icon-wrapper" onclick={() => activeApp.set('phonecall')} aria-label="Phone Dialer">
            <div class="app-icon phonecall-bg">📞</div>
            <span class="app-label">Phone</span>
          </button>

          <button class="app-icon-wrapper" onclick={() => activeApp.set('contacts')} aria-label="Contacts">
            <div class="app-icon contacts-bg">👤</div>
            <span class="app-label">Contacts</span>
          </button>

          <button class="app-icon-wrapper" onclick={() => activeApp.set('messages')} aria-label="Messages">
            <div class="app-icon messages-bg">💬</div>
            {#if $unreadMessagesCount > 0}
              <span class="badge">{$unreadMessagesCount}</span>
            {/if}
            <span class="app-label">Messages</span>
          </button>

          <button class="app-icon-wrapper" onclick={() => activeApp.set('banking')} aria-label="Banking">
            <div class="app-icon banking-bg">🏦</div>
            <span class="app-label">Banking</span>
          </button>

          <button class="app-icon-wrapper" onclick={() => activeApp.set('garage')} aria-label="Smart Garage">
            <div class="app-icon garage-bg">🚗</div>
            <span class="app-label">Garage</span>
          </button>

          <button class="app-icon-wrapper" onclick={() => activeApp.set('hotlines')} aria-label="Service Hotlines">
            <div class="app-icon hotlines-bg">☎️</div>
            <span class="app-label">Hotlines</span>
          </button>

          <button class="app-icon-wrapper" onclick={() => activeApp.set('notifications')} aria-label="Notifications">
            <div class="app-icon notifications-bg">📢</div>
            {#if $unreadNotificationsCount > 0}
              <span class="badge">{$unreadNotificationsCount}</span>
            {/if}
            <span class="app-label">Notifs</span>
          </button>

          <button class="app-icon-wrapper" onclick={() => activeApp.set('jobboard')} aria-label="Job Board">
            <div class="app-icon jobboard-bg">📋</div>
            <span class="app-label">Job Board</span>
          </button>

          <button class="app-icon-wrapper" onclick={() => activeApp.set('faction')} aria-label="Faction Channel">
            <div class="app-icon faction-bg">📡</div>
            <span class="app-label">Radio</span>
          </button>

          <button class="app-icon-wrapper" onclick={() => activeApp.set('cityfeed')} aria-label="City Feed">
            <div class="app-icon cityfeed-bg">🐦</div>
            <span class="app-label">CityFeed</span>
          </button>

          <button class="app-icon-wrapper" onclick={() => activeApp.set('settings')} aria-label="Settings">
            <div class="app-icon settings-bg">⚙️</div>
            <span class="app-label">Settings</span>
          </button>

          <!-- Job app registry tiles (server-filtered) -->
          {#each $dynamicApps as app (app.id)}
            <button class="app-icon-wrapper app-transition" onclick={() => activeApp.set(`dyn:${app.id}`)} aria-label={app.label}>
              <div class="app-icon leader-bg">{app.icon}</div>
              <span class="app-label">{app.label}</span>
            </button>
          {/each}

          <!-- Dynamic Leader App Icon -->
          {#if leaderApp}
            <button class="app-icon-wrapper app-transition" onclick={() => activeApp.set(leaderApp.app)} aria-label={leaderApp.name}>
              <div class="app-icon leader-bg">{leaderApp.icon}</div>
              <span class="app-label">{leaderApp.name}</span>
            </button>
          {/if}
        </div>

        <!-- Hot Dock -->
        <div class="hot-dock glass-effect">
          <button class="dock-icon-wrapper" onclick={() => activeApp.set('phonecall')} aria-label="Quick Dialer">
            <div class="dock-icon phonecall-bg">📞</div>
          </button>
          <button class="dock-icon-wrapper" onclick={() => activeApp.set('messages')} aria-label="Quick Messages">
            <div class="dock-icon messages-bg">💬</div>
            {#if $unreadMessagesCount > 0}
              <span class="badge">{$unreadMessagesCount}</span>
            {/if}
          </button>
          <button class="dock-icon-wrapper" onclick={() => activeApp.set('banking')} aria-label="Quick Banking">
            <div class="dock-icon banking-bg">🏦</div>
          </button>
          <button class="dock-icon-wrapper" onclick={() => activeApp.set('jobboard')} aria-label="Quick Job Board">
            <div class="dock-icon jobboard-bg">📋</div>
          </button>
        </div>
      </div>
    {:else}
      <!-- Render active application -->
      <div class="active-app-host">
        {#if $activeApp === 'contacts'}
          <Contacts />
        {:else if $activeApp === 'messages'}
          <Messages />
        {:else if $activeApp === 'banking'}
          <Banking />
        {:else if $activeApp === 'phonecall'}
          <PhoneCall />
        {:else if $activeApp === 'garage'}
          <Garage />
        {:else if $activeApp === 'hotlines'}
          <Hotlines />
        {:else if $activeApp === 'notifications'}
          <Notifications />
        {:else if $activeApp === 'jobboard'}
          <JobBoard />
        {:else if $activeApp === 'faction'}
          <FactionChannel />
        {:else if $activeApp === 'cityfeed'}
          <CityFeed />
        {:else if $activeApp === 'settings'}
          <Settings />
        {:else if $activeApp === 'leader_mayor'}
          <MayorApp />
        {:else if $activeApp === 'leader_sheriff'}
          <SheriffApp />
        {:else if $activeApp === 'leader_gangboss'}
          <GangBossApp />
        {:else if $activeApp.startsWith('dyn:')}
          {@const dynApp = getApp($activeApp.slice(4))}
          {#if dynApp}
            {@const AppComponent = dynApp.component}
            <AppComponent />
          {:else}
            <DynamicApp appId={$activeApp.slice(4)} />
          {/if}
        {/if}
      </div>
    {/if}
  </DeviceShell>
{/if}

<!-- Browser development quick trigger tools (hidden in game) -->
{#if isBrowser()}
  <div class="nui-preview-panel">
    <h3>📱 PHONE PREVIEW</h3>
    <div class="panel-row">
      <button onclick={() => (window as any).triggerMockPhoneOpen('civilian', 'entry')}>Civilian Entry</button>
      <button onclick={() => (window as any).triggerMockPhoneOpen('mayor', 'leader')}>Mayor (Leader)</button>
    </div>
    <div class="panel-row">
      <button onclick={() => (window as any).triggerMockPhoneOpen('police', 'leader')}>Sheriff (Leader)</button>
      <button onclick={() => (window as any).triggerMockPhoneOpen('gang', 'leader')}>Godfather (Leader)</button>
    </div>
    <div class="panel-row">
      <button onclick={() => {
        notificationsList.update(list => [{
          id: Math.floor(Math.random() * 10000),
          title: '🚨 Tactical Dispatch',
          content: 'LSPD units dispatched to Vinewood jewelry heist.',
          timestamp: new Date().toISOString(),
          is_read: false
        }, ...list]);
      }}>Trigger Notif</button>
      <button onclick={() => {
        isPhoneOpen.set(false);
      }}>Close Phone</button>
    </div>
  </div>
{/if}

<style>
  /* Wallpaper Background */
  .phone-wallpaper {
    position: absolute;
    inset: 0;
    background: var(--phone-wallpaper);
    z-index: 0;
  }

  .wallpaper-dim {
    position: absolute;
    inset: 0;
    background: var(--phone-wallpaper-dim);
  }

  .active-app-host {
    position: relative;
    width: 100%;
    height: 100%;
    z-index: 10;
  }

  /* Home Screen */
  .home-screen {
    position: relative;
    display: flex;
    flex-direction: column;
    height: 100%;
    z-index: 10;
    padding: 24px 20px;
    padding-top: 15px;
    box-sizing: border-box;
    justify-content: space-between;
  }

  /* Widget */
  .widget-area {
    height: 70px;
    border-radius: 18px;
    padding: 12px 16px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    box-sizing: border-box;
    background: var(--phone-glass-bg);
    border: 1px solid var(--phone-glass-border);
  }

  .widget-time-row {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .widget-time {
    font-size: 42px;
    font-weight: 800;
    font-family: 'Outfit', sans-serif;
    letter-spacing: 2px;
    line-height: 1;
    color: var(--phone-home-text);
  }

  .widget-day {
    font-size: 13px;
    font-weight: 600;
    color: var(--phone-home-muted);
    font-family: 'Outfit', sans-serif;
    margin-top: 2px;
  }

  .widget-details {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 2px;
  }

  .widget-temp {
    font-size: 16px;
    font-weight: 800;
    color: var(--phone-home-accent);
  }

  .widget-cond {
    font-size: 10.5px;
    font-weight: 600;
    color: var(--phone-home-muted-2);
  }

  /* App Icons Grid */
  .apps-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    grid-gap: 16px 12px;
    margin-top: 25px;
    flex: 1;
    align-content: flex-start;
  }

  .app-icon-wrapper {
    position: relative;
    background: transparent;
    border: none;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 6px;
    color: #fff;
    cursor: pointer;
    transition: transform 0.2s;
    outline: none;
    padding: 0;
  }

  .app-icon-wrapper:hover {
    transform: scale(1.08);
  }

  .app-icon-wrapper:active {
    transform: scale(0.95);
  }

  .app-icon {
    width: 54px;
    height: 54px;
    border-radius: 13px;
    font-size: 26px;
    display: flex;
    align-items: center;
    justify-content: center;
    box-shadow: 0 4px 10px rgba(0, 0, 0, 0.35);
    border: 1px solid rgba(255, 255, 255, 0.08);
    transition: filter 0.2s;
  }

  /* Distinct App BG gradients */
  .phonecall-bg { background: linear-gradient(135deg, #22c55e 0%, #16a34a 100%); }
  .contacts-bg { background: linear-gradient(135deg, #10b981 0%, #047857 100%); }
  .messages-bg { background: linear-gradient(135deg, #2563eb 0%, #1d4ed8 100%); }
  .banking-bg { background: linear-gradient(135deg, #a855f7 0%, #7e22ce 100%); }
  .garage-bg { background: linear-gradient(135deg, #f59e0b 0%, #d97706 100%); }
  .hotlines-bg { background: linear-gradient(135deg, #636e72 0%, #2d3436 100%); }
  .notifications-bg { background: linear-gradient(135deg, #f59e0b 0%, #d97706 100%); }
  .jobboard-bg { background: linear-gradient(135deg, #06b6d4 0%, #0891b2 100%); }
  .faction-bg { background: linear-gradient(135deg, #ec4899 0%, #be185d 100%); }
  .cityfeed-bg { background: linear-gradient(135deg, #0ea5e9 0%, #0284c7 100%); }
  .settings-bg { background: linear-gradient(135deg, #64748b 0%, #334155 100%); }
  .leader-bg { background: linear-gradient(135deg, #ef4444 0%, #b91c1c 100%); }

  .app-label {
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.1px;
    color: var(--phone-home-text);
    text-shadow: var(--phone-home-label-shadow);
    text-align: center;
    max-width: 65px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  /* Badge indicator */
  .badge {
    position: absolute;
    top: -4px;
    right: 4px;
    background: #ef4444;
    color: #fff;
    font-size: 9.5px;
    font-weight: 800;
    min-width: 16px;
    height: 16px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0 4px;
    box-sizing: border-box;
    box-shadow: 0 2px 5px rgba(0,0,0,0.3);
    border: 1px solid #fff;
  }

  /* Hot Dock */
  .hot-dock {
    height: 76px;
    border-radius: 22px;
    padding: 10px 20px;
    background: var(--phone-glass-bg);
    border: 1px solid var(--phone-glass-border);
    display: flex;
    justify-content: space-around;
    align-items: center;
    box-sizing: border-box;
    margin-bottom: 5px;
  }

  .dock-icon-wrapper {
    position: relative;
    background: transparent;
    border: none;
    cursor: pointer;
    outline: none;
    transition: transform 0.2s;
    padding: 0;
  }

  .dock-icon-wrapper:hover {
    transform: translateY(-4px) scale(1.05);
  }

  .dock-icon-wrapper:active {
    transform: translateY(0) scale(0.95);
  }

  .dock-icon {
    width: 48px;
    height: 48px;
    border-radius: 12px;
    font-size: 22px;
    display: flex;
    align-items: center;
    justify-content: center;
    box-shadow: 0 4px 8px rgba(0,0,0,0.3);
    border: 1px solid rgba(255, 255, 255, 0.05);
  }

  /* NUI Preview Panel (Dev Only) */
  .nui-preview-panel {
    position: fixed;
    left: 20px;
    bottom: 20px;
    background: rgba(15, 15, 20, 0.95);
    border: 1px solid rgba(255, 255, 255, 0.1);
    padding: 14px;
    border-radius: 12px;
    width: 250px;
    z-index: 10000;
    box-shadow: 0 10px 30px rgba(0,0,0,0.5);
    font-family: monospace;
  }

  .nui-preview-panel h3 {
    margin: 0 0 10px 0;
    font-size: 13px;
    color: #a855f7;
    font-weight: bold;
    text-align: center;
  }

  .panel-row {
    display: flex;
    gap: 8px;
    margin-bottom: 8px;
  }

  .panel-row button {
    flex: 1;
    background: #27272a;
    color: #fff;
    border: none;
    padding: 6px 4px;
    border-radius: 6px;
    font-size: 10px;
    cursor: pointer;
    font-family: inherit;
    transition: background 0.2s;
  }

  .panel-row button:hover {
    background: #3f3f46;
  }
</style>
