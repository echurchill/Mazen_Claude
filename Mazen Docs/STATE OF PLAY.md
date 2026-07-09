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

- **M14b Curved Geometry is functionally COMPLETE (Phases 0–4) and committed.** What's left is polish/authoring, not core: (1) **per-world authored roundness** (right now a single `CubeModel.roundness`, default `0.0`; the `-`/`=` debug keys dial *all* worlds at once via `Renderer.adjustRoundness`; the design wants natural≈0.5 / mech≈0 / hybrid per world) — this is where the sky-world *foreshadowing* pays off; (2) **sunrise/sunset terminator tuning** (warm low-sun tint is in, but not tuned at a low sun); (3) optional: frame-rail/fog on the surface path, imported-asset AO. Full plan: [M14b Curved Geometry Plan](M14b%20Curved%20Geometry%20Plan.md).
- Then the vertical-slice road resumes: **M15 inverted-cube interiors** / **M16 lock→open→enter**, or the **glyph-language** design thread.

## Pending / uncommitted right now

- **Nothing pending — M14b is committed and pushed.** `main` == `origin/main`. All of M14b (per-vertex tessellated superellipsoid inflation, replacing the M14 per-tile approach that levered/swapped hedges) is done, builds clean, all 7060 tests pass, `roundness==0` byte-neutral, and **visually verified**: floors (smooth seamless rolling ground) + walls/posts (tessellated, bend with the floor, swap gone) + curve-correct TBN + warm low-sun + procedural props + imported assets (horse/house) seated on the curve + FP camera rides the curve (level horizon) + sky-worlds inflate independently (stood on the round 3³ moon) + 9³ at 100fps.
  - **Mechanism (for future reference):** `InstanceData` carries per-instance `spinMatrix`/`roundness`/`invHalfExtent` (Swift convenience init MUST use `self.init()` + field assignment, NOT a same-labelled `self.init(...)` — that infinite-recurses). `CubeModel.restMatrix` = un-spun flat placement; `CubeModel.inflatedPlacement(...)` seats rigid objects (imported assets, the FP camera) on the curve. Shader `m14bTransform` (`Shaders.metal`, scene **and** shadow VS): footprint-project → extrude-along-curved-normal → spin. Tessellation knobs in `WorldScale` (`floorTess`, `wallTessLen`, `wallTessHeight`). Debug: `M` matte, `-`/`=` roundness (all worlds), `H` HUD.
- Build note: the sandbox may block `xcodebuild` / `git` — run with the sandbox disabled. **git ↔ external volume:** if git returns `EPERM` on `.git` after a Claude update, re-grant the live "claude" entry **Removable Volumes / Full Disk Access** (System Settings → Privacy) and relaunch — TCC keys grants to the binary's cdhash, which changes on update.
