// core/nav.ts — 手机/平板的焦点导航（键位由 Lua 轮询控制后以 phone:nav 消息送来）。
//
// 设计要点见 docs/client/research/keyboard-and-gamepad-navigation.md：
// 浏览器原生 Tab 在游戏里拿不到键（GTA 占了），所以焦点模型放在这里，
// 输入统一从 Lua 来 —— 同一套动作既能被键盘触发，也能被手柄触发。

import { writable } from 'svelte/store';
import { fetchNui } from '../utils/nui';

/**
 * 当前焦点框（视口坐标）+ 标签。用 store 暴露给 App.svelte 画一个**叠加层**，
 * 而不是只给元素加 class：Svelte 一重渲染就把命令式加的 class 冲掉了，
 * 结果就是"焦点其实在动，但人看不见"（真机反馈）。
 */
export const navFocus = writable<{
  label: string;
  x: number;
  y: number;
  width: number;
  height: number;
} | null>(null);

const FOCUSABLE = 'button, [href], input, select, textarea, [data-nav]';

let current: HTMLElement | null = null;

function visible(el: HTMLElement): boolean {
  if (el.hasAttribute('disabled') || el.getAttribute('aria-hidden') === 'true') return false;
  const rect = el.getBoundingClientRect();
  if (rect.width === 0 || rect.height === 0) return false;
  const style = getComputedStyle(el);
  return style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
}

/** 当前活动 app 里的可聚焦元素，按 DOM 顺序。 */
export function focusables(root: ParentNode = document): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(visible);
}

function labelOf(el: HTMLElement): string {
  const aria = el.getAttribute('aria-label');
  if (aria) return aria.trim().slice(0, 40);
  // 输入框没有文字，placeholder 才是有意义的名字（否则只会看到 "input"）
  const placeholder = (el as HTMLInputElement).placeholder;
  if (typeof placeholder === 'string' && placeholder.trim()) return placeholder.trim().slice(0, 40);
  const text = (el.textContent ?? '').replace(/\s+/g, ' ').trim();
  if (text) return text.slice(0, 40);
  return el.tagName.toLowerCase();
}

function report(el: HTMLElement | null, rect?: { x: number; y: number; w: number; h: number }): void {
  // 把"现在焦点在哪个控件上"回吐给 Lua：agent 看不见 DOM，没有这条只能盲按方向键。
  // kind='text' 时 Lua 会压一层 text 帧 —— Esc 先退出输入框，再退出 App。
  const label = el ? labelOf(el) : '';
  const tag = el?.tagName ?? '';
  const kind = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' ? 'text' : 'control';
  void fetchNui('uiFocus', { label, kind, rect }).catch(() => {});
}

// 叠加层的原点：坐标相对它来算，这样叠加层可以直接嵌在手机壳里，
// 不受 fixed 定位 + 外壳 z-index/transform 的摆布（真机上 fixed 那版完全看不见）。
let originEl: HTMLElement | null = null;

/** 告诉 nav 叠加层挂在哪：坐标会变成相对它的偏移。 */
export function setNavOrigin(el: HTMLElement | null): void {
  originEl = el;
  remeasureSoon();
}

function rectOf(el: HTMLElement): { x: number; y: number; w: number; h: number } {
  const box = el.getBoundingClientRect();
  const origin = originEl?.getBoundingClientRect();
  return {
    x: Math.round(box.left - (origin?.left ?? 0)),
    y: Math.round(box.top - (origin?.top ?? 0)),
    w: Math.round(box.width),
    h: Math.round(box.height),
  };
}

function remeasureSoon(): void {
  setTimeout(() => remeasure(), 0);
}

function measure(el: HTMLElement | null): void {
  if (!el) {
    navFocus.set(null);
    return;
  }
  const rect = rectOf(el);
  navFocus.set({ label: labelOf(el), x: rect.x, y: rect.y, width: rect.w, height: rect.h });
}

function paint(el: HTMLElement | null): void {
  if (current && current !== el) {
    current.removeAttribute('data-nav-focus');
    current.classList.remove('nav-focus');
  }
  current = el;
  report(el, el ? rectOf(el) : undefined);
  if (!el) {
    navFocus.set(null);
    return;
  }
  el.setAttribute('data-nav-focus', 'true');
  el.classList.add('nav-focus');
  el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  // 先立刻量一次，再在滚动落定后补一次。
  // 不用 requestAnimationFrame：CEF 在窗口失焦时会把 rAF 节流到几乎不触发，
  // 叠加层就永远画不出来（真机现象：只有元素自带的 outline，没有我们的框和标签）。
  measure(el);
  setTimeout(() => {
    if (current === el) measure(el);
  }, 0);
}

/** 列表滚动/窗口变化后重新贴住焦点（叠加层不跟随 DOM，必须自己重算）。 */
export function remeasure(): void {
  if (current) measure(current);
}

/** 把焦点放到第一个可聚焦元素（开屏、切 app 时用）。 */
export function focusFirst(): void {
  paint(focusables()[0] ?? null);
}

export function currentElement(): HTMLElement | null {
  return current;
}

export function reset(): void {
  paint(null);
}

const ORDER: Record<string, number> = { up: -1, down: 1, left: -1, right: 1 };

/** 方向键移动：up/left 往前、down/right 往后（grid 的几何排序是 P2）。 */
export function move(dir: string): void {
  const items = focusables();
  if (items.length === 0) return;
  // 还没有焦点（鼠标模式 → 玩家第一次按键）：不论按哪个方向都先落到第一个，
  // 而不是"按上就跳到最后" —— 手机桌面默认从 Phone Dialer 开始。
  if (!current) {
    paint(items[0]);
    return;
  }
  const step = ORDER[dir] ?? 1;
  const index = items.indexOf(current);
  const base = index === -1 ? 0 : index;
  const next = (base + step + items.length) % items.length;
  paint(items[next]);
}

/** PageUp/PageDown：一次挪 n 格。长列表按 24 次方向键太蠢。 */
export function moveSteps(dir: string, steps: number): void {
  for (let i = 0; i < Math.max(1, steps); i += 1) move(dir);
}

/** 焦点所在的可滚容器（没有就是 null）。 */
function scrollParent(el: HTMLElement | null): HTMLElement | null {
  let node = el?.parentElement ?? null;
  while (node) {
    if (node.scrollHeight > node.clientHeight + 1) return node;
    node = node.parentElement;
  }
  return null;
}

/**
 * Home / End：跳到第一个 / 最后一个可聚焦元素。
 * 焦点已经在某个可滚容器里时，只在那个容器里跳 —— 否则会跳到壳层的
 * "回桌面"键（真机实测：MDT 列表里按 End 直接跳出了列表，一点用没有）。
 */
export function jump(edge: 'first' | 'last'): void {
  const items = focusables();
  if (items.length === 0) return;
  const box = scrollParent(current);
  const pool = box ? items.filter((el) => box.contains(el)) : items;
  const list = pool.length > 0 ? pool : items;
  paint(edge === 'first' ? list[0] : list[list.length - 1]);
}

/** 确认：焦点在输入框上就保持原样（让人继续打字），否则点一下。 */
export function activate(): void {
  // 鼠标模式下没有焦点：Enter 不做任何事（不乱点、也不"选中第一个再点"）。
  if (!current) return;
  const tag = current.tagName.toLowerCase();
  if (tag === 'input' || tag === 'textarea' || tag === 'select') {
    current.focus();
    return;
  }
  current.click();
}

/** 返回：交给调用方决定"回桌面还是关屏"（shell 知道当前在哪个 app）。 */
export function hasFocus(): boolean {
  return current !== null;
}
