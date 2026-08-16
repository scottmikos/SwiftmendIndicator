# SwiftmendIndicator

A Restoration Druid addon for WoW Midnight (11.2 client / `Interface: 120100`). It draws a small
colored dot on party and raid unit frames to mark units that currently have a player-cast
Swiftmend-consumable HoT — but only while Swiftmend itself is off cooldown. When Swiftmend is
down, every dot hides; when it comes back up, the dots reappear on whichever units still qualify.

The addon has no unit frames of its own. It attaches to a third-party frame addon through an
adapter (currently DandersFrames only).

## File layout

| File | Role |
| --- | --- |
| `SwiftmendIndicator.toc` | Load order + `## SavedVariables: SwiftmendIndicatorDB` |
| `SwiftmendIndicator.lua` | Everything: aura container pool, cooldown logic, events, slash commands, settings panel |
| `Adapters/DandersFrames.lua` | Frame discovery only — which frames are visible and what unit each shows |

Load order in the `.toc` is significant: the core file creates the global `SwiftmendIndicator`
table and `SI.RegisterAdapter`, and each adapter file calls `SI.RegisterAdapter(...)` at file
scope. Adapters must be listed after the core.

## The central constraint: secret aura values

This is the design driver for nearly every odd-looking decision in the codebase. **Read this
before changing anything.**

As of 12.1, aura data on group members is *secret* in combat. The addon therefore **never reads
auras at all** — there is no `C_UnitAuras` call anywhere, and adding one is not a fix for
anything.

Instead, detection is delegated to the game:

- Each pool entry owns an `AuraContainer` (`CustomAuraContainerTemplate`) holding exactly one
  `AuraSlot`, added with the `"HELPFUL|PLAYER"` filter and
  `candidateFilters = { includeSpellIDs = ... }` built from `HOT_SPELL_IDS`.
- `HOT_SPELL_IDS` is `{ 774, 8936, 48438, 155777 }` — Rejuvenation, Regrowth, Wild Growth,
  Germination. **Detection is spell-ID based**; there is no name matching and no aura iteration.
  Adding a HoT means adding its ID to that table, nothing more.
- The container shows the slot's button when a matching aura is present. We never learn *whether*
  it matched — the visible dot is the only signal, and it is produced inside the restricted
  system where we cannot observe it.

We control only the *container's* visibility, driven by Swiftmend's cooldown, which is still
readable. So the two conditions compose: the game decides "does this unit have my HoT", we decide
"is Swiftmend up", and the dot appears only when both hold.

### Hard rule: containers and slots are out-of-combat only

`AuraContainer` and `AuraSlot` objects **can only be created outside combat**. Creating them in
combat fails *silently* — no error, no Lua warning, just nothing. This was established by
experiment, not from documentation.

Consequences baked into the design:

- A pool of `POOL_SIZE = 45` entries (party 5 + raid 40, the worst case) is pre-built out of
  combat by `SI.BuildPool`.
- The roster is handled by **re-pointing existing entries**, never by creating new ones.
  `SetPoint`, `SetUnit`, `Show` and `Hide` are all combat-safe.
- If the addon loads mid-combat, `BuildPool` bails and retries on `PLAYER_REGEN_ENABLED`.
- Aura buttons get a fixed generous `BUTTON_SIZE = 32`; the visible dot is a texture *inside* the
  button that we size ourselves. Appearance settings therefore never require rebuilding a
  container — which we could not do in combat anyway, and which would leak frames, since WoW
  frames cannot be destroyed.

### What is still readable

`C_Spell.GetSpellCooldown(18562)` is not secret. Note the field semantics in
`SI.SwiftmendIsReady`, which are easy to get backwards:

- `info.isActive` is **true while the spell is on cooldown**.
- `info.isOnGCD` is checked so the global cooldown does *not* count as unready — without it the
  dots would blink off after every cast.

## Key functions

All live in `SwiftmendIndicator.lua` unless noted.

### Pool construction (out of combat)

- **`CreateEntry()`** — builds one container + slot pair. Returns an entry table:
  `{ container, slot, tex, mask, frame, unit, active, dirtyAnchor }`. Slots, unlike aura *groups*,
  are not auto-anchored, so it explicitly sizes and centers the slot in its container.
- **`MakeInitializeFrame(entry)`** — returns the `initializeFrame` callback the container invokes
  once, when it first creates the button for that slot. Two deliberate omissions to preserve:
  - **Never call `SetIcon`.** Without it the button draws nothing of its own, leaving only our
    texture. Calling it would put a spell icon under the dot.
  - **`SetMouseMotionEnabled(false)`** keeps the button from eating mouse input, so it cannot
    interfere with click-casting on the unit frame beneath it.

  It also creates the dot texture (`entry.tex`) and a circular mask (`entry.mask`), then styles it.
- **`SI.BuildPool()`** — creates `POOL_SIZE` entries. Idempotent via `poolBuilt`; returns `false`
  and defers if called in combat.

### Per-frame assignment

- **`SI.Refresh()`** — the main entry point. Builds the pool if needed, collects frames from every
  active adapter, and hands the list to `AssignFrames`.
- **`AssignFrames(list)`** — maps list entries onto pool entries by index. Two short-circuits
  matter for performance and are worth preserving: it re-anchors only when `entry.frame` actually
  changed (or `dirtyAnchor` is set), and calls `SetUnit` only when `entry.unit` changed. Unused
  entries are marked inactive and hidden.
- **`SI.MarkAnchorsDirty()`** — flags every entry for re-anchoring and refreshes. Call this after
  changing anchor point, offsets, or frame level.

### Visibility

- **`SI.SwiftmendIsReady()`** — `IsSpellKnown` guard plus the cooldown check described above.
- **`SI.UpdateVisibility()`** — shows a container only if it is both `active` (assigned to a
  visible frame) and Swiftmend is ready. Cheap; safe to call on every `SPELL_UPDATE_COOLDOWN`.

### Appearance

- **`StyleEntry(entry)`** — sizes/colors the dot texture, rotates it 45° for the diamond shape, and
  adds or removes the circular mask. No-ops if `entry.tex` is nil (button not created yet — it gets
  styled on creation instead).
- **`SI.ApplyStyleToAll()`** — restyles the whole pool. **If called in combat it sets
  `stylePending` and returns**, because touching aura button children while auras are secret is
  unreliable. The deferred restyle runs on `PLAYER_REGEN_ENABLED`.

### Settings

- **`SI.BuildSettingsPanel()`** — registers the Blizzard settings category using
  `Settings.RegisterProxySetting` throughout. Called from `ADDON_LOADED`, after defaults are merged.

## Adapter contract

An adapter is a plain table registered with `SI.RegisterAdapter(adapter)`. It must implement:

```lua
adapter.name                -- string
adapter:IsActive()          -- true when the target frame addon is present and usable
adapter:GetActiveFrames()   -- array of { frame = <Frame>, unit = <unitToken> }
                            -- visible frames only, deduplicated by frame object
```

**Frame discovery is the adapter's entire job.** No aura logic, no cooldown logic, no styling —
all of that lives in the core. Keep it that way; the core is where the restricted-API assumptions
are documented and enforced.

The two invariants in the return contract exist because of real quirks in DandersFrames, and any
new adapter will likely need to handle the equivalents:

- **Visible frames only.** `DandersFrames.unitFrameMap` holds both the party and raid frame sets
  simultaneously, with only one set shown at a time. Filtering on `frame:IsVisible()` is what keeps
  hidden frames from consuming pool entries.
- **Deduplicated by frame object.** The same map points several unit tokens (e.g. `"player"` and
  `"raid1"`) at one frame. Without the `seen` dedupe, one frame would receive multiple containers
  stacked on top of each other.

## Conventions

- **Wrap restricted-API calls in `pcall`.** Every call that touches a container, slot, aura button
  or its children is wrapped, with the failure reported through `SI.Debug`. The restricted system
  changes between patches and silent failure is the norm — a raw call that starts erroring will
  break the addon on login for everyone.
- **`SI.Debug(...)` over bare `print`.** It is gated on the `debugMode` flag toggled by
  `/si debug`. Only user-facing slash command output uses `print` directly.
- **`SI.db` *is* the SavedVariables table**, not a copy. `ADDON_LOADED` merges `DEFAULTS` into
  `SwiftmendIndicatorDB` for any missing key and assigns it to `SI.db`; settings setters mutate it
  in place, so there is no save step.
- **Adding a setting** means three things: a key in `DEFAULTS`, a `Settings.RegisterProxySetting`
  block in `BuildSettingsPanel`, and the right refresh call in its setter —
  `SI.ApplyStyleToAll()` for anything about the dot's appearance, `SI.MarkAnchorsDirty()` for
  anything about its position or frame level.
- **Timers after events.** `PLAYER_ENTERING_WORLD` refreshes after 1.0s and roster/spec changes
  after 0.5s, because frame addons need a moment to lay out their frames. Removing these delays
  produces frames that are not yet visible and get skipped.

## Events handled

`ADDON_LOADED` (init + settings), `PLAYER_ENTERING_WORLD` (delayed refresh),
`PLAYER_REGEN_ENABLED` (deferred pool build and deferred restyle), `GROUP_ROSTER_UPDATE`
(delayed refresh), `SPELL_UPDATE_COOLDOWN` (visibility only), `PLAYER_SPECIALIZATION_CHANGED`
(visibility + delayed refresh).

## Testing

There is no test harness and no way to run this outside the game client. Verification is in-game:

```
/si status    -- pool built?, pool size, in combat?, active containers, swiftmend ready?
/si debug     -- toggle debug output
/si refresh   -- force a frame re-scan
```

Then `/reload` to pick up file changes.

Be aware that **reading the code cannot catch the combat-only failures**, because the failure mode
is silence rather than an error. Any change touching container or slot creation needs to be
exercised by actually entering combat, and any change to pooling needs to be exercised at raid
size, not just in a party.
