// tests/nui/quests.spec.mjs — 任务 App 的浏览器级场景。
//
// 这套断言回答两个问题：
//   1. 30 个任务模板真的能从手机里看到吗（列表渲染、不可接的原因摆出来）；
//   2. 点「接取」是不是真的发出 appAction（而不是只在本地把状态改了）。
import { checkEqual, checkIncludes, checkTruthy, openPhone, openQuests, waitFor } from './harness.mjs';

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
    surfaces: ['phone'],
    name: '可以用 phone:navigate 确定性地打开任务 App（真机鼠标点不到时 agent 走这条）',
    async run({ page, world }) {
      world.apps = [...world.apps, QUESTS_APP];
      world.quests = [QUEST_FREE];
      world.questActive = [];
      await openPhone(page, 'phone');
      // 真机上 OS 光标被 GTA 锁在屏幕角上，SetCursorPos 无效，合成点击永远落在手机外，
      // 所以自动化导航走消息，而不是坐标。
      // 动态 App 列表是 open 之后异步拉回来的；等它到位再导航（agent 也一样：先看主页有没有那颗图标）
      await page.locator('button[aria-label="任务"]').waitFor({ state: 'visible', timeout: 8000 });
      await page.evaluate(() => window.postMessage({ action: 'phone:navigate', app: 'quests' }, '*'));
      const opened = await page.locator('.quests-app').isVisible().catch(() => false);
      checkTruthy('任务 App 已经打开', opened);
      // 非法 app 名一律忽略，不许把任意字符串塞进 activeApp
      await page.evaluate(() => window.postMessage({ action: 'phone:navigate', app: '../etc/passwd' }, '*'));
      await page.waitForTimeout(200);
      checkTruthy('非法 app 名被忽略（仍停在任务页）', await page.locator('.quests-app').isVisible());
    },
  },
  {
    surfaces: ['phone'],
    name: '换形态不丢当前 App（Lua 用 reason=switch 关掉再重开）',
    async run({ page, world }) {
      world.apps = [...world.apps, QUESTS_APP];
      world.quests = [QUEST_FREE];
      world.questActive = [];
      await openQuests(page, 'phone');
      // Lua 的 ClosePhone('switch') → OpenPhone(kind, 'switch')：中间会推一次 close，
      // 再推一次 phone:open 且 reason=switch。人还看着任务页，不能回桌面。
      await page.evaluate(() =>
        window.postMessage({ action: 'phone:close', reason: 'switch' }, '*'),
      );
      await page.waitForTimeout(100);
      await page.evaluate(() =>
        window.postMessage({ action: 'phone:open', surface: 'tablet', reason: 'switch' }, '*'),
      );
      await page.waitForTimeout(400);
      checkTruthy('换形态后仍在任务页', await page.locator('.quests-app').isVisible());
      // 对照：真正的重新打开（没有 reason=switch）应当回桌面
      await page.evaluate(() =>
        window.postMessage({ action: 'phone:open', surface: 'phone', reason: 'key' }, '*'),
      );
      await page.waitForTimeout(400);
      checkEqual('普通打开回桌面', await page.locator('.quests-app').count(), 0);
    },
  },
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

  {
    // 4615b03 之后不可接的任务整行不进列表；但它们"存在"这件事必须能被看到，
    // 否则新玩家只看到一片空白，会以为任务 App 坏了。
    surfaces: ['phone'],
    name: '任务计数：说清还有多少任务存在，只是条件没满足',
    async run({ page, world }) {
      world.apps = [...world.apps, QUESTS_APP];
      world.quests = [QUEST_FREE, QUEST_BLOCKED];
      world.questActive = [];

      await openQuests(page, 'phone');
      await waitFor(async () => (await page.locator('.list > li').count()) === 1, 5000, '只该渲染可接的那一条');

      const head = (await page.locator('.quests-sub').textContent()) ?? '';
      checkIncludes('计数要说清可接数量', head, '1 条可接');
      checkIncludes('计数要说清还有多少条件未满足', head, '1 条条件未满足');
      checkEqual('不可接的任务仍然不进列表', await page.locator('.list > li', { hasText: QUEST_BLOCKED.title }).count(), 0);
    },
  },
  {
    // 平板右栏原来对「进行中」的任务也渲染「接取」（进行中的行没有 available 字段，
    // 旧的 row.available !== false 判成了可接），点了必然被 TriggerQuest 拒绝。
    surfaces: ['phone'],
    name: '平板：进行中给放弃，切 tab 不残留上一个 tab 的选中',
    async run({ page, world }) {
      world.apps = [...world.apps, QUESTS_APP];
      world.quests = [QUEST_FREE];
      world.questActive = [{
        quest_id: 'police_ch1', title: '蓝墙内外', status: 'active', current_step: '去警局报到',
      }];

      await openQuests(page, 'tablet');
      // 两栏取决于量出来的宽度：开屏那一帧可能还是手机宽度，等它稳定再数
      await waitFor(async () => (await page.locator('.quests-app [data-pane]:visible').count()) === 2,
        5000, '平板应并出两栏');
      checkTruthy('平板：两栏都在', (await page.locator('.quests-app [data-pane]:visible').count()) === 2);

      // 默认在「可接」tab，右栏是那条可接任务
      checkTruthy('默认右栏是可接任务的详情',
        ((await page.locator('[data-pane="quest"]').textContent()) ?? '').includes(QUEST_FREE.title));

      // 切到「进行中」：右栏必须换成进行中的任务，并且动作是「放弃」而不是「接取」
      await page.locator('.tabs button', { hasText: '进行中' }).click();
      await waitFor(
        async () => ((await page.locator('[data-pane="quest"]').textContent()) ?? '').includes('蓝墙内外'),
        5000,
        '切到进行中后右栏要跟着换',
      );
      checkEqual('右栏不该再出现接取按钮', await page.locator('[data-pane="quest"] button.primary').count(), 0);
      const abandonBtn = page.locator('[data-pane="quest"] button.ghost');
      await waitFor(async () => (await abandonBtn.count()) === 1, 5000, '进行中的任务右栏要给放弃');

      await abandonBtn.click();
      await waitFor(
        () => world.calls.some((c) => c.callback === 'appAction' && c.payload?.action === 'abandon'),
        5000,
        '点放弃必须发出 appAction(abandon)',
      );
      const call = world.calls.find((c) => c.callback === 'appAction' && c.payload?.action === 'abandon');
      checkEqual('放弃要带上 quest_id', call.payload.params?.quest_id, 'police_ch1');

      // 切回「可接」：右栏不能还挂着进行中那条（旧实现的 selectedId 会残留）
      await page.locator('.tabs button', { hasText: '可接' }).click();
      await waitFor(
        async () => ((await page.locator('[data-pane="quest"]').textContent()) ?? '').includes(QUEST_FREE.title),
        5000,
        '切回可接后右栏要回到可接任务',
      );
      checkTruthy('右栏不该残留进行中的任务',
        !((await page.locator('[data-pane="quest"]').textContent()) ?? '').includes('蓝墙内外'));
    },
  },
];
