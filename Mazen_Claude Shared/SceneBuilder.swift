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

    /// Per-face fog tint. A total switch (R2.13) — no dictionary lookup + force-unwrap in the
    /// per-tile hot loop.
    static func faceColor(_ face: CubeFace) -> SIMD4<Float> {
        switch face {
        case .positiveX: return SIMD4(0.85, 0.75, 0.70, 1.0)
        case .negativeX: return SIMD4(0.70, 0.80, 0.85, 1.0)
        case .positiveY: return SIMD4(0.80, 0.85, 0.70, 1.0)
        case .negativeY: return SIMD4(0.85, 0.80, 0.65, 1.0)
        case .positiveZ: return SIMD4(0.80, 0.75, 0.85, 1.0)
        case .negativeZ: return SIMD4(0.75, 0.85, 0.80, 1.0)
        }
    }

    /// Light green for corner / jamb posts (M10 Phase B), rendered via materialID 8.
    static let postColor = SIMD4<Float>(0.55, 0.82, 0.42, 1.0)

    /// Per-kind prop colours (M10 Phase G). Props render via materialID 10 — the shader's
    /// generic lit + shadow-receiving branch — so the look is entirely this base colour.
    static let propColors: [PropKind: SIMD4<Float>] = [
        .topiary:     SIMD4(0.28, 0.52, 0.26, 1.0),  // deep hedge green
        .obelisk:     SIMD4(0.62, 0.60, 0.55, 1.0),  // pale stone
        .chest:       SIMD4(0.55, 0.36, 0.18, 1.0),  // wood
        .houseCorner: SIMD4(0.50, 0.45, 0.44, 1.0),  // roof grey (walls are imported tan kit; M12-E)
        .portal:      SIMD4(0.11, 0.20, 0.52, 1.0),  // TARDIS police-box blue (M11.2 world portal)
        .portalLamp:  SIMD4(1.0, 1.0, 1.0, 1.0),     // overridden per-frame by the blink (below)
        .dial:        SIMD4(0.52, 0.52, 0.58, 1.0),  // M16.3 — overridden by state below
        .glyph:       SIMD4(0.68, 0.65, 0.59, 1.0),  // M16.5 — carved stone (lock livery may gild it)
        .plinth:      SIMD4(1.0, 1.0, 1.0, 1.0),     // M16.6 — material 21 does the colouring itself
        .tree:        SIMD4(0.20, 0.44, 0.22, 1.0),  // M19 — conifer green
        .treeTrunk:   SIMD4(0.34, 0.24, 0.15, 1.0),  // M19 — bark brown
        .boulder:     SIMD4(0.44, 0.44, 0.47, 1.0),  // M19 — moon rock grey
        .foliageCard: SIMD4(0.26, 0.46, 0.22, 1.0),  // M20 — leafy green (alpha-cutout card)
    ]

    // Reusable scratch buffers (kept across frames to avoid per-frame allocation).
    private var opaqueFogTiles: [TileEntry] = []
    private var dissolveTiles: [TileEntry] = []
    private var frameTiles: [TileEntry] = []
    private var celestialTiles: [TileEntry] = []
    private var mazeFloorTiles: [UInt8: [TileEntry]] = [:]
    private var mazePathFloorTiles: [UInt8: [TileEntry]] = [:]
    private var mazeWallTiles: [UInt8: [TileEntry]] = [:]
    private var mazePostTiles: [UInt8: [TileEntry]] = [:]
    private var mazePropTiles: [UInt8: [TileEntry]] = [:]
    private var fieldTiles: [TileEntry] = []   // M19: natural-register ground (grass/water), one shared mesh

    /// `worldOffset` pushes the entire built world by an extra transform — used (M11) to hang a
    /// *counterpart* world (the overworld) out in the sky of the world you're standing in, at an
    /// orbital position/scale. `includeCelestials` is false for that counterpart so it doesn't drag
    /// its own tiny sun/moon along. Both default to the identity/normal single-world render.
    func build(gameState: GameState, tileMeshLib: TileMeshLibrary, instanceBuffer buf: MTLBuffer,
               worldOffset: float4x4 = matrix_identity_float4x4, includeCelestials: Bool = true,
               includeMoon: Bool = true, sunOverride: SIMD3<Float>? = nil) -> SceneDrawData {
        let model = gameState.cubeModel
        // Fold the offset into the spin so every tile/wall/prop/player-marker matrix (all built as
        // `spin * …`) is pushed out together — one injection point for the whole world.
        let spin = worldOffset * gameState.worldSpinMatrix()   // M9.5-3 idle cube spin (+ M11 world offset)
        let capacity = buf.length / MemoryLayout<InstanceDataSwift>.stride
        let ptr = buf.contents().bindMemory(to: InstanceDataSwift.self, capacity: capacity)

        opaqueFogTiles.removeAll(keepingCapacity: true)
        dissolveTiles.removeAll(keepingCapacity: true)
        frameTiles.removeAll(keepingCapacity: true)
        celestialTiles.removeAll(keepingCapacity: true)
        for key in mazeFloorTiles.keys { mazeFloorTiles[key]?.removeAll(keepingCapacity: true) }
        for key in mazePathFloorTiles.keys { mazePathFloorTiles[key]?.removeAll(keepingCapacity: true) }
        for key in mazeWallTiles.keys { mazeWallTiles[key]?.removeAll(keepingCapacity: true) }
        for key in mazePostTiles.keys { mazePostTiles[key]?.removeAll(keepingCapacity: true) }
        for key in mazePropTiles.keys { mazePropTiles[key]?.removeAll(keepingCapacity: true) }
        fieldTiles.removeAll(keepingCapacity: true)

        // Precompute the in-flight twist matrix if active (single source: SliceRotation, R2.3)
        let sr = gameState.sliceRotation
        let sliceAnimMatrix: float4x4? = sr.isActive ? sr.currentMatrix : nil
        // M16.2: while a refused twist strains, the LOCKED structure flares — a red pulse on the
        // bonded tiles' props (the Player Journey's "glow tracing the structure" image).
        let refusalGlow: Float = (sr.isActive && sr.isRefusal) ? sinf(sr.progress * .pi) : 0

        for face in CubeFace.allCases {
            for row in 0..<model.size {
                for col in 0..<model.size {
                    // M14b: the maze surface (floors/walls/posts/frame/props) inflates per-vertex in
                    // the shader from the *un-spun rest* placement + per-instance spin/roundness.
                    // `matrix` — a rigid seat ON the curved surface at the tile centre — anchors only
                    // the translucent fog layers (R2.1: via inflatedPlacement, not the old per-tile-
                    // inflated worldMatrix).
                    var matrix = model.inflatedPlacement(face: face, row: row, col: col, localX: 0, localY: 0)

                    guard let (ci, fi) = model.faceletAt(face: face, row: row, col: col) else { continue }
                    let facelet = model.cubies[ci].facelets[fi]

                    var restM = model.restMatrix(face: face, row: row, col: col)
                    if let animMat = sliceAnimMatrix, sr.affectedCubies.contains(ci) {
                        matrix = animMat * matrix
                        restM = animMat * restM
                    }
                    matrix = spin * matrix
                    let roundness = model.roundness
                    let relief = model.reliefAmplitude
                    let invHalf: Float = 1.0 / model.worldScale.faceDistance

                    let faceColor = Self.faceColor(face)

                    // Frame rail — the dark cubie-border grid. Only on the engineered maze worlds;
                    // a natural planet (grass/water/regolith) has no visible cube frame, so skip it
                    // there — otherwise the dark rails read as black strips on the ground (Eddie,
                    // M19), the more so as relief lifts them. Also skipped for a natural-dressed
                    // maze (the M20 garden — a hedge maze on a green planet).
                    if facelet.terrain == .maze && !model.naturalDressing {
                        let frameInst = InstanceDataSwift(
                            modelMatrix: restM,
                            baseColor: SIMD4(0.06, 0.06, 0.08, 1.0),
                            materialID: 7,
                            tileID: 0,
                            discoveryAmount: 1.0,
                            styleSeed: 0,
                            spinMatrix: spin, roundness: roundness, invHalfExtent: invHalf, reliefAmplitude: relief
                        )
                        frameTiles.append(TileEntry(instance: frameInst, mesh: tileMeshLib.frameMesh))
                    }

                    switch facelet.tileState {
                    case .unknown:
                        // M20: a no-fog world (gallery) simply doesn't draw the unexplored tiles —
                        // no fog wall, just open sky beyond the revealed area.
                        if model.noFog { break }
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
                        // Revealed maze geometry + the dissolve fog that is still burning off it.
                        emitMazeTile(facelet, restM: restM, spin: spin,
                                     roundness: roundness, invHalf: invHalf, relief: relief,
                                     naturalDressing: model.naturalDressing, tileMeshLib: tileMeshLib)
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
                        switch facelet.terrain {
                        case .maze:
                            emitMazeTile(facelet, restM: restM, spin: spin,
                                         roundness: roundness, invHalf: invHalf, relief: relief,
                                         naturalDressing: model.naturalDressing, tileMeshLib: tileMeshLib)
                        case .grass, .water, .regolith:
                            // M19: a full-tile ground quad, no walls. Grass (14) / water (15) /
                            // regolith (16) share the fieldFloor mesh, so they batch into one draw.
                            let mat: UInt32 = facelet.terrain == .water ? 15 : (facelet.terrain == .regolith ? 16 : 14)
                            let fieldInst = InstanceDataSwift(modelMatrix: restM, baseColor: SIMD4(1, 1, 1, 1),
                                materialID: mat,
                                tileID: UInt32(facelet.id.rawValue), discoveryAmount: 1.0,
                                styleSeed: facelet.mazeTile.styleSeed,
                                spinMatrix: spin, roundness: roundness, invHalfExtent: invHalf, reliefAmplitude: relief)
                            fieldTiles.append(TileEntry(instance: fieldInst, mesh: tileMeshLib.fieldFloor))
                        }
                    }

                    // Props (M10 Phase G) — on revealed tiles only. Built on the *rest* matrix and
                    // inflated per-vertex (M14b Phase 2.5): the prop's footprint projects onto the
                    // curved floor and it stands up along the local normal, so it no longer pokes
                    // through / floats above the curve. `restM` already carries the slice animation.
                    if facelet.tileState == .discovered {
                        let step = model.worldScale.subCellStep
                        for prop in facelet.props {
                            guard let mesh = tileMeshLib.propMesh(kind: prop.kind) else { continue }
                            // M19: trees & boulders vary in size by `state` (0/1/2 = small/med/large)
                            // AND a per-instance jitter, so a stand / rock field reads as many
                            // distinct objects, not three repeated sizes. Trunk matches its tree.
                            var treeScale: Float = 1.0
                            if prop.kind == .tree || prop.kind == .treeTrunk || prop.kind == .boulder
                                || prop.kind == .foliageCard || prop.kind == .greeneryCard || prop.kind == .treeBillboard {
                                var sj = UInt32(truncatingIfNeeded: facelet.id.rawValue) &* 40503 &+ UInt32(prop.subRow &* 7 &+ prop.subCol)
                                sj ^= sj >> 13
                                let jitter = 0.78 + 0.44 * Float(sj & 0xFFFF) / 65535.0   // ×0.78…1.22
                                // trees/boulders: `state` = size bucket. foliage/greenery/tree-sprite:
                                // `state` = texture slice (not size), so size is a per-kind base × jitter.
                                let sizeBase: Float
                                switch prop.kind {
                                case .foliageCard:  sizeBase = 0.95
                                case .greeneryCard: sizeBase = 0.6
                                case .treeBillboard: sizeBase = 1.0     // mesh is already tall
                                default:            sizeBase = [0.62, 0.95, 1.45][max(0, min(2, prop.state))]
                                }
                                treeScale = sizeBase * jitter
                            }
                            var pm = restM
                                * float4x4.translation(Float(prop.subCol - 1) * step, Float(prop.subRow - 1) * step, 0)
                                * float4x4.rotation(radians: Float(prop.facing.rawValue) * (.pi / 4) + prop.viewAngle * (.pi / 180), axis: SIMD3(0, 0, 1))
                                * float4x4.scale(treeScale)
                            if prop.kind == .alignmentCylinder {
                                // M16.6 Phase 2b — GROW: scale the drum's height about its base (the
                                // plinth top) by `anim`, so it rises from the disc rather than the floor.
                                let zBase = model.worldScale.floorY + TileMeshLibrary.plinthHeightM * (model.worldScale.eyeHeight / 1.7)
                                pm = pm * float4x4.translation(0, 0, zBase)
                                        * float4x4.scale(1, 1, max(0.001, prop.anim))
                                        * float4x4.translation(0, 0, -zBase)
                            }
                            var color = Self.propColors[prop.kind] ?? SIMD4(0.6, 0.6, 0.6, 1.0)
                            var materialID: UInt32 = 10
                            if model.bondedGroups.contains(where: { $0.contains(ci) }) {
                                // Locked-structure livery (M16.2, Eddie): golden yellow, so a lock
                                // is findable at a glance — and it flares red while a refused
                                // twist strains against it.
                                color = SIMD4(0.95, 0.78, 0.20, 1.0)
                                if refusalGlow > 0 { color = mix(color, SIMD4(1.0, 0.10, 0.06, 1.0), t: refusalGlow) }
                            }
                            if prop.kind == .portal, model.sealedPortalCubies.contains(ci) {
                                color = SIMD4(0.16, 0.17, 0.22, 1.0)   // M16.4: sealed — dark, inert
                            }
                            if prop.kind == .dial {
                                // M16.3: aligned dials wear the SAME gold as the locked temple —
                                // the colour rhyme is the clue that these four belong to the lock.
                                color = prop.state == 1 ? SIMD4(0.95, 0.78, 0.20, 1.0)
                                                        : SIMD4(0.52, 0.52, 0.58, 1.0)
                            }
                            if prop.kind == .chest && prop.state == 1 { color = SIMD4(0.98, 0.80, 0.30, 1.0) }  // opened / "lit"
                            if prop.kind == .tree {
                                // M19: vary each conifer's green (deep fir → sage) by a per-tile hash,
                                // so a stand reads as many trees, not one colour stamped everywhere.
                                var s = UInt32(truncatingIfNeeded: facelet.id.rawValue) &* 2654435761
                                s ^= s >> 15
                                let f = Float(s & 0xFFFF) / 65535.0
                                color = mix(SIMD4(0.13, 0.33, 0.15, 1.0), SIMD4(0.31, 0.53, 0.27, 1.0), t: f)
                            }
                            if prop.kind == .boulder {
                                // M19: vary each rock's grey (shadowed → sunlit) per the Apollo photos.
                                var s = UInt32(truncatingIfNeeded: facelet.id.rawValue) &* 2246822519
                                s ^= s >> 13
                                let g = 0.34 + 0.24 * Float(s & 0xFFFF) / 65535.0
                                color = SIMD4(g, g, g * 1.03, 1.0)
                            }
                            var propStyleSeed: UInt32 = 0
                            if prop.kind == .foliageCard {
                                // M20: alpha-cutout foliage material (17). `state` = the LeafSet slice
                                // (styleSeed → array slice in the shader); vary the green per bush.
                                materialID = 17
                                propStyleSeed = UInt32(max(0, prop.state))
                                var s = UInt32(truncatingIfNeeded: facelet.id.rawValue) &* 668265263
                                s ^= s >> 15
                                color = mix(SIMD4(0.18, 0.38, 0.16, 1.0), SIMD4(0.34, 0.55, 0.26, 1.0),
                                            t: Float(s & 0xFFFF) / 65535.0)
                            }
                            if prop.kind == .greeneryCard || prop.kind == .treeBillboard {
                                // M20: misc_greenery (18) / WenrexaTrees (19). `state` = array slice;
                                // full-colour sprites, so no tint.
                                materialID = prop.kind == .greeneryCard ? 18 : 19
                                propStyleSeed = UInt32(max(0, prop.state))
                                color = SIMD4(1, 1, 1, 1)
                            }
                            if prop.kind == .plinth {
                                // M16.6: the Builder plinth — material 21 reads stone/resin vs glyph
                                // from the mesh's UV flag; `state` selects the caustic symbol slice.
                                materialID = 21
                                propStyleSeed = UInt32(max(0, prop.state))
                                color = SIMD4(1, 1, 1, 1)
                            }
                            if prop.kind == .alignmentCylinder {
                                // M16.6 Phase 2b — material 22 hardcodes swirl-top + square-wrap; the
                                // align value rides `discoveryAmount` (set on the instance below).
                                materialID = 22
                                color = SIMD4(1, 1, 1, 1)
                            }
                            if prop.kind == .portalLamp {
                                if model.sealedPortalCubies.contains(ci) {
                                    color = SIMD4(0.10, 0.10, 0.12, 1.0)    // M16.4: sealed — lamp dead
                                } else {
                                    // TARDIS-style flash: a brief bright pulse each ~1.4 s cycle, else dim. Emissive.
                                    let cyclePos = gameState.time.truncatingRemainder(dividingBy: 1.4) / 1.4
                                    let v: Float = cyclePos < 0.18 ? 1.0 : 0.28
                                    color = SIMD4(v, v, min(1, v * 1.2), 1.0)   // white with a cool tint
                                    materialID = 12                             // emissive (unlit) → reads as a lamp
                                }
                            }
                            // M16.6 Phase 2b: the cylinder rides its align value in discoveryAmount
                            // (material 22 shears the square-wrap by it); every other prop is fully shown.
                            let discovery: Float = prop.kind == .alignmentCylinder ? prop.alignAnim : 1.0
                            let inst = InstanceDataSwift(modelMatrix: pm, baseColor: color,
                                materialID: materialID, tileID: 0, discoveryAmount: discovery, styleSeed: propStyleSeed,
                                spinMatrix: spin, roundness: roundness, invHalfExtent: invHalf, reliefAmplitude: relief)
                            mazePropTiles[prop.kind.rawValue, default: []].append(TileEntry(instance: inst, mesh: mesh))
                        }
                    }
                }
            }
        }

        // Player marker (orbit mode only) — seated at the inflated sub-cell footprint (R2.1), so
        // it sits ON the curved surface exactly like the FP camera, then faced and shrunk to fit.
        if gameState.camera.mode == .orbit {
            let player = gameState.player
            let step = model.worldScale.standStep
            let localX = Float(player.subCol - player.standCenter) * step
            let localY = Float(player.subRow - player.standCenter) * step
            var pMatrix = model.inflatedPlacement(face: player.face, row: player.row, col: player.col,
                                                  localX: localX, localY: localY)
            if let animMat = sliceAnimMatrix, sr.playerCubieIndex >= 0, sr.affectedCubies.contains(sr.playerCubieIndex) {
                pMatrix = animMat * pMatrix
            }
            let tb = player.facing.tangentBitangent
            let facingAngle = atan2f(-tb.t, tb.b)
            pMatrix = spin * pMatrix
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

        // Celestial bodies (M9): the sun cube (emissive) and moon cube (sun-lit) at their
        // orbital positions. Both use the shared celestialCube mesh, so they batch together.
        // Skipped for a counterpart world (M11) — it shouldn't carry its own sun/moon into the sky.
        if includeCelestials {
            let cs = gameState.celestialSystem
            let timeSunPos = cs.sunPosition(time: gameState.time)
            // Shift+T noon-lock: draw the sun overhead too (same distance), so the visible sun
            // matches the overhead light instead of sitting low while the ground reads as noon.
            let sunPos = sunOverride.map { $0 * simd_length(timeSunPos) } ?? timeSunPos
            let sunMat = float4x4.translation(sunPos.x, sunPos.y, sunPos.z) * float4x4.scale(cs.sunSize)
            celestialTiles.append(TileEntry(
                instance: InstanceDataSwift(modelMatrix: sunMat, baseColor: SIMD4(1.0, 0.93, 0.65, 1.0),
                    materialID: 12, tileID: 0, discoveryAmount: 1.0, styleSeed: 0),
                mesh: tileMeshLib.celestialCube))
            // The plain M9 moon is skipped when the real moon-world is being rendered in its place
            // (M11), so there aren't two moons in the sky.
            if includeMoon {
                let moonPos = cs.moonPosition(time: gameState.time)
                let moonMat = float4x4.translation(moonPos.x, moonPos.y, moonPos.z) * float4x4.scale(cs.moonSize)
                celestialTiles.append(TileEntry(
                    instance: InstanceDataSwift(modelMatrix: moonMat, baseColor: SIMD4(0.72, 0.72, 0.75, 1.0),
                        materialID: 13, tileID: 0, discoveryAmount: 1.0, styleSeed: 0),
                    mesh: tileMeshLib.celestialCube))
            }
        }

        // Pack instances — opaque first, then translucent.
        // R2.16 hard guard: the writes below are raw `ptr[idx]` stores with no per-store bounds
        // check, so prove the whole frame fits BEFORE writing — a silent buffer overrun (the old
        // failure mode beyond ~size 13) must never be possible again. Provisioning in Renderer
        // budgets 8 instances/tile, so this should be unreachable; if it ever fires, the budget
        // (not this check) is what needs raising.
        let totalInstances = frameTiles.count
            + mazeFloorTiles.values.reduce(0) { $0 + $1.count }
            + mazePathFloorTiles.values.reduce(0) { $0 + $1.count }
            + mazeWallTiles.values.reduce(0) { $0 + $1.count }
            + mazePostTiles.values.reduce(0) { $0 + $1.count }
            + mazePropTiles.values.reduce(0) { $0 + $1.count }
            + fieldTiles.count
            + opaqueFogTiles.count + dissolveTiles.count + celestialTiles.count
        precondition(totalInstances <= capacity,
                     "SceneBuilder instance overflow: \(totalInstances) > capacity \(capacity) — raise instancesPerTileBudget in Renderer")
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

        // M19 natural-register ground (grass + water share the fieldFloor mesh; each instance
        // carries its own materialID 14/15).
        if !fieldTiles.isEmpty {
            let mesh = fieldTiles[0].mesh
            let startIdx = idx
            for entry in fieldTiles {
                ptr[idx] = entry.instance
                idx += 1
            }
            opaqueDrawCalls.append(DrawCall(
                indexOffset: mesh.indexOffset,
                indexCount: mesh.indexCount,
                instanceOffset: startIdx,
                instanceCount: fieldTiles.count
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

        // Celestial bodies (M9) — emissive, drawn with the opaque geometry (far outside the
        // shadow-map frustum, so their presence in the shadow pass is a harmless no-op).
        if !celestialTiles.isEmpty {
            let mesh = celestialTiles[0].mesh
            let startIdx = idx
            for entry in celestialTiles {
                ptr[idx] = entry.instance
                idx += 1
            }
            opaqueDrawCalls.append(DrawCall(
                indexOffset: mesh.indexOffset,
                indexCount: mesh.indexCount,
                instanceOffset: startIdx,
                instanceCount: celestialTiles.count
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

    /// Emit one revealed tile's maze geometry — floor, paved path-cross, hedge walls, jamb posts —
    /// all on the per-vertex inflation path (rest placement + per-instance spin/roundness), keyed
    /// into their instancing buckets. Shared by the `.adjacent` and `.discovered` tile states
    /// (R2.2: previously two hand-maintained copies that had to be edited in lockstep).
    private func emitMazeTile(_ facelet: MazeFacelet, restM: float4x4, spin: float4x4,
                              roundness: Float, invHalf: Float, relief: Float, naturalDressing: Bool,
                              tileMeshLib: TileMeshLibrary) {
        let openings = facelet.mazeTile.openings
        let pathColor = SIMD4<Float>(0.72, 0.62, 0.45, 1.0)
        let uvT = facelet.mazeTile.uvTurns
        let key = (openings.rawValue & 0x0F) | (UInt8(((uvT % 4) + 4) % 4) << 4)
        if naturalDressing {
            // M20 natural-maze hybrid (garden): keep the hedge walls/posts below, but floor the
            // whole tile in grass (material 14, the full fieldFloor) instead of the paved maze
            // floor + path-cross — a hedge garden on a green planet.
            let grass = InstanceDataSwift(modelMatrix: restM, baseColor: SIMD4(1, 1, 1, 1),
                materialID: 14, tileID: UInt32(facelet.id.rawValue), discoveryAmount: 1.0,
                styleSeed: facelet.mazeTile.styleSeed,
                spinMatrix: spin, roundness: roundness, invHalfExtent: invHalf, reliefAmplitude: relief)
            fieldTiles.append(TileEntry(instance: grass, mesh: tileMeshLib.fieldFloor))
        } else {
            // Floor: inflated per-vertex (rest matrix + roundness + relief).
            let floorInst = InstanceDataSwift(modelMatrix: restM, baseColor: pathColor,
                materialID: 1, tileID: UInt32(facelet.id.rawValue), discoveryAmount: 1.0,
                styleSeed: facelet.mazeTile.styleSeed,
                spinMatrix: spin, roundness: roundness, invHalfExtent: invHalf, reliefAmplitude: relief)
            mazeFloorTiles[key, default: []].append(TileEntry(instance: floorInst, mesh: tileMeshLib.floorMesh(for: openings, uvTurns: uvT)))
            if let pfm = tileMeshLib.pathFloorMesh(for: openings, uvTurns: uvT) {
                let pathInst = InstanceDataSwift(modelMatrix: restM, baseColor: SIMD4(1, 1, 1, 1),
                    materialID: 9, tileID: UInt32(facelet.id.rawValue), discoveryAmount: 1.0,
                    styleSeed: facelet.mazeTile.styleSeed,
                    spinMatrix: spin, roundness: roundness, invHalfExtent: invHalf, reliefAmplitude: relief)
                mazePathFloorTiles[key, default: []].append(TileEntry(instance: pathInst, mesh: pfm))
            }
        }
        // Wall/post: inflate per-vertex (M14b Phase 2) — footprint + extrude along the
        // curved normal, so hedges stand up from the curved floor instead of levering.
        let cfg = facelet.mazeTile.edgeConfigKey
        if let wm = tileMeshLib.wallMesh(configKey: cfg) {
            let wallInst = InstanceDataSwift(modelMatrix: restM, baseColor: pathColor,
                materialID: 1, tileID: UInt32(facelet.id.rawValue), discoveryAmount: 1.0,
                styleSeed: facelet.mazeTile.styleSeed,
                spinMatrix: spin, roundness: roundness, invHalfExtent: invHalf, reliefAmplitude: relief)
            mazeWallTiles[cfg, default: []].append(TileEntry(instance: wallInst, mesh: wm))
        }
        if let pm = tileMeshLib.postMesh(configKey: cfg) {
            let postInst = InstanceDataSwift(modelMatrix: restM, baseColor: Self.postColor,
                materialID: 8, tileID: UInt32(facelet.id.rawValue),
                discoveryAmount: 1.0, styleSeed: facelet.mazeTile.styleSeed,
                spinMatrix: spin, roundness: roundness, invHalfExtent: invHalf, reliefAmplitude: relief)
            mazePostTiles[cfg, default: []].append(TileEntry(instance: postInst, mesh: pm))
        }
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
