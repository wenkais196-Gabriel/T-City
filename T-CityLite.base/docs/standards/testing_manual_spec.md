# 🧪 T-City Lite 测试手册编写规范 (testing_manual_spec.md)

> **修订日期**: 2026-06-04  
> **设计原理**: 实施 Layer 1 (离线 Python) -> Layer 2 (游戏内 Lua) 双层测试保障，辅以前端 NUI 仿真 Mock，降低单人开发联调开销。

---

## 1. 测试体系结构规范

项目所有资源的测试体系统一分为三部分：

```
                    ┌──────────────────────────────┐
                    │  1. 前端 NUI 浏览器仿真 Mock  │  ← web 目录开发调试
                    └──────────────┬───────────────┘
                                   ▼
                    ┌──────────────────────────────┐
                    │  2. Layer 1 终端离线自检     │  ← 提交前终端 3 秒扫描
                    └──────────────┬───────────────┘
                                   ▼
                    ┌──────────────────────────────┐
                    │  3. Layer 2 游戏内断言套件   │  ← 进游戏 /test run
                    └──────────────────────────────┘
```

---

## 2. Layer 1 离线自检编写规范

所有离线自检脚本必须使用 Python 3 编写，统一放在项目根目录下的 `tests/` 文件夹。

*   `check_cfgs.py`：对新加的模块 `ensure xxx` 扫描，必须有对应的 `fxmanifest.lua`。
*   `check_db_schema.py`：连接本地 MariaDB 开发数据库，验证字段和新增索引是否存在。

### Python 自检输出断言风格：
自检输出必须简洁，一目了然地显示 **PASS/FAIL/WARNING** 状态：
```python
# 离线自检命令行输出模板示例：
print("═══════════════════════════════════════")
print(" T-City Lite 离线检测报告")
print("═══════════════════════════════════════")
print("[PASS] CFG 完整性验证 — 56/56 resources OK")
print("[FAIL] db_schema 索引验证 — 缺失 bank_statements.idx_date 索引")
```

---

## 3. Layer 2 游戏内 Lua 测试套件规范

所有的游戏内测试用例统一存放于 `[custom]/custom-testing/suites/` 下，文件命名为 `[序号]_[功能]_test.lua`（例如：`01_banking_test.lua`）。

### 3.1 测试框架断言语法

```lua
-- 标准测试套件语法示例
Test.describe("银行系统 (qb-banking)", function()
    
    -- 每个用例开始前执行的 Hook（可选）
    Test.before_each(function()
        -- 重置测试资金
    end)

    Test.it("应成功存款并正确累加余额", function()
        local src = source
        local beforeBalance = exports['service_economy']:GetBalance(src)
        
        -- 调用待测试的 API
        local success = exports['qb-banking']:DoDeposit(src, 1000, "测试存款")
        
        local afterBalance = exports['service_economy']:GetBalance(src)
        
        -- 标准断言 API
        Test.assert_true(success, "存款操作应返回成功状态")
        Test.assert_equal(beforeBalance + 1000, afterBalance, "存款后余额应精确累加 1000")
    end)

    Test.it("超出余额的取款应被安全拦截", function()
        local src = source
        local balance = exports['service_economy']:GetBalance(src)
        
        -- 尝试超额取款
        local success, err = exports['qb-banking']:DoWithdraw(src, balance + 99999, "非法取款")
        
        Test.assert_false(success, "超额取款应被逻辑拒绝")
        Test.assert_not_nil(err, "被拒绝时应附带错误原因说明")
    end)
end)
```

### 3.2 单人多角色模拟 (Mock 机制)
单人开发时，由于无法让真实的多人玩家在线联调（例如测试警察数量达到 2 人时才允许抢劫），必须在测试脚本中使用 `Mock` 进行逻辑打桩：

```lua
-- 模拟 2 名执勤警察在线
Mock.set_onduty_count("police", 2)

-- 运行抢劫触发用例
local allowed = exports['custom-crime']:CheckStoreRobbery(source, 1)
Test.assert_true(allowed, "警察满2名时，商店抢劫应允许触发")

-- 模拟警察全部下班
Mock.set_onduty_count("police", 0)
local allowed_fail = exports['custom-crime']:CheckStoreRobbery(source, 1)
Test.assert_false(allowed_fail, "无警察在岗时，商店抢劫应被无情拦截")
```

---

## 4. 前端 NUI 浏览器仿真规范 (Svelte Mock)

任何包含 HTML5 用户界面的资源，必须在其前端工程（通常是资源目录下的 `web/` 目录）中集成环境判定与 Mock。

### 4.1 环境判定代码
在前端的通用网络库中，判定当前是真实游戏还是普通浏览器调试模式：

```typescript
// web/src/utils/nui.ts
export function isBrowser(): boolean {
  // 游戏内会提供 GetParentResourceName 函数，普通浏览器环境没有
  return !(window as any).GetParentResourceName;
}
```

### 4.2 浏览器级事件模拟
在 `isBrowser()` 为 `true` 时，拦截所有向 FiveM 客户端发送的 `fetchNui` 消息，并在内存中构造完全一致的响应结果：

```typescript
// 统一请求代理封装
export async function requestNui<T>(eventName: string, data?: any): Promise<T> {
  if (isBrowser()) {
    console.log(`[Browser Mock Request] Event: ${eventName}`, data);
    
    // 根据事件名模拟内存返回
    if (eventName === "withdraw") {
      if (data.amount > 10000) {
        return { success: false, message: "ATM单笔取款限额 $10,000" } as unknown as T;
      }
      return { success: true, message: "取款成功" } as unknown as T;
    }
    
    // 默认返回成功
    return { success: true } as unknown as T;
  }

  // 游戏内真实发包给 FiveM Cef 容器
  const resourceName = (window as any).GetParentResourceName();
  const resp = await fetch(`https://${resourceName}/${eventName}`, {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=UTF-8" },
    body: JSON.stringify(data),
  });
  return await resp.json();
}
```
通过该规范，开发者可以直接在普通 Chrome 浏览器中通过 `npm run dev` 快速调试 UI、微动画与报错文案，免去反复进入游戏的痛苦。
