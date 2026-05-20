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

-- Game-save hook candidates. Whichever the game calls will trigger save_all_inventories().
local GAME_SAVE_HOOKS = {
    "/Script/Dominion.DominionPlayerController:ServerSaveCharacter",
    "/Script/Dominion.DominionPlayerController:SaveCharacter",
    "/Script/Dominion.DominionPlayerController:SaveGame",
    "/Script/Dominion.DominionGameMode:SaveGame",
    "/Script/Dominion.DominionGameMode:AutoSave",
    "/Script/Dominion.DominionGameMode:SaveWorld",
    "/Script/Engine.GameplayStatics:SaveGameToSlot",
}

-- Candidate paths for the close function. "InventoryComponent" is the confirmed
-- base class (141 instances found); "PersonalInventoryComponent" is our specific
-- class. We try both — whichever is hookable will fire.
local CLOSE_HOOK_PATHS = {
    "/Script/Dominion.PersonalInventoryComponent:ClosePersonalInventory",
    "/Script/Dominion.InventoryComponent:ClosePersonalInventory",
}

-- Observed JsonInventory format (from InventoryComponent [4],[5] in diagnostic):
-- { "Version": 67, "0": {"GUID":"...","ItemData":"...","Count":N}, ...,
--   "MaxSlotIndex": N, "AllowAdds": false }
--
-- Empty seed passed to OpenPersonalInventory so the engine creates the slot array
-- and ctrl+click works on the first open. MaxSlotIndex:-1 = no items, just structure.
local EMPTY_INV_JSON = '{"Version":67,"MaxSlotIndex":-1,"AllowAdds":false}'

local SAVE_DIR = nil

-- -----------------------------------------------------------------------------
-- Runtime state
-- -----------------------------------------------------------------------------

local SecondInventories  = {}  -- ctrl → PersonalInventoryComponent
local ControllerGuids    = {}  -- ctrl → guid string
local CachedInventoryJson = {} -- ctrl → json string captured at close time

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
        log("No save file found for GUID " .. guid .. ", starting empty.")
        return nil
    end
    local content = file:read("*a")
    file:close()

    if content == "" then return nil end

    -- Raw engine JsonInventory string — pass straight back to populate_inventory.
    log("Loaded saved inventory for GUID " .. guid)
    return content
end

-- fallback_json: used when JsonInventory on the component is empty (e.g. between
-- close and the next game save). This is the last value captured at close time.
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

    if ok_json and json_str and json_str ~= "" and json_str ~= EMPTY_INV_JSON then
        file:write(json_str)
        file:close()
        log("Saved inventory (live JsonInventory) for GUID " .. guid)
        return
    end

    if fallback_json and fallback_json ~= "" and fallback_json ~= EMPTY_INV_JSON then
        file:write(fallback_json)
        file:close()
        log("Saved inventory (cached close-time JsonInventory) for GUID " .. guid)
        return
    end

    file:close()
    log("Inventory is empty — nothing written for GUID " .. guid)
end

-- Saves all active second inventories. Called from game-save hooks.
local function save_all_inventories()
    local count = 0
    for ctrl, inv in pairs(SecondInventories) do
        local guid = ControllerGuids[ctrl]
        if guid and ctrl:IsValid() and inv:IsValid() then
            save_inventory_data(guid, inv, CachedInventoryJson[ctrl])
            count = count + 1
        end
    end
    if count > 0 then
        log("Game save detected — wrote " .. count .. " second inventor" .. (count == 1 and "y." or "ies."))
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
        log("Populated inventory from saved data.")
        pcall(function() inv_comp.OnInventoryLoadedFromSave:Broadcast() end)
    else
        log_err("Failed to set JsonInventory: " .. tostring(err))
    end
end

-- -----------------------------------------------------------------------------
-- Second inventory component construction
-- -----------------------------------------------------------------------------

local function get_or_create_second_inventory(ctrl)
    if SecondInventories[ctrl] and SecondInventories[ctrl]:IsValid() then
        return SecondInventories[ctrl]
    end

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

    -- NOTE: RegisterComponent(), InitializeComponent(), BeginPlay() all fail with
    -- "UObject instance is nullptr" in this UE4SS build (not callable as UFunctions).
    -- ctrl+click initialization is handled by seeding EMPTY_INV_JSON before first open.

    SecondInventories[ctrl] = second_inv
    return second_inv
end

-- -----------------------------------------------------------------------------
-- UI open logic
-- -----------------------------------------------------------------------------

local function open_second_inventory_ui(ctrl, second_inv, char_obj)
    -- p1=34 matches real chest calls (param-spy confirmed). p1=0 opens the UI
    -- but ctrl+click reports "cannot be stored".
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
-- Close-time JSON capture
-- -----------------------------------------------------------------------------
-- Called from ClosePersonalInventory hooks (post-hook). Reads JsonInventory from
-- every active second inventory and caches it. This is the only reliable point
-- where the engine has serialized in-memory item state back to JsonInventory.

local function capture_inventory_on_close()
    for ctrl, inv in pairs(SecondInventories) do
        if inv:IsValid() then
            local ok_j, j = pcall(function()
                return inv:GetPropertyValue("JsonInventory"):ToString()
            end)
            if ok_j and j and j ~= "" and j ~= EMPTY_INV_JSON then
                CachedInventoryJson[ctrl] = j
                log("Captured JsonInventory at close (len=" .. #j .. ").")
            end
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

        -- Close-inventory hooks: capture JsonInventory at close time so it can be
        -- restored before the next OpenPersonalInventory (which reloads from JsonInventory
        -- and would otherwise wipe in-session items since our component is never
        -- serialized by the game's own save flow).
        for _, close_path in ipairs(CLOSE_HOOK_PATHS) do
            local ok_c = pcall(function()
                RegisterHook(close_path,
                    function() end,
                    function() ExecuteInGameThread(capture_inventory_on_close) end
                )
            end)
            if ok_c then
                log("Close hook registered: " .. close_path)
            end
        end

        -- Suppress the Eye of Oculus build menu via DeactivateOculus in the post-hook.
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
        if ok_oa then
            log("OculusComponent:ActivateOculus hook registered.")
        else
            log_err("Could not hook ActivateOculus.")
        end

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

                        -- Resolve and cache GUID.
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
                        ControllerGuids[ctrl] = guid

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

                        local second_inv = get_or_create_second_inventory(ctrl)
                        if not second_inv then return end

                        -- Determine what JsonInventory to set before opening:
                        -- 1. Cached close-time JSON (items from this session)
                        -- 2. Saved JSON from disk (items from a previous session)
                        -- 3. EMPTY_INV_JSON seed (first ever open — initializes slot array
                        --    so ctrl+click works immediately)
                        local restore_json = CachedInventoryJson[ctrl]

                        if not restore_json then
                            restore_json = load_inventory_data(guid)
                        end

                        if restore_json then
                            populate_inventory(second_inv, restore_json)
                            log("Restored " .. (CachedInventoryJson[ctrl] and "session" or "saved") .. " inventory data.")
                        else
                            -- First ever open: seed with known-good empty format so
                            -- OpenPersonalInventory initializes the slot array properly.
                            local ok_seed = pcall(function()
                                second_inv:SetPropertyValue("JsonInventory", EMPTY_INV_JSON)
                            end)
                            if ok_seed then
                                log("Seeded empty inventory JSON (first open, format confirmed safe).")
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
