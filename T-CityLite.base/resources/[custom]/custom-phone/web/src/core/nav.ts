// core/nav.ts — 手机/平板的焦点导航（键位由 Lua 轮询控制后以 phone:nav 消息送来）。
//
// 设计要点见 docs/client/research/keyboard-and-gamepad-navigation.md：
// 浏览器原生 Tab 在游戏里拿不到键（GTA 占了），所以焦点模型放在这里，
// 输入统一从 Lua 来 —— 同一套动作既能被键盘触发，也能被手柄触发。

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

function paint(el: HTMLElement | null): void {
  if (current && current !== el) {
    current.removeAttribute('data-nav-focus');
    current.classList.remove('nav-focus');
  }
  current = el;
  if (!el) return;
  el.setAttribute('data-nav-focus', 'true');
  el.classList.add('nav-focus');
  el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
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
  const step = ORDER[dir] ?? 1;
  let index = current ? items.indexOf(current) : -1;
  if (index === -1) {
    index = step < 0 ? 0 : -1;
  }
  const next = (index + step + items.length) % items.length;
  paint(items[next]);
}

/** 确认：焦点在输入框上就保持原样（让人继续打字），否则点一下。 */
export function activate(): void {
  if (!current) {
    focusFirst();
    return;
  }
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
