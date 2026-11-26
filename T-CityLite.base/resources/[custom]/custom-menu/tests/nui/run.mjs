#!/usr/bin/env node
// tests/nui/run.mjs — dependency-free NUI verification for custom-menu (Scheme A info rows).
//
// Runs two layers using only Node built-ins:
//   1. Fast deterministic DOM/renderer contract tests directly against ../../html/renderer.js
//   2. Real headless Chromium/Edge CDP verification against ../../html/index.html when a
//      browser binary is available locally or via PLAYWRIGHT_CHROMIUM_EXECUTABLE.

import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MENU_ROOT = path.resolve(__dirname, '../..');
const HTML_DIR = path.join(MENU_ROOT, 'html');
const RENDERER_PATH = path.join(HTML_DIR, 'renderer.js');

// ---------------------------------------------------------------------------
// 1. Minimal deterministic HTML/DOM mock for renderer.js CommonJS unit tests
// ---------------------------------------------------------------------------

function decodeEntities(str) {
  return String(str)
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}

function parseAttrs(raw) {
  const attrs = {};
  const re = /([a-zA-Z0-9_:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'))?/g;
  let m;
  while ((m = re.exec(raw)) !== null) {
    attrs[m[1]] = m[2] !== undefined ? decodeEntities(m[2]) : (m[3] !== undefined ? decodeEntities(m[3]) : '');
  }
  return attrs;
}

function makeClassList(el) {
  return {
    _tokens() {
      return String(el._attrs.class || '').split(/\s+/).filter(Boolean);
    },
    _save(tokens) {
      if (tokens.length) el._attrs.class = tokens.join(' ');
      else delete el._attrs.class;
    },
    contains(name) {
      return this._tokens().includes(name);
    },
    add(...names) {
      const tokens = this._tokens();
      for (const n of names) {
        if (n && !tokens.includes(n)) tokens.push(n);
      }
      this._save(tokens);
    },
    remove(...names) {
      const tokens = this._tokens().filter((t) => !names.includes(t));
      this._save(tokens);
    },
    toggle(name, force) {
      const has = this.contains(name);
      const want = force === undefined ? !has : Boolean(force);
      if (want && !has) this.add(name);
      if (!want && has) this.remove(name);
      return want;
    },
  };
}

function matchesSelector(el, selector) {
  const sel = selector.trim();
  if (!sel) return false;
  if (sel.includes(',')) {
    return sel.split(',').some((part) => matchesSelector(el, part));
  }
  // Support simple compound selectors: tag, #id, .cls, [attr], [attr="val"]
  let rest = sel;
  const tagMatch = rest.match(/^([a-zA-Z][a-zA-Z0-9_-]*)/);
  if (tagMatch) {
    if (el.tagName.toLowerCase() !== tagMatch[1].toLowerCase()) return false;
    rest = rest.slice(tagMatch[0].length);
  }
  while (rest.length > 0) {
    if (rest[0] === '#') {
      const m = rest.match(/^#([a-zA-Z0-9_-]+)/);
      if (!m || el.id !== m[1]) return false;
      rest = rest.slice(m[0].length);
    } else if (rest[0] === '.') {
      const m = rest.match(/^\.([a-zA-Z0-9_-]+)/);
      if (!m || !el.classList.contains(m[1])) return false;
      rest = rest.slice(m[0].length);
    } else if (rest[0] === '[') {
      const m = rest.match(/^\[([a-zA-Z0-9_-]+)(?:=(?:"([^"]*)"|'([^']*)'|([^\]]*)))?\]/);
      if (!m) return false;
      const attrVal = el.getAttribute(m[1]);
      if (attrVal === null) return false;
      const expected = m[2] ?? m[3] ?? m[4];
      if (expected !== undefined && attrVal !== expected) return false;
      rest = rest.slice(m[0].length);
    } else {
      return false;
    }
  }
  return true;
}

function parseHtmlInto(parent, html, doc) {
  parent.children = [];
  const stack = [parent];
  const tokenRe = /<(\/?)([a-zA-Z0-9]+)([^>]*)>|([^<]+)/g;
  const VOID_TAGS = new Set(['input', 'br', 'hr', 'img', 'link', 'meta']);
  let m;
  while ((m = tokenRe.exec(html)) !== null) {
    const top = stack[stack.length - 1];
    if (m[4] !== undefined) {
      top.children.push({ nodeType: 3, textContent: decodeEntities(m[4]), parentNode: top });
      continue;
    }
    const isClose = m[1] === '/';
    const tag = m[2].toLowerCase();
    const attrStr = m[3] || '';
    if (isClose) {
      for (let i = stack.length - 1; i >= 1; i--) {
        if (stack[i].tagName.toLowerCase() === tag) {
          stack.length = i;
          break;
        }
      }
      continue;
    }
    const selfClosing = attrStr.trim().endsWith('/') || VOID_TAGS.has(tag);
    const el = doc.createElement(tag);
    el._attrs = parseAttrs(attrStr.replace(/\/$/, ''));
    el.parentNode = top;
    top.children.push(el);
    if (!selfClosing) {
      stack.push(el);
    }
  }
}

function createFakeDom() {
  const docListeners = {};
  const doc = {
    activeElement: null,
    documentElement: null,
    createElement(tagName) {
      const listeners = {};
      const el = {
        nodeType: 1,
        tagName: String(tagName).toUpperCase(),
        _attrs: {},
        style: {},
        parentNode: null,
        children: [],
        scrollTop: 0,
        clientHeight: 390,
        offsetWidth: 300,
        get id() {
          return this._attrs.id || '';
        },
        set id(v) {
          this._attrs.id = String(v);
        },
        get className() {
          return this._attrs.class || '';
        },
        set className(v) {
          this._attrs.class = String(v);
        },
        getAttribute(name) {
          return Object.prototype.hasOwnProperty.call(this._attrs, name) ? this._attrs[name] : null;
        },
        setAttribute(name, val) {
          this._attrs[name] = String(val);
        },
        appendChild(child) {
          child.parentNode = this;
          this.children.push(child);
          return child;
        },
        contains(other) {
          let cur = other;
          while (cur) {
            if (cur === this) return true;
            cur = cur.parentNode;
          }
          return false;
        },
        closest(selector) {
          let cur = this;
          while (cur && cur.nodeType === 1) {
            if (matchesSelector(cur, selector)) return cur;
            cur = cur.parentNode;
          }
          return null;
        },
        querySelectorAll(selector) {
          const parts = selector.trim().split(/\s+/);
          const out = [];
          function walk(node, matchFn) {
            for (const child of node.children || []) {
              if (child.nodeType === 1) {
                if (matchFn(child)) out.push(child);
                walk(child, matchFn);
              }
            }
          }
          if (parts.length === 1) {
            walk(this, (n) => matchesSelector(n, parts[0]));
          } else {
            // Simple descendant selector: "A B"
            walk(this, (n) => {
              if (!matchesSelector(n, parts[parts.length - 1])) return false;
              let p = n.parentNode;
              let idx = parts.length - 2;
              while (p && p.nodeType === 1 && idx >= 0) {
                if (matchesSelector(p, parts[idx])) idx--;
                p = p.parentNode;
              }
              return idx < 0;
            });
          }
          return out;
        },
        querySelector(selector) {
          return this.querySelectorAll(selector)[0] || null;
        },
        addEventListener(type, fn) {
          listeners[type] = listeners[type] || [];
          listeners[type].push(fn);
        },
        dispatchEvent(evt) {
          const event = Object.assign({ target: this, preventDefault() {}, stopPropagation() {} }, evt);
          let cur = this;
          while (cur && cur.nodeType === 1) {
            for (const fn of cur._listeners?.[event.type] || []) {
              fn(event);
            }
            cur = cur.parentNode;
          }
        },
        scrollIntoView() {},
        get _listeners() {
          return listeners;
        },
        set innerHTML(html) {
          this._rawHtml = String(html);
          parseHtmlInto(this, this._rawHtml, doc);
        },
        get innerHTML() {
          return this._rawHtml || '';
        },
        get textContent() {
          let out = '';
          for (const child of this.children) {
            out += child.nodeType === 3 ? child.textContent : child.textContent;
          }
          return out;
        },
        set textContent(val) {
          this.children = [{ nodeType: 3, textContent: String(val), parentNode: this }];
        },
      };
      el.classList = makeClassList(el);
      return el;
    },
    getElementById(id) {
      return this.documentElement.querySelector('#' + id);
    },
    addEventListener(type, fn) {
      docListeners[type] = docListeners[type] || [];
      docListeners[type].push(fn);
    },
  };
  doc.documentElement = doc.createElement('html');
  return doc;
}

function makeKeyEvent(key) {
  return {
    key,
    prevented: false,
    stopped: false,
    preventDefault() {
      this.prevented = true;
    },
    stopPropagation() {
      this.stopped = true;
    },
  };
}

function runDomUnitTests() {
  const require = createRequire(import.meta.url);
  const CustomMenu = require(RENDERER_PATH);

  // Test 1: Scheme A info rows + disabled action row + enabled action row
  {
    const doc = createFakeDom();
    const mountEl = doc.createElement('section');
    const toastEl = doc.createElement('div');
    doc.documentElement.appendChild(mountEl);
    doc.documentElement.appendChild(toastEl);

    const emitted = [];
    const inst = CustomMenu.createInstance({
      doc,
      mountEl,
      toastEl,
      onIntent(detail) {
        emitted.push(detail);
      },
    });

    const spec = {
      id: 'industry_panel',
      title: '洛圣都矿业公司 · L1 · Mine Owner',
      surface: 'list',
      items: [
        { id: 'bal', kind: 'info', label: '金库余额', hint: '$4,195,095', icon: 'fa-solid fa-vault' },
        { id: 'empty_hint', kind: 'info', label: '无右值提示' },
        { id: 'hire', kind: 'action', label: '雇工位（$123,018）', disabled: true, disabledReason: '资金不足', intent: 'ind:hire' },
        { id: 'back', kind: 'action', label: '返回', intent: 'ind:back' },
      ],
    };

    const res = inst.render(mountEl, spec, { resetState: true });
    assert.equal(res.ok, true);

    const info0 = mountEl.querySelector('[data-item-index="0"]');
    const info1 = mountEl.querySelector('[data-item-index="1"]');
    const actDisabled = mountEl.querySelector('[data-item-index="2"]');
    const actEnabled = mountEl.querySelector('[data-item-index="3"]');

    assert.ok(info0, 'info row 0 must render');
    assert.ok(info1, 'info row 1 (missing hint) must render');
    assert.equal(info0.classList.contains('disabled'), false, 'info row must NOT carry disabled class');
    assert.equal(info0.classList.contains('focused'), false, 'info row must NOT carry focused class');
    assert.equal(info0.classList.contains('info-row'), true, 'info row must carry info-row class');
    assert.equal(info0.textContent.includes('›'), false, 'info row must NOT render chevron arrow');
    assert.equal(info0.querySelector('.row-hint')?.textContent, '$4,195,095');

    assert.equal(info1.classList.contains('disabled'), false, 'info row missing hint must NOT carry disabled class');
    assert.equal(info1.textContent.includes('undefined'), false, 'info row missing hint must NOT render undefined');

    assert.equal(actDisabled.classList.contains('disabled'), true, 'disabled action row must keep disabled class');
    assert.equal(actDisabled.classList.contains('focused'), true, 'initial focus must skip info rows and land on first action row');
    assert.equal(actDisabled.querySelector('.row-disabled-reason')?.textContent, '资金不足');
    assert.equal(inst.getState().focusIndex, 2, 'initial focusIndex must skip info rows');

    // Click info row -> zero intents, zero toasts, focusIndex unchanged
    info0.querySelector('.row-label').dispatchEvent({ type: 'click' });
    assert.equal(emitted.length, 0, 'clicking info row must NOT emit intent');
    assert.equal(toastEl.querySelectorAll('.toast-card').length, 0, 'clicking info row must NOT push toast');
    assert.equal(inst.getState().focusIndex, 2, 'clicking info row must NOT move focusIndex');

    // ArrowDown / ArrowUp skip info rows
    inst.handleKeyDown(makeKeyEvent('ArrowDown'));
    assert.equal(inst.getState().focusIndex, 3);
    assert.equal(actEnabled.classList.contains('focused'), true);
    assert.equal(info0.classList.contains('focused'), false);

    inst.handleKeyDown(makeKeyEvent('ArrowDown'));
    assert.equal(inst.getState().focusIndex, 2, 'ArrowDown wrap must skip info rows');
    assert.equal(info0.classList.contains('focused'), false);
    assert.equal(info1.classList.contains('focused'), false);

    inst.handleKeyDown(makeKeyEvent('ArrowUp'));
    assert.equal(inst.getState().focusIndex, 3, 'ArrowUp wrap must skip info rows');

    // Clicking disabled action row -> pushes toast, emits no intent
    actDisabled.dispatchEvent({ type: 'click' });
    assert.equal(emitted.length, 0, 'disabled action row must not emit intent');
    assert.equal(toastEl.querySelectorAll('.toast-card').length, 1, 'disabled action row should still push toast');

    // Clicking enabled action row -> emits intent
    actEnabled.dispatchEvent({ type: 'click' });
    assert.equal(emitted.length, 1);
    assert.equal(emitted[0].intent, 'ind:back');
  }

  // Test 2: All-info menu never focuses any row and clicking never emits/toasts
  {
    const doc = createFakeDom();
    const mountEl = doc.createElement('section');
    const toastEl = doc.createElement('div');
    doc.documentElement.appendChild(mountEl);
    doc.documentElement.appendChild(toastEl);

    const emitted = [];
    const inst = CustomMenu.createInstance({
      doc,
      mountEl,
      toastEl,
      onIntent(detail) {
        emitted.push(detail);
      },
    });

    inst.render(mountEl, {
      id: 'only_info',
      title: '只读状态',
      surface: 'list',
      items: [
        { id: 'r1', kind: 'info', label: 'A', hint: '1', disabled: true },
        { id: 'r2', kind: 'info', label: 'B' },
      ],
    }, { resetState: true });

    assert.equal(inst.getState().focusIndex, -1, 'all-info menu should have focusIndex = -1');
    assert.equal(mountEl.querySelectorAll('.focused').length, 0, 'no row may be focused in all-info menu');
    assert.equal(mountEl.querySelectorAll('.disabled').length, 0, 'info rows never carry disabled class even if flag set');
    inst.handleKeyDown(makeKeyEvent('ArrowDown'));
    inst.handleKeyDown(makeKeyEvent('ArrowUp'));
    assert.equal(inst.getState().focusIndex, -1);
    mountEl.querySelector('[data-item-index="0"]').dispatchEvent({ type: 'click' });
    inst.handleKeyDown(makeKeyEvent('Enter'));
    assert.equal(emitted.length, 0);
    assert.equal(toastEl.querySelectorAll('.toast-card').length, 0);
  }

  // Test 3: Virtualized list (>= 50 items) also skips info rows & omits disabled class
  {
    const doc = createFakeDom();
    const mountEl = doc.createElement('section');
    const toastEl = doc.createElement('div');
    doc.documentElement.appendChild(mountEl);
    doc.documentElement.appendChild(toastEl);

    const emitted = [];
    const inst = CustomMenu.createInstance({
      doc,
      mountEl,
      toastEl,
      onIntent(detail) {
        emitted.push(detail);
      },
    });

    const items = [
      { id: 'v_info_0', kind: 'info', label: '状态', hint: '正常' },
      { id: 'v_info_1', kind: 'info', label: '配额', hint: '10/20' },
    ];
    for (let i = 0; i < 50; i++) {
      items.push({ id: `act_${i}`, kind: 'action', label: `操作 ${i}`, intent: `act:${i}` });
    }
    inst.render(mountEl, { id: 'v_menu', title: 'VList', surface: 'list', items }, { resetState: true });
    assert.equal(inst.getState().focusIndex, 2, 'vlist initial focus must skip info rows');
    const vInfo = mountEl.querySelector('.vlist-row[data-item-index="0"]');
    assert.ok(vInfo);
    assert.equal(vInfo.classList.contains('info-row'), true);
    assert.equal(vInfo.classList.contains('disabled'), false);
    assert.equal(vInfo.classList.contains('focused'), false);
    vInfo.dispatchEvent({ type: 'click' });
    assert.equal(emitted.length, 0);
    inst.handleKeyDown(makeKeyEvent('ArrowUp'));
    assert.equal(inst.getState().focusIndex, 51, 'vlist ArrowUp must skip info rows');
  }

  console.log('✔ DOM/JS renderer unit scenarios passed (3/3)');
}

// ---------------------------------------------------------------------------
// 2. Real Headless Chromium CDP verification (computed styles + DOM events)
// ---------------------------------------------------------------------------

function findBrowserExecutable() {
  const candidates = [];
  if (process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE) {
    candidates.push(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE);
  }
  const localAppData = process.env.LOCALAPPDATA;
  if (localAppData) {
    const msPw = path.join(localAppData, 'ms-playwright');
    if (existsSync(msPw)) {
      for (const entry of readdirSync(msPw, { withFileTypes: true })) {
        if (entry.isDirectory() && entry.name.startsWith('chromium-')) {
          candidates.push(path.join(msPw, entry.name, 'chrome-win64', 'chrome.exe'));
        }
      }
    }
  }
  const linuxCache = path.join(os.homedir(), '.cache', 'ms-playwright');
  if (existsSync(linuxCache)) {
    for (const entry of readdirSync(linuxCache, { withFileTypes: true })) {
      if (entry.isDirectory() && entry.name.startsWith('chromium-')) {
        candidates.push(path.join(linuxCache, entry.name, 'chrome-linux64', 'chrome'));
      }
    }
  }
  candidates.push(
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
  );
  return candidates.find((p) => p && existsSync(p)) || null;
}

function startStaticServer(rootDir) {
  const MIME = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
  };
  const server = createServer((req, res) => {
    const pathname = (req.url || '/').split('?')[0];
    const rel = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
    const file = path.resolve(rootDir, rel);
    if (!file.startsWith(rootDir + path.sep) && file !== path.join(rootDir, 'index.html')) {
      res.writeHead(403).end('forbidden');
      return;
    }
    if (!existsSync(file)) {
      res.writeHead(404).end('not found');
      return;
    }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
    res.end(readFileSync(file));
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolve({
        url: `http://127.0.0.1:${port}/index.html`,
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}

class CdpClient {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
    this.ready = new Promise((resolve, reject) => {
      this.ws.addEventListener('open', resolve, { once: true });
      this.ws.addEventListener('error', reject, { once: true });
    });
    this.ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(String(ev.data));
      if (msg.id) {
        const entry = this.pending.get(msg.id);
        if (entry) {
          this.pending.delete(msg.id);
          if (msg.error) entry.reject(new Error(msg.error.message));
          else entry.resolve(msg.result);
        }
      } else {
        this.events.push(msg);
      }
    });
  }
  async send(method, params = {}) {
    await this.ready;
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  async evalExpr(expression) {
    const res = await this.send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (res.exceptionDetails) {
      throw new Error(res.exceptionDetails.exception?.description || res.exceptionDetails.text);
    }
    return res.result?.value;
  }
  close() {
    this.ws.close();
  }
}

async function runBrowserTests() {
  const exe = findBrowserExecutable();
  if (!exe) {
    if (process.env.REQUIRE_BROWSER === '1') {
      throw new Error('No Chromium/Edge executable found while REQUIRE_BROWSER=1');
    }
    console.log('↷ Skip real browser CDP checks (no local Chromium/Edge binary)');
    return;
  }

  const server = await startStaticServer(HTML_DIR);
  const proc = spawn(
    exe,
    [
      '--headless=new',
      '--disable-gpu',
      '--no-sandbox',
      '--disable-dev-shm-usage',
      '--remote-debugging-port=0',
      '--user-data-dir=' + path.join(os.tmpdir(), 'cm-nui-test-' + process.pid + '-' + Date.now()),
      'about:blank',
    ],
    { stdio: ['ignore', 'pipe', 'pipe'] }
  );

  let cdp = null;
  try {
    const wsUrl = await new Promise((resolve, reject) => {
      let buf = '';
      const timer = setTimeout(() => reject(new Error('Chromium DevTools timed out: ' + buf)), 15000);
      const onData = (chunk) => {
        buf += chunk.toString();
        const m = buf.match(/DevTools listening on (ws:\/\/[^\s]+)/);
        if (m) {
          clearTimeout(timer);
          resolve(m[1]);
        }
      };
      proc.stderr.on('data', onData);
      proc.stdout.on('data', onData);
      proc.once('exit', (code) => {
        clearTimeout(timer);
        reject(new Error(`Browser exited early (${code}): ${buf}`));
      });
    });

    const targetsRes = await fetch(wsUrl.replace(/^ws:/, 'http:').replace(/\/devtools\/browser\/.*$/, '/json/list'));
    const targets = await targetsRes.json();
    const pageTarget = targets.find((t) => t.type === 'page') || targets[0];
    assert.ok(pageTarget?.webSocketDebuggerUrl, 'Missing CDP page target');

    cdp = new CdpClient(pageTarget.webSocketDebuggerUrl);
    await cdp.send('Page.enable');
    await cdp.send('Runtime.enable');
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      width: 1280,
      height: 720,
      deviceScaleFactor: 1,
      mobile: false,
    });

    await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
      source: `
        window.__nuiPosts = [];
        window.GetParentResourceName = () => 'custom-menu';
        window.fetch = async (url, opts) => {
          const event = String(url).split('/').pop();
          const body = opts && opts.body ? JSON.parse(opts.body) : {};
          window.__nuiPosts.push({ event, body });
          return { ok: true, status: 200, json: async () => ({ ok: true }) };
        };
      `,
    });

    await cdp.send('Page.navigate', { url: server.url });
    await new Promise((r) => setTimeout(r, 400));

    const openOk = await cdp.evalExpr(`
      (() => {
        window.postMessage({
          action: 'menu:open',
          ackToken: 'ack-browser-1',
          spec: {
            id: 'ind_panel',
            title: '洛圣都矿业公司 · L1 · Mine Owner',
            surface: 'list',
            items: [
              { id: 'bal', kind: 'info', label: '金库余额', hint: '$4,195,095', icon: 'fa-solid fa-vault' },
              { id: 'fac', kind: 'info', label: '设施', hint: '矿业设施 L1 · 工位 3/10', icon: 'fa-solid fa-building' },
              { id: 'quota', kind: 'info', label: '配额', hint: '全服剩 10 / 20 · 本组织剩 0 / 10', icon: 'fa-solid fa-chart-pie' },
              { id: 'no_hint', kind: 'info', label: '无右值信息' },
              { id: 'hire', kind: 'action', label: '雇工位（$123,018）', disabled: true, disabledReason: '资金不足', intent: 'ind:hire' },
              { id: 'sell', kind: 'action', label: '卖出…（最多 0 件）', disabled: true, disabledReason: '配额已用完', intent: 'ind:sell' },
              { id: 'back', kind: 'action', label: '返回', intent: 'ind:back' }
            ]
          }
        }, '*');
        return true;
      })()
    `);
    assert.equal(openOk, true);
    await new Promise((r) => setTimeout(r, 200));

    const metrics = await cdp.evalExpr(`
      (() => {
        const shell = document.querySelector('.menu-shell');
        if (!shell) return { missingShell: true };
        const shellWidth = Math.round(shell.getBoundingClientRect().width);
        const fontViolations = [];
        for (const el of shell.querySelectorAll('*')) {
          const text = Array.from(el.childNodes).filter((n) => n.nodeType === 3 && n.textContent.trim()).length > 0;
          if (!text) continue;
          const fs = parseFloat(getComputedStyle(el).fontSize);
          if (fs < 12) fontViolations.push({ cls: el.className, fs, text: el.textContent.trim() });
        }
        const info0 = document.querySelector('[data-item-index="0"]');
        const info3 = document.querySelector('[data-item-index="3"]');
        const labelEl = info0.querySelector('.row-label');
        const hintEl = info0.querySelector('.row-hint');
        const hireEl = document.querySelector('[data-item-index="4"]');
        const backEl = document.querySelector('[data-item-index="6"]');
        return {
          shellWidth,
          fontViolations,
          infoDisabled: info0.classList.contains('disabled'),
          infoFocused: info0.classList.contains('focused'),
          infoOpacity: getComputedStyle(info0).opacity,
          infoBg: getComputedStyle(info0).backgroundColor,
          infoText: info0.textContent,
          info3Text: info3.textContent,
          labelWeight: getComputedStyle(labelEl).fontWeight,
          labelColor: getComputedStyle(labelEl).color,
          hintColor: getComputedStyle(hintEl).color,
          hintAlign: getComputedStyle(hintEl).textAlign,
          hireDisabled: hireEl.classList.contains('disabled'),
          hireFocused: hireEl.classList.contains('focused'),
          hireOpacity: parseFloat(getComputedStyle(hireEl).opacity),
          hireReason: hireEl.querySelector('.row-disabled-reason')?.textContent || '',
          backFocused: backEl.classList.contains('focused'),
        };
      })()
    `);

    assert.equal(metrics.missingShell, undefined);
    assert.equal(metrics.shellWidth, 300, `menu-shell width must be 300px, got ${metrics.shellWidth}`);
    assert.deepEqual(metrics.fontViolations, [], `All text font sizes must be >= 12px: ${JSON.stringify(metrics.fontViolations)}`);
    assert.equal(metrics.infoDisabled, false, 'info row must not have disabled class');
    assert.equal(metrics.infoFocused, false, 'info row must not start focused');
    assert.equal(metrics.infoOpacity, '1', 'info row must not be dimmed');
    assert.equal(metrics.infoText.includes('›'), false, 'info row must not show chevron arrow');
    assert.equal(metrics.info3Text.includes('undefined'), false, 'missing hint must not render undefined');
    assert.equal(metrics.labelWeight, '400', 'info label must be normal font-weight (400)');
    assert.equal(metrics.labelColor, 'rgb(226, 232, 240)', 'info label color must match Scheme A');
    assert.equal(metrics.hintColor, 'rgb(248, 250, 252)', 'info value color must match Scheme A');
    assert.equal(metrics.hintAlign, 'right', 'info value must be right-aligned');
    assert.equal(metrics.hireDisabled, true, 'disabled action row must keep disabled class');
    assert.equal(metrics.hireFocused, true, 'initial focus must skip info rows and land on hire');
    assert.ok(metrics.hireOpacity < 0.7, 'disabled action row must stay dimmed');
    assert.equal(metrics.hireReason, '资金不足', 'disabled action row must display disabledReason');

    // Click info row -> zero nui:intent, zero toasts, focus stays on hire (index 4)
    const afterInfoClick = await cdp.evalExpr(`
      (() => {
        const before = window.__nuiPosts.filter((p) => p.event === 'nui:intent').length;
        document.querySelector('[data-item-index="0"]').click();
        const after = window.__nuiPosts.filter((p) => p.event === 'nui:intent').length;
        return {
          intentDelta: after - before,
          toasts: document.querySelectorAll('.toast-card').length,
          focusedIdx: document.querySelector('.focused')?.getAttribute('data-item-index'),
        };
      })()
    `);
    assert.equal(afterInfoClick.intentDelta, 0, 'clicking info row must not send nui:intent');
    assert.equal(afterInfoClick.toasts, 0, 'clicking info row must not push toast');
    assert.equal(afterInfoClick.focusedIdx, '4', 'clicking info row must not move focus');

    // Real CDP keyboard ArrowDown / ArrowUp skip info rows
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'ArrowDown', code: 'ArrowDown', windowsVirtualKeyCode: 40 });
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'ArrowDown', code: 'ArrowDown', windowsVirtualKeyCode: 40 });
    assert.equal(await cdp.evalExpr(`document.querySelector('.focused')?.getAttribute('data-item-index')`), '5');

    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'ArrowDown', code: 'ArrowDown', windowsVirtualKeyCode: 40 });
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'ArrowDown', code: 'ArrowDown', windowsVirtualKeyCode: 40 });
    assert.equal(await cdp.evalExpr(`document.querySelector('.focused')?.getAttribute('data-item-index')`), '6');

    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'ArrowDown', code: 'ArrowDown', windowsVirtualKeyCode: 40 });
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'ArrowDown', code: 'ArrowDown', windowsVirtualKeyCode: 40 });
    assert.equal(
      await cdp.evalExpr(`document.querySelector('.focused')?.getAttribute('data-item-index')`),
      '4',
      'ArrowDown wrap must skip all 4 info rows'
    );

    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'ArrowUp', code: 'ArrowUp', windowsVirtualKeyCode: 38 });
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'ArrowUp', code: 'ArrowUp', windowsVirtualKeyCode: 38 });
    assert.equal(
      await cdp.evalExpr(`document.querySelector('.focused')?.getAttribute('data-item-index')`),
      '6',
      'ArrowUp wrap must skip all 4 info rows'
    );

    // Enter on '返回' sends nui:intent
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
    await new Promise((r) => setTimeout(r, 50));
    const intents = await cdp.evalExpr(`window.__nuiPosts.filter((p) => p.event === 'nui:intent')`);
    assert.equal(intents.length, 1);
    assert.equal(intents[0].body.itemId, 'back');
    assert.equal(intents[0].body.intent, 'ind:back');

    // Click disabled action row triggers toast without sending nui:intent
    const disabledClick = await cdp.evalExpr(`
      (() => {
        document.querySelector('[data-item-index="4"]').click();
        return {
          intents: window.__nuiPosts.filter((p) => p.event === 'nui:intent').length,
          toastMsg: document.querySelector('.toast-msg')?.textContent || '',
        };
      })()
    `);
    assert.equal(disabledClick.intents, 1, 'disabled action click must not send nui:intent');
    assert.equal(disabledClick.toastMsg, '资金不足');

    const exceptions = cdp.events.filter((e) => e.method === 'Runtime.exceptionThrown');
    assert.deepEqual(exceptions, [], 'No uncaught exceptions allowed in browser');

    console.log(`✔ Headless browser CDP scenarios passed (${path.basename(exe)})`);
  } finally {
    if (cdp) cdp.close();
    proc.kill();
    await server.close();
  }
}

runDomUnitTests();
await runBrowserTests();
