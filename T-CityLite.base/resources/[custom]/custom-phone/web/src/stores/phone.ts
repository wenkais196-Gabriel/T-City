import { writable, derived } from 'svelte/store';
import { fetchNui } from '../utils/nui';

// ----------------------------------------------------
// Global Stores
// ----------------------------------------------------
export const isPhoneOpen = writable<boolean>(false);
export const activeApp = writable<string>('home'); // home, messages, contacts, banking, notifications, jobboard, faction, cityfeed, leader_mayor, leader_sheriff, leader_gangboss

// Game clock (GTA V native time) — status bar and home widget share this
export const gameTime = writable<{ hour: number; minute: number }>({ hour: 0, minute: 0 });

// Player Metadata
export const playerData = writable<any>({
  citizenid: 'CIV12345',
  name: 'Unknown Player',
  phone: '0000000000',
  money: { cash: 0, bank: 0 },
  career: { primary_role: 'civilian', rank_tier: 'entry', department: '', certs: [] }
});

// Contacts CRUD
export const contactsList = writable<any[]>([]);

// SMS messages list
export const messagesList = writable<any[]>([]);

// SMS page size. getPhoneData ships the newest 30 per conversation (server
// side) and loadMessages() asks for older keyset pages of the same size.
export const MESSAGE_PAGE_SIZE = 30;

// Notifications list
export const notificationsList = writable<any[]>([]);

// Recent calls (server `phone:server:getCallHistory`, newest first, max 20)
export const callHistory = writable<any[]>([]);

// Job Board tasks list
export const jobBoardTasks = writable<any[]>([]);

// Faction/career organization group chat messages
export const factionMessages = writable<any[]>([]);

// ----------------------------------------------------
// Derived / Selectors
// ----------------------------------------------------
// Total unread SMS count
export const unreadMessagesCount = derived(
  [messagesList, playerData],
  ([$messages, $playerData]) => {
    return $messages.filter(
      m => m.receiver_number === $playerData.phone && !m.is_read
    ).length;
  }
);

// Total unread system notifications count
export const unreadNotificationsCount = derived(
  notificationsList,
  ($notifications) => $notifications.filter(n => !n.is_read).length
);

// Sorted SMS threads list (grouped by other contact number, with latest message details)
export const smsThreads = derived(
  [messagesList, playerData, contactsList],
  ([$messages, $playerData, $contacts]) => {
    const threadsMap: { [number: string]: any } = {};

    $messages.forEach(msg => {
      const isMeSender = msg.sender_number === $playerData.phone;
      const otherNumber = isMeSender ? msg.receiver_number : msg.sender_number;
      
      const contact = $contacts.find(c => c.number === otherNumber);
      const name = contact ? contact.name : otherNumber;

      if (!threadsMap[otherNumber]) {
        threadsMap[otherNumber] = {
          number: otherNumber,
          name,
          messages: [],
          latestMessage: '',
          latestTime: '',
          hasUnread: false
        };
      }

      threadsMap[otherNumber].messages.push(msg);
      
      // Check if message is unread and addressed to me
      if (!msg.is_read && msg.receiver_number === $playerData.phone) {
        threadsMap[otherNumber].hasUnread = true;
      }
    });

    const threads = Object.values(threadsMap).map(t => {
      // Sort messages inside thread by time ascending
      t.messages.sort((a: any, b: any) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime());
      const last = t.messages[t.messages.length - 1];
      t.latestMessage = last.message;
      t.latestTime = last.timestamp;
      return t;
    });

    // Sort threads by latest message timestamp descending
    threads.sort((a: any, b: any) => new Date(b.latestTime).getTime() - new Date(a.latestTime).getTime());
    return threads;
  }
);

// ----------------------------------------------------
// Actions / API bridge helpers
// ----------------------------------------------------
export async function loadPhoneData() {
  try {
    const res = await fetchNui<any>('getPhoneData');
    if (res && res.success) {
      playerData.set(res.playerData);
      contactsList.set(Array.isArray(res.contacts) ? res.contacts : []);
      messagesList.set(Array.isArray(res.messages) ? res.messages : []);
      notificationsList.set(Array.isArray(res.notifications) ? res.notifications : []);
      jobBoardTasks.set(Array.isArray(res.jobBoard) ? res.jobBoard : []);
      factionMessages.set(Array.isArray(res.factionMessages) ? res.factionMessages : []);
      void loadCallHistory();
    }
  } catch (err) {
    console.error('Failed to load phone data', err);
  }
}

// Load one older page of a conversation (keyset by id). The first 30 messages
// per conversation already arrive with getPhoneData; this prepends anything
// older and de-duplicates by id.
export async function loadMessages(number: string, beforeId?: number) {
  try {
    const payload: { number: string; limit: number; before_id?: number } = {
      number,
      limit: MESSAGE_PAGE_SIZE,
    };
    if (typeof beforeId === 'number') payload.before_id = beforeId;

    const res = await fetchNui<any>('getMessages', payload);
    if (!res || !res.success) {
      return {
        success: false,
        messages: [] as any[],
        nextBeforeId: null as number | null,
        hasMore: null as boolean | null,
      };
    }

    const incoming: any[] = Array.isArray(res.messages) ? res.messages : [];
    if (incoming.length > 0) {
      messagesList.update(list => {
        const known = new Set(list.map(m => m.id));
        const fresh = incoming.filter(m => !known.has(m.id));
        return fresh.length > 0 ? [...fresh, ...list] : list;
      });
    }

    return {
      success: true,
      messages: incoming,
      nextBeforeId: typeof res.next_before_id === 'number' ? res.next_before_id : null,
      // The server probes one extra row, so this is exact when present.
      hasMore: typeof res.has_more === 'boolean' ? res.has_more : null,
    };
  } catch (err) {
    console.error('Failed to load earlier messages', err);
    return {
      success: false,
      messages: [] as any[],
      nextBeforeId: null as number | null,
      hasMore: null as boolean | null,
    };
  }
}

export async function loadCallHistory() {
  try {
    const res = await fetchNui<any>('getCallHistory');
    if (res && res.success) {
      callHistory.set(Array.isArray(res.calls) ? res.calls : []);
    }
  } catch (err) {
    console.error('Failed to load call history', err);
  }
}

export async function closePhone() {
  try {
    await fetchNui('closePhone');
    isPhoneOpen.set(false);
    activeApp.set('home');
  } catch (err) {
    console.error('Failed to close phone', err);
  }
}
