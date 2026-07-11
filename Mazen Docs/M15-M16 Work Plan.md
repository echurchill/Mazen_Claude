# M15 + M16 — Work Plan (inverted interiors → the lock→break→enter loop)

*Drafted 2026-07-10 (evening) for Eddie's greenlight, incorporating this week's design decisions: the [World Graph](World%20Graph%20—%20Relational%20Worlds.md) (route-keyed worlds — M15's first build step), [Builder Glyphs](Builder%20Glyphs%20—%204D%20Shadows.md) (locks eventually speak in 4D shadows), the M13 bandaging foundation (built, inert), and M10's deferred Phase H (gates). R2 left the runway clear: Renderer split, placement unified behind `restMatrix`/`inflatedPlacement`, 107k tests. Statuses: **📋 all phases awaiting greenlight.***

## Why these two together

M16 (lock → break → enter) is **the single most important loop in the game** — but its payoff ("enter") is an M15 interior. M15 (inverted-cube interiors) is the big new spatial mode — but without M16 it's a tech demo with no reason to go inside. Built in the order below, each M15 phase hands M16 exactly what it needs next, and the combined exit criterion is the **core-loop vertical slice**: *notice → twist refused → understand → unlock → twist open → step inside.*

---

## The architectural insight that makes M15 cheap(er)

After R2.1, **every placement in the game routes through two functions** — `restMatrix` (what the shader inflates from) and `inflatedPlacement` (rigid seats: camera, props, marker). An interior world is, to first order, **one basis change in those functions**:

> exterior basis `(tangent, bitangent, normal)` → interior basis `(−tangent, bitangent, −normal)`

That is a **180° rotation about the bitangent** — determinant +1, so triangle winding/culling are untouched — which points the tile's "up" *into* the cube. Floors, walls, posts, props, the frame grid, the FP camera, and the player marker all follow **automatically**, because they all consume these two functions. No mesh changes, no shader changes, no per-system special-casing. (This is the payoff of the R2 consolidation — before it, inverting meant touching every placement site.)

What does *not* come for free (the real M15 work): edge crossings on a concave dihedral, interior lighting, and comfort.

---

## M15 — Inverted-Cube Interiors

### Phase 0 — The World Registry *(the World Graph, realized; subsumes M11's "multiple portal destinations")*
Replace `worldStack` + the hardcoded `testInterior` with a **registry**: `[(destination, context) : GameState]`, lazy-created, persistent (scars keep). The stack remains navigation *history*; the registry is the *universe*. Counterpart (sky) lookup goes through the same registry — identity-bound edges (earth↔moon) resolve to one instance; divergent edges to variants.
*Danger:* **Low** (refactor + feature; the moon keeps working exactly as today, now as a registry entry). *Verify:* portal hop earth↔moon unchanged; scars persist across visits; tests green; a second registered destination reachable from a second portal proves the key actually keys.

### Phase 1 — The inverted world type
A per-world `orientation: exterior | interior` (on `WorldScale` or `GameState`) consumed *only* inside `restMatrix`/`inflatedPlacement` (the basis flip above). Interior worlds: `includeCelestials: false`, **no sky pass** (dark clear color for now), fog off, **roundness 0 — deliberately**: interiors are *engineered*, so hard-cubic interiors are the shape-as-meaning dial doing its job (and it defers all inverted-inflation math, possibly forever).
*Danger:* **Med** — the two known traps: (1) **EdgeCrossing on a concave dihedral** — the face-adjacency table should hold combinatorially (same cube graph), but the camera's corner-rounding slerp was tuned for convex corners; expect a sign/behavior fix at interior edges. (2) **Lighting** — sun direction is meaningless inside; first pass = a fixed warm "lantern" directional + ambient (decision point D2). *Verify:* stand on an interior floor in FP, level horizon; walk across all 6 interior faces incl. edge crossings (the Escher moment: rooms overhead); orbit view of an interior world renders sanely (debug).

### Phase 2 — The first real interior, reached through a portal
A small hand-stamped **temple interior** (3³ or 5³ — decision D3) registered as `(temple-interior, from: overworld)`, reached through a portal prop on the overworld. Stamp it sparsely: stone register (existing stone texture), a couple of prop pedestals, one open chamber — legible, not busy.
*Verify:* the full walk-through: overworld → portal → fade → standing *inside* — look up, see the far wall's maze overhead. Return trip persists scars.

### Phase 3 — Twist while inside
Slice rotation of the world you're standing in — the *room rearranges around you*. Architecturally this should mostly already work (twist machinery is per-`GameState`; the camera rides via `playerCubieIndex`), but nobody has ever twisted an interior.
*Verify:* Q/E inside; walls/ceiling sweep past correctly; `.step` scrub looks right; bandaging legality still enforced.

**M15 exit criterion:** enter a temple interior through a door, walk its inside surfaces comfortably, twist a slice of it, leave, come back — everything persists.

---

## M16 — Lock → Break → Enter (activating M13 as the verb)

### Phase 1 — Bond a real structure
The overworld temple structure (new prop cluster, or the existing house — decision D4) becomes an M13 **bonded group**. Twists through its slices now *refuse*. Needs one tiny API addition: `removeBond` (bonds are currently add-only).
*Verify:* existing bandaging tests + a new remove/unbond test; the refused twist genuinely doesn't move.

### Phase 2 — The refusal cue *(the `twistRefused` flag finally gets its consumer)*
When a twist is refused: a soft resistance shake (a few degrees of rotation that spring back), a low tone placeholder, and a **glow trace on the bonded structure** (the Player Journey's four-points image). This is the game's first *taught-not-told* beat — the refusal IS the tutorial for "lock."
*Danger:* **Low-Med** (first gameplay-feel work; iterate with Eddie live). *Verify:* feel pass together.

### Phase 3 — The first "understand → unlock" mechanism
The Player Journey's beat, minimally: **four dial-props** placed around the garden, three pre-aligned, one not; an environmental clue (a carved slab prop). Interacting (F) with the last dial aligns it → `removeBond` fires → the glow goes warm → the structure's slice is twistable. M10's deferred Phase H (gates/locks) is raw material here.
*Scope guard:* this is deliberately "find the pattern and act once" — the *deep* version (composable glyph grammar) is M17+ territory; do not gold-plate.

### Phase 4 — Twist open → enter → the loop closes
The now-unlocked slice twist swings the temple open, revealing the portal (the door prop activates / appears) → walk through → **the M15 interior**. First full run of the core loop, end to end.
*Verify (the milestone's whole point):* a fresh player-eye run: notice the structure → try the twist → refusal cue → find the dials → align → twist open → step inside → the reveal (engineered interior under the natural surface).

### Phase 5 — The first glyph (bridge to M17)
Carve one **hand-authored placeholder glyph** in the Builder-Glyphs *style* (a frozen 4D cross-section look — carved stone register) on the lock face, paired with the dial mechanism. No language system yet — just the *presence* of the language, seeding the community-translation surface and testing the carved render register. The real glyph forge stays unscheduled.

---

## Decision points — ✅ GREENLIT (Eddie, 2026-07-11)

- **D1 — Sequence:** as recommended — M15.0 → M15.1–2 → M16.1–2 early → M15.3 → M16.3–5.
- **D2 — Interior lighting:** fixed warm lantern-directional + ambient first; revisit after the loop works.
- **D3 — First interior size: 5³** *(Eddie's call — roomier, more maze inside; overrides the 3³ recommendation).*
- **D4 — First bonded structure:** a **new temple** prop-cluster on the overworld plaza.
- **D5 — Registry keys:** adopt the `<destination>-<origin>` convention as the literal key format now.

## Risks (honest list)

1. **FP comfort inside a concave space** — the design docs' own flagged unknown. Mitigation: the basis-flip approach keeps *local* movement identical to the exterior (it's the same math); the novelty is only at edges and in what you *see*. Test early with Eddie.
2. **Corner-crossing slerp** at concave edges — expect one gnarly afternoon.
3. **Interior lighting/mood** — flat lantern light may feel dead; budget one polish pass after the loop works (shaft-of-light comes with M19/art).
4. **Scope creep at M16.3** — the mechanism must stay dumb; the glyph language is *not* this milestone.
5. Registry persistence is in-memory only until save games exist (fine; note it).

*Estimated shape: M15.0 ~a session; M15.1–2 one to two sessions (the slerp risk); M15.3 short; M16.1–2 short; M16.3–5 one to two sessions incl. a feel pass. The core-loop slice is plausibly ~a week of sessions away.*
