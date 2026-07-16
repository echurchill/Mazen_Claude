import simd
import Foundation

/// Master switch for the chatty developer console output — the per-world maze ASCII diagram,
/// player start/arrival lines, and asset-load summaries. Off by default so startup stays quiet;
/// flip to `true` when you want the play-by-play. Genuine error/failure logs are NOT gated.
let verboseDebugLog = false

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
        /// M16.2: a REFUSED twist — the slice strains a few degrees and springs back (a damped
        /// wobble); nothing is finalized. The cue that teaches "locked" without a word of UI.
        var isRefusal = false

        // R2.3: the ONE definition of the in-flight twist transform. SceneBuilder, the asset
        // instancer, and the camera all animate off these — previously three hand-copied
        // smoothstep+rotation constructions that had to be kept in sync by comment.
        var axisVector: SIMD3<Float> {
            axis == 0 ? SIMD3(1, 0, 0) : axis == 1 ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
        }
        /// Smoothstep-eased current angle of the in-flight twist — or, for a refusal (M16.2),
        /// a damped wobble in the attempted direction that returns exactly to rest.
        var currentAngle: Float {
            if isRefusal {
                let amplitude: Float = 0.06   // ~3.4° of strain
                let direction: Float = angle < 0 ? -1 : 1
                return direction * amplitude * sinf(progress * .pi * 3) * (1 - progress)
            }
            let t = progress * progress * (3 - 2 * progress)
            return angle * t
        }
        var currentMatrix: float4x4 { float4x4.rotation(radians: currentAngle, axis: axisVector) }
        var currentQuat: simd_quatf { simd_quatf(angle: currentAngle, axis: axisVector) }
    }
    var sliceRotation = SliceRotation()

    /// Debug pacing for slice twists (M12-E verification): watch a split happen slowly, or hold a
    /// twist mid-way and scrub it frame-by-frame with the bracket keys.
    enum TwistPacing { case normal, slow, step }
    var twistPacing: TwistPacing = .normal

    /// Set when a twist was refused because it would tear a bonded structure (M13). A refusal cue
    /// (visual/audio, TODO) reads and clears it. Harmless until bonds exist.
    var twistRefused = false

    struct DiscoveryAnim {
        let cubieIndex: Int
        let faceletIndex: Int
        var elapsed: Float = 0
        let duration: Float = 1.5
    }
    var activeAnimations: [DiscoveryAnim] = []

    /// The world's identity name — the `destination` half of its `WorldKey` (M15.0 world graph):
    /// "earth" for the overworld, "moon", "temple-interior", … Used to resolve sky/portal edges.
    let name: String

    init(size: Int = 3, name: String = "world", interior: Bool = false, stamp: WorldStamp = .overworldDemo) {
        self.name = name
        let ws = WorldScale(cubeSize: size, interior: interior)
        worldScale = ws
        cubeModel = CubeModel(worldScale: ws, stamp: stamp)
        player = PlayerState(size: size, standGrid: ws.standGrid)
        if verboseDebugLog { printMazeDebug(face: player.face) }
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
                // Steer to look FIRST, same as forward — else backward moves opposite the stale
                // discrete facing (which lags the camera after mouselook), so S sometimes went the
                // wrong way (Eddie). Now it always moves directly away from where you're looking.
                if camera.mode == .firstPerson { steerToLook() }
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
                if sliceRotation.isRefusal {
                    twistRefused = false   // cue delivered; nothing to finalize
                } else {
                    finalizeSliceRotation()
                }
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

    /// Everything the renderer needs from the camera this frame, from ONE first-person pose
    /// evaluation (R2.4 — previously viewProjection/position/up each re-derived the full pose,
    /// 3× per frame, each with its own fresh spin matrix).
    struct FramePose {
        let viewProjection: float4x4
        let position: SIMD3<Float>
        let up: SIMD3<Float>
    }

    func framePose(aspect: Float) -> FramePose {
        let pose: FirstPersonPose? = camera.mode == .firstPerson
            ? camera.firstPersonPose(player: player, cubeModel: cubeModel,
                                     sliceRotation: sliceRotation, worldSpin: worldSpinMatrix())
            : nil
        return FramePose(
            viewProjection: camera.viewProjectionMatrix(aspect: aspect, cubeModel: cubeModel, pose: pose),
            position: camera.cameraPosition(cubeModel: cubeModel, pose: pose),
            up: camera.cameraUp(pose: pose)
        )
    }

    /// Mouselook (Caps-Lock) steering: snap the discrete `facing` to the 8-way nearest the
    /// current mouse look, then set `lookYaw` to the leftover angle so the view doesn't jump.
    /// Geometry-based (via `worldToHeading8`), so it stays consistent with however the camera
    /// renders the look — no separate sign convention to keep straight.
    func steerToLook() {
        let interior = worldScale.interior
        let up = interior ? -player.face.normal : player.face.normal
        let base = CameraState.headingToWorld(player.facing, face: player.face, interior: interior)
        let look = simd_quatf(angle: camera.lookYaw, axis: up).act(base)
        let newFacing = CameraState.worldToHeading8(look, face: player.face, interior: interior)
        let snapped = CameraState.headingToWorld(newFacing, face: player.face, interior: interior)
        // signed residual angle from the snapped facing to the actual look, about `up`
        camera.lookYaw = atan2f(dot(cross(snapped, look), up), dot(snapped, look))
        player.facing = newFacing
    }

    /// M16.3: true when no dial anywhere is still unaligned.
    private func allDialsAligned() -> Bool {
        for cubie in cubeModel.cubies {
            for facelet in cubie.facelets {
                if facelet.props.contains(where: { $0.kind == .dial && $0.state == 0 }) { return false }
            }
        }
        return true
    }

    // MARK: - Discovery

    private func onPlayerArrived(viaMove: Bool = true) {
        // M11.2c: walk-through — stepping onto a portal tile switches worlds (no F). Fires only on a
        // real tile crossing, so it never triggers at spawn while you're already standing on one.
        // Also NOT on a twist (viaMove == false): a slice that rotates a portal under you must not
        // teleport you home — you interact with F or walk onto it (Eddie, M19 — the moon's return
        // portal sits by spawn, so a twist kept landing it under the player).
        // M15.2: the portal's `state` says WHERE it leads (index into Renderer.portalDestinations).
        if viaMove,
           let (pci, pfi) = cubeModel.faceletAt(face: player.face, row: player.row, col: player.col),
           let portal = cubeModel.cubies[pci].facelets[pfi].props.first(where: { $0.kind == .portal }),
           !cubeModel.sealedPortalCubies.contains(pci) {   // M16.4: a sealed door is just a door
            portalRequested = true
            portalDestinationID = portal.state
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

        // M13 bandaging: a twist that would tear a bonded structure is REFUSED — and the refusal
        // IS the cue (M16.2): the slice strains against the lock and springs back (the camera
        // rides the strain), while the bonded structure flares (SceneBuilder). No finalize.
        guard cubeModel.canRotateSlice(axis: axis, index: index) else {
            twistRefused = true
            sliceRotation = SliceRotation(
                isActive: true, axis: axis, index: index, angle: angle,
                progress: 0, speed: 4.0,
                affectedCubies: Set(cubieIndices), playerCubieIndex: playerCI,
                isRefusal: true
            )
            return
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

        // M16.4: the opening — a completed twist of an UNLOCKED sealed door's slice swings it
        // open: the door lights up and becomes a portal. (Still bonded ⇒ the twist was refused
        // long before we got here, so checking "no bond" is enough.)
        var opened = false
        for ci in sliceRotation.affectedCubies where cubeModel.sealedPortalCubies.contains(ci) {
            if !cubeModel.bondedGroups.contains(where: { $0.contains(ci) }) {
                cubeModel.sealedPortalCubies.remove(ci)
                opened = true
            }
        }
        if opened { updateDoorPlinths() }    // the twist swings it open ⇒ the plinth shows the portal

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
                    let interior = worldScale.interior
                    let oldDir = CameraState.headingToWorld(player.facing, face: player.face, interior: interior)
                    let newDir = rotQ.act(oldDir)
                    player.facing = CameraState.worldToHeading8(newDir, face: player.face, interior: interior)

                    // Rotate the standing sub-cell the same way the tile's contents rotate:
                    // rotate its offset-from-center by the slice quaternion, then re-read it
                    // in the face frame. Consistent with the openings rotation (same rotQ),
                    // so the player stays on the rotated path cross.
                    let t = player.face.tangent
                    let b = interior ? -player.face.bitangent : player.face.bitangent
                    let sc = player.standCenter
                    let oldOffset = t * Float(player.subCol - sc) + b * Float(player.subRow - sc)
                    let newOffset = rotQ.act(oldOffset)
                    player.subCol = min(player.standGrid - 1, max(0, Int(dot(newOffset, t).rounded()) + sc))
                    player.subRow = min(player.standGrid - 1, max(0, Int(dot(newOffset, b).rounded()) + sc))
                    break
                }
            }
        }

        onPlayerArrived(viaMove: false)   // a twist finalizing must not trigger a walk-through portal
    }

    // MARK: - Interaction (M10 Phase G)

    /// Set by `interact()` when the player stands on a portal tile; the Renderer consumes it to
    /// switch worlds (M11.2), then clears it. Lives here (per-world) because interact() runs on the
    /// active world; the Renderer owns the world stack, so the world-switch itself happens there.
    var portalRequested = false
    /// Which world the requesting portal leads to (M15.2) — the portal Prop's `state`, indexing
    /// `Renderer.portalDestinations`. Ignored when the swap is a pop (leaving a sub-world).
    var portalDestinationID = 0

    /// The interaction hook: act on any interactive props on the player's current tile.
    /// A portal takes priority (stepping "through the door" switches worlds); otherwise chests
    /// toggle open ↔ closed. This is the dispatch point where a lever would trigger a slice
    /// rotation, etc.
    /// M16.6 — the door plinth speaks the lock's state, and only ever says it in glyphs (no UI text).
    /// blank → **swirl** once the bond dissolves ("turn/combine to produce" — the verb naming the
    /// twist M16.4 requires) → **portal** once that twist has swung the door open. The plinth lives
    /// on the door tile, so it's found by looking for a plinth sharing a tile with a portal.
    /// (Mazen Docs/Builder Glyphs — 4D Shadows.md)
    private func updateDoorPlinths() {
        let unlocked = cubeModel.bondedGroups.isEmpty
        for ci in cubeModel.cubies.indices {
            for fi in cubeModel.cubies[ci].facelets.indices {
                let props = cubeModel.cubies[ci].facelets[fi].props
                guard props.contains(where: { $0.kind == .portal }),
                      let pi = props.firstIndex(where: { $0.kind == .plinth }) else { continue }
                let opened = !cubeModel.sealedPortalCubies.contains(ci)
                // 6 = portal, 5 = swirl, 0 = blank (TextureLoader.CausticSymbol).
                let symbol = opened ? 6 : (unlocked ? 5 : 0)
                if cubeModel.cubies[ci].facelets[fi].props[pi].state != symbol {
                    cubeModel.cubies[ci].facelets[fi].props[pi].state = symbol
                }
            }
        }
    }

    func interact() {
        guard let (ci, fi) = cubeModel.faceletAt(face: player.face, row: player.row, col: player.col) else { return }
        let props = cubeModel.cubies[ci].facelets[fi].props
        if let portal = props.first(where: { $0.kind == .portal }),
           !cubeModel.sealedPortalCubies.contains(ci) {    // M16.4: sealed = inert
            portalRequested = true
            portalDestinationID = portal.state
            return
        }
        // M16.3: dials — the lock's mechanism. Aligning the last one dissolves the bond: the
        // temple sheds its gold and the face twists again. (One lock per world for now — the
        // dial→lock association becomes real data with the glyph system, M17.)
        if let di = cubeModel.cubies[ci].facelets[fi].props.firstIndex(where: { $0.kind == .dial }) {
            if cubeModel.cubies[ci].facelets[fi].props[di].state == 0 {
                cubeModel.cubies[ci].facelets[fi].props[di].state = 1
                cubeModel.cubies[ci].facelets[fi].props[di].facing = .n
                if allDialsAligned() {
                    cubeModel.bondedGroups.removeAll()
                    updateDoorPlinths()      // the bond dissolves ⇒ the door plinth shows the swirl
                }
            }
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
