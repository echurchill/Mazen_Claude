# Design Note — Bandaged Cube Mechanic ("bonded structures")

*Captured 2026-07-05 from the M12-E house work.*

> **Status: 🔨 foundation built (2026-07-07).** The **bond model + legality rule** are implemented and unit-tested (`CubeModel.bondedGroups` / `addBond` / `canRotateSlice`; the bandaged rule = every bonded group entirely in or entirely out of the slice). Verified across cube sizes 3/5/7/9 (`Tests/CoordinateMathTests.swift` → `testBandagedLegality`; bonds survive a full turn cycle, indices stay valid). The **enforcement point is wired** in `GameState.startSliceRotation` (refuses illegal twists; sets `twistRefused`) — currently **inert because nothing is bonded yet**. **Remaining (needs the screen):** bond the first structure (the house), a refusal **cue** (shake/tint/sound), and a visual **affordance** marking what's locked — plus the design conversation about *what you twist toward* (the goal).

## The idea in one line

Some multi-cubie structures should **bond** their cubies together so that any slice twist which would tear them apart is **illegal and refused** — turning the cube into a *bandaged* puzzle where buildings and walls constrain which twists are legal.

## Background — what a bandaged Rubik's cube is

A **bandaged cube** is a twisty-puzzle variant in which some adjacent pieces are physically **glued/bonded** into rigid blocks. The bonds don't add pieces — they **remove moves**: any turn whose slice plane would have to cut through a bonded block is blocked. The set of legal moves therefore becomes **position-dependent** (it changes as you turn), and solving gets subtler and often much harder. Real examples: Bandaged 3×3, Fused Cube, Bicube, Meffert's Bandaged.

## Why it fits this game

The prototype is "Rubik's cube meets hedge-maze meets game board." We already anchor multi-tile **structures** (the M12-E modular house spans four cubies) to the cube. Today those structures **tear** when a slice cuts them. Bandaging is the opposite, and arguably the richer, reading of the same setup:

- **Tear (current):** a slice through the house splits it apart — dramatic, but structures don't persist through play.
- **Bandage (proposed):** a slice through a bonded structure is **refused** — the structure is a solid landmark, and the player must plan a twist sequence that never illegally cuts it.

Bandaging makes the **maze + structures into the puzzle constraints**: to route the maze into a solvable state you must find a sequence of legal twists that respects every bond. That's a genuine puzzle layer on top of navigation.

Both can coexist: a per-structure flag — decorative structures **tear**, "solid" structures **bandage**.

## Design stance: twisting is deliberate, not ambient (from the M12-E house work)

A key realization from building the modular house: the twist mechanic **fights both the player and the content when it's always-on everywhere**. Twists are fast and hard to read (which is why we added the single-step debug control), and every multi-cubie structure has to be authored to survive being torn — expensive and fiddly.

The fix is to treat the twist as a **designed, level-scoped mechanic**, not ambient physics — and **bandaging is what makes that possible**. If most of the cube is bonded (twist-*locked*) by default, twisting becomes a **rare, deliberate, readable action** only in the places a level designs for it. That simultaneously resolves:

- **UX friction** — twists happen only where meaningful, so they can be slow, committed, telegraphed "moves" rather than surprise blender events.
- **Model complexity** — most structures never need to split, because they sit on locked cubies (or live *inside* a portal-world; see [Worlds & Portals](Worlds%20and%20Portals%20Plan.md)). Only hand-designed set-pieces split, as an intentional reveal.

So the guiding principle: **bandaging turns the twist from ambient chaos into a scalpel** handed to the player in specific puzzles. The default cube is stable to navigate; twisting is a special capability a level grants.

## Design sketch

- **Bond model.** A *bonded group* is a set of cubie indices that must always move together. Author it alongside a structure (the four house cubies become one bonded group). A cubie may belong to at most one group (v1).
- **Legality rule.** A slice twist (axis, index) is **legal** iff, for every bonded group, the slice contains **all** of the group's cubies or **none** of them. If any group is *partially* in the slice, the twist would tear it → **illegal**.
  - This is exactly the standard bandaged-cube legality test, expressed on our `cubieIndicesInSlice(axis:index:)`.
- **Enforcement point.** `GameState.startSliceRotation` already guards on `!sliceRotation.isActive && …`. Add a `canRotateSlice(axis:index:)` check in front of it; if illegal, don't start the twist — instead emit a **refusal cue** (a short shake/rebound of the slice, a "locked" sound, a brief tint on the bonded structure).
- **Legal twist carries the whole group.** When a legal twist *does* contain an entire bonded group, the group rotates rigidly with the slice — which already happens for free, because each cubie rides `applySliceRotation` and each prop rides `Prop.rotate`. Bonds add no new motion code; they only add the **veto**.
- **Feedback / affordance.** The player needs to *see* why a twist is refused. Options: highlight the bonded structure that would be torn; show the bond as a visible "brace/strut"; a HUD line ("twist locked — would split the manor").

## Implementation notes

- **Data:** `var bondedGroups: [Set<Int>]` on `CubeModel` (cubie indices). A structure stamps its group when it's placed (the M12-E house loop is the natural spot).
- **Check (cheap):** for a candidate `(axis, index)`, `let slice = Set(cubieIndicesInSlice(axis:index:))`; illegal if any group satisfies `!group.isDisjoint(with: slice) && !group.isSubset(of: slice)`.
- **Group identity through twists:** groups are sets of *cubie indices*, and `applySliceRotation` moves cubies (updates their `position`/`orientation`) but does **not** reindex the `cubies` array — so a group's index set stays valid across twists. Confirm this invariant before building on it.
- **Solvability guard (important):** bonds can *over*-constrain and deadlock the cube (no legal twist reaches the goal). Any generator that places bonded structures must verify the target state is still reachable — or bonds must be authored by hand on known-solvable layouts.

## Open questions

- How are bonds authored — per structure kind, or a general "bond these tiles" stamp?
- Do bonds interact with the **fog/discovery** system (can you bandage a structure you haven't revealed)?
- Difficulty tuning: how many bonded structures before the cube locks up?
- Mixed model: should a single structure be able to *partially* bond (some seams tear, some hold)?
- Visual language for "this is solid / bonded" vs "this will tear."

## Relationship to other work

- **M12-E house** is the first candidate bonded structure (four cubies, already one logical unit).
- Pairs naturally with a **"solid vs decorative" structure flag** in the prop/structure system.
- Independent of the [Superellipsoid Cube](Superellipsoid%20Cube.md) visual track — they can land in either order.
