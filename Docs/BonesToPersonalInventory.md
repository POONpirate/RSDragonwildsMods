# BonesToPersonalInventory — Mod Design Document

## Goal

Hook the **Bones to Peaches** spell so that casting it opens a **second, separate personal inventory** — completely independent of the existing bank/Personal Chest. This second inventory has 40 slots and leaves the regular `PersonalInventoryComponent` untouched. Its contents are serialized to a **JSON file keyed by character GUID** on every change. Because persistence lives in the JSON file rather than the game's save system, items survive mod removal and re-appear automatically when the mod is re-enabled.

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

### Step 1 — Find the Bones to Peaches hook path

We need the GE class name for Bones to Peaches so we can hook its `OnGameplayEffectAdded`. In FModel, navigate to:

```
RSDragonwilds > Content > Gameplay > UtilityMagic > PerkSpells
```

Look for a folder named something like `BonesToPeaches`, `Bones`, or `B2P`. Export:
- The `USD_` spell data asset
- The `GE_` gameplay effect it references

From the GE asset, confirm:
1. The full class name (e.g. `GE_PerkV2_Magic_BonesToPeaches_C`)
2. That it has an `OnGameplayEffectAdded` function (all BP GEs do)
3. What the default effect does (so we can decide whether to suppress it or run it alongside)

### Step 2 — Register the hook

```lua
-- Hook path will be something like:
RegisterHook("/Game/Gameplay/GameplayEffects/.../GE_BonesToPeaches.GE_BonesToPeaches_C:OnGameplayEffectAdded",
    function(self, instance)
        ExecuteInGameThread(function()
            -- our logic here
        end)
    end,
    function(self, instance)
        -- post-hook (optional)
    end
)
```

The pre-hook fires before the default GE logic. Returning false from a pre-hook suppresses the default. We'll decide in Step 1 whether to suppress the bones-to-peaches conversion or keep it.

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

## Files Still Needed from FModel

| File | Path | Why |
|---|---|---|
| Bones to Peaches USD | `Gameplay/UtilityMagic/PerkSpells/<B2P folder>/USD_*.uasset` | Get spell name and GE reference |
| Bones to Peaches GE | `Gameplay/GameplayEffects/...` (path is in the USD) | Get hookable class name and `OnGameplayEffectAdded` signature |

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

1. **Suppress or keep B2P default?** Does the player still want bones converted to peaches when they cast the spell, or should casting only open the second inventory?
2. **UI redirection** — Can the bank UI be pointed at an arbitrary `PersonalInventoryComponent` instance, or is it hardcoded to the original? (See Step 5.) This determines whether we need a custom widget.
3. **StaticConstructObject viability** — Does UE4SS's `StaticConstructObject` produce a component that can register with the inventory UI system, or will a different construction approach be needed?
4. **Multiplayer**: Each player's second inventory is keyed by their own character GUID, so per-player separation should work correctly in multiplayer sessions the same way the regular bank does.
5. **Exact property name** for items array on `PersonalInventoryComponent` — needs runtime inspection or further FModel digging.
6. **Exact event/delegate name** for inventory changes on `PersonalInventoryComponent` — needs confirmation from a live instance.
