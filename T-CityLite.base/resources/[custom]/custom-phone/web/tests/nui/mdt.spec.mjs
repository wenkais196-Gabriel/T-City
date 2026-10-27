// tests/nui/mdt.spec.mjs — browser-level scenarios for the police MDT.
//
// Each scenario gets a fresh browser context, a fresh world and the real
// `html/` bundle. The mock only lives at `https://custom-phone/**`; all UI
// state is produced by the app itself.

import {
  CheckError,
  INCIDENT_911,
  UNIT_ALPHA,
  UNIT_BRAVO,
  checkEqual,
  checkIncludes,
  checkListEquals,
  openDispatchTab,
  openMdt,
  refreshButton,
  waitEnabled,
  waitFor,
  waitText,
} from './harness.mjs';

const CLEAR_TRANSITION_TEXT = '清场失败：警情状态已变化，请刷新后重试';

function unitCallsigns(page) {
  return page.locator('.mdt [data-pane="units"] section.card .row b').allTextContents();
}

async function waitUnitCallsigns(page, timeoutMs) {
  const locator = page.locator('.mdt [data-pane="units"] section.card .row b');
  await waitFor(async () => (await locator.count()) > 0, timeoutMs, '刷新后应出现在勤单位行');
  return locator.allTextContents();
}

async function waitIncidentVisible(page, timeoutMs) {
  const locator = page.locator('.mdt .incident');
  await waitFor(async () => (await locator.count()) > 0, timeoutMs, '接警列表应出现警情行');
  return locator.first();
}

function incidentsRequestCount(world) {
  return world.calls.filter(
    (call) => call.callback === 'appQuery' && call.payload?.query === 'incidents',
  ).length;
}

export const scenarios = [
  {
    name: 'phone:navigate 带页码跳转（agent 不用点也能逐页验收）',
    async run({ page, world, surface }) {
      world.units = [];
      world.incidents = [INCIDENT_911];
      await openMdt(page, surface);

      const lastTab = () => {
        const calls = world.calls.filter((call) => call.callback === 'appState');
        return calls.at(-1)?.payload?.tab ?? null;
      };

      for (const tab of ['case', 'person', 'report', 'me', 'dispatch']) {
        await page.evaluate(
          (value) => window.postMessage({ action: 'phone:navigate', app: 'police_mdt', tab: value }, '*'),
          tab,
        );
        await page.waitForTimeout(250);
        checkEqual(`跳到 ${tab} 后 appState.tab`, lastTab(), tab);
      }

      // 不属于自己的导航消息必须忽略
      await page.evaluate(() =>
        window.postMessage({ action: 'phone:navigate', app: 'quests', tab: 'me' }, '*'),
      );
      await page.waitForTimeout(200);
      checkEqual('别的 App 的跳页消息不影响 MDT', lastTab(), 'dispatch');
    },
  },
  {
    name: 'MDT 把「哪一页、哪条警情」回吐给 agent',
    async run({ page, world, surface }) {
      world.units = [];
      world.incidents = [INCIDENT_911];
      await openMdt(page, surface);
      // 手机上调度页默认停在「单位」段，警情列表在「接警」段里
      await openDispatchTab(page, '接警');
      await waitIncidentVisible(page, 8000);

      const appStates = () => world.calls.filter((call) => call.callback === 'appState');
      const last = () => appStates().at(-1)?.payload ?? {};

      checkEqual('app id', last().app, 'police_mdt');
      checkEqual('初始页', last().tab, 'dispatch');
      checkEqual('未选中时 selected 为空', last().selected ?? null, null);

      // 警情行有入场动画，Playwright 会一直等“稳定”；这里只要事件派发
      await page.locator('.mdt .incident').first().click({ force: true });
      await page.waitForTimeout(250);
      checkEqual('选了警情后 selected 是它的 id', last().selected, String(INCIDENT_911.id));

      await page.locator('.mdt nav.tabs button', { hasText: '人车' }).click({ force: true });
      await page.waitForTimeout(250);
      checkEqual('切到人车页后 tab 变化', last().tab, 'person');
      // 警情 id 在人车页没有意义：继续报会让人以为他还在看那条警情
      checkEqual('离开调度页后 selected 清空', last().selected ?? null, null);
    },
  },
  {
    name: '首轮 500 + 断连：错误可见、loading 复位、刷新后渲染单位与 911 警情',
    async run({ page, world, surface }) {
      world.units = [
        { citizenid: 'COP001', name: 'Alice Adams', callsign: UNIT_ALPHA, dept: 'LSPD', status: 'available', incident_id: null },
        { citizenid: 'COP002', name: 'Bob Brown', callsign: UNIT_BRAVO, dept: 'LSPD', status: 'busy', incident_id: 6 },
      ];
      world.incidents = [INCIDENT_911];
      // First paint: units returns HTTP 500 with a JSON error, incidents has
      // its connection dropped (fetch rejects). Both must be survivable.
      world.failQueries = new Set(['units']);
      world.abortQueries = new Set(['incidents']);

      await openMdt(page, surface);

      // This is the regression guard for "永久 loading": if loading never
      // resets, the refresh button stays disabled until the timeout below.
      await waitEnabled(
        await refreshButton(page),
        5000,
        '首轮请求失败后刷新按钮应恢复可点击（loading 必须复位）',
      );

      const errorText = await waitText(
        page.locator('.mdt > p.err').first(),
        3000,
        '首轮 500 后应显示错误提示',
      );
      checkEqual('应用错误码 db_error 应映射为中文', errorText, '数据库错误，请重试');
      checkListEquals(
        '首轮失败时不应渲染任何单位',
        await unitCallsigns(page),
        [],
      );

      // Second round succeeds; the user clicks the same refresh button again.
      await (await refreshButton(page)).click();
      const callsigns = await waitUnitCallsigns(page, 5000);
      checkListEquals('刷新后应渲染在勤单位', callsigns, [UNIT_ALPHA, UNIT_BRAVO]);
      checkEqual(
        '刷新成功后错误提示应清空',
        await page.locator('.mdt > p.err').count(),
        0,
      );

      await openDispatchTab(page, '接警');
      const incident = await waitIncidentVisible(page, 3000);
      checkIncludes(
        '刷新后应渲染 mock 的 911 警情',
        await incident.locator('b').first().textContent(),
        '#6 [911] 测试警情一号',
      );

      const unitQueries = world.calls.filter(
        (call) => call.callback === 'appQuery' && call.payload?.query === 'units',
      ).length;
      checkEqual('units 应在失败后重新查询一次（共 2 次）', unitQueries, 2);
    },
  },

  {
    name: '911 新建警情：页面不自动刷新，手动刷新后出现在接警列表',
    async run({ page, world, surface }) {
      world.incidents = [];
      await openMdt(page, surface);
      await waitEnabled(await refreshButton(page), 5000, '首轮加载应结束');
      await openDispatchTab(page, '接警');
      checkEqual('初始接警列表应为空', await page.locator('.mdt .incident').count(), 0);
      checkEqual('初始加载只查询一次 incidents', incidentsRequestCount(world), 1);

      // Simulate `/911`: the row lands in the DB after the page loaded, with no
      // NUI push (the known gap from LIVE_TEST_NOTES). The app must show it on
      // the next manual refresh.
      world.incidents.push({
        ...INCIDENT_911,
        id: 42,
        title: '测试警情 911 二号',
        created_at: '2026-10-24 18:25:00',
      });

      await (await refreshButton(page)).click();
      const incident = await waitIncidentVisible(page, 3000);
      checkIncludes(
        '手动刷新后新 911 警情应出现',
        await incident.locator('b').first().textContent(),
        '#42 [911] 测试警情 911 二号',
      );
      checkEqual('手动刷新应重新查询 incidents（共 2 次）', incidentsRequestCount(world), 2);
    },
  },

  {
    name: '错误码映射：invalid_transition 显示中文，未知码原样回退',
    async run({ page, world, surface }) {
      world.incidents = [INCIDENT_911];
      world.actionErrors = {};
      await openMdt(page, surface);
      await waitEnabled(await refreshButton(page), 5000, '首轮加载应结束');
      await openDispatchTab(page, '接警');
      await waitIncidentVisible(page, 3000);

      world.actionErrors.clear = 'invalid_transition';
      await page.locator('.mdt .incident .clear').first().click();

      const notice = await waitText(
        page.locator('.mdt > p.notice').first(),
        3000,
        '清场失败后应显示 notice',
      );
      checkEqual('invalid_transition 应映射为中文', notice, CLEAR_TRANSITION_TEXT);

      const clearCall = world.calls.find(
        (call) => call.callback === 'appAction' && call.payload?.action === 'clear',
      );
      checkEqual('清场动作应带 app_id=police_mdt', clearCall?.payload?.app_id, 'police_mdt');
      checkEqual('清场动作应带 incident_id=6', clearCall?.payload?.params?.incident_id, 6);

      // The table comment promises unknown codes are never swallowed.
      await page.waitForTimeout(80);
      world.actionErrors.clear = 'totally_new_code';
      await page.locator('.mdt .incident .clear').first().click();
      const rawNotice = await waitText(
        page.locator('.mdt > p.notice').first(),
        3000,
        '未知错误码应原样显示',
        (text) => text.includes('totally_new_code'),
      );
      checkEqual('未知错误码应回退为原码', rawNotice, '清场失败：totally_new_code');
    },
  },

  {
    name: '挂起的 appQuery 在超时后恢复，刷新按钮可再次使用',
    async run({ page, world, surface }) {
      world.units = [];
      world.incidents = [];
      // Both requests never settle; the 6s AbortController timeout must turn
      // them into query_failed and let refresh() leave loading=false.
      world.hangQueries = new Set(['units', 'incidents']);
      await openMdt(page, surface);
      await waitEnabled(
        await refreshButton(page),
        15000, // 6s AbortController 超时之后才会复位；慢机器/双形态并行时 9s 会误报
        '挂起的查询超时后刷新按钮应恢复可点击',
      );
      const text = await waitText(
        page.locator('.mdt > p.err').first(),
        3000,
        '超时后应显示查询失败',
        (value) => value.includes('查询失败') || value.includes('query_failed'),
      );
      checkIncludes('超时错误应可见', text, '查询失败');

      // The one-shot hang is consumed; the next refresh succeeds normally.
      await (await refreshButton(page)).click();
      await waitEnabled(await refreshButton(page), 3000, '第二次刷新应结束');
      checkEqual(
        '超时后第二次 incidents 查询应发出',
        incidentsRequestCount(world),
        2,
      );
    },
  },
];
