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

    /// M20 — for a world whose walls are DRESSED with imported models (`WallStyle.dressed`), which of
    /// the wall "types" this tile's walls use (0 = cleanest/most wall-like … up = more overgrown).
    /// Stored per-tile (not computed from position) so it travels with the tile through slice-twists.
    /// 0 for every other world, so behaviour is unchanged by default.
    var wallType: UInt8 = 0

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

    /// Whether sub-cell (subRow, subCol) of a `grid`×`grid` stand grid is a path cell
    /// (M10 Phase C, generalized for the M18 stand grid). The path is a cross: the centre
    /// cell, plus the centre row/column cells toward each open edge. subRow 0 = north,
    /// grid−1 = south; subCol 0 = west, grid−1 = east. Off-cross cells are never path —
    /// at grid 3 they are propSpace; M18 Phase 1 replaces this rule with the walkability
    /// mask (grass). Default grid 3 serves the render/author-grid callers.
    func isPathCell(_ subRow: Int, _ subCol: Int, grid: Int = 3) -> Bool {
        let c = grid / 2
        if subCol == c {
            if subRow == c { return true }
            return openings.contains(subRow < c ? .north : .south)
        }
        if subRow == c {
            return openings.contains(subCol < c ? .west : .east)
        }
        return false
    }

    /// M18 Phase 1 — whether edge `dir` lets a player stand at / cross through lateral
    /// stand-cell `lateral` (0..<grid along the edge). Fully open edges (room interiors,
    /// natural worlds) allow anywhere; gateway edges only through the centered gap (the
    /// middle third — exactly the visual gap `gatewayGapFraction` cuts, jambs flank it);
    /// closed edges never (the hedge wall occupies the border strip).
    func edgeAllows(_ dir: SurfaceDirection, lateral: Int, grid: Int) -> Bool {
        if openEdges.contains(direction: dir) { return true }
        guard openings.contains(direction: dir) else { return false }
        let gapLo = grid / 3
        return lateral >= gapLo && lateral < grid - gapLo
    }

    /// M18 Phase 1 — the walkability rule: every stand cell is walkable (grass!) except
    /// border cells claimed by their edge's wall geometry. A corner cell answers to both
    /// of its edges. (Prop footprints subtract on top of this in M18 Phase 2.)
    func isStandable(_ subRow: Int, _ subCol: Int, grid: Int) -> Bool {
        if subRow == 0 && !edgeAllows(.north, lateral: subCol, grid: grid) { return false }
        if subRow == grid - 1 && !edgeAllows(.south, lateral: subCol, grid: grid) { return false }
        if subCol == 0 && !edgeAllows(.west, lateral: subRow, grid: grid) { return false }
        if subCol == grid - 1 && !edgeAllows(.east, lateral: subRow, grid: grid) { return false }
        return true
    }
}

/// A placed object living on a tile's propSpace (M10 Phase G). Anchored to its facelet,
/// so slice rotations carry it exactly like the tile.
enum PropKind: UInt8 {
    case topiary      // sub-cell decorative hedge sculpture
    case obelisk      // tall landmark, visible over the hedges (G3)
    case chest        // interactive (G4)
    case houseCorner  // one quarter of a 2×2 modular house (G5)
    case portal       // a doorway to another world — interact (F) switches worlds (M11.2)
    case importedAsset // a decoration backed by an imported mesh; `state` = the Renderer's registry index. Rides slices like any prop.
    case portalLamp   // the flashing lamp atop the portal (TARDIS-style); rendered emissive + blinking
    case dial         // M16.3: a stone lock-dial; `state` 1 = aligned (gold), 0 = off (grey); interact (F) aligns
    case glyph        // M16.5: a carved Builder-glyph plaque (a frozen 4D cross-section) — presence, not system yet
    case tree         // M19: a conifer — a green cone; `state` 0/1/2 = small/medium/large (SceneBuilder scales)
    case treeTrunk    // M19: a short brown trunk under a tree (own kind so it takes the brown colour)
    case boulder      // M19: a grey rock on the moon (regolith); `state` 0/1/2 = small/medium/large
    case foliageCard  // M20: a leafy bush — crossed cards, alpha-cutout leaf array (material 17); `state` = LeafSet slice
    case greeneryCard // M20: an undergrowth plant (fern/flower/…) — misc-greenery array (material 18); `state` = slice
    case treeBillboard // M20: a WenrexaTrees billboard sprite — tree array (material 19); `state` = slice
    case plinth       // M16.6: a Builder plinth — a tapered stone with a caustic glyph lit on its top face.
                      // `state` = TextureLoader.CausticSymbol (0 blank, 1-4 ordinals, 5 swirl, 6 portal).
    case alignmentCylinder  // M16.6 Phase 2: grows from the door plinth when unlocked — a drum bearing
                            // the "square" (world) glyph. Engaging it (F) twists the world open (the
                            // waldo). `anim` = grow/align progress 0…1; walk-through (sits on the plinth).
    case switchBase   // M16.6 (Eddie): a switch = a disc-less plinth base + a switchCap. Replaces the dial.
    case switchCap    // M16.6: the switch's number cylinder — flush (disengaged) ↔ poking out (engaged).
                      // `state` = the number glyph; `anim` = height (0 flush disc … 1 fully out). F toggles.
    case importedFoliage // M20: a Quaternius plant dressing the garden — same imported-mesh render path as
                         // `.importedAsset` (`state` = registry index), but NON-solid (the hedges block, the
                         // plants are scenery) and scaled per-instance by `extraScale`. Added at the end of
                         // the enum so existing raw values don't shift.
    case portalField     // M20 (Eddie): a portal's animated ENERGY surface — a vertical shimmering veil
                         // (material 23). `state` = style: 0 blue veil, 1 pink veil, 2 starfield/galaxy
                         // fill. NON-solid (you step through it). The new portal styles replacing the TARDIS.
    case portalRing      // M20: a flat glowing ring on the ground at a portal's base (emissive, material
                         // 12) — the light pooling under an energy veil / the lit floor of the elevator.
    case signpost        // M20 (Eddie): a wooden post + board naming the portal it stands beside
                         // (material 24). `state` = the label-array slice (a hub destination index).

    /// M18 Phase 2 — does the player collide with this? Portals and their lamp are
    /// walk-through (stepping onto a portal IS the interaction); a tree's trunk is the
    /// solid part (its cone crown overhangs, so the crown itself is walk-through);
    /// everything else is solid and removes the stand points under it. (Imported assets:
    /// solid for now; a mesh-bounds-derived footprint is Phase 3 tuning.)
    var isSolid: Bool {
        switch self {
        case .portal, .portalLamp, .tree, .foliageCard, .greeneryCard, .treeBillboard, .alignmentCylinder, .switchCap, .importedFoliage, .portalField, .portalRing, .signpost: return false
        default: return true
        }
    }

    /// M18 Phase 3 — collision footprint half-extent, in STAND cells from the prop's centre. The
    /// default fills the whole author sub-cell (k/2 ⇒ the historic 5×5 block at standGrid 15). A
    /// prop physically smaller than one 1.3 m stand cell overrides this so it doesn't wall off a
    /// ~6 m square around itself.
    func footprintRadius(grid: Int) -> Int {
        switch self {
        case .plinth, .switchBase: return 0   // small base — blocks only the single cell it stands on
        case .obelisk:             return 1   // M20: a thin pillar — a 3×3 footprint, not the default 5×5 (Eddie: don't eat more stepping spots than needed)
        default:                   return max(0, grid / 3 / 2)
        }
    }
}

/// M19 — what a tile's ground is made of. `maze` is the pastoral hedge world (floor + walls +
/// paved path, the default everywhere before M19); `grass`/`water` are the natural register:
/// a full-tile ground quad, no walls. Water is not walkable — you walk the shore around it.
enum TerrainKind: UInt8 {
    case maze
    case grass
    case water
    case regolith   // M19 moon — grey dust; walkable like grass, no walls
}

/// One prop instance: what it is, which 3×3 sub-cell it stands on, and how it faces.
/// Props live on the 3×3 AUTHOR grid; a solid one removes the stand cells under it (M18 P2).
struct Prop {
    var kind: PropKind
    /// Sub-cell it stands on (subRow 0 = north … 2 = south, subCol 0 = west … 2 = east).
    var subRow: Int
    var subCol: Int
    /// Facing within the tile — matters only for asymmetric props (a chest's front).
    var facing: Heading8 = .n
    /// Free-form per-prop state (e.g. chest open = 1 / closed = 0).
    var state: Int = 0
    /// M20 — extra rotation about the vertical axis, in degrees (on top of `facing`). Lets several
    /// billboard cards of ONE tree intersect at even angles (a multi-view "billboard cloud"). 0 = none.
    var viewAngle: Float = 0
    /// M16.6 Phase 2b — the alignment cylinder's two animation values, driven per-frame by GameState:
    /// `anim` = GROW (0 hidden → 1 fully risen, on unlock); `alignAnim` = the two half-squares' pivot
    /// (0 split → 1 whole, on engage — passed to the shader as discoveryAmount to shear the wrap).
    var anim: Float = 0
    var alignAnim: Float = 0
    /// M20 — per-instance uniform scale multiplier on top of an imported mesh's registry `target`
    /// fit. Only `.importedFoliage` reads it: the gallery normalises every model to one size, but the
    /// garden wants trees big and flowers small, so each scattered plant carries its own scale.
    var extraScale: Float = 1
    /// M20 — fine tile-local position offset (in tile units, where a tile is 1.0 wide), added on top
    /// of the coarse 3×3 sub-cell centre. Lets `.importedFoliage` pack many models at sub-metre
    /// spacing to build a continuous "wall" of bushes/rocks, instead of snapping to the 6 m author grid.
    var offsetX: Float = 0
    var offsetY: Float = 0
    /// M20 — bury the model into the ground by this fraction of its own height. A rounded rock/bush
    /// rested on its single lowest vertex balances on a point and looks like it floats; sinking a
    /// little seats it. 0 = base exactly on the floor (flat-bottomed walls). Only imported kinds read it.
    var sink: Float = 0

    /// M18 Phase 2 — does this prop remove stand cell (subRow, subCol) of a `grid`×`grid`
    /// tile? Centred on the prop's author sub-cell, it blocks a square of half-extent
    /// `kind.footprintRadius`. The default (k/2, k = grid/3) fills the whole sub-cell exactly —
    /// the historic 5×5 block at standGrid 15 — so every existing prop is unchanged. A SMALL prop
    /// (M16.6: a 0.75 m plinth is narrower than one 1.3 m stand cell) blocks fewer cells, so you can
    /// walk right up to it instead of being held a full ~6 m author-cell away. Walk-through props
    /// (portals) block nothing; the connectivity guard proves no footprint severs a tile.
    func blocks(_ subRow: Int, _ subCol: Int, grid: Int) -> Bool {
        guard kind.isSolid else { return false }
        let k = grid / 3
        let rc = self.subRow * k + k / 2, cc = self.subCol * k + k / 2   // the sub-cell's centre cell
        let rad = kind.footprintRadius(grid: grid)
        return abs(subRow - rc) <= rad && abs(subCol - cc) <= rad
    }

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
            // M20: the fine sub-tile offset must rotate the SAME way (else wall props end up mis-placed
            // after a twist): (offsetX, offsetY) → (−offsetY, offsetX).
            let ox = offsetX, oy = offsetY
            offsetX = -oy
            offsetY = ox
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
    /// M19 — the tile's ground register. `.maze` (default) keeps the pastoral hedge floor;
    /// natural worlds set `.grass`/`.water`. Water tiles are not walkable.
    var terrain: TerrainKind = .maze
}

struct Cubie {
    var id: CubieID
    var position: SIMD3<Int32>
    var orientation: simd_quatf
    var facelets: [MazeFacelet]
}
