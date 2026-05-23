-- =============================================================================
-- PropertyDumper — main.lua
-- Dumps PersonalInventoryComponent properties across the full class hierarchy.
-- Uses GetFullName() which is the confirmed working method for FProperty names.
-- =============================================================================

local function log(msg)
    print("[PropertyDumper] " .. msg .. "\n")
end

log("Loaded. Enumerating UFunctions on FarmSlotComponent...")

local dumped = false

NotifyOnNewObject("/Script/Dominion.FarmSlotComponent", function(_)
    if dumped then return end

    ExecuteInGameThread(function()
        if dumped then return end
        dumped = true

        local ok_cls, cls = pcall(StaticFindObject, "/Script/Dominion.FarmSlotComponent")
        if not ok_cls or not cls or not cls:IsValid() then
            log("Could not find FarmSlotComponent class.")
            return
        end

        log("============================================")
        log("UFunctions on FarmSlotComponent (own class only):")

        -- Attempt 1: ForEachFunction (mirrors ForEachProperty)
        local count = 0
        local ok_fef, err_fef = pcall(function()
            cls:ForEachFunction(function(fn)
                local ok_n, n = pcall(function() return fn:GetFName():ToString() end)
                log("  " .. (ok_n and n or "?"))
                count = count + 1
            end)
        end)
        if ok_fef then
            log("ForEachFunction: " .. count .. " functions found.")
        else
            log("ForEachFunction not available: " .. tostring(err_fef))

            -- Attempt 2: iterate Children linked list via GetFirstOwnedFunction
            local ok_ff, first = pcall(function() return cls:GetFirstOwnedFunction() end)
            if ok_ff and first and first:IsValid() then
                log("GetFirstOwnedFunction: walking linked list...")
                local fn = first
                local depth = 0
                while fn and depth < 200 do
                    local ok_n, n = pcall(function() return fn:GetFName():ToString() end)
                    log("  " .. (ok_n and n or "?"))
                    local ok_nx, nx = pcall(function() return fn:GetNextFunction() end)
                    if not ok_nx or not nx or not nx:IsValid() then break end
                    fn = nx
                    depth = depth + 1
                end
            else
                log("GetFirstOwnedFunction not available: " .. tostring(first))
            end
        end

        log("============================================")
        log("Done. You can disable this mod now.")
    end)
end)
