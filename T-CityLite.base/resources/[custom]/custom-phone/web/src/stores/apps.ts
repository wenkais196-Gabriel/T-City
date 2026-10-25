import { writable } from 'svelte/store';
import { fetchNui } from '../utils/nui';
import { requestAppAction, requestAppQuery } from '../core/request';

export interface DynamicAppMeta {
  id: string;
  label: string;
  icon: string;
  queries: string[];
  actions: string[];
}

export const dynamicApps = writable<DynamicAppMeta[]>([]);

export async function loadDynamicApps() {
  try {
    const res = await fetchNui<any>('getPhoneApps');
    if (res && res.success && Array.isArray(res.apps)) {
      dynamicApps.set(res.apps);
    }
  } catch (err) {
    console.error('Failed to load phone apps', err);
  }
}

export async function queryApp(appId: string, query: string, params: Record<string, unknown> = {}) {
  return requestAppQuery(appId, query, params);
}

export async function appAction(appId: string, action: string, params: Record<string, unknown> = {}) {
  return requestAppAction(appId, action, params);
}
