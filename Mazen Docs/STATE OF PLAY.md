# STATE OF PLAY — read me first

*A one-page handoff so a fresh session (or a future me) starts with the full picture. Last updated 2026-08-27. If you read nothing else, read this, then the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md) and the [Master Roadmap](Master%20Roadmap.md). Unscheduled ideas / open items live in [Open Questions & Future Work](Open%20Questions%20%26%20Future%20Work.md).*

## The world-model plinth — PROTOTYPE, first eyes-on (2026-08-27)

A plinth on Scene 5 that is only a plinth until you use it, then unfolds **the world you are standing
in** at ~1.4 m across above the pedestal, and folds away when you walk more than three tiles off.
No new machinery: it is the sky counterpart's build path with a different offset matrix. Awake it
costs a second `SceneBuilder.build` — scene 5 goes **2.22 ms → 4.56 ms** (Debug) — which is exactly
the doubling **R2.6** (per-world uniforms) exists to delete. `MAZEN_MODEL=1` wakes it at boot so a
headless validated run exercises the draw path.

Eddie's first look found two things, both now fixed:

- **The miniature appeared across the world from its plinth after a twist.** The plinth's
  `(face, row, col)` was cached at stamp time, and a twist moves facelets between grid slots — the
  coordinates named a tile the plinth had been rotated out of. Now stored as a **facelet ID** and
  resolved live each tick. `CubeModel.locate` already carried the rule in a comment
  (*"live rather than remembered… has to ask again rather than cache"*); the fix is what obeying it
  looks like. Guarded by `testTheWorldModelFollowsItsPlinthThroughATwist`, mutation-tested.
- **The world had its back turned.** The model inherited the world's idle spin and nothing else, so
  it presented whichever face that left outward — `+Y` at 0.89 toward the eye while Scene 5's channel
  cross lay on `+Z` at **0.04**, dead edge-on. It now **turns to present the face the player is
  standing on** (`WorldModelPlinth.presenting`, tested and mutation-tested). Eddie likes it; whether
  it should instead hold a fixed orientation you can walk around is still open.

- **The channels were drawn before the ground they lie in.** Three theories died first — too thin
  (wrong: reverted), facing away (a real bug, but not this one), not emitted (wrong: both builds
  emit all 22 tiles, with byte-identical draw calls). `channelFloor` carries a 0.004 lift in local z
  so the groove sits proud of the floor, and it was packed BEFORE the floor. At world scale that
  lift is ~7.6 cm and the depth test settles it cleanly; on the miniature at ~1/164 it becomes
  **0.024 mm**, the two surfaces quantise into each other, and the ground — drawn second — won. The
  group is now packed AFTER the field floor, which is the natural order and is scale-robust.

  **The lesson is about method, not depth buffers.** Three wrong answers came from reasoning about
  the code; the right one came from photographing it. So the bench can now photograph itself:
  `MAZEN_SHOT=name` writes `PortalViews/name.png` at frame `MAZEN_SHOT_FRAME`, `MAZEN_MODEL=front`
  parks the miniature in front of the camera (a headless run has no player to walk it to the
  plinth), and `MAZEN_MODEL_SIZE` scales it. Painting material 33 solid red and photographing it
  took one build to settle what three rounds of argument could not.

**The presented face now wears a seam** (material 38): a warm amber line along the outer edge of the
face the model is showing. On a rounded world the six faces melt into one sphere, which is the point
of the inflation and exactly wrong for a control — you cannot choose a face you cannot find. Border
tiles only, drawn from the same four-bit mask the channels use, read as edges rather than as spokes.
Warm on purpose: the current is blue-white, and a selection sharing its colour would read as part of
the puzzle rather than as a control over it. First pass came out dashed and was widened to a
continuous line.

Next on it (Eddie, 2026-08-27): **how you interact with it** — "if we can make this
change and figure out how to interact with it then I think this is a wonderful visualization and
control mechanism". Also noted: pressing Q/E while the model is up makes it fly away and return —
the twist moves the plinth's facelet and the model chases it. Cool, not useful.

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
- **Tooling** — debug HUD (`H`, names the prop under you), twist pacing (`G`/`[`/`]`), the **`` ` `` portal hub** (single key → a labeled plaza of TARDIS portals to every world; replaced the per-world `O/I/B/V/Y/1-4` jumps), `U` (make the door lock ready, bypassing the switches — for testing the turn), headless tests (`Tests/run-tests.sh`, **249,920 checks** (the dressed-wall test was rewritten smaller in the wall fix) incl. portal gating + topology-cache invariants). All debug toggles default OFF.

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

### Cyberpunk kit adopted for Scene 6's underside (2026-08-01)
Quaternius' Cyberpunk Game Kit (CC0), same OBJ + flat-`Kd` shape as the other three packs, so it
needed no pipeline work. **Structural half only** — 35 models: platforms, supports, rails, pipes,
cables, AC units, antennae, lights. Left behind: the character, the enemies and turrets, the pickups
(no combat, no inventory), and deliberately the neon signage and screens — meaning in this game is
read off the world's own geometry and never written down, so legible signs and displays argue with
the premise. The full pack sits in `Mazen_Models/Cyberpunk Pack/` (its `OBJ/` + `Textures/` now tracked, the
rest ignored — see the asset-slice note below);
`OBJ/` is the curated subset the game loads. **No emissive materials in the pack** — every `Ke` is
zero, so any neon must come from our own shaders.

It dresses `-X`, Scene 6's arrival region, which was bare: density rises toward the edge the portal
assembly stands on, so the machinery reads as belonging to that structure and thins into bare plate
away from it. Non-solid, so it changes nothing about where the player can walk — asserted, along
with the region staying unreachable from Scene 2's own spawn, and the dressing being deterministic.

**`gallery-cyberpunk` (destination 16)** joins the hub, whose grid went to 3 rows × 6 columns; the
plaza already reached that far, so nothing had to move.

### THE WORLD USED TO BRICK ITSELF (2026-08-03) — the routing model changed
Eddie, playing Scene 4 with the twist in hand: *"I have traveled around and rotated numerous slices,
I find myself stuck. Every time the tile the portal is on seems to always have 4 walls."*

Measured, and it was not him:

| twists | 0 | 5 | 10 | 20 | 30 | 40 |
|---|---|---|---|---|---|---|
| open edges | 322 | 244 | 172 | 104 | 58 | **32** |

Every twist ran `reconcileSharedEdges(preferOpen: false)` over the **whole cube**, closing any
opening whose partner was shut. Openings only ever decreased and turning a slab back never restored
them, so a few minutes of play walled the portal in on all four sides. Worse, this was **my July fix
for the invisible walls**: it made the symptom go away by demolishing whatever disagreed.

**An edge belongs to the SEAM, not to either tile.** Walls now stay exactly as authored; passage
asks BOTH sides (`CubeModel.passableOpenings`), and a wall is DRAWN wherever either side refuses —
one answer feeding movement and rendering, which is all an "invisible wall" has ever been. A turn
can sever a route without deleting anything, and turning back restores it. This is the rule Scene 5's
channels already used ("both ends must have a groove"); the maze now uses it too.

`testTwistsLeaveTheTopologyConsistent` asserted the OLD rule (no disagreeing halves) and rightly
failed. It now asserts what actually matters: **openings are conserved** across twists, passage is
never one-way, and four quarter-turns of a slab return the world bit-for-bit to where it started.
Disagreement is a STATE, not damage — it lasts exactly as long as two tiles are neighbours.

Cost of asking both sides every frame, Release: Scene 2 **77 fps**, Scene 4 at the **100 fps** vsync
floor.

### Scene 4 could be stranded, and the fix is a picture (2026-08-03)
Eddie released all three anchors, then pressed the vessel, and the scene was over: no twist, Q/E
dead, nothing on screen saying why. The vessel only performed `if !bondedGroups.isEmpty` — a stand-in
for "this is not Scene 1" — so with the lock already gone the teacher fell silent and the verb was
never handed over. **A property of the vessel was being inferred from the state of something else.**

Two changes, and the second is Eddie's and is the better one:

1. `CubeModel.vesselTeachesTheTwist`, set by Scene 4's stamp. The world says what its vessel is for,
   so the vessel behaves the same whatever has already happened to the lock.
2. **The anchors wait for the vessel, and say so.** Until it has been used an anchor is not a control
   — it wears the **vessel's own mark** (a new `.vessel` caustic glyph: the lathe silhouette in
   blobs, same dot language as the ordinals and the portal) and refuses, flashing the mark while a
   tone answers from the vessel's direction. The lock shows you its key. It is a hint in the only
   language the prologue allows, and it makes the stranding order unenterable.

Worth keeping: mutation testing showed change 1 is **unreachable through play** once change 2 is in
— no player-level test can distinguish it, because the bonds can never be empty when the vessel is
first pressed. It is asserted directly instead (dissolve the bonds through the model, then press the
vessel). A guarantee worth having is a guarantee worth testing on its own terms, or the next person
deletes it as dead code.

### Touch could not press anything (2026-08-03)
`interact()` was called from exactly one place — macOS's `F`. iOS had tap/double-tap/swipe/pinch and
no route to it at all, so every control in the prologue (Scene 2's switches, Scene 4's anchors,
Scene 3's plinths, every portal used by `F` rather than walked through) was **keyboard-only**. The
game has been quietly unplayable on a phone for as long as those controls have existed, and no test
could see it because the model layer does not know which platform is calling it.

Tap now means `F` **where the player is standing on something usable**, and "walk forward" everywhere
else — disambiguated by position rather than by a second gesture, so a player can still walk over
their own controls. `GameState.interactableKinds` is shared by `interact()` and `hasInteractableHere`
so the touch path cannot drift from the keyboard one.

Scene 5 gained **six face rotators** in the same pass (Eddie: "Q/E won't work well on touch
screens"), each turning the slab it stands on. The test that matters is not that they exist but that
they are ENOUGH — the scene is solvable by walking and pressing alone.

### Rigid imported props sit badly on ROUNDED worlds (2026-08-01)
Tried scattering the Cyberpunk platform decks over Scene 5 and reverted it the same day (Eddie: "they
look odd due to the roundness"). Worth writing down as a constraint rather than a one-off:

An imported asset is **rigid**. `inflatedPlacement` seats its anchor on the curved surface and tilts
it to the local normal, but the mesh itself stays flat — so a BROAD flat model on a world with
`roundness = 1` meets a surface curving away beneath it, and either floats at its edges or cuts into
the ground. The bigger the footprint, the worse: a 4×4 deck spans enough of a 7³ world to show it
plainly.

So on rounded worlds prefer props that are **tall and narrow** (supports, antennae, pipes) or small
enough that the curvature under them is negligible — which is why the same kit reads correctly on
Scene 6's underside: `-X` belongs to Scene 2, whose `roundness` is **0**. Flat and wide is a
cube-world material.

The real fix, if broad decks are ever wanted on a curved world, is to give imported meshes the same
per-vertex inflation the maze geometry already gets (M14b), rather than to keep hunting for models
that happen not to show it.

### The puzzle-integrity suite (2026-08-01)
Every existing test passed while Scene 2 was unsolvable, because they all checked PARTS: the
switches were stamped, the lock was bonded, the turn moved the right slab. What broke was the JOIN.

So there is now a suite that plays each scene with only what a player has — stand on a tile, press
F, turn a slab — and asserts the scene can be finished:

| test | what it plays |
|---|---|
| `testSceneOneCanBeWalkedToItsArch` | the arch exists, leads to Scene 2, and is reachable on foot from the spawn |
| `testSceneTwoCanActuallyBeSolved` | four switches both ways → lock dissolves → cylinder rises → world turns → chamber goes live |
| `testSceneThreeCanBeSolvedByPressingItsPlinths` | an obelisk REFUSES being touched; six plinths wake six obelisks; the exit appears only at the sixth, and is reachable |
| `testSceneFourReleasesItsAnchorsAndThenTurns` | three anchors released by F, each permanent, the slab refused until the last |
| `testSceneFiveCanBeSolvedByTurningItBack` | the scramble undone → circuit live → exit exists, stands on the current, and is reachable |
| `testNoSceneHandsOutItsExitEarly` | no scene's way out exists before its puzzle is done (Scene 2's is present but SEALED, which is its image) |

**They were mutation-tested, because a suite written after the fact that passes first try has proved
nothing.** Re-introducing the door-identity bug fails 4 checks by name; making anchors stop releasing
their bond, and a Scene 3 plinth wake every obelisk instead of its own, fails 27 more. Each mutation
was reverted and the suite verified green again.

### Scene 2's lock had been dead (found 2026-08-01)
`templeDoorStillSealed()` — the guard that makes the four corner switches inert once the door is
open — identified the door as "the portal whose destination is **1**", i.e. `temple-interior`: the
world Scene 2's chamber pointed at *before Scene 3 existed*. Repointing the chamber to Scene 3
(destination 13) left that lookup finding nothing, falling through to `false`, and silently
rejecting **every** switch press. No crash, no log, nothing on screen. Scene 2 has been unsolvable
since, through every session that "verified" it by looking at it.

A door identified by which world lies behind it breaks the day that world changes; a door identified
by BEING SEALED does not. `testSceneTwoCanActuallyBeSolved` now walks the whole chain — every switch
in both directions, the lock dissolving, the cylinder rising, the world turning, the chamber going
live — because what broke was not a step but the join between two of them.

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
- **The orbit camera never reported where it was (fixed 2026-08-01).** `cameraPosition` returned a
  constant `(0, 0, orbitDistance)` in orbit — the camera as it sits *before* you drag it — while the
  view matrix rotated properly. Harmless for as long as it only fed the audio listener and Scene 1's
  "is the player looking at it" vessel test. Then prop culling asked it where the eye was and
  believed the answer, so it kept whatever faced `+Z` however the world was turned: a band of
  scenery tracking the world's spin rather than the camera. **A stale answer is worse than none,
  because it looks like a plausible one.**
- **And the cull test itself was wrong twice, in opposite directions.** A backface test asks whether
  a surface is turned away from *where the eye is* — `dot(p̂, normalize(eye − p))`. The intermediate
  version compared against the VIEW AXIS instead (`dot(p̂, ê)`), which culls the far half of every
  oblique face while that face is plainly on screen; on a cube a whole side face reads as 90° from
  the axis and vanished. Restored, with the outside-only gate that the first fix got right.
- **The in-view diagnostic was itself vacuous** — it required the prop to be within 6 units, which
  never fires from orbit 26 units out, so it read 0 through the entire time orbit was visibly broken.
  It now means "near the middle of the screen, on a surface comfortably facing the eye", and it is
  **proved sensitive**: `MAZEN_CULL_T=0.4` (a deliberately wrong cull) reports 1,137 killed while in
  view; the shipping threshold reports 0, at every yaw, in both cameras. A check that cannot fail is
  not a check.
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

The prologue chain is complete and every scene is playable end to end. In order:

1. **Scene 6 — "The World Remembered."** Arrival, persistence and the `-X` region are built and
   tested; **it is still a dead end**, because 6D is what opens that region to the rest of the world.
   Then 6E/6F (the second entrance into Scene 3's interior), 6G (the orb reading which face you came
   in by), 6H (the metal vessel — cheapest item in the scene), and 6I/6J (the route-keyed portal,
   whose audio is already four registered tones waiting to be played together).
2. **Scene 5's remaining beats**: the source is a vessel where 5C asks for a basin in nested rings;
   the receivers are obelisks where 5D asks for crescents or bowls; 5C's diagnostic pulse is unbuilt
   (cheap now the pulse is a real simulated front); and 5J, the world-becoming-a-diagram.
3. **Touch beyond `interact`.** Tap now presses things, but Q/E map to a two-finger swipe, which is
   undiscoverable in a game with no UI. Scene 5 answered this with rotators you walk up to; Scene 4
   has the same problem and no answer, and it is the scene that TEACHES the verb.
4. **More GPU on Scene 2 if wanted**: ~13 ms in Release, still ~19,900 imported instances drawn in
   two passes. LOD, or a reduced shadow-caster set, is the next lever.

Small and unblocking, good filler while something compiles: Scene 1's wall-absorbs-sound cue (1C)
and reflecting vessel (1E), Scene 2's post-rotation silence beat (2H), Scene 3's authored dead ends
(3H) and nebula parallax (3L), Scene 4's second vessel marking and 4B shape-as-meaning.

### Portals became what they are, not what a door looks like (2026-08-06)
Eddie: *"Given these are 4d projections that the Builders are creating for us, why would there be
stonework? Even the concept of down/up (scene 2 to 3 to 4) doesn't even make sense — up/down would
likely be foreign to the Builders."* Right on both counts, and it retired a lot of code.

**Every portal in the game is now one object:** a vertical circular opening ~3.4 m across, sunk 10%
of its diameter into the floor so it reads as planted, showing the captured view of where it leads
with parallax, ringed by an animated wormhole swirl over the outer 10%. Nothing frames it. Gone: the
Ruins arch, the Dungeons columns, the two elevator curtains, the starfield-in-an-arch, the blue and
pink veils, and the glowing ground ring — the disc grounds itself.

A circle also deleted a bug class. The rectangle needed a cover-fit to map a square capture into a
non-square opening, and I got the axis backwards; a circle's bounding box is square, so the question
no longer exists.

**The police box stays, and got MORE detail** — corner posts, stepped roof, sign band, sixteen
windows. Now that every other door is frameless, the hub's boxes read as a deliberate joke rather
than as one door style among many. Every distinction is carried by `aoFactor`, the only shading
channel a single-colour prop has.

**APPROVED by Eddie (2026-08-06)**: disc size, rim thickness, sink depth and Scene 3's targeting
beam all read right in place. The numbers that survived judgement: radius 0.09 (~3.4 m), swirl over
the outer 10%, sunk 0.2 × radius, beam aimed at `PortalDisc.topAboveFloor`.

The five wrong turns getting there are worth keeping, because four were the same misunderstanding:
`roundness == 0` does not mean "leave this prop alone", it means "use `modelMatrix` verbatim and
apply `spinMatrix` on top". A prop matrix is the FLAT-CUBE rest placement, so that put the portal in
orbit; inflating instead squashed the circle into an oval; baking spin AND passing it turned the
world twice. The right answer was `inflatedPlacement` + identity spin — the path every rigid
imported asset already used. The contract was written in a comment directly above the code both
times I got it wrong.

### The asset packs join the repo — the slice that loads, not the ballast (2026-08-05)
Six packs, 515 MB, lived outside git pending an LFS decision, which meant a fresh clone compiled,
passed all 249,949 checks, and then came up with no galleries, an unplanted garden and a bare
underside. The fix needed no LFS and no loader change: `AssetRegistry` reads exactly `OBJ/` and the
pack's texture folder, and everything else in those directories — .blend sources, FBX/glTF
duplicates, engine-project .zips, preview renders — is what the weight actually was. Tracking only
what is read costs **91 MB for 1,031 files**, and every gallery stays whole.

Two things the sizing exercise turned up. The MegaKit's `Blends/textures` holds 26 MB of
`*_Normal.png` that no code path reads — ignored, to be un-ignored the day a normal-map path
exists. And `TextureLoader`'s own `.rgba-cache/` decode dirs (165 MB under the MegaKit alone, ~2×
each PNG, regenerated on demand) were being staged as if they were source: they nearly tripled the
slice before the ignore rule landed. A generated cache sitting next to its input looks exactly like
an asset when you are matching on directory names.

The Blocks pack was the one held back — it shipped with no license file, and committing an asset
is redistributing it. Eddie identified it as Quaternius' Cube World Kit, CC0 like every other pack
here; `Mazen_Models/Blocks Pack/PROVENANCE.md` records that, since the download carries nothing.

### The "hung benches" were App Nap all along (2026-08-05) — diagnosis corrected
Three wrong theories, each retracted here: it was not the locked display as such, not
window-occlusion throttling, not a code hang. **macOS App Nap suspends the entire process of an
occluded app** — draws, run-loop timers, everything — so a CLI-launched bench behind any window
went silent mid-run. Each wrong theory survived because suspension produces *silence, and silence
supports any theory*. Proven by elimination: a run-loop-timer heartbeat also went silent (killing
the throttle theory), and `ProcessInfo.beginActivity(.latencyCritical)` fixed it outright —
scene-2 now runs a full bench to "BENCH done" while occluded.

Benches now: hold an App Nap exemption for the run, order their window front politely (no focus
steal), and a 5-second heartbeat names the condition if frames ever stall again. Refactor #5's
deferred scene-2 gate ran clean under the fix.

### Refactor pass 3→2→4→1 (2026-08-05) — the approved four, done
- **#3 Animation is not topology.** The surveyor is a per-frame DYNAMIC asset instance outside the
  bucket cache (never culled, always a caster); the six animation-only `markTopologyChanged` sites
  are gone, with the rule stated at the call sites.
- **#2 `channelDepths` memoized** on `topologyVersion` — one reach walk per world state instead of
  seven call sites re-walking, several per frame. (Correction to the previous commit's message:
  the measured update win was 1.12 → 0.94 ms, not the 0.65 claimed there.)
- **#4 GameState split**: core 2,338 → 1,900 lines; `GameStateSceneFive.swift` (circuit, pulse,
  bloom, surveyor — 25 regions moved verbatim) and `GameStateSceneSix.swift` (route-keyed arrival,
  metal vessel). `run-tests.sh` updated in the same commit, per the B2 trap.
- **#1 `interact()` is an explicit dispatch**: ten named handlers, one array that IS the precedence,
  mirrored as `interactionOrder` data and PINNED by a test — a reorder now fails by name instead of
  silently swallowing someone's press (how the metal-vessel/plinth bug happened). The whole
  puzzle-integrity suite passed through the new dispatch unchanged before the pin went in.

Deferred from the analysis, still open: the full-cube prop-sweep consolidation (#5), the test-file
split (#6), and the small position-helper cleanups (#7).

### The surveyor (2026-08-04, overnight) — Eddie's mobile-builder, BUILT
A Builder machine walks Scene 5's LIVE channel runs and grows stepped fractal filigree onto the
bare tiles beside them — the reference image's Manhattan dendrites, generated as a 6-slice RG
texture (r = line, g = distance-from-entry, so branches grow OUTWARD tip-first) that was prototyped
offline and looked at before the Swift port. Its behaviour is diegetic feedback: it can only extend
from flowing current, works busily along what the player repaired, and STANDS IDLE at the frontier
of what they have not — silent when stalled, humming when working.

The laws, all tested and the liveness one mutation-checked: filigree never conducts (channel masks
bit-identical after an hour of growth) and never blocks; it grows only beside channels live at
grow-time, entry edges always face a real channel tile; it rides twists (entry rotates with the
tile; an orphaned branch goes dark — "thin dark cracks"); the scene still solves under it; a
severed trunk freezes growth and a repaired one resumes it. 5J's bloom lifts all filigree with the
world. The machine itself: a squat plated box with a sensor mast, sliding smoothly between tiles,
inert to F — Builders' machinery does not notice you.

**Frame-verification pending:** the display session locked when Eddie logged off, and a CLI-launched
app gets no drawables from a locked session — diagnosed by control (a commit that drew at 100 fps
in the morning hangs identically at night). Suite, mutations and both platform builds are green;
the bench and validation boot run when the machine wakes. NOTHING here invalidates the wall fix —
it was gated while the display was live.

### Scene 6 critical path (2026-08-03)
The dead end is open. Built and play-tested end to end:
- **6D** — three latches beneath the assembly on `-X`, engaged in physical order; out-of-order
  presses rebuff and the ANSWERING tone comes from the latch that is next (Scene 3's
  refusal-teaches pattern). The third opens the **hatch**: the second descent, a portal into
  Scene 3's interior.
- **The route problem, solved where it belongs**: both descents depart a world *named* scene-2, so
  `WorldCatalog.routeName` counts a departure from a Scene-2-entered-from-Scene-5 as the
  **scene-6 route** — that one rule is what lets the same door land differently.
- **6E/6F** — the second descent arrives on `-Z`, a face the first visit never used, into a chamber
  still solved (persistence already guaranteed).
- **6G** — the chamber answers the route: arrival acknowledgement brightens the nearest beam,
  fading over ~6 s.
- **6H** — the **metal vessel** stands near the new entrance (`state 6`), its rings stepping a
  quarter-turn one beat behind the chamber's clock. First placement landed on a plinth tile and
  swallowed its press — six plinths, five obelisks — caught by the suite the same hour; it now
  seats on verified-empty ground.
- **6I/6J** — the **route-keyed portal**: opens only when three facts hold at once — Scene 2 still
  turned (honest geometry, queried across worlds at the swap and stamped as a route fact),
  Scene 3 solved, and arrival via the underside. Distinct chooser (never the nebula frame's tile),
  aperture-sized field, and the four remembered tones sound together at creation. It points at the
  hub until an Act I destination exists.

Deferred: 6J's layered portal image, 6K's sweeping view, the 6A afterimage, and the route-keyed
sky decision (Eddie's call). Mutations caught by name: order-free latches, a two-fact portal.

### Scene 5 polish pass (2026-08-03)
The five items from the analysis doc, all played by tests and mutation-checked:
- **5C diagnostic pulse** — F (or tap) at the basin fires a brighter front immediately.
- **5D three receiver states** — dark / filling 0.55 / locked 1.0; a fed-but-broken bowl holds
  light only while the pulse feeds it, and only a LOCKED one hums. "Temporary success is
  deliberately different from lasting success" is now visible and audible.
- **The scripted fixtures** — the source is a basin in three nested mineral rings, the receivers
  are raised bowls (new lathes, new material 35: translucent mineral that fills bottom-up via a
  uv fill coordinate). The source is no longer a vessel, which was muddying 5F's "vessels observe
  the circuit" argument.
- **5I seamless** — a live circuit never withdraws or sounds the incomplete tone; the front wraps
  source→receivers→source as a rhythm.
- **5J the bloom** — on lock: every circuit channel floods, the tile grid surfaces across the pale
  stone, fixtures breathe in rhythm, the three receiver tones align; then it settles to a resting
  glow ~0.3. The world stays brighter than it began.

### Render plan executed: Tier 1 + 2 (2026-08-03)
B4 (WorldCatalog is the one name), B1 (Renderer split into frame loop / world stack / asset
instancer / bench), B2 (the six scene stamps out of CubeModel into `Stamps/`, with `run-tests.sh`
updated in the same commit — the trap the plan named). A1 shadow-caster subset (casters-first
packing; the shadow pass draws the prefix) and A2 projected-size LOD with hysteresis are in:
**Scene 2 Release orbit 13.2 → 10.5 ms (76 → 95 fps)**, FP at the floor. A4 was measured out —
after A1 the shadow pass costs nothing (equal frame time with it ablated) — and A3 is held.
Thresholds calibrated from a measured size histogram after the guessed ones matched zero instances.
Eddie's eyes still owed: shadows gone under small scatter (~<3 m), and LOD popping while zooming.

### Eddie's verdicts (2026-08-03)
- **The routing change: ACCEPTED.** "The new wall logic looks pretty good… mark it as done." He will
  keep an eye out; the invariants (conservation, symmetry, reversibility) are in the suite.
- **Scene 5's rotators: accepted** — look and work as intended.
- **The vessel glyph: accepted, scaled down** to 0.90 so it sits inside the swirl's footprint
  (1.58 tall against the spiral's 1.64), at his request that the two read at the same size.
- **Scene 6's machinery: accepted, minus the greenery.** "I like Scene 6's machinery. I think we
  could lose the plants and natural stuff though." The underside now clears the world's own scatter
  off its face before laying machinery, and its walls are exempt from overgrowth — a bush on the
  back of a turning slab is the one thing that stops it reading as a machine.

### Still waiting on his eyes
- Whether the waiting anchor's borrowed switch-cap resin material looks wrong beside the brass an
  anchor wears once live.

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
