// tests/nui/quests.spec.mjs — 任务 App 的浏览器级场景。
//
// 这套断言回答两个问题：
//   1. 30 个任务模板真的能从手机里看到吗（列表渲染、不可接的原因摆出来）；
//   2. 点「接取」是不是真的发出 appAction（而不是只在本地把状态改了）。
import { checkEqual, checkIncludes, openQuests, waitFor } from './harness.mjs';

const QUEST_FREE = {
  id: 'euro_trucking_steel',
  title: '工业钢材配送',
  description: '使用重载货车配送工业用高规格钢板。',
  category: 'logistics',
  level: 1,
  available: true,
  requirements: [
    { kind: 'tags', text: '身份：平民', met: true },
    { kind: 'cooldown', text: '冷却 2 小时', met: true },
  ],
};

const QUEST_BLOCKED = {
  id: 'police_ch1',
  title: '蓝墙内外',
  description: '穿上警徽。',
  category: 'law',
  level: 3,
  available: false,
  reason: 'police',
  reason_text: '在勤警力 ≥ 2（当前 0）',
  requirements: [
    { kind: 'tags', text: '职业：警察', met: false },
    { kind: 'police', text: '在勤警力 ≥ 2（当前 0）', met: false },
  ],
};

const QUESTS_APP = {
  id: 'quests',
  label: '任务',
  icon: '📜',
  queries: ['list', 'active'],
  actions: ['accept', 'abandon'],
};

export const questScenarios = [
  {
    name: '任务列表：只摆能接的，不可接的不出现',
    async run({ page, world, surface }) {
      world.apps = [...world.apps, QUESTS_APP];
      world.quests = [QUEST_FREE, QUEST_BLOCKED];
      world.questActive = [];

      await openQuests(page, surface);
      await waitFor(async () => (await page.locator('.list > li').count()) === 1, 5000, '只该渲染可接的那一条');

      checkEqual('不可接的任务不出现', await page.locator('.list > li.blocked').count(), 0);
      checkEqual('可接的任务有接取按钮', await page.locator('.list > li button.primary').count(), 1);

      const text = (await page.locator('.quests-app').textContent()) ?? '';
      checkIncludes('可接任务的标题要渲染', text, QUEST_FREE.title);

      // 不可接的任务整体不出现（玩家只该看到"我现在能做什么"）
      const blockedRows = await page.locator('.list > li', { hasText: QUEST_BLOCKED.title }).count();
      if (blockedRows !== 0) throw new Error('不可接的任务不该出现在列表里');
      if (text.includes('在勤警力 ≥ 2（当前 0）')) throw new Error('不可接任务的拒绝原因不该出现');

      // 可接任务的需求仍要逐条摊开（绿勾 = 这条线要什么，你满足了吗）
      const met = page.locator('[data-pane="list"] .reqs .req:not(.unmet)');
      await waitFor(async () => (await met.count()) === 2, 5000, '可接任务的两条需求应显示为满足');
      checkIncludes('需求文案要能读', text, '身份：平民');
    },
  },
  {
    name: '点接取会真的发 appAction，失败原因显示在页面上',
    async run({ page, world, surface }) {
      world.apps = [...world.apps, QUESTS_APP];
      world.quests = [QUEST_FREE];
      world.questActive = [];
      world.actionErrors = { accept: 'rejected' };

      await openQuests(page, surface);
      await page.locator('.list > li button.primary').first().click();

      await waitFor(
        () => world.calls.some((c) => c.callback === 'appAction' && c.payload?.action === 'accept'),
        5000,
        '点击接取必须发出 appAction(accept)',
      );
      const call = world.calls.find((c) => c.callback === 'appAction' && c.payload?.action === 'accept');
      checkEqual('action 必须带上 app_id', call.payload.app_id, 'quests');
      checkEqual('必须带上 quest_id', call.payload.params?.quest_id, QUEST_FREE.id);

      await waitFor(
        async () => ((await page.locator('.quests-app').textContent()) ?? '').includes('接取失败'),
        5000,
        '下游拒绝要在页面上可见，不能静默',
      );
    },
  },
];
