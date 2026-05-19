-- =============================================================================
-- ComponentTest — main.lua  (round 4)
-- Searching for hookable item manipulation functions on InventoryComponent
-- and session-end hooks we can use as a secondary save trigger.
-- =============================================================================

local function log(msg)
    print("[ComponentTest] " .. msg .. "\n")
end

log("Loaded.")

local tested = false

NotifyOnNewObject("/Script/Dominion.DominionPlayerController", function(_)
    if tested then return end

    ExecuteInGameThread(function()
        if tested then return end
        local ctrls = FindAllOf("DominionPlayerController")
        if not ctrls or #ctrls == 0 then return end
        local ctrl = nil
        for _, c in ipairs(ctrls) do if c:IsValid() then ctrl = c break end end
        if not ctrl then return end
        tested = true

        log("================================================")
        log("Testing RegisterHook candidates...")
        log("------------------------------------------------")

        local candidates = {
            -- Item manipulation on InventoryComponent
            "/Script/Dominion.InventoryComponent:AddItem",
            "/Script/Dominion.InventoryComponent:RemoveItem",
            "/Script/Dominion.InventoryComponent:MoveItem",
            "/Script/Dominion.InventoryComponent:SwapItems",
            "/Script/Dominion.InventoryComponent:SetItem",
            "/Script/Dominion.InventoryComponent:DropItem",
            "/Script/Dominion.InventoryComponent:UseItem",
            "/Script/Dominion.InventoryComponent:TransferItem",
            "/Script/Dominion.InventoryComponent:ClearItems",
            "/Script/Dominion.InventoryComponent:SortInventory",
            "/Script/Dominion.InventoryComponent:FillStacks",
            "/Script/Dominion.InventoryComponent:SetSlotItem",
            "/Script/Dominion.InventoryComponent:UpdateSlot",
            -- PersonalInventoryComponent specific
            "/Script/Dominion.PersonalInventoryComponent:OpenPersonalInventory",
            "/Script/Dominion.PersonalInventoryComponent:Open",
            -- Controller level
            "/Script/Dominion.DominionPlayerController:OpenPersonalInventory",
            -- Session end / level change
            "/Script/Engine.Actor:EndPlay",
            "/Script/Engine.GameModeBase:Logout",
            "/Script/Dominion.DominionPlayerController:EndPlay",
        }

        for _, path in ipairs(candidates) do
            local ok, err = pcall(function()
                local id = RegisterHook(path, function() end, function() end)
                UnregisterHook(path, id)
            end)
            log((ok and "  [OK]   " or "  [FAIL] ") .. path)
        end

        log("------------------------------------------------")
        log("Done.")
        log("================================================")
    end)
end)
