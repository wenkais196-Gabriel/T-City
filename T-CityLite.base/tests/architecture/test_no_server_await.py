"""P2-1 闸门：服务端脚本里不许再新增 `Citizen.Await`，存量每条都要有主且会到期。

判据见 `server_await_scan.py` 的模块注释。要点：

* 只扫**服务端**文件（客户端里 Await NUI/动画是正常写法）；
* 跑在**脱掉注释**的代码上（`-- 旧实现用 Citizen.Await` 不算命中）；
* 存量 5 条在 `server_await_allowlist.json` 里写明「为什么不是阻塞主线程」+ 到期日；
* 新增一条 = 红；allowlist 里有、代码里已经没有了 = 也红（债要同步还）。
"""

from __future__ import annotations

from datetime import date

import server_await_scan as scan


def test_no_new_server_side_citizen_await():
    hits = scan.scan_repo()
    allowed = set(scan.allowlist())
    unexpected = {path: lines for path, lines in hits.items() if path not in allowed}
    assert not unexpected, (
        "服务端出现新的 Citizen.Await（DB/HTTP 读会挂起处理该事件的协程）："
        f"{unexpected}。改缓存 + 后台预热，或写进 server_await_allowlist.json 说明理由与到期日。"
    )
    # 反向保护：一条存量都扫不到 = 口径写坏了（闸门会永久绿）
    assert len(hits) >= 5, f"只扫到 {len(hits)} 条存量，扫描器可能失效"
    # 本轮修掉的那一个：patron 的读路径不许再出现 Await
    assert "[standalone]/core-framework/services/patron_service.lua" not in hits


def test_allowlist_rejects_stale_and_expired_entries():
    hits = scan.scan_repo()
    today = date.today()
    stale, expired = [], []
    for path, entry in scan.allowlist().items():
        if path not in hits:
            stale.append(path)
        if entry.get("expires") and date.fromisoformat(entry["expires"]) < today:
            expired.append(path)
    assert not stale, f"这些文件已经没有 Await 了，allowlist 条目要同 commit 删掉：{stale}"
    assert not expired, f"这些残留已经过期，要么修、要么续期并说明：{expired}"
    # 每条都要能解释自己
    for path, entry in scan.allowlist().items():
        assert entry.get("reason", "").strip(), f"{path}: 没写理由"
        assert entry.get("owner", "").strip(), f"{path}: 没写 owner"


# ══════════════════════════════════════════════════════════════════
# 反向形状
# ══════════════════════════════════════════════════════════════════

SERVER_WITH_AWAIT = """
local function read(id)
    local p = promise.new()
    exports.oxmysql:prepare('SELECT 1', { id }, function(r) p:resolve(r) end)
    return Citizen.Await(p)
end
"""

COMMENT_ONLY = """
-- 旧实现：local row = Citizen.Await(p)  ← 注释里的不算
local function read(id) return id end
"""

CLIENT_WITH_AWAIT = """
local p = promise.new()
Citizen.Await(p)
"""


def test_reverse_server_await_is_detected():
    # 用显式服务端集合调用（scan_repo 的真实形状）：路径里不一定有 /server/
    rel = "[standalone]/core-framework/services/some_service.lua"
    assert scan.scan_source(rel, SERVER_WITH_AWAIT, {rel})


def test_reverse_comment_is_not_detected():
    rel = "[standalone]/core-framework/server/main.lua"
    assert not scan.scan_source(rel, COMMENT_ONLY, {rel})


def test_reverse_client_await_is_out_of_scope():
    # 客户端文件不在 server_scripts 里 → 集合里没有它 → 不算命中
    assert not scan.scan_source("[qb]/qb-input/client/main.lua", CLIENT_WITH_AWAIT, set())
