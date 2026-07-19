# Asset Sourcing Guide

*What kinds of third-party assets and shaders actually fit our custom Metal 4 / Swift engine — so shopping trips don't end in lock-in. (Eddie + Claude, 2026-07-18.)*

## The one-line rule

**Flat data or readable shader source = usable. A node-graph or an engine's material file = reference only.**

Our engine consumes exactly two things:

1. **Flat data** — meshes and images the ModelIO/Metal pipeline can read directly.
2. **Shader *source* you can read** (GLSL/HLSL/Shadertoy) — Claude ports the algorithm to `Shaders.metal` by hand. The maths transfers even though the file doesn't.

Anything that is a *compiled/serialized* material, a *node graph*, or an *engine scene* is *reference only* — good for a visual target, never a drop-in.

## ✅ Search for these (drop-in data)

- **`CC0`** — the single most important tag: free, no attribution, any project. (Also "public domain".)
- **Meshes:** `OBJ` (our ModelIO import path), also `glTF` / `GLB` (ModelIO reads these too).
- **Textures:** `PBR texture`, `seamless` / `tileable`, `texture atlas`, `trim sheet`; `alpha` / `cutout` / `billboard` / `sprite sheet` (for our alpha-cutout card foliage, materials 17/18); `noise map` / `gradient map` / `flow map` (fuel for procedural shaders).
- **Style match:** `stylized`, `hand-painted`, `low poly` — matches our flat/Quaternius look.
- **Best CC0 sources:** Quaternius, Kenney, Poly Haven, ambientCG.

## 🟡 Search for these (shader *techniques* — reference, Claude ports by hand)

- **`Shadertoy`**, plain **`GLSL`** / **`HLSL`** — readable in any language; the algorithm transfers.
- Search by **effect name:** `portal`, `vortex`, `force field`, `dissolve`, `fresnel`, `hologram`, `energy shield`, `fog`, `water`, `toon` / `cel`.
- A pack of engine-locked shaders (e.g. `.gdshader`) is still worth *looking at* for the technique, even if we can't import a byte of it.

## ❌ Avoid (engine-welded — reference at best)

- `.gdshader` (Godot), Unity **Shader Graph** / `.shadergraph` / Amplify, Unreal **Material** / Niagara.
- Serialized engine files: `.tres`, `.tscn`, `.prefab`, `.uasset`.

## Worked example — the BinBun free packs (2026-07-18)

- **BinbunVFX (portal):** no usable assets (only a `placeholder.png`); the effect is 100% procedural in `portal.gdshader`. Godot-locked, but a great **technique reference** — layered parallax depth, polar swirl, distance-field shape mask + open/close, Bayer dithering, screen-space refraction. Ported the swirl-vortex + shape mask into our `material 23`. **Verdict: don't buy; reference only.**
- **BinbunGrass:** `.gdshader` files unusable, but the **PNGs transfer** (four 512² grass-tuft alpha masks + a 1024² 2×2 atlas) — drop-in for our card foliage path. Wind-sway technique is portable too. **Verdict: textures usable, but we already have grass coverage — nice-to-have.**
- **License caveat:** the free downloads shipped *no* license file. The paid page claims CC0 — confirm the terms on the store page/EULA before shipping any of those PNGs.

## Always, before shipping a third-party asset

Confirm the **license** (CC0 / permissive) — a bundled `LICENSE`/`EULA`, or the store page. "Free to download" ≠ "free to redistribute in a build."
