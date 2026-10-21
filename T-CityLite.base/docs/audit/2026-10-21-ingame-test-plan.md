# 实机玩法回归测试计划（Issue #16）

> **日期**: 2026-10-21
> **服务器**: `T-City Lite [DEV]`，端口 `30120`
> **当前状态**: 服务端已启动（79 资源、0 script error、DB 正常），**等待真实 GTA V/FiveM 客户端连接**

---

## 0. 连接信息

| 项 | 值 |
|:---|:---|
| 服务端 IP（VM 内） | `172.20.101.94` |
| 端口 | `30120`（TCP/UDP） |
| 主机名 | `T-City Lite [DEV]` |
| 最大人数 | 48 |
| 数据库 | 本地 `TCityLite`（MariaDB 11.8） |

如果客户端在宿主机、服务器在 VMware NAT 虚拟机内，需要先把宿主机的 `30120` 转发到 `172.20.101.94:30120`，或把虚拟机网卡改成桥接。

客户端 F8 控制台：

```
connect 172.20.101.94:30120
```

> 也可以用 `connect 127.0.0.1:30120`，前提是端口已转发到宿主机。

---

## 1. 测试前检查（服务端）

```bash
# 1) 服务端在线
curl -s http://127.0.0.1:30120/dynamic.json

# 2) 无脚本错误
grep -aE 'SCRIPT ERROR|Could not start|Failed to load' /tmp/tcity-server.log | tail

# 3) 记录测试角色
mysql -uswk -p TCityLite -e "SELECT citizenid,name FROM players ORDER BY last_updated DESC LIMIT 5;"
```

每条用例记录：`时间 / 角色 citizenid / 预期 / 实际 / 截图或日志`。

---

## 2. 用例清单

### TC-01 连接与角色创建

- [ ] 客户端连接成功，进入角色选择
- [ ] 创建新角色，出生点正常
- [ ] HUD / 小地图 / 聊天正常
- [ ] 服务端 console 无新报错

### TC-02 手机与基础 UI

- [ ] 打开手机（默认按键见 `custom-phone` 配置）
- [ ] 联系人、消息、JobBoard 可打开
- [ ] 银行 App：余额显示正确
- [ ] 关闭/重开手机无 NUI 卡死

### TC-03 任务接取 → 推进 → 完成

- [ ] 手机 JobBoard 接取一个 civilian 任务
- [ ] 步骤节点（GOTO/INTERACT）可正常触发
- [ ] 完成后只发一次奖励（现金/物品）
- [ ] 任务进入冷却，不能立即重接
- [ ] 服务端日志出现 `[quest-manager] 🏁 COMPLETING`，且只出现一次

SQL 复核：

```sql
SELECT quest_id,status,current_step,completion_count
FROM player_quests WHERE citizenid='<CID>' ORDER BY started_at DESC LIMIT 5;
```

### TC-04 剧情决策与持久化

- [ ] 接取 Cartel/Police/Civilian 序章任务
- [ ] 决策弹窗出现，选项可点击
- [ ] 选择后任务继续推进
- [ ] 重登后 `player_choices` 仍有记录
- [ ] 不选择、等待 2 分钟：任务不应永久卡死（服务端超时按默认选项收口）

```sql
SELECT decision_id,chosen_option,arc_id,chapter,chosen_at
FROM player_choices WHERE citizenid='<CID>' ORDER BY chosen_at DESC LIMIT 5;
```

### TC-05 经济与银行

- [ ] 现金/银行余额与 DB 一致
- [ ] 银行转账（在线玩家）成功
- [ ] 手机转账：扣款一次、到账一次
- [ ] 重登后余额不回档

```sql
SELECT citizenid,account_name,account_balance FROM bank_accounts WHERE citizenid='<CID>';
```

### TC-06 载具

- [ ] PDM 购车：扣款一次、车辆入库
- [ ] 车库取车、钥匙可用、锁车/解锁
- [ ] 车载中控屏（默认 `I`）可打开
- [ ] 改装/维修后重登，mods 仍在

```sql
SELECT plate,vehicle,garage,state,mods FROM player_vehicles WHERE citizenid='<CID>';
```

### TC-07 警察 / EMS / 司法

- [ ] 警察 on/off duty、警车、罚单
- [ ] EMS 急救/复活
- [ ] 逮捕 → 入狱 → 刑满释放
- [ ] 非法客户端事件被拒（可选，用测试脚本）

### TC-08 死亡 / 复活 / 断线

- [ ] 死亡后医疗流程正常
- [ ] 断线重连：位置不是 `0,0,0`
- [ ] 重连后任务/背包/余额与断线前一致

### TC-09 安全回归

- [ ] 非警察无法使用警察命令
- [ ] 非车主无法拿钥匙/改车
- [ ] 非摊主无法触发热狗结算
- [ ] 伪造决策/节点事件无法推进任务

---

## 3. 结果记录模板

| 用例 | 结果 | 证据 | 备注 |
|:---|:---|:---|:---|
| TC-01 | ⬜ | | |
| TC-02 | ⬜ | | |
| TC-03 | ⬜ | | |
| TC-04 | ⬜ | | |
| TC-05 | ⬜ | | |
| TC-06 | ⬜ | | |
| TC-07 | ⬜ | | |
| TC-08 | ⬜ | | |
| TC-09 | ⬜ | | |

---

## 4. 当前阻塞

本机是 VMware 虚拟机，**没有 GTA V / FiveM 客户端、没有 Wine**，无法从服务器侧发起真实客户端连接。

需要：

1. 你在宿主机用 FiveM 客户端连接 `172.20.101.94:30120`（或端口转发后的宿主机地址）；
2. 或提供一台可连接该服务器的 Windows 测试机；
3. 或把 `alpine/` + `server.cfg` 迁到你有客户端的机器上。

连接后我可以实时看 `journalctl`/`/tmp/tcity-server.log` 和 DB，按上表逐项记录。
