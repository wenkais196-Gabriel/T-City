# 客户端可观测性：服务端能看见客户端

## 问题

客户端的 `print` 只进**玩家自己的 F8**。服务端日志里永远没有它。于是这些问题在服务端无法回答：

- 我这版客户端脚本到底有没有被加载？（`refresh`/`restart` 之后尤其）
- 跨资源导出是不是缺了？（`No such export` 只在第一次调用时炸，而那可能发生在玩家点按钮时）
- core-framework 那个客户端共享文件的包含是不是生效了？（失效时是静默降级成 no-op）

这三个坑都真实发生过，每次都只能让对方截图 F8。

## 通道

由 `core-framework` 提供，客户端通过加载期包含接入：

```lua
client_scripts {
    '@core-framework/client/shared.lua',   -- 必须排在其它 client 脚本之前
    'client/main.lua',
}
dependencies { 'core-framework' }
```

### 1. 就绪信标（自动）

`shared.lua` 被加载后 1.5 秒发一次，服务端记一行：

```
[client-ready] custom-police v1.7.0 Tester(#7)
```

判断"新代码有没有到客户端"直接看这一行就够了。版本取自资源的 `version` 字段——
改了客户端脚本就顺手改版本号，否则这条日志分辨不出新旧。

### 2. 错误上报（手动）

```lua
CFShared.Report('error', ('LoadAnimDict 失败: %s'):format(dict))
CFShared.Report('warn', 'NUI 未就绪，退回原生提示')
```

服务端记：

```
[client-report] error Tester(#7): LoadAnimDict 失败: mini@repair
```

kind 只接受 `error` / `warn` / `info`（其它值降级成 `info`）。

## 安全约定（为什么它不会变成日志炸弹）

这条通道的输入**完全由客户端控制**，而输出是服务端日志，所以：

| 风险 | 处理 | 位置 |
|---|---|---|
| 客户端伪造多行日志（`\n[ADMIN] ...`） | 去所有控制字符、压空白 | `clean()` |
| 日志被刷爆 | 就绪：**同一资源 1 条/分钟 + 每玩家总量 40 条/分钟**；上报：每玩家 10 条/分钟。都走限流 owner | `RateLimitWindow` |
| 超长消息 | 消息截断 400 字、资源名 64、版本 32（且限制字符集） | `clean(value, max, pattern)` |
| 服务端来源被当成玩家上报 | `src == 0` 直接忽略 | 两个处理器 |

登记在 `tests/architecture/net_events_allowlist.json`（category: `diagnostic`）。
**事件名必须写字面量**：架构闸门按字面量扫描，`RegisterNetEvent(EVENT_NAME, ...)`
会让整条事件对闸门不可见——这条规则由 `test_net_event_registration_uses_a_literal_name` 钉住。

## 覆盖范围（谁真的接上了）

这条通道此前只有 `custom-phone` 与 `custom-police` 接上，其余二十多个自有资源的客户端
错误根本没有上行通道——文档在写，代码没接。现在按资源类别划清：

| 范围 | 状态 |
|---|---|
| 自有客户端资源（`[custom]`、`[system]`，且已 ensure） | 全部接入，包含必须是 client_scripts 第一项 |
| `atom_nodes`、`aaa_silence` | 启动早于 `core-framework`，`@` 包含会在加载期找不到文件 |
| `production-freeze` | 与 `core-framework` 成环（`core-framework` 依赖它加载 `_L` i18n），不能反向包含 |
| `monitor`、`notify-test` | 不在启动链里（手动 `ensure`），没有运行时就不需要信标 |
| `[qb]`、`[cfx-default]`、`[voice]`、`[defaultmaps]` | 上游/默认资源，不迁移 |
| `PolyZone`、`oxmysql`、`menuv`、`bob74_ipl`、`safecracker`、`progressbar`、`interact-sound`、`cartel-gates` | vendored 第三方，不注入自家代码 |

**启动顺序是硬约束**：`@resource/file` 只在对方资源已启动时才解析成功，所以
`core-framework` 必须排在所有接入者之前。它在 `core.cfg` 里排在 `production-freeze`
之后（对方先加载 `_L`）、`hud-position-tool` 之前。这条由接线闸门
（`test_existing_cfg_and_dependency_parsers_agree`）钉住，不要只靠人记。

闸门：`tests/architecture/test_client_observability.py`（CLI-01）。它做四件事——缺包含要点名、
包含不在第一位要点名、豁免双向校验（已接入还登记 / 登记的资源没了都红）、结构性豁免
（上游目录与 vendored 库）也要校验仍存在且没被注入。每条规则都先构造坏形状证明自己能红，
再看真实仓库。名单镜像在 `client_observability.json`。

## 边界（这套东西管不到的情况）

- **客户端在 `shared.lua` 加载之前就崩了**：信标发不出去。这种情况只能靠 F8。
- **NUI（浏览器端）里的异常**：不走这条通道，用资源自己的 NUI 错误上报
  （例如 `custom-phone` 的 `phone:server:clientError`）。
- **真实端到端**：需要真玩家连上服务器。服务端一半与客户端一半都有单测
  （`tests/unit/layer1_core/test_client_reports.py`、`test_client_shared.py`），
  但"玩家登录后确实看到 `[client-ready]`"这一条要人连上去验。
