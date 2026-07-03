import simd

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

    init(worldScale: WorldScale) {
        self.worldScale = worldScale
        self.size = worldScale.cubeSize
        self.cubies = []
        buildCubies()
        buildFaceletLocationMap()
        generateMaze()
        addEdgeBridges()
        rebuildProjection()
        stampDemoRoom()
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

        // Apply to facelets
        for row in 0..<n {
            for col in 0..<n {
                if let (ci, fi) = findFaceletIndices(face: face, row: row, col: col) {
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

    // MARK: - World matrices

    func worldMatrix(face: CubeFace, row: Int, col: Int) -> float4x4 {
        let halfN = Float(size) / 2.0
        let spacing = worldScale.cellSpacing

        let normal = face.normal
        let tangent = face.tangent
        let bitangent = face.bitangent

        let colF = (Float(col) + 0.5 - halfN) * spacing
        let rowF = (Float(row) + 0.5 - halfN) * spacing

        let center = normal * halfN + tangent * colF + bitangent * rowF

        let right = tangent
        let up = bitangent
        let forward = normal

        return float4x4(columns: (
            SIMD4(right.x,   right.y,   right.z,   0),
            SIMD4(up.x,      up.y,      up.z,      0),
            SIMD4(forward.x, forward.y, forward.z,  0),
            SIMD4(center.x,  center.y,  center.z,  1)
        ))
    }

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
        EdgeCrossing.cross(face: face, direction: direction, row: row, col: col, cubeSize: size)
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

                if let (ci, fi) = findFaceletIndices(face: face, row: departRow, col: departCol) {
                    cubies[ci].facelets[fi].mazeTile.openings.insert(mask(for: dir))
                }
                if let (ci, fi) = findFaceletIndices(face: crossing.face, row: crossing.row, col: crossing.col) {
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

    private func findFaceletIndices(face: CubeFace, row: Int, col: Int) -> (cubieIndex: Int, faceletIndex: Int)? {
        for (ci, cubie) in cubies.enumerated() {
            for (fi, facelet) in cubie.facelets.enumerated() {
                let worldFace = effectiveFace(cubie: cubie, localFace: facelet.localFace)
                guard worldFace == face else { continue }
                let (gr, gc) = gridPosition(cubie: cubie, face: face)
                if gr == row && gc == col {
                    return (ci, fi)
                }
            }
        }
        return nil
    }

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
