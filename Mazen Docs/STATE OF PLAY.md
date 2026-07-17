# STATE OF PLAY — read me first

*A one-page handoff so a fresh session (or a future me) starts with the full picture. Last updated 2026-07-16. If you read nothing else, read this, then the [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md) and the [Master Roadmap](Master%20Roadmap.md). Unscheduled ideas / open items live in [Open Questions & Future Work](Open%20Questions%20%26%20Future%20Work.md).*

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
- **Tooling** — debug HUD (`H`, names the prop under you), twist pacing (`G`/`[`/`]`), world toggles (`O` interior, `I` temple, `B` natural, `V` garden, `Y` prop/glyph gallery), `U` (make the door lock ready, bypassing the switches — for testing the turn), headless tests (`Tests/run-tests.sh`, **218,002 checks**). All debug toggles default OFF.

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
