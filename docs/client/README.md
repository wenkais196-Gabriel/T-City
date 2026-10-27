# 客户端与 NUI 资料库

| 文档 | 内容 |
|---|---|
| `FIVEM_CLIENT_RESEARCH.md` | FiveM/QBCore 客户端四层模型、NUI/CEF、QBCore callback 并发、故障矩阵 |
| `CLIENT_AUDIT.md` | 客户端模块审计（phone/police/justice/agent/other）+ 优先修复 Top 10 + 扫描器说明 |
| `plans/2026-10-25-client-baseline.md` | 客户端基线计划：手机查询失败定位、双端诊断协议、基线规则入 CI（含交付门禁） |
| `research/fivem-nui-2026.md` | NUI/CEF 机制调研（ui_page/files、缓存与 restart、回调三态、焦点语义、DevTools/日志、性能与安全）+ 34 条可检查规则 |
| `research/nui-debug-playbook.md` | NUI 请求失败排查手册：5 个 60 秒探针、判定矩阵、9 类原因排序、日志三通道 |
| `research/client-observability-design.md` | 四段往返可观测设计：`phone:server:diag` 事件模型、采样限流、断点判定、脱敏与测试接法 |
| 客户端开发 skill（agent skill，不在本仓库） | 客户端开发规则、流程、验证 |
| NUI/Client review skill（agent skill，不在本仓库） | NUI / Client review 清单 |

静态契约：`T-CityLite.base/tests/architecture/test_nui_client_contracts.py`（规则
`NUI-CLIENT-01`，债务登记 `tests/architecture/nui_client_allowlist.json`）。

## 关键结论

- NUI 回调不 `cb`、fetch 无超时、焦点未释放 → “点了没反应/永久 loading”。
- qb-core `QBCore.ServerCallbacks[name]` 只存一个槽：同名并发（如 `Promise.all` 打 `phone:server:appQuery`）会覆盖，首个请求永不返回。
- Vite NUI 必须 `base: './'`；资源通过 `https://cfx-nui-<resource>/` 提供。
- 客户端只做表现；服务端权威。
