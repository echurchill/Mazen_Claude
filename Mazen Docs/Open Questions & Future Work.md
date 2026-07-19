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
