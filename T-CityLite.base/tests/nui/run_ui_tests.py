#!/usr/bin/env python3
"""
run_ui_tests.py — 无头浏览器 NUI 冒烟测试

覆盖:
  - qb-vehicleshop NUI: open 消息 -> 渲染车辆 -> 关闭回调
  - tcity-dashboard NUI: open 消息 -> 渲染中控屏
  - custom-phone NUI: phone:open 消息 -> 渲染手机壳

不覆盖（需要 FiveM 客户端）:
  - 游戏内按键/焦点/3D 交互
  - 真实游戏数据与服务器回调

用法:
    pip install playwright
    playwright install chromium
    python tests/nui/run_ui_tests.py [--headed]
"""

from __future__ import annotations

import argparse
import functools
import http.server
import json
import sys
import threading
from pathlib import Path

from playwright.sync_api import sync_playwright

BASE = Path(__file__).resolve().parents[2]
ARTIFACTS = Path(__file__).resolve().parent / "artifacts"


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class StaticServer:
    def __init__(self, directory: Path):
        handler = functools.partial(QuietHandler, directory=str(directory))
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self) -> str:
        self.thread.start()
        host, port = self.httpd.server_address[:2]
        return f"http://{host}:{port}"

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)


def nui_init_script(resource: str) -> str:
    return f"""
window.__resourceName = {json.dumps(resource)};
window.__nuiCalls = [];
window.GetParentResourceName = () => window.__resourceName;
window.fetch = async (url, opts) => {{
  window.__nuiCalls.push({{
    url: String(url),
    method: (opts && opts.method) || 'GET',
    body: (opts && opts.body) || null,
  }});
  return {{ ok: true, status: 200, json: async () => ({{}}), text: async () => '' }};
}};
"""


def collect_errors(page) -> list[str]:
    errors: list[str] = []

    def on_console(msg):
        if msg.type != "error":
            return
        text = msg.text
        if "favicon" in text.lower():
            return
        errors.append(f"console: {text}")

    def on_pageerror(err):
        errors.append(f"pageerror: {err}")

    page.on("console", on_console)
    page.on("pageerror", on_pageerror)
    return errors


def test_vehicleshop(browser, artifacts: Path) -> list[str]:
    html_dir = BASE / "resources/[qb]/qb-vehicleshop/html"
    errors: list[str] = []
    with StaticServer(html_dir) as url:
        ctx = browser.new_context(viewport={"width": 1280, "height": 720})
        ctx.add_init_script(nui_init_script("qb-vehicleshop"))
        page = ctx.new_page()
        page_errors = collect_errors(page)
        page.goto(f"{url}/index.html")
        page.evaluate(
            """() => window.postMessage({
                type: 'open',
                shopLabel: 'PDM',
                shopName: 'pdm',
                vehicle: { brand: 'Pfister', name: 'Comet', model: 'comet2', price: 150000 },
                specs: [{ label: 'Speed', value: 90, display: '90' }],
                showFinance: true
            }, '*')"""
        )
        page.wait_for_selector(".dealership-panel", state="visible", timeout=5000)
        text = page.inner_text("#app")
        assert "Pfister" in text, f"vehicle brand missing: {text[:200]}"
        assert "150,000" in text, f"formatted price missing: {text[:200]}"
        page.screenshot(path=str(artifacts / "vehicleshop-open.png"), full_page=True)

        # 展示车切换：update 原地刷新，不重新打开/不丢焦点
        page.evaluate(
            """() => window.postMessage({
                type: 'update',
                shopLabel: 'PDM',
                shopName: 'pdm',
                vehicle: { brand: 'Declasse', name: 'Vigero', model: 'vigero', price: 39500 },
                specs: [{ label: 'Speed', value: 80, display: '80' }],
                showFinance: true
            }, '*')"""
        )
        page.wait_for_function("document.body.innerText.includes('39,500')", timeout=3000)
        assert "Declasse" in page.inner_text("#app"), "update did not change vehicle"

        page.click("button.btn-icon")
        page.wait_for_timeout(200)
        calls = page.evaluate("window.__nuiCalls")
        assert any("closeNui" in c["url"] for c in calls), f"closeNui not called: {calls}"

        # 重新打开 → 点击 Buy Now，验证购买请求携带正确车型
        page.evaluate(
            """() => window.postMessage({
                type: 'open',
                shopLabel: 'PDM',
                shopName: 'pdm',
                vehicle: { brand: 'Pfister', name: 'Comet', model: 'comet2', price: 150000 },
                specs: [{ label: 'Speed', value: 90, display: '90' }],
                showFinance: true
            }, '*')"""
        )
        page.wait_for_selector(".dealership-panel", state="visible", timeout=3000)
        page.click("button.btn-primary")
        page.wait_for_timeout(300)
        calls = page.evaluate("window.__nuiCalls")
        buys = [c for c in calls if "buyVehicle" in c["url"]]
        assert buys, f"buyVehicle not called: {calls}"
        assert "comet2" in (buys[-1]["body"] or ""), f"wrong vehicle payload: {buys[-1]}"
        assert page.is_visible(".dealership-panel"), "NUI should stay open while processing"
        assert "Processing" in page.inner_text("#app"), "processing state missing"

        # 服务端失败：面板保留并显示错误
        page.evaluate("() => window.postMessage({ type: 'result', success: false, message: '余额不足' }, '*')")
        page.wait_for_function("document.body.innerText.includes('余额不足')", timeout=3000)
        assert page.is_visible(".dealership-panel"), "NUI should stay open on failure"

        # 服务端成功：关闭面板
        page.evaluate("() => window.postMessage({ type: 'result', success: true, message: '' }, '*')")
        page.wait_for_timeout(200)
        assert page.is_hidden(".dealership-panel"), "NUI should close on success"

        errors.extend(page_errors)
        ctx.close()
    return errors


def test_dashboard(browser, artifacts: Path) -> list[str]:
    resource_dir = BASE / "resources/[system]/tcity-dashboard"
    errors: list[str] = []
    with StaticServer(resource_dir) as url:
        ctx = browser.new_context(viewport={"width": 1280, "height": 720})
        ctx.add_init_script(nui_init_script("tcity-dashboard"))
        page = ctx.new_page()
        page_errors = collect_errors(page)
        page.goto(f"{url}/nui/dist/index.html")
        # Vue 把中控屏 teleport 到 body，不挂在 #app 下
        page.wait_for_function("document.body.innerText.includes('诊断')", timeout=8000)
        page.add_style_tag(content="body { background: #0a0e18; }")
        page.evaluate(
            """() => window.postMessage({
                type: 'open',
                plate: 'POLICE01',
                model: 'Police Cruiser',
                class: 18,
                template: 'emergency',
                theme: {
                    style: 'tactical',
                    cssVars: {
                        '--tcity-accent': '#2266FF',
                        '--tcity-accent-glow': 'rgba(34,102,255,0.3)',
                        '--tcity-bg-primary': 'rgba(10,14,24,0.70)',
                        '--tcity-text-primary': '#F5F5FA',
                        '--tcity-text-dim': '#667799',
                        '--tcity-danger': '#FF2244',
                        '--tcity-success': '#22DD88',
                        '--tcity-warning': '#FFAA00',
                        '--tcity-border': 'rgba(34,102,255,0.15)',
                        '--tcity-style': 'tactical',
                        '--tcity-font': 'system-ui'
                    }
                },
                features: {},
                seats: 4,
                isConvertible: false,
                vehicleTags: ['police'],
                job: 'police',
                snapshot: {}
            }, '*')"""
        )
        page.wait_for_function("document.body.innerText.includes('POLICE01')", timeout=5000)
        text = page.inner_text("body")
        assert "POLICE01" in text
        page.screenshot(path=str(artifacts / "dashboard-open.png"), full_page=True)
        errors.extend(page_errors)
        ctx.close()
    return errors


def test_phone(browser, artifacts: Path) -> list[str]:
    resource_dir = BASE / "resources/[custom]/custom-phone"
    errors: list[str] = []
    with StaticServer(resource_dir) as url:
        ctx = browser.new_context(viewport={"width": 420, "height": 860})
        ctx.add_init_script(nui_init_script("custom-phone"))
        page = ctx.new_page()
        page_errors = collect_errors(page)
        page.goto(f"{url}/html/index.html")
        # Svelte 在 phone:open 之后才挂载 UI
        page.wait_for_timeout(800)
        page.evaluate("() => window.postMessage({ action: 'phone:open' }, '*')")
        page.wait_for_function("document.body.innerText.includes('Messages')", timeout=5000)
        text = page.inner_text("body")
        assert len(text.strip()) > 20, f"phone UI looks empty: {text!r}"
        page.screenshot(path=str(artifacts / "phone-open.png"), full_page=True)
        errors.extend(page_errors)
        ctx.close()
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--headed", action="store_true")
    args = parser.parse_args()

    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    results: dict[str, dict] = {}

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not args.headed, args=["--no-sandbox"])
        try:
            for name, fn in [
                ("qb-vehicleshop", test_vehicleshop),
                ("tcity-dashboard", test_dashboard),
                ("custom-phone", test_phone),
            ]:
                try:
                    errors = fn(browser, ARTIFACTS)
                    results[name] = {"ok": not errors, "errors": errors}
                except Exception as exc:  # noqa: BLE001 - report each NUI independently
                    results[name] = {"ok": False, "errors": [str(exc)]}
        finally:
            browser.close()

    print("NUI smoke tests")
    print("=" * 60)
    failed = 0
    for name, result in results.items():
        status = "PASS" if result["ok"] else "FAIL"
        print(f"  [{status}] {name}")
        for err in result["errors"]:
            print(f"         {err}")
        failed += 0 if result["ok"] else 1
    print("=" * 60)
    print(f"  {len(results) - failed}/{len(results)} passed | screenshots: {ARTIFACTS}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
