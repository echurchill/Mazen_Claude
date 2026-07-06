# Design Note — Superellipsoid ("inflated") Cube

*Status: concept / future visual milestone. Captured 2026-07-05.*

## The idea in one line

Bulge the game cube's faces outward toward a **superellipsoid**, so the cube reads as a **small rounded world** — a continuous "roundness" dial from hard cube to puffed planet — especially to reinforce the M9 cube-solar-system.

## The math

A **superellipsoid** (a superquadric) is the 3D generalization of the superellipse. The symmetric form:

```
|x|ⁿ + |y|ⁿ + |z|ⁿ = 1
```

The exponent `n` dials **squareness continuously**:

- `n = 2` → a **sphere**
- `n → ∞` → a hard **cube**
- in between (e.g. `n = 4…8`) → a **rounded / inflated cube** — faces bulge, edges round off (the 3D "squircle")

Other names for the same look: inflated cube, puffed cube, bulged cube, cube-sphere. In graphics the **cube-sphere** family is the standard tool for turning a cube grid into a planet with low distortion.

## Why it fits this game

- **M9 synergy.** We already treat the cube as a mini-planet with a sun/moon, day/night, and shadows. A gently inflated cube *looks* like a small world instead of a die — the horizon curves, faces swell.
- **Free realism win for lighting.** M9's per-face day/night uses `surfDir = normalize(worldPosition)` for the terminator. On a flat cube, `surfDir` is a crude stand-in for the true surface normal; on an **inflated** cube the real normals bend toward `normalize(worldPosition)`, so the existing shading gets *more* physically correct as roundness increases. The two features reinforce each other.
- **Aesthetic.** Softer, more organic, more "board-game-planet" — on theme for "Rubik meets maze meets game board."

## Design sketch

- A single **roundness parameter** `r ∈ [0, 1]`: `0` = today's hard cube, `1` = maximum inflation (short of a sphere). Could be a fixed art choice, a setting, or **animated** (cube ⇄ planet morph — a great reveal/transition).
- The **maze topology is unchanged** — still an N×N grid per face, same adjacency, same slice logic. Only the **geometry (vertex positions + normals)** is remapped. Movement, openings, and the split/bandage mechanics all stay grid-based and untouched.

## Implementation notes

Today `CubeModel.worldMatrix(face:row:col:)` places each tile on a **flat** face:
`center = normal·halfN + tangent·colF + bitangent·rowF`, with the tile's basis = (tangent, bitangent, normal).

To inflate:

1. **Remap position.** Take the flat cube-surface point `P` (normalized to the unit cube, components in `[-1, 1]`) and push it onto the rounded surface. Two practical routes:
   - **Cube→sphere blend** (simplest knob): compute the low-distortion sphere point
     ```
     x' = x·√(1 − y²/2 − z²/2 + y²z²/3)   (and cyclic for y', z')
     ```
     then `P_round = lerp(P_cube, P_sphere, r)`. `r` is the roundness dial.
   - **True superellipsoid:** solve the `|x|ⁿ+|y|ⁿ+|z|ⁿ=1` radius along `P`'s direction and scale to it; map `r` → `n` (large n ≈ cube).
2. **Recompute the normal** from the rounded surface (gradient of the implicit form, or the analytic derivative of the cube→sphere map) so lighting, the player's up-vector, and the camera follow the curve. This is the step that makes it read as a world rather than a decal.
3. **Tiles tilt to follow the surface.** Each tile's basis is rebuilt from the local surface normal + tangents. At low `r` the tilt is subtle; watch tile **seams** where neighbours meet on the curve (may need slight overlap or edge-skirts).
4. **Everything else composes:** the world spin, slice `animMat`, and shadow pass all still multiply the same model matrices — they don't care that the base surface is curved.

## Open questions

- How much inflation reads well without distorting the maze/tiles uncomfortably — subtle bulge vs strong puff?
- Do slice **rotations** still look right on a curved cube? (A rotated slab of a superellipsoid is a curved slice sweeping through — probably *more* interesting, but verify it doesn't self-intersect visually at high `r`.)
- Seam/gap management between tiles on the curved surface.
- Cost: the remap is per-vertex; fine as a one-time layout if `r` is static, cheap in a vertex stage if animated.
- First-person camera very close to a curved floor — near-plane and horizon behaviour.

## Relationship to other work

- Sequenced next to **M9 (cube solar system)** — the planet reading is the main payoff, and the day/night shading already leans this way.
- Purely a **geometry/visual** change; orthogonal to the [Bandaged Cube Mechanic](Bandaged%20Cube%20Mechanic.md) and to M12 asset import.
- Could debut as an **animated cube→planet morph** transition rather than a static setting.
