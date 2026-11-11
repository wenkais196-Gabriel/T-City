---
id: ux-admin-commands
type: manual
status: active
system: ux
owner: hermes
updated: 2026-11-11
review_by: 2027-02-28
---

> **本文件由 `tools/dev/scan_commands.py` 生成，不要手改。**
> 改代码后跑一次：`python3 tools/dev/scan_commands.py`；闸门 `test_admin_commands_doc.py` 会比对是否过期。


# 管理员命令清单

共 **339** 条命令。`权限` 列是扫描器从调用里读到的判定；`—` 表示没读到（**新命令默认不该是 `—`**）。

## 危险命令但没有判权：0 条

无。

## 权限分布

| 权限来源 | 命令数 |
|---|---|
| — | 152 |
| QBCore | 106 |
| restricted=true | 40 |
| job/gang 判定 | 38 |
| ACE | 3 |

## 按资源分组

### PolyZone

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `pzadd` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/PolyZone/creation/client/commands.lua:33 |
| `pzcancel` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/PolyZone/creation/client/commands.lua:49 |
| `pzcomboinfo` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/PolyZone/creation/client/commands.lua:53 |
| `pzcreate` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/PolyZone/creation/client/commands.lua:1 |
| `pzfinish` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/PolyZone/creation/client/commands.lua:41 |
| `pzlast` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/PolyZone/creation/client/commands.lua:45 |
| `pzundo` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/PolyZone/creation/client/commands.lua:37 |

### [gameplay]

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `earn` | RegisterCommand | restricted=true | T-CityLite.base/resources/[cfx-default]/[gameplay]/[examples]/money/server.lua:105 |
| `playerData` | RegisterCommand | restricted=true | T-CityLite.base/resources/[cfx-default]/[gameplay]/player-data/server.lua:164 |
| `spend` | RegisterCommand | restricted=true | T-CityLite.base/resources/[cfx-default]/[gameplay]/[examples]/money/server.lua:112 |

### [system]

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `crun` | RegisterCommand | restricted=true | T-CityLite.base/resources/[cfx-default]/[system]/runcode/runcode_sv.lua:13 |
| `run` | RegisterCommand | restricted=true | T-CityLite.base/resources/[cfx-default]/[system]/runcode/runcode_sv.lua:9 |
| `runcode` | RegisterCommand | restricted=true | T-CityLite.base/resources/[cfx-default]/[system]/runcode/runcode_sv.lua:21 |

### cartel-gates

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `gatedebug` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/cartel-gates/client.lua:380 |
| `gateheading` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/cartel-gates/client.lua:203 |
| `gateoffset` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/cartel-gates/client.lua:189 |
| `gatesave` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/cartel-gates/client.lua:213 |
| `placegate` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/cartel-gates/client.lua:152 |
| `testgate` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/cartel-gates/client.lua:248 |
| `testslide` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/cartel-gates/client.lua:306 |
| `tpgates` | RegisterCommand | — | T-CityLite.base/resources/[standalone]/cartel-gates/client.lua:240 |

### custom-admin

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `amenu` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-admin/server/commands.lua:114 |
| `apanel` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-admin/server/commands.lua:542 |
| `checklicense` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-admin/server/commands.lua:459 |
| `clearme` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-admin/server/commands.lua:216 |
| `givelicense` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-admin/server/commands.lua:315 |
| `givemelicense` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-admin/server/commands.lua:250 |
| `menu` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-admin/server/commands.lua:546 |
| `myid` | QBCore.Commands.Add | — | T-CityLite.base/resources/[custom]/custom-admin/server/commands.lua:83 |
| `reinstatelicense` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-admin/server/commands.lua:387 |
| `revokelicense` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-admin/server/commands.lua:351 |
| `revokemelicense` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-admin/server/commands.lua:280 |
| `suspendlicense` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-admin/server/commands.lua:423 |
| `tccops` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-admin/server/commands.lua:153 |

### custom-agent-client

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `adc` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-agent-client/server/main.lua:568 |

### custom-agent-ops

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `agent` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-agent-ops/server/main.lua:1011 |

### custom-career

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `careertest` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-career/server/main.lua:377 |
| `mycareer` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-career/client/main.lua:24 |
| `mycareer` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-career/server/main.lua:418 |

### custom-cartel

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `cartelinfo` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-cartel/server/main.lua:233 |
| `cartellab` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-cartel/server/main.lua:184 |
| `cartelmembers` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-cartel/server/main.lua:206 |
| `cartelstorage` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-cartel/server/main.lua:196 |

### custom-consumables

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `consumables_status` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-consumables/server/main.lua:172 |

### custom-debug

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `camreset` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-debug/client/debug.lua:115 |
| `colortest` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-debug/client/debug.lua:220 |
| `debugscreen` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-debug/client/debug.lua:60 |
| `fullfix` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-debug/client/debug.lua:125 |
| `gamecam` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-debug/client/debug.lua:234 |
| `nuioff` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-debug/client/debug.lua:86 |
| `watchscreen` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-debug/client/debug.lua:180 |

### custom-director

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `agentapprove` | RegisterCommand | ACE: qbcore.god | T-CityLite.base/resources/[custom]/custom-director/server/main.lua:2092 |

### custom-justice

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `arrest` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-justice/server/arrest.lua:150 |
| `cases` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-justice/server/trial.lua:304 |
| `inmates` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-justice/server/prison.lua:335 |
| `plea` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-justice/server/trial.lua:266 |
| `setjusticedept` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-justice/server/main.lua:231 |
| `trial` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-justice/server/trial.lua:238 |

### custom-main

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `clearwanted` | QBCore.Commands.Add | — | T-CityLite.base/resources/[custom]/custom-main/server/dispatch.lua:154 |
| `clearwarrant` | QBCore.Commands.Add | — | T-CityLite.base/resources/[custom]/custom-main/server/dispatch.lua:155 |
| `duty` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-main/server/dispatch.lua:216 |

### custom-market

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `market` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-market/server/main.lua:406 |
| `marketsetprice` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-market/server/main.lua:439 |

### custom-mining

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `mine` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-mining/server/main.lua:183 |

### custom-notify

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `notifydev` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-notify/server/main.lua:130 |
| `notifytest` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-notify/client/main.lua:44 |

### custom-phone

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `focusprobe` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-phone/client/main.lua:1106 |
| `paycitation` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-phone/client/main.lua:1312 |
| `phone` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-phone/client/main.lua:481 |
| `phone` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-phone/client/main.lua:496 |
| `phone_call` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-phone/server/main.lua:1132 |
| `phonefix` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-phone/client/main.lua:514 |
| `phoneui` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-phone/client/main.lua:505 |
| `tablet` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-phone/client/main.lua:498 |

### custom-police

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `10-6` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-police/client/p0.lua:8 |
| `10-7` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-police/client/p0.lua:9 |
| `10-8` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-police/client/p0.lua:7 |
| `911` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-police/client/p0.lua:11 |
| `911p` | QBCore.Commands.Add | — | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:572 |
| `anklet` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:465 |
| `ankletlocation` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:476 |
| `backup` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-police/client/backup.lua:1205 |
| `callsign` | QBCore.Commands.Add | — | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:249 |
| `cam` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:520 |
| `checkid` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:389 |
| `checklicense` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:431 |
| `clearblood` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:357 |
| `clearcasings` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:346 |
| `coroner` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-police/client/coroner.lua:180 |
| `cuff` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:233 |
| `depot` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:496 |
| `escort` | QBCore.Commands.Add | — | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:244 |
| `fine` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:300 |
| `flagplate` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/vehicle.lua:100 |
| `grantlicense` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:27 |
| `impound` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:507 |
| `impoundnear` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-police/server/vehicle.lua:197 |
| `impoundplayer` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-police/server/vehicle.lua:159 |
| `lockdown` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-police/client/lockdown.lua:38 |
| `npc_callout` | RegisterCommand | ACE: police.release | T-CityLite.base/resources/[custom]/custom-police/server/p4_npc.lua:471 |
| `pa` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-police/client/pa.lua:3 |
| `paylawyer` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:552 |
| `paytow` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:531 |
| `plateinfo` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/vehicle.lua:139 |
| `pobject` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:153 |
| `police_backup_dev` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-police/server/p2_system.lua:1828 |
| `police_backup_state` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-police/server/p2_system.lua:1853 |
| `police_case_seed` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-police/server/seed_dev.lua:10 |
| `police_coroner_dev` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-police/server/coroner.lua:143 |
| `police_incident_bench` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-police/server/seed_dev.lua:168 |
| `police_incident_seed` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-police/server/seed_dev.lua:122 |
| `police_incidents_public` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-police/server/seed_dev.lua:103 |
| `police_justice_seed` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-police/server/seed_dev.lua:51 |
| `police_release` | RegisterCommand | ACE: police.release | T-CityLite.base/resources/[custom]/custom-police/server/p2_system.lua:1889 |
| `police_tow_dev` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-police/server/tow.lua:131 |
| `police_verdict_seed` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-police/server/seed_dev.lua:80 |
| `reinstatelicense` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:106 |
| `revokelicense` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:53 |
| `sample` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-police/client/forensics.lua:8 |
| `sc` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:289 |
| `seizecash` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:278 |
| `setdept` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:179 |
| `setdistrict` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:205 |
| `spikestrip` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:144 |
| `suspendlicense` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:80 |
| `takedna` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:368 |
| `takedrivinglicense` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:131 |
| `tow` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-police/client/tow.lua:165 |
| `unflagplate` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/vehicle.lua:119 |
| `unjail` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[custom]/custom-police/server/commands.lua:255 |

### custom-prompt

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `prompttest` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-prompt/client/main.lua:69 |

### custom-quest

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `abandonquest` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-quest/server/main.lua:977 |
| `debugquest` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-quest/server/main.lua:1044 |
| `getpos` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-quest/client/quest_pos_collector.lua:150 |
| `grantheavy` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-quest/server/main.lua:1003 |
| `listquests` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-quest/server/main.lua:1133 |
| `quest` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-quest/client/main.lua:374 |
| `quest_client_test` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-quest/tests/client/quest_client_test.lua:337 |
| `quest_flow_test` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-quest/tests/server/quest_flow_test.lua:323 |
| `quest_reenode` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-quest/server/main.lua:343 |
| `questrestore` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-quest/client/main.lua:319 |
| `queststep` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-quest/server/main.lua:1171 |
| `reloadquests` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-quest/server/quest_registry.lua:411 |
| `revokeheavy` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-quest/server/main.lua:1024 |
| `savepos` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-quest/client/quest_pos_collector.lua:29 |
| `startquest` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-quest/server/main.lua:953 |
| `testplacement` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-quest/client/quest_entity_placement.lua:337 |

### custom-storage

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `gangstorage` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-storage/server/main.lua:168 |
| `jobstorage` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[custom]/custom-storage/server/main.lua:139 |
| `orgstoragelist` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[custom]/custom-storage/server/main.lua:199 |

### custom-taxes

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `proptax` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-taxes/server/property_tax.lua:320 |
| `taxstats` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-taxes/server/transaction_monitor.lua:125 |

### custom-testing

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `stress` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-testing/stress_test.lua:315 |
| `test` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-testing/server_test.lua:25 |
| `vtest` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/custom-testing/suites/vehicle_test.lua:10 |

### custom-vehicles

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `givekeys` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-vehicles/client/main.lua:490 |
| `hotwire` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-vehicles/client/main.lua:540 |
| `lockpick` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-vehicles/client/main.lua:584 |
| `quickcruise` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-vehicles/client/cruise.lua:392 |
| `removekeys` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-vehicles/client/main.lua:526 |
| `shuff` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-vehicles/client/noshuff.lua:34 |
| `togglecruise` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-vehicles/client/cruise.lua:383 |
| `toggleseatbelt` | RegisterCommand | — | T-CityLite.base/resources/[custom]/custom-vehicles/client/seatbelt.lua:79 |

### economy-dashboard

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `assets` | RegisterCommand | restricted=true | T-CityLite.base/resources/[system]/economy-dashboard/server/main.lua:136 |
| `econ` | RegisterCommand | restricted=true | T-CityLite.base/resources/[system]/economy-dashboard/server/main.lua:262 |
| `econreport` | RegisterCommand | restricted=true | T-CityLite.base/resources/[system]/economy-dashboard/server/main.lua:299 |
| `hotrank` | RegisterCommand | restricted=true | T-CityLite.base/resources/[system]/economy-dashboard/server/main.lua:108 |

### hud-position-tool

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `gauges` | RegisterCommand | — | T-CityLite.base/resources/[custom]/hud-position-tool/client.lua:204 |
| `huddebug` | RegisterCommand | — | T-CityLite.base/resources/[custom]/hud-position-tool/client.lua:355 |
| `mapcomp` | RegisterCommand | — | T-CityLite.base/resources/[custom]/hud-position-tool/client.lua:254 |
| `mapdump` | RegisterCommand | — | T-CityLite.base/resources/[custom]/hud-position-tool/client.lua:322 |
| `mapsize` | RegisterCommand | — | T-CityLite.base/resources/[custom]/hud-position-tool/client.lua:144 |
| `ringdiag` | RegisterCommand | — | T-CityLite.base/resources/[custom]/hud-position-tool/client.lua:338 |
| `ringpos` | RegisterCommand | — | T-CityLite.base/resources/[custom]/hud-position-tool/client.lua:176 |
| `wpdist` | RegisterCommand | — | T-CityLite.base/resources/[custom]/hud-position-tool/client.lua:229 |

### monitor

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `atk` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_trollactions.lua:129 |
| `ptfx` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_ptfx.lua:119 |
| `tnew` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/cl_playerlist.lua:195 |
| `tprint` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/cl_playerlist.lua:198 |
| `tx` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_base.lua:56 |
| `txAdmin-reauth` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_base.lua:141 |
| `txAdmin:menu:boostVehicle` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_vehicle.lua:196 |
| `txAdmin:menu:clearArea` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_main_page.lua:83 |
| `txAdmin:menu:deleteVehicle` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_vehicle.lua:160 |
| `txAdmin:menu:fixVehicle` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_vehicle.lua:178 |
| `txAdmin:menu:healMyself` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_main_page.lua:118 |
| `txAdmin:menu:noClipToggle` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_player_mode.lua:244 |
| `txAdmin:menu:openPlayersPage` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_base.lua:58 |
| `txAdmin:menu:spawnVehicle` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_vehicle.lua:139 |
| `txAdmin:menu:togglePlayerIDs` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_player_ids.lua:203 |
| `txAdmin:menu:tpBack` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_main_page.lua:51 |
| `txAdmin:menu:tpToCoords` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_main_page.lua:17 |
| `txAdmin:menu:tpToWaypoint` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_main_page.lua:33 |
| `txaEvent` | RegisterCommand | restricted=true | T-CityLite.base/resources/[system]/monitor/resource/sv_main.lua:475 |
| `txaInitialData` | RegisterCommand | restricted=true | T-CityLite.base/resources/[system]/monitor/resource/sv_initialData.lua:53 |
| `txaPing` | RegisterCommand | restricted=true | T-CityLite.base/resources/[system]/monitor/resource/sv_main.lua:474 |
| `txaReportResources` | RegisterCommand | restricted=true | T-CityLite.base/resources/[system]/monitor/resource/sv_main.lua:476 |
| `txaSetDebugMode` | RegisterCommand | restricted=true | T-CityLite.base/resources/[system]/monitor/resource/sv_main.lua:477 |
| `txadmin` | RegisterCommand | — | T-CityLite.base/resources/[system]/monitor/resource/menu/client/cl_base.lua:55 |

### notify-test

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `notifytest` | RegisterCommand | — | T-CityLite.base/resources/[custom]/notify-test/client/test.lua:10 |
| `notifytest_server` | RegisterCommand | — | T-CityLite.base/resources/[custom]/notify-test/server/test.lua:7 |
| `notifytest_svr` | RegisterCommand | — | T-CityLite.base/resources/[custom]/notify-test/server/test.lua:91 |

### pma-voice

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `-radiotalk` | RegisterCommand | — | T-CityLite.base/resources/[voice]/pma-voice/client/module/radio.lua:245 |
| `cycleproximity` | RegisterCommand | — | T-CityLite.base/resources/[voice]/pma-voice/client/commands.lua:66 |
| `setvoiceintent` | RegisterCommand | — | T-CityLite.base/resources/[voice]/pma-voice/client/commands.lua:3 |
| `vol` | RegisterCommand | — | T-CityLite.base/resources/[voice]/pma-voice/client/commands.lua:22 |

### qb-adminmenu

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `admin` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:382 |
| `admincar` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:368 |
| `announce` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:372 |
| `blips` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:348 |
| `checkwarns` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:446 |
| `coords` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:358 |
| `delwarn` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:462 |
| `givenuifocus` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:419 |
| `heading` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:581 |
| `kickall` | QBCore.Commands.Add | QBCore: god | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:533 |
| `maxmods` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:343 |
| `names` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:353 |
| `noclip` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:363 |
| `report` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:388 |
| `reportr` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:472 |
| `reporttoggle` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:523 |
| `setammo` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:555 |
| `setmodel` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:495 |
| `setspeed` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:514 |
| `staffchat` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:397 |
| `vector2` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:566 |
| `vector3` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:571 |
| `vector4` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:576 |
| `warn` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-adminmenu/server/server.lua:426 |

### qb-ambulancejob

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `911e` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua:616 |
| `aheal` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua:723 |
| `heal` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua:647 |
| `kill` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua:709 |
| `revive` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua:681 |
| `revivep` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua:664 |
| `setemsdept` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua:589 |
| `setpain` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua:695 |
| `status` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua:630 |

### qb-banking

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `givecash` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-banking/server.lua:711 |

### qb-cityhall

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `drivinglicense` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-cityhall/server/main.lua:341 |

### qb-clothing

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `refreshskin` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-clothing/client/main.lua:1584 |

### qb-core

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `addpermission` | QBCore.Commands.Add | QBCore: god | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:136 |
| `car` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:193 |
| `closeserver` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:171 |
| `dv` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:197 |
| `dvall` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:201 |
| `dvo` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:219 |
| `dvp` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:210 |
| `gang` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:268 |
| `givemoney` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:228 |
| `job` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:248 |
| `me` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:320 |
| `ooc` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:287 |
| `openserver` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:158 |
| `removepermission` | QBCore.Commands.Add | QBCore: god | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:146 |
| `setgang` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:273 |
| `setjob` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:253 |
| `setmoney` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:237 |
| `togglepvp` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:129 |
| `tp` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:90 |
| `tpm` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-core/server/commands.lua:125 |

### qb-crypto

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `checkcryptoworth` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-crypto/server/main.lua:184 |
| `crypto` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-crypto/server/main.lua:189 |
| `setcryptoworth` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-crypto/server/main.lua:134 |

### qb-doorlock

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `doordebug` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-doorlock/server/main.lua:351 |
| `newdoor` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-doorlock/server/main.lua:347 |
| `remotetriggerdoor` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-doorlock/client/main.lua:809 |
| `testcartelgate` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-doorlock/client/main.lua:943 |
| `toggledoorlock` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-doorlock/client/main.lua:777 |

### qb-drugs

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `dealergoto` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-drugs/server/deliveries.lua:460 |
| `dealers` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-drugs/server/deliveries.lua:445 |
| `deletedealer` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-drugs/server/deliveries.lua:429 |
| `deliverydebug` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-drugs/client/deliveries.lua:430 |
| `deliveryreset` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-drugs/client/deliveries.lua:440 |
| `newdealer` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-drugs/server/deliveries.lua:390 |
| `selldrugs` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[qb]/qb-drugs/server/cornerselling.lua:113 |

### qb-houserobbery

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `gethroffset` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-houserobbery/client/main.lua:295 |

### qb-houses

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `addgarage` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[qb]/qb-houses/server/main.lua:74 |
| `createhouse` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[qb]/qb-houses/server/main.lua:61 |
| `decorate` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-houses/server/main.lua:56 |
| `getoffset` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-houses/client/main.lua:1571 |
| `ring` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-houses/server/main.lua:85 |

### qb-hud

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `bank` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-hud/server.lua:28 |
| `cash` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-hud/server.lua:21 |
| `dev` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-hud/server.lua:35 |
| `menu` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-hud/client.lua:149 |
| `resethud` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-hud/client.lua:190 |
| `rings` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-hud/client.lua:195 |

### qb-inventory

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `clearinv` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-inventory/server/commands.lua:86 |
| `closeInv` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-inventory/server/commands.lua:97 |
| `giveitem` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-inventory/server/commands.lua:3 |
| `hotbar` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-inventory/server/commands.lua:101 |
| `inventory` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-inventory/server/commands.lua:116 |
| `openInv` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-inventory/client/main.lua:306 |
| `randomitems` | QBCore.Commands.Add | QBCore: god | T-CityLite.base/resources/[qb]/qb-inventory/server/commands.lua:51 |
| `slot_` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-inventory/client/main.lua:317 |
| `toggleHotbar` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-inventory/client/main.lua:312 |

### qb-lapraces

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `cancelrace` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-lapraces/server/main.lua:660 |
| `togglesetup` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-lapraces/server/main.lua:692 |

### qb-mechanicjob

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `fix` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-mechanicjob/server/main.lua:342 |
| `setmechdept` | QBCore.Commands.Add | job/gang 判定 | T-CityLite.base/resources/[qb]/qb-mechanicjob/server/main.lua:315 |

### qb-menu

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `playerfocus` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-menu/client/main.lua:133 |

### qb-multicharacter

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `closeNUI` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-multicharacter/server/main.lua:80 |
| `deletechar` | QBCore.Commands.Add | QBCore: god | T-CityLite.base/resources/[qb]/qb-multicharacter/server/main.lua:278 |
| `logout` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-multicharacter/server/main.lua:74 |

### qb-prison

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `prison` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-prison/client/main.lua:217 |

### qb-scoreboard

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `-scoreboard` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-scoreboard/client.lua:104 |
| `scoreboard` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-scoreboard/client.lua:61 |

### qb-spawn

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `fadein` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-spawn/client.lua:617 |
| `fixscreen` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-spawn/client.lua:623 |

### qb-storerobbery

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `acceptsurrender` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[qb]/qb-storerobbery/server/main.lua:186 |
| `surrenders` | QBCore.Commands.Add | QBCore: user | T-CityLite.base/resources/[qb]/qb-storerobbery/server/main.lua:270 |

### qb-target

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `-playerTarget` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-target/client.lua:1281 |
| `playerTarget` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-target/client.lua:1268 |

### qb-vehicleshop

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `transfervehicle` | QBCore.Commands.Add | — | T-CityLite.base/resources/[qb]/qb-vehicleshop/server/purchases.lua:213 |

### qb-weapons

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `repairweapon` | QBCore.Commands.Add | QBCore: god | T-CityLite.base/resources/[qb]/qb-weapons/server/main.lua:295 |

### qb-weathersync

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `blackout` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-weathersync/server/server.lua:240 |
| `checktime` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-weathersync/client/client.lua:150 |
| `evening` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-weathersync/server/server.lua:258 |
| `freezetime` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-weathersync/server/server.lua:215 |
| `freezeweather` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-weathersync/server/server.lua:224 |
| `freezeworld` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-weathersync/server/server.lua:277 |
| `morning` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-weathersync/server/server.lua:248 |
| `night` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-weathersync/server/server.lua:263 |
| `noon` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-weathersync/server/server.lua:253 |
| `settime` | RegisterCommand | — | T-CityLite.base/resources/[qb]/qb-weathersync/client/client.lua:159 |
| `time` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-weathersync/server/server.lua:268 |
| `unfreezeworld` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-weathersync/server/server.lua:312 |
| `weather` | QBCore.Commands.Add | QBCore: admin | T-CityLite.base/resources/[qb]/qb-weathersync/server/server.lua:232 |

### story-engine

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `decision` | RegisterCommand | — | T-CityLite.base/resources/[custom]/story-engine/client/main.lua:392 |
| `fixui` | RegisterCommand | — | T-CityLite.base/resources/[custom]/story-engine/client/main.lua:431 |
| `nuifocus` | RegisterCommand | — | T-CityLite.base/resources/[custom]/story-engine/client/main.lua:423 |
| `nuitest` | RegisterCommand | — | T-CityLite.base/resources/[custom]/story-engine/client/main.lua:417 |
| `story_choose` | RegisterCommand | — | T-CityLite.base/resources/[custom]/story-engine/client/main.lua:260 |
| `story_nui_ping` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/story-engine/server/main.lua:269 |
| `story_offer_dev` | RegisterCommand | restricted=true | T-CityLite.base/resources/[custom]/story-engine/server/main.lua:278 |

### tcity-atmosphere

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `atmos` | RegisterCommand | — | T-CityLite.base/resources/[system]/tcity-atmosphere/server/atmosphere_service.lua:364 |

### tcity-dashboard

| 命令 | API | 权限 | 位置 |
|---|---|---|---|
| `dashboard` | RegisterCommand | — | T-CityLite.base/resources/[system]/tcity-dashboard/client/main.lua:342 |
