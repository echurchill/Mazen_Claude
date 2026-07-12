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

### Phase 0 — World-authoring foundation — ✅ first pass (2026-07-11)
Per-world **authored roundness** landed as a stamp default (`.natural` → 1.0, set in
`CubeModel.init`; other worlds unchanged at 0 — Eddie's "natural worlds use roundness 1.0").
Terrain palette = the new `TerrainKind` (`maze`/`grass`/`water`) per facelet. The `.natural`
`WorldStamp` graduated from M18 testbed to the authored Natureworld.
*Remaining:* a cleaner authored-roundness home (per-world, not a stamp `if`) when a second
natural world needs a different value; existing worlds confirmed unaffected (0 default).

### Phase 1 — Natureworld terrain — ✅ verified (Eddie: "Looks good", 2026-07-12); richness pass ongoing
Built: **grass** ground everywhere (material 14 — the moss texture recoloured to meadow green
+ per-tile hue drift, no walls, full-tile `fieldFloor` mesh); **water** (material 15 — flat
blue, soft specular + slow shimmer) as a **meandering stream** down the arrival face, *not
walkable* (PlayerState refuses entry — you follow the banks, so water is the routing that
hedges used to be); **conifers** over the whole planet — a `.tree` prop (two stacked green
cones) on a solid `.treeTrunk` (brown), scattered ~30% by a deterministic spatial hash, in
three sizes (state 0/1/2, SceneBuilder scales) so a stand reads as a forest not a row of
clones. The crown is walk-through (overhangs), the trunk is the solid footprint. Verified:
build clean, 208,761 headless checks green, natural-render path boots without crash (temp
boot-into-natural smoke test, reverted). **NOT yet verified: the actual look** — press **B**,
does it read as the Natural World concept image? *Danger:* Med. *Verify:* Eddie's eyes on B.
*Deferred to a later pass:* forest **clumps** (several trunks per footprint cell for the
image's density), and the "looser garden" hedge-cluster mix (this pass is pure natural).

### Phase 2 — Relief
Hills via floor-vertex displacement on M14b's tessellated floors, eye-height following the
same floor function (M18 left the hook). Gentle at first — rolling, not alpine. This is the
riskiest render work in the milestone (displacement must respect tile seams and inflation).
*Danger:* Med-High. *Verify:* seam-continuity at tile and cube edges with displacement on;
walk the hills — no floating, no sinking.

### Phase 3 — Moon World — 🔨 first pass built 2026-07-12 (awaiting Eddie's eyes)
Built: the moon stops being a hedge demo. New `.lunar` stamp — open grey **regolith** (shader
material 16: moss texture desaturated to grey with a strong per-tile brightness drift, mottled/
pocked, no walls), **boulders** scattered ~38% (a squashed faceted grey rock, three sizes via
`state`, solid), a walk-through portal home, roundness 1.0. The moon world (both the sky
counterpart AND the O-key visit) now uses `.lunar` — so the **killer visual is fixed**: earth's
sky showed a *green hedge cube*; it's now a grey moon. Verified: 221,001 headless checks green
(lunar connectivity added), build clean, lunar render path boots without crash (temp smoke test,
reverted). **NOT yet visually verified** — Eddie's eyes on the sky-moon + an O-key visit.
*Deferred to the relief pass:* **craters** (rim rings + bowls need M19 relief); the moon stays
flat-per-tile for now. Size is still 3³ (coarse — fine as a sky object; a ground revisit may
want more per the scope steer).

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
