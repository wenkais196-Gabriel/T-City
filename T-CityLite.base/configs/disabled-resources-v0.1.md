# Disabled Resources - v0.1

v0.1 avoids broad grouped loading such as `ensure [qb]`. Resources below are intentionally not started unless listed in "Dependency exceptions".

## Dependency exceptions started in v0.1

| Resource | Reason | Planned ownership |
| --- | --- | --- |
| PolyZone | Required by `qb-target`, `qb-apartments`, and `qb-clothing`. | Core/player dependency |
| qb-interior | Required by `qb-apartments`. | Player spawn/apartment dependency |
| qb-clothing | Required by `qb-apartments`; originally planned disabled, but manifest dependency blocks apartment startup without it. | Revisit in v0.2 |
| qb-weapons | Required by `qb-inventory`. | Inventory dependency |

## Disabled for later versions

| Resource | Reason | Planned version | Known dependency notes |
| --- | --- | --- | --- |
| qb-phone | Non-essential for login/spawn startup. | v0.2+ | May depend on player, banking, mail, and jobs data. |
| qb-houses | Housing gameplay outside v0.1 minimal flow. | v0.2+ | May overlap with apartments/spawn decisions. |
| qb-policejob | Job gameplay outside v0.1 minimal flow. | v0.2+ | Likely depends on jobs, duty, evidence, vehicles, inventory items. |
| qb-ambulancejob | Job gameplay outside v0.1 minimal flow. | v0.2+ | Likely depends on hospital/spawn logic and job data. |
| qb-bankrobbery | Crime gameplay outside v0.1 minimal flow. | v0.5+ | Depends on police/job/inventory/security resources. |
| qb-doorlock | World interaction module outside v0.1 minimal flow. | v0.2+ | May depend on jobs and target/menu systems. |
| qb-garages | Vehicle ownership flow outside v0.1 minimal flow. | v0.2+ | May depend on vehicles, apartments/houses, and database tables. |
| qb-vehicleshop | Economy/vehicle sales outside v0.1 minimal flow. | v0.3+ | Depends on vehicle data and economy. |
| qb-drugs | Crime gameplay outside v0.1 minimal flow. | v0.5+ | Depends on inventory, police, and map/interaction resources. |
| qb-houserobbery | Crime gameplay outside v0.1 minimal flow. | v0.5+ | Depends on houses, police, inventory. |
| qb-storerobbery | Crime gameplay outside v0.1 minimal flow. | v0.5+ | Depends on police, inventory, dispatch/alerts if present. |
| qb-jewelery | Crime gameplay outside v0.1 minimal flow. | v0.5+ | Depends on police, inventory, and robbery flow resources. |
| qb-lapraces | Racing gameplay outside v0.1 minimal flow. | v0.5+ | May depend on phone, vehicles, and racing tables. |
| qb-streetraces | Racing gameplay outside v0.1 minimal flow. | v0.5+ | May depend on phone, vehicles, and racing tables. |

## Removed grouped starts

- `ensure [qb]`
- `ensure [standalone]`
- `ensure [voice]`
- `ensure [defaultmaps]`
