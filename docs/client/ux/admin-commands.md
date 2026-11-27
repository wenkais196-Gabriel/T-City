---
id: ux-admin-commands
type: manual
status: active
system: ux
owner: hermes
updated: 2026-11-26
review_by: 2027-02-28
---

> **本文件由 `tools/dev/scan_commands.py` 生成，不要手改。**
> 改代码后跑一次：`python3 tools/dev/scan_commands.py`；闸门 `test_admin_commands_doc.py` 会比对是否过期。


# 管理员命令清单

共 **357** 条命令。`权限` 列是扫描器从调用里读到的判定；`—` 表示没读到（**新命令默认不该是 `—`**）。

> 本表**只记身份**（命令名 + 所属资源 + API + 权限），不记 `文件:行号`：行号是派生数据，改一行注释就会漂移，而它一漂移闸门就红 —— 一天里为此多跑三次 CI。需要定位时用 `rg` 现场查。

## 危险命令但没有判权：0 条

无。

## 权限分布

| 权限来源 | 命令数 |
|---|---|
| — | 162 |
| QBCore | 106 |
| restricted=true | 44 |
| job/gang 判定 | 35 |
| handler 内判定 | 10 |

## 按资源分组

### PolyZone

| 命令 | API | 权限 |
|---|---|---|
| `pzadd` | RegisterCommand | — |
| `pzcancel` | RegisterCommand | — |
| `pzcomboinfo` | RegisterCommand | — |
| `pzcreate` | RegisterCommand | — |
| `pzfinish` | RegisterCommand | — |
| `pzlast` | RegisterCommand | — |
| `pzundo` | RegisterCommand | — |

### [gameplay]

| 命令 | API | 权限 |
|---|---|---|
| `earn` | RegisterCommand | restricted=true |
| `playerData` | RegisterCommand | restricted=true |
| `spend` | RegisterCommand | restricted=true |

### [system]

| 命令 | API | 权限 |
|---|---|---|
| `crun` | RegisterCommand | restricted=true |
| `run` | RegisterCommand | restricted=true |
| `runcode` | RegisterCommand | restricted=true |

### cartel-gates

| 命令 | API | 权限 |
|---|---|---|
| `gatedebug` | RegisterCommand | — |
| `gateheading` | RegisterCommand | — |
| `gateoffset` | RegisterCommand | — |
| `gatesave` | RegisterCommand | — |
| `placegate` | RegisterCommand | — |
| `testgate` | RegisterCommand | — |
| `testslide` | RegisterCommand | — |
| `tpgates` | RegisterCommand | — |

### custom-admin

| 命令 | API | 权限 |
|---|---|---|
| `amenu` | QBCore.Commands.Add | QBCore: admin |
| `apanel` | QBCore.Commands.Add | QBCore: admin |
| `checklicense` | QBCore.Commands.Add | QBCore: admin |
| `clearme` | QBCore.Commands.Add | QBCore: admin |
| `givelicense` | QBCore.Commands.Add | handler 内判定: canUseLicenseTool |
| `givemelicense` | QBCore.Commands.Add | QBCore: admin |
| `menu` | QBCore.Commands.Add | QBCore: admin |
| `myid` | QBCore.Commands.Add | — |
| `reinstatelicense` | QBCore.Commands.Add | handler 内判定: canUseLicenseTool |
| `revokelicense` | QBCore.Commands.Add | handler 内判定: canUseLicenseTool |
| `revokemelicense` | QBCore.Commands.Add | QBCore: admin |
| `suspendlicense` | QBCore.Commands.Add | handler 内判定: canUseLicenseTool |
| `tccops` | QBCore.Commands.Add | QBCore: admin |

### custom-agent-client

| 命令 | API | 权限 |
|---|---|---|
| `adc` | RegisterCommand | restricted=true |
| `tpme` | RegisterCommand | — |

### custom-agent-ops

| 命令 | API | 权限 |
|---|---|---|
| `agent` | RegisterCommand | — |

### custom-career

| 命令 | API | 权限 |
|---|---|---|
| `careertest` | QBCore.Commands.Add | QBCore: admin |
| `mycareer` | RegisterCommand | — |
| `mycareer` | QBCore.Commands.Add | QBCore: user |

### custom-cartel

| 命令 | API | 权限 |
|---|---|---|
| `cartelinfo` | QBCore.Commands.Add | QBCore: admin |
| `cartellab` | QBCore.Commands.Add | QBCore: user |
| `cartelmembers` | QBCore.Commands.Add | QBCore: user |
| `cartelstorage` | QBCore.Commands.Add | QBCore: user |

### custom-consumables

| 命令 | API | 权限 |
|---|---|---|
| `consumables_status` | RegisterCommand | — |

### custom-debug

| 命令 | API | 权限 |
|---|---|---|
| `camreset` | RegisterCommand | — |
| `colortest` | RegisterCommand | — |
| `debugscreen` | RegisterCommand | — |
| `fullfix` | RegisterCommand | — |
| `gamecam` | RegisterCommand | — |
| `nuioff` | RegisterCommand | — |
| `watchscreen` | RegisterCommand | — |

### custom-director

| 命令 | API | 权限 |
|---|---|---|
| `agentapprove` | RegisterCommand | handler 内判定: IsPlayerAceAllowed |

### custom-industry

| 命令 | API | 权限 |
|---|---|---|
| `industry` | RegisterCommand | — |
| `industry_setphase` | RegisterCommand | restricted=true |
| `industry_settle` | RegisterCommand | restricted=true |
| `orgbuild` | QBCore.Commands.Add | QBCore: user |
| `orgfacility` | QBCore.Commands.Add | handler 内判定: HasPermission |
| `orgfund` | QBCore.Commands.Add | handler 内判定: HasPermission |
| `orgfunddeposit` | QBCore.Commands.Add | QBCore: user |
| `orgfundgrant` | QBCore.Commands.Add | QBCore: user |
| `orgfundwithdraw` | QBCore.Commands.Add | QBCore: user |
| `orghire` | QBCore.Commands.Add | QBCore: user |
| `orgmenu` | RegisterCommand | — |
| `orgproduce` | RegisterCommand | restricted=true |
| `orgsell` | RegisterCommand | restricted=true |

### custom-justice

| 命令 | API | 权限 |
|---|---|---|
| `arrest` | QBCore.Commands.Add | QBCore: user |
| `cases` | QBCore.Commands.Add | QBCore: user |
| `inmates` | QBCore.Commands.Add | QBCore: user |
| `plea` | QBCore.Commands.Add | QBCore: user |
| `setjusticedept` | QBCore.Commands.Add | job/gang 判定 |
| `trial` | QBCore.Commands.Add | QBCore: user |

### custom-main

| 命令 | API | 权限 |
|---|---|---|
| `clearwanted` | QBCore.Commands.Add | — |
| `clearwarrant` | QBCore.Commands.Add | — |
| `duty` | QBCore.Commands.Add | QBCore: user |

### custom-market

| 命令 | API | 权限 |
|---|---|---|
| `market` | QBCore.Commands.Add | QBCore: user |
| `marketsetprice` | QBCore.Commands.Add | QBCore: admin |

### custom-menu

| 命令 | API | 权限 |
|---|---|---|
| `cmenudemo` | RegisterCommand | — |

### custom-mining

| 命令 | API | 权限 |
|---|---|---|
| `mine` | QBCore.Commands.Add | QBCore: user |

### custom-notify

| 命令 | API | 权限 |
|---|---|---|
| `notifydev` | RegisterCommand | — |
| `notifytest` | RegisterCommand | — |

### custom-phone

| 命令 | API | 权限 |
|---|---|---|
| `focusprobe` | RegisterCommand | — |
| `paycitation` | RegisterCommand | — |
| `phone` | RegisterCommand | — |
| `phone` | RegisterCommand | — |
| `phone_call` | RegisterCommand | restricted=true |
| `phonefix` | RegisterCommand | — |
| `phoneui` | RegisterCommand | — |
| `tablet` | RegisterCommand | — |

### custom-police

| 命令 | API | 权限 |
|---|---|---|
| `10-6` | RegisterCommand | — |
| `10-7` | RegisterCommand | — |
| `10-8` | RegisterCommand | — |
| `911` | RegisterCommand | — |
| `911p` | QBCore.Commands.Add | — |
| `anklet` | QBCore.Commands.Add | job/gang 判定 |
| `ankletlocation` | QBCore.Commands.Add | job/gang 判定 |
| `backup` | RegisterCommand | — |
| `callsign` | QBCore.Commands.Add | — |
| `cam` | QBCore.Commands.Add | job/gang 判定 |
| `checkid` | QBCore.Commands.Add | job/gang 判定 |
| `clearblood` | QBCore.Commands.Add | job/gang 判定 |
| `clearcasings` | QBCore.Commands.Add | job/gang 判定 |
| `coroner` | RegisterCommand | — |
| `cuff` | QBCore.Commands.Add | job/gang 判定 |
| `depot` | QBCore.Commands.Add | job/gang 判定 |
| `escort` | QBCore.Commands.Add | — |
| `fine` | QBCore.Commands.Add | job/gang 判定 |
| `flagplate` | QBCore.Commands.Add | job/gang 判定 |
| `grantlicense` | QBCore.Commands.Add | job/gang 判定 |
| `impound` | QBCore.Commands.Add | job/gang 判定 |
| `impoundnear` | QBCore.Commands.Add | QBCore: admin |
| `impoundplayer` | QBCore.Commands.Add | QBCore: admin |
| `lockdown` | RegisterCommand | — |
| `npc_callout` | RegisterCommand | handler 内判定: IsPlayerAceAllowed |
| `pa` | RegisterCommand | — |
| `paylawyer` | QBCore.Commands.Add | job/gang 判定 |
| `paytow` | QBCore.Commands.Add | job/gang 判定 |
| `plateinfo` | QBCore.Commands.Add | job/gang 判定 |
| `pobject` | QBCore.Commands.Add | job/gang 判定 |
| `police_backup_dev` | RegisterCommand | restricted=true |
| `police_backup_state` | RegisterCommand | restricted=true |
| `police_case_seed` | RegisterCommand | restricted=true |
| `police_coroner_dev` | RegisterCommand | restricted=true |
| `police_incident_bench` | RegisterCommand | — |
| `police_incident_seed` | RegisterCommand | — |
| `police_incidents_public` | RegisterCommand | — |
| `police_justice_seed` | RegisterCommand | restricted=true |
| `police_release` | RegisterCommand | handler 内判定: IsPlayerAceAllowed |
| `police_tow_dev` | RegisterCommand | restricted=true |
| `police_verdict_seed` | RegisterCommand | restricted=true |
| `sample` | RegisterCommand | — |
| `sc` | QBCore.Commands.Add | job/gang 判定 |
| `seizecash` | QBCore.Commands.Add | job/gang 判定 |
| `setdept` | QBCore.Commands.Add | job/gang 判定 |
| `setdistrict` | QBCore.Commands.Add | job/gang 判定 |
| `spikestrip` | QBCore.Commands.Add | job/gang 判定 |
| `takedna` | QBCore.Commands.Add | job/gang 判定 |
| `takedrivinglicense` | QBCore.Commands.Add | job/gang 判定 |
| `tow` | RegisterCommand | — |
| `unflagplate` | QBCore.Commands.Add | job/gang 判定 |
| `unjail` | QBCore.Commands.Add | job/gang 判定 |
| `verifylicense` | QBCore.Commands.Add | job/gang 判定 |

### custom-prompt

| 命令 | API | 权限 |
|---|---|---|
| `prompttest` | RegisterCommand | — |

### custom-quest

| 命令 | API | 权限 |
|---|---|---|
| `abandonquest` | RegisterCommand | restricted=true |
| `debugquest` | RegisterCommand | restricted=true |
| `getpos` | RegisterCommand | — |
| `grantheavy` | RegisterCommand | restricted=true |
| `listquests` | RegisterCommand | restricted=true |
| `quest` | RegisterCommand | — |
| `quest_client_test` | RegisterCommand | — |
| `quest_flow_test` | RegisterCommand | restricted=true |
| `quest_hotdog_vendor_accept` | RegisterCommand | — |
| `quest_hotdog_vendor_cook` | RegisterCommand | — |
| `quest_hotdog_vendor_decline` | RegisterCommand | — |
| `quest_hotdog_vendor_interact` | RegisterCommand | — |
| `quest_hotdog_vendor_menu` | RegisterCommand | — |
| `quest_reenode` | RegisterCommand | restricted=true |
| `questrestore` | RegisterCommand | — |
| `queststep` | RegisterCommand | restricted=true |
| `reloadquests` | RegisterCommand | restricted=true |
| `revokeheavy` | RegisterCommand | restricted=true |
| `savepos` | RegisterCommand | — |
| `startquest` | RegisterCommand | restricted=true |
| `testplacement` | RegisterCommand | — |

### custom-storage

| 命令 | API | 权限 |
|---|---|---|
| `gangstorage` | QBCore.Commands.Add | QBCore: user |
| `jobstorage` | QBCore.Commands.Add | QBCore: user |
| `orgstoragelist` | QBCore.Commands.Add | QBCore: admin |

### custom-taxes

| 命令 | API | 权限 |
|---|---|---|
| `proptax` | RegisterCommand | restricted=true |
| `taxstats` | RegisterCommand | restricted=true |

### custom-testing

| 命令 | API | 权限 |
|---|---|---|
| `stress` | RegisterCommand | restricted=true |
| `test` | RegisterCommand | — |
| `vtest` | RegisterCommand | restricted=true |

### custom-vehicles

| 命令 | API | 权限 |
|---|---|---|
| `givekeys` | RegisterCommand | — |
| `hotwire` | RegisterCommand | — |
| `lockpick` | RegisterCommand | — |
| `quickcruise` | RegisterCommand | — |
| `removekeys` | RegisterCommand | — |
| `shuff` | RegisterCommand | — |
| `togglecruise` | RegisterCommand | — |
| `toggleseatbelt` | RegisterCommand | — |

### economy-dashboard

| 命令 | API | 权限 |
|---|---|---|
| `assets` | RegisterCommand | restricted=true |
| `econ` | RegisterCommand | restricted=true |
| `econreport` | RegisterCommand | restricted=true |
| `hotrank` | RegisterCommand | restricted=true |

### hud-position-tool

| 命令 | API | 权限 |
|---|---|---|
| `gauges` | RegisterCommand | — |
| `huddebug` | RegisterCommand | — |
| `mapcomp` | RegisterCommand | — |
| `mapdump` | RegisterCommand | — |
| `mapsize` | RegisterCommand | — |
| `ringdiag` | RegisterCommand | — |
| `ringpos` | RegisterCommand | — |
| `wpdist` | RegisterCommand | — |

### monitor

| 命令 | API | 权限 |
|---|---|---|
| `atk` | RegisterCommand | — |
| `ptfx` | RegisterCommand | — |
| `tnew` | RegisterCommand | — |
| `tprint` | RegisterCommand | — |
| `tx` | RegisterCommand | — |
| `txAdmin-reauth` | RegisterCommand | — |
| `txAdmin:menu:boostVehicle` | RegisterCommand | — |
| `txAdmin:menu:clearArea` | RegisterCommand | — |
| `txAdmin:menu:deleteVehicle` | RegisterCommand | — |
| `txAdmin:menu:fixVehicle` | RegisterCommand | — |
| `txAdmin:menu:healMyself` | RegisterCommand | — |
| `txAdmin:menu:noClipToggle` | RegisterCommand | — |
| `txAdmin:menu:openPlayersPage` | RegisterCommand | — |
| `txAdmin:menu:spawnVehicle` | RegisterCommand | — |
| `txAdmin:menu:togglePlayerIDs` | RegisterCommand | — |
| `txAdmin:menu:tpBack` | RegisterCommand | — |
| `txAdmin:menu:tpToCoords` | RegisterCommand | — |
| `txAdmin:menu:tpToWaypoint` | RegisterCommand | — |
| `txaEvent` | RegisterCommand | restricted=true |
| `txaInitialData` | RegisterCommand | restricted=true |
| `txaPing` | RegisterCommand | restricted=true |
| `txaReportResources` | RegisterCommand | restricted=true |
| `txaSetDebugMode` | RegisterCommand | restricted=true |
| `txadmin` | RegisterCommand | — |

### notify-test

| 命令 | API | 权限 |
|---|---|---|
| `notifytest` | RegisterCommand | — |
| `notifytest_server` | RegisterCommand | — |
| `notifytest_svr` | RegisterCommand | — |

### pma-voice

| 命令 | API | 权限 |
|---|---|---|
| `-radiotalk` | RegisterCommand | — |
| `cycleproximity` | RegisterCommand | — |
| `setvoiceintent` | RegisterCommand | — |
| `vol` | RegisterCommand | — |

### qb-adminmenu

| 命令 | API | 权限 |
|---|---|---|
| `admin` | QBCore.Commands.Add | QBCore: admin |
| `admincar` | QBCore.Commands.Add | QBCore: admin |
| `announce` | QBCore.Commands.Add | QBCore: admin |
| `blips` | QBCore.Commands.Add | QBCore: admin |
| `checkwarns` | QBCore.Commands.Add | QBCore: admin |
| `coords` | QBCore.Commands.Add | QBCore: admin |
| `delwarn` | QBCore.Commands.Add | QBCore: admin |
| `givenuifocus` | QBCore.Commands.Add | QBCore: admin |
| `heading` | QBCore.Commands.Add | QBCore: admin |
| `kickall` | QBCore.Commands.Add | QBCore: god |
| `maxmods` | QBCore.Commands.Add | QBCore: admin |
| `names` | QBCore.Commands.Add | QBCore: admin |
| `noclip` | QBCore.Commands.Add | QBCore: admin |
| `report` | QBCore.Commands.Add | — |
| `reportr` | QBCore.Commands.Add | QBCore: admin |
| `reporttoggle` | QBCore.Commands.Add | QBCore: admin |
| `setammo` | QBCore.Commands.Add | QBCore: admin |
| `setmodel` | QBCore.Commands.Add | QBCore: admin |
| `setspeed` | QBCore.Commands.Add | QBCore: admin |
| `staffchat` | QBCore.Commands.Add | QBCore: admin |
| `vector2` | QBCore.Commands.Add | QBCore: admin |
| `vector3` | QBCore.Commands.Add | QBCore: admin |
| `vector4` | QBCore.Commands.Add | QBCore: admin |
| `warn` | QBCore.Commands.Add | QBCore: admin |

### qb-ambulancejob

| 命令 | API | 权限 |
|---|---|---|
| `911e` | QBCore.Commands.Add | job/gang 判定 |
| `aheal` | QBCore.Commands.Add | QBCore: admin |
| `heal` | QBCore.Commands.Add | job/gang 判定 |
| `kill` | QBCore.Commands.Add | QBCore: admin |
| `revive` | QBCore.Commands.Add | QBCore: admin |
| `revivep` | QBCore.Commands.Add | job/gang 判定 |
| `setemsdept` | QBCore.Commands.Add | job/gang 判定 |
| `setpain` | QBCore.Commands.Add | QBCore: admin |
| `status` | QBCore.Commands.Add | job/gang 判定 |

### qb-banking

| 命令 | API | 权限 |
|---|---|---|
| `givecash` | QBCore.Commands.Add | — |

### qb-cityhall

| 命令 | API | 权限 |
|---|---|---|
| `drivinglicense` | QBCore.Commands.Add | — |

### qb-clothing

| 命令 | API | 权限 |
|---|---|---|
| `refreshskin` | RegisterCommand | — |

### qb-core

| 命令 | API | 权限 |
|---|---|---|
| `addpermission` | QBCore.Commands.Add | QBCore: god |
| `car` | QBCore.Commands.Add | QBCore: admin |
| `closeserver` | QBCore.Commands.Add | QBCore: admin |
| `dv` | QBCore.Commands.Add | QBCore: admin |
| `dvall` | QBCore.Commands.Add | QBCore: admin |
| `dvo` | QBCore.Commands.Add | QBCore: admin |
| `dvp` | QBCore.Commands.Add | QBCore: admin |
| `gang` | QBCore.Commands.Add | QBCore: user |
| `givemoney` | QBCore.Commands.Add | QBCore: admin |
| `job` | QBCore.Commands.Add | QBCore: user |
| `me` | QBCore.Commands.Add | QBCore: user |
| `ooc` | QBCore.Commands.Add | handler 内判定: HasPermission |
| `openserver` | QBCore.Commands.Add | QBCore: admin |
| `removepermission` | QBCore.Commands.Add | QBCore: god |
| `setgang` | QBCore.Commands.Add | QBCore: admin |
| `setjob` | QBCore.Commands.Add | QBCore: admin |
| `setmoney` | QBCore.Commands.Add | QBCore: admin |
| `togglepvp` | QBCore.Commands.Add | QBCore: admin |
| `tp` | QBCore.Commands.Add | QBCore: admin |
| `tpm` | QBCore.Commands.Add | QBCore: admin |

### qb-crypto

| 命令 | API | 权限 |
|---|---|---|
| `checkcryptoworth` | QBCore.Commands.Add | — |
| `crypto` | QBCore.Commands.Add | — |
| `setcryptoworth` | QBCore.Commands.Add | QBCore: admin |

### qb-doorlock

| 命令 | API | 权限 |
|---|---|---|
| `doordebug` | QBCore.Commands.Add | — |
| `newdoor` | QBCore.Commands.Add | — |
| `remotetriggerdoor` | RegisterCommand | — |
| `testcartelgate` | RegisterCommand | — |
| `toggledoorlock` | RegisterCommand | — |

### qb-drugs

| 命令 | API | 权限 |
|---|---|---|
| `dealergoto` | QBCore.Commands.Add | QBCore: admin |
| `dealers` | QBCore.Commands.Add | QBCore: admin |
| `deletedealer` | QBCore.Commands.Add | QBCore: admin |
| `deliverydebug` | RegisterCommand | — |
| `deliveryreset` | RegisterCommand | — |
| `newdealer` | QBCore.Commands.Add | QBCore: admin |
| `selldrugs` | QBCore.Commands.Add | QBCore: user |

### qb-houserobbery

| 命令 | API | 权限 |
|---|---|---|
| `gethroffset` | RegisterCommand | — |

### qb-houses

| 命令 | API | 权限 |
|---|---|---|
| `addgarage` | QBCore.Commands.Add | job/gang 判定 |
| `createhouse` | QBCore.Commands.Add | job/gang 判定 |
| `decorate` | QBCore.Commands.Add | — |
| `getoffset` | RegisterCommand | — |
| `ring` | QBCore.Commands.Add | — |

### qb-hud

| 命令 | API | 权限 |
|---|---|---|
| `bank` | QBCore.Commands.Add | — |
| `cash` | QBCore.Commands.Add | — |
| `dev` | QBCore.Commands.Add | QBCore: admin |
| `hud` | RegisterCommand | — |
| `hudsettings` | RegisterCommand | — |
| `resethud` | RegisterCommand | — |
| `rings` | RegisterCommand | — |

### qb-inventory

| 命令 | API | 权限 |
|---|---|---|
| `clearinv` | QBCore.Commands.Add | QBCore: admin |
| `closeInv` | RegisterCommand | — |
| `giveitem` | QBCore.Commands.Add | QBCore: admin |
| `hotbar` | RegisterCommand | — |
| `inventory` | RegisterCommand | — |
| `openInv` | RegisterCommand | — |
| `randomitems` | QBCore.Commands.Add | QBCore: god |
| `slot_` | RegisterCommand | — |
| `toggleHotbar` | RegisterCommand | — |

### qb-lapraces

| 命令 | API | 权限 |
|---|---|---|
| `cancelrace` | QBCore.Commands.Add | — |
| `togglesetup` | QBCore.Commands.Add | — |

### qb-mechanicjob

| 命令 | API | 权限 |
|---|---|---|
| `fix` | QBCore.Commands.Add | QBCore: admin |
| `setmechdept` | QBCore.Commands.Add | job/gang 判定 |

### qb-menu

| 命令 | API | 权限 |
|---|---|---|
| `playerfocus` | RegisterCommand | — |

### qb-multicharacter

| 命令 | API | 权限 |
|---|---|---|
| `closeNUI` | QBCore.Commands.Add | — |
| `deletechar` | QBCore.Commands.Add | QBCore: god |
| `logout` | QBCore.Commands.Add | QBCore: admin |

### qb-prison

| 命令 | API | 权限 |
|---|---|---|
| `prison` | RegisterCommand | — |

### qb-scoreboard

| 命令 | API | 权限 |
|---|---|---|
| `-scoreboard` | RegisterCommand | — |
| `scoreboard` | RegisterCommand | — |

### qb-spawn

| 命令 | API | 权限 |
|---|---|---|
| `fadein` | RegisterCommand | — |
| `fixscreen` | RegisterCommand | — |

### qb-storerobbery

| 命令 | API | 权限 |
|---|---|---|
| `acceptsurrender` | QBCore.Commands.Add | QBCore: user |
| `surrenders` | QBCore.Commands.Add | QBCore: user |

### qb-target

| 命令 | API | 权限 |
|---|---|---|
| `-playerTarget` | RegisterCommand | — |
| `playerTarget` | RegisterCommand | — |

### qb-vehicleshop

| 命令 | API | 权限 |
|---|---|---|
| `transfervehicle` | QBCore.Commands.Add | — |

### qb-weapons

| 命令 | API | 权限 |
|---|---|---|
| `repairweapon` | QBCore.Commands.Add | QBCore: god |

### qb-weathersync

| 命令 | API | 权限 |
|---|---|---|
| `blackout` | QBCore.Commands.Add | QBCore: admin |
| `checktime` | RegisterCommand | — |
| `evening` | QBCore.Commands.Add | QBCore: admin |
| `freezetime` | QBCore.Commands.Add | QBCore: admin |
| `freezeweather` | QBCore.Commands.Add | QBCore: admin |
| `freezeworld` | QBCore.Commands.Add | QBCore: admin |
| `morning` | QBCore.Commands.Add | QBCore: admin |
| `night` | QBCore.Commands.Add | QBCore: admin |
| `noon` | QBCore.Commands.Add | QBCore: admin |
| `settime` | RegisterCommand | — |
| `time` | QBCore.Commands.Add | QBCore: admin |
| `unfreezeworld` | QBCore.Commands.Add | QBCore: admin |
| `weather` | QBCore.Commands.Add | QBCore: admin |

### story-engine

| 命令 | API | 权限 |
|---|---|---|
| `decision` | RegisterCommand | — |
| `fixui` | RegisterCommand | — |
| `nuifocus` | RegisterCommand | — |
| `nuitest` | RegisterCommand | — |
| `story_choose` | RegisterCommand | — |
| `story_nui_ping` | RegisterCommand | restricted=true |
| `story_offer_dev` | RegisterCommand | restricted=true |

### tcity-atmosphere

| 命令 | API | 权限 |
|---|---|---|
| `atmos` | RegisterCommand | — |

### tcity-dashboard

| 命令 | API | 权限 |
|---|---|---|
| `dashboard` | RegisterCommand | — |
