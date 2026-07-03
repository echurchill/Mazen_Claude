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
    /// Largest cube size the renderer's instance buffers are provisioned for.
    static let maxSupportedSize = 25

    let cubeSize: Int

    // MARK: - Tile geometry & spacing
    /// Distance between adjacent tile centers (historically tileSize 1.0 + gap 0.01).
    /// The M10 gap-removal decision sets this to 1.0 here, in one place.
    var cellSpacing: Float = 1.01
    /// Full width of a tile's wall footprint.
    var tileMeshSize: Float = 0.98
    /// Half-width of the floor quad (slightly inset from the walls).
    var floorHalfSize: Float = 0.48
    var floorY: Float = 0.001

    /// Distance between adjacent 3×3 sub-cell centers, in a tile's local frame.
    var subCellStep: Float { 2.0 * floorHalfSize / 3.0 }
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
    var cameraFarZ: Float = 100.0

    init(cubeSize: Int) {
        self.cubeSize = cubeSize
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
    /// Half-extent of the shadow map's orthographic frustum. 8 at size 5.
    var shadowOrthoRadius: Float { 1.6 * sizeF }
    /// Distance of the shadow-casting light from the cube center. 15 at size 5.
    var lightDistance: Float { 3.0 * sizeF }
    /// Shadow frustum near plane. 5 at size 5.
    var shadowNearZ: Float { 1.0 * sizeF }
    /// Shadow frustum far plane. 25 at size 5.
    var shadowFarZ: Float { 5.0 * sizeF }

    var orbitFOVRadians: Float { orbitFOVDegrees / 180.0 * .pi }
    var firstPersonFOVRadians: Float { firstPersonFOVDegrees / 180.0 * .pi }
}
