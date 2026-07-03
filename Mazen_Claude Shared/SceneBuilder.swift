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

    /// Per-kind prop colours (M10 Phase G). Props render via materialID 10 — the shader's
    /// generic lit + shadow-receiving branch — so the look is entirely this base colour.
    static let propColors: [PropKind: SIMD4<Float>] = [
        .topiary:     SIMD4(0.28, 0.52, 0.26, 1.0),  // deep hedge green
        .obelisk:     SIMD4(0.62, 0.60, 0.55, 1.0),  // pale stone
        .chest:       SIMD4(0.55, 0.36, 0.18, 1.0),  // wood
        .houseCorner: SIMD4(0.72, 0.66, 0.52, 1.0),  // warm plaster
    ]

    // Reusable scratch buffers (kept across frames to avoid per-frame allocation).
    private var opaqueFogTiles: [TileEntry] = []
    private var dissolveTiles: [TileEntry] = []
    private var frameTiles: [TileEntry] = []
    private var mazeFloorTiles: [UInt8: [TileEntry]] = [:]
    private var mazePathFloorTiles: [UInt8: [TileEntry]] = [:]
    private var mazeWallTiles: [UInt8: [TileEntry]] = [:]
    private var mazePostTiles: [UInt8: [TileEntry]] = [:]
    private var mazePropTiles: [UInt8: [TileEntry]] = [:]

    func build(gameState: GameState, tileMeshLib: TileMeshLibrary, instanceBuffer buf: MTLBuffer) -> SceneDrawData {
        let model = gameState.cubeModel
        let capacity = buf.length / MemoryLayout<InstanceDataSwift>.stride
        let ptr = buf.contents().bindMemory(to: InstanceDataSwift.self, capacity: capacity)

        opaqueFogTiles.removeAll(keepingCapacity: true)
        dissolveTiles.removeAll(keepingCapacity: true)
        frameTiles.removeAll(keepingCapacity: true)
        for key in mazeFloorTiles.keys { mazeFloorTiles[key]?.removeAll(keepingCapacity: true) }
        for key in mazePathFloorTiles.keys { mazePathFloorTiles[key]?.removeAll(keepingCapacity: true) }
        for key in mazeWallTiles.keys { mazeWallTiles[key]?.removeAll(keepingCapacity: true) }
        for key in mazePostTiles.keys { mazePostTiles[key]?.removeAll(keepingCapacity: true) }
        for key in mazePropTiles.keys { mazePropTiles[key]?.removeAll(keepingCapacity: true) }

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
                        let uvT = facelet.mazeTile.uvTurns
                        let key = (openings.rawValue & 0x0F) | (UInt8(((uvT % 4) + 4) % 4) << 4)
                        mazeFloorTiles[key, default: []].append(TileEntry(instance: mazeInst, mesh: tileMeshLib.floorMesh(for: openings, uvTurns: uvT)))
                        if let pfm = tileMeshLib.pathFloorMesh(for: openings, uvTurns: uvT) {
                            let pathInst = InstanceDataSwift(modelMatrix: matrix, baseColor: SIMD4(1, 1, 1, 1),
                                materialID: 9, tileID: UInt32(facelet.id.rawValue),
                                discoveryAmount: 1.0, styleSeed: facelet.mazeTile.styleSeed)
                            mazePathFloorTiles[key, default: []].append(TileEntry(instance: pathInst, mesh: pfm))
                        }
                        let cfg = facelet.mazeTile.edgeConfigKey
                        if let wm = tileMeshLib.wallMesh(configKey: cfg) {
                            mazeWallTiles[cfg, default: []].append(TileEntry(instance: mazeInst, mesh: wm))
                        }
                        if let pm = tileMeshLib.postMesh(configKey: cfg) {
                            let postInst = InstanceDataSwift(modelMatrix: matrix, baseColor: Self.postColor,
                                materialID: 8, tileID: UInt32(facelet.id.rawValue),
                                discoveryAmount: 1.0, styleSeed: facelet.mazeTile.styleSeed)
                            mazePostTiles[cfg, default: []].append(TileEntry(instance: postInst, mesh: pm))
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
                        let uvT = facelet.mazeTile.uvTurns
                        let key = (openings.rawValue & 0x0F) | (UInt8(((uvT % 4) + 4) % 4) << 4)
                        mazeFloorTiles[key, default: []].append(TileEntry(instance: inst, mesh: tileMeshLib.floorMesh(for: openings, uvTurns: uvT)))
                        if let pfm = tileMeshLib.pathFloorMesh(for: openings, uvTurns: uvT) {
                            let pathInst = InstanceDataSwift(modelMatrix: matrix, baseColor: SIMD4(1, 1, 1, 1),
                                materialID: 9, tileID: UInt32(facelet.id.rawValue),
                                discoveryAmount: 1.0, styleSeed: facelet.mazeTile.styleSeed)
                            mazePathFloorTiles[key, default: []].append(TileEntry(instance: pathInst, mesh: pfm))
                        }
                        let cfg = facelet.mazeTile.edgeConfigKey
                        if let wm = tileMeshLib.wallMesh(configKey: cfg) {
                            mazeWallTiles[cfg, default: []].append(TileEntry(instance: inst, mesh: wm))
                        }
                        if let pm = tileMeshLib.postMesh(configKey: cfg) {
                            let postInst = InstanceDataSwift(modelMatrix: matrix, baseColor: Self.postColor,
                                materialID: 8, tileID: UInt32(facelet.id.rawValue),
                                discoveryAmount: 1.0, styleSeed: facelet.mazeTile.styleSeed)
                            mazePostTiles[cfg, default: []].append(TileEntry(instance: postInst, mesh: pm))
                        }
                    }

                    // Props (M10 Phase G) — on revealed tiles only. `matrix` already
                    // carries the slice animation, so props ride rotations for free.
                    if facelet.tileState == .discovered {
                        let step = model.worldScale.subCellStep
                        for prop in facelet.props {
                            guard let mesh = tileMeshLib.propMesh(kind: prop.kind) else { continue }
                            let pm = matrix
                                * float4x4.translation(Float(prop.subCol - 1) * step, Float(prop.subRow - 1) * step, 0)
                                * float4x4.rotation(radians: Float(prop.facing.rawValue) * (.pi / 4), axis: SIMD3(0, 0, 1))
                            var color = Self.propColors[prop.kind] ?? SIMD4(0.6, 0.6, 0.6, 1.0)
                            if prop.kind == .chest && prop.state == 1 { color = SIMD4(0.98, 0.80, 0.30, 1.0) }  // opened / "lit"
                            let inst = InstanceDataSwift(modelMatrix: pm, baseColor: color,
                                materialID: 10, tileID: 0, discoveryAmount: 1.0, styleSeed: 0)
                            mazePropTiles[prop.kind.rawValue, default: []].append(TileEntry(instance: inst, mesh: mesh))
                        }
                    }
                }
            }
        }

        // Player marker (orbit mode only)
        if gameState.camera.mode == .orbit {
            let player = gameState.player
            var pMatrix = model.worldMatrix(face: player.face, row: player.row, col: player.col)
            if let animMat = sliceAnimMatrix, sr.playerCubieIndex >= 0, sr.affectedCubies.contains(sr.playerCubieIndex) {
                pMatrix = animMat * pMatrix
            }
            // Offset to the standing sub-cell, rotate to the 8-way heading, shrink to fit.
            let step = model.worldScale.subCellStep
            let localX = Float(player.subCol - 1) * step
            let localY = Float(player.subRow - 1) * step
            let tb = player.facing.tangentBitangent
            let facingAngle = atan2f(-tb.t, tb.b)
            pMatrix = pMatrix
                * float4x4.translation(localX, localY, 0)
                * float4x4.rotation(radians: facingAngle, axis: SIMD3(0, 0, 1))
                * float4x4.scale(0.6)
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

        // Opaque path-cross floor tiles (paved material) — coplanar with, but disjoint
        // from, the propSpace floor cells, so no depth conflict.
        for (_, entries) in mazePathFloorTiles {
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

        // Opaque props (M10 Phase G) — solid-colour, cast + receive shadows
        for (_, entries) in mazePropTiles {
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
        let floorMesh = tileMeshLib.floorMesh(for: openings, uvTurns: 0)
        ptr[idx] = inst
        idx += 1
        opaqueDrawCalls.append(DrawCall(
            indexOffset: floorMesh.indexOffset,
            indexCount: floorMesh.indexCount,
            instanceOffset: 0,
            instanceCount: 1
        ))

        // Walls
        if let wallMesh = tileMeshLib.wallMesh(configKey: MazeTile(openings: openings, styleSeed: 0).edgeConfigKey) {
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
