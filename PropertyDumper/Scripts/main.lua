-- =============================================================================
-- PropertyDumper — main.lua
-- Dumps PersonalInventoryComponent properties across the full class hierarchy.
-- Uses GetFullName() which is the confirmed working method for FProperty names.
-- =============================================================================

local function log(msg)
    print("[PropertyDumper] " .. msg .. "\n")
end

log("Loaded. Waiting for PersonalInventoryComponent...")

local dumped = false

NotifyOnNewObject("/Script/Dominion.PersonalInventoryComponent", function(_)
    if dumped then return end

    ExecuteInGameThread(function()
        if dumped then return end

        local comps = FindAllOf("PersonalInventoryComponent")
        if not comps or #comps == 0 then
            log("No instances yet, retrying on next creation.")
            return
        end

        local comp = nil
        for _, c in ipairs(comps) do
            if c:IsValid() then comp = c break end
        end
        if not comp then return end

        dumped = true
        log("============================================")

        -- GetFullName() returns e.g. "ArrayProperty /Script/Foo.MyClass:MyItems"
        -- Split on ":" to get just the property name, and on " " for the type.
        local function prop_info(prop)
            local full = ""
            local ok, val = pcall(function() return prop:GetFullName() end)
            if ok and val then full = val end
            local ptype = full:match("^(%S+)") or "?"
            local pname = full:match(":(.+)$") or "?"
            return ptype, pname
        end

        local function dump_class(cls, label)
            if not cls then log("[" .. label .. "] nil") return end
            local ok, valid = pcall(function() return cls:IsValid() end)
            if not ok or not valid then log("[" .. label .. "] invalid") return end

            local count = 0
            local each_ok, each_err = pcall(function()
                cls:ForEachProperty(function(prop)
                    local ptype, pname = prop_info(prop)
                    log("  " .. ptype .. " | " .. pname)
                    count = count + 1
                end)
            end)
            if not each_ok then
                log("[" .. label .. "] ForEachProperty error: " .. tostring(each_err))
            end
            log("[" .. label .. "] " .. count .. " properties")
        end

        -- Walk the full class hierarchy from PersonalInventoryComponent upward
        log("--- Class hierarchy walk ---")
        local ok_start, current = pcall(StaticFindObject, "/Script/Dominion.PersonalInventoryComponent")
        if not ok_start or not current then
            log("Could not find starting class")
            return
        end

        local depth = 0
        while current and depth < 15 do
            local ok_name, full_name = pcall(function() return current:GetFullName() end)
            local label = ok_name and (full_name or "?") or "unknown"
            dump_class(current, label)

            local ok_super, super = pcall(function() return current:GetSuperStruct() end)
            if not ok_super or not super then
                log("GetSuperStruct failed at depth " .. depth)
                break
            end
            -- Check if we've hit the top
            local ok_sname, sname = pcall(function() return super:GetFullName() end)
            local ok_cname, cname = pcall(function() return current:GetFullName() end)
            if ok_sname and ok_cname and sname == cname then break end
            if ok_sname and sname and sname:find("Object$") then
                dump_class(super, sname)
                break
            end

            current = super
            depth = depth + 1
        end

        log("============================================")
        log("Done. You can disable this mod now.")
    end)
end)
