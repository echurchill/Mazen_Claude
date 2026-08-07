import simd

/// Single source of truth for all world-scale constants — **per world**. A game
/// world (and, later, the M11 moon world) each own a `WorldScale`; it is never a
/// global singleton, so different worlds can carry different scales.
///
/// Two kinds of value live here:
///
///  * **Tuning knobs** — tile/wall dimensions, eye height, field of view. The M10
///    Phase A perceptual scale-up and the inter-tile gap-removal decision become
///    one-file changes here instead of edits scattered across CameraState,
///    TileMeshLibrary, and CubeModel.
///
///  * **Cube-size-derived world extents** — orbit distance, shadow volume, light
///    distance. These are computed from `cubeSize`, so changing the cube (5³ → 7³/9³)
///    needs no other edits. The coefficients are chosen to reproduce the historical
///    size-5 values exactly, keeping the R1 refactor behavior-neutral.
struct WorldScale {
    /// Largest cube size the engine supports (R2.16). The renderer's instance buffers are
    /// provisioned for this size, and `init` clamps `cubeSize` to it — so a world larger than
    /// the buffers can hold is impossible to construct, by design (Eddie's cap, 2026-07-10).
    static let maxSupportedSize = 25

    let cubeSize: Int

    /// M15.1: an **interior** world — the maze lives on the *inside* faces of a hollow cube (the
    /// temples/homes you break into). Consumed by `CubeModel.restMatrix`/`inflatedPlacement` (the
    /// placement basis points "up" inward and mirrors the row axis — seeing a face from behind is
    /// a mirror image), by `CubeModel.edgeCrossing` (conjugated adjacency), and by the renderer
    /// (no sky, no celestials, lantern light). Grid/maze/twist logic is orientation-blind.
    let interior: Bool

    // MARK: - Tile geometry & spacing
    /// Distance between adjacent tile centers. 1.0 (M10 decision #5 gap removal) so
    /// adjacent floors meet seamlessly instead of showing a dark trench across plazas.
    var cellSpacing: Float = 1.0
    /// Full width of a tile's wall footprint. Equal to cellSpacing so collinear wall
    /// segments meet edge-to-edge (continuous hedge, no joint crack). They don't
    /// z-fight: outer faces are adjacent (not overlapping) and the end caps at the
    /// shared boundary sit back-to-back with opposite normals (one is always culled).
    var tileMeshSize: Float = 1.0
    /// Half-width of the floor quad — fills the whole cell (cellSpacing/2) so adjacent
    /// floors abut edge-to-edge with no seam.
    var floorHalfSize: Float = 0.5
    var floorY: Float = 0.001

    /// Distance between adjacent 3×3 sub-cell centers, in a tile's local frame.
    /// This is the PROP/AUTHOR grid — prop placement stays 3×3; movement uses `standGrid`.
    var subCellStep: Float { 2.0 * floorHalfSize / 3.0 }

    /// M18 Phase 0: the STAND grid — standing spots per tile side. Movement runs on this
    /// finer d×d grid while props keep the 3×3 author grid above. Must be an **odd multiple
    /// of 3** (9, 15, 21…): ×3 keeps every legacy 3×3 coordinate an exact integer scale-up,
    /// odd keeps a true centre cell (spawn/portal seating/twist-remap rounding rely on one).
    /// Walking pace is normalized to this in PlayerState, so density never changes speed.
    /// Per-world on purpose — interiors may want finer (M18 D4).
    /// 15 (≈1.3 m/step at perceptual scale — a natural stride) is the default (Eddie, M18 P3).
    var standGrid: Int = 15
    /// Distance between adjacent stand-cell centers, in a tile's local frame.
    var standStep: Float { 2.0 * floorHalfSize / Float(standGrid) }
    /// M14b: how many times to subdivide each floor sub-cell edge, so the floor has enough
    /// interior vertices to follow the curved (inflated) surface smoothly instead of faceting.
    /// 1 = today's single quad per sub-cell; 3 → a 3×3 grid per sub-cell (9×9 per tile). Render-
    /// only; the maze grid/topology is unaffected.
    var floorTess: Int = 3
    /// M14b: subdivisions of each wall face along its length / height, so hedges bend to follow the
    /// curved floor (base hugs the ground, no chord gaps) instead of standing as flat slabs. Height
    /// dominates the bending, so it gets more. Render-only.
    var wallTessLen: Int = 2
    var wallTessHeight: Int = 3
    var uvScale: Float = 2.0
    // M10 Phase A perceptual scale-up: the player is shrunk ~5x relative to a tile,
    // so a tile reads as a ~19m plaza instead of a ~3.7m corridor. Walls keep their
    // real-world height (~4.5m) — 0.24 units against a 0.09 eye — so they still read
    // as tall hedges around a much larger floor. (Anchored to eyeHeight ≈ 1.7m.)
    var wallHeight: Float = 0.24
    var wallThickness: Float = 0.07
    /// Width of a gateway's centered gap as a fraction of the edge (M10 Phase B).
    /// One-third aligns the gap with the middle sub-cell of the Phase C 3×3 grid.
    var gatewayGapFraction: Float = 1.0 / 3.0

    // MARK: - Camera
    var orbitFOVDegrees: Float = 70.0
    /// Narrower than orbit to tame the wide-angle "miniature" look that a very low
    /// first-person eye otherwise produces (M10 Phase A).
    var firstPersonFOVDegrees: Float = 58.0
    var eyeHeight: Float = 0.09
    var cameraNearZ: Float = 0.01
    // Far enough to contain the M9 sun (orbit 176 + half-size 5.5) seen from the orbit camera at
    // its max zoom-out (3·size) on the far side, with margin. Anchored: exactly the historical 220
    // for sizes ≤ 10; grows for the larger dev sizes (R2.16 — at size 25 the max-zoom camera sits
    // at 75, and a fixed 220 would clip the sun on the opposite side).
    var cameraFarZ: Float { max(220.0, 3.0 * sizeF + 190.0) }

    init(cubeSize: Int, interior: Bool = false) {
        // R2.16: hard upper limit — clamp rather than trust callers, so nothing can ever build
        // a world bigger than the instance buffers are provisioned for. (Lower bound 2 keeps the
        // math meaningful; the game itself uses 3+.)
        self.cubeSize = min(max(cubeSize, 2), Self.maxSupportedSize)
        self.interior = interior
    }

    // MARK: - Derived world extents (scale with cube size; exact at size 5)
    private var sizeF: Float { Float(cubeSize) }

    /// Half-width of the cube in world units — the face plane distance from the origin
    /// (`worldMatrix`'s `halfN`).
    var faceDistance: Float { sizeF / 2.0 }
    /// Orbit-camera default framing distance. 12 at size 5.
    var orbitDistance: Float { 2.4 * sizeF }
    /// Closest / farthest the user may zoom the orbit camera. 5 / 15 at size 5.
    var orbitDistanceMin: Float { 1.0 * sizeF }
    var orbitDistanceMax: Float { 3.0 * sizeF }
    /// Half-extent of the shadow map's orthographic frustum. Covers the cube's
    /// projected half-diagonal (~0.87·size) with margin.
    var shadowOrthoRadius: Float { 1.1 * sizeF }
    /// Distance of the shadow-casting light from the cube center.
    var lightDistance: Float { 3.0 * sizeF }
    /// Shadow frustum near/far — hug the cube (center at lightDistance = 3·size, cube
    /// half-diagonal ~0.87·size) so the depth range stays tight and the bias small in
    /// world units. Loose ranges were the source of the M10-scale shadow acne.
    var shadowNearZ: Float { 1.8 * sizeF }
    var shadowFarZ: Float { 4.2 * sizeF }

    var orbitFOVRadians: Float { orbitFOVDegrees / 180.0 * .pi }
    var firstPersonFOVRadians: Float { firstPersonFOVDegrees / 180.0 * .pi }
}

/// The portal disc's proportions. In the MODEL layer, not the mesh library, because the model needs
/// them: Scene 3's targeting beam aims at the top of the disc, and `GameState` cannot see the
/// renderer — the standalone test harness compiles the model without any of it. `TileMeshLibrary`
/// builds the mesh from these same numbers, so the geometry and everything that aims at it cannot
/// disagree.
enum PortalDisc {
    /// ~3.4 m across.
    static let radius: Float = 0.09
    /// × radius: how far below the floor the bottom sits — 10% of the diameter, so it reads planted.
    static let sink: Float = 0.2
    /// Centre height, in the tile's local frame.
    static func centre(floorY: Float) -> Float { floorY - sink * radius + radius }
    /// Highest point, measured from the floor — what a beam should aim at.
    static func topAboveFloor(floorY: Float) -> Float { centre(floorY: floorY) + radius - floorY }
}
