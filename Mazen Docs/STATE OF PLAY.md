# STATE OF PLAY — read me first

*A one-page handoff so a fresh session (or a future me) starts with the full picture. Last updated 2026-07-09. If you read nothing else, read this, then the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md) and the [Master Roadmap](Master%20Roadmap.md).*

## The 60-second catch-up

We built a first-person, twistable **cube-maze prototype**, and over a design conversation it found its game: **The Garden of Worlds** — a cozy, no-grind, Witness-taught archaeology of impossible worlds. The engine is real and working (M8–M13); the *design* is now the north star; the next work is turning the design's core loop into a playable **vertical slice**.

## The game (the north star)

> You're a tiny traveler *inside* a cluster of maze-planets. **Learn** how a world thinks (from the world itself, never told) → **undo an ancient lock** (bandaging) → **twist the world open** (the slice) → **step inside** it (inverted-cube interiors) → find the **engineered truth beneath the natural surface** → which teaches you the next thing.

One deep verb (the twist), no grind (every action reveals something new), no hand-holding. The bold theme candidate: the Builders *learned everything, lost the ability to forget, and dissolved into background noise* — **wisdom is curation, not accumulation** (ties to a memory/selective-forgetting mechanic no one else has). Full detail + art direction + the new mechanisms (inverted cubes, shape-as-meaning, memory-as-key, long tiles) in the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md). The minute-to-minute verb is teased out in [Player Journey](Player%20Journey%20—%20A%20Session.md).

## What's built (the engine is real)

- **Cube + procedural hedge maze**, fog/discovery (currently *revealed-all* for testing), sizes 3–9.
- **The twist** — slice rotation rearranges the maze; you ride it; props/walls/structures carried correctly.
- **M9 solar system** — cube sun/moon, orbits, day/night, phases, eclipse, shadows, idle spin.
- **M10** — perceptual scale, 3×3 sub-cell movement, gateways, rooms, procedural props.
- **M12** — imported 3D models (ModelIO), the modular house that **splits Rubik's-style**, decorations that ride slices.
- **M11 (core done)** — world stack, **TARDIS walk-through portals** + fade, a persistent moon world, and **the killer visual**: the real other world hangs in the sky (moon from earth & vice-versa), turning, with your twists baked in.
- **M13 (foundation done)** — bandaging legality rule + unit tests + enforcement wired, **inert until something's bonded**.
- **Tooling** — debug HUD (`H`), twist pacing (`G`/`[`/`]`), world toggle (`O`), headless tests (`Tests/run-tests.sh`, 7060 checks). All debug toggles default OFF.

## Live design questions (the next real work is here, not code)

1. **Can "this lock needs *understanding X*" be legible with no UI?** The exact needle The Witness / Outer Wilds spend their whole budget threading. Hardest craft problem.
2. **Is the "understand" verb deep enough to repeat across worlds** without becoming "find the switches"? Leading candidate: a **Builder glyph/language you slowly learn to *read*** (Chants of Sennaar / Heaven's Vault style) as the deepening verb.
3. Where memory-*editing* / selective-forgetting enters as a verb vs. staying theme.

## Milestone road to a vertical slice (rough)

M14 shape-as-meaning (superellipsoid) → M15 inverted-cube interiors → **M16 the lock→open→enter chain** (the single most important loop) → M17 memory first pass → M18 one small solar system (a few natural worlds) → M19 cozy/feel polish. Details + sequencing in the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md).

## Immediate next actions on resume

- **M14b is mid-implementation and UNCOMMITTED** (see Pending). Next: seat imported assets (horse/house) on the curve; visually re-verify procedural props; decide the committed default roundness (temp `0.5` in `CubeModel` right now — revert to `0.0` before commit); then commit the M14b checkpoint. Full plan + phase status: [M14b Curved Geometry Plan](M14b%20Curved%20Geometry%20Plan.md).
- Then remaining M14b: Phase 3 (camera/player ride the curve) + Phase 4 (sky-world inflates with its own roundness; perf; sunrise/sunset tuning).

## Pending / uncommitted right now

- **M14b Curved Geometry — IN PROGRESS, UNCOMMITTED, builds clean, all 7060 tests pass, `roundness==0` byte-neutral.** Per-vertex tessellated superellipsoid inflation (replaces the M14 per-tile approach, which levered/swapped hedges). Done + **visually verified**: **Phase 0** uint32 index migration; **Phase 1** floors inflate per-vertex + `floorTess` subdivision (smooth seamless rolling ground); **Phase 2a/2b** walls+posts inflate + `wallTess` mesh subdivision + curve-correct TBN (VS-supplied tangent) + warm low-sun tint. Done in code (**not yet visually verified** — Mac locked): **Phase 2.5** procedural props (topiary/obelisk/chest/portal) inflate via the same footprint+extrude path.
  - **Mechanism:** `InstanceData` gained per-instance `spinMatrix`/`roundness`/`invHalfExtent` (+ a Swift convenience init — note: it must use `self.init()` + field assignment, NOT a same-labelled `self.init(...)` which infinite-recurses). `CubeModel.restMatrix` = un-spun flat placement; shader `m14bTransform` (in `Shaders.metal`, used by scene **and** shadow VS) does footprint-project → extrude-along-curved-normal → spin. Floors/walls/posts/procedural-props route through it; celestials stay world-frame.
  - **Files:** `ShaderTypes.h`, `Shaders.metal`, `CubeModel.swift`, `SceneBuilder.swift`, `TileMeshLibrary.swift`, `WorldScale.swift`, `Renderer.swift` (uint32 draw sites + convenience init), `GameViewController.swift` (`M` matte toggle, `-`/`=` roundness, HUD).
  - **Remaining:** imported assets (horse/house, materialID 11) still **rigid → clip the curve** — they're Y-up with orient baked into the transform, so they need *rigid-seat-on-curve* (project anchor to surface + tilt to local normal), NOT per-vertex bend. Then Phase 3 (camera) + Phase 4 (sky-world + perf + sun tuning). Eddie likes roundness **0.5** ("rolling hills") in FP.
- Build note: the sandbox may block `xcodebuild` — run builds with the sandbox disabled if it recurs (normal local compile).
- Otherwise `main` == `origin/main`, pushed. Repo is **private**. (The M14 working-tree changes are the only thing uncommitted.)
