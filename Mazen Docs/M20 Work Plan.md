# M20 — The Journey Walkthrough (work plan)

*Drafted 2026-07-11 at Eddie's suggestion: after the natural worlds exist, "actually create
an actual walkthrough of the Journey script." This is the **vertical slice**: the
[Player Journey](Player%20Journey%20—%20A%20Session.md) session (0:00 → 0:30), staged for real,
beat for beat. Prerequisites: **M17** (memory), **M18** (movement), **M19** (the worlds).
Cozy/feel polish slides to **M21**. Status: **📋 awaiting greenlight (after M17–M19).***

## The realization this milestone is built on

Almost every beat in the Journey script is machinery that already exists or is already
planned: the twist, the refused lock with red flare, the four dials, the slab clue, the
gold-shedding unlock, the twist-open door, the inverted interior, the pedestal mote, the
perception change, the knowledge-gated arch. **M20 adds almost no new systems — it is an
authoring, staging, and pacing milestone.** Its product is not code; it is *the session*.
And its test is the script's own: legible and quietly compelling **with almost no UI and
no one telling you anything.**

## Beat map (script → machinery)

| Script beat | Machinery | Status |
|---|---|---|
| 0:00 threshold — pastoral home, humming arch, walk through | M11/M15 portals, home world | ✅ built |
| 0:01 arrival — round garden world, home turning in the sky | M19 Natureworld + counterpart visual | M19 |
| 0:04 first twist — **seam groove** noticed at a dead end | twist ✅; seam-groove *affordance decal* | **new (small)** |
| 0:09 locked temple — refusal, tone, four glowing points | M13/M16 bond + refusal cue | ✅ built |
| 0:09 slab clue — four dots, three filled | M16.3 clue-slab pattern | ✅ pattern exists |
| 0:13 understand → align the last dial (in a hedge-spiral) | M16.3 dials | ✅ built |
| 0:15 twist open, step inside — **the peel** | M15 interiors + sealed door | ✅ built |
| 0:22 the memory — mote on the pedestal, receive | M17 mote + receive beat | M17 |
| 0:22 re-see — planted rows show, hill reveals the machine | M17 perception change, **staged big** | M17 + **new staging** |
| 0:25 a dark arch lights — knowledge opens the way | M17 knowledge gate | M17 |
| 0:30 the choice — onward, or home with new eyes | world graph, no prompt | ✅ built |

The only genuinely new items: the **seam-groove affordance** (a subtle floor decal marking a
twistable seam — the script's replacement for a tutorial), the **staged re-see** (the garden
must visibly change register once the memory is held: planted-row alignment revealing itself,
one authored mound with machinery showing — M19's D4 single hill), and **pacing/comfort**
work (the interior gravity flip needs the gentle transition the script's holes-list demands).

## Golden Thread Prototype — the ordered build (2026-07-13)

*The "golden thread" is the thinnest end-to-end playable version of the whole script — every
beat present and connected, none of it polished. Its purpose is to prove the loop plays and to
concentrate risk on the few real inventions. Key finding: **the middle of the script (0:09→0:15,
lock → refusal → dials → unlock → twist-open → step-inside) is already a built and Eddie-verified
loop** — it lives on the dev overworld today. So the thread is mostly (a) **re-stage that spine
onto the garden**, (b) build a **front** (home → garden → first-twist-as-teaching), (c) build the
**back** (memory → re-see → new arch), where nearly all genuine invention sits.*

**Tags:** `[have]` = compose/author existing verified systems · `[glue]` = small new code/art ·
`[INVENT]` = a genuinely new system. Each step notes its **prototype-minimal** form.

### Prerequisite spike — the natural-maze hybrid *(do first; the one unproven "have")*
The garden is a **hedge maze *on* a natural planet** — hedge paths / dead-ends / twistable slices
dressed with grass floors, trees, roundness 1. Every other "have" is verified; this combination
never has been (worlds are maze *or* nature so far). `[glue]` — a grass-floored maze terrain +
M19 tree scatter on maze tiles. **Validate before trusting the garden.** (Tracked in memory.)

### Arc 1 — FRONT (0:00–0:08): threshold, arrival, the first twist
1. **Home clearing** — a small, calm, sparse pastoral world with one discoverable arch. `[have]`
   (maze/overworld register, purpose-built). *Min:* a few tiles, one arch, nothing else.
2. **Stone-arch portal look** — portals read as an arch, not the police box. `[glue]`. *Min:* a
   simpler arch mesh (or recolour) — swap the visual only, machinery unchanged.
3. **Home → garden wiring** — arch routes to the garden via the registry. `[have]`.
4. **Garden world** — the natural-maze hybrid from the spike, authored as a loose garden with a
   dead-end that a twist opens. `[have]` once the spike lands. *Min:* a handful of hedge tiles +
   one authored twist that clears a dead end.
5. **Counterpart sky** — home turning overhead in the garden. `[have]`.
6. **Seam-groove affordance** — the subtle floor marking that teaches "this slice turns," no UI.
   `[INVENT]` (small, load-bearing). *Min:* a decal on the twistable seam tiles.

> **Verified 2026-07-17 — the lock runs on a curved world.** The M16.6 lock was only ever built/run
> flat; before staging it in the roundness-1 garden I drove the whole puzzle on a roundness-1.0 model
> headlessly (solve switch → bond releases → raise cylinder → turn → **door unseals**: all pass) and
> rendered the full curved lock — plinth (mat 21), switch caps + alignment-cylinder drum (mat 22),
> caustic glyphs — under Metal API+GPU validation with zero errors. Confirmed by inspection that the
> lock's logic reads only cube-topology (no roundness / inflated geometry). **Arc 2's one open risk is
> cleared** — re-staging onto the garden is pure authoring.

### Arc 2 — SPINE (0:09–0:15): re-stage the verified lock→enter loop onto the garden
7. **Temple on a garden slice** — a bonded structure that refuses the twist (refusal wobble + red
   flare). `[have]` (M16). *Min:* reuse the exact overworld temple bond, placed in the garden.
8. **Four indicator points on the temple** reflecting the four dials' states (3 steady, 1 flicker).
   `[glue]` — dial-state data exists; show it as lights on the structure.
9. **Clue slab** — a fallen slab carved "four dots, three filled." `[glue]` — plaque system + new
   clue art. *Min:* one plaque with a static four-dot diagram.
10. **Four dials, one hidden** — three pre-aligned, one in a hedge-spiral; aligning it releases the
    bond. `[have]` (M16.3). *Min:* four dials, one off, placed by hand.
11. **Mossy-stone temple dressing** — not gold dev props. `[glue]` — art/dressing (defer-able).
12. **Twist open + the peel** — the unlocked slice twists the structure open. Door-unseal `[have]`;
    the visible **peel** (stone splits/peels) `[INVENT]` (medium, most stubbable). *Min:* door
    lights and opens simply; full peel later.
13. **Step inside → inverted interior** — swap to the temple-interior world. `[have]` (M15).
14. **Gravity-flip entry comfort** — arrival orientation + fade so the flip reads as wonder, not
    nausea. `[glue]` (interior + per-face up already work; this is transition polish).
15. **Interior dressing** — hollow chamber, shaft of light, the pedestal. `[have]` (dress the
    existing templeInterior stamp).

### Arc 3 — BACK (0:22–0:30): the memory, the re-see, the choice *(the invention cluster)*
16. **PlayerKnowledge** — player-global knowledge that crosses worlds (can't live in a per-world
    `GameState`). `[INVENT]` (M17 Phase 0; foundational, low-risk — **build first in this arc**;
    the rest of the arc hangs off it). *Min:* a single "has-temple-memory" flag on a
    Renderer-level object beside the world registry.
17. **Mote on the pedestal** — new prop. `[glue]`. *Min:* a small glowing prop.
18. **Receive-a-memory beat** — reaching the mote plays a short "through a Builder's eyes" vision;
    sets the knowledge flag. `[INVENT]` (the first wonder beat; new presentation). *Min:* a slow
    warm flash + the mote drifting into the camera (M17 D1 "humble v1").
19. **The re-see / perception change** — back outside, the world visibly changes: hedges show
    planted rows, a hill opens to reveal a buried machine. `[INVENT]` (**the signature mechanic**;
    a render-hook keyed to PlayerKnowledge + authored reveals). *Min:* **one** authored reveal
    (e.g., a single hill that opens to a machine when the flag is set).
20. **Knowledge-gated arch** — a dark portal at the garden's edge that lights *because* you now
    know. `[INVENT]` (small — a portal inert until the flag is set). *Min:* the arch lamp lights +
    the portal activates when the flag flips.
21. **The choice** — new arch → a stub next-world, or home; no prompt. `[have]` + a placeholder
    destination. *Min:* both portals live; the new one leads to a bare stub world.

### Build order (recommended)
**Spike the natural-maze hybrid → Arc 2 first** (re-stage the proven spine onto the garden — fast,
high-confidence, gives a playable core immediately) → **Arc 1** (wrap the front around it) →
**Arc 3** (the inventions, PlayerKnowledge first). Doing the proven spine early means the thread is
*playable* long before the hard back-half, and each invention gets tested against a real game.

### Inventions, ranked (with their prototype-minimal form)
1. **Re-see / perception change** — big, the game's whole point; *min:* one authored hill reveal.
2. **Receive-a-memory beat** — first wonder beat; *min:* a warm flash + drifting mote.
3. **PlayerKnowledge** — the cross-world substrate (1),(2),(4) need; *min:* one flag. Build first.
4. **Knowledge-gated portal** — *min:* arch lights when the flag is set.
5. **Seam-groove affordance** — *min:* a decal on twistable seams.
6. **Structure peel-open** — most stubbable; *min:* door opens simply.

Everything else is **composition + authoring** of verified systems — above all the entire
lock→dials→unlock→enter spine. The prototype ships *minimal* versions of all six inventions, which
collapses the real risk to two design problems worth prototyping with care: **the receive beat**
and **the one re-see reveal**.

### Golden-thread risks
- **Natural-maze hybrid unproven** — the prerequisite spike; if it fights us, the garden's whole
  register is at stake. Do it first.
- **Legibility** (the script's own hardest problem) — "this lock needs *understanding X*" with no
  UI. Not a system to invent; a target only a fresh-eyes playtest confirms (see Phase 4 below).
- **Invention creep** — hold each invention to its prototype-minimal form; depth is post-thread.

## Phases

### Phase 0 — Paper edit
**Draft: [M20 Journey Shot List](M20%20Journey%20Shot%20List.md)** (2026-07-17 — awaiting sign-off).
Walk the script against the built game world-by-world and write the *shot list*: where each
beat physically lives on the M19 Natureworld (where the arch is, where the dead-end seam is,
where the temple squats, where the four dials hide, which hill buries the machine). Scope
steer (Eddie): the Journey occupies a **small region** of the sphere — the shot list picks
that region and leaves the rest of the world as loose authored wilderness for later game;
the Moon appears only in the sky. Cheap,
and it drives every stamp that follows.
*Verify:* Eddie signs off the shot list before staging starts.

### Phase 1 — Stage the garden
Author the Natureworld stamp to the shot list: the looser garden maze, the dead-end with the
seam groove, the mossy temple (bonded, gold-livery suppressed until refusal — the script
wants it *discovered*, not advertised), dials placed including the hedge-spiral, the slab.
*Verify:* each beat reachable in order by natural wandering; nothing signposted.

### Phase 2 — The peel & the memory
Interior staged (the script's "staircases climbing every wall" ambition trimmed to what the
inverted 5³ supports — one shaft of light is cheap and carries most of it); mote on the
pedestal; the **gravity-flip comfort pass** (fade timing, arrival orientation, one breath of
stillness before control returns).
*Verify:* first-time-entry feel pass — disorienting in the intended way, not the bad way.

### Phase 3 — The re-see
The staged perception change: known-glyph glow (M17) plus the two big authored reveals —
planted rows and the hill machine — and the dark arch lighting up. This is the milestone's
emotional payload; budget iteration here.
*Verify:* walk out of the temple and feel the garden become *tended*.

### Phase 4 — The full run
End-to-end sessions with fresh eyes (and at least one player who isn't Eddie or me, if
available): no UI help, no narration. Measure against the script's own test — every beat
legible, the session quietly compelling, the 0:30 choice genuinely open.
*Verify:* the holes-list from the playtest becomes M21's worklist.

**M20 exit criterion:** a stranger can play 0:00 → 0:30 unassisted and experience every
beat — threshold, first twist, lock, understanding, the peel, the memory, the re-see, the
choice — and the session holds them. That is the vertical slice, and everything after it
is more game, not more proof.

## Decision points for Eddie

- **D1 — Seam-groove affordance:** subtle floor decal on twistable seams everywhere
  (recommended — it becomes the game's permanent twist-affordance language) vs. only at
  authored story seams.
- **D2 — The re-see's scope:** the two authored reveals (rows + hill machine, recommended)
  vs. a broader world-relighting pass (M21 candidate).
- **D3 — Home world's role:** keep the current overworld as the pastoral home (recommended —
  it already has the register) vs. authoring a smaller dedicated home clearing.
- **D4 — Playtest:** recruit one outside player for Phase 4 (recommended, even informally)
  vs. self-test only.

## Risks

1. **Legibility is the hardest craft problem in the game** (the script says so itself) —
   the refusal + slab + dials chain worked for Eddie in M16, but he built it with us. Phase 4
   with fresh eyes is the only honest measurement; expect iteration.
2. **The re-see under-delivering** — "understanding rewrote perception" is the game's
   signature promise; two small authored reveals must feel like revelation, not a texture
   swap. Budget Phase 3 accordingly.
3. **Scope creep back into systems** — if a beat wants new machinery, first ask whether
   staging can carry it; the milestone's power is that the systems already exist.
