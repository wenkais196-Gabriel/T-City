import { get } from 'svelte/store';
import { settings } from '../stores/settings';

// Local TTS for server-side callers (dispatch / 911 / agent). pma-voice carries
// the player's microphone; it cannot inject a remote voice, so the line is
// spoken by CEF on this client and mirrored as a subtitle. If the runtime has
// no speech synthesis (some CEF builds), the caller's text still shows.
export function speakDispatch(text: string): boolean {
  if (typeof window === 'undefined' || !('speechSynthesis' in window)) return false;
  try {
    const volume = get(settings).callVolume / 100;
    if (volume <= 0) return false;
    const utterance = new SpeechSynthesisUtterance(text);
    utterance.lang = 'zh-CN';
    utterance.rate = 0.95;
    utterance.pitch = 1;
    utterance.volume = Math.min(1, Math.max(0, volume));
    window.speechSynthesis.cancel();
    window.speechSynthesis.speak(utterance);
    return true;
  } catch {
    return false;
  }
}

export function stopDispatchSpeech() {
  if (typeof window === 'undefined' || !('speechSynthesis' in window)) return;
  try {
    window.speechSynthesis.cancel();
  } catch {
    // ignore
  }
}
