-- client/interact.lua — "站在区域里按 E" 的唯一实现
--
-- 收口前 `job.lua` 有 **6 段一模一样的逐帧轮询**（值班、储物柜、垃圾桶、直升机、拖车场、车库）：
--
--     CreateThread(function()
--         while true do
--             Wait(0)
--             if inStash and PlayerJob.type == 'leo' then
--                 if IsControlJustReleased(0, 38) then ... break end
--             else
--                 break
--             end
--         end
--     end)
--
-- 每段的差别只有"哪个 flag""要不要在车里""按下去做什么"。这类循环的问题：
--   * 逐帧跑（Wait(0)），而它要等的只是一个按键；
--   * 6 份拷贝各自演化，改一处忘一处（`sleep = 5` 这种死代码就是拷贝留下的）；
--   * 退出条件散落在 else 分支里，看不出来它其实只在区域内才活。
--
-- 这里留一份实现，退出条件写成显式的 `active`，额外条件写成 `allowed` / `requireVehicle`。

PoliceInteract = PoliceInteract or {}

--- 在区域内按控制键触发一次，然后退出。
---@param opts table {
---   active: fun():boolean      必须；返回 false 时线程退出（例如离开区域）
---   onPress: fun()             必须；按下时执行一次
---   allowed: fun():boolean|nil 可选；返回 false 时线程退出（例如换了职业）
---   requireVehicle: boolean|nil 可选；只在车内响应（拖车场/车库）
---   control: number|nil        默认 38（E）
---   after: fun()|nil           可选；按下后、退出前执行（例如复位 flag）
--- }
---@return boolean started
function PoliceInteract.Watch(opts)
    if type(opts) ~= 'table' then return false end
    if type(opts.active) ~= 'function' or type(opts.onPress) ~= 'function' then return false end
    local control = opts.control or 38

    CreateThread(function()
        while true do
            if not opts.active() then
                break
            end
            if opts.allowed and not opts.allowed() then
                break
            end

            local ready = true
            if opts.requireVehicle and not IsPedInAnyVehicle(PlayerPedId(), false) then
                ready = false
            end

            if ready and IsControlJustReleased(0, control) then
                if opts.onPress() ~= false then
                    if opts.after then opts.after() end
                    break
                end
            end

            Wait(0)
        end
    end)
    return true
end
