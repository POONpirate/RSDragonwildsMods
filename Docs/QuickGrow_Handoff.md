# QuickGrow Mod — Handoff Prompt

## Goal
Build a UE4SS Lua mod for RuneScape: Dragonwilds called **QuickGrow**. When the player casts the Eye of Oculus spell, it should advance the in-game world to the next morning (skipping the night), regardless of the current time of day. Crops grow on natural server day-ticks, so forcing a day advance is how we accelerate crop growth. Direct crop growth manipulation is not possible.

## Current mod files

`QuickGrow/scripts/main.lua` — current v4.1 (see full file in the mod folder)

Key behavior:
- Hooks `OculusComponent:ActivateOculus` post-hook to suppress the build menu via `DeactivateOculus`
- Hooks the spell's gameplay effect (`GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded`) pre-hook to call `advanceWorldDay()`
- `advanceWorldDay()` finds the player's claimed `BP_BaseBuilding_Bed_C` actor, gets its `BedComponent` (via `bed.Bed`), and calls `bedComp:Sleep(cache.player)` directly

## What works

- Hook registration works for both Oculus and spell hooks
- `FindAllOf("BP_BaseBuilding_Bed_C")` finds beds
- `bedComp:IsClaimedByPlayer(player)` correctly identifies the player's claimed bed
- At **nighttime**, physically interacting with the bed (which calls the Blueprint function `ToggleRestingOrSleeping`) teleports the player to the bed and advances the day — this is the behavior we want to replicate programmatically
- `bedComp:Sleep(cache.player)` **calls without error** (confirmed correct parameter count)

## What does NOT work

- `bedComp:Sleep(cache.player)` executes without error but **nothing happens visually** — no teleport, no day advance, no animation
- We cannot override `BedComponent:CanSleep`'s return value via a native post-hook — the Blueprint caller already received the original value before the post-hook fires (confirmed: Lua-side copy only)
- `OnAllPlayersSleeping` is a `MulticastInlineDelegateProperty` on `DominionGameMode` — cannot be broadcast from Lua

## Class hierarchy discovered

Via PropertyDumper (UE4SS `StaticFindObject` + `ForEachProperty` + `RegisterHook` probe scanner):

### `BedComponent` (`/Script/Dominion.BedComponent`)
Extends `RestingAreaComponent`. Properties (own):
- `ClaimantGuidChangedEvent` (MulticastInlineDelegate)
- `GameplayObjectRegistryIdentifier` (Struct)
- `bRequiresClaimingToSleepIn` (Bool)

Functions (confirmed via `RegisterHook` probe — these exist and are hookable):
- `CanSleep` — returns `ECanRestResult`: 0 = success, 4 = not nighttime
- `IsClaimedByPlayer(player)`
- `IsClaimedByAnyPlayer()`
- **`Sleep(player)`** ← takes 1 param; executes without error but no visible effect
- `StopSleeping()`

### `RestingAreaComponent` (`/Script/Dominion.RestingAreaComponent`)
Base class of `BedComponent`. Functions:
- `CanRest()` — always returns 0 (success) at any time of day
- `IsResting()`
- `GetCurrentRestingPlayer()`
- **`Rest(?)`** — daytime bed use (just lies down, no day advance)
- `StopResting()`

Properties (own):
- `OnCurrentRestingPlayerChangedDynamic` (MulticastInlineDelegate)
- `RestingMontage`, `RestLoopSectionName`, `RestingCameraProfile`, `OnRestSound`
- `PlayerRestingTransformSettings`
- `LeaveActionText`
- `CurrentRestingPlayer` (WeakObject)

### `PlayerRestComponent` (`/Script/Dominion.PlayerRestComponent`)
On the player character. Get via `cache.player:GetPlayerRestComponent()`. At runtime is actually a `BP_Components_Rest_C` Blueprint subclass. Functions (confirmed hookable):
- `IsResting()`
- `GetIsSleeping()`
- `GetCurrentRestingAreaActor()` — returns which bed actor player is currently resting at
- `GetCurrentRestingAreaComponent()`
- **`StartSleeping(?)`** ← confirmed exists, parameters unknown
- `OnFullyRested(?)`
- **`SetRestingArea(?)`** ← confirmed exists, parameters unknown

Properties (own):
- `OnNewRestingAreaComponent` (MulticastInlineDelegate)
- `RestingStartedEvent` (MulticastInlineDelegate)
- `FullyRestedEvent` (MulticastInlineDelegate)
- `RestingEndEvent` (MulticastInlineDelegate)
- `PlayerCharacter` (Object)
- `UIInputApi` (Object)
- `PlayerSleepSettings` (Object)
- `RestedGEs`, `RestingGEs` (Arrays)
- `TryingToSleepNotificationTag`, `TooEarlyToSleepNotificationTag` (GameplayTags)
- `TryToSleepText`, `PlayerWantsToSleepText`, `TooEarlyToSleepText` (Text)
- `WakeUpPlayerHook` (Object)
- `WellRestedDurationSeconds` (Float)
- **`CurrentRestingAreaActor`** (Object) ← which bed the player is resting at
- **`CurrentRestingAreaComponent`** (Object)
- **`IsSleeping`** (Bool)
- `TimeNeededToApplyRestedEffect` (Float)

## Blueprint function locals (from FModel uasset dump)

`BP_BaseBuilding_Bed_C:ToggleRestingOrSleeping` (the working physical-interaction path) has these local variables, revealing its call structure:
- Gets `PlayerRestComponent` from player via `GetPlayerRestComponent()`
- Calls `GetCurrentRestingAreaActor()` on PlayerRestComponent (toggle check: already resting here?)
- Calls `IsResting()` and `GetIsSleeping()` 
- Calls `CanRest()` on BedComponent → must be 0
- Calls `CanSleep()` on BedComponent → must be 0 (fails during day, returns 4)
- Calls some void function(s) to actually start sleeping (void calls leave no local variable in the uasset dump)
- Sets `StartedRestingOrSleeping` out param

## Current hypothesis for why `Sleep(player)` does nothing

`BedComponent:Sleep(player)` may silently bail if the `PlayerRestComponent` is not already in the correct state. Specifically, `SetRestingArea` may need to be called first to tell `PlayerRestComponent` which bed actor/component the player is sleeping at — then `Sleep(player)` can proceed to set `IsSleeping = true`, fire `RestingStartedEvent`, and trigger the server-side day advance.

Alternatively, **`PlayerRestComponent:StartSleeping`** may be the correct direct trigger (rather than `BedComponent:Sleep`) — this function may be what fires `RestingStartedEvent` and increments the GameMode's sleeping player count.

## Suggested next steps (in order)

1. **Probe `SetRestingArea` parameter signature** by trying `restComp:SetRestingArea(bed)`, `restComp:SetRestingArea(bed, bedComp)`, and `restComp:SetRestingArea(bedComp)` in sequence (pcall each). Then call `bedComp:Sleep(player)` after.

2. **Try `PlayerRestComponent:StartSleeping` directly** with similar param probing: `restComp:StartSleeping(bed)`, `restComp:StartSleeping(bed, bedComp)`, `restComp:StartSleeping(cache.player)`.

3. **Hook `PlayerRestComponent:StartSleeping` and `SetRestingArea`** as observers. Then physically interact with a bed at night and observe what params these functions are called with — that gives us the correct signature to replicate in Lua.

4. **Check authority**: on a listen server, confirm UE4SS Lua runs with server authority. If `BedComponent:Sleep` is a server-only function, calling it from a Lua mod that lacks authority would silently no-op. A workaround might be calling `ToggleRestingOrSleeping` (which does work) and then somehow intercepting/modifying its internal CanSleep call before it executes.

5. **Hook `BedComponent:Sleep` pre/post** to confirm it's actually firing when we call it and see what it does.

6. **Try hooking `ToggleRestingOrSleeping` pre-hook** to set a flag, then immediately call `CanSleep` pre-hook to return 0 before the C++ runs — this is a "pre-hook override" (different from post-hook override which doesn't work). If UE4SS pre-hooks can suppress the native call and substitute a return value, this could work.

## Confirmed findings from v4.2/v4.3 diagnostic runs (2026-06-09)

- The working physical night-sleep path calls **exactly** `BedComponent:Sleep(player)` — same self, same single param we pass. No `SetRestingArea`/`StartSleeping` precede it. Our call is correct; it silently bails during the day on an internal native time check. **The bed API is not the lever — the time system is.**
- `CanSleep` signature: takes the player — `CanSleep(player)` → 4 during day. `CanSleep()` errors (nil).
- `SetRestingArea` takes exactly 1 param (an Actor). Passing a `BedComponent` **crashes the game natively**. Never probe object params blindly.
- Generic property dumping (`ForEachProperty` + reading every value) **crashes** on exotic property types. Read known props by name only.
- **TIME SYSTEM: `BP_InGameTimeActor_C`** (one instance in PersistentLevel):
  - `RealTimeMinutesPerInGameDay` = 24 (so 1 real second = 60 game seconds)
  - `TimeOfDawn` = 4.5, `TimeOfDusk` = 22.0
  - `StoredTime` = game-seconds counter (e.g. 272430), `LastSyncTime` = real seconds
  - `InitialTime` (Timespan struct), `bIsTimePaused` (read returned nil)
- v4.4 strategy: bump `StoredTime` +1 game-hour at a time until `CanSleep(player) == 0`, then `Sleep(player)`; restore `StoredTime` on failure.
- v4.4 crash: **`ForEachFunction` crashes natively too** (died mid-enumeration of `/Script/Engine.Actor`). NO reflection enumeration of any kind is safe in this game — only the `RegisterHook` name-probe technique. Also: `BP_InGameTimeActor_C` and `/Script/Dominion.InGameTimeActor` enumerate zero own functions before the crash. Class chain confirmed: `BP_InGameTimeActor_C` → `/Script/Dominion.InGameTimeActor` → `Actor`.
- v4.5: enumeration removed; clock-advance loop runs directly; on failure, safe RegisterHook name-probe on `/Script/Dominion.InGameTimeActor`.
- v4.5 results: **NIGHT cast now works** (Sleep(player) → sleep + day advance). DAY cast: 30 StoredTime bumps never changed `CanSleep` (write may not stick, or CanSleep reads time elsewhere). 0/45 name hits on native InGameTimeActor. CanSleep also returned **3** once (probably "too early/recently slept"; 4 = not night).
- BP time actor full class path: `/Game/Gameplay/World/Time/BP_InGameTimeActor.BP_InGameTimeActor_C`.
- v4.6: startup probe+observe (throttled, 5 logs/fn) across InGameTimeActor (native+BP), DominionGameMode, DominionGameState (~65 names); a working night cast should reveal the real day-advance call. Day cast verifies whether StoredTime writes stick via read-back.
- v4.6 results: **StoredTime writes STICK** (read-back confirms, float precision) but `CanSleep` ignores them across +30 game-hours → StoredTime is NOT the live clock (probably save-state only). **0/65 name probes hit** on all four classes — name-guessing exhausted.
- v4.7: lists ALL `BP_InGameTimeActor_C` instances (wrong-instance/CDO hypothesis) and hop-writes all of them; adds crash-safe property map (pass 1 names+types only, pass 2 values gated to numeric/bool/enum/name/str types) of time actor + GameMode + GameState, stopping before `/Script/Engine.*` supers.
- If v4.7's map doesn't reveal the live clock: fall back to UE4SS GUI dumpers (UHT header dump) for the full Dominion SDK — definitive, offline, no more guessing.
- v4.7 results: **complete `InGameTimeActor` property list** = RealTimeMinutesPerInGameDay (int), InitialTime (Timespan struct), TimeOfDawn (float), TimeOfDusk (float), StoredTime (float), LastSyncTime (float), bIsTimePaused (bool). **No live-clock property exists** — current time is a non-reflected C++ member; that's why StoredTime writes stick but do nothing. Also: ForEachProperty crashed on DominionGameModeBase even name-only → ALL reflection enumeration permanently banned. GameMode native props: just the 4 delegates + PreferedPlayerStartTag.
- v4.8 fix ("move the goalposts"): set `TimeOfDusk = 0.01` (fallback also `TimeOfDawn = 24.0`) so any current time counts as night → `CanSleep(player)==0` → `Sleep(player)` → restore bounds immediately. Dawn drives wake-up time and is restored before sleep fade finishes.
- v4.8 results: dusk shift does NOTHING; **`TimeOfDawn=24.0` flips CanSleep 4→0 and Sleep is accepted** (player gets in bed). But day didn't advance because (a) IsSleeping sets asynchronously (instant check reported false), and (b) we restored dawn immediately, so the deferred all-players-sleeping night re-check failed. Confirmed `CanSleep=3` is a non-time blocker (shifts don't clear it; likely "slept too recently").
- v4.9: keep dawn=24.0 until sleep completes — poll IsSleeping→true (5s), then →false = woke (60s), THEN restore bounds. StoredTime logged each phase to verify the jump and the wake-up hour (watch for a wrong wake time if morning is computed from the shifted dawn).
- v4.9 result: dawn=24 ALONE does NOT flip CanSleep (stayed 4). The v4.8 flip required BOTH `TimeOfDusk=0.01` AND `TimeOfDawn=24.0` (they were applied cumulatively). Night check needs both bounds shifted.
- v5.0: shifts both bounds, then the v4.9 polling flow (restore only after wake/timeout).

## UE4SS Lua notes

- `RegisterHook` supports pre-hook and post-hook; post-hook return value modification for native C++ functions modifies only a Lua-side copy (Blueprint caller already received original)
- `ForEachFunction` returns 0 for all C++ classes in this game — use `RegisterHook` probe scanner to discover function existence
- `NotifyOnNewObject` fires when a new UObject of that class is created
- `ExecuteInGameThread` required for game-state modification from hooks
- Out params in UFunction calls require a Lua table `{}` as placeholder
- `pcall` is essential around all UE4SS calls
- `FindAllOf("BP_BaseBuilding_Bed_C")` returns all bed actors
- `bed.Bed` accesses the `BedComponent` on the bed actor
- `cache.player:GetPlayerRestComponent()` gets the `PlayerRestComponent` (returns `BP_Components_Rest_C` at runtime)
