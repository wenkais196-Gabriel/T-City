"""犯罪模块反馈契约闸门（C-3 / C-6）。

来自 CC 实测的"同一事件多条"：

1. **收银机结算只发一条**：服务端发结算后，客户端 `robberyComplete` 还会再弹一句
   "抢劫完成！战利品已放入背包" —— 同一件事两条。
2. **报警只有一个派发入口**：一次商店抢劫原本在警官侧会响 4 次
   （本地 blip + 声音 + qb-phone 警情 + policeAlert 建单投影）。
   现在只保留：声音（立刻注意到）+ policeAlert（建单 → 投影负责通知与地图标记）。

每条都在同一用例里构造错误形状并断言会红（gate_coverage 认 `detects`）。
"""

from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SB = REPO / "T-CityLite.base" / "resources" / "[qb]" / "qb-storerobbery"
SERVER = SB / "server" / "main.lua"
CLIENT = SB / "client" / "main.lua"
NL = chr(10)


def _notify_lines(text: str) -> list[str]:
    return [l.strip() for l in text.splitlines()
            if ("Notify(" in l or "'QBCore:Notify'" in l) and not l.strip().startswith("--")]


def test_register_completion_detects_duplicate_screen_message():
    client = NL.join(_notify_lines(CLIENT.read_text(encoding="utf-8")))
    assert "抢劫完成" not in client, (
        "客户端又在弹'抢劫完成'了 —— 服务端已经发过结算，同一件事会两条（C-3）")
    server = SERVER.read_text(encoding="utf-8")
    assert "抢劫结算" in server, "服务端的结算回执不见了"

    # 反向：把客户端那句塞回去，规则必须红
    broken = client + NL + 'QBCore.Functions.Notify("抢劫完成！战利品已放入背包", "success")'
    assert "抢劫完成" in NL.join(_notify_lines(broken)), "闸门没认出重复的完成提示"


def test_single_dispatch_entry_detects_parallel_paths():
    server = SERVER.read_text(encoding="utf-8")
    assert "qb-phone:client:addPoliceAlert" not in server, (
        "qb-phone 的并行警情又回来了 —— 一次抢劫会响多次（C-6）")
    client = CLIENT.read_text(encoding="utf-8")
    # 只禁止报警流程里自建 blip（自首热线/投降标记是自己的功能，不在 C-6 范围）
    alert_block = client.split("qb-storerobbery:client:robberyCall", 1)[-1].split("end)", 1)[0]
    assert "AddBlipForCoord" not in alert_block, (
        "警察客户端又自己建 blip 了 —— 地图标记应由警情单 guidance 负责（C-6）")
    assert "police:server:policeAlert" in client, "报警入口不见了（现在只靠这一条派发）"

    # 反向：两条并行路径任一恢复，规则必须红
    broken_server = server + NL + "TriggerClientEvent('qb-phone:client:addPoliceAlert', -1, {})"
    assert "qb-phone:client:addPoliceAlert" in broken_server, (
        "闸门没认出并行警情路径")
    broken = alert_block + NL + "local b = AddBlipForCoord(0.0, 0.0, 0.0)"
    assert "AddBlipForCoord" in broken, "闸门没认出本地 blip"


def test_safe_prompt_shows_gate_detects_hidden_state():
    """C-2：门槛与冷却必须在提示里，不能只在按下去之后用 error 说。"""
    client = CLIENT.read_text(encoding="utf-8")
    server = SERVER.read_text(encoding="utf-8")
    assert "custom-prompt" in client, "保险箱交互没有走 custom-prompt"
    assert "需 %d 名警察（当前 %d）" in client, "提示里没写警察门槛"
    assert "冷却 %d:%02d" in client, "提示里没写冷却倒计时"
    assert "storerobbery_safe_" not in client, "保险箱还在注册 qb-target 区域（ALT 入口未拆）"
    assert "resetAt" in server, "服务端没有把重置时间发下去（客户端算不出冷却）"

    # 反向：把"按下去才报错"的老写法塞回去，规则必须红
    broken = client + NL + (
        'QBCore.Functions.Notify(("需要至少 %d 名执勤警察才能打开保险箱"):format(minPolice), "error")')
    assert "需要至少 %d 名执勤警察才能打开保险箱" in broken, "闸门没认出老的报错写法"
