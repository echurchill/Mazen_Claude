# M17 — Learning & Memory, First Pass (work plan)

*Drafted 2026-07-11 (evening), the day the core loop became playable. Goal: prototype the
**knowledge-is-transportation** pillar — pick up a memory, and it changes what you can perceive
and where you can go. Companions: [Design Synthesis](Garden%20of%20Worlds%20—%20Design%20Synthesis.md)
(memory-as-key), [Builder Glyphs](Builder%20Glyphs%20—%204D%20Shadows.md) (motes = section *sweeps*;
memory teaches glyphs), [World Graph](World%20Graph%20—%20Relational%20Worlds.md) (knowledge in the
edge key re-aims doors), [Player Journey §0:22](Player%20Journey%20—%20A%20Session.md) (the beat this
builds). The pedestal — and its carved plaque — already stand in the temple hall waiting.
Statuses: **📋 awaiting greenlight.***

## The scope guard, first

M17 is a *first pass* at three things: **receive** a memory, **carry** knowledge across worlds,
and have knowledge **change perception + open a way**. It is NOT: the glyph forge/language
system, the memory-*editing*/forgetting verb, the library UI as a real place, or NPC memory.
One hand-authored glyph identity ("the temple mark") is the entire vocabulary.

## Phases

### Phase 0 — Knowledge lives with the PLAYER, not a world
Today every `GameState` owns everything; but knowledge must cross worlds (that's the whole
point). A small `PlayerKnowledge` object (e.g. `knownGlyphs: Set<String>`, `receivedMotes:
Set<String>`) owned at the Renderer level beside the world registry, readable by every world's
scene build + interact.
*Danger:* Low. *Verify:* tests for the container; knowledge visible from two different worlds.

### Phase 1 — The mote + the receive beat
A `mote` prop (new PropKind): a small, softly pulsing form floating above the temple pedestal —
the first thing in the game that visibly *doesn't* belong to the pastoral register. Walking onto
its tile (or `F`) **receives** it: the mote fades from the pedestal, and the receive beat plays
(D1). Its identity: the temple glyph.
*Danger:* Low-Med (first "vision" presentation; keep the v1 humble). *Verify:* feel pass.

### Phase 2 — Perception changes: the glyphs light up
The first honest "understanding rewrites perception": once the temple glyph is *known*, **every
plaque carrying it glows softly** — the dials' plaques, the lock face, the pedestal plaque, in
every world, forever. The world is suddenly annotated — because *you* changed, not it.
(Implementation: plaque color/emissive keyed off `PlayerKnowledge` in SceneBuilder — the same
pattern as the lock livery.)
*Danger:* Low. *Verify:* receive the mote inside → walk out → the overworld plaques glow.

### Phase 3 — Knowledge opens a way (the M17 payoff)
Knowledge must *transport*, not just decorate. First pass (D4): a **second sealed door** somewhere
on the overworld whose seal is keyed to the glyph — no dials this time: it unseals the moment its
glyph is known (walk up to it after the mote: it simply… opens for you). Where it leads: a small
second interior variant — the first **knowledge-gated edge** in the world graph (and the seed of
"doors re-aim by what you know").
*Danger:* Med (this is new design surface; keep the destination a stub). *Verify:* before the
mote: sealed. After: open. The player never touches a mechanism — knowing IS the key.

### Phase 4 — The memory surface (minimal)
Not the library-world (that's later). Just: the HUD (or a held key, e.g. `Tab`) shows what you
carry — the glyph(s) you know, drawn as their actual shapes. Enough to make knowledge feel like
*inventory of understanding* without building UI chrome.
*Danger:* Low. *Verify:* visual.

**M17 exit criterion:** enter the temple ignorant → receive the mote → the world's glyphs light
up across every world → a door that was sealed opens *because you know* → step through. The
knowledge-is-transportation pillar, playable.

## Decision points for Eddie

- **D1 — The receive beat.** (a) *Humble v1 (recommended):* a slow warm flash + the mote drifting
  into the camera + the glyph-glow flipping on — no vision content yet; (b) *Orbit vision:* fade
  to a few seconds of the overworld slowly turning in orbit view — "the garden as the Builders
  saw it" — then back (uses existing rendering; more evocative, more plumbing).
- **D2 — Knowledge container:** player-global `PlayerKnowledge` at the Renderer level
  (recommended) vs. per-world with sync (not recommended — knowledge that forgets when you
  travel contradicts the pillar).
- **D3 — First perception change:** known-glyph plaques glow (recommended) vs. something bigger
  (hidden geometry reveal — defer to M19's authored worlds).
- **D4 — The knowledge gate:** a second knowledge-sealed door on the overworld (recommended) vs.
  re-aiming an EXISTING door (the moon door leads somewhere new once you know the glyph —
  spookier, but changes behavior the player already learned; better saved for when the sky can
  lie in M18).
- **D5 — Phase 4 (memory surface) now or defer** to M20 polish.

## Risks
1. **Scope creep into the language system** — one glyph, hand-authored, is the whole vocabulary.
   The forge stays unscheduled.
2. **The receive beat under-landing** — it's the game's first "wonder" beat; if the humble v1
   feels flat, note it and move on — presentation polish is M20's job, the *mechanics* are M17's.
3. **Knowledge-gate legibility** — a door that opens "by itself" must read as *because I know*,
   not "buggy door": the door's plaque glowing (Phase 2) as you approach is the tell. Watch it
   in the feel pass.
