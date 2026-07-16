# STATE OF PLAY — read me first

*A one-page handoff so a fresh session (or a future me) starts with the full picture. Last updated 2026-07-15. If you read nothing else, read this, then the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md) and the [Master Roadmap](Master%20Roadmap.md).*

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
4. **What base do the Builders count in?** Decimal is an anatomical accident (two hands, five fingers); post-biological beings have no fingers, so their base is a *fingerprint of the shape they think in*. Open — Eddie thinking. Constraint already fixed by the design: **base > 4**; and it's deferrable (at 1–4 every base looks like tallies). Claude's pitch: **16 = a tesseract's corners**, because the player's reasonable guess (8 = a cube's corners) is wrong by exactly one dimension and *that error is the revelation*. See [Builder Glyphs](Builder%20Glyphs%20—%204D%20Shadows.md#numbers--the-builders-dont-have-hands-eddie-2026-07-15--open).
5. **The top of the waldo ladder:** magic → plinth → **portable waldo (a "Pipboy") _or_ no device at all**? Constraint: the enhancement must be **fluency, not capacity** — enhance the player toward Builder-scale and you destroy the finitude that makes them the only one who can find pattern in noise ("the player's limitation is the searchlight").
6. **Vase/plinth taxonomy:** the control now looks like the message (a cylinder on a plinth vs. standing alone). Bug (can't tell a word from a handle) or in-theme (*you can't tell a Builder's word from a Builder's hand*)? Decide on purpose.

## Milestone road to a vertical slice (rough)

M14 shape-as-meaning (superellipsoid) → M15 inverted-cube interiors → **M16 the lock→open→enter chain** (the single most important loop) → M18 densified-grid movement & solidity → M17 memory first pass → M19 natural & moon worlds → M20 the Journey Walkthrough (vertical slice) → M21 cozy/feel polish. Details + sequencing in the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md).

## Immediate next actions on resume

- **THE CORE LOOP IS PLAYABLE (2026-07-11):** notice → twist refused (strain + red flare) → find the grey dial → align (F) → the temple sheds its gold → twist swings it open → the door lights → step into the inverted 5³ temple interior. Eddie's verdict after the first full run: **"That was fun."** All of M15.0–2 and M16.1–4 were built AND verified in one session (world registry; inverted interiors; door-semantics portals; the bonded gold temple rooted through the hollow world's core; dials; sealed doors).
- **Next:** M16.5 (the first carved glyph — Builder-Glyphs style, cosmetic seed), the M15.3 twist-percept experiment (camera decoupling while riding), polish (clue slab, player-carried light, feel tuning) — then M17 (memory) / M18 (the slice worlds).
- ~~Greenlight the [M15/M16 Work Plan](M15-M16%20Work%20Plan.md)~~ — **greenlit and mostly executed**; statuses live in that doc.
- *(Original pre-greenlight note follows for context:)* **the [M15/M16 Work Plan](M15-M16%20Work%20Plan.md)** — drafted 2026-07-10 evening for Eddie's review. Five decision points (D1 sequence, D2 interior lighting, D3 first-interior size, D4 first bonded structure, D5 registry key format), each with a recommendation. First build step on approval: **M15 Phase 0, the World Registry** (route-keyed worlds per the [World Graph](World%20Graph%20—%20Relational%20Worlds.md)).
- **THE GLYPH LANGUAGE GOT REAL (2026-07-15).** Eddie's caustic expansion landed a working model: the **frame cube is the cartouche**, the **vase is a sentence made solid** (its cross-sections ARE the words, so reading = a light plane sweeping it), and the **plinth is a WALDO for the world** — mechanism, not signage. The first Builder text is glossed (*a star, 2 planets, 3 ringed planets, swirled together into a solar system, where humanity lives* — a creation story sitting on a vase in world 1). Full capture: [Builder Glyphs — 4D Shadows](Builder%20Glyphs%20—%204D%20Shadows.md).
- **Built + pushed, NOT yet reviewed by Eddie:** the plinth replaces M16.5's plaque beside the M16 lock — four dials carry ordinals 1–4 (teaching-only; puzzle unchanged), the door plinth goes **blank → swirl → portal** with no UI text. Symbols are *generated* (blobs splatted at target points = the forge's transport minus the inverse solve), so blob radius already IS the comprehension-gradient dial. **Eddie's next look: how it LOOKS — sizing, the blue, blob radius, whether the portal glyph reads at plinth scale.**
- **Designed, not built:** the **alignment cylinder** — the plinth grows taller, two halves each carrying half a **square** (= *world*); align them and the world twists (grind + shake + sky lurch). With the swirl on the cap that reads **"TURN THE WORLD"** — a two-word imperative you complete by obeying it.
- ⚠️ **Naming collision to resolve:** the plinth work was labelled **M21** in code comments and commits, but this doc's roadmap already uses **M21 = cozy/feel polish**. It extends M16.5 (the lock's glyph), so **M16.6** is probably the right label. Eddie's call; rename before it sets.
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
- **Design (a very productive week):** [World Graph](World%20Graph%20—%20Relational%20Worlds.md) — route-keyed world identity, the-sky-can-lie; [Builder Glyphs — 4D Shadows](Builder%20Glyphs%20—%204D%20Shadows.md) — the glyph-source question ANSWERED (slice=word / sweep=sentence / rotation=verb; the twist is the language's 3D step-down), plus the canon frame (both Builder fates true, stewards unaware of the lost) and the reunion-endgame seed; [NPC Classes](NPC%20Classes.md) (Remnants = 4D intersections; co-worker's NPC/AI docs still pending, ~1.5 wks); [Builders v3 background doc](The_Builders_of_Garden_of_Worlds_-_Transcendent_Civilization_v3.docx) committed.
- **Key mechanism notes:** all placement routes through `CubeModel.restMatrix` / `inflatedPlacement` (this is what makes M15's inverted basis a ~one-function change). `InstanceData` carries per-instance `spinMatrix`/`roundness`/`invHalfExtent`. Debug keys: `M` matte, `-`/`=` roundness (all worlds), `H` HUD, `J` spin toggle, `K` freeze time in place, `N` size cycle 3–9 (engine caps at 25).
- Build note: run `xcodebuild`/`git` with the sandbox disabled. **git ↔ external volume:** if git returns `EPERM` on `.git` after a Claude update, re-grant the live "claude" entry **Removable Volumes / Full Disk Access** (System Settings → Privacy) and relaunch — TCC keys grants to the binary's cdhash, which changes on update.
- `main` == `origin/main`, everything committed and pushed. Repo is **private**.
