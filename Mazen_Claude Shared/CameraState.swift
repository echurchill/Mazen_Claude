import simd

enum CameraMode {
    case orbit
    case firstPerson
}

/// A fully-resolved first-person camera pose. Computing it walks the whole chain (inflated
/// placement, move/turn interpolation, mouse look, twist ride, world spin), so it is computed
/// **once per frame** (R2.4) and handed to the getters below rather than re-derived by each.
struct FirstPersonPose {
    var eye: SIMD3<Float>
    var forward: SIMD3<Float>
    var up: SIMD3<Float>
}

struct CameraState {
    var mode: CameraMode = .orbit
    var orbitRotation: SIMD2<Float> = SIMD2(0.45, 0.5)
    var orbitAutoRotate: Bool = true

    /// User zoom override on the orbit camera. `nil` = use the world's default framing
    /// distance (`WorldScale.orbitDistance`). Set/clamped by the platform zoom handlers.
    var orbitDistanceOverride: Float? = nil

    /// First-person mouse look (radians). `lookYaw` is an offset from the discrete `facing`;
    /// `lookPitch` is absolute and clamped. A forward move snaps `facing` to the look direction
    /// (aim-to-steer, via `GameState.steerToLook`).
    var lookYaw: Float = 0
    var lookPitch: Float = 0

    mutating func updateOrbit(deltaTime: Float) {
        if mode == .orbit && orbitAutoRotate {
            orbitRotation.x += deltaTime * 0.15
        }
    }

    func viewProjectionMatrix(aspect: Float, cubeModel: CubeModel, pose: FirstPersonPose?) -> float4x4 {
        let ws = cubeModel.worldScale
        let fov = mode == .orbit ? ws.orbitFOVRadians : ws.firstPersonFOVRadians
        let projection = float4x4.perspective(
            fovYRadians: fov,
            aspect: aspect,
            nearZ: ws.cameraNearZ,
            farZ: ws.cameraFarZ
        )

        switch mode {
        case .orbit:
            let rotX = float4x4.rotation(radians: orbitRotation.y, axis: SIMD3(1, 0, 0))
            let rotY = float4x4.rotation(radians: orbitRotation.x, axis: SIMD3(0, 1, 0))
            let translate = float4x4.translation(0, 0, -(orbitDistanceOverride ?? ws.orbitDistance))
            return projection * translate * rotX * rotY

        case .firstPerson:
            guard let p = pose else { return projection }   // FP always supplies its pose
            let view = float4x4.lookAt(eye: p.eye, target: p.eye + p.forward, up: p.up)
            return projection * view
        }
    }

    func cameraPosition(cubeModel: CubeModel, pose: FirstPersonPose?) -> SIMD3<Float> {
        switch mode {
        case .orbit:
            // The orbit view is `translate * rotX * rotY`, so the camera's WORLD position is that
            // view inverted, applied to the origin: rotY⁻¹ · rotX⁻¹ · (0, 0, d). This used to return
            // the bare (0, 0, d) — the camera as it sits before you have dragged it — which is only
            // right at zero rotation and silently wrong everywhere else.
            //
            // Nothing noticed while this was merely the audio listener's position and the "is the
            // player looking at it" test for Scene 1's vessels. Prop culling then asked it where the
            // eye was, believed the answer, and kept whatever faced +Z however the world was turned:
            // a band of scenery that tracked the world's spin instead of the camera (Eddie:
            // "scene 1 and 2 still have orbital culling happening"). A stale answer is worse than no
            // answer, because it looks like a plausible one.
            let d = orbitDistanceOverride ?? cubeModel.worldScale.orbitDistance
            let invX = float4x4.rotation(radians: -orbitRotation.y, axis: SIMD3(1, 0, 0))
            let invY = float4x4.rotation(radians: -orbitRotation.x, axis: SIMD3(0, 1, 0))
            let e = invY * (invX * SIMD4<Float>(0, 0, d, 1))
            return SIMD3(e.x, e.y, e.z)
        case .firstPerson:
            return pose?.eye ?? SIMD3(0, 0, 0)
        }
    }

    func firstPersonPose(player: PlayerState, cubeModel: CubeModel, sliceRotation: GameState.SliceRotation, worldSpin: float4x4) -> FirstPersonPose {
        let eyeHeight = cubeModel.worldScale.eyeHeight
        let step = cubeModel.worldScale.standStep
        let center = cubeModel.worldScale.standGrid / 2

        // M14b Phase 3: a standing spot's eye ON the curved surface — inflate the stand-cell footprint,
        // stand the eye up along the *local* surface normal. Returns eye + that normal (the up vec).
        // At roundness 0 this is exactly the old flat spot (inflatedPlacement returns the flat frame).
        func spot(_ f: CubeFace, _ r: Int, _ c: Int, _ sr: Int, _ sc: Int) -> (eye: SIMD3<Float>, up: SIMD3<Float>) {
            let p = cubeModel.inflatedPlacement(face: f, row: r, col: c,
                                                localX: Float(sc - center) * step, localY: Float(sr - center) * step)
            let normal = SIMD3<Float>(p.columns.2.x, p.columns.2.y, p.columns.2.z)
            let pos = p.position
            return (pos + normal * eyeHeight, normal)
        }

        var (eyePos, upDir) = player.isMoving
            ? spot(player.moveFromFace, player.moveFromRow, player.moveFromCol, player.moveFromSubRow, player.moveFromSubCol)
            : spot(player.face, player.row, player.col, player.subRow, player.subCol)

        if player.isMoving {
            let (toEye, toUp) = spot(player.moveToFace, player.moveToRow, player.moveToCol, player.moveToSubRow, player.moveToSubCol)
            let t = player.moveProgress   // linear = constant walking speed (no per-hop stop-start)
            if player.moveFromFace != player.moveToFace {
                // Round the corner along the sphere instead of chording straight
                // through it: slerp the eye *direction* around the shared cube edge and
                // interpolate the radius separately. A plain mix()+renormalize cuts
                // inside the corner — very visible at the low first-person eye height.
                let radius = length(eyePos) * (1 - t) + length(toEye) * t
                eyePos = Self.slerp(normalize(eyePos), normalize(toEye), t: t) * radius
                upDir = Self.slerp(upDir, toUp, t: t)
            } else {
                eyePos = mix(eyePos, toEye, t: t)
                upDir = normalize(mix(upDir, toUp, t: t))
            }
        }

        var facingWorld: SIMD3<Float>
        if player.isMoving {
            let interior = cubeModel.worldScale.interior
            let fromDir = Self.headingToWorld(player.facing, face: player.moveFromFace, interior: interior)
            let toDir = Self.headingToWorld(player.moveNewFacing, face: player.moveToFace, interior: interior)
            let t = player.moveProgress   // linear = constant walking speed (no per-hop stop-start)
            facingWorld = normalize(mix(fromDir, toDir, t: t))
        } else if player.isTurning {
            let interior = cubeModel.worldScale.interior
            let fromDir = Self.headingToWorld(player.turnFromFacing, face: player.face, interior: interior)
            let toDir = Self.headingToWorld(player.turnToFacing, face: player.face, interior: interior)
            let t = Self.smoothstep(player.turnProgress)
            facingWorld = normalize(mix(fromDir, toDir, t: t))
        } else {
            facingWorld = Self.headingToWorld(player.facing, face: player.face, interior: cubeModel.worldScale.interior)
        }

        // M14b: re-seat the (flat) heading into the local curved tangent plane, so the horizon
        // stays level with the ground underfoot on an inflated world. No-op at roundness 0.
        facingWorld = normalize(facingWorld - upDir * dot(facingWorld, upDir))

        // Mouse look: yaw about the face up, then pitch about the view's right axis. Free-look
        // and mouselook render identically here; they differ only in whether a forward move
        // snaps `facing` to the look (handled in GameState.steerToLook).
        facingWorld = simd_quatf(angle: lookYaw, axis: upDir).act(facingWorld)
        let rightAxis = normalize(cross(facingWorld, upDir))
        facingWorld = normalize(simd_quatf(angle: lookPitch, axis: rightAxis).act(facingWorld))

        if sliceRotation.isActive && sliceRotation.playerCubieIndex >= 0 && sliceRotation.affectedCubies.contains(sliceRotation.playerCubieIndex) {
            let rotQ = sliceRotation.currentQuat   // single source: SliceRotation (R2.3)
            eyePos = rotQ.act(eyePos)
            facingWorld = rotQ.act(facingWorld)
            upDir = rotQ.act(upDir)
        }

        // M9.5-3: ride the idle world spin — first person stands on the turning cube, so the
        // maze stays fixed relative to the player while the world-frame sun/moon/sky sweep by.
        let se = worldSpin * SIMD4(eyePos, 1)
        let sf = worldSpin * SIMD4(facingWorld, 0)
        let su = worldSpin * SIMD4(upDir, 0)
        eyePos = SIMD3(se.x, se.y, se.z)
        facingWorld = SIMD3(sf.x, sf.y, sf.z)
        upDir = SIMD3(su.x, su.y, su.z)

        return FirstPersonPose(eye: eyePos, forward: facingWorld, up: upDir)
    }

    func cameraUp(pose: FirstPersonPose?) -> SIMD3<Float> {
        switch mode {
        case .orbit:
            return SIMD3(0, 1, 0)
        case .firstPerson:
            return pose?.up ?? SIMD3(0, 1, 0)
        }
    }

    /// Which way the camera is LOOKING. Needed as its own value (rather than pulled back out of the
    /// view-projection) by anything that has to orient itself the way the player is oriented — the
    /// audio listener, whose whole job is knowing which direction a sound arrives from. In orbit the
    /// camera looks at the cube's centre from its orbit position; in first person the pose says so.
    func cameraForward(cubeModel: CubeModel, pose: FirstPersonPose?) -> SIMD3<Float> {
        switch mode {
        case .orbit:
            let p = cameraPosition(cubeModel: cubeModel, pose: pose)
            let len = simd_length(p)
            return len > 1e-5 ? -p / len : SIMD3(0, 0, -1)
        case .firstPerson:
            return pose?.forward ?? SIMD3(0, 0, -1)
        }
    }

    // MARK: - Helpers

    /// World-space direction a heading points, in a face's local (tangent, bitangent) plane.
    /// Interior worlds (M15.1) mirror the row/bitangent axis — the face seen from inside.
    static func headingToWorld(_ h: Heading8, face: CubeFace, interior: Bool) -> SIMD3<Float> {
        let tb = h.tangentBitangent
        let b = interior ? -face.bitangent : face.bitangent
        return normalize(face.tangent * tb.t + b * tb.b)
    }

    /// Nearest 8-way heading for a world-space direction on a face (inverse of the above).
    static func worldToHeading8(_ dir: SIMD3<Float>, face: CubeFace, interior: Bool) -> Heading8 {
        let t = dot(dir, face.tangent)
        let b = dot(dir, interior ? -face.bitangent : face.bitangent)
        let angle = atan2f(t, -b)  // 0 = north (−bitangent in the world frame of this orientation)
        var idx = Int((angle / (.pi / 4)).rounded())
        idx = ((idx % 8) + 8) % 8
        return Heading8(rawValue: idx)!
    }

    /// Spherical interpolation of two unit vectors — constant-angular-velocity travel
    /// along the great-circle arc between them (unlike `mix`, which cuts the chord).
    /// Falls back to a plain lerp when the vectors are nearly parallel.
    static func slerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        let d = max(-1, min(1, dot(a, b)))
        let theta = acosf(d)
        if theta < 1e-4 { return normalize(mix(a, b, t: t)) }
        let s = sinf(theta)
        return a * (sinf((1 - t) * theta) / s) + b * (sinf(t * theta) / s)
    }

    static func smoothstep(_ t: Float) -> Float {
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }
}
