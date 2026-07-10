# R2 — Shared-Code Refactor & Optimization Plan

*Drafted 2026-07-10 from a full read of `Mazen_Claude Shared/` (~5,000 lines). Follows the R1 (WorldScale) convention: every step behavior-neutral unless stated, verified before the next.*

**STATUS: DORMANT (Eddie, 2026-07-10).** The backbone is done — Tier 1, R2.8 (Renderer split), R2.11, R2.13, R2.14, R2.16, plus two unplanned wins found along the way (the O(n⁵) startup scan; Metal-4 attachment residency). The remaining items are **trigger-armed, not scheduled**: R2.6→R2.7 fire when iOS/perf gets real; R2.12 folds into M15's movement work; R2.9/R2.10/R2.15 fire opportunistically per their notes. Reopen this doc when a trigger fires.*

**Ratings.** *Confidence* = how certain the change is correct & worth it (High / Med / Low). *Danger* = regression blast radius if done carelessly (None / Low / Med / High). Every item lists its verification.

**Baseline guardrails for the whole plan:** builds clean on both targets, `Tests/run-tests.sh` 7060 green, `roundness == 0` pixel-identical, spot-check roundness 0.5 + a twist + a portal hop.

---

## Tier 1 — high value, low risk (the "M14b cleanup" pass; ~a day, mostly deletion + tests)

*✅ Tier 1 landed 2026-07-10 (commits `f234706`…`e7fdb16`), tests-first as planned. 7,060 → 22,142 checks. Verified: both targets build, r==0 pixel-path covered by tests, FP walk + twist + horse-on-pedestal eyeballed at roundness 0.5, and **Eddie confirmed the orbit player marker + other seated objects look correct** — Tier 1 fully verified, nothing outstanding. (Note: R2.5c bandaging table already existed.)*

- [x] **R2.1 Consolidate the three placement APIs** — `CubeModel` has `worldMatrix` (still carrying the **superseded** M14 per-tile inflation *and* the 9% seam-overlap hack), `restMatrix`, and `inflatedPlacement`. The inflated `worldMatrix` branch now only feeds the fog anchors + orbit player-marker, and the overlap hack scales their bases. Delete the per-tile branch, make `worldMatrix` ≡ `restMatrix`, seat fog/marker via `inflatedPlacement`.
  *Confidence:* **High** (path is superseded; consumers enumerated). *Danger:* **Low–Med** (fog/marker placement changes at roundness > 0 — that's the *point*, but must be eyeballed). *Effort:* small. *Verify:* R2.5a test (rest == flat world) + visual: fog + player marker at 0 and 0.5.

- [x] **R2.2 Deduplicate SceneBuilder `.adjacent` / `.discovered`** — ~40 near-identical lines of instance emission (colors re-declared in both; M14b required editing both in lockstep twice). Extract `emitTileGeometry(...)` with a with-fog flag.
  *Confidence:* **High**. *Danger:* **Low** (pure extraction; expected pixel-identical). *Effort:* small. *Verify:* screenshot diff before/after, both tile states visible.

- [x] **R2.3 One source for the slice-anim matrix** — `SceneBuilder:88`, `Renderer:~697`, `CameraState:119` each rebuild `smoothstep(progress) → rotation` (a comment currently does a function's job). Extract `GameState.currentSliceMatrix() -> float4x4?`. All three already use the same smoothstep, so this is pure consolidation.
  *Confidence:* **High**. *Danger:* **Low** (if one call site were silently different, extraction *reveals* it — that's a win). *Effort:* trivial. *Verify:* twist a slice at normal + `.step` pacing; walls/props/camera stay glued.

- [x] **R2.4 Compute the FP camera pose once per frame** — `viewProjectionMatrix()` / `cameraPosition()` / `cameraUp()` each run the full `firstPersonCamera` (slerp + look quats + `inflatedPlacement`'s 3 finite-difference inflations) plus a fresh `worldSpinMatrix()` — 3× per frame. Cache a `CameraPose` computed once after `gameState.update`.
  *Confidence:* **High**. *Danger:* **Low** — the one trap is *ordering* (pose must be built after update, before uniforms). *Effort:* small. *Verify:* FP walk incl. edge crossing + during a twist; no one-frame lag between view and marker.

- [x] **R2.5 Invariant tests** — (a) `restMatrix` == old flat `worldMatrix` for all faces/cells/sizes; (b) **footprint continuity**: adjacent tiles' shared-edge `inflatedPlacement`s coincide at several roundness values (the seamless-surface property); (c) `canRotateSlice` bandaging truth-table; (d) golden-value test for `inflatedUnitPoint` — honest limitation: it guards the *Swift* side only (MSL twin can't run headless); the golden doubles as the spec both implementations must match.
  *Confidence:* **High**. *Danger:* **None** (additive). *Effort:* small-medium. *Verify:* they run in `run-tests.sh`.

## Tier 2 — bigger wins, worth planning as their own sessions

- [ ] **R2.6 Per-world uniforms instead of per-instance `spinMatrix`** — every instance carries a 64-byte spin identical across its world (~40% of the 168B stride). Replace with `uint worldIndex` into a 2-entry per-world param array (spin, roundness, invHalfExtent). Prereq for R2.7.
  *Confidence:* **High** on the bandwidth win; **Med** on urgency (perf is fine today — this matters for iOS/bigger scenes). *Danger:* **Med** — shader ABI change touching both passes + every instance write; the flat-world "spin baked into modelMatrix" byte-neutral path must be preserved or deliberately retired; counterpart world (which also bakes **scale** into its offset) is the regression hotspot. *Effort:* medium. *Verify:* r==0 pixel-identical; counterpart in sky at correct size/spin; stand on the moon.

- [ ] **R2.7 Dirty-flag the scene rebuild (+ prop-scan cache, + shader-side lamp blink)** — `buildDrawCalls()` rewrites every instance of both worlds every frame; with R2.6 static geometry becomes genuinely static. Rebuild only on: twist active/finalize, discovery animation, portal swap, roundness change, N-reset, world switch. Also cache `updateAssetInstances`' 6×n² prop scan (invalidate on twist finalize/world switch), and move the portalLamp 1.4s pulse into the shader (it currently forces per-frame CPU writes).
  *Confidence:* **Med-High** (the win is real; the risk is enumerating invalidations). *Danger:* **Med-High** — classic cache bug shape: a missed invalidation = stale visuals that *look* like renderer bugs. *Effort:* medium. *Verify:* explicit checklist — twist, scrubbed twist, discovery fog dissolve, portal hop each way, roundness dial, N-key size cycle, world-spin toggle (J), lamp blink.

- [x] **R2.8 Split the Renderer god-object (before M15/M16)** *(landed 2026-07-10 — Renderer 1,160→827 lines; new `PipelineFactory.swift`, `TextureLoader.swift`, `AssetRegistry.swift`, all verbatim moves; both targets build, tests green, visual smoke passed)* — 1,089 lines: pipeline setup, three texture loaders, asset/kit registry + house assembly, world stack, transitions, four draw loops. Extract `PipelineFactory`, `TextureLoader`, `AssetRegistry` (load + stamp); Renderer keeps frame loop + world stack. Mechanical moves only, zero logic change.
  *Confidence:* **High** (structural value before interiors add pipelines/world types). *Danger:* **Med** — big mechanical diff; Metal object creation *order* in init matters; easy to fumble a binding. *Effort:* medium-large. *Verify:* build both targets + full visual smoke (orbit, FP, twist, portal, shadows, HUD).

- [x] **R2.11 Scale-dependent shader constants → FrameUniforms** *(landed 2026-07-10, commit `43e46c8` — builds + 107k tests green; FP anchored to historical values exactly. ✅ Visually confirmed in Eddie's size-25 session ("everything looked great"); the follow-up sky-exemption for the counterpart moon landed after — one FP glance at the moon closes it fully.)* The fragment shader's distance fog runs `smoothstep(4, 14, dist)` in orbit — constants tuned for the size-5 world (orbit cam at 12). At size 7 the orbit camera sits at 16.8, so the **entire cube lies past fogFar** and every pixel blends toward the pale horizon color; `M` looks like the "fix" only because matte returns before the fog block. Same problem family: the orbit-blend `smoothstep(3.0, 5.0, camDist)` (texture swap + fog gate, twice). Fix: derive fog near/far + the orbit-blend threshold from `WorldScale`, passed via `FrameUniforms` — chosen so **in orbit the fog starts beyond the cube's far edge** (full normal textures from orbit at every size) while first-person fog keeps today's values exactly (its depth-cue job is correct there).
  *Confidence:* **High** (root cause read directly from the shader + verified arithmetic). *Danger:* **Low-Med** (visual tuning; FP look must be anchored to today's values). *Effort:* small. *Verify:* orbit at sizes 3/7/9 shows clean textures; FP fog unchanged side-by-side; night + day.

- [x] **R2.16 Cube-size scaling & safety (cap at 25)** *(landed 2026-07-10, commit `3fa845b` — provisioning ×8/tile, hard precondition guard at the write sites, cubeSize clamped to 25 in WorldScale, size-aware cameraFarZ anchored at 220 for ≤10; test suite now runs size 25: 22,142 → 107,366 checks. ✅ Visually confirmed — Eddie ran a full size-25 session (guard quiet, shadows/framing fine); an O(n^5) startup scan found in that run was fixed separately.)* Playable sizes today are 3–9; `WorldScale.maxSupportedSize = 25` **overstates** the real ceiling: instance buffers are provisioned at `6·25·25` = **one instance per tile**, but the scene emits **~4 per tile** (frame rail + floor + path-cross + wall + posts), and SceneBuilder's `ptr[idx] = …` writer has **no bounds check** — beyond roughly size 11–13 that's a *silent buffer overrun*, not an error. The work, in order:
  1. **Provisioning fix + hard guard** — size the instance buffers with a realistic per-tile multiplier (or an exact count), and add a capacity clamp/assert at the write sites so overflow can never be silent again.
  2. **Artificial upper limit of 25** *(Eddie's call)* — clamp `cubeSize` at `maxSupportedSize = 25` at world-creation (`WorldScale`/`resetGame`), so nothing can construct a world the buffers aren't provisioned for. The N-key cycle stays 3→9; 11–25 become *possible* (dev/tests), >25 impossible.
  3. **Shadow-map density** — fixed 2048² over `1.1·size` halves texel density as size doubles; bump resolution or accept softening, verified at 25.
  4. **Size-derived celestials + far plane** — `sunOrbitRadius 176` / `moonOrbitRadius 54.4` / `cameraFarZ 220` are fixed; fine to ~25, but derive them from `cubeSize` (R1-style, anchored to today's values at sizes 3–9) so framing/orbits stay sane at the cap.
  *(The remaining scale wall — per-frame full CPU rebuild — is already tracked as R2.6 + R2.7; not duplicated here.)*
  *Confidence:* **High** (the overrun is arithmetic: 6·13²·~4 > 6·25·25). *Danger:* **Low-Med** — items 1–2 are pure safety; 3–4 are visual tuning that must stay anchored at current sizes. *Effort:* small-medium. *Verify:* tests green (extend size list to include 11/25 for the math suites); run at 11/13/25 with the guard proving no overflow; shadows + sun/moon framing eyeballed at 25; sizes 3–9 pixel-unchanged.

## Tier 3 — opportunistic (do when passing through)

- [ ] **R2.9 Shader micro-work** — drop the redundant `normalize(modelMatrix[0/1])` in `m14bTransform` (×2 passes, hottest path). ⚠️ Rests on an **undocumented invariant**: every roundness>0 instance has an orthonormal basis (scale lives in `spinMatrix` for the counterpart; imported assets carry scale but are roundness==0). Document the invariant where it's relied on. Analytic Cobb-map Jacobian (replaces 2 of 3 inflate evals/vertex) is a separate, fiddlier follow-up — hold until iOS perf demands it.
  *Confidence:* **Med** (correct today; invariant could rot). *Danger:* **Med** (silent wrong-normals if violated later). *Effort:* trivial + comment. *Verify:* pixel-diff at 0.5; grep-able invariant comment.

- [ ] **R2.10 Floor UV-turn mesh dedup** — the 4 baked UV-turn floor variants differ only in texCoords; a 2-bit per-instance `uvTurns` + shader UV rotation cuts floor meshes 4×. (Collapsing the 81 wall configs → 8 per-edge meshes trades verts for instances; only if mesh memory ever matters.)
  *Confidence:* **Med-High**. *Danger:* **Med** — the shader rotation must exactly reproduce baked UVs *through slice finalization* (the `uvTurns` carry logic) or floors visibly "snap" after a twist. *Effort:* medium. *Verify:* twist a slice repeatedly; floor texture stays glued.

- **R2.11** — *moved to Tier 2 (2026-07-10): confirmed as the orbit "silver veil"; see above.*

- [ ] **R2.12 PlayerState as a real state machine** — 14 parallel fields (`moveFrom…`×5, `moveTo…`×5, flags) → enum with associated values (`idle / moving / turning`); makes illegal states unrepresentable and shrinks `firstPersonCamera` branching.
  *Confidence:* **Med** (readability, not perf). *Danger:* **Med** — movement + camera interpolation regressions read as motion glitches. *Effort:* medium. *Verify:* FP walk, turn, edge-cross, held-key chaining, move-during-twist refusal.

- [x] **R2.13 Force-unwrap hygiene** *(landed 2026-07-10 — faceColors dict+`!` → total switch; `worldStack.last!` invariant documented)* — `Self.faceColors[face]!` per tile per frame → `switch`/array; document the `worldStack.last!` never-empty invariant. *Confidence:* **High**. *Danger:* **Low**. *Effort:* trivial.

- [x] **R2.14 Doc drift** *(landed 2026-07-10 — CelestialSystem farZ comment + roadmap M14/M14b/R2 statuses synced)* — `CelestialSystem.swift:10` says "cameraFarZ = 100" (it's 220); Master Roadmap M14/M14b entries still read "uncommitted"/"planned". *Confidence:* **High**. *Danger:* **None**. *Effort:* trivial.

- [ ] **R2.15 Async asset loading** — 9 USD/OBJ models load synchronously in Renderer init; `needsDecorativeStamp` already supports late stamping. Only if launch time becomes a complaint.
  *Confidence:* **Med** (speculative benefit). *Danger:* **Med** (threading + first-frame races). *Effort:* medium. **Deferred by default.**

---

## Sequencing

1. ~~**Now-ish:** Tier 1 as one "R2 cleanup" pass (R2.5 tests land *first* so R2.1 is caught by them).~~ ✅ **Done 2026-07-10, fully verified.**
2. ~~**Next up:** **R2.11** + **R2.16**.~~ ✅ **Landed 2026-07-10** (commits `3fa845b`, `43e46c8`); two visual confirms outstanding — see the ⚠️ notes on each item.
3. **Before M15:** R2.8 (Renderer split) — interiors will pile more onto it.
4. **When iOS/perf gets real:** R2.6 → R2.7 together.
5. **Tier 3:** fold into whatever session touches that file anyway. R2.14 anytime.
