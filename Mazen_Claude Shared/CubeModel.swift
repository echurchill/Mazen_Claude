import simd

/// What gets stamped onto a freshly generated world (M15.2). The maze itself is always generated;
/// the stamp is the authored layer on top — rooms, props, portals.
enum WorldStamp {
    case overworldDemo   // the dev overworld: start plaza + props, BOTH doorways, the −Z house court
    case moonDemo        // the moon: the demo plaza but only its one door home (no temple doorway)
    case templeInterior  // the first hand-stamped interior: central hall, pedestal, return portal
    case bare            // nothing authored — the bare generated maze (tests; procedural worlds later)
}

class CubeModel {
    let size: Int
    let worldScale: WorldScale
    var cubies: [Cubie]

    private var projectionDirty = true
    private var cachedProjection: [CubeFace: [[FaceletID?]]] = [:]

    // Static map: facelet id → its fixed location in the cubies array. Assigned once
    // in buildCubies and never invalidated — slice rotations mutate cubie position /
    // orientation in place but never reorder the array or reassign facelet ids. This
    // turns findFaceletIndices(id:) (hit once per faceletAt, ~6·n² times per frame)
    // from an O(n²) scan into an O(1) lookup.
    private var faceletLocation: [FaceletID: (cubieIndex: Int, faceletIndex: Int)] = [:]

    init(worldScale: WorldScale, stamp: WorldStamp = .overworldDemo) {
        self.worldScale = worldScale
        self.size = worldScale.cubeSize
        self.cubies = []
        buildCubies()
        buildFaceletLocationMap()
        generateMaze()
        addEdgeBridges()
        rebuildProjection()
        switch stamp {
        case .overworldDemo:
            stampDemoRoom()
            stampDemoProps(templeDoor: true)
        case .moonDemo:
            stampDemoRoom()
            stampDemoProps(templeDoor: false)
        case .templeInterior:
            stampTempleInterior()
        case .bare:
            break
        }
    }

    // MARK: - Rooms (M10 Phase F)

    /// Prototype: merge a 3×3 block of tiles centered on the player's start face into
    /// one open plaza. Interior shared edges become `open` (passable, no geometry).
    private func stampDemoRoom() {
        let h = min(3, size), w = min(3, size)
        let top = max(0, size / 2 - h / 2)
        let left = max(0, size / 2 - w / 2)
        stampRoom(face: .positiveZ, top: top, left: left, height: h, width: w)
    }

    /// Open the interior shared edges of a rectangular tile block so it reads as one room.
    func stampRoom(face: CubeFace, top: Int, left: Int, height: Int, width: Int) {
        func open(_ r: Int, _ c: Int, _ dir: SurfaceDirection) {
            guard let (ci, fi) = faceletAt(face: face, row: r, col: c) else { return }
            let m = Self.directionMask(dir)
            cubies[ci].facelets[fi].mazeTile.openings.insert(m)
            cubies[ci].facelets[fi].mazeTile.openEdges.insert(m)
        }
        for r in top..<(top + height) {
            for c in left..<(left + width) {
                if c + 1 < left + width { open(r, c, .east);  open(r, c + 1, .west) }
                if r + 1 < top + height { open(r, c, .south); open(r + 1, c, .north) }
            }
        }
    }

    /// Open a rectangular block into a fully walkable, hedge-free room the player can enter
    /// (M12-E). Every edge of every block tile is opened — so no interior *or* perimeter hedges
    /// render, leaving the imported house walls to enclose it — and the reciprocal edges of the
    /// same-face neighbours are opened too, so the player can walk in from the surrounding plaza.
    /// Edges that fall off the face (the cube-edge sides where a slice splits the house) simply
    /// find no neighbour and are skipped.
    func stampOpenPlaza(face: CubeFace, top: Int, left: Int, height: Int, width: Int) {
        let n = size
        func open(_ r: Int, _ c: Int, _ dir: SurfaceDirection) {
            guard (0..<n).contains(r), (0..<n).contains(c),
                  let (ci, fi) = faceletAt(face: face, row: r, col: c) else { return }
            let m = Self.directionMask(dir)
            cubies[ci].facelets[fi].mazeTile.openings.insert(m)
            cubies[ci].facelets[fi].mazeTile.openEdges.insert(m)
        }
        for r in top..<(top + height) {
            for c in left..<(left + width) {
                open(r, c, .north); open(r, c, .south); open(r, c, .east); open(r, c, .west)
            }
        }
        // Reciprocal same-face neighbour edges, so the room connects to the plaza around it.
        for c in left..<(left + width) {
            open(top - 1, c, .south)         // north neighbour ↔ block
            open(top + height, c, .north)    // south neighbour ↔ block
        }
        for r in top..<(top + height) {
            open(r, left - 1, .east)         // west neighbour ↔ block
            open(r, left + width, .west)     // east neighbour ↔ block
        }
    }

    /// Place a hedge-sculpture topiary in the NW corner sub-cell of each start-plaza tile
    /// so Phase G's prop pipeline is visible — and rides slice rotations (the plaza is on
    /// the start face, so Q/E carries the topiaries around). (M10 Phase G)
    private func stampDemoProps(templeDoor: Bool) {
        let h = min(3, size), w = min(3, size)
        let top = max(0, size / 2 - h / 2)
        let left = max(0, size / 2 - w / 2)
        for r in top..<(top + h) {
            for c in left..<(left + w) {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                cubies[ci].facelets[fi].props.append(Prop(kind: .topiary, subRow: 0, subCol: 0))
            }
        }
        // On the plaza-centre tile (the player's start tile): a landmark obelisk (SE corner) and an
        // interactive chest (NE corner).
        if let (ci, fi) = faceletAt(face: .positiveZ, row: size / 2, col: size / 2) {
            cubies[ci].facelets[fi].props.append(Prop(kind: .obelisk, subRow: 2, subCol: 2))
            cubies[ci].facelets[fi].props.append(Prop(kind: .chest, subRow: 0, subCol: 2))
        }
        // Open the start plaza into a walkable hub, and put a portal doorway on the empty tile just
        // NORTH of the plaza (M11.2c): walking onto it switches worlds — step through it like a
        // doorway, no button (F still works). The 3×3 plaza itself is fully packed with the imported
        // decorations, so the portal sits one tile beyond it (reachable — stampOpenPlaza opens that
        // edge). On a tiny cube with no room north, it falls back into the plaza.
        stampOpenPlaza(face: .positiveZ, top: top, left: left, height: h, width: w)
        let portalRow = max(0, top - 1)
        if let (ci, fi) = faceletAt(face: .positiveZ, row: portalRow, col: left + w / 2) {
            // facing = the door's EXIT direction (M15.2): emerge looking south, back at the plaza.
            cubies[ci].facelets[fi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .s))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))  // flashing lamp atop
        }
        // M15.2: a second doorway SOUTH of the plaza — the temple interior (destination id 1;
        // Prop.state carries which world a portal leads to). Overworld only.
        // M16.1: the temple is a LOCKED, bonded structure — the door tile, its two flanking
        // pillar tiles, and a ROOT cubie directly beneath the door are one rigid bond. Because
        // the root lies in the layer below, the start face's own slice twist (Q/E) would tear
        // the bond and is REFUSED — the temple pins the face until the lock is undone (M16.3).
        let templeRow = min(size - 1, top + h)
        let doorCol = left + w / 2
        if templeDoor, let (dci, dfi) = faceletAt(face: .positiveZ, row: templeRow, col: doorCol) {
            cubies[dci].facelets[dfi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n, state: 1))
            cubies[dci].facelets[dfi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))
            var bond: Set<Int> = [dci]
            for pc in [doorCol - 1, doorCol + 1] where (0..<size).contains(pc) {
                if let (pci, pfi) = faceletAt(face: .positiveZ, row: templeRow, col: pc) {
                    cubies[pci].facelets[pfi].props.append(Prop(kind: .obelisk, subRow: 1, subCol: 1))
                    bond.insert(pci)
                }
            }
            // The root: the cube is HOLLOW (only surface cubies exist — buildCubies skips
            // interiors), so the lock anchors straight through the world's core to the cubie on
            // the OPPOSITE face (z = 0). Any twist of the start face's slice would tear door from
            // root — refused until the lock is undone.
            if let root = cubies.firstIndex(where: {
                $0.position == SIMD3<Int32>(Int32(doorCol), Int32(templeRow), 0)
            }) {
                bond.insert(root)
            }
            addBond(bond)

            // M16.3: the lock's mechanism — four stone dials spread to the garden's diagonal
            // quarters. Three are aligned (gold, pointer north); the SE one — nearest the temple —
            // is off (grey, pointer east). Align it (F, GameState.interact) and the temple
            // unbonds: understanding is the key. Deliberately "find the pattern and act once";
            // the composable glyph grammar is M17's.
            let cc = size / 2
            let spread = min(3, size / 2)
            let dialSpots: [(Int, Int, Heading8, Int)] = [
                (cc - spread, cc - spread, .n, 1),
                (cc - spread, cc + spread, .n, 1),
                (cc + spread, cc - spread, .n, 1),
                (cc + spread, cc + spread, .e, 0),
            ]
            for (r, c2, f, st) in dialSpots {
                if let (ci2, fi2) = faceletAt(face: .positiveZ, row: r, col: c2) {
                    cubies[ci2].facelets[fi2].props.append(Prop(kind: .dial, subRow: 1, subCol: 1, facing: f, state: st))
                }
            }
        }
        // M12-E: the 2×2 modular house gets its OWN open plaza on the −Z (back) face, away from the
        // crowded +Z demo plaza, so it has room to breathe. It sits at the row-0 face edge so an
        // adjacent-face slice still cuts through and splits it. The court is opened into a hedge-free,
        // walkable room and revealed, so the imported walls do the enclosing and the player can walk
        // in from the surrounding plaza.
        let houseFace: CubeFace = .negativeZ
        let courtW = min(4, size), courtH = min(4, size)
        let courtLeft = max(0, size / 2 - courtW / 2)
        stampOpenPlaza(face: houseFace, top: 0, left: courtLeft, height: courtH, width: courtW)
        for r in 0..<courtH {
            for c in courtLeft..<(courtLeft + courtW) {
                if let (ci, fi) = faceletAt(face: houseFace, row: r, col: c) {
                    cubies[ci].facelets[fi].tileState = .discovered
                    cubies[ci].facelets[fi].discoveryAmount = 1.0
                }
            }
        }
        // The 2×2 quarters, centred across the court width, at the row-0 edge (for the split).
        let hLeft = courtLeft + max(0, (courtW - 2) / 2)
        let house: [(Int, Int, Heading8)] = [(0, hLeft, .n), (0, hLeft + 1, .e), (1, hLeft, .w), (1, hLeft + 1, .s)]
        for (r, c, f) in house {
            if let (ci, fi) = faceletAt(face: houseFace, row: r, col: c) {
                cubies[ci].facelets[fi].props.append(Prop(kind: .houseCorner, subRow: 1, subCol: 1, facing: f))
            }
        }
    }

    /// Where this world's (first) portal doorway stands — arrivals emerge here, facing the
    /// portal's `facing` (its exit direction), so travel reads as walking through a door
    /// (M15.2). Scans the grid; worlds have at most a couple of portals.
    func firstPortalLocation() -> (face: CubeFace, row: Int, col: Int, exitFacing: Heading8)? {
        for face in CubeFace.allCases {
            for row in 0..<size {
                for col in 0..<size {
                    if let (ci, fi) = faceletAt(face: face, row: row, col: col),
                       let portal = cubies[ci].facelets[fi].props.first(where: { $0.kind == .portal }) {
                        return (face, row, col, portal.facing)
                    }
                }
            }
        }
        return nil
    }

    /// M15.2 — the first hand-stamped interior world (a 5³ temple, D3). Sparse and legible: a
    /// 3×3 open hall centred on the arrival face (+Z, where the player spawns at the centre), a
    /// pedestal to the north (placeholder for the M17 memory-mote), and the way home to the
    /// south — a walk-through return portal. The generated maze stands everywhere else: the
    /// chamber is the anteroom, the rest of the inside is there to be explored.
    private func stampTempleInterior() {
        let n = size
        let c = n / 2
        let top = max(0, c - 1), left = max(0, c - 1)
        let h = min(3, n), w = min(3, n)
        stampOpenPlaza(face: .positiveZ, top: top, left: left, height: h, width: w)
        // Pedestal north of centre (the player spawns AT centre — keep it clear).
        if let (ci, fi) = faceletAt(face: .positiveZ, row: max(0, c - 1), col: c) {
            cubies[ci].facelets[fi].props.append(Prop(kind: .obelisk, subRow: 1, subCol: 1))
        }
        // Return portal south of centre (walking onto it exits — depth > 1 always pops).
        // Its exit direction is north: arrivals emerge facing the hall and the pedestal.
        if let (ci, fi) = faceletAt(face: .positiveZ, row: min(n - 1, c + 1), col: c) {
            cubies[ci].facelets[fi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))
        }
    }

    private static func directionMask(_ dir: SurfaceDirection) -> DirectionMask {
        switch dir {
        case .north: return .north
        case .east:  return .east
        case .south: return .south
        case .west:  return .west
        }
    }

    convenience init(size: Int) {
        self.init(worldScale: WorldScale(cubeSize: size))
    }

    private func buildFaceletLocationMap() {
        faceletLocation.removeAll(keepingCapacity: true)
        for (ci, cubie) in cubies.enumerated() {
            for (fi, facelet) in cubie.facelets.enumerated() {
                faceletLocation[facelet.id] = (ci, fi)
            }
        }
    }

    // MARK: - Initialization

    private func buildCubies() {
        var cubieIndex = 0
        var faceletIndex = 0
        let n = Int32(size)

        for x: Int32 in 0..<n {
            for y: Int32 in 0..<n {
                for z: Int32 in 0..<n {
                    let onMinX = x == 0
                    let onMaxX = x == n - 1
                    let onMinY = y == 0
                    let onMaxY = y == n - 1
                    let onMinZ = z == 0
                    let onMaxZ = z == n - 1

                    let isSurface = onMinX || onMaxX || onMinY || onMaxY || onMinZ || onMaxZ
                    guard isSurface else { continue }

                    let cubieID = CubieID(rawValue: cubieIndex)
                    cubieIndex += 1
                    var facelets: [MazeFacelet] = []

                    let exposedFaces: [(CubeFace, Bool)] = [
                        (.positiveX, onMaxX), (.negativeX, onMinX),
                        (.positiveY, onMaxY), (.negativeY, onMinY),
                        (.positiveZ, onMaxZ), (.negativeZ, onMinZ),
                    ]

                    for (face, exposed) in exposedFaces {
                        guard exposed else { continue }
                        let fid = FaceletID(rawValue: faceletIndex)
                        faceletIndex += 1
                        let seed = UInt32(truncatingIfNeeded: fid.rawValue &* 2654435761)
                        let facelet = MazeFacelet(
                            id: fid,
                            cubieID: cubieID,
                            localFace: face,
                            mazeTile: MazeTile(openings: [], styleSeed: seed),
                            tileState: .unknown,
                            discoveryAmount: 0
                        )
                        facelets.append(facelet)
                    }

                    let cubie = Cubie(
                        id: cubieID,
                        position: SIMD3(x, y, z),
                        orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                        facelets: facelets
                    )
                    cubies.append(cubie)
                }
            }
        }
    }

    private func generateMaze() {
        // Simple per-face maze using recursive backtracker
        // For now, generate a basic pattern that guarantees some connectivity
        for face in CubeFace.allCases {
            generateFaceMaze(face: face)
        }
    }

    private func generateFaceMaze(face: CubeFace) {
        let n = size
        var grid = Array(repeating: Array(repeating: DirectionMask(), count: n), count: n)
        var visited = Array(repeating: Array(repeating: false, count: n), count: n)

        struct Cell { let row: Int; let col: Int }

        func neighbors(_ c: Cell) -> [(SurfaceDirection, Cell)] {
            var result: [(SurfaceDirection, Cell)] = []
            if c.row > 0     { result.append((.north, Cell(row: c.row - 1, col: c.col))) }
            if c.row < n - 1 { result.append((.south, Cell(row: c.row + 1, col: c.col))) }
            if c.col > 0     { result.append((.west,  Cell(row: c.row, col: c.col - 1))) }
            if c.col < n - 1 { result.append((.east,  Cell(row: c.row, col: c.col + 1))) }
            return result
        }

        func directionMask(_ d: SurfaceDirection) -> DirectionMask {
            switch d {
            case .north: return .north
            case .east:  return .east
            case .south: return .south
            case .west:  return .west
            }
        }

        var stack: [Cell] = []
        let start = Cell(row: 0, col: 0)
        visited[0][0] = true
        stack.append(start)

        // Seeded RNG for reproducibility per face
        var rng = FaceSeededRNG(seed: UInt64(face.rawValue) &+ 42)

        while !stack.isEmpty {
            let current = stack.last!
            let unvisited = neighbors(current).filter { !visited[$0.1.row][$0.1.col] }

            if unvisited.isEmpty {
                stack.removeLast()
            } else {
                let idx = Int(rng.next() % UInt64(unvisited.count))
                let (dir, next) = unvisited[idx]
                grid[current.row][current.col].insert(directionMask(dir))
                grid[next.row][next.col].insert(directionMask(dir.opposite))
                visited[next.row][next.col] = true
                stack.append(next)
            }
        }

        // Apply to facelets. faceletAt = cached projection + O(1) id map — the old per-cell
        // findFaceletIndices(face:) linear scan made maze gen O(n⁵): ~58M cubie visits at size 25,
        // the whole of the startup cost (R2, startup-time fix).
        for row in 0..<n {
            for col in 0..<n {
                if let (ci, fi) = faceletAt(face: face, row: row, col: col) {
                    cubies[ci].facelets[fi].mazeTile.openings = grid[row][col]
                }
            }
        }
    }

    // MARK: - Projection

    func rebuildProjection() {
        let n = size
        cachedProjection = [:]
        for face in CubeFace.allCases {
            var grid: [[FaceletID?]] = Array(
                repeating: Array(repeating: nil, count: n),
                count: n
            )
            for cubie in cubies {
                for facelet in cubie.facelets {
                    let worldFace = effectiveFace(cubie: cubie, localFace: facelet.localFace)
                    guard worldFace == face else { continue }
                    let (row, col) = gridPosition(cubie: cubie, face: face)
                    if row >= 0 && row < n && col >= 0 && col < n {
                        grid[row][col] = facelet.id
                    }
                }
            }
            cachedProjection[face] = grid
        }
        projectionDirty = false
    }

    func faceletAt(face: CubeFace, row: Int, col: Int) -> (cubieIndex: Int, faceletIndex: Int)? {
        if projectionDirty { rebuildProjection() }
        guard let fid = cachedProjection[face]?[row][col] else { return nil }
        return findFaceletIndices(id: fid)
    }

    // MARK: - Shape (M14 — shape-as-meaning)

    /// Roundness dial for the superellipsoid "inflated cube". `0` = today's hard cube
    /// (behavior-neutral); `1` = maximum inflation toward a sphere. **Per-world** — this
    /// is the shape-as-meaning axis: natural worlds bulge round, mechanistic worlds stay
    /// hard-cubic. Only the *render geometry* (tile centers + basis) is remapped; the maze
    /// topology, movement, slice, and bandaging all stay grid-based and untouched.
    var roundness: Float = 0.0

    /// Low-distortion cube→sphere map (the standard "Cobb"/`√` cube-sphere): pushes a point
    /// on the unit cube `[-1,1]³` onto the unit sphere, then blends back toward the flat cube
    /// point by `roundness`. `roundness == 0` returns the point unchanged (no-op fast path).
    /// ⚠️ Twin implementation: must stay bit-identical to `m14bInflate` in Shaders.metal — the
    /// camera/props seat on THIS function while the floor renders through the shader one. The
    /// golden-value test in CoordinateMathTests is the tripwire (internal, not private, for it).
    func inflatedUnitPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        guard roundness > 0 else { return p }
        let x = p.x, y = p.y, z = p.z
        let sx = x * (max(0, 1 - (y*y + z*z) / 2 + (y*y * z*z) / 3)).squareRoot()
        let sy = y * (max(0, 1 - (z*z + x*x) / 2 + (z*z * x*x) / 3)).squareRoot()
        let sz = z * (max(0, 1 - (x*x + y*y) / 2 + (x*x * y*y) / 3)).squareRoot()
        let sphere = SIMD3(sx, sy, sz)
        return p + (sphere - p) * roundness
    }

    // MARK: - World matrices

    /// The **flat** (un-inflated, un-spun) placement of a tile — tangent/bitangent/normal basis at
    /// the tile center on the axis-aligned cube face. This is the rest frame the M14b vertex shader
    /// inflates from (per-vertex); rigid objects seat on the curve via `inflatedPlacement` instead.
    func restMatrix(face: CubeFace, row: Int, col: Int) -> float4x4 {
        let halfN = Float(size) / 2.0
        let spacing = worldScale.cellSpacing
        let normal = face.normal
        let tangent = face.tangent
        let bitangent = face.bitangent
        let colF = (Float(col) + 0.5 - halfN) * spacing
        let rowF = (Float(row) + 0.5 - halfN) * spacing

        // M15.1 — interior world: the tile sits on the SAME face plane but is seen from inside,
        // which is a mirror image. Keep col ↔ +tangent, mirror the row axis instead: basis
        // (tangent, −bitangent, −normal) — right-handed, det +1 (cross(t,−b) = −n ✓), local "up"
        // (+z) points into the cube — and mirror the row *placement* to match (rowF term negated),
        // so tile-local geometry (walls on grid-north edges etc.) stays aligned with grid logic.
        if worldScale.interior {
            let center = normal * halfN + tangent * colF - bitangent * rowF
            return float4x4(columns: (
                SIMD4(tangent.x,    tangent.y,    tangent.z,    0),
                SIMD4(-bitangent.x, -bitangent.y, -bitangent.z, 0),
                SIMD4(-normal.x,    -normal.y,    -normal.z,    0),
                SIMD4(center.x,     center.y,     center.z,     1)
            ))
        }

        let center = normal * halfN + tangent * colF + bitangent * rowF
        return float4x4(columns: (
            SIMD4(tangent.x,   tangent.y,   tangent.z,   0),
            SIMD4(bitangent.x, bitangent.y, bitangent.z, 0),
            SIMD4(normal.x,    normal.y,    normal.z,     0),
            SIMD4(center.x,    center.y,    center.z,     1)
        ))
    }

    /// M14b: the inflated **surface placement** of a point at tile-local offset `(localX, localY)`
    /// from a tile center — position on the curved surface + the local surface frame (tangent /
    /// bitangent / outward normal as the matrix columns). Used to seat *rigid* objects (imported
    /// assets like the horse/house) on the curve, tilted to the local normal, rather than bending
    /// them per-vertex. `roundness == 0` returns the flat placement (offset applied in the tile
    /// plane) — identical to the old `worldMatrix · translation` seating.
    func inflatedPlacement(face: CubeFace, row: Int, col: Int, localX: Float, localY: Float) -> float4x4 {
        let base = restMatrix(face: face, row: row, col: col)
        // Offset the origin within the tile plane, in the base frame (avoids the render-side
        // `float4x4.translation` extension so this stays compilable in the test target).
        let baseRight = SIMD3<Float>(base.columns.0.x, base.columns.0.y, base.columns.0.z)
        let baseUp    = SIMD3<Float>(base.columns.1.x, base.columns.1.y, base.columns.1.z)
        let basePos   = SIMD3<Float>(base.columns.3.x, base.columns.3.y, base.columns.3.z)
        guard roundness > 0 else {
            var m = base
            let p = basePos + baseRight * localX + baseUp * localY
            m.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
            return m
        }
        let halfN = Float(size) / 2.0
        let spacing = worldScale.cellSpacing
        let footRest = basePos + baseRight * localX + baseUp * localY
        let unit = footRest / halfN
        let worldC = inflatedUnitPoint(unit) * halfN

        let tHat = normalize(baseRight)
        let bHat = normalize(baseUp)
        let eps = 0.5 * spacing / halfN
        let dT = inflatedUnitPoint(unit + tHat * eps) * halfN - worldC
        let dB = inflatedUnitPoint(unit + bHat * eps) * halfN - worldC
        var forward = normalize(cross(dT, dB))
        if dot(forward, normalize(worldC)) < 0 { forward = -forward }
        let right = normalize(dT - forward * dot(dT, forward))
        let up = cross(forward, right)
        return float4x4(columns: (
            SIMD4(right.x,   right.y,   right.z,   0),
            SIMD4(up.x,      up.y,      up.z,      0),
            SIMD4(forward.x, forward.y, forward.z, 0),
            SIMD4(worldC.x,  worldC.y,  worldC.z,  1)
        ))
    }

    // (R2.1: the M14-era per-tile-inflating `worldMatrix` — with its 9% seam-overlap hack — is
    // gone. Per-vertex inflation happens in the shader from `restMatrix`; anything that needs a
    // rigid seat ON the curved surface uses `inflatedPlacement`.)

    // MARK: - Slice Rotation

    func cubieIndicesInSlice(axis: Int, index: Int) -> [Int] {
        cubies.indices.filter { i in
            let pos = cubies[i].position
            switch axis {
            case 0: return pos.x == Int32(index)
            case 1: return pos.y == Int32(index)
            case 2: return pos.z == Int32(index)
            default: return false
            }
        }
    }

    // MARK: - Bandaging (M13)

    /// Bonded cubie groups: each set of cubie indices must move together, so a slice twist that
    /// would cut through a group — some of its cubies in the rotating slice, some out — is illegal
    /// and refused. Indices are into `cubies` and stay valid across turns (`applySliceRotation`
    /// moves cubies but never reindexes the array). A cubie should belong to at most one group.
    var bondedGroups: [Set<Int>] = []

    /// Bond a set of cubie indices so they move as one rigid block (M13). Ignores trivial groups.
    func addBond(_ cubieIndices: Set<Int>) {
        guard cubieIndices.count > 1 else { return }
        bondedGroups.append(cubieIndices)
    }

    /// Dissolve the bond containing `cubieIndex` (M16: understanding undoes a lock — the bonded
    /// structure becomes twistable again). Cubie indices stay valid across turns, so the caller
    /// can hold one member (e.g. the structure's anchor cubie) from bond time. Returns whether
    /// a bond was actually removed.
    @discardableResult
    func removeBond(containing cubieIndex: Int) -> Bool {
        guard let i = bondedGroups.firstIndex(where: { $0.contains(cubieIndex) }) else { return false }
        bondedGroups.remove(at: i)
        return true
    }

    /// Whether a slice twist is legal under the current bonds (the bandaged-cube rule): every bonded
    /// group must be **entirely inside** the rotating slice or **entirely outside** it. A group that
    /// straddles the slice would be torn, so the twist is refused. No bonds ⇒ always legal.
    func canRotateSlice(axis: Int, index: Int) -> Bool {
        guard !bondedGroups.isEmpty else { return true }
        let slice = Set(cubieIndicesInSlice(axis: axis, index: index))
        for group in bondedGroups where !group.isDisjoint(with: slice) && !group.isSubset(of: slice) {
            return false
        }
        return true
    }

    func applySliceRotation(axis: Int, index: Int, angle: Float) {
        let axisVec: SIMD3<Float> = axis == 0 ? SIMD3(1,0,0) : axis == 1 ? SIMD3(0,1,0) : SIMD3(0,0,1)
        let rotQ = simd_quatf(angle: angle, axis: axisVec)
        let center = Float(size - 1) / 2.0

        for i in cubieIndicesInSlice(axis: axis, index: index) {
            // Rotate maze openings to match the new orientation
            for fi in cubies[i].facelets.indices {
                let oldWorldNormal = cubies[i].orientation.act(cubies[i].facelets[fi].localFace.normal)
                let oldWorldFace = closestFace(to: oldWorldNormal)
                let oldTangent = oldWorldFace.tangent

                let newWorldNormal = rotQ.act(oldWorldNormal)
                let newWorldFace = closestFace(to: newWorldNormal)
                let newTangent = newWorldFace.tangent
                let newBitangent = newWorldFace.bitangent

                let rotatedOldTangent = rotQ.act(oldTangent)
                let dotT = dot(rotatedOldTangent, newTangent)
                let dotB = dot(rotatedOldTangent, newBitangent)
                let quarterTurns: Int
                if abs(dotT) > abs(dotB) {
                    quarterTurns = dotT > 0 ? 0 : 2
                } else {
                    quarterTurns = dotB > 0 ? 1 : 3
                }
                if quarterTurns != 0 {
                    cubies[i].facelets[fi].mazeTile.openings = cubies[i].facelets[fi].mazeTile.openings.rotated(quarterTurns: quarterTurns)
                    cubies[i].facelets[fi].mazeTile.openEdges = cubies[i].facelets[fi].mazeTile.openEdges.rotated(quarterTurns: quarterTurns)
                    // Keep the floor texture glued to the tile through finalization.
                    cubies[i].facelets[fi].mazeTile.uvTurns = (cubies[i].facelets[fi].mazeTile.uvTurns + quarterTurns) % 4
                    // Carry any props around with the tile.
                    for pi in cubies[i].facelets[fi].props.indices {
                        cubies[i].facelets[fi].props[pi].rotate(quarterTurns: quarterTurns)
                    }
                }
            }

            cubies[i].orientation = (rotQ * cubies[i].orientation).normalized

            let pos = SIMD3<Float>(Float(cubies[i].position.x), Float(cubies[i].position.y), Float(cubies[i].position.z))
            let centered = pos - SIMD3(center, center, center)
            let rotated = rotQ.act(centered)
            let newPos = rotated + SIMD3(center, center, center)
            cubies[i].position = SIMD3<Int32>(Int32(round(newPos.x)), Int32(round(newPos.y)), Int32(round(newPos.z)))
        }

        rebuildProjection()
    }

    func sliceAxisAndIndex(for face: CubeFace) -> (axis: Int, index: Int) {
        switch face {
        case .positiveX: return (0, size - 1)
        case .negativeX: return (0, 0)
        case .positiveY: return (1, size - 1)
        case .negativeY: return (1, 0)
        case .positiveZ: return (2, size - 1)
        case .negativeZ: return (2, 0)
        }
    }

    // MARK: - Edge Crossing

    func edgeCrossing(face: CubeFace, direction: SurfaceDirection, row: Int, col: Int) -> (face: CubeFace, row: Int, col: Int, facing: SurfaceDirection) {
        guard worldScale.interior else {
            return EdgeCrossing.cross(face: face, direction: direction, row: row, col: col, cubeSize: size)
        }
        // M15.1 — interior adjacency by conjugation: an interior cell (r,c) occupies the same
        // world spot as the exterior cell (n−1−r, c) on the same face (the row axis is mirrored
        // in restMatrix), and grid N/S are world-swapped while E/W are unchanged. So: mirror into
        // exterior coordinates, cross with the proven exterior table, mirror back. The headless
        // edge-continuity test pins this to world positions.
        func flip(_ d: SurfaceDirection) -> SurfaceDirection {
            d == .north ? .south : (d == .south ? .north : d)
        }
        let ext = EdgeCrossing.cross(face: face, direction: flip(direction),
                                     row: size - 1 - row, col: col, cubeSize: size)
        return (ext.face, size - 1 - ext.row, ext.col, flip(ext.facing))
    }

    private func addEdgeBridges() {
        var rng = FaceSeededRNG(seed: 99)
        let n = size

        func mask(for dir: SurfaceDirection) -> DirectionMask {
            switch dir {
            case .north: return .north
            case .east:  return .east
            case .south: return .south
            case .west:  return .west
            }
        }

        let edges: [(CubeFace, SurfaceDirection)] = [
            (.positiveZ, .north), (.positiveZ, .south), (.positiveZ, .east), (.positiveZ, .west),
            (.negativeZ, .north), (.negativeZ, .south), (.negativeZ, .east), (.negativeZ, .west),
            (.positiveY, .east),  (.positiveY, .west),
            (.negativeY, .east),  (.negativeY, .west),
        ]

        // Scale the number of face-to-face bridges with edge length so larger cubes
        // stay comparably connected. max(1, n/3) keeps n<=5 at the historical single
        // bridge per edge (and the identical RNG sequence) while a 7- or 9-face gets
        // 2-3. Duplicate positions just collapse via the idempotent openings.insert.
        let bridgesPerEdge = max(1, n / 3)
        for (face, dir) in edges {
            for _ in 0..<bridgesPerEdge {
                let pos = Int(rng.next() % UInt64(n))
                let departRow: Int, departCol: Int
                switch dir {
                case .north: departRow = 0;     departCol = pos
                case .south: departRow = n - 1; departCol = pos
                case .east:  departRow = pos;   departCol = n - 1
                case .west:  departRow = pos;   departCol = 0
                }

                let crossing = edgeCrossing(face: face, direction: dir, row: departRow, col: departCol)
                let arrivalDir = crossing.facing.opposite

                if let (ci, fi) = faceletAt(face: face, row: departRow, col: departCol) {
                    cubies[ci].facelets[fi].mazeTile.openings.insert(mask(for: dir))
                }
                if let (ci, fi) = faceletAt(face: crossing.face, row: crossing.row, col: crossing.col) {
                    cubies[ci].facelets[fi].mazeTile.openings.insert(mask(for: arrivalDir))
                }
            }
        }
    }

    // MARK: - Helpers

    private func effectiveFace(cubie: Cubie, localFace: CubeFace) -> CubeFace {
        let rotatedNormal = cubie.orientation.act(localFace.normal)
        return closestFace(to: rotatedNormal)
    }

    private func closestFace(to direction: SIMD3<Float>) -> CubeFace {
        var bestFace = CubeFace.positiveX
        var bestDot: Float = -2
        for face in CubeFace.allCases {
            let d = dot(direction, face.normal)
            if d > bestDot {
                bestDot = d
                bestFace = face
            }
        }
        return bestFace
    }

    private func gridPosition(cubie: Cubie, face: CubeFace) -> (row: Int, col: Int) {
        let pos = cubie.position
        let n = Int32(size - 1)
        switch face {
        case .positiveX: return (row: Int(pos.y), col: Int(n - pos.z))
        case .negativeX: return (row: Int(pos.y), col: Int(pos.z))
        case .positiveY: return (row: Int(n - pos.z), col: Int(pos.x))
        case .negativeY: return (row: Int(pos.z), col: Int(pos.x))
        case .positiveZ: return (row: Int(pos.y), col: Int(pos.x))
        case .negativeZ: return (row: Int(pos.y), col: Int(n - pos.x))
        }
    }

    // (R2 startup fix: the old findFaceletIndices(face:row:col:) — a full linear scan over every
    // cubie per lookup — is gone; all callers use faceletAt's cached projection + O(1) id map.)

    private func findFaceletIndices(id: FaceletID) -> (cubieIndex: Int, faceletIndex: Int)? {
        return faceletLocation[id]
    }
}

// MARK: - Simple seeded RNG

private struct FaceSeededRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
