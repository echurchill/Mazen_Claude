# Design Note — Worlds & Portals ("bigger on the inside")

*Status: concept / future milestone. Captured 2026-07-06. Reframes and absorbs the [M11 Lunar Excursion Seed](M11%20Lunar%20Excursion%20Seed.md).*

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
- **Portal** = a prop/tile with a `destinationWorld`. Triggered by walking through or interacting (`F`). Fires a **transition** (fade / step-through / zoom) then swaps the active world.
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
