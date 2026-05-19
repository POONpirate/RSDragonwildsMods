# BonesToPersonalInventory — Mod Design Document

## Goal

Hook the **Eye of Oculus** spell so that casting it opens a **second, separate personal inventory** — completely independent of the existing bank/Personal Chest. This second inventory has 40 slots and leaves the regular `PersonalInventoryComponent` untouched. Its contents are serialized to a **JSON file keyed by character GUID** on every change. Because persistence lives in the JSON file rather than the game's save system, items survive mod removal and re-appear automatically when the mod is re-enabled.

---

## What We Know About the AccessPersonalChest System

### Spell chain for the existing bank spell

```
USD_AccessPersonalChest
  └─ SpellModule_GameplayEffect (fires at ESpellStateTrigger::FinishedCasting)
       └─ GE_PerkV2_Construction_AccessPersonalChest_C
            └─ OnGameplayEffectAdded()
                 ├─ GetInstigator() → cast to DominionPlayerCharacter
                 ├─ GetController() → cast to DominionPlayerController
                 └─ GetPersonalInventory() → PersonalInventoryComponent
                      └─ [opens bank UI]
```

The **Personal Chest building** (`BP_BaseBuilding_PersonalChest_C`) does exactly the same thing — it's just a physical trigger. The storage lives on the `DominionPlayerController`, not on any chest actor.

### Key asset paths

| Asset | Package path |
|---|---|
| AccessPersonalChest spell | `/Game/Gameplay/UtilityMagic/PerkSpells/AccessPersonalChest/USD_AccessPersonalChest` |
| Bank portal GE | `/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_AccessPersonalChest` |
| GE class (hookable) | `/Script/Dominion` → `GE_PerkV2_Construction_AccessPersonalChest_C` |
| PersonalInventory component | `BP_Components_PersonalInventory_C` — extends `PersonalInventoryComponent` (/Script/Dominion) |
| PersonalInventory BP | `/Game/Gameplay/Character/Components/BP_Components_PersonalInventory` |

### PersonalInventoryComponent defaults

- `MaxSlotCount`: 20
- `bSupportsSortAndFillStacks`: true
- `bShouldGenerateTelemetryEvents`: true

---

## Chosen Architecture

### A second PersonalInventoryComponent + JSON persistence

A second `PersonalInventoryComponent` is created dynamically at runtime using UE4SS's `StaticConstructObject` pattern and attached to `DominionPlayerController`. This keeps it entirely separate from the existing bank component — the regular Personal Chest building and `AccessPersonalChest` spell continue to use the original component without any interference.

Key points:
- The second component only exists while the mod is active, so it cannot rely on the game's own save system
- All item data is written to a **JSON file keyed by character GUID** (`GetCharacterGuid()`) on every inventory change
- On load, the JSON is read and used to populate the second component before the UI opens
- If the mod is disabled, the JSON file remains on disk untouched — re-enabling the mod restores all items exactly as left
- `MaxSlotCount` is set to **40** via `SetPropertyValue` immediately after the component is constructed

### Open research question

Whether the existing bank UI can be pointed at an arbitrary `PersonalInventoryComponent` instance (rather than the one already registered on the controller) is still to be confirmed. If the UI is hardcoded to the original component, we will need a different open trigger or a custom UI widget.

---

## Implementation Plan

### Step 1 — Find the spell hook path ✅

**Resolved.** `USD_EyeOfOculus.uasset` confirmed the following:

- The spell is **GE-based**: `SpellModule_GameplayEffect` fires `GE_PerkV2_Construction_Oculus_C` at `ESpellStateTrigger::FinishedCasting`
- GE package path: `/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus`
- Full hook path:
  ```
  /Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded
  ```
- In the hook, `self` is the GE CDO and `instance` is the active GE spec; the player controller is obtained via `instance:GetInstigator():GetController()`
- Costs 3 Astral Runes per cast (`SpellModule_CostItems`)

### Step 2 — Register the hook

Eye of Oculus is GE-based. We hook `OnGameplayEffectAdded` on `GE_PerkV2_Construction_Oculus_C`. `self` is the GE CDO; `instance` is the active spec. The player controller comes from `instance:GetInstigator():GetController()`. Returning false suppresses the default GE effect.

```lua
RegisterHook(
    "/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded",
    function(self, instance)
        ExecuteInGameThread(function()
            local ctrl = instance:GetInstigator():GetController()
            -- our logic here
        end)
        return false  -- suppress default Eye of Oculus effect
    end,
    function(self, instance) end  -- post-hook unused
)
```

### Step 3 — Get the controller and construct the second inventory component

Inside the hook, get the player controller and either retrieve the already-constructed second component (if it exists from a previous cast this session) or create it fresh:

```lua
local ok, ctrl = pcall(function()
    return instance:GetInstigator():GetController()
end)
if not ok or not ctrl or not ctrl:IsValid() then return end

-- Construct the second PersonalInventoryComponent and attach it to the controller
-- This should only happen once per session; store the reference in a Lua-side table keyed by ctrl
if not SecondInventories[ctrl] then
    local ok2, secondInv = pcall(function()
        return StaticConstructObject(
            StaticFindObject("/Script/Dominion.PersonalInventoryComponent"),
            ctrl,
            FName("SecondPersonalInventory")
        )
    end)
    if not ok2 or not secondInv or not secondInv:IsValid() then return end

    -- Set slot count to 40
    secondInv:SetPropertyValue("MaxSlotCount", 40)

    SecondInventories[ctrl] = secondInv
end

local secondInv = SecondInventories[ctrl]
```

> **Note**: The exact `StaticConstructObject` signature and whether a dynamically constructed component can participate in the bank UI needs to be validated in-game. If `StaticConstructObject` is not sufficient, an alternative is to use `RegisterCustomProperty` or find an unused component slot already on the controller.

### Step 4 — Load JSON and populate the second inventory

Before opening the UI, read the JSON file for this character and write items into the second component's slots:

```lua
local guid = ctrl:GetCharacterGuid()  -- unique per character, confirmed in PersonalChest BP
local json = loadJSON(guid)           -- custom helper, see Step 6
populateInventory(secondInv, json)
```

Populating will use `SetPropertyValue` on the inventory's items array. The exact property name needs to be confirmed by inspecting a live `PersonalInventoryComponent` instance (use `FindAllOf` or `GetPropertyValue` in-game on the component).

### Step 5 — Open the UI for the second inventory

This step depends on whether the bank UI can be redirected to an arbitrary `PersonalInventoryComponent` instance. Two paths:

**Option A — Redirect GetPersonalInventory temporarily**
```lua
-- Pre-hook DominionPlayerController:GetPersonalInventory
-- Swap return value to secondInv for this one call, then swap back
-- Then trigger the AccessPersonalChest GE normally to open the UI
```
This is the cleanest approach if the UI purely relies on the return value of `GetPersonalInventory`.

**Option B — Apply the AccessPersonalChest GE directly**
```lua
-- Apply GE_PerkV2_Construction_AccessPersonalChest_C to the player via AbilitySystemComponent
-- If Option A's hook is in place, this will cause the UI to open against secondInv
```

**Option C — Custom UI widget (fallback)**

If the bank UI is hardcoded to the original component in native C++ and cannot be redirected, a custom UMG-style widget would be needed. This is the most work and should only be pursued if Options A and B are confirmed impossible.

> **To be determined**: Whether `GetPersonalInventory`'s return value is what the UI widget actually reads, or if the UI holds a direct reference set at construction time. Runtime inspection needed.

### Step 6 — JSON helpers

Each character gets its own JSON file named by their GUID, so multiple characters on the same machine never share or overwrite each other's second inventory.

```lua
local UEProjDir = ...  -- path to Saved/ or the mod's own folder
local function jsonPath(guid)
    return UEProjDir .. "/PersonalInventoryMod_" .. guid .. ".json"
end

local function loadJSON(guid)
    -- io.open(jsonPath(guid), "r"), read, parse
    -- return table of { itemPath, count } entries, or {} if no file
end

local function saveJSON(guid, inventoryTable)
    -- serialize inventoryTable to JSON string
    -- io.open(jsonPath(guid), "w"), write
end
```

UE4SS Lua has access to `io` so file read/write is straightforward. The JSON file survives mod removal — if the mod is re-enabled, `loadJSON` finds the file and restores all items.

For JSON encoding/decoding, either:
- Ship a tiny pure-Lua JSON library (`json.lua`) in the mod's `Scripts/` folder
- Or encode manually (simple enough for a flat array of `{path, count}` pairs)

### Step 7 — Serialize on change

After constructing the second component (Step 3), hook its inventory change event so JSON is written whenever items are added or removed. We hook the specific instance rather than all `PersonalInventoryComponent` objects to avoid interfering with the regular bank:

```lua
-- After secondInv is constructed:
local guid = ctrl:GetCharacterGuid()
RegisterHook(secondInv, "InventoryChangedEvent", function()
    ExecuteInGameThread(function()
        local items = secondInv:GetPropertyValue("Items")  -- property name TBD
        saveJSON(guid, items)
    end)
end)
```

The exact event/delegate name on `PersonalInventoryComponent` needs to be confirmed from a live instance or further FModel export of the component's parent class.

---

## Confirmed Properties (from runtime PropertyDumper)

All unknowns are now resolved. Full class hierarchy of `PersonalInventoryComponent`:

| Class | Property | Type | Notes |
|---|---|---|---|
| `PersonalInventoryComponent` | `OnPersonalInventoryClosed` | `MulticastInlineDelegateProperty` | Fires when inventory UI closes — used for save trigger |
| `PersonalInventoryComponent` | `CachedPersonalChest` | `ObjectProperty` | Internal reference, not needed by mod |
| `InventoryWithLogComponent` | `OnNewLogEvent` | `MulticastInlineDelegateProperty` | |
| `InventoryWithLogComponent` | `LogEvents` | `ArrayProperty` | |
| `InventoryWithLogComponent` | `IdGenerator` | `StructProperty` | |
| `InventoryComponent` | `OnInventoryChanged` | `MulticastInlineDelegateProperty` | Fires on every item change |
| `InventoryComponent` | `OnInventoryLoadedFromSave` | `MulticastInlineDelegateProperty` | Broadcast after loading from save to refresh UI |
| `InventoryComponent` | `OnItemUsed` | `MulticastInlineDelegateProperty` | |
| `InventoryComponent` | **`ItemSlots`** | `ArrayProperty` | **The items array** |
| `InventoryComponent` | `PreviousItemSlots` | `ArrayProperty` | |
| `InventoryComponent` | `MaxSlotCount` | `IntProperty` | Set to 40 at construction |
| `InventoryComponent` | `bSupportsSortAndFillStacks` | `BoolProperty` | |
| `InventoryComponent` | **`JsonInventory`** | `StrProperty` | **Engine's own JSON serialization of the inventory — read/write this directly for persistence** |

### Key decisions from these findings

- **Save trigger**: `OnPersonalInventoryClosed` (on close, not per-change) — avoids file thrashing
- **Items array**: `ItemSlots` — used as fallback if `JsonInventory` is unavailable
- **Persistence**: The engine already serializes inventory to `JsonInventory` as a string. We save this string to our JSON file and write it back on load via `SetPropertyValue("JsonInventory", ...)`, then broadcast `OnInventoryLoadedFromSave` to refresh the UI. This is far more reliable than manually reconstructing `ItemSlots`.

### Confirmed from BP_BaseBuilding_PersonalChest

- `DominionPlayerController:GetCharacterGuid()` — confirmed callable, returns a **`DomCharacterGuid` struct**. The usable string is in the `InnerGuid` field (e.g. `"00000000-00000000-00000000-00000000"`). Use `ctrl:GetCharacterGuid().InnerGuid` for JSON file naming.
- `DominionPlayerController:GetPersonalInventory()` — confirmed callable, returns `PersonalInventoryComponent`.
- The chest interaction also calls `GetCharacterDisplayName()` on the controller, available if needed.

---

## Mod File Structure

```
RSDragonwildsMods/
└─ PersonalInventoryMod/
   ├─ Scripts/
   │   ├─ main.lua
   │   └─ json.lua          (tiny pure-Lua JSON lib, if needed)
   ├─ enabled.txt
   └─ (no pak required)
```

---

## Open Questions

1. **Suppress Eye of Oculus default?** The default GE effect is currently suppressed (return false). Confirm whether the original Eye of Oculus effect should also fire or be replaced entirely.
2. **UI redirection** — Can the bank UI be pointed at an arbitrary `PersonalInventoryComponent` instance, or is it hardcoded to the original? (See Step 5.) This determines whether we need a custom widget.
3. **StaticConstructObject viability** — Does UE4SS's `StaticConstructObject` produce a component that can register with the inventory UI system, or will a different construction approach be needed?
4. **Multiplayer**: Each player's second inventory is keyed by `DomCharacterGuid.InnerGuid` (confirmed available on `DominionPlayerController`), so per-player separation will work correctly in multiplayer sessions the same way the regular bank does.
5. **Items array**: `ItemSlots` (`ArrayProperty` on `InventoryComponent`) — confirmed via runtime PropertyDumper. Superseded by `JsonInventory` approach.
6. **Save delegate**: `OnPersonalInventoryClosed` (`MulticastInlineDelegateProperty` on `PersonalInventoryComponent`) — confirmed. `OnInventoryChanged` also available on `InventoryComponent` if per-change saving is ever needed.
