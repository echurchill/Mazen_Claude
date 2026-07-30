# Routing — How Paths Live in the Cube

*Written 29 Jul 2026, answering Eddie's question: "explain the need for the route custom floor
tile and how the routing works from a data structure POV. It seems that the paths are actually
part of the data structures of the cube itself."*

**Short answer: you are reading it correctly.** The route *is* the cube's data structure. There
is no path object anywhere in the engine — no list of waypoints, no route graph, no "correct
path" the game holds and compares you against. A route is an emergent property of which walls
are missing, and nothing else.

That has a consequence worth stating up front, because it decides Scene 4 item #2: **a twist
edits the maze itself.** It is not a camera trick with a scripted "and now the door opens" —
the topology genuinely changes, and a route that did not exist before genuinely exists after.

---

## 1. Where a route actually lives

One field, four bits:

```swift
struct MazeTile {
    var openings: DirectionMask      // .north .east .south .west — 4 bits
    …
}
```

`DirectionMask` is an `OptionSet` over `UInt8`. Per tile, per face, four bits saying which of
its edges you can walk through. That is the entire routing model.

Everything else about walls is *derived* from it, every frame:

```swift
func edgeType(_ dir: SurfaceDirection) -> EdgeType {
    guard openings.contains(direction: dir) else { return .wall }
    return openEdges.contains(direction: dir) ? .open : .gateway
}
```

So "is there a wall here" is not stored. A wall is **the absence of an opening**, rendered. This
is why the dressed stone walls survive a twist without any special handling: they are re-emitted
from live topology each frame, so when the bits move, the stones move with them.

There are three layers, and it is worth keeping them separate in your head:

| Layer | Stored as | Decides |
|---|---|---|
| **Topology** | `MazeTile.openings` (4 bits/tile) | Whether a route exists at all |
| **Stand grid** | computed — `isStandable`, `edgeAllows` | Where within a tile your feet may be |
| **Decoration** | `Facelet.props`, `terrain`, `uvTurns` | What it looks like |

Only the top layer routes. The middle layer is the 15×15 sub-cell mask that makes movement
continuous rather than tile-to-tile, and it is *computed from* the topology (a gateway edge is
crossable only through its middle third, matching the visual gap the jambs flank). The bottom
layer cannot affect reachability at all.

## 2. So what is the "custom floor tile" for?

**Nothing routes it. It is a readout.** The precedent is already in the garden —
`stampGardenPath`, the stepping stones that mark the correct way through the hedge maze. Look at
how it decides where to put them:

```swift
// BFS distance from the spine over WALKABLE tiles (open edges), so the taper follows the maze.
for (ok, nt) in [(op.contains(.north), …), (op.contains(.south), …), …] where ok && …
```

It walks the `openings` bits with a breadth-first search, computes each tile's distance from the
intended spine, and scatters stones with a density that tapers as you get further from the
correct route. The stones are `props`. Delete every one of them and the maze is *identical* —
same walls, same reachability, same solution. You would simply have no visual hint.

That is the honest need for a custom floor on Scene 4's route: **legibility, not function.**
Scene 4's script asks for "recessed pathways and waist-high barriers rather than tall walls", on
a 5-cube where you can see several faces at once. With walls that low, the eye needs the floor to
say "this is a way through" and, crucially, "this way through *stops here*". The script's whole
premise is a route the player can see is incomplete:

> *"The pieces of a route exist."*

You cannot read a piece of something unless the pieces look like they were meant to join. A
distinct floor treatment is what makes the gap legible as a **gap** rather than as ordinary
dead-end maze. It carries no routing information the topology doesn't already have — it makes the
topology visible from across the world.

Two engine facts that make this cheap:

- `TerrainKind` already varies the floor per facelet (grass / water / regolith / plating), so a
  route floor is a new case plus a shader material, not new machinery.
- `MazeTile.uvTurns` already keeps floor textures glued to their tile through a twist, so a route
  floor will not pop or shear when the slab turns. That problem is solved.

## 3. What a twist does to the data

`applySliceRotation` is where the world genuinely changes. For every facelet on every cubie in
the slice:

1. Work out where the facelet's normal *was* pointing and where it now points.
2. Compare the rotated tangent against the new face's tangent and bitangent — this yields
   `quarterTurns` (0–3), how much the tile spun within its new face.
3. Rotate the data by that amount:

```swift
mazeTile.openings  = mazeTile.openings.rotated(quarterTurns: quarterTurns)
mazeTile.openEdges = mazeTile.openEdges.rotated(quarterTurns: quarterTurns)
mazeTile.uvTurns   = (mazeTile.uvTurns + quarterTurns) % 4     // floor stays glued
for pi in props.indices { props[pi].rotate(quarterTurns: quarterTurns) }
```

`rotated` is a 4-bit barrel roll — north becomes east, and so on. So the tile keeps its own
shape; what changes is **which of its neighbours its openings now face**.

This is why the twist is a real puzzle verb rather than set dressing. Two tiles that each had a
wall between them can end up with openings facing each other, and the route is now continuous —
with no code anywhere having decided "connect these". It falls out of rotating bitmasks.

Note what does **not** rotate: a prop's `facing` is *not* changed by a twist (found by probe, the
hard way, when Scene 2's portal arrived edge-on). Author props in their final orientation.

## 4. What this means for Scene 4 item #2

This is the snag I flagged, now with numbers behind it. Scene 4 is a 5-cube and its twistable
slab is the outer `+Z` slice. Measured, not remembered:

```
slab: axis 2, index 4 — 25 cubies of 98
  positiveZ: 25/25 tiles ride the slab      ← the player's whole face
  positiveX:  5/25       negativeX: 5/25
  positiveY:  5/25       negativeY: 5/25    ← a one-tile edge strip each
  negativeZ:  0/25                          ← the far side stays put
```

45 surface tiles ride; 105 stay. And here is the point:

**Every tile on `+Z` rotates together.** The player, the portal, the route fragments, the walls —
all of it, rigidly. Relative adjacency *within* `+Z` is therefore completely unchanged by the
turn. If the sealed route is entirely on the face you are standing on, the turn moves it and
changes nothing about whether you can walk it.

The only adjacencies the turn actually edits are the **20 crossings** where the four side-face
strips (5 tiles each) meet the static remainder of those faces. That is the whole of what a twist
can break and reform here.

Which is exactly what your script already says, and I should have read it more carefully before
raising this as an open question:

> *"The maze route leading toward it terminates against a closed wall at the boundary between
> the current outer slice and the rest of the world."* — Scene 4, line 141

So the design resolves itself:

- The portal sits on `+Z`, inside the slab, unreachable within `+Z` alone.
- The completing route **leaves the slab** — down over an edge onto a side face, across the
  static region, and back up into a strip.
- One of those strip↔static crossings is misaligned: the strip tile's opening faces a static
  tile's wall. Dead end, and visibly so if the route floor stops there.
- The turn carries the strips round (`-Z`→`-Y` clockwise, per the earlier probe), bringing a
  *different* strip tile against that static opening — one whose bits line up. Route complete.

This also gives the scene its circumnavigation for free: the three anchors are already on `-Z`,
`+Y` and `-Y`, so the player is walking the static region anyway and will *see* the misalignment
from the far side before they ever twist.

**One thing to verify before building it:** whether a route can cross the strip↔static boundary
cleanly given how `EdgeCrossing` conjugates directions over a cube edge. I would probe that with
a reachability test — before and after the turn — rather than reason about it, since edge
conjugation is precisely the sort of thing eyes and intuition both get wrong. The test would
assert the portal is unreachable at 0 anchors released and reachable after the turn, which is the
claim the scene actually rests on.

---

## Summary

- The route is `openings` — four bits per tile. Nothing else stores a path.
- Walls are the absence of openings, re-derived every frame; that is why they survive twists.
- A custom route floor is **decoration**: it makes an incomplete route legible on a low-walled
  world. The garden's stepping stones are the same idea, placed by BFS over the same bits.
- A twist rotates those bits, so reachability genuinely changes — no scripting.
- For Scene 4 the break must sit on the slab boundary, not inside the player's face, because a
  face rotating in place cannot change its own internal connectivity. Your script already
  specifies this.
