# Open Questions & Future Work

*A parking lot for ideas and open work items that aren't scheduled yet, so they don't get lost. Not a bug list — see [Known Issues](Known%20Issues.md) for those. Add freely; promote to a work plan when it's time.*

## M20 garden — design & fixes (Eddie, 2026-07-17)

- **Temple as a real puzzle (riff — not final).** The garden temple isn't a puzzle yet. Rough idea:
  **a puzzle plinth at the centre of each of the 6 cube faces**; interacting with each turns something
  on (charges something?); once **all 6 are lit, the gateway to the next world opens**. Just riffing —
  design later. (Would replace/extend the current switch-plinth lock as the world's core puzzle.)
- **Rethink the clue plinth** (next major session). Two concrete problems with the current one:
  (1) it's the wrong presentation (needs a rethink); (2) it's **static** — disengaging one of the
  other switches updates the door plinth but NOT the clue, so they disagree and confuse. Address when
  we redo it.
- **Temple indicator points still wrong / missing** (the four-points-on-the-structure beat) — deferred,
  needs Eddie's eye (see shot list step 3).

## Twist-safe walls — RESOLVED: the dynamic dressed-wall framework (2026-07-18)

**Constraint discovered the hard way:** the garden is a twistable Rubik's maze, and a maze wall must
stay correct *through a twist*. Only walls **re-derived from each tile's topology every frame** do —
static stamped props can't, because a door-twist is a whole-cube slice rotation that rotates tiles in
from *outside* the stamped region (⇒ invisible/misplaced walls when the hedge mesh is suppressed).

**Built the framework (`WallStyle.dressed`):** a world can now dress its maze walls with imported wall
MODELS (Ruins pieces + rocks/bushes) instead of hedges, and they survive twists — because the Renderer
re-emits them per closed edge from live topology every frame, exactly like the hedge mesh (never
stamped). Pieces: `MazeTile.wallType` (per-tile overgrowth grade, travels through twists),
`CubeModel.dressedWallProps` / `dressedClearTiles`, `SceneBuilder` suppresses the hedge mesh, and
`Renderer.updateAssetInstances` runs the wall props through the normal `placeProp` path. The garden now
uses this; **the static "stone-in-hedges" look (`stampGardenWalls`) is kept available** for reuse (Eddie
liked it). Reusable for future wall models — just add them to `wallFlora()`. **Confirmed by Eddie
(2026-07-18): looks good in the garden.**

## Performance — done + deferred (2026-07-19 optimization pass)

**Done (Fable):** instanced asset draws (1000s → tens, both passes); topology-versioned caches
(dressed-wall derivation, clear-tiles, prop-tile list, switch/cylinder locations — ~12k `faceletAt`/frame
→ cache hits, twist-safety proven by structural probe); one `restMatrix` per tile (was 2× in SceneBuilder,
per-prop in the asset pass); Set-flattened per-prop membership tests; reused fog dictionaries.

**Deferred candidates (medium confidence — need care or Eddie's eyes):**
- **Counterpart (sky) world**: a full second `SceneBuilder.build` every frame while visible. Fix = build
  its instances once, push the per-frame orbital offset as a uniform — a small shader-semantics change.
- **Scene dirty-gating**: the active world also rebuilds every frame; but idle spin dirties every frame
  unless spin too moves into a uniform. Bigger refactor, do together with the counterpart fix.
- **Shader octave cuts** (grass 14 / regolith 16 / fog 4-5 FBM, fog layer overdraw): real GPU wins but
  VISUAL changes — tune with Eddie looking.
- **Garden first-entry hitch**: built once ever (registry-cached), but that one build lands mid-fade;
  could pre-build at app load like the moon.

## Scene 2's rotator vs Scene 5's orb plinth — one family or two? (Eddie, 2026-08-27)

Eddie, having seen the orb plinth working: *"does world 2's rotator look too different? The image
(swirly) is there but the cylinder is really different looking. I wonder if we should rethink it?"*
Noted for pondering, not scheduled.

**The two objects do different jobs, and the difference may be correct.** Scene 2's rotator is a
one-off ceremony — solve the four corners, the control RISES out of its disc, you turn the world
once. Scene 5's is a tool pressed a dozen times while reading a route, so it stands ready and shows
you the world while you use it. `stampFaceRotators` already carries that reasoning: *"the ceremony
belongs to a one-off, not to something pressed a dozen times"*.

**But they share the swirl glyph, which claims kinship the bodies then deny.** A shared mark is a
promise that two things are the same kind of thing. If the cylinder reads as unrelated machinery
wearing a familiar sticker, the glyph is doing no work — and worse, it teaches that the mark means
nothing in particular.

**Leading candidate: make Scene 2's rotator the PRECURSOR of the orb plinth.** Same plinth body,
same glyph, and nothing floating above it yet. Then Scene 5's is visibly the same object grown up,
and the miniature world is the thing you EARN rather than a second unrelated control. That reads as
a progression — first twist as ceremony, mastery as a tool — and it costs one stamp change plus
whatever ceremony we keep for the rise.

Open either way: whether the rise-from-the-disc ceremony survives, and whether Scene 4 (which is
supposed to teach the twist) should get the same body a step earlier still.

## The orbit view must be WITHHELD in Scenes 1–3 (noted 2026-08-07, deferred on purpose)

Space gives a god camera everywhere, including inside an inverted interior where "orbit" is
meaningless. Two reasons it has to go, and they compound:

1. **It spoils the reveal.** The prologue's whole arc is the slow discovery that a world is a cube
   you can turn. One press of Space in Scene 1 gives that away in the first thirty seconds — the
   same reason the sun and moon stopped being cubes (2026-08-07).
2. **It defuses the scenes.** Scene 2 is "there is more world than you can see" and Scene 3 is "no
   privileged floor". Both are much weaker if the player can simply zoom out and look at the shape
   of the problem.

**The plan:** the orbit view becomes a PLACE — the orbital plinth (Eddie's term) — arriving around
Scene 4, when turning the world is the verb. Reaching it then pays off the attract screen the player
saw before they ever landed. Scenes 1–3 simply do not have it.

**Deliberately not done yet:** it stays available while we are prototyping, because being able to
look at any world from outside is worth more to us than the reveal is right now. Gate it when the
plinth exists. The toggle sites carry a comment pointing here.

## Rendering / assets

- **MegaKit custom shaders (Eddie, 2026-07-17).** The Stylized Nature MegaKit ships with *custom shaders* (in its `Engine Projects` / Unity+Unreal material graphs) that "might prove interesting." We currently use only the pack's diffuse atlases through our ModelIO path — the shaders aren't wired in and our pipeline can't consume Unity/Unreal material graphs directly. **Worth a look:** are any of the effects (e.g. wind sway on foliage, stylized rock/path shading) reproducible as a Metal material in our shader (`Shaders.metal`)? Could give the nature dressing motion/life beyond the flat/atlas look.

- **Textured vs. flat rock/bush mix in the wall-builder.** The wall overgrowth now mixes *textured* MegaKit rocks with *flat-shaded* Nature/Ruins rocks in the same wall. If that reads as inconsistent rather than "variety," bias the wall rocks toward one source (or texture the flat ones). Pending Eddie's eyes.

- **Overgrown-wall "Green" submesh.** Ruins overgrown walls have a solid `Green` submesh (mis-exported as grey `Kd` 0.64) that we leave flat-grey — binding the cutout leaf texture to it would punch holes in solid geometry. If it still reads too grey, options: a solid green tint (needs per-submesh colour override in the asset path), or a dedicated non-cutout green texture.

## Path stones (prototyped 2026-07-17 — pending direction)

- Rock-path stone models (MegaKit `RockPath_*`) are prototyped in the gallery (west of the catalog): **just paved path / stones on paved path / just stones**. Once Eddie picks a look, the next step is a **real path pass** — lay rock-path stones along the garden's paved path tiles to replace/augment the current path texture. `Pebble_*` models are also available for finer scatter.

## Model folder cleanup (done 2026-07-17)

`Mazen_Models` pruned to only what's loaded: **Dungeons Pack, Nature Pack, Ruins Pack, Stylized
Nature MegaKit** (eval packs), **Modular Temple** (flags/vase), **horse_statue_01_2k**,
**modular_house_collection** (the splitting house). Deleted (unused, gitignored): Quaternius pack,
Modular Village, modular_fort_01_2k, modular_terrain_collections, othertrees, pinetree,
para_CC0_tex-pack-hedges (its `hedge_*` textures are already bundled in the app), old_military_crate_2k,
stone_fire_pit_2k, WenrexaTrees (billboard sprites removed), tree_stump_01/02_2k. All re-downloadable if needed.

## Shearing planes — an accident worth keeping (2026-07-28)

While building the **cut faces** that give a turning slab its thickness (Scene 2), a mismatch produced
an effect Eddie wants to use deliberately later.

The cut faces are quads on a slice's *interior* plane — flat, because a cut through a cube's inside is
flat. But a world with `roundness > 0` inflates its **surface** tiles out onto a curved shell. The two
then disagree, and the interior planes detach from the slab and **shear through the world** as it
turns: large flat sheets slicing across the cube at angles that have nothing to do with its geometry.

Wrong for Scene 2 (fixed by taking that world to roundness 0, which its puzzle wanted anyway), but a
striking image in its own right — a world coming apart along planes that were never surfaces.

Candidate uses:
- a world being *unmade*, or one whose structure is failing
- a Builder-scale operation the player is not meant to understand yet
- an Act III higher-order world operation (the roadmap wants those to feel mythic)
- a route-variant world glimpsed mid-transition

To do it on purpose the effect needs to be **authored rather than emergent**: drive the plane count,
angles and drift explicitly, instead of relying on a roundness mismatch. The mismatch is not a stable
mechanism — it changes with roundness, size and slab index.

Related constraint, worth remembering: **cut faces only line up on a roundness-0 world.** A rounded
world with scripted twists needs the cut plane inflated to match the shell, which is unsolved. See
`SceneBuilder.build`'s cut-face block.
