# AGENTS.md — 测试怎么写

> 目录：`T-CityLite.base/tests/`。原则：**离线、确定性、不需要服务器/DB/网络**。
> 需要 DB 的用例统一 `pytest.mark.skipif`（当前 132 个 skip 就是这样来的）。

## 两个测试族

| 族 | 位置 | 回答的问题 | 跑法 |
|---|---|---|---|
| **单元 / 业务** | `tests/unit/layer3_business/` 等 | 这段代码按契约工作吗 | `pytest tests/unit` |
| **架构 / 契约** | `tests/architecture/` | 整个仓库还守不守规矩 | `pytest tests/architecture` |

架构测试是"fitness function"：它拦的是**架构性错误**（越界依赖、未登记事件、预算超标），
不是格式问题。格式交给 formatter，不要写进闸门。

## 唯一入口（复用现有模式，不要发明新写法）

| 需求 | 做法 | 参考实现 |
|---|---|---|
| 测 Lua 业务逻辑 | 用 `-- [marker] begin/end` 从源码抽块，`lua5.4` 沙箱跑真代码 | `tests/unit/layer3_business/test_phone_client_core.py` |
| 需要 FiveM 原生 | 手写 stub（`GetGameTimer`/`GetConvar`/`TriggerServerEvent`/`print` 捕获） | `test_phone_diag_protocol.py` |
| 静态契约（文本断言） | 读文件 + 正则断言，配**反向校验** | `test_nui_baseline.py` |
| 新增 net event / 表 | 更新对应 JSON 登记表 + 加所有者与到期 | `net_events_allowlist.json` |
| 前端逻辑 | Node 沙箱 harness | `resources/[custom]/custom-phone/web/tests/nui/run.mjs` |

## 禁止

- 断言"存在即正确"：必须**反向校验**——把错误形状喂进去，规则要红。
  （没有反向校验的静态断言，改个变量名就永久通过了。）
- 让测试依赖执行顺序、时间、随机数、真实网络。
- 把 `pytest.mark.skip` 当"以后再修"；要 skip 必须写 `reason` 和到期条件。
- 在测试里复制实现逻辑（复制一遍等于没测）。

## 改动前必读

- 覆盖率要求：函数覆盖率 **98%+**，从底层到业务层；新增分支必须有用例。
- 先红后绿：先写会失败的复现用例，确认失败（记录输出），再改代码。
- allowlist 都是**债务清单**：`expires` 过期会让套件红；修好之后必须同 commit 删条目
  （不删会被判 stale）。
- 断言消息写"为什么"：失败时人要能直接照着修，而不是去读实现。

## 验收命令

```bash
cd T-CityLite.base && /usr/bin/python3 -m pytest tests/unit tests/architecture -q
cd resources/[custom]/custom-phone/web && node tests/nui/run.mjs
```

新增闸门时，至少验证三件事：
1. 当前仓库全绿（不是靠放宽规则绿的）；
2. 注入错误形状会红（反向校验）；
3. 修好之后自动恢复绿，且不需要手工改断言。
