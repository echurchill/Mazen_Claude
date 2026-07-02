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
