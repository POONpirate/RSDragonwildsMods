-- =============================================================================
-- PersonalInventoryMod — main.lua
-- Hooks the Eye of Oculus spell to open a second personal inventory (40 slots).
-- The regular bank/Personal Chest is left completely untouched.
-- Item data persists in a per-character JSON file so it survives mod removal.
-- JSON is written whenever the game itself saves, keeping mod data in sync with
-- the game's own save state.
-- =============================================================================

local json = require("json")

-- -----------------------------------------------------------------------------
-- Config
-- -----------------------------------------------------------------------------

local MOD_NAME         = "PersonalInventoryMod"
local SECOND_INV_SLOTS = 40

local SPELL_HOOK = "/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded"

local GAME_SAVE_HOOKS = {
    "/Script/Dominion.DominionPlayerController:ServerSaveCharacter",
    "/Script/Dominion.DominionPlayerController:SaveCharacter",
    "/Script/Dominion.DominionPlayerController:SaveGame",
    "/Script/Dominion.DominionGameMode:SaveGame",
    "/Script/Dominion.DominionGameMode:AutoSave",
    "/Script/Dominion.DominionGameMode:SaveWorld",
    "/Script/Engine.GameplayStatics:SaveGameToSlot",
}

-- Confirmed format (observed from real InventoryComponent instances).
-- MaxSlotIndex:39 = "slots 0-39 exist" → UI renders 40 slots.
-- MaxSlotIndex:-1 only rendered 1 slot (just enough for the first item in ItemSlots).
-- Item content comes from ItemSlots (in-memory), NOT from this string — so setting
-- this before every OpenPersonalInventory gives us 40 slots without wiping items.
local SLOT_LAYOUT_JSON = '{"Version":67,"MaxSlotIndex":' .. (SECOND_INV_SLOTS - 1) .. ',"AllowAdds":false}'

-- 40-slot empty inventory JSON.  Used ONCE at component construction: setting this as
-- JsonInventory then firing OnInventoryLoadedFromSave:Broadcast() causes the engine to
-- parse the 40 explicit slot entries and pre-populate ItemSlots with 40 empty FItemSlot
-- structs.  Without this, ItemSlots starts at size 0 and only grows one entry per manual
-- drag, making all other slots unusable.
-- Excluded from save checks just like SLOT_LAYOUT_JSON.
local EMPTY_GUID = "00000000000000000000000000000000"
local function _build_empty_inv_json(n)
    local t = { '{"Version":67' }
    for i = 0, n - 1 do
        t[#t + 1] = string.format(',"%d":{"GUID":"%s","ItemData":"","Count":0}', i, EMPTY_GUID)
    end
    t[#t + 1] = string.format(',"MaxSlotIndex":%d,"AllowAdds":false}', n - 1)
    return table.concat(t)
end
local EMPTY_INV_JSON = _build_empty_inv_json(SECOND_INV_SLOTS)

local SAVE_DIR = nil

-- -----------------------------------------------------------------------------
-- Runtime state
-- -----------------------------------------------------------------------------
-- All tables are keyed by GUID (stable string), NOT by ctrl (Lua proxy object).
-- FindAllOf returns a new Lua proxy object each call even for the same underlying
-- UObject, so using ctrl as a table key always misses on subsequent casts.

local SecondInventories  = {}  -- guid → PersonalInventoryComponent
local ControllersByGuid  = {}  -- guid → ctrl  (kept for open/save calls)
local CachedInventoryJson = {} -- guid → json string (captured from component between casts)
local LoadedFromDisk     = {}  -- guid → true once disk save has been restored this session

-- -----------------------------------------------------------------------------
-- Logging helpers
-- -----------------------------------------------------------------------------

local function log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

local function log_err(msg)
    print(string.format("[%s] ERROR: %s\n", MOD_NAME, msg))
end

-- -----------------------------------------------------------------------------
-- Save directory resolution
-- -----------------------------------------------------------------------------

local function get_save_dir()
    if SAVE_DIR then return SAVE_DIR end
    SAVE_DIR = "ue4ss/Mods/" .. MOD_NAME .. "/"
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
        log("No save file found for GUID " .. guid .. ".")
        return nil
    end
    local content = file:read("*a")
    file:close()
    if content == "" then return nil end
    log("Loaded saved inventory for GUID " .. guid)
    return content
end

local function save_inventory_data(guid, inv_comp, fallback_json)
    if not inv_comp or not inv_comp:IsValid() then return end

    local path = json_path(guid)
    local file = io.open(path, "w")
    if not file then
        log_err("Could not open save file for writing: " .. path)
        return
    end

    local ok_json, json_str = pcall(function()
        return inv_comp:GetPropertyValue("JsonInventory"):ToString()
    end)

    if ok_json and json_str and json_str ~= "" and json_str ~= SLOT_LAYOUT_JSON and json_str ~= EMPTY_INV_JSON then
        file:write(json_str)
        file:close()
        log("Saved inventory (live) for GUID " .. guid)
        return
    end

    if fallback_json and fallback_json ~= "" and fallback_json ~= SLOT_LAYOUT_JSON and fallback_json ~= EMPTY_INV_JSON then
        file:write(fallback_json)
        file:close()
        log("Saved inventory (cached) for GUID " .. guid)
        return
    end

    file:close()
    log("Inventory is empty — nothing written for GUID " .. guid)
end

local function save_all_inventories()
    local count = 0
    for guid, inv in pairs(SecondInventories) do
        if inv:IsValid() then
            save_inventory_data(guid, inv, CachedInventoryJson[guid])
            count = count + 1
        end
    end
    if count > 0 then
        log("Game save — wrote " .. count .. " second inventor" .. (count == 1 and "y." or "ies."))
    end
end

-- -----------------------------------------------------------------------------
-- Inventory population
-- -----------------------------------------------------------------------------

local function populate_inventory(inv_comp, data)
    if not data or data == "" then return end
    local ok, err = pcall(function()
        inv_comp:SetPropertyValue("JsonInventory", data)
    end)
    if ok then
        log("Set JsonInventory on component.")
        pcall(function() inv_comp.OnInventoryLoadedFromSave:Broadcast() end)
    else
        log_err("Failed to set JsonInventory: " .. tostring(err))
    end
end

-- -----------------------------------------------------------------------------
-- Second inventory component construction
-- -----------------------------------------------------------------------------

local function get_or_create_second_inventory(guid, ctrl)
    -- Check existing Lua reference first.
    if SecondInventories[guid] and SecondInventories[guid]:IsValid() then
        log("Reusing existing second inventory component.")
        return SecondInventories[guid]
    end

    -- Lua reference may be stale even if the UObject is still alive (GC hasn't
    -- collected it because ctrl is still its outer). Search by component name.
    local ok_fa, all_pics = pcall(function() return FindAllOf("PersonalInventoryComponent") end)
    if ok_fa and all_pics then
        for _, pic in ipairs(all_pics) do
            if pic:IsValid() then
                local ok_nm, nm = pcall(function() return pic:GetName() end)
                if ok_nm and nm and nm:find("SecondPersonalInventory") then
                    log("Re-found SecondPersonalInventory by name — storing reference.")
                    SecondInventories[guid] = pic
                    return pic
                end
            end
        end
    end

    -- Construct a new component.
    local ok, second_inv = pcall(function()
        return StaticConstructObject(
            StaticFindObject("/Script/Dominion.PersonalInventoryComponent"),
            ctrl,
            FName("SecondPersonalInventory")
        )
    end)

    if not ok or not second_inv or not second_inv:IsValid() then
        log_err("StaticConstructObject failed: " .. tostring(second_inv))
        return nil
    end

    local ok2, err2 = pcall(function()
        second_inv:SetPropertyValue("MaxSlotCount", SECOND_INV_SLOTS)
    end)
    if not ok2 then
        log_err("Failed to set MaxSlotCount: " .. tostring(err2))
    else
        log("Second inventory constructed with " .. SECOND_INV_SLOTS .. " slots.")
    end

    -- Pre-allocate the ItemSlots TArray to SECOND_INV_SLOTS entries.
    -- Without this, the array starts at size 0. The first drag creates entry 0;
    -- all other visual slots are ghost slots that silently reject items.
    -- RegisterComponent/InitializeComponent/BeginPlay all fail as UFunctions in
    -- this UE4SS build ("UObject instance is nullptr"), so we try several paths.

    -- Attempt 1: ReceiveBeginPlay — the BlueprintImplementableEvent version of
    -- BeginPlay IS a UFUNCTION. If PersonalInventoryComponent has BP logic in its
    -- BeginPlay that calls ItemSlots.SetNum(MaxSlotCount), this will trigger it.
    local ok_rbp = pcall(function() second_inv:ReceiveBeginPlay() end)
    if ok_rbp then
        log("ReceiveBeginPlay() succeeded — ItemSlots should be pre-allocated.")
    else
        -- Attempt 2: SetPropertyValue("ItemSlots", ...) with an array of 40 empty
        -- tables. UE4SS may default-initialize each FItemSlot struct from the empty
        -- table, giving us 40 pre-allocated (empty) slot entries.
        local ok_pre = pcall(function()
            local slots = {}
            for i = 1, SECOND_INV_SLOTS do slots[i] = {} end
            second_inv:SetPropertyValue("ItemSlots", slots)
        end)
        if ok_pre then
            log("ItemSlots pre-allocated via SetPropertyValue (40 empty entries).")
        else
            -- Attempt 3: game-specific named functions.
            local named_fns = {
                { "InitInventory",       function() second_inv:InitInventory(SECOND_INV_SLOTS) end },
                { "InitializeInventory", function() second_inv:InitializeInventory(SECOND_INV_SLOTS) end },
                { "SetNumSlots",         function() second_inv:SetNumSlots(SECOND_INV_SLOTS) end },
                { "ResizeInventory",     function() second_inv:ResizeInventory(SECOND_INV_SLOTS) end },
                { "EnsureSlotCount",     function() second_inv:EnsureSlotCount(SECOND_INV_SLOTS) end },
                { "AddSlots",            function() second_inv:AddSlots(SECOND_INV_SLOTS) end },
                { "SetInventorySize",    function() second_inv:SetInventorySize(SECOND_INV_SLOTS) end },
            }
            local any_ok = false
            for _, entry in ipairs(named_fns) do
                local ok_fn = pcall(entry[2])
                if ok_fn then
                    log("Slot pre-alloc via " .. entry[1] .. "() succeeded!")
                    any_ok = true
                    break
                end
            end
            if not any_ok then
                log_err("All slot pre-alloc attempts failed. Only 1 slot will be usable until this is resolved.")
            end
        end
    end

    -- Diagnostic: read ItemSlots back to see what state the TArray is in.
    -- GetPropertyValue returns a TArray as userdata (not a Lua table), so #slots_val
    -- won't work — try the TArray:Num() method instead.
    local ok_diag, slots_val = pcall(function()
        return second_inv:GetPropertyValue("ItemSlots")
    end)
    if ok_diag and slots_val ~= nil then
        local slots_type = type(slots_val)
        local slots_count
        if slots_type == "table" then
            slots_count = tostring(#slots_val)
        else
            local ok_num, num = pcall(function() return slots_val:Num() end)
            slots_count = ok_num and tostring(num) or "? (Num() unavailable)"
        end
        log("ItemSlots after pre-alloc: type=" .. slots_type .. " count=" .. slots_count)
    else
        log("ItemSlots diagnostic: read failed or returned nil.")
    end

    -- Seed with empty 40-slot JSON and broadcast OnInventoryLoadedFromSave so the engine
    -- parses the 40 slot entries and pre-populates ItemSlots with 40 empty FItemSlot structs.
    -- This runs only here (fresh construction), never on reuse, so live items are never wiped.
    populate_inventory(second_inv, EMPTY_INV_JSON)
    log("Seeded empty 40-slot JSON — engine should pre-allocate ItemSlots via Broadcast().")

    -- Confirm ItemSlots count after seeding.
    local ok_diag2, slots_val2 = pcall(function()
        return second_inv:GetPropertyValue("ItemSlots")
    end)
    if ok_diag2 and slots_val2 ~= nil then
        local slots_type2 = type(slots_val2)
        local slots_count2
        if slots_type2 == "table" then
            slots_count2 = tostring(#slots_val2)
        else
            local ok_n2, n2 = pcall(function() return slots_val2:Num() end)
            slots_count2 = ok_n2 and tostring(n2) or "? (Num() unavailable)"
        end
        log("ItemSlots after seed: type=" .. slots_type2 .. " count=" .. slots_count2)
    end

    SecondInventories[guid] = second_inv
    return second_inv
end

-- -----------------------------------------------------------------------------
-- UI open logic
-- -----------------------------------------------------------------------------

local function open_second_inventory_ui(ctrl, second_inv, char_obj)
    local ok, err = pcall(function()
        second_inv:OpenPersonalInventory(34, char_obj)
    end)
    if ok then
        log("Second inventory UI opened (p1=34).")
    else
        log_err("OpenPersonalInventory(34) failed: " .. tostring(err))
        local ok2, err2 = pcall(function()
            second_inv:OpenPersonalInventory(ctrl, char_obj)
        end)
        if ok2 then
            log("OpenPersonalInventory fallback (p1=ctrl) succeeded.")
        else
            log_err("OpenPersonalInventory fallback also failed: " .. tostring(err2))
        end
    end
end

-- -----------------------------------------------------------------------------
-- Game-save hooks
-- -----------------------------------------------------------------------------

log("Registering game-save hooks...")
for _, hook_path in ipairs(GAME_SAVE_HOOKS) do
    local ok = pcall(function()
        RegisterHook(hook_path,
            function() end,
            function() ExecuteInGameThread(save_all_inventories) end
        )
    end)
    if ok then log("Save hook registered: " .. hook_path) end
end

-- -----------------------------------------------------------------------------
-- Eye of Oculus hook
-- -----------------------------------------------------------------------------

log("Waiting for player controller to register Eye of Oculus hook...")

local hook_registered = false

NotifyOnNewObject("/Script/Dominion.DominionPlayerController", function(_)
    if hook_registered then return end

    ExecuteInGameThread(function()
        if hook_registered then return end

        log("Player controller ready — registering hooks...")

        local ok_oa = pcall(function()
            RegisterHook("/Script/Dominion.OculusComponent:ActivateOculus",
                function(self) end,
                function(self)
                    local ok_get, comp = pcall(function() return self:get() end)
                    if not ok_get or not comp then return end
                    local ok_d, err_d = pcall(function() comp:DeactivateOculus() end)
                    if ok_d then
                        log("Build menu closed via DeactivateOculus.")
                    else
                        log_err("DeactivateOculus failed: " .. tostring(err_d))
                    end
                end
            )
        end)
        if ok_oa then log("OculusComponent:ActivateOculus hook registered.")
        else log_err("Could not hook ActivateOculus.") end

        local reg_ok, reg_err = pcall(function()
            RegisterHook(SPELL_HOOK,
                function(self, Instance)
                    ExecuteInGameThread(function()
                        log("Eye of Oculus cast — finding local player controller...")

                        local all_ctrls = FindAllOf("DominionPlayerController")
                        if not all_ctrls or #all_ctrls == 0 then
                            log_err("FindAllOf returned no DominionPlayerController instances.")
                            return
                        end

                        local ctrl = nil
                        for _, c in ipairs(all_ctrls) do
                            if c:IsValid() then
                                local ok_local, is_local = pcall(function() return c:IsLocalController() end)
                                if ok_local and is_local then ctrl = c break end
                            end
                        end
                        if not ctrl then
                            for _, c in ipairs(all_ctrls) do
                                if c:IsValid() then ctrl = c break end
                            end
                        end
                        if not ctrl then
                            log_err("No valid DominionPlayerController found.")
                            return
                        end

                        -- Resolve GUID.
                        local ok_guid, guid_struct = pcall(function() return ctrl:GetCharacterGuid() end)
                        if not ok_guid or not guid_struct then
                            log_err("GetCharacterGuid failed: " .. tostring(guid_struct))
                            return
                        end
                        local ig = guid_struct.InnerGuid
                        local guid
                        if type(ig) == "string" then
                            guid = ig
                        else
                            local ok_ts, ts = pcall(function() return ig:ToString() end)
                            if ok_ts and ts and ts ~= "" then
                                guid = ts
                            else
                                guid = string.format("%08X%08X%08X%08X",
                                    ig.A or 0, ig.B or 0, ig.C or 0, ig.D or 0)
                            end
                        end
                        if not guid or guid == "" then
                            log_err("Could not resolve GUID.")
                            return
                        end
                        log("Controller found, GUID=" .. guid)
                        ControllersByGuid[guid] = ctrl

                        local char_obj = nil
                        local ok_ch, chars = pcall(function() return FindAllOf("DominionPlayerCharacter") end)
                        if ok_ch and chars then
                            for _, ch in ipairs(chars) do
                                if ch:IsValid() then char_obj = ch break end
                            end
                        end
                        if not char_obj then
                            log_err("Could not find DominionPlayerCharacter — UI may not open.")
                        end

                        local second_inv = get_or_create_second_inventory(guid, ctrl)
                        if not second_inv then return end

                        -- JsonInventory controls grid layout (how many slots the UI renders).
                        -- ItemSlots holds actual item data and persists in-memory on the
                        -- component between casts. The engine does NOT update JsonInventory
                        -- when items are dragged in — only during game serialization/save.
                        --
                        -- On the very first open after loading (disk save exists), we restore
                        -- by calling populate_inventory, which sets JsonInventory and fires
                        -- OnInventoryLoadedFromSave:Broadcast() so the engine rebuilds ItemSlots.
                        -- LoadedFromDisk prevents re-loading on subsequent casts, which would
                        -- overwrite any items moved since the last restore.
                        --
                        -- When there is no disk save (or already restored), we only update
                        -- JsonInventory via SetPropertyValue (no broadcast) to keep the 40-slot
                        -- grid visible without touching the live ItemSlots array.

                        local saved = (not LoadedFromDisk[guid]) and load_inventory_data(guid)
                        if saved then
                            populate_inventory(second_inv, saved)
                            LoadedFromDisk[guid] = true
                            log("Restored from disk save.")
                        else
                            -- ItemSlots is already pre-allocated from construction seed.
                            -- Just refresh JsonInventory string so UI stays at 40 slots.
                            local ok_layout = pcall(function()
                                second_inv:SetPropertyValue("JsonInventory", SLOT_LAYOUT_JSON)
                            end)
                            if ok_layout then
                                log("Refreshed layout JSON (40 slots, ItemSlots untouched).")
                            end
                        end

                        open_second_inventory_ui(ctrl, second_inv, char_obj)
                    end)
                end,

                function(self, Instance) end
            )
        end)

        if not reg_ok then
            log_err("Failed to register Eye of Oculus hook: " .. tostring(reg_err))
        else
            hook_registered = true
            log("All hooks registered. Waiting for Eye of Oculus cast.")
        end
    end)
end)
