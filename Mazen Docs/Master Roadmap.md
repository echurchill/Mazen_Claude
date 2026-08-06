# Mazen — Master Roadmap & Sequencing

*The overarching plan: the vision, where every milestone stands, and what order to build next. Living document — last synced **2026-08-05**.*

> **Sync note (2026-08-05).** This doc had drifted a month behind the code: it still called M11/M12/M13
> "in progress", recommended M17/M18 as "next", and made no mention of the **six-scene prologue** —
> which is the actual work of 2026-07-20 → 08-05 and the closest thing the project has to a vertical
> slice. Anyone reading the old version would have thought the game a month behind where it is.
> Statuses below were re-checked **against the code**, not against the other docs.

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
| **M11** — Worlds & Portals | Other worlds through one transition system | ✅ **Delivered** — world stack, walk-through portals, the killer visual; superseded in scope by M15's route-keyed registry |
| **M12** — Asset Import | Import USD/OBJ models, textures, the modular house + split | 🔨 **In use everywhere** — six imported packs dress every world; remaining = normal maps + **bundling for shipping** |
| **M13** — Bandaged Cube | Bonded structures that *refuse* illegal twists | ✅ **ACTIVE, no longer inert** — Scene 4's anchors/bonds ARE this mechanic: the world refuses the twist until the player reads and releases the bond |
| **M14/M14b** — Curved Geometry | Cube renders as a rounded planet (per-vertex inflation) | ✅ **Complete** (2026-07-09); per-world *authored* roundness now real (natural/moon/garden 1.0, Scene 2 flat 0.0) |
| **M15/M16** — Registry + the core loop | Route-keyed worlds; lock → refuse → understand → unlock → twist open → enter | ✅ **Done & playable** (2026-07-11) |
| **M17** — Learning & Memory | Knowledge is transportation | 🔨 **Phase 0 only** — `PlayerKnowledge` exists and is tested, deliberately INERT; the receive beat and knowledge-gated arch are unbuilt |
| **M18** — Densified movement grid | 3×3 → fine stand grid, solidity from removed stand points | ✅ **Built** — `standGrid = 15`; the freeform version stays [aspirational](Milestones/M18%20Freeform%20Movement%20%28Aspirational%29.md) |
| **M19** — Natural & Moon worlds | Mazeless open ground; the moon as a place | ✅ **Built** — natural world + moon, both at roundness 1.0 |
| **M20** — The Journey garden | The Journey Walkthrough vertical slice | 🔨 **Partly** — the garden is built and dressed; the walkthrough's Arc 3 "invention cluster" is unbuilt. **The prologue overtook it** as the actual vertical slice |
| **The PROLOGUE** — Scenes 1–6 | Six connected scenes teaching the game's whole language | ✅ **COMPLETE AND PLAYABLE END TO END** (2026-07-20 → 08-05) — see below |

*(No milestone "M7 and earlier" doc set is tracked here; the [Overnight Plan](Archive/Overnight%20Plan.md) is a historical audit, now superseded.)*

### The prologue — the thing this table used to omit entirely

Six scenes, each teaching one idea, playable start to finish: **1** find a path · **2** reveal a
hidden surface · **3** navigate a world with no privileged floor · **4** turn the world yourself ·
**5** plan a sequence of turns · **6** discover that worlds remember what was done to them. Scripts
in [`Scenes/`](Scenes) (read-only, Eddie's); build status per scene in
[STATE OF PLAY](STATE%20OF%20PLAY.md); the Scene 5/6 analysis lives in
[Scenes 5-6 — Analysis & Answers](Scenes%205-6%20—%20Analysis%20%26%20Answers.md).

What the prologue forced into existence, which no milestone doc predicted: **the seam-owned routing
model** (a wall is drawn wherever either side refuses — twists conserve openings and never mutate
walls), **route-keyed identity** (`WorldCatalog`: the same Scene 2 is Scene 6 when entered from
Scene 5, down to what hangs in its sky), and a **~250,000-check puzzle-integrity suite** that proves
every scene can still be solved by the moves a player actually has.

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
- **Open:** normal maps (EXR→PNG + tangents); crate open/closed; **bundle models + re-enable the app sandbox before shipping** (the one real blocker — see §7).
- *Corrected 2026-08-05:* `modular_fort_01_2k` was described here as "held out of git at 164M, needs a git-LFS decision". It was **deleted** in the 2026-07-17 folder cleanup and is not on disk; its multi-texture experiment is re-downloadable if ever wanted. Its `.gitignore` line is a leftover.

---

## 5. Next — the recommended sequence *(re-synced 2026-08-05)*

**Everything the old sequence recommended has happened.** M15+M16 landed 2026-07-11; M18's grid,
M19's natural and moon worlds, and M20's garden all followed — and then the **six-scene prologue**
was built on top of them and became the project's real vertical slice. The prologue is playable end
to end today.

So the question is no longer "which milestone next" but **what the prologue exposed**. In order:

1. **Touch for the twist (the only gap that breaks a shipped scene).** Tap presses things; Q/E map
   to a two-finger swipe that nothing teaches. Scene 5 solved this by accident with walk-up rotators
   the player stands on. **Scene 4 has the same problem and no answer — and Scene 4 is the scene
   that TEACHES the twist.** On iOS the prologue currently contains a scene that cannot teach its
   own verb. Generalising Scene 5's rotators is the obvious candidate.
2. **Shipping hygiene** — bundle `Mazen_Models` as a build phase and re-enable `ENABLE_APP_SANDBOX`.
   Much closer than it was: the loaded slice of every pack is now IN git (2026-08-05), so bundling is
   a build phase plus one `modelsRoot` change with a dev-path fallback. Until then the game runs on
   exactly one machine.
3. **M17 for real** — the pedestal and its plaque already stand in the temple hall, and
   `PlayerKnowledge` already exists and is tested. Phases 1+ (receive a mote, carry it across a
   portal, have it open a dark arch) are the next *new* verb, and the prologue has been quietly
   building the vocabulary for it.
4. **The remaining scene beats** — small, individually cheap, listed per scene in
   [STATE OF PLAY](STATE%20OF%20PLAY.md)'s "Next": Scene 1's fade-in / sound-absorbing wall /
   reflecting vessel, Scene 2's silence beat, Scene 3's dead ends and nebula parallax, Scene 4's
   second vessel marking, Scene 5's staged 5K emergence and near-miss aids, Scene 6's portal image
   and sweeping view. Good filler; none blocks anything.
5. **Perf, when it gets real** — R2.6 → R2.7 (per-world uniforms, then dirty-flagged rebuilds) plus
   the counterpart-world rebuild are one pass, not three. A visible sky counterpart is a **full
   second `SceneBuilder.build` every frame**, whether or not the player is looking up.
   **Now measured** (Debug, `MAZEN_BENCH`, so ~10x a Release figure):

   | standing in | hangs overhead | counterpart build | frame |
   |---|---|---|---|
   | scene-4 (5³) | scene-2 (11³) | **1.62 ms** | 10.68 ms |
   | scene-5 (7³) | scene-4 (5³) | 0.40 ms | 10.33 ms |
   | scene-2 (11³) | nothing | 0.00 ms | 26.18 ms |

   The expensive direction is a SMALL world hanging a BIG one, and Scene 4 has done exactly that
   since long before the sky decision — 1.62 ms, ~21% of its build. The route-keyed sky adds Scene 4
   (5³) over Scene 6, which by the scene-5 row costs about 0.4 ms on a 26 ms frame: real, small, and
   not the reason Scene 2 is slow — its own 24.56 ms build is. *Caveat:* the harness cannot enter the
   Scene 6 route, so that 0.4 ms is inferred from scene-5 building the same counterpart, not measured
   on Scene 6 itself.

**Newly on the list (2026-08-06):** [**Sky Worlds — Dressing the Counterpart**](Sky%20Worlds%20—%20Dressing%20the%20Counterpart.md).
Eddie noticed sky worlds getting less detailed over time; the cause is structural — `updateAssetInstances`
reads only the active world, so **no counterpart has ever shown a single imported prop**, and a
`.dressed` world overhead has no walls at all. **BUILT 2026-08-06** — the asset pass is
parameterised per world, its bucket cache is per world, and the sky world now carries its structural
props. Two scoping predictions about LOD were wrong and are corrected in the doc.

Parallel tracks when desired:
- **M14b polish** — sunrise/sunset terminator tuning (per-world authored roundness is done).
- **M12 loose ends** — normal maps, crate states.
- **Glyph forge** spike (see [Builder Glyphs](Builder%20Glyphs%20—%204D%20Shadows.md)) — unscheduled; now
  reads as M17's natural companion rather than a side quest.
- **The garden's own puzzle** — the M20 garden is dressed but, as
  [Open Questions](Open%20Questions%20%26%20Future%20Work.md) admits, "isn't a puzzle yet".

## 6. Future milestones (design captured)

- **M11 — Worlds & Portals** — [doc](Worlds%20and%20Portals%20Plan.md) *(reframes the [M11 Lunar Excursion Seed](Milestones/M11%20Lunar%20Excursion%20Seed.md))*. "Bigger on the inside": structures are portals to separate worlds; one transition system for houses, the moon, dungeons. **🔨 Core built & verified (2026-07-06):** world-stack spine, TARDIS walk-through portals + fade, different-size worlds, and **the killer visual** — the real counterpart world (the moon from earth, and vice-versa) hangs in the sky, turning, with every twist baked in; it persists so tears stay. **Remaining:** Phase 3 (persist camera/time across worlds), a real **house interior** destination, moon styling/rules, and multiple portal destinations.
- ~~**M13 — Bandaged Cube Mechanic**~~ — **CLOSED 2026-08-05.** [doc](Bandaged%20Cube%20Mechanic.md).
  Delivered as designed and no longer a future milestone: `bondedGroups` + `canRotateSlice` are the
  general gate (any world can bond anything), `bondsBlocking` reports *how many* things refuse so a
  lock can weaken legibly, and **Scene 4 is the mechanic played straight** — read the bond, release
  the anchors, and only then will the world turn. Scene 2 bonds too.
  *One design note for the record:* the original plan named the modular house as the first bonded
  structure. That never happened and is now moot — interiors moved inside portal worlds (M15), so
  the house has no slice to be torn by. The mechanic found a better first subject in a scene whose
  whole lesson is "the world refuses, and you must understand why."
- **M14 — Superellipsoid Cube** — [doc](Superellipsoid%20Cube.md). **Superseded by M14b** (the per-tile first pass tilted tiles rigidly, so hedge walls levered and crossed; its keepers — the `roundness` dial, `M` matte toggle, sun-softening — live on inside M14b).
- **M14b — Curved Geometry (per-vertex tessellated inflation)** — [doc](Milestones/M14b%20Curved%20Geometry%20Plan.md). **✅ COMPLETE & verified (2026-07-09, committed).** Floors/walls/posts/frame/props tessellate and inflate per-vertex (footprint-project + extrude along the curved normal); rigid assets + the FP camera seat on the curve via `inflatedPlacement`; **sky-worlds inflate with their own roundness** (verified standing on the round 3³ moon); 9³ at 100fps; `roundness == 0` byte-neutral (`-`/`=` dial, default 0). **Remaining = polish/authoring only:** per-world *authored* roundness (natural≈0.5 / mech≈0 — where the sky-foreshadowing pays off) + sunrise/sunset terminator tuning.

---

## 7. Backlog / carryover (not yet on a milestone)

- **Builder Glyphs — 4D shadows** — [doc](Builder%20Glyphs%20—%204D%20Shadows.md). The glyph-language source, answered (2026-07-10): Builders are hyper-dimensional; glyphs = 3D shadows of 4D forms (slice=word, sweep=sentence, rotation=verb; the twist is the language's 3D step-down). Legibility mitigations + a cheap "glyph forge" prototype path (unscheduled, slots near M16/M17). Canon tension **resolved: both true** — the stewards don't know the lost stratum exists; candidate endgame seed: the player as introducer/reunion (non-canonical). Background: [Builders v3 docx](Source%20Material/The_Builders_of_Garden_of_Worlds_-_Transcendent_Civilization_v3.docx).
- **World Graph — relational worlds** — [doc](World%20Graph%20—%20Relational%20Worlds.md). Design captured (2026-07-10): world identity keyed by route (`destination` × `context`), registry resolves keys to instances (lazy, persistent); identity-bound by default (earth↔moon killer visual), divergent by choice (time periods / alternate realities); sky-worlds resolve through the same registry (*the sky can lie*); M17 extension — knowledge in the key re-aims doors. **The registry is M15's first build step** and subsumes M11's "multiple portal destinations."
- **R2 shared-code refactor & optimization** — [doc](R2%20Shared%20Code%20Refactor%20Plan.md). Tracked checklist (2026-07-10) with per-item confidence/danger: Tier 1 "M14b cleanup" (placement-API consolidation, SceneBuilder dedup, slice-matrix single source, camera-pose caching, invariant tests), Tier 2 (per-world uniforms → dirty-flagged scene rebuild; **Renderer split — do before M15**), Tier 3 opportunistic. **Status: Tier 1 ✅, R2.11/R2.16 ✅, R2.8 Renderer split ✅ (+R2.13/R2.14); remaining: R2.6→R2.7 (perf pair), R2.9/R2.10/R2.12/R2.15.**
- **NPC classes** — [doc](NPC%20Classes.md). Design captured (2026-07-08), no implementation. Three classes along a *how memory lives* axis: **machines/computers** (external, networked knowledge, tiered isolated → world-net → inter-world-net, freshest-is-least-complete — a queryable knowledge graph with holes; incl. embedded machines like memory-keeping portals — *more thoughts needed*); **biologic beings** (*tentative, may be cut*); **Builder remnants** (post-biologic, near-certain — internal fallible/self-edited memory, the emotional core of selective-forgetting). **Parked worms:** LLM-backed behavior for the memory-bearing NPCs + co-worker docs to fold in (need paths).
- **Frame-rate** — measurable now: `MAZEN_BENCH=<world>` prints per-phase CPU/GPU timings. Settled 2026-08-01: the renderer was never fill-bound, and **Debug (-Onone) inflates CPU ~10x** — every perf claim must name its configuration. The 50 fps lock is long gone.
- **Cubie frame** (from M8.6) — the 3D dark rails between cube segments were deferred.
- **Per-vertex tangents** — for cleaner normal-mapped tiling (heuristic TBN today).
- **Shipping hygiene** — bundle `Mazen_Models` as a resource + re-enable `ENABLE_APP_SANDBOX` (both disabled for dev via absolute paths). **Promoted to §5 item 2**: this is now the hard blocker on anyone else ever running the game.
- **iOS touch** — see §5 item 1. Tap/double-tap/two-finger-swipe exist; discoverability does not.
- **Large-asset strategy** — SETTLED for the six in-use packs (2026-08-05): track the slice the
  loader actually reads (`OBJ/` + the pack's texture folder), ignore the .blend/FBX/glTF/zip
  source material around it. 515 MB on disk becomes 91 MB in git, no LFS, and a fresh clone runs
  with every gallery whole. Still open for `modular_fort_01_2k` (164 MB of PBR maps, not currently
  on disk) and future heavy PBR kits, where the *textures themselves* are the weight.

---

## 8. Open decisions (need a call before/while building)

1. **Moon transition feel** — instant portal vs. a travel/launch sequence (M11).
2. **House ambition** — keep the simple clean house, or invest in tile-many-modules detail (likely mooted by moving interiors into portal-worlds).
3. ~~**Twist scope** — commit to bandaging as the default?~~ **ANSWERED BY THE PROLOGUE.** Scene 4 makes the bond the thing you must read and release before the world will move, and Scene 5 makes twists a planned sequence. Deliberate, level-scoped twisting is the default in practice.
4. **Large binaries** — settled for the current packs (track the loaded slice, see above); revisit
   if a kit arrives whose own textures exceed what plain git should carry.

---

## 9. Architecture guardrails (proven, keep intact)

- **`WorldScale` is per-world**, never a global singleton — the spine of multi-world (M11).
- **`SceneBuilder(gameState:)`** renders *any* world's state — a second world is just another call.
- **Props anchor to facelets** and ride slice rotations + `Prop.rotate` — imported structures inherit the split for free (proven by M12-E).
- **Vertex-pulling render path** (shaders index `vertices[]`/`instances[]`) lets imported meshes render through the existing pipeline by binding a different buffer.
