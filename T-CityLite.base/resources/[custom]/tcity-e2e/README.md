# tcity-e2e — 服务端端到端测试（无客户端）

用 fake player 在真实 FXServer 上跑通：

1. 创建测试角色（直接写 `players` 表 + `QBCore.Player.CreatePlayer`）
2. 经济：加钱 → 落库
3. 任务：`TriggerQuest`（验证 `required_tags` / `story_arc` 门控）→ 逐步推进
4. 剧情：`OfferDecision` + `MakeChoice` 服务端提交
5. 奖励：只发一次；重复决策/完成不再发奖
6. 清理测试角色与任务/决策/冷却数据

## 使用

```cfg
# server.cfg（仅测试环境）
setr tcity_e2e 1
ensure tcity-e2e
```

重启后看 console：

```
[E2E] PASS | quest.trigger
...
[E2E] DONE | pass=N fail=0 cid=E2E123456
```

跑完把上面两行从 `server.cfg` 移除（或 `setr tcity_e2e 0` 后 `ensure` 不会执行）。

## 注意

- 不加入任何 `configs/modules/*.cfg`，生产不会加载。
- 使用固定 source `9001`，不会与真实玩家冲突（maxclients 48）。
- 测试结束会删除 `players` / `player_quests` / `player_choices` / `quest_cooldowns` 中该 CID 的行。
- 不覆盖客户端渲染/NUI/输入；那些仍需要真实客户端。
