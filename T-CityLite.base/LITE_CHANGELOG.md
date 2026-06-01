# T-City Lite Changelog

## v0.2 - Basic RP modules

Date: 2026-05-28

- Added modular startup cfg files for jobs, banking, vehicles, police, and medical.
- Enabled `progressbar`, `qb-management`, `qb-banking`, `qb-fuel`, `qb-vehiclekeys`, `qb-garages`, `qb-policejob`, and `qb-ambulancejob`.
- Kept startup loading modular through `exec configs\modules\*.cfg`; grouped `ensure [qb]` remains disabled.
- **Fixed `pma-voice` OneSync dependency**: Added `set onesync on` to `server.cfg` to resolve OneSync error and allow voice system to start successfully.
- Verified database tables (`bank_accounts`, `bank_statements`, `player_vehicles`) in `QBCore_CDB34E` are fully loaded and operational.
- Recorded v0.2 resource inventory, dependency notes, security preaudit, and deferred resources.
- Confirmed `qb-core\shared\jobs.lua` already includes police, ambulance, mechanic, taxi, and boss grade configuration.
- Deferred `qb-phone`, `qb-smallresources`, `qb-doorlock`, and `qb-prison` until future milestones.
- **Test Feedback Adjustments (2026-05-29)**:
  - Removed "Order Physical Debit Card" button from Svelte UI and disabled server-side card ordering callback since debit cards and ATMs are disabled.
  - Fixed NUI shared users list bug by decoding `users` JSON string into a Lua table in `openBank` and `openATM` callbacks (resolving the `[` and `]` display issue).
  - **Wanted Level Police Handover & Radar blips (New Custom Gameplay)**: Implemented custom client/server dispatch system inside `custom-main` where native GTA wanted levels >= 3 automatically clear native AI cops (preventing NPC clutter) and hand over the chase to player police. Triggered server-wide dispatch alerts, persistent metadata saving, radar triangulation red-blips updating every 8 seconds on on-duty cop HUDs, and a `/clearwanted [id]` police command. Includes a **local civilian NPC panic system** where pedestrians scream and flee in fear, and drivers slam the gas to speed away when within 25 meters of a wanted fugitive.
  - **Custom Duty Toggle Command**: Added a convenient chat command `/duty` allowing players with compatible careers (police, ambulance, mechanic, taxi) to quickly toggle between active duty (On Duty) and off duty (Off Duty) without needing to visit the physical duty markers inside target buildings.
- Completed and checked off all milestones in `v0.2-basic-rp.md` spec checklist.


## Active v0.2 resources

### Jobs

- progressbar
- qb-management

### Banking

- qb-banking

### Vehicles

- qb-fuel
- qb-vehiclekeys
- qb-garages

### Police

- qb-policejob

### Medical

- qb-ambulancejob

## v0.1 - Lite startup chain

Date: 2026-05-28

- **Spawn Death Prevention**: Implemented an automated health restoration and auto-revival fallback system in `custom-main` that automatically triggers when `qb-ambulancejob` is disabled, preventing players from spawning dead/downed during testing.
- Created Lite base from `D:\txData\QBCore_CDB34E.base`.
- Reworked startup loading away from grouped `ensure [qb]`.
- Added module configs under `configs\modules`.
- Added disabled resource tracking for v0.1.
- Added startup test log placeholder for first server run.
- Added user input checklist for sensitive or environment-specific config.
- Added required dependency exceptions discovered from manifests: `PolyZone`, `qb-interior`, `qb-clothing`, and `qb-weapons`.
- Added v0.1 maintenance documentation under `docs\v0.1-maintenance.md`.
- Recorded basic client test as passed.

## Active v0.1 resources

### Core

- oxmysql
- qb-core

### Player

- qb-menu
- qb-input
- qb-target
- PolyZone
- qb-multicharacter
- qb-spawn
- qb-apartments
- qb-interior
- qb-clothing
- qb-inventory
- qb-weapons
- qb-hud
- qb-weathersync

### Voice

- pma-voice

### Custom

- custom-main

## Known pending items

- [x] Reconnect persistence has been successfully tested and confirmed operational by the user.
- FiveM license key and public server metadata should be confirmed before public use.
- Continue capturing console and client F8 errors during later module expansion.
