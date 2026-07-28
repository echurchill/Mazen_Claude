# Prologue Build Plan — Scenes 1–4

*Build order and work breakdown for the four-scene prototype. Sizing is relative (S/M/L), not
time-based. "Reused" means shipped code that works today, unchanged.*

**Build order: Phase 0 → Scene 2 → Scene 4 → Scene 3 → Scene 1**

Rationale: Scene 2 and Scene 4 are mostly assembly of proven parts, so they produce a playable
vertical slice fastest and de-risk the set's best trick (the hidden face rotating into view).
Scene 3 carries the most new tech and the only real performance risk. Scene 1 is the most
art-dependent and least mechanically novel, so it benefits from being authored last, when the
visual language is settled.

---

## Phase 0 — Foundation (do first, ~half a day)

Small, invisible, and unblocks everything after it.

| Work | Size | Why now |
|---|---|---|
| **Portal transitions as explicit data** (`push` / `pop` / `goto` per portal) replacing the hardcoded `nestedEnter` / `hubEnter` name-matching | S | Two special cases already exist for four worlds. Six scenes add more, and Scene 6's return to Scene 2 is inexpressible without it. Behaviour-neutral today. |
| **Per-world twist gating** (`GameState.twistEnabled`) | S | Scenes 1–3 specify "twist disabled"; Q/E is currently always live. |
| **Arrival route recorded on the world** (`lastArrivalOrigin`) | S | Scene 6's orb reacts to it. One field, no consumer yet. |
| **New scene worlds registered, old worlds left in place** | S | Append to `portalDestinations` — never insert (portal props store an index into it). |

Retire the old worlds only once the new chain stands on its own; `prototype-v1` is tagged, so
retiring means deleting, not archiving.

---

## Scene 2 — "The Four Corners"

**The most built-already scene.** The four-switch lock, the progress glyph, the two-stage commit,
and the scripted distant twist all ship today.

### Reused unchanged
- Four reversible corner switches (`switchCap` toggle + `refreshSwitchLock`)
- Central plinth progress display — dots/rings driven by `progressMaskBase + switchMask()`
- Two-stage commit — `F` raises the alignment cylinder, `F` again commits (`tickAlignmentCylinder`)
- Scripted twist with the **player off the moving slab** — `startBackSliceRotation`, `playerCubieIndex = -1`
- Sealed portal opening on a finalized twist — including the `opensSealedDoors` decoupling flag
- Props riding facelets → **hidden-face structures rotate into view for free**
- Dressed stone walls re-derived from live topology (twist-safe)

### Engine work
| Work | Size | Note |
|---|---|---|
| Scripted twist targets a **designated** slice | S | Today the slice is derived from player facing; Scene 2 needs the authored hidden-face slice. |
| Obelisk activation visual (light climbing base→tip) | M | First use of an emissive-progress prop; reused by Scene 3. |
| Energy veil between the two obelisks | S | Material 23 already has veil styles. |
| Portal closes behind you on arrival | S | Reused by every later scene. |

### Authoring
Exterior world (~15, blue star, no moon) · central clearing with plinth · four quadrant routes ·
four corner plinths · **hidden-face assembly** (2 obelisks + chamber + platform + corridor stubs
that connect after the turn) · ruin-density gradient from centre outward.

> **Authoring note:** the hidden face's maze corridors must line up with the playable face's
> corridors *after* a 90° turn. Author both together, then verify by twisting.

---

## Scene 4 — "The First Turn"

**Second-most built.** The bond/refusal/dissolve loop is entirely shipped.

### The key finding: the three anchors need no new lock code
Model the three anchors as **three separate bonds**, each straddling the target slice.
`canRotateSlice` already refuses if *any* group straddles, and `dissolveBond(containing:)` already
removes one. So: release an anchor → dissolve its bond → the turn stays refused until all three are
gone. **Zero new engine machinery for the central lock.**

### Reused unchanged
- Bonds, refusal with strain-and-spring-back, `dissolveBond`
- Player rides the slice — position, facing, and standing sub-cell all rotate
- Maze rewiring on a finalized turn
- Sealed portal + finalized-twist opening
- Counterpart world rendered live in the sky (Scene 2's world overhead, in its twisted state)

### Engine work
| Work | Size | Note |
|---|---|---|
| **Bond visualisation** — three luminous bands tracing bonded cubies | **L** | The scene's one significant new feature. Must derive from bonded cubies' *current facelets*, never world coordinates, so it stays correct after dissolve and after the twist. |
| Progressive weakening — strain grows as anchors are released | S | Refusal amplitude is currently the constant `0.06`; make it a function of remaining bonds. |
| Anchor prop kind | S | Plate + segment symbol + recessed control. |
| Explicit counterpart binding (Scene 2 overhead, not the stack neighbour) | S | Registry supports it; the default stack rule would show Scene 3. |

### Authoring
5×5×5 exterior, low-moderate roundness, dark stone · low maze walls (twist must be legible) ·
sealed arch + deliberately misaligned route · the layered vessel with three rings · three anchors
spread across faces to force circumnavigation.

---

## Scene 3 — "The Heart of the World"

**Most new tech, and the only real performance risk.**

### Reused unchanged
- Interior topology, six-face walking, conjugated edge crossing
- **Six obelisks, one per face** — already stamped
- Fog, glyph atlas, plinth props, portal styles

### Engine work
| Work | Size | Note |
|---|---|---|
| **Beams** — obelisk tip → cube centre | **L** | The scene's signature visual. New emissive geometry; also back-fills Scene 2's obelisks. |
| **Central orb** at the interior centre | **M–L** | Nothing currently renders at an interior centre. Refraction/facets are art-driven. |
| **1:1 plinth→obelisk binding** | M | Today's switches are *collective*; this needs a specific remote target per plinth. |
| Six new symbols in the glyph atlas | S | The atlas + CoreText pipeline exist. |
| Portal placement as a **function** (returning a constant for now) | S | Static per your call — but written so dynamic placement is a later swap, not a refactor. |

### ⚠️ Performance risk — prototype this early
Interior worlds show **all six faces at once**: no horizon, no fog occlusion. Everything is on
screen simultaneously. You already hit frame-rate pain with *one* dressed face in the garden.
At 5×5×5 the tile count is small (150 tiles), which helps a lot — the risk is **dressing density**
plus six beams and a refracting orb. Build a density spike before authoring the full chamber.

---

## Scene 1 — "The First Clearing"

Mechanically the simplest; most dependent on art and mood.

### Reused unchanged
Exterior world, high roundness · fog of discovery · hedge/stone maze · arch portal with the
volumetric-cloud shader (material 23, style 2) · centre-sub-cell portal trigger · day/night with
sun and moon both visible at dawn (the counterpart body).

### Engine work
| Work | Size | Note |
|---|---|---|
| Gaze-dependent prop animation (the vessel that moves only when unobserved) | M | Camera-forward vs prop direction test; the prop `anim` channels already exist. |
| Twist disabled | — | Phase 0. |

### Authoring
Clearing with a thick-walled north break · maze ≈3× the clearing area · vessels at every dead end,
sharing a stacked axial grammar · one larger vessel beside the arch.

---

## Cross-cutting risks

1. **Scene 3 render load** — see above. The single biggest technical unknown.
2. **No save system.** Worlds persist *in memory for the session only*. Fine for a demo in one
   sitting; a hard dependency the moment Scene 6's "the world remembers" must survive a relaunch.
3. **`portalDestinations` is index-based** — always append.
4. **Vessel vs plinth grammar.** Scenes 1 and 4 use vessels; 2 and 3 use plinths/obelisks. Worth
   settling deliberately, since the Builders' "recognise the grammar" payoff depends on it.
5. **Twist legibility vs roundness** — high roundness fights the readability that twisting needs.
   Tune per world by eye.

## Suggested first commits

1. Phase 0 (portal transition kinds + twist gate + arrival origin) — behaviour-neutral, fully testable.
2. Scene 2 world stamp with the four-corner lock reusing the temple lock verbatim — playable end to end before any new visuals.
3. Hidden-face assembly + designated-slice scripted twist — **the vertical slice**. Once this reads
   well, the riskiest idea in the prologue is proven.
