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
| 日志被刷爆 | 每玩家：就绪 3 条/分钟、上报 10 条/分钟，走限流 owner | `RateLimitWindow` |
| 超长消息 | 消息截断 400 字、资源名 64、版本 32（且限制字符集） | `clean(value, max, pattern)` |
| 服务端来源被当成玩家上报 | `src == 0` 直接忽略 | 两个处理器 |

登记在 `tests/architecture/net_events_allowlist.json`（category: `diagnostic`）。
**事件名必须写字面量**：架构闸门按字面量扫描，`RegisterNetEvent(EVENT_NAME, ...)`
会让整条事件对闸门不可见——这条规则由 `test_net_event_registration_uses_a_literal_name` 钉住。

## 边界（这套东西管不到的情况）

- **客户端在 `shared.lua` 加载之前就崩了**：信标发不出去。这种情况只能靠 F8。
- **NUI（浏览器端）里的异常**：不走这条通道，用资源自己的 NUI 错误上报
  （例如 `custom-phone` 的 `phone:server:clientError`）。
- **真实端到端**：需要真玩家连上服务器。服务端一半与客户端一半都有单测
  （`tests/unit/layer1_core/test_client_reports.py`、`test_client_shared.py`），
  但"玩家登录后确实看到 `[client-ready]`"这一条要人连上去验。
