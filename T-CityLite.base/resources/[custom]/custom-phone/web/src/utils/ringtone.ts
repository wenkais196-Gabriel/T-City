// Lightweight ringtone synthesised with the Web Audio API.
// The resource ships no ringtone audio file (and `html/assets/*` only carries the
// Vite bundle), so we generate a two-tone "ring ring" pattern instead of adding a
// binary asset that would also need a fxmanifest `files` entry.
// TODO ringtone: swap this for a real audio asset (e.g. html/assets/ringtone.ogg)
// once one is vendored into the resource.
const RING_INTERVAL_MS = 2000;
const BEEP_LENGTH = 0.35;

let audioCtx: AudioContext | null = null;
let ringTimer: ReturnType<typeof setInterval> | null = null;

function getAudioContext(): AudioContext | null {
  if (typeof window === 'undefined') return null;
  const Ctor = window.AudioContext ?? (window as any).webkitAudioContext;
  if (!Ctor) return null;
  if (!audioCtx) audioCtx = new Ctor();
  return audioCtx;
}

function beep(ctx: AudioContext, startAt: number) {
  const osc = ctx.createOscillator();
  const gain = ctx.createGain();
  osc.type = 'sine';
  osc.frequency.setValueAtTime(880, startAt);
  gain.gain.setValueAtTime(0.0001, startAt);
  gain.gain.exponentialRampToValueAtTime(0.12, startAt + 0.02);
  gain.gain.exponentialRampToValueAtTime(0.0001, startAt + BEEP_LENGTH);
  osc.connect(gain);
  gain.connect(ctx.destination);
  osc.start(startAt);
  osc.stop(startAt + BEEP_LENGTH + 0.02);
}

function playPattern() {
  const ctx = getAudioContext();
  if (!ctx) return;
  // NUI may be blocked by the browser autoplay policy until the first user
  // gesture; the incoming-call screen and the 30s timeout still work without it.
  if (ctx.state === 'suspended') void ctx.resume().catch(() => {});
  if (ctx.state !== 'running') return;
  const now = ctx.currentTime + 0.02;
  beep(ctx, now);
  beep(ctx, now + 0.55);
}

export function startRingtone() {
  stopRingtone();
  playPattern();
  ringTimer = setInterval(playPattern, RING_INTERVAL_MS);
}

export function stopRingtone() {
  if (ringTimer) {
    clearInterval(ringTimer);
    ringTimer = null;
  }
}
