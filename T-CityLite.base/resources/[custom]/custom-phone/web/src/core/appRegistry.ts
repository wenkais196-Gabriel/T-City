// core/appRegistry.ts — frontend App SDK registry.
//
// A manifest maps a stable server app id (`getPhoneApps` / `dyn:<id>`) onto a
// Svelte component. Visibility stays server-authoritative: the manifest is
// only looked up when the user opens `dyn:<id>`, and the server still decides
// which tiles a player receives.
import type { Component } from 'svelte';
import PoliceMDT from '../apps/PoliceMDT.svelte';

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
