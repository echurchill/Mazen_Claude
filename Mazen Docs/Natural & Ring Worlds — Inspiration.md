# Natural & Ring Worlds — Inspiration (M19 seeds)

*2026-07-11 — Eddie added three concept images (this folder) plus seed notes in
[Random Thoughts](Random%20Thoughts.md). Capture + first mechanical read. The visible dark
seams in the images predate the game's real geometry — **ignore them** (Eddie).*

## The images

1. **[Natural World](Natural%20World.png)** — a fully green sphere at roundness ~1.0: dense
   conifer forest with real variation (clumps, clearings), **rivers and lakes** threading
   between the stands, visible ground relief. No paths, no maze — a garden left to grow.
2. **[Moon World](Moon%20World.png)** — the same body language in grey: regolith texture,
   **craters at many scales with raised rims**, boulder fields. Desolate but sculpted.
3. **[Natural World with World Builder Toroidal](Natural%20World%20with%20World%20Builder%20Toroidal.png)**
   — the natural world encircled by a **mechanical toroidal ring**: dense greebled machinery,
   pipes, panels, small glowing elements. The gardener's scaffold around the garden — the
   engineered truth made visible, *encircling* the natural surface instead of hiding under it.

## Eddie's seed notes (from Random Thoughts)

- **Ringworld** — *a walkable but not twistable ring around a traditional world.*
- **Natureworld** — no mazes; grass floors; **"water" floors**; trees of different sizes and
  density where there's no water; hills / relief (?).

## First mechanical read (how this lands on what we have)

### Natureworld → M18/M19, mostly already planned
- **No mazes / grass floors** — exactly M18's wall-less stamp + walkable-by-default mask.
- **Water floors** — a second floor material that is (presumably) *unwalkable*: just cells
  subtracted from the walkability mask by terrain type rather than by prop. The mask gains a
  notion of *why* a cell is closed (wall / prop / water) only if we ever need different
  feedback at the boundary (a splash-refusal vs a bump). Rivers as connectivity shapers are
  the natural world's replacement for hedge walls — the maze dissolves, the *routing* remains.
- **Trees of different sizes and density** — footprint props; crucially, **render density can
  exceed collision density**: a cell blocked by "forest" can draw a clump of several trees of
  varied scale. One footprint, many trunks — the image's density without a mask per trunk.
- **Hills / relief** — M19 authoring on M14b's tessellated floors (already fenced in the M18
  plan: eye-height follows the floor function; M18 builds the hook, nothing more).
- **Craters** — relief bowls; if a crater should trap or block, its **rim** is the footprint
  (a ring of closed cells) while the bowl stays walkable. Cheap drama.

### Ringworld → a surprisingly good fit for the existing engine (sketch)
A ring is *not* a new surface topology if we build it as **the equatorial band of a cube
world**: keep only the four side faces' middle rows walkable (poles closed), and at high
roundness the footprint-projection inflates the band toward an **annulus with a squarish
cross-section** — visually a ring, mechanically still tiles + edge crossings that already
work. "Walkable but not twistable" = a world with no legal slices (fully bonded, or slice
input disabled per-world) — M13's machinery already expresses this. Open questions for its
own design pass: does the projection of a band-only cube actually read as the image's torus
(or does it need its own inflation map — a real torus map is a different `m14bTransform`
branch); what stands on it (machinery props); and whether the ring is its own world in the
registry (`ring-earth`?) reached by portal, hanging in the sky like the moon does — **the
killer visual pattern again**: from the garden you'd see the gardener's ring turning overhead.

### Canon note
The "World Builder" name says it plainly: the ring is the **machine that built (or tends) the
world it encircles** — Builders' infrastructure at planetary scale. It slots directly into the
engineered-truth thesis and the [Builder Glyphs](Builder%20Glyphs%20—%204D%20Shadows.md) /
[NPC Classes](NPC%20Classes.md) frame (an *embedded machine* NPC at the largest possible
scale — a ring that remembers what it grew). The moon's sculpted craters and the garden's
routed rivers are the same statement at smaller scales: nothing here is wild; all of it is
tended.
