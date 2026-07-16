# Rubik's Maze -- Overnight Plan
*Generated 2026-06-16 from codebase audit + rendering research*

> **Status: 🗄️ HISTORICAL / SUPERSEDED** — see [Master Roadmap](../Master%20Roadmap.md). This was an early codebase audit; its work fed into the M8–M12 milestones, which are the live roadmap. Most items are resolved (SceneBuilder/PlayerState/CameraState extraction happened in M10 Phase 0; the debug HUD exists on `H`; walls are now full 3D hedges, not paper-thin). **Still-open carryovers** were migrated to the roadmap backlog: **iOS touch input** (still minimal) and a **frame-rate check** (a historical 50fps lock — verify it's gone). Kept for provenance; don't plan from this doc directly.

---

## Part 1: Codebase vs Plan Cross-Check

Compared the current codebase against `Rubik's Maze Plan.rtf`. Milestones M1-M6 are complete. Below are all remaining gaps, grouped by severity.

### Critical Bugs

1. **Wall mesh missing 4 of 6 faces** (`TileMeshLibrary.swift:148-208`)
   - `addWall()` generates only the inner face (facing corridor) and top cap
   - Missing: outer face, left end cap, right end cap, bottom face
   - Visible in orbit view as missing triangles -- walls look paper-thin
   - Fix: add 3 more quads per wall segment (outer + 2 end caps; bottom is optional)

2. **Frame rate locked at 50 fps** (logged in `/tmp/mazen_log.txt`, consistent 20ms/frame)
   - Plan target: 60 fps (16.67ms) on both Mac and iOS
   - Likely cause: `preferredFramesPerSecond` not set, or vsync hitting 50Hz display mode
   - Need to investigate `MTKView.preferredFramesPerSecond = 120` and actual display refresh rate

### Missing Features (Plan Items Not Yet Implemented)

3. **iOS has zero touch input** (`Mazen_Claude iOS/GameViewController.swift` -- 57 lines, no gesture recognizers)
   - Plan calls for placeholder touch input on iOS
   - Need: tap-to-move or virtual D-pad, swipe for rotation

4. **FrameUniforms missing lighting fields** (`ShaderTypes.h:8-14`)
   - Plan specifies `sunDirection` and padding in FrameUniforms
   - Current struct has: viewProjectionMatrix, cameraPosition, time
   - Missing: sunDirection (float3), lightColor, ambientColor
   - Light direction is hardcoded in shader at `normalize(float3(0.4, 0.8, 0.6))`

5. **No unit tests for edge crossing** (`CubeModel.swift` edge crossing logic)
   - Plan lists edge-crossing validation as M6 success criteria
   - Currently validated only via manual play-testing

6. **Wall height mismatch**
   - Plan: wallHeight = 1.3x tile width (~1.25 for tileSize 0.96)
   - Current: wallHeight = 0.35 (reduced during M5 for debugging)
   - Need to restore to plan value once wall mesh bug is fixed

### M7 Work Items (Not Yet Started)

7. **Lighting tuning** -- adjust ambient/diffuse balance for concept art look
8. **Color matching** -- hedge green, sand, stone, fog white to match reference images
9. **styleSeed variation** -- per-tile procedural variation (seed exists in InstanceData but shader barely uses it)
10. **60fps verification** -- profile on both Mac and physical iOS device
11. **4x4x4 test** -- scale cube from 3x3x3 to 4x4x4 to validate architecture
12. **Debug overlay** -- face/position/fps HUD for development
13. **End-to-end demo** -- walk through maze, rotate slice, cross edge, see fog dissolve

### Architecture Gaps vs Plan

14. **File structure doesn't match plan** -- plan specifies ~12 files in subdirectories (Model/, Topology/, Geometry/, Render/, Camera/, Input/); current code is 6 flat files in Shared/
15. **PlayerState not separated from GameState** -- plan has `PlayerState.swift` as its own file; currently embedded in `GameState.swift` (609 lines)
16. **No FaceAdjacency.swift** -- edge crossing table is embedded in `CubeModel.swift`
17. **No CameraSystem.swift** -- camera logic lives in `GameState.swift`
18. **TextureIndex enum defined but unused** (`ShaderTypes.h`) -- dead code
19. **`projectionDirty` flag** in CubeModel is effectively unused -- `rebuildProjection()` is called directly
20. **`findFaceletIndices`** is O(n) scan -- plan implies indexed lookup via CubeProjection

### Minor Differences (Acceptable)

- Controls: Plan says WASD; implementation uses WASD + Q/E for rotation + Space for camera toggle. This is fine per user instruction to ignore minor control differences.
- Plan mentions `MazeTile.swift` and `LayerTurn.swift` as separate files; functionality exists but is folded into CubeModel and GameState. Addressed in architecture section below.
- Debug print statements remain in GameState.swift ("Move:", "Blocked", "Edge crossing:", "Arrived:"). Should be removed or gated behind a debug flag before demo.

---

## Part 2: Rendering Fix Plan

Goal: transform the current flat-shaded prototype into something approaching the concept art aesthetic -- green hedge walls, sandy paths, gray stone outer walls, white per-tile fog, dark gaps, warm directional lighting.

### Phase R1: Fix Wall Mesh (Prerequisite for Everything Else)

**What:** Add the 3 missing wall faces in `TileMeshLibrary.addWall()`.

**How:**
```
For each wall segment, currently generates:
  1. Inner face (4 verts, 2 tris) -- KEEP
  2. Top face (4 verts, 2 tris) -- KEEP

Add:
  3. Outer face -- same as inner but offset by -wallThickness along inwardNormal,
     with normal flipped (outwardNormal = -inwardNormal)
  4. Left end cap -- small quad connecting inner and outer edges at p0 end
  5. Right end cap -- small quad connecting inner and outer edges at p1 end
```

- Each wall segment goes from 8 verts / 4 tris to 20 verts / 10 tris
- 16 masks x 4 possible walls = ~64 wall segments max, so ~1280 additional vertices total. Negligible.
- Winding must be counter-clockwise when viewed from outside (matches setCullMode(.back) + setFrontFacing(.counterClockwise))

**Impact:** Walls will look solid from all angles. Currently orbit view shows paper-thin walls.

**Effort:** ~30 lines of code in TileMeshLibrary.swift.

### Phase R2: Lighting Upgrade

**What:** Replace hardcoded Lambert with Half-Lambert + configurable light direction.

**Why Half-Lambert over Blinn-Phong:**
- Half-Lambert wraps light around geometry so no cube face goes completely dark
- Identical ALU cost to current Lambert (same instruction count)
- No per-material shininess tuning needed
- Specifically designed for stylized games (Valve, TF2) -- matches our art direction
- Formula: `halfLambert = (dot(N,L) * 0.5 + 0.5)^2`

**Steps:**
1. Add to FrameUniforms in ShaderTypes.h:
   ```c
   vector_float3 sunDirection;  // normalized, pointing toward light
   vector_float3 lightColor;    // e.g., (1.0, 0.95, 0.85) warm sun
   vector_float3 ambientColor;  // e.g., (0.35, 0.45, 0.65) blue sky
   ```
2. Update Renderer.swift to populate these each frame
3. Replace shader lighting from:
   ```metal
   float lighting = 0.3 + 0.7 * max(dot(N, L), 0.0);
   ```
   to:
   ```metal
   float hl = dot(N, L) * 0.5 + 0.5;
   hl *= hl;
   float lighting = 0.25 + 0.75 * hl;
   ```
4. Give fog tiles softer lighting: `0.55 + 0.45 * hl` (fog is self-illuminating)

**Effort:** ~20 lines shader, ~10 lines Swift.

### Phase R3: Material Shaders (Concept Art Colors)

Each material ID gets a procedural shader treatment. All fully procedural -- no texture assets needed.

#### R3a: Hedge Walls (materialID 1, height > 0.1)
- **Base:** 5-color green palette blended via layered value noise
  - Dark: (0.18, 0.30, 0.12), Mid-dark: (0.25, 0.40, 0.18), Mid: (0.30, 0.48, 0.22), Light: (0.38, 0.55, 0.30), Highlight: (0.45, 0.62, 0.35)
- **Technique:** 2-octave value noise at different scales + domain warping for organic feel
- **Fake bump:** Perturb world normal by noise gradient for surface detail without geometry cost
- **Height fade:** Darken near wall base with smoothstep(0.1, wallHeight*0.6, z)
- **Cost:** ~40 extra ALU ops per fragment (2 noise samples + math). Acceptable for Apple GPU with HSR.

#### R3b: Sand/Path Floor (materialID 1, height <= 0.1)
- **Base:** Warm sand palette: (0.72, 0.62, 0.45) to (0.60, 0.50, 0.35)
- **Technique:** Value noise at scale 6.0 for subtle color variation + fine-grain noise at scale 30.0 for sparkle
- **Contact darkening:** Darken floor near wall bases using smoothstep on distance to nearest wall edge (approximated by texCoord proximity to 0/1 edges)

#### R3c: Stone Walls (materialID 3 -- currently unused, for outer cube walls)
- **Base:** Gray palette: (0.55, 0.50, 0.45) to (0.65, 0.60, 0.55)
- **Technique:** Voronoi noise for stone block shapes, F2-F1 difference for mortar lines
- **Per-cell color:** Hash cell ID for subtle per-stone color variation
- **Cost:** Voronoi is ~60 ALU ops (9 hash evals + distances). Still fine for Apple GPU.

#### R3d: Fog (materialID 4) -- Enhancement
- **Current:** Basic FBM cloud pattern -- works but could be richer
- **Enhancement:** Add domain warping (feed noise into noise input coordinates) for swirling, organic fog
- **Layered opacity:** Multiple fog layers at slightly different Z heights for depth
- **Billboard approach:** For first-person mode, fog should fill corridors, not just lie flat. Cross-stacked camera-facing quads (2-3 per tile) recommended over ray marching for performance.

#### R3e: Dissolve Overlay (materialID 5) -- Enhancement
- **Current:** Noise-based dissolve with smoothstep threshold -- functional
- **Enhancement:** Add thin glowing edge at dissolve boundary
  ```metal
  float edgeDist = noise - threshold;
  float edgeGlow = (1.0 - smoothstep(0.0, 0.04, edgeDist)) * step(0.0, edgeDist);
  color += float3(0.3, 0.6, 1.0) * edgeGlow;  // blue edge glow
  ```
- **Alpha-based dissolve preferred over discard_fragment()** on Apple TBDR to preserve Hidden Surface Removal

**Total shader effort:** ~80-100 new lines in Shaders.metal.

### Phase R4: Vertex-Baked Ambient Occlusion

**What:** Compute AO factor per vertex at mesh build time based on wall adjacency. Zero runtime cost.

**How:**
1. Add `aoFactor` field to MazeVertex struct (float, 0.0 = fully occluded, 1.0 = fully lit)
2. In TileMeshLibrary, when generating vertices:
   - Floor vertices near wall bases: aoFactor = 0.6-0.7 (darkened)
   - Wall vertices at floor junction: aoFactor = 0.5-0.6
   - Wall top vertices: aoFactor = 1.0
   - Open floor center: aoFactor = 1.0
3. In fragment shader: `lighting *= in.aoFactor;`

**Impact:** Adds grounding and depth to the scene. Walls look like they're sitting on the floor instead of floating.

**Effort:** ~15 lines mesh generation, 1 line shader, update vertex struct.

### Phase R5: Performance Target (60fps)

1. Investigate the 50fps cap:
   - Check `MTKView.preferredFramesPerSecond` setting
   - Check if display is running at 50Hz mode
   - Profile with Xcode Metal debugger GPU counters
2. Use `half` precision in shader where possible (colors, normals, noise) -- 2x ALU throughput on Apple GPU
3. Consider pre-baking noise texture (256x256 R8Unorm, ~64KB) for fog if procedural FBM is too expensive on older iOS devices
4. All procedural materials should stay well within 16.67ms budget given:
   - TBDR + HSR eliminates overdraw for opaque geometry
   - Maze geometry is simple (few thousand triangles)
   - Noise complexity is modest (2-4 octave FBM)

### Rendering Phase Order

```
R1 (wall mesh fix) -- standalone, do first
R2 (lighting) -- standalone, can parallel with R1
R3 (materials) -- depends on R2 for lighting uniforms
R4 (AO) -- depends on R1 for correct wall geometry
R5 (performance) -- do last, after all shader work is in place
```

### What This Does NOT Include (Future Work)
- Bloom/post-processing -- not needed for prototype
- Shadow mapping -- Half-Lambert + baked AO is sufficient
- PBR materials -- stylized look doesn't need metallic/roughness
- Texture assets -- everything stays fully procedural
- Particle effects -- out of scope for visual prototype

---

## Part 3: Architecture Reorganization Plan

Goal: evolve from 6 large files toward the plan's ~12-file structure. Not literally matching the plan, but conceptually -- each file has a single clear responsibility.

### Current State

| File | Lines | Responsibilities |
|------|-------|-----------------|
| GameState.swift | 609 | Player state, movement, camera (orbit + FP), input handling, discovery, slice rotation, animation |
| CubeModel.swift | 419 | Cubie data, maze generation, projection, edge crossing table, world matrix, slice rotation math |
| Renderer.swift | 528 | Metal 4 pipeline, draw calls, instance building, uniform updates |
| TileMeshLibrary.swift | 209 | All mesh generation (floor, walls, fog quad, player marker) |
| CubeTypes.swift | 122 | Type definitions (CubeFace, SurfaceDirection, DirectionMask, MazeFacelet, Cubie) |
| ShaderTypes.h | 50 | Shared C/Metal types |
| Shaders.metal | 154 | Vertex + fragment shaders, noise functions |

### Proposed Structure

```
Mazen_Claude Shared/
  ShaderTypes.h              -- shared C/Metal/Swift types (expand with lighting)
  Shaders.metal              -- vertex/fragment shaders (will grow with materials)

  Model/
    CubeTypes.swift          -- KEEP as-is (types are already clean)
    CubeModel.swift          -- EXTRACT edge crossing table + projection
    EdgeCrossing.swift       -- NEW: 24-entry edge crossing lookup table
                                (currently ~60 lines in CubeModel.buildEdgeCrossings)
    MazeGenerator.swift      -- EXTRACT: maze generation algorithm from CubeModel
                                (~80 lines: generateMaze, addEdgeBridges)

  State/
    GameState.swift           -- SLIM DOWN: keeps game loop, discovery, slice rotation
    PlayerState.swift         -- EXTRACT: player position, facing, movement logic
                                 (~120 lines from GameState)
    CameraState.swift         -- EXTRACT: orbit + first-person camera, interpolation
                                 (~100 lines from GameState)

  Geometry/
    TileMeshLibrary.swift     -- KEEP (will grow with wall fix + AO vertices)

  Render/
    Renderer.swift            -- KEEP (may extract instance building later)

  Input/
    KeyboardInput.swift       -- EXTRACT from macOS GameViewController
    TouchInput.swift          -- NEW: iOS touch input (currently missing entirely)
```

### Extraction Priority

**Do first (highest value, lowest risk):**
1. **PlayerState.swift** -- cleanest extraction. Player position, facing, movement queue, and `processMovement()` are self-contained. GameState keeps a `var player: PlayerState` reference.
2. **CameraState.swift** -- orbit rotation, first-person position, interpolation, and `updateCamera()` are already logically grouped in GameState. Extract as a struct with `update(player:deltaTime:)` method.
3. **TouchInput.swift** -- entirely new file, no extraction risk. Unblocks iOS testing.

**Do second (moderate complexity):**
4. **EdgeCrossing.swift** -- the 24-entry lookup table and `edgeCrossing()` function. Pure data + lookup, no state.
5. **MazeGenerator.swift** -- `generateMaze()` and `addEdgeBridges()`. Takes a cubie array, returns modified cubies. Stateless.

**Do later (can wait):**
6. **KeyboardInput.swift** -- small refactor, low urgency
7. **InstanceBuilder** extraction from Renderer -- only worthwhile if Renderer grows past ~600 lines

### Guiding Principles

- Each file should have **one reason to change**. If fixing player movement doesn't require touching camera code, they belong in separate files.
- Prefer **structs with methods** over classes where possible (value semantics, no reference cycles).
- Keep the **dependency direction simple**: Model knows nothing about Render. State depends on Model. Render depends on both.
- Don't over-abstract. If a function is only called from one place, it can stay in that file.
- **No protocol abstractions** unless there are genuinely two implementations (e.g., keyboard vs touch input).

### What NOT To Do

- Don't create a `Utils/` folder with random helpers
- Don't add a dependency injection framework
- Don't split Shaders.metal into multiple files (Metal compiler handles one file fine at this scale)
- Don't refactor and add features simultaneously -- extract first, then add new code to the clean structure

---

## Summary: Recommended Work Order

```
1. R1: Fix wall mesh (30 min)          -- unblocks visual testing
2. Architecture: Extract PlayerState    -- cleanest win, reduces GameState
3. Architecture: Extract CameraState    -- second cleanest extraction
4. R2: Lighting upgrade                 -- Half-Lambert + uniforms
5. R3: Material shaders                 -- hedge, sand, stone colors
6. R4: Baked AO                         -- vertex darkening at wall bases
7. Architecture: EdgeCrossing.swift     -- clean data extraction
8. iOS: TouchInput.swift                -- unblocks iOS testing
9. R5: 60fps investigation              -- profile with all shaders in place
10. M7: Final tuning + demo walkthrough
```

Each step is independently testable. Build and run after every step.
