# GPS 任务消息模式 — 模板文档

任何需要"手机短信 + 地图导航 + 完成后拦截"的任务系统，遵循此模板。

---

## 📡 通信协议

### 任务激活 → 发 GPS 短信

**服务端：**

```lua
-- 1. 存数据库 + 推客户端
RegisterNetEvent('your-system:server:sendTaskSMS', function(message, coords)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local phoneNumber = Player.PlayerData.charinfo.phone

    local msgData = {
        id = math.random(10000, 99999),
        sender_number = '000-0000',
        receiver_number = phoneNumber,
        message = message,
        timestamp = os.time(),
        is_read = false,
        gps = { x = coords.x, y = coords.y, label = coords.label or '目的地' },
        status = 'active',                         -- ← 关键
    }

    local gpsJson = json.encode({ x = coords.x, y = coords.y, label = coords.label })
    MySQL.insert('INSERT INTO phone_messages (sender_number, receiver_number, message, gps, msg_status) VALUES (?, ?, ?, ?, ?)', {
        '000-0000', phoneNumber, message, gpsJson, 'active'
    }, function()
        TriggerClientEvent('phone:client:gpsMessage', src, msgData)
    end)
end)
```

### 任务完成/失败 → 发 done 通知

**服务端（在奖励结算后调用）：**

```lua
-- 2. 任务结束时清除 GPS
if deliveryData.coords and deliveryData.coords.x then
    TriggerClientEvent('phone:client:gpsMessage', src, {
        status = 'done',
        gps = { x = deliveryData.coords.x, y = deliveryData.coords.y, label = deliveryData.locationLabel or '目的地' },
    })
end
```

---

## 🔒 客户端拦截规则

`custom-phone/client/main.lua` 的 `setGpsRoute` 回调已内置：

| 场景 | 结果 |
|------|------|
| 有活跃任务，点**匹配坐标**的 📍 | ✅ 设置导航 |
| 有活跃任务，点**不匹配坐标**的 📍 | ⚠️ "非本次任务地点" |
| 无活跃任务，点任何 📍 | ⚠️ "当前无活跃任务" |
| 同坐标新任务，点旧消息的 📍 | ✅ 匹配成功 |

核心存储：`LocalPlayer.state.activeGpsX/Y`（state bag，跨帧不丢失）

---

## 🧩 对接清单

新建任务系统时，确保以下三步：

- [ ] **激活时**：`TriggerClientEvent('phone:client:gpsMessage', src, { status='active', gps={x,y,label} })`
- [ ] **完成时**：`TriggerClientEvent('phone:client:gpsMessage', src, { status='done', gps={x,y,label} })`
- [ ] **短信内容**：带 emoji + 任务信息，label 与 gps 坐标一致

无需修改 `custom-phone`。拦截规则已统一实现。

---

## 📋 参考实现

`qb-drugs/server/deliveries.lua` — `successDelivery` + `sendDeliverySMS`
