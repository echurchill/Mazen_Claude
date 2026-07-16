# Working Plan — Next Session (2026-07-07)

*Prioritized plan drafted 2026-07-06, end of the M11 killer-visual session. Everything's on `main`, tests green (6960). Pick the top item, or reorder — this is a recommendation, not a contract.*

## Where we are

The **world-switch system (M11) is built and verified**: world stack, TARDIS walk-through portals with a fade, decorations that ride slices, and **the killer visual** — the real counterpart world (the moon from earth, and vice-versa) hangs in the sky, turning, with every twist baked in, and it persists so tears stay. The prototype now has: a textured maze on a spinnable cube (M8), a live sun/moon sky (M9), sub-tile navigation + props (M10), imported-asset pipeline + a splitting modular house (M12), and multi-world portals (M11).

What it still lacks: **a reason to twist** (no goal), destinations that feel like *places* (the moon is a grey 3³), and the deeper puzzle layer we designed (bandaging).

---

## Recommended priority order

### ⭐ 1 — Bandaged Cube (M13): make the twist a real puzzle

**Why this is the ideal lead.** The twist is the game's signature, but right now it's *aimless* — you can twist anything and structures just tear. Bandaging turns twisting into a **constraint puzzle**: bonded structures **refuse** any slice that would cut them, so the legal move set becomes position-dependent and you have to *plan* turns. It's the single biggest leap toward this being a **game**, it fixes the "twist-anything-into-chaos" feel, and — crucially — its **core is pure logic I can build and unit-test myself**, so we move fast at low risk. Design is already written: [Bandaged Cube Mechanic](../Bandaged%20Cube%20Mechanic.md).

**Tasks (roughly in order):**
1. **Bond model + legality** *(self-verifiable)* — `bondedGroups: [Set<Int>]` on `CubeModel`; `canRotateSlice(axis:index:)` = every group is fully-in or fully-out of the slice. Unit tests: bonds survive legal twists, illegal twists are detected, group indices stay valid across turns. I can land this solo with confidence.
2. **Enforcement + cue** — refuse illegal twists in `startSliceRotation`; add a "locked" feedback (a small rebound/shake of the slice, or a tint/flash on the offending structure) so the refusal reads.
3. **First bonded structure** — bond the house's four cubies into one group (a `solid`/`bonded` flag on structures); verify twists that would tear it are refused, and legal twists carry the whole block intact.
4. **Affordance** — mark bonded structures visually (a brace, a tint, or a subtle glyph) so the player can *see* what's locked.

**Verification:** unit tests (me) for the legality core; you check the refusal UX and that legal twists still carry structures.

---

### 2 — Make the worlds real (finish the portals vision)

The momentum choice if you'd rather stay in the world-building flow. Completes "bigger on the inside."
- **House interior** — wire the house's *door* to a hand-built interior **room** you drop into (reuses the world-switch spine; the door becomes a portal to a small room-world). This is the other half of portals and the literal "bigger on the inside" payoff.
- **Moon feel** — give the moon its own look (regolith/grey palette, maybe lower gravity-feel later) so it reads as a *place*, not a test cube. Cheap, high-impact on the killer visual.

### 3 — Quick wins (as time allows)
- **Persist camera/time across worlds** (M11 Phase 3) — small plumbing; swaps feel more continuous (matters for interiors).
- **M12 loose ends** — normal maps (real surface depth on the fire pit/stumps/statue) *or* fort multi-texture support.

---

## Bigger bets (higher effort/risk — worth doing, plan first)

- **Superellipsoid planet (M14)** — inflate the cube toward a rounded planet. **New synergy from today:** the counterpart worlds in the sky currently read as *cubes*; inflated, they'd read as real **planets** hanging there — a big upgrade to the killer visual, and it improves M9's day/night shading too. But it's a core geometry change (`worldMatrix`), touches everything, and I can't self-verify it — so it needs a careful, staged approach. [Superellipsoid Cube](../Superellipsoid%20Cube.md).
- **Player collision** — stop walking through walls/buildings; makes exploration feel real (flagged since the house work).
- **Audio** — first sound pass (footsteps, the twist, the portal "vworp"). A large absence for feel; even a little transforms it.

---

## The one thing worth a conversation first: **what's the goal?**

We have rich *systems* (maze, twist, worlds, a sky) but **no objective or win condition** yet. Bandaging begs the question directly: *twist toward what?* Some directions to weigh together:
- **Scramble → solve** — the classic Rubik's framing: the maze/faces start scrambled; twist (legally, around bonded landmarks) to restore a target state.
- **Navigate to a goal** — reach a target tile/world; twists open and close the routes.
- **Collect / restore** — gather something across faces and worlds; portals gate progress.

This is the biggest open design decision and it's **yours** — a short chat before committing a direction would be well spent. Bandaging + a chosen goal = an actual puzzle game rather than a beautiful sandbox.

---

## Notes for whoever picks this up (me)
- **I can start M13 task 1 (bond model + legality + tests) solo** — it's self-verifiable, so we hit the ground running even before you're at the screen. The enforcement/visual/UX bits need your eyes.
- Recommended flow: **land the M13 legality core + tests → wire up refusal + the house bond → then pause to look and talk about the goal.**
- If you'd rather stay in the worlds flow, jump to **Priority 2 (house interior)** — it's the most tangible continuation of today.
- Everything is committed and pushed; the standalone test runner is `Tests/run-tests.sh`.
