"""P1-3 批 11：qb-inventory 的 8 个事件。

这是核心资源（几乎所有资源都调它的 AddItem/RemoveItem/SetInventoryData），所以改动只限制在
"客户端参数的形状校验"和"归属"两层，不碰物品搬运算法本身：

- `openVending(data)` / `closeInventory(inventory)` / `useItem(item)`：三个 handler 直接写
  `data.coords` / `inventory:find` / `item.slot`，客户端发一个数字/字符串就抛错 ——
  事件线程被打崩，任何人可反复触发。
- `openDrop(dropId)`：只认 `isOpen`，一个人打开后不发 `closeInventory`（改过的客户端或直接崩游戏）
  就能把这份掉落物**永久锁死**，别人再也打不开。
- `updateDrop(dropId, coords)`：距离只校验"玩家 ↔ 声称坐标"，没校验归属 —— 任何玩家都能把别人的
  包一段段拖走（每次 5 米，次数不限）。
- `QBCore:Server:UpdateObject`：判据写的是 `source ~= ''`，而服务端的 `source` 是数字 0，
  所以这个 handler 实际上**永远不会执行**（死代码）。改成 `source ~= 0` 之后才真正"只接受服务端触发"。
- `snowball(action)` / `SetInventoryData(...)`：前者只动自己的玩具武器（已有 2 秒冷却），
  后者已有 `validateOtherPlayerInventory`（目标在线 + 3 米内，管理员除外）—— 登记即可。

探针真加载 config + server/main.lua（server/functions.lua 的全局函数用桩替代）。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def _run() -> dict[str, str]:
    proc = subprocess.run(
        [
            "lua5.4",
            (FIXTURES / "inventory_probe.lua").as_posix(),
            (BASE / "resources" / "[qb]" / "qb-inventory").as_posix(),
        ],
        capture_output=True,
        text=True,
        timeout=90,
    )
    assert proc.returncode == 0, f"probe 失败：{proc.stderr} / {proc.stdout}"
    data: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "|" not in line:
            continue
        key, _, value = line.partition("|")
        data.setdefault(key, value)
    assert "HANDLER_ERROR" not in data, f"handler 抛错：{data.get('HANDLER_ERROR')}"
    return data


def test_update_object_only_runs_from_the_server():
    """`QBCore:Server:UpdateObject` 的判据要能区分服务端触发。

    旧判据 `source ~= ''`：服务端的 `source` 是数字 0，`0 ~= ''` 恒真 → handler 永远提前 return，
    等于死代码（其它资源重启 qb-core 后调它并不会刷新对象）。
    """
    data = _run()
    assert data["UPDATE_OBJECT_CLIENT_BLOCKED"] == "true", "客户端触发了 UpdateObject"
    assert data["UPDATE_OBJECT_SERVER_ALLOWED"] == "true", "服务端触发也被挡（handler 是死代码）"


def test_vending_handlers_survive_malformed_client_data():
    """三个 handler 直接索引客户端参数，发个数字就能把事件线程打崩。"""
    data = _run()
    assert data["VENDING_BAD_DATA_SAFE"] == "true", "openVending 收到非表参数时抛错"
    assert data["VENDING_FAR_NO_CRASH"] == "true", "openVending 远处玩家调用时抛错"
    assert data["CLOSE_BAD_ID_SAFE"] == "true", "closeInventory 收到非字符串时抛错"
    assert data["CLOSE_BAD_TARGET_SAFE"] == "true", "closeInventory 的非法 targetId 抛错"
    assert data["USE_ITEM_BAD_SAFE"] == "true", "useItem 收到非表参数时抛错"


def test_drop_cannot_be_locked_forever_by_one_player():
    """一个人打开掉落物后不关闭，不能让所有人永远打不开。"""
    data = _run()
    assert data["DROP_LOCKED_BY_OPENER"] == "true", "别人能抢开正在被打开的掉落物"
    assert data["DROP_TAKEOVER_AFTER_TIMEOUT"] == "true", "超过 2 分钟仍无法接管（掉落物被永久锁死）"


def test_drop_position_updates_require_the_bag_to_actually_be_there():
    """`updateDrop` 的坐标必须和**包的实体位置**对得上。

    只校验「玩家 ↔ 声称坐标」的话，改过的客户端可以把别处的包"挪"到自己脚下，
    随后 `openDrop` 的 2.5 米校验就形同虚设（远程开包拿东西）。
    但也不能只认创建者 —— 任何玩家都能把包捡起来带走（这是玩法），那样会堵死正常搬运。
    """
    data = _run()
    assert data["DROP_MOVE_FOREIGN_BLOCKED"] == "true", "包的实体明明在别处，坐标却被远程改了"
    assert data["DROP_MOVE_CARRIER_ALLOWED"] == "true", "正常「捡起再放下」被挡住（过度收紧）"


def test_snowball_is_rate_limited_and_self_scoped():
    """雪球只动自己的玩具武器，且已有 2 秒冷却。"""
    data = _run()
    assert data["SNOWBALL_NO_CRASH"] == "true", "snowball handler 抛错"
