# ASPIRATIONAL — Freeform Movement & Solidity (not the M18 plan)

> **⚠️ Superseded as the M18 plan (2026-07-11, same day it was drafted).** Eddie
> counter-proposed a far cheaper path that delivers most of the value: densify the stand-point
> grid (3×3 → 9×9-ish), allow standing on the grass, and make solidity = *removing the stand
> points under walls and props*. That is now the real **[M18 Work Plan](M18%20Work%20Plan.md)**.
> This document is kept as the **aspirational north star**: if the game ever wants true
> continuous movement + free yaw, the analysis below (tile-anchored representation, analytic
> colliders, edge-crossing risk, feel gate) is where to restart — and the densified grid's
> footprint data is deliberately the same data this plan's colliders would consume.


*Drafted 2026-07-11 at Eddie's call: "we need to make walking more free form (not just a few
points on the walk ways) and the poly/3d shapes more 'real'." Two long-standing simplifications
retire together, because they're the same problem: **where can the player BE** (continuous
position, not path-cross points) and **what stops them** (walls and props become solid).
Numbering note: this claims the M18 slot; the informal "one small solar system" milestone
becomes **M19**, cozy/feel polish **M20**. Status: **📋 awaiting greenlight.***

## What exists today (the thing being replaced)

`PlayerState` is a tile anchor `(face, row, col)` plus a discrete sub-cell `(subRow, subCol)`
on the 3×3 **path cross** — movement is scripted hops between those points (`startMove` /
`beginMove` / `updateMovement`), facing is 8-way `Heading8` with snap turns, tiles are only
exited through an edge-middle cell + open gateway, and **nothing collides** — the player
ghosts through dials, plaques, pillars, and (if aimed right) hedge geometry. It has been a
great scaffold: reliable, cross-face-correct, twist-riding-correct. M18 keeps everything it
proved and swaps the representation underneath.

## The architectural bet

**Keep the tile anchor; free the offset.** The player becomes `(face, row, col)` + a
*continuous* tile-local offset (float, in sub-cell units) + a *continuous* yaw. Crossing a
tile boundary re-anchors to the neighbor (same `edgeCrossing` math, now applied to a float
offset + velocity + yaw instead of a sub-cell index). Why this and not a raw world-space
position: every system that works today — walk-through portals, prop interact, discovery,
slice riding (the anchor tile's `restMatrix` already carries `animMat`), the twist-remap of
the player, the M15 interior basis — is keyed by tile. Anchored-continuous keeps their blast
radius near zero; `subRow/subCol` and `facing: Heading8` survive as *derived* (rounded)
properties during bring-up so nothing breaks mid-refactor.

Collision is **analytic, not mesh-based**: walls are derived from `mazeTile.openings` (the
same truth the wall meshes are built from — they cannot drift apart), props from a small
per-kind footprint table. Circle-vs-slab in tile-local 2D with slide response. All of it is
pure shared-code math — no Metal — so the headless harness can hammer it.

## Phases

### Phase 0 — Representation swap (no behavior change)
Continuous `offset: SIMD2<Float>` + `yaw: Float` inside PlayerState; hops re-expressed as
short glides between the same points; derived `subRow/subCol/facing` keep every consumer
(HUD, interact, portals, twist remap, `steerToLook`) working untouched.
*Danger:* Med (touching the spine everything stands on). *Verify:* plays identically to today.

### Phase 1 — Free locomotion (feel-first, still no collision)
Held-key velocity (WASD-style) relative to camera yaw with short accel/decel ramps; free
continuous yaw (D1); speed matched to today's ~1.2 s/tile. Tile exits no longer require the
edge-middle cell — you walk where you point. Gateways still gate at this phase via a cheap
"is the crossing open" check so the maze stays a maze before walls are solid.
*Danger:* Med. *Verify:* feel pass — Eddie walks the overworld; cozy or bust.

### Phase 2 — Solid walls
Per-tile collider set from `openings`: closed edge → full-edge slab; open edge → two flanking
slabs leaving the gateway gap; jamb posts. Player circle (radius, D3) vs slabs, **slide**
response (velocity projected along the wall, no sticky stops). Near edges, the 3×3 tile
neighborhood's colliders are consulted (with the face-edge basis remap at cube borders).
Phase 1's gateway check retires — geometry itself now does the gating.
*Danger:* Med. *Verify:* headless invariant tests (never penetrate, gateways passable,
corners never trap, fuzz-walk N thousand random inputs stays in legal space) + feel pass.

### Phase 3 — Solid props
A footprint (circle or box) per `PropKind` in one table: pedestals, dials, obelisks, plaques,
pillars, house walls; imported assets auto-derive from mesh bounds × target scale. Portals
stay walk-through (their trigger is the point of them); small ground decor stays ghost (D4).
This closes the plaque saga for good: a plaque can sit anywhere and simply can't be stood in.
*Danger:* Low-Med (tuning which footprints feel fair). *Verify:* can't walk through a dial;
can still reach its F-interact range comfortably.

### Phase 4 — Seams, faces, interiors
Continuous crossing at cube edges: offset, velocity, and yaw remapped through `edgeCrossing`
(the discrete version of this remap already exists in the twist player-carry — same pattern);
the interior worlds' mirrored basis goes through the same conjugated path M15 proved. Camera
up-vector slerp across edges (the corner-cut treatment) so walking over a cube edge stays the
signature "horizon rolls toward you" moment, now without the hop rhythm.
*Danger:* **High** — this is the hard math of the milestone. *Verify:* world-position-pinned
continuity tests (the M15 technique): walk a straight line across every edge of every face,
exterior and interior, at several sizes; position and heading must be continuous.

### Phase 5 — Twists + curvature under continuous feet
Riding a rotating slice already works via the anchor tile; verify with continuous offset
(including walking *while* the slice turns — now possible, decide if allowed, D5). Refusal
wobble unchanged. M14b: movement math stays in flat rest space, the camera seats via
`inflatedPlacement` exactly as today — verify feel at roundness 0.5 (gentle slopes underfoot).
*Danger:* Med. *Verify:* twist while walking; moon at 0.5 roundness feel pass.

### Phase 6 — Retire the scaffold
Delete the hop state machine (`isMoving/moveProgress/moveTo*`, snap-turn state), collapse the
derived-compat shims that turned out unneeded, update the HUD. Docs + STATE OF PLAY sweep.
*Danger:* Low. *Verify:* full test suite + one long play session.

**M18 exit criterion:** walk anywhere the geometry allows and nowhere it doesn't — smoothly,
across tile seams, cube edges, and interior mirrors, while slices twist and the world curves —
with the maze, portals, locks, dials, and plaques all behaving exactly as before.

## Decision points for Eddie

- **D1 — Steering.** (a) *Free yaw* (recommended): held arrow keys / mouse-look turn smoothly,
  any angle; `Heading8` lives on only as a derived value where systems need a discrete
  direction (portal exit facing, interact). (b) Keep 8-way snap turns over continuous
  translation — cozier rhythm, but fights the freeform goal.
- **D2 — Collision source:** analytic from `openings` + footprint table (recommended) vs.
  colliders generated from the render meshes (heavier, drift-proof by construction, overkill
  for box hedges).
- **D3 — Player radius:** proposed ~0.25 sub-cell — wide enough that walls feel like walls,
  narrow enough that a gateway (one sub-cell) never pinches. Tuned in the Phase 2 feel pass.
- **D4 — What's solid:** walls, jambs, pedestals/dials/obelisks/plaques/pillars/house/imported
  assets solid; portals walk-through; flags/vase/small decor ghost (recommended) — or
  everything solid for maximum "real".
- **D5 — Walking during a twist:** freeze feet while riding (today's rule, recommended for v1)
  vs. free walking on the rotating slice (delightful, but collision against mid-rotation
  neighbors is a can of worms — note for M15.3's percept experiment, which this milestone
  makes much easier).
- **D6 — Input mapping:** keep keyboard-only (arrows/WASD + Caps-Lock mouselook) for now
  (recommended); full mouse-look default and iOS touch design are their own later item.

## Risks

1. **Feel regression.** The grid-hop is reliable and cozy; continuous movement can feel
   floaty or jittery. Mitigation: Phase 1 is a feel gate — if it doesn't feel *better*, stop
   and reassess before any collision work.
2. **Hidden discrete couplings.** Portals, interact, discovery, twist-remap, `steerToLook`,
   `framePose` caching all assume the anchor model somewhere. The anchored-continuous
   representation + derived-compat shims are the mitigation; Phase 0 exists to flush these
   out while behavior is still identical.
3. **Cube-edge crossing is the hard part** (Phase 4). Same class of problem as M15's inverted
   basis — solved the same way: world-position-pinned headless tests before believing eyes.
4. **Scope creep into physics.** No jumping, no gravity sim, no dynamic bodies — "solidity"
   means *you can't stand inside things*, nothing more.
