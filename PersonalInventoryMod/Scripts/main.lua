-- =============================================================================
-- PersonalInventoryMod — main.lua
-- Hooks the Bones to Peaches spell to open a second personal inventory (40 slots).
-- The regular bank/Personal Chest is left completely untouched.
-- Item data persists in a per-character JSON file so it survives mod removal.
-- =============================================================================

local json = require("json")

-- -----------------------------------------------------------------------------
-- Config
-- -----------------------------------------------------------------------------

local MOD_NAME       = "PersonalInventoryMod"
local SECOND_INV_SLOTS = 40

-- Hook path derived from USD_EyeOfOculus.uasset.
-- Eye of Oculus is GE-based: SpellModule_GameplayEffect fires GE_PerkV2_Construction_Oculus_C
-- at ESpellStateTrigger::FinishedCasting. We hook OnGameplayEffectAdded on the GE class.
-- 'instance' in the hook is the GE spec; get the controller via instance:GetInstigator():GetController().
local SPELL_HOOK = "/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded"

-- JSON save files are written to the game's Saved/ directory, one file per character GUID.
-- UE4SS exposes the project directory via GetKismetSystemLibrary or a known relative path.
-- TODO: Confirm the writable save path available in UE4SS on this game.
--       Fallback: use a path relative to the UE4SS Mods folder.
local SAVE_DIR = nil  -- resolved at runtime in get_save_dir()

-- -----------------------------------------------------------------------------
-- Runtime state
-- -----------------------------------------------------------------------------

-- Keyed by DominionPlayerController instance; stores the constructed second
-- PersonalInventoryComponent for each active player this session.
local SecondInventories = {}

-- -----------------------------------------------------------------------------
-- Logging helpers
-- -----------------------------------------------------------------------------

local function log(msg)
    print(string.format("[%s] %s", MOD_NAME, msg))
end

local function log_err(msg)
    print(string.format("[%s] ERROR: %s", MOD_NAME, msg))
end

-- -----------------------------------------------------------------------------
-- Save directory resolution
-- -----------------------------------------------------------------------------

local function get_save_dir()
    if SAVE_DIR then return SAVE_DIR end

    -- TODO: Replace this with the actual UE4SS method for getting a writable path.
    --       Options to investigate at runtime:
    --         1. UEHelpers.GetGameStateBase():GetPathName() for a game-relative path
    --         2. A known relative path like "../../Saved/PersonalInventoryMod/"
    --         3. UE4SS's own mod directory if it exposes __DIR__
    --
    -- Placeholder: uses a path relative to the executable that typically resolves
    -- to <GameRoot>/RSDragonwilds/Saved/PersonalInventoryMod/
    SAVE_DIR = "../../Saved/" .. MOD_NAME .. "/"
    log("Save directory set to: " .. SAVE_DIR)
    return SAVE_DIR
end

local function json_path(guid)
    return get_save_dir() .. MOD_NAME .. "_" .. guid .. ".json"
end

-- -----------------------------------------------------------------------------
-- JSON persistence
-- -----------------------------------------------------------------------------

local function load_inventory_data(guid)
    local path = json_path(guid)
    local file = io.open(path, "r")
    if not file then
        log("No save file found for GUID " .. guid .. ", starting empty.")
        return {}
    end
    local content = file:read("*a")
    file:close()

    if content == "" then return {} end

    -- If the file looks like a raw engine JsonInventory string (starts with "{" or "["),
    -- return it as-is so populate_inventory can write it straight back via SetPropertyValue.
    -- Otherwise decode it as our manual slot table format.
    local first_char = content:sub(1, 1)
    if first_char == "{" then
        -- Raw engine JSON object — pass the string directly to populate_inventory
        log("Loaded raw JsonInventory string for GUID " .. guid)
        return content
    end

    local ok, data = pcall(json.decode, content)
    if not ok or type(data) ~= "table" then
        log_err("Failed to parse save file for GUID " .. guid .. ": " .. tostring(data))
        return {}
    end

    log("Loaded " .. #data .. " slot(s) for GUID " .. guid)
    return data
end

local function save_inventory_data(guid, inv_comp)
    if not inv_comp or not inv_comp:IsValid() then return end

    local path = json_path(guid)
    local file = io.open(path, "w")
    if not file then
        log_err("Could not open save file for writing: " .. path)
        return
    end

    -- Read JsonInventory using confirmed method: GetPropertyValue():ToString()
    local ok_json, json_str = pcall(function()
        return inv_comp:GetPropertyValue("JsonInventory"):ToString()
    end)
    if ok_json and json_str and json_str ~= "" then
        file:write(json_str)
        file:close()
        log("Saved inventory via JsonInventory for GUID " .. guid)
        return
    end

    file:close()
    log_err("JsonInventory was empty or unreadable for GUID " .. guid .. " — nothing saved.")
end

-- -----------------------------------------------------------------------------
-- Inventory population
-- -----------------------------------------------------------------------------

local function populate_inventory(inv_comp, data)
    if not data or (type(data) == "table" and #data == 0) then return end

    -- data is a plain Lua string saved from JsonInventory:ToString() — write it back directly.
    if type(data) == "string" and data ~= "" then
        local ok, err = pcall(function()
            inv_comp:SetPropertyValue("JsonInventory", data)
        end)
        if ok then
            log("Populated second inventory via JsonInventory string.")
            -- Fire OnInventoryLoadedFromSave if available so the UI refreshes correctly.
            pcall(function()
                inv_comp.OnInventoryLoadedFromSave:Broadcast()
            end)
        else
            log_err("Failed to set JsonInventory: " .. tostring(err))
        end
        return
    end

    -- Approach B: write ItemSlots array back manually.
    -- TODO: Confirm slot layout matches what the engine expects before relying on this.
    local ok, err = pcall(function()
        inv_comp:SetPropertyValue("ItemSlots", data)
    end)
    if not ok then
        log_err("Failed to populate ItemSlots: " .. tostring(err))
    else
        log("Populated second inventory with " .. #data .. " slot(s) via ItemSlots.")
    end
end

-- -----------------------------------------------------------------------------
-- Second inventory component construction
-- -----------------------------------------------------------------------------

local function get_or_create_second_inventory(ctrl)
    if SecondInventories[ctrl] and SecondInventories[ctrl]:IsValid() then
        return SecondInventories[ctrl]
    end

    -- Construct a new PersonalInventoryComponent and attach it to the controller.
    -- TODO: Validate that StaticConstructObject works for BP components in this game.
    --       If it does not, investigate:
    --         1. Using a pre-existing but unused component slot on DominionPlayerController
    --         2. RegisterCustomProperty as an alternative construction path
    local ok, second_inv = pcall(function()
        return StaticConstructObject(
            StaticFindObject("/Script/Dominion.PersonalInventoryComponent"),
            ctrl,
            FName("SecondPersonalInventory")
        )
    end)

    if not ok or not second_inv or not second_inv:IsValid() then
        log_err("StaticConstructObject failed for PersonalInventoryComponent: " .. tostring(second_inv))
        log_err("The mod cannot open a second inventory until this is resolved.")
        log_err("See design doc Open Questions #3 for alternatives.")
        return nil
    end

    -- Set slot count to 40
    local ok2, err2 = pcall(function()
        second_inv:SetPropertyValue("MaxSlotCount", SECOND_INV_SLOTS)
    end)
    if not ok2 then
        log_err("Failed to set MaxSlotCount to " .. SECOND_INV_SLOTS .. ": " .. tostring(err2))
    else
        log("Second inventory constructed with " .. SECOND_INV_SLOTS .. " slots.")
    end

    SecondInventories[ctrl] = second_inv

    -- Hook OnPersonalInventoryClosed — confirmed MulticastInlineDelegateProperty on
    -- PersonalInventoryComponent. Fires when the inventory UI closes, which is the
    -- right point to serialize (better than per-change — avoids thrashing the file).
    local guid_struct = ctrl:GetCharacterGuid()
    local guid = guid_struct and guid_struct.InnerGuid or "unknown"
    local hook_ok, hook_err = pcall(function()
        second_inv.OnPersonalInventoryClosed:Add(function()
            ExecuteInGameThread(function()
                if second_inv:IsValid() then
                    save_inventory_data(guid, second_inv)
                end
            end)
        end)
    end)
    if not hook_ok then
        log_err("Could not hook OnPersonalInventoryClosed: " .. tostring(hook_err))
        log_err("Items will not auto-save on close until this is resolved.")
    else
        log("OnPersonalInventoryClosed hook registered for GUID " .. guid)
    end

    return second_inv
end

-- -----------------------------------------------------------------------------
-- UI open logic
-- -----------------------------------------------------------------------------

local function open_second_inventory_ui(ctrl, second_inv)
    -- Option A: Temporarily redirect GetPersonalInventory to return second_inv,
    -- then fire the AccessPersonalChest GE to open the bank UI against it.
    --
    -- TODO: Validate that the bank UI reads from GetPersonalInventory at open time
    --       rather than holding a cached reference. If it caches at login, this
    --       approach will not work and Option C (custom widget) will be needed.
    --
    -- The hook below intercepts ONE call to GetPersonalInventory and swaps the
    -- return value to second_inv, then immediately unregisters itself.

    local hook_id = nil
    local hook_fired = false

    local pre_ok, pre_err = pcall(function()
        hook_id = RegisterHook("/Script/Dominion.DominionPlayerController:GetPersonalInventory",
            function(self)
                if self == ctrl and not hook_fired then
                    hook_fired = true
                    -- Unregister after first fire so normal bank use is unaffected
                    if hook_id then
                        UnregisterHook("/Script/Dominion.DominionPlayerController:GetPersonalInventory", hook_id)
                    end
                    return second_inv
                end
            end
        )
    end)

    if not pre_ok then
        log_err("Could not register GetPersonalInventory redirect: " .. tostring(pre_err))
        log_err("The second inventory UI will not open. See design doc Step 5.")
        return
    end

    -- Trigger the AccessPersonalChest GE to open the bank UI.
    -- TODO: Confirm the correct way to apply a GE via Lua in this game.
    --       Candidates:
    --         1. ctrl:GetAbilitySystemComponent():ApplyGameplayEffectToSelf(...)
    --         2. Calling OnGameplayEffectAdded directly on a constructed GE instance
    --       The call below is a placeholder; replace with the confirmed approach.
    local apply_ok, apply_err = pcall(function()
        local asc = ctrl:GetAbilitySystemComponent()
        if not asc or not asc:IsValid() then
            error("AbilitySystemComponent not found on controller")
        end
        local ge_class = StaticFindObject("/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_AccessPersonalChest.GE_PerkV2_Construction_AccessPersonalChest_C")
        asc:ApplyGameplayEffectToSelf(ge_class, 1, asc:MakeEffectContext())
    end)

    if not apply_ok then
        log_err("Failed to apply AccessPersonalChest GE: " .. tostring(apply_err))
        log_err("TODO: Confirm GE application method. See design doc Step 5.")
        -- Clean up the redirect hook so normal bank use is unaffected
        if hook_id and not hook_fired then
            pcall(function()
                UnregisterHook("/Script/Dominion.DominionPlayerController:GetPersonalInventory", hook_id)
            end)
        end
    end
end

-- -----------------------------------------------------------------------------
-- Eye of Oculus hook
-- -----------------------------------------------------------------------------

-- GE_PerkV2_Construction_Oculus_C is a Blueprint GE with DurationType::Infinite.
-- Its Blueprint class is not loaded at mod startup — only once the player is in-world
-- and the asset gets streamed in. We defer RegisterHook to NotifyOnNewObject so that
-- by the time we try to hook, the class is guaranteed to exist in memory.
--
-- 'self' in the pre-hook is the GE data CDO.
-- 'Instance' (capital I, per the asset) is the active DominionGameplayEffect.
-- Returning false suppresses the default Eye of Oculus effect entirely.

log("Waiting for player controller to register Eye of Oculus hook...")

local hook_registered = false

NotifyOnNewObject("/Script/Dominion.DominionPlayerController", function(_)
    if hook_registered then return end

    ExecuteInGameThread(function()
        if hook_registered then return end

        log("Player controller ready — registering Eye of Oculus hook...")
        log("Hook path: " .. SPELL_HOOK)

        local reg_ok, reg_err = pcall(function()
            RegisterHook(SPELL_HOOK,
                -- Pre-hook: fires before the GE applies.
                function(self, Instance)
                    ExecuteInGameThread(function()
                        log("Eye of Oculus cast — opening second inventory.")

                        local ok, ctrl = pcall(function()
                            return Instance:GetInstigator():GetController()
                        end)
                        if not ok or not ctrl or not ctrl:IsValid() then
                            log_err("Could not get DominionPlayerController from GE instance.")
                            return
                        end

                        local ok_guid, guid_struct = pcall(function()
                            return ctrl:GetCharacterGuid()
                        end)
                        if not ok_guid or not guid_struct then
                            log_err("Could not get character GUID from controller.")
                            return
                        end
                        local guid = guid_struct.InnerGuid
                        if not guid or guid == "" then
                            log_err("DomCharacterGuid.InnerGuid was empty.")
                            return
                        end

                        local second_inv = get_or_create_second_inventory(ctrl)
                        if not second_inv then return end

                        -- Preemptive save: capture any changes from the previous open
                        -- before we re-populate from disk.
                        if SecondInventories[ctrl] then
                            save_inventory_data(guid, second_inv)
                        end

                        local data = load_inventory_data(guid)
                        populate_inventory(second_inv, data)
                        open_second_inventory_ui(ctrl, second_inv)
                    end)

                    return false  -- suppress default Eye of Oculus effect
                end,

                function(self, Instance) end  -- post-hook unused
            )
        end)

        if not reg_ok then
            log_err("Failed to register Eye of Oculus hook: " .. tostring(reg_err))
        else
            hook_registered = true
            log("Hook registered. Waiting for Eye of Oculus cast.")
        end
    end)
end)
