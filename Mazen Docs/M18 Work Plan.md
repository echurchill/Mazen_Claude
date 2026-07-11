# M18 — Densified Grid Movement & Solidity (work plan)

*Drafted 2026-07-11 from Eddie's counter-proposal to the freeform plan (kept as the
[aspirational north star](M18%20Freeform%20Movement%20%28Aspirational%29.md)): instead of
continuous movement, **densify the stand points** (3×3 → 9×9-ish), let the player step off the
paths onto the grass, and make walls/props solid by **removing the stand points under them**.
Numbering: M18 = this; solar-system slice = M19; Journey Walkthrough = M20; cozy/feel polish = M21.
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

## The driver: natural worlds (why M18 outranks M17)

*(Eddie, 2026-07-11.)* M19's earth/moon worlds are **mazeless**: roundness ~1.0, natural ground
(grass fields with trees, or regolith with craters), and walking there must feel like *not
being in a maze at all* — no paths in the traditional sense. That is what M18 exists to make
possible, so **M18 runs before M17.** Consequences for this plan:

- **A natural world is just a wall-less stamp.** Masks start all-walkable; trees, boulders,
  and crater rims are footprint props. "Paths" become purely visual (worn grass), never
  mechanical. The mask system needs nothing new for this — it's its best case.
- **The feel bar moves.** The old test was "maze walking stays cozy." The real test is now
  "an open field doesn't feel like a grid." Two specific threats: (1) **8-way heading in the
  open** — corridors mask the 45° polyline, a grass field won't; (2) **seam invisibility** —
  at roundness 1.0 the cube edges vanish visually, so crossing one must feel like nothing,
  and today diagonal travel can't cross a tile edge at all (cardinal-only exits). Both get
  tested early on a wall-less stamp instead of being discovered in M19.
- **The escape hatch is priced in:** if 8-way in the open fails the feel pass, the ladder is
  16-way heading → free yaw over grid position (a slice of the
  [aspirational plan](M18%20Freeform%20Movement%20%28Aspirational%29.md)) — the mask and
  footprint work is identical under all three.
- **The thematic jackpot, for the record:** a perfect green sphere that is *secretly a cube
  maze underneath* is the game's whole thesis — the engineered truth beneath the natural
  surface. The first twist on a "natural" world, shearing a grass field along an invisible
  slice plane, is M19's killer moment; M18 is what earns it.

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

### Phase 0 — Densify (behavior-identical) — ✅ verified (Eddie, 2026-07-11)
Introduce `d` and the integer scaling: prop subcell coordinates, `edgeMiddle`, spawn centre,
player marker, portal/interact positions, the twist player-remap. First flip walkability to
*exactly the scaled path cross* so the game plays identically to today — this flushes every
hidden `0...2` assumption while behavior is still bit-comparable.
*Danger:* Med (wide but mechanical). *Verify:* plays identically; headless remap tests.
*Build note:* one deliberate deviation — **props keep the 3×3 author grid forever**
(`Prop.subRow/subCol` untouched, `subCellStep` stays the prop step); only the STAND grid
densified (`WorldScale.standGrid = 9`, `standStep`, PlayerState carries `standGrid` with
pace normalized ×d/3). Less churn, and Phase 2 maps a prop cell → k×k stand cells anyway.
Touched: WorldScale, CubeTypes (`isPathCell(grid:)`), PlayerState, GameState (spawn +
twist remap), CameraState (FP eye), SceneBuilder (marker), Renderer (portal seating);
+5,424 checks (stand-grid cross at d=3/9/15 × all 16 opening combos).

### Phase 1 — Open the grass, mask the walls — ✅ verified (Eddie, 2026-07-11)
Walkable-by-default + wall/jamb subtraction replaces the path-cross rule. The player steps
off the path for the first time. Gateways now gate by geometry (the wall cells), not by the
edge-middle rule — tile exits allowed from any open edge cell, crossing to the neighbour's
mirrored cell through `edgeCrossing` (generalizing the existing sub-cell remap pattern),
**including diagonal exits** (decomposed as cardinal cross + lateral cell offset) so a
diagonal walk never stutters at a tile seam — mandatory for the natural worlds, where seams
are invisible. Add a `.natural` **test stamp** (wall-less world, a few tree footprints) as
the standing testbed for the open-field feel question.
*Danger:* Med — the edge/interior sub-cell remap is this plan's hardest math (a far smaller
cousin of the freeform plan's Phase 4). *Verify:* world-position-pinned crossing tests (the
M15 technique) over every edge, exterior + interior, several sizes, cardinal AND diagonal;
then a feel walk — corridor and open field.
*Build note:* walkability = `MazeTile.isStandable` (grass by default; closed edges claim
their border cells, gateways their non-gap cells — the gap is exactly the visual middle
third). Crossings from ANY border gap cell, lateral index preserved via an EdgeCrossing
probe (`PlayerState.lateralSign`) so interior conjugation is consistent for free; diagonal
exits decompose to cardinal-cross + lateral shift; travel heading rotates with the surface
frame (a diagonal walk stays diagonal over a fold). `.natural` stamp (all edges open +
landmarks + return portal), **B key** visits it (registry world "natural", size 7).
Tests: +31,050 (hand-derived standable truths; world-pinned seam/fold continuity, cardinal
+ diagonal, ext + int — same-face seams exact, folds pin the lateral along the shared cube
edge axis); 146,115 green. Also fixed: faceletAt crashes on out-of-range coords — natural
stamp bounds-checks (found by the size-3 test).

### Phase 2 — Solid props (stand-point removal) — 🔨 built 2026-07-11, awaiting Eddie's play check
The footprint table + auto-derived imports; subtraction into the mask. A plaque, dial,
pedestal, pillar, or house wall simply cannot be stood in — the plaque saga becomes
inexpressible rather than merely fixed. Includes the **connectivity sanity check**: a
footprint may never disconnect a tile's gateways from each other (authoring mistakes become
log lines, not unwinnable mazes).
*Danger:* Low-Med. *Verify:* can't occupy a prop's cells; F-interact still reaches from
adjacent cells; connectivity check fires on a deliberately bad stamp in tests.
*Build note:* `PropKind.isSolid` (portals + lamps walk-through, all else solid) +
`Prop.blocks(_:_:grid:)` — a solid prop removes the k×k stand block of its author sub-cell
(k = grid/3, so the three author thirds tile the stand grid exactly). PlayerState consults
prop footprints on both within-tile and cross-tile landings. Imported-asset footprints stay
one author cell for now (mesh-bounds auto-derivation is Phase 3 — the model layer has no
mesh). Connectivity guard: BFS (8-connected, matching movement) over every tile of every
authored world proves all walkable border cells stay one component — no footprint severs a
tile (opening the grass is what saves it: you detour around any prop through interior grass).
Tests: +26,836 (footprint tiling + walk-through + per-world connectivity); 172,951 green.

### Phase 3 — Density, pace & open-field tuning (Eddie's phase) — 🔨 density decided (15); open-field pass pending
**Density call (Eddie, 2026-07-11): 15**, the default for all worlds — "That feels nice"
walking the maze at ~1.3 m/step (a natural stride), and the maze feel-pass (stride rhythm,
footprint fairness, grass wandering) passed. The debug 9↔15 cycle key was made moot by
settling directly on 15, so it wasn't wired. **Remaining — the open-field pass, the one that
gates M19:** ready to run now — press **B** (the `.natural` wall-less world), raise roundness
with **=** toward 1.0, and wander the sphere in every direction, over the invisible cube
edges, around the topiary/obelisk. Does it read as *ground*, or as a grid with the walls
deleted? If 8-way heading is the tell in the open, climb the escape-hatch ladder (16-way →
free yaw over grid position) before Phase 4 retires anything. Density scope (D4): global for
now (one `standGrid`); revisit per-world only if interiors want finer.
*Danger:* Low to code, **high stakes to judge** — this verdict is what M19 stands on.
*Verify:* Eddie's verdict on the open-field pass — this phase exists to be played, not coded.

### Phase 4 — Sweep & retire assumptions
HUD shows the finer position; delete the temporary path-cross-equivalence shim from Phase 0;
docs + STATE OF PLAY; note what the aspirational plan would still add (free yaw, sub-cell
smoothness) so the north star stays visible.
*Danger:* Low. *Verify:* full suite + a long play session.

**M18 exit criterion:** walk anywhere on a tile the geometry honestly allows — including the
grass — and never into a wall, plaque, dial, pedestal, or house; across tile seams, cube
edges, and interior mirrors; while slices twist; at a density that survived a real feel pass.
**And the M19 gate:** on the wall-less test sphere at roundness 1.0, walking reads as *ground*,
not as a maze with the walls deleted — seams imperceptible, heading unobtrusive, trees dodged
like trees.

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
  touches movement; the milestones stay order-independent — **M18 first** per Eddie, as the
  natural-worlds prerequisite).
- **Terrain relief is NOT this milestone.** Craters, rolling hills, and local ground
  displacement are M19 authoring (on top of M14b's tessellated floors). M18 ground stays
  flat-per-tile; if M19 displaces floor vertices, eye-height should follow the same floor
  function — leave the hook, build nothing.
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
