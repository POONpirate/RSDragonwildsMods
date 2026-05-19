# BonesToPersonalInventory — Mod Design Document

## Goal

Hook the **Bones to Peaches** spell so that casting it opens the player's Personal Chest (bank) UI instead of — or in addition to — its default effect. The bank's contents are serialized to a **JSON file** on every change, making items persist independently of the game's save system. If the mod is disabled, items survive in the JSON and re-appear when the mod is re-enabled.

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

### Why reuse the bank (PersonalInventoryComponent)

- No chest actor needs to exist in the world
- No spawning required — the component already lives on `DominionPlayerController`
- The bank UI is already wired to open with this component
- `InventoryChangedEvent` (or equivalent) gives us a hook to serialize on every change
- Items in the component are also saved by the game's own save system as a secondary backup

### Trade-off

Bones to Peaches and the Physical Personal Chest building will share the same storage. If the player wants to keep them separate they'd need a different trigger. For now this is the agreed approach.

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

### Step 3 — Get the player's PersonalInventoryComponent

Inside the hook:

```lua
local ok, ctrl = pcall(function()
    return instance:GetInstigator():GetController()
end)
if not ok or not ctrl or not ctrl:IsValid() then return end

local ok2, personalInv = pcall(function()
    return ctrl:GetPersonalInventory()
end)
if not ok2 or not personalInv or not personalInv:IsValid() then return end
```

`GetPersonalInventory()` is a UFunction on `DominionPlayerController` confirmed from the GE's blueprint graph locals.

### Step 4 — Load JSON and populate the inventory

Before opening the UI, read the JSON file and write items into the component's slots:

```lua
local json = loadJSON()  -- custom helper, see Step 6
populateInventory(personalInv, json)
```

Populating will use `SetPropertyValue` on the inventory's items array. The exact property name needs to be confirmed by inspecting a live `PersonalInventoryComponent` instance (use `FindAllOf` or `GetPropertyValue` in-game on the component).

### Step 5 — Open the bank UI

Call the AccessPersonalChest GE on the player to trigger the bank UI opening. Two options:

**Option A — Call the GE directly**
```lua
-- Apply GE_PerkV2_Construction_AccessPersonalChest_C to the player
-- This requires knowing how to apply a GE in Lua (may need to call a UFunction on AbilitySystemComponent)
```

**Option B — Call OnGameplayEffectAdded directly on a GE instance**
```lua
-- Find or construct a GE instance and call OnGameplayEffectAdded(instance)
-- on the controller
```

**Option C — RegisterHook on GetPersonalInventory as the open trigger**
```lua
-- Hook DominionPlayerController:GetPersonalInventory
-- Pre-hook: populate inventory from JSON
-- Post-hook or InventoryChangedEvent: serialize to JSON
```

Option C is the safest since `GetPersonalInventory` is confirmed callable and is the actual gate before the UI opens. We hook it pre/post and use it as our sync point.

> **To be determined**: Exact UFunction signature for opening the bank UI from Lua. If calling the GE directly is not possible, we may register a second hook on `GetPersonalInventory` as the open/close boundary.

### Step 6 — JSON helpers

```lua
local UEProjDir  = ...  -- path to Saved/ or a known writable location
local JSON_PATH  = UEProjDir .. "/BonesToPersonalInventory.json"

local function loadJSON()
    -- io.open(JSON_PATH, "r"), read, parse
    -- return table of { itemPath, count } entries, or {} if no file
end

local function saveJSON(inventoryTable)
    -- serialize inventoryTable to JSON string
    -- io.open(JSON_PATH, "w"), write
end
```

UE4SS Lua has access to `io` so file read/write is straightforward. The JSON path can be relative to the game's `Saved/` directory or the mod's own folder.

For JSON encoding/decoding, either:
- Ship a tiny pure-Lua JSON library (`json.lua`) in the mod's `Scripts/` folder
- Or encode manually (simple enough for a flat array of `{path, count}` pairs)

### Step 7 — Serialize on change

Hook the inventory change event so JSON is written whenever items are added/removed:

```lua
NotifyOnNewObject("/Script/Dominion.PersonalInventoryComponent", function(comp)
    ExecuteInGameThread(function()
        -- Hook InventoryChangedEvent on this comp instance
        -- On fire: serialize comp's items to JSON
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

1. **Suppress or keep B2P default?** Does the player still want bones converted to peaches when they cast the spell, or should casting only open the bank?
2. **Slot count**: The second inventory will have **40 slots**. `PersonalInventoryComponent.MaxSlotCount` is 20 by default and will be raised to 40 via `SetPropertyValue` at startup (same pattern as radius mods).
3. **Multiplayer**: `GetPersonalInventory()` is called on the local player's controller. In a multiplayer session, each player's bank is separate — this should work correctly per-player as long as JSON is keyed by player GUID (available via `GetCharacterGuid()` seen in the PersonalChest BP).
4. **Exact property name** for items array on `PersonalInventoryComponent` — needs runtime inspection or further FModel digging.
5. **Exact UFunction name** for opening the bank UI from Lua — confirmed it goes through `GetPersonalInventory` but the UI-open call may be native C++ after that.
