# 没有游戏客户端时怎么证明改动有效

四条命令 + 每条能证明什么、不能证明什么。顺序重要：语法 → 类型 → 单测/架构闸门 →
构建产物 → 无头 NUI → 真服务器启动。

```bash
luac5.4 -p client/main.lua server/main.lua                     # 语法
/usr/bin/python3 -m pytest tests/unit tests/architecture -q    # 单测 + 架构闸门
npx svelte-check --tsconfig ./tsconfig.app.json                # 类型（0 error 再构建）
node tests/nui/run.mjs                                         # 无头 NUI
```

- `svelte-check` is a real gate, not decoration: it catches a duplicate key in an error-code table
  that the runtime silently resolves to the last entry, and mock-array typing that `never[]`-infers
  and breaks the build later. A clean `svelte-check` also proves the frontend compiles before a
  multi-minute browser run.
- **A Lua unit sandbox must load the files the module now depends on.** Once a service calls a global
  defined in another file of the same resource (a shared `util.lua`), loading only the service makes
  every test in that file fail with `attempt to call a nil value`. Feed the real dependency in —
  `mock + util_code + service_code + test_code` — instead of stubbing the helper: a stub reimplements
  the old semantics and stays green while the real implementation drifts. The failure is loud and
  total (whole file red), which is a feature: it tells you the loader, not the logic, is wrong.
- **A module that delegates to another resource needs a fake `exports`, and the fake must swallow
  `self`.** CfxLua's `exports` is a table that is *also* callable (`exports('Name', fn)` registers;
  `exports['res']:Method(a)` calls). Emulate both, and in the `__index` wrapper drop the first
  argument: `:Method(a)` passes the proxy table as `self`, so a naive passthrough shifts every
  parameter — `RateLimitTokenBucket(proxy, key, rate, burst)` sees a table where the key belongs, the
  guard `type(key) ~= 'string'` returns "allowed", and the test passes 15/15 while proving nothing.
  Load the real owner file into the sandbox (never a second implementation of it) and assert the
  **pattern**, not one sample: `burst=10 → YYYYYYYYYYNNN`, not just `call 11 == false`.

- **A test that asserts source text is a test of *where* the code lives.** `assert "IsModelInCdimage" in
  src` passes only while the guard sits in that file; after moving the implementation into a shared
  include every such assertion goes red even though the behaviour is intact, and the lazy fix
  (delete the assertion) removes the only thing checking the guard. Rewrite it as two assertions:
  the caller *references* the shared symbol (`assert "CFShared" in caller_src`), and the guard plus
  its timeout still exist *in the shared file*. Same for file-existence assertions — a path
  assertion is a location claim, so re-point it at the new home in the same commit.
- `luac5.4 -p` and the runtime disagree **in both directions**. CfxLua files never pass luac
  (extensions), and luac also accepts things CfxLua rejects: `type(exports['x']:Method)` parses but
  the server answers `function arguments expected near ')'` and drops the file. luac is therefore
  necessary, never sufficient — the loadability proof is the absence of `Failed to load script` /
  `Error parsing script` in the boot log. When a resource's subsystem goes quiet right after you
  touched it, grep the log for those two strings before reading your own diff.
- **Stubbing a native silently breaks the harness when the module calls it indirectly.** Client code
  written as `Citizen.Wait(10)` ignores a global `function Wait()` stub and dies with
  `attempt to index a nil value (global 'Citizen')` — stub `Citizen = { Wait = … }` and drive the
  injected clock from there. Likewise do **not** stub global `print` for capture unless the test's
  own output goes elsewhere: every `print` from the test body lands in the capture table and the
  harness reports `{}` against a passing run. Emit test lines with
  `io.write(x .. string.char(10))` (avoiding `\n` inside a Python triple-quoted Lua string is the
  other half of that fix: the escape can collapse into a real newline and split a Lua statement).
  `git show HEAD:<path> > /tmp/x.lua && luac5.4 -p /tmp/x.lua` — same line, same message, not
  yours. Then read which line it reports: if the reported line is unchanged by your edit, your hunk
  is syntactically consistent; if it moved or the message changed, you broke something. Never
  rewrite `+=` into `a = a + 1` (or strip backticks) to make the checker green — that is a real
  change to someone else's resource made only to satisfy a tool.
- Build the bundle before the NUI runner (`npm run build`); editing `web/src` alone does not
  change `html/assets/*.js`, and the runner loads the built bundle. Check the emitted filenames are
  hashed (`index-<hash>.js`) — a fixed name is the stale-bundle trap above.
- Run the browser runner detached with output to a log. A cold chromium launch can exceed a
  3-minute foreground timeout — a timeout there is not a failing test, so give it a long budget
  and read the log.
- Parse **every** manifest, not just the one you touched — a manifest is Lua, so one loop covers the
  tree and it takes a second:
  ```bash
  for f in $(find resources -maxdepth 3 -name fxmanifest.lua); do
      out=$(luac5.4 -p "$f" 2>&1); [ -n "$out" ] && echo "❌ $f: $out"
  done
  ```
  The failure this catches is the one with no local signal: inserting an entry into
  `dependencies { … }` or `client_scripts { … }` without the comma after the *previous* last item
  yields `'}' expected`, yet `restart <resource>` reports success because the server reuses parsed
  metadata. It surfaces at the next `refresh`/full boot as "N resources failed to load" — and since
  `dependencies` is a start barrier, a broken **core** manifest keeps every dependent down: the
  console shows a half-empty resource list, which reads like a server crash.
- Then restart the resource on the live server and read the boot lines. `Started resource X`
  with no `stack traceback` is the layer the unit gates cannot prove.
- Manifest changes split in two. Editing an already-listed script propagates on
  `restart <resource>`; a **newly added** script/file entry does not, because the server reuses its
  parsed resource metadata (script list included) on restart. Run `refresh` (or restart the whole
  server) **then** `restart <resource>` — a client reconnect alone does not help, and the file looks
  broken rather than absent. Prove the file ran at all before debugging it: put a single
  `TriggerServerEvent`/`print` at its top and restart once. Keep a one-line boot log in every module
  (`[x] trace core loaded (level=N)`) so "did this file load" never costs a round of guessing.

## 服务端逻辑的验证：启动即执行、结果落盘的探针

要验的不是"导出存在"，而是**函数算得对不对**（SQL 语义、限流边界、并发）。这种错静态检查
和单测可以全绿——单测用的是 mock 的 MySQL，真 SQL 里 `DECIMAL` 与 `DOUBLE` 相加照样漂。

做法：把探针放进一个已声明 `dependencies` 的服务端资源，**启动时自动跑**，结果用
`SaveResourceFile` 写进资源目录，然后整机重启，直接读文件。全程不碰控制台——控制台回显不可信、
命令会被拼坏、还可能把资源静默停掉。

```lua
-- server/_probe_verify.lua，临时插进 fxmanifest 的 server_scripts
CreateThread(function()
    Wait(8000)                      -- 等 qb-core / oxmysql / core-framework 就绪
    local out = {}
    local function rec(k, v) out[#out + 1] = ('%s = %s'):format(k, tostring(v)) end

    local cid = 'probe' .. math.random(100000, 999999)
    MySQL.insert.await('INSERT INTO players (citizenid, license, name, money, job, position, metadata) VALUES (?,?,?,?,?,?,?)',
        { cid, 'probe', 'Probe', json.encode({ cash = 100, bank = 500, keep = 'must-survive' }),
          '{}', '{}', '{}' })

    local done, ok = false, nil          -- 回调式 API 要自己等
    exports['qb-core']:EconomyAddMoneyOffline(cid, 'cash', 0.55, 'probe', function(r) done, ok = true, r end)
    local t0 = GetGameTimer()
    while not done and GetGameTimer() - t0 < 5000 do Wait(25) end

    rec('cash_+0.55', ('ok=%s money=%s'):format(tostring(ok),
        MySQL.scalar.await('SELECT JSON_EXTRACT(money, "$.cash") FROM players WHERE citizenid = ?', { cid })))
    rec('unknown_field_kept', MySQL.scalar.await('SELECT JSON_EXTRACT(money, "$.keep") FROM players WHERE citizenid = ?', { cid }))

    MySQL.query.await('DELETE FROM players WHERE citizenid = ?', { cid })
    SaveResourceFile(GetCurrentResourceName(), 'probe_report.txt', table.concat(out, '\n'), -1)
end)
```

要点：

- 探针要能**造数据 → 断言 → 清数据**，否则跑一次就在正式库里留垃圾（临时 `citizenid` 前缀 + 末尾 DELETE）。
- 只 `INSERT` 一个 `citizenid` 会失败：`players` 有 `license`/`name`/`money`/`job`/`position`/`metadata`
  这些 NOT NULL 且无默认值的列。先在探针里跑一次 `SHOW COLUMNS FROM players` 并把结果打出来。
- 把期望值也写进报告，而不是只打错误——报告要能直接贴进交付说明当证据。
- 跑完**立刻**删探针文件、从 fxmanifest 摘掉（`refresh` 才重新解析清单）、删生成的报告文件，
  否则它会被提交进仓库。
- 这一层抓得到、单测抓不到的典型：金额浮点漂移（`100 + 0.55 = 100.5499999999999545`）、
  令牌桶 `burst=N` 放过第 `N+1` 次、整块覆盖导致的丢更新（并发两次 `+10` 只加一次）。
- 抓到之后**先补一个会红的单测**再修，否则下次改一行又回去了。

## 证明跨资源导出真的能用（进程内的端到端探针）

静态检查（导出注册在正确侧、调用方惰性包装、文件在清单里）会一直绿，而运行时是坏的：
**缺失的导出只在你第一次调用它的那一刻才抛 `No such export`**。靠重启"没报错"判断安全是错的，
因为调用发生在玩家触发时。同时客户端的 `print` 只到玩家的 F8 控制台，**服务端日志里永远看不到**，
所以它不能作为给你的证据。

可靠的做法是用一个临时探针，把结果送到服务端能看见的通道：

```lua
-- 临时探针：验完即删（放在调用方资源里，重启该资源即生效）
CreateThread(function()
    Wait(4000)
    local ok, res = pcall(function() return exports['core']:LoadAnimDict('mini@repair') end)
    TriggerServerEvent('phone:server:clientError', {        -- 任何已登记的 diagnostic 事件都行
        source = 'anim-probe', event = 'LoadAnimDict',
        message = ('ok=%s returned=%s loaded=%s'):format(tostring(ok), tostring(res),
            tostring(ok and HasAnimDictLoaded('mini@repair'))),
    })
end)
```

三条都要看：`ok=true`（导出存在）、`returned=true`、`loaded=1`（真的加载出资源）。

- `ok=false … No such export`：**客户端没拿到新文件**。`refresh` → 重启提供方 → 重启调用方；
  客户端重连不管用。
- 采集到证据后删掉探针；提供方保留一行启动自证 print（F8 可见），用来区分"文件没加载"和"逻辑错"。
- **在加载期调用的助手（`config.lua` 顶层）不需要探针**：缺导出会让资源在启动时直接失败，
  所以"资源 Started 且无 `No such export`"本身就是证据——前提是它声明了 `dependencies`。
