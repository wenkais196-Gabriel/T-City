# 交付：<主题>

> 阶段 S。这份清单可以当 PR 描述，也可以只做最后一遍自检。

## 1. 交付物

- [ ] 代码（commit：`<sha>`）
- [ ] 测试（新增/修改：）
- [ ] 文档（`docs/...`；引用路径已存在）
- [ ] `CHANGELOG.md` 条目（Added / Changed / Fixed / Security 对应段）
- [ ] 登记表更新（net event / table owner / wiring / allowlist）
- [ ] 产物重建（前端改动的 `html/` 与 hash）

## 2. 安全检查

```
$ python3 tools/dev/release_check.py
```

- [ ] 无凭据（`server.cfg` / token / license / webhook / 私钥）
- [ ] 无 PII（日志、测试 fixture、文档示例）
- [ ] allowlist 无过期条目
- [ ] 新增的 `diagnostic` 事件都有投影 + 限流 + 预算

## 3. 契约变化（无则写"无"）

| 类型 | 旧 | 新 | 影响方 |
|---|---|---|---|
| 事件 | | | |
| 字段 | | | |
| 错误码 | | | |

## 4. 上线 / 回滚

- 需要重启：
- 需要 refresh（新增脚本文件）：
- 回滚步骤：

## 5. 验收人

- 谁验证的 / 什么时候：
