// tests/nui/quests.spec.mjs — 任务 App 的浏览器级场景。
//
// 这套断言回答两个问题：
//   1. 30 个任务模板真的能从手机里看到吗（列表渲染、不可接的原因摆出来）；
//   2. 点「接取」是不是真的发出 appAction（而不是只在本地把状态改了）。
import { checkEqual, checkIncludes, checkTruthy, openPhone, openQuests, waitFor, waitText } from './harness.mjs';

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
  queries: ['list', 'active', 'receipts'],
  actions: ['accept', 'abandon'],
};

// GetQuestReceipts 的真实 DTO 形状（camelCase：questId / issuedAt）。
// 关键点：net_text 是服务端算好的 35，非售出五行之和 50-28+19+3 = 44 ——
// UI 必须显示 35；前端一旦自己求和就会露馅。
const RECEIPT = {
  questId: 'hotdog',
  issuedAt: 1794787200, // 2026-11-16T00:00:00Z（本地化后仍落在 2026）
  net: 35,
  net_text: '35',
  replayed: false,
  context: {
    quest_title: '热狗摊',
    minutes: 14,
    sold_count: 9,
    leftover: { common: 2, rare: 1, exotic: 0 },
    raw_count: 3,
    billable: true,
  },
  rows: [
    { id: 'deposit', label: '押金退回', amount: 50, amount_text: '50', kind: 'in' },
    { id: 'rent', label: '租金（按时长）', amount: -28, amount_text: '28', kind: 'out' },
    { id: 'sold', label: '售出（已付现）', amount: 115, amount_text: '115', kind: 'cash', counted: false },
    { id: 'leftover', label: '成品回收', amount: 19, amount_text: '19', kind: 'in' },
    { id: 'raw', label: '原料回收', amount: 3, amount_text: '3', kind: 'in' },
    { id: 'tax', label: '税（0% · 未启用）', amount: 0, amount_text: '0', kind: 'out', muted: true },
  ],
};

function withReceipts(world) {
  world.apps = [...world.apps, QUESTS_APP];
  world.quests = [];
  world.questActive = [];
}

async function openSettledTab(page) {
  await page.locator('.quests-app .tabs button', { hasText: '已结算' }).click();
}

export const questScenarios = [
  {
    surfaces: ['phone'],
    name: '长列表：焦点往下走会把列表带着滚，且焦点始终留在可视区',
    async run({ page, world }) {
      world.apps = [...world.apps, QUESTS_APP];
      // 24 条，肯定超过一屏（一屏大约 6-7 条）
      world.quests = Array.from({ length: 24 }, (_, i) => ({
        ...QUEST_FREE,
        id: `bulk_q${i}`,
        title: `批量任务 ${i}`,
      }));

      await openQuests(page, 'phone');

      // 真正滚动的是焦点元素所在的可滚祖先（单栏是 .pane，不是 .quests-app）
      const scrollerTop = () => page.evaluate(() => {
        let el = document.querySelector('[data-nav-focus="true"]');
        while (el) {
          if (el.scrollHeight > el.clientHeight + 1) return el.scrollTop;
          el = el.parentElement;
        }
        return -1;
      });

      // 开屏焦点在壳层（关闭键/标题栏），不在列表里，所以这时还量不到滚动容器；
      // 先走两步进入列表再当基线。
      for (let i = 0; i < 2; i += 1) {
        await page.evaluate(() => window.postMessage({ action: 'phone:nav', kind: 'move', dir: 'down' }, '*'));
        await page.waitForTimeout(60);
      }
      checkEqual('进入列表时还在顶部', await scrollerTop(), 0);

      for (let i = 0; i < 14; i += 1) {
        await page.evaluate(() => window.postMessage({ action: 'phone:nav', kind: 'move', dir: 'down' }, '*'));
        await page.waitForTimeout(60);
      }

      const after = await scrollerTop();
      checkTruthy('焦点往下走会把列表滚下去', after > 0);

      const staysInView = await page.evaluate(() => {
        const focused = document.querySelector('[data-nav-focus="true"]');
        if (!focused) return false;
        let box = focused.parentElement;
        while (box && box.scrollHeight <= box.clientHeight + 1) box = box.parentElement;
        if (!box) return false;
        const ring = focused.getBoundingClientRect();
        const view = box.getBoundingClientRect();
        return ring.top >= view.top - 2 && ring.bottom <= view.bottom + 2;
      });
      checkTruthy('焦点元素停在可视区内', staysInView);

      for (let i = 0; i < 16; i += 1) {
        await page.evaluate(() => window.postMessage({ action: 'phone:nav', kind: 'move', dir: 'up' }, '*'));
        await page.waitForTimeout(60);
      }
      // 焦点回到壳层时量不到滚动容器（-1），也算"回到顶部"
      const back = await scrollerTop();
      checkTruthy('走回顶部时列表也回到顶部', back <= 0);

      // 翻页键：两次 PageDown 应该走得更远，End 直接落到最后一个
      const focusLabel = () => page.evaluate(
        () => document.querySelector('[data-nav-focus="true"]')?.textContent?.trim() ?? '',
      );
      // 上面的循环用的是 phone:nav 消息（模拟 Lua 在管键盘），CEF 侧 120ms 内会
      // 主动让位去重；等一会儿再按键，模拟"人停了一下再按"
      await page.waitForTimeout(200);
      await page.keyboard.press('PageDown');
      await page.waitForTimeout(150);
      const afterPage = await scrollerTop();
      // 滚动用 block:'nearest'（最小滚动），所以判"明显比一步远"而不是"整屏"
      checkTruthy('PageDown 一次走的位置比一步远得多', afterPage > 80);

      // End：焦点已经在列表里，所以只在列表里跳 —— 落到底部那条的按钮上
      await page.waitForTimeout(200);
      await page.keyboard.press('End');
      await page.waitForTimeout(250);
      const bottom = await page.evaluate(() => {
        let el = document.querySelector('[data-nav-focus="true"]');
        const inside = Boolean(el?.closest('.quests-app'));
        while (el && el.scrollHeight <= el.clientHeight + 1) el = el.parentElement;
        return {
          inside,
          top: el?.scrollTop ?? -1,
          max: el ? el.scrollHeight - el.clientHeight : -1,
          // 容器有内边距，'nearest' 滚动不会贴到 0 误差
          atBottom: el ? el.scrollTop >= el.scrollHeight - el.clientHeight - 24 : false,
        };
      });
      checkTruthy('End 之后焦点还在列表里', bottom.inside);
      checkTruthy('End 把列表带到底部', bottom.atBottom);

      // Home：回到列表第一个可聚焦元素（不是壳层的关闭键）
      await page.waitForTimeout(200);
      await page.keyboard.press('Home');
      await page.waitForTimeout(250);
      const topBack = await page.evaluate(() => {
        const el = document.querySelector('[data-nav-focus="true"]');
        const inside = Boolean(el?.closest('.quests-app'));
        let box = el?.parentElement ?? null;
        while (box && box.scrollHeight <= box.clientHeight + 1) box = box.parentElement;
        return { inside, top: box?.scrollTop ?? -1 };
      });
      checkTruthy('Home 之后焦点还在列表里', topBack.inside);
      // 列表容器上面还有页头，所以"顶部"是接近 0 而不是严格 0
      checkTruthy('Home 把列表带回顶部', topBack.top >= 0 && topBack.top <= 120);
    },
  },
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

      // 默认在「可接」tab，右栏是那条可接任务。
      // 右栏内容是异步拉回来的：CI 上「两栏都在」成立的那一刻详情可能还没渲染，
      // 同步读一次就红（这块换着地方红过两次）。所以要等文本出现再断言。
      await waitFor(
        async () => ((await page.locator('[data-pane="quest"]').textContent()) ?? '').includes(QUEST_FREE.title),
        5000,
        '默认右栏要显示可接任务的标题',
      );
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

  {
    surfaces: ['phone'],
    name: '已结算：手机点行内联展开六行账单，净额用服务端 net_text',
    async run({ page, world }) {
      withReceipts(world);
      world.questReceipts = [RECEIPT];

      await openQuests(page, 'phone');
      await openSettledTab(page);
      await waitFor(
        async () => (await page.locator('li[data-receipt-id]').count()) === 1,
        5000,
        '「已结算」列表要出现一张账单',
      );

      const rowText = (await page.locator('li[data-receipt-id]').textContent()) ?? '';
      checkIncludes('列表行有任务标题', rowText, '热狗摊');
      checkIncludes('列表行有净额文本', rowText, '$35');
      const dateText = (await page.locator('.receipt-date').first().textContent()) ?? '';
      checkTruthy('列表行的日期已本地化', /2026/.test(dateText));

      await page.locator('li[data-receipt-id]').click();
      await waitFor(
        async () => (await page.locator('[data-pane="list"] .bill-card').count()) === 1,
        5000,
        '手机点账单行应在 list 内联展开账单卡',
      );
      checkEqual('手机的 detail pane 不塞账单卡',
        await page.locator('[data-pane="quest"] .bill-card').count(), 0);
      checkEqual('账单卡恰好六行', await page.locator('.bill-card .bill-row').count(), 6);

      const card = (await page.locator('.bill-card').textContent()) ?? '';
      checkIncludes('售出行标「已付现 · 不计入净额」', card, '已付现 · 不计入净额');
      checkIncludes('税行标「未启用」', card, '未启用');
      checkIncludes('税行金额显示破折号',
        await page.locator('.bill-row[data-row-id="tax"] .bill-amount').textContent(), '—');
      checkIncludes('净额直接显示 net_text', await page.locator('.bill-net').textContent(), '$35');
      checkTruthy('净额不是 rows 求和（44）',
        !((await page.locator('.bill-net').textContent()) ?? '').includes('44'));
      checkTruthy('不显示「手头现金」', !card.includes('手头现金'));
    },
  },
  {
    surfaces: ['phone'],
    name: '已结算空态：没有账单时给说明，不摆一张假卡',
    async run({ page, world }) {
      withReceipts(world);
      world.questReceipts = [];

      await openQuests(page, 'phone');
      await openSettledTab(page);
      const text = await waitText(
        page.locator('[data-pane="list"]'),
        5000,
        '空态文案要出现',
        (value) => value.includes('还没有已结算的班次'),
      );
      checkIncludes('空态解释下一步', text, '收摊结算后');
      checkIncludes('空态说明回看期限', text, '账单在本次服务器运行期间可回看');
      checkEqual('空态不摆账单卡', await page.locator('.bill-card').count(), 0);
    },
  },
  {
    surfaces: ['phone'],
    name: '已结算：replayed 的账单标「已结算（重复查看）」',
    async run({ page, world }) {
      withReceipts(world);
      world.questReceipts = [{ ...RECEIPT, replayed: true }];

      await openQuests(page, 'phone');
      await openSettledTab(page);
      await waitFor(
        async () => (await page.locator('li[data-receipt-id]').count()) === 1,
        5000,
        'replayed 账单也要进列表',
      );
      checkIncludes('列表行标重复查看',
        await page.locator('li[data-receipt-id]').textContent(), '已结算（重复查看）');

      await page.locator('li[data-receipt-id]').click();
      await waitFor(async () => (await page.locator('.bill-card').count()) === 1, 5000, '账单卡展开');
      checkIncludes('账单卡也标重复查看',
        await page.locator('.bill-card').textContent(), '已结算（重复查看）');
    },
  },
  {
    surfaces: ['tablet'],
    name: '平板：已结算列表 + 右栏账单卡（list 不内联）',
    async run({ page, world }) {
      withReceipts(world);
      world.questReceipts = [RECEIPT];

      await openQuests(page, 'tablet');
      await waitFor(
        async () => (await page.locator('.quests-app [data-pane]:visible').count()) === 2,
        5000,
        '平板应并出两栏',
      );
      await openSettledTab(page);
      await waitFor(
        async () => (await page.locator('li[data-receipt-id]').count()) === 1,
        5000,
        '平板列表要出现账单行',
      );
      await page.locator('li[data-receipt-id]').click();
      await waitFor(
        async () => (await page.locator('[data-pane="quest"] .bill-card').count()) === 1,
        5000,
        '平板右栏要渲染账单卡',
      );
      checkEqual('平板 list 里不内联账单卡',
        await page.locator('[data-pane="list"] .bill-card').count(), 0);
      checkEqual('右栏账单六行',
        await page.locator('[data-pane="quest"] .bill-row').count(), 6);
    },
  },
  {
    surfaces: ['phone'],
    name: '已结算：导出缺失时错误可见（receipt_unavailable）',
    async run({ page, world }) {
      withReceipts(world);
      world.questReceiptsError = 'receipt_unavailable';

      await openQuests(page, 'phone');
      await openSettledTab(page);
      await waitText(
        page.locator('[data-pane="list"]'),
        5000,
        '导出缺失不能静默成空列表',
        (value) => value.includes('账单暂时不可用'),
      );
    },
  },
];
