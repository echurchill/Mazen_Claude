# M11: Lunar Excursion (Seed)

> **Status: seed, not a plan — NOT implemented.** Captures the concept and its architectural implications so the thinking survives.
>
> **⤳ REFRAMED (2026-07-06):** M11 is now the **first showcase of a general world-transition system**, not a bespoke moon feature. See [Worlds & Portals](../Worlds%20and%20Portals%20Plan.md) and the [Master Roadmap](../Master%20Roadmap.md). The moon becomes one destination among many (house interiors, dungeons) reached through the same "enter a portal → switch world" spine. **Preserve from this seed:** the *orbital-counterpart* "killer visual" (seeing the real other world hanging in the sky, updated live with its actual rotations) and the per-world-`WorldScale` / `SceneBuilder(gameState:)` guardrails, which are already in place.

## Vision

The moon is not scenery — it is a second, smaller game world. An interactable object on the main world (a lunar shrine, a beacon, a launch pad...) transports the player to the moon: a pocket-sized cube maze with its own texture set, its own rules, and a puzzle. Solving it (and finding the return gate) brings the player home with whatever key/reward gates further progress on the main world.

## Core loop

1. Player discovers a transport object on the main world (an M10 prop, using the Phase G adjacency + facing interaction hook — **this is the first real customer for that hook**).
2. Transition: first-person → camera pulls back to orbit → flies the gap → descends to the moon's surface. A camera spline over existing camera machinery; a spectacular moment for roughly a day of work.
3. Moon exploration: same movement/maze mechanics, different world.
4. Puzzle solved → return gate unlocks → reverse transition home.
5. Both worlds persist: maze state, discovery, and rotation scars survive the round trip (they're just live objects in memory).

## Why the architecture is ready

- `CubeModel` / `GameState` are instance-based and size-parameterized — nothing in the model layer assumes one world. The moon is a second `GameState` (3³ — pocket-cube sized, odd, respects the center-tile rule) with its own maze seed.
- "Being on the moon" ≈ which `GameState` the renderer and input feed from, plus a saved return position for the main world.
- Texture set: a second texture array (or extra slices with a per-world materialID offset); binding already happens per frame.
- Cost: two worlds in memory is negligible (a 3³ world is ~26 cubies).

## The killer visual: the sky is real

- M9's moon need not be an emissive prop — render the *actual moon world's model* at its orbital position. Look up from the main world and see the real state of the moon, including slice rotations you made while visiting.
- The reverse is the signature shot: standing on the moon with the main game world hanging in the starfield — an earthrise. With instanced rendering, drawing the other world's ~150–486 tiles at distance is nearly free; no impostors needed at these scales.
- Each world stays origin-centered in its own frame; only the *sky rendering* of the counterpart reflects orbital position. (This is how the current architecture already wants to work — the game world never moves.)

## Lighting & celestial integration

- The M9 sun direction works identically on the moon world — phases happen because you're *standing on* the phase.
- The moon's dark side can be lit by "planetshine" from the main world (a second faint directional source, same pattern as M9's moonlight).
- An eclipse while standing on the moon is an emergent event, not authored content.

## Different world, different rules (design hooks)

- **Slice rotation as the puzzle:** on the moon, the frozen-bands limitation is lifted — all slices rotatable — and arranging the moon's tiles *is* the puzzle that unlocks the return gate.
- Different texture palette (gray regolith floors, glowing crystal walls vs. moss/gravel/stone).
- Possibly different `WorldScale` feel (smaller tiles, different movement cadence — "everything on the moon is smaller/lighter").
- ~90% shared code; the foreignness comes from rules + palette + scale.

## The one real design tension: moon size

M9 plans the moon as a 1.5-unit cube at 20 units out (~4.3° in the sky). A walkable 3³ world at standard tile scale is ~3 units wide — ~8.6° at the same distance. Options (decide when M9 lands):

1. Push the moon orbit radius to ~35–40.
2. Shrink the moon world's per-world tile scale (charming "smaller world" fiction; needs per-world `WorldScale`).
3. Embrace the big looming moon.

## Dependencies

| Dependency | What M11 needs from it |
|---|---|
| M9 | Moon exists, orbits, is lit; celestial system provides positions for transitions and counterpart-in-sky rendering |
| M10 Phase G | Props + the adjacency/facing interaction hook (the transport object) |
| Phase 0 guardrails | See below — must not be violated during the refactor |

### Phase 0 guardrails (cost nothing now, expensive to retrofit)

- **R1:** `WorldScale` must be **per-world**, not a singleton.
- **R3:** the extracted scene builder must take the `CubeModel` (and palette) **as parameters**, never assuming a single global world.

Both are the natural way to write them anyway — the guardrail is simply: don't bake in "one world."

## Open questions (for when this becomes a real plan)

1. Is the moon reachable once, repeatedly, or freely after first unlock?
2. Does time pass on the main world while on the moon (does the sun keep orbiting)? (Suggest: yes — coming home at a different time of day is atmospheric.)
3. Can slice rotations on the main world be *observed* from the moon mid-rotation (live counterpart), or is the sky-render a static snapshot refreshed on transition?
4. One moon, or does this pattern generalize (asteroids, a second moon, the sun itself as an endgame world)?
5. Save/load implications once persistence exists.
