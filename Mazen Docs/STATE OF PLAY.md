# STATE OF PLAY — read me first

*A one-page handoff so a fresh session (or a future me) starts with the full picture. Last updated 2026-07-30. If you read nothing else, read this, then the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md) and the [Master Roadmap](Master%20Roadmap.md). Unscheduled ideas / open items live in [Open Questions & Future Work](Open%20Questions%20%26%20Future%20Work.md).*

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
- **Tooling** — debug HUD (`H`, names the prop under you), twist pacing (`G`/`[`/`]`), the **`` ` `` portal hub** (single key → a labeled plaza of TARDIS portals to every world; replaced the per-world `O/I/B/V/Y/1-4` jumps), `U` (make the door lock ready, bypassing the switches — for testing the turn), headless tests (`Tests/run-tests.sh`, **218,050 checks** incl. portal gating + topology-cache invariants). All debug toggles default OFF.

## Live design questions (the next real work is here, not code)

1. **Can "this lock needs *understanding X*" be legible with no UI?** The exact needle The Witness / Outer Wilds spend their whole budget threading. Hardest craft problem.
2. **Is the "understand" verb deep enough to repeat across worlds** without becoming "find the switches"? Leading candidate: a **Builder glyph/language you slowly learn to *read*** (Chants of Sennaar / Heaven's Vault style) as the deepening verb.
3. Where memory-*editing* / selective-forgetting enters as a verb vs. staying theme.
4. **What base do the Builders count in?** Decimal is an anatomical accident (two hands, five fingers); post-biological beings have no fingers, so their base is a *fingerprint of the shape they think in*. Open — Eddie thinking. Constraint already fixed by the design: **base > 4**; and it's deferrable (at 1–4 every base looks like tallies). Claude's pitch: **16 = a tesseract's corners**, because the player's reasonable guess (8 = a cube's corners) is wrong by exactly one dimension and *that error is the revelation*. See [Builder Glyphs](Builder%20Glyphs%20—%204D%20Shadows.md#numbers--the-builders-dont-have-hands-eddie-2026-07-15--open).
5. **The top of the waldo ladder:** magic → plinth → **portable waldo (a "Pipboy") _or_ no device at all**? Constraint: the enhancement must be **fluency, not capacity** — enhance the player toward Builder-scale and you destroy the finitude that makes them the only one who can find pattern in noise ("the player's limitation is the searchlight").
6. **Vase/plinth taxonomy:** the control now looks like the message (a cylinder on a plinth vs. standing alone). Bug (can't tell a word from a handle) or in-theme (*you can't tell a Builder's word from a Builder's hand*)? Decide on purpose.

## Milestone road to a vertical slice (rough)

M14 shape-as-meaning (superellipsoid) → M15 inverted-cube interiors → **M16 the lock→open→enter chain** (the single most important loop) → M18 densified-grid movement & solidity → M17 memory first pass → M19 natural & moon worlds → M20 the Journey Walkthrough (vertical slice) → M21 cozy/feel polish. Details + sequencing in the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md).

## Where things stand — M20 sprint (2026-07-17 → 19)

- **THE JOURNEY SPINE IS WIRED END-TO-END:** the app now **boots into the first world** — a
  pastoral home clearing (the natural world re-used) whose one portal is a **stone arch** filled
  with an original volumetric-cloud shader → walk through into the **garden** → solve the switch
  lock → the temple door (an **elevator** portal, streaks flowing DOWN, hidden until unsealed) →
  the inverted temple interior → return via the UP elevator. Home stays named "earth" so the moon
  still hangs in its sky.
- **TARDIS retired in the journey worlds.** Three portal styles built (prototypes in the gallery
  showroom, north of the catalog): **elevator** (two columns + a two-layer desynced translucent
  streak curtain + motes; down=surface, up=temple), **spot-to-spot** (frameless energy-veil ovals,
  blue/pink — unused so far), **level-to-level** (stone arch + volumetric clouds). Material 23
  drives all the animated energy; the clouds are an ORIGINAL clean-room raymarcher (the Shadertoy
  references were CC BY-NC-SA — see the licence rule in [Asset Sourcing Guide](Asset%20Sourcing%20Guide.md)).
- **Walk-through portals are sub-cell gated:** they fire when you step onto the portal's own
  centre sub-cell (checked continuously, edge-triggered, primed on spawn/twist) — not on entering
  the ~19 m tile. Both live regressions are now permanent tests.
- **Dressed walls are the garden's walls** (the `WallStyle.dressed` framework): stone wall models +
  graded overgrowth re-derived from live topology, fully rigid through twists (identity-owned,
  canonical edge frames). The "stone-in-hedges" static look is kept as an option.
- **Performance pass (Fable, 2026-07-19):** instanced asset draws (1000s → tens, both passes),
  topology-versioned caches (~12k `faceletAt`/frame → cache hits, twist-safety proven structurally),
  matrix + allocation cleanups. Deferred candidates recorded in
  [Open Questions](Open%20Questions%20%26%20Future%20Work.md). **Eddie to verify fps on return.**
- **Tests: 218,050** — the harness now compiles GameState (portal gating + cache invariants covered).
- **Shipping landmine flagged:** imported models load from an absolute dev path — fine now, blocks
  sharing builds ([Known Issues](Known%20Issues.md)).

## Where things stand — the PROLOGUE sprint (2026-07-20 → 29)

The prototype was tagged **`prototype-v1`** and the six scene scripts (Eddie, vibe-scripted with
ChatGPT, in `Mazen Docs/Scenes/` — **do not edit those**) became the build target. Plan:
[Prologue Build Plan](Prologue%20Build%20Plan%20—%20Scenes%201-4.md). Engine orientation for a fresh
session: [Engine Primer](Engine%20Primer%20—%20Worlds%2C%20Twists%2C%20Travel.md).

- **Phase 0 — travel is now authored, not inferred.** `WorldTransition` (`auto`/`push`/`pop`/`goto`)
  lives on the portal, replacing name-matching special cases. Worlds record `lastArrivalOrigin`
  ("how you got here") for Scene 6. `twistEnabled` lets the prologue **withhold the verb** — Scenes
  1–3 disable Q/E, Scene 4 grants it, which is the moment the game hands over its defining action.
- **Scene 2 "The Four Corners" — BUILT & played.** Four corner switches → a control plinth raises an
  alignment cylinder → the world turns and brings a hidden face into view. Eddie: *"Fun."* The
  turned slab now shows **cut faces** (material 25, metal plating) so a rotating slice is solid
  rather than a transparent shell.
- **Scene 4 "The First Turn" — BUILT, in progress.** 5³, three anchors on three faces (bonds
  straddling the player's slab), a sealed portal, and the player's own first twist. Strain now
  **grows as each anchor releases** (~3.2° → 4° → 6.3°), so partial progress is felt before the turn
  is legal. Scene 2 hangs **overhead** as the fixed reference (`WorldStamp.skyCounterpart`).
- **AUDIO IS IN — PHASE**, synthesised at boot, no asset files. Twist strain / lock / turning,
  switches, portals, the cylinder raise. Spatialised and verified on AirPods Pro. Plan:
  [Audio Plan — PHASE](Audio%20Plan%20—%20PHASE.md).
- **Prologue scenes are single-instance** — one Scene 2 however you reach it, so the world overhead
  is the world behind the door. Every other world keeps the registry's per-edge variant default.
- **Skyboxes:** one full-sphere equirect per system; five fictional starfields generated from HYG
  data as compositing bases; `L` cycles them in place. Sky banding fixed by a `skyDay`-scaled TPDF
  dither (gated on the gradient, so clean night skies stay clean).
- **Tests: 249,353** across sizes [3, 5, 7, 9, 11, 25]. The harness now compiles `WorldGraph` too.
- **New doc:** [Routing — How Paths Live in the Cube](Routing%20—%20How%20Paths%20Live%20in%20the%20Cube.md)
  — where a route actually lives (4 bits/tile), why a route floor is decoration, and what a twist
  can and cannot change. Read it before authoring Scene 4's route.

- **Scene 4D is complete.** The layered vessel is built (lathe of Scene 1's silhouette, three ring
  seams that come home one per anchor), it STRAINS in sympathy with any refused twist using the same
  curve the ground uses, and `F` runs the script's six beats — swirl, ring attempt, strain, ground
  answer, spring back, three anchors flashing. Finishing it **grants the twist**: Scene 4 now arrives
  with `twistEnabled = false`, so the verb is learned from an object rather than found in a control
  list, and 4E (the first refused turn) follows immediately.
- **Audio C, D and E are in.** Sustained emitters republished every frame from live topology, so they
  ride twists; occlusion by walking `openings` between listener and source (attenuation, not
  filtering — see the caveat below); per-world ambience beds with the script's silence-on-arrival.
- **Scene 2A closes behind you** — an inward-folding descending tone, the way back gone rather than
  refused (a veil, never a working portal), and dust shaken from wall joints by a twist. Dust is the
  engine's first particle: `heightScale` about the floor pivot drops it, a screen-door dither fades it.
- **The garden's other five faces** now carry ground scatter (they had none), and prop placement is
  continuous with clumped density rather than sitting on the 3×3 authoring lattice.
- **Walkability fix:** dressed worlds were narrowing OPEN edges to a gateway's centred gap despite
  drawing no jambs — invisible walls either side of a lane. See `CubeModel.fullWidthGateways`.
- **Metal fix:** attachment residency was cached by `ObjectIdentifier`, which is a recyclable address;
  a new attachment landing on a dead one's address was never made resident. That was the intermittent
  magenta at startup/resize.

### Open on Scene 4
- **Route alignment (#2) — the one real gap left.** Measured: every tile on `+Z` is already reachable
  from spawn, so the script's premise ("the maze does not connect to the portal; the route exists in
  pieces") is not built. What exists instead is a SEAL: the portal is dark and the turn lights it.
  The break must sit on the **slab boundary** — the player's whole face rotates rigidly and cannot
  change its own internal connectivity; the slab is all 25 `+Z` tiles plus a 5-tile edge strip on
  each side face, `-Z` untouched, so only the 20 strip↔static crossings are editable by a turn.
  Verify those crossings with a reachability probe **before** authoring. Also decide whether to drop
  the seal once the route exists, so the turn's payoff is one idea rather than two locks at once.

### Open elsewhere
- **Audio F** is scene-gated: Scene 3's six kin tones and Scene 5's travelling pulse need those
  scenes to exist. **Occlusion is attenuation, not filtering** — PHASE offers no per-event gain on
  this path, so a walled-off source is pushed further away instead. It gets quieter, not duller.
- fps: 60–70 full screen, ~100 at launch size (Eddie, 2026-07-30). It tracks window AREA, so the
  renderer is fill-bound; adding props is cheap, adding full-screen shader work is not. Worth
  remembering for Scene 3's beams.
- Uncommitted and awaiting a call: `Prototype Worlds.ods` (modified), `Mazen_Models/metal_plate_02_1k/`,
  `To_be_evaluated/`.

## Immediate next actions on resume

- **THE CORE LOOP IS PLAYABLE (2026-07-11):** notice → twist refused (strain + red flare) → undo the lock → twist swings it open → the door lights → step into the inverted 5³ temple interior. Eddie after the first full run: **"That was fun."** M15.0–2 and M16.1–4 built + verified in one session (world registry; inverted interiors; door-semantics portals; the bonded gold temple rooted through the hollow world's core; sealed doors). *(The lock's mechanism has since been rebuilt as switch-plinths — see M16.6 below.)*
- **THE GLYPH LANGUAGE GOT REAL (design, 2026-07-15).** Eddie's caustic expansion: the **frame cube is the cartouche**, the **vase is a sentence made solid** (its cross-sections ARE the words, so reading = a light plane sweeping it), and the **plinth is a WALDO for the world** — mechanism, not signage. First Builder text glossed (*a star, 2 planets, 3 ringed planets, swirled together into a solar system, where humanity lives* — a creation story on a vase in world 1). Full capture: [Builder Glyphs — 4D Shadows](Builder%20Glyphs%20—%204D%20Shadows.md).

### M16.6 — the Builder-glyph tutorial lock: BUILT & Eddie-reviewed ("looked pretty nice", 2026-07-16)

The whole first-world lock is now the caustic-glyph waldo, no UI text anywhere. In-game via `I` (temple), or `U` to skip the switches for testing the turn. Reachable glyph gallery: `Y`.

- **Switches** (replaced the dials): four **switch plinths** in the garden's diagonal corners — a disc-less base + a *number cylinder* that **pokes out = engaged / sits flush = disengaged** (one height-variable cylinder; the disc IS the cylinder at min height, per Eddie). `F` toggles. Three start engaged, **#4 off**. All four engaged dissolves the lock; disengaging any one **re-applies** it (goof-and-fix).
- **Door plinth = positional lock readout:** one dot per switch, **filled if engaged, hollow ring if not** (16 generated caustic masks), so goofing #2 shows dot #2 hollow. All filled ⇒ ready → the **portal** glyph once opened.
- **The turn (waldo):** at the ready door plinth, `F` **raises** the rotator cylinder (swirl on top + the **square** = *world* wrapping the drum, tiled in thirds so it reads at 1:1); a second deliberate `F` (after a 0.5 s **cooldown**, so a stray double-tap can't fire it) **turns the world** — the two half-squares pivot whole and the start-face slice twist opens the door; the cylinder retracts. **Switches go inert once the door is open.**
- **Caustic glyphs** are *generated* (soft blobs splatted at target points — the forge's transport minus the inverse solve), with **per-glyph blob size** (bold dots vs a fine spiral) — a per-glyph slice of the comprehension-gradient dial. Verified by dumping the actual GPU texture slices to disk and eyeballing them.
- ✅ **Naming:** this is **M16.6** (extends M16.5's carved glyph); M21 stays reserved for cozy/feel polish. (Historical commits from 2026-07-15 still say M21; the code doesn't.)
- **STILL DEFERRED — the one open piece:** the **grind / camera-shake / sky-lurch** on the turn ("it's been a while since this last happened"). A self-contained feel pass; trigger the sequence on demand with `U` → `F` → `F` to tune it.

- Loose ends that can ride along anytime: M14b polish (per-world authored roundness; sunset terminator tuning), one FP glance at the moon to fully close R2.11's note.

## Where things stand — M18 + M19 first pass (2026-07-11 night)

- **M18 (densified-grid movement & solidity) is DONE & Eddie-verified:** walk anywhere the
  geometry allows (grass included), never into walls or solid props, across seams/edges/interior
  mirrors; density **15** (~1.3 m/step). Known limit: cube-corner traversal glitch — accepted,
  steer around it (see [Known Issues](Known%20Issues.md)).
- **M19 Natureworld first pass BUILT (awaiting Eddie's eyes):** press **B** — a green planet
  (roundness 1.0), grass everywhere, a meandering unwalkable **stream**, and **conifers**
  (cone-on-trunk, three sizes) scattered over the whole sphere. Build clean, 208,761 tests
  green, boots without crash. Eddie confirmed it **looks good** (2026-07-12); a richness pass
  followed (denser forest, tree-colour variety, a lake).
- **Moon upgraded to grey regolith (M19 Phase 3 first pass, awaiting eyes):** the sky-moon was a
  green hedge cube — now open grey regolith + scattered boulders (`.lunar` stamp), fixing the
  killer visual; also walkable via O. Craters wait on the relief pass.
- **Next (best with Eddie present):** relief/hills (camera-sits-on-ground needs eyes), then
  world-graph/sky wiring. Trees-in-clumps and the looser-garden mix are deferred passes.

## Where things stand (as of 2026-07-10 night)

- **Engine:** M8–M14b done; **R2 refactor DORMANT** — backbone complete (Tier 1, Renderer split into `PipelineFactory`/`TextureLoader`/`AssetRegistry`, size cap 25 + buffer guard, scale-derived fog, 107,366 tests incl. size 25), remaining items trigger-armed in the [R2 tracker](R2%20Shared%20Code%20Refactor%20Plan.md). Fixed this week: E/W-wall black flicker (degenerate TBN), orbit + moon "silver veil" (size-derived fog + sky-object exemption), O(n⁵) startup scan (170ms→7.6ms at 25), Metal-4 attachment residency + redundant state sets (validation run now perfectly clean).
- **Design (a very productive week):** [World Graph](World%20Graph%20—%20Relational%20Worlds.md) — route-keyed world identity, the-sky-can-lie; [Builder Glyphs — 4D Shadows](Builder%20Glyphs%20—%204D%20Shadows.md) — the glyph-source question ANSWERED (slice=word / sweep=sentence / rotation=verb; the twist is the language's 3D step-down), plus the canon frame (both Builder fates true, stewards unaware of the lost) and the reunion-endgame seed; [NPC Classes](NPC%20Classes.md) (Remnants = 4D intersections; co-worker's NPC/AI docs still pending, ~1.5 wks); [Builders v3 background doc](Source%20Material/The_Builders_of_Garden_of_Worlds_-_Transcendent_Civilization_v3.docx) committed.
- **Key mechanism notes:** all placement routes through `CubeModel.restMatrix` / `inflatedPlacement` (this is what makes M15's inverted basis a ~one-function change). `InstanceData` carries per-instance `spinMatrix`/`roundness`/`invHalfExtent`. Debug keys: `M` matte, `-`/`=` roundness (all worlds), `H` HUD, `J` spin toggle, `K` freeze time in place, `N` size cycle 3–9 (engine caps at 25).
- Build note: run `xcodebuild`/`git` with the sandbox disabled. **git ↔ external volume:** if git returns `EPERM` on `.git` after a Claude update, re-grant the live "claude" entry **Removable Volumes / Full Disk Access** (System Settings → Privacy) and relaunch — TCC keys grants to the binary's cdhash, which changes on update.
- `main` == `origin/main`, everything committed and pushed. Repo is **private**.
