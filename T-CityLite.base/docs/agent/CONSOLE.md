---
id: base-agent-console
type: manual
status: active
system: agent
owner: hermes
updated: 2026-10-25
review_by: 2027-01-30
---

# 驱动服务器控制台（`tcity-cmd`）

> 这份文档原先被手工追加在 `TOOLS.md` 末尾。`TOOLS.md` 是 `tools/agent_tools.py --write`
> 的生成物，CI 用 `--check` 校验"生成器输出 == 提交内容"，手写段落会一直判 drift。
> 内容搬到这里，生成物保持纯生成。

这个 FXServer build **没有 RCON**（30120 只有 HTTP，Source-RCON 的 auth 包会被直接断开），
所以命令只能通过 `screen` 会话注入到控制台 stdin：

```bash
tcity-cmd -w 6 "restart custom-phone"     # 执行并等待 6 秒再读输出
tcity-cmd --page                          # 只看当前控制台页
```

四条必须知道的坑（都实测踩过）：

1. **回显不可信。** 控制台会把同时段写到 stdout 的日志片段混进输入行的显示，于是你会看到
   `vector2version`、`saystatus`、`randomitemsrestart custom-director`。**但真正执行的命令是对的**
   （`version` 照样打出完整输出）。不要拿回显校验，**要看效果**——`Started resource X`、
   期望的那行 `print`、或 `No such export` 是否消失。
2. **输入行不清空。** 退格（`\177`）、Ctrl+U、空回车都清不掉残留字符；唯一有效的是
   先发一个回车把残留当成一条命令丢掉，再发真命令（`tcity-cmd` 内部就是这么做的）。
3. **混淆的代价是真的，而且会复发。** 两次实测：`restart custom-director` 被拼成
   `randomitemsrestart custom-director`；`restart custom-agent-client` 被拼成
   `rateLimiter_arrayUpdate_burstrestart custom-agent-client`。两次都是**资源被停掉、
   命令看起来还像成功了**。所以：

   ```bash
   curl -s localhost:30120/info.json        # 看 resources 数组里到底在不在
   ```

   一旦发现资源莫名不在了，**不要**用控制台逐条抢救（残留会越拼越乱）：直接整机重启
   ——`screen -S tcity -X quit` → `fuser -k 30120/tcp` → 重新拉起，50 秒内回到 84 个资源。
4. **需要确定性时，把验证做成启动即执行、结果落盘的探针**：临时插一个 `CreateThread`，
   用 `SaveResourceFile` 写报告文件，重启资源后直接读文件——完全不依赖控制台回显。
   探针用完立刻从 fxmanifest 摘掉（`refresh` 才会重新解析清单）。

另外：**新增脚本文件必须 `refresh` 才会交付给已连接的客户端**（`restart` 只重读清单里已有的
文件）。症状是"文件在、就是不执行"，或者跨资源导出在首次调用时炸 `No such export`。
