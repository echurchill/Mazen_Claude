# Engine Primer — Worlds, Twists, Travel

*A foundation for level & puzzle-dynamics research. Describes what the **engine actually supports**
today (Garden of Worlds, Metal 4 / Swift, macOS + iOS). Where something is latent-but-unused it is
marked **[latent]** — those are affordances, not promises.*

---

## 1. What a world is

A world is an **N×N×N cube of cubies**. Only the surface matters: each cubie face that lies on the
cube's exterior carries a **facelet**, and each facelet is one **tile** of walkable ground. So a
world presents **6 faces × N × N tiles**, and the tile grid is the play space.

`N` is clamped to **2…25** (`WorldScale.maxSupportedSize = 25`; the renderer's instance buffers are
provisioned for that ceiling). Worlds in play range from 3 (the moon) to 25. Odd sizes are
conventional — they give a true centre tile — but not enforced.

Every world owns its own `WorldScale`; nothing is global. Worlds of different sizes and shapes
coexist and are visible from each other.

### Two topologies

| | Where you walk | Notes |
|---|---|---|
| **Exterior** | outside surface of the cube | a planet; has sky, sun, stars, celestial bodies |
| **Interior** | inside faces of a hollow cube | enclosed; no sky, no celestials, lantern-lit |

Interior is one flag (`WorldScale.interior`). Crucially, **grid, maze and twist logic are
orientation-blind** — the same code runs both. Interior differs in only two places: the placement
basis points "up" *inward* (and mirrors the row axis, since you see a face from behind), and
adjacency is *conjugated* — an interior cell (r,c) occupies the same world spot as exterior
(N−1−r, c), so edge-crossing mirrors in, uses the proven exterior table, and mirrors back.

**This matters for puzzles:** on an interior world, "up" from *every* face points toward a single
shared centre. That is a genuine geometric fact you can build on, and it has no exterior analogue
(on a planet, "up" from each face diverges into space).

### Shape is cosmetic, topology is not

Two per-world dials deform the *render geometry* only:

- **`roundness` (0…1)** — blends the hard cube toward a sphere (Cobb √ mapping). A "planet" is
  roundness 1; a mechanistic world stays 0. Smaller cubes show curvature far more strongly.
- **`reliefAmplitude`** — pushes the surface radially by a height field (rolling hills, crater
  bowls with rims).

Neither changes the maze topology, movement, slice logic, or bandaging — all of those stay
grid-based. **Shape carries meaning without changing rules** (the project calls this
shape-as-meaning). A puzzle can rely on how a world *looks* without the geometry becoming variable.

---

## 2. The tile grid and movement

Each tile carries an **openings** mask over the four surface directions (N/E/S/W). An open edge is
walkable; a closed edge is a wall. That mask *is* the maze — walls are rendered from it (hedge
meshes, or imported stone models re-derived from live topology), and movement is blocked by it.

Within a tile there are two sub-grids:
- **`standGrid = 15`** — the movement sub-cells. The player occupies a sub-cell, not just a tile.
- **3×3** — the authoring grid for prop placement.

The distinction is load-bearing: a portal can require you to stand on its **centre sub-cell**, not
merely somewhere on its tile.

### The surface is a closed manifold

Walking off the edge of a face **continues onto the adjacent face**, with your facing direction
remapped (`EdgeCrossing.cross`). There are no borders and no falling off. You can circumnavigate
any world. Six faces meet at 8 corners, and those corner triple-points are the only topological
oddity — direction is continuous but not smoothly so.

**Consequence for design:** a route can leave the "level" you think you're on and arrive on another
face. Faces are not separate rooms; they are regions of one continuous surface.

---

## 3. Twist — the signature manipulation

The cube is a **Rubik's cube**. A twist rotates one **slice** by 90°.

A slice is defined by an **axis** (x/y/z = 0/1/2) and an **index** (0…N−1) — every cubie whose
position along that axis equals the index. Rotating it does three things at once:

1. **Permutes cubies** — the tiles physically move to new positions on the cube.
2. **Rotates each moved facelet's openings** — the maze rewires. A corridor that ran north–south
   may now run east–west, and connections across the slice boundary are severed and remade.
3. **Re-orients everything riding those tiles** — props, walls, portals, and the player if they are
   standing in the slice (position, facing, and standing sub-cell all rotate with it).

Texture orientation is tracked (`uvTurns`) so floors stay glued to their tiles rather than
snapping.

**Which slices can turn:** player-driven twists rotate the slice of the face the player is on —
i.e. the *outer* slice, index 0 or N−1 (`sliceAxisAndIndex(for:)`). The underlying machinery
accepts **any index**, so **middle-slice turns are [latent]** — supported by the model, simply not
exposed to input. That is a large unused design space.

There is also a scripted variant already in use: a puzzle solve can rotate a *chosen* slice — the
current "turn the world" reward rotates the **back** slab (the distant wall across your forward
edge) rather than the ground underfoot, purely for spectacle.

### Bandaging — the rule that makes twists puzzles

A **bond** is a set of cubies declared rigidly joined (`bondedGroups`). The rule:

> A twist is **refused** if any bonded group is *partly* in the slice — i.e. the group intersects
> the slice but is not wholly contained by it.

A refused twist is not silent: the slice strains a few degrees and springs back (the camera rides
the strain), teaching "locked" with no UI text.

This is the core puzzle primitive. Bonds make certain rotations illegal, so **the reachable
configuration space is authored, not free**. Dissolving a bond ("understanding undoes a lock")
re-opens twists that were previously refused.

### Sealed portals

A portal can be **sealed** — inert and dark. It opens only when *both*: its bond has been
dissolved, **and** a finalized twist of its slice has swung it open. So the canonical gate is
**"solve the lock, then turn the world."** Twist is the verb that commits the change.

### The twist-safety invariant (critical constraint)

Anything placed in a world must **ride its facelet** through a twist. Props are stored on facelets,
so they travel automatically. Anything *derived* — dressed walls, decorative scatter — must be
re-derived from live topology (openings, `uvTurns`) rather than from absolute position, or a twist
will scramble it. Caches are keyed on a `topologyVersion` that changes on every twist or prop
mutation.

**For puzzle design:** any mechanism must survive being rotated, mirrored onto another face, and
carried away from where it was authored. State that depends on absolute coordinates will break.

---

## 4. Travel — how worlds connect

Worlds connect through **portals** (props on tiles). Walking onto a portal's centre sub-cell — or
pressing the interact key on it — triggers a world switch. Portals have visual styles (stone arch,
elevator streak-curtain up/down, energy veil, TARDIS box) which are cosmetic, and semantic
properties which are not.

### The world stack

Navigation is a **stack**. Entering a world **pushes** it; a **return portal pops** back to
whatever pushed it. So sub-worlds nest: home → garden → temple, and the temple's exit returns you
to the garden. Two push rules exist alongside the default toggle behaviour: a *nested descend*
(entering the temple from an already-pushed world) and a *hub enter* (stepping out of the
navigation hub) both push rather than pop.

Worlds on the stack are **persistent** — you return to the state you left, twists and all.

### The world graph — worlds are route-keyed

This is the most unusual travel property. A world is identified **by the edge you arrive
through**, not merely by name:

```
WorldKey(destination: "moon", origin: "earth")
```

The registry maps keys to worlds, lazily created and persistent. Two consequences:

- **Identity-bound edges:** several keys can resolve to the *same* world — the moon you see in
  earth's sky *is* the moon you can visit, same object, same scars.
- **Variants [latent]:** different keys may resolve to *different* worlds — the same door, approached
  from elsewhere, yielding another interior (time periods, alternate realities). The mechanism
  exists; only identity-binding is currently used.

Design note already anticipated in the code: context could later extend beyond origin to include
**what the player knows**, so doors re-aim as understanding changes.

### Worlds in each other's skies

A world can hang in another's sky, rendered from its **real current state** — every twist you made
is visible on the body overhead — pushed out to an orbital offset. From a pushed world, the world
beneath you on the stack appears above you. This makes travel legible: you can *see* the place you
came from, and see it changed.

Each exterior world also has a sun with a day/night cycle, per-face lighting, and its own skybox
(a full-sphere equirectangular image, selectable per world).

---

## 5. Visibility and state

- **Discovery / fog:** tiles are `unknown → adjacent → discovered`. Unexplored regions are fogged;
  a world may reveal only an authored region. Fog is opt-out per world (`noFog`).
- **Props** live on facelets with a kind, a 3×3 sub-cell, a facing, a `state` integer, and two
  animation channels. Existing kinds include portals and their fields/rings, plinths, obelisks,
  switch bases/caps, an alignment cylinder, signposts (which render **text** via generated texture
  atlases), trees/foliage, and imported models.
- **Interaction** is currently a single verb: `F` = activate/interact with the prop on your tile.
  Movement, turning, and twist are the rest of the input surface.

---

## 6. Constraints worth designing against

1. **Size ≤ 25**, and the play region is usually far smaller than the face.
2. **Only outer slices are player-twistable** today; middle slices are latent.
3. **A twist is all-or-nothing** — 90°, whole slice, and it either completes or is refused.
4. **Bonds are the only twist restriction** — there is no per-tile "cannot rotate".
5. **Everything must be twist-safe** (see §3).
6. **Corner triple-points** are where face adjacency is most awkward; heavy structures there tend
   to reveal seams.
7. **Portals gate on a sub-cell**, giving precise trigger placement.

## 7. Fertile latent ground

Middle-slice twists · multi-slice or whole-world rotations · route-variant worlds (same door,
different destination by approach) · bonds as movable/placeable objects · interior worlds where
all six faces' "up" converges · using the counterpart-in-sky as a puzzle readout · knowledge-keyed
doors.
