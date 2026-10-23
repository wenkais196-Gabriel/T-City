import { writable } from 'svelte/store';
import { fetchNui } from '../utils/nui';

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
  try {
    return await fetchNui<any>('appQuery', { app_id: appId, query, params });
  } catch (err) {
    console.error('App query failed', err);
    return { success: false, error: 'query_failed' };
  }
}

export async function appAction(appId: string, action: string, params: Record<string, unknown> = {}) {
  try {
    return await fetchNui<any>('appAction', { app_id: appId, action, params });
  } catch (err) {
    console.error('App action failed', err);
    return { success: false, error: 'action_failed' };
  }
}
