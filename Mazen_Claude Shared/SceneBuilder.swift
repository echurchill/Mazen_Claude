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
        .portalField: SIMD4(0.42, 0.55, 1.0, 1.0),   // M20 — energy-veil tint (overridden per style below)
        .portalRing:  SIMD4(0.55, 0.72, 1.0, 1.0),   // M20 — base-glow ring (emissive)
        .signpost:    SIMD4(1.0, 1.0, 1.0, 1.0),     // M20 — material 24 colours itself (wood + label)
        .dial:        SIMD4(0.52, 0.52, 0.58, 1.0),  // M16.3 — overridden by state below
        .glyph:       SIMD4(0.68, 0.65, 0.59, 1.0),  // M16.5 — carved stone (lock livery may gild it)
        .plinth:      SIMD4(1.0, 1.0, 1.0, 1.0),     // M16.6 — material 21 does the colouring itself
        .tree:        SIMD4(0.20, 0.44, 0.22, 1.0),  // M19 — conifer green
        .treeTrunk:   SIMD4(0.34, 0.24, 0.15, 1.0),  // M19 — bark brown
        .boulder:     SIMD4(0.44, 0.44, 0.47, 1.0),  // M19 — moon rock grey
        .foliageCard: SIMD4(0.26, 0.46, 0.22, 1.0),  // M20 — leafy green (alpha-cutout card)
        .anchor:      SIMD4(0.72, 0.68, 0.45, 1.0),  // Scene 4 — brass plate; dims once released
    ]

    // Reusable scratch buffers (kept across frames to avoid per-frame allocation).
    private var opaqueFogTiles: [TileEntry] = []
    private var dissolveTiles: [TileEntry] = []
    // PERF: reused mesh-grouping scratch for the fog passes (were fresh dictionaries every frame).
    private var fogByMesh: [Int: [TileEntry]] = [:]
    private var dissolveByMesh: [Int: [TileEntry]] = [:]
    private var frameTiles: [TileEntry] = []
    /// The CUT FACES of a slab in mid-twist — the inner side of each cubie in the turning slice,
    /// where it separates from the rest of the cube. Those faces are not cube faces, so no facelet
    /// exists for them and nothing is ever rendered there: at rest they are buried and invisible, but
    /// the moment a slice swings out they are exactly the surface that would show its THICKNESS.
    /// Without them a slab reads as a couple of one-tile rim strips with sky between (Eddie,
    /// playtest), and the props riding it appear to float. Built only while a twist is in flight.
    private var cutFaceTiles: [TileEntry] = []
    /// Bond bands — the luminous seams tracing what holds the world rigid (Scene 4). Rebuilt from
    /// live topology each frame, so they follow a twist and vanish with the bond they describe.
    private var bondBandTiles: [TileEntry] = []
    private var celestialTiles: [TileEntry] = []
    /// Scene 3 — the suspended orb, and one beam per lit obelisk. Separate arrays because each has
    /// its own mesh, and each becomes a single instanced draw.
    private var orbTiles: [TileEntry] = []
    private var beamTiles: [TileEntry] = []
    private var mazeFloorTiles: [UInt8: [TileEntry]] = [:]
    private var mazePathFloorTiles: [UInt8: [TileEntry]] = [:]
    private var mazeWallTiles: [UInt8: [TileEntry]] = [:]
    private var mazePostTiles: [UInt8: [TileEntry]] = [:]
    private var mazePropTiles: [UInt8: [TileEntry]] = [:]
    private var fieldTiles: [TileEntry] = []   // M19: natural-register ground (grass/water), one shared mesh


    /// Which edge of tile `a` the band leaves through on its way to `b`, as an N/E/S/W bit mask
    /// (N=1, E=2, S=4, W=8) matching material 27's spine directions.
    ///
    /// Same face: the row/col delta says it outright. Across a face edge: the band leaves through
    /// whichever border `a` sits on — a tile on row 0 exits north, on the last column exits east,
    /// and so on. A corner tile sits on two borders and is genuinely ambiguous from position alone;
    /// it takes the first match, which puts the seam on one of the two correct edges rather than
    /// none. (Local axes, from `wallCenterline`: north is −y, south +y, west −x, east +x, so in
    /// normalised tile UV north is v=0 and east is u=1.)
    private static func bandLink(from a: CubeModel.PropTileEntry, to b: CubeModel.PropTileEntry, size: Int) -> UInt32 {
        if a.face == b.face {
            if b.row < a.row { return 1 }
            if b.row > a.row { return 4 }
            if b.col < a.col { return 8 }
            if b.col > a.col { return 2 }
            return 0
        }
        if a.row == 0 { return 1 }
        if a.row == size - 1 { return 4 }
        if a.col == 0 { return 8 }
        if a.col == size - 1 { return 2 }
        return 0
    }

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
        cutFaceTiles.removeAll(keepingCapacity: true)
        bondBandTiles.removeAll(keepingCapacity: true)
        celestialTiles.removeAll(keepingCapacity: true)
        orbTiles.removeAll(keepingCapacity: true)
        beamTiles.removeAll(keepingCapacity: true)
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
        // PERF: flatten the per-prop membership tests to O(1) set lookups (they ran a linear
        // contains(where:) per prop per frame on the hot path).
        let bondedCubies = model.bondedGroups.reduce(into: Set<Int>()) { $0.formUnion($1) }
        let styledPortalCubies = Set(model.styledPortals.map { $0.ci })

        for face in CubeFace.allCases {
            for row in 0..<model.size {
                for col in 0..<model.size {
                    guard let (ci, fi) = model.faceletAt(face: face, row: row, col: col) else { continue }
                    let facelet = model.cubies[ci].facelets[fi]

                    // M14b: the maze surface (floors/walls/posts/frame/props) inflates per-vertex in
                    // the shader from the *un-spun rest* placement + per-instance spin/roundness.
                    // `matrix` — a rigid seat ON the curved surface at the tile centre — anchors only
                    // the translucent fog layers (R2.1: via inflatedPlacement, not the old per-tile-
                    // inflated worldMatrix). PERF: the rest matrix is built ONCE per tile and shared
                    // by the inflated fog seat (was built twice).
                    var restM = model.restMatrix(face: face, row: row, col: col)
                    var matrix = model.inflatedPlacement(base: restM, localX: 0, localY: 0)

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
                                     naturalDressing: model.naturalDressing, suppressHedge: model.wallStyle == .dressed,
                                     metal: model.wallStyle == .metal, tileMeshLib: tileMeshLib)
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
                                         naturalDressing: model.naturalDressing, suppressHedge: model.wallStyle == .dressed,
                                     metal: model.wallStyle == .metal, tileMeshLib: tileMeshLib)
                        case .grass, .water, .regolith, .plating:
                            // M19: a full-tile ground quad, no walls. Grass (14) / water (15) /
                            // regolith (16) share the fieldFloor mesh, so they batch into one draw.
                            let mat: UInt32 = facelet.terrain == .water ? 15
                                            : facelet.terrain == .regolith ? 16
                                            : facelet.terrain == .plating ? 25 : 14
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
                            // M20 (Eddie) — styled portals (elevator streaks / cloud arch) render their
                            // own visual, not the TARDIS box; and their energy field + ring only show
                            // while the portal is ACTIVE (its cubie not sealed). The imported frame
                            // (columns / arch) is unaffected.
                            if prop.kind == .portal, styledPortalCubies.contains(ci) { continue }
                            if (prop.kind == .portalField || prop.kind == .portalRing), model.sealedPortalCubies.contains(ci) { continue }
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
                            // Scene 4D beat 3 — "the entire vessel strains several degrees". The vessel
                            // stands ON the twistable slab, so it already rides a refused twist along
                            // with the player and the ground; riding together is relative stillness and
                            // reads as nothing at all. The strain has to be ON TOP of the slab's, about
                            // the vessel's own axis, so the vase visibly turns against the ground it
                            // stands on and springs back with it. Same curve the ground is straining to
                            // (`SliceRotation.currentAngle` on a refusal already damps back to zero), so
                            // the object and the world cannot disagree about how hard the lock is held.
                            var extraYaw: Float = 0
                            if prop.kind == .layeredVessel {
                                // Scene 1C — the peripheral drift. Whole turns, so what you glimpse
                                // is the vessel having MOVED rather than moving: it is never caught
                                // mid-rotation, only found in a new position.
                                let id = facelet.id.rawValue
                                if let drift = gameState.vesselDrift[id] {
                                    extraYaw += (.pi / 2) * drift.rounded(.down)
                                }
                                // Scene 1G — the watcher turns to face you, continuously, rather
                                // than in the quarter-turns the others drift by. That difference is
                                // the point: everything else in this world moves only when unobserved.
                                if prop.state == 5, let watch = gameState.vesselWatch[id] {
                                    extraYaw = watch
                                }
                                if sr.isActive, sr.isRefusal {
                                    extraYaw = sr.currentAngle * 1.6
                                } else if prop.alignAnim > 0 {
                                    // 4D beat 3, self-driven: the vessel demonstrates the strain with
                                    // no twist happening at all. Same curve, same amplitude the ground
                                    // would give against the bonds that remain, so the demonstration
                                    // is an honest preview rather than a canned animation.
                                    let blocking = model.bondsBlocking(axis: 2, index: model.size - 1)
                                    let amp: Float = blocking > 0 ? 0.03 + 0.08 / Float(blocking) : 0.06
                                    extraYaw = GameState.SliceRotation.strainCurve(
                                        progress: prop.alignAnim, amplitude: amp * 1.6, direction: 1)
                                }
                            }
                            let pm = restM
                                * float4x4.translation(Float(prop.subCol - 1) * step + prop.offsetX, Float(prop.subRow - 1) * step + prop.offsetY, 0)
                                * float4x4.rotation(radians: Float(prop.facing.rawValue) * (.pi / 4) + prop.viewAngle * (.pi / 180) + extraYaw, axis: SIMD3(0, 0, 1))
                                * float4x4.scale(treeScale)
                            // M16.6/M20 — the alignment cylinder (GROW) and switch cap (flush↔out) animate
                            // their HEIGHT. Pass it as heightScale about the plinth top (applied to the
                            // vertex's local z in the shader), NOT a modelMatrix Z-scale: a non-uniform Z
                            // in modelMatrix corrupts the curved-world footprint/height split and floated
                            // the flush cap on the garden (Eddie).
                            var heightScale: Float = 1, heightPivot: Float = 0
                            if prop.kind == .alignmentCylinder || prop.kind == .switchCap {
                                heightPivot = model.worldScale.floorY + TileMeshLibrary.plinthHeightM * (model.worldScale.eyeHeight / 1.7)
                                if prop.kind == .alignmentCylinder {
                                    heightScale = max(0.001, prop.anim)                          // rise from the disc
                                } else {
                                    let flushFrac = TileMeshLibrary.switchCapFlushM / TileMeshLibrary.switchCapOutM
                                    heightScale = flushFrac + (1 - flushFrac) * max(0, min(1, prop.anim))   // flush ↔ poking out
                                }
                            }
                            var color = Self.propColors[prop.kind] ?? SIMD4(0.6, 0.6, 0.6, 1.0)
                            var materialID: UInt32 = 10
                            if bondedCubies.contains(ci) {
                                // Locked-structure livery: GOLD on the engineered overworld (a lock
                                // findable at a glance). But the M20 garden temple wants to be
                                // *discovered, not advertised* (Player Journey) — so on a natural-dressed
                                // world it wears mossy grey-green stone instead. Both still flare red
                                // while a refused twist strains against them.
                                color = model.naturalDressing ? SIMD4(0.40, 0.45, 0.33, 1.0)
                                                              : SIMD4(0.95, 0.78, 0.20, 1.0)
                                if refusalGlow > 0 { color = mix(color, SIMD4(1.0, 0.10, 0.06, 1.0), t: refusalGlow) }
                            }
                            if prop.kind == .portal, Renderer.prologueDestinationIDs.contains(prop.state) {
                                // Doors to the prologue wear DARSIT red instead of TARDIS blue
                                // (Eddie) — the boxes in the hub that aren't dev worlds.
                                color = SIMD4(0.58, 0.10, 0.11, 1.0)
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
                            if prop.kind == .obelisk && prop.anim > 0 {
                                // M20 Scene 2 — an AWAKENING obelisk: material 26 climbs a line of
                                // light up the shaft, driven by `anim` (carried in discoveryAmount).
                                // A dormant obelisk (anim == 0) stays on the plain lit material.
                                materialID = 26
                                color = SIMD4(1, 1, 1, 1)
                            }
                            if prop.kind == .anchor {
                                // Bound anchors carry the lock's livery so they read as part of one
                                // structure; a released one goes dull and stays that way.
                                color = prop.anim > 0.5 ? SIMD4(0.95, 0.78, 0.20, 1.0)
                                                        : SIMD4(0.34, 0.33, 0.30, 1.0)
                                if refusalGlow > 0 && prop.anim > 0.5 {
                                    color = mix(color, SIMD4(1.0, 0.10, 0.06, 1.0), t: refusalGlow)
                                }
                                // 4D beat 6 — "three distant points around the world answer with brief
                                // flashes". The anchors name themselves, so the player learns where the
                                // lock is held without being told there is one. `alignAnim` decays.
                                if prop.alignAnim > 0 {
                                    color = mix(color, SIMD4(1.0, 0.96, 0.72, 1.0), t: prop.alignAnim)
                                    materialID = 12                     // emissive: visible from afar
                                }
                            }
                            if prop.kind == .plinth {
                                // M16.6: the Builder plinth — material 21 reads stone/resin vs glyph
                                // from the mesh's UV flag; `state` selects the caustic symbol slice.
                                materialID = 21
                                propStyleSeed = UInt32(max(0, prop.state))
                                color = SIMD4(1, 1, 1, 1)
                            }
                            if prop.kind == .alignmentCylinder {
                                // M16.6 Phase 2b — material 22: swirl on top (styleSeed) + square wrap;
                                // the align value rides `discoveryAmount` (set on the instance below).
                                materialID = 22
                                propStyleSeed = UInt32(TextureLoader.CausticSymbol.swirl.rawValue)
                                color = SIMD4(1, 1, 1, 1)
                            }
                            if prop.kind == .switchCap {
                                // M16.6 (Eddie) — the switch's number cylinder: material 22 (no wrap in
                                // this mesh), `state` = the number glyph on top. Height (engaged out /
                                // disengaged flush) is `anim`, applied to pm below.
                                materialID = 22
                                propStyleSeed = UInt32(max(0, prop.state))
                                color = SIMD4(1, 1, 1, 1)
                            }
                            if prop.kind == .portalField {
                                // M20 (Eddie) — animated energy field (material 23). `state` = style
                                // (0 blue veil, 1 pink veil, 2 starfield); the tint per style rides
                                // baseColor. Emissive + time-driven; the shader wisps its own edges.
                                materialID = 23
                                propStyleSeed = UInt32(max(0, prop.state))
                                switch prop.state {
                                case 1:  color = SIMD4(1.0, 0.42, 0.66, 1.0)   // pink/magenta veil
                                case 2:  color = SIMD4(0.42, 0.34, 0.78, 1.0)  // starfield nebula (violet)
                                case 3, 4: color = SIMD4(0.36, 0.78, 0.95, 1.0) // elevator streaks (cyan) — 3 down, 4 up
                                default: color = SIMD4(0.40, 0.56, 1.0, 1.0)   // blue/purple veil
                                }
                                // A portal field can be stretched taller than its mesh (extraScale) so
                                // e.g. the arch fill reaches the apex; base stays pinned at the floor.
                                if prop.extraScale != 1 {
                                    heightScale = prop.extraScale
                                    heightPivot = model.worldScale.floorY
                                }
                            }
                            if prop.kind == .portalRing {
                                materialID = 12                                 // emissive glow ring
                            }
                            if prop.kind == .dustMote {
                                // Falls as it dies: heightScale about the FLOOR pivot lowers the mote
                                // from joint height to the ground over its life, and discoveryAmount
                                // dithers it away. One prop field doing both jobs.
                                materialID = 29
                                heightPivot = model.worldScale.floorY
                                heightScale = max(0.001, prop.anim)
                                color = SIMD4(1, 1, 1, 1)
                            }
                            if prop.kind == .layeredVessel {
                                // Scene 4D — material 28 draws the three ring seams from a single
                                // float: `anim` counts rings aligned (0…3), normalised here into the
                                // discoveryAmount slot the shader reads.
                                materialID = 28
                                // Scene 1E — "one appears warmer in sunlight". baseColor tints the
                                // ceramic; every other vessel takes it plain, so the difference is
                                // only visible with one of each in view.
                                color = prop.state == 2 ? SIMD4(1.10, 1.02, 0.88, 1)
                                                        : SIMD4(1, 1, 1, 1)
                                // Beat 2 — "one ring attempts to rotate": the LEADING ring (the next
                                // one not yet home) swings further than the body and springs back.
                                // Signed strain in radians, packed into the otherwise-unused styleSeed
                                // as (strain + 0.25) × 2000 so the shader can recover the sign.
                                // Scene 1's peripheral drift also lands in extraYaw, and it is NOT
                                // strain — a vessel quietly rotating is not a vessel straining, so
                                // only the demo's own animation feeds the ring.
                                let demoStrain = prop.alignAnim > 0 ? extraYaw / 1.6 : 0
                                let strain = (sr.isActive && sr.isRefusal) ? sr.currentAngle : demoStrain
                                propStyleSeed = UInt32(max(0, min(1000, Int((strain + 0.25) * 2000))))
                                // Beat 1 — the swirl on the cap illuminates while it demonstrates,
                                // and keeps a low ember afterwards: this object has been read. The
                                // ALPHA carries that; keep the RGB the tint chose above, or the warm
                                // vessel would be quietly reset to plain here.
                                color.w = gameState.vesselGlow
                            }
                            if prop.kind == .signpost {
                                materialID = 24                                 // wood + rendered label
                                propStyleSeed = UInt32(max(0, prop.state))      // state = label-array slice
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
                            // discoveryAmount doubles as the portal-field OPACITY (material 23 screen-door
                            // dither) for the translucent elevator layers; alignAnim==0 ⇒ fully opaque.
                            let discovery: Float
                            if prop.kind == .alignmentCylinder { discovery = prop.alignAnim }
                            else if prop.kind == .dustMote { discovery = max(0, min(1, prop.anim)) }
                            else if prop.kind == .layeredVessel { discovery = max(0, min(1, prop.anim / 3)) }
                            else if prop.kind == .obelisk && prop.anim > 0 { discovery = prop.anim }
                            // Scene 3D — the refusal. A faint flash on the symbol of the obelisk the
                            // player just touched, and only that one: enough to say "you were heard"
                            // without ever saying "yes".
                            else if prop.kind == .obelisk && gameState.obeliskRebuffFacelet == facelet.id.rawValue {
                                discovery = gameState.obeliskRebuff * 0.22
                            }
                            // 3I AFTER FIVE: "the remaining inactive obelisk flashes once. Its symbol
                            // becomes more visible, helping the player identify the final matching
                            // plinth. This is guidance, not an objective marker." So: a slow pulse on
                            // the one that is left, never a steady light.
                            else if prop.kind == .obelisk, gameState.chamberWoken > 0.8, gameState.chamberWoken < 1 {
                                discovery = 0.10 + 0.10 * (0.5 + 0.5 * sinf(gameState.time * 1.6))
                            }
                            else if prop.kind == .portalField && prop.alignAnim > 0 { discovery = prop.alignAnim }
                            else { discovery = 1.0 }
                            let inst = InstanceDataSwift(modelMatrix: pm, baseColor: color,
                                materialID: materialID, tileID: 0, discoveryAmount: discovery, styleSeed: propStyleSeed,
                                spinMatrix: spin, roundness: roundness, invHalfExtent: invHalf, reliefAmplitude: relief,
                                heightScale: heightScale, heightPivot: heightPivot)
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

        // ── SCENE 3: THE SUSPENDED HEART, AND THE BEAMS THAT REACH FOR IT ──────────────────────
        // An interior chamber's centre is the one place nothing has ever been drawn: the world is a
        // hollow shell and the middle of it was simply empty space. "Every surface of the chamber has
        // its local up directed toward this shared center… it is not on the ceiling. It is always
        // inward." So the orb sits at the origin, which is exactly what makes that true for free.
        var beamIndex: UInt32 = 0
        for e in gameState.chamberEmitters {
            if e.isOrb {
                let c = spin * SIMD4(e.a.x, e.a.y, e.a.z, 1)
                let orbM = float4x4.translation(c.x, c.y, c.z) * float4x4.scale(e.radius)
                orbTiles.append(TileEntry(
                    instance: InstanceDataSwift(modelMatrix: orbM, baseColor: SIMD4(1, 1, 1, 1),
                        materialID: 30, tileID: 0, discoveryAmount: e.glow, styleSeed: 0,
                        spinMatrix: matrix_identity_float4x4, roundness: 0, invHalfExtent: 1, reliefAmplitude: 0),
                    mesh: tileMeshLib.orbMesh))
                continue
            }
            let a4 = spin * SIMD4(e.a.x, e.a.y, e.a.z, 1), b4 = spin * SIMD4(e.b.x, e.b.y, e.b.z, 1)
            let start = SIMD3(a4.x, a4.y, a4.z), finish = SIMD3(b4.x, b4.y, b4.z)
            let along = finish - start
            let len = simd_length(along)
            guard len > 1e-4 else { continue }
            let dir = along / len
            // A frame whose +Z runs along the beam.
            let up = abs(dir.y) > 0.95 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            let x = simd_normalize(simd_cross(up, dir))
            let y = simd_cross(dir, x)
            var bm = matrix_identity_float4x4
            bm.columns.0 = SIMD4(x * e.radius, 0)
            bm.columns.1 = SIMD4(y * e.radius, 0)
            bm.columns.2 = SIMD4(dir * len, 0)
            bm.columns.3 = SIMD4(start, 1)
            beamTiles.append(TileEntry(
                instance: InstanceDataSwift(modelMatrix: bm, baseColor: SIMD4(1, 1, 1, 1),
                    materialID: 31, tileID: 0, discoveryAmount: e.glow, styleSeed: beamIndex,
                    spinMatrix: matrix_identity_float4x4, roundness: 0, invHalfExtent: 1, reliefAmplitude: 0),
                mesh: tileMeshLib.beamMesh))
            beamIndex += 1
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

        // BOND BANDS — draw what the world is holding on to.
        for band in model.bondBands() {
            for (bi, t) in band.enumerated() {
                // Which way the run continues out of THIS tile (N/E/S/W bits). The seam is drawn from
                // the tile centre toward each of them, so a run reads as one continuous line and a
                // corner actually turns — previously the stripe always lay along the tile's local x,
                // whatever direction the band was going.
                var linkMask: UInt32 = 0
                if bi > 0 { linkMask |= Self.bandLink(from: t, to: band[bi - 1], size: model.size) }
                if bi < band.count - 1 { linkMask |= Self.bandLink(from: t, to: band[bi + 1], size: model.size) }
                var restM = model.restMatrix(face: t.face, row: t.row, col: t.col)
                if let animMat = sliceAnimMatrix, sr.affectedCubies.contains(t.ci) { restM = animMat * restM }
                // Lift a hair off the ground so the seam is not z-fighting the floor it sits in.
                let lift = SIMD3<Float>(restM.columns.2.x, restM.columns.2.y, restM.columns.2.z) * 0.004
                restM.columns.3 += SIMD4(lift.x, lift.y, lift.z, 0)
                let inst = InstanceDataSwift(
                    modelMatrix: restM, baseColor: SIMD4(1, 1, 1, 1),
                    materialID: 27, tileID: 0,
                    discoveryAmount: refusalGlow,          // the band runs hot while a turn strains
                    styleSeed: linkMask,
                    spinMatrix: spin, roundness: model.roundness,
                    invHalfExtent: 1.0 / model.worldScale.faceDistance,
                    reliefAmplitude: model.reliefAmplitude)
                bondBandTiles.append(TileEntry(instance: inst, mesh: tileMeshLib.bandFloor))
            }
        }

        // CUT FACES — give a turning slab its thickness (see `cutFaceTiles`).
        //
        // A slice is one cubie thick. Its outward side is a real cube face and renders normally; its
        // INNER side — where it parts from the rest of the cube — is not a cube face at all, so no
        // facelet exists there and nothing is drawn. At rest that is right (it is buried). Mid-twist
        // it is the surface that shows the slab has depth, and without it the slab reads as a couple
        // of thin rim strips with sky between them.
        //
        // Each cubie of the slice has exactly one facelet on the slice's outward face, so walking
        // that face enumerates the slice one-to-one. The cut plane sits one cell inward from it, so
        // the quad is that facelet's own transform slid along the inward normal — no new mesh, no new
        // coordinate math, and it inherits the twist automatically by being built the same way.
        if let animMat = sliceAnimMatrix, !sr.isRefusal {
            let outward: CubeFace
            switch (sr.axis, sr.index == 0) {
            case (0, true):  outward = .negativeX
            case (0, false): outward = .positiveX
            case (1, true):  outward = .negativeY
            case (1, false): outward = .positiveY
            case (2, true):  outward = .negativeZ
            default:         outward = .positiveZ
            }
            // Only an OUTER slice has an outward face to enumerate from; a middle slice (latent in
            // the engine, unused so far) has two cut planes and no such face, so skip it rather than
            // draw something wrong.
            if sr.index == 0 || sr.index == model.size - 1 {
                let inward = -outward.normal * model.worldScale.cellSpacing
                for row in 0..<model.size {
                    for col in 0..<model.size {
                        guard let (ci, _) = model.faceletAt(face: outward, row: row, col: col),
                              sr.affectedCubies.contains(ci) else { continue }
                        var cutM = model.restMatrix(face: outward, row: row, col: col)
                        cutM.columns.3 += SIMD4(inward.x, inward.y, inward.z, 0)
                        // NO `spin` here. Ground tiles submit their matrix WITHOUT the idle world
                        // spin and hand it to the shader separately as `spinMatrix`; baking it into
                        // the model matrix as well applies it twice. Because that spin advances
                        // continuously, the doubled version drifted — the cut plane sat at a
                        // different angle on every replay, and looked right only in the instant the
                        // spin passed through identity (Eddie: "it tracked the slice once but I
                        // couldn't duplicate it").
                        let m = animMat * cutM
                        // Roundness 0: a cut through the cube's interior is FLAT, and inflating it
                        // like a surface tile would bow it the wrong way and push it out of the slab.
                        //
                        // CONSTRAINT: this only lines up on a world whose own roundness is 0. Above
                        // that, surface tiles are inflated onto a curved shell while these interior
                        // quads stay on the flat cube, so the cut planes visibly detach and shear
                        // through the world. A rounded world with scripted twists would need the cut
                        // plane inflated to match — worth solving when one actually needs it, since
                        // the failure is spectacular rather than subtle (Eddie liked the look enough
                        // to want it deliberately one day; see Open Questions).
                        let inst = InstanceDataSwift(
                            modelMatrix: m,
                            baseColor: SIMD4(1, 1, 1, 1),
                            materialID: 25,                      // the same plating as the slab's shell
                            tileID: 0,
                            discoveryAmount: 1.0,
                            styleSeed: UInt32(truncatingIfNeeded: row &* 73856093 ^ col &* 19349663),
                            spinMatrix: spin, roundness: 0, invHalfExtent: 1.0 / model.worldScale.faceDistance,
                            reliefAmplitude: 0)
                        cutFaceTiles.append(TileEntry(instance: inst, mesh: tileMeshLib.fieldFloor))
                    }
                }
            }
        }

        // Pack instances — opaque first, then translucent.
        // R2.16 hard guard: the writes below are raw `ptr[idx]` stores with no per-store bounds
        // check, so prove the whole frame fits BEFORE writing — a silent buffer overrun (the old
        // failure mode beyond ~size 13) must never be possible again. Provisioning in Renderer
        // budgets 8 instances/tile, so this should be unreachable; if it ever fires, the budget
        // (not this check) is what needs raising.
        let totalInstances = frameTiles.count + cutFaceTiles.count + bondBandTiles.count + orbTiles.count + beamTiles.count
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

        // Bond bands
        if !bondBandTiles.isEmpty {
            let mesh = bondBandTiles[0].mesh
            let startIdx = idx
            for entry in bondBandTiles { ptr[idx] = entry.instance; idx += 1 }
            opaqueDrawCalls.append(DrawCall(
                indexOffset: mesh.indexOffset, indexCount: mesh.indexCount,
                instanceOffset: startIdx, instanceCount: bondBandTiles.count))
        }

        // Scene 3's orb and beams — one instanced draw each.
        for group in [orbTiles, beamTiles] where !group.isEmpty {
            let mesh = group[0].mesh
            let startIdx = idx
            for entry in group { ptr[idx] = entry.instance; idx += 1 }
            opaqueDrawCalls.append(DrawCall(
                indexOffset: mesh.indexOffset, indexCount: mesh.indexCount,
                instanceOffset: startIdx, instanceCount: group.count))
        }

        // Cut faces of the turning slab (mid-twist only)
        if !cutFaceTiles.isEmpty {
            let mesh = cutFaceTiles[0].mesh
            let startIdx = idx
            for entry in cutFaceTiles {
                ptr[idx] = entry.instance
                idx += 1
            }
            opaqueDrawCalls.append(DrawCall(
                indexOffset: mesh.indexOffset,
                indexCount: mesh.indexCount,
                instanceOffset: startIdx,
                instanceCount: cutFaceTiles.count
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
            for key in fogByMesh.keys { fogByMesh[key]?.removeAll(keepingCapacity: true) }
            for entry in opaqueFogTiles {
                fogByMesh[entry.mesh.indexOffset, default: []].append(entry)
            }
            for (_, entries) in fogByMesh where !entries.isEmpty {
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
            for key in dissolveByMesh.keys { dissolveByMesh[key]?.removeAll(keepingCapacity: true) }
            for entry in dissolveTiles {
                dissolveByMesh[entry.mesh.indexOffset, default: []].append(entry)
            }
            for (_, entries) in dissolveByMesh where !entries.isEmpty {
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
                              suppressHedge: Bool, metal: Bool = false, tileMeshLib: TileMeshLibrary) {
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
                materialID: metal ? 32 : 1, tileID: UInt32(facelet.id.rawValue), discoveryAmount: 1.0,
                styleSeed: facelet.mazeTile.styleSeed,
                spinMatrix: spin, roundness: roundness, invHalfExtent: invHalf, reliefAmplitude: relief)
            mazeFloorTiles[key, default: []].append(TileEntry(instance: floorInst, mesh: tileMeshLib.floorMesh(for: openings, uvTurns: uvT)))
            if let pfm = tileMeshLib.pathFloorMesh(for: openings, uvTurns: uvT) {
                let pathInst = InstanceDataSwift(modelMatrix: restM, baseColor: SIMD4(1, 1, 1, 1),
                    materialID: metal ? 32 : 9, tileID: UInt32(facelet.id.rawValue), discoveryAmount: 1.0,
                    styleSeed: facelet.mazeTile.styleSeed,
                    spinMatrix: spin, roundness: roundness, invHalfExtent: invHalf, reliefAmplitude: relief)
                mazePathFloorTiles[key, default: []].append(TileEntry(instance: pathInst, mesh: pfm))
            }
        }
        // Wall/post: inflate per-vertex (M14b Phase 2) — footprint + extrude along the
        // curved normal, so hedges stand up from the curved floor instead of levering.
        // M20: the garden REPLACES its hedge walls with packed foliage/ruin walls (stampGardenWalls),
        // so skip the wall + post meshes there — the maze topology still blocks movement.
        let cfg = facelet.mazeTile.edgeConfigKey
        if suppressHedge {
            // (walls are the foliage props placed by stampGardenWalls; nothing to emit here)
        } else if let wm = tileMeshLib.wallMesh(configKey: cfg) {
            let wallInst = InstanceDataSwift(modelMatrix: restM, baseColor: pathColor,
                materialID: metal ? 32 : 1, tileID: UInt32(facelet.id.rawValue), discoveryAmount: 1.0,
                styleSeed: facelet.mazeTile.styleSeed,
                spinMatrix: spin, roundness: roundness, invHalfExtent: invHalf, reliefAmplitude: relief)
            mazeWallTiles[cfg, default: []].append(TileEntry(instance: wallInst, mesh: wm))
        }
        if !suppressHedge, let pm = tileMeshLib.postMesh(configKey: cfg) {
            let postInst = InstanceDataSwift(modelMatrix: restM, baseColor: Self.postColor,
                materialID: metal ? 32 : 8, tileID: UInt32(facelet.id.rawValue),
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
