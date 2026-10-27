# Lua golden harness

```bash
lua5.4 T-CityLite.base/tests/agent/lua/runner.lua
```

- `lua/cases/`：9 个 suite（HTTP 契约、live、effect、director、phone…）
- `lua/stubs/`：FiveM / QBCore / MySQL 桩
- 输出 JSON 到 stdout，pytest 包装在 `tests/agent/test_lua_harness.py`

新增 case：在 `lua/cases/` 加文件并在 `lua/runner.lua` 的 `CASES` 注册。
