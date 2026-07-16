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
| **M14/M14b** — Curved Geometry | Cube renders as a rounded planet (per-vertex inflation) | ✅ **Complete** (2026-07-09) |

*(No milestone "M7 and earlier" doc set is tracked here; the [Overnight Plan](Archive/Overnight%20Plan.md) is a historical audit, now superseded.)*

---

## 3. Done / mostly done

### M8 — Textured Mesh Rendering — [doc](Milestones/M8%20Textured%20Mesh%20Plan.md)
Core visual upgrade **done**: painted hedge/gravel/stone textures via texture arrays, UV mapping, a rewritten materialID-1 shader (normal mapping via heuristic TBN, half-Lambert, height-based moss, orbit/FP blending), a dynamic sky, and 2048² PCF shadow mapping. MSAA 4× on. Rounded hedge tops implemented.
- **Superseded, not TODO:** M8.3's wall-height (→1.2), wall-thickness (→0.12), and eye-height (→0.45) targets were *overridden* by M10 Phase A's perceptual scale-up (walls 0.24, eye 0.09 — a tile now reads as a ~19m plaza). Those M8 numbers are obsolete by design.
- **Genuinely deferred:** the 3D "cubie frame" dark rails between segments; a true per-vertex tangent on `MazeVertex` (heuristic TBN used instead).

### M9 — Cube Solar System — [doc](Milestones/M9%20Cube%20Solar%20System%20Plan.md)
**Complete.** All phases 1–7 + polish M9.5-1…4: `CelestialSystem` sun/moon orbits (sun period 480s / moon 546s, tuned distances so their apparent sizes match → Earth-like eclipse), per-face day/night terminator (`surfDir = normalize(worldPosition)`, softened), dynamic sky, idle cube spin, moonlight fill, moon shadows, eclipse. **Deferred (cosmetic, user-agreed):** further orbit-view terminator softness.

### M10 — Tile Scale-Up — [doc](Milestones/M10%20Tile%20Scale-Up%20Plan.md)
**Complete (A–G).** Perceptual scale-up; 3×3 sub-cell **path-cross** movement with 8-way (`Heading8`) 45° turns; gateways + jamb posts; cross-face crossing; `stampRoom`/`stampOpenPlaza` multi-tile rooms; the procedural prop system (topiary/obelisk/chest + the 2×2 modular house). Key fixes baked in: floor-UV `uvTurns` accumulator, corner-cut slerp at face crossings, gap-removal (cellSpacing 1.0), shadow-acne. **Deferred:** Phase H (doors/locks/animated gates).

---

## 4. In progress

### M12 — Asset Import Pipeline — [doc](Milestones/M12%20Asset%20Import%20Plan.md)
**Done:** ModelIO USD/OBJ import into the `MazeVertex` layout with 32-bit indices (M12-A/C/D); textured props (fire pit, statue, stumps, crate) + solid-colour multi-material OBJ kits; the **UV V-flip fix** (all imports); and **M12-E: the modular house splits Rubik's-style** — placed via the four `.houseCorner` Prop anchors, riding slice `animMat`, verified with the new single-step twist control. Imported kit walls + procedural hip roof, relocated to its own −Z court.
**Remaining / learnings:**
- **Kit-scale mismatch (learning):** kit modules are small (tile-many-per-room); our tiles are ~19m, so one stretched module per edge squashes windows/doors and the kit roof has no 4-way hip. → richer house detail needs the **tile-many-small-modules** approach, *or* moves inside a portal-world (see M11).
- **Open:** normal maps (EXR→PNG + tangents); crate open/closed; **fort multi-texture** (`modular_fort_01_2k`, held out of git at 164M — needs a git-LFS decision); bundle models + re-enable the app sandbox before shipping.

---

## 5. Next — the recommended sequence *(updated 2026-07-10)*

~~**M15 + M16 together**~~ ✅ **DONE & PLAYABLE (2026-07-11)** — the full core loop (notice → refused → understand → unlock → twist open → enter) built and Eddie-verified in one day; statuses in the [M15-M16 Work Plan](Milestones/M15-M16%20Work%20Plan.md). **Next: [M17 Work Plan](M17%20Work%20Plan.md)** (memory-motes; knowledge-is-transportation) and [M18 Work Plan](Milestones/M18%20Work%20Plan.md) (densified stand-point grid: 3×3 → 9×9-ish, grass walkable, solidity = stand points removed under walls/props; the full-freeform version is kept [aspirational](Milestones/M18%20Freeform%20Movement%20%28Aspirational%29.md); then [M19 Work Plan](Milestones/M19%20Work%20Plan.md): the Natural & Moon worlds — inspiration in [Natural & Ring Worlds](Natural%20%26%20Ring%20Worlds%20—%20Inspiration.md) — and [M20 Work Plan](M20%20Work%20Plan.md): the **Journey Walkthrough vertical slice**, staging the [Player Journey](Player%20Journey%20—%20A%20Session.md) beat-for-beat; feel polish becomes M21) — both drafted, awaiting greenlight; **M18 runs first** (Eddie: it's the prerequisite for M19's mazeless natural worlds — open ground at roundness 1.0 that must not feel like a maze). In one line: World Registry (route-keyed worlds) → inverted-cube interior world type (a ~one-function basis change thanks to R2's placement consolidation) → first temple interior through a portal → activate M13 bandaging as the verb (bond → refusal cue → understand → unlock) → **twist open → step inside** — the loop that everything else exists to serve.

*(Historical: the previous recommendation here — "build M11 next" — was followed and delivered: world stack, TARDIS portals, the killer visual. M11's remaining oddments are absorbed: "multiple portal destinations" → the M15 registry; the house interior → an M15 interior world.)*

Parallel tracks when desired:
- **M14b polish** — per-world authored roundness + sunset terminator tuning.
- **M12 loose ends** — normal maps / fort multi-texture / bundling — polish, not blockers.
- **Glyph forge** spike (see [Builder Glyphs](Builder%20Glyphs%20—%204D%20Shadows.md)) — unscheduled; slots near M16 Phase 5 / M17.

---

## 6. Future milestones (design captured)

- **M11 — Worlds & Portals** — [doc](Worlds%20and%20Portals%20Plan.md) *(reframes the [M11 Lunar Excursion Seed](Milestones/M11%20Lunar%20Excursion%20Seed.md))*. "Bigger on the inside": structures are portals to separate worlds; one transition system for houses, the moon, dungeons. **🔨 Core built & verified (2026-07-06):** world-stack spine, TARDIS walk-through portals + fade, different-size worlds, and **the killer visual** — the real counterpart world (the moon from earth, and vice-versa) hangs in the sky, turning, with every twist baked in; it persists so tears stay. **Remaining:** Phase 3 (persist camera/time across worlds), a real **house interior** destination, moon styling/rules, and multiple portal destinations.
- **M13 — Bandaged Cube Mechanic** — [doc](Bandaged%20Cube%20Mechanic.md). Bond structures so a twist that would tear them is *refused*; twisting becomes a rare, deliberate, readable puzzle action. The house is the first candidate bonded structure.
- **M14 — Superellipsoid Cube** — [doc](Superellipsoid%20Cube.md). **Superseded by M14b** (the per-tile first pass tilted tiles rigidly, so hedge walls levered and crossed; its keepers — the `roundness` dial, `M` matte toggle, sun-softening — live on inside M14b).
- **M14b — Curved Geometry (per-vertex tessellated inflation)** — [doc](Milestones/M14b%20Curved%20Geometry%20Plan.md). **✅ COMPLETE & verified (2026-07-09, committed).** Floors/walls/posts/frame/props tessellate and inflate per-vertex (footprint-project + extrude along the curved normal); rigid assets + the FP camera seat on the curve via `inflatedPlacement`; **sky-worlds inflate with their own roundness** (verified standing on the round 3³ moon); 9³ at 100fps; `roundness == 0` byte-neutral (`-`/`=` dial, default 0). **Remaining = polish/authoring only:** per-world *authored* roundness (natural≈0.5 / mech≈0 — where the sky-foreshadowing pays off) + sunrise/sunset terminator tuning.

---

## 7. Backlog / carryover (not yet on a milestone)

- **Builder Glyphs — 4D shadows** — [doc](Builder%20Glyphs%20—%204D%20Shadows.md). The glyph-language source, answered (2026-07-10): Builders are hyper-dimensional; glyphs = 3D shadows of 4D forms (slice=word, sweep=sentence, rotation=verb; the twist is the language's 3D step-down). Legibility mitigations + a cheap "glyph forge" prototype path (unscheduled, slots near M16/M17). Canon tension **resolved: both true** — the stewards don't know the lost stratum exists; candidate endgame seed: the player as introducer/reunion (non-canonical). Background: [Builders v3 docx](Source%20Material/The_Builders_of_Garden_of_Worlds_-_Transcendent_Civilization_v3.docx).
- **World Graph — relational worlds** — [doc](World%20Graph%20—%20Relational%20Worlds.md). Design captured (2026-07-10): world identity keyed by route (`destination` × `context`), registry resolves keys to instances (lazy, persistent); identity-bound by default (earth↔moon killer visual), divergent by choice (time periods / alternate realities); sky-worlds resolve through the same registry (*the sky can lie*); M17 extension — knowledge in the key re-aims doors. **The registry is M15's first build step** and subsumes M11's "multiple portal destinations."
- **R2 shared-code refactor & optimization** — [doc](R2%20Shared%20Code%20Refactor%20Plan.md). Tracked checklist (2026-07-10) with per-item confidence/danger: Tier 1 "M14b cleanup" (placement-API consolidation, SceneBuilder dedup, slice-matrix single source, camera-pose caching, invariant tests), Tier 2 (per-world uniforms → dirty-flagged scene rebuild; **Renderer split — do before M15**), Tier 3 opportunistic. **Status: Tier 1 ✅, R2.11/R2.16 ✅, R2.8 Renderer split ✅ (+R2.13/R2.14); remaining: R2.6→R2.7 (perf pair), R2.9/R2.10/R2.12/R2.15.**
- **NPC classes** — [doc](NPC%20Classes.md). Design captured (2026-07-08), no implementation. Three classes along a *how memory lives* axis: **machines/computers** (external, networked knowledge, tiered isolated → world-net → inter-world-net, freshest-is-least-complete — a queryable knowledge graph with holes; incl. embedded machines like memory-keeping portals — *more thoughts needed*); **biologic beings** (*tentative, may be cut*); **Builder remnants** (post-biologic, near-certain — internal fallible/self-edited memory, the emotional core of selective-forgetting). **Parked worms:** LLM-backed behavior for the memory-bearing NPCs + co-worker docs to fold in (need paths).
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
