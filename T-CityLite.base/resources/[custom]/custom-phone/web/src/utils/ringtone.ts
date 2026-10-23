// Ringback / hang-up tones.
//
// Preferred path: the real WAV assets in `html/assets/audio/` (copied there
// from `web/public/assets/audio/` by Vite). Relative URLs keep working under
// FiveM's NUI origin. If playback is blocked (autoplay policy) or the file is
// missing, fall back to the previous Web Audio two-tone synthesiser so a call
// still rings.
import { get } from 'svelte/store';
import { settings } from '../stores/settings';

const RING_SRC = './assets/audio/ring.wav';
const HANGUP_SRC = './assets/audio/hangup.wav';
const RING_INTERVAL_MS = 2000;
const BEEP_LENGTH = 0.35;

let audioCtx: AudioContext | null = null;
let ringTimer: ReturnType<typeof setInterval> | null = null;
let ringAudio: HTMLAudioElement | null = null;
let hangupAudio: HTMLAudioElement | null = null;
let usingSynthFallback = false;
// Bumped on every start/stop so a late play() rejection cannot revive a ring
// that was already stopped (e.g. the call was rejected immediately).
let ringToken = 0;

function volumeScale(): number {
  return Math.min(1, Math.max(0, get(settings).ringtoneVolume / 100));
}

function getAudioContext(): AudioContext | null {
  if (typeof window === 'undefined') return null;
  const Ctor = window.AudioContext ?? (window as any).webkitAudioContext;
  if (!Ctor) return null;
  if (!audioCtx) audioCtx = new Ctor();
  return audioCtx;
}

function beep(ctx: AudioContext, startAt: number, frequency: number, duration: number, gainValue: number) {
  const osc = ctx.createOscillator();
  const gain = ctx.createGain();
  osc.type = 'sine';
  osc.frequency.setValueAtTime(frequency, startAt);
  gain.gain.setValueAtTime(0.0001, startAt);
  gain.gain.exponentialRampToValueAtTime(Math.max(0.0001, gainValue), startAt + 0.02);
  gain.gain.exponentialRampToValueAtTime(0.0001, startAt + duration);
  osc.connect(gain);
  gain.connect(ctx.destination);
  osc.start(startAt);
  osc.stop(startAt + duration + 0.02);
}

function playPattern() {
  const ctx = getAudioContext();
  if (!ctx) return;
  // NUI may be blocked by the browser autoplay policy until the first user
  // gesture; the incoming-call screen and the 30s timeout still work without it.
  if (ctx.state === 'suspended') void ctx.resume().catch(() => {});
  if (ctx.state !== 'running') return;
  const now = ctx.currentTime + 0.02;
  const gain = 0.12 * volumeScale();
  beep(ctx, now, 880, BEEP_LENGTH, gain);
  beep(ctx, now + 0.55, 880, BEEP_LENGTH, gain);
}

function startSynthFallback() {
  usingSynthFallback = true;
  playPattern();
  ringTimer = setInterval(playPattern, RING_INTERVAL_MS);
}

function getRingAudio(): HTMLAudioElement | null {
  if (typeof Audio === 'undefined') return null;
  if (!ringAudio) {
    ringAudio = new Audio(RING_SRC);
    ringAudio.loop = true;
    ringAudio.preload = 'auto';
  }
  return ringAudio;
}

export function startRingtone() {
  stopRingtone();
  const prefs = get(settings);
  if (!prefs.ringtoneEnabled || prefs.ringtoneVolume <= 0) return;

  const audio = getRingAudio();
  if (!audio) {
    startSynthFallback();
    return;
  }

  audio.volume = volumeScale();
  try {
    audio.currentTime = 0;
  } catch {
    // Some CEF builds reject seeking before metadata is loaded; looping the
    // asset from wherever it starts is still fine.
  }

  const token = ringToken;
  const played = audio.play();
  if (played && typeof played.catch === 'function') {
    played.catch(() => {
      if (token === ringToken && !usingSynthFallback) startSynthFallback();
    });
  }
}

export function stopRingtone() {
  ringToken += 1;
  if (ringTimer) {
    clearInterval(ringTimer);
    ringTimer = null;
  }
  usingSynthFallback = false;
  if (ringAudio) {
    ringAudio.pause();
    try {
      ringAudio.currentTime = 0;
    } catch {
      // Ignore: stopping the interval is what matters.
    }
  }
}

function playHangupBeep() {
  const ctx = getAudioContext();
  if (!ctx) return;
  if (ctx.state === 'suspended') void ctx.resume().catch(() => {});
  if (ctx.state !== 'running') return;
  const now = ctx.currentTime + 0.02;
  const gain = 0.1 * volumeScale();
  beep(ctx, now, 520, 0.12, gain);
  beep(ctx, now + 0.14, 392, 0.16, gain);
}

export function playHangupSound() {
  const prefs = get(settings);
  if (!prefs.ringtoneEnabled || prefs.ringtoneVolume <= 0) return;

  if (typeof Audio !== 'undefined') {
    if (!hangupAudio) {
      hangupAudio = new Audio(HANGUP_SRC);
      hangupAudio.preload = 'auto';
    }
    hangupAudio.volume = volumeScale();
    try {
      hangupAudio.currentTime = 0;
    } catch {
      // See startRingtone().
    }
    const played = hangupAudio.play();
    if (played && typeof played.catch === 'function') {
      played.catch(() => playHangupBeep());
    }
    return;
  }

  playHangupBeep();
}
