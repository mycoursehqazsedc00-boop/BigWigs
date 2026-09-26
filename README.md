# BigWigs — FPS & Stability Fixes

Patch on top of the Turtle WoW [`pepopo978/BigWigs`](https://github.com/pepopo978/BigWigs) fork, addressing reported FPS drops when facing bosses (and busy trash packs) on patch 1.12.1 / Turtle WoW.

Everything below was found by static code review of this repo, not by profiling in a live client. Where a fix could be tested outside the game (pure-Lua logic), it was simulated/unit-tested under Lua 5.1 and the result is noted. **FPS numbers reported by players are the real validation** — see [Testing](#testing) below.



## Client mods considered

These are optional, external 1.12.1 client modifications — none are required, and nothing here depends on them being installed. `ClientMods.lua` (new, see below) detects them at runtime.

| Mod | What it offers here | Used? |
|---|---|---|
| [SuperWoW](https://github.com/balakethelock/SuperWoW/wiki) | `UNIT_CASTEVENT` — structured cast info instead of text parsing | Detected only. Several boss modules already use it *alongside* text triggers (Firemaw, Ebonroc, Flamegor, Nefarian); migrating them to use it *instead of* text triggers is a follow-up, not done here. |
| [nampower](https://github.com/brues-code/nampower) | Structured spell/aura events | Detected only. Already used by `MageTools`. Could replace Proximity's debuff polling — not done here. |
| [UnitXP_SP3](https://codeberg.org/konaka/UnitXP_SP3/wiki) | `distanceBetween` — real yard distances | Detected only. Would improve Proximity's accuracy (currently fixed-range checks), not its FPS cost — not done here. |
| [ClassicAPI](https://github.com/brues-code/ClassicAPI) | Native `C_Timer`, allocation-free `C_UnitAuras.UnitAura` | Detected only. Not used by any fix in this patch. |
| [VanillaHelpers](https://github.com/isfir/VanillaHelpers) | — | Detected only. Nothing here uses it. |
| [WeirdUtils](https://codeberg.org/MarcelineVQ/WeirdUtils/) (`weirdperformance.dll`, `dpslog.dll`) | Incremental/generational GC, `string.find` literal prefilter, WotLK-style `COMBAT_LOG_EVENT_UNFILTERED` | Detected only (`GetWeirdUtilsVersion`, `CombatLogGetCurrentEventInfo`). Attacks the same problems from the engine side (GC pauses, text-parsing cost) — complementary to, not a dependency of, the fixes below. Not required. |

**None of the fixes below require any client mod.** They're all pure-Lua changes to BigWigs itself.

## Fixes

### 1. `Libs/AceEvent-2.0/AceEvent-2.0.lua` — scheduler
The timer-event scheduler copied and walked its *entire* queue every rendered frame, even when nothing was due for seconds. Now it tracks the next-due timestamp and skips the walk until then.
- Simulated (120s fight, 150 queued events + repeaters + callback-scheduled/cancelled events): registry walks **7,200 → 362**. All 416 events fired at identical times versus the original.

### 2. `Libs/CandyBar-2.2/CandyBar-2.2.lua` — timer bars
Every bar, every frame, ran `string.format` + `SetText` + `SetValue` + spark `SetPoint`, regardless of whether the displayed value changed. Now throttled to ~30Hz, and text is only rewritten when it actually changes.
- Simulated (one 60s bar at 144fps): `SetText` calls **8,640 → 150**. Same visible countdown text, except the very last "0.0" frame is skipped.

### 3. `Raids/AQ40/Cthun.lua` — proximity map
Refreshed on every rendered frame: ~40× `GetPlayerMapPosition` plus Show/SetPoint/SetTexture/SetWidth/SetHeight per raid member. Throttled to 10Hz.

### 4. `Plugins/Threat.lua` — debug logging
Built full debug strings (concatenating per-player threat/tank info) for every packet even when debug was off. Now gated behind the actual `/bw debug` flag.

### 5. `Plugins/Proximity.lua` — nearby-player check
Allocated two fresh tables every tick (10Hz) instead of reusing the ones it had just cleared, and rewrote its FontStrings every tick even when the text was unchanged. Both fixed.

### 6. Interrupt/melee event gating — `Kelthuzad.lua`, `Thekal.lua`, `Jeklik.lua`, `BugFamily.lua`
These four modules were the worst in a codebase-wide audit (17–20 raid-wide combat-log event registrations each). In each, the kick/pummel/shield-bash/earth-shock and creature-melee events only feed a branch guarded by a state flag (`castingFrostbolt`, `castingHeal`, `castingMindFlay`). They were registered for the *entire* fight but only mattered while that flag was set. Now registered only while the flag is set, and dropped when it clears or the module resets.
- Jeklik has two flags (`castingHeal`/`castingMindFlay`); the watch stays active while either is set and drops only when both clear — unit-tested (no double registration, fully unregisters when both are off).
- All reset paths (engage-reset, death-triggered reset, normal Over/Stop) were traced by hand to confirm the disable call is always paired with the flag clear.

### 7. Combat-log-range CVar leak — `Kelthuzad.lua`
Turtle WoW exposes eight client CVars (`CombatLogRangeParty`, `CombatLogRangeFriendlyPlayers`, `CombatLogRangeHostilePlayers`, `CombatLogRangeCreature`, `CombatDeathLogRange`, + pet variants) that control how far away the client even *generates* combat-log text — this is upstream of every text-parsing cost in the addon. `Kelthuzad.lua`'s `OnEnable()` force-set all eight to their 200-yard (unlimited) maximum "to make sure players don't miss any events" — and **never restored them**. One Kel'Thuzad pull silently pinned your combat-log range at maximum for the rest of the session, inflating text volume for *every other boss afterward*, not just Kel'Thuzad. (`Victory()` already restored a different setting, `farclip`, on kill — proving the pattern was known, just not applied here.)
- Fixed: the CVars are snapshotted the first time they're overridden, and restored to their original values in `Victory()` on kill. Deliberately **not** restored on wipe, to avoid changing whether the encounter's own triggers fire reliably across repeated pulls within one raid ID — see the file for the reasoning.
- Unit-tested: values captured once, stay maxed across repeated (simulated) wipes, restored exactly on kill.

### 8. `plain=true` sweep — codebase-wide, 1,017 call sites
Almost every trigger in the addon is matched with `string.find(msg, L["trigger_xxx"])`, which runs Lua's full pattern-matching engine even when the trigger string is plain literal text with no pattern syntax. Every one of the 1,017 such call sites in the codebase was audited; where the trigger string is plain across *every* locale translation (not just enUS), the call now passes `plain=true`, switching it to a cheap substring search instead of pattern compilation/matching. Triggers containing real pattern syntax (capture groups like `(.+)`, or literal `.`/`-`/`%`) were left untouched — this changes *how* Lua searches, never *what* matches.
- This matters most exactly when several *different*, untracked mobs are fighting alongside a tracked one (e.g. a ZG pull mixing Gurubashi Berserkers with untracked Hakkari Priests/Witch Doctors/Axe Throwers) — the tracked module's handler still has to test every irrelevant line, and each test is now cheaper.

### 9. World-boss idle-timeout watchdog — `Core.lua`
`CheckForWipe()` only resets a module once `UnitAffectingCombat` is false for the player *and every raid member*. For an outdoor world boss that can chain-aggro across a huge area (`Lethon.lua`'s own `zonename` spans four zones), it only takes one straggler still tagged in combat *anywhere* for that condition to never clear — so a failed or retreated pull left the module "engaged" indefinitely until a raid leader manually ran `/bw reboot`.
- Fixed: `Engage()` now stamps an engage timestamp; `CheckForWipe()` gained an independent, combat-flag-agnostic ceiling (`module.maxEngageDuration`, default 20 minutes) that force-reboots the module regardless of anyone's combat status, with a chat message explaining why. Any module can override the threshold or set it to `false` to disable. Purely additive — doesn't touch the existing combat-flag detection.
- Unit-tested (5 scenarios): a normal short fight never trips it; a stuck module trips right at 20:00; a per-module override trips at its own threshold; `false` disables it even after an hour; a clean wipe-then-repull resets the clock instead of carrying over elapsed time.

### 10. New: `ClientMods.lua`
Detects the client mods in the table above at load. `/bwmods` prints what was found.

### 11. New: `Plugins/FpsProbe.lua`
`/bwperf start` / `/bwperf stop` samples FPS, Lua memory allocation rate, GC runs, and peak scheduled-event/bar counts once per second between the two commands, and prints a summary — for collecting real evidence on a specific pull. `/bwperf auto` samples every combat automatically.

## What wasn't found to need fixing

Audited but left alone, with reasoning:
- **`Raids/ZG/Hakkar.lua`** — 11 always-on event registrations, but every trigger is relevant for the entire fight (no phase/cast gating applies); no CVar override; add-tracking (Sons of Hakkar) uses an aggregate counter, not per-add state, so no leak.
- **`Raids/ZG/GurubashiBerserker.lua`** and other same-name-mob packs — multiple simultaneous copies of one mob type reset a single shared, name-keyed bar rather than creating duplicates; no leak or state-stacking risk by construction.
- **AQ40 Guardians+Defenders, Champion+Brainwasher, BWL Wyrmguards+Alchemists** — initially flagged as a "multiple concurrently-active trash modules" risk, but confirmed these packs are in separate raid sections and never actually overlap.
- **`UNIT_HEALTH` handlers** (21 modules) — cheap (one `UnitName` call per event, only in the currently-active module); not worth gating.

## Testing

- **Regression:** the patch reproduces the patched tree byte-for-byte when reapplied to a clean checkout of the original files. All 219 `.lua` files pass `luac5.1 -p` (syntax check).
- **Simulated/unit-tested where possible** (Lua 5.1, no WoW client): the AceEvent scheduler, CandyBar throttling, the interrupt-gating logic, the CombatLogRange save/restore lifecycle, and the idle-timeout watchdog — see inline notes above.
- **Not yet tested in a live client.** To validate for real:
  1. `/bwperf start`, pull a boss *before* Kel'Thuzad, `/bwperf stop` — this is your baseline.
  2. Fight/kill or wipe Kel'Thuzad normally.
  3. `/bwperf start`, pull a comparable boss *after* Kel'Thuzad, `/bwperf stop`.
  4. Compare (3) to (1). On unpatched BigWigs, (3) should look worse purely from the leaked combat-log-range setting; on patched, it should match (1).
  5. For the watchdog: deliberately let a world-boss pull (Lethon/Emeriss) fail and don't `/bw reboot` manually — it should auto-reset with a chat message ~20 minutes after engage.

## Files changed

```
BigWigs.toc                              (load ClientMods.lua, Plugins/FpsProbe.lua)
README.md                                (Optional client mods / Diagnosing FPS problems sections)
ClientMods.lua                           (new)
Plugins/FpsProbe.lua                     (new)
Plugins/Threat.lua
Plugins/Proximity.lua
Libs/AceEvent-2.0/AceEvent-2.0.lua
Libs/CandyBar-2.2/CandyBar-2.2.lua
Core.lua
Raids/AQ40/Cthun.lua
Raids/Naxxramas/Kelthuzad.lua
Raids/ZG/Thekal.lua
Raids/ZG/Jeklik.lua
Raids/AQ40/BugFamily.lua
+ 1,017 string.find() call sites across ~125 additional Raids/*.lua files (plain=true sweep only)
```
