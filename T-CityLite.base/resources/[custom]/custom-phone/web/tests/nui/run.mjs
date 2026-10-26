#!/usr/bin/env node
// tests/nui/run.mjs — minimal runner for the MDT NUI scenarios.
//
// Why not a full test framework: the suite only needs one browser, one
// throwaway static server and a stable 期望/实际 report. playwright-core is the
// only dependency and it never downloads a browser (a cached chromium or
// PLAYWRIGHT_CHROMIUM_EXECUTABLE is used).

import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  CheckError,
  blockExternalFonts,
  installGameGlobals,
  installNuiMock,
  launchChromium,
  requestLog,
  startStaticServer,
  createWorld,
} from './harness.mjs';
import { scenarios as mdtScenarios } from './mdt.spec.mjs';
import { questScenarios } from './quests.spec.mjs';
import { notifyScenarios } from './notify.spec.mjs';
import { emergencyScenarios } from './emergency.spec.mjs';
import { surfaceScenarios } from './surface.spec.mjs';

const scenarios = [...surfaceScenarios, ...mdtScenarios, ...questScenarios, ...notifyScenarios, ...emergencyScenarios];

const HTML_DIR = path.resolve(fileURLToPath(new URL('../../../html', import.meta.url)));

function renderFailure(name, error, extra) {
  console.error(`\n✖ ${name}`);
  if (error instanceof CheckError) {
    console.error(`  ${error.message}`);
    for (const [key, value] of Object.entries(error.details)) {
      const lines = String(value).split('\n');
      console.error(`  ${key}: ${lines[0]}`);
      for (const line of lines.slice(1)) console.error(`        ${line}`);
    }
  } else {
    console.error(`  ${error?.stack ?? error}`);
  }
  if (extra.pageErrors.length > 0) {
    console.error('  页面未捕获异常:');
    for (const message of extra.pageErrors.slice(-5)) console.error(`    ${message}`);
  }
  if (extra.consoleErrors.length > 0) {
    console.error('  浏览器 console.error（最后 5 条）:');
    for (const message of extra.consoleErrors.slice(-5)) console.error(`    ${message}`);
  }
  console.error(`  请求记录: ${extra.requests}`);
  console.error('  提示: 运行 npm run build 后重跑；需要可交互调试时把场景里的 headless 改成 false。');
}

async function main() {
  if (!existsSync(path.join(HTML_DIR, 'index.html'))) {
    throw new Error(`找不到 ${path.join(HTML_DIR, 'index.html')}，请先执行 npm run build。`);
  }

  const { browser, executablePath } = await launchChromium();
  const server = await startStaticServer(HTML_DIR);
  console.log('T-City P1 MDT NUI E2E');
  console.log(`  chromium: ${executablePath}`);
  console.log(`  bundle:   ${HTML_DIR}`);
  console.log(`  page:     ${server.url}\n`);

  let passed = 0;
  let failed = 0;
  let skipped = 0;

  try {
    for (const scenario of scenarios) {
      if (scenario.skip) {
        skipped += 1;
        console.log(`↷ SKIP ${scenario.name}\n  ${scenario.skip}\n`);
        continue;
      }

      const context = await browser.newContext({
        locale: 'zh-CN',
        viewport: { width: 1280, height: 900 },
      });
      const page = await context.newPage();
      const world = createWorld();
      const pageErrors = [];
      const consoleErrors = [];
      page.on('pageerror', (error) => pageErrors.push(String(error)));
      page.on('console', (message) => {
        if (message.type() === 'error') consoleErrors.push(message.text());
      });

      try {
        // Route + init script must be installed before the first navigation.
        await installNuiMock(page, world);
        await installGameGlobals(page);
        await blockExternalFonts(page);
        await page.goto(server.url, { waitUntil: 'load' });
        await scenario.run({ page, world, server });
        passed += 1;
        console.log(`✔ ${scenario.name}`);
      } catch (error) {
        failed += 1;
        renderFailure(scenario.name, error, {
          pageErrors,
          consoleErrors,
          requests: requestLog(world).join(', ') || '(none)',
        });
      } finally {
        await context.close().catch(() => {});
      }
    }
  } finally {
    await browser.close().catch(() => {});
    await server.close().catch(() => {});
  }

  console.log(`\n${passed} passed, ${failed} failed, ${skipped} skipped`);
  if (failed > 0) process.exitCode = 1;
}

main().catch((error) => {
  console.error(`NUI harness crashed: ${error?.stack ?? error}`);
  process.exitCode = 1;
});
