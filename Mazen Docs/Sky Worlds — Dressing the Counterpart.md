# Sky Worlds — Dressing the Counterpart (scope)

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
