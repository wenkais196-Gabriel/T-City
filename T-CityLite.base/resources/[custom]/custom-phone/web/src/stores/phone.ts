import { writable, derived } from 'svelte/store';
import { fetchNui } from '../utils/nui';

// ----------------------------------------------------
// Global Stores
// ----------------------------------------------------
export const isPhoneOpen = writable<boolean>(false);
export const activeApp = writable<string>('home'); // home, messages, contacts, banking, notifications, jobboard, faction, cityfeed, leader_mayor, leader_sheriff, leader_gangboss

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

// Notifications list
export const notificationsList = writable<any[]>([]);

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
      contactsList.set(res.contacts || []);
      messagesList.set(res.messages || []);
      notificationsList.set(res.notifications || []);
      jobBoardTasks.set(res.jobBoard || []);
      factionMessages.set(res.factionMessages || []);
    }
  } catch (err) {
    console.error('Failed to load phone data', err);
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
