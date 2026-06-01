export interface PlayerData {
  citizenid: string;
  charinfo: {
    firstname: string;
    lastname: string;
  };
  money: {
    cash: number;
    bank: number;
  };
}

export type AccountType = 'checking' | 'shared' | 'job' | 'gang';

export interface Account {
  id?: number;
  citizenid: string;
  account_name: string;
  account_balance: number;
  account_type: AccountType;
  users: string[]; // List of citizenids who have access
}

export interface Statement {
  id: number;
  citizenid: string;
  account_name: string;
  amount: number;
  reason: string;
  statement_type: 'deposit' | 'withdraw';
  date: string;
}
