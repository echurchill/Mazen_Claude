import simd

enum CameraMode {
    case orbit
    case firstPerson
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

    func viewProjectionMatrix(aspect: Float, player: PlayerState, cubeModel: CubeModel, sliceRotation: GameState.SliceRotation, worldSpin: float4x4) -> float4x4 {
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
            let (eye, forward, up) = firstPersonCamera(player: player, cubeModel: cubeModel, sliceRotation: sliceRotation, worldSpin: worldSpin)
            let view = float4x4.lookAt(eye: eye, target: eye + forward, up: up)
            return projection * view
        }
    }

    func cameraPosition(player: PlayerState, cubeModel: CubeModel, sliceRotation: GameState.SliceRotation, worldSpin: float4x4) -> SIMD3<Float> {
        switch mode {
        case .orbit:
            return SIMD3(0, 0, orbitDistanceOverride ?? cubeModel.worldScale.orbitDistance)
        case .firstPerson:
            let (eye, _, _) = firstPersonCamera(player: player, cubeModel: cubeModel, sliceRotation: sliceRotation, worldSpin: worldSpin)
            return eye
        }
    }

    private func firstPersonCamera(player: PlayerState, cubeModel: CubeModel, sliceRotation: GameState.SliceRotation, worldSpin: float4x4) -> (eye: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) {
        let eyeHeight = cubeModel.worldScale.eyeHeight
        let step = cubeModel.worldScale.subCellStep

        // World position of a standing spot's eye (tile center + sub-cell offset + height).
        func eye(_ f: CubeFace, _ r: Int, _ c: Int, _ sr: Int, _ sc: Int) -> SIMD3<Float> {
            let m = cubeModel.worldMatrix(face: f, row: r, col: c)
            let center = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            let spot = center + f.tangent * (Float(sc - 1) * step) + f.bitangent * (Float(sr - 1) * step)
            return spot + f.normal * eyeHeight
        }

        let fromFace = player.isMoving ? player.moveFromFace : player.face
        var eyePos = player.isMoving
            ? eye(player.moveFromFace, player.moveFromRow, player.moveFromCol, player.moveFromSubRow, player.moveFromSubCol)
            : eye(player.face, player.row, player.col, player.subRow, player.subCol)
        var upDir = fromFace.normal

        if player.isMoving {
            let toEye = eye(player.moveToFace, player.moveToRow, player.moveToCol, player.moveToSubRow, player.moveToSubCol)
            let t = Self.smoothstep(player.moveProgress)
            if player.moveFromFace != player.moveToFace {
                // Round the corner along the sphere instead of chording straight
                // through it: slerp the eye *direction* around the shared cube edge and
                // interpolate the radius separately. A plain mix()+renormalize cuts
                // inside the corner — very visible at the low first-person eye height.
                let radius = length(eyePos) * (1 - t) + length(toEye) * t
                eyePos = Self.slerp(normalize(eyePos), normalize(toEye), t: t) * radius
                upDir = Self.slerp(fromFace.normal, player.moveToFace.normal, t: t)
            } else {
                eyePos = mix(eyePos, toEye, t: t)
            }
        }

        var facingWorld: SIMD3<Float>
        if player.isMoving {
            let fromDir = Self.headingToWorld(player.facing, face: player.moveFromFace)
            let toDir = Self.headingToWorld(player.moveNewFacing, face: player.moveToFace)
            let t = Self.smoothstep(player.moveProgress)
            facingWorld = normalize(mix(fromDir, toDir, t: t))
        } else if player.isTurning {
            let fromDir = Self.headingToWorld(player.turnFromFacing, face: player.face)
            let toDir = Self.headingToWorld(player.turnToFacing, face: player.face)
            let t = Self.smoothstep(player.turnProgress)
            facingWorld = normalize(mix(fromDir, toDir, t: t))
        } else {
            facingWorld = Self.headingToWorld(player.facing, face: player.face)
        }

        // Mouse look: yaw about the face up, then pitch about the view's right axis. Free-look
        // and mouselook render identically here; they differ only in whether a forward move
        // snaps `facing` to the look (handled in GameState.steerToLook).
        facingWorld = simd_quatf(angle: lookYaw, axis: upDir).act(facingWorld)
        let rightAxis = normalize(cross(facingWorld, upDir))
        facingWorld = normalize(simd_quatf(angle: lookPitch, axis: rightAxis).act(facingWorld))

        if sliceRotation.isActive && sliceRotation.playerCubieIndex >= 0 && sliceRotation.affectedCubies.contains(sliceRotation.playerCubieIndex) {
            let axisVec: SIMD3<Float> = sliceRotation.axis == 0 ? SIMD3(1,0,0) : sliceRotation.axis == 1 ? SIMD3(0,1,0) : SIMD3(0,0,1)
            let t = Self.smoothstep(sliceRotation.progress)
            let currentAngle = sliceRotation.angle * t
            let rotQ = simd_quatf(angle: currentAngle, axis: axisVec)
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

        return (eyePos, facingWorld, upDir)
    }

    func cameraUp(player: PlayerState, cubeModel: CubeModel, sliceRotation: GameState.SliceRotation, worldSpin: float4x4) -> SIMD3<Float> {
        switch mode {
        case .orbit:
            return SIMD3(0, 1, 0)
        case .firstPerson:
            let (_, _, up) = firstPersonCamera(player: player, cubeModel: cubeModel, sliceRotation: sliceRotation, worldSpin: worldSpin)
            return up
        }
    }

    // MARK: - Helpers

    /// World-space direction a heading points, in a face's local (tangent, bitangent) plane.
    static func headingToWorld(_ h: Heading8, face: CubeFace) -> SIMD3<Float> {
        let tb = h.tangentBitangent
        return normalize(face.tangent * tb.t + face.bitangent * tb.b)
    }

    /// Nearest 8-way heading for a world-space direction on a face (inverse of the above).
    static func worldToHeading8(_ dir: SIMD3<Float>, face: CubeFace) -> Heading8 {
        let t = dot(dir, face.tangent)
        let b = dot(dir, face.bitangent)
        let angle = atan2f(t, -b)  // 0 = north (−bitangent)
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
