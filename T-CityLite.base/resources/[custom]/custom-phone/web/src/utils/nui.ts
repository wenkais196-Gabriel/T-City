import { onMount, onDestroy } from 'svelte';

// Check if we are running in the game or in a normal browser
export const isBrowser = () => !(window as any).GetParentResourceName;

// Safe Svelte NUI message event listener helper (prevents memory leak)
export function registerNuiEvent<T = any>(action: string, handler: (data: any) => void) {
  const listener = (event: MessageEvent) => {
    const data = event.data;
    if (data && data.action === action) {
      handler(data);
    }
  };

  onMount(() => {
    window.addEventListener('message', listener);
  });

  onDestroy(() => {
    window.removeEventListener('message', listener);
  });
}

// ----------------------------------------------------
// Global Mock State for Browser Development / Preview
// ----------------------------------------------------
let mockPlayerData = {
  citizenid: 'WKS99281',
  name: 'John Doe',
  phone: '1234567890',
  money: {
    cash: 5820,
    bank: 24500,
  },
  career: {
    primary_role: 'civilian', // civilian, police, mayor, medic, gang
    rank_tier: 'entry',       // entry, mid, leader
    department: 'LSPD',
    certs: ['pilot_license']
  }
};

let mockContacts = [
  { id: 1, citizenid: 'COP99881', name: 'Sheriff Miller', number: '1112223333' },
  { id: 2, citizenid: 'DOC12345', name: 'Dr. Sarah', number: '5556667777' },
  { id: 3, citizenid: 'GNG55443', name: 'Big Tony', number: '9998887777' },
];

let mockMessages = [
  { id: 1, sender_number: '1112223333', receiver_number: '1234567890', message: 'Hello! Are you on duty today?', timestamp: new Date(Date.now() - 3600000 * 2).toISOString(), is_read: true },
  { id: 2, sender_number: '1234567890', receiver_number: '1112223333', message: 'Hey Sheriff! No, I am running deliveries right now.', timestamp: new Date(Date.now() - 3600000 * 1.9).toISOString(), is_read: true },
  { id: 3, sender_number: '1112223333', receiver_number: '1234567890', message: 'Alright, stay safe. Let me know if you see anything suspicious near the cartel gates.', timestamp: new Date(Date.now() - 3600000 * 1.8).toISOString(), is_read: false },
  { id: 4, sender_number: '9998887777', receiver_number: '1234567890', message: 'Bring the package to the docks. ASAP.', timestamp: new Date(Date.now() - 3600000 * 12).toISOString(), is_read: true },
];

let mockNotifications = [
  { id: 1, title: '🏦 Bank Deposit', content: 'Your salary of $1,200 has been deposited to checking.', timestamp: new Date(Date.now() - 3600000 * 4).toISOString(), is_read: false },
  { id: 2, title: '👮 Police Dispatch', content: 'Wanted fugitive reported near Sandy Shores.', timestamp: new Date(Date.now() - 3600000 * 3).toISOString(), is_read: false },
];

let mockJobBoard = [
  {
    id: 1,
    task_id: 10,
    title: '📦 Dockside Hauling Delivery',
    description: 'Load high-grade industrial equipment from LS Port and transport to Sandy Shores Logistics. Target Tags: civilian (entry+).',
    target_tags: { role: 'civilian', tier: 'entry' },
    reward: 1250,
    status: 'open',
    taken_by: null,
    posted_at: new Date(Date.now() - 3600000 * 1).toISOString(),
    deadline: new Date(Date.now() + 3600000 * 5).toISOString(),
  },
  {
    id: 2,
    task_id: 11,
    title: '🗑️ City Recycling Route',
    description: 'Clean up recyclable materials around Mirror Park and deposit at the local processing plant.',
    target_tags: { role: 'civilian', tier: 'entry' },
    reward: 800,
    status: 'taken',
    taken_by: 'WKS99281',
    posted_at: new Date(Date.now() - 3600000 * 2).toISOString(),
    deadline: new Date(Date.now() + 3600000 * 1).toISOString(),
  }
];

let mockFactionMessages = {
  police: [
    { sender: 'Sheriff Miller', content: 'All units prioritize highway patrol today. High speeding reports.', time: Math.floor(Date.now() / 1000) - 1800 },
    { sender: 'Officer Adams', content: 'Copy that, setting up radar near Vinewood Hills.', time: Math.floor(Date.now() / 1000) - 900 }
  ],
  gang: [
    { sender: 'Big Tony', content: 'Remember the quota: $5000 in cash by midnight.', time: Math.floor(Date.now() / 1000) - 3600 }
  ],
  civilian: []
};

let mockCityFeed = [
  { id: 1, name: 'Mayor Office', citizenid: 'MAYOR001', content: 'Excited to announce the new Dockside Hauling project! Go grab the job from your Job Board App now!', likes: 24, timestamp: new Date(Date.now() - 3600000 * 3).toISOString() },
  { id: 2, name: 'John Doe', citizenid: 'WKS99281', content: 'Recycling route is pretty relaxing today. Weather is perfect!', likes: 5, timestamp: new Date(Date.now() - 3600000 * 1).toISOString() }
];

// NUI fetch function (sends requests to Lua)
export async function fetchNui<T = any>(eventName: string, data?: any): Promise<T> {
  const options = {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json; charset=UTF-8',
    },
    body: JSON.stringify(data),
  };

  // If in game, use standard fetch
  if (!isBrowser()) {
    try {
      const resourceName = (window as any).GetParentResourceName();
      const resp = await fetch(`https://${resourceName}/${eventName}`, options);
      return await resp.json();
    } catch (error) {
      console.error(`Failed to fetch NUI event: ${eventName}`, error);
      throw error;
    }
  }

  // Else, return mock data for browser preview/development
  console.log(`[Mock NUI Fetch] Event: ${eventName}`, data);
  await new Promise((resolve) => setTimeout(resolve, 300)); // Simulate minor networking delay

  switch (eventName) {
    case 'closePhone':
      console.log('[Mock NUI] Phone Closed');
      return { success: true } as any;

    case 'getPhoneData':
      return {
        success: true,
        playerData: mockPlayerData,
        contacts: mockContacts,
        messages: mockMessages,
        notifications: mockNotifications,
        jobBoard: mockJobBoard,
        factionMessages: mockFactionMessages[mockPlayerData.career.primary_role as keyof typeof mockFactionMessages] || []
      } as any;

    // Contact CRUD Mock
    case 'addContact': {
      const { name, number } = data;
      if (!name || !number) return { success: false, message: 'Invalid name or number' } as any;
      const newContact = {
        id: Math.floor(Math.random() * 10000),
        citizenid: mockPlayerData.citizenid,
        name,
        number
      };
      mockContacts.push(newContact);
      return { success: true, contact: newContact, message: 'Contact added!' } as any;
    }

    case 'deleteContact': {
      const { id } = data;
      mockContacts = mockContacts.filter(c => c.id !== id);
      return { success: true, message: 'Contact deleted!' } as any;
    }

    // Message SMS Mock
    case 'sendMessage': {
      const { receiver_number, message } = data;
      if (!receiver_number || !message) return { success: false, message: 'Invalid parameters' } as any;
      const newMsg = {
        id: Math.floor(Math.random() * 10000),
        sender_number: mockPlayerData.phone,
        receiver_number,
        message,
        timestamp: new Date().toISOString(),
        is_read: true
      };
      mockMessages.push(newMsg);
      
      // Auto-reply mock for fun
      setTimeout(() => {
        const reply = {
          id: Math.floor(Math.random() * 10000),
          sender_number: receiver_number,
          receiver_number: mockPlayerData.phone,
          message: `[AUTO-REPLY] Thanks for your message: "${message}". I will reply as soon as possible!`,
          timestamp: new Date().toISOString(),
          is_read: false
        };
        mockMessages.push(reply);
        
        // Dispatch window message event as if it came from FiveM server!
        const event = new MessageEvent('message', {
          data: {
            action: 'phone:newMessage',
            message: reply
          }
        });
        window.dispatchEvent(event);
      }, 2000);

      return { success: true, message: newMsg } as any;
    }

    case 'markMessagesRead': {
      const { sender_number } = data;
      mockMessages = mockMessages.map(m => {
        if (m.sender_number === sender_number && m.receiver_number === mockPlayerData.phone) {
          return { ...m, is_read: true };
        }
        return m;
      });
      return { success: true } as any;
    }

    // Banking App Mock
    case 'bankDeposit': {
      const amount = parseFloat(data.amount);
      if (isNaN(amount) || amount <= 0 || mockPlayerData.money.cash < amount) {
        return { success: false, message: 'Invalid deposit amount or insufficient cash' } as any;
      }
      mockPlayerData.money.cash -= amount;
      mockPlayerData.money.bank += amount;
      return { success: true, newBalances: mockPlayerData.money, message: 'Deposit successful!' } as any;
    }

    case 'bankWithdraw': {
      const amount = parseFloat(data.amount);
      if (isNaN(amount) || amount <= 0 || mockPlayerData.money.bank < amount) {
        return { success: false, message: 'Invalid withdrawal amount or insufficient bank funds' } as any;
      }
      mockPlayerData.money.bank -= amount;
      mockPlayerData.money.cash += amount;
      return { success: true, newBalances: mockPlayerData.money, message: 'Withdrawal successful!' } as any;
    }

    case 'bankTransfer': {
      const { toPhoneNumber, amount, reason } = data;
      const transferAmount = parseFloat(amount);
      if (isNaN(transferAmount) || transferAmount <= 0 || mockPlayerData.money.bank < transferAmount) {
        return { success: false, message: 'Invalid amount or insufficient bank funds' } as any;
      }
      mockPlayerData.money.bank -= transferAmount;
      return { success: true, newBalances: mockPlayerData.money, message: `Successfully transferred $${transferAmount}!` } as any;
    }

    // Job Board Mock
    case 'acceptJobBoardTask': {
      const { id } = data;
      const job = mockJobBoard.find(j => j.id === id);
      if (!job) return { success: false, message: 'Job not found' } as any;
      if (job.status !== 'open') return { success: false, message: 'Job is already taken or completed' } as any;
      
      job.status = 'taken';
      job.taken_by = mockPlayerData.citizenid;

      // Simulate completion after 8 seconds
      setTimeout(() => {
        job.status = 'completed';
        mockPlayerData.money.bank += job.reward;
        
        // Push notification
        const newNotif = {
          id: Math.floor(Math.random() * 10000),
          title: '📋 Job Completed!',
          content: `You completed "${job.title}" and earned a payout of $${job.reward} (credited to Bank).`,
          timestamp: new Date().toISOString(),
          is_read: false
        };
        mockNotifications.push(newNotif);

        window.dispatchEvent(new MessageEvent('message', {
          data: { action: 'phone:newNotification', notification: newNotif }
        }));
      }, 8000);

      return { success: true, message: 'Job accepted! GPS routing activated.' } as any;
    }

    case 'postJobBoardTask': {
      const { title, description, reward } = data;
      if (!title || isNaN(parseFloat(reward))) return { success: false, message: 'Invalid task values' } as any;
      
      const newJob = {
        id: mockJobBoard.length + 1,
        task_id: Math.floor(Math.random() * 1000),
        title,
        description,
        target_tags: { role: 'civilian', tier: 'entry' },
        reward: parseFloat(reward),
        status: 'open' as const,
        taken_by: null,
        posted_at: new Date().toISOString(),
        deadline: new Date(Date.now() + 3600000 * 2).toISOString()
      };
      mockJobBoard.push(newJob);

      // Broadcast to other clients
      window.dispatchEvent(new MessageEvent('message', {
        data: { action: 'phone:jobboard:newJob', job: newJob }
      }));

      return { success: true, message: 'Urban project posted successfully!' } as any;
    }

    // Faction Messages Mock
    case 'sendFactionMessage': {
      const { content } = data;
      if (!content) return { success: false } as any;
      const newMsg = {
        sender: mockPlayerData.name,
        content,
        time: Math.floor(Date.now() / 1000)
      };
      
      const role = mockPlayerData.career.primary_role;
      mockFactionMessages[role as keyof typeof mockFactionMessages].push(newMsg);

      return { success: true, message: newMsg } as any;
    }

    // CityFeed Mock
    case 'getCityFeed':
      return { success: true, feed: mockCityFeed } as any;

    case 'postCityFeed': {
      const { content } = data;
      if (!content) return { success: false } as any;
      const newPost = {
        id: mockCityFeed.length + 1,
        name: mockPlayerData.name,
        citizenid: mockPlayerData.citizenid,
        content,
        likes: 0,
        timestamp: new Date().toISOString()
      };
      mockCityFeed.unshift(newPost);
      return { success: true, post: newPost } as any;
    }

    case 'likeCityFeed': {
      const { id } = data;
      const post = mockCityFeed.find(p => p.id === id);
      if (post) post.likes += 1;
      return { success: true, likes: post ? post.likes : 0 } as any;
    }

    default:
      return { success: false, message: 'Unknown mock fetch endpoint' } as any;
  }
}

// Helper to simulate receiving Lua messages in the browser
export function triggerMockLuaMessage(action: string, extra?: any) {
  if (!isBrowser()) return;

  const event = new MessageEvent('message', {
    data: {
      action,
      playerData: mockPlayerData,
      contacts: mockContacts,
      messages: mockMessages,
      notifications: mockNotifications,
      jobBoard: mockJobBoard,
      ...extra,
    },
  });

  window.dispatchEvent(event);
}

// Quick debug controls helper inside browser
if (isBrowser()) {
  (window as any).triggerMockPhoneOpen = (role = 'civilian', tier = 'entry') => {
    mockPlayerData.career.primary_role = role;
    mockPlayerData.career.rank_tier = tier;
    
    // Trigger open
    triggerMockLuaMessage('phone:open');
    console.log(`[Mock Phone] Opened as primary_role: "${role}", rank_tier: "${tier}"`);
  };
}
