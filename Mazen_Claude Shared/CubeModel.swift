import simd

class CubeModel {
    let size: Int
    var cubies: [Cubie]

    private var projectionDirty = true
    private var cachedProjection: [CubeFace: [[FaceletID?]]] = [:]

    init(size: Int) {
        self.size = size
        self.cubies = []
        buildCubies()
        generateMaze()
        rebuildProjection()
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
        let n = Float(size)
        let halfN = n / 2.0
        let tileSize: Float = 1.0
        let gap: Float = 0.04

        let normal = face.normal
        let tangent = face.tangent
        let bitangent = face.bitangent

        let colF = (Float(col) + 0.5 - halfN) * (tileSize + gap)
        let rowF = (Float(row) + 0.5 - halfN) * (tileSize + gap)

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
        switch face {
        case .positiveX, .negativeX:
            return (row: Int(pos.y), col: Int(pos.z))
        case .positiveY, .negativeY:
            return (row: Int(pos.z), col: Int(pos.x))
        case .positiveZ, .negativeZ:
            return (row: Int(pos.y), col: Int(pos.x))
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
        for (ci, cubie) in cubies.enumerated() {
            for (fi, facelet) in cubie.facelets.enumerated() {
                if facelet.id == id { return (ci, fi) }
            }
        }
        return nil
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
