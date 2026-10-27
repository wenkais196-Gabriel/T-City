"""QA-03 — 任务入口这条链路的接线必须被检查，而且必须能抓到旁路。

链路：custom-quest 导出 → custom-phone 的 quests app → appRegistry 的 Quests 组件。
这条链断任何一环的表现都是"手机里看不到任务"，而真正危险的是**旁路**：手机层直接读库、
或者自己实现一套准入判断——那样 TriggerQuest 的权威就被绕开了。所以这个闸门除了检查
"该有的都在"，还反向确认"不该有的没有"。
"""
from __future__ import annotations

from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
QUEST = BASE / "resources/[custom]/custom-quest"
PHONE = BASE / "resources/[custom]/custom-phone"
WEB = PHONE / "web/src"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_quest_entrypoint_wiring_detects_bypasses_and_missing_links():
    # 1. 服务端导出存在，并且都走 quest_availability（不在 main.lua 里另写一套判断）
    main_lua = read(QUEST / "server/main.lua")
    assert "exports('GetAvailableQuests'" in main_lua, "缺少 GetAvailableQuests 导出"
    assert "exports('GetQuestDetail'" in main_lua, "缺少 GetQuestDetail 导出"
    assert "QuestAvailability.List(source)" in main_lua
    assert "QuestAvailability.Detail(source, questId)" in main_lua

    # 2. 模块确实被加载，且在 main.lua 之前（它依赖 QuestManager / QuestCooldown 已定义）
    manifest = read(QUEST / "fxmanifest.lua")
    assert "server/quest_availability.lua" in manifest, "quest_availability.lua 没进清单"
    assert manifest.index("server/quest_manager.lua") < manifest.index("server/quest_availability.lua")
    assert manifest.index("server/quest_availability.lua") < manifest.index("server/main.lua")

    # 3. 手机 App 注册了 quests，并且加载在 main.lua 之前
    phone_manifest = read(PHONE / "fxmanifest.lua")
    assert "server/apps/quests.lua" in phone_manifest, "quests app 没进清单"
    assert phone_manifest.index("server/apps/quests.lua") < phone_manifest.index("server/main.lua")

    app_src = read(PHONE / "server/apps/quests.lua")
    assert "id = 'quests'" in app_src
    for handler in ("list", "active", "detail"):
        assert f"{handler} = function" in app_src, f"缺少 {handler} 查询"
    for action in ("accept", "abandon"):
        assert f"{action} = function" in app_src, f"缺少 {action} 动作"

    # 4. 反向：手机层不许直连数据库，也不许自己判断准入 —— 一律走 custom-quest 导出
    assert "exports['custom-quest']" in app_src, "接取必须走 custom-quest 导出"
    assert "TriggerQuest" in app_src, "接取必须调用 TriggerQuest"
    for forbidden in ("MySQL", "QuestDB", "QuestManager", "QuestRegistry", "IsQuestActive"):
        assert forbidden not in app_src, (
            f"手机层出现 {forbidden}：旁路了 custom-quest 的权威判定/存储，"
            "准入规则会被复制成两份"
        )

    # 5. NUI：调色板里有 Quests 组件，未注册的 app 仍然回退到 DynamicApp
    registry = read(WEB / "core/appRegistry.ts")
    assert "import Quests from '../apps/Quests.svelte'" in registry, "Quests 组件没导入"
    assert "id: QUESTS_APP_ID" in registry and "component: Quests" in registry
    app_svelte = read(WEB / "App.svelte")
    assert "<DynamicApp appId={$activeApp.slice(4)} />" in app_svelte, (
        "DynamicApp 兜底被移除：没有专属组件的 app 会打不开"
    )

    # 6. 组件本身不许自己判"能不能接"（只看服务端给的 available）
    quests_svelte = read(WEB / "apps/Quests.svelte")
    assert "queryApp('quests', 'list')" in quests_svelte
    assert "appAction('quests', 'accept'" in quests_svelte
    assert "row.available" in quests_svelte, "UI 要按服务端给的 available 决定按钮"

    # 7. 运维视角：/listquests 从控制台调用时 source == 0，没有客户端能收 chat 消息，
    #    必须直接 print；否则运维想确认"模板加载了几个"只会拿到一句 native 报错。
    assert "src == 0" in main_lua and "print(text)" in main_lua, (
        "/listquests 缺少控制台分支：控制台调用会 TriggerClientEvent(0, ...) 并抛 native 错误"
    )

    # 8. 需求清单必须真的渲染出来：玩家要看到"缺哪一条"，
    #    只给一句 reason_text 等于没说（role=gang_member 这种原始标签更是没法看）。
    assert "row.requirements" in quests_svelte, "Quests.svelte 没消费服务端的 requirements"
    assert ".reqs" in quests_svelte and "req.met === false" in quests_svelte, (
        "未满足的需求必须与满足的区分开（否则玩家看不出差在哪）"
    )
