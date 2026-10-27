"""Static contract for the phone frontend App SDK (core/appRegistry + core/request)."""
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
PHONE = BASE / "resources" / "[custom]" / "custom-phone"
WEB = PHONE / "web"
SRC = WEB / "src"
CORE = SRC / "core"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def bundle() -> str:
    return "\n".join(
        p.read_text(encoding="utf-8", errors="ignore")
        for p in sorted((PHONE / "html/assets").glob("*.js"))
    )


def test_app_registry_declares_manifest_and_lookup():
    src = read(CORE / "appRegistry.ts")
    assert "export interface PhoneAppManifest" in src
    for field in (
        "id: string",
        "label: string",
        "icon: string",
        "component: Component",
        "audience?: PhoneAppAudience",
        "schemaVersion: number",
    ):
        assert field in src, field
    for fn in (
        "export function registerApp",
        "export function getApp",
        "export function listApps",
    ):
        assert fn in src, fn
    assert "new Map<string, PhoneAppManifest>()" in src
    assert "apps.get(id)" in src
    assert "[...apps.values()]" in src


def test_police_mdt_is_registered_through_the_sdk():
    src = read(CORE / "appRegistry.ts")
    assert "import PoliceMDT from '../apps/PoliceMDT.svelte'" in src
    assert "export const POLICE_MDT_APP_ID = 'police_mdt'" in src
    assert "id: POLICE_MDT_APP_ID" in src
    assert "label: 'MDT'" in src
    assert "component: PoliceMDT" in src
    assert "audience: { jobs: ['police'] }" in src
    assert "schemaVersion: 1" in src


def test_app_svelte_renders_dyn_apps_through_the_registry():
    app = read(SRC / "App.svelte")
    # The MDT no longer has a bespoke import or branch; the registry owns it.
    assert "$activeApp === 'dyn:police_mdt'" not in app
    assert "import PoliceMDT" not in app
    assert "getApp($activeApp.slice(4))" in app
    assert "AppComponent = dynApp.component" in app
    assert "<AppComponent />" in app
    # Unknown dyn ids still fall back to the generic renderer.
    assert "<DynamicApp appId={$activeApp.slice(4)} />" in app
    # 前缀判断现在有两处：渲染分支 + 状态回吐（切到不报状态的 App 时要把 id 报准）。
    # 真正要守住的是"动态 App 只有 registry 一条渲染路径"，下面几条已经钉住了。
    assert app.count("startsWith('dyn:')") >= 1
    assert "loadDynamicApps" in app


def test_app_svelte_keeps_the_existing_hardcoded_apps():
    app = read(SRC / "App.svelte")
    for legacy in (
        "contacts",
        "messages",
        "banking",
        "phonecall",
        "garage",
        "hotlines",
        "notifications",
        "jobboard",
        "faction",
        "cityfeed",
        "settings",
        "leader_mayor",
        "leader_sheriff",
        "leader_gangboss",
    ):
        assert f"$activeApp === '{legacy}'" in app, legacy


def test_request_wrapper_normalises_the_envelope():
    src = read(CORE / "request.ts")
    for token in (
        "export async function phoneRequest",
        "requestAppQuery",
        "requestAppAction",
        "timeoutMs?: number",
        "timeoutMs = 9000",
        "fetchNui<PhoneResponse<T>>",
        "'appQuery'",
        "'appAction'",
        "'timeout'",
        "'query_failed'",
        "'action_failed'",
        "'no_response'",
        "detail",
    ):
        assert token in src, token
    # Success and failure both stay inside the documented envelope.
    assert "success: true, data:" in src
    assert "success: false, error" in src


def test_stores_and_mdt_use_the_shared_request_layer():
    stores = read(SRC / "stores/apps.ts")
    assert "from '../core/request'" in stores
    assert "requestAppQuery" in stores and "requestAppAction" in stores
    assert "fetchNui<any>('appQuery'" not in stores
    assert "fetchNui<any>('appAction'" not in stores

    mdt = read(SRC / "apps/PoliceMDT.svelte")
    assert "from '../core/request'" in mdt
    assert "requestAppQuery as queryApp" in mdt
    assert "requestAppAction as appAction" in mdt
    assert "queryApp(DB" in mdt and "appAction(DB" in mdt


def test_built_bundle_ships_the_app_registry():
    js = bundle()
    for token in ("police_mdt", "schemaVersion", "audience"):
        assert token in js, token
    # The bespoke `dyn:police_mdt` branch is gone from the shipped app.
    assert "dyn:police_mdt" not in js
