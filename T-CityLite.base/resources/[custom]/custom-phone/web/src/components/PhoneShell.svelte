<script lang="ts">
  import { closePhone, activeApp, playerData, unreadMessagesCount, unreadNotificationsCount } from '../stores/phone';
  import { onMount } from 'svelte';

  // Svelte 5 children prop
  let { children } = $props();

  // Real-time status bar clock
  let timeStr = $state('08:00');
  
  onMount(() => {
    const updateTime = () => {
      const d = new Date();
      let h = d.getHours().toString().padStart(2, '0');
      let m = d.getMinutes().toString().padStart(2, '0');
      timeStr = `${h}:${m}`;
    };
    updateTime();
    const interval = setInterval(updateTime, 1000);
    return () => clearInterval(interval);
  });

  const handleHomeClick = () => {
    activeApp.set('home');
  };
</script>

<div class="phone-backdrop-mask" onclick={closePhone} onkeydown={(e) => e.key === 'Escape' && closePhone()} role="button" tabindex="0">
  <div class="phone-wrapper" onclick={(e) => e.stopPropagation()}>
    <!-- Outer shell bezel -->
    <div class="phone-bezel">
      <!-- Camera/Speaker Notch -->
      <div class="phone-notch">
        <div class="camera-lens"></div>
        <div class="speaker-grill"></div>
      </div>
      
      <!-- Power Button -->
      <button class="bezel-btn power-btn" aria-label="Close Phone" onclick={closePhone}></button>
      <!-- Volume Keys -->
      <div class="bezel-btn vol-up"></div>
      <div class="bezel-btn vol-down"></div>

      <!-- Inner Screen Area -->
      <div class="phone-screen">
        <!-- Top Status Bar -->
        <div class="status-bar">
          <div class="status-left">
            <span class="status-time">{timeStr}</span>
          </div>
          <div class="status-right">
            <!-- Network Signal -->
            <div class="signal-bars">
              <span class="bar active"></span>
              <span class="bar active"></span>
              <span class="bar active"></span>
              <span class="bar active"></span>
              <span class="bar"></span>
            </div>
            <!-- 5G Label -->
            <span class="net-type">5G</span>
            <!-- Battery Icon -->
            <div class="battery-icon">
              <div class="battery-level"></div>
            </div>
          </div>
        </div>

        <!-- App Body Container -->
        <div class="screen-body">
          {@render children?.()}
        </div>

        <!-- Bottom Gestures / Home Bar -->
        <div class="home-gesture-bar-container">
          <!-- Home back key button -->
          <button class="home-gesture-bar" onclick={handleHomeClick} aria-label="Go to Home Screen"></button>
        </div>
      </div>
    </div>
  </div>
</div>

<style>
  /* Phone Shell Core Styles */
  .phone-backdrop-mask {
    position: fixed;
    inset: 0;
    width: 100vw;
    height: 100vh;
    background: transparent;
    z-index: 9998;
    outline: none;
  }

  .phone-wrapper {
    position: fixed;
    right: 30px;
    bottom: 30px;
    width: 375px;
    height: 780px;
    z-index: 9999;
    user-select: none;
    font-family: 'Outfit', 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    filter: drop-shadow(0 25px 50px rgba(0, 0, 0, 0.45));
    animation: phone-slide-up 0.55s cubic-bezier(0.16, 1, 0.3, 1) forwards;
  }

  @keyframes phone-slide-up {
    0% {
      transform: translateY(850px) rotate(8deg);
      opacity: 0;
    }
    100% {
      transform: translateY(0) rotate(0deg);
      opacity: 1;
    }
  }

  /* Physical Bezel */
  .phone-bezel {
    position: relative;
    width: 100%;
    height: 100%;
    background: #1c1c1e;
    border-radius: 48px;
    padding: 13px; /* Bezel size */
    box-sizing: border-box;
    box-shadow: 
      inset 0 4px 6px rgba(255, 255, 255, 0.15),
      inset 0 -4px 6px rgba(0, 0, 0, 0.6),
      0 0 0 4px #2c2c2e;
  }

  /* Notch */
  .phone-notch {
    position: absolute;
    top: 13px;
    left: 50%;
    transform: translateX(-50%);
    width: 130px;
    height: 25px;
    background: #000;
    border-bottom-left-radius: 18px;
    border-bottom-right-radius: 18px;
    z-index: 1000;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 16px;
    box-sizing: border-box;
  }

  .camera-lens {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: radial-gradient(circle, #0e2a4a 0%, #000000 70%);
    box-shadow: inset 0 1px 2px rgba(255, 255, 255, 0.3);
  }

  .speaker-grill {
    width: 45px;
    height: 3px;
    background: #222;
    border-radius: 2px;
    border: 0.5px solid #111;
  }

  /* Side Buttons */
  .bezel-btn {
    position: absolute;
    background: #2c2c2e;
    border: none;
    border-radius: 2px;
    box-shadow: inset 0 1px 1px rgba(255, 255, 255, 0.1);
    cursor: pointer;
  }

  .power-btn {
    right: -3px;
    top: 170px;
    width: 3px;
    height: 75px;
  }
  
  .power-btn:active {
    right: -1px;
  }

  .vol-up {
    left: -3px;
    top: 120px;
    width: 3px;
    height: 40px;
  }

  .vol-down {
    left: -3px;
    top: 175px;
    width: 3px;
    height: 40px;
  }

  /* AMOLED Screen Area */
  .phone-screen {
    position: relative;
    width: 100%;
    height: 100%;
    background: #09090b;
    border-radius: 38px;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    box-shadow: inset 0 0 20px rgba(0, 0, 0, 0.85);
  }

  /* Top Status Bar */
  .status-bar {
    height: 38px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 22px;
    padding-top: 4px;
    font-size: 11.5px;
    font-weight: 600;
    color: #ffffff;
    z-index: 99;
    box-sizing: border-box;
  }

  .status-time {
    letter-spacing: -0.2px;
  }

  .status-right {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .net-type {
    font-size: 9.5px;
    font-weight: 800;
    letter-spacing: 0.5px;
    opacity: 0.9;
  }

  /* Battery Icon */
  .battery-icon {
    width: 19px;
    height: 10px;
    border: 1px solid rgba(255, 255, 255, 0.7);
    border-radius: 3px;
    padding: 1px;
    box-sizing: border-box;
    display: flex;
    position: relative;
  }

  .battery-icon::after {
    content: '';
    position: absolute;
    right: -2.5px;
    top: 3px;
    width: 1.5px;
    height: 3.5px;
    background: rgba(255, 255, 255, 0.7);
    border-top-right-radius: 1px;
    border-bottom-right-radius: 1px;
  }

  .battery-level {
    flex: 1;
    background: #22c55e;
    border-radius: 1px;
  }

  /* Signal Bars */
  .signal-bars {
    display: flex;
    align-items: flex-end;
    gap: 1.5px;
    height: 8px;
  }

  .signal-bars .bar {
    width: 2px;
    background: rgba(255, 255, 255, 0.3);
    border-radius: 0.5px;
  }

  .signal-bars .bar:nth-child(1) { height: 2px; }
  .signal-bars .bar:nth-child(2) { height: 4px; }
  .signal-bars .bar:nth-child(3) { height: 6px; }
  .signal-bars .bar:nth-child(4) { height: 8px; }
  .signal-bars .bar:nth-child(5) { height: 10px; }

  .signal-bars .bar.active {
    background: #ffffff;
  }

  /* App Body container */
  .screen-body {
    flex: 1;
    position: relative;
    overflow: hidden;
  }

  /* Home Bar Gesture */
  .home-gesture-bar-container {
    height: 20px;
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 100;
  }

  .home-gesture-bar {
    width: 120px;
    height: 5px;
    background: rgba(255, 255, 255, 0.6);
    border-radius: 10px;
    border: none;
    cursor: pointer;
    transition: background 0.2s, transform 0.2s;
  }

  .home-gesture-bar:hover {
    background: #ffffff;
    transform: scaleX(1.05);
  }

  .home-gesture-bar:active {
    transform: scaleX(0.95);
  }
</style>
