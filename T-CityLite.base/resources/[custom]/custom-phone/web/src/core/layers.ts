// core/layers.ts — 手机内的"层栈"最小实现（P1 · D5 乙）
//
// 为什么要有：以前没有层栈，只有 `activeApp` 一个 store + 各 App 自己 `z-index`。
// 结果就是真机那串毛病 —— 点输入框不入栈、Backspace 被 Lua 当成"返回"、Esc 直接关整台手机。
//
// 这里只做**文字输入**这一层需要的事（其余层的渲染仍由 AppSurface 负责，不重写）：
//   * 谁拿着键盘（`textLayer`）是一个 store，任何组件都能读；
//   * `use:textFocus` 一个 Svelte action —— 元素获得焦点就入栈并让 CEF 拿走键盘，
//     失焦就出栈并把键盘还给游戏。App 里写一行即可复用：
//
//       <input type="text" use:textFocus />
//
// 与 Lua 的契约：`fetchNui('textFocus', { active })`
//   active=true  → Lua Push 一个 keepInput=false 的帧（键盘归 CEF，字符走原生 input）
//   active=false → pop（键盘回游戏，恢复 nav 注入）

import { writable, get } from 'svelte/store';
import { fetchNui } from '../utils/nui';

/** 当前是否由某个文本层持有键盘。 */
export const textOwned = writable(false);

/** 入栈计数：嵌套输入框（比如弹窗里的输入框）不会互相把对方 pop 掉。 */
let holders = 0;

function notify(active: boolean): void {
  void fetchNui('textFocus', { active }).catch(() => {});
}

function acquire(): void {
  holders += 1;
  if (holders === 1) {
    textOwned.set(true);
    notify(true);
  }
}

function release(): void {
  holders = Math.max(0, holders - 1);
  if (holders === 0 && get(textOwned)) {
    textOwned.set(false);
    notify(false);
  }
}

/** 手机被关掉/换 App 时兜底：把层全部弹掉，别把键盘留在 CEF 里。 */
export function releaseAllTextLayers(): void {
  if (holders > 0 || get(textOwned)) {
    holders = 0;
    textOwned.set(false);
    notify(false);
  }
}

/**
 * 把输入框接到层栈上。
 *
 * 为什么用 focusin/focusout 而不是 onfocus/onblur：Svelte 里直接写在元素上的
 * onblur 会被后续 bind 重渲染覆盖，而 focusin/focusout 是冒泡的、不容易被冲掉。
 */
export function textFocus(node: HTMLElement): { destroy: () => void } {
  let held = false;

  const take = () => {
    if (held) return;
    held = true;
    acquire();
  };
  const drop = () => {
    if (!held) return;
    held = false;
    release();
  };

  node.addEventListener('focus', take);
  node.addEventListener('blur', drop);
  // 元素在持有键盘时被移出 DOM（切 App / 关会话）：blur 不一定触发，这里兜住
  const observer = new MutationObserver(() => {
    if (held && !node.isConnected) drop();
  });
  observer.observe(document.body, { childList: true, subtree: true });

  return {
    destroy() {
      observer.disconnect();
      node.removeEventListener('focus', take);
      node.removeEventListener('blur', drop);
      drop();
    },
  };
}
