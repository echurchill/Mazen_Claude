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

/// Eight-way facing within a tile (M10 Phase D). Ordered clockwise from north so a
/// ±1 step is a 45° turn. subRow 0 = north, 2 = south; subCol 0 = west, 2 = east.
enum Heading8: Int, CaseIterable {
    case n = 0, ne, e, se, s, sw, w, nw

    /// Sub-cell step in this direction, as (deltaSubRow, deltaSubCol).
    var subDelta: (dr: Int, dc: Int) {
        switch self {
        case .n:  return (-1,  0)
        case .ne: return (-1,  1)
        case .e:  return ( 0,  1)
        case .se: return ( 1,  1)
        case .s:  return ( 1,  0)
        case .sw: return ( 1, -1)
        case .w:  return ( 0, -1)
        case .nw: return (-1, -1)
        }
    }

    var isCardinal: Bool { rawValue % 2 == 0 }

    /// The 4-way SurfaceDirection for a cardinal heading (used for edge crossings);
    /// nil for diagonals, which never cross a tile boundary.
    var cardinal: SurfaceDirection? {
        switch self {
        case .n: return .north
        case .e: return .east
        case .s: return .south
        case .w: return .west
        default: return nil
        }
    }

    /// Direction in the tile's local (tangent, bitangent) plane. North = -bitangent,
    /// east = +tangent; diagonals are unit-length.
    var tangentBitangent: (t: Float, b: Float) {
        let s: Float = 0.7071068
        switch self {
        case .n:  return ( 0, -1)
        case .ne: return ( s, -s)
        case .e:  return ( 1,  0)
        case .se: return ( s,  s)
        case .s:  return ( 0,  1)
        case .sw: return (-s,  s)
        case .w:  return (-1,  0)
        case .nw: return (-s, -s)
        }
    }

    func turned(steps: Int) -> Heading8 {
        Heading8(rawValue: (((rawValue + steps) % 8) + 8) % 8)!
    }

    var opposite: Heading8 { turned(steps: 4) }

    static func from(surfaceDirection dir: SurfaceDirection) -> Heading8 {
        switch dir {
        case .north: return .n
        case .east:  return .e
        case .south: return .s
        case .west:  return .w
        }
    }
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
    /// Passable edges that are *fully open* (no geometry) rather than gateways — the
    /// interior edges of a merged multi-tile room (M10 Phase F). Always a subset of
    /// `openings`; empty for ordinary tiles, so behavior is unchanged by default.
    var openEdges: DirectionMask = []

    /// Accumulated quarter-turns (mod 4) this tile's contents have rotated through slice
    /// rotations, in the same sense as `openings.rotated`. The floor texture is glued to
    /// the tile's local frame, so after a rotation finalizes — the mesh snaps back to
    /// face-aligned while `openings` rotate to compensate the geometry — the UVs would
    /// otherwise jump 90°. Rotating the floor UVs by `uvTurns` keeps the ground texture
    /// glued to the tile across finalization (no pop). 0 for tiles that never rotated.
    var uvTurns: Int = 0

    /// Geometric type of one edge (Phase B/F): wall if closed, open if a room interior,
    /// otherwise a gateway.
    func edgeType(_ dir: SurfaceDirection) -> EdgeType {
        guard openings.contains(direction: dir) else { return .wall }
        return openEdges.contains(direction: dir) ? .open : .gateway
    }

    /// Base-3 encoding of the four edge types (N,E,S,W), 0…80 — the cache key for the
    /// wall/post meshes now that an edge has three states.
    var edgeConfigKey: UInt8 {
        let n = Int(edgeType(.north).rawValue)
        let e = Int(edgeType(.east).rawValue)
        let s = Int(edgeType(.south).rawValue)
        let w = Int(edgeType(.west).rawValue)
        return UInt8(n * 27 + e * 9 + s * 3 + w)
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

/// A placed object living on a tile's propSpace (M10 Phase G). Anchored to its facelet,
/// so slice rotations carry it exactly like the tile.
enum PropKind: UInt8 {
    case topiary   // sub-cell decorative hedge sculpture
    case obelisk   // tall landmark, visible over the hedges (G3)
    case chest     // interactive (G4)
}

/// One prop instance: what it is, which 3×3 sub-cell it stands on, and how it faces.
/// Sub-cell corner props need no collision — the player only walks the path cross.
struct Prop {
    var kind: PropKind
    /// Sub-cell it stands on (subRow 0 = north … 2 = south, subCol 0 = west … 2 = east).
    var subRow: Int
    var subCol: Int
    /// Facing within the tile — matters only for asymmetric props (a chest's front).
    var facing: Heading8 = .n
    /// Free-form per-prop state (e.g. chest open = 1 / closed = 0).
    var state: Int = 0

    /// Rotate the prop's placement to match a slice rotation, in the same sense as
    /// `DirectionMask.rotated` (one quarter-turn = local +90°, N→E). Keeps the prop glued
    /// to the tile through finalization — the same treatment `openings` and the player
    /// sub-cell get.
    mutating func rotate(quarterTurns: Int) {
        let turns = ((quarterTurns % 4) + 4) % 4
        for _ in 0..<turns {
            // R(+90°) on the offset-from-center: (dc, dr) → (−dr, dc).
            let dc = subCol - 1, dr = subRow - 1
            subCol = -dr + 1
            subRow = dc + 1
        }
        facing = facing.turned(steps: 2 * turns)  // 90° = two 45° Heading8 steps
    }
}

struct MazeFacelet {
    var id: FaceletID
    var cubieID: CubieID
    var localFace: CubeFace
    var mazeTile: MazeTile
    var tileState: TileState
    var discoveryAmount: Float
    /// Props standing on this tile (M10 Phase G). Empty for most tiles.
    var props: [Prop] = []
}

struct Cubie {
    var id: CubieID
    var position: SIMD3<Int32>
    var orientation: simd_quatf
    var facelets: [MazeFacelet]
}
