import simd

// MARK: - Core identifiers

struct CubieID: Hashable {
    let rawValue: Int
}

struct FaceletID: Hashable {
    let rawValue: Int
}

// MARK: - Enumerations

enum CubeFace: Int, CaseIterable {
    case positiveX = 0  // right
    case negativeX      // left
    case positiveY      // top
    case negativeY      // bottom
    case positiveZ      // front (toward camera)
    case negativeZ      // back

    var normal: SIMD3<Float> {
        switch self {
        case .positiveX: return SIMD3( 1,  0,  0)
        case .negativeX: return SIMD3(-1,  0,  0)
        case .positiveY: return SIMD3( 0,  1,  0)
        case .negativeY: return SIMD3( 0, -1,  0)
        case .positiveZ: return SIMD3( 0,  0,  1)
        case .negativeZ: return SIMD3( 0,  0, -1)
        }
    }

    var tangent: SIMD3<Float> {
        switch self {
        case .positiveX: return SIMD3( 0,  0, -1)
        case .negativeX: return SIMD3( 0,  0,  1)
        case .positiveY: return SIMD3( 1,  0,  0)
        case .negativeY: return SIMD3( 1,  0,  0)
        case .positiveZ: return SIMD3( 1,  0,  0)
        case .negativeZ: return SIMD3(-1,  0,  0)
        }
    }

    var bitangent: SIMD3<Float> {
        return cross(normal, tangent)
    }
}

enum SurfaceDirection: Int, CaseIterable {
    case north = 0
    case east
    case south
    case west

    var opposite: SurfaceDirection {
        switch self {
        case .north: return .south
        case .south: return .north
        case .east: return .west
        case .west: return .east
        }
    }
}

enum TileState: Int {
    case unknown = 0
    case adjacent
    case discovered
}

struct DirectionMask: OptionSet {
    let rawValue: UInt8

    static let north = DirectionMask(rawValue: 1 << 0)
    static let east  = DirectionMask(rawValue: 1 << 1)
    static let south = DirectionMask(rawValue: 1 << 2)
    static let west  = DirectionMask(rawValue: 1 << 3)

    static let all: DirectionMask = [.north, .east, .south, .west]

    func rotated(quarterTurns: Int) -> DirectionMask {
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns == 0 { return self }
        let bits = self.rawValue & 0x0F
        let rotated = ((bits << turns) | (bits >> (4 - turns))) & 0x0F
        return DirectionMask(rawValue: rotated)
    }

    func contains(direction: SurfaceDirection) -> Bool {
        switch direction {
        case .north: return contains(.north)
        case .east:  return contains(.east)
        case .south: return contains(.south)
        case .west:  return contains(.west)
        }
    }
}

// MARK: - Data structures

/// How a tile edge is realized geometrically (M10 Phase B).
///  - `wall`: a full-height solid wall slab.
///  - `gateway`: a wall with a centered gap (two stubs) — a passable opening framed
///     by jamb posts. Every ordinary maze passage is a gateway.
///  - `open`: no geometry at all — reserved for merged multi-tile rooms (Phase F).
///
/// Through Phase B, an edge's type is derived from `MazeTile.openings` (gateway where
/// the passage is open, wall where closed); `open` is not produced until rooms arrive,
/// at which point `edges` becomes stored state and `openings` a computed shim.
enum EdgeType: UInt8 {
    case wall, gateway, open
}

struct MazeTile {
    var openings: DirectionMask
    var styleSeed: UInt32

    /// Geometric type of one edge, derived from connectivity (Phase B).
    func edgeType(_ dir: SurfaceDirection) -> EdgeType {
        openings.contains(direction: dir) ? .gateway : .wall
    }

    /// Whether sub-cell (subRow, subCol) of the 3×3 grid is a path cell (M10 Phase C).
    /// The path is a cross: the center, plus the middle cell of each open (gateway)
    /// edge. subRow 0 = north, 2 = south; subCol 0 = west, 2 = east. Corners are never
    /// path — they are propSpace, reserved for props.
    func isPathCell(_ subRow: Int, _ subCol: Int) -> Bool {
        switch (subRow, subCol) {
        case (1, 1): return true
        case (0, 1): return openings.contains(.north)
        case (2, 1): return openings.contains(.south)
        case (1, 0): return openings.contains(.west)
        case (1, 2): return openings.contains(.east)
        default:     return false
        }
    }
}

struct MazeFacelet {
    var id: FaceletID
    var cubieID: CubieID
    var localFace: CubeFace
    var mazeTile: MazeTile
    var tileState: TileState
    var discoveryAmount: Float
}

struct Cubie {
    var id: CubieID
    var position: SIMD3<Int32>
    var orientation: simd_quatf
    var facelets: [MazeFacelet]
}
