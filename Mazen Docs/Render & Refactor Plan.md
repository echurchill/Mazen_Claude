# Render & Refactor Plan

**Status (2026-08-03): Tier 1 (B4, B1, B2) and Tier 2 (A1, A2) are BUILT. A4 was measured out —
after A1 the shadow pass costs nothing measurable (10.58 vs 10.58 ms with it ablated), so there is
nothing for an update-rate scheme to save. A3 is HELD at Eddie's direction. Results: Scene 2
Release orbit 13.2 → 10.5 ms (76 → 95 fps); first person 98–100. Thresholds were calibrated from a
measured size histogram (the first guess was 8× off and matched nothing — the counter reading zero
is what caught it). Awaiting Eddie's eyes: missing shadows under ~3 m scatter, and LOD popping
while zooming.**

*Analysis only — nothing here is built. Written 2026-08-03 after a code survey plus the measured
numbers from the `MAZEN_BENCH` work. Each item carries a **gate**: the measurement that decides
whether it ships, because two of this month's perf beliefs ("fill-bound", "36→70 fps") turned out
to be artifacts of measuring the wrong thing.*

## The baseline (measured, Release, 2026-08-01→03)

| fact | number |
|---|---|
| Scene 2 (11³, the heaviest world), orbit | ~12–13 ms (77–87 fps) |
| Scene 2, first person | 10 ms — the vsync floor |
| CPU per frame, Release | 0.5–2 ms (the CPU is **not** the wall) |
| The GPU wall, by ablation | imported-prop geometry, drawn in BOTH passes |
| — main pass, assets off | 21 → 10 ms |
| — shadow pass, assets off | 21 → 15.7 ms |
| — maze on/off, either pass | no change (the maze is nearly free) |
| Asset instances after culling | ~8.7–9.6k of ~19.9k (orbit), ~4k (FP) |
| Draw calls / encode time | ~150–250 / 0.1–0.2 ms (not the wall) |
| Shadow map | 2048², redrawn in full every frame |
| MSAA | 4× at full window resolution |

**The one sentence that matters: the render cost IS the imported props, twice.** Everything else
is small against them, so graphics work that doesn't reduce prop cost is polish.

---

## Workstream A — graphics (in priority order)

### A1. Shadow-caster subset — the cheapest big win
Every culled-in prop casts into the 2048 map every frame: a grass card at 40 units contributes
invisible texels at real vertex cost. The ablation says the shadow pass carries ~5 ms of asset
geometry.

- **Change:** at pack time (where culling already runs), mark instances whose *projected size* in
  the shadow map is below a threshold as non-casters; the shadow pass draws only casters. Grass,
  flowers, pebbles, cables stop casting; walls, trees, platforms keep.
- **Gate:** Scene 2 orbit ≤ 10 ms in Release **and** no visible shadow loss Eddie can spot at
  ground level. `MAZEN_BENCH_ABLATE=shadowassets` already isolates the number.
- **Risk:** low. It reuses the existing pack-time path and the bench proves it.

### A2. Distance/size LOD for props — the other half of the same coin
The main pass still draws ~9k instances in orbit, most of them ground scatter whose projected size
is a few pixels.

- **Change:** same pack-time test, main pass: below a projected-size threshold, drop small
  *scatter* props (grass, flowers, pebbles) entirely; medium things (bushes, rocks) drop at a
  farther threshold; structure (walls, platforms, obelisks) never drops. No mesh LODs needed —
  this pack's models are already low-poly; the win is instance count, not triangle density.
- **Gate:** orbit ≥ 90 fps on Scene 2 with no popping Eddie notices while zooming. The cull
  margin lesson applies: the threshold must be *hysteretic* (drop farther than re-appear) or
  zooming will shimmer.
- **Risk:** medium — visible if tuned wrong. Ship behind `MAZEN_BENCH_ABLATE=lod` first.

### A3. Cache the maze tile instances the way the asset path already is
`SceneBuilder.build` rebuilds every tile instance from scratch each frame, and the counterpart
world hanging in the sky doubles that. The asset path got its rest-frame cache in the 36→70 work;
the tile path never did. In Release this is only ~0.3–1.3 ms — **this is an iOS-headroom and
counterpart win, not a Mac fps win**, and it is also what makes the fog/discovery path cheaper.

- **Change:** same token pattern (`topologyVersion`, discovery epoch, twist-in-flight), spin
  applied at pack. The discovery animation writes `discoveryAmount` per frame — that field must
  live outside the cached part or be patched in, which is the fiddly bit.
- **Gate:** identical frame output (the bench's draws/instances counters must not change), CPU
  build time halves in Debug.
- **Risk:** medium — cache-invalidation bugs here look like "world doesn't update". The existing
  cache-invalidation tests cover the asset path; this needs the mirror tests first.

### A4. Shadow map update rate
With Shift+T noon-lock the sun does not move, yet the map redraws at full rate; in normal play the
sun moves slowly. Update the shadow map only when (sun direction delta > ε) OR (topology/twist
changed) OR (any caster moved). Under noon-lock that is ~never; in play it is a few times a second.
- **Gate:** ablation shows the shadow pass cost approaching zero in steady state; no visible
  shadow lag during a twist (twist forces an update, so there should be none).
- **Risk:** low-medium. Interacts with A1; do after it.

### A5. Measure-first items (no work until a number says so)
- **MSAA 4× and resolution scaling.** On Apple TBDR GPUs 4× MSAA is cheap in tile memory, so this
  is probably *not* the win it would be on desktop — but no one has measured 2× vs 4× here. One
  bench run each; keep 4× unless the delta is real. iOS may want a render-scale dial regardless.
- **Fog overdraw.** `dissolveTiles` stacks several translucent layers per fogged tile. Only Scene
  1-adjacent worlds fog now; bench a fogged world before touching it.
- **The über-shader.** 31 `materialID` branches in one fragment function. Branches are coherent
  per-draw (buckets are material-keyed) so divergence is fine, but register pressure may cap
  occupancy. Measure with Metal's shader profiler before splitting anything; if it matters, split
  the 3–4 heavy materials (25 plating, 32 patchwork, 33 channels, sky) into their own pipelines.

### What NOT to do
- **No depth pre-pass** — TBDR already gives hidden-surface removal for opaque.
- **No texture atlasing** — the props are flat-`Kd`; there is almost nothing to atlas.
- **No indirect command buffers / GPU-driven culling yet** — encode is 0.2 ms; the CPU cull is
  effectively free in Release. Complexity with no measured payer.
- **No merging static props into baked meshes** — it breaks the "props ride their tile through a
  twist" property that the whole game rests on, for a win A1+A2 get more safely.

---

## Workstream B — refactoring (enables A, and pays down the month's growth)

### B1. Split `Renderer.swift` (2,078 lines)
It currently owns: device/pipeline setup, the world stack and graph resolution, per-frame uniforms,
asset instancing + culling + cache, the bench instrumentation, audio driving, and draw encoding.
Proposed split, no behaviour change:
- `Renderer.swift` — frame loop and encoding only
- `WorldStack.swift` — buildWorld, portal swap, transitions, registry binding (the Scene 6
  resolution logic lives here)
- `AssetInstancer.swift` — buckets, cache token, culling, `CullFrustum` (A1/A2 land here)
- `RenderBench.swift` — every `bench*` counter and `MAZEN_BENCH*` path, so instrument noise
  stops obscuring the frame code (all of it behind one `#if DEBUG`-able type)

### B2. Split `CubeModel.swift` (4,098 lines)
The model core is maybe 1,200 lines; the rest is per-scene stamps. Move each scene's stamp +
helpers into `Stamps/SceneOne.swift` … `Stamps/SceneSix.swift` as extensions. The test harness
compile list grows by six files — update `run-tests.sh` in the same commit or the suite silently
tests stale code (it takes a file list, it does not glob).

### B3. A prop-iteration utility
The codebase has ~15 hand-rolled triple-nested loops of the shape "for every facelet, for every
prop where kind == X". Each is 8–12 lines; several have had off-by-subtlety bugs (the vessel-count
test, the exit-search). One utility on `CubeModel`:
`forEachProp(ofKind:)`, `tiles(with:)`, `firstProp(ofKind:)` — then migrate call sites
mechanically. The tests already grew their own copies of these helpers; the model should own them.

### B4. Finish the `WorldCatalog` migration
`Renderer.portalDestinations` / `destinationLabels` / `prologueDestinationIDs` are now aliases of
`WorldCatalog`. Migrate call sites to reference `WorldCatalog` directly and delete the aliases —
two names for the same table is how the label drift happened in the first place.

### B5. `GameState.swift` (1,989 lines): extract per-scene systems
Scene 5's pulse/circuit and Scene 3's chamber are self-contained systems (fields + tick + queries)
living inline. Extract `ChannelCircuit` and `ChamberSystem` types owned by GameState. This is the
lowest-priority split — do it when Scene 6's systems would otherwise pile into the same file.

### Refactoring rules (from this month's scars)
- Every move is a *move*, verified by the suite at 249,979 checks and both platform builds.
- No behaviour change rides along with a file split. Ever. Separate commits.
- The bench runs before and after each phase; draws/instances counters must be identical.

---

## Sequencing

1. **B1 + B4** (mechanical, unblocks A-work landing in clean files)
2. **A1** shadow-caster subset → gate → **A2** LOD with hysteresis → gate
3. **B3** prop utility (touches many files; nicer after the splits)
4. **A3** tile-instance cache (write the mirror invalidation tests first)
5. **A4** shadow update rate
6. **B2** stamp split, **B5** scene systems — background work, any time
7. **A5** only if its measurements say so

Rough shape: A1+A2 are the fps items and are small; B1/B2 are a day of careful moving; A3 is the
one with real regression risk and goes behind its tests.
