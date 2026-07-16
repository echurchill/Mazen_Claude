# M14b — Curved Geometry (per-vertex tessellated superellipsoid inflation)

*Status: **IMPLEMENTED (Phases 0–4), committed, visually verified** (2026-07-09). Remaining = polish/authoring only: per-world authored roundness, sunrise/sunset terminator tuning, optional frame-rail/fog on the surface path. Supersedes the M14 first pass's per-tile inflation. Roadmap: [Master Roadmap](../Master%20Roadmap.md) §6. Design context: [Design Synthesis](../Garden%20of%20Worlds%20—%20Design%20Synthesis.md) (shape-as-meaning), [Superellipsoid Cube](../Superellipsoid%20Cube.md).*

## Why this milestone exists (the problem M14 exposed)

The M14 first pass inflates the cube **per-tile**: `CubeModel.worldMatrix` remaps each tile's *center* onto a cube→sphere surface and rebuilds a rigid basis, so each whole tile *tilts* to be tangent to the sphere. A single 4×4 transform per tile has no interior vertices, so it can **tilt but never bend**. Tall hedge walls are levers: on a convex surface, adjacent tiles' normals converge, so neighbouring hedge-tops lean together, **merge (~roundness 0.1–0.2), then cross — visually swapping places.** That corrupts maze legibility (walls that lie about the layout), so capping roundness low is *not* an option — even 0.1 breaks. And the natural worlds are load-bearing: the whole arc is *natural surface → twist open → engineered truth beneath*; if natural worlds read as broken geometry, every reveal's setup collapses.

**Fix:** subdivide the geometry and project the new vertices onto the curved surface per-vertex — so floors bow smoothly and walls' bases ride the curved floor while standing up along the local normal.

## Core technique

Tessellate floor + wall meshes so they have interior vertices, then inflate **per-vertex in the vertex shader**, in the cube's axis-aligned **rest frame**, *before* world-spin/twist. The wall insight that avoids degeneracy: **never push a raised vertex through the cube→sphere map** (points above the surface break the `√` map). Instead — per vertex:

1. `footFlat = M·(x, y, 0)` — the vertex's footprint on the flat cube face (`M` = flat placement matrix).
2. `h = z` — height above the face (basis is unit-length, so local z = world height).
3. `surf = inflate(footFlat / H, r) · H` — inflated footprint (`H` = cube half-extent, `r` = this world's roundness; `inflate` is the shader port of `CubeModel.inflatedUnitPoint`, identity at `r==0`).
4. Inflated local frame at `surf` by finite differences (mirrors the existing CPU code): `right`, `up`, `nInf` (outward normal).
5. `posPreSpin = surf + nInf · h` — extrude straight up along the curved normal.
6. `worldPos = spin · posPreSpin`. Normals rotated into `(right, up, nInf)` then by `spin`.

Because adjacent tiles share footprints exactly (`cellSpacing == 1`: tile A's east edge and tile B's west edge map to the *same* cube point), `surf` and the frame match across the seam → **zero gap, no lighting seam.** The M14 `1 + 0.09·roundness` overlap hack retires.

`roundness == 0` is a byte-exact fast path: bake `spin` into `M` as today, pass `spin = identity`, and the shader reduces to `M·position` — pixel-identical, the 7060 headless tests (which only exercise CubeModel grid math, never `worldMatrix`/shaders) stay green by construction.

## Per-world parameters — the sky-world requirement

Sky-worlds (the "counterpart" hanging in the sky) must inflate with **their own** roundness, different from the active world, in the *same frame* — a round moon over a round Earth, and a hard-cubic / sphere-in-cube world overhead to **foreshadow** a mech/hybrid world before the player travels there. Since both worlds share one `FrameUniforms`, roundness **cannot** be a single per-frame scalar.

**Decision (recommended): carry `spinMatrix` + `roundness` + `invHalfExtent` per-instance in `InstanceData`.** One uniform mechanism, one shader path; it handles both the two-world split *and* the intra-world heterogeneity that a per-world uniform can't:
- maze surface → `spin = worldSpin`, `roundness = world.roundness` (inflate);
- props / posts / fog → `spin = worldSpin`, `roundness = 0` (rigid, but riding the curved surface via their inflated `worldMatrix` anchor);
- celestials (sun/moon/portal-lamp, materialID 12/13) → `spin = identity`, `roundness = 0` (world-frame, as today);
- counterpart world → every instance carries *its own* `spin/roundness/invHalfExtent`. Two worlds coexist for free.

Cost: per-instance duplication of `spin` (mitigable later via a `worldIndex` into a tiny per-world array — same shader interface). Fallback if rejected: FrameUniforms + a second counterpart uniform buffer + a per-instance `transformMode` selector (strictly more moving parts).

## Phases (each independently verifiable via the `M` matte view)

- **Phase 0 — uint32 index migration (prerequisite).** The maze mesh shares one vertex buffer with **16-bit** indices (65,535 ceiling; ~20k today, tessellation pushes it over). Convert `TileMeshLibrary` `[UInt16]`→`[UInt32]` + the four maze draw sites in `Renderer` (the imported-asset path already proves the uint32 pattern). No visual change. *Verify:* both targets build, `Tests/run-tests.sh` stays 7060 green, flat world pixel-identical.
- **Phase 1 — floors tessellate + inflate.** Add per-instance params; add `CubeModel.restMatrix` (factor the flat branch out; keep `worldMatrix` inflating for the camera path); move `spin` out of `modelMatrix`; tessellate `addFloorCells` (~6×6/tile); implement `inflate`/FD-frame/`restToWorld` in the scene **and** shadow vertex shaders. Walls still rigid (they'll tilt — expected). *Verify:* `r==0` pixel-identical; at `r=0.3/0.6` matte, floor is a smooth curved sheet, no inter-tile gaps/seams; shadows track it.
- **Phase 2 — walls tessellate + inflate (the core fix).** Tessellate `addWall` inner/outer/caps (`Lw×Hw`, height dominates — start 2×4); side normals rotated by the inflated frame; AO ramp; land the fragment **TBN-from-VS-tangent** fix (the dominant-axis TBN breaks on a curved surface). *Verify:* on a convex face at `r=0.1–0.3`, adjacent hedge-tops **bend apart, no longer merge/cross**; continuous curved hedges; seam-free normal-mapped lighting. Diff against a pre-M14b screenshot to show the swap gone.
- **Phase 3 — camera/player ride the curve.** Reconcile `CameraState`/`PlayerState` sampling with the shader surface (sample `inflate`+frame at the player footprint, not just tile center). *Verify:* walk a convex face in FP at `r=0.4`; horizon curves, eye stays glued across tile/gateway boundaries, no pop.
- **Phase 4 — sky-world signaling + tuning/perf.** Confirm the counterpart inflates by its own roundness (round moon; cubic sky world for mech foreshadowing); tune tessellation density, AO ramp, shadow bias; GPU-profile at cube size 9. *Verify:* frame capture within budget; one frame showing the sky world at a *different* roundness than the active world.

## Integration risks / edge cases (from the code read)

- **Fragment TBN (`Shaders.metal` ~250–260) will break** under curving (dominant-axis selection flips mid-surface). Fix in Phase 2: pass the inflated tangent from the VS via `VertexOut`, build TBN in the fragment. Cleans up the flat case too.
- **AO** interpolates fine post-tessellation; new verts must reproduce the base/upper wall rule (`0.55`→`1.0`) as a smooth ramp over the height rows.
- **Height-keyed effects** (moss blend, wall-base darkening, floor edge darkening) use `localPosition` = pre-inflation local coords → unchanged, keep working.
- **Everything attached to the surface must ride the curve, not just the floor.** Confirmed visually at roundness 0.5: geometry placed on each tile's *flat tangent plane* (posts, props/decorations — obelisks, chests, topiary, house, portal) pokes up out of / sinks into the curved floor as it moves off the tile center. **Floor + paved path-cross floor already inflate.** **Walls + posts** move to the inflation path in Phase 2 (footprint + extrude). **Props/decorations** are a dedicated follow-up (Phase 2.5): they carry sub-cell offsets + their own local transforms, so each anchor must be projected onto the curve and oriented to the local normal, and sub-cell-offset props must sample the curve at their offset footprint — not just the tile center.
- **Frame rail (id 7), fog (4/5)** stay rigid (`roundness=0`) on their inflated anchor for now; promote to the surface path if they read wrong at the chosen roundness.
- **Distance fog & day/night** consume the final inflated world position → work unchanged (terminator actually smoother on a rounder surface).
- **Shadow bias** may need a small bump on steep curved wall faces.
- **iOS parity** free — shaders + `InstanceData` are shared; rebuild both targets.
- **`buildSingleTile` debug path** — set its instances `roundness=0`, `spin=identity`.

## Lighting — sunrise/sunset on the curved surface (a story requirement)

Sunrise and sunset are narrative beats; the curved surface is exactly where that light reads or fails, so lighting is a first-class M14b concern, not an afterthought.

**Served automatically by the per-vertex work:**
- True per-vertex surface normals (`nInf`) replace the flat cube's crude face normal, so the **day/night terminator becomes a smooth band sweeping the curved world** (a real planetary terminator) instead of snapping at face seams; Lambert/half-Lambert now respond to genuine curvature, so low raking sun behaves.
- The shadow pass shares the inflation → **long dawn/dusk shadows follow the curved ground and the bent hedges.**
- The Phase-2 VS-supplied tangent (TBN fix) lets normal-mapped surface detail catch grazing light without swimming.

**Needs deliberate design (not automatic):**
- **Warm/reddened low-angle surface light.** Today `sunColor` is a fixed warm-white scaled only by `dayFactor` (`Shaders.metal:196`); the *sky* reddens at sunset (`:96-99`) but the *ground* doesn't. Warm/redden the surface sun term as the sun nears the horizon (drive off `sunElevation`), matched to the sky's sunset band.
- **Don't let the noon-washout fix flatten sunset drama.** The M14-pass sun-softening (`0.75 → 0.55`, `Shaders.metal:288`) tames noon clipping; verify it still leaves punch for a dramatic low sun — likely the sun term should *rise again* at grazing angles (a warmth/rim boost) rather than a flat reduction.
- **Terminator width retune.** The `smoothstep(-0.22, 0.22, …)` band (`:192`) was tuned on a cube; on a rounder surface it may want widening/retuning so dawn/dusk sweeps gracefully.
- The **moon** matters too (lesser): the cool moon fill (`:202`) rakes the night side and should read believably across the curve.

**Acceptance test (add to Phase 2 & Phase 4 verification):** freeze the sun near the horizon (`Shift+T` sets noon — add a low-sun debug pose or scrub time) and advance time slowly; confirm the terminator sweeps smoothly across the curved surface, low sun rakes **warm** across floors and bent hedges, and dawn/dusk long shadows track the curve. A named beat, not "looks fine."

## Open decisions for the human

1. **Confirm the per-instance parameter carrier** (recommended) vs. the FrameUniforms + second-buffer + `transformMode` fallback. *(Engineering call; recommend per-instance.)*
2. **Shape parameterization / future hybrid.** Ship the plain cube→sphere **blend scalar** now, but type the shader's shape input as a small **descriptor** (exponent + frame-preservation weight) so the hybrid "sphere-baked-in-a-cube-frame" look — likely a *frame/edge* treatment (keep the rail hard while the interior rounds) more than one exponent — is a later phase, not a schema change. *(Design-facing — ties to sky-world foreshadowing.)*
3. **Tessellation density** `Mf/Lw/Hw` — start `2/2/4`, tune in Phase 4.
4. **Posts/frame/fog fidelity at extreme roundness** — accept rigid for M14b, or promote in Phase 4?
5. **Drop the M14 seam-overlap hack** for the per-vertex surface (seams close exactly) — retain only in the rigid `worldMatrix` if a residual camera/prop gap appears.

## Critical files
- `Mazen_Claude Shared/TileMeshLibrary.swift` — tessellate `addFloorCells` (267–304) & `addWall` (321–435); uint32 migration (204–216, drop the pad at 96–98).
- `Mazen_Claude Shared/Shaders.metal` — `vertexShader` (136–167) & `shadowVertexShader` (108–119) per-vertex inflation; fragment TBN fix (250–260).
- `Mazen_Claude Shared/ShaderTypes.h` — add `spinMatrix`/`roundness`/`invHalfExtent` to `InstanceData` (48–56).
- `Mazen_Claude Shared/SceneBuilder.swift` — stop baking `spin` (73, 108, 251); write per-world params; `restMatrix` for surface, inflated `worldMatrix` for props.
- `Mazen_Claude Shared/CubeModel.swift` — add `restMatrix` (factor 363–369); keep `worldMatrix`/`inflatedUnitPoint` as the camera path + shader reference.
- `Mazen_Claude Shared/Renderer.swift` — uint32 index type at the four maze draw sites (877–879, 951–953, 989–991, 1007–1009).
- Phase 3 (secondary): `CameraState.swift` (63–139), `PlayerState.swift`.

## Relationship to the M14 first pass (currently uncommitted)
The M14 render-only work in the tree — per-world `roundness` on `CubeModel`, the `M` **matte-debug toggle** (keep: essential for verifying curvature), the **sun-softening** in the maze material (keep), and the **seam-overlap** hack (retire in Phase 1) — is behavior-neutral at `roundness==0`, builds clean, 7060 tests pass. Decide whether to land the keepers first or fold everything into M14b Phase 1.
