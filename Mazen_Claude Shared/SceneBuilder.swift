import Metal
import simd

/// One tile's instance data paired with the mesh it should be drawn with.
struct TileEntry {
    var instance: InstanceDataSwift
    var mesh: TileMesh
}

/// The per-frame draw-call lists produced from a world's state.
struct SceneDrawData {
    var opaque: [DrawCall]
    var translucent: [DrawCall]
    /// Sub-range of `opaque` that holds the maze walls (kept for callers that want to
    /// treat walls specially, e.g. depth bias). Currently informational.
    var wallRange: Range<Int>
}

/// Turns a `GameState` (its cube model, player, and slice-rotation state) into packed
/// GPU instance data + draw calls. Pulled out of `Renderer` so celestial bodies (M9)
/// and sub-tile / prop geometry (M10) can be added here in focused code rather than
/// threaded through the renderer's Metal setup.
///
/// `build` takes the `GameState` (hence the `CubeModel` and its `WorldScale`) and the
/// `TileMeshLibrary` as parameters — it never reaches for a global world, so a second
/// world (the M11 moon) is rendered simply by calling it with that world's state.
final class SceneBuilder {

    static let faceColors: [CubeFace: SIMD4<Float>] = [
        .positiveX: SIMD4(0.85, 0.75, 0.70, 1.0),
        .negativeX: SIMD4(0.70, 0.80, 0.85, 1.0),
        .positiveY: SIMD4(0.80, 0.85, 0.70, 1.0),
        .negativeY: SIMD4(0.85, 0.80, 0.65, 1.0),
        .positiveZ: SIMD4(0.80, 0.75, 0.85, 1.0),
        .negativeZ: SIMD4(0.75, 0.85, 0.80, 1.0),
    ]

    /// Light green for corner / jamb posts (M10 Phase B), rendered via materialID 8.
    static let postColor = SIMD4<Float>(0.55, 0.82, 0.42, 1.0)

    // Reusable scratch buffers (kept across frames to avoid per-frame allocation).
    private var opaqueFogTiles: [TileEntry] = []
    private var dissolveTiles: [TileEntry] = []
    private var frameTiles: [TileEntry] = []
    private var mazeFloorTiles: [UInt8: [TileEntry]] = [:]
    private var mazeWallTiles: [UInt8: [TileEntry]] = [:]
    private var mazePostTiles: [UInt8: [TileEntry]] = [:]

    func build(gameState: GameState, tileMeshLib: TileMeshLibrary, instanceBuffer buf: MTLBuffer) -> SceneDrawData {
        let model = gameState.cubeModel
        let ptr = buf.contents().bindMemory(to: InstanceDataSwift.self, capacity: 6 * model.size * model.size)

        opaqueFogTiles.removeAll(keepingCapacity: true)
        dissolveTiles.removeAll(keepingCapacity: true)
        frameTiles.removeAll(keepingCapacity: true)
        for key in mazeFloorTiles.keys { mazeFloorTiles[key]?.removeAll(keepingCapacity: true) }
        for key in mazeWallTiles.keys { mazeWallTiles[key]?.removeAll(keepingCapacity: true) }
        for key in mazePostTiles.keys { mazePostTiles[key]?.removeAll(keepingCapacity: true) }

        // Precompute slice rotation matrix if active
        var sliceAnimMatrix: float4x4?
        let sr = gameState.sliceRotation
        if sr.isActive {
            let axisVec: SIMD3<Float> = sr.axis == 0 ? SIMD3(1,0,0) : sr.axis == 1 ? SIMD3(0,1,0) : SIMD3(0,0,1)
            let t = sr.progress * sr.progress * (3 - 2 * sr.progress)
            let currentAngle = sr.angle * t
            sliceAnimMatrix = float4x4.rotation(radians: currentAngle, axis: axisVec)
        }

        for face in CubeFace.allCases {
            for row in 0..<model.size {
                for col in 0..<model.size {
                    var matrix = model.worldMatrix(face: face, row: row, col: col)

                    guard let (ci, fi) = model.faceletAt(face: face, row: row, col: col) else { continue }
                    let facelet = model.cubies[ci].facelets[fi]

                    if let animMat = sliceAnimMatrix, sr.affectedCubies.contains(ci) {
                        matrix = animMat * matrix
                    }

                    let faceColor = Self.faceColors[face]!

                    // Frame rail for every tile
                    let frameInst = InstanceDataSwift(
                        modelMatrix: matrix,
                        baseColor: SIMD4(0.06, 0.06, 0.08, 1.0),
                        materialID: 7,
                        tileID: 0,
                        discoveryAmount: 1.0,
                        styleSeed: 0
                    )
                    frameTiles.append(TileEntry(instance: frameInst, mesh: tileMeshLib.frameMesh))

                    switch facelet.tileState {
                    case .unknown:
                        let inst = InstanceDataSwift(
                            modelMatrix: matrix,
                            baseColor: faceColor * 0.9,
                            materialID: 4,
                            tileID: UInt32(facelet.id.rawValue),
                            discoveryAmount: facelet.discoveryAmount,
                            styleSeed: facelet.mazeTile.styleSeed
                        )
                        opaqueFogTiles.append(TileEntry(instance: inst, mesh: tileMeshLib.fogLayers[0]))

                    case .adjacent:
                        let openings = facelet.mazeTile.openings
                        let pathColor = SIMD4<Float>(0.72, 0.62, 0.45, 1.0)
                        let mazeInst = InstanceDataSwift(
                            modelMatrix: matrix,
                            baseColor: pathColor,
                            materialID: 1,
                            tileID: UInt32(facelet.id.rawValue),
                            discoveryAmount: 1.0,
                            styleSeed: facelet.mazeTile.styleSeed
                        )
                        let key = openings.rawValue & 0x0F
                        mazeFloorTiles[key, default: []].append(TileEntry(instance: mazeInst, mesh: tileMeshLib.floorMesh(for: openings)))
                        if let wm = tileMeshLib.wallMesh(for: openings) {
                            mazeWallTiles[key, default: []].append(TileEntry(instance: mazeInst, mesh: wm))
                        }
                        if let pm = tileMeshLib.postMesh(for: openings) {
                            let postInst = InstanceDataSwift(modelMatrix: matrix, baseColor: Self.postColor,
                                materialID: 8, tileID: UInt32(facelet.id.rawValue),
                                discoveryAmount: 1.0, styleSeed: facelet.mazeTile.styleSeed)
                            mazePostTiles[key, default: []].append(TileEntry(instance: postInst, mesh: pm))
                        }

                        let fogInst = InstanceDataSwift(
                            modelMatrix: matrix,
                            baseColor: faceColor * 0.9,
                            materialID: 5,
                            tileID: UInt32(facelet.id.rawValue),
                            discoveryAmount: facelet.discoveryAmount,
                            styleSeed: facelet.mazeTile.styleSeed
                        )
                        for layer in tileMeshLib.fogLayers {
                            dissolveTiles.append(TileEntry(instance: fogInst, mesh: layer))
                        }

                    case .discovered:
                        let openings = facelet.mazeTile.openings
                        let pathColor = SIMD4<Float>(0.72, 0.62, 0.45, 1.0)
                        let inst = InstanceDataSwift(
                            modelMatrix: matrix,
                            baseColor: pathColor,
                            materialID: 1,
                            tileID: UInt32(facelet.id.rawValue),
                            discoveryAmount: 1.0,
                            styleSeed: facelet.mazeTile.styleSeed
                        )
                        let key = openings.rawValue & 0x0F
                        mazeFloorTiles[key, default: []].append(TileEntry(instance: inst, mesh: tileMeshLib.floorMesh(for: openings)))
                        if let wm = tileMeshLib.wallMesh(for: openings) {
                            mazeWallTiles[key, default: []].append(TileEntry(instance: inst, mesh: wm))
                        }
                        if let pm = tileMeshLib.postMesh(for: openings) {
                            let postInst = InstanceDataSwift(modelMatrix: matrix, baseColor: Self.postColor,
                                materialID: 8, tileID: UInt32(facelet.id.rawValue),
                                discoveryAmount: 1.0, styleSeed: facelet.mazeTile.styleSeed)
                            mazePostTiles[key, default: []].append(TileEntry(instance: postInst, mesh: pm))
                        }
                    }
                }
            }
        }

        // Player marker (orbit mode only)
        if gameState.camera.mode == .orbit {
            var pMatrix = model.worldMatrix(face: gameState.player.face, row: gameState.player.row, col: gameState.player.col)
            if let animMat = sliceAnimMatrix, sr.playerCubieIndex >= 0, sr.affectedCubies.contains(sr.playerCubieIndex) {
                pMatrix = animMat * pMatrix
            }
            let facingAngle: Float = {
                switch gameState.player.facing {
                case .north: return .pi
                case .west:  return .pi / 2
                case .south: return 0
                case .east:  return -.pi / 2
                }
            }()
            let localRot = float4x4.rotation(radians: facingAngle, axis: SIMD3(0, 0, 1))
            pMatrix = pMatrix * localRot
            let markerInst = InstanceDataSwift(
                modelMatrix: pMatrix,
                baseColor: SIMD4(1.0, 0.2, 0.1, 1.0),
                materialID: 6,
                tileID: 0,
                discoveryAmount: 1.0,
                styleSeed: 0
            )
            opaqueFogTiles.append(TileEntry(instance: markerInst, mesh: tileMeshLib.playerMarker))
        }

        // Pack instances — opaque first, then translucent
        var idx = 0
        var opaqueDrawCalls: [DrawCall] = []
        var translucentDrawCalls: [DrawCall] = []

        // Cubie frame rails
        if !frameTiles.isEmpty {
            let mesh = frameTiles[0].mesh
            let startIdx = idx
            for entry in frameTiles {
                ptr[idx] = entry.instance
                idx += 1
            }
            opaqueDrawCalls.append(DrawCall(
                indexOffset: mesh.indexOffset,
                indexCount: mesh.indexCount,
                instanceOffset: startIdx,
                instanceCount: frameTiles.count
            ))
        }

        // Opaque maze floor tiles (no depth bias)
        for (_, entries) in mazeFloorTiles {
            guard !entries.isEmpty else { continue }
            let mesh = entries[0].mesh
            let startIdx = idx
            for entry in entries {
                ptr[idx] = entry.instance
                idx += 1
            }
            opaqueDrawCalls.append(DrawCall(
                indexOffset: mesh.indexOffset,
                indexCount: mesh.indexCount,
                instanceOffset: startIdx,
                instanceCount: entries.count
            ))
        }

        // Opaque maze wall tiles (rendered with depth bias)
        let wallDrawCallStart = opaqueDrawCalls.count
        for (_, entries) in mazeWallTiles {
            guard !entries.isEmpty else { continue }
            let mesh = entries[0].mesh
            let startIdx = idx
            for entry in entries {
                ptr[idx] = entry.instance
                idx += 1
            }
            opaqueDrawCalls.append(DrawCall(
                indexOffset: mesh.indexOffset,
                indexCount: mesh.indexCount,
                instanceOffset: startIdx,
                instanceCount: entries.count
            ))
        }
        let wallRange = wallDrawCallStart..<opaqueDrawCalls.count

        // Opaque corner / jamb posts (light-green material)
        for (_, entries) in mazePostTiles {
            guard !entries.isEmpty else { continue }
            let mesh = entries[0].mesh
            let startIdx = idx
            for entry in entries {
                ptr[idx] = entry.instance
                idx += 1
            }
            opaqueDrawCalls.append(DrawCall(
                indexOffset: mesh.indexOffset,
                indexCount: mesh.indexCount,
                instanceOffset: startIdx,
                instanceCount: entries.count
            ))
        }

        // Opaque fog base layer + player marker
        if !opaqueFogTiles.isEmpty {
            var byMesh: [Int: [TileEntry]] = [:]
            for entry in opaqueFogTiles {
                byMesh[entry.mesh.indexOffset, default: []].append(entry)
            }
            for (_, entries) in byMesh {
                let mesh = entries[0].mesh
                let startIdx = idx
                for entry in entries {
                    ptr[idx] = entry.instance
                    idx += 1
                }
                opaqueDrawCalls.append(DrawCall(
                    indexOffset: mesh.indexOffset,
                    indexCount: mesh.indexCount,
                    instanceOffset: startIdx,
                    instanceCount: entries.count
                ))
            }
        }

        // Translucent fog upper layers + dissolve fog
        if !dissolveTiles.isEmpty {
            var byMesh: [Int: [TileEntry]] = [:]
            for entry in dissolveTiles {
                byMesh[entry.mesh.indexOffset, default: []].append(entry)
            }
            for (_, entries) in byMesh {
                let mesh = entries[0].mesh
                let startIdx = idx
                for entry in entries {
                    ptr[idx] = entry.instance
                    idx += 1
                }
                translucentDrawCalls.append(DrawCall(
                    indexOffset: mesh.indexOffset,
                    indexCount: mesh.indexCount,
                    instanceOffset: startIdx,
                    instanceCount: entries.count
                ))
            }
        }

        return SceneDrawData(opaque: opaqueDrawCalls, translucent: translucentDrawCalls, wallRange: wallRange)
    }

    func buildSingleTile(tileMeshLib: TileMeshLibrary, instanceBuffer buf: MTLBuffer) -> SceneDrawData {
        let ptr = buf.contents().bindMemory(to: InstanceDataSwift.self, capacity: 4)

        var opaqueDrawCalls: [DrawCall] = []
        let translucentDrawCalls: [DrawCall] = []

        let identity = matrix_identity_float4x4
        let pathColor = SIMD4<Float>(0.72, 0.62, 0.45, 1.0)
        // Single north wall only (openings = east+south+west, so north is closed)
        let openings = DirectionMask([.east, .south, .west])

        let inst = InstanceDataSwift(
            modelMatrix: identity,
            baseColor: pathColor,
            materialID: 1,
            tileID: 0,
            discoveryAmount: 1.0,
            styleSeed: 42
        )

        var idx = 0

        // Floor
        let floorMesh = tileMeshLib.floorMesh(for: openings)
        ptr[idx] = inst
        idx += 1
        opaqueDrawCalls.append(DrawCall(
            indexOffset: floorMesh.indexOffset,
            indexCount: floorMesh.indexCount,
            instanceOffset: 0,
            instanceCount: 1
        ))

        // Walls
        if let wallMesh = tileMeshLib.wallMesh(for: openings) {
            ptr[idx] = inst
            idx += 1
            opaqueDrawCalls.append(DrawCall(
                indexOffset: wallMesh.indexOffset,
                indexCount: wallMesh.indexCount,
                instanceOffset: 1,
                instanceCount: 1
            ))
        }

        return SceneDrawData(opaque: opaqueDrawCalls, translucent: translucentDrawCalls, wallRange: 0..<0)
    }
}
