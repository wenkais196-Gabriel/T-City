// tests/nui/emergency.spec.mjs — 手机报警入口 + MDT 警情时间
//
// 两件在现场暴露的问题：
// 1. 手机「热线」里的 911 只是个拨号动画，玩家没有真正能用的报警入口；
// 2. MDT 把 DB 的 created_at 原文（2026-10-26T09:43:42.000Z）直接印在板上。

import { checkIncludes, openDispatchTab, openHotlines, openMdt, waitFor } from './harness.mjs';

export const emergencyScenarios = [
  {
    name: '手机报警：真的提交，并把单号显示出来',
    async run({ page, world }) {
      await openHotlines(page);

      const box = page.locator('.report911 .report-input');
      await box.fill('好麦坞大道有人持枪抢店');
      await page.locator('.report911 .report-btn').click();

      // 提交必须真的走 NUI 回调，并且带上玩家写的原因
      for (let i = 0; i < 40; i += 1) {
        if (world.reported911) break;
        await page.waitForTimeout(50);
      }
      if (!world.reported911) throw new Error('点「拨 911」没有发出 report911 回调');
      checkIncludes('报警原因要原样交给服务端', JSON.stringify(world.reported911), '好麦坞大道有人持枪抢店');

      // 回调是异步的：等界面把单号写出来，而不是立刻读
      await waitFor(
        async () => ((await page.locator('.report911').textContent()) ?? '').includes('#42'),
        5000,
        '报警成功后应显示警情单号',
      );
      const text = (await page.locator('.report911').textContent()) ?? '';
      checkIncludes('要把警情单号告诉玩家', text, '#42');
      if (text.includes('NaN')) throw new Error('报警反馈里出现了 NaN');
    },
  },
  {
    name: 'MDT 警情时间：ISO 原文必须变成 HH:MM + 相对时间',
    async run({ page, world }) {
      world.incidents = [
        {
          id: 77,
          code: '911',
          title: '持械抢劫',
          description: '好麦坞大道',
          priority: 1,
          status: 'open',
          created_at: new Date(Date.now() - 3 * 60 * 1000).toISOString(),
        },
      ];
      await openMdt(page);
      await openDispatchTab(page, '接警');

      const text = (await page.locator('.mdt').textContent()) ?? '';
      if (text.includes('T') && /\d{4}-\d{2}-\d{2}T/.test(text)) {
        throw new Error('MDT 还在印 ISO 原文');
      }
      if (text.includes('NaN')) throw new Error('MDT 时间出现了 NaN');
      if (!/[0-9]{2}:[0-9]{2}/.test(text)) throw new Error('警情时间没有渲染成 HH:MM');
      checkIncludes('相对时间要能读', text, '分钟前');
    },
  },
  {
    name: 'MDT 前往：把现场画成路线；到场后收掉',
    async run({ page, world }) {
      world.incidents = [
        {
          id: 78, code: '10-31', title: '持械抢劫', description: '好麦坞大道',
          priority: 1, status: 'open', created_at: new Date().toISOString(),
          x: 111.5, y: 222.5, z: 33,
        },
      ];
      await openMdt(page);
      await openDispatchTab(page, '接警');

      const card = page.locator('.incident', { hasText: '#78' });
      await card.locator('button', { hasText: '前往' }).click();

      await waitFor(async () => world.mdtRoute !== null, 5000, '点前往应画出一条路线');
      const route = world.mdtRoute;
      if (route.x !== 111.5 || route.y !== 222.5) {
        throw new Error(`路线坐标不对：${JSON.stringify(route)}`);
      }
      checkIncludes('路线标签要带单号', String(route.label), '#78');

      await card.locator('button', { hasText: '到场' }).click();
      await waitFor(async () => world.mdtRoute === null, 5000, '到场地后路线应收掉');
    },
  },
];
