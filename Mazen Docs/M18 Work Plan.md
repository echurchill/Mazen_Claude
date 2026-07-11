# M18 — Densified Grid Movement & Solidity (work plan)

*Drafted 2026-07-11 from Eddie's counter-proposal to the freeform plan (kept as the
[aspirational north star](M18%20Freeform%20Movement%20%28Aspirational%29.md)): instead of
continuous movement, **densify the stand points** (3×3 → 9×9-ish), let the player step off the
paths onto the grass, and make walls/props solid by **removing the stand points under them**.
Numbering: M18 = this; solar-system slice = M19; cozy/feel polish = M20.
Status: **📋 awaiting greenlight.***

## Why this shape (the trade, honestly)

The freeform plan's two big risks were continuous cube-edge crossing (hard math) and feel
regression (the game's cozy rhythm lives partly in the hop cadence). This plan keeps the hop
state machine **structurally untouched** — `subRow/subCol` just range wider — so every
discrete coupling (portals, twist player-remap, interact, discovery, `steerToLook`) survives
with mechanical coordinate scaling. Edge crossing stays a discrete hop through the existing
`edgeCrossing` remap. Solidity needs no physics at all: a prop subtracts the cells it sits on
from the walkable set, and `startMove`'s existing "is the target cell standable" check does
the rest. What we give up, for now: free yaw (heading stays 8-way) and sub-cell smoothness.
What we keep forever: the footprint data is exactly what a future continuous-collision system
would consume — a stepping stone, not a detour.

## Core concepts

- **Density `d`** — one constant, everything derived. Must be an **odd multiple of 3**
  (9, 15, 21): multiple-of-3 makes every legacy 3×3 coordinate scale by an exact integer
  `k = d/3`; odd keeps a true centre cell (spawn, portals, twist-remap rounding rely on one).
  At perceptual scale (tile ≈ 19 m): 9×9 → ~2.1 m cells (a stride), 15×15 → ~1.3 m.
  Ground speed is normalized (`hopDuration = 1 / (speed · k)`) so density never changes pace.
- **Walkability mask** — per-facelet `d×d` bitmask, derived: start all-walkable (**grass is
  standable** — the freedom this milestone buys), subtract hedge walls + jambs (from
  `mazeTile.openings`, the same truth the wall meshes are built from), subtract prop
  footprints. Lives with the facelet → rides slice rotations for free; re-derived when props
  change (e.g. M17's mote leaving its pedestal frees the cell).
- **Footprints** — a per-`PropKind` table of cell spans (procedural props have authored sizes
  in TileMeshLibrary); imported assets auto-derive from mesh bounds × target scale, rounded
  outward. `footprint = none` for props that must stay standable (portals — stepping on them
  IS the trigger) and ghost-decor.

## Phases

### Phase 0 — Densify (behavior-identical)
Introduce `d` and the integer scaling: prop subcell coordinates, `edgeMiddle`, spawn centre,
player marker, portal/interact positions, the twist player-remap. First flip walkability to
*exactly the scaled path cross* so the game plays identically to today — this flushes every
hidden `0...2` assumption while behavior is still bit-comparable.
*Danger:* Med (wide but mechanical). *Verify:* plays identically; headless remap tests.

### Phase 1 — Open the grass, mask the walls
Walkable-by-default + wall/jamb subtraction replaces the path-cross rule. The player steps
off the path for the first time. Gateways now gate by geometry (the wall cells), not by the
edge-middle rule — tile exits allowed from any open edge cell, crossing to the neighbour's
mirrored cell through `edgeCrossing` (generalizing the existing sub-cell remap pattern).
*Danger:* Med — the edge/interior sub-cell remap is this plan's hardest math (a far smaller
cousin of the freeform plan's Phase 4). *Verify:* world-position-pinned crossing tests (the
M15 technique) over every edge, exterior + interior, several sizes; then a feel walk.

### Phase 2 — Solid props (stand-point removal)
The footprint table + auto-derived imports; subtraction into the mask. A plaque, dial,
pedestal, pillar, or house wall simply cannot be stood in — the plaque saga becomes
inexpressible rather than merely fixed. Includes the **connectivity sanity check**: a
footprint may never disconnect a tile's gateways from each other (authoring mistakes become
log lines, not unwinnable mazes).
*Danger:* Low-Med. *Verify:* can't occupy a prop's cells; F-interact still reaches from
adjacent cells; connectivity check fires on a deliberately bad stamp in tests.

### Phase 3 — Density & pace tuning (Eddie's phase)
`d` is already a constant; add a debug key to cycle 9 ↔ 15 (rebuild scene + remap player,
like the `N` size cycle) and run a feel pass: stride rhythm, footprint fairness around the
dials/plaques, grass wandering, diagonal movement (D2). Lock the default; decide whether `d`
stays per-world (WorldScale) or global.
*Danger:* Low. *Verify:* Eddie's verdict — this phase exists to be played, not coded.

### Phase 4 — Sweep & retire assumptions
HUD shows the finer position; delete the temporary path-cross-equivalence shim from Phase 0;
docs + STATE OF PLAY; note what the aspirational plan would still add (free yaw, sub-cell
smoothness) so the north star stays visible.
*Danger:* Low. *Verify:* full suite + a long play session.

**M18 exit criterion:** walk anywhere on a tile the geometry honestly allows — including the
grass — and never into a wall, plaque, dial, pedestal, or house; across tile seams, cube
edges, and interior mirrors; while slices twist; at a density that survived a real feel pass.

## Decision points for Eddie

- **D1 — Default density:** 9 (recommended start — stride-scale cells, chunky-but-fair
  footprints) vs 15 (finer avoidance, smoother-looking blocking). Phase 3 decides with feet.
- **D2 — Diagonal rule:** generalize today's flanking-cell rule (a diagonal hop needs at
  least one adjacent orthogonal cell open — recommended; prevents slipping through wall
  corners) vs free diagonals.
- **D3 — What blocks:** walls/jambs + pedestals, dials, obelisks, plaques, pillars, house,
  imported assets solid; portals + lamps + flags/vase ghost (recommended list — amend at will).
- **D4 — Density scope:** per-world in `WorldScale` (recommended — interiors may want finer)
  vs one global constant.
- **D5 — Grass pace:** same speed on grass as on path, or a touch slower on grass (flavor,
  cheap, maybe cozy — no recommendation, feel-pass question).

## Additional notes & thoughts

- **The upgrade path is real, not rhetorical.** Mask derivation = rasterized version of the
  aspirational plan's analytic colliders, from the same sources (`openings` + footprints).
  Going freeform later means swapping the consumer (cell lookup → circle-vs-slab slide),
  keeping every input. Nothing built here is throwaway.
- **Discovery/fog is untouched** — it's tile-level, and the player still occupies exactly one
  tile. Same for portals' walk-through, dial interact range, and the M17 plan (which never
  touches movement; the two milestones stay order-independent, M17-first still recommended).
- **iOS benefits quietly:** discrete cells make future touch input (tap-to-step, swipe-to-turn)
  much easier to design than analog sticks would be.
- **Perf is a non-issue:** masks are `d²` bits per facelet, derived on stamp/spawn and on prop
  change; movement stays O(1) per hop.
- **M15.3 percept experiment** (camera rides the slice) is unaffected either way; the
  aspirational plan would have made it easier, this plan leaves it as-is.
- **Watch item for Phase 1:** with grass walkable, the *maze* is now enforced only by hedge
  walls — any tile whose wall emission doesn't fully cover its closed edges becomes a secret
  shortcut. The mask derives from `openings` (not the meshes), so the mask is airtight even if
  a mesh has a visual gap — but the reverse (mask hole, mesh solid) would read as an invisible
  wall; the headless mask-vs-openings invariant test guards it.
