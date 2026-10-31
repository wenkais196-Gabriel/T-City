# AI 调度员 MVP：agent 拿内容 → 解析 → call 卡草稿

> 目标不是"上 LLM 服务"，而是**先把闭环跑通**：真实文本进来，模型判断，草稿进箱，警员采纳。

## 1. 分工（关键）

| 谁 | 做什么 | 为什么 |
|---|---|---|
| `tools/agent/dispatch_mvp.py` | **取内容**（短信表增量）+ **提交草稿**（走 `police_call_draft` 动作） | 这两件事是确定性的，脚本做更稳、可重放 |
| **agent（模型）** | **解析**：原文 → `title / details / code / priority` | 判断类型与优先级是模型该干的事；脚本里写关键词表只会变成"伪 AI" |
| 警员 | 在 MDT 草稿箱里**采纳 / 丢弃** | L2 审批不可绕过；采纳前不响铃、不上板 |

## 2. 用法

```bash
# 1) 取待处理内容（按游标增量，不重复读）
python tools/agent/dispatch_mvp.py fetch --limit 10 > inbox.json

# 2) agent 解析 inbox.json，产出 parsed.json（结构见脚本 docstring）

# 3) 提交草稿（默认只 propose，落在草稿箱等采纳）
python tools/agent/dispatch_mvp.py submit parsed.json

# 自测时才用 --approve（需要 admin token）
python tools/agent/dispatch_mvp.py submit parsed.json --approve --advance-cursor
```

约束：

- **幂等键按来源 id 生成**（`dispatch_mvp/<sms_id>/<code>`）——同一条短信重复提交不会产生第二张卡；
- 令牌只从本地 `server.cfg` 读，**不打印、不落盘**；
- 脚本里没有"关键词 → 调度码"的映射表；认不出的码由服务端白名单兜底（降 `911`）。

## 3. 真机跑通记录（2026-10-31）

喂了三条真实语气的报案短信，agent 解析后提交：

| 短信 | agent 解析 | 结果 |
|---|---|---|
| 「我超市被抢了！两个戴头盔的人…骑车往南跑了」 | `10-31` / P1 / 抢劫 | 草稿 `#71` |
| 「有人在我家门口一直砸门，好像是楼上那个醉汉」 | `911` / P2 / 纠纷 | 草稿 `#72` |
| 「Grove Street 那边有辆车撞了电线杆，司机还坐在里面不动」 | `10-52` / P1 / 车祸 | 草稿 `#73` |

同一批数据还验证了脚本的**判断边界**：收件箱里第一条是系统消息（`City Services` 的测试短信），agent 直接跳过、没有生成卡。

## 4. 还没做

| 项 | 说明 |
|---|---|
| 真正的 LLM 常驻 | 现在是"agent 在场时跑一次"；要常驻就需要一个能调模型的宿主进程（或把 Hub 接上） |
| 图片/语音 | 只有文本；语音转写与图片理解未做 |
| 误判评估 | AC-P6-05 要求 10 条样本 ≥80% 类型准确率，样本量还不够 |
