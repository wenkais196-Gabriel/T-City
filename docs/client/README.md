# 客户端与 NUI 资料库

| 文档 | 内容 |
|---|---|
| `FIVEM_CLIENT_RESEARCH.md` | FiveM/QBCore 客户端四层模型、NUI/CEF、QBCore callback 并发、故障矩阵 |
| `CLIENT_AUDIT.md` | 客户端模块审计（phone/police/justice/agent/other）+ 优先修复 Top 10 + 扫描器说明 |
| `skills/fivem-client/SKILL.md` | 客户端开发 skill（规则、流程、验证） |
| `skills/fivem-nui-review/SKILL.md` | NUI/Client review 清单 |

静态契约：`T-CityLite.base/tests/architecture/test_nui_client_contracts.py`（规则
`NUI-CLIENT-01`，债务登记 `tests/architecture/nui_client_allowlist.json`）。

## 关键结论

- NUI 回调不 `cb`、fetch 无超时、焦点未释放 → “点了没反应/永久 loading”。
- qb-core `QBCore.ServerCallbacks[name]` 只存一个槽：同名并发（如 `Promise.all` 打 `phone:server:appQuery`）会覆盖，首个请求永不返回。
- Vite NUI 必须 `base: './'`；资源通过 `https://cfx-nui-<resource>/` 提供。
- 客户端只做表现；服务端权威。
