import { writable } from 'svelte/store';

// Subtitle for a server-side (dispatch) voice line. Kept separate from the
// call state so pagination/settings code does not need to know about it.
export const callSubtitle = writable('');

let timer: ReturnType<typeof setTimeout> | null = null;

export function showSubtitle(text: string, ms = 9000) {
  callSubtitle.set(text);
  if (timer) clearTimeout(timer);
  timer = setTimeout(() => callSubtitle.set(''), ms);
}

export function clearSubtitle() {
  callSubtitle.set('');
  if (timer) clearTimeout(timer);
  timer = null;
}
