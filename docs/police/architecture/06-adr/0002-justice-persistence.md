---
id: police-architecture-06-adr-0002-justice-persistence
type: adr
status: final
system: justice
owner: hermes
updated: 2026-10-24
---

# ADR-0002 justice 案件与判决持久化

- 状态：Proposed
- 相关：TD-02、SM-04

## 背景
`activeCases` / `inmates` 只在 custom-justice 内存，重启即丢；判决只 best-effort 回写 `police_reports.justice_verdict`。

## 决定
- 新增 `justice_cases` / `justice_verdicts` 持久表；
- `custom-justice` 是唯一写者；`custom-police` 只读投影；
- 案件号使用稳定序列，不回绕；
- `justice_case_id` 是 `VARCHAR(32)` 展示号（`CASE-0001`）；与 `police_cases` 的关联用 BIGINT `case_id`（过渡期可加 `justice_case_ref`），不得把字符串写进 `case_id`；
- 服刑计时落 `justice_sentences`（服务端 `ends_at`），由 ADR-0007 定义，不在本 ADR 重复；
- 判决写入与 `police_reports.justice_verdict` 投影最终一致。

## 后果
- 重启可恢复待审案件；
- 需要迁移、fixture 与回放测试；
- 在完成前，`police_reports.justice_verdict` 仍是唯一可查判决。
