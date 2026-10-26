// tests/nui/harness.mjs — dependency-free harness for the phone NUI (MDT).
//
// The game runs this bundle inside CEF and talks to Lua through
// `fetch('https://<resource>/<callback>')`. A plain Chromium page cannot open
// that origin, so the harness:
//   1. injects `window.GetParentResourceName = () => 'custom-phone'` before any
//      app script runs (the app then takes the "in game" fetch path instead of
//      the built-in browser mock),
//   2. serves the real `html/` build from a throwaway localhost server,
//   3. intercepts `https://custom-phone/**` with Playwright and answers with
//      deterministic JSON (including HTTP 5xx / aborted requests).
//
// Keeping the mock at the network boundary means the Svelte stores, the
// `fetchNui` error handling and the MDT UI are all exercised for real.

import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { existsSync, readdirSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';

export const RESOURCE = 'custom-phone';
export const NUI_ORIGIN = `https://${RESOURCE}`;

const HTML_DIR = path.resolve(fileURLToPath(new URL('../../../html', import.meta.url)));

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.webp': 'image/webp',
  '.wav': 'audio/wav',
  '.mp3': 'audio/mpeg',
  '.woff2': 'font/woff2',
  '.ico': 'image/x-icon',
};

// ---------------------------------------------------------------------------
// Readable failures: every check carries 期望/实际 so CI logs show a diff
// instead of a bare "false !== true".
// ---------------------------------------------------------------------------

export class CheckError extends Error {
  constructor(label, details) {
    super(label);
    this.name = 'CheckError';
    this.details = details ?? {};
  }
}

export function show(value) {
  if (typeof value === 'string') return JSON.stringify(value);
  if (value === undefined) return 'undefined';
  return JSON.stringify(value, null, 2);
}

export function checkEqual(label, actual, expected) {
  if (Object.is(actual, expected)) return;
  throw new CheckError(label, { 期望: show(expected), 实际: show(actual) });
}

export function checkTruthy(label, value) {
  if (value) return;
  throw new CheckError(label, { 期望: 'truthy', 实际: show(value) });
}

export function checkIncludes(label, haystack, needle) {
  if (String(haystack ?? '').includes(needle)) return;
  throw new CheckError(label, { 期望包含: show(needle), 实际: show(haystack) });
}

/** Compare two string lists and report missing/extra entries (order-insensitive). */
export function checkListEquals(label, actual, expected) {
  const unique = (list) => [...new Set((list ?? []).map((item) => String(item).trim()).filter(Boolean))];
  const actualList = unique(actual);
  const expectedList = unique(expected);
  const missing = expectedList.filter((item) => !actualList.includes(item));
  const extra = actualList.filter((item) => !expectedList.includes(item));
  if (missing.length === 0 && extra.length === 0) return;
  throw new CheckError(label, {
    缺少: show(missing),
    多出: show(extra),
    期望: show(expectedList),
    实际: show(actualList),
  });
}

/** Poll a predicate; throws a CheckError with the last observed value. */
export async function waitFor(predicate, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    last = await predicate();
    if (last) return last;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new CheckError(label, {
    期望: '条件在超时前成立',
    实际: `等待 ${timeoutMs}ms 后仍不成立；最后观测值 = ${show(last)}`,
  });
}

/** The refresh button is enabled only when `loading === false`. */
export async function waitEnabled(locator, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  let enabled = false;
  let visible = false;
  while (Date.now() < deadline) {
    visible = await locator.isVisible().catch(() => false);
    enabled = visible && (await locator.isEnabled().catch(() => false));
    if (enabled) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new CheckError(label, {
    期望: '刷新按钮可见且可点击（loading 已复位）',
    实际: !visible ? '按钮不可见' : '按钮仍 disabled（loading 卡在 true）',
  });
}

export async function waitText(locator, timeoutMs, label, predicate = () => true) {
  const deadline = Date.now() + timeoutMs;
  let last = '';
  while (Date.now() < deadline) {
    last = ((await locator.textContent().catch(() => '')) ?? '').trim();
    if (last && predicate(last)) return last;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new CheckError(label, {
    期望: '元素出现且文本满足条件',
    实际: `等待 ${timeoutMs}ms 后文本 = ${show(last)}`,
  });
}

// ---------------------------------------------------------------------------
// Static server for the Vite build (`web/html`).
// ---------------------------------------------------------------------------

export async function startStaticServer(root = HTML_DIR) {
  if (!existsSync(path.join(root, 'index.html'))) {
    throw new Error(`找不到构建产物 ${path.join(root, 'index.html')}，请先执行 npm run build。`);
  }
  const server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url ?? '/', 'http://127.0.0.1');
      let pathname = decodeURIComponent(url.pathname);
      if (pathname === '/' || pathname === '') pathname = '/index.html';
      const file = path.resolve(root, `.${pathname}`);
      if (!file.startsWith(`${root}${path.sep}`)) {
        response.writeHead(403).end('forbidden');
        return;
      }
      const info = await stat(file).catch(() => null);
      if (!info || !info.isFile()) {
        response.writeHead(404).end('not found');
        return;
      }
      const body = await readFile(file);
      response.writeHead(200, {
        'content-type': MIME[path.extname(file).toLowerCase()] ?? 'application/octet-stream',
        'cache-control': 'no-store',
      });
      response.end(body);
    } catch (error) {
      response.writeHead(500).end(String(error));
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  return {
    root,
    url: `http://127.0.0.1:${port}/index.html`,
    close: () =>
      new Promise((resolve) => {
        server.close(resolve);
        server.closeAllConnections?.();
      }),
  };
}

// ---------------------------------------------------------------------------
// Chromium discovery — never downloads a browser.
// ---------------------------------------------------------------------------

export function findChromium() {
  const explicit = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
  if (explicit) {
    if (!existsSync(explicit)) {
      throw new Error(`PLAYWRIGHT_CHROMIUM_EXECUTABLE 指向的文件不存在：${explicit}`);
    }
    return explicit;
  }

  const cacheRoot =
    process.env.PLAYWRIGHT_BROWSERS_PATH && process.env.PLAYWRIGHT_BROWSERS_PATH !== '0'
      ? process.env.PLAYWRIGHT_BROWSERS_PATH
      : path.join(os.homedir(), '.cache', 'ms-playwright');

  if (!existsSync(cacheRoot)) {
    throw new Error(
      `找不到 Playwright 浏览器缓存目录 ${cacheRoot}。\n` +
        '本测试不下载浏览器；请设置 PLAYWRIGHT_CHROMIUM_EXECUTABLE 指向本机 chromium，\n' +
        '或把已有的 chromium 放到 ~/.cache/ms-playwright/chromium-<rev>/chrome-linux64/chrome。',
    );
  }

  const builds = readdirSync(cacheRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && /^chromium(-\d+)?$/.test(entry.name))
    .map((entry) => ({ name: entry.name, revision: Number(entry.name.match(/-(\d+)$/)?.[1] ?? 0) }))
    .sort((a, b) => b.revision - a.revision);

  for (const build of builds) {
    const candidate = path.join(cacheRoot, build.name, 'chrome-linux64', 'chrome');
    if (existsSync(candidate)) return candidate;
  }

  throw new Error(
    `在 ${cacheRoot} 下没有找到可用的 chromium（期望 chromium-<rev>/chrome-linux64/chrome）。\n` +
      '请设置 PLAYWRIGHT_CHROMIUM_EXECUTABLE 指向本机 chromium。',
  );
}

export async function launchChromium() {
  const executablePath = findChromium();
  const browser = await chromium.launch({
    executablePath,
    headless: true,
    // CEF has no cross-origin policy for the `https://<resource>/` NUI origin;
    // Chromium would otherwise block the mocked cross-origin fetches. The tests
    // still exercise the exact `fetchNui` code path and JSON contract.
    args: [
      '--disable-web-security',
      '--disable-dev-shm-usage',
      '--disable-gpu',
      '--mute-audio',
      '--no-sandbox',
    ],
  });
  return { browser, executablePath };
}

// ---------------------------------------------------------------------------
// Deterministic NUI backend
// ---------------------------------------------------------------------------

export const UNIT_ALPHA = '1-ADAM-12';
export const UNIT_BRAVO = '2-LINCOLN-7';

export const INCIDENT_911 = {
  id: 6,
  // 服务端 IncidentActionState() 的下发结果：UI 只渲染，不自己算规则
  actions: {
    claim: { allowed: false, reason: 'already_joined' },
    clear: { allowed: true, reason: null },
  },
  primary: 'CID_ME',
  units: [{ citizenid: 'CID_ME', role: 'primary' }],
  code: '911',
  title: '测试警情一号',
  description: 'Vinewood 珠宝店报案',
  priority: 1,
  status: 'open',
  disposition: null,
  npc_template: null,
  created_at: '2026-10-24 18:20:00',
  x: 100.5,
  y: 200.25,
  z: 30,
};

export function createWorld() {
  return {
    player: {
      citizenid: 'COP001',
      name: 'Alice Adams',
      phone: '5550001111',
      money: { cash: 1200, bank: 5400 },
      career: {
        primary_role: 'police',
        rank_tier: 'entry',
        department: 'LSPD',
        certs: [],
      },
    },
    me: { citizenid: 'COP001', callsign: UNIT_ALPHA, grade: 2, status: 'available' },
    apps: [
      {
        id: 'police_mdt',
        label: 'MDT',
        icon: '🛡️',
        queries: ['units', 'incidents', 'me'],
        actions: ['set_status', 'assign', 'clear', 'alert'],
      },
    ],
    units: [
      { citizenid: 'COP001', name: 'Alice Adams', callsign: UNIT_ALPHA, dept: 'LSPD', status: 'available', incident_id: null },
      { citizenid: 'COP002', name: 'Bob Brown', callsign: UNIT_BRAVO, dept: 'LSPD', status: 'busy', incident_id: 6 },
    ],
    incidents: [],
    /** 通知托盘：测试里注入坏时间戳，验证界面不会渲染 NaN。 */
    notifications: [],
    /** 任务 App 的假数据：list 里刻意混入一条不可接的，验证 UI 会摆出原因。 */
    quests: [],
    questActive: [],
    /** One-shot query failures; consumed so the next refresh succeeds. */
    failQueries: new Set(),
    failStatus: 500,
    failError: 'db_error',
    /** One-shot aborted requests (simulates a dropped NUI callback). */
    abortQueries: new Set(),
    /** One-shot requests that never settle until the client timeout aborts. */
    hangQueries: new Set(),
    /** action name -> error code returned by appAction. */
    actionErrors: {},
    calls: [],
    clientErrors: [],
  };
}

function ok(body) {
  return { status: 200, body };
}

function queryData(world, query) {
  switch (query) {
    case 'units':
      return { rows: world.units, count: world.units.length };
    case 'incidents':
      return { rows: world.incidents, count: world.incidents.length };
    case 'me':
      return { rows: [world.me], count: 1 };
    case 'charges':
      return { rows: [{ id: 1, label: 'Reckless Driving', minutes: 5, fine: 500 }], count: 1 };
    default:
      return { rows: [], count: 0 };
  }
}

/** 任务 App 的假后端。按 app_id 分流，避免和 MDT 的 query 名撞车。 */
function questData(world, query) {
  switch (query) {
    case 'list':
      return { rows: world.quests, count: world.quests.length };
    case 'active':
      return { rows: world.questActive, count: world.questActive.length };
    default:
      return { rows: [], count: 0 };
  }
}

export function handleNui(world, callback, payload) {
  world.calls.push({ callback, payload });

  switch (callback) {
    case 'getPhoneData':
      return ok({
        success: true,
        playerData: world.player,
        contacts: [],
        messages: [],
        notifications: world.notifications ?? [],
        jobBoard: [],
        factionMessages: [],
      });
    case 'getPhoneApps':
      return ok({ success: true, apps: world.apps });
    case 'getCallHistory':
      return ok({ success: true, calls: [] });
    case 'report911':
      // 报警入口的假后端：返回单号，UI 要把它显示出来
      world.reported911 = payload ?? null;
      return ok({ success: true, incident_id: 42, merged: false });
    case 'clientError':
      world.clientErrors.push(payload);
      return ok({ ok: true });
    case 'appQuery': {
      const query = payload?.query;
      if (payload?.app_id === 'quests') {
        return ok({ success: true, data: questData(world, query) });
      }
      if (world.failQueries.has(query)) {
        world.failQueries.delete(query);
        return { status: world.failStatus, body: { success: false, error: world.failError } };
      }
      if (world.abortQueries.has(query)) {
        world.abortQueries.delete(query);
        return { abort: true };
      }
      if (world.hangQueries.has(query)) {
        world.hangQueries.delete(query);
        return { hang: true };
      }
      return ok({ success: true, data: queryData(world, query) });
    }
    case 'appAction': {
      const action = payload?.action;
      if (world.actionErrors[action]) {
        return ok({ success: false, error: world.actionErrors[action] });
      }
      return ok({ success: true, data: {} });
    }
    default:
      return ok({ success: true });
  }
}

const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'POST, OPTIONS',
  'access-control-allow-headers': 'content-type',
  'access-control-max-age': '600',
};

export async function installNuiMock(page, world) {
  await page.route(`${NUI_ORIGIN}/**`, async (route) => {
    const request = route.request();
    if (request.method() === 'OPTIONS') {
      await route.fulfill({ status: 204, headers: CORS_HEADERS });
      return;
    }
    const callback = new URL(request.url()).pathname.replace(/^\/+/, '');
    let payload = null;
    try {
      payload = request.postDataJSON();
    } catch {
      payload = null;
    }
    const result = handleNui(world, callback, payload);
    if (result.abort) {
      await route.abort('failed');
      return;
    }
    if (result.hang) {
      await new Promise((resolve) => setTimeout(resolve, 20000));
      return;
    }
    await route.fulfill({
      status: result.status,
      headers: { ...CORS_HEADERS, 'content-type': 'application/json; charset=utf-8' },
      body: JSON.stringify(result.body),
    });
  });
}

/**
 * The app CSS imports Google Fonts. Tests must stay offline (and CI has no
 * network), so answer those requests locally instead of waiting on the network.
 */
export async function blockExternalFonts(page) {
  await page.route('https://fonts.googleapis.com/**', (route) =>
    route.fulfill({ status: 200, contentType: 'text/css', body: '/* offline test: webfonts disabled */' }),
  );
  await page.route('https://fonts.gstatic.com/**', (route) => route.abort());
}

/** Inject the game globals before the bundle runs (see the header comment). */
export async function installGameGlobals(page) {
  await page.addInitScript((resource) => {
    window.GetParentResourceName = () => resource;
    window.__NUI_TEST__ = { resource };
  }, RESOURCE);
}

// ---------------------------------------------------------------------------
// Interaction helpers
// ---------------------------------------------------------------------------

export async function openPhone(page, surface = 'phone') {
  // surface 是宿主（Lua）决定的形态；测试里直接指定它，模拟 SurfaceRules 的结论。
  for (let attempt = 0; attempt < 40; attempt += 1) {
    await page.evaluate((id) => window.postMessage({ action: 'phone:open', surface: id }, '*'), surface);
    if (await page.locator('.phone-wrapper').isVisible().catch(() => false)) return;
    await page.waitForTimeout(50);
  }
  throw new CheckError('手机没有打开', {
    期望: 'postMessage({action:"phone:open"}) 后出现 .phone-wrapper',
    实际: '等待 2s 后手机外壳仍不可见（App.svelte 的 NUI 监听未就绪？）',
  });
}

/** Open the phone, then the MDT tile that `getPhoneApps` advertised. */
export async function openMdt(page, surface = 'phone') {
  await openPhone(page, surface);
  const tile = page.locator('button[aria-label="MDT"]');
  try {
    await tile.waitFor({ state: 'visible', timeout: 5000 });
  } catch {
    throw new CheckError('手机主页没有 MDT 图标', {
      期望: 'getPhoneApps 返回 police_mdt 后渲染一个 aria-label="MDT" 的按钮',
      实际: '5s 内没有找到 button[aria-label="MDT"]',
    });
  }
  await tile.click();
  try {
    await page.locator('.mdt').waitFor({ state: 'visible', timeout: 5000 });
  } catch {
    throw new CheckError('点击 MDT 图标后没有进入 MDT', {
      期望: '出现 .mdt 根节点',
      实际: '5s 内 .mdt 不可见',
    });
  }
}

/** 打开手机里的「任务」瓦片（服务端注册的 quests app）。 */
export async function openQuests(page, surface = 'phone') {
  await openPhone(page, surface);
  const tile = page.locator('button[aria-label="任务"]');
  try {
    await tile.waitFor({ state: 'visible', timeout: 5000 });
  } catch {
    throw new CheckError('手机主页没有任务图标', {
      期望: 'getPhoneApps 返回 quests 后渲染一个 aria-label="任务" 的按钮',
      实际: '5s 内没有找到 button[aria-label="任务"]',
    });
  }
  await tile.click();
  try {
    await page.locator('.quests-app').waitFor({ state: 'visible', timeout: 5000 });
  } catch {
    throw new CheckError('点击任务图标后没有进入任务页', {
      期望: '出现 .quests-app（appRegistry 里 quests → Quests.svelte）',
      实际: '5s 内 .quests-app 不可见（DynamicApp 兜底？组件没注册？）',
    });
  }
}

export async function openDispatchTab(page, label) {
  const tab = page.locator('.mdt .tabs.sub-tabs button', { hasText: label });
  // 平板（grid）上两栏并排，分段切换没有意义也不渲染 —— 这时"切页"是空操作
  if (!(await tab.isVisible().catch(() => false))) return;
  await tab.click();
  await page.waitForTimeout(80);
}

export async function refreshButton(page) {
  // 调度页拆成 pane 之后，"刷新"在单位栏和接警栏各有一颗：取当前可见的那颗。
  return page.locator('.mdt button.refresh:visible').first();
}

export function requestLog(world) {
  const counts = new Map();
  for (const call of world.calls) {
    const key = call.callback === 'appQuery' || call.callback === 'appAction'
      ? `${call.callback}:${call.payload?.query ?? call.payload?.action}`
      : call.callback;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return [...counts.entries()].map(([key, count]) => `${key}×${count}`);
}

/** 打开手机里的「通知」托盘（Home 上的喇叭图标）。 */
export async function openNotifications(page) {
  await openPhone(page);
  const tile = page.locator('button[aria-label="Notifications"]');
  try {
    await tile.waitFor({ state: 'visible', timeout: 5000 });
  } catch {
    throw new CheckError('手机主页没有通知图标', {
      期望: '出现 aria-label="Notifications" 的按钮',
      实际: '5s 内找不到该按钮',
    });
  }
  await tile.click();
  await page.locator('.notifications-app').waitFor({ state: 'visible', timeout: 5000 });
}

/** 打开手机里的「热线」页（报警入口在那儿）。 */
export async function openHotlines(page) {
  await openPhone(page);
  const tile = page.locator('button[aria-label="Service Hotlines"]');
  try {
    await tile.waitFor({ state: 'visible', timeout: 5000 });
  } catch {
    throw new CheckError('手机主页没有热线图标', {
      期望: '出现 aria-label="Service Hotlines" 的按钮',
      实际: '5s 内找不到该按钮',
    });
  }
  await tile.click();
  await page.locator('.report911').waitFor({ state: 'visible', timeout: 5000 });
}
