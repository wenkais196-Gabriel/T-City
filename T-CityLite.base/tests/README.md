# 测试指南

> 目标：在任何机器上都能跑"不依赖 FXServer"的检查；需要游戏内/DB 的测试单独标注前提。

## 1. 环境变量

DB 测试**不再内置密码**。先复制模板并填写：

```bash
cp .env.example .env          # 仓库根目录
set -a; . ./.env; set +a
```

必需变量：

| 变量 | 说明 |
|:---|:---|
| `TCITY_DB_HOST` / `TCITY_DB_PORT` | 默认 `localhost:3306` |
| `TCITY_DB_USER` / `TCITY_DB_PASS` | 有写权限的测试账号 |
| `TCITY_DB_NAME` | 默认 `TCityLite` |
| `TCITY_DB_URI` | JS 测试用完整 URI（可由上面拼出） |

没有设置 `TCITY_DB_PASS` 时，DB 相关 fixture 会自动 `skip`，不会失败。

## 2. 离线检查（无需 FXServer / DB）

```bash
cd T-CityLite.base

python3 tests/check_cfgs.py             # ensure 目标存在、无重复
python3 tests/check_dependencies.py     # 依赖图 + 启动顺序
python3 tests/check_bus_wiring.py       # Bus 注册方是否 include bus.lua
python3 tests/check_db_schema.py        # 有 DB 时校验表结构；否则报 SKIP

python3 tests/run_all.py                # 一键跑以上 + light_lint
```

## 3. Python 单元测试

```bash
cd T-CityLite.base
python3 -m pytest -q tests/unit
```

需要：

```bash
python3 -m pip install --user mysql-connector-python
```

## 4. 集成测试

```bash
cd T-CityLite.base
python3 -m pytest -q tests/integration
```

会连接 `TCITY_DB_*` 指定的库；未配置密码时自动 skip。

## 5. JavaScript DB 冒烟

```bash
cd T-CityLite.base/tests
npm install                 # 仅首次
TCITY_DB_URI="mysql://user:pass@localhost:3306/TCityLite" node db_check.js
TCITY_DB_URI="mysql://user:pass@localhost:3306/TCityLite" node db_chain_check.js
node unit/layer0_js/test_flatten_json.cjs   # 需要 MYSQL_URL 或 TCITY_DB_URI
```

## 6. 游戏内测试（需要 FXServer）

以下测试需要真实服务器（含 `alpine/`、license key、DB）：

- `custom-testing` 资源的 `/test`、`/stress`
- `tests/*.lua`（`run_all_tests.lua`、`v0.5_e2e_test.lua` 等）
- `custom-quest/tests/*`

生产环境不要 ensure `custom-testing`；本地开发在 `server.cfg` 里：

```
exec configs/modules/dev.cfg
```

## 7. 已知基线噪音

- `tests/light_lint.py` 会对全仓（含第三方资源）报大量 W001/E 级告警，属既有基线，非关键失败。
- `tests/check_db_schema.py` 的 `EXPECTED_SCHEMA` 尚未覆盖全部新表（quest/story/world_state），会按缺失报告，需逐步补齐。

## 8. 安全

- 不要在测试代码里写死密码；统一走环境变量。
- `.env` 已在 `.gitignore` 中。
- 如果历史提交里出现过真实密码，请立即轮换数据库账号密码。
