# M10: Tile Scale-Up — Sub-Tile Navigation, Gateways & Multi-Tile Spaces

## Vision

Make each tile *feel* roughly 5x larger from the player's point of view, and use that new space:

- Tiles subdivide into a **3x3 sub-grid**; the path cells are standing spots, and the player moves between spots, not tiles.
- **45° turns** — the player can face 8 directions instead of 4.
- **Paths** cross each tile connecting its gateways; the non-path areas host **3D objects/props**.
- Wall openings become **gateways** — a gap through a wall with flanking wall stubs — instead of a fully missing wall. Later these become real gates (doors, locked, animated).
- Walls gain **corner posts** (the light-green corners in the mockups — these do not exist today; current walls are plain slabs per edge).
- Walls between two or more tiles can be **eliminated entirely** to merge tiles into larger scenes (e.g., a 2x2 room containing a house model).

The trick: tile geometry stays the same size in world units. The *perception* of scale comes from shrinking the player — eye height, wall height, wall thickness, and FOV — as validated in our scale discussion.

---

## Current State (what exists today)

| Thing | Today | M10 |
|---|---|---|
| `tileSize` | 0.98 units (~3.7m at old scale) | unchanged in units; reads as ~18.5m |
| `wallHeight` | 1.2 (~4.5m) | ~0.24 (same ~4.5m real-world at new scale) |
| `wallThickness` | 0.12 | ~0.06–0.08 |
| `eyeHeight` | 0.45 (first-person) | ~0.09 |
| FOV | 70° (shared, orbit + FP) | ~55–60° in first person |
| Standing spots | 1 per tile (center) | up to 5 per tile (path cells of 3x3 sub-grid) |
| Facing | 4 directions (`SurfaceDirection`) | 8 directions (new `Heading8`) |
| Wall opening | wall absent on whole edge | gateway: wall stubs + centered gap |
| Wall corners | none | corner posts (distinct material) |
| Per-edge state | 1 bit (`DirectionMask`) | 3 states: `wall` / `gateway` / `open` |
| Props | none | footprint-based prop system |
| Player avatar | flat marker mesh, 4 rotations | scaled to sub-cell, 8 rotations |

Key files: `TileMeshLibrary.swift` (tile/wall meshes, 16 cached wall masks), `CubeTypes.swift` (`SurfaceDirection`, `DirectionMask`, `MazeTile`), `PlayerState.swift` (tile-level movement), `EdgeCrossing.swift` (24-entry face-crossing table), `CameraState.swift` (eyeHeight 0.45, FOV 70°), `CubeModel.swift` (openings, rotation, `worldMatrix` with 0.01 inter-tile gap).

---

## Data Model

### Sub-grid (3x3)

Each tile subdivides into 9 sub-cells, `(subRow, subCol)` in `0...2`, each `tileSize/3` wide. Path sub-cell centers are standing spots (red squares); the spots the mockups show on blue quadrants are reserved as future prop-interaction points, not free destinations.

Sub-cell classification, derived per tile:
- **`path`** — the cross arms: center `(1,1)` plus the middle cell of each edge that has a gateway or is open. (A tile with N and E gateways gets path cells `(1,1)`, `(0,1)`, `(1,2)`.)
- **`propSpace`** — the rest (blue in mockups): not a movement destination, reserved for props; renders as open floor.
- **`blocked`** — propSpace occupied by a prop footprint.

Walkability: only `path` cells are destinations. Empty propSpace reads as open floor and doesn't block diagonal corner-glides; occupied propSpace does. Prop interaction happens from an adjacent path cell while facing the prop — the 45° facings let the player face diagonally-adjacent props.

### Edges: from bit to enum

`MazeTile.openings: DirectionMask` (4 bits) is replaced/augmented by per-edge state:

```swift
enum EdgeType: UInt8 { case wall, gateway, open }
// MazeTile gains: var edges: (n: EdgeType, e: EdgeType, s: EdgeType, w: EdgeType)
```

- `wall` — full wall slab + corner posts.
- `gateway` — wall stubs on both sides, centered gap 1/3 of tile width, jamb posts (light green) flanking the gap. This is where doors/gates mount later.
- `open` — no geometry at all; used for merged multi-tile spaces.

A `rotated(quarterTurns:)` equivalent is needed (same pattern as `DirectionMask.rotated`). Compatibility shim: `openings` can be computed (`gateway`/`open` ⇒ open) so existing movement/discovery code keeps working during the transition.

### Facing: 8 directions

```swift
enum Heading8: Int, CaseIterable { case n, ne, e, se, s, sw, w, nw }
```

Keep `SurfaceDirection` (4-dir) for edges, gateways, and the EdgeCrossing table — walls are inherently 4-directional. Add conversion helpers (`Heading8` ↔ `SurfaceDirection` for the cardinal cases, rotation by 45° steps, quarter-turn rotation for slice rotations and face crossings).

### Player position

`PlayerState` gains `subRow`, `subCol` (0–2) and `facing: Heading8`. Movement becomes spot-to-spot:

- **Orthogonal move:** to a 4-adjacent path cell.
- **Diagonal move:** to a diagonal path cell, unless either flanking orthogonal cell is `blocked` (no clipping through prop corners; empty propSpace flanks don't block — gliding over the corner of open floor is fine).
- **Tile crossing:** only from an edge-middle cell, facing that edge, when the edge is `gateway` or `open`. Arrival is always the neighbor's opposite edge-middle cell.

**Key simplification:** because gateways are always centered on the edge, crossing a tile (or cube-face) boundary always lands at a deterministic sub-cell — the existing 24-entry `EdgeCrossing` table needs *no* sub-coordinate mapping, only the facing rotated by the crossing's quarter-turn delta (in 45°-step space: quarter turn = 2 steps).

### Slice rotations

Sub-tile state rotates with the tile, using the same quarter-turn logic that already rotates `openings`:
- Edge states rotate (n→e→s→w).
- Path classification is *derived* from edges, so it rotates for free.
- Player `(subRow, subCol)` rotates: CW quarter turn ⇒ `(r, c) → (c, 2 - r)`.
- Player `facing` rotates by 2 × 45° steps per quarter turn.
- Prop anchors/orientations rotate with their cubie (see Props).

---

## Implementation Phases

### Phase A — Perceptual scale-up (small; instant payoff)

Pure constant changes, no data-model work. Validates the feel before we invest in the rest.

- `eyeHeight`: 0.45 → **0.09**
- `wallHeight`: 1.2 → **0.24**
- `wallThickness`: 0.12 → **0.07**
- First-person FOV: 70° → **~58°** (split FOV per camera mode; orbit stays 70°)
- Tune first-person move/turn speeds: sub-cell moves come later, but even now, slower traversal sells the size (a 5x-bigger world should take longer to walk).
- Check floor texture tiling density and near-plane (0.01 is fine vs. eye 0.09) at the new scale.

**Deliverable:** the world reads ~5x larger in first person. Orbit view unchanged.

### Phase B — Edge model + new wall geometry (medium)

- Introduce `EdgeType`, migrate `MazeTile` from `openings` to `edges` (with the compatibility shim).
- Maze generation: carved connections become `gateway` (not "no wall"); walls stay `wall`. Edge bridges likewise become gateways.
- `TileMeshLibrary` rebuild:
  - Wall slab per `wall` edge (as today, new dimensions).
  - **Gateway mesh** per `gateway` edge: two stubs + jamb posts.
  - **Corner posts** at tile corners (light green / new materialID): present when any adjoining edge at that corner is `wall` or `gateway`; suppressed when the corner is interior to a merged open area.
  - Mesh caching: 3 states × 4 edges = 81 combos — either cache all 81 (still small) or compose per-edge segments at instance-build time (4 sub-draws per tile, simpler). Recommend composing per edge; walls are already batched by mask, and per-edge composition removes the combinatorial cache entirely.
  - Respect the 4-byte index-buffer alignment rule (Apple Silicon drops triangles on misaligned offsets — bitten by this before).
- Shader: new material for corner/jamb posts (lighter green tint).

**Deliverable:** maze looks the same topologically, but openings are now visible gateways with posts and corners. More enclosed, more architectural.

### Phase C — Sub-grid model + path rendering (medium)

- Add sub-cell classification (derived from edges, computed per tile, cached; recompute on rotation — or just derive on the fly, it's cheap).
- Floor mesh/material split: path cells get a distinct floor material (the purple in mockups → likely a stone/brick texture), propSpace cells keep the base floor. Simplest: render floor as 9 sub-quads per tile with per-sub-cell materialID (instanced, still cheap at 5x5x6 = 150 tiles × 9 = 1350 quads).
- With the inter-tile gap removed (see Decisions), path floors meet seamlessly at gateways — no bridge geometry needed.

**Deliverable:** tiles visibly show paths and plazas. No movement change yet.

### Phase D — Sub-tile movement + 45° turns (medium-large)

- `PlayerState`: `subRow`/`subCol`, `facing: Heading8`, spot-to-spot move animation (reuse the existing progress-based move/turn animation; turn animation now animates 45° increments).
- Movement rules (orthogonal, diagonal with no-corner-clipping, gateway crossing) per the Data Model section.
- Input mapping unchanged (forward/backward along facing, left/right turn = 45° steps now).
- Camera (first person): eye follows the standing spot, not the tile center; look direction along `Heading8`.
- Player marker: 8 rotations, scaled to sub-cell size (flat marker retained; a 3D avatar is a future milestone).
- `GameState.printMazeDebug`, discovery triggers (`onPlayerArrived`) updated: discovery still fires per *tile* on first entry (per-sub-cell discovery is out of scope for M10).

**Deliverable:** the player walks across big tiles spot-by-spot, turns in 45° steps, and passes through gateways.

### Phase E — Cross-face crossing + slice-rotation integration (medium)

- Gateway crossing across cube edges: reuse `EdgeCrossing` table + facing rotation in 8-dir space; arrival sub-cell is the deterministic edge-middle (no table changes).
- Slice rotation: rotate player sub-position and heading; rotate edge states (replaces `openings.rotated`); verify with the debug maze print.
- First-person camera continuity through crossings and rotations at the new eye height.

**Deliverable:** full navigation parity with today's game, at sub-tile resolution, everywhere on the cube — including during/after slice rotations.

### Phase F — Multi-tile spaces (medium)

- Room concept: a rectangular group of tiles on one face whose shared edges are set to `open` (no geometry, no posts at fully-interior corners).
- Authoring: start with generator-stamped rooms (e.g., one 2x2 room per face where the maze allows), or a hand-authored template list per face for the prototype. Room perimeter keeps `wall`/`gateway` edges (at least one gateway guaranteed for connectivity).
- Maze generator interplay: stamp rooms first, then run the maze around them treating the room as a single super-node (or simplest prototype path: carve the room *after* generation and accept the connectivity it inherits — good enough for a visual prototype).
- Floor continuity: room templates author their own path route through the space (the winding purple route in the mockup); remaining cells are propSpace hosting the room's props. With the gap removed, tile floors meet seamlessly.

**Deliverable:** large open plazas/rooms spanning 2–4+ tiles, walls only at the perimeter.

### Phase G — Props / 3D objects (large; the payoff)

- `PropInstance`: mesh ID, anchor `(face, row, col)`, orientation (quarter turns), footprint = list of `(tileOffsetRow, tileOffsetCol, subCellMask)` — supports props within one tile or spanning a room.
- Occupancy: footprint sub-cells become `blocked` (a prop spanning a whole tile may also block path cells); props may later *add* interaction spots (e.g., "stand at the door").
- Interaction hook: a path cell adjacent (orthogonal or diagonal) to a prop footprint, with the player facing it, exposes an interaction (pick up part of the prop, etc.). M10 only needs the adjacency + facing query; the interaction system itself is a later milestone.
- Rendering: props go through the existing instanced opaque pass (new meshes in the library or a simple built-in house: box + prism roof to start), cast/receive shadows via the existing shadow pass, lit by the M9 sun when that lands.
- Anchoring: props attach to their anchor cubie — slice rotations carry them exactly like tiles (same `worldMatrix` × animation matrix path).
- **Multi-tile props and slice rotations:** a slice can cut through a room and tear a house apart. Recommendation: embrace it — make multi-tile props *modular per tile* (each tile carries its quarter of the house), so rotations split them cleanly at tile seams and the player can re-assemble them Rubik's-style. This turns a hazard into the game's signature mechanic. (Alternative, if unwanted: block rotations that cut occupied rooms.)

**Deliverable:** houses and scene objects living on the cube, surviving (or deliberately splitting under) slice rotations.

### Phase H — Gates (future, beyond M10 core)

Gateways get door meshes, open/closed state, lock conditions, animations. The jamb posts from Phase B are the mounting points. Listed here so Phase B's geometry leaves room for a door leaf (gap width, post depth).

---

## Suggested Order & Effort

| Phase | Effort | Risk | Visual impact |
|---|---|---|---|
| A — Scale perception | XS | none | huge (feel) |
| B — Edges + gateways + posts | M | low | high |
| C — Sub-grid + path floors | M | low | high |
| D — Sub-tile movement + 45° | M/L | medium | high (feel) |
| E — Crossings + rotations | M | **highest** (coordinate math) | parity |
| F — Multi-tile rooms | M | medium | high |
| G — Props | L | medium | huge |
| H — Gates | — | — | future |

A → B → C → D → E → F → G. A is shippable alone; B+C are shippable without movement changes; D+E restore full navigation; F+G deliver the scene-building vision.

---

## File Changes Summary

| File | Changes |
|---|---|
| `CubeTypes.swift` | `EdgeType`, `Heading8`, `MazeTile.edges`, rotation helpers |
| `TileMeshLibrary.swift` | new wall dims, gateway meshes, corner/jamb posts, per-sub-cell floor quads, bridge quads, per-edge mesh composition |
| `PlayerState.swift` | sub-position, `Heading8` facing, new movement rules, diagonal moves |
| `GameState.swift` | crossing logic on sub-grid, slice-rotation sub-state updates, discovery hooks |
| `EdgeCrossing.swift` | unchanged table; facing math moves to 8-dir space at call sites |
| `CubeModel.swift` | edges storage, derived path classification, rotation of edge states, room stamping |
| `CameraState.swift` | eyeHeight 0.09, per-mode FOV, eye follows sub-cell |
| `Renderer.swift` | sub-cell floor instancing, prop instancing, marker 8-rotations |
| `Shaders.metal` | corner-post material, path floor material |
| `ShaderTypes.h` | new materialIDs (corner post, path floor, prop materials) |
| `CelestialSystem.swift` (M9) | no interaction; props simply join the lit/shadowed geometry |

---

## Tuning Parameters

- `eyeHeight` = 0.09, `wallHeight` = 0.24, `wallThickness` = 0.07 (all "player is 2m" anchored; walls ≈ 4.5m real-world)
- First-person FOV ≈ 58° (orbit unchanged at 70°)
- Gateway gap = tileSize/3 (aligned to the middle sub-cell), jamb post cross-section ≈ wallThickness × 1.5
- Sub-cell move duration ≈ 0.35–0.45s; 45° turn ≈ 0.12s
- Corner post cross-section ≈ wallThickness × 1.5, same height as wall

---

## Decisions (resolved 2026-07-02)

1. **Diagonal movement** — yes; no-corner-clipping rule applies (blocked only by prop corners, not empty floor).
2. **Blue (non-path) areas** — props only for now; movement is path-only. Moving toward / facing an adjacent prop may trigger interaction (e.g., picking up part of the prop).
3. **Slice rotations vs. multi-tile structures** — embrace tearing: multi-tile props are modular per tile, split cleanly at seams, and get reassembled Rubik's-style.
4. **Gateways everywhere** — ordinary maze passages all become gateways; fully-open edges are reserved for merged rooms.
5. **Inter-tile gap** — remove it (fall back to a 0.001 hairline only if seams shimmer during slice animation).
6. **Avatar** — flat marker stays for M10 (scaled down, 8 rotations); 3D avatar is a future milestone.

---

## Polish backlog (deferred)

Non-blocking issues noted during implementation, to clean up later:

- **First-person corner-cut at face crossings (found in Phase A).** Crossing from one cube face to another, the first-person eye takes a shortcut near the cube edge/corner instead of smoothly rounding it. Cause: `CameraState.firstPersonCamera` lerps `eyePos` linearly between the two face positions and renormalizes — the straight line between two points on adjacent faces passes inside the corner. Fix: slerp the eye *direction* around the shared edge (spherical interp) and interpolate radius separately, rather than `mix()` + renormalize. Minor; more noticeable now at the low eye height.
- **Floor/path texture pops on slice rotation (found in Phase E).** Pressing Q/E, the floor and path-cross textures change at the tile the player is on while the walls stay stable. Likely causes: (1) per-facelet `styleSeed` hue variation — after a rotation a different facelet occupies each position, so the floor tint shifts; walls mask this because their look is dominated by the height-based moss/gravel blend; (2) the path-cross re-splits as openings rotate, so the paved stripe moves. Partly *correct* (tiles physically move, so the floor genuinely changes) but reads as a pop. Options: make the floor `styleSeed` variation position-stable, or cross-fade the floor at finalization. Deferred — user aware.
- ~~**Inter-tile gap seam (decision #5).**~~ ✅ **Fixed (2026-07-03).** `cellSpacing` 1.01→1.0 and `floorHalfSize` 0.48→0.5 so adjacent floors abut edge-to-edge — the dark grid across plazas is gone.
- ~~**Shadow acne / "tearing" on posts & walls (found in Phase F).**~~ ✅ **Fixed (2026-07-03).** Three causes: (1) the PCF used `texelSize = 1/1024` after the shadow map was bumped to 2048 → double-spaced, misaligned samples; (2) the shadow ortho frustum was `size`…`5·size` (huge depth range → oversized world-space bias); (3) bias constants tuned for the old geometry. Fix: `texelSize` → 1/2048; hug the frustum to the cube (`shadowNearZ` 1.8·size, `shadowFarZ` 4.2·size, `shadowOrthoRadius` 1.1·size); cut bias ~4× (0.0008 / 0.0025).

---

## Technical Notes

- **Inter-tile gap (decided: remove):** `CubeModel.worldMatrix` spaces tiles with a 0.01 gap; at 5x perceived scale that seam reads as a ~19cm trench. Set gap to 0 — coplanar edge-to-edge quads don't z-fight, and the sub-cell floor pattern keeps the tiling readable. If seams shimmer during slice animations (MSAA/depth precision), fall back to a 0.001 hairline.
- **Edge-centered gateways save the math:** all boundary crossings arrive at the neighbor's edge-middle sub-cell, so the `EdgeCrossing` table (verified correct in M8 debugging) is untouched. Only facing needs the quarter-turn rotation, now ×2 in 45° steps.
- **Wall mesh caching:** move from mask-keyed cached meshes (16 today, 81 with `EdgeType`) to per-edge composition. Walls remain instanced/batched; draw-call count stays modest (150 surface tiles max × ≤4 edge pieces).
- **Index alignment:** any new index-buffer slicing must keep 4-byte-aligned offsets for UInt16 indices (Apple Silicon silently drops triangles otherwise — hit this in M8).
- **First-person near plane:** 0.01 against eye 0.09 is fine; watch for floor-texture magnification at the low eye height — may want a higher-frequency detail texture or subtle noise to avoid blur.
- **Performance:** sub-cell floors ≈ +1200 quads, corner posts ≈ +600 small boxes, props are the only real new cost — all instanced through the existing pipeline; no new Metal API surface needed.
- **M9 interaction:** none required. Props and new wall geometry automatically join the shadow pass; the sun/moon system lights them like everything else. If M9 lands first, verify gateway stubs self-shadow acceptably at low sun angles.

---

## M9/M10 Compatibility & Sequencing

*(This section is duplicated verbatim in both the M9 and M10 plan documents. If you update it, update both.)*

### Known friction points

1. **Shadow tuning vs. 5x smaller features (the trap).** The current shadow bias (`0.003`–`0.008` over the light's 20-unit depth range, near 5 → far 25) equals **0.06–0.16 world units** of offset. Invisible against today's 1.2-high walls, but 25–67% of M10's 0.24 wall height — shadows will detach ("peter-pan") or vanish on low walls and 0.07-thick posts, worst at M9's low sun angles. Also: at 1024x1024 over the 16-unit ortho span, a jamb post is ~4.5 shadow texels wide and the 3x3 PCF blur is comparable to the feature size. **Fix once, after M10 Phase B geometry exists:** tighten light near/far around the cube, cut bias ~4x, consider a 2048 shadow map.
2. **Same-file churn.** Both milestones edit `Shaders.metal`, `ShaderTypes.h`, and `Renderer.swift`. Run phases strictly serially; never interleave M9 and M10 work.
3. **Night legibility at the new scale.** M9's night ambient / `moonIntensity` must be tuned at M10's 0.09 eye height inside gateway-enclosed corridors — a much darker experience than the old over-the-walls view. The fog/translucent pass colors also need day-factor modulation, or fog will glow at night.
4. **Aesthetic constants assume the old perceived scale.** After M10 Phase A, revisit `moonOrbitRadius` (the moon subtends ~4.3°; at 5x perceived scale a 20-unit orbit reads as "a barn 400m away") and `sunPeriod` (a 300s day may feel short once traversal takes ~3x longer).

### Non-issues (verified)

- Props, gateways, and corner posts flow through the existing instanced opaque + shadow passes, so they are automatically lit and shadowed by the sun/moon — no extra integration work.
- Sun at 80 units sits inside `farZ = 100`; orbit camera distance 12 unaffected.
- Material additions don't collide: M9 adds `FrameUniforms` fields and dedicated sun/moon shaders; M10 adds materialIDs (corner post, path floor, props) in `InstanceData` space.

### Phase 0 — pre-flight refactor (before any M9/M10 work)

> **STATUS: ✅ COMPLETE (2026-07-02).** All of R1–R5 landed as behavior-neutral refactors, each verified (tests + build + screenshot-identical render). Coordinate math is now proven size-generic across {3,5,7,9} by `Tests/run-tests.sh` (6592 checks). New files: `WorldScale.swift` (single scale source, per-world — Phase A knobs `eyeHeight`/`wallHeight`/`wallThickness`/`cellSpacing`/per-mode FOV now live here as one-file changes), `SceneBuilder.swift` (instance building extracted from Renderer, which dropped 857→546 lines), `Tests/` (standalone runner). One intentional behavior tweak: iOS pinch zoom-in limit 3→5 to unify with macOS via `WorldScale.orbitDistanceMin`.
>
> **Step 0.5 ✅ done (2026-07-03).** Default cube flipped to **7³** (`Renderer.initialCubeSize`); the N key now cycles odd sizes 3→5→7→9 live; shadow map bumped to 2048; edge-bridge density scales with cube size (`max(1, n/3)`). Verified at 7³ and 9³ — framing and shadows auto-adjusted with **no other changes needed**.
>
> **M10 Phase A ✅ done (2026-07-03).** Perceptual scale-up: eyeHeight 0.45→0.09, wallHeight 1.2→0.24, wallThickness 0.12→0.07, first-person FOV 70°→58° (all in WorldScale), moveSpeed 2.5→0.8 (PlayerState). First-person now reads as a large plaza with distant hedges instead of a tight corridor; orbit view is correspondingly flatter (shared wall geometry). Approved as feels-good. One deferred polish item logged (first-person corner-cut at face crossings).
>
> **M10 Phase B ✅ done (2026-07-03).** `EdgeType {wall, gateway, open}` vocabulary added (derived from `openings` for now — stored `edges` deferred to Phase F when rooms need `open`, per below). Open edges now render as **gateways**: a wall with a centered gap (`WorldScale.gatewayGapFraction` = 1/3, sub-grid-aligned) via two stubs, built by generalizing `addWall` to a sub-span. **Posts** added with a light-green material (materialID 8): slim corner markers capped at hedge height + bold jamb posts (1.5× wall thickness, above the hedge line) framing each gateway — proportions chosen live with the user. Kept the 16-mask mesh cache (2 states, not 3) rather than per-edge composition; that's deferred to Phase F where `open` makes it 3 states.
>
> **M10 Phase C ✅ done (2026-07-03).** 3×3 sub-grid classification via `MazeTile.isPathCell` (path = center + the middle cell of each gateway edge; corners are propSpace). Tile floor split into path-cross cells vs propSpace cells (`addFloorCells`, disjoint & coplanar → no z-fight), rendered as two meshes: propSpace keeps the base ground (materialID 1), the path cross gets a warm paved-stone material (materialID 9). User kept it subtle/naturalistic. Also fixed the instance-buffer capacity hint to the true buffer size. No movement change yet.
>
> **M10 Phase D ✅ done (2026-07-03).** `Heading8` (8-way facing, clockwise from north). Player gains `subRow`/`subCol`; movement is now spot-to-spot between path cells: within-tile hops (incl. diagonals arm→arm) plus gateway crossings that arrive at the neighbor's opposite edge-middle cell. **Key simplification:** crossings only happen on *cardinal* moves from an edge-middle cell, so the existing `EdgeCrossing` table is reused unchanged and 8-way facing lives only within a tile. 45° turns; camera eye follows the sub-cell standing spot; player marker gets 8 rotations + sub-cell offset + scale. `moveSpeed` retuned 0.8→2.5 (0.4s/hop). Verified in first-person: forward through gateways, 45° turns. Slice-rotation sub-cell rotation and rigorous cross-face verification deferred to Phase E.
>
> **M10 Phase E ✅ done (2026-07-03).** Slice rotation now rotates the player's **sub-cell** too: its offset-from-center is rotated by the slice quaternion and re-read in the face frame — consistent-by-construction with the facing rotation (same rotQ) and the openings rotation. Cross-face gateway crossing (built in Phase D) reuses the R4-verified `EdgeCrossing` table with deterministic edge-middle arrival. Edge-state rotation is a no-op here (edges are derived from openings, which already rotate). Verified in first-person: rotating from center and arm cells leaves the player coherent and navigable (walked a corridor of gateways through a rotation + a crossing). **This completes M10's core navigation (Phases A–E).** Deferred: the inter-tile gap seam is still visible at the low eye height (decision #5 gap-removal — a one-line `cellSpacing` change, plus widening `floorHalfSize` to fully close the floor seam). Remaining M10: Phase F (multi-tile rooms), Phase G (props).
>
> **M10 Phase F ✅ done (2026-07-03).** The deferred `open` edge state is now live. `MazeTile.openEdges` (a `DirectionMask` ⊆ `openings`) marks room-interior edges; `edgeType` returns wall / gateway / **open**. Wall+post meshes re-keyed from the 16 openings masks to the **81 three-state edge-configs** (`edgeConfigKey`, base-3): open edges emit no geometry, and a corner interior to a merged room (both adjoining edges open) drops its post. Floors stay keyed by the 16 openings masks (path split depends only on passability). `openEdges` rotates with `openings` under slice rotation. `CubeModel.stampRoom` + a prototype 3×3 room centered on the start face. Verified: the player starts in a merged **plaza** — walls only at the perimeter, no interior walls/posts, navigable across the room to a perimeter gateway. (Room *authoring* — multiple/procedural rooms, authored path routes — is future.) Next: **Phase G (props)**.

Small, surgical, each step independently verifiable (build + run + compare screenshot). Phase 0 also **bakes in cube-size independence** (see R1/R4/R5) — but the actual size flip is deliberately *not* part of Phase 0, since changing the world mid-refactor would destroy the screenshot-identical baseline; it runs as its own experiment right after (step 0.5 below):

- **R1 — Single source of scale truth.** A `WorldScale` constants type (tile spacing, tile mesh size, gap, wallHeight, wallThickness, eyeHeight, per-mode FOV) that also takes **cube size as a first-class input**, deriving the world-extent values from it: camera `orbitDistance` (today hardcoded 12, tuned to a 5-wide cube), shadow ortho bounds (`-8..8` — a 9³ cube's half-diagonal of ~7.8 barely fits), light near/far and eye distance, and M9 orbit radii. M10 Phase A, the gap-removal decision, and any future cube-size change become one-file changes.
- **R2 — De-duplicate the uniforms struct.** `FrameUniformsSwift` (Renderer.swift) manually mirrors `FrameUniforms` (ShaderTypes.h); the layouts must match by hand. M9 adds three fields — an easy skew. Either bridge the C struct into Swift and delete the mirror, or add a compile-time size assertion.
- **R3 — Extract scene/instance building from Renderer.** Renderer.swift (~855 lines) mixes pipeline setup, texture loading, per-frame instance building, and animation-matrix logic. Pull instance building into its own file so M9 (celestial draws) and M10 (sub-cell floors, props) land in focused code instead of weaving through the monolith.
- **R4 — Coordinate-math test target.** Unit tests for `gridPosition`/`worldMatrix` consistency, `EdgeCrossing` round-trips, and rotation math — **parameterized across cube sizes {3, 5, 7, 9}**, turning "the coordinate math is probably size-generic" into "verified". This exact class of bug cost us the entire M8 debugging session; M10 Phases D–E multiply the coordinate math by sub-grids and 8 headings. Cheapest insurance in the plan.
- **R5 — Facelet lookup dictionary.** `CubeModel.findFaceletIndices` is an O(n²) scan — fine at 5³ today, but M10 sub-grid movement and prop occupancy query it more often, and larger cubes (7³/9³) grow it ~4x. Promoted from optional now that Phase 0 targets size-independence.

**M11 guardrails (free now, expensive to retrofit):** the planned moon-as-a-world milestone (see *M11 Lunar Excursion Seed.md*) requires that R1's `WorldScale` be **per-world** (not a singleton) and that R3's scene builder take the `CubeModel` **as a parameter** — never assume a single global world.

**Do NOT pre-refactor** (M9/M10 rewrite these anyway): `PlayerState` movement duplication (Phase D rewrites movement), `TileMeshLibrary` wall-mask caching (Phase B replaces it with per-edge composition), maze generation (Phase F changes it for rooms).

### Recommended sequence

| Step | Work | Why this position |
|---|---|---|
| 0 | Pre-flight refactor R1–R5 | Both milestones touch these seams; cheapest before either starts. Bakes in size-independence (R1 derives world-extent values from cube size; R4 tests sizes 3/5/7/9) |
| 0.5 | *(Optional)* Cube-size experiment — flip to 7³ or 9³ | ~1 hour once Phase 0 lands: one-line change + visual tuning pass (edge-bridge density, shadow map 2048). Done here so the baseline is stable before M10 geometry work; keep odd sizes — even sizes break the center-tile player start |
| 1 | M10 Phase A — perception scale-up | Instant payoff; sets the perceived scale that later aesthetic tuning depends on |
| 2 | M10 Phase B — edge model, gateways, corner posts | Finalizes wall geometry *before* shadow tuning |
| 3 | M9 Phases 1–4 — celestial system, sun, moon, day/night + **shadow retune** | Shadows tuned once against final wall geometry; night ambient tuned at new eye height |
| 4 | M10 Phases C–E — sub-grid, movement, crossings/rotations | Pure gameplay/data-model work; shaders stay stable |
| 5 | M10 Phases F–G — rooms, props | Props enter already-tuned lighting; verify prop self-shadowing |
| 6 | M9 Phases 5–7 — moon light, moon shadows, eclipses | Night polish tuned against real scenes with props |
| 7 | M10 Phase H+ — gates, 3D avatar | Future milestones |
