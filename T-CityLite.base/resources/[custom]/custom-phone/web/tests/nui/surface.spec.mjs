// surface.spec.mjs — 同一台设备的两种形态：手机（右下角）/ 平板（居中）。
//
// 这里证明的是"外壳按形态换"，不证明 Lua 的判定（那在 test_phone_surface.py 的 lua harness）。

import { checkEqual, checkListEquals, checkTruthy, openMdt, openPhone, openQuests, waitFor } from './harness.mjs';

const CLOSED = () => !document.querySelector('.phone-wrapper');

async function box(page) {
  // 入场动画（手机 0.55s 下滑 + 8° 旋转）期间 boundingBox 是变换后的包围盒，
  // 量出来会比 375 宽 —— 必须等动画结束，否则断言测的是动画而不是布局。
  // 入场动画（手机 0.55s 下滑 + 8° 旋转）期间 boundingBox 是变换后的包围盒。
  // 不用 getAnimations（CEF 里不保证可用），直接等一个大于动画时长的固定时间。
  await page.waitForTimeout(700);
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
    surfaces: ['phone'],
    name: '切到不报状态的 App：页面 id 会跟着换，焦点落在新页面',
    async run({ page, world }) {
      await openPhone(page, 'phone');
      await page.evaluate(() => window.postMessage({ action: 'phone:navigate', app: 'settings' }, '*'));
      await page.waitForTimeout(500);

      const lastApp = () => world.calls.filter((c) => c.callback === 'appState').at(-1)?.payload ?? null;
      checkEqual('切到 Settings 后回吐的 id 是 settings', lastApp()?.app, 'settings');
      checkEqual('焦点落在新页面的第一个控件上',
        await page.locator('.phone-wrapper [data-nav-focus="true"]').count(), 1);

      await page.evaluate(() => window.postMessage({ action: 'phone:navigate', app: 'home' }, '*'));
      await page.waitForTimeout(400);
      checkEqual('回桌面时清空页面 id', lastApp()?.app, '');
    },
  },
  {
    surfaces: ['phone'],
    name: '键盘能从输入框进出：Tab 离开输入框，输入框里方向键不被抢',
    async run({ page }) {
      await openPhone(page, 'phone');
      // 打开 Contacts（有搜索框）
      await page.locator('button[aria-label="Contacts"]').click();
      await page.waitForTimeout(300);
      const input = page.locator('input[placeholder*="Search"], input[type="text"]').first();
      await input.waitFor({ state: 'visible', timeout: 5000 });

      // 用导航走到输入框（DOM 顺序在后半段，最多绕一圈）
      for (let i = 0; i < 30; i += 1) {
        const tag = await page.evaluate(() => document.querySelector('[data-nav-focus="true"]')?.tagName);
        if (tag === 'INPUT') break;
        await page.evaluate(() => window.postMessage({ action: 'phone:nav', kind: 'move', dir: 'down' }, '*'));
        await page.waitForTimeout(50);
      }
      checkEqual('焦点落在输入框上', await page.evaluate(() => document.querySelector('[data-nav-focus="true"]')?.tagName), 'INPUT');

      // 确认键把 DOM 焦点给输入框，然后输入
      await page.evaluate(() => window.postMessage({ action: 'phone:nav', kind: 'activate' }, '*'));
      await page.waitForTimeout(120);
      await page.keyboard.type('alice');
      checkEqual('输入框收到了字符', await input.inputValue(), 'alice');

      // 输入框里按方向键不能把焦点挪走（要能移动光标）
      await page.keyboard.press('ArrowLeft');
      await page.waitForTimeout(80);
      checkEqual('输入框里方向键不抢焦点', await page.evaluate(() => document.querySelector('[data-nav-focus="true"]')?.tagName), 'INPUT');

      // Tab 是唯一的出口：必须能把焦点挪出输入框
      await page.keyboard.press('Tab');
      await page.waitForTimeout(120);
      const afterTab = await page.evaluate(() => document.querySelector('[data-nav-focus="true"]')?.tagName);
      checkTruthy('Tab 把焦点移出了输入框', afterTab !== 'INPUT');
    },
  },
  {
    surfaces: ['phone'],
    name: '键盘/手柄导航：开屏即有焦点、方向键移动、确认打开 App、返回回桌面',
    async run({ page }) {
      const focused = () => page.locator('[data-nav-focus="true"]');
      const gridTiles = () => page.locator('.app-icon-wrapper').count();

      await openPhone(page, 'phone');
      await page.waitForTimeout(200);
      checkEqual('开屏后恰好一个焦点', await focused().count(), 1);
      checkTruthy('焦点在手机里（不是 body）', (await page.locator('.phone-wrapper [data-nav-focus="true"]').count()) === 1);

      const first = await focused().first().getAttribute('aria-label');
      await page.evaluate(() => window.postMessage({ action: 'phone:nav', kind: 'move', dir: 'down' }, '*'));
      await page.waitForTimeout(120);
      const second = await focused().first().getAttribute('aria-label');
      checkTruthy('方向键把焦点移到了另一个元素', first !== second);
      checkEqual('移动后仍然只有一个焦点', await focused().count(), 1);

      // 走到 Contacts 图标再确认；顺序由 DOM 决定，最多转一圈
      for (let i = 0; i < 24; i += 1) {
        const label = await focused().first().getAttribute('aria-label');
        if (label === 'Contacts') break;
        await page.evaluate(() => window.postMessage({ action: 'phone:nav', kind: 'move', dir: 'down' }, '*'));
        await page.waitForTimeout(60);
      }
      checkEqual('焦点停在 Contacts 上', await focused().first().getAttribute('aria-label'), 'Contacts');
      checkTruthy('确认前在桌面（有图标网格）', (await gridTiles()) > 0);

      await page.evaluate(() => window.postMessage({ action: 'phone:nav', kind: 'activate' }, '*'));
      await page.waitForTimeout(400);
      checkEqual('确认键把 App 打开了（桌面网格消失）', await gridTiles(), 0);

      await page.evaluate(() => window.postMessage({ action: 'phone:nav', kind: 'back' }, '*'));
      await page.waitForTimeout(400);
      checkTruthy('返回键回到桌面', (await gridTiles()) > 0);
    },
  },
  {
    surfaces: ['phone'],
    name: '按 M 时 NUI 不自己关（M 归 Lua，CEF 只是同时收到了这个键）',
    async run({ page }) {
      await openPhone(page, 'phone');
      await page.waitForTimeout(200);
      await page.keyboard.press('m');
      await page.waitForTimeout(300);
      checkTruthy('手机仍然开着', (await page.locator('.phone-wrapper').count()) === 1);
      // ESC 仍然归 NUI：Lua 没有绑定 ESC，不存在双重处理
      await page.keyboard.press('Escape');
      await page.waitForTimeout(300);
      checkEqual('ESC 仍然能关', await page.locator('.phone-wrapper').count(), 0);
    },
  },
  {
    surfaces: ['phone'],
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
    surfaces: ['phone'],
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
    surfaces: ['phone'],
    name: '平板：警用终端并出三栏；手机同一页只有一栏',
    async run({ page, world }) {
      world.units = [
        { citizenid: 'COP001', name: 'Alice Adams', callsign: '1-Adam-12', dept: 'LSPD', status: 'available', incident_id: null },
      ];
      world.incidents = [
        {
          id: 40, code: '10-31', title: '持械抢劫 — 便利店', description: '两人持械进入',
          priority: 1, status: 'open', created_at: new Date().toISOString(),
          units: [], primary: null,
          actions: { claim: { allowed: true, label: 'claim' }, clear: { allowed: false, reason: '你还没申领这张单' } },
        },
      ];

      await openMdt(page, 'tablet');
      const surfaceEl = page.locator('.mdt .app-surface');
      checkEqual('平板用 grid 排布', await surfaceEl.getAttribute('data-mode'), 'grid');

      const visiblePanes = await page.locator('.mdt [data-pane]:visible').evaluateAll(
        (nodes) => nodes.map((n) => n.getAttribute('data-pane')),
      );
      checkEqual('三栏都在同一个屏幕上', visiblePanes.sort().join(','), 'detail,incidents,units');

      const columns = await surfaceEl.evaluate((node) => getComputedStyle(node).gridTemplateColumns);
      checkEqual('三列轨道', columns.split(' ').length, 3);

      // 右栏自动选中第一张单（打开详情无副作用，不像 Messages 会清未读）
      await waitFor(
        async () => (await page.locator('[data-pane="detail"] h3').count()) > 0,
        3000,
        '详情栏应显示选中的警情',
      );
      checkTruthy('详情栏显示的是那张单',
        (await page.locator('[data-pane="detail"] h3').first().textContent()).includes('#40'));

      // 同一页在手机上只能看到一栏（先关掉平板，否则 openPhone 会因为"已经开着"立刻返回）
      await page.locator('[data-device-close]').click();
      await page.waitForFunction(() => !document.querySelector('.phone-wrapper'), null, { timeout: 5000 });
      await openMdt(page, 'phone');
      const phoneSurface = page.locator('.mdt .app-surface');
      checkEqual('手机用 stack 排布', await phoneSurface.getAttribute('data-mode'), 'stack');
      const phonePanes = await page.locator('.mdt [data-pane]:visible').count();
      checkEqual('手机一次只显示一个 pane', phonePanes, 1);
    },
  },

  {
    surfaces: ['phone'],
    name: '同一交互在两种形态下发出同一组 app 请求（parity）',
    async run({ page, world }) {
      const keysSince = (from) => [...new Set(world.calls.slice(from)
        .filter((call) => call.callback === 'appQuery' || call.callback === 'appAction')
        .map((call) => `${call.callback}:${call.payload?.app_id}:${call.payload?.query ?? call.payload?.action}`))]
        .sort();

      world.incidents = [{
        id: 41, code: '10-90', title: '入室盗窃', description: '后院有人翻墙',
        priority: 2, status: 'open', created_at: new Date().toISOString(),
        units: [], primary: null,
        actions: { claim: { allowed: true, label: 'claim' }, clear: { allowed: false, reason: '你还没申领这张单' } },
      }];

      await openMdt(page, 'phone');
      const phoneStart = world.calls.length;
      await page.locator('.mdt button.refresh:visible').first().click();
      await waitFor(async () => (await page.locator('.mdt .incident').count()) > 0, 5000, '手机端应渲染警情');
      const phoneKeys = keysSince(phoneStart);

      // 换形态 = 同一台设备换个窗口，不是换一个 app
      await openMdt(page, 'tablet');
      const tabletStart = world.calls.length;
      await page.locator('.mdt button.refresh:visible').first().click();
      await waitFor(async () => (await page.locator('.mdt .incident').count()) > 0, 5000, '平板端应渲染警情');
      const tabletKeys = keysSince(tabletStart);

      checkListEquals('两种形态的 app 请求集合必须相等（平板不许偷偷多拉数据）', tabletKeys, phoneKeys);
    },
  },
  {
    surfaces: ['phone'],
    name: '任务：手机内联，平板并出详情栏',
    async run({ page, world }) {
      world.apps = [...world.apps, { id: 'quests', label: '任务', icon: '📜', queries: ['list', 'active'], actions: ['accept', 'abandon'] }];
      world.quests = [{
        id: 'euro_trucking_steel', title: '工业钢材配送', description: '使用重载货车配送钢板。',
        category: 'logistics', level: 1, available: true,
        requirements: [{ kind: 'tags', text: '身份：平民', met: true }],
      }];
      world.questActive = [];

      await openQuests(page, 'phone');
      checkEqual('手机：只显示一栏', await page.locator('.quests-app [data-pane]:visible').count(), 1);
      // 列表数据是 openQuests 之后异步拉的：等渲染完再数，别和加载赛跑
      await waitFor(async () => (await page.locator('.list > li .desc').count()) > 0, 5000,
        '手机列表应内联任务描述');
      checkTruthy('手机：描述内联在列表里',
        (await page.locator('.list > li .desc').count()) > 0);

      await openQuests(page, 'tablet');
      const panes = await page.locator('.quests-app [data-pane]:visible').evaluateAll(
        (nodes) => nodes.map((node) => node.getAttribute('data-pane')).sort(),
      );
      checkEqual('平板：列表 + 详情并排', panes.join(','), 'list,quest');
      await waitFor(async () => (await page.locator('[data-pane="quest"] .quest-detail').count()) === 1,
        5000, '平板详情栏应渲染选中的任务');
      checkTruthy('平板：详情栏显示同一条任务',
        (await page.locator('[data-pane="quest"] .quest-detail').count()) === 1);
      checkEqual('平板：列表里不再重复描述（收窄成标题+状态）',
        await page.locator('.list > li .desc:visible').count(), 0);
    },
  },
  {
    surfaces: ['phone'],
    name: '两种形态都能关，且关闭只发一次 closePhone',
    async run({ page, world }) {
      await openPhone(page, 'tablet');
      await page.locator('[data-device-close]').click();
      await page.waitForFunction(() => !document.querySelector('.phone-wrapper'), null, { timeout: 5000 });
      const closes = world.calls.filter((c) => c.callback === 'closePhone').length;
      checkEqual('closePhone 调用次数', closes, 1);

      // 手机用 ESC 关（先把焦点放到遮罩上：headless 里按键发给 document.activeElement）
      await openPhone(page, 'phone');
      await page.locator('.phone-backdrop-mask').focus();
      await page.keyboard.press('Escape');
      await page.waitForFunction(() => !document.querySelector('.phone-wrapper'), null, { timeout: 5000 });
      checkEqual('手机 ESC 关闭后仍只多一次 closePhone',
        world.calls.filter((c) => c.callback === 'closePhone').length, 2);
    },
  },
];
