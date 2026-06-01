import { onMount, onDestroy } from 'svelte';
import type { PlayerData, Account, Statement } from '../types';

// Check if we are running in the game or in a normal browser
export const isBrowser = () => !(window as any).GetParentResourceName;

// Safe Svelte NUI message event listener helper
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

// Global mock state for browser development
let mockPlayerData: PlayerData = {
  citizenid: 'WKS99281',
  charinfo: {
    firstname: 'John',
    lastname: 'Doe',
  },
  money: {
    cash: 5820,
    bank: 24500,
  },
};

let mockAccounts: Account[] = [
  {
    id: 1,
    citizenid: 'WKS99281',
    account_name: 'checking',
    account_balance: 24500,
    account_type: 'checking',
    users: ['WKS99281'],
  },
  {
    id: 2,
    citizenid: 'WKS99281',
    account_name: 'Family Savings',
    account_balance: 154000,
    account_type: 'shared',
    users: ['WKS99281', 'MOM12345'],
  },
  {
    id: 3,
    citizenid: 'POLICE',
    account_name: 'police',
    account_balance: 852000,
    account_type: 'job',
    users: ['WKS99281', 'COP99881'],
  },
];

let mockStatements: Statement[] = [
  {
    id: 101,
    citizenid: 'WKS99281',
    account_name: 'checking',
    amount: 1500,
    reason: 'Weekly Paycheck',
    statement_type: 'deposit',
    date: new Date(Date.now() - 3600000 * 24).toISOString(),
  },
  {
    id: 102,
    citizenid: 'WKS99281',
    account_name: 'checking',
    amount: 250,
    reason: 'Store Purchase',
    statement_type: 'withdraw',
    date: new Date(Date.now() - 3600000 * 5).toISOString(),
  },
  {
    id: 103,
    citizenid: 'WKS99281',
    account_name: 'Family Savings',
    amount: 5000,
    reason: 'Savings Deposit',
    statement_type: 'deposit',
    date: new Date(Date.now() - 3600000 * 48).toISOString(),
  },
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
  await new Promise((resolve) => setTimeout(resolve, 500)); // Simulate networking delay

  switch (eventName) {
    case 'closeApp':
      console.log('[Mock NUI] App Closed');
      return { success: true } as any;

    case 'withdraw': {
      const { accountName, amount, reason } = data;
      const withdrawAmount = tonumber(amount);
      if (isNaN(withdrawAmount) || withdrawAmount <= 0) {
        return { success: false, message: 'Invalid amount' } as any;
      }

      if (accountName === 'checking') {
        if (mockPlayerData.money.bank < withdrawAmount) {
          return { success: false, message: 'Insufficient funds' } as any;
        }
        mockPlayerData.money.bank -= withdrawAmount;
        mockPlayerData.money.cash += withdrawAmount;
        const mainChecking = mockAccounts.find(a => a.account_name === 'checking');
        if (mainChecking) mainChecking.account_balance = mockPlayerData.money.bank;
      } else {
        const acc = mockAccounts.find(a => a.account_name === accountName);
        if (!acc) return { success: false, message: 'Account not found' } as any;
        if (acc.account_balance < withdrawAmount) {
          return { success: false, message: 'Insufficient funds' } as any;
        }
        acc.account_balance -= withdrawAmount;
        mockPlayerData.money.cash += withdrawAmount;
      }

      mockStatements.unshift({
        id: Math.floor(Math.random() * 10000),
        citizenid: mockPlayerData.citizenid,
        account_name: accountName,
        amount: withdrawAmount,
        reason: reason || 'Mock ATM Withdrawal',
        statement_type: 'withdraw',
        date: new Date().toISOString(),
      });

      return { success: true, message: 'Withdrawal successful!' } as any;
    }

    case 'deposit': {
      const { accountName, amount, reason } = data;
      const depositAmount = tonumber(amount);
      if (isNaN(depositAmount) || depositAmount <= 0) {
        return { success: false, message: 'Invalid amount' } as any;
      }

      if (mockPlayerData.money.cash < depositAmount) {
        return { success: false, message: 'Not enough cash in pocket' } as any;
      }

      if (accountName === 'checking') {
        mockPlayerData.money.bank += depositAmount;
        mockPlayerData.money.cash -= depositAmount;
        const mainChecking = mockAccounts.find(a => a.account_name === 'checking');
        if (mainChecking) mainChecking.account_balance = mockPlayerData.money.bank;
      } else {
        const acc = mockAccounts.find(a => a.account_name === accountName);
        if (!acc) return { success: false, message: 'Account not found' } as any;
        acc.account_balance += depositAmount;
        mockPlayerData.money.cash -= depositAmount;
      }

      mockStatements.unshift({
        id: Math.floor(Math.random() * 10000),
        citizenid: mockPlayerData.citizenid,
        account_name: accountName,
        amount: depositAmount,
        reason: reason || 'Mock ATM Deposit',
        statement_type: 'deposit',
        date: new Date().toISOString(),
      });

      return { success: true, message: 'Deposit successful!' } as any;
    }

    case 'internalTransfer': {
      const { fromAccountName, toAccountName, amount, reason } = data;
      const transferAmount = tonumber(amount);
      if (isNaN(transferAmount) || transferAmount <= 0) {
        return { success: false, message: 'Invalid amount' } as any;
      }

      let fromBal = 0;
      if (fromAccountName === 'checking') {
        fromBal = mockPlayerData.money.bank;
      } else {
        const fromAcc = mockAccounts.find(a => a.account_name === fromAccountName);
        if (!fromAcc) return { success: false, message: 'Source account not found' } as any;
        fromBal = fromAcc.account_balance;
      }

      if (fromBal < transferAmount) {
        return { success: false, message: 'Insufficient funds' } as any;
      }

      // Deduct from source
      if (fromAccountName === 'checking') {
        mockPlayerData.money.bank -= transferAmount;
        const checkingAcc = mockAccounts.find(a => a.account_name === 'checking');
        if (checkingAcc) checkingAcc.account_balance = mockPlayerData.money.bank;
      } else {
        const fromAcc = mockAccounts.find(a => a.account_name === fromAccountName);
        if (fromAcc) fromAcc.account_balance -= transferAmount;
      }

      // Add to destination
      if (toAccountName === 'checking') {
        mockPlayerData.money.bank += transferAmount;
        const checkingAcc = mockAccounts.find(a => a.account_name === 'checking');
        if (checkingAcc) checkingAcc.account_balance = mockPlayerData.money.bank;
      } else {
        const toAcc = mockAccounts.find(a => a.account_name === toAccountName);
        if (toAcc) toAcc.account_balance += transferAmount;
      }

      mockStatements.unshift({
        id: Math.floor(Math.random() * 10000),
        citizenid: mockPlayerData.citizenid,
        account_name: fromAccountName,
        amount: transferAmount,
        reason: reason || `Transfer to ${toAccountName}`,
        statement_type: 'withdraw',
        date: new Date().toISOString(),
      });

      mockStatements.unshift({
        id: Math.floor(Math.random() * 10000),
        citizenid: mockPlayerData.citizenid,
        account_name: toAccountName,
        amount: transferAmount,
        reason: reason || `Transfer from ${fromAccountName}`,
        statement_type: 'deposit',
        date: new Date().toISOString(),
      });

      return { success: true, message: 'Internal transfer completed!' } as any;
    }

    case 'externalTransfer': {
      const { fromAccountName, toCitizenId, amount, reason } = data;
      const transferAmount = tonumber(amount);
      if (isNaN(transferAmount) || transferAmount <= 0) {
        return { success: false, message: 'Invalid amount' } as any;
      }

      let fromBal = 0;
      if (fromAccountName === 'checking') {
        fromBal = mockPlayerData.money.bank;
      } else {
        const fromAcc = mockAccounts.find(a => a.account_name === fromAccountName);
        if (!fromAcc) return { success: false, message: 'Source account not found' } as any;
        fromBal = fromAcc.account_balance;
      }

      if (fromBal < transferAmount) {
        return { success: false, message: 'Insufficient funds' } as any;
      }

      if (fromAccountName === 'checking') {
        mockPlayerData.money.bank -= transferAmount;
        const checkingAcc = mockAccounts.find(a => a.account_name === 'checking');
        if (checkingAcc) checkingAcc.account_balance = mockPlayerData.money.bank;
      } else {
        const fromAcc = mockAccounts.find(a => a.account_name === fromAccountName);
        if (fromAcc) fromAcc.account_balance -= transferAmount;
      }

      mockStatements.unshift({
        id: Math.floor(Math.random() * 10000),
        citizenid: mockPlayerData.citizenid,
        account_name: fromAccountName,
        amount: transferAmount,
        reason: reason || `Wire transfer to ${toCitizenId}`,
        statement_type: 'withdraw',
        date: new Date().toISOString(),
      });

      return { success: true, message: 'Wire transfer sent successfully!' } as any;
    }

    case 'openAccount': {
      const { accountName, accountType, amount } = data;
      const initialAmount = tonumber(amount) || 0;

      if (mockPlayerData.money.bank < initialAmount) {
        return { success: false, message: 'Insufficient checking bank balance for initial deposit' } as any;
      }

      // Deduct from checking
      mockPlayerData.money.bank -= initialAmount;
      const checkingAcc = mockAccounts.find(a => a.account_name === 'checking');
      if (checkingAcc) checkingAcc.account_balance = mockPlayerData.money.bank;

      mockAccounts.push({
        id: mockAccounts.length + 1,
        citizenid: mockPlayerData.citizenid,
        account_name: accountName,
        account_balance: initialAmount,
        account_type: accountType,
        users: [mockPlayerData.citizenid],
      });

      mockStatements.unshift({
        id: Math.floor(Math.random() * 10000),
        citizenid: mockPlayerData.citizenid,
        account_name: 'checking',
        amount: initialAmount,
        reason: `Initial deposit for ${accountName}`,
        statement_type: 'withdraw',
        date: new Date().toISOString(),
      });

      return { success: true, message: 'Account opened successfully!' } as any;
    }

    case 'renameAccount': {
      const { accountName, newName } = data;
      const acc = mockAccounts.find(a => a.account_name === accountName);
      if (!acc) return { success: false, message: 'Account not found' } as any;

      acc.account_name = newName;
      return { success: true, message: 'Account renamed successfully!' } as any;
    }

    case 'deleteAccount': {
      const { accountName } = data;
      const index = mockAccounts.findIndex(a => a.account_name === accountName);
      if (index === -1) return { success: false, message: 'Account not found' } as any;

      const acc = mockAccounts[index];
      // Refund balance to checking
      mockPlayerData.money.bank += acc.account_balance;
      const checkingAcc = mockAccounts.find(a => a.account_name === 'checking');
      if (checkingAcc) checkingAcc.account_balance = mockPlayerData.money.bank;

      mockAccounts.splice(index, 1);

      mockStatements.unshift({
        id: Math.floor(Math.random() * 10000),
        citizenid: mockPlayerData.citizenid,
        account_name: 'checking',
        amount: acc.account_balance,
        reason: `Closure refund from ${accountName}`,
        statement_type: 'deposit',
        date: new Date().toISOString(),
      });

      return { success: true, message: 'Account closed, balance refunded!' } as any;
    }

    case 'addUser': {
      const { accountName, citizenid } = data;
      const acc = mockAccounts.find(a => a.account_name === accountName);
      if (!acc) return { success: false, message: 'Account not found' } as any;
      if (acc.users.includes(citizenid)) return { success: false, message: 'User already has access' } as any;

      acc.users.push(citizenid);
      return { success: true, message: `Access granted to citizen ${citizenid}` } as any;
    }

    case 'removeUser': {
      const { accountName, citizenid } = data;
      const acc = mockAccounts.find(a => a.account_name === accountName);
      if (!acc) return { success: false, message: 'Account not found' } as any;
      if (!acc.users.includes(citizenid)) return { success: false, message: 'User does not have access' } as any;
      if (citizenid === mockPlayerData.citizenid) return { success: false, message: 'Cannot remove yourself' } as any;

      acc.users = acc.users.filter(u => u !== citizenid);
      return { success: true, message: `Access revoked for citizen ${citizenid}` } as any;
    }

    case 'orderCard': {
      return { success: true, message: 'Debit card ordered and delivered to your pockets!' } as any;
    }

    default:
      return { success: false, message: 'Unknown mock event' } as any;
  }
}

// Utility to convert strings safely to numbers (like Lua tonumber)
function tonumber(val: any): number {
  if (typeof val === 'number') return val;
  const num = parseFloat(val);
  return isNaN(num) ? NaN : num;
}

// Helper to simulate receiving Lua messages in the browser
export function triggerMockLuaMessage(action: 'openBank' | 'openATM', extra?: any) {
  if (!isBrowser()) return;

  const event = new MessageEvent('message', {
    data: {
      action,
      playerData: mockPlayerData,
      accounts: mockAccounts,
      statements: mockStatements,
      acceptablePins: ['1234', '1111', '8888'], // for ATM
      pinNumbers: ['1234', '1111', '8888'],
      ...extra,
    },
  });

  window.dispatchEvent(event);
}
