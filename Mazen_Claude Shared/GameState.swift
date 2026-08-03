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

    /// M20 (Eddie) — this world's own skybox, as a Skyboxes/ file basename (no extension); nil ⇒ the
    /// shipped default `skybox.png`. The Renderer resolves it per frame, so a world carries its sky
    /// with it. First user: the garden (Eagle Nebula).
    var skyboxName: String? = nil

    /// The world this one wants hanging **overhead**, by name; nil ⇒ the default rule (the world
    /// beneath you on the stack, or the moon edge from the root). The counterpart is the player's
    /// only fixed external reference while their own world turns under them, so which world it is
    /// is authored, not inherited from however they happened to arrive. First user: Scene 4, whose
    /// script hangs the larger Scene 2 world above the small one — you watch the sky hold still and
    /// realise it is *you* that moved. Resolved through the registry as an edge (see `WorldGraph`),
    /// so the world you see is the same instance you could walk into, twists and all.
    var skyCounterpart: String? = nil

    /// Phase 0 — whether the player may twist a slice here (Q/E). The prologue withholds the verb:
    /// Scenes 1-3 disable it and Scene 4 grants it, which is the moment the game hands the player its
    /// defining action. Default true, so every existing world keeps today's always-on behaviour.
    /// Only the PLAYER path is gated — scripted twists (a solved puzzle turning the world) ignore it.
    var twistEnabled = true

    /// Phase 0 — the name of the world the player arrived FROM, recorded on every portal swap (nil at
    /// boot). Scene 6's orb reacts to the route by which the player re-entered a solved world; this is
    /// the minimum that has to be remembered for "how you got here" to be answerable at all.
    var lastArrivalOrigin: String? = nil
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
    /// Where a frame's CPU time actually goes, in ms, rolling-averaged with `avgFrameTimeMs`. A frame
    /// time on its own cannot tell "the CPU is busy" from "the CPU is waiting for the GPU", and those
    /// need opposite fixes — Scene 2's 11³ was slow for a year of sessions without anyone knowing
    /// which. `cpuTotal` well under `avgFrameTimeMs` means the GPU is the wall.
    struct FramePerf {
        var update: Float = 0      // the model tick
        var build: Float = 0       // instance assembly + draw-call bucketing
        var encode: Float = 0      // filling the command buffer
        var wait: Float = 0        // blocked on a frame in flight retiring — i.e. on the GPU
        var drawCalls = 0
        var instances = 0
        var cpuTotal: Float { update + build + encode }
    }
    var perf = FramePerf()

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
        /// How far a refused twist gives before springing back, in radians. Set when the refusal is
        /// raised, from how many bonds still straddle the slice: Scene 4 releases its anchors one at a
        /// time, and "partial progress may weaken a lock without yet making a turn legal" only reads
        /// if the world visibly gives MORE as each one goes. A fixed amplitude made three anchors feel
        /// identical to one.
        var strainAmplitude: Float = 0.06

        /// M20 (Eddie): the switch-trip "turn the world" spectacle rotates the BACK slab (a distant
        /// wall for impact), which needn't contain the sealed door — so this flags the finalize to
        /// open the (unbonded) door regardless. Manual Q/E twists leave it false and stay coupled to
        /// the rotated slab.
        var opensSealedDoors = false

        // R2.3: the ONE definition of the in-flight twist transform. SceneBuilder, the asset
        // instancer, and the camera all animate off these — previously three hand-copied
        // smoothstep+rotation constructions that had to be kept in sync by comment.
        var axisVector: SIMD3<Float> {
            axis == 0 ? SIMD3(1, 0, 0) : axis == 1 ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
        }
        /// The refusal wobble: strain out and spring back, ending exactly at rest. Shared so the
        /// VESSEL (Scene 4D) demonstrates the same motion the ground makes — if the two were written
        /// separately they would drift, and the whole point of the object is that it is telling the
        /// truth about the lock.
        static func strainCurve(progress: Float, amplitude: Float, direction: Float) -> Float {
            direction * amplitude * sinf(progress * .pi * 3) * (1 - progress)
        }

        /// Smoothstep-eased current angle of the in-flight twist — or, for a refusal (M16.2),
        /// a damped wobble in the attempted direction that returns exactly to rest.
        var currentAngle: Float {
            if isRefusal {
                return Self.strainCurve(progress: progress, amplitude: strainAmplitude,
                                        direction: angle < 0 ? -1 : 1)
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

    /// Sounds the world wants to make this frame. The model only ever DESCRIBES them (see
    /// `AudioCue`); the renderer drains this and plays them, so nothing here depends on an audio
    /// framework and the headless harness still links.
    var pendingAudioCues: [AudioCue] = []

    /// World-space centre of a slab, for positioning the sound of it moving.
    func sliceCentre(axis: Int, index: Int) -> SIMD3<Float>? {
        let idx = cubeModel.cubieIndicesInSlice(axis: axis, index: index)
        guard !idx.isEmpty else { return nil }
        var sum = SIMD3<Float>(0, 0, 0)
        let half = Float(cubeModel.size) / 2.0
        for ci in idx {
            let p = cubeModel.cubies[ci].position
            sum += SIMD3(Float(p.x) + 0.5 - half, Float(p.y) + 0.5 - half, Float(p.z) + 0.5 - half)
        }
        return sum / Float(idx.count) * cubeModel.worldScale.cellSpacing
    }

    /// M16.6 Phase 2b — true while the door plinth's alignment cylinder is running its ALIGN
    /// animation (engage → the two half-squares pivot together → the world twists). See
    /// `tickAlignmentCylinder`.
    var cylinderEngaged = false
    /// When the alignment cylinder was last RAISED (F #1). The turn (F #2) is refused until this
    /// cooldown has passed, so a stray double-tap of the raise doesn't fire the turn (Eddie).
    var lastCylinderRaiseTime: Float = -100
    let cylinderEngageCooldown: Float = 0.5

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
        skyCounterpart = stamp.skyCounterpart
        player = PlayerState(size: size, standGrid: ws.standGrid)
        // Stand where the world SAYS you stand. `spawnLocation` was only ever applied on arrival
        // through a portal, so a world entered any other way — the boot world above all — put the
        // player at PlayerState's default, the centre of the front face.
        //
        // That was harmless while every world revealed itself at build. Scene 1 keeps its fog, so
        // the default dropped the player into the middle of the maze with only the clearing
        // revealed: no walls (they need a seen tile), fog where the ground should be, and a clearing
        // nowhere near them. One wrong position, three symptoms that look like three bugs (Eddie:
        // "what the heck is going on?").
        if let spawn = cubeModel.spawnLocation {
            player.face = spawn.face
            player.row = spawn.row
            player.col = spawn.col
            player.facing = spawn.facing
        }
        if verboseDebugLog { printMazeDebug(face: player.face) }
        // Seed the door plinth's initial glyph from the freshly-stamped lock state (three-of-four
        // while three dials are pre-aligned) — otherwise it stays blank until the first dial is
        // touched. No-op in worlds without a temple door.
        updateDoorPlinths()
        revealLineOfSight()      // the first frame should show what standing there shows
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
        // A turn the world owes from a control already pressed — fired the moment the player is
        // settled enough to watch it, rather than being lost because they were mid-stride.
        if let owed = pendingScriptedTwist, !sliceRotation.isActive, !player.isMoving, !player.isTurning {
            pendingScriptedTwist = nil
            startScriptedSliceRotation(axis: owed.axis, index: owed.index,
                                       clockwise: owed.clockwise, speed: owed.speed)
        }
        camera.updateOrbit(deltaTime: deltaTime)

        if player.updateMovement(deltaTime: deltaTime) {
            onPlayerArrived()
        }
        updateWalkThroughPortal()   // fires when you settle on a portal's sub-cell (before walk-chaining)
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

        tickAlignmentCylinder(deltaTime)
        tickObeliskAwakening(deltaTime)
        tickObeliskRebuff(deltaTime)
        tickChamberWave(deltaTime)
        tickChannelCircuit(deltaTime)
        tickChannelPulse(deltaTime)
        tickLayeredVessel(deltaTime)
        tickVesselDemo(deltaTime)
        tickAnchorFlash(deltaTime)
        tickDust(deltaTime)
        tickArrivalDoorway(deltaTime)
        updateAudioEmitters()
        updateAmbienceTriggers()
        tickVesselDrift(deltaTime)

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
                cubeModel.markTopologyChanged()   // PERF: a newly discovered tile gains dressed walls etc.
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
        // An INTERIOR never spins. The spin exists so the sun sweeps across the faces of a planet —
        // an interior has no sun and no sky, so it buys nothing there, and it is not free: it turns
        // the world-space normals under everything, so any shading that reads them drifts while the
        // player stands still. That is exactly how Scene 3's metal walls came to flicker.
        guard spinEnabled, !worldScale.interior else { return matrix_identity_float4x4 }
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
        /// Look direction — carried so the audio listener can be oriented the same way the camera is
        /// without having to invert the view-projection.
        let forward: SIMD3<Float>
    }

    func framePose(aspect: Float) -> FramePose {
        let pose: FirstPersonPose? = camera.mode == .firstPerson
            ? camera.firstPersonPose(player: player, cubeModel: cubeModel,
                                     sliceRotation: sliceRotation, worldSpin: worldSpinMatrix())
            : nil
        return FramePose(
            viewProjection: camera.viewProjectionMatrix(aspect: aspect, cubeModel: cubeModel, pose: pose),
            position: camera.cameraPosition(cubeModel: cubeModel, pose: pose),
            up: camera.cameraUp(pose: pose),
            forward: camera.cameraForward(cubeModel: cubeModel, pose: pose)
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


    // MARK: - Discovery

    private func onPlayerArrived(viaMove: Bool = true) {
        // Walk-through portal triggering moved to `updateWalkThroughPortal` (checked continuously, so it
        // fires when you reach the portal's sub-cell, not at the tile edge where this tile-crossing hook
        // fires). This just handles discovery on tile entry.
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
        revealLineOfSight()
    }

    /// You can see DOWN a corridor, so reveal along it. Marking only the four touching tiles meant a
    /// maze arrived one tile at a time however far you could actually see, which reads as the world
    /// building itself around you as you walk into it. Stepping each open direction until a wall
    /// stops it is cheaper than a real visibility test and is exactly what the script describes the
    /// player seeing on entering: "one forward path, one immediate branch, several walls hiding the
    /// maze's full extent".
    ///
    /// Same face only — over a cube edge, "straight ahead" stops being a straight line.
    func revealLineOfSight(range: Int = 6) {
        let n = cubeModel.size
        for (mask, dr, dc) in [(DirectionMask.north, -1, 0), (.south, 1, 0), (.west, 0, -1), (.east, 0, 1)] {
            var r = player.row, c = player.col
            for _ in 0..<range {
                guard let (ci, fi) = cubeModel.faceletAt(face: player.face, row: r, col: c),
                      cubeModel.cubies[ci].facelets[fi].mazeTile.openings.contains(mask) else { break }
                r += dr; c += dc
                guard r >= 0, r < n, c >= 0, c < n,
                      let (nci, nfi) = cubeModel.faceletAt(face: player.face, row: r, col: c) else { break }
                if cubeModel.cubies[nci].facelets[nfi].tileState == .unknown {
                    cubeModel.cubies[nci].facelets[nfi].tileState = .adjacent
                    cubeModel.cubies[nci].facelets[nfi].discoveryAmount = 0.2
                }
            }
        }
    }

    // Walk-through portals fire when the player reaches the portal's OWN sub-cell (its 3×3 author cell
    // — the centre where the arch/curtain stands), not merely anywhere on the ~19 m tile (Eddie:
    // "sensitive"). Checked every frame because sub-cell moves within a tile don't fire onPlayerArrived
    // (that's tile-crossing only). Edge-triggered (fires once on entry, keyed by the portal cubie) and
    // PRIMED — the first evaluation after a spawn or twist just records where you are, so a portal you
    // start on (or that a twist rotates under you) doesn't teleport you; you must walk onto it.
    private var portalZonePrimed = false
    private var portalZoneCubie: Int? = nil

    func reprimePortalZone() { portalZonePrimed = false }   // call after a twist finalizes

    private func updateWalkThroughPortal() {
        guard !player.isMoving, !sliceRotation.isActive else { return }   // only when settled
        var zone: Int? = nil, dest = 0, transition: WorldTransition = .auto
        if let (pci, pfi) = cubeModel.faceletAt(face: player.face, row: player.row, col: player.col),
           let portal = cubeModel.cubies[pci].facelets[pfi].props.first(where: { $0.kind == .portal }),
           !cubeModel.sealedPortalCubies.contains(pci),                  // M16.4: a sealed door is just a door
           player.subRow * 3 / player.standGrid == portal.subRow,        // stand-grid → author 3×3
           player.subCol * 3 / player.standGrid == portal.subCol {
            zone = pci; dest = portal.state; transition = portal.transition
        }
        if portalZonePrimed, let z = zone, z != portalZoneCubie {        // just stepped onto a portal
            portalRequested = true
            portalDestinationID = dest
            portalTransition = transition
        }
        portalZonePrimed = true
        portalZoneCubie = zone
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
        // Phase 0: the PLAYER's twist is a per-world privilege (the prologue withholds it until
        // Scene 4). Scripted twists — a solved puzzle turning the world — call
        // `startBackSliceRotation` and are deliberately not gated.
        guard twistEnabled else { return }
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
            pendingAudioCues.append(.twistStrain)
            // The fewer bonds still holding, the further the world gives before it springs back.
            let blocking = cubeModel.bondsBlocking(axis: axis, index: index)
            let strain: Float = blocking > 0 ? 0.03 + 0.08 / Float(blocking) : 0.06
            sliceRotation = SliceRotation(
                isActive: true, axis: axis, index: index, angle: angle,
                progress: 0, speed: 4.0,
                affectedCubies: Set(cubieIndices), playerCubieIndex: playerCI,
                isRefusal: true, strainAmplitude: strain
            )
            return
        }

        pendingAudioCues.append(.twistTurning(at: sliceCentre(axis: axis, index: index), slow: false))
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

    /// M20 (Eddie) — the switch-trip "the world turns" spectacle. Rather than spinning the slab the
    /// player stands on (the ground underfoot, barely visible in first person — the old top-slice
    /// turn), rotate the BACK slab: the slice of the face you'd step onto by walking forward over the
    /// far edge — a vertical wall in the distance that visibly swings. The sealed door isn't in that
    /// slab, so `opensSealedDoors` tells the finalize to open it anyway; the puzzle payoff is
    /// decoupled from which slab provides the spectacle (the door's own opening flourish is a later
    /// visual pass). Manual Q/E keep using `startSliceRotation` (the player's own slab).
    func startBackSliceRotation(clockwise: Bool) {
        // The face across the far edge in the player's forward direction is the "back" wall. Diagonal
        // headings fall back to north (the garden solve faces the door dead-on, a cardinal heading).
        let forward = player.facing.cardinal ?? .north
        let backFace = cubeModel.edgeCrossing(face: player.face, direction: forward,
                                              row: player.row, col: player.col).face
        let (axis, index) = cubeModel.sliceAxisAndIndex(for: backFace)
        startScriptedSliceRotation(axis: axis, index: index, clockwise: clockwise)
    }

    /// Turn one NAMED slab as a puzzle's reward — the world moving itself, not the player twisting.
    /// Deliberately not gated by `twistEnabled`: that withholds the player's own verb, and a scene
    /// that turns the world for you (Scene 2) is exactly how the verb is introduced before it is
    /// granted. The player rides the slab only if they are actually standing in it.
    /// `speed` is progress-per-second, so 0.7 ≈ a 1.4 s turn. Deliberately far slower than a player's
    /// own twist (2.5, ≈0.4 s): this one happens at the far edge of the world, and at that distance a
    /// snap was over before you could find it — or missed completely if you were facing away. The
    /// slower sweep also reads as the script asks, "a machine executing an ancient, exact motion."
    /// A scripted turn the world owes the player, held until they are standing still.
    ///
    /// This used to be dropped on the floor: the plinth's alignment finishes on whatever frame it
    /// finishes on, and if the player was mid-step or mid-turn at that moment the guard below
    /// returned and the turn simply never happened — leaving a raised, aligned rotator and a world
    /// that had not moved, so the next F was needed to fire it again. That reads as a third press
    /// (Eddie: "one F raises, second F rotates the rotator, third F makes the slice move").
    /// A control the player pressed should not lose its effect because they were still walking.
    private(set) var pendingScriptedTwist: (axis: Int, index: Int, clockwise: Bool, speed: Float)? = nil

    func startScriptedSliceRotation(axis: Int, index: Int, clockwise: Bool, speed: Float = 0.7) {
        guard !sliceRotation.isActive && !player.isMoving && !player.isTurning else {
            pendingScriptedTwist = (axis, index, clockwise, speed)
            return
        }
        pendingScriptedTwist = nil
        let angle: Float = clockwise ? -.pi / 2 : .pi / 2
        let cubieIndices = cubeModel.cubieIndicesInSlice(axis: axis, index: index)

        // If a bond would refuse the slab, still deliver the payoff so the puzzle completes.
        guard cubeModel.canRotateSlice(axis: axis, index: index) else {
            openSealedDoors()
            return
        }

        // Usually the player watches a distant slab turn from outside it — but the slab carries one
        // edge column of the face they walk on, so they CAN be standing in it. Carry them if so
        // (position, facing and standing sub-cell all rotate); otherwise leave them still.
        var playerCI = -1
        if let (ci, _) = cubeModel.faceletAt(face: player.face, row: player.row, col: player.col),
           cubieIndices.contains(ci) {
            playerCI = ci
        }

        // Give the motion a voice for its whole length — otherwise a turn is silence then a thud.
        pendingAudioCues.append(.twistTurning(at: sliceCentre(axis: axis, index: index), slow: speed < 1.5))

        sliceRotation = SliceRotation(
            isActive: true, axis: axis, index: index, angle: angle,
            progress: 0, speed: speed,
            affectedCubies: Set(cubieIndices), playerCubieIndex: playerCI
        )
        sliceRotation.opensSealedDoors = true
    }

    /// Open every unbonded sealed door (the temple door) and refresh its plinth. The switch-trip turn
    /// uses this because its spectacle slab need not contain the door (see `startBackSliceRotation`).
    /// Scene 2H — after the turn finalizes, the obelisks flanking the revealed chamber WAKE: a line
    /// of light climbs each shaft. They are stabilizers, not monuments; their lighting up is what
    /// says the rotated slab has locked into the correct orientation. Driven by `anim` on the props
    /// (material 26 climbs the light with it), ticked in `tickObeliskAwakening`.
    ///
    /// Deliberately only the obelisks sharing a face with a now-open portal: a world may carry other
    /// obelisks as scenery (the temple interior does), and those must stay dormant.
    private func beginObeliskAwakening() {
        var openFaces = Set<Int>()
        for cu in cubeModel.cubies.indices where !cubeModel.sealedPortalCubies.contains(cu) {
            for f in cubeModel.cubies[cu].facelets
            where f.props.contains(where: { $0.kind == .portal && $0.state == 1 }) {
                openFaces.insert(cu)
            }
        }
        guard !openFaces.isEmpty else { return }
        for cu in cubeModel.cubies.indices {
            for fi in cubeModel.cubies[cu].facelets.indices {
                for pi in cubeModel.cubies[cu].facelets[fi].props.indices
                where cubeModel.cubies[cu].facelets[fi].props[pi].kind == .obelisk {
                    // Wake an obelisk if it stands within a tile of an opened chamber's cubie.
                    if openFaces.contains(cu) || openFaces.contains(where: { abs($0 - cu) <= 1 }) {
                        if cubeModel.cubies[cu].facelets[fi].props[pi].anim <= 0 {
                            cubeModel.cubies[cu].facelets[fi].props[pi].anim = 0.0001   // > 0 ⇒ awakening
                            obeliskAwakening = true
                        }
                    }
                }
            }
        }
        if obeliskAwakening { cubeModel.markTopologyChanged() }
    }

    /// True while any obelisk's light is still climbing; cleared when they all reach full.
    private var obeliskAwakening = false

    /// Climb each waking obelisk's light 0→1 (~1.4 s), a beat slower than the turn itself so it
    /// reads as a response to the world settling rather than part of the same motion.
    private func tickObeliskAwakening(_ dt: Float) {
        guard obeliskAwakening else { return }
        let rate: Float = 1.0 / 1.4
        var stillRunning = false
        for cu in cubeModel.cubies.indices {
            for fi in cubeModel.cubies[cu].facelets.indices {
                for pi in cubeModel.cubies[cu].facelets[fi].props.indices
                where cubeModel.cubies[cu].facelets[fi].props[pi].kind == .obelisk {
                    let a = cubeModel.cubies[cu].facelets[fi].props[pi].anim
                    guard a > 0, a < 1 else { continue }
                    cubeModel.cubies[cu].facelets[fi].props[pi].anim = min(1, a + dt * rate)
                    if cubeModel.cubies[cu].facelets[fi].props[pi].anim < 1 { stillRunning = true }
                }
            }
        }
        obeliskAwakening = stillRunning
    }

    /// Scene 4D — the vessel reads the lock. Its `anim` counts rings brought home (0…3), and it
    /// EASES toward the true count rather than snapping, because the script wants the vessel to
    /// answer the player's action a beat later: you release an anchor across the world, walk back,
    /// and find the vessel has turned. A snap would read as a UI element updating; a turn reads as
    /// the object having done something.
    ///
    /// The target is derived from live bond state, never counted separately — the vessel cannot
    /// disagree with the lock it is reporting on, however a bond comes or goes.
    private func tickLayeredVessel(_ dt: Float) {
        guard sceneFourAnchorTotal > 0 else { return }
        let remaining = cubeModel.bondedGroups.count
        let target = Float(max(0, sceneFourAnchorTotal - remaining))
        let rate: Float = 1.0 / 2.2                       // ~2.2 s for a ring to come home
        for cu in cubeModel.cubies.indices {
            for fi in cubeModel.cubies[cu].facelets.indices {
                for pi in cubeModel.cubies[cu].facelets[fi].props.indices
                where cubeModel.cubies[cu].facelets[fi].props[pi].kind == .layeredVessel {
                    let a = cubeModel.cubies[cu].facelets[fi].props[pi].anim
                    guard abs(a - target) > 0.001 else { continue }
                    cubeModel.cubies[cu].facelets[fi].props[pi].anim =
                        a < target ? min(target, a + dt * rate) : max(target, a - dt * rate)
                }
            }
        }
    }

    /// How many anchors the scene started with — the denominator the vessel reports against. Zero in
    /// every world that has no anchors, which is what makes `tickLayeredVessel` free elsewhere.
    private lazy var sceneFourAnchorTotal: Int = {
        var n = 0
        for cu in cubeModel.cubies {
            for f in cu.facelets { n += f.props.filter { $0.kind == .anchor }.count }
        }
        return n
    }()

    /// Scene 4D — the vessel's demonstration, running 0→1 once when the player activates it.
    /// The script's six beats: the swirl lights, one ring attempts to turn, the whole vessel strains,
    /// the ground answers, the ring springs back, and three distant points flash. It ends by GRANTING
    /// the twist ("after the vessel is inspected, player-controlled twist input becomes available") —
    /// the vessel does not perform the turn, it introduces the possibility.
    private(set) var vesselDemo: Float = 0
    private(set) var vesselInspected = false
    private var vesselAnswered = false           // the anchors answer once, partway through
    private let vesselDemoDuration: Float = 1.9

    /// True while the vessel is mid-demonstration — the swirl runs bright.
    var vesselGlow: Float {
        guard vesselDemo > 0 else { return vesselInspected ? 0.25 : 0 }
        return 0.25 + 0.75 * sinf(min(1, vesselDemo) * .pi)
    }

    private func tickVesselDemo(_ dt: Float) {
        guard vesselDemo > 0 else { return }
        vesselDemo = min(1, vesselDemo + dt / vesselDemoDuration)
        // Beat 6 — "three distant points around the world answer with brief flashes": the anchors
        // name themselves, so the player learns WHERE the lock is without being told there is one.
        // Fired after the ring has sprung back, so it reads as an answer and not an accompaniment.
        if !vesselAnswered && vesselDemo > 0.62 {
            vesselAnswered = true
            for cu in cubeModel.cubies.indices {
                for fi in cubeModel.cubies[cu].facelets.indices {
                    for pi in cubeModel.cubies[cu].facelets[fi].props.indices
                    where cubeModel.cubies[cu].facelets[fi].props[pi].kind == .anchor
                        && cubeModel.cubies[cu].facelets[fi].props[pi].anim > 0.5 {
                        cubeModel.cubies[cu].facelets[fi].props[pi].alignAnim = 1
                    }
                }
            }
            pendingAudioCues.append(.twistLocked(at: nil))
        }
        // The vessel carries its own progress, like every other animating prop.
        setVesselDemoProgress(vesselDemo < 1 ? vesselDemo : 0)
        if vesselDemo >= 1 {
            vesselDemo = 0
            vesselInspected = true
            // The handover. Scenes 1-3 withhold Q/E; this is the moment the game gives it up.
            twistEnabled = true
        }
    }

    private func setVesselDemoProgress(_ v: Float) {
        for cu in cubeModel.cubies.indices {
            for fi in cubeModel.cubies[cu].facelets.indices {
                for pi in cubeModel.cubies[cu].facelets[fi].props.indices
                where cubeModel.cubies[cu].facelets[fi].props[pi].kind == .layeredVessel {
                    cubeModel.cubies[cu].facelets[fi].props[pi].alignAnim = v
                }
            }
        }
    }

    /// The anchors' answering flash decays on its own.
    private func tickAnchorFlash(_ dt: Float) {
        for cu in cubeModel.cubies.indices {
            for fi in cubeModel.cubies[cu].facelets.indices {
                for pi in cubeModel.cubies[cu].facelets[fi].props.indices
                where cubeModel.cubies[cu].facelets[fi].props[pi].kind == .anchor
                    && cubeModel.cubies[cu].facelets[fi].props[pi].alignAnim > 0 {
                    cubeModel.cubies[cu].facelets[fi].props[pi].alignAnim =
                        max(0, cubeModel.cubies[cu].facelets[fi].props[pi].alignAnim - dt / 0.9)
                }
            }
        }
    }

    /// Begin the vessel's demonstration (F at the vessel). No-op while one is running.
    func beginVesselDemo(at where_: SIMD3<Float>?) {
        guard vesselDemo <= 0 else { return }
        vesselDemo = 0.001
        vesselAnswered = false
        // Beat 4 — "a matching vibration travels through the ground". The same cue a refused twist
        // makes, because it is the same thing happening: something is being held.
        pendingAudioCues.append(.twistStrain)
        pendingAudioCues.append(.controlRaised(at: where_))
    }

    /// Audio Phase C — everything currently making a sustained sound, republished every frame.
    /// Rebuilt from live props rather than remembered, which is what makes it twist-safe: the
    /// position comes from wherever the facelet is NOW, so a slab turning carries its sounds round
    /// with it and nothing has to be told that a twist happened.
    private(set) var activeEmitters: [AudioEmitter] = []

    /// Scene 1B — "after the player first moves, a low tonal layer enters almost below conscious
    /// notice". Latched, never cleared: it is the world noticing you, and a thing that noticed you
    /// does not stop.
    private(set) var hasMoved = false
    /// Scene 1G — "the ambient birds fall silent" as the arch is approached. Distance to the nearest
    /// ACTIVE portal, in tiles, or nil when there is none to be near.
    private(set) var tilesToNearestPortal: Int? = nil

    /// Scene 1C — "one layered section may complete a tiny quarter-turn while outside the center of
    /// the camera's view. When the player looks directly at it, it is still."
    ///
    /// The effect is entirely about ATTENTION, so it is driven by where the camera points rather than
    /// by a timer: a vessel drifts only while it is off to the side, and freezes the moment it is
    /// looked at. You cannot catch it. "The motion should be subtle enough that the player may doubt
    /// having seen it" — which is only achievable if doubting is literally correct.
    ///
    /// Stored per facelet id and advanced here rather than in the renderer, so the drift survives a
    /// world being left and returned to: the vessels "remain where they were. Or appear to."
    private(set) var vesselDrift: [Int: Float] = [:]
    /// Scene 1G — the largest vessel, the one beside the arch: "its uppermost layer turns slowly
    /// toward the player. Not like a head. Not quite." Eased, never snapped, and slow enough that
    /// it is only ever noticed in retrospect. Keyed by facelet id like the drift.
    private(set) var vesselWatch: [Int: Float] = [:]
    /// Set by the renderer each frame — the camera's forward in world space, and its position.
    var viewForward = SIMD3<Float>(0, 0, 1)
    var viewOrigin = SIMD3<Float>(0, 0, 0)

    private func tickVesselDrift(_ dt: Float) {
        guard !cubeModel.styledPortals.isEmpty || !vesselDrift.isEmpty || true else { return }
        let spin = worldSpinMatrix()
        for face in CubeFace.allCases {
            for r in 0..<cubeModel.size {
                for c in 0..<cubeModel.size {
                    guard let (ci, fi) = cubeModel.faceletAt(face: face, row: r, col: c),
                          cubeModel.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .layeredVessel })
                    else { continue }
                    let m = spin * cubeModel.restMatrix(face: face, row: r, col: c)
                    let p = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                    let toIt = p - viewOrigin
                    let len = simd_length(toIt)
                    guard len > 1e-4 else { continue }
                    // How far off the centre of view it is. Dead ahead ⇒ 1, hard to the side ⇒ 0.
                    let centred = simd_dot(simd_normalize(toIt), viewForward)
                    let id = cubeModel.cubies[ci].facelets[fi].id.rawValue
                    // Only drift when it is genuinely peripheral, and stop dead when looked at. The
                    // threshold is generous on purpose: catching it should be impossible, not hard.
                    // Scene 1E — "each vessel may react differently to the player's route… one
                    // rotates a middle ring, one emits a barely audible tone… one remains completely
                    // inert. These differences should not yet form a solvable puzzle. They are the
                    // first syllables of a language the player does not know they are hearing."
                    // `state` carries which syllable: 0 never moves at all, and the others drift.
                    let inert = cubeModel.cubies[ci].facelets[fi].props.contains {
                        $0.kind == .layeredVessel && $0.state == 0
                    }
                    if centred < 0.72 && !inert {
                        vesselDrift[id, default: 0] += dt * 0.06
                    }
                    // The WATCHER (state 5 — the largest, placed beside the arch) tracks the player
                    // instead of drifting. Eased at ~9°/s: too slow to catch in the act, fast enough
                    // that it is facing you by the time you have walked up to it.
                    guard cubeModel.cubies[ci].facelets[fi].props.contains(where: {
                        $0.kind == .layeredVessel && $0.state == 5
                    }) else { continue }
                    let lx = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
                    let ly = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
                    let target = atan2f(simd_dot(-toIt, ly), simd_dot(-toIt, lx))
                    let cur = vesselWatch[id] ?? target
                    // Shortest way round, so it never unwinds the long way when you circle it.
                    var delta = target - cur
                    while delta > .pi { delta -= 2 * .pi }
                    while delta < -.pi { delta += 2 * .pi }
                    vesselWatch[id] = cur + max(-dt * 0.16, min(dt * 0.16, delta))
                }
            }
        }
    }

    private func updateAmbienceTriggers() {
        if player.isMoving { hasMoved = true }
        // Straight-line distance in the world, converted to tiles — NOT same-face Manhattan, which
        // was the first attempt and never fired in Scene 2: its portal sits on another face until
        // the slab turns, so "near the arch" was permanently false and the birds never hushed
        // however close Eddie stood to the light.
        var best: Float? = nil
        let here = cubeModel.restMatrix(face: player.face, row: player.row, col: player.col)
        let hp = SIMD3(here.columns.3.x, here.columns.3.y, here.columns.3.z)
        for sp in cubeModel.styledPortals where !cubeModel.sealedPortalCubies.contains(sp.ci) {
            guard let loc = cubeModel.locate(cubie: sp.ci, facelet: sp.fi) else { continue }
            let m = cubeModel.restMatrix(face: loc.face, row: loc.row, col: loc.col)
            let d = simd_distance(hp, SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z))
                / cubeModel.worldScale.cellSpacing
            if best == nil || d < best! { best = d }
        }
        tilesToNearestPortal = best.map { Int($0.rounded()) }
    }

    private func updateAudioEmitters() {
        activeEmitters.removeAll(keepingCapacity: true)
        let listenerFace = player.face, lr = player.row, lc = player.col
        for face in CubeFace.allCases {
            for r in 0..<cubeModel.size {
                for c in 0..<cubeModel.size {
                    guard let (ci, fi) = cubeModel.faceletAt(face: face, row: r, col: c) else { continue }
                    let facelet = cubeModel.cubies[ci].facelets[fi]
                    var kind: AudioEmitter.Kind? = nil
                    // An AWAKENED obelisk hums; a dormant one is silent. Scene 2 lights them one at
                    // a time, so the world gains a voice per solved step.
                    if facelet.props.contains(where: { $0.kind == .obelisk && $0.anim > 0.01 }) { kind = .obelisk }
                    // Scene 1E — one of them "emits a barely audible tone". Deliberately quiet and
                    // occluded like anything else, so it is something you notice you have been
                    // hearing rather than something you hear.
                    else if facelet.props.contains(where: { $0.kind == .layeredVessel && $0.state == 1 }) { kind = .vessel }
                    // An OPEN portal holds the "low, stable tone" the scripts describe. A sealed one
                    // is inert and says nothing — which is the difference the player is listening for.
                    else if facelet.props.contains(where: { $0.kind == .portal })
                        && !cubeModel.sealedPortalCubies.contains(ci) { kind = .portal }
                    guard let k = kind else { continue }
                    // Phase D — occlusion from the maze. Same face: walk the walls between. A source
                    // round the curve of the world is muffled by the world itself.
                    let walls = face == listenerFace
                        ? cubeModel.wallsBetween(face: face, fromRow: lr, fromCol: lc, toRow: r, toCol: c)
                        : 3
                    let m = cubeModel.restMatrix(face: face, row: r, col: c)
                    // Scene 3's obelisks each sing a distinct partial of one fundamental — the
                    // voice is chosen by the SYMBOL, so the note and the mark are the same fact.
                    var voice = -1
                    if k == .obelisk, cubeModel.symbolPairedPlinths,
                       let ob = facelet.props.first(where: { $0.kind == .obelisk }) {
                        voice = Self.sceneThreeVoices.firstIndex(of: ob.state) ?? -1
                    }
                    activeEmitters.append(AudioEmitter(
                        id: facelet.id.rawValue, kind: k,
                        position: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z),
                        occlusion: min(1, Float(walls) * 0.34), voice: voice))
                }
            }
        }
        // Scene 5 — the pulse, which is a single moving source rather than a thing standing on a
        // tile, so it is appended once here rather than found in the sweep above.
        if let pe = pulseEmitter { activeEmitters.append(pe) }
    }

    /// Scene 2 — "dust falls from nearby wall joints" / "dust shakes loose from moving walls".
    /// Seeded at CLOSED edges near the player, because that is where a joint is and where the player
    /// is looking; a world-wide shower would cost more and read as weather rather than as this world
    /// having just moved. Deterministic per tile, so a replayed twist shakes the same dust.
    private func shakeDustFromJoints() {
        let n = cubeModel.size, face = player.face
        for dr in -3...3 {
            for dc in -3...3 {
                let r = player.row + dr, c = player.col + dc
                guard r >= 0, r < n, c >= 0, c < n,
                      let (ci, fi) = cubeModel.faceletAt(face: face, row: r, col: c) else { continue }
                let closed = DirectionMask.all.subtracting(cubeModel.cubies[ci].facelets[fi].mazeTile.openings)
                guard !closed.isEmpty else { continue }
                var h = UInt32(truncatingIfNeeded: r &* 73856093 ^ c &* 19349663)
                h ^= h >> 15; h = h &* 2246822519; h ^= h >> 13
                let motes = 3 + Int(h % 4)      // was 1–3; too sparse to notice while the world turns
                for k in 0..<motes {
                    let p = cubeModel.scatterPlacement(h &+ UInt32(k &* 977))
                    var mote = Prop(kind: .dustMote, subRow: p.subRow, subCol: p.subCol,
                                    viewAngle: p.yaw, offsetX: p.ox, offsetY: p.oy)
                    mote.anim = 1                        // full life; ticks down and it falls
                    cubeModel.cubies[ci].facelets[fi].props.append(mote)
                }
            }
        }
        cubeModel.markTopologyChanged()
    }

    private func tickDust(_ dt: Float) {
        var removedAny = false
        for cu in cubeModel.cubies.indices {
            for fi in cubeModel.cubies[cu].facelets.indices {
                guard cubeModel.cubies[cu].facelets[fi].props.contains(where: { $0.kind == .dustMote }) else { continue }
                for pi in cubeModel.cubies[cu].facelets[fi].props.indices
                where cubeModel.cubies[cu].facelets[fi].props[pi].kind == .dustMote {
                    cubeModel.cubies[cu].facelets[fi].props[pi].anim -= dt / 2.6   // longer, so it can be looked AT
                }
                let before = cubeModel.cubies[cu].facelets[fi].props.count
                cubeModel.cubies[cu].facelets[fi].props.removeAll { $0.kind == .dustMote && $0.anim <= 0 }
                if cubeModel.cubies[cu].facelets[fi].props.count != before { removedAny = true }
            }
        }
        if removedAny { cubeModel.markTopologyChanged() }
    }

    /// Scene 2A — the route behind you closes. "If the player turns immediately, they witness the
    /// disappearance. If they continue forward, they hear a brief inward rush and later discover that
    /// the route behind them is gone."
    ///
    /// Deliberately a VEIL and a ring, never a working `.portal` prop: there must be no moment where
    /// stepping back is possible. The prologue's one-way rule is enforced by the door not existing,
    /// not by the door refusing.
    func closeArrivalDoorway() {
        guard let (ci, fi) = cubeModel.faceletAt(face: player.face, row: player.row, col: player.col) else { return }
        // `anim = 1` MARKS these two as the arrival doorway's own. Without a marker the cleanup below
        // matched by kind and swept the whole world — including the scene's real exit portal, whose
        // veil and ring are the same two prop kinds. Caught in review before it reached a playthrough.
        var veil = Prop(kind: .portalField, subRow: 1, subCol: 1, facing: player.facing.opposite, state: 2)
        veil.alignAnim = 1                       // opacity; ticked to 0, then removed
        veil.anim = 1
        var ring = Prop(kind: .portalRing, subRow: 1, subCol: 1)
        ring.anim = 1
        cubeModel.cubies[ci].facelets[fi].props.append(veil)
        cubeModel.cubies[ci].facelets[fi].props.append(ring)
        arrivalDoorwayTile = (ci, fi)
        arrivalDoorwayClosing = 1
        cubeModel.markTopologyChanged()
        pendingAudioCues.append(.portalClosed(at: nil))
    }

    /// 1 → 0 while the arrival veil shuts; 0 = nothing closing.
    private var arrivalDoorwayClosing: Float = 0
    /// Where it was placed. Props ride their facelet through a twist, so this stays valid even if the
    /// slab the player arrived on turns while the doorway is still closing.
    private var arrivalDoorwayTile: (ci: Int, fi: Int)?

    private func tickArrivalDoorway(_ dt: Float) {
        guard arrivalDoorwayClosing > 0, let t = arrivalDoorwayTile else { return }
        arrivalDoorwayClosing = max(0, arrivalDoorwayClosing - dt / 2.2)
        for pi in cubeModel.cubies[t.ci].facelets[t.fi].props.indices
        where cubeModel.cubies[t.ci].facelets[t.fi].props[pi].kind == .portalField
            && cubeModel.cubies[t.ci].facelets[t.fi].props[pi].anim > 0.5 {
            cubeModel.cubies[t.ci].facelets[t.fi].props[pi].alignAnim = arrivalDoorwayClosing
        }
        if arrivalDoorwayClosing <= 0 {
            // Gone, not merely invisible — nothing left to walk into. Only OUR two props, only here.
            cubeModel.cubies[t.ci].facelets[t.fi].props.removeAll {
                ($0.kind == .portalField || $0.kind == .portalRing) && $0.anim > 0.5
            }
            arrivalDoorwayTile = nil
            cubeModel.markTopologyChanged()
        }
    }

    /// Scene 3 — where the chamber's light comes from: the orb, and each lit beam as a SEGMENT.
    ///
    /// Defined once and read by both the SceneBuilder (which draws them) and the Renderer (which
    /// lights the room with them). Computing the beam endpoints twice is exactly how the drawn beam
    /// and the light it casts would end up in different places — a class of bug this codebase has
    /// already produced more than once.
    ///
    /// Positions are UNSPUN: each consumer applies the world spin itself, because the renderer folds
    /// that in at a different point than the builder does.
    struct ChamberEmitter {
        let a: SIMD3<Float>       // orb centre, or the beam's obelisk end
        let b: SIMD3<Float>       // the same point for an orb; the far end for a beam
        let radius: Float         // orb radius, or beam half-thickness
        let glow: Float           // 0…1
        let isOrb: Bool
    }

    var chamberEmitters: [ChamberEmitter] {
        guard worldScale.interior, cubeModel.symbolPairedPlinths else { return [] }
        let cc = cubeModel.size / 2
        let reach = worldScale.faceDistance
        let orbR = reach * 0.20
        let centre = SIMD3<Float>(0, 0, 0)
        var lit: Float = 0, total: Float = 0
        var out: [ChamberEmitter] = []
        for face in CubeFace.allCases {
            guard let (ci, fi) = cubeModel.faceletAt(face: face, row: cc, col: cc) else { continue }
            for p in cubeModel.cubies[ci].facelets[fi].props where p.kind == .obelisk {
                total += 1
                guard p.anim > 0 else { continue }
                lit += 1
                let m = cubeModel.restMatrix(face: face, row: cc, col: cc)
                let from = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                let toC = centre - from
                let dist = simd_length(toC)
                guard dist > 1e-4 else { continue }
                let dir = toC / dist
                out.append(ChamberEmitter(a: from + dir * (reach * 0.16),
                                          b: centre - dir * (orbR * 1.55),
                                          radius: reach * 0.012,
                                          glow: min(1, p.anim), isOrb: false))
            }
        }
        guard total > 0 else { return [] }
        out.insert(ChamberEmitter(a: centre, b: centre, radius: orbR,
                                  glow: lit / total, isOrb: true), at: 0)
        // 3K — THE TARGETING BEAM. "The orb emits a new beam. Unlike the six broad, pulsing obelisk
        // beams, this one is narrow, continuous, sharply directional, brighter at its point of
        // contact." It runs the OTHER way — from the orb out to the chosen tile — and unlike the six
        // it touches what it points at, because its whole job is to say "there".
        if let exit = cubeModel.chosenExit {
            let m = cubeModel.restMatrix(face: exit.face, row: exit.row, col: exit.col)
            let target = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            let dir = simd_normalize(target - centre)
            out.append(ChamberEmitter(a: centre + dir * (orbR * 1.05), b: target,
                                      radius: reach * 0.004, glow: 1, isOrb: false))
        }
        return out
    }

    /// Scene 3J — the completion wave. "A wave of light travels outward from the orb, down each
    /// beam, into every obelisk, and across all six faces. The wave reveals the full cube for a
    /// moment. Then the chamber returns to its darker state." 0 = not running; climbs once to 1 and
    /// stops, because it happens exactly once and the chamber is quieter afterwards for having.
    private(set) var chamberWave: Float = 0
    private var chamberWaveFired = false

    /// Scene 5 — receivers follow the current, moment to moment, and the way out appears when all
    /// three hold at once. Ticked rather than event-driven because a twist can UNFEED a receiver as
    /// easily as feed one, and the scene depends on the player seeing that happen.
    private func tickChannelCircuit(_ dt: Float) {
        guard !cubeModel.channelReceivers.isEmpty else { return }
        let fed = channelReach
        var changed = false
        for cu in cubeModel.cubies.indices {
            for f in cubeModel.cubies[cu].facelets.indices {
                let id = cubeModel.cubies[cu].facelets[f].id.rawValue
                guard cubeModel.channelReceivers.contains(id) else { continue }
                for pi in cubeModel.cubies[cu].facelets[f].props.indices
                where cubeModel.cubies[cu].facelets[f].props[pi].kind == .obelisk {
                    let want: Float = fed.contains(id) ? 1 : 0
                    let have = cubeModel.cubies[cu].facelets[f].props[pi].anim
                    if abs(have - want) > 0.001 {
                        // Ease, so a receiver going dark is something you SEE go dark.
                        let next = have + max(-dt * 1.6, min(dt * 1.6, want - have))
                        cubeModel.cubies[cu].facelets[f].props[pi].anim = next
                        changed = true
                    }
                }
            }
        }
        // 5F — the junction vessels mirror LOCAL truth: how many of this tile's channel arms are
        // actually carrying current. Not a hint and not a count of the puzzle's progress — just what
        // is true here, which is why a vessel can read three while the circuit is still broken.
        for cu in cubeModel.cubies.indices {
            for f in cubeModel.cubies[cu].facelets.indices {
                let facelet = cubeModel.cubies[cu].facelets[f]
                guard facelet.props.contains(where: { $0.kind == .layeredVessel }),
                      !facelet.mazeTile.channels.isEmpty else { continue }
                let live = fed.contains(facelet.id.rawValue)
                var arms = 0
                for d in [DirectionMask.north, .east, .south, .west]
                where facelet.mazeTile.channels.contains(d) { arms += 1 }
                let want = live ? Float(min(3, arms)) : 0
                for pi in cubeModel.cubies[cu].facelets[f].props.indices
                where cubeModel.cubies[cu].facelets[f].props[pi].kind == .layeredVessel {
                    let have = cubeModel.cubies[cu].facelets[f].props[pi].anim
                    if abs(have - want) > 0.001 {
                        // Eased, so "the ring rotates out of phase" when a twist breaks the route is
                        // something the player can catch happening.
                        cubeModel.cubies[cu].facelets[f].props[pi].anim =
                            have + max(-dt * 1.2, min(dt * 1.2, want - have))
                        changed = true
                    }
                }
            }
        }
        if changed { cubeModel.markTopologyChanged() }
        // 5K — the way out, created when the circuit goes live. → Scene 6 does not exist yet, so it
        // returns to the hub's Scene 4 for now.
        // 5K — placed by Scene 5's own rule (the far end of the live current), not Scene 3's
        // "as far as you can walk", which would have put the door somewhere the circuit never goes.
        // → SCENE 6, which is Scene 2 RETURNED TO (destination 10): the same world, entered on the
        // far side of the slab the player turned there. Not a new world; that is the whole point.
        if liveCircuit { cubeModel.createCircuitExit(destinationID: 10, depths: channelDepths) }
    }

    private func tickChamberWave(_ dt: Float) {
        if !chamberWaveFired, cubeModel.symbolPairedPlinths, sceneThreeAllObelisksAwake {
            chamberWaveFired = true
        }
        guard chamberWaveFired, chamberWave < 1 else { return }
        chamberWave = min(1, chamberWave + dt / 3.2)
    }

    /// How much of the chamber is awake, 0…1 — the value 3I's stages are keyed to.
    var chamberWoken: Float {
        guard cubeModel.symbolPairedPlinths else { return 0 }
        var lit: Float = 0, total: Float = 0
        for cu in cubeModel.cubies {
            for f in cu.facelets {
                for p in f.props where p.kind == .obelisk {
                    total += 1
                    if p.anim > 0 { lit += 1 }
                }
            }
        }
        return total > 0 ? lit / total : 0
    }

    /// Scene 3D — an obelisk that has just been touched and refused: 1 → 0 as its symbol flashes.
    /// Which one, by facelet id, so only the one the player put their hand on answers.
    private(set) var obeliskRebuff: Float = 0
    private(set) var obeliskRebuffFacelet: Int = -1

    private func tickObeliskRebuff(_ dt: Float) {
        guard obeliskRebuff > 0 else { return }
        obeliskRebuff = max(0, obeliskRebuff - dt / 0.8)
        if obeliskRebuff <= 0 { obeliskRebuffFacelet = -1 }
    }

    /// The six symbols Scene 3 uses, in voice order — index here IS the harmonic. Kept beside the
    /// audio rather than in the stamp so the two cannot disagree about which mark sings which note.
    static let sceneThreeVoices = [TextureLoader.CausticSymbol.one.rawValue,
                                   TextureLoader.CausticSymbol.two.rawValue,
                                   TextureLoader.CausticSymbol.three.rawValue,
                                   TextureLoader.CausticSymbol.four.rawValue,
                                   TextureLoader.CausticSymbol.swirl.rawValue,
                                   TextureLoader.CausticSymbol.square.rawValue]

    /// Scene 5 — every facelet the current reaches, by facelet id. Walked over CHANNELS, not over
    /// openings: the current follows grooves, and a groove crossing a slab boundary only conducts if
    /// the tile on the other side has one facing back. That is the whole scene — a twist rotates a
    /// tile's channels, so it can join two runs or sever one, and neither is announced.
    ///
    /// Recomputed on demand rather than cached, because the thing it depends on is exactly the thing
    /// the player is changing.
    var channelReach: Set<Int> { Set(channelDepths.keys) }

    /// The same walk, keeping HOW FAR each tile is from the source in channel-steps. The set alone
    /// answers "is this lit"; the pulse needs "when does the current get here", which is the same
    /// question the BFS was already answering and throwing away.
    var channelDepths: [Int: Int] {
        guard let src = cubeModel.channelSource,
              let (sci, sfi) = cubeModel.faceletAt(face: src.face, row: src.row, col: src.col) else { return [:] }
        struct T: Hashable { let f: Int; let r: Int; let c: Int }
        let n = cubeModel.size
        var reached: [Int: Int] = [cubeModel.cubies[sci].facelets[sfi].id.rawValue: 0]
        var q = [(t: T(f: src.face.rawValue, r: src.row, c: src.col), d: 0)], head = 0
        var seen: Set<T> = [q[0].t]
        while head < q.count {
            let (t, depth) = q[head]; head += 1
            guard let face = CubeFace(rawValue: t.f),
                  let (ci, fi) = cubeModel.faceletAt(face: face, row: t.r, col: t.c) else { continue }
            let ch = cubeModel.cubies[ci].facelets[fi].mazeTile.channels
            for (dir, mask, dr, dc) in [(SurfaceDirection.north, DirectionMask.north, -1, 0),
                                        (.south, .south, 1, 0), (.west, .west, 0, -1), (.east, .east, 0, 1)]
            where ch.contains(mask) {
                let nr = t.r + dr, nc = t.c + dc
                let nt: T
                let back: SurfaceDirection
                if nr >= 0, nr < n, nc >= 0, nc < n {
                    nt = T(f: t.f, r: nr, c: nc); back = dir.opposite
                } else {
                    let cr = cubeModel.edgeCrossing(face: face, direction: dir, row: t.r, col: t.c)
                    nt = T(f: cr.face.rawValue, r: cr.row, c: cr.col); back = cr.facing.opposite
                }
                guard let nFace = CubeFace(rawValue: nt.f),
                      let (nci, nfi) = cubeModel.faceletAt(face: nFace, row: nt.r, col: nt.c) else { continue }
                // BOTH ends must have a groove. A channel that stops against a blank tile is exactly
                // the "thin dark crack where channels have been rotated out of alignment".
                let backMask: DirectionMask = back == .north ? .north : back == .south ? .south
                                            : back == .west ? .west : .east
                guard cubeModel.cubies[nci].facelets[nfi].mazeTile.channels.contains(backMask) else { continue }
                if seen.insert(nt).inserted {
                    reached[cubeModel.cubies[nci].facelets[nfi].id.rawValue] = depth + 1
                    q.append((nt, depth + 1))
                }
            }
        }
        return reached
    }


    // MARK: - Scene 5C — the travelling pulse

    /// "At its center, liquid light gathers and releases a slow pulse into the nearest channel… The
    /// pulse travels at walking speed… This repeating pulse is the puzzle's primary teaching tool.
    /// The player is never shown an abstract diagram. The circuit explains itself by failing visibly."
    ///
    /// So the pulse is not decoration and cannot be a shader scroll: it has to reach a real place and
    /// stop there, because WHERE it stops is the entire lesson. It is modelled as a front advancing
    /// through the depth map — one number, in channel-steps from the source — which the groove
    /// shader, the emitter and the failure tone all read, so light and sound cannot disagree about
    /// where the current has got to.
    private(set) var pulseFront: Float = -1
    /// Where the current died this cycle, by facelet id: -1 while it is still travelling.
    private(set) var pulseBrokeAt: Int = -1
    private var pulseHold: Float = 0
    private var pulseDepths: [Int: Int] = [:]

    /// One tile per this many seconds. Taken from the player's own gait rather than tuned: the script
    /// says walking speed, and "slow enough for the player to follow on foot" is a promise the pulse
    /// has to keep even if the walk speed is retuned later.
    var pulseTilesPerSecond: Float { player.moveSpeed / Float(player.standGrid) }

    private func tickChannelPulse(_ dt: Float) {
        guard !cubeModel.channelReceivers.isEmpty, cubeModel.channelSource != nil else { return }
        pulseDepths = channelDepths
        let maxDepth = Float(pulseDepths.values.max() ?? 0)

        if pulseHold > 0 {
            // "It spreads briefly against the dead end… the light withdraws toward the source and
            // begins again." The hold IS that beat; the pulse stays put while it happens.
            pulseHold -= dt
            if pulseHold <= 0 { pulseFront = -1; pulseBrokeAt = -1 }
            return
        }

        let previous = pulseFront
        if pulseFront < 0 {
            pulseFront = 0
            pendingAudioCues.append(.channelPulse(at: faceletPosition(of: cubeModel.channelSource)))
        } else {
            pulseFront += dt * pulseTilesPerSecond
        }

        // A receiver the front has just crossed answers as it is fed, whether or not the circuit as
        // a whole holds — that difference is the scene's subject, not a state to be hidden.
        for id in cubeModel.channelReceivers {
            guard let d = pulseDepths[id] else { continue }
            if Float(d) > previous, Float(d) <= pulseFront {
                pendingAudioCues.append(.channelReceiverFed(at: faceletPosition(ofFaceletID: id)))
            }
        }

        if pulseFront >= maxDepth {
            pulseFront = maxDepth
            pulseHold = liveCircuit ? 0.8 : 1.6
            if !liveCircuit {
                // The deepest tile the current reached: the break the player has to find.
                pulseBrokeAt = pulseDepths.first(where: { Float($0.value) == maxDepth })?.key ?? -1
                pendingAudioCues.append(.channelIncomplete(at: faceletPosition(ofFaceletID: pulseBrokeAt)))
            }
        }
    }

    /// World position of a facelet by id — the pulse needs to place a sound at a tile it found by
    /// searching, not by walking a face/row/col it already holds.
    private func faceletPosition(ofFaceletID id: Int) -> SIMD3<Float>? {
        guard id >= 0, let loc = cubeModel.locate(faceletID: id) else { return nil }
        return faceletPosition(of: (face: loc.face, row: loc.row, col: loc.col))
    }

    /// REST position, deliberately unspun: `play(cues:worldSpin:)` and `updateEmitters(_:worldSpin:)`
    /// both spin what they are given, so a position spun here would be spun twice and the whole
    /// scene's audio would swing away from its geometry as the world turns.
    private func faceletPosition(of loc: (face: CubeFace, row: Int, col: Int)?) -> SIMD3<Float>? {
        guard let loc else { return nil }
        let m = cubeModel.restMatrix(face: loc.face, row: loc.row, col: loc.col)
        return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// The emitter that travels with the front, so the pulse can be followed by ear around the far
    /// side of a world. Placed on the reached tile whose depth the front is currently passing,
    /// choosing the one nearest the player when a branch means there are several.
    private var pulseEmitter: AudioEmitter? {
        guard pulseFront >= 0, !pulseDepths.isEmpty else { return nil }
        let want = Int(pulseFront.rounded())
        var best: (id: Int, pos: SIMD3<Float>, dist: Float)? = nil
        let spin = worldSpinMatrix()
        for (id, d) in pulseDepths where d == want {
            guard let p = faceletPosition(ofFaceletID: id) else { continue }
            // Compare in the SPUN frame, where the listener is, but publish the rest position.
            let sp = spin * SIMD4(p, 1)
            let dist = simd_length(SIMD3(sp.x, sp.y, sp.z) - viewOrigin)
            if best == nil || dist < best!.dist { best = (id, p, dist) }
        }
        guard let b = best else { return nil }
        // One STABLE id, not the tile's: the emitter is the pulse, which is a single moving thing.
        // Keying it by tile would restart the loop at every tile boundary — a stutter, not a sound.
        return AudioEmitter(id: -5001, kind: .pulse, position: b.pos, occlusion: 0)
    }

    /// Scene 5 — all three receivers fed from the source AT ONCE. Not "each has been fed at some
    /// point": the scene's whole subject is holding a relationship, so this is a snapshot.
    var liveCircuit: Bool {
        guard !cubeModel.channelReceivers.isEmpty else { return false }
        let fed = channelReach
        return cubeModel.channelReceivers.allSatisfy { fed.contains($0) }
    }

    /// Scene 3 — every obelisk lit. The exit "is created only after all six obelisks are active".
    var sceneThreeAllObelisksAwake: Bool {
        for cu in cubeModel.cubies {
            for f in cu.facelets {
                // Strictly zero means dark. The awakening STARTS at a hair above zero and climbs,
                // so a threshold of 0.01 counted a freshly-lit obelisk as still out.
                for p in f.props where p.kind == .obelisk && p.anim <= 0 { return false }
            }
        }
        return true
    }

    private func openSealedDoors(limitedTo cubies: Set<Int>? = nil) {
        var opened = false
        for ci in Array(cubeModel.sealedPortalCubies)
        where !cubeModel.bondedGroups.contains(where: { $0.contains(ci) })
            && (cubies?.contains(ci) ?? true) {
            cubeModel.sealedPortalCubies.remove(ci)
            opened = true
        }
        if opened {
            updateDoorPlinths()
            beginObeliskAwakening()
            pendingAudioCues.append(.portalOpened(at: nil))
        }
    }

    /// Debug (Shift+Q / Shift+E) — replay the scene's scripted turn on demand, so the one-off puzzle
    /// payoff can be watched as many times as it takes to judge it. Turns the slab the scene names
    /// (Scene 2's hidden-exit slab), or the back slab in a world that names none. Combine with `G` to
    /// slow it right down, and `[` / `]` to scrub a held turn frame by frame.
    ///
    /// Respects bonds: if the lock still refuses this slab, nothing happens — deliberately, so the
    /// key cannot quietly desync a puzzle by turning a world that shouldn't move yet. It also skips
    /// the `openSealedDoors` fallback the puzzle path uses, since replaying a view should not unseal
    /// anything.
    func debugReplayScriptedTwist(clockwise: Bool) {
        guard let s = cubeModel.scriptedTwistSlice else {
            startBackSliceRotation(clockwise: clockwise)
            return
        }
        guard cubeModel.canRotateSlice(axis: s.axis, index: s.index) else { return }
        startScriptedSliceRotation(axis: s.axis, index: s.index, clockwise: clockwise)
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
        // Positioned BEFORE the permutation, so it marks where the slab was as it settled.
        pendingAudioCues.append(.twistLocked(at: sliceCentre(axis: sliceRotation.axis, index: sliceRotation.index)))
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
        if opened {
            updateDoorPlinths(); beginObeliskAwakening()   // the twist swings it open ⇒ the plinth shows the portal
            pendingAudioCues.append(.portalOpened(at: sliceCentre(axis: sliceRotation.axis, index: sliceRotation.index)))
        }

        // M20 (Eddie): the switch-trip turn rotates a distant back slab that need not contain the
        // door — open it here so the payoff still lands (see startBackSliceRotation).
        // A door in the slab that just turned opens, if its lock is gone. Scene 4 rests on this: the
        // player releases three anchors, twists their own face, and the sealed portal in it comes
        // alive. It never could before — `openSealedDoors` was reachable ONLY from the garden's
        // scripted switch-trip turn, so the player's own twist unsealed nothing and Scene 4's portal
        // was unopenable (Eddie: "the vessel was aligned but the portal didn't open").
        if sliceRotation.opensSealedDoors { openSealedDoors() }
        else { openSealedDoors(limitedTo: sliceRotation.affectedCubies) }
        shakeDustFromJoints()

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

        onPlayerArrived(viaMove: false)
        reprimePortalZone()   // a twist that rotates a portal under you must not teleport you — re-prime
    }

    // MARK: - Interaction (M10 Phase G)

    /// Set by `interact()` when the player stands on a portal tile; the Renderer consumes it to
    /// switch worlds (M11.2), then clears it. Lives here (per-world) because interact() runs on the
    /// active world; the Renderer owns the world stack, so the world-switch itself happens there.
    var portalRequested = false
    /// Which world the requesting portal leads to (M15.2) — the portal Prop's `state`, indexing
    /// `Renderer.portalDestinations`. Ignored when the swap is a pop (leaving a sub-world).
    var portalDestinationID = 0
    /// Phase 0 — how the requesting portal moves the world stack (copied from the Prop's
    /// `transition`), so the Renderer no longer has to infer push-vs-pop from world names.
    var portalTransition: WorldTransition = .auto

    /// The interaction hook: act on any interactive props on the player's current tile.
    /// A portal takes priority (stepping "through the door" switches worlds); otherwise chests
    /// toggle open ↔ closed. This is the dispatch point where a lever would trigger a slice
    /// rotation, etc.
    /// M16.6 — the door plinth speaks the lock's state, and only ever says it in glyphs (no UI text).
    /// blank → **swirl** once the bond dissolves ("turn/combine to produce" — the verb naming the
    /// twist M16.4 requires) → **portal** once that twist has swung the door open.
    /// (Mazen Docs/Builder Glyphs — 4D Shadows.md)
    ///
    /// The plinth sits on the plaza tile just NORTH of the temple door (Eddie moved it off the
    /// walk-through portal tile, 2026-07-16), so we find the temple-door portal (`state == 1`,
    /// destination temple-interior; the moon portal's state is 0) and drive the plinth on its north
    /// neighbour — falling back to the door tile itself for the tiny-cube case.
    private func updateDoorPlinths() {
        // A scene may name the plinth that reports the lock, when it isn't beside the door it reports
        // on (Scene 2's central plinth is deliberately remote — "a map of conditions, not of the
        // maze"). Same glyph language either way: filled dots per engaged switch, the portal glyph
        // once the way is open.
        if let pp = cubeModel.progressPlinth {
            let opened = !templeDoorStillSealed()
            let symbol = opened ? TextureLoader.CausticSymbol.portal.rawValue
                                : (TextureLoader.progressMaskBase + switchMask())
            if let pi = cubeModel.cubies[pp.ci].facelets[pp.fi].props.firstIndex(where: { $0.kind == .plinth }),
               cubeModel.cubies[pp.ci].facelets[pp.fi].props[pi].state != symbol {
                cubeModel.cubies[pp.ci].facelets[pp.fi].props[pi].state = symbol
            }
            if opened, cubeModel.cubies[pp.ci].facelets[pp.fi].props.contains(where: { $0.kind == .alignmentCylinder }) {
                cubeModel.cubies[pp.ci].facelets[pp.fi].props.removeAll { $0.kind == .alignmentCylinder }
                cubeModel.markTopologyChanged()   // PERF: prop removed — location caches re-derive
            }
            return
        }
        let n = cubeModel.size
        for r in 0..<n {
            for c in 0..<n {
                guard let (pci, pfi) = cubeModel.faceletAt(face: .positiveZ, row: r, col: c),
                      cubeModel.cubies[pci].facelets[pfi].props.contains(where: { $0.kind == .portal && $0.state == 1 })
                else { continue }
                let opened = !cubeModel.sealedPortalCubies.contains(pci)
                // M16.6 (Eddie): the plinth is the lock's POSITIONAL PROGRESS DISPLAY — one dot per
                // switch, filled if that switch is engaged, a hollow ring if disengaged (so goofing up
                // one switch shows its dot hollow). All four filled ⇒ ready to turn; portal once
                // opened. The alignment cylinder is NOT spawned here; it rises on F at the ready plinth.
                let symbol = opened ? TextureLoader.CausticSymbol.portal.rawValue
                                    : (TextureLoader.progressMaskBase + switchMask())
                // The plinth is on a tile ADJACENT to the door. A twist rotates the +Z face, so which
                // neighbour it's on changes — search all four (+ the door tile). Only the door plinth
                // is adjacent to the door portal; the dials sit in the far corners.
                for (nr, nc) in [(r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1), (r, c)] {
                    guard let (ci, fi) = cubeModel.faceletAt(face: .positiveZ, row: nr, col: nc),
                          let pi = cubeModel.cubies[ci].facelets[fi].props.firstIndex(where: { $0.kind == .plinth })
                    else { continue }
                    if cubeModel.cubies[ci].facelets[fi].props[pi].state != symbol {
                        cubeModel.cubies[ci].facelets[fi].props[pi].state = symbol
                    }
                    // Once opened, retract the alignment cylinder (the twist that opened the door).
                    if opened {
                        cubeModel.cubies[ci].facelets[fi].props.removeAll { $0.kind == .alignmentCylinder }
                        cubeModel.markTopologyChanged()   // PERF: prop removed — location caches re-derive
                    }
                    break
                }
            }
        }
    }

    /// M16.6 Phase 2b — drive the alignment cylinder's two animations each frame:
    ///  • GROW: `anim` rises 0→1 the moment the cylinder exists (unlock), so it extrudes from the disc.
    ///  • ALIGN: once engaged AND fully risen, `alignAnim` rises 0→1 (the half-squares pivot whole);
    ///    at 1 it fires the start-face twist that opens the door — the plinth turning the world for you.
    /// PERF: iterates the cached list of facelets that actually CARRY a switch cap / cylinder
    /// (`animatablePropTiles`, keyed on topologyVersion) instead of sweeping every cubie×facelet×prop
    /// per frame — a full-surface scan at size 25 to animate a handful of props.
    private func tickAlignmentCylinder(_ dt: Float) {
        let growRate: Float = 1.0 / 0.8, alignRate: Float = 1.0 / 1.1
        let switchRate: Float = dt / 0.3       // switch cap slides between flush/out in ~0.3 s
        for (ci, fi) in cubeModel.animatablePropTiles() {
            // Switch caps: ease the current height (anim) toward the engaged target (alignAnim).
            for pi in cubeModel.cubies[ci].facelets[fi].props.indices
            where cubeModel.cubies[ci].facelets[fi].props[pi].kind == .switchCap {
                let target = cubeModel.cubies[ci].facelets[fi].props[pi].alignAnim
                let cur = cubeModel.cubies[ci].facelets[fi].props[pi].anim
                cubeModel.cubies[ci].facelets[fi].props[pi].anim =
                    cur < target ? min(target, cur + switchRate) : max(target, cur - switchRate)
            }
            for pi in cubeModel.cubies[ci].facelets[fi].props.indices
            where cubeModel.cubies[ci].facelets[fi].props[pi].kind == .alignmentCylinder {
                cubeModel.cubies[ci].facelets[fi].props[pi].anim =
                    min(1, cubeModel.cubies[ci].facelets[fi].props[pi].anim + dt * growRate)
                guard cylinderEngaged, cubeModel.cubies[ci].facelets[fi].props[pi].anim >= 1 else { continue }
                let a = min(1, cubeModel.cubies[ci].facelets[fi].props[pi].alignAnim + dt * alignRate)
                cubeModel.cubies[ci].facelets[fi].props[pi].alignAnim = a
                if a >= 1 {
                    cylinderEngaged = false
                    // A scene may name the slab its lock turns (Scene 2 turns the one carrying the
                    // hidden exit); otherwise the distant BACK wall turns, relative to the player.
                    if let s = cubeModel.scriptedTwistSlice {
                        startScriptedSliceRotation(axis: s.axis, index: s.index, clockwise: s.clockwise)
                    } else {
                        startBackSliceRotation(clockwise: true)
                    }
                }
            }
        }
    }

    /// Debug (U key): make the temple door READY without walking to the far dials — re-seal the
    /// door, clear the lock, drop any cylinder — so the plinth reads "four filled". Then stand at the
    /// plinth and press F to watch the turn-the-world sequence. Repeatable (resets after it opens).
    func debugMakeDoorReady() {
        for cu in cubeModel.cubies.indices {
            for fi in cubeModel.cubies[cu].facelets.indices {
                if cubeModel.cubies[cu].facelets[fi].props.contains(where: { $0.kind == .portal && $0.state == 1 }) {
                    cubeModel.sealedPortalCubies.insert(cu)   // re-seal the temple door
                }
                cubeModel.cubies[cu].facelets[fi].props.removeAll { $0.kind == .alignmentCylinder }
                for pi in cubeModel.cubies[cu].facelets[fi].props.indices
                where cubeModel.cubies[cu].facelets[fi].props[pi].kind == .switchCap {
                    cubeModel.cubies[cu].facelets[fi].props[pi].alignAnim = 1   // engage every switch
                    cubeModel.cubies[cu].facelets[fi].props[pi].anim = 1
                }
            }
        }
        cylinderEngaged = false
        cubeModel.bondedGroups.removeAll()   // unlock (bypass the switches)
        cubeModel.markTopologyChanged()      // PERF: cylinder props removed above — caches re-derive
        updateDoorPlinths()                  // ⇒ plinth shows all-filled, ready for F
    }

    /// Where a prop stands, in STAND cells, so "which of these am I next to" is answerable. Mirrors
    /// `Prop.blocks`: the author sub-cell's centre, shifted by the same offset the renderer draws it at.
    private func standPosition(of p: Prop) -> (row: Float, col: Float) {
        let grid = worldScale.standGrid
        let k = Float(grid) / 3, step = worldScale.standStep
        return (Float(p.subRow) * k + k / 2 + (step > 0 ? p.offsetY / step : 0),
                Float(p.subCol) * k + k / 2 + (step > 0 ? p.offsetX / step : 0))
    }

    /// What F (and, on iOS, a tap) acts on. Shared with `hasInteractableHere` so the touch path
    /// cannot drift from the keyboard one.
    static let interactableKinds: Set<PropKind> = [.portal, .layeredVessel, .anchor, .switchCap,
                                                   .plinth, .dial, .chest, .alignmentCylinder]

    /// Is the player standing on something worth pressing? On iOS a tap means "walk forward", so it
    /// can only mean "use this" where there is something to use — otherwise the player could never
    /// cross their own controls.
    var hasInteractableHere: Bool {
        guard let (ci, fi) = cubeModel.faceletAt(face: player.face, row: player.row, col: player.col)
        else { return false }
        return cubeModel.cubies[ci].facelets[fi].props.contains {
            GameState.interactableKinds.contains($0.kind)
        }
    }

    func interact() {
        guard let (ci, fi) = cubeModel.faceletAt(face: player.face, row: player.row, col: player.col) else { return }
        let props = cubeModel.cubies[ci].facelets[fi].props
        // A tile is ~19 m across and can hold more than one thing worth pressing F at — Scene 1
        // stands its largest vessel BESIDE the arch, on the same tile. Taking the portal first
        // whatever else was there meant walking up to that vessel, pressing F, and being thrown
        // through the door instead (Eddie). So F acts on whatever you are actually NEAREST to.
        //
        // Walking THROUGH a portal is unaffected: that fires from the portal's own centre sub-cell,
        // continuously, and is the primary way doors are used. This only decides what F means.
        let interactable = GameState.interactableKinds
        let here = (row: Float(player.subRow), col: Float(player.subCol))
        let nearest = props.filter { interactable.contains($0.kind) }.min { a, b in
            let pa = standPosition(of: a), pb = standPosition(of: b)
            let da = (pa.row - here.row) * (pa.row - here.row) + (pa.col - here.col) * (pa.col - here.col)
            let db = (pb.row - here.row) * (pb.row - here.row) + (pb.col - here.col) * (pb.col - here.col)
            return da < db
        }
        if let portal = props.first(where: { $0.kind == .portal }),
           !cubeModel.sealedPortalCubies.contains(ci),      // M16.4: sealed = inert
           nearest?.kind == .portal {
            portalRequested = true
            portalDestinationID = portal.state
            portalTransition = portal.transition
            return
        }
        // Scene 4D — the VESSEL. Activating it makes it demonstrate the turn, and fail: the ring
        // attempts, the vessel strains, the anchors answer, and the twist becomes the player's.
        if cubeModel.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .layeredVessel }) {
            // …but only where there is something for it to demonstrate. Scene 1 is explicit that
            // "if the player approaches the vessels, nothing dramatic happens" — they are scenery
            // that will turn out not to have been scenery, and a vessel that performs on demand in
            // the opening spends that reveal before it has been set up. A world with no lock has
            // nothing to say, so it says nothing.
            if !cubeModel.bondedGroups.isEmpty {
                let (axis, index) = cubeModel.sliceAxisAndIndex(for: player.face)
                beginVesselDemo(at: sliceCentre(axis: axis, index: index))
            }
            return
        }
        // Scene 4 — an ANCHOR. Unlike a switch this does not toggle: activating it RELEASES the bond
        // it holds, and that release is permanent ("The anchors may be released in any order. Each
        // release is permanent."). The turn stays refused until the last one is gone, because
        // canRotateSlice refuses while ANY bonded group straddles the slab.
        if let aIdx = cubeModel.cubies[ci].facelets[fi].props.firstIndex(where: { $0.kind == .anchor }) {
            guard cubeModel.cubies[ci].facelets[fi].props[aIdx].anim > 0.5 else { return }  // already released
            cubeModel.cubies[ci].facelets[fi].props[aIdx].anim = 0
            cubeModel.removeBond(containing: ci)
            pendingAudioCues.append(.switchDisengaged(at: nil))   // released, at the player's hand
            // The last one going frees the world: let that land as its own sound.
            if cubeModel.bondedGroups.isEmpty { pendingAudioCues.append(.controlRaised(at: nil)) }
            cubeModel.markTopologyChanged()
            return
        }
        // M16.6 (Eddie): a SWITCH — F toggles it engaged (poking out) ↔ disengaged (flush). All four
        // engaged dissolves the lock; disengaging any one re-applies it (goof-and-fix). The door
        // plinth's progress display + the lock are refreshed together.
        // Scene 3D — touching an OBELISK. "Activating an obelisk directly does nothing. The symbol
        // flashes faintly, a distant answering tone sounds from somewhere else in the maze, the
        // obelisk remains inactive. This teaches that the control is located elsewhere."
        //
        // The answering tone is positioned at the obelisk's own PLINTH, so the sound is not merely
        // "somewhere else" — it is the answer, and a player who turns toward it is already walking
        // to the thing they need. The lesson and the direction arrive together.
        if cubeModel.symbolPairedPlinths,
           let obIdx = cubeModel.cubies[ci].facelets[fi].props.firstIndex(where: { $0.kind == .obelisk }) {
            let symbol = cubeModel.cubies[ci].facelets[fi].props[obIdx].state
            if cubeModel.cubies[ci].facelets[fi].props[obIdx].anim <= 0 {
                obeliskRebuff = 1                       // the symbol flashes and fades
                obeliskRebuffFacelet = cubeModel.cubies[ci].facelets[fi].id.rawValue
                var answerAt: SIMD3<Float>? = nil
                for cu in cubeModel.cubies.indices {
                    for f in cubeModel.cubies[cu].facelets.indices
                    where cubeModel.cubies[cu].facelets[f].props.contains(where: {
                        $0.kind == .switchCap && $0.state == symbol
                    }) {
                        if let loc = cubeModel.locate(cubie: cu, facelet: f) {
                            let m = cubeModel.restMatrix(face: loc.face, row: loc.row, col: loc.col)
                            answerAt = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                        }
                    }
                }
                pendingAudioCues.append(.switchDisengaged(at: answerAt))
            }
            return                                       // it stays inactive either way
        }
        // Scene 3 — a plinth that controls ONE obelisk, by symbol, somewhere else in the chamber.
        // "Unlike Scene 2, activation is not reversible during normal play. Once raised, a plinth
        // remains active. The puzzle is cumulative."
        if cubeModel.symbolPairedPlinths,
           let capIdx = cubeModel.cubies[ci].facelets[fi].props.firstIndex(where: { $0.kind == .switchCap }) {
            guard cubeModel.cubies[ci].facelets[fi].props[capIdx].alignAnim < 0.5 else { return }  // already raised
            let symbol = cubeModel.cubies[ci].facelets[fi].props[capIdx].state
            cubeModel.cubies[ci].facelets[fi].props[capIdx].alignAnim = 1
            pendingAudioCues.append(.switchEngaged(at: nil))
            // "A pulse travels away through embedded channels… the matching obelisk activates
            // elsewhere in the chamber." The obelisk is found by its MARK, not by a pairing table —
            // so the puzzle's rule is the same thing the player is reading off the stone.
            var wokeAt: SIMD3<Float>? = nil
            for cu in cubeModel.cubies.indices {
                for f in cubeModel.cubies[cu].facelets.indices {
                    for pi in cubeModel.cubies[cu].facelets[f].props.indices
                    where cubeModel.cubies[cu].facelets[f].props[pi].kind == .obelisk
                        && cubeModel.cubies[cu].facelets[f].props[pi].state == symbol
                        && cubeModel.cubies[cu].facelets[f].props[pi].anim <= 0.01 {
                        cubeModel.cubies[cu].facelets[f].props[pi].anim = 0.001   // begins to climb
                        if let loc = cubeModel.locate(cubie: cu, facelet: f) {
                            let m = cubeModel.restMatrix(face: loc.face, row: loc.row, col: loc.col)
                            wokeAt = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                        }
                    }
                }
            }
            obeliskAwakening = true
            // Positioned AT the obelisk, across the chamber: the sound is how the player learns the
            // control they just pressed did something somewhere they cannot see.
            pendingAudioCues.append(.twistLocked(at: wokeAt))
            // 3K — the orb chooses where the way out appears, and only now. → SCENE 4: "emergence
            // beneath the stars", the small world the player is handed the twist on. This was
            // pointing back at Scene 2 as a placeholder while Scene 3 was being built.
            if sceneThreeAllObelisksAwake { cubeModel.createChosenExit(destinationID: 11) }
            cubeModel.markTopologyChanged()
            return
        }
        if let capIdx = cubeModel.cubies[ci].facelets[fi].props.firstIndex(where: { $0.kind == .switchCap }) {
            // Once the door is open (portal activated), the switches are inert for this puzzle (Eddie).
            guard templeDoorStillSealed() else { return }
            let engaged = cubeModel.cubies[ci].facelets[fi].props[capIdx].alignAnim > 0.5
            cubeModel.cubies[ci].facelets[fi].props[capIdx].alignAnim = engaged ? 0 : 1
            // "A short tone sounds… the tone plays in reverse" on disengage (Scene 2E).
            let where_ = sliceCentre(axis: 0, index: cubeModel.cubies[ci].position.x >= 0 ? Int(cubeModel.cubies[ci].position.x) : 0)
            pendingAudioCues.append(engaged ? .switchDisengaged(at: where_) : .switchEngaged(at: where_))
            refreshSwitchLock()
            return
        }
        // SCENE 5 — a FACE ROTATOR. The slab it turns is the one it stands on: the outer layer of
        // the face under the player's feet, which is the same slab Q/E would turn from here. So the
        // control means the same thing wherever it ends up after a turn carries it somewhere new —
        // it turns the face you are looking at, not a slab it was born remembering.
        if cubeModel.faceRotators,
           cubeModel.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .alignmentCylinder }) {
            // Ignored rather than queued while the world is already moving: a control pressed a
            // dozen times while reading a route must not bank up turns the player has forgotten
            // asking for.
            guard !sliceRotation.isActive, !player.isMoving, !player.isTurning else { return }
            let (axis, index) = cubeModel.sliceAxisAndIndex(for: player.face)
            startScriptedSliceRotation(axis: axis, index: index, clockwise: true)
            return
        }
        // M16.6 (Eddie): F at the READY door plinth (lock undone, door still sealed, no cylinder yet)
        // rises the alignment cylinder and plays the turn-the-world sequence (grow → align → twist).
        // Only the door plinth reaches here — dial-tile plinths are caught by the dial branch above,
        // and gallery plinths have no state-1 door portal to be "sealed".
        if let plinthProp = cubeModel.cubies[ci].facelets[fi].props.first(where: { $0.kind == .plinth }),
           cubeModel.bondedGroups.isEmpty, templeDoorStillSealed() {
            // TWO deliberate presses (Eddie): F #1 RAISES the cylinder (grow only); F #2 — once it's
            // fully risen AND past a short cooldown — TURNS THE WORLD (align + twist). The cooldown
            // stops a stray double-tap of the first press from firing the turn by accident.
            if let cyl = cubeModel.cubies[ci].facelets[fi].props.first(where: { $0.kind == .alignmentCylinder }) {
                if cyl.anim >= 1 && !cylinderEngaged && time - lastCylinderRaiseTime > cylinderEngageCooldown {
                    cylinderEngaged = true
                }
            } else {
                cubeModel.cubies[ci].facelets[fi].props.append(
                    Prop(kind: .alignmentCylinder, subRow: plinthProp.subRow, subCol: plinthProp.subCol,
                         facing: plinthProp.facing, state: 0))
                cubeModel.markTopologyChanged()   // PERF: prop added — location caches re-derive
                lastCylinderRaiseTime = time
                pendingAudioCues.append(.controlRaised(at: nil))   // at the player: they are AT the plinth
            }
            return
        }
        for pi in cubeModel.cubies[ci].facelets[fi].props.indices
        where cubeModel.cubies[ci].facelets[fi].props[pi].kind == .chest {
            cubeModel.cubies[ci].facelets[fi].props[pi].state = 1 - cubeModel.cubies[ci].facelets[fi].props[pi].state
        }
    }

    /// M16.6 — the 4-bit engaged mask of the four switches (bit i = switch i+1 engaged). Drives the
    /// door plinth's positional progress display.
    private func switchMask() -> Int {
        var m = 0
        for cu in cubeModel.cubies {
            for f in cu.facelets {
                for p in f.props where p.kind == .switchCap {
                    if p.alignAnim > 0.5, (1...4).contains(p.state) { m |= (1 << (p.state - 1)) }
                }
            }
        }
        return m
    }

    private func allSwitchesEngaged() -> Bool { switchMask() == 0b1111 }

    /// M16.6 — after a switch toggles: while the door is still sealed, clear the lock if all four are
    /// engaged, else RE-apply the stored temple bond (goof-and-fix). Then refresh the plinth display.
    private func refreshSwitchLock() {
        if templeDoorStillSealed() {
            if allSwitchesEngaged() {
                cubeModel.bondedGroups.removeAll()
            } else if !cubeModel.templeDoorBond.isEmpty {
                cubeModel.bondedGroups = [cubeModel.templeDoorBond]
            }
        }
        updateDoorPlinths()
    }

    /// Is the temple door (the `state == 1` portal) still sealed? Used to gate the door plinth's F.
    /// "Is the door this lock opens still shut?" — the switches go inert once it is open (Eddie).
    ///
    /// This used to look for a portal whose destination is 1, which is `temple-interior`: the world
    /// Scene 2's chamber pointed at before Scene 3 existed. When the chamber was repointed to
    /// Scene 3 (destination 13) this stopped finding anything, fell through to `false`, and the
    /// guard in the switch branch silently rejected EVERY press — Scene 2's four-corner lock has
    /// been dead since, with no error and nothing on screen to say so (Eddie's walkthrough,
    /// 2026-08-01). A door identified by which world lies behind it breaks the day that world
    /// changes; a door identified by BEING SEALED does not.
    private func templeDoorStillSealed() -> Bool {
        for cu in cubeModel.cubies.indices where cubeModel.sealedPortalCubies.contains(cu) {
            if cubeModel.cubies[cu].facelets.contains(where: { f in
                f.props.contains(where: { $0.kind == .portal })
            }) { return true }
        }
        return false
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
