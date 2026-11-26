-- fixtures/industry_probe_common.lua — 假 DB 探针共用的构造器。
--
-- 由 tests/unit/layer3_business/industry_harness.py 在**所有 industry 探针之前**
-- 注入（sales / cycle / treasury / facility / production）。抽出来的原因：
-- facility 行、ledger 行、audit 行这几个 shape 在四个探针里各写一遍，
-- SonarCloud 会把它们算成新代码重复（issue #377）。
--
-- 这里只放「纯构造」：不读写探针状态，不实现任何 SQL 语义。探针的判据
-- （守卫 / affectedRows / CAS）仍各自留在对应 fixture 里。

function __industryCopy(row)
    local out = {}
    for key, value in pairs(row) do out[key] = value end
    return out
end

function __industryDemandKey(cycleNo, phase, item)
    return tostring(cycleNo) .. '\0' .. tostring(phase) .. '\0' .. tostring(item)
end

---@param orgId string
---@param values table|nil
function __industryFacilityRow(orgId, values)
    values = values or {}
    return {
        org_id = orgId,
        facility_type = values.facility_type or 'mine',
        level = values.level or 1,
        workstations = values.workstations or 0,
        recipe_id = values.recipe_id,
        stock = values.stock or 0,
        produced_units = values.produced_units or 0,
        last_tick_epoch = values.last_tick_epoch or 0,
    }
end

function __industryLedgerRow(id, orgId, delta, balanceAfter, reason, ref)
    return {
        id = id,
        org_id = orgId,
        delta = delta,
        balance_after = balanceAfter,
        reason = reason,
        ref = ref,
    }
end

--- `industry_audit` 的两种参数形状：带 actor（4 个）与不带 actor（3 个）。
function __industryAuditEntry(values)
    if #values == 4 then
        return {
            org_id = values[1], actor_cid = values[2], action = values[3], payload = values[4],
        }
    end
    return {
        org_id = values[1], actor_cid = nil, action = values[2], payload = values[3],
    }
end
