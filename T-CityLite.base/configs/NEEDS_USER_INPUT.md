# T-City Lite v0.1 - Needs User Input

Fill or confirm these before the first real startup test.

## Required

- Database connection string in `server.cfg`
  - Current value was copied from the original base.
  - Confirm host, database name, username, and password.
  - Decide whether Lite should keep using `QBCore_CDB34E` or use a separate database.
- FiveM license key in `server.cfg`
  - Current value was copied from the original base.
  - Confirm it is valid for this server.

## Recommended

- Server locale in `server.cfg`
  - Current value: `root-AQ`
  - Suggested example: `zh-CN`, `en-US`, or the locale you want players to see.
- Admin principals in `server.cfg`
  - Replace `identifier.fivem:YOUR_FIVEM_ID` with your actual FiveM identifier
  - 如何获取: 在服务器控制台中输入 `print(player)` 查看自己的 identifier
- Public server name, project name, project description, and tags.

## Startup test data to provide

- Whether MySQL/MariaDB is running locally or elsewhere.
- Database user privileges for the selected QBCore database.
- First server console errors after startup.
- Client F8 errors after connecting.
