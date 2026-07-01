import simd

enum CameraMode {
    case orbit
    case firstPerson
}

struct CameraState {
    var mode: CameraMode = .orbit
    var orbitRotation: SIMD2<Float> = SIMD2(0.45, 0.5)
    var orbitDistance: Float = 5.0
    var orbitAutoRotate: Bool = true

    mutating func updateOrbit(deltaTime: Float) {
        if mode == .orbit && orbitAutoRotate {
            orbitRotation.x += deltaTime * 0.15
        }
    }

    func viewProjectionMatrix(aspect: Float, player: PlayerState, cubeModel: CubeModel, sliceRotation: GameState.SliceRotation) -> float4x4 {
        let projection = float4x4.perspective(
            fovYRadians: (70.0 / 180.0) * .pi,
            aspect: aspect,
            nearZ: 0.01,
            farZ: 100.0
        )

        switch mode {
        case .orbit:
            let rotX = float4x4.rotation(radians: orbitRotation.y, axis: SIMD3(1, 0, 0))
            let rotY = float4x4.rotation(radians: orbitRotation.x, axis: SIMD3(0, 1, 0))
            let translate = float4x4.translation(0, 0, -orbitDistance)
            return projection * translate * rotX * rotY

        case .firstPerson:
            let (eye, forward, up) = firstPersonCamera(player: player, cubeModel: cubeModel, sliceRotation: sliceRotation)
            let view = float4x4.lookAt(eye: eye, target: eye + forward, up: up)
            return projection * view
        }
    }

    func cameraPosition(player: PlayerState, cubeModel: CubeModel, sliceRotation: GameState.SliceRotation) -> SIMD3<Float> {
        switch mode {
        case .orbit:
            return SIMD3(0, 0, orbitDistance)
        case .firstPerson:
            let (eye, _, _) = firstPersonCamera(player: player, cubeModel: cubeModel, sliceRotation: sliceRotation)
            return eye
        }
    }

    private func firstPersonCamera(player: PlayerState, cubeModel: CubeModel, sliceRotation: GameState.SliceRotation) -> (eye: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) {
        let eyeHeight: Float = 0.45

        let face: CubeFace
        let row: Int
        let col: Int

        if player.isMoving {
            face = player.moveFromFace
            row = player.moveFromRow
            col = player.moveFromCol
        } else {
            face = player.face
            row = player.row
            col = player.col
        }

        let tileMatrix = cubeModel.worldMatrix(face: face, row: row, col: col)
        let tileCenter = SIMD3<Float>(tileMatrix.columns.3.x, tileMatrix.columns.3.y, tileMatrix.columns.3.z)
        let faceNormal = face.normal
        let faceTangent = face.tangent
        let faceBitangent = face.bitangent

        var eyePos = tileCenter + faceNormal * eyeHeight
        var upDir = faceNormal

        if player.isMoving {
            let toMatrix = cubeModel.worldMatrix(face: player.moveToFace, row: player.moveToRow, col: player.moveToCol)
            let toCenter = SIMD3<Float>(toMatrix.columns.3.x, toMatrix.columns.3.y, toMatrix.columns.3.z)
            let toEye = toCenter + player.moveToFace.normal * eyeHeight
            let t = Self.smoothstep(player.moveProgress)
            if player.moveFromFace != player.moveToFace {
                eyePos = normalize(mix(eyePos, toEye, t: t)) * length(eyePos) * (1 - t) + normalize(mix(eyePos, toEye, t: t)) * length(toEye) * t
                upDir = normalize(mix(faceNormal, player.moveToFace.normal, t: t))
            } else {
                eyePos = mix(eyePos, toEye, t: t)
            }
        }

        var facingWorld: SIMD3<Float>
        if player.isMoving && player.moveFromFace != player.moveToFace {
            let fromDir = Self.directionToWorld(player.facing, face: face, tangent: faceTangent, bitangent: faceBitangent)
            let toTangent = player.moveToFace.tangent
            let toBitangent = player.moveToFace.bitangent
            let toDir = Self.directionToWorld(player.moveNewFacing, face: player.moveToFace, tangent: toTangent, bitangent: toBitangent)
            let t = Self.smoothstep(player.moveProgress)
            facingWorld = normalize(mix(fromDir, toDir, t: t))
        } else {
            facingWorld = Self.directionToWorld(player.facing, face: face, tangent: faceTangent, bitangent: faceBitangent)
        }

        if player.isTurning {
            let fromWorld = Self.directionToWorld(player.turnFromFacing, face: face, tangent: faceTangent, bitangent: faceBitangent)
            let toWorld = Self.directionToWorld(player.turnToFacing, face: face, tangent: faceTangent, bitangent: faceBitangent)
            let t = Self.smoothstep(player.turnProgress)
            facingWorld = normalize(mix(fromWorld, toWorld, t: t))
        }

        let pitchAngle: Float = -0.05
        facingWorld = normalize(facingWorld + upDir * pitchAngle)

        if sliceRotation.isActive && sliceRotation.playerCubieIndex >= 0 && sliceRotation.affectedCubies.contains(sliceRotation.playerCubieIndex) {
            let axisVec: SIMD3<Float> = sliceRotation.axis == 0 ? SIMD3(1,0,0) : sliceRotation.axis == 1 ? SIMD3(0,1,0) : SIMD3(0,0,1)
            let t = Self.smoothstep(sliceRotation.progress)
            let currentAngle = sliceRotation.angle * t
            let rotQ = simd_quatf(angle: currentAngle, axis: axisVec)
            eyePos = rotQ.act(eyePos)
            facingWorld = rotQ.act(facingWorld)
            upDir = rotQ.act(upDir)
        }

        return (eyePos, facingWorld, upDir)
    }

    func cameraUp(player: PlayerState, cubeModel: CubeModel, sliceRotation: GameState.SliceRotation) -> SIMD3<Float> {
        switch mode {
        case .orbit:
            return SIMD3(0, 1, 0)
        case .firstPerson:
            let (_, _, up) = firstPersonCamera(player: player, cubeModel: cubeModel, sliceRotation: sliceRotation)
            return up
        }
    }

    // MARK: - Helpers

    static func directionToWorld(_ dir: SurfaceDirection, face: CubeFace, tangent: SIMD3<Float>, bitangent: SIMD3<Float>) -> SIMD3<Float> {
        switch dir {
        case .north: return -bitangent
        case .south: return bitangent
        case .east:  return tangent
        case .west:  return -tangent
        }
    }

    static func smoothstep(_ t: Float) -> Float {
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }
}
