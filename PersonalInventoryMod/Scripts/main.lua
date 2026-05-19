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

-- Hook path confirmed from BP_PerkSpell_BonesToPeaches.uasset.
-- The spell is NOT GE-based — it extends UtilitySpell and fires ActivateGameplayEffects
-- when cast. The ItemTransmuteSpellComponent on the actor handles the bone conversion.
local B2P_HOOK = "/Game/Gameplay/UtilityMagic/PerkSpells/BonesToPeaches/BP_PerkSpell_BonesToPeaches.BP_PerkSpell_BonesToPeaches_C:ActivateGameplayEffects"

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
    -- The game has a built-in JsonInventory StrProperty on InventoryComponent.
    -- Try reading that first — if it's populated, it's the most reliable source
    -- since the engine itself serialized it. Fall back to reading ItemSlots manually.

    local path = json_path(guid)
    local file = io.open(path, "w")
    if not file then
        log_err("Could not open save file for writing: " .. path)
        log_err("Make sure the directory exists: " .. get_save_dir())
        return
    end

    -- Approach A: use the engine's own JsonInventory string
    local ok_json, json_str = pcall(function()
        return inv_comp:GetPropertyValue("JsonInventory")
    end)
    if ok_json and json_str and json_str ~= "" then
        file:write(json_str)
        file:close()
        log("Saved inventory via JsonInventory for GUID " .. guid)
        return
    end

    -- Approach B: read ItemSlots array manually
    -- ItemSlots is the confirmed ArrayProperty on InventoryComponent.
    -- Slot entry property names (Quantity, ItemData path) need runtime confirmation.
    local ok_slots, slots = pcall(function()
        return inv_comp:GetPropertyValue("ItemSlots")
    end)
    if not ok_slots or not slots then
        log_err("Could not read ItemSlots for GUID " .. guid)
        file:close()
        return
    end

    local data = {}
    for i = 1, #slots do
        local slot = slots[i]
        -- TODO: Confirm slot entry property names via PropertyDumper on an ItemSlots element.
        --       Likely candidates for item reference: ItemData, ItemDef, ItemClass
        --       Likely candidates for count: Quantity, Count, StackCount
        table.insert(data, {
            itemData  = tostring(slot.ItemData  or slot.ItemDef or ""),
            quantity  = slot.Quantity or slot.Count or 0,
            slotIndex = i,
        })
    end

    file:write(json.encode(data))
    file:close()
    log("Saved " .. #data .. " slot(s) via ItemSlots for GUID " .. guid)
end

-- -----------------------------------------------------------------------------
-- Inventory population
-- -----------------------------------------------------------------------------

local function populate_inventory(inv_comp, data)
    if not data or (type(data) == "table" and #data == 0) then return end

    -- Approach A: if data is a string, it came from JsonInventory — write it back directly.
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
-- Bones to Peaches hook
-- -----------------------------------------------------------------------------

-- The spell is BP_PerkSpell_BonesToPeaches_C, a UtilitySpell actor.
-- ActivateGameplayEffects is the Blueprint event that triggers when the spell fires.
-- 'self' in the hook is the spell actor instance.
-- Returning false from the pre-hook suppresses the ActivateGameplayEffects event,
-- which prevents the ItemTransmuteSpellComponent from running the bone conversion.

log("Registering Bones to Peaches hook...")
log("Hook path: " .. B2P_HOOK)

local reg_ok, reg_err = pcall(function()
    RegisterHook(B2P_HOOK,
        -- Pre-hook: fires before ActivateGameplayEffects runs. Return false to suppress
        -- the bone-to-peach conversion entirely.
        function(self)
            ExecuteInGameThread(function()
                log("Bones to Peaches cast — opening second inventory.")

                -- self is the BP_PerkSpell_BonesToPeaches_C spell actor.
                -- Get the instigator (player pawn) then their controller.
                local ok, ctrl = pcall(function()
                    return self:GetInstigator():GetController()
                end)
                if not ok or not ctrl or not ctrl:IsValid() then
                    log_err("Could not get DominionPlayerController from spell actor.")
                    return
                end

                -- Get the character GUID for JSON keying.
                -- GetCharacterGuid() returns a DomCharacterGuid struct, not a plain string.
                -- We read its InnerGuid field to get a stable string for the filename.
                local ok_guid, guid_struct = pcall(function()
                    return ctrl:GetCharacterGuid()
                end)
                if not ok_guid or not guid_struct then
                    log_err("Could not get character GUID from controller.")
                    return
                end
                local guid = guid_struct.InnerGuid
                if not guid or guid == "" then
                    log_err("DomCharacterGuid.InnerGuid was empty — cannot key save file.")
                    return
                end

                -- Get or construct the second inventory component
                local second_inv = get_or_create_second_inventory(ctrl)
                if not second_inv then return end

                -- Load saved items and populate the component
                local data = load_inventory_data(guid)
                populate_inventory(second_inv, data)

                -- Open the bank UI pointed at the second inventory
                open_second_inventory_ui(ctrl, second_inv)
            end)

            -- Return false to suppress the default bones-to-peaches conversion
            return false
        end,

        -- Post-hook (unused for now)
        function(self) end
    )
end)

if not reg_ok then
    log_err("Failed to register B2P hook: " .. tostring(reg_err))
else
    log("Hook registered. Waiting for Bones to Peaches cast.")
end
