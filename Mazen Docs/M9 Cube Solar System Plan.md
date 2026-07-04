# M9: Cube Solar System — Sun, Moon & Dynamic Lighting

## Vision

Add a cube-shaped sun and cube-shaped moon to the game world, creating a miniature solar system with physically-motivated orbital mechanics and dynamic lighting. The game world remains the stationary reference frame; the sun and moon move around it.

---

## Orbital Model

### Reference Frame
The game world (5x5x5 cube) stays at the origin. All celestial positions are computed relative to it. This is the player's frame of reference — the sun and moon appear to orbit.

### Sun (apparent orbit)
In reality the game world would orbit the sun, but since we hold the game world fixed, the sun traces an apparent orbit around it.

- **Orbit radius:** ~80 units (distant enough to appear as a directional light source; the 5-unit game cube subtends ~3.6° from the sun — realistic for a "planet")
- **Orbit period:** ~300 seconds (5-minute day/night cycle, tunable)
- **Orbit plane:** tilted ~23° from the game world's Y-axis (gives seasonal shadow angle variation as the orbit progresses)
- **Shape:** cube, ~8 units per side (subtends ~5.7° from the game world — visually prominent)
- **Material:** emissive (self-lit, bright yellow-white, no shadow receiving)

### Moon
The moon orbits the game world directly (a true satellite).

- **Orbit radius:** ~18–22 units (close enough to be visually significant)
- **Orbit period:** ~45–60 seconds (faster than the sun, so the player sees it move)
- **Orbit plane:** tilted ~5° relative to the sun's orbital plane (occasional eclipses when planes intersect)
- **Shape:** cube, ~1.5 units per side
- **Material:** diffuse gray, lit by the sun (shows phases naturally — the sun-facing side is bright, the opposite side is dark)

### Position Computation (per frame)
```
sunAngle = (time / sunPeriod) * 2π
sunPos = sunRadius * (cos(sunAngle) * orbitX + sin(sunAngle) * orbitZ)
  where orbitX, orbitZ are the tilted orbital basis vectors

moonAngle = (time / moonPeriod) * 2π
moonPos = moonRadius * (cos(moonAngle) * moonOrbitX + sin(moonAngle) * moonOrbitZ)
```

The orbital basis vectors encode the tilt:
```
sunOrbitX = (1, 0, 0)
sunOrbitZ = (0, sin(23°), cos(23°))  // tilted from Y-axis

moonOrbitX = rotate(sunOrbitX, 5° around Y)
moonOrbitZ = rotate(sunOrbitZ, 5° around Y)
```

---

## Rendering Changes

### Current State (what exists today)
- Fixed directional light at `normalize(0.4, 0.8, 0.6)`
- 1024x1024 shadow map, single pass from light's perspective
- Half-Lambert diffuse lighting with sun color `(1.0, 0.95, 0.85)` and sky ambient `(0.35, 0.45, 0.65)`
- Shadow mapping with 3x3 PCF, 55% shadow darkness
- Equirectangular skybox sphere

### Step 1: Orbital System (`CelestialSystem.swift` — new file)

Create a `CelestialSystem` class/struct that computes sun and moon positions each frame.

```swift
struct CelestialSystem {
    // Sun orbit parameters
    let sunOrbitRadius: Float = 80.0
    let sunPeriod: Float = 300.0        // seconds for full day
    let sunTilt: Float = 23.0 * .pi / 180.0
    let sunSize: Float = 8.0

    // Moon orbit parameters
    let moonOrbitRadius: Float = 20.0
    let moonPeriod: Float = 50.0
    let moonTilt: Float = 5.0 * .pi / 180.0
    let moonSize: Float = 1.5

    func sunPosition(time: Float) -> SIMD3<Float>
    func moonPosition(time: Float) -> SIMD3<Float>
    func sunDirection(time: Float) -> SIMD3<Float>  // normalized, for lighting
    func moonDirection(time: Float) -> SIMD3<Float>
}
```

**Dependencies:** None (pure math).

### Step 2: Dynamic Light Direction (Renderer.swift)

Replace the fixed `lightDir` with the sun's computed direction.

Current (line ~646):
```swift
let lightDir = normalize(SIMD3<Float>(0.4, 0.8, 0.6))
```

Replace with:
```swift
let lightDir = celestialSystem.sunDirection(time: gameState.time)
```

Update the shadow map's light-view-projection matrix to track the sun:
```swift
let lightPos = lightDir * 15.0  // keep shadow map centered on game world
let lightView = float4x4.lookAt(eye: lightPos, target: SIMD3(0,0,0), up: ...)
```

The `up` vector for `lookAt` needs care — when the sun is near the Y-axis, use a fallback up vector to avoid gimbal issues.

**Dependencies:** Step 1.

### Step 3: Render Sun and Moon Cubes (Renderer.swift)

Add geometry for the sun and moon cubes. Options:

**Option A (simple):** Reuse the existing cube vertex buffer, draw with a simple emissive/unlit shader at the computed position and scale.

**Option B (dedicated):** Create small pipeline states for celestial bodies.

Recommended: **Option A** — create two new shader functions:

- `celestialVertexShader` — transforms a unit cube to world position/scale
- `sunFragmentShader` — outputs emissive color (bright yellow-white), no lighting
- `moonFragmentShader` — basic diffuse lit by sun direction, gray albedo

Draw order: render sun and moon **after** the skybox but **before** the game world (or after — they're far enough away that depth sorting is fine either way, though rendering before game world with depth write would be safest).

**Dependencies:** Step 1, new shader code.

### Step 4: Day/Night Ambient Cycle (Shaders.metal)

As the sun dips below the horizon (sun Y < 0), transition lighting:

- **Daytime** (sun above horizon): current warm lighting
- **Sunset/sunrise** (sun near horizon): orange-tinted light, longer shadows
- **Nighttime** (sun below horizon): cool blue ambient, moonlight only

Add to `FrameUniforms`:
```c
float sunElevation;        // dot(sunDir, up) — positive = day, negative = night
vector_float3 moonDirection;
float moonIntensity;       // 0.0–0.15 range
```

In the fragment shader:
```metal
float dayFactor = smoothstep(-0.1, 0.2, frame.sunElevation);
float3 ambient = mix(nightAmbient, dayAmbient, dayFactor);
float3 sunContribution = sunColor * halfLambert * shadowFactor * dayFactor;
float3 moonContribution = moonColor * moonHL * frame.moonIntensity * (1.0 - dayFactor);
float3 lighting = ambient + sunContribution + moonContribution;
```

**Dependencies:** Steps 1–2.

### Step 5: Moon Phases (visual)

The moon's lit face is determined by the sun-moon angle. Since the moon is a cube, this happens naturally if we light it with the sun direction in Step 3's `moonFragmentShader`. The player will see:
- Full "moon" when the sun is behind the camera and the moon is in front
- New "moon" when the moon is between game world and sun
- Quarter phases at 90° angles

No extra code needed — diffuse shading handles this automatically.

**Dependencies:** Step 3.

### Step 6: Moon Shadow (optional, lower priority)

The moon could cast a very faint secondary shadow. This requires a second shadow map pass from the moon's direction. Given the moon's dimness, this is a nice-to-have.

If implemented:
- Second 512x512 shadow map (lower res than sun's)
- Only active at night (when `sunElevation < 0`)
- Very subtle shadow factor (~10% darkness)

**Dependencies:** Steps 1–4. Can be deferred.

### Step 7: Eclipse Events (optional, lower priority)

When the moon passes between the sun and game world, the shadow should darken dramatically. This happens naturally if:
- The moon is rendered into the sun's shadow map (it occludes sun light)
- The orbital planes occasionally intersect

The 5° tilt means eclipses are rare but possible — a nice emergent behavior.

**Dependencies:** Steps 1–5. Mostly free if moon is in shadow pass.

---

## Implementation Order

| Phase | What | Effort | Visual Impact |
|-------|------|--------|---------------|
| **Phase 1** | CelestialSystem + dynamic sun direction | Small | Shadows rotate over time (day cycle) |
| **Phase 2** | Render sun cube (emissive) | Small | Visible sun in sky |
| **Phase 3** | Render moon cube (sun-lit) | Small | Visible moon with phases |
| **Phase 4** | Day/night ambient cycle | Medium | Dramatic lighting changes |
| **Phase 5** | Moon as secondary light | Small | Subtle nighttime illumination |
| **Phase 6** | Moon shadows | Medium | Secondary shadow at night |
| **Phase 7** | Eclipse handling | Free | Emergent from moon in shadow pass |

**Phases 1–3** deliver the core visual. **Phase 4** makes it atmospheric. **Phases 5–7** are polish.

> **STATUS — M9-1 + M9-2 ✅ done (2026-07-03).** New `CelestialSystem.swift` (owned by `GameState`) computes sun/moon orbits — sun period 90 s, 23° tilt, starts at noon; distances fixed (60 / 22) inside `cameraFarZ = 100`, so the same orbit reads across cube sizes. The shadow-casting light now tracks `sunDirection(time:)` (lookAt up-vector guarded when the sun is near-vertical) → shadows sweep across the maze over the day. A visible **emissive cube-sun** (materialID 12, excluded from distance fog, drawn via a `celestialCube` unit-cube mesh + a `SceneBuilder` celestial batch into the opaque list; harmless in the shadow pass since it's far outside the frustum). The M10 shadow retune already covered the plan's "shadow tuning vs 5× features" trap, so **no retune was needed**. Night is flat until M9-4. **User: "Looks so cool."** Next: M9-3 (moon), M9-4 (day/night).
>
> **STATUS — M9-3 ✅ done (2026-07-03).** Moon: a smaller grey cube (materialID 13) at its orbital position (period 47 s, opposite tilt, starts opposite the sun), diffuse-lit by the sun direction so its cube faces read as crisp phases; excluded from fog, batched with the sun via `celestialCube`. **User: "looks correct."**
>
> **STATUS — M9-4 done; refinements → M9.5 (2026-07-03).** Day/night cycle: `FrameUniforms` gained `sunElevation` / `moonDirection` / `moonIntensity` (the struct is a Swift `typealias`, so no manual mirror to sync). A `dayFactor = smoothstep(-0.15, 0.15, sunElevation)` fades the sun out at night, shifts ambient warm-day → cool-night, and adds a moon fill light while the moon is up; the fog gained a day/night horizon so it stops glowing against the night sky. Builds and reads as a cycle — but a playtest in **orbit view** exposed three things the cycle *doesn't* touch (now collected into **M9.5** below): the sky never changes, the whole cube dims as one (a flat-world model, wrong for a cube), and the cube itself never moves. Also flagged: sun/moon read a touch close.

## M9.5 — Polish (planned — picking up 2026-07-04)

M9 Phases 1–4 delivered the core (sun, moon, sweeping shadows, day/night). A playtest in **orbit view** — where the sky fills the frame and you see the whole cube at once — showed the cycle stops at the maze and the world feels static. M9.5 collects the polish to make the solar system read as a *living, correct* scene. **Keep the accelerated orbit rate (`sunPeriod` 90 s) until these land**, then re-tune the periods for real play.

> **STATUS — M9.5-1 + M9.5-2 ✅ done (2026-07-04).** **Dynamic sky** keyed to `cameraUp` (the face normal in first person, world-up in orbit): a daytime gradient + sun halo + horizon sunset, fading to the starfield at night, stars faintly through the day sky. **Per-face day/night** derives `faceUp` from the dominant axis of the (cube-centred) world position and runs the day factor off `dot(faceUp, sunDir)` — so each face has its own cycle, the sun-facing face stays bright at dawn/dusk, and the terminator sweeps the cube (and will sweep from the spin for free once M9.5-3 lands, since `faceUp` comes from the already-spun world position). `frame.sunElevation` is now unused by the main shader (left in the struct). User verified in orbit + first person. Next: **M9.5-3 (cube spin)** + **M9.5-4 (push sun/moon out)**.
>
> **STATUS — M9.5-3 + M9.5-4 ✅ done (2026-07-04).** **Cube spin:** a slow idle `GameState.worldSpinMatrix()` (Y-axis) applied to all game-cube render instances and the first-person camera (which rides it); the sun/moon and the orbit camera stay world-frame. Net — orbit view watches the cube turn like a planet; first person keeps the maze rock-stable underfoot while the sun/sky/shadows sweep by (no navigation disorientation). Composes with the M9.5-2 `faceUp` (from world position), so the terminator also sweeps from the spin for free. **Distances/pacing (iterated with the user):** sun pushed to 176 (2× perceived distance = half apparent size); moon to 54.4 so its apparent size *equals* the sun's (the Earth eclipse coincidence — sets up M9-7); `cameraFarZ` 100→220 to fit the sun; orbit periods stretched to a ~8-min day (sun 480 s, moon 546 s, Earth-like ratio). User: shadows + sunrise/set "look pretty good," distances "much better." **This completes M9.5-1…4.**
>
> **Deferred (future polish round, user-agreed):** the per-face day/night terminator in *orbit view* reads harsh — the lit face is a touch flat/over-bright and its boundary to the night face is a hard edge. A shading-softness pass (graded terminator, lower the lit max, a little bounce light on the dark side) — cosmetic, not structural. Also still open from the base plan: **M9 Phase 6** (moon shadows — a second shadow pass, subtle payoff, deferred).
>
> **STATUS — M9 Phase 5 + Phase 7 ✅ done (2026-07-04).** **Moonlight (Phase 5):** the moon fill is now a proper cool, half-Lambert directional light on the night side (intensity 0.15→0.30), so moonlit nights read as lit. **Eclipse (Phase 7):** an `eclipseFactor` uniform (from `dot(sunDir, moonDir)` vs the shared apparent radius) fades the sun's light on the day faces as the nearer moon crosses it — dramatic since the two share an apparent size — plus an eerie reddish twilight; the moon cube naturally occludes the sun cube by depth. Added a debug **`T`** key (world time-scale 1×/8×/60×; player controls stay real-time) to reach night and hunt the (rare, node-aligned) eclipse. **Also added — first-person mouselook:** mouse looks around with pointer capture (`CGAssociateMouseAndMouseCursorPosition` + hidden cursor in FP); a forward move steers `facing` to the look, snapped to the 8-way grid (`GameState.steerToLook`, geometry-based so no sign convention to track). Explored a free-look/mouselook toggle (Caps-Lock, then `L`) but the **user standardized on mouselook**, so the toggle was removed. Yaw sign flipped after a first-look test.
>
> **STATUS — M9 Phase 6 + orbit terminator + movement smoothing ✅ done (2026-07-04). M9 complete.** **Terminator softened:** day/night now runs off `normalize(worldPosition)` (the surface's radial direction) instead of the discrete face normal, so it's a smooth band sweeping the cube rather than a hard face-seam edge; lit peak toned down a touch for the "over-bright" note. **Moon shadows (Phase 6)** done cheaply — one shadow map, its casting light switched to the moon when the sun is below the horizon (`shadowDir` in the Renderer), and only the direct moonlight takes the resulting `shadowFactor` (ambient + eclipse glow stay unshadowed). **Walking smoothness** (user flagged "herky jerky"): two fixes — **hold-to-walk** (W/S set `forwardHeld`/`backwardHeld`; `GameState.update` chains the next hop the instant one ends, so no OS key-repeat gap) and **linear** move interpolation (the old per-hop `smoothstep` decelerated to a full stop at every sub-cell boundary; turns keep their ease). **M9 is now complete** — core (1–4) + M9.5 polish (1–4) + Phases 5–7. Deferred/optional only: further per-face shading finesse, and non-M9 milestones (M12 assets, M11 moon world).

### M9.5-1 — Dynamic sky
`skyFragmentShader` samples one fixed starfield texture (no day/night), so "day" reads as a bright cube in dead-of-night space — glaring in orbit view.
- Drive the sky from `sunElevation` / `lightDirection`: a lit daytime sky gradient (brighter toward the sun and horizon), warm sunset tones as the sun nears the horizon, fading back to the starfield at night; optionally a soft sun glow around `lightDirection`.
- No new uniforms — the sky shader already has `frame`.
- **Design choice:** keep it spacey (stars always faintly present, sky tints over them) vs a full atmospheric blue day. Lean hybrid, to keep the cube-in-space identity.

### M9.5-2 — Per-face day/night (fix the global dimming)
M9-4's `dayFactor` is a single **global** value from the sun's world elevation (`sunDir.y`) — a flat-world model. On a cube seen whole in orbit it's wrong: the face the sun sits directly on gets dimmed at dawn/dusk instead of staying bright. The base directional lighting already lights faces correctly; the global scaling of `sunColor` is the culprit.
- Make day/night **per-face**: a local sun elevation from the surface's face normal vs the sun (`dot(faceUp, sunDir)`), so each face runs its own dawn → day → dusk → night as the sun sweeps the cube — the terminator crossing faces is both correct and better-looking.
- Face-up for a fragment: derive from the dominant axis of its (cube-centred) world position, or pass the tile face normal per-instance. Must use the **spun** normal once M9.5-3 lands.
- Keep full-strength per-face sun; key the night ambient / moon-fill to the local factor. First-person players still get a real local day/night on their face.

### M9.5-3 — Game-cube idle rotation
Only the orbit *camera* pans today; the cube itself never moves, which adds to the static feel. Give the world a slow idle spin — a planet turning under its orbiting sun.
- A slow, time-based `worldSpin` (tilted axis) applied as a global transform to all game-cube instances; the sun/moon and the orbit camera stay world-frame, so the spin sweeps the sun across faces → dynamic lighting/shadows from the spin itself, compounding with the sun's orbit.
- First-person camera rides the spin (you stand on the turning cube); the orbit camera does not.
- Composes with the slice-rotation animation (`worldSpin · sliceAnim · worldMatrix`) and the shadow pass (world-frame light; spun geometry sweeps shadows). Coupled with M9.5-2 (spun face normals) — build together.
- **Tunables:** spin period (minutes), axis tilt. Decide whether it eases/pauses during active first-person navigation to avoid disorientation, or just stays gentle enough not to matter.

### M9.5-4 — Push the sun & moon out
They read a touch close. Increase `sunOrbitRadius` / `moonOrbitRadius` (≈ 60→90, 22→36) so they sit farther and read as celestial; bump `WorldScale.cameraFarZ` (100→≈160) so they stay inside the frustum; re-tune `sunSize` / `moonSize` for a sensible apparent size at the new distance.

### Sequencing
M9.5-2 + M9.5-3 are coupled (both about the cube's orientation vs the sun) — do them together. M9.5-1 and M9.5-4 are independent quick wins that can land first. After M9.5: revisit M9 Phases 5–7 (moon-as-light, moon shadows, eclipses) and re-tune orbital periods for real play.

---

## File Changes Summary

| File | Changes |
|------|---------|
| `CelestialSystem.swift` | **NEW** — orbital computation |
| `Renderer.swift` | Dynamic light dir, render sun/moon cubes, celestial system init |
| `Shaders.metal` | Sun/moon shaders, day/night ambient, optional moon light |
| `ShaderTypes.h` | Add `sunElevation`, `moonDirection`, `moonIntensity` to `FrameUniforms` |
| `GameState.swift` | Pass time to celestial system (or renderer reads `gameState.time` directly) |

---

## Tuning Parameters

All in `CelestialSystem`:
- `sunPeriod` — day length (300s default, adjustable for testing)
- `moonPeriod` — lunar month (50s default)
- `sunOrbitRadius` — how far away the sun appears (80 units)
- `moonOrbitRadius` — moon distance (20 units)
- `sunSize` / `moonSize` — visual size of cube celestials
- `sunTilt` / `moonTilt` — orbital plane inclinations

---

## Technical Notes

- **Shadow map stability:** As the sun moves, shadow map coverage needs to track. The current orthographic projection (`-8..8` range) works for a 5-unit cube. Keep the shadow map centered on the game world, not the sun.
- **Shadow map up-vector:** When `lightDir` is near `(0,1,0)` or `(0,-1,0)`, the `lookAt` up-vector must switch to avoid degeneracy. Use `abs(dot(lightDir, Y)) > 0.99 ? X : Y` as fallback.
- **Far plane for sun/moon:** Current `farZ = 100.0`. The sun at 80 units will be within range. If orbit radius increases, bump `farZ`.
- **Performance:** Two extra cube draws (12 triangles each) and unchanged shadow pass count = negligible cost. Day/night is a few extra ALU ops in the fragment shader.
- **Metal 4 compatibility:** No new API surface needed. Existing pipeline descriptor patterns work for the new shaders.

---

## M9/M10 Compatibility & Sequencing

*(This section is duplicated verbatim in both the M9 and M10 plan documents. If you update it, update both.)*

### Known friction points

1. **Shadow tuning vs. 5x smaller features (the trap).** The current shadow bias (`0.003`–`0.008` over the light's 20-unit depth range, near 5 → far 25) equals **0.06–0.16 world units** of offset. Invisible against today's 1.2-high walls, but 25–67% of M10's 0.24 wall height — shadows will detach ("peter-pan") or vanish on low walls and 0.07-thick posts, worst at M9's low sun angles. Also: at 1024x1024 over the 16-unit ortho span, a jamb post is ~4.5 shadow texels wide and the 3x3 PCF blur is comparable to the feature size. **Fix once, after M10 Phase B geometry exists:** tighten light near/far around the cube, cut bias ~4x, consider a 2048 shadow map.
2. **Same-file churn.** Both milestones edit `Shaders.metal`, `ShaderTypes.h`, and `Renderer.swift`. Run phases strictly serially; never interleave M9 and M10 work.
3. **Night legibility at the new scale.** M9's night ambient / `moonIntensity` must be tuned at M10's 0.09 eye height inside gateway-enclosed corridors — a much darker experience than the old over-the-walls view. The fog/translucent pass colors also need day-factor modulation, or fog will glow at night.
4. **Aesthetic constants assume the old perceived scale.** After M10 Phase A, revisit `moonOrbitRadius` (the moon subtends ~4.3°; at 5x perceived scale a 20-unit orbit reads as "a barn 400m away") and `sunPeriod` (a 300s day may feel short once traversal takes ~3x longer).

### Non-issues (verified)

- Props, gateways, and corner posts flow through the existing instanced opaque + shadow passes, so they are automatically lit and shadowed by the sun/moon — no extra integration work.
- Sun at 80 units sits inside `farZ = 100`; orbit camera distance 12 unaffected.
- Material additions don't collide: M9 adds `FrameUniforms` fields and dedicated sun/moon shaders; M10 adds materialIDs (corner post, path floor, props) in `InstanceData` space.

### Phase 0 — pre-flight refactor (before any M9/M10 work)

> **STATUS: ✅ COMPLETE (2026-07-02).** All of R1–R5 landed as behavior-neutral refactors, each verified (tests + build + screenshot-identical render). Coordinate math is now proven size-generic across {3,5,7,9} by `Tests/run-tests.sh` (6592 checks). New files: `WorldScale.swift` (single scale source, per-world), `SceneBuilder.swift` (instance building extracted from Renderer, which dropped 857→546 lines), `Tests/` (standalone runner). One intentional behavior tweak: the iOS pinch zoom-in limit went from 3 to 5 units to unify with macOS via `WorldScale.orbitDistanceMin`.
>
> **Step 0.5 ✅ done (2026-07-03).** Default cube flipped to **7³** (`Renderer.initialCubeSize`); the N key now cycles odd sizes 3→5→7→9 live; shadow map bumped to 2048; edge-bridge density scales with cube size (`max(1, n/3)`). Verified at 7³ and 9³ — framing and shadows auto-adjusted with **no other changes needed**, confirming the size-independence work paid off. Next: step 1 (M10 Phase A).

Small, surgical, each step independently verifiable (build + run + compare screenshot). Phase 0 also **bakes in cube-size independence** (see R1/R4/R5) — but the actual size flip is deliberately *not* part of Phase 0, since changing the world mid-refactor would destroy the screenshot-identical baseline; it runs as its own experiment right after (step 0.5 below):

- **R1 — Single source of scale truth.** A `WorldScale` constants type (tile spacing, tile mesh size, gap, wallHeight, wallThickness, eyeHeight, per-mode FOV) that also takes **cube size as a first-class input**, deriving the world-extent values from it: camera `orbitDistance` (today hardcoded 12, tuned to a 5-wide cube), shadow ortho bounds (`-8..8` — a 9³ cube's half-diagonal of ~7.8 barely fits), light near/far and eye distance, and M9 orbit radii. M10 Phase A, the gap-removal decision, and any future cube-size change become one-file changes.
- **R2 — De-duplicate the uniforms struct.** `FrameUniformsSwift` (Renderer.swift) manually mirrors `FrameUniforms` (ShaderTypes.h); the layouts must match by hand. M9 adds three fields — an easy skew. Either bridge the C struct into Swift and delete the mirror, or add a compile-time size assertion.
- **R3 — Extract scene/instance building from Renderer.** Renderer.swift (~855 lines) mixes pipeline setup, texture loading, per-frame instance building, and animation-matrix logic. Pull instance building into its own file so M9 (celestial draws) and M10 (sub-cell floors, props) land in focused code instead of weaving through the monolith.
- **R4 — Coordinate-math test target.** Unit tests for `gridPosition`/`worldMatrix` consistency, `EdgeCrossing` round-trips, and rotation math — **parameterized across cube sizes {3, 5, 7, 9}**, turning "the coordinate math is probably size-generic" into "verified". This exact class of bug cost us the entire M8 debugging session; M10 Phases D–E multiply the coordinate math by sub-grids and 8 headings. Cheapest insurance in the plan.
- **R5 — Facelet lookup dictionary.** `CubeModel.findFaceletIndices` is an O(n²) scan — fine at 5³ today, but M10 sub-grid movement and prop occupancy query it more often, and larger cubes (7³/9³) grow it ~4x. Promoted from optional now that Phase 0 targets size-independence.

**M11 guardrails (free now, expensive to retrofit):** the planned moon-as-a-world milestone (see *M11 Lunar Excursion Seed.md*) requires that R1's `WorldScale` be **per-world** (not a singleton) and that R3's scene builder take the `CubeModel` **as a parameter** — never assume a single global world.

**Do NOT pre-refactor** (M9/M10 rewrite these anyway): `PlayerState` movement duplication (Phase D rewrites movement), `TileMeshLibrary` wall-mask caching (Phase B replaces it with per-edge composition), maze generation (Phase F changes it for rooms).

### Recommended sequence

| Step | Work | Why this position |
|---|---|---|
| 0 | Pre-flight refactor R1–R5 | Both milestones touch these seams; cheapest before either starts. Bakes in size-independence (R1 derives world-extent values from cube size; R4 tests sizes 3/5/7/9) |
| 0.5 | *(Optional)* Cube-size experiment — flip to 7³ or 9³ | ~1 hour once Phase 0 lands: one-line change + visual tuning pass (edge-bridge density, shadow map 2048). Done here so the baseline is stable before M10 geometry work; keep odd sizes — even sizes break the center-tile player start |
| 1 | M10 Phase A — perception scale-up | Instant payoff; sets the perceived scale that later aesthetic tuning depends on |
| 2 | M10 Phase B — edge model, gateways, corner posts | Finalizes wall geometry *before* shadow tuning |
| 3 | M9 Phases 1–4 — celestial system, sun, moon, day/night + **shadow retune** | Shadows tuned once against final wall geometry; night ambient tuned at new eye height |
| 4 | M10 Phases C–E — sub-grid, movement, crossings/rotations | Pure gameplay/data-model work; shaders stay stable |
| 5 | M10 Phases F–G — rooms, props | Props enter already-tuned lighting; verify prop self-shadowing |
| 6 | M9 Phases 5–7 — moon light, moon shadows, eclipses | Night polish tuned against real scenes with props |
| 7 | M10 Phase H+ — gates, 3D avatar | Future milestones |
