<script lang="ts">
  import { settings, updateSettings } from '../stores/settings';

  const setVolume = (key: 'ringtoneVolume' | 'callVolume', value: string) => {
    const n = Number(value);
    if (!Number.isFinite(n)) return;
    const volume = Math.min(100, Math.max(0, Math.round(n)));
    updateSettings(key === 'ringtoneVolume' ? { ringtoneVolume: volume } : { callVolume: volume });
  };
</script>

<div class="settings-app app-transition">
  <!-- App Header -->
  <div class="app-header">
    <span class="app-title">⚙️ Settings</span>
  </div>

  <div class="app-content phone-scrollable">
    <div class="device-note">
      💾 Saved on this device (localStorage). Settings are not tied to your character.
    </div>

    <section class="settings-card glass-card">
      <h3 class="section-title">Sounds</h3>

      <label class="setting-row">
        <span class="row-label">
          Ringtone
          <span class="row-hint">Play a tone for incoming calls</span>
        </span>
        <input
          type="checkbox"
          class="switch"
          checked={$settings.ringtoneEnabled}
          onchange={(e) => updateSettings({ ringtoneEnabled: e.currentTarget.checked })}
        />
      </label>

      <div class="setting-row column">
        <div class="row-head">
          <span class="row-label">Ringtone volume</span>
          <span class="row-value">{$settings.ringtoneVolume}%</span>
        </div>
        <input
          type="range"
          aria-label="Ringtone volume"
          min="0"
          max="100"
          step="1"
          value={$settings.ringtoneVolume}
          oninput={(e) => setVolume('ringtoneVolume', e.currentTarget.value)}
        />
      </div>

      <div class="setting-row column">
        <div class="row-head">
          <span class="row-label">Call volume</span>
          <span class="row-value">{$settings.callVolume}%</span>
        </div>
        <input
          type="range"
          aria-label="Call volume"
          min="0"
          max="100"
          step="1"
          value={$settings.callVolume}
          oninput={(e) => setVolume('callVolume', e.currentTarget.value)}
        />
        <p class="row-hint">
          Stored on this device only. In-game call loudness is handled by pma-voice,
          which exposes no NUI volume control, so this slider does not change voice audio yet.
        </p>
      </div>
    </section>

    <section class="settings-card glass-card">
      <h3 class="section-title">Appearance</h3>

      <div class="theme-toggle">
        <button
          class="theme-btn"
          class:active={$settings.theme === 'dark'}
          onclick={() => updateSettings({ theme: 'dark' })}
        >
          🌙 Dark
        </button>
        <button
          class="theme-btn"
          class:active={$settings.theme === 'light'}
          onclick={() => updateSettings({ theme: 'light' })}
        >
          ☀️ Light
        </button>
      </div>

      <p class="row-hint">
        Theme applies to the phone shell and home screen; individual apps keep their own styling.
      </p>
    </section>
  </div>
</div>

<style>
  .settings-app {
    display: flex;
    flex-direction: column;
    height: 100%;
    background: #09090b;
    color: #fff;
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
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .device-note {
    padding: 10px 14px;
    font-size: 11.5px;
    line-height: 1.45;
    color: #bbb;
    border-left: 3.5px solid hsl(var(--phone-accent));
    background: rgba(138, 43, 226, 0.06);
    border-radius: 8px;
  }

  .settings-card {
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  .section-title {
    margin: 0;
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.7px;
    text-transform: uppercase;
    color: #8e8e93;
  }

  .setting-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    cursor: pointer;
  }

  .setting-row.column {
    flex-direction: column;
    align-items: stretch;
    gap: 8px;
    cursor: default;
  }

  .row-label {
    font-size: 14px;
    font-weight: 600;
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  .row-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .row-value {
    font-size: 12.5px;
    color: #a78bfa;
    font-weight: 700;
  }

  .row-hint {
    margin: 0;
    font-size: 10.5px;
    line-height: 1.45;
    color: #8e8e93;
    font-weight: 400;
  }

  /* iOS-style switch */
  .switch {
    appearance: none;
    width: 46px;
    height: 27px;
    border-radius: 14px;
    background: #3a3a3c;
    position: relative;
    cursor: pointer;
    flex-shrink: 0;
    transition: background 0.2s;
    outline: none;
  }

  .switch::after {
    content: '';
    position: absolute;
    top: 2px;
    left: 2px;
    width: 23px;
    height: 23px;
    border-radius: 50%;
    background: #fff;
    box-shadow: 0 2px 4px rgba(0, 0, 0, 0.4);
    transition: transform 0.2s;
  }

  .switch:checked {
    background: #22c55e;
  }

  .switch:checked::after {
    transform: translateX(19px);
  }

  input[type='range'] {
    appearance: none;
    width: 100%;
    height: 4px;
    border-radius: 2px;
    background: #3a3a3c;
    outline: none;
  }

  input[type='range']::-webkit-slider-thumb {
    appearance: none;
    width: 18px;
    height: 18px;
    border-radius: 50%;
    background: #fff;
    box-shadow: 0 2px 6px rgba(0, 0, 0, 0.45);
    cursor: pointer;
  }

  .theme-toggle {
    display: flex;
    gap: 10px;
  }

  .theme-btn {
    flex: 1;
    padding: 11px 10px;
    border-radius: 12px;
    border: 1px solid rgba(255, 255, 255, 0.1);
    background: rgba(255, 255, 255, 0.04);
    color: #ddd;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    transition: background 0.2s, border-color 0.2s, color 0.2s;
  }

  .theme-btn.active {
    background: rgba(138, 43, 226, 0.22);
    border-color: hsl(var(--phone-accent));
    color: #fff;
  }

  /* Light theme: the shell/home are themed globally, and this app follows. */
  :global(body.theme-light) .settings-app {
    background: #eef1f6;
    color: #14151a;
  }

  :global(body.theme-light) .app-header {
    border-bottom-color: rgba(0, 0, 0, 0.08);
  }

  :global(body.theme-light) .settings-card {
    background: rgba(255, 255, 255, 0.7);
    border-color: rgba(0, 0, 0, 0.08);
  }

  :global(body.theme-light) .section-title,
  :global(body.theme-light) .row-hint {
    color: #5c6370;
  }

  :global(body.theme-light) .device-note {
    color: #444b57;
    background: rgba(138, 43, 226, 0.08);
  }

  :global(body.theme-light) .switch {
    background: #c7cbd4;
  }

  :global(body.theme-light) .switch:checked {
    background: #22c55e;
  }

  :global(body.theme-light) input[type='range'] {
    background: #c7cbd4;
  }

  :global(body.theme-light) .theme-btn {
    background: rgba(0, 0, 0, 0.04);
    border-color: rgba(0, 0, 0, 0.1);
    color: #2b303a;
  }

  :global(body.theme-light) .theme-btn.active {
    background: rgba(138, 43, 226, 0.16);
    border-color: hsl(var(--phone-accent));
    color: #14151a;
  }
</style>
