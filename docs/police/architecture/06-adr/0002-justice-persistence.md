# ADR-0002 justice 案件与判决持久化

- 状态：Proposed
- 相关：TD-02、SM-04

## 背景
`activeCases` / `inmates` 只在 custom-justice 内存，重启即丢；判决只 best-effort 回写 `police_reports.justice_verdict`。

## 决定
- 新增 `justice_cases` / `justice_verdicts` 持久表；
- `custom-justice` 是唯一写者；`custom-police` 只读投影；
- 案件号使用稳定序列，不回绕；
- 判决写入与 `police_reports.justice_verdict` 投影最终一致。

## 后果
- 重启可恢复待审案件；
- 需要迁移、fixture 与回放测试；
- 在完成前，`police_reports.justice_verdict` 仍是唯一可查判决。
