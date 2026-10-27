# REUSE — 共享代码放哪、什么该合并、怎么收敛

> 这份文件回答"组件复用"的具体问题：**同一能力允许有几份实现**。
> 配套：`tools/dev/reuse_scan.py`（报告）、`tests/architecture/reuse_budget.json`（预算）、
> `tests/architecture/test_reuse_budget.py`（棘轮闸门）。

## 1. 一条规则

**同名能力的第二份实现，必须是一次显式决策**：要么合并，要么在预算里写理由。
默认不是"再抄一份更快"，而是"先看有没有现成的"。

```bash
python3 tools/dev/reuse_scan.py --min 3        # 现在哪些能力被实现了很多遍
```

## 2. 共享代码放哪

| 类型 | 位置 | 例子 |
|---|---|---|
| 与业务无关的纯工具（两端都要） | `resources/[standalone]/core-framework/shared/util.lua`，用 `exports('<Name>')` 暴露 | `LoadAnimDict` |
| 只在一侧用的工具 | 同上，但导出前用 `if not IsDuplicityVersion()`（客户端）或服务端分支包裹 | — |
| 跨资源业务能力 | 由 **owner 资源** 用 `exports` 暴露，别的资源调用前先确认 owner 表 | `core_economy:TriggerReward` |
| 资源内部重复（同一资源多文件） | 该资源自建的 client 库文件 / shared 目录 | — |

调用方写法（**不要**在文件顶部直接 `local f = exports[...]`）：

```lua
-- 导出在"调用时"解析：这样资源启动顺序不影响，也不会把核心资源变成加载期硬依赖。
local loadAnimDict = function(dict) return exports['core-framework']:LoadAnimDict(dict) end
```

## 3. 什么不该合并（以及为什么）

| 情况 | 例子 | 理由 |
|---|---|---|
| 同名但**语义不同** | `DebugPrint`（14 份） | 每份带自己的调试开关（`EnableDebug` / `enableDebugLogs`）与日志前缀，合并会改变行为 |
| **上游/第三方**代码 | `qb-*` 里的 `loadAnimDict`（10 份）、`standalone/`（2 份） | 迁成我们核心的导出 = 与上游分叉，后续无法合并上游更新 |
| 参数语义还没统一 | `DrawText3D` / `DrawText3Ds` | 各份 scale/color/参数顺序不同，先统一签名再合并 |
| owner 明确的业务能力 | `HasItem` / `AddMoney` | 真正的 owner 是 qb-inventory / 经济服务，重复的应该是"调用 owner"而不是"再写一份" |

判据很实用：**合并后行为是否完全一致**。一致 → 合并；不一致 → 那不是重复，是同名。

## 4. 棘轮（只许变少）

`reuse_budget.json` 记每个能力当前的实现份数：

- 现在 **多于** 预算 → 红（碎片变多了）；
- 现在 **少于** 预算 → 也红，并要求把预算降到实际值（否则棘轮只会松，不会紧）；
- 出现新的"≥4 份同名定义"却没登记 → 红（逼一次决策）。

合并完成后，同一次提交里把预算数字降下来——这就是"收敛"的证据。

## 5. 当前状态（2026-10-25）

| 能力 | 之前 | 现在 | 说明 |
|---|---|---|---|
| `loadAnimDict` | 17 | 12 | `[custom]` 5 处合并；qb/standalone 保留（不迁上游） |
| convar 助手族（`GetIntConvar` / `GetBoolConvar` / `GetFloatConvar` / `GetStrConvar` / `GetNumConvar` / `convarInt` / `convarString`） | 23 | 0（全部走 `ConvarString/Int/Float/Bool`） | 12 个文件迁移；**这批是在加载期调用的**，所以顺带给 6 个资源补了 `dependencies { 'core-framework' }` |
| 合计同名 ≥4 的能力组 | 15 组 | 12 组 | `reuse_budget.json` 同步收紧 |

顺带修掉的两个真隐患：

- `loadAnimDict` 原实现无上限（`while … Wait(n)`），字典缺失会把客户端脚本线程卡死 → 共享版有 5s 上限；
- convar 助手在 `config.lua` **顶层**就被调用（`RewardScale = GetFloatConvar(...)`），这类调用对启动
  顺序敏感。所以迁移必须同时补 `dependencies`，否则某个资源先起就会 `No such export` 整个加载失败。
  闸门 `test_load_time_callers_declare_the_core_dependency` 把这条钉住了。

下一批候选（按收益排序）：`loadModel`（阻塞循环，与 loadAnimDict 同类，需加超时）→
`checkRateLimit`（与 `core-framework` 的 `rate_limit.lua` 职责重叠）→ `DrawText3D` 族（先统一签名）→
`AddMoney`（重复本身可能是宪法②的违反，要单独审）。

## 6. 怎么加一个新的共享工具

1. 在 `resources/[standalone]/core-framework/shared/util.lua` 加函数 + `exports('<Name>', fn)`（客户端能力记得加守卫）；
2. 写清注释：**语义、返回值、超时/失败行为**；
3. 迁移至少一个调用点作为样板，其余留在预算里逐步收；
4. `reuse_scan` 里对应的计数应下降 → 同提交把 `reuse_budget.json` 调低；
5. 验证真实调用（**必做**，静态检查救不了这一步）。这是本仓库踩过的真实故障：
   前 4 步全绿、`restart` 后也没有任何报错，但客户端根本没拿到 `resources/[standalone]/core-framework/shared/util.lua`，
   要等玩家触发动画时才炸 `No such export LoadAnimDict in resource core-framework`。

   ```bash
   # a. 共享库改过/新增文件 → 必须先 refresh：`restart` 只重读清单里"已存在"的文件，
   #    新增文件不会交付给已经连接的客户端。
   tcity-cmd -w 8 "refresh" && tcity-cmd -w 8 "restart core-framework"
   tcity-cmd -w 8 "restart <调用方资源>"

   # b. 客户端 F8 里应出现自证行（只有客户端能看到，服务端日志没有）：
   #    [core-framework] client util ready (exports: LoadAnimDict)
   ```

   ```lua
   -- c. 服务端可见的端到端证明：临时探针（验完删掉）
   CreateThread(function()
       Wait(4000)
       local ok, res = pcall(function() return exports['core-framework']:LoadAnimDict('mini@repair') end)
       TriggerServerEvent('phone:server:clientError', {   -- 现成的诊断通道，白名单字段
           source = 'anim-probe', event = 'LoadAnimDict',
           message = ('ok=%s returned=%s loaded=%s'):format(tostring(ok), tostring(res),
               tostring(ok and HasAnimDictLoaded('mini@repair'))),
       })
   end)
   -- 期望：[custom-phone][nui-error] src=N source=anim-probe ... ok=true returned=true loaded=1
   ```

   三条都要看：自证行（脚本到了）、`ok=true`（导出存在）、`loaded=1`（真的加载出字典）。
