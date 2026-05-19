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

-- Hook path for Eye of Oculus GE.
local SPELL_HOOK = "/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded"

-- Game-save hook candidates. We register post-hooks on all of these; whichever
-- the game actually calls will trigger save_all_inventories(). Add more paths
-- here if additional save points are discovered.
local GAME_SAVE_HOOKS = {
    "/Script/Dominion.DominionPlayerController:ServerSaveCharacter",
    "/Script/Dominion.DominionPlayerController:SaveCharacter",
    "/Script/Dominion.DominionPlayerController:SaveGame",
    "/Script/Dominion.DominionGameMode:SaveGame",
    "/Script/Dominion.DominionGameMode:AutoSave",
    "/Script/Dominion.DominionGameMode:SaveWorld",
    "/Script/Engine.GameplayStatics:SaveGameToSlot",
}

local SAVE_DIR = nil  -- resolved at runtime in get_save_dir()

-- -----------------------------------------------------------------------------
-- Runtime state
-- -----------------------------------------------------------------------------

-- Keyed by DominionPlayerController instance.
local SecondInventories = {}  -- ctrl → PersonalInventoryComponent
local ControllerGuids   = {}  -- ctrl → guid string (set on first cast, used at save time)

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
        return {}
    end
    local content = file:read("*a")
    file:close()

    if content == "" then return {} end

    -- Raw engine JsonInventory string (starts with "{") — pass straight back
    -- to populate_inventory to write via SetPropertyValue.
    if content:sub(1, 1) == "{" then
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

-- Saves all active second inventories. Called from game-save hooks so our JSON
-- stays in sync with the game's own save state. If the game crashes unsaved,
-- both the game data and our JSON remain at their last-saved state — correct.
local function save_all_inventories()
    local count = 0
    for ctrl, inv in pairs(SecondInventories) do
        local guid = ControllerGuids[ctrl]
        if guid and ctrl:IsValid() and inv:IsValid() then
            save_inventory_data(guid, inv)
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
    if not data or (type(data) == "table" and #data == 0) then return end

    -- data is a plain Lua string saved from JsonInventory:ToString() — write back directly.
    if type(data) == "string" and data ~= "" then
        local ok, err = pcall(function()
            inv_comp:SetPropertyValue("JsonInventory", data)
        end)
        if ok then
            log("Populated second inventory via JsonInventory string.")
            -- Fire OnInventoryLoadedFromSave if the delegate is accessible.
            pcall(function() inv_comp.OnInventoryLoadedFromSave:Broadcast() end)
        else
            log_err("Failed to set JsonInventory: " .. tostring(err))
        end
        return
    end

    -- Fallback: write ItemSlots array directly.
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

    local ok, second_inv = pcall(function()
        return StaticConstructObject(
            StaticFindObject("/Script/Dominion.PersonalInventoryComponent"),
            ctrl,
            FName("SecondPersonalInventory")
        )
    end)

    if not ok or not second_inv or not second_inv:IsValid() then
        log_err("StaticConstructObject failed for PersonalInventoryComponent: " .. tostring(second_inv))
        return nil
    end

    -- NOTE: RegisterComponent(), InitializeComponent(), and BeginPlay() all fail
    -- with "UObject instance is nullptr" via UE4SS — not callable as UFunctions
    -- in this game's build. Slot initialization (ctrl+click) remains an open issue.

    local ok2, err2 = pcall(function()
        second_inv:SetPropertyValue("MaxSlotCount", SECOND_INV_SLOTS)
    end)
    if not ok2 then
        log_err("Failed to set MaxSlotCount to " .. SECOND_INV_SLOTS .. ": " .. tostring(err2))
    else
        log("Second inventory constructed with " .. SECOND_INV_SLOTS .. " slots.")
    end

    SecondInventories[ctrl] = second_inv
    log("Second inventory component created and registered.")
    return second_inv
end

-- -----------------------------------------------------------------------------
-- UI open logic
-- -----------------------------------------------------------------------------
-- p1=34 matches real chest calls (observed via param-spy).
-- p1=0 (ctrl mapped) opens the UI but ctrl+click reports "cannot be stored".
-- Testing whether p1=34 alone (without bad JSON seed) enables full interaction.

local function open_second_inventory_ui(ctrl, second_inv, char_obj)
    local ok, err = pcall(function()
        second_inv:OpenPersonalInventory(34, char_obj)
    end)
    if ok then
        log("Second inventory UI opened successfully (p1=34).")
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
-- Register post-hooks on all GAME_SAVE_HOOKS paths. Whichever the game actually
-- calls will trigger save_all_inventories(). Unknown paths fail silently.

log("Registering game-save hooks...")
for _, hook_path in ipairs(GAME_SAVE_HOOKS) do
    local ok = pcall(function()
        RegisterHook(hook_path,
            function() end,  -- pre-hook: no-op
            function()
                ExecuteInGameThread(save_all_inventories)
            end
        )
    end)
    if ok then
        log("Save hook registered: " .. hook_path)
    end
end

-- -----------------------------------------------------------------------------
-- Eye of Oculus hook
-- -----------------------------------------------------------------------------

-- GE_PerkV2_Construction_Oculus_C is a Blueprint GE — not loaded at mod startup.
-- Defer hook registration to NotifyOnNewObject so the class exists when we hook.
-- return false does NOT suppress blueprint or native events in this UE4SS build;
-- ActivateOculus suppression is handled via DeactivateOculus in the post-hook.

log("Waiting for player controller to register Eye of Oculus hook...")

local hook_registered = false

NotifyOnNewObject("/Script/Dominion.DominionPlayerController", function(_)
    if hook_registered then return end

    ExecuteInGameThread(function()
        if hook_registered then return end

        log("Player controller ready — registering Eye of Oculus hook...")

        -- Suppress the Eye of Oculus build menu by calling DeactivateOculus in
        -- the post-hook (return false does not cancel native calls in this build).
        local ok_oa, err_oa = pcall(function()
            RegisterHook("/Script/Dominion.OculusComponent:ActivateOculus",
                function(self) end,
                function(self)
                    local ok_get, comp = pcall(function() return self:get() end)
                    if not ok_get or not comp then
                        log_err("ActivateOculus post: self:get() failed: " .. tostring(comp))
                        return
                    end
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
            log_err("Could not hook ActivateOculus: " .. tostring(err_oa))
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
                            log_err("No valid DominionPlayerController found via FindAllOf.")
                            return
                        end

                        -- Resolve GUID and cache it for save_all_inventories().
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
                            log_err("Could not resolve a GUID string from DomCharacterGuid.")
                            return
                        end
                        log("Controller found, GUID=" .. guid)

                        -- Cache for save hooks.
                        ControllerGuids[ctrl] = guid

                        -- Diagnostic: scan for real chest components to capture JsonInventory
                        -- format. Cast while standing next to a Personal Chest. Remove once
                        -- the correct seed format is known and ctrl+click is confirmed fixed.
                        do
                            local classes = {
                                "PersonalInventoryComponent",
                                "PersonalChestComponent",
                                "InventoryComponent",
                                "StorageComponent",
                                "ContainerComponent",
                            }
                            for _, cls in ipairs(classes) do
                                local ok_fa, found = pcall(function() return FindAllOf(cls) end)
                                if ok_fa and found and #found > 0 then
                                    log("FindAllOf " .. cls .. " — " .. #found .. " found:")
                                    for i, pic in ipairs(found) do
                                        if pic:IsValid() then
                                            local ok_j, j = pcall(function()
                                                return pic:GetPropertyValue("JsonInventory"):ToString()
                                            end)
                                            local jstr = ok_j and tostring(j) or "no JsonInventory"
                                            log("  [" .. i .. "] JsonInventory=[" .. jstr .. "]")
                                        end
                                    end
                                end
                            end
                        end

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

                        local data = load_inventory_data(guid)
                        populate_inventory(second_inv, data)
                        open_second_inventory_ui(ctrl, second_inv, char_obj)
                    end)
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
