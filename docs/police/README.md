# 警察扮演（Police Roleplay）

| 文档 | 内容 |
|---|---|
| `research-external.md` | 外部模组调研（ps-mdt / ps-dispatch / wasabi_mdt / rcore / ESX 对照），功能矩阵与可借鉴/不可借鉴 |
| `audit-current.md` | 本地警察栈现状：44 条能力矩阵，判刑断链、零持久化、身份分裂与客户端信任漏洞 |
| `DESIGN.md` | 一体化设计：角色/循环/MDT/调度/数据模型/接口/审计/分阶段（P0–P4）与验收 |

结论：新增 `custom-police` 作为唯一服务端权威，MDT 作为 `custom-phone` 的 `police_mdt` App；
`qb-policejob` 保留现场动作层；P0 只做「出勤状态 + 911/警情 + 派单/到场/清场 + MDT 查询 + 审计」。
