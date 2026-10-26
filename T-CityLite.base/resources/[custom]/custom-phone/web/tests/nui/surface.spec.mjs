// surface.spec.mjs — 同一台设备的两种形态：手机（右下角）/ 平板（居中）。
//
// 这里证明的是"外壳按形态换"，不证明 Lua 的判定（那在 test_phone_surface.py 的 lua harness）。

import { checkEqual, checkTruthy, createWorld, openPhone } from './harness.mjs';

const CLOSED = () => !document.querySelector('.phone-wrapper');

async function box(page) {
  // 入场动画（手机 0.55s 下滑 + 8° 旋转）期间 boundingBox 是变换后的包围盒，
  // 量出来会比 375 宽 —— 必须等动画结束，否则断言测的是动画而不是布局。
  await page.waitForFunction(() => {
    const el = document.querySelector('.phone-wrapper');
    if (!el) return false;
    return el.getAnimations().every((a) => a.playState === 'finished');
  }, null, { timeout: 3000 });
  const el = page.locator('.phone-wrapper');
  const b = await el.boundingBox();
  const surface = await el.getAttribute('data-surface');
  const computed = await page.evaluate(() => {
    const node = document.querySelector('.phone-wrapper');
    const style = getComputedStyle(node);
    return { width: parseFloat(style.width), height: parseFloat(style.height) };
  });
  return { b, surface, viewport: page.viewportSize(), computed };
}

export const surfaceScenarios = [
  {
    name: '手机形态：右下角 375x780，有刘海和手势条',
    async run({ page }) {
      await openPhone(page, 'phone');
      const { b, surface, viewport, computed } = await box(page);
      checkEqual('data-surface', surface, 'phone');
      checkEqual('宽度', Math.round(computed.width), 375);
      checkEqual('高度', Math.round(computed.height), 780);
      checkEqual('包围盒宽度', Math.round(b.width), 375);
      checkEqual('右边距 30px', Math.round(viewport.width - (b.x + b.width)), 30);
      checkEqual('下边距 30px', Math.round(viewport.height - (b.y + b.height)), 30);
      checkTruthy('有刘海', await page.locator('.phone-notch').isVisible());
      checkTruthy('有手势条', await page.locator('.home-gesture-bar').isVisible());
      checkEqual('手机不该有关闭按钮（用电源键/手势条/ESC）',
        await page.locator('[data-device-close]').count(), 0);
    },
  },
  {
    name: '平板形态：居中 1034x676，无刘海无手势条但有关闭按钮',
    async run({ page }) {
      await openPhone(page, 'tablet');
      const { b, surface, viewport, computed } = await box(page);
      checkEqual('data-surface', surface, 'tablet');
      checkEqual('宽度', Math.round(computed.width), 1034);
      checkEqual('高度', Math.round(computed.height), 676);
      const centerOffset = Math.abs(b.x + b.width / 2 - viewport.width / 2);
      checkTruthy(`水平居中（偏移 ${Math.round(centerOffset)}px）`, centerOffset <= 1);
      checkEqual('平板没有刘海', await page.locator('.phone-notch').count(), 0);
      checkEqual('平板没有手势条', await page.locator('.home-gesture-bar').count(), 0);
      checkTruthy('平板上必须有看得见的关闭入口',
        await page.locator('[data-device-close]').isVisible());
    },
  },
  {
    name: '两种形态都能关，且关闭只发一次 closePhone',
    async run({ page, world }) {
      await openPhone(page, 'tablet');
      await page.locator('[data-device-close]').click();
      await page.waitForFunction(() => !document.querySelector('.phone-wrapper'), null, { timeout: 5000 });
      const closes = world.calls.filter((c) => c.callback === 'closePhone').length;
      checkEqual('closePhone 调用次数', closes, 1);

      // 手机用 ESC 关
      await openPhone(page, 'phone');
      await page.keyboard.press('Escape');
      await page.waitForFunction(() => !document.querySelector('.phone-wrapper'), null, { timeout: 5000 });
      checkEqual('手机 ESC 关闭后仍只多一次 closePhone',
        world.calls.filter((c) => c.callback === 'closePhone').length, 2);
    },
  },
];
