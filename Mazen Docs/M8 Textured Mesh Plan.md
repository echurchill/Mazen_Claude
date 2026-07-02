# M8: Textured Mesh Rendering Upgrade
*Generated 2026-07-01 from codebase audit + reference image analysis*

---

## Reference Image Analysis

Two concept images define the target aesthetic:

1. **Orbit view** — Rubik's cube of hedge maze segments viewed from above at an angle
2. **First-person view** — standing inside a corridor between towering hedges

### What the Reference Images Show vs Current State

| Feature | Reference | Current |
|---|---|---|
| **Hedge texture** | Dense leafy boxwood, visible individual leaves | Flat procedural 3-color noise |
| **Floor texture** | Gravel/crushed stone with visible grain | Procedural sand with noise sparkle |
| **Wall height** | Hedges tower over player (3-4x corridor width) | 0.35 units (shorter than eye height 0.55) |
| **Wall shape** | Rounded tops, organic edges | Flat-top rectangular boxes |
| **Sky** | Blue sky with clouds above corridors | Solid dark blue clear color |
| **Shadows** | Strong directional shadows on floor | No shadow mapping |
| **Cubie frame** | Dark charcoal metallic rails between segments | Empty gap with background color |
| **Stone detail** | Rough stone visible on orbit-view walls with moss | Same hedge material on all walls |

### What We Already Have in Place

- `TextureIndex.Color = 0` enum defined in ShaderTypes.h (unused)
- Fragment argument table allocated with `maxTextureBindCount = 1`
- `ColorMap.png` asset exists in xcassets (unused)
- Vertex format includes `texCoord` (currently 0-1 for procedural use)
- `materialID` branching in fragment shader ready for texture sampling
- `styleSeed` per-tile variation already wired through

---

## Phase Plan

### M8.1 — Texture Loading & Binding

**Files:** Renderer.swift, ShaderTypes.h, Shaders.metal

The infrastructure is 80% there. Fragment arg table already reserves a texture slot.

- Create `MTKTextureLoader` and load textures from xcassets
- Use **MTLTextureType.type2DArray** (texture array) — each slice is one material (hedge=0, gravel=1, stone=2, normal maps=3-5). Avoids atlas UV math, each slice gets independent mipmaps
- Create `MTLSamplerState` with linear filtering + repeat addressing
- Expand `maxTextureBindCount` from 1 to 4 (diffuse array, normal array, sky, shadow map)
- Add `setTexture()` and `setSamplerState()` calls on fragment arg table
- Expand `TextureIndex` enum: `TextureIndexDiffuseArray = 0`, `TextureIndexNormalArray = 1`

**Texture assets needed** (512x512 tileable each):
- Hedge leaves diffuse + normal map
- Gravel/crushed stone diffuse + normal map
- Rough stone diffuse + normal map (orbit view)

These can be AI-generated or sourced from CC0 libraries (Polyhaven, ambientCG).

---

### M8.2 — UV Mapping Overhaul

**Files:** TileMeshLibrary.swift

Current texCoords are 0-1 normalized per quad, fine for procedural but wrong for tiling textures.

- **Wall faces**: World-space UVs — use `(horizontal_distance, height)` so the texture tiles naturally across adjacent walls. Scale factor ~2.0 repeats per tile width for hedge leaf density matching the reference.
- **Floor faces**: Planar projection in tile-local space, scaled to match gravel grain size.
- **Top cap**: Use wall-aligned UV from the top edge coordinates.
- Add a `tangent` field to `MazeVertex` for normal mapping (tangent-space lighting). This changes vertex stride from 48 to 64.

---

### M8.3 — Wall Geometry Upgrade

**Files:** TileMeshLibrary.swift, CameraState.swift

This is the biggest visual win — matching the reference's towering hedges.

- `wallHeight`: 0.35 → **1.2** (walls are ~2.4x tile width, matching reference proportions)
- `eyeHeight`: 0.55 → **0.45** (camera below wall tops)
- FOV: 80° → **70°** (tighter, more immersive corridor feel)
- Camera pitch: -0.12 → **-0.05** (less downward tilt, see more sky)
- **Rounded top cap**: Replace flat top quad with 4-8 arc segments forming a half-cylinder. Adds ~24 extra triangles per wall segment but matches the reference's organic hedge silhouette.
- Wall thickness: 0.08 → **0.12** (meatier hedges)

---

### M8.4 — Fragment Shader Rewrite

**Files:** Shaders.metal, ShaderTypes.h

The biggest shader change — replacing procedural noise with texture sampling while keeping fog/dissolve procedural.

```metal
// materialID 1 wall: sample hedge texture
float3 hedgeColor = diffuseArray.sample(sampler, uv, slice=0).rgb;
float3 hedgeNormal = normalArray.sample(sampler, uv, slice=0).rgb * 2.0 - 1.0;
// Transform normal to world space using TBN matrix
// Apply half-Lambert lighting with perturbed normal

// materialID 1 floor: sample gravel texture
float3 gravelColor = diffuseArray.sample(sampler, uv, slice=1).rgb;

// materialID 4/5 fog: KEEP procedural (it looks good already)
// materialID 6 player: KEEP as-is
```

- Normal mapping for leaf surface detail (the reference shows individual leaf shadows)
- Keep AO multiplication (`color *= aoFactor`)
- Keep styleSeed variation as a subtle color tint on top of the texture
- Height-based moss blend for orbit view (lerp stone texture toward green near top)

---

### M8.5 — Sky & Lighting (Polish)

**Files:** Shaders.metal, Renderer.swift

- **Procedural sky**: Fullscreen quad rendered before scene (depth disabled). Gradient from horizon blue to zenith blue, with noise-based cloud layer. No cubemap asset needed — the reference sky is simple enough for procedural.
- **Shadow mapping**: Single 1024x1024 directional shadow map. Render depth from light's perspective, sample in fragment shader. The reference's second image shows strong shadow lines across the gravel — this is a major immersion upgrade for first-person mode.
- **Light color**: Current `(0.4, 0.8, 0.6)` direction is fine. Add warm sun color `(1.0, 0.95, 0.85)` and cool ambient `(0.35, 0.45, 0.65)`.

---

### M8.6 — Cubie Frame & Final Polish (Polish)

**Files:** TileMeshLibrary.swift, Renderer.swift, CubeModel.swift

- **Dark frame mesh**: The reference shows charcoal metallic rails between cube segments. Generate thin rounded-rectangle strips at cubie boundaries. New materialID (7) with dark metallic shader.
- **MSAA**: Set `mtkView.sampleCount = 4` and update pipeline descriptor. The hedge silhouettes against sky will alias badly without it.
- **Orbit-view stone**: In orbit mode, the inner portions of walls could show stone texture (materialID 3) blended with moss on top edges, matching the reference's first image.

---

## Codebase Integration Points

### Existing Infrastructure

| Component | File | Status |
|---|---|---|
| Texture slot enum | ShaderTypes.h:21-24 | `TextureIndex.Color = 0` defined, unused |
| Fragment arg table | Renderer.swift:84 | `maxTextureBindCount = 1` allocated, never bound |
| ColorMap asset | Assets.xcassets/ColorMap.textureset | 37.5 KB PNG exists, never loaded |
| Vertex texCoord | ShaderTypes.h:49 | `vector_float2 texCoord` in MazeVertex, used for procedural |
| Material branching | Shaders.metal:97-201 | materialID switch in fragment shader |
| Per-tile seed | Shaders.metal:97 | `styleSeed` wired through InstanceData |

### Buffer & Stride Details

| Buffer | Stride | Notes |
|---|---|---|
| MazeVertex | 48 bytes | position(12) + normal(12) + texCoord(8) + aoFactor(4) + padding(12) |
| InstanceData | 96 bytes | modelMatrix(64) + baseColor(16) + materialID(4) + tileID(4) + discoveryAmount(4) + styleSeed(4) |
| FrameUniforms | ~80 bytes | viewProjectionMatrix(64) + cameraPosition(12) + time(4) + lightDirection(12) |

### Metal 4 API Constraints

- `MTL4ArgumentTable` for binding (not traditional `setVertexBuffer`/`setFragmentTexture`)
- `setTexture()` on argument table for texture binding
- `setSamplerState()` on argument table for sampler binding
- Index buffers require 4-byte alignment for UInt16 indices
- Instanced rendering groups tiles by openings mask

### Wall Geometry Reference (Current)

| Parameter | Current Value | M8 Target |
|---|---|---|
| wallHeight | 0.35 | 1.2 |
| wallThickness | 0.08 | 0.12 |
| tileSize | 0.98 | 0.98 (unchanged) |
| floorY | 0.001 | 0.001 (unchanged) |
| eyeHeight | 0.55 | 0.45 |
| FOV | 80° | 70° |
| pitchAngle | -0.12 | -0.05 |

### Texture Asset Requirements

| Texture | Size | Format | Purpose |
|---|---|---|---|
| Hedge diffuse | 512x512 | RGBA, tileable | Wall surfaces in FP + orbit |
| Hedge normal | 512x512 | RGB, tileable | Leaf surface detail bump |
| Gravel diffuse | 512x512 | RGBA, tileable | Floor paths |
| Gravel normal | 512x512 | RGB, tileable | Stone grain detail |
| Stone diffuse | 512x512 | RGBA, tileable | Orbit view inner walls |
| Stone normal | 512x512 | RGB, tileable | Rough stone bump |

All textures should be seamlessly tileable. Can be AI-generated or sourced from CC0 libraries (Polyhaven, ambientCG).

---

## Recommended Work Order

```
M8.1 (texture loading)     → foundation, unblocks everything
M8.2 (UV mapping)          → depends on M8.1 for testing
M8.3 (wall geometry)       → independent, can parallel M8.1+2
M8.4 (shader rewrite)      → depends on M8.1+2
── 80% visual target reached ──
M8.5 (sky + shadows)       → independent polish
M8.6 (frame + MSAA)        → independent polish
```

M8.1 through M8.4 get to ~80% of the reference look. M8.5 and M8.6 are polish that can be deferred.

The single highest-impact change is **M8.3 (wall height)** — even with procedural textures, taller walls in first-person mode will dramatically change the feel.

---

## What This Does NOT Include (Future Work)

- PBR materials (metallic/roughness) — stylized look doesn't need it
- Bloom/post-processing — not needed for this art style
- Particle effects (leaves, dust) — out of scope
- LOD system — geometry count is low enough at 5x5x5
- Deferred rendering — forward rendering is fine for this scene complexity
- Real-time GI — baked AO + half-Lambert is sufficient

## Potential future milestone work
Retexture

Outer surface
Moons
Sun

Inward surface 
Library 
Cave
House
Building 

Portals between planets 
Polar Mineways
