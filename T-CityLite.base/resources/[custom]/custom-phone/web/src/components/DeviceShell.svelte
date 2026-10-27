<script lang="ts">
  // DeviceShell.svelte — 唯一的外壳。手机和平板是同一台设备的两种形态，
  // 差异全部收在 core/surface.ts 的预设表里；这个组件不接受任何业务参数。
  //
  // 保留 .phone-wrapper 这个类名是刻意的：现有 NUI 测试和外部样式都按它选，
  // 改名只会制造无意义的改动面。data-surface 才是形态的真值。
  import { closePhone, activeApp, gameTime } from '../stores/phone';
  import { presetOf, type Surface } from '../core/surface';

  let { surface = 'phone', children }: { surface?: Surface; children?: any } = $props();

  const preset = $derived(presetOf(surface));
  const goHome = () => activeApp.set('home');
  const close = () => void closePhone();
</script>

<!-- 遮罩**不再**点击关闭：手机贴在屏幕右下角，遮罩占满其余视野，
     真机上鼠标坐标一偏就落到遮罩上 → 玩家以为"点一下手机就关机"。
     关闭只走三种明确入口：M / Esc / 平板状态栏的关闭按钮。 -->
<div
  class="phone-backdrop-mask"
  data-surface={surface}
  style:background={preset.mask}
  role="presentation"
  tabindex="-1"
>
  <div
    class="phone-wrapper device-shell"
    data-surface={surface}
    style:width={`${preset.width}px`}
    style:height={`${preset.height}px`}
    style:--device-radius={`${preset.radius}px`}
    onclick={(e) => e.stopPropagation()}
  >
    <!-- Outer shell bezel -->
    <div class="phone-bezel" style:padding={`${preset.bezel}px`} style:border-radius={`${preset.radius}px`}>
      {#if preset.notch}
        <!-- Camera/Speaker Notch（只有手机有） -->
        <div class="phone-notch">
          <div class="camera-lens"></div>
          <div class="speaker-grill"></div>
        </div>
      {/if}

      {#if preset.sideButtons}
        <!-- Power Button（装饰件：3px 宽、贴在壳外沿，鼠标点击会误触，不承担关闭职责） -->
        <button class="bezel-btn power-btn" aria-label="Close Phone" aria-hidden="true" tabindex="-1"></button>
        <!-- Volume Keys -->
        <div class="bezel-btn vol-up"></div>
        <div class="bezel-btn vol-down"></div>
      {/if}

      <!-- Inner Screen Area -->
      <div class="phone-screen" style:border-radius={`${preset.radius - preset.bezel}px`}>
        <!-- Top Status Bar -->
        <div class="status-bar" style:height={`${preset.statusBar}px`}>
          <div class="status-left">
            {#if surface === 'tablet'}
              <button class="status-action" onclick={goHome} aria-label="主页">主页</button>
            {/if}
            <span class="status-time">{String($gameTime.hour).padStart(2, '0')}:{String($gameTime.minute).padStart(2, '0')}</span>
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
            {#if preset.closeLabel}
              <button class="status-action status-close" data-device-close onclick={close}>{preset.closeLabel}</button>
            {/if}
          </div>
        </div>

        <!-- App Body Container -->
        <div class="screen-body">
          {@render children?.()}
        </div>

        {#if preset.homeBar}
          <!-- Bottom Gestures / Home Bar（只有手机有） -->
          <div class="home-gesture-bar-container">
            <button class="home-gesture-bar" onclick={goHome} aria-label="Go to Home Screen"></button>
          </div>
        {/if}
      </div>
    </div>
  </div>
</div>

<style>
  /* ===================== 外壳 ===================== */
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
    z-index: 9999;
    user-select: none;
    font-family: 'Outfit', 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    filter: drop-shadow(0 25px 50px rgba(0, 0, 0, 0.45));
  }

  /* 手机：右下角，不挡视野 */
  .phone-wrapper[data-surface='phone'] {
    right: 30px;
    bottom: 30px;
    animation: device-slide-up 0.55s cubic-bezier(0.16, 1, 0.3, 1) forwards;
  }

  /* 平板：居中；窗口不够大时收窄，不缩放（缩放会让字发虚） */
  .phone-wrapper[data-surface='tablet'] {
    inset: 0;
    margin: auto;
    width: min(1034px, calc(100vw - 40px));
    height: min(676px, calc(100vh - 40px));
    animation: device-fade-in 0.18s cubic-bezier(0.16, 1, 0.3, 1) forwards;
  }

  @keyframes device-slide-up {
    0% { transform: translateY(850px) rotate(8deg); opacity: 0; }
    100% { transform: translateY(0) rotate(0deg); opacity: 1; }
  }

  @keyframes device-fade-in {
    0% { transform: scale(0.96); opacity: 0; }
    100% { transform: scale(1); opacity: 1; }
  }

  /* Physical Bezel */
  .phone-bezel {
    position: relative;
    width: 100%;
    height: 100%;
    background: #1c1c1e;
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
    pointer-events: none;
    background: #2c2c2e;
    border: none;
    border-radius: 2px;
    box-shadow: inset 0 1px 1px rgba(255, 255, 255, 0.1);
    cursor: pointer;
  }

  .power-btn { right: -3px; top: 170px; width: 3px; height: 75px; }
  .power-btn:active { right: -1px; }
  .vol-up { left: -3px; top: 120px; width: 3px; height: 40px; }
  .vol-down { left: -3px; top: 175px; width: 3px; height: 40px; }

  /* AMOLED Screen Area */
  .phone-screen {
    position: relative;
    width: 100%;
    height: 100%;
    background: var(--phone-screen-bg);
    overflow: hidden;
    display: flex;
    flex-direction: column;
    box-shadow: inset 0 0 20px rgba(0, 0, 0, 0.85);
  }

  /* Top Status Bar */
  .status-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 22px;
    padding-top: 4px;
    font-size: 11.5px;
    font-weight: 600;
    color: var(--phone-status-text);
    z-index: 99;
    box-sizing: border-box;
    flex: none;
  }

  .status-left { display: flex; align-items: center; gap: 10px; }
  .status-time { letter-spacing: -0.2px; }
  .status-right { display: flex; align-items: center; gap: 6px; }

  /* 平板没有侧键，必须有一个看得见的关闭入口 */
  .status-action {
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid var(--phone-status-border);
    color: var(--phone-status-text);
    border-radius: 7px;
    padding: 2px 9px;
    font-size: 10.5px;
    font-weight: 600;
    cursor: pointer;
  }
  .status-action:hover { background: rgba(255, 255, 255, 0.16); }

  .net-type { font-size: 9.5px; font-weight: 800; letter-spacing: 0.5px; opacity: 0.9; }

  /* Battery Icon */
  .battery-icon {
    width: 19px;
    height: 10px;
    border: 1px solid var(--phone-status-border);
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
    background: var(--phone-status-border);
    border-top-right-radius: 1px;
    border-bottom-right-radius: 1px;
  }

  .battery-level { flex: 1; background: #22c55e; border-radius: 1px; }

  /* Signal Bars */
  .signal-bars { display: flex; align-items: flex-end; gap: 1.5px; height: 8px; }
  .signal-bars .bar { width: 2px; background: var(--phone-signal); border-radius: 0.5px; }
  .signal-bars .bar:nth-child(1) { height: 2px; }
  .signal-bars .bar:nth-child(2) { height: 4px; }
  .signal-bars .bar:nth-child(3) { height: 6px; }
  .signal-bars .bar:nth-child(4) { height: 8px; }
  .signal-bars .bar:nth-child(5) { height: 10px; }
  .signal-bars .bar.active { background: var(--phone-signal-active); }

  /* App Body container —— app 的排布容器，容器查询以它为基准 */
  .screen-body {
    flex: 1;
    position: relative;
    overflow: hidden;
    container-type: inline-size;
  }

  /* Home Bar Gesture */
  .home-gesture-bar-container {
    height: 20px;
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 100;
    flex: none;
  }

  .home-gesture-bar {
    width: 120px;
    height: 5px;
    background: var(--phone-home-bar);
    border-radius: 10px;
    border: none;
    cursor: pointer;
    transition: background 0.2s, transform 0.2s;
  }

  .home-gesture-bar:hover { background: var(--phone-home-bar-hover); transform: scaleX(1.05); }
  .home-gesture-bar:active { transform: scaleX(0.95); }
</style>
