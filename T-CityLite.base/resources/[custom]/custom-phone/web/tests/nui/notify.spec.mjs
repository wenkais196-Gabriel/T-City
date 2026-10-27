// tests/nui/notify.spec.mjs — 通知托盘的时间显示
//
// 现场看到的 bug："notify 的时间显示成 NaN:NaN"。根因不是某一个时间戳错了，而是
// 格式化函数直接 new Date(v).getHours()：只要字段缺失或是对象，界面就印出 NaN。
// 现在时间统一走 utils/time.formatClock，坏值回退成 --:--，并且这条用例守住它。

import { checkIncludes, openNotifications, checkEqual } from './harness.mjs';

const ISO_OK = {
  id: 1,
  title: '10-50: 交通事故',
  content: '洛圣都大道与阿尔塔街交叉口',
  timestamp: '2026-10-26T09:43:42.000Z',
  is_read: false,
};

const NO_TS = {
  id: 2,
  title: '10-32: 持械人员',
  content: '好麦坞大道',
  is_read: false,
};

export const notifyScenarios = [
  {
    surfaces: ['phone'],
    name: '通知时间：坏时间戳不许渲染成 NaN',
    async run({ page, world, surface }) {
      // 真机日志里出现过：值看着是标准 ISO，但前后混了 BOM / 零宽空格 → 解析失败，
      // 界面显示 --:--。这三种都必须照常渲染成 HH:MM。
      const ISO_BOM = { ...ISO_OK, id: 9901, timestamp: '﻿2026-10-27T18:15:16.000Z' };
      const ISO_ZWSP = { ...ISO_OK, id: 9902, timestamp: '2026-10-27T18:15:16.000Z​' };
      world.notifications = [ISO_OK, NO_TS, ISO_BOM, ISO_ZWSP];
      await openNotifications(page);

      const text = (await page.locator('.notifications-app').textContent()) ?? '';
      if (text.includes('NaN')) {
        throw new Error('通知时间渲染出了 NaN:NaN —— 格式化函数没有兜住坏值');
      }
      // 有效的那条必须显示成 HH:MM
      const clock = /[0-9]{2}:[0-9]{2}/.test(text);
      if (!clock) throw new Error('有效时间戳没有渲染成 HH:MM');
      // 缺 timestamp 的那条回退成占位符，而不是空白或 NaN
      checkIncludes('缺失时间要显示占位符', text, '--:--');
      checkIncludes('两条通知都要渲染', text, '持械人员');
      // BOM/零宽两条：除了 NO_TS 那一条占位符之外，其余都必须是真实时间
      const placeholders = (text.match(/--:--/g) ?? []).length;
      checkEqual('只有缺时间的那条是占位符', placeholders, 1);
    },
  },
];
