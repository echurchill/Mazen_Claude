import simd
import Foundation

class GameState {
    let cubeModel: CubeModel
    var player: PlayerState
    var camera = CameraState()
    var time: Float = 0
    var frameTimeMs: Float = 0
    var avgFrameTimeMs: Float = 0

    struct SliceRotation {
        var isActive = false
        var axis: Int = 0
        var index: Int = 0
        var angle: Float = 0
        var progress: Float = 0
        var speed: Float = 2.5
        var affectedCubies: Set<Int> = []
        var playerCubieIndex: Int = -1
    }
    var sliceRotation = SliceRotation()

    struct DiscoveryAnim {
        let cubieIndex: Int
        let faceletIndex: Int
        var elapsed: Float = 0
        let duration: Float = 1.5
    }
    var activeAnimations: [DiscoveryAnim] = []

    init(size: Int = 3) {
        cubeModel = CubeModel(size: size)
        player = PlayerState(size: size)
        printMazeDebug(face: player.face)
    }

    func printMazeDebug(face: CubeFace) {
        let n = cubeModel.size
        NSLog("Maze for face \(face) (\(n)x\(n)):")
        for row in 0..<n {
            var top = ""
            var mid = ""
            for col in 0..<n {
                if let (ci, fi) = cubeModel.faceletAt(face: face, row: row, col: col) {
                    let openings = cubeModel.cubies[ci].facelets[fi].mazeTile.openings
                    top += openings.contains(.north) ? "+  " : "+--"
                    mid += openings.contains(.west) ? "   " : "|  "
                } else {
                    top += "+??"
                    mid += "|??"
                }
            }
            top += "+"
            mid += "|"
            NSLog("%@", top)
            NSLog("%@", mid)
        }
        var bottom = ""
        for _ in 0..<n { bottom += "+--" }
        bottom += "+"
        NSLog("%@", bottom)
        NSLog("Player at (\(player.row),\(player.col)) facing \(player.facing)")
    }

    // MARK: - Update

    func update(deltaTime: Float) {
        time += deltaTime
        camera.updateOrbit(deltaTime: deltaTime)

        if player.updateMovement(deltaTime: deltaTime) {
            onPlayerArrived()
        }
        player.updateTurn(deltaTime: deltaTime)

        if sliceRotation.isActive {
            sliceRotation.progress += deltaTime * sliceRotation.speed / abs(sliceRotation.angle)
            if sliceRotation.progress >= 1.0 {
                sliceRotation.progress = 1.0
                sliceRotation.isActive = false
                finalizeSliceRotation()
            }
        }

        var completed: [Int] = []
        for i in activeAnimations.indices {
            activeAnimations[i].elapsed += deltaTime
            let t = min(activeAnimations[i].elapsed / activeAnimations[i].duration, 1.0)
            let ci = activeAnimations[i].cubieIndex
            let fi = activeAnimations[i].faceletIndex
            cubeModel.cubies[ci].facelets[fi].discoveryAmount = t
            if t >= 1.0 {
                cubeModel.cubies[ci].facelets[fi].tileState = .discovered
                completed.append(i)
            }
        }
        for i in completed.reversed() {
            activeAnimations.remove(at: i)
        }
    }

    // MARK: - Camera convenience

    func viewProjectionMatrix(aspect: Float) -> float4x4 {
        camera.viewProjectionMatrix(aspect: aspect, player: player, cubeModel: cubeModel, sliceRotation: sliceRotation)
    }

    func cameraPosition() -> SIMD3<Float> {
        camera.cameraPosition(player: player, cubeModel: cubeModel, sliceRotation: sliceRotation)
    }

    func cameraUp() -> SIMD3<Float> {
        camera.cameraUp(player: player, cubeModel: cubeModel, sliceRotation: sliceRotation)
    }

    // MARK: - Discovery

    private func onPlayerArrived() {
        discoverTile(face: player.face, row: player.row, col: player.col)
        let n = cubeModel.size
        for dir in SurfaceDirection.allCases {
            let (dr, dc) = PlayerState.deltaForDirection(dir)
            let nr = player.row + dr
            let nc = player.col + dc
            let neighborFace: CubeFace
            let neighborRow: Int
            let neighborCol: Int
            if nr >= 0 && nr < n && nc >= 0 && nc < n {
                neighborFace = player.face
                neighborRow = nr
                neighborCol = nc
            } else {
                let crossing = cubeModel.edgeCrossing(face: player.face, direction: dir, row: player.row, col: player.col)
                neighborFace = crossing.face
                neighborRow = crossing.row
                neighborCol = crossing.col
            }
            if let (ci, fi) = cubeModel.faceletAt(face: neighborFace, row: neighborRow, col: neighborCol) {
                if cubeModel.cubies[ci].facelets[fi].tileState == .unknown {
                    cubeModel.cubies[ci].facelets[fi].tileState = .adjacent
                    cubeModel.cubies[ci].facelets[fi].discoveryAmount = 0.2
                }
            }
        }
    }

    func discoverTile(face: CubeFace, row: Int, col: Int) {
        guard let (ci, fi) = cubeModel.faceletAt(face: face, row: row, col: col) else { return }
        let facelet = cubeModel.cubies[ci].facelets[fi]
        guard facelet.tileState == .unknown || facelet.tileState == .adjacent else { return }
        cubeModel.cubies[ci].facelets[fi].tileState = .adjacent
        cubeModel.cubies[ci].facelets[fi].discoveryAmount = 0
        activeAnimations.append(DiscoveryAnim(cubieIndex: ci, faceletIndex: fi))
    }

    // MARK: - Slice Rotation

    func startSliceRotation(clockwise: Bool) {
        guard !sliceRotation.isActive && !player.isMoving && !player.isTurning else { return }

        let (axis, index) = cubeModel.sliceAxisAndIndex(for: player.face)
        let angle: Float = clockwise ? -.pi / 2 : .pi / 2

        let cubieIndices = cubeModel.cubieIndicesInSlice(axis: axis, index: index)
        var playerCI = -1
        if let (ci, _) = cubeModel.faceletAt(face: player.face, row: player.row, col: player.col) {
            playerCI = ci
        }

        sliceRotation = SliceRotation(
            isActive: true,
            axis: axis,
            index: index,
            angle: angle,
            progress: 0,
            speed: 2.5,
            affectedCubies: Set(cubieIndices),
            playerCubieIndex: playerCI
        )
    }

    private func finalizeSliceRotation() {
        let playerCI = sliceRotation.playerCubieIndex
        cubeModel.applySliceRotation(axis: sliceRotation.axis, index: sliceRotation.index, angle: sliceRotation.angle)

        if playerCI >= 0 {
            let cubie = cubeModel.cubies[playerCI]
            for facelet in cubie.facelets {
                let worldFace = closestFace(to: cubie.orientation.act(facelet.localFace.normal))
                if worldFace == player.face {
                    let pos = cubie.position
                    let (newRow, newCol) = gridPositionForFace(pos: pos, face: worldFace)
                    player.row = newRow
                    player.col = newCol

                    let rotQ = simd_quatf(angle: sliceRotation.angle, axis: sliceRotation.axis == 0 ? SIMD3(1,0,0) : sliceRotation.axis == 1 ? SIMD3(0,1,0) : SIMD3(0,0,1))
                    let tangent = player.face.tangent
                    let bitangent = player.face.bitangent
                    let oldDir = CameraState.directionToWorld(player.facing, face: player.face, tangent: tangent, bitangent: bitangent)
                    let newDir = rotQ.act(oldDir)
                    player.facing = worldToDirection(newDir, face: player.face, tangent: tangent, bitangent: bitangent)
                    break
                }
            }
        }

        onPlayerArrived()
    }

    // MARK: - Helpers

    private func closestFace(to direction: SIMD3<Float>) -> CubeFace {
        var bestFace = CubeFace.positiveX
        var bestDot: Float = -2
        for face in CubeFace.allCases {
            let d = dot(direction, face.normal)
            if d > bestDot { bestDot = d; bestFace = face }
        }
        return bestFace
    }

    private func gridPositionForFace(pos: SIMD3<Int32>, face: CubeFace) -> (row: Int, col: Int) {
        switch face {
        case .positiveX, .negativeX: return (Int(pos.y), Int(pos.z))
        case .positiveY, .negativeY: return (Int(pos.z), Int(pos.x))
        case .positiveZ, .negativeZ: return (Int(pos.y), Int(pos.x))
        }
    }

    private func worldToDirection(_ dir: SIMD3<Float>, face: CubeFace, tangent: SIMD3<Float>, bitangent: SIMD3<Float>) -> SurfaceDirection {
        let dotT = dot(dir, tangent)
        let dotB = dot(dir, bitangent)
        if abs(dotT) > abs(dotB) {
            return dotT > 0 ? .east : .west
        } else {
            return dotB > 0 ? .south : .north
        }
    }
}

// MARK: - float4x4 helpers

extension float4x4 {
    static func perspective(fovYRadians fovy: Float, aspect: Float, nearZ: Float, farZ: Float) -> float4x4 {
        let ys = 1.0 / tanf(fovy * 0.5)
        let xs = ys / aspect
        let zs = farZ / (nearZ - farZ)
        return float4x4(columns: (
            SIMD4(xs,  0,  0,  0),
            SIMD4( 0, ys,  0,  0),
            SIMD4( 0,  0, zs, -1),
            SIMD4( 0,  0, zs * nearZ, 0)
        ))
    }

    static func rotation(radians: Float, axis: SIMD3<Float>) -> float4x4 {
        let a = normalize(axis)
        let ct = cosf(radians)
        let st = sinf(radians)
        let ci = 1 - ct
        let x = a.x, y = a.y, z = a.z
        return float4x4(columns: (
            SIMD4(ct + x*x*ci,     y*x*ci + z*st, z*x*ci - y*st, 0),
            SIMD4(x*y*ci - z*st,   ct + y*y*ci,   z*y*ci + x*st, 0),
            SIMD4(x*z*ci + y*st,   y*z*ci - x*st, ct + z*z*ci,   0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    static func translation(_ x: Float, _ y: Float, _ z: Float) -> float4x4 {
        return float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(x, y, z, 1)
        ))
    }

    static func orthographic(left: Float, right: Float, bottom: Float, top: Float, nearZ: Float, farZ: Float) -> float4x4 {
        let sx = 2.0 / (right - left)
        let sy = 2.0 / (top - bottom)
        let sz = 1.0 / (nearZ - farZ)
        let tx = -(right + left) / (right - left)
        let ty = -(top + bottom) / (top - bottom)
        let tz = nearZ / (nearZ - farZ)
        return float4x4(columns: (
            SIMD4(sx,  0,  0, 0),
            SIMD4( 0, sy,  0, 0),
            SIMD4( 0,  0, sz, 0),
            SIMD4(tx, ty, tz, 1)
        ))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = normalize(target - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return float4x4(columns: (
            SIMD4( s.x,  u.x, -f.x, 0),
            SIMD4( s.y,  u.y, -f.y, 0),
            SIMD4( s.z,  u.z, -f.z, 0),
            SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        ))
    }
}
