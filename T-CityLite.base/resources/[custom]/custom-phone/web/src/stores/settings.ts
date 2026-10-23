import { writable } from 'svelte/store';

// Device-local phone preferences. These are deliberately not part of
// playerData: the same PC keeps its sound/theme settings across characters,
// which is why they live in localStorage instead of the database.
export type PhoneTheme = 'dark' | 'light';

export interface PhoneSettings {
  ringtoneEnabled: boolean;
  ringtoneVolume: number; // 0-100
  callVolume: number;     // 0-100 (local only, pma-voice owns real voice volume)
  theme: PhoneTheme;
}

const STORAGE_KEY = 'tcity.phone.settings.v1';

export const DEFAULT_SETTINGS: PhoneSettings = {
  ringtoneEnabled: true,
  ringtoneVolume: 70,
  callVolume: 80,
  theme: 'dark',
};

function clampVolume(value: unknown, fallback: number): number {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(100, Math.max(0, Math.round(n)));
}

function readStored(): PhoneSettings {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return { ...DEFAULT_SETTINGS };
    const parsed = JSON.parse(raw);
    return {
      ringtoneEnabled: parsed.ringtoneEnabled !== false,
      ringtoneVolume: clampVolume(parsed.ringtoneVolume, DEFAULT_SETTINGS.ringtoneVolume),
      callVolume: clampVolume(parsed.callVolume, DEFAULT_SETTINGS.callVolume),
      theme: parsed.theme === 'light' ? 'light' : 'dark',
    };
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

function applyTheme(theme: PhoneTheme) {
  if (typeof document === 'undefined' || !document.body) return;
  document.body.classList.toggle('theme-light', theme === 'light');
}

export const settings = writable<PhoneSettings>(readStored());

// Persist and apply on every change, including the initial load.
settings.subscribe((value) => {
  applyTheme(value.theme);
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(value));
  } catch {
    // localStorage can be unavailable in some NUI configurations; the
    // in-memory store still applies for the current session.
  }
});

export function updateSettings(patch: Partial<PhoneSettings>) {
  settings.update((current) => ({ ...current, ...patch }));
}
