import simd
import Foundation

enum CameraMode {
    case orbit
    case firstPerson
}

class GameState {
    let cubeModel: CubeModel
    var orbitRotation: SIMD2<Float> = SIMD2(0.45, 0.5)
    var orbitDistance: Float = 6.0
    var time: Float = 0
    var frameTimeMs: Float = 0
    var cameraMode: CameraMode = .firstPerson

    // Player state
    var playerFace: CubeFace = .positiveZ
    var playerRow: Int = 1
    var playerCol: Int = 1
    var playerFacing: SurfaceDirection = .north

    // Movement interpolation
    var isMoving = false
    var moveProgress: Float = 0
    var moveSpeed: Float = 2.5
    var moveFromFace: CubeFace = .positiveZ
    var moveFromRow: Int = 0
    var moveFromCol: Int = 0
    var moveToFace: CubeFace = .positiveZ
    var moveToRow: Int = 0
    var moveToCol: Int = 0
    var moveNewFacing: SurfaceDirection = .north

    // Turn interpolation
    var isTurning = false
    var turnProgress: Float = 0
    var turnSpeed: Float = 5.0
    var turnFromFacing: SurfaceDirection = .north
    var turnToFacing: SurfaceDirection = .north

    // Slice rotation
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
        playerRow = size / 2
        playerCol = size / 2
        printMazeDebug(face: playerFace)
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
        NSLog("Player at (\(playerRow),\(playerCol)) facing \(playerFacing)")
    }

    func update(deltaTime: Float) {
        time += deltaTime
        if cameraMode == .orbit {
            orbitRotation.x += deltaTime * 0.15
        }

        // Movement interpolation
        if isMoving {
            moveProgress += deltaTime * moveSpeed
            if moveProgress >= 1.0 {
                moveProgress = 1.0
                isMoving = false
                let crossedFace = moveFromFace != moveToFace
                playerFace = moveToFace
                playerRow = moveToRow
                playerCol = moveToCol
                playerFacing = moveNewFacing
                print("Arrived: \(playerFace) (\(playerRow),\(playerCol)) facing \(playerFacing)\(crossedFace ? " [CROSSED EDGE]" : "")")
                onPlayerArrived()
            }
        }

        // Turn interpolation
        if isTurning {
            turnProgress += deltaTime * turnSpeed
            if turnProgress >= 1.0 {
                turnProgress = 1.0
                isTurning = false
                playerFacing = turnToFacing
            }
        }

        // Slice rotation animation
        if sliceRotation.isActive {
            sliceRotation.progress += deltaTime * sliceRotation.speed / abs(sliceRotation.angle)
            if sliceRotation.progress >= 1.0 {
                sliceRotation.progress = 1.0
                sliceRotation.isActive = false
                finalizeSliceRotation()
            }
        }

        // Discovery animations
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

    // MARK: - Player movement

    func tryMoveForward() {
        guard !isMoving && !isTurning else { return }
        guard let (ci, fi) = cubeModel.faceletAt(face: playerFace, row: playerRow, col: playerCol) else {
            print("No facelet at \(playerFace) (\(playerRow),\(playerCol))")
            return
        }
        let tile = cubeModel.cubies[ci].facelets[fi]
        print("Move: at \(playerFace) (\(playerRow),\(playerCol)) facing \(playerFacing), openings=\(tile.mazeTile.openings.rawValue)")

        guard tile.mazeTile.openings.contains(direction: playerFacing) else {
            print("  Blocked — no opening \(playerFacing)")
            return
        }

        let (dr, dc) = deltaForDirection(playerFacing)
        let newRow = playerRow + dr
        let newCol = playerCol + dc

        if newRow >= 0 && newRow < cubeModel.size && newCol >= 0 && newCol < cubeModel.size {
            if let (tci, tfi) = cubeModel.faceletAt(face: playerFace, row: newRow, col: newCol) {
                let targetTile = cubeModel.cubies[tci].facelets[tfi]
                guard targetTile.mazeTile.openings.contains(direction: playerFacing.opposite) else { return }
            }

            moveFromFace = playerFace
            moveFromRow = playerRow
            moveFromCol = playerCol
            moveToFace = playerFace
            moveToRow = newRow
            moveToCol = newCol
            moveNewFacing = playerFacing
            moveProgress = 0
            isMoving = true
        } else {
            let crossing = cubeModel.edgeCrossing(face: playerFace, direction: playerFacing, row: playerRow, col: playerCol)
            let arrivalDir = crossing.facing.opposite
            if let (tci, tfi) = cubeModel.faceletAt(face: crossing.face, row: crossing.row, col: crossing.col) {
                let targetTile = cubeModel.cubies[tci].facelets[tfi]
                guard targetTile.mazeTile.openings.contains(direction: arrivalDir) else { return }
            } else {
                return
            }

            moveFromFace = playerFace
            moveFromRow = playerRow
            moveFromCol = playerCol
            moveToFace = crossing.face
            moveToRow = crossing.row
            moveToCol = crossing.col
            moveNewFacing = crossing.facing
            moveProgress = 0
            isMoving = true
            print("Edge crossing: \(playerFace) (\(playerRow),\(playerCol)) -> \(crossing.face) (\(crossing.row),\(crossing.col)) facing \(crossing.facing)")
        }
    }

    func tryTurnLeft() {
        guard !isMoving && !isTurning else { return }
        turnFromFacing = playerFacing
        turnToFacing = turnLeft(playerFacing)
        turnProgress = 0
        isTurning = true
    }

    func tryTurnRight() {
        guard !isMoving && !isTurning else { return }
        turnFromFacing = playerFacing
        turnToFacing = turnRight(playerFacing)
        turnProgress = 0
        isTurning = true
    }

    func tryMoveBackward() {
        guard !isMoving && !isTurning else { return }
        let backDir = playerFacing.opposite
        guard let (ci, fi) = cubeModel.faceletAt(face: playerFace, row: playerRow, col: playerCol) else { return }
        let tile = cubeModel.cubies[ci].facelets[fi]
        guard tile.mazeTile.openings.contains(direction: backDir) else { return }

        let (dr, dc) = deltaForDirection(backDir)
        let newRow = playerRow + dr
        let newCol = playerCol + dc

        if newRow >= 0 && newRow < cubeModel.size && newCol >= 0 && newCol < cubeModel.size {
            if let (tci, tfi) = cubeModel.faceletAt(face: playerFace, row: newRow, col: newCol) {
                let targetTile = cubeModel.cubies[tci].facelets[tfi]
                guard targetTile.mazeTile.openings.contains(direction: backDir.opposite) else { return }
            }

            moveFromFace = playerFace
            moveFromRow = playerRow
            moveFromCol = playerCol
            moveToFace = playerFace
            moveToRow = newRow
            moveToCol = newCol
            moveNewFacing = playerFacing
            moveProgress = 0
            isMoving = true
        } else {
            let crossing = cubeModel.edgeCrossing(face: playerFace, direction: backDir, row: playerRow, col: playerCol)
            let arrivalDir = crossing.facing.opposite
            if let (tci, tfi) = cubeModel.faceletAt(face: crossing.face, row: crossing.row, col: crossing.col) {
                let targetTile = cubeModel.cubies[tci].facelets[tfi]
                guard targetTile.mazeTile.openings.contains(direction: arrivalDir) else { return }
            } else {
                return
            }

            moveFromFace = playerFace
            moveFromRow = playerRow
            moveFromCol = playerCol
            moveToFace = crossing.face
            moveToRow = crossing.row
            moveToCol = crossing.col
            moveNewFacing = crossing.facing.opposite
            moveProgress = 0
            isMoving = true
        }
    }

    private func onPlayerArrived() {
        discoverTile(face: playerFace, row: playerRow, col: playerCol)
        let n = cubeModel.size
        for dir in SurfaceDirection.allCases {
            let (dr, dc) = deltaForDirection(dir)
            let nr = playerRow + dr
            let nc = playerCol + dc
            let neighborFace: CubeFace
            let neighborRow: Int
            let neighborCol: Int
            if nr >= 0 && nr < n && nc >= 0 && nc < n {
                neighborFace = playerFace
                neighborRow = nr
                neighborCol = nc
            } else {
                let crossing = cubeModel.edgeCrossing(face: playerFace, direction: dir, row: playerRow, col: playerCol)
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
        guard !sliceRotation.isActive && !isMoving && !isTurning else { return }

        let (axis, index) = cubeModel.sliceAxisAndIndex(for: playerFace)
        let angle: Float = clockwise ? -.pi / 2 : .pi / 2

        let cubieIndices = cubeModel.cubieIndicesInSlice(axis: axis, index: index)
        var playerCI = -1
        if let (ci, _) = cubeModel.faceletAt(face: playerFace, row: playerRow, col: playerCol) {
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

        // Update player position if they were on the rotating slice
        if playerCI >= 0 {
            let cubie = cubeModel.cubies[playerCI]
            for facelet in cubie.facelets {
                let worldFace = closestFace(to: cubie.orientation.act(facelet.localFace.normal))
                if worldFace == playerFace {
                    let pos = cubie.position
                    let (newRow, newCol) = gridPositionForFace(pos: pos, face: worldFace)
                    playerRow = newRow
                    playerCol = newCol

                    // Rotate facing direction
                    let rotQ = simd_quatf(angle: sliceRotation.angle, axis: sliceRotation.axis == 0 ? SIMD3(1,0,0) : sliceRotation.axis == 1 ? SIMD3(0,1,0) : SIMD3(0,0,1))
                    let tangent = playerFace.tangent
                    let bitangent = playerFace.bitangent
                    let oldDir = directionToWorld(playerFacing, face: playerFace, tangent: tangent, bitangent: bitangent)
                    let newDir = rotQ.act(oldDir)
                    playerFacing = worldToDirection(newDir, face: playerFace, tangent: tangent, bitangent: bitangent)
                    break
                }
            }
        }

        // Rediscover around player's new position
        onPlayerArrived()
    }

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

    // MARK: - Camera

    func viewProjectionMatrix(aspect: Float) -> float4x4 {
        let projection = float4x4.perspective(
            fovYRadians: (80.0 / 180.0) * .pi,
            aspect: aspect,
            nearZ: 0.01,
            farZ: 100.0
        )

        switch cameraMode {
        case .orbit:
            let rotX = float4x4.rotation(radians: orbitRotation.y, axis: SIMD3(1, 0, 0))
            let rotY = float4x4.rotation(radians: orbitRotation.x, axis: SIMD3(0, 1, 0))
            let translate = float4x4.translation(0, 0, -orbitDistance)
            return projection * translate * rotX * rotY

        case .firstPerson:
            let (eye, forward, up) = firstPersonCamera()
            let view = float4x4.lookAt(eye: eye, target: eye + forward, up: up)
            return projection * view
        }
    }

    func cameraPosition() -> SIMD3<Float> {
        switch cameraMode {
        case .orbit:
            return SIMD3(0, 0, orbitDistance)
        case .firstPerson:
            let (eye, _, _) = firstPersonCamera()
            return eye
        }
    }

    private func firstPersonCamera() -> (eye: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) {
        let eyeHeight: Float = 0.55

        let face: CubeFace
        let row: Int
        let col: Int

        if isMoving {
            face = moveFromFace
            row = moveFromRow
            col = moveFromCol
        } else {
            face = playerFace
            row = playerRow
            col = playerCol
        }

        let tileMatrix = cubeModel.worldMatrix(face: face, row: row, col: col)
        let tileCenter = SIMD3<Float>(tileMatrix.columns.3.x, tileMatrix.columns.3.y, tileMatrix.columns.3.z)
        let faceNormal = face.normal
        let faceTangent = face.tangent
        let faceBitangent = face.bitangent

        var eyePos = tileCenter + faceNormal * eyeHeight
        var upDir = faceNormal

        // Interpolate position during movement
        if isMoving {
            let toMatrix = cubeModel.worldMatrix(face: moveToFace, row: moveToRow, col: moveToCol)
            let toCenter = SIMD3<Float>(toMatrix.columns.3.x, toMatrix.columns.3.y, toMatrix.columns.3.z)
            let toEye = toCenter + moveToFace.normal * eyeHeight
            let t = smoothstep(moveProgress)
            if moveFromFace != moveToFace {
                eyePos = normalize(mix(eyePos, toEye, t: t)) * length(eyePos) * (1 - t) + normalize(mix(eyePos, toEye, t: t)) * length(toEye) * t
                upDir = normalize(mix(faceNormal, moveToFace.normal, t: t))
            } else {
                eyePos = mix(eyePos, toEye, t: t)
            }
        }

        // Facing direction in world space
        var facingWorld: SIMD3<Float>
        if isMoving && moveFromFace != moveToFace {
            let fromDir = directionToWorld(playerFacing, face: face, tangent: faceTangent, bitangent: faceBitangent)
            let toTangent = moveToFace.tangent
            let toBitangent = moveToFace.bitangent
            let toDir = directionToWorld(moveNewFacing, face: moveToFace, tangent: toTangent, bitangent: toBitangent)
            let t = smoothstep(moveProgress)
            facingWorld = normalize(mix(fromDir, toDir, t: t))
        } else {
            facingWorld = directionToWorld(playerFacing, face: face, tangent: faceTangent, bitangent: faceBitangent)
        }

        // Interpolate facing during turns
        if isTurning {
            let fromWorld = directionToWorld(turnFromFacing, face: face, tangent: faceTangent, bitangent: faceBitangent)
            let toWorld = directionToWorld(turnToFacing, face: face, tangent: faceTangent, bitangent: faceBitangent)
            let t = smoothstep(turnProgress)
            facingWorld = normalize(mix(fromWorld, toWorld, t: t))
        }

        // Slight downward pitch to see the floor
        let pitchAngle: Float = -0.12
        facingWorld = normalize(facingWorld + upDir * pitchAngle)

        // Apply slice rotation to camera if player is on rotating slice
        if sliceRotation.isActive && sliceRotation.playerCubieIndex >= 0 && sliceRotation.affectedCubies.contains(sliceRotation.playerCubieIndex) {
            let axisVec: SIMD3<Float> = sliceRotation.axis == 0 ? SIMD3(1,0,0) : sliceRotation.axis == 1 ? SIMD3(0,1,0) : SIMD3(0,0,1)
            let t = smoothstep(sliceRotation.progress)
            let currentAngle = sliceRotation.angle * t
            let rotQ = simd_quatf(angle: currentAngle, axis: axisVec)
            eyePos = rotQ.act(eyePos)
            facingWorld = rotQ.act(facingWorld)
            upDir = rotQ.act(upDir)
        }

        return (eyePos, facingWorld, upDir)
    }

    private func directionToWorld(_ dir: SurfaceDirection, face: CubeFace, tangent: SIMD3<Float>, bitangent: SIMD3<Float>) -> SIMD3<Float> {
        switch dir {
        case .north: return -bitangent
        case .south: return bitangent
        case .east:  return tangent
        case .west:  return -tangent
        }
    }

    // MARK: - Helpers

    private func deltaForDirection(_ dir: SurfaceDirection) -> (Int, Int) {
        switch dir {
        case .north: return (-1, 0)
        case .south: return (1, 0)
        case .east:  return (0, 1)
        case .west:  return (0, -1)
        }
    }

    private func turnLeft(_ dir: SurfaceDirection) -> SurfaceDirection {
        switch dir {
        case .north: return .west
        case .west:  return .south
        case .south: return .east
        case .east:  return .north
        }
    }

    private func turnRight(_ dir: SurfaceDirection) -> SurfaceDirection {
        switch dir {
        case .north: return .east
        case .east:  return .south
        case .south: return .west
        case .west:  return .north
        }
    }

    private func smoothstep(_ t: Float) -> Float {
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
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
