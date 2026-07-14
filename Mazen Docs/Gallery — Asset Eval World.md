# Gallery — Asset Evaluation World (dev tool)

*A flat grass world laid out as a grid of every prop / foliage variant, one per cell, so assets
can be evaluated in near-isolation. Built 2026-07-14 at Eddie's request ("a place where all the
textures/props can be placed in a grid… and a way to specify which one I'm referring to").*

## How to use it
- **Press `Y`** to fade into the gallery (a `.gallery` world, reached like any portal world). Press
  `Y` (or walk into the return portal by the spawn) to leave.
- You spawn at the south edge facing **north** into the grid; walk up to any item.
- **Press `H`** for the debug HUD — the **`Here:`** line names the prop on your current tile. For
  foliage it names the exact LeafSet, e.g. `Here: foliageCard → LeafSet022 (slice 4)`. That is how
  you refer to one: just tell me the name/slice the HUD shows (or the grid position below).

## The grid (row-major, nearest row first)
5 columns; the catalog fills left→right, near row→far row. Position = `(row r, col c)` counting the
grid from its near-left corner (r = 0 nearest).

| # | grid (r,c) | item | notes |
|---|---|---|---|
| 0 | 0,0 | topiary | green ellipsoid bush (old placeholder) |
| 1 | 0,1 | obelisk | tall stone landmark |
| 2 | 0,2 | chest | wooden |
| 3 | 0,3 | dial [0] | grey / unaligned |
| 4 | 0,4 | dial [1] | gold / aligned |
| 5 | 1,0 | glyph | carved plaque |
| 6 | 1,1 | tree [0] | conifer, small |
| 7 | 1,2 | tree [1] | conifer, medium |
| 8 | 1,3 | tree [2] | conifer, large |
| 9 | 1,4 | treeTrunk | the solid trunk (usually under a tree) |
| 10 | 2,0 | boulder [0] | small |
| 11 | 2,1 | boulder [1] | medium |
| 12 | 2,2 | boulder [2] | large |
| 13 | 2,3 | foliageCard → LeafSet004 | alpha-cutout leaf card |
| 14 | 2,4 | foliageCard → LeafSet010 | |
| 15 | 3,0 | foliageCard → LeafSet014 | |
| 16 | 3,1 | foliageCard → LeafSet017 | |
| 17 | 3,2 | foliageCard → LeafSet022 | |
| 18 | 3,3 | foliageCard → LeafSet023 | |
| 19 | 3,4 | foliageCard → LeafSet024 | (the one wired first) |
| 20 | 4,0 | foliageCard → LeafSet030 | |

*(The single source of truth is `CubeModel.galleryCatalog`; this table mirrors it. The `Here:`
HUD line is authoritative if they ever drift.)*

## Growing it
As new asset layers land, append to `CubeModel.galleryCatalog` and they appear in the grid
automatically (and the HUD names them). Planned next: **misc_greenery** undergrowth cards,
**WenrexaTrees** billboard sprites, the **pinetree** imported model, and a row of **hedge-texture**
wall segments (para pack). The world is size 15, flat (roundness 0), sealed + region-revealed, so
it stays a clean isolated showroom.
