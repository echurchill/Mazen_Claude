# Sky Worlds — Dressing the Counterpart

**BUILT 2026-08-06.** Results at the bottom; two of the five predictions below were wrong in ways
only measuring caught.

*Scoped 2026-08-06, from Eddie's observation: "the worlds in the sky have been becoming
increasingly LESS detailed. Which really kind of takes away from the story you described." He is
right, and the cause is structural rather than a slow slide in quality.*

---

## The gap

The world hanging in your sky is **the real world, rendered for real** — that is the M11 killer
visual, and the reason it persists with every twist baked in. But it is rendered by exactly one
call: a second `sceneBuilder.build(...)` into `counterpartInstanceBuffers`, pushed out by an
orbital offset (`Renderer.buildDrawCalls`).

**Imported models do not go through `SceneBuilder`.** They go through `updateAssetInstances()`,
which reads `gameState` — the *active* world — and nothing else. So no sky world has ever shown a
single imported prop: no portal frames, no Ruins wall pieces, no Nature/MegaKit vegetation, no
Cyberpunk machinery, no statues, no house.

That is why it has been getting **worse over time** rather than being a constant. Every world we
dressed with imported models moved that world's detail out of the only path the sky can see. Sky
worlds did not degrade; the ground worlds pulled ahead.

The sharpest case is the garden. A world with `wallStyle == .dressed` has its **hedge mesh
suppressed** in `SceneBuilder` — the walls are *only* imported Ruins pieces, emitted per closed
edge by the asset pass. So the garden overhead has **no walls at all**: a maze world rendered as a
bare plate.

This undercuts the premise. The point of the counterpart is "that is the real place, with your
twists in it." A stripped-down cousin reads as decoration, which is precisely what it was built not
to be.

---

## The shape of the fix

`SceneBuilder.build` already takes a `worldOffset` and folds it into the spin — *one* injection
point for a whole world. The asset pass needs the same treatment:

```swift
// today
func updateAssetInstances()                       // implicitly: gameState, assetInstanceBuffers
// scoped
func updateAssetInstances(for world: GameState,
                          offset: float4x4 = .identity,
                          into buffer: MTLBuffer,
                          cache: inout AssetBucketCache,
                          castsShadows: Bool) -> [AssetDrawCmd]
```

`updateAssetInstances` reads `gameState` in about a dozen places (`worldScale`, `worldSpinMatrix`,
`cubeModel`, `sliceRotation`, `camera.mode`, `name`, the four surveyor fields). All become the
parameter. The offset folds into `spin` at the single line that already computes it — symmetric
with `SceneBuilder`, and for the same reason.

**No work needed on scale or roundness.** Imported assets bake spin into their model matrix on the
CPU and sit at `roundness == 0` (they seat on the curve via `inflatedPlacement`), so the offset
injection is the whole story.

---

## Work items

1. **Parameterize the asset pass** (above). Mechanical, but touches the hottest function in the
   renderer.

2. **The bucket cache must become per-world.** `assetBuckets`, `lodShown` and `assetCacheToken` are
   single-instance. Two worlds sharing them means a **full rebuild every frame for both** — which is
   exactly the 18-of-28 ms regression the cache was built to kill. `AssetCacheToken` already carries
   `ObjectIdentifier(world)`, so this is a dictionary of caches rather than new logic. **Must evict**
   when a world leaves the stack and the sky, or every world ever visited keeps a bucket set alive.

3. **A second buffer set + residency.** Mirror `counterpartInstanceBuffers`: allocate, add to
   `resDesc.initialCapacity`, insert into the residency set, and bind it around the counterpart's
   asset draws the way the maze draws already rebind. Size is an open question — see LOD below.

4. **Cull correctness — the real trap.** The horizon cull inverts the *active* world's spin to get
   `cullEye` and compares it against the *active* world's `ws.faceDistance`. Pointed at an offset
   world, both are meaningless. **This is the exact family that emptied the first-person view and
   produced the corner invisible walls** — a cull gate applied across a boundary it was not designed
   for, twice. Recommendation: the counterpart gets **frustum cull only, horizon cull off**, stated
   in a comment rather than left to be rediscovered.

5. **LOD is an asset here, not a hazard.** `lodDropRatio` is 110 and the sky world sits tens of units
   away, so everything under `lodMaxSize` (0.16 ≈ 3 m — grass, flowers, pebbles, cables) drops out
   and structure stays: walls, trees, platforms, arches. That is the right silhouette for a world
   seen from orbit *and* it means the counterpart's buffer can be far smaller than the active 32,768.
   **Measure it; do not assume it.** A dressed 11³ overhead asks for ~19,944 instances before LOD.

6. **Shadows: excluded, deliberately.** `assetDrawCmds` feed the shadow pass. The counterpart must
   not cast into the active world's shadow map — it is not in that world. Counterpart asset commands
   get `casterCount: 0` and never enter the shadow list. (Its maze geometry already doesn't.)

7. **The surveyor and any future dynamic prop.** Drawn outside the bucket cache, appended fresh each
   frame from `gameState`. v1: **skip for the counterpart** — one machine on a world hundreds of
   metres away is invisible. Revisit only if a scene ever wants a visible moving thing overhead.

---

## Cost, honestly

Measured (Debug, `MAZEN_BENCH`, so roughly 10× a Release figure):

| standing in | overhead | counterpart build | frame |
|---|---|---|---|
| scene-4 (5³) | scene-2 (11³) | 1.62 ms | 10.68 ms |
| scene-5 (7³) | scene-4 (5³) | 0.40 ms | 10.33 ms |

Adding the asset pass roughly **doubles** what a sky world costs before LOD, and for a *dressed*
world it is more than double, because there the walls **are** the assets. After LOD it should be
much less, but that number does not exist yet.

The mitigation is already written down as R2.6 → R2.7 (per-world uniforms, then dirty-flagged
rebuilds), and this feature makes it worth doing rather than merely available: **a sky world is the
ideal cache candidate, because it only changes when somebody twists it.** Recommended order is still
correctness first, then measure, then decide — optimising a path whose cost you have not seen is how
the last three perf theories went wrong.

---

## Verification

- **The bench already reports it**: `counterpart build %.2f ms` (`RendererBench`). Take before/after
  on `scene-4` (11³ overhead — the worst case in the game) and `scene-5`.
- **The suite will not catch anything here.** `Renderer` is not compiled by the test harness, which
  is the standing reason policy keeps moving out of it (`singleInstanceNames`, `WorldCatalog`). If
  any *decision* falls out of this — which world is the counterpart, when horizon cull applies — it
  should land in a pure function where a test can reach it.
- **Eddie's eyes for the result**, which is the entire point of the work: does the garden overhead
  read as the place he just walked out of?

## Effort

About one session for items 1–4 and 6–7 with the usual gates (build both platforms, suite, validated
boot), plus a measurement pass for item 5. It touches no model code and no gameplay, so the risk is
concentrated in the renderer's hottest function and in cache lifetime — not in anything the puzzle
suite protects.


---

## Built — what actually happened (2026-08-06)

All seven items landed. Two predictions in the scope above were **wrong**, both about LOD, and both
would have shipped a feature that quietly did nothing.

### 1. "LOD is an asset here, not a hazard" — wrong, it dropped every single prop

First measurement after the plumbing worked: `counterpart: build 1.81 ms + props 4.23 ms,
**0 prop instances overhead**`. The pass ran, built its buckets, spent the time — and packed
nothing.

The distance-ratio LOD test (`distance ÷ worldSize` vs 110) is the wrong instrument for a sky
world. The counterpart is drawn *scaled down to the moon's apparent size* and tens of units away, so
every prop on it is "sub-pixel" by that measure. Individually true; collectively nonsense, because a
maze's walls **are** its silhouette. The test was dropping exactly the thing the feature exists to
show, and it would have looked like success — a green build, no errors, no props.

Fixed by filtering the sky world on **intrinsic** size instead: divide the orbital scale back out
and keep anything above the same 0.16 threshold. Structure stays (walls, trees, platforms, arches),
scatter goes (grass, flowers, pebbles, cables). No hysteresis — there is no boundary to shimmer
across when the test no longer depends on distance.

### 2. "The counterpart's buffer can be far smaller" — wrong, and dangerous

Sized at 8,192 on that reasoning. Measured demand for a dressed 11³ overhead: **12,262 instances
after the scatter is filtered out**, because its walls are all imported and walls are precisely what
must survive. Raised to 32,768, matching the active world. Guessing small would have clamped the sky
silently — the same failure this whole change exists to undo.

### 3. A free win the scope missed: the sky world is usually off-screen

With the counterpart out of frame, the props pass still cost **4.2 ms a frame** testing ~19,000
instances against the frustum one at a time, for a world nobody could see. One bounding-sphere test
against the frustum now answers for all of them, and that case costs **0.00 ms**. The sphere is the
world's corner radius (`faceDistance·√3`) times the orbital scale, deliberately generous — culling a
sky world that *is* visible would reproduce the exact bug being fixed.

### Measured cost (Debug, ~10x Release)

| case | counterpart build | counterpart props | frame |
|---|---|---|---|
| scene-4, sky off-screen | 1.66 ms | **0.00 ms** | 10.49 ms |
| scene-4, sky fully in frame (`ABLATE=cull`) | 1.67 ms | 8.63 ms | — |

The second row is a deliberate worst case: an 11³ dressed world overhead, entirely in frame, with
frustum culling disabled outright. Real viewing sits between the two. If it ever bites, R2.6 → R2.7
is the answer, and a sky world is the ideal cache candidate because it only changes when somebody
twists it.

### Verification

- Both platforms build; suite green at 249,954 checks (it exercises none of this — `Renderer` is not
  in the harness, as ever).
- `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1` boot with the sky props forced through: clean, runs to
  `BENCH done`.
- **`MAZEN_BENCH_ABLATE=cull` deliberately reaches the off-screen early-out**, because that lever is
  the only way to force the sky world's props through the whole pipeline headlessly — the bench
  camera never happens to face the moon. Without that, the feature is unverifiable without eyes.
- **Not verified: how it looks.** That is Eddie's, and it is the entire point.
