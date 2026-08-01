# STATE OF PLAY — read me first

*A one-page handoff so a fresh session (or a future me) starts with the full picture. Last updated 2026-08-01. If you read nothing else, read this, then the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md) and the [Master Roadmap](Master%20Roadmap.md). Unscheduled ideas / open items live in [Open Questions & Future Work](Open%20Questions%20%26%20Future%20Work.md).*

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
- **Tooling** — debug HUD (`H`, names the prop under you), twist pacing (`G`/`[`/`]`), the **`` ` `` portal hub** (single key → a labeled plaza of TARDIS portals to every world; replaced the per-world `O/I/B/V/Y/1-4` jumps), `U` (make the door lock ready, bypassing the switches — for testing the turn), headless tests (`Tests/run-tests.sh`, **249,648 checks** incl. portal gating + topology-cache invariants). All debug toggles default OFF.

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

## Where things stand — SCENES 3 AND 5; the chain is whole (2026-07-31 → 08-01)

**All six prologue worlds now exist and lead into each other**, and every one of them is reachable
from the `` ` `` hub, whose grid grew a northern row to hold them.

### Scene 3 — "The Heart of the World"
- **Six obelisks fire beams into the cube's centre, where an orb hangs.** The orb is at an interior
  centre — a place nothing had ever rendered — and it lights the chamber rather than merely glowing:
  orb and beams are published as segment (line) lights from `GameState.chamberEmitters`, the single
  source both `SceneBuilder` and `Renderer` read, so what is drawn and what lights are never two
  descriptions of the same thing that can drift apart.
- The chamber wakes **in stages** and fires its wave once. Plinths bind 1:1 to distant obelisks.
- Called "the only real performance risk" in the build plan. It costs less than feared: the renderer
  is fill-bound, and six beams are geometry, not full-screen work.
- **Still open:** 3H's authored maze and dead ends (the layout is still procedural), 3L nebula
  parallax.

### Scene 5 — "The Broken Meridian"
- A luminous **circuit laid across the world's surface**: a source, runs of channel that cross face
  edges, and receivers at the ends. The circuit is broken on arrival; a turn that brings the runs
  back into line completes it. Solvability is asserted, not assumed — a probe walks the circuit for
  the scramble the stamp applies.
- **The channel walker was the whole scene's bug.** `layChannel` assumed cross-face neighbours share
  a row/col, which is false at four of the six seams, so runs stopped dead at an edge and the scene
  was unwinnable. `layRun` now uses `edgeCrossing` and carries the reoriented heading forward. The
  solvability probe caught it; nothing about the world's appearance did.
- **Eddie's screenshot found three more** (fixed 2026-08-01), and one of them is a lesson about
  rounded worlds: an overlay lifted in the MODEL MATRIX has its lift *discarded*, because the Cobb
  inflation projects the footprint back onto the shell. The channels were being drawn and were
  z-fighting the ground. Lift belongs in LOCAL z, which the inflation extrudes along the normal.
  The other two: junction vessels asked for 3+ channel arms, and three runs from one source have
  exactly one branch point (now they stand where a channel crosses a face edge — where the slabs
  part, so where a turn can break the route); and the receivers used the stock obelisk, a 1.16-unit
  shaft on a world of radius 3.5.
- **A green test hid all of it.** `testSceneFiveVesselsMirrorLocalTruthNotProgress` counted vessels
  *including* the source, which exists by construction, so `junctions > 0` could never fail. A count
  that includes the thing you are trying to prove exists is not a check. It now excludes the source.
- **The pulse is real** (2026-08-01). It was a shader scroll: pretty, and a lie — it never stopped
  where the route stopped, which is the only thing the scene has to teach ("the circuit explains
  itself by failing visibly"). It is now a front advancing through the reach walk's DEPTH map at the
  player's own gait, and the groove shader, the travelling emitter and the incomplete tone all read
  that one number, so light and sound cannot drift apart. `discoveryAmount` carries depth + 1 for
  channel tiles — clamps to 1 for "lit", subtracts back to the step count — so no instance field had
  to be added. **Audio F is complete**; Scene 5's three voices sit at ratios of one 110 Hz
  fundamental, the break a tritone that will not settle.
- **5K has its own rule now.** It borrowed Scene 3's chooser, which picks the tile farthest to WALK
  to and knows nothing about channels, so it could put the door where the current never goes — the
  "arbitrary reward disconnected from the puzzle" the script rules out. The door now stands at the
  far end of the live current, which gives 5L for free: the way to it is the thing you just repaired.
- **The surface is pale stone** — Tiles141, Eddie's pick (material 34, texture slice 3).
- **Still open:** 5J, the world-becomes-a-diagram.

## Where things stand — SCENE 1, and the app opens into the prologue (2026-07-31)

**The app now boots into Scene 1.** Starting anywhere else made the prologue's opening a place you
had to go looking for. `earth`/`homeClearing` is still built on demand from the hub, and the moon
still hangs in its sky, because that binding is by name rather than by being first.

### Scene 1 — "The First Clearing"
- A 3×3 walled clearing at dawn; a break in its north wall that is "not framed as a doorway"; a
  corridor that **dog-legs** inside the wall (Eddie) so the maze is not visible through the gap; a
  carved maze of ~35 tiles beyond it; and the arch at the dead end FURTHEST from the corridor, so it
  is found last and several vessels have been met on the way.
- **Vessels at every dead end**, solitary and in groups, plus two alcoves off the corridor itself —
  which state the scene's rule (a dead end is where a vessel stands) before the maze can be mistaken
  for getting lost.
- **They move only when you are not looking.** Camera-driven, in whole quarter-turns, so you find
  one *having moved* and can never catch it — the only way to earn "subtle enough that the player
  may doubt having seen it". Drift is stored per facelet on the world, so it survives leaving and
  returning. The largest, beside the arch, does the opposite and tracks you at ~9°/s.
- **1E variations:** one inert, one humming a fifth above the undertone, one warmer in sunlight.
- **Audio:** sparse unplaceable birds that hush near the arch; a 49 Hz undertone that latches on the
  player's first movement and never stops.
- **The fog is OFF.** Built as the script asks and it read badly (Eddie: "really damn odd") — the
  fog is a solid volume, not a horizon, so the maze arrived as blocks lifting off rather than as
  distance resolving. The line-of-sight reveal it prompted stays for the worlds that still fog. The
  script's gradual-scale idea deserves another attempt with a different mechanism, probably tight
  distance fog rather than tile discovery.

### Elsewhere
- **The portal lights its surroundings** (Scene 1G). An emissive surface lights only itself, so the
  arch could never do this alone; the nearest ACTIVE portal is published as a point light. First
  pass was a floodlight that washed the obelisks out of Scene 2 — now a glow on nearby stone.
- **`F` acts on what you are nearest to**, not on the portal every time. A tile is ~19 m across and
  Scene 1 stands its largest vessel BESIDE the arch, so the portal branch made that vessel — the one
  the script most wants looked at — unreachable.
- **A world places the player where it says.** `spawnLocation` was only applied on arrival through a
  portal; anything else got PlayerState's default, the centre of the front face. Dormant for as long
  as it existed, because every world revealed itself at build.

### Things that were right for a world standing still
Three of the last four bugs had this shape, and it is worth suspecting first:
- **Seals were one-sided.** Enough while movement is tested on the departing tile — you could not
  step out — until `reconcileSharedEdges` (open wins) undid all six. Now `sealRegionBorder` closes
  both halves and runs last in each stamp.
- **Only the play face was sealed.** Fine until a slab TURNS and swings other faces into reach.
  Scene 2 now seals every face; edges travel with their tiles, so each stays an island.
- **`setSharedEdge` closed `openings` but not `openEdges`.** That mask means "fully open, no
  geometry" and `edgeAllows` checks it FIRST, so sealed borders leaked wherever a room had set it.

### Hazard worth remembering
`reconcileSharedEdges` has now caused two bugs. It fixed a real class (an edge is stored twice and
the halves could disagree), but its rule was chosen on a false premise — "every one-sided edit is an
insert", which a grep for `openings.remove` could not disprove because six sites mutate a local
`op`. **One-sided closes are what it gets wrong.** Anything that opens up unexpectedly, suspect it.

### Still open on Scene 1
- The wall-absorbs-sound cue (1C) and the vessel carrying "a faint reflection of a place not visible
  nearby" (1E) — the only two script beats not built.
- The 1B fade-in: the script opens with the screen fading in; at app start you simply appear.
- Maze walls lower than the clearing walls (Eddie deferred).
- **Unverified:** the moon should be setting as the sun rises. Dawn is set; the moon's position at
  that moment has not been checked.

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
- **Tests: 249,529** across sizes [3, 5, 7, 9, 11, 25]. The harness now compiles `WorldGraph` too.
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

### Scene 4 is complete
- **The route puzzle is built.** The portal is present and lit from arrival and simply cannot be
  walked to: its corner of `+Z` is sealed from the rest of the face, and its one way out is a single
  ring tile whose along-ring edges are shut and whose outer door opens onto a sealed pocket — the
  route reaching the slab boundary and stopping, which is what the player walks up to and reads.
  A 90° turn slides that ring tile a quarter of the way round, its door now faces the live shell,
  and the world is joined up. Nothing is created; a piece is brought into line.
- **The seal is gone.** The obstacle is the route, not a dark door — two locks at once blurred the
  one idea the turn is meant to land. ("A portal is present, but the maze does not connect to it.")
- Measured and asserted: portal unreachable before, reachable after, and **all three anchors
  reachable throughout** — the half a route puzzle most easily breaks.
- Useful geometry, measured rather than derived: the slab is the whole `+Z` face **plus a one-tile
  ring** (5 tiles on each side face). Everything in it rotates together, so a turn cannot change
  reachability *within* `+Z`. The 20 places that ring meets the static shell are the entire editable
  surface of any Scene 4-style puzzle.

### "Invisible wall" was three different bugs (2026-07-30)

Worth knowing, because the phrase describes a SYMPTOM and the three causes need opposite
investigations. All three are fixed and each has a test that makes its class impossible.

1. **Asymmetric edges.** An edge is one thing stored in BOTH tiles, and several stamps carved a
   passage by opening one side only. Movement is tested on the departing tile, so it was passable
   one way; and the dressed wall is drawn by whichever tile owns it, so if the owner thought the
   edge was open, nothing was drawn while the other side still blocked. 18 halves in Scene 2, 38 in
   the hub. `reconcileSharedEdges` (open wins) runs after every stamp.
2. **Oversized footprints.** Flat things set into the ground — anchor, dial, glyph, and earlier the
   vessel — inherited the default footprint of `grid/3/2` = a 6.3 m square, filling the middle of
   their own tile. A footprint draws nothing, so it is invisible by construction.
3. **Corner refusals at a seam.** Crossing an edge open on both sides carried the lateral over
   verbatim, landing on the arrival tile's corner where a PERPENDICULAR wall had claimed the cell.
   156 spots in Scene 4. Only bites when you walk ALONG a wall. Movement now slides the lateral
   toward the middle until it finds a free cell.

**The HUD tells them apart** — `Walls: NESW` shows a letter where the engine believes there is a
wall and a dot where it believes there is a way through, plus the stand sub-cell and any solid prop.
A letter in the direction you are pushing means a wall failed to DRAW; a dot means collision is
wrong. From a screenshot those look identical, which is why the first two took so long.

### Open elsewhere
- **Audio F** is scene-gated: Scene 3's six kin tones and Scene 5's travelling pulse need those
  scenes to exist. **Occlusion is attenuation, not filtering** — PHASE offers no per-event gain on
  this path, so a walled-off source is pushed further away instead. It gets quieter, not duller.
- **fps: DIAGNOSED (2026-08-01), and BOTH standing assumptions were wrong.** The renderer was not
  fill-bound. Scene 2's 11³ spent 27.7 of its 27.9 ms on the CPU with the GPU idle — 18.4 of it
  re-placing dressed-wall props that had not moved. The derivation was cached; the PLACEMENT was
  not, and could not be, because the world's idle spin is baked into every prop matrix. Spin is one
  matrix common to all of them, so it now goes on at pack time and the buckets survive across
  frames.
- **The second wrong assumption was mine: those were DEBUG numbers.** In Release the CPU was never
  the wall — the same frame costs 0.5 ms of CPU, and the asset cache is worth 3.3 ms of CPU but
  almost nothing in frame time. It is still the right change (Eddie plays the Debug build from
  Xcode, where it is 27.9 → 18.9 ms), but "36 → 70 fps" was a Debug measurement and is corrected
  here. **Measure the configuration you are claiming about.**
- **The GPU wall is the imported props, in both passes.** By ablation (`MAZEN_BENCH_ABLATE`):
  removing asset draws from the main pass takes 21 ms to the 10 ms vsync floor; removing them from
  the SHADOW pass takes 21 → 15.7, while removing the maze from the shadow pass changes nothing.
  The maze geometry is nearly free; ~19,900 imported instances are the entire cost.
- **Horizon + frustum culling at pack time** — Scene 2 draws 8,654 of 19,944 instead of all of them.
  **Release: 21.1 → 11.5 ms (47 → 87 fps) in orbit, and first person reaches the 100 fps vsync
  floor.** The test is deliberately
  loose (a 2-unit frustum margin, a band past the horizon) because a culled instance loses its
  SHADOW too — the shadow pass draws from the same buffer. Interiors are exempt from the horizon
  test: you stand inside an inverted world, so every prop in the room reads as over the horizon and
  the room empties.
- **A cull test can cost more than it saves.** The first version called a method that did
  `ablate.contains("cull")` — a string hash per instance, 20,000 times a frame. It spent 10 ms of
  CPU to save 3 ms of GPU. Hoisting the planes and the flag into locals was the whole difference.
- **THE HORIZON TEST WAS MEASURED ONLY IN ORBIT, AND ONLY WORKED THERE (fixed 2026-08-01).** It
  compared a prop's outward direction against the direction to the eye — fine from 26 units away,
  meaningless from 0.09 above the surface, where a prop a few tiles to one side has p̂ pointing
  sideways and the eye lying the other way (dot ≈ −0.7). It emptied Scene 2 on foot: Eddie's POV
  screenshot showed bare ground with a couple of bushes on the skyline. The bench booted in orbit,
  so nothing caught it. Now: the real condition (`dot(p̂, ê) ≥ R/E`), and applied ONLY when the
  camera is properly outside the world (`|eye| > faceDistance × 1.35`); on foot the frustum test
  does the work. **`MAZEN_BENCH_FP=1` benches in first person**, and the bench reports
  "KILLED WHILE PLAINLY IN VIEW" — anything culled within 6 units and well inside the view cone.
  It reads 0 in both cameras now and would have been enormous before. **A camera-dependent
  optimisation has to be measured from every camera.**
- **The same work found a silent bug.** Scene 2 wanted 19,944 asset instances against a 16,384
  buffer, so ~3,600 props were dropped every frame — and which ones depended on dictionary
  iteration order, so not the same ones twice. A missing piece of a stone wall reads as authored.
  Buffer raised to 32,768; overflow now logs instead of truncating quietly.
- **`MAZEN_BENCH=<world>`** boots straight into a world and logs where the frame goes (update /
  build / encode / wait-on-gpu, the build split, draws, instances, culled, dropped), then exits.
  **`MAZEN_BENCH_ABLATE=shadow,assets,maze,translucent,cull,assetcache,shadowassets,shadowmaze`**
  omits work so its cost can be read off the difference. Built because "34 fps" sat in this document
  for weeks as a number nobody could reproduce — the absence of a finding, not a finding.
- **Watch for**: shadows popping at the screen edge (the cull margin), and Scene 2's remaining
  ~11 ms of GPU, which is still ~19,900 imported instances drawn twice. LOD or a shadow-caster
  subset is the next lever.
- The world list has moved on from the spreadsheet: the six scene scripts in `Scenes/` are the build
  target now, so `Prototype Worlds.ods` is in `Archive/` rather than tracking a plan nothing follows.
  (`metal_plate_02_1k/` and `To_be_evaluated/` were removed by Eddie, 2026-07-30.)

## Next

The prologue chain is complete, so there is no longer one blocking scene. In order:

1. **Scene 6 — "The World Remembered"**, the only scene never started, and the one that finishes
   the prologue. It is also the payoff for something already built: Phase 0 records
   `lastArrivalOrigin` on every world specifically for Scene 6, and nothing has ever read it.
2. **Scene 5's 5J**, the world-becoming-a-diagram — the one piece of that scene still unbuilt.
3. **More GPU on Scene 2 if wanted**: 11.4 ms in Release after culling, still ~19,900 imported
   instances drawn in two passes. LOD, or a reduced shadow-caster set, is the next lever.

Small and unblocking, good filler while something compiles: Scene 1's wall-absorbs-sound cue (1C)
and reflecting vessel (1E), Scene 2's post-rotation silence beat (2H), Scene 3's authored dead ends
(3H) and nebula parallax (3L), Scene 4's second vessel marking and 4B shape-as-meaning.

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
