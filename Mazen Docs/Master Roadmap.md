# Mazen — Master Roadmap & Sequencing

*The overarching plan: the vision, where every milestone stands, and what order to build next. Living document — last synced 2026-07-06.*

> This is the map. Each milestone has its own detailed doc; this ties them together, records status, and sequences what's next. Per-doc status headers point back here.

---

## 1. The vision (the enduring core)

**Rubik's cube meets hedge-maze meets game board.**

A first-person puzzle-exploration game where **the game board *is* a Rubik's cube.** The player stands inside a procedurally-generated hedge maze covering the cube's surface. Tiles are unknown until discovered (fog at the periphery), then reveal walkable paths and hedge walls. **The signature mechanic:** rotating a slice of the cube **rearranges the maze around the player** — the player rides the rotating tile, walls open and close, the space transforms. Pastoral aesthetic: green hedges, sandy paths, stone, white fog, viewed at player height.

**What has emerged on top of that core** (and now belongs to the vision):
- **A living sky** — a cube sun & moon with real orbits, day/night, moon phases, eclipses (M9). The cube reads as a small **planet**.
- **Multiple worlds** — the cube is a *hub*; doors and gates are **portals** to other worlds (house interiors, the moon), each at its own scale. "Bigger on the inside."
- **The twist as a scalpel, not ambient physics** — via *bandaging*, twisting becomes a deliberate, level-scoped puzzle action rather than a constant hazard.

---

## 2. Status at a glance

| Milestone | Scope | Status |
|---|---|---|
| **M8** — Textured Mesh | Painted textures, UVs, shader rewrite, sky, shadows | ✅ **Core done** (~85%); a few targets superseded by M10 (see note) |
| **M9** — Cube Solar System | Sun/moon orbits, day/night, moon phases, eclipse, per-face terminator | ✅ **Complete** (cosmetic terminator finesse deferred) |
| **M10** — Tile Scale-Up | Perceptual scale, 3×3 sub-grid movement, gateways, rooms, procedural props | ✅ **Complete** (A–G); Phase H "gates" deferred |
| **M12** — Asset Import | Import USD/OBJ models, textures, the modular house + split | 🔨 **In progress** — pipeline, house split, decorations-ride-slices done; texture polish + shipping remain |
| **M11** — Worlds & Portals | Moon + house interiors via one world-transition system | 🔨 **In progress** — spine, TARDIS walk-through portals, and the killer visual built & verified |
| **M13** — Bandaged Cube | Bonded structures that *refuse* illegal twists | 🔨 **Foundation built** — legality rule + tests + enforcement wired (inert until something's bonded) |
| **M14** — Superellipsoid Cube | Inflate the cube toward a rounded planet | 💡 **Design captured** — future |

*(No milestone "M7 and earlier" doc set is tracked here; the [Overnight Plan](Overnight%20Plan.md) is a historical audit, now superseded.)*

---

## 3. Done / mostly done

### M8 — Textured Mesh Rendering — [doc](M8%20Textured%20Mesh%20Plan.md)
Core visual upgrade **done**: painted hedge/gravel/stone textures via texture arrays, UV mapping, a rewritten materialID-1 shader (normal mapping via heuristic TBN, half-Lambert, height-based moss, orbit/FP blending), a dynamic sky, and 2048² PCF shadow mapping. MSAA 4× on. Rounded hedge tops implemented.
- **Superseded, not TODO:** M8.3's wall-height (→1.2), wall-thickness (→0.12), and eye-height (→0.45) targets were *overridden* by M10 Phase A's perceptual scale-up (walls 0.24, eye 0.09 — a tile now reads as a ~19m plaza). Those M8 numbers are obsolete by design.
- **Genuinely deferred:** the 3D "cubie frame" dark rails between segments; a true per-vertex tangent on `MazeVertex` (heuristic TBN used instead).

### M9 — Cube Solar System — [doc](M9%20Cube%20Solar%20System%20Plan.md)
**Complete.** All phases 1–7 + polish M9.5-1…4: `CelestialSystem` sun/moon orbits (sun period 480s / moon 546s, tuned distances so their apparent sizes match → Earth-like eclipse), per-face day/night terminator (`surfDir = normalize(worldPosition)`, softened), dynamic sky, idle cube spin, moonlight fill, moon shadows, eclipse. **Deferred (cosmetic, user-agreed):** further orbit-view terminator softness.

### M10 — Tile Scale-Up — [doc](M10%20Tile%20Scale-Up%20Plan.md)
**Complete (A–G).** Perceptual scale-up; 3×3 sub-cell **path-cross** movement with 8-way (`Heading8`) 45° turns; gateways + jamb posts; cross-face crossing; `stampRoom`/`stampOpenPlaza` multi-tile rooms; the procedural prop system (topiary/obelisk/chest + the 2×2 modular house). Key fixes baked in: floor-UV `uvTurns` accumulator, corner-cut slerp at face crossings, gap-removal (cellSpacing 1.0), shadow-acne. **Deferred:** Phase H (doors/locks/animated gates).

---

## 4. In progress

### M12 — Asset Import Pipeline — [doc](M12%20Asset%20Import%20Plan.md)
**Done:** ModelIO USD/OBJ import into the `MazeVertex` layout with 32-bit indices (M12-A/C/D); textured props (fire pit, statue, stumps, crate) + solid-colour multi-material OBJ kits; the **UV V-flip fix** (all imports); and **M12-E: the modular house splits Rubik's-style** — placed via the four `.houseCorner` Prop anchors, riding slice `animMat`, verified with the new single-step twist control. Imported kit walls + procedural hip roof, relocated to its own −Z court.
**Remaining / learnings:**
- **Kit-scale mismatch (learning):** kit modules are small (tile-many-per-room); our tiles are ~19m, so one stretched module per edge squashes windows/doors and the kit roof has no 4-way hip. → richer house detail needs the **tile-many-small-modules** approach, *or* moves inside a portal-world (see M11).
- **Open:** normal maps (EXR→PNG + tangents); crate open/closed; **fort multi-texture** (`modular_fort_01_2k`, held out of git at 164M — needs a git-LFS decision); bundle models + re-enable the app sandbox before shipping.

---

## 5. Next — the recommended sequence

**Build M11 (Worlds & Portals) next.** It's the highest-leverage move: it simultaneously (a) unblocks *rich* house interiors by moving detail off the cramped cube surface into a properly-scaled interior world, and (b) delivers the moon. One world-transition system serves both — and the architecture (`WorldScale` per-world, `SceneBuilder(gameState:)`, the `interact()` portal hook) was already built for it.

Suggested order within M11:
1. **World-switch spine** — an `activeWorld` + a world stack + `enterWorld`/`exitWorld`, with a simple screen-fade transition.
2. **First interior** — a small hand-built room reached through the house door (proves "bigger on the inside" end-to-end).
3. **The moon** — as a second world, then its presentation (the **orbital-counterpart "killer visual":** the real other world hanging in the sky, updated live — from the M11 seed).

Then, as separate tracks when desired:
- **M13 Bandaged Cube** — makes the twist deliberate; pairs with real level design.
- **M14 Superellipsoid Cube** — visual; pairs with the M9 planet feel.
- **M12 loose ends** — normal maps / fort multi-texture / bundling — as polish, not blockers.

---

## 6. Future milestones (design captured)

- **M11 — Worlds & Portals** — [doc](Worlds%20and%20Portals%20Plan.md) *(reframes the [M11 Lunar Excursion Seed](M11%20Lunar%20Excursion%20Seed.md))*. "Bigger on the inside": structures are portals to separate worlds; one transition system for houses, the moon, dungeons. **🔨 Core built & verified (2026-07-06):** world-stack spine, TARDIS walk-through portals + fade, different-size worlds, and **the killer visual** — the real counterpart world (the moon from earth, and vice-versa) hangs in the sky, turning, with every twist baked in; it persists so tears stay. **Remaining:** Phase 3 (persist camera/time across worlds), a real **house interior** destination, moon styling/rules, and multiple portal destinations.
- **M13 — Bandaged Cube Mechanic** — [doc](Bandaged%20Cube%20Mechanic.md). Bond structures so a twist that would tear them is *refused*; twisting becomes a rare, deliberate, readable puzzle action. The house is the first candidate bonded structure.
- **M14 — Superellipsoid Cube** — [doc](Superellipsoid%20Cube.md). Inflate the cube toward a rounded planet (n between sphere and cube); reinforces the M9 solar-system feel and *improves* the day/night shading as it rounds.

---

## 7. Backlog / carryover (not yet on a milestone)

- **iOS touch input** — the macOS path is rich; iOS interactivity is still minimal/stubbed. Needs a touch-control design (movement + slice twist gestures).
- **Frame-rate** — `preferredFramesPerSecond = 120`; confirm it's actually achieved (a historical 50fps lock was flagged in the Overnight audit — verify it's gone).
- **Cubie frame** (from M8.6) — the 3D dark rails between cube segments were deferred.
- **Per-vertex tangents** — for cleaner normal-mapped tiling (heuristic TBN today).
- **Shipping hygiene** — bundle `Mazen_Models` as a resource + re-enable `ENABLE_APP_SANDBOX` (both disabled for dev via absolute paths).
- **Large-asset strategy** — git-LFS (or exclude) for `modular_fort_01_2k` (164M) and future heavy PBR kits.

---

## 8. Open decisions (need a call before/while building)

1. **Moon transition feel** — instant portal vs. a travel/launch sequence (M11).
2. **House ambition** — keep the simple clean house, or invest in tile-many-modules detail (likely mooted by moving interiors into portal-worlds).
3. **Twist scope** — commit to bandaging (twist deliberate/level-scoped) as the default (M13)?
4. **Large binaries** — git-LFS vs. exclude for heavy model kits.

---

## 9. Architecture guardrails (proven, keep intact)

- **`WorldScale` is per-world**, never a global singleton — the spine of multi-world (M11).
- **`SceneBuilder(gameState:)`** renders *any* world's state — a second world is just another call.
- **Props anchor to facelets** and ride slice rotations + `Prop.rotate` — imported structures inherit the split for free (proven by M12-E).
- **Vertex-pulling render path** (shaders index `vertices[]`/`instances[]`) lets imported meshes render through the existing pipeline by binding a different buffer.
