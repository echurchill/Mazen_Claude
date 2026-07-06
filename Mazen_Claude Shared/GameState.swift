import simd
import Foundation

class GameState {
    let worldScale: WorldScale
    let cubeModel: CubeModel
    var player: PlayerState
    var camera = CameraState()
    var celestialSystem = CelestialSystem()
    // M9.5-3: slow idle spin of the whole game cube (a planet turning under its sun).
    var spinEnabled = true
    var spinPeriod: Float = 120   // seconds per full rotation
    /// Multiplier on world time (sun/moon/spin/fog) only — player controls stay real-time.
    /// A debug fast-forward to reach night / catch an eclipse without waiting (M9 Phases 5–7).
    var timeScale: Float = 1
    var time: Float = 0

    /// Hold-to-walk state: the input layer sets these on key down/up and `update` chains the
    /// next hop the instant the current one ends, so walking is continuous and smooth rather
    /// than gated by the OS key-repeat.
    var forwardHeld = false
    var backwardHeld = false
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

    /// Debug pacing for slice twists (M12-E verification): watch a split happen slowly, or hold a
    /// twist mid-way and scrub it frame-by-frame with the bracket keys.
    enum TwistPacing { case normal, slow, step }
    var twistPacing: TwistPacing = .normal

    struct DiscoveryAnim {
        let cubieIndex: Int
        let faceletIndex: Int
        var elapsed: Float = 0
        let duration: Float = 1.5
    }
    var activeAnimations: [DiscoveryAnim] = []

    init(size: Int = 3) {
        let ws = WorldScale(cubeSize: size)
        worldScale = ws
        cubeModel = CubeModel(worldScale: ws)
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
        time += deltaTime * timeScale
        camera.updateOrbit(deltaTime: deltaTime)

        if player.updateMovement(deltaTime: deltaTime) {
            onPlayerArrived()
        }
        player.updateTurn(deltaTime: deltaTime)

        // Chain held-key walking so movement is continuous (no waiting on OS key-repeat).
        if !player.isMoving && !player.isTurning && !sliceRotation.isActive {
            if forwardHeld {
                if camera.mode == .firstPerson { steerToLook() }
                player.tryMoveForward(cubeModel: cubeModel)
            } else if backwardHeld {
                player.tryMoveBackward(cubeModel: cubeModel)
            }
        }

        if sliceRotation.isActive {
            // .step holds the twist for manual scrubbing (see stepSlice); .slow crawls; .normal auto.
            if twistPacing != .step {
                let scale: Float = twistPacing == .slow ? 0.15 : 1.0
                sliceRotation.progress += deltaTime * sliceRotation.speed * scale / abs(sliceRotation.angle)
            }
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

    /// The current idle-spin transform of the game cube (M9.5-3). Applied to the game-cube
    /// render instances and the first-person camera (which rides the spin); the sun/moon and
    /// the orbit camera stay world-frame, so the sun sweeps across the faces as the cube turns.
    func worldSpinMatrix() -> float4x4 {
        guard spinEnabled else { return matrix_identity_float4x4 }
        let angle = time / spinPeriod * 2 * .pi
        return float4x4.rotation(radians: angle, axis: SIMD3(0, 1, 0))
    }

    func viewProjectionMatrix(aspect: Float) -> float4x4 {
        camera.viewProjectionMatrix(aspect: aspect, player: player, cubeModel: cubeModel, sliceRotation: sliceRotation, worldSpin: worldSpinMatrix())
    }

    func cameraPosition() -> SIMD3<Float> {
        camera.cameraPosition(player: player, cubeModel: cubeModel, sliceRotation: sliceRotation, worldSpin: worldSpinMatrix())
    }

    func cameraUp() -> SIMD3<Float> {
        camera.cameraUp(player: player, cubeModel: cubeModel, sliceRotation: sliceRotation, worldSpin: worldSpinMatrix())
    }

    /// Mouselook (Caps-Lock) steering: snap the discrete `facing` to the 8-way nearest the
    /// current mouse look, then set `lookYaw` to the leftover angle so the view doesn't jump.
    /// Geometry-based (via `worldToHeading8`), so it stays consistent with however the camera
    /// renders the look — no separate sign convention to keep straight.
    func steerToLook() {
        let up = player.face.normal
        let base = CameraState.headingToWorld(player.facing, face: player.face)
        let look = simd_quatf(angle: camera.lookYaw, axis: up).act(base)
        let newFacing = CameraState.worldToHeading8(look, face: player.face)
        let snapped = CameraState.headingToWorld(newFacing, face: player.face)
        // signed residual angle from the snapped facing to the actual look, about `up`
        camera.lookYaw = atan2f(dot(cross(snapped, look), up), dot(snapped, look))
        player.facing = newFacing
    }

    // MARK: - Discovery

    private func onPlayerArrived() {
        // M11.2c: walk-through — stepping onto a portal tile switches worlds (no F). Fires only on a
        // real tile crossing, so it never triggers at spawn while you're already standing on one.
        if let (pci, pfi) = cubeModel.faceletAt(face: player.face, row: player.row, col: player.col),
           cubeModel.cubies[pci].facelets[pfi].props.contains(where: { $0.kind == .portal }) {
            portalRequested = true
        }
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

    /// Debug: manually scrub an in-progress twist (single-step verification, `.step` pacing only).
    /// Advances/retreats `progress`; finalizes when it reaches 1, and can be scrubbed back toward 0.
    func stepSlice(_ delta: Float) {
        guard twistPacing == .step, sliceRotation.isActive else { return }
        sliceRotation.progress = max(0, sliceRotation.progress + delta)
        if sliceRotation.progress >= 1.0 {
            sliceRotation.progress = 1.0
            sliceRotation.isActive = false
            finalizeSliceRotation()
        }
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
                    let oldDir = CameraState.headingToWorld(player.facing, face: player.face)
                    let newDir = rotQ.act(oldDir)
                    player.facing = CameraState.worldToHeading8(newDir, face: player.face)

                    // Rotate the standing sub-cell the same way the tile's contents rotate:
                    // rotate its offset-from-center by the slice quaternion, then re-read it
                    // in the face frame. Consistent with the openings rotation (same rotQ),
                    // so the player stays on the rotated path cross.
                    let t = player.face.tangent, b = player.face.bitangent
                    let oldOffset = t * Float(player.subCol - 1) + b * Float(player.subRow - 1)
                    let newOffset = rotQ.act(oldOffset)
                    player.subCol = min(2, max(0, Int(dot(newOffset, t).rounded()) + 1))
                    player.subRow = min(2, max(0, Int(dot(newOffset, b).rounded()) + 1))
                    break
                }
            }
        }

        onPlayerArrived()
    }

    // MARK: - Interaction (M10 Phase G)

    /// Set by `interact()` when the player stands on a portal tile; the Renderer consumes it to
    /// switch worlds (M11.2), then clears it. Lives here (per-world) because interact() runs on the
    /// active world; the Renderer owns the world stack, so the world-switch itself happens there.
    var portalRequested = false

    /// The interaction hook: act on any interactive props on the player's current tile.
    /// A portal takes priority (stepping "through the door" switches worlds); otherwise chests
    /// toggle open ↔ closed. This is the dispatch point where a lever would trigger a slice
    /// rotation, etc.
    func interact() {
        guard let (ci, fi) = cubeModel.faceletAt(face: player.face, row: player.row, col: player.col) else { return }
        let props = cubeModel.cubies[ci].facelets[fi].props
        if props.contains(where: { $0.kind == .portal }) {
            portalRequested = true
            return
        }
        for pi in cubeModel.cubies[ci].facelets[fi].props.indices
        where cubeModel.cubies[ci].facelets[fi].props[pi].kind == .chest {
            cubeModel.cubies[ci].facelets[fi].props[pi].state = 1 - cubeModel.cubies[ci].facelets[fi].props[pi].state
        }
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
        let n = Int32(cubeModel.size - 1)
        switch face {
        case .positiveX: return (Int(pos.y), Int(n - pos.z))
        case .negativeX: return (Int(pos.y), Int(pos.z))
        case .positiveY: return (Int(n - pos.z), Int(pos.x))
        case .negativeY: return (Int(pos.z), Int(pos.x))
        case .positiveZ: return (Int(pos.y), Int(pos.x))
        case .negativeZ: return (Int(pos.y), Int(n - pos.x))
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

    static func scale(_ s: Float) -> float4x4 {
        return float4x4(columns: (
            SIMD4(s, 0, 0, 0),
            SIMD4(0, s, 0, 0),
            SIMD4(0, 0, s, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    /// Non-uniform scale — needed for imported kit buildings whose footprint fills a tile
    /// but whose height must stay realistic (M12-E house).
    static func scale(_ x: Float, _ y: Float, _ z: Float) -> float4x4 {
        return float4x4(columns: (
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, z, 0),
            SIMD4(0, 0, 0, 1)
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
