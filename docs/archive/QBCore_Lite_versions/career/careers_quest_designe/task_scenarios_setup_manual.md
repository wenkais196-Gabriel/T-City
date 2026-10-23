# T-City 职业与组织任务情景建立手册 (Batch 1, Batch 2, Batch 3 & Batch 4)

本手册是 T-City 任务系统在职业角色扮演情景设计上的最高指导性技术与策划文档。我们遵循“四原则”（模块化、高性能、安全、可拓展），以提升玩家角色扮演的沉浸感与成就感为核心，对任务场景进行深度规范。

---

## 🏛️ 1. 节点过渡设计与架构哲学

在设计具体任务前，节点与节点之间的**过渡机制**是保障体验连贯性与数据安全性的关键：

```
 [当前步骤 A] ──(客户端触发意图)──► [安全网关层] ──(服务端权威验证)──► [状态推进到 B]
                                                                        │
 ┌──────────────────────────────────────────────────────────────────────┘
 ▼
 [下一步骤 B 激活] ──► 执行 B 节点的 OnActive 生命周期:
                       - 服务端: 创建同步实体 / 记录时间戳
                       - 客户端: 销毁 A 的 Zone/Blip ──► 绘制 B 的 Zone/Blip/Target 选项
```

1. **零延迟状态同步 (State Transition Sync)**
   * 当步骤 A 成功验证后，服务端在推进状态的同时，必须触发一次性网络事件。客户端在同一帧执行旧资源销毁与新资源初始化。
2. **实体生命周期的“无缝对接” (Seamless Spawning)**
   * 步骤 B 的 OnActive 生成的 Prop 完美继承 A 载具的交付位置，增强物理写实感。

---

## 2. 警务部门 (LSPD) 任务情景配置 (Batch 1)

### 2.1 任务 ID：`police_patrol_incident` (日常巡逻与警情应对)

#### 🛠️ 节点链详细配置 (Payload Spec)
```lua
{
    id = "police_patrol_incident",
    title = "警区巡逻与警情应对",
    category = "police",
    level = 1,
    required_tags = { role = "police" },
    conditions = { min_police = 1, min_license = "driver" },
    steps = {
        -- Step 1: 驱车巡逻区域 (GOTO)
        {
            id = "step_goto_ghetto",
            type = "GOTO",
            data = {
                coords = { x = 120.0, y = -1900.0, z = 30.0 },
                shape = "circle",
                radius = 25.0,
                blip = { sprite = 60, color = 3, route = true },
                label = "驾驶警车前往戴维斯高危街区巡逻"
            }
        },
        -- Step 2: 戒备观察 (WAIT)
        {
            id = "step_patrol_wait",
            type = "WAIT",
            data = {
                coords = { x = 120.0, y = -1900.0, z = 30.0 },
                radius = 30.0,
                duration = 30,
                allowLeave = false,
                leavePenalty = "reset",
                label = "在区域内慢速巡逻并戒备观察"
            }
        },
        -- Step 3: 清剿袭击者 (COMBAT)
        {
            id = "step_neutralize_cartel",
            type = "COMBAT",
            data = {
                coords = { x = 125.0, y = -1895.0, z = 30.0 },
                npcModel = "g_m_y_lost_01",
                count = 3,
                weapon = "WEAPON_PISTOL",
                npcHealth = 150,
                npcAccuracy = 20,
                spawn_server_side = true,
                label = "消灭正在袭击平民的暴徒！"
            }
        },
        -- Step 4: 物证扣押 (INTERACT)
        {
            id = "step_seize_contraband",
            type = "INTERACT",
            data = {
                coords = { x = 125.0, y = -1895.0, z = 30.0 },
                spawn_entity = { type = "prop", model = "prop_drug_package_02", freeze = true },
                duration = 5000,
                label = "正在收集现场掉落违禁品...",
                attach_prop = { model = "prop_police_box", bone = "PH_L_Hand" },
                target = { use_target = true, label = "收集违禁证物箱" }
            }
        },
        -- Step 5: 物证归档与分成 (DELIVER)
        {
            id = "step_deliver_evidence",
            type = "DELIVER",
            data = {
                destCoords = { x = 450.0, y = -980.0, z = 25.0 },
                radius = 5.0,
                items = { { name = "contraband_box", count = 1 } },
                consume = true,
                vehicle = { required = true, use_bound = true, consume_vehicle = false },
                label = "将证物箱送回分局保险库归档"
            }
        }
    }
}
```

---

## 3. 医疗部门 (Pillbox) 任务情景配置 (Batch 1)

### 3.1 任务 ID：`ems_accident_extraction` (创伤急救与生死转运)

#### 🛠️ 节点链详细配置 (Payload Spec)
```lua
{
    id = "ems_accident_extraction",
    title = "车祸现场重伤转运",
    category = "ambulance",
    level = 1,
    required_tags = { role = "ambulance" },
    conditions = { min_police = 0, min_license = "driver" },
    steps = {
        -- Step 1: 驾救护车出警 (GOTO)
        {
            id = "step_goto_crash",
            type = "GOTO",
            data = {
                coords = { x = 290.0, y = -1400.0, z = 29.0 },
                shape = "circle",
                radius = 15.0,
                blip = { sprite = 153, color = 1, route = true },
                label = "拉响警哨赶往车祸现场"
            }
        },
        -- Step 2: 现场急救与装载 (INTERACT)
        {
            id = "step_stabilize_patient",
            type = "INTERACT",
            data = {
                coords = { x = 290.0, y = -1400.0, z = 29.0 },
                spawn_entity = { 
                    type = "ped", 
                    model = "a_m_m_eastsa_01", 
                    heading = 45.0, 
                    animDict = "missheistconceptb", 
                    animName = "death_dying_loop_f"
                },
                duration = 8000,
                label = "正在建立静脉通道并包扎止血...",
                minigame = { type = "skillbar", difficulty = "medium" },
                target = { use_target = true, label = "抢救伤员并抬上担架" }
            }
        },
        -- Step 3: 转运期维生 (WAIT)
        {
            id = "step_ambulance_transport",
            type = "WAIT",
            data = {
                coords = { x = 300.0, y = -1440.0, z = 29.0 },
                radius = 500.0,
                duration = 40,
                allowLeave = false,
                label = "开启救护车将伤员紧急送往 Pillbox 急诊室"
            }
        },
        -- Step 4: 移交急诊 (DELIVER)
        {
            id = "step_er_deliver",
            type = "DELIVER",
            data = {
                destCoords = { x = 350.0, y = -1400.0, z = 30.0 },
                radius = 8.0,
                vehicle = { required = true, use_bound = true, consume_vehicle = false },
                label = "将伤员安全移交给急诊医生"
            }
        }
    }
}
```

---

## 4. 市政厅 (City Hall) 任务情景配置 (Batch 1)

### 4.1 任务 ID：`mayor_budget_allocation` (财政预算审批与政策颁布)

#### 🛠️ 节点链详细配置 (Payload Spec)
```lua
{
    id = "mayor_budget_allocation",
    title = "市政预算审批与政策颁布",
    category = "mayor",
    level = 1,
    required_tags = { role = "mayor", tier = "boss" },
    conditions = { min_police = 0 },
    steps = {
        -- Step 1: 办公室行政桌 (GOTO)
        {
            id = "step_goto_office",
            type = "GOTO",
            data = {
                coords = { x = -540.0, y = -200.0, z = 38.0 },
                shape = "box",
                size = { length = 5.0, width = 5.0, height = 3.0 },
                heading = 0.0,
                label = "前往市长办公室行政桌"
            }
        },
        -- Step 2: 审批预算 (VALIDATOR)
        {
            id = "step_approve_budgets",
            type = "VALIDATOR",
            data = {
                coords = { x = -540.0, y = -200.0, z = 38.0 },
                radius = 3.0,
                duration = 5000,
                label = "正在审核 LSPD 与 Pillbox 提交的载具采购申请...",
                validator_id = "validate_mayor_budget_action",
                validator_data = {
                    action = "approve_department_funds",
                    max_allowed_grant = 50000
                }
            }
        },
        -- Step 3: 颁布经济刺激政策 (INTERACT)
        {
            id = "step_issue_policy_event",
            type = "INTERACT",
            data = {
                coords = { x = -540.0, y = -200.0, z = 38.0 },
                duration = 6000,
                label = "正在录入并签署经济政策刺激法案...",
                minigame = { type = "skillbar", difficulty = "easy" },
                target = { use_target = true, label = "颁布经济刺激法令" }
            }
        }
    }
}
```

---

## 5. 司法法庭 (Courthouse) 任务情景配置 (Batch 1)

### 5.1 任务 ID：`judge_judicial_trial` (司法审判与行为矫正)

#### 🛠️ 节点链详细配置 (Payload Spec)
```lua
{
    id = "judge_judicial_trial",
    title = "司法审判与纠纷裁决",
    category = "judge",
    level = 1,
    required_tags = { role = "judge" },
    conditions = { min_police = 1 },
    steps = {
        -- Step 1: 准备开庭 (GOTO)
        {
            id = "step_enter_court",
            type = "GOTO",
            data = {
                coords = { x = 230.0, y = -400.0, z = 48.0 },
                shape = "box",
                size = { length = 8.0, width = 12.0, height = 4.0 },
                heading = 180.0,
                label = "前往第一法庭法官席准备开庭"
            }
        },
        -- Step 2: 审查起诉卷宗 (INTERACT)
        {
            id = "step_review_dossier",
            type = "INTERACT",
            data = {
                coords = { x = 230.0, y = -400.0, z = 48.0 },
                duration = 8000,
                label = "正在听取原被告陈述并审查证物链...",
                target = { use_target = true, label = "查阅本案起诉卷宗" }
            }
        },
        -- Step 3: 宣判与强制矫正 (VALIDATOR)
        {
            id = "step_pronounce_verdict",
            type = "VALIDATOR",
            data = {
                coords = { x = 230.0, y = -400.0, z = 48.0 },
                radius = 3.0,
                duration = 3000,
                label = "敲击法槌，宣读判决书...",
                validator_id = "validate_judicial_verdict",
                validator_data = {
                    verdict_action = "sentence_reform_service"
                }
            }
        }
    }
}
```

---

## 6. 洛圣都律师事务所 (Law Firm) 任务情景配置 (Batch 1)

### 6.1 任务 ID：`lawyer_defense_mediation` (人权辩护与司法斡旋)

#### 🛠️ 节点链详细配置 (Payload Spec)
```lua
{
    id = "lawyer_defense_mediation",
    title = "嫌犯会见与程序性抗辩",
    category = "lawyer",
    level = 1,
    required_tags = { role = "lawyer" },
    conditions = { min_police = 1 },
    steps = {
        -- Step 1: 探监 (GOTO)
        {
            id = "step_goto_jail_visiting",
            type = "GOTO",
            data = {
                coords = { x = 460.0, y = -1000.0, z = 28.0 },
                shape = "circle",
                radius = 5.0,
                label = "前往 LSPD 探监室会见委托人"
            }
        },
        -- Step 2: 司法面谈 (INTERACT)
        {
            id = "step_interview_client",
            type = "INTERACT",
            data = {
                coords = { x = 460.0, y = -1000.0, z = 28.0 },
                duration = 6000,
                label = "正在听取嫌疑人陈述并签署授权协议...",
                attach_prop = { model = "prop_notepad_01", bone = "PH_L_Hand" },
                target = { use_target = true, label = "与委托人进行司法面谈" }
            }
        },
        -- Step 3: 程序合规审查 (VALIDATOR)
        {
            id = "step_audit_police_procedure",
            type = "VALIDATOR",
            data = {
                coords = { x = 460.0, y = -1000.0, z = 28.0 },
                radius = 4.0,
                duration = 5000,
                label = "正在接入警局局域网调取逮捕过程数据...",
                validator_id = "validate_police_procedure_flaw",
                validator_data = {
                    check_arrest_duration = true
                }
            }
        },
        -- Step 4: 呈递抗辩动议 (DELIVER)
        {
            id = "step_deliver_motion",
            type = "DELIVER",
            data = {
                destCoords = { x = 230.0, y = -400.0, z = 48.0 },
                radius = 4.0,
                items = { { name = "defense_motion_dossier", count = 1 } },
                consume = true,
                label = "前往法院向法官呈递保释与抗辩动议"
            }
        }
    }
}
```

---

## 7. 洛圣都矿业公司 (Mining Co) 任务情景配置 (Batch 2)

### 7.1 任务 ID：`mining_auto_extraction` (规模化机械钻探与产业流转)

#### 📝 设计构想与意图
机械化钻孔。90% 回收换钱，10% 提炼为 `refined_iron` 工业配件供改装厂与制造厂消耗。

#### 🛠️ 节点链详细配置 (Payload Spec)
```lua
{
    id = "mining_auto_extraction",
    title = "规模化矿石钻探与熔炼结算",
    category = "miner",
    level = 1,
    required_tags = { role = "miner" },
    conditions = { min_license = "heavy" },
    steps = {
        -- Step 1: 运送钻机 (GOTO)
        {
            id = "step_goto_drill_spot",
            type = "GOTO",
            data = {
                coords = { x = -590.0, y = 3500.0, z = 30.0 },
                shape = "circle",
                radius = 15.0,
                blip = { sprite = 318, color = 5, route = true },
                label = "驾驶重型货车将工业钻井设备送往 1 号采矿坑"
            }
        },
        -- Step 2: 锚定架设 (INTERACT)
        {
            id = "step_deploy_drill",
            type = "INTERACT",
            data = {
                coords = { x = -590.0, y = 3500.0, z = 30.0 },
                spawn_entity = { type = "prop", model = "prop_tool_jackham", freeze = true },
                duration = 6000,
                label = "正在锚定并架设全自动深井钻机...",
                minigame = { type = "lockpick", pins = 4 },
                target = { use_target = true, label = "激活自动采掘机" }
            }
        },
        -- Step 3: 自动化背景采掘 (WAIT)
        {
            id = "step_wait_extraction",
            type = "WAIT",
            data = {
                coords = { x = -590.0, y = 3500.0, z = 30.0 },
                radius = 40.0,
                duration = 40,
                allowLeave = false,
                leavePenalty = "reset",
                label = "钻机作业中，请在现场看守采矿平台"
            }
        },
        -- Step 4: 运往冶炼厂结算 (DELIVER)
        {
            id = "step_deliver_ore",
            type = "DELIVER",
            data = {
                destCoords = { x = 1080.0, y = -1980.0, z = 30.0 },
                radius = 8.0,
                items = { { name = "raw_iron_ore", count = 10 } },
                consume = true,
                vehicle = { required = true, use_bound = true, consume_vehicle = false },
                label = "将开采的粗铁矿送往冶炼厂熔炼并兑换现金"
            }
        }
    }
}
```

---

## 8. 洛圣都环卫局 (Garbage Co) 任务情景配置 (Batch 2)

### 8.1 任务 ID：`garbage_intelligence_run` (环卫清运与黑市情报收集)

#### 📝 设计构想与意图
环卫作为**“城市隐秘情报的流动暗渠”**。扫街时有 8% 概率搜集到加密U盘或日记本残页。

#### 🛠️ 节点链详细配置 (Payload Spec)
```lua
{
    id = "garbage_intelligence_run",
    title = "社区垃圾清运与情报勘查",
    category = "garbage",
    level = 1,
    required_tags = { role = "garbage" },
    conditions = { min_license = "heavy" },
    steps = {
        -- Step 1: 第一垃圾站 (GOTO)
        {
            id = "step_goto_bin_a",
            type = "GOTO",
            data = {
                coords = { x = -150.0, y = -1000.0, z = 27.0 },
                shape = "box",
                size = { length = 8.0, width = 6.0, height = 3.0 },
                heading = 90.0,
                label = "驾驶垃圾车前往第一垃圾站"
            }
        },
        -- Step 2: 垃圾装载 (INTERACT)
        {
            id = "step_collect_bin_a",
            type = "INTERACT",
            data = {
                coords = { x = -150.0, y = -1000.0, z = 27.0 },
                spawn_entity = { type = "prop", model = "prop_bin_01a", freeze = true },
                duration = 5000,
                label = "正在清理并倾倒垃圾桶...",
                attach_prop = { model = "hei_prop_heist_binbag" },
                minigame = { type = "skillbar", difficulty = "easy" },
                target = { use_target = true, label = "清空垃圾桶并装载" }
            }
        },
        -- Step 3: 回收倾倒 (DELIVER)
        {
            id = "step_deliver_garbage",
            type = "DELIVER",
            data = {
                destCoords = { x = -480.0, y = -1700.0, z = 18.0 },
                radius = 6.0,
                vehicle = { required = true, use_bound = true, consume_vehicle = false },
                label = "将垃圾运回处理厂倒进粉碎机"
            }
        }
    }
}
```

---

## 9. 洛圣都货运物流 (Trucking Co) 任务情景配置 (Batch 2)

### 9.1 任务 ID：`trucker_customs_freight` (重载挂接与过境关税审批)

#### 🛠️ 节点链详细配置 (Payload Spec)
```lua
{
    id = "trucker_customs_freight",
    title = "长途重载钢材过境配送",
    category = "trucker",
    level = 2,
    required_tags = { role = "unemployed" },
    conditions = { min_license = "heavy" },
    steps = {
        -- Step 1: 保证金扣除 (VALIDATOR)
        {
            id = "step_truck_check_in",
            type = "VALIDATOR",
            data = {
                coords = { x = 900.0, y = -3150.0, z = 6.0 },
                radius = 12.0,
                duration = 3000,
                label = "正在验证重型车辆资质并预扣保证金...",
                validator_id = "validate_logistics_vehicle",
                validator_data = {
                    allowed_classes = { 10 },
                    rental_deposit = 1200,
                    rental_fee_percent = 25
                }
            }
        },
        -- Step 2: 物理挂车倒车连接 (INTERACT)
        {
            id = "step_hitch_cargo_trailer",
            type = "INTERACT",
            data = {
                coords = { x = 900.0, y = -3150.0, z = 6.0 },
                radius = 15.0,
                duration = 5000,
                label = "正在与气压刹车管道及线束连接...",
                detach_trailer = false,
                auto_trigger = true,
                target = { use_target = true, label = "开始物理挂接" }
            }
        },
        -- Step 3: 安检站等待 (WAIT)
        {
            id = "step_customs_border_wait",
            type = "WAIT",
            data = {
                coords = { x = 1600.0, y = 100.0, z = 80.0 },
                radius = 10.0,
                duration = 15,
                allowLeave = false,
                leavePenalty = "fail",
                label = "海关安检与关税核验中，请保持车辆停稳..."
            }
        },
        -- Step 4: 安检通过盖章 (VALIDATOR)
        {
            id = "step_customs_stamp",
            type = "VALIDATOR",
            data = {
                coords = { x = 1600.0, y = 100.0, z = 80.0 },
                radius = 5.0,
                duration = 2000,
                label = "海关电子戳印盖章中...",
                validator_id = "validate_delivery_arrival",
                validator_data = {
                    destCoords = { x = 1600.0, y = 100.0, z = 80.0 },
                    use_bound_vehicle = true,
                    require_trailer = true
                }
            }
        },
        -- Step 5: 运抵交付脱离挂车 (DELIVER)
        {
            id = "step_final_dock_delivery",
            type = "DELIVER",
            data = {
                destCoords = { x = 850.0, y = -3200.0, z = 6.0 },
                radius = 8.0,
                vehicle = { required = true, use_bound = true, consume_vehicle = true },
                label = "开回物流站脱钩交付，退还货品保证金"
            }
        }
    }
}
```

---

## 10. 改装技工与清障服务 (LS Customs & Towing) 任务情景配置 (Batch 2)

### 10.1 任务 ID：`mechanic_fleet_overhaul` (公车故障大修与矿料消耗)

#### 📝 设计构想与意图
大修必须拉入工位，**强制扣除背包中从矿工处收购的“精炼铁” (refined_iron)**。

#### 🛠️ 节点链详细配置 (Payload Spec)
```lua
{
    id = "mechanic_fleet_overhaul",
    title = "执勤公用载具总成大修",
    category = "mechanic",
    level = 2,
    required_tags = { role = "mechanic" },
    conditions = { min_license = "driver" },
    steps = {
        -- Step 1: 驶入工位 (GOTO)
        {
            id = "step_drive_to_lift",
            type = "GOTO",
            data = {
                coords = { x = -350.0, y = -130.0, z = 40.0 },
                shape = "box",
                size = { length = 6.0, width = 4.0, height = 3.0 },
                heading = 45.0,
                label = "驾驶受损公车停入 1 号气动举升工位"
            }
        },
        -- Step 2: 电脑诊断 (INTERACT)
        {
            id = "step_diagnose_engine",
            type = "INTERACT",
            data = {
                coords = { x = -350.0, y = -130.0, z = 40.0 },
                duration = 6000,
                label = "正在读取 OBD-II 车载诊断系统总线数据...",
                minigame = { type = "hacking", difficulty = "medium" },
                target = { use_target = true, label = "连接 OBD 故障诊断仪" }
            }
        },
        -- Step 3: 材料扣减与结算 (VALIDATOR)
        {
            id = "step_process_repair_billing",
            type = "VALIDATOR",
            data = {
                coords = { x = -350.0, y = -130.0, z = 40.0 },
                radius = 3.0,
                duration = 3000,
                label = "正在确认账单与备件库耗损状态...",
                validator_id = "validate_mechanic_repair_materials",
                validator_data = {
                    required_materials = { { name = "refined_iron", count = 3 } },
                    base_billing_rate = 1200
                }
            }
        },
        -- Step 4: 大修动画 (WAIT)
        {
            id = "step_execute_overhaul_work",
            type = "WAIT",
            data = {
                coords = { x = -350.0, y = -130.0, z = 40.0 },
                radius = 5.0,
                duration = 10,
                allowLeave = false,
                label = "正在进行引擎活塞换新与冷却系统大修..."
            }
        }
    }
}
```

---

## 11. 洛圣都公共交通与新闻商贸任务配置 (Batch 2)

### 11.1 出租车 (Taxi) 任务配置：`taxi_active_fares` (动态通勤服务)
```lua
{
    id = "taxi_active_fares",
    title = "城市出租运送服务",
    category = "taxi",
    level = 1,
    required_tags = { role = "taxi" },
    conditions = { min_license = "driver" },
    steps = {
        -- Step 1: 上客区 (GOTO)
        {
            id = "step_goto_passenger",
            type = "GOTO",
            data = {
                coords = { x = -200.0, y = -800.0, z = 30.0 },
                shape = "circle",
                radius = 10.0,
                blip = { sprite = 56, color = 5, route = true },
                label = "前往调度中心派单的乘客上客区"
            }
        },
        -- Step 2: 乘客登车 (INTERACT)
        {
            id = "step_passenger_boarding",
            type = "INTERACT",
            data = {
                coords = { x = -200.0, y = -800.0, z = 30.0 },
                spawn_entity = { type = "ped", model = "a_f_y_business_01" },
                duration = 3000,
                in_vehicle = true,
                label = "正在等待乘客上车并系好安全带...",
                target = { use_target = true, label = "核对车费信息" }
            }
        },
        -- Step 3: 送达结算 (DELIVER)
        {
            id = "step_deliver_passenger",
            type = "DELIVER",
            data = {
                destCoords = { x = -1000.0, y = -200.0, z = 32.0 },
                radius = 8.0,
                vehicle = { required = true, use_bound = true, consume_vehicle = false },
                label = "运送乘客至罗克福德大厦"
            }
        }
    }
}
```

### 11.2 新闻社 (Reporter) 任务配置：`reporter_press_event` (突发新闻现场采风)
```lua
{
    id = "reporter_press_event",
    title = "突发事件现场拍摄与采风",
    category = "reporter",
    level = 1,
    required_tags = { role = "reporter" },
    steps = {
        -- Step 1: 新闻现场 (GOTO)
        {
            id = "step_goto_event_scene",
            type = "GOTO",
            data = {
                coords = { x = -580.0, y = -100.0, z = 35.0 },
                shape = "circle",
                radius = 15.0,
                blip = { sprite = 459, color = 1, route = true },
                label = "迅速驱车前往突发事件中心现场"
            }
        },
        -- Step 2: 架设镜头调试 (INTERACT)
        {
            id = "step_shoot_video",
            type = "INTERACT",
            data = {
                coords = { x = -580.0, y = -100.0, z = 35.0 },
                spawn_entity = { type = "prop", model = "prop_v_cam_01", freeze = true },
                duration = 8000,
                label = "架设摄像机调试镜头并录制中...",
                minigame = { type = "skillbar", difficulty = "medium" },
                target = { use_target = true, label = "开始摄像采风" }
            }
        },
        -- Step 3: 编辑部交单 (DELIVER)
        {
            id = "step_submit_tape",
            type = "DELIVER",
            data = {
                destCoords = { x = -590.0, y = -80.0, z = 40.0 },
                radius = 4.0,
                items = { { name = "raw_press_tape", count = 1 } },
                consume = true,
                label = "将新闻录像带提交至报社编辑部进行头版排版"
            }
        }
    }
}
```

### 11.3 热狗摊贩 (Hotdog) 任务配置：`hotdog_passive_vending` (街头零售与兜底挂机系统)
```lua
{
    id = "hotdog_passive_vending",
    title = "街头热狗制作与经营",
    category = "hotdog",
    level = 1,
    required_tags = { role = "hotdog" },
    steps = {
        -- Step 1: 部署车辆 (GOTO)
        {
            id = "step_setup_cart",
            type = "GOTO",
            data = {
                coords = { x = -300.0, y = -900.0, z = 30.0 },
                shape = "box",
                size = { length = 4.0, width = 4.0, height = 3.0 },
                heading = 90.0,
                label = "将热狗餐车停放到指定商业人流旺区"
            }
        },
        -- Step 2: 主动烹饪与零售 (INTERACT)
        {
            id = "step_active_cooking",
            type = "INTERACT",
            data = {
                coords = { x = -300.0, y = -900.0, z = 30.0 },
                duration = 4000,
                label = "正在煎制香肠并打包热狗...",
                minigame = { type = "skillbar", difficulty = "easy" },
                target = { use_target = true, label = "烤制热狗并售卖" }
            }
        },
        -- Step 3: 兜底挂机自动售卖 (WAIT)
        {
            id = "step_passive_afk_selling",
            type = "WAIT",
            data = {
                coords = { x = -300.0, y = -900.0, z = 30.0 },
                radius = 10.0,
                duration = 1800,
                allowLeave = false,
                leavePenalty = "reset",
                label = "已进入自动挂机托管状态，NPC 正在陆续购买...",
                afk_mode = {
                    payout_modifier = 0.5,
                    auto_exit_minutes = 30,
                    npc_ped_generation = true
                }
            }
        }
    }
}
```

---

## 🏴‍☠️ 12. 地下组织与非法帮派任务配置 (Batch 3)

### 12.1 卡特尔集团 (Cartel)：`cartel_smuggling_flight` (低空运毒与警网通缉联动)

#### 📝 设计构想与意图
飞行避雷达，越界直接服务端通缉 3 星触发警员拦截博弈。

#### 🛠️ 节点链详细配置 (Payload Spec)
```lua
{
    id = "cartel_smuggling_flight",
    title = "卡特尔低空过境毒品空投",
    category = "cartel",
    level = 3,
    required_tags = { role = "cartel", tier = "entry" },
    conditions = { min_police = 1, min_license = "pilot" },
    steps = {
        -- Step 1: 沙漠跑道提机 (GOTO)
        {
            id = "step_goto_airstrip",
            type = "GOTO",
            data = {
                coords = { x = 1700.0, y = 3250.0, z = 35.0 },
                shape = "circle",
                radius = 20.0,
                blip = { sprite = 307, color = 1, route = true },
                label = "前往沙漠私人简易跑道"
            }
        },
        -- Step 2: 危险品装机 (INTERACT)
        {
            id = "step_load_drugs",
            type = "INTERACT",
            data = {
                coords = { x = 1700.0, y = 3250.0, z = 35.0 },
                spawn_entity = { type = "prop", model = "prop_boxpile_06a", freeze = true },
                duration = 8000,
                label = "正在将走走私高纯度可卡因箱搬入货仓...",
                minigame = { type = "skillbar", difficulty = "medium" },
                target = { use_target = true, label = "装载走私货箱" }
            }
        },
        -- Step 3: 低空躲避雷达越境 (WAIT)
        {
            id = "step_radar_evasion",
            type = "WAIT",
            data = {
                coords = { x = 1700.0, y = 3250.0, z = 35.0 },
                radius = 3000.0,
                duration = 45,
                allowLeave = true,
                label = "起飞并保持飞行高度在海平面 150 米以下以避开雷达网",
                flight_radar = {
                    max_height = 150.0,
                    grace_period_sec = 5,
                    trigger_wanted_stars = 3,
                    announce_to_police = true
                }
            }
        },
        -- Step 4: 海湾毒品空投 (DELIVER)
        {
            id = "step_drop_drugs",
            type = "DELIVER",
            data = {
                destCoords = { x = -2000.0, y = -1500.0, z = 0.0 },
                radius = 30.0,
                vehicle = { required = true, use_bound = true, consume_vehicle = false },
                label = "将货运飞机飞往外海空投区，按 E 键抛投走私货箱"
            }
        }
    }
}
```

---

### 12.2 街头帮派 (Street Gangs)：`gang_turf_conquest` (区块宣示与涂鸦占领)

#### 📝 设计构想与意图
帮派领地占领，绑定势力金库收益与购买特权。

#### 🛠️ 节点链详细配置 (Payload Spec)
```lua
{
    id = "gang_turf_conquest",
    title = "领地区块喷漆与主权宣示",
    category = "gang",
    level = 1,
    steps = {
        -- Step 1: 渗透街区 (GOTO)
        {
            id = "step_goto_disputed_turf",
            type = "GOTO",
            data = {
                coords = { x = 100.0, y = -1800.0, z = 28.0 },
                shape = "box",
                size = { length = 15.0, width = 15.0, height = 4.0 },
                heading = 0.0,
                blip = { sprite = 310, color = 1, route = true },
                label = "携带喷漆罐潜入目标争议区块"
            }
        },
        -- Step 2: 街角放哨警惕 (WAIT)
        {
            id = "step_turf_scouting",
            type = "WAIT",
            data = {
                coords = { x = 100.0, y = -1800.0, z = 28.0 },
                radius = 20.0,
                duration = 20,
                allowLeave = false,
                label = "在街角放哨，警惕周围情况...",
                turf_invasion = {
                    turf_id = "rancho_block_a",
                    notify_rival_gang = true,
                    notify_template = "⚠️ 警报: 我们的 Rancho 区块正在被侵入，请速回防！"
                }
            }
        },
        -- Step 3: 清剿敌对混混 (COMBAT)
        {
            id = "step_clear_rivals",
            type = "COMBAT",
            data = {
                coords = { x = 105.0, y = -1795.0, z = 28.0 },
                npcModel = "g_m_y_ballasout_01",
                count = 4,
                weapon = "WEAPON_BAT",
                npcHealth = 150,
                spawn_server_side = true,
                label = "击退街角聚集的敌对帮派分子！"
            }
        },
        -- Step 4: 领地涂鸦占领 (INTERACT)
        {
            id = "step_spray_graffiti",
            type = "INTERACT",
            data = {
                coords = { x = 100.0, y = -1800.0, z = 28.0 },
                spawn_entity = { type = "prop", model = "prop_wall_light_05a", freeze = true },
                duration = 6000,
                label = "正在喷涂己方帮派涂鸦占领标记...",
                minigame = { type = "skillbar", difficulty = "medium" },
                target = { use_target = true, label = "喷涂帮派涂鸦" }
            }
        }
    }
}
```

---

## 🪪 13. 准入资质、执照考核与学院培训系统 (Batch 4)

资质系统作为获取高阶职业的前置门槛，与**警察学院、医学院、法律学院**结合，建立仿照 **GTA SA（圣安地列斯）** 的考训机制，用严格的操作判定与奖励机制塑造资质的“含金量”。

### 13.1 GTA SA 式准入资质与考试中心 (Licensing Schools)

为了提升驾驶、飞行、航海以及专业装备的操作含金量，我们将考试系统划分为四大考训中心，均绑定以下两条核心机制：
1. **勋章等级与薪资浮动机制 (Medal-Based Payout Scaling)**：
   * 考试步骤完成后，根据通关总时长划定**金牌 (Gold)、银牌 (Silver)、铜牌 (Bronze/合格)** 评级。
   * 此评级将作为永久元数据（Metadata）写入玩家的 `custom-certificates` 数据库中。
   * 拥有高评级的玩家在未来接取相关商业任务（如飞行走私、重载货运）时，将获得薪资加成（**金牌 +10% 奖金，银牌 +5%**），从而刺激高水平玩家反复打磨驾驶技巧。
2. **零容忍合规校验 (Strict Compliance Flags)**：
   * 考试车辆如果发生中途撞击（载具血量低于 1000）、超速（限速区）或强闯安检，系统立即执行 `FailQuest` 中断考试，树立资质威信。

#### 13.1.1 驾校 (Driving School) - 课目设计
* **课目一：360度原地漂移旋转 (360 Degree Spin)**
  * **设计意图**：测试车辆低速抱死与手刹配合。
  * **节点链**：`INTERACT` 开启挑战 $\rightarrow$ `WAIT` (保持在直径 10 米的圆圈内，在 5 秒内通过手刹和油门使车辆 Heading 旋转大于 360 度，由 Validator 提取 Vehicle 状态进行方向积分校验)。
* **课目二：避障与精准急停 (Whip and Terminate)**
  * **设计意图**：高速避障与短距离制动。
  * **节点链**：`GOTO` (限时 12 秒内以高于 80km/h 速度驶过锥桶 S 弯) $\rightarrow$ `DELIVER` (在终点 Box Zone 内完美刹停，车身倾角不得偏差大于 5 度，车体完整度必须为 100%)。
* **课目三：90度侧方漂移入库 (90-Degree Parallel Parking)**
  * **设计意图**：高速手刹横摆入库。
  * **节点链**：`GOTO` (加速点) $\rightarrow$ `INTERACT` (触发漂移，手刹横摆) $\rightarrow$ `DELIVER` (车身横向停入两个静止道具车辆之间的狭窄车位)。

#### 13.1.2 飞校 (Flying School) - 课目设计
* **课目一：跑道起飞与空中穿圈 (Takeoff & Ring Flight)**
  * **设计意图**：控制飞机的仰角和飞行路线。
  * **节点链**：`WAIT` (跑道起飞加速，3 秒内升空) $\rightarrow$ `GOTO` (依次穿过 3 个位于海拔 150 米、180 米、200 米的空中浮空检查圈，半径 30 米)。
* **课目二：直升机精确降落 (Precision Helicopter Landing)**
  * **设计意图**：重力悬停与垂直降落。
  * **节点链**：`GOTO` (穿过峡谷检查点) $\rightarrow$ `DELIVER` (降落在指定摩天大楼停机坪，落点必须位于中心半径 2 米内，触地速度不得超过 3m/s)。

#### 13.1.3 船校 (Boat School) - 课目设计
* **课目一：水上绕标障碍赛 (Slalom Course)**
  * **设计意图**：水面惯性操控与切弯。
  * **节点链**：`GOTO` 环链 (依次绕过水面生成的 5 个浮标，撞击浮标将增加 5 秒罚时，用 Validator 判定航迹)。
* **课目二：跃浪滑行与定点落水 (Water Jump)**
  * **设计意图**：高速冲坡与姿态控制。
  * **节点链**：`GOTO` (加速冲上跳板) $\rightarrow$ `DELIVER` (在空中飞跃后，安全落入前方 30 米外的水面矩形判定区)。

#### 13.1.4 重型货运学校 (Heavy Logistics School) - 课目设计
* **课目一：气压倒车挂载 (Reverse Trailer Hooking)**
  * **设计意图**：重载卡车的盲区视野与挂接。
  * **节点链**：`GOTO` (驾驶车头驶入挂车前) $\rightarrow$ `INTERACT` (倒车对齐挂钩锁舌，QTE 读条建立气压管连接) $\rightarrow$ `WAIT` (检测气压值充能)。
* **课目二：90度倒车入库 (Reverse Docking)**
  * **设计意图**：双铰接载具的逆向转向控制。
  * **节点链**：`DELIVER` (牵引挂车，以倒车姿态将挂车尾部精准塞入位于物流仓库的 90 度折角装卸货位，撞击侧墙直接挂科)。

---

### 13.2 专业学院培训系统 (Professional Academies)

为了避免野蛮执法、野蛮医疗及非专业司法，所有公职岗位（LSPD、EMS、法院）将实行**学院毕业强校验准入 (Graduation Hard Gate)**。招聘系统将完全锁死未取得毕业证书（即 `custom-certificates` 中未包含对应学院毕业 Tag）的玩家。

#### 13.2.1 警察学院 (LSPD Academy) - 任务链配置
* **课目一：警用车辆战术拦截 (PIT Maneuver - 战术避障与拦截)**
  * **配置结构**：
    ```lua
    {
        id = "lspd_academy_pit",
        title = "警用拦截战术避障与拦截",
        category = "police_academy",
        steps = {
            -- Step 1: 追踪目标车辆 (GOTO)
            {
                id = "pit_pursuit",
                type = "GOTO",
                data = {
                    coords = { x = -2000.0, y = 2800.0, z = 15.0 },
                    shape = "circle",
                    radius = 50.0,
                    label = "咬尾追踪警校教学模拟逃逸车辆"
                }
            },
            -- Step 2: 碰撞拦截判定 (VALIDATOR)
            {
                id = "pit_execute",
                type = "VALIDATOR",
                data = {
                    coords = { x = -2000.0, y = 2800.0, z = 15.0 },
                    radius = 30.0,
                    duration = 3000,
                    label = "撞击目标车辆尾部侧面进行 PIT 旋转拦截...",
                    validator_id = "validate_pit_maneuver",
                    validator_data = {
                        target_npc_model = "blista",
                        require_spin_angle = 90.0, -- 目标车旋转需大于90度
                        max_self_damage = 50       -- 自身警车损耗不能过高
                    }
                }
            }
        }
    }
    ```
* **课目二：靶场速射与人质辨识 (Range Shooting & Hostage Discrimination)**
  * **配置结构**：
    ```lua
    {
        id = "lspd_academy_shooting",
        title = "警队靶场实弹与人质甄别",
        category = "police_academy",
        steps = {
            -- 射击甄别 (COMBAT)
            {
                id = "combat_range",
                type = "COMBAT",
                data = {
                    coords = { x = 820.0, y = -3100.0, z = 5.0 },
                    npcModel = "g_m_m_chigoon_01",
                    count = 5,
                    weapon = "WEAPON_PISTOL",
                    spawn_server_side = true,
                    hostage_config = {
                        hostage_model = "a_f_y_business_01",
                        hostage_count = 2,
                        fail_on_hostage_killed = true -- 误伤人质直接失败
                    },
                    label = "消灭靶场中突现的靶纸歹徒，切勿射击无辜市民人质"
                }
            }
        }
    }
    ```
* **课目三：逮捕、搜查与米兰达宣告规范 (Arrest & Miranda Protocol)**
  * **配置结构**：
    ```lua
    {
        id = "lspd_academy_arrest",
        title = "警队标准拘留与搜身执法",
        category = "police_academy",
        steps = {
            -- 强制搜身 (INTERACT)
            {
                id = "arrest_cuffing",
                type = "INTERACT",
                data = {
                    coords = { x = 830.0, y = -3110.0, z = 5.0 },
                    spawn_entity = { type = "ped", model = "a_m_y_beach_01", heading = 90.0, animDict = "mp_arresting", animName = "idle" },
                    duration = 5000,
                    label = "正在对嫌疑人进行上铐...",
                    minigame = { type = "skillbar", difficulty = "medium" },
                    target = { use_target = true, label = "给嫌疑人戴上手铐" }
                }
            },
            -- 米兰达宣言权利宣读与搜身 (VALIDATOR)
            {
                id = "miranda_audit",
                type = "VALIDATOR",
                data = {
                    coords = { x = 830.0, y = -3110.0, z = 5.0 },
                    radius = 3.0,
                    duration = 4000,
                    label = "正在检查是否正确搜出违禁武器并宣读权利...",
                    validator_id = "validate_arrest_protocol",
                    validator_data = {
                        read_rights_completed = true,
                        item_seized = "weapon_knife"
                    }
                }
            }
        }
    }
    ```

#### 13.2.2 医学院 (Pillbox Medical Academy) - 任务链配置
* **课目一：心肺复苏与应急除颤操作 (CPR & Defibrillation)**
  * **配置结构**：
    ```lua
    {
        id = "ems_academy_cpr",
        title = "医学除颤与心肺复苏模拟",
        category = "ems_academy",
        steps = {
            -- 双重 CPR QTE 交互 (INTERACT)
            {
                id = "cpr_simulation",
                type = "INTERACT",
                data = {
                    coords = { x = 360.0, y = -1410.0, z = 29.0 },
                    spawn_entity = { type = "prop", model = "prop_body_bag_01", freeze = true },
                    duration = 10000,
                    label = "正在进行胸外按压与人工呼吸配合...",
                    minigame = { type = "skillbar", difficulty = "hard", keys = { "w", "a", "s", "d" } },
                    target = { use_target = true, label = "对假人实施CPR" }
                }
            },
            -- 电击除颤时机判定 (VALIDATOR)
            {
                id = "defib_voltage_check",
                type = "VALIDATOR",
                data = {
                    coords = { x = 360.0, y = -1410.0, z = 29.0 },
                    radius = 3.0,
                    duration = 3000,
                    label = "正在调整除颤仪能量并充电起搏...",
                    validator_id = "validate_defibrillate_charge",
                    validator_data = {
                        target_pulse_rate = 75
                    }
                }
            }
        }
    }
    ```
* **课目二：大型灾害急诊检伤分类 (Mass Casualty Triage Sorting)**
  * **配置结构**：
    ```lua
    {
        id = "ems_academy_triage",
        title = "急诊灾前检伤分类与分流",
        category = "ems_academy",
        steps = {
            -- 现场 3 伤员巡视 (GOTO)
            {
                id = "triage_goto_spot",
                type = "GOTO",
                data = {
                    coords = { x = 365.0, y = -1415.0, z = 29.0 },
                    shape = "circle",
                    radius = 8.0,
                    label = "前往临时应急灾情检伤演练区"
                }
            },
            -- 伤员分诊分流 (VALIDATOR)
            {
                id = "triage_sorting",
                type = "VALIDATOR",
                data = {
                    coords = { x = 365.0, y = -1415.0, z = 29.0 },
                    radius = 6.0,
                    duration = 6000,
                    label = "正在根据骨折、大出血、昏迷状态进行手带标记...",
                    validator_id = "validate_ems_triage_sort",
                    validator_data = {
                        expected_labels = {
                            ["ped_trauma_01"] = "RED",    -- 动脉出血：红色危急
                            ["ped_trauma_02"] = "YELLOW", -- 闭合骨折：黄色中度
                            ["ped_trauma_03"] = "GREEN"   -- 轻微擦伤：绿色轻微
                        }
                    }
                }
            }
        }
    }
    ```

#### 13.2.3 法律学院 (Law School / Courthouse Academy) - 任务链配置
* **课目一：司法物证链完整性审计 (Evidence Chain Audit)**
  * **配置结构**：
    ```lua
    {
        id = "law_academy_audit",
        title = "法学物证链合规审计",
        category = "law_academy",
        steps = {
            -- 审查案卷 (INTERACT)
            {
                id = "audit_dossier",
                type = "INTERACT",
                data = {
                    coords = { x = 240.0, y = -410.0, z = 48.0 },
                    duration = 8000,
                    label = "正在核对扣押笔录、逮捕时间及口供录音...",
                    target = { use_target = true, label = "审查模拟案卷物证" }
                }
            },
            -- 排除非法证据 (VALIDATOR)
            {
                id = "audit_verdict_exclude",
                type = "VALIDATOR",
                data = {
                    coords = { x = 240.0, y = -410.0, z = 48.0 },
                    radius = 2.0,
                    duration = 4000,
                    label = "正在剔除无搜查令扣押的物证...",
                    validator_id = "validate_law_exclusionary_rule",
                    validator_data = {
                        exclude_illegal_evidence = true,
                        required_correct_exclusions = 2
                    }
                }
            }
        }
    }
    ```
* **课目二：法庭对抗与程序辩护模拟 (Mock Court Advocacy)**
  * **配置结构**：
    ```lua
    {
        id = "law_academy_court_mock",
        title = "法制仲裁与辩护陈述模拟",
        category = "law_academy",
        steps = {
            -- 法庭就位 (GOTO)
            {
                id = "goto_defense_bench",
                type = "GOTO",
                data = {
                    coords = { x = 230.0, y = -400.0, z = 48.0 },
                    shape = "circle",
                    radius = 2.0,
                    label = "站在辩护席上准备陈词"
                }
            },
            -- 提请动议 (DELIVER)
            {
                id = "submit_defense_argument",
                type = "DELIVER",
                data = {
                    destCoords = { x = 235.0, y = -400.0, z = 48.0 },
                    radius = 2.0,
                    items = { { name = "mock_defense_brief", count = 1 } },
                    consume = true,
                    label = "向法庭呈递标准答辩状及动议书"
                }
            }
        }
    }
    ```

---

## 📊 14. 沙盒经济标定与数值平衡设计

为确保任务配置中的数值不会导致通货膨胀或物价崩溃，所有任务金钱产出必须基于 [economy_baseline.json](file:///e:/T-City/T-CityLite.base/economy_baseline.json) 与 [simulation_report.json](file:///e:/T-City/simulation_report.json) 进行标定。

### 14.1 任务奖金权威推导算法
任何新任务的 `rewards.money` 必须通过以下数学公式推导：

$$\text{QuestPayout} = \text{TargetHourlyIncome(Tier)} \times \text{TimeWeight} \times \text{RiskMultiplier} \times \text{global.multiplier}$$

* **参数对照（定义于 economy_baseline.json）**：
  * **目标时薪 $\text{TargetHourlyIncome}$**：
    * `civilian_grind` (平民体力劳动) = **\$1500/时**
    * `skilled_labor` (持证专业劳动) = **\$2500/时**
    * `high_risk_illegal` (高风险犯罪行为) = **\$5000/时**
  * **时间权重 $\text{TimeWeight}$**：
    * `short` (约5分钟): **0.15** | `medium` (约15分钟): **0.35** | `long` (约30分钟): **0.60**
  * **风险乘数 $\text{RiskMultiplier}$**：
    * `safe`: **1.0** | `low_risk`: **1.3** | `medium_risk`: **1.8** | `high_risk`: **2.5** | `extreme_risk`: **4.0**

### 14.2 系统兜底挂机与商贩代售机制设计 (Anti-Inflation AFK Guard)
根据 **23.9 天 / 100 人模拟沙盒报表** 阻断通胀极化：

1. **非满额低保时薪限制**：
   * 玩家挂机托管（如 `hotdog_passive_vending` 的 Step 3）每小时时薪只拿 50%（\$750/小时），提供新人的基础生计保障，同时避免挂机脚本稀释服务器活跃车辆和活体浓度。
2. **30分钟强制中断锁 (30-Min Exit Gate)**：
   * 步骤执行满 1800 秒（30分钟）后，服务端核心状态机挂起此任务，停止发放金币，并全屏提示。
   * 玩家必须手动完成一次 `INTERACT` 的清洗/补货小游戏（QTE），方可手动重置并进入下一个 30 分钟的挂机阶段，彻底避免无人值守外挂。
