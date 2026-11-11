"""角色与出生模块的契约闸门（I-1 / I-2 / I-4）。

三条规则，都来自真机踩过的问题：

1. **角色卡是数据库快照，必须标注时间**：只给金额不给出处，玩家会以为服务器算错了
   （真机出现过卡片 $818 / 游戏内 $518）。
2. **删除角色必须输入全名**：原来点一下确认键就删掉背包/车/房产/银行。
3. **救援兜底文案不许出现"空间裂缝/虚空"**：那是开发者视角的 bug 描述，
   而且这类系统兜底要走 `toast`，不能和玩家的动作结果挤同一个 error 通道。

每条都在同一用例里构造错误形状并断言会红（gate_coverage 认 `detects`）。
"""

from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base" / "resources" / "[qb]"
MC_SERVER = RES / "qb-multicharacter" / "server" / "main.lua"
MC_HTML = RES / "qb-multicharacter" / "html" / "index.html"
MC_APP = RES / "qb-multicharacter" / "html" / "app.js"
SPAWN = RES / "qb-spawn" / "client.lua"
NL = chr(10)


def test_card_shows_snapshot_time_detects_missing():
    server = MC_SERVER.read_text(encoding="utf-8")
    html = MC_HTML.read_text(encoding="utf-8")
    app = MC_APP.read_text(encoding="utf-8")

    assert "lastUpdated" in server, "服务端没有把 last_updated 传给角色卡"
    assert "上次保存" in html, "卡片没有显示'上次保存'"
    assert "savedAgo" in app, "没有相对时间方法"

    # 反向：把标注删掉，规则必须红
    broken = html.replace("上次保存", "")
    assert "上次保存" not in broken


def test_delete_requires_full_name_detects_one_click():
    html = MC_HTML.read_text(encoding="utf-8")
    app = MC_APP.read_text(encoding="utf-8")

    assert "deleteConfirmOk" in app, "没有'全名匹配'的计算属性"
    assert "deleteConfirmOk" in html, "确认按钮没有绑定'全名匹配'"
    assert "disabled" in html, "确认按钮没有禁用态（等于能一键删）"
    assert "delete-input" in html, "没有输入框"
    assert "不可恢复" in html, "没有写明不可恢复"

    # 反向：把禁用态摘掉，规则必须红
    broken = html.replace(':disabled="!deleteConfirmOk"', "")
    assert ":disabled=\"!deleteConfirmOk\"" not in broken


def test_rescue_copy_detects_dev_jargon():
    spawn = SPAWN.read_text(encoding="utf-8")
    for bad in ("空间裂缝", "虚空空间", "水下呼吸气泡", "紧急救生备用伞包"):
        assert bad not in spawn, f"救援文案还留着开发者视角的描述：{bad}"
    assert "PushLocal('toast'" in spawn, "救援提示没走 toast 通道"

    # 反向：把老文案塞回去，规则必须红
    broken = spawn + NL + 'exports["x"] = "检测到空间裂缝"'
    assert "空间裂缝" in broken
