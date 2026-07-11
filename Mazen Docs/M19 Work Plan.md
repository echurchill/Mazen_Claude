# M19 — Natural & Moon Worlds (work plan)

*Drafted 2026-07-11. The settings milestone: two authored worlds in the natural register —
a **Natureworld** (the garden world of the [Player Journey](Player%20Journey%20—%20A%20Session.md))
and a real **Moon** — at roundness ~1.0, walked with M18's mazeless movement. Inspiration +
first mechanical read: [Natural & Ring Worlds](Natural%20%26%20Ring%20Worlds%20—%20Inspiration.md)
(the three concept images). Seeds: Eddie's [Random Thoughts](Random%20Thoughts.md).
Prerequisite: **M18** (and M17 runs before the M20 walkthrough that stages these worlds).
Status: **📋 awaiting greenlight.***

## What M19 is (and isn't)

M19 builds the **worlds**: terrain registers (grass/water/regolith), trees and craters,
relief, authored per-world roundness, and their place in the world graph and sky. It does
NOT stage the story beats on them — the temple, dials, seam-grooves, and memory beats are
**M20 (Journey Walkthrough)**, which composes M15–M18's machinery inside M19's settings.
The split keeps this milestone judgeable on one question: *does standing on these worlds
feel like the concept images?*

**Scope steer (Eddie, 2026-07-11):** the Journey (M20) uses only a **small region** of the
Natureworld — the rest of the sphere is authored *loosely* now and used later in the game.
The Moon is **visible-only** for the Journey (a sky element; the story revisits it later on
the ground) — so Phase 3 is sky-quality first: it must be right in the home/garden sky at
concept-image fidelity, while its ground detail can trail behind everything else in this
plan without blocking M20. And per the world-graph's new
[time-periods section](World%20Graph%20—%20Relational%20Worlds.md), earth/moon may eventually
exist in **multiple era instances** — stamps should be written era-parameterizable-later
(one lineage, era-varied dressing), not hardcoded to a single now.

## Phases

### Phase 0 — World-authoring foundation
Per-world **authored roundness** finally lands (the long-parked M14b polish item — natural
worlds ≈ 1.0, home/mech worlds lower); per-world terrain palette (which floor materials a
world uses); new `WorldStamp` cases. A `.natural` stamp already exists as M18's test world —
this phase turns it from testbed into authoring surface.
*Danger:* Low. *Verify:* existing worlds byte-identical at their authored roundness.

### Phase 1 — Natureworld terrain
Grass floors everywhere; **water floors** (rivers/lakes) as a floor material whose cells are
subtracted from the walkability mask — with the maze gone, water becomes the routing (the
hedge wall's natural-register successor). **Forest clumps**: one footprint cell can draw
several trees of varied size (render density > collision density — the image's density
without a mask per trunk). The garden is *looser, not empty*: occasional hedge clusters and
garden features survive, per the Journey's "more like a garden than a labyrinth."
*Danger:* Med (first multi-material terrain authoring). *Verify:* wander it — does it read
as the Natural World image (minus seams)? Water blocks, trees dodge like trees.

### Phase 2 — Relief
Hills via floor-vertex displacement on M14b's tessellated floors, eye-height following the
same floor function (M18 left the hook). Gentle at first — rolling, not alpine. This is the
riskiest render work in the milestone (displacement must respect tile seams and inflation).
*Danger:* Med-High. *Verify:* seam-continuity at tile and cube edges with displacement on;
walk the hills — no floating, no sinking.

### Phase 3 — Moon World
The moon stops being a hedge demo: regolith floor material, **craters at several scales**
(relief bowls; where a crater should block, the **rim** is the footprint ring and the bowl
stays walkable), boulder-field props. Same body language as the Natureworld, in grey.
*Danger:* Low-Med (reuses Phases 1–2 machinery). *Verify:* the Moon World image test; the
killer visual still works — the cratered moon turning in the home sky.

### Phase 4 — World-graph & sky wiring
The Natureworld joins the registry as a new destination (the Journey's home world stays the
pastoral hedge world — the garden is *travelled to*); portals placed; counterpart visuals
(from the garden you see home turning overhead — the Journey's 0:01 beat). Interior worlds
under natural surfaces inherit nothing new — the peel is M20's to stage.
*Danger:* Low (M15's registry does the lifting). *Verify:* round trip home ↔ garden ↔ moon
with camera-mode transfer, correct skies, persistent scars.

### Phase 5 (stretch) — Ringworld spike
One question only: does an **equatorial band of a cube world** at high roundness read as the
toroidal ring image, or does a real torus need its own inflation branch in `m14bTransform`?
Timebox it; the walkable-not-twistable ring is its own future milestone either way.
*Danger:* Low (throwaway spike). *Verify:* a screenshot judged against the image.

**M19 exit criterion:** stand on the Natureworld and the Moon and have them read as their
concept images *from the ground*: grass/water/trees or regolith/craters, gentle relief,
round horizon, seams invisible, movement feeling like ground (M18's gate held). The worlds
are ready to be staged.

## Decision points for Eddie

- **D1 — The garden's place:** new destination world reached by portal from home
  (recommended — matches the Journey's 0:00 threshold beat) vs. converting the current
  overworld into it.
- **D2 — Water v1 ambition:** flat tinted-material floor cells, unwalkable (recommended)
  vs. animated/reflective water (M21 polish candidate).
- **D3 — Tree source:** procedural clump meshes in TileMeshLibrary (recommended — matches
  the stylized register and we control footprints) vs. imported models (M12 pipeline is
  ready if a good kit appears).
- **D4 — Relief amplitude:** subtle rolling only (recommended for v1 — comfort + seam risk)
  vs. real hills with occlusion gameplay (the Journey's "machine under the hill" wants at
  least one hill big enough to bury something — can be a single authored mound).
- **D5 — Ringworld spike:** inside M19 as Phase 5 (recommended — cheap while the inflation
  code is warm) vs. deferred entirely.

## Risks

1. **Displacement vs. seams/inflation (Phase 2)** — relief that breaks M14b's continuity
   would be visible everywhere. Mitigate: displacement in the same footprint-space the
   inflation consumes; seam tests before eyes.
2. **Register drift** — natural worlds must still be *this game* (stylized, tended, calm),
   not an asset-store biome. The concept images are the art direction; judge against them.
3. **Scope creep into staging** — no temples, dials, or beats here; M20 owns the story.
   M19 is done when the ground is convincing.
