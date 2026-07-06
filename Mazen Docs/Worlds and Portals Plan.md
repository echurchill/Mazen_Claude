# Design Note — Worlds & Portals ("bigger on the inside")

*Captured 2026-07-06. Reframes and absorbs the [M11 Lunar Excursion Seed](M11%20Lunar%20Excursion%20Seed.md).*

> **Status: 🔨 IN PROGRESS — core built (2026-07-06).** The world-switch spine (Phase 1), portals + fade + walk-through (Phase 2), different-size worlds (Phase 4), and **the killer visual (Phase 5)** are all implemented and verified. Standing on earth you see the real **moon** hanging in the sky — its actual state, every twist baked in, slowly turning — and vice-versa from a sub-world; the moon persists so its tears stay. Portals are TARDIS beacons you step through; the arena decorations ride slices. **Remaining:** Phase 3 (hoist camera/time so they persist across worlds — currently reset per world), a real **house interior** destination (the "bigger on the inside" house door, as opposed to the moon), moon *styling/rules*, and multiple portal destinations. See the [Master Roadmap](Master%20Roadmap.md).

## The idea in one line

Structures on the cube (houses, gates, the moon) are **portals to separate worlds** — each world its own space at its own scale — so a small door on the cube can open into a large, detailed interior ("bigger on the inside," Doctor Who style). **One world-transition system serves houses, the moon, and dungeons alike.**

## Why this matters (it dissolves the scale problem)

M12-E hit a wall: the modular-kit house looks wrong when a single small kit module is stretched across a ~19m cube tile. "Bigger on the inside" **removes the constraint entirely**:

- The **exterior** on the cube stays a small, simple **facade + a door** — cheap, tidy, no stretched detail.
- The **interior** is a **separate world** with as much room as it wants, built at natural scale (where kit modules, furniture, and detail finally look right).

Interior and exterior are **decoupled**, so richness no longer fights the cube-surface scale. This is the standard pattern in Skyrim/Zelda/etc. (exterior door → load → interior far larger than the outside).

## The unification: houses and the moon are the same mechanic

Getting into a house and getting to the moon are the **same operation** — *switch the active world*:

- Enter a house → **push** the house-interior world.
- Step onto a moon-gate → **push** the moon world.
- Exit → **pop** back to the cube overworld.

The dressing differs (a house door is a quiet fade-through; the moon might get a grander launch/zoom sequence) but underneath it's **one call**. Build the world-transition system once; every "place you go" reuses it.

### The architecture already anticipates this

`WorldScale` was deliberately built **per-world, not a global singleton** — its own doc comment names "the M11 moon world" as a second world. So a small **world stack / registry** is a natural extension of what's already there, not a rewrite.

## Design sketch

- **World** = a self-contained space: its own `CubeModel`/room geometry, `WorldScale`, props, lighting, and (optionally) its own maze. The cube surface is just the first/hub world.
- **Portal** = a prop/tile with a `destinationWorld`. Fires a **transition** (fade / step-through / zoom) then swaps the active world.
  - **Target UX: step through the door (walk-through), not press-F.** The portal should trigger **automatically when the player walks onto its sub-cell** — so entering a building, a cave, or a gate feels seamless, like crossing a threshold, with no button prompt. The current F-to-enter (M11.2) is an interim using the existing `interact()` hook; the walk-through trigger (a check in the movement/arrival code that requests the switch when the destination sub-cell holds a portal) is the real goal. Keep press-F as a fallback/alternate where a deliberate action reads better (e.g. a lever-gate).
- **World stack** = push on enter, pop on exit, so nested travel (cube → house → basement) returns cleanly. State that should persist (player inventory, puzzle flags) lives above the stack; per-world layout can be regenerated or cached.
- **The cube stays the hub** — the overworld you navigate; portals are the branches to content.

## Getting to the moon — the one real fork to decide

How should the moon transition *feel*? This is the design decision to settle before building:

- **A) Instant portal** — a moon-gate you step through; quick fade; simplest, reuses the house path exactly.
- **B) Travel sequence** — a visible launch/orbit/zoom from the cube out to the moon; grander, on-theme with the M9 solar system; more work, but memorable.
- **C) Both** — same underlying world-switch, but the moon gets sequence (B) as dressing while houses get (A).

Recommendation: build the **world-switch spine first** (works for houses immediately), then add the moon's travel sequence as *presentation* on top. That way houses ship value early and the moon's grandeur is additive, not blocking.

## Implementation notes

- **Minimal spine:** an `activeWorld` the renderer/gamestate read from, a `[World]` stack, and `enterWorld(_:)` / `exitWorld()`. The draw loop, camera, and input already funnel through `GameState`; point them at `activeWorld` instead of a single fixed model.
- **Transition:** a short timed blend (screen fade or camera dolly) gating the swap so it doesn't pop.
- **First target:** a **house interior** (small hand-built room) as the simplest destination — proves the spine end-to-end before the moon's presentation work.
- **Interiors need no maze at first** — a single room validates the mechanic; maze/puzzle interiors come later.

## Implementation plan (phased) — from the codebase map

*Grounded in a 2026-07-06 read of the actual code. Surface area is ~170 lines, mostly orchestration.*

### The surface area (what assumes one world today)
- **The single anchor:** `Renderer` holds one `var gameState: GameState` and the whole draw loop reads it (`gameState.update()`, `updateFrameUniforms()`, `updateAssetInstances()`, `sceneBuilder.build(gameState:)`). *This is the thing to make swappable.*
- **Already multi-world-ready (keep intact):** `SceneBuilder.build(gameState:)` is **stateless** w.r.t. world identity; `WorldScale` is per-world; `CameraState`/`CelestialSystem`/`CubeModel` hold no cross-world refs. A world renders simply by calling `build()` with its state.
- **Reusable resources (no per-world realloc for sizes 3–9):** the maze instance buffer is sized for the max cube (6·25²), the shadow map is one 2048² texture, and the imported-asset buffers are global — all fine for push/pop where only one world is active.
- **The one genuinely hard resource:** `TileMeshLibrary` is baked from a single `WorldScale` at init, and the residency set references its buffers. A world of a **different cube size** needs a rebuilt library (+ residency update). → *sidestep this in the spine by making the first interior the same size.*
- **State that's logically global but currently lives in `GameState`:** `camera` (mode/orbit), `time`/spin, `celestialSystem`. Switching worlds shouldn't reset these — hoist or share them (Phase 3).
- **The portal hook exists:** `GameState.interact()` already has the comment "a portal would load the M11 moon" but only toggles chests — this is where the world-push goes.

### Phases (each independently verifiable)

**Phase 1 — World-stack spine (instant swap, same size).**
- `Renderer` gains `var worldStack: [GameState]`; `activeWorld` = top; the draw loop reads `activeWorld` instead of `gameState`. `enterWorld(_:)` / `exitWorld()` push/pop.
- First interior = **another same-size cube world** (e.g. a small hand-stamped room on a 7³) so `TileMeshLibrary`, buffers, and residency set are all reused unchanged.
- Temporary debug key to swap worlds (no portal/transition yet) — isolates the plumbing.
- **Deliverable:** press a key, the rendered world swaps and swaps back, both states intact.

**Phase 2 — Portal + transition.**
- ✅ **2a (done):** `PropKind.portal` + a beacon mesh; `interact()` (F) sets `portalRequested`; the Renderer consumes it and toggles the world. A portal on the interior's start tile pops back.
- **2b:** a short **screen fade** (fullscreen quad, alpha ramp ~0.3s) gating the swap so it doesn't pop.
- **2c (refinement, wanted):** **walk-through trigger** — auto-switch when the player steps onto the portal's sub-cell, so entering a building/cave feels seamless (see the Portal bullet above). Interim is F.
- **Deliverable:** step into a doorway, fade into the interior, step back out through a gate.

**Phase 3 — Hoist the globals.**
- Move `camera` mode, `time`/spin, and `celestialSystem` so they **persist across worlds** (a small session/app holder above the stack, or shared refs). Day/night and camera mode survive a portal.
- **Deliverable:** switch worlds; time-of-day and camera mode don't reset.

**Phase 4 — Different-size interiors.**
- `TileMeshLibrary` **cache keyed by cube size** (or lazy rebuild) + residency-set handling on library change.
- **Deliverable:** a 3³ interior world reached from the 7³ overworld.

**Phase 5 — The moon + the killer visual.**
- The moon as a second world (its own palette/rules); then render the **orbital counterpart** — the *real* other world's tiles at their orbital position in the sky (negligible cost via the existing instanced path), updated live with its actual twists.
- The **moon-transition feel fork** (instant vs travel sequence) lands here as *presentation* on top of the Phase 1–2 spine.
- **Deliverable:** stand on the moon, see the real cube (with your scars) hanging in the starfield.

### Risks & mitigations
- **`TileMeshLibrary`/residency rebuild cost** → deferred to Phase 4; the spine uses same-size worlds so nothing rebuilds.
- **Inactive-world state loss** → the stack *retains* each `GameState`; never rebuild a world on return (that's the whole point — persistent scars).
- **Shadow map / buffers are single** → fine for push/pop (one active world); only simultaneous split-view would need duplicates.
- **The render pipeline is cube-face-shaped** → interiors are *cubes* (or rooms stamped on a cube) for now, not arbitrary geometry; a truly free-form interior is a later, separate lift.

## How it relates to the other threads

- **[Bandaged Cube Mechanic](Bandaged%20Cube%20Mechanic.md):** portal-worlds *reduce* the need for cube structures to split — most content lives inside portals, so the twist can be a rare, deliberate puzzle action rather than something every surface structure must survive. The two ideas reinforce "twist = scalpel, not ambient."
- **[Superellipsoid Cube](Superellipsoid%20Cube.md):** orthogonal (a visual treatment of the hub world). A moon world could itself be a superellipsoid "planet."
- **[M11 Lunar Excursion Seed](M11%20Lunar%20Excursion%20Seed.md):** this note **reframes** it — the moon becomes the first showcase of the general transition system rather than a bespoke feature.

## Open questions

- Instant vs travel-sequence for the moon (the fork above).
- What state persists across worlds (player, inventory, puzzle progress) vs is per-world.
- Are interiors authored by hand, generated, or a mix?
- Does the cube overworld keep simulating (sun/spin) while you're inside a portal-world, or freeze?
- Visual language that reads "this door goes somewhere" vs a decorative structure.
