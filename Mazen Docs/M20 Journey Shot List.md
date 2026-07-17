# M20 — Journey Shot List (Phase 0)

*The paper edit for the [Journey](Player%20Journey%20—%20A%20Session.md) vertical slice: **where each beat
physically lives on the garden**, so Phase 1 staging has a map to author against. Covers Arc 1
(front) + Arc 2 (the lock spine); Arc 3 (memory/re-see) is stubbed at the end for forward-compat.
Status: **📋 draft — awaiting Eddie's sign-off before staging.** See [M20 Work Plan](M20%20Work%20Plan.md).*

## The canvas (the garden as it is today)

The garden (`V`) is a **sealed 11×11 region on the +Z face**, rows **7–17** × cols **7–17**, on a
size-25 roundness-1.0 world (so the local surface reads nearly flat). Orientation used here:

- **row 7 = north (deep in the garden)** … **row 17 = south (toward home)**
- **col 7 = west** … **col 17 = east**
- **Spawn** = **(12, 12)**, dead-center, with a 3×3 clearing (rows 11–13, cols 11–13).
- The region is **sealed** at its boundary (no escape); everything outside stays fogged/unbuilt.

**Forward-only (Eddie):** once you're in the garden there is **no way back to home** — only onward and
forward. The spike's return-to-home portal (next to spawn) is **removed** for the journey. The two
exits are *deeper* (into the temple → interior) and, at the very end, the *onward arch*. (The current
`V` spike still has the return portal as a dev convenience; staging drops it.)

**Verified prerequisite:** the M16.6 lock runs correctly on this curved world (logic + render), so
everything below is authoring, not new systems.

## Scope steer

- **Golden-thread minimal.** A handful of authored tiles carrying the spine, not a full garden.
- **Carve the spine, keep procedural filler.** Phase 1 deliberately carves the route below (dead-end,
  temple slice, switch nooks); the rest of the region stays procedural hedge maze for texture.
- **Two worlds are off this map:** the **home clearing** (the world you arrive *from* — keep the
  overworld, plan D3) and the **temple interior** (what the door opens *into* — the M15 `templeInterior`).
  This shot list is the garden surface only; it notes the seams to those worlds.

## The route (designed discovery order)

1. **Arrival** — fade in at spawn (12,12). Calm clearing; home turning overhead in the sky. No way
   back — nowhere obvious to go → you wander deeper. *[Arc 1]*
2. **First twist (the teaching)** — a short walk **west** dead-ends at a hedge with a **seam groove**
   in the paving. On a hunch you twist the slice → the dead-end swings away, opening the way north. The
   "oh, I can move the world" hook, taught by a seam, not a tutorial. *[Arc 1]*
3. **The locked temple** — heading **north (deep)** you reach a squat mossy structure on a slice. You
   try to twist it toward you — **refused** (wobble + red flare); four points on it glow, three steady,
   one flickering. You just met a lock without being told. *[Arc 2]*
4. **The clue** — a fallen **slab** beside the temple approach, carved *four dots, three filled*. The
   door **plinth** in front of the temple shows the same four-dot progress read-out (caustic glyph). *[Arc 2]*
5. **Understand → find the switches** — three **switch-plinths** stand already engaged in the garden's
   corners; the **fourth is hidden** (a hedge-spiral in the SE you'd have skipped). Engaging it
   dissolves the lock (the temple's four points steady, glow goes warm). *[Arc 2]*
6. **Turn it open, step inside** — back at the ready door plinth, **F raises** the alignment cylinder,
   a second **F turns the world**: the temple's slice twists and the structure **opens**. You walk
   through the unsealed door → the **inverted interior** (peel: natural skin → engineered truth). *[Arc 2]*
7. *(Arc 3, later)* the **memory** on the interior pedestal → the **re-see** back outside → a dark
   **onward arch** at the garden's edge lights because you now know. Locations stubbed below.

## Placement table

| # | Beat | Location (row, col) | Machinery reused | Authoring notes |
|---|---|---|---|---|
| 1 | Arrival / spawn | **(12,12)** | garden stamp | 3×3 clearing (exists); **no return portal** (forward-only) |
| 2 | First-twist dead-end + **seam groove** | **(12,9)** (west of spawn) | twist (`Q`) + seam decal `[INVENT-small]` | carve a dead-end here; decal on the twistable seam tile |
| 3 | **Temple** (bonded, on a slice) | body **rows 8–9, cols 11–13**; door **(9,12)** facing south | M13/M16 bond + refusal (`stampDemoProps` temple, re-placed) | door faces the approaching player; temple + door-plinth share one twistable slice |
| 3 | Four indicator points | on the temple face | dial/switch-state lights `[glue]` | 3 steady, 1 flicker (mirror switch mask) |
| 4 | **Clue slab** (four dots, 3 filled) | **(10,13)** | plaque + four-dot art `[glue]` | static diagram; beside the approach |
| 4 | **Door plinth** (read-out + turn) | **(10,12)** in front of the door | `.plinth` + M16.6 turn (verified) | positional 4-dot caustic read-out |
| 5 | Switch-plinth #1 (engaged) | **(9,9)** NW | `.switchBase`/`.switchCap` (exists) | pre-engaged |
| 5 | Switch-plinth #2 (engaged) | **(9,15)** NE | " | pre-engaged |
| 5 | Switch-plinth #3 (engaged) | **(15,9)** SW | " | pre-engaged |
| 5 | Switch-plinth #4 (**hidden**, off) | **(15,15)** SE hedge-spiral | " | the one to find + engage |
| 6 | Alignment cylinder / turn | at the door plinth (10,12) | M16.6 rotator (verified) | spawns on the ready plinth |
| 6 | Temple door → interior | door (9,12) → `templeInterior` | M15 portal (exists) | seam to the interior world |
| 7 | Onward arch (Arc 3, dark) | **(12,17)** east edge | knowledge-gated portal `[INVENT-small]` | **inert until you exit the temple carrying the memory** — then it lights (the re-see reward). Built in Arc 3 |
| — | Counterpart sky (home overhead) | n/a (sky) | M11 sky-object | wire home as the garden's sky world |

## Map (rows 7–17 × cols 7–17)

```
        col:  7  8  9 10 11 12 13 14 15 16 17
   row  7      ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·      north / deep
   row  8      ·  ·  ·  ·  ▓  ▓  ▓  ·  ·  ·  ·      ▓ = temple body
   row  9      ·  ·  ①  ·  ·  D  ·  ·  ②  ·  ·      D = temple door (faces south)
   row 10      ·  ·  ·  ·  ·  P  L  ·  ·  ·  ·      P = door plinth   L = clue slab
   row 11      ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·
   row 12      ·  ·  ⟳  ·  · [S] ·  ·  ·  ·  A      S = spawn   ⟳ = first-twist seam   A = onward arch (dark until the memory)
   row 13      ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·
   row 14      ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·
   row 15      ·  ·  ③  ·  ·  ·  ·  ·  ④  ·  ·      ④ = hidden switch (SE hedge-spiral)
   row 16      ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·
   row 17      ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·      south
```

Route: **[S]** → west to **⟳** (first twist) → north to the temple **▓/D**, refused → read **L** + **P**
→ find switches **①②③** + hidden **④** → engage ④ → back to **P**, turn → door opens → step inside →
(memory) → back out → **A** lights → onward. **No way back home** — forward only.

## Reconciling the mechanism (script "dials" → M16.6 switches)

The Player Journey script says "four **dials**"; the built + verified lock is **four switch-plinths**
(toggle with F) + a **door plinth** that reads the 4-dot progress as a caustic glyph. The mapping: the
"align the last dial" beat = **find + engage the hidden 4th switch**; the "understanding" layer is the
**caustic-glyph reading** (the door plinth's positional read-out and the switch glyphs) rather than a
pattern-alignment. Staging uses the switches as built; the "understand" craft problem lives in whether
that reads as comprehension, not switch-hunting (that's the Phase 4 fresh-eyes test, the plan's D-risk).

## Decisions for Eddie

- **D-A — Region size:** keep the current **11×11** (recommended — minimal thread, fits the layout
  above) vs. expand for a looser wander.
- **D-B — First-twist placement:** **west of spawn (12,9)** as an early low-stakes beat (recommended)
  vs. on the northern approach to the temple.
- **D-C — Carve vs. procedural:** **carve the spine, keep procedural filler** (recommended) vs. fully
  hand-author every tile.
- **D-D — Hidden switch motif:** the 4th in a **hedge-spiral** you'd skip (recommended, matches the
  script) vs. just a far dead-end.

*(Resolved: **switches** = keep the M16.6 switch-plinths; **forward-only** — the return-home portal is
removed. The temple + door-plinth-share-a-twistable-slice constraint is a staging detail, handled in
Phase 1, not a design decision.)*

## Phase 1 progress

Per the plan's build order (spine first):
- ✅ **(1) Lock re-staged onto the garden (2026-07-17).** The verified M16.6 lock (shared
  `stampTempleLock`) now stamps into the garden at the tiles above — temple north (door faces south),
  door plinth in front, four switches at the ±3 corners (SE off) — with a carved reachable **spine**
  of corridors from spawn to the plinth and every switch. Way-home portal removed (forward-only).
  Verified headlessly: the puzzle solves end-to-end on the curved garden and all switches + plinth are
  reachable. **Eddie's visual check:** press `V`, walk north to the temple, solve the switches, turn.
- ✅ **(4) Step-inside works (2026-07-17).** Stepping onto the opened temple door from the garden now
  PUSHES the temple interior (fixed the nested-world pop bug); returning pops back to the garden. The
  full spine plays: arrival → solve switches → turn → door opens → step inside → return. Verified
  headlessly.
- ⬜ **(2)** first-twist dead-end + seam groove (west of spawn).
- ⬜ **(3)** clue slab + four indicator points + mossy temple dressing.

Then Arc 1 wraps the front (home world, arrival, counterpart sky, arch look), and Arc 3 (the
inventions — PlayerKnowledge, memory, re-see, onward arch) comes last.
