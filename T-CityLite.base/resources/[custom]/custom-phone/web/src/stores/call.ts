import { get, writable } from 'svelte/store';
import { fetchNui } from '../utils/nui';
import { startRingtone, stopRingtone } from '../utils/ringtone';
import { activeApp } from './phone';

// Call state lives here (module singleton) so it survives PhoneCall unmounting
// and so calls can be received while the phone is on Home / closed.
export type CallPhase = 'idle' | 'incoming' | 'dialing' | 'ringing' | 'ongoing';

export const callPhase = writable<CallPhase>('idle');
export const callId = writable<any>(null);
export const callPeerName = writable('');
export const callPeerNumber = writable('');
export const callStatusText = writable('');
export const callDuration = writable(0);

// Client-side safety net: the server has no ringing timeout (audit B15), so we
// auto-reject after 30s instead of ringing forever.
const RING_TIMEOUT_MS = 30_000;

let durationTimer: ReturnType<typeof setInterval> | null = null;
let ringTimeout: ReturnType<typeof setTimeout> | null = null;
let failureTimeout: ReturnType<typeof setTimeout> | null = null;
// Incremented by resetCall(); async NUI callbacks compare it so a reply that
// arrives after the call was cancelled/ended cannot revive a dead call.
let callToken = 0;

// callId may arrive as a number, a string or (until the oxmysql insert contract
// is fixed server-side) an { insertId } object — compare loosely.
function sameCall(a: any, b: any) {
  return a != null && b != null && String(a) === String(b);
}

function startDurationTimer() {
  stopDurationTimer();
  callDuration.set(0);
  durationTimer = setInterval(() => {
    callDuration.update((s) => s + 1);
  }, 1000);
}

function stopDurationTimer() {
  if (durationTimer) {
    clearInterval(durationTimer);
    durationTimer = null;
  }
}

function clearRingTimeout() {
  if (ringTimeout) {
    clearTimeout(ringTimeout);
    ringTimeout = null;
  }
}

export function resetCall() {
  callToken += 1;
  stopRingtone();
  stopDurationTimer();
  clearRingTimeout();
  if (failureTimeout) {
    clearTimeout(failureTimeout);
    failureTimeout = null;
  }
  callPhase.set('idle');
  callId.set(null);
  callPeerName.set('');
  callPeerNumber.set('');
  callStatusText.set('');
  callDuration.set(0);
}

// --- Events coming from Lua (App.svelte registers these globally) ---

export function handleIncomingCall(callData: any) {
  if (!callData) return;
  resetCall();
  callId.set(callData.callId);
  callPeerName.set(callData.callerName || callData.callerNumber || 'Unknown Caller');
  callPeerNumber.set(callData.callerNumber || '');
  callStatusText.set('Incoming Call...');
  callPhase.set('incoming');
  activeApp.set('phonecall');
  startRingtone();
  ringTimeout = setTimeout(() => {
    void rejectIncomingCall();
  }, RING_TIMEOUT_MS);
}

export function handleCallAnswered(data: any) {
  if (!data || !sameCall(get(callId), data.callId)) return;
  clearRingTimeout();
  stopRingtone();
  callPhase.set('ongoing');
  callStatusText.set('Connected');
  startDurationTimer();
}

export function handleCallEnded(data: any) {
  if (!data || !sameCall(get(callId), data.callId)) return;
  resetCall();
}

// --- Actions from the PhoneCall UI ---

export async function placeCall(targetNumber: string) {
  if (!targetNumber) return;
  resetCall();
  const token = callToken;
  callPeerNumber.set(targetNumber);
  callStatusText.set('Dialing...');
  callPhase.set('dialing');

  try {
    const res: any = await fetchNui('initiateCall', { targetNumber });
    if (token !== callToken) return; // phone closed / call cancelled while dialing
    if (res && res.success) {
      callId.set(res.callId);
      callStatusText.set('Ringing...');
      callPhase.set('ringing');
    } else {
      callStatusText.set(res?.message || 'Call failed');
      failureTimeout = setTimeout(() => {
        if (token === callToken) resetCall();
      }, 2000);
    }
  } catch (err) {
    if (token !== callToken) return;
    console.error('Failed to place call', err);
    callStatusText.set('Network error');
    failureTimeout = setTimeout(() => {
      if (token === callToken) resetCall();
    }, 2000);
  }
}

export async function answerIncomingCall() {
  const id = get(callId);
  if (id == null) return;
  const token = callToken;
  try {
    const res: any = await fetchNui('answerCall', { callId: id });
    if (token !== callToken) return;
    if (res && res.success) {
      clearRingTimeout();
      stopRingtone();
      callPhase.set('ongoing');
      callStatusText.set('Connected');
      startDurationTimer();
    } else {
      callStatusText.set(res?.message || 'Call not found');
    }
  } catch (err) {
    console.error('Failed to answer call', err);
  }
}

export async function rejectIncomingCall() {
  const id = get(callId);
  const token = callToken;
  stopRingtone();
  clearRingTimeout();
  if (id != null) {
    try {
      await fetchNui('rejectCall', { callId: id });
    } catch (err) {
      console.error('Failed to reject call', err);
    }
  }
  if (token === callToken) resetCall();
}

export async function endActiveCall() {
  const id = get(callId);
  const token = callToken;
  stopRingtone();
  clearRingTimeout();
  stopDurationTimer();
  if (id != null) {
    try {
      await fetchNui('hangupCall', { callId: id });
    } catch (err) {
      console.error('Failed to hang up call', err);
    }
  }
  if (token === callToken) resetCall();
}
