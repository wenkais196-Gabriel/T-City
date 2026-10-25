// core/appRegistry.ts — frontend App SDK registry.
//
// A manifest maps a stable server app id (`getPhoneApps` / `dyn:<id>`) onto a
// Svelte component. Visibility stays server-authoritative: the manifest is
// only looked up when the user opens `dyn:<id>`, and the server still decides
// which tiles a player receives.
import type { Component } from 'svelte';
import PoliceMDT from '../apps/PoliceMDT.svelte';
import Quests from '../apps/Quests.svelte';

export interface PhoneAppAudience {
  jobs?: string[];
  onduty?: boolean;
}

export interface PhoneAppManifest {
  id: string;
  label: string;
  icon: string;
  component: Component;
  audience?: PhoneAppAudience;
  schemaVersion: number;
}

const apps = new Map<string, PhoneAppManifest>();

export function registerApp(manifest: PhoneAppManifest): void {
  apps.set(manifest.id, manifest);
}

export function getApp(id: string): PhoneAppManifest | undefined {
  return apps.get(id);
}

export function listApps(): PhoneAppManifest[] {
  return [...apps.values()];
}

// Built-in app manifests. The server registry (server/phone_apps.lua) is still
// the single source of truth for visibility; this only supplies the component.
export const POLICE_MDT_APP_ID = 'police_mdt';

registerApp({
  id: POLICE_MDT_APP_ID,
  label: 'MDT',
  icon: '🛡️',
  component: PoliceMDT,
  audience: { jobs: ['police'] },
  schemaVersion: 1,
});

// 任务 App：服务端注册表（server/apps/quests.lua）决定谁看得到这块瓦片，
// 这里只负责给它一个真正的界面（而不是 DynamicApp 的调试式列表）。
export const QUESTS_APP_ID = 'quests';

registerApp({
  id: QUESTS_APP_ID,
  label: '任务',
  icon: '📜',
  component: Quests,
  audience: {},
  schemaVersion: 1,
});
