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
};

const QUEST_BLOCKED = {
  id: 'police_ch1',
  title: '蓝墙内外',
  description: '穿上警徽。',
  category: 'law',
  level: 3,
  available: false,
  reason: 'police',
  reason_text: 'Not enough officers on duty',
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
    name: '任务列表：可接的能点，不可接的显示原因而不是消失',
    async run({ page, world }) {
      world.apps = [...world.apps, QUESTS_APP];
      world.quests = [QUEST_FREE, QUEST_BLOCKED];
      world.questActive = [];

      await openQuests(page);
      await waitFor(async () => (await page.locator('.list li').count()) === 2, 5000, '应渲染两条任务');

      checkEqual('不可接的任务也要显示出来（只是标记 blocked）', await page.locator('.list li.blocked').count(), 1);
      checkEqual('只给可接的任务一个接取按钮', await page.locator('.list li button.primary').count(), 1);

      const text = (await page.locator('.quests-app').textContent()) ?? '';
      checkIncludes('不可接原因要摆给玩家看', text, 'Not enough officers on duty');
      checkIncludes('可接任务的标题要渲染', text, QUEST_FREE.title);
    },
  },
  {
    name: '点接取会真的发 appAction，失败原因显示在页面上',
    async run({ page, world }) {
      world.apps = [...world.apps, QUESTS_APP];
      world.quests = [QUEST_FREE];
      world.questActive = [];
      world.actionErrors = { accept: 'rejected' };

      await openQuests(page);
      await page.locator('.list li button.primary').first().click();

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
