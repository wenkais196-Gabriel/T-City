# archive/

不再随服务器启动、但保留用于追溯/恢复的资源与文档。

| 目录 | 原因 | 替代 |
|---|---|---|
| `qb-phone/` | 旧手机，未 ensure；被 custom-phone 取代 | `[custom]/custom-phone` + `[compat]/qb-phone` 导出 shim |
| `design-notes/`（在 docs/archive） | 旧设计稿，与 docs 实施报告内容不同 | 保留参考，不参与构建 |

恢复方式：把目录移回 `T-CityLite.base/resources/[qb]/` 并在模块 cfg 里 ensure；
注意与 `[compat]/qb-phone` 的导出命名冲突（同名资源不能同时存在）。
