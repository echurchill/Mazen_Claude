# Open Questions & Future Work

*A parking lot for ideas and open work items that aren't scheduled yet, so they don't get lost. Not a bug list — see [Known Issues](Known%20Issues.md) for those. Add freely; promote to a work plan when it's time.*

## Rendering / assets

- **MegaKit custom shaders (Eddie, 2026-07-17).** The Stylized Nature MegaKit ships with *custom shaders* (in its `Engine Projects` / Unity+Unreal material graphs) that "might prove interesting." We currently use only the pack's diffuse atlases through our ModelIO path — the shaders aren't wired in and our pipeline can't consume Unity/Unreal material graphs directly. **Worth a look:** are any of the effects (e.g. wind sway on foliage, stylized rock/path shading) reproducible as a Metal material in our shader (`Shaders.metal`)? Could give the nature dressing motion/life beyond the flat/atlas look.

- **Textured vs. flat rock/bush mix in the wall-builder.** The wall overgrowth now mixes *textured* MegaKit rocks with *flat-shaded* Nature/Ruins rocks in the same wall. If that reads as inconsistent rather than "variety," bias the wall rocks toward one source (or texture the flat ones). Pending Eddie's eyes.

- **Overgrown-wall "Green" submesh.** Ruins overgrown walls have a solid `Green` submesh (mis-exported as grey `Kd` 0.64) that we leave flat-grey — binding the cutout leaf texture to it would punch holes in solid geometry. If it still reads too grey, options: a solid green tint (needs per-submesh colour override in the asset path), or a dedicated non-cutout green texture.

## Path stones (prototyped 2026-07-17 — pending direction)

- Rock-path stone models (MegaKit `RockPath_*`) are prototyped in the gallery (west of the catalog): **just paved path / stones on paved path / just stones**. Once Eddie picks a look, the next step is a **real path pass** — lay rock-path stones along the garden's paved path tiles to replace/augment the current path texture. `Pebble_*` models are also available for finer scatter.

## Unused model folders (audit 2026-07-17)

Not referenced at runtime (candidates to remove for disk hygiene; leaving in place for now):
`Modular Village`, `modular_fort_01_2k`, `modular_terrain_collections`, `othertrees`, `pinetree`,
`para_CC0_tex-pack-hedges` (was the *source* of the now-bundled `hedge_*` textures; folder itself isn't loaded),
`old_military_crate_2k` & `stone_fire_pit_2k` (only commented-out references). (`Quaternius Ultimate Stylized Nature Pack` already deleted.)
