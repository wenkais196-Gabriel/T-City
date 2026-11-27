// tests/nui/industry.spec.mjs — 产业 App（W1）的浏览器级场景。
//
// 断言三件事：
//   1. 卖出必须是 estimate → 确认 → sell，且 appAction 只带 orgId/qty（不带价格）；
//   2. 雇工位只发 orgId，金额/工位号只显示服务端返回值；
//   3. 非 Boss 只读；专用页面注册缺失时 dyn:<id> 仍回落 DynamicApp 只读列表。
import {
  checkEqual,
  checkIncludes,
  checkTruthy,
  openIndustry,
  openPhone,
  waitFor,
  waitLoaded,
} from './harness.mjs';

const INDUSTRY_APP = {
  id: 'industry',
  label: '产业',
  icon: '⛏️',
  queries: ['snapshot', 'snapshot_estimate'],
  actions: ['sell', 'hire'],
};

const SNAPSHOT = {
  orgId: 'mining_co',
  orgLabel: '洛圣都矿业公司',
  gradeName: 'Mine Owner',
  isBoss: true,
  balance: 47675,
  producedUnits: 777,
  phase: {
    key: 'expansion',
    label: '扩张期',
    cycleNo: 3,
    endsAt: 0,
    productionMultiplier: 1.1,
    priceMultiplier: 1.05,
    quotaMultiplier: 1,
    purchasable: true,
  },
  facility: {
    built: true,
    type: 'mine',
    label: '矿业设施',
    level: 1,
    maxLevel: 5,
    workstations: 3,
    workstationCap: 10,
    stock: 45,
    stockCap: 540,
    nextWorkstationCost: 123018,
    hireBlocked: null,
  },
  demand: {
    item: 'iron_ore',
    unitPrice: 50,
    globalTotal: 10,
    globalUsed: 5,
    globalRemaining: 5,
    orgCap: 5,
    orgUsed: 0,
    orgRemaining: 5,
  },
  sellable: { maxQty: 5, blocked: null },
};

function withIndustry(world, overrides = {}) {
  world.apps = [...world.apps, INDUSTRY_APP];
  world.industry = { ...SNAPSHOT, ...overrides };
}

export const industryScenarios = [
  {
    surfaces: ['phone'],
    name: '产业 App：Boss 估价 → 确认卖出，appAction 只带 orgId/qty',
    async run({ page, world }) {
      withIndustry(world);
      await openIndustry(page, 'phone');

      // 快照字段必须来自服务端，而不是前端自己算。
      const text = (await page.locator('.industry-app').textContent()) ?? '';
      checkIncludes('组织名来自快照', text, '洛圣都矿业公司');
      checkIncludes('工位来自快照', text, '3 / 10');
      checkIncludes('单位售价来自快照', text, '$50');
      checkIncludes('下一工位成本来自快照', text, '$123,018');

      await page.locator('#industry-qty').fill('3');
      await page.locator('.estimate-btn').click();

      await waitFor(
        () => world.calls.some((c) => c.callback === 'appQuery' && c.payload?.query === 'snapshot_estimate'),
        5000,
        '点估价必须发 snapshot_estimate 查询',
      );
      const estimateCall = world.calls.find(
        (c) => c.callback === 'appQuery' && c.payload?.query === 'snapshot_estimate',
      );
      checkEqual('估价必须带 app_id', estimateCall.payload.app_id, 'industry');
      checkEqual('估价数量来自输入框', estimateCall.payload.params?.qty, 3);
      checkEqual('估价必须带自己的 orgId', estimateCall.payload.params?.orgId, 'mining_co');

      const revenue = await page.locator('.estimate .revenue').textContent();
      checkEqual('报价只显示服务端 revenue', revenue?.trim(), '$150');

      // estimate → 确认 → sell：确认按钮出现之前不能有 sell 动作。
      const sellBefore = world.calls.filter((c) => c.callback === 'appAction' && c.payload?.action === 'sell');
      checkEqual('确认之前不该卖出', sellBefore.length, 0);
      await page.locator('.estimate button.primary').click();

      await waitFor(
        () => world.calls.some((c) => c.callback === 'appAction' && c.payload?.action === 'sell'),
        5000,
        '点确认必须发 appAction(sell)',
      );
      const sellCall = world.calls.find(
        (c) => c.callback === 'appAction' && c.payload?.action === 'sell',
      );
      checkEqual('sell 必须带 app_id', sellCall.payload.app_id, 'industry');
      checkEqual('sell 数量用服务端确认后的 qty', sellCall.payload.params?.qty, 3);
      checkEqual('sell 必须带自己的 orgId', sellCall.payload.params?.orgId, 'mining_co');
      // 前端不许把价格/收益/工位号塞回服务端。
      checkEqual(
        'sell 只带 orgId/qty',
        Object.keys(sellCall.payload.params ?? {}).sort().join(','),
        'orgId,qty',
      );

      await waitFor(
        async () => ((await page.locator('.feedback').textContent()) ?? '').includes('已卖出 3 件'),
        5000,
        '卖出结果要显示在页面上',
      );
    },
  },
  {
    surfaces: ['phone'],
    name: '产业 App：雇工位只发 orgId，金额/工位号用服务端返回值',
    async run({ page, world }) {
      withIndustry(world);
      await openIndustry(page, 'phone');

      await page.locator('.hire-btn').click();
      await waitFor(
        () => world.calls.some((c) => c.callback === 'appAction' && c.payload?.action === 'hire'),
        5000,
        '点雇工位必须发 appAction(hire)',
      );
      const hireCall = world.calls.find(
        (c) => c.callback === 'appAction' && c.payload?.action === 'hire',
      );
      checkEqual('hire 必须带 app_id', hireCall.payload.app_id, 'industry');
      checkEqual('hire 只带 orgId', Object.keys(hireCall.payload.params ?? {}).join(','), 'orgId');
      checkEqual('hire 的 orgId 是自己的组织', hireCall.payload.params?.orgId, 'mining_co');

      const feedback = await waitFor(
        async () => {
          const value = (await page.locator('.feedback').textContent()) ?? '';
          return value.includes('已雇工位') ? value : false;
        },
        5000,
        '雇工位结果要显示在页面上',
      );
      checkIncludes('工位号来自服务端', feedback, '#2');
      checkIncludes('成本来自服务端', feedback, '$67,500');
    },
  },
  {
    surfaces: ['phone'],
    name: '产业 App：hireBlocked 时按钮不出现，并说明原因',
    async run({ page, world }) {
      withIndustry(world, {
        facility: { ...SNAPSHOT.facility, hireBlocked: 'funds' },
      });
      await openIndustry(page, 'phone');

      checkEqual('受阻时不该渲染雇工位按钮', await page.locator('.hire-btn').count(), 0);
      const text = (await page.locator('.industry-app').textContent()) ?? '';
      checkIncludes('受阻原因要显示出来', text, '金库余额不足');
    },
  },
  {
    surfaces: ['phone'],
    name: '产业 App：非 Boss 只读，不渲染卖出/雇工位按钮',
    async run({ page, world }) {
      withIndustry(world, { isBoss: false, gradeName: '矿工' });
      await openIndustry(page, 'phone');

      checkEqual('非 Boss 不该有估价按钮', await page.locator('.estimate-btn').count(), 0);
      checkEqual('非 Boss 不该有雇工位按钮', await page.locator('.hire-btn').count(), 0);
      const text = (await page.locator('.industry-app').textContent()) ?? '';
      checkIncludes('要告诉成员为什么没有按钮', text, '只有 Boss');
      checkIncludes('成员仍能看库存', text, '45 / 540');
    },
  },
  {
    surfaces: ['phone'],
    name: '注册缺失时 dyn:<id> 回落 DynamicApp 只读列表',
    async run({ page, world }) {
      // 服务端仍下发这个 App，但前端 appRegistry 没有对应组件（旧构建 / 注册遗漏）。
      world.apps = [
        ...world.apps,
        { id: 'industry_stale', label: '产业（旧）', icon: '⛏️', queries: ['snapshot'], actions: [] },
      ];
      await openPhone(page, 'phone');
      const tile = page.locator('button[aria-label="产业（旧）"]');
      await tile.waitFor({ state: 'visible', timeout: 10000 });
      await tile.click();

      await waitLoaded(page, '.dynamic-app', 'DynamicApp');
      checkEqual('没有专用页面时才走 DynamicApp', await page.locator('.industry-app').count(), 0);
      const text = (await page.locator('.dynamic-app').textContent()) ?? '';
      checkIncludes('DynamicApp 仍渲染服务端只读行', text, '洛圣都矿业公司');
      checkTruthy('DynamicApp 标题是服务端 label', text.includes('产业（旧）'));
    },
  },
];
