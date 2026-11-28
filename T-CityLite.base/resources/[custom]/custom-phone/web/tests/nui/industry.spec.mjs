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
  actions: ['sell', 'hire', 'withdraw'],
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
  // 服务端快照的只读提现字段：本周已提 10,000 / 额度 25,000 / 税 20%。
  treasury: { weeklyQuota: 25000, withdrawnThisWeek: 10000, taxRate: 0.2 },
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
      checkEqual('非 Boss 提现按钮禁用', await page.locator('.withdraw-btn').isDisabled(), true);
      const text = (await page.locator('.industry-app').textContent()) ?? '';
      checkIncludes('要告诉成员为什么没有按钮', text, '只有 Boss');
      checkIncludes('成员仍能看库存', text, '45 / 540');
      checkIncludes('非 Boss 提现原因', text, '只有 Boss 能提现');
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
  {
    surfaces: ['phone'],
    name: '产业 App：升级库存上限后上限/等级/下一级价格随快照更新',
    async run({ page, world }) {
      const before = {
        ...SNAPSHOT,
        balance: 1000000,
        facility: {
          ...SNAPSHOT.facility,
          stockLevel: 0,
          stockMaxLevel: 6,
          stockCap: 540,
          nextStockUpgradeCost: 40000,
          stockUpgradeBlocked: null,
        },
      };
      const after = {
        ...before,
        balance: 960000,
        facility: {
          ...before.facility,
          stockLevel: 1,
          stockCap: 1440,
          nextStockUpgradeCost: 64000,
        },
      };
      withIndustry(world);
      // 模拟服务端：收到 upgrade_stock 后，后续 snapshot 返回升级后的状态。
      // 前端必须靠重新拉快照显示新值，而不是自己 +900 或 +1 级。
      Object.defineProperty(world, 'industry', {
        configurable: true,
        get() {
          const upgraded = world.calls.some(
            (call) => call.callback === 'appAction' && call.payload?.action === 'upgrade_stock',
          );
          return upgraded ? after : before;
        },
      });

      await openIndustry(page, 'phone');
      const initial = (await page.locator('.industry-app').textContent()) ?? '';
      checkIncludes('升级前库存上限来自快照', initial, '45 / 540');
      checkIncludes('升级前库存等级来自快照', initial, 'L0 / 6');
      checkIncludes('升级前下一级价格来自快照', initial, '$40,000');

      await page.locator('.stock-upgrade-btn').click();
      await waitFor(
        () => world.calls.some(
          (call) => call.callback === 'appAction' && call.payload?.action === 'upgrade_stock',
        ),
        5000,
        '点升级必须发 appAction(upgrade_stock)',
      );
      const upgradeCall = world.calls.find(
        (call) => call.callback === 'appAction' && call.payload?.action === 'upgrade_stock',
      );
      checkEqual('upgrade 必须带 app_id', upgradeCall.payload.app_id, 'industry');
      checkEqual(
        'upgrade 只带 orgId',
        Object.keys(upgradeCall.payload.params ?? {}).join(','),
        'orgId',
      );
      checkEqual('upgrade 的 orgId 是自己的组织', upgradeCall.payload.params?.orgId, 'mining_co');

      // 组件在动作成功后自己 load()；等新快照渲染出来。
      const upgraded = await waitFor(
        async () => {
          const text = (await page.locator('.industry-app').textContent()) ?? '';
          return text.includes('45 / 1440') ? text : false;
        },
        5000,
        '升级后库存上限必须变成 1,440（说明重新拉取了服务端快照）',
      );
      checkIncludes('升级后库存等级来自快照', upgraded, 'L1 / 6');
      checkIncludes('升级后下一级价格来自快照', upgraded, '$64,000');
      checkIncludes('升级结果要显示在页面上', upgraded, '库存上限已升级');
    },
  },
  {
    surfaces: ['phone'],
    name: '产业 App：库存满级时升级按钮禁用并说明原因',
    async run({ page, world }) {
      withIndustry(world, {
        facility: {
          ...SNAPSHOT.facility,
          stockLevel: 6,
          stockMaxLevel: 6,
          stockCap: 5940,
          nextStockUpgradeCost: null,
          stockUpgradeBlocked: 'max_level',
        },
      });
      await openIndustry(page, 'phone');

      const text = (await page.locator('.industry-app').textContent()) ?? '';
      checkIncludes('满级库存上限来自快照', text, '45 / 5940');
      checkIncludes('满级时说明原因', text, '库存已满级');
      checkEqual(
        '满级时升级按钮必须禁用',
        await page.locator('.stock-upgrade-btn').isDisabled(),
        true,
      );
      checkEqual(
        '满级时不该出现「下一级价格」',
        await page.locator('.industry-app').textContent().then((t) => (t ?? '').includes('下一级价格')),
        false,
      );
    },
  },
  {
    surfaces: ['phone'],
    name: '产业 App：提现显示本周额度/税后到账，动作只带 orgId/amount',
    async run({ page, world }) {
      withIndustry(world);
      await openIndustry(page, 'phone');

      const text = (await page.locator('.industry-app').textContent()) ?? '';
      checkIncludes('本周已提/额度来自服务端快照', text, '本周已提 $10,000 / 额度 $25,000');
      checkIncludes('税率来自服务端快照', text, '20%');
      checkIncludes('本周还可提由快照算', text, '本周还可提 $15,000');

      await page.locator('#industry-withdraw-amount').fill('5000');
      const net = await page.locator('.withdraw-net b').textContent();
      checkEqual('税后到账按 taxRate 预估', net?.trim(), '$4,000');
      checkEqual('额度未用尽时提现按钮可点', await page.locator('.withdraw-btn').isDisabled(), false);

      await page.locator('.withdraw-btn').click();
      await waitFor(
        () => world.calls.some(
          (call) => call.callback === 'appAction' && call.payload?.action === 'withdraw',
        ),
        5000,
        '点提现必须发 appAction(withdraw)',
      );
      const call = world.calls.find(
        (item) => item.callback === 'appAction' && item.payload?.action === 'withdraw',
      );
      checkEqual('withdraw 必须带 app_id', call.payload.app_id, 'industry');
      // 前端不许把净值/税/价格塞回服务端。
      checkEqual(
        'withdraw 只带 orgId/amount',
        Object.keys(call.payload.params ?? {}).sort().join(','),
        'amount,orgId',
      );
      checkEqual('withdraw 的 orgId 是自己的组织', call.payload.params?.orgId, 'mining_co');
      checkEqual('withdraw 的 amount 来自输入框', call.payload.params?.amount, 5000);

      const feedback = await waitFor(
        async () => {
          const value = (await page.locator('.feedback').textContent()) ?? '';
          return value.includes('已提现') ? value : false;
        },
        5000,
        '提现结果要显示在页面上',
      );
      checkIncludes('税后到账用服务端返回值', feedback, '$4,000');
    },
  },
  {
    surfaces: ['phone'],
    name: '产业 App：本周额度用尽时提现按钮禁用并说明原因',
    async run({ page, world }) {
      withIndustry(world, {
        treasury: { weeklyQuota: 25000, withdrawnThisWeek: 25000, taxRate: 0.2 },
      });
      await openIndustry(page, 'phone');

      const text = (await page.locator('.industry-app').textContent()) ?? '';
      checkIncludes('额度显示已提满', text, '本周已提 $25,000 / 额度 $25,000');
      checkIncludes('说明额度已用尽', text, '本周提现额度已用完');
      checkEqual('额度用尽时按钮禁用', await page.locator('.withdraw-btn').isDisabled(), true);
      checkEqual(
        '额度用尽时不该发出提现动作',
        world.calls.filter(
          (call) => call.callback === 'appAction' && call.payload?.action === 'withdraw',
        ).length,
        0,
      );
    },
  },
];
