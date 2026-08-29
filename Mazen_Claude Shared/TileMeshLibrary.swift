import Metal
import simd

struct TileMesh {
    let vertexOffset: Int
    let indexOffset: Int
    let indexCount: Int
}

class TileMeshLibrary {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer

    let fogLayers: [TileMesh]
    let playerMarker: TileMesh
    let frameMesh: TileMesh
    let celestialCube: TileMesh   // unit SPHERE for the M9 sun/moon bodies (was a cube — it spoiled the reveal)
    let fieldFloor: TileMesh      // M19: a full-tile tessellated ground quad (grass/water — no path split)
    let orbMesh: TileMesh         // Scene 3: the suspended heart at the chamber's centre
    let beamMesh: TileMesh        // Scene 3: one obelisk-to-orb beam, a unit length along +Z
    /// The half of Scene 2's pipes that TURNS — see `addAlignmentPipeHalf`.
    let alignmentPipeTurning: TileMesh
    let channelFloor: TileMesh    // Scene 5: bandFloor, lifted in LOCAL z so it clears the ground on a ROUNDED world
    let bandFloor: TileMesh       // Same quad with NORMALISED [0,1]² UVs — for overlays that reason in tile
                                  // fractions (bond bands). fieldFloor bakes `uvScale` into its UVs for
                                  // texture tiling, which is wrong for anything measuring "half a tile".
    private var floorMeshes: [UInt8: TileMesh] = [:]      // propSpace sub-cells (base ground)
    private var pathFloorMeshes: [UInt8: TileMesh] = [:]  // path-cross sub-cells (paved)
    private var wallMeshes: [UInt8: TileMesh] = [:]
    private var postMeshes: [UInt8: TileMesh] = [:]
    private var propMeshes: [UInt8: TileMesh] = [:]  // keyed by PropKind.rawValue (M10 Phase G)

    init(device: MTLDevice, worldScale ws: WorldScale) {
        var allVerts: [MazeVertexSwift] = []
        var allIndices: [UInt32] = []

        func recordMesh() -> TileMesh {
            TileMesh(vertexOffset: 0, indexOffset: 0, indexCount: 0)
        }

        // Volumetric fog layers — 3 horizontal planes + 2 vertical cross-planes
        let fogHs: Float = 0.47
        var fogLayerList: [TileMesh] = []

        func addFogQuad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                        _ n: SIMD3<Float>,
                        _ uvA: SIMD2<Float>, _ uvB: SIMD2<Float>, _ uvC: SIMD2<Float>, _ uvD: SIMD2<Float>) {
            let start = allVerts.count
            let iStart = allIndices.count
            allVerts.append(contentsOf: [
                MazeVertexSwift(position: a, normal: n, texCoord: uvA, aoFactor: 1.0),
                MazeVertexSwift(position: b, normal: n, texCoord: uvB, aoFactor: 1.0),
                MazeVertexSwift(position: c, normal: n, texCoord: uvC, aoFactor: 1.0),
                MazeVertexSwift(position: d, normal: n, texCoord: uvD, aoFactor: 1.0),
            ])
            let base = UInt32(start)
            allIndices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
            fogLayerList.append(TileMesh(vertexOffset: start, indexOffset: iStart, indexCount: 6))
        }

        // 5 horizontal layers — tightly stacked near the surface
        let hZLevels: [Float] = [0.003, 0.04, 0.10, 0.20, 0.35]
        for z in hZLevels {
            addFogQuad(
                SIMD3(-fogHs, -fogHs, z), SIMD3( fogHs, -fogHs, z),
                SIMD3( fogHs,  fogHs, z), SIMD3(-fogHs,  fogHs, z),
                SIMD3(0, 0, 1),
                SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)
            )
        }
        fogLayers = fogLayerList

        // Player marker — diamond body + arrow pointing in +Y (north)
        let pmVStart = allVerts.count
        let pmIStart = allIndices.count
        let pmH: Float = 0.45
        let pmR: Float = 0.12
        let pmDirs: [SIMD3<Float>] = [
            SIMD3( pmR, 0, 0), SIMD3(0,  pmR, 0),
            SIMD3(-pmR, 0, 0), SIMD3(0, -pmR, 0)
        ]
        let pmTip = SIMD3<Float>(0, 0, pmH)
        for i in 0..<4 {
            let a = pmDirs[i]
            let b = pmDirs[(i + 1) % 4]
            let n = normalize(cross(b - a, pmTip - a))
            let bi = UInt32(allVerts.count)
            allVerts.append(MazeVertexSwift(position: a, normal: n, texCoord: SIMD2(0, 0), aoFactor: 1.0))
            allVerts.append(MazeVertexSwift(position: b, normal: n, texCoord: SIMD2(1, 0), aoFactor: 1.0))
            allVerts.append(MazeVertexSwift(position: pmTip, normal: n, texCoord: SIMD2(0.5, 1), aoFactor: 1.0))
            allIndices.append(contentsOf: [bi, bi+1, bi+2])
        }
        let arrowN = SIMD3<Float>(0, 0, 1)
        let arrowZ: Float = 0.03
        let ai = UInt32(allVerts.count)
        allVerts.append(MazeVertexSwift(position: SIMD3(0, pmR + 0.22, arrowZ), normal: arrowN, texCoord: SIMD2(0.5, 1), aoFactor: 1.0))
        allVerts.append(MazeVertexSwift(position: SIMD3(-0.08, pmR + 0.04, arrowZ), normal: arrowN, texCoord: SIMD2(0, 0), aoFactor: 1.0))
        allVerts.append(MazeVertexSwift(position: SIMD3( 0.08, pmR + 0.04, arrowZ), normal: arrowN, texCoord: SIMD2(1, 0), aoFactor: 1.0))
        allIndices.append(contentsOf: [ai, ai+1, ai+2])
        let pmIdxCount = allIndices.count - pmIStart
        playerMarker = TileMesh(vertexOffset: pmVStart, indexOffset: pmIStart, indexCount: pmIdxCount)

        // (uint32 indices are 4 bytes each, so every indexOffset*4 GPU address is already
        // 4-byte aligned — the old UInt16 alignment pad is no longer needed. M14b Phase 0.)

        // Cubie frame — dark border ring around each tile perimeter
        let frameVStart = allVerts.count
        let frameIStart = allIndices.count
        let fi: Float = 0.46
        let fo: Float = 0.52
        let fz: Float = 0.0
        let frameN = SIMD3<Float>(0, 0, 1)

        // Subdivide each rail along its length (a→b / d→c) so it bends with the curved floor under
        // M14b inflation instead of chording across a tile (M14b). Thin cross-section stays 1 quad.
        let frameSeg = max(1, ws.floorTess)
        func addFrameStrip(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            for i in 0..<frameSeg {
                let s0 = Float(i) / Float(frameSeg), s1 = Float(i + 1) / Float(frameSeg)
                let p00 = a + (b - a) * s0, p10 = a + (b - a) * s1
                let p11 = d + (c - d) * s1, p01 = d + (c - d) * s0
                let base = UInt32(allVerts.count)
                allVerts.append(contentsOf: [
                    MazeVertexSwift(position: p00, normal: frameN, texCoord: SIMD2(s0, 0), aoFactor: 0.8),
                    MazeVertexSwift(position: p10, normal: frameN, texCoord: SIMD2(s1, 0), aoFactor: 0.8),
                    MazeVertexSwift(position: p11, normal: frameN, texCoord: SIMD2(s1, 1), aoFactor: 0.8),
                    MazeVertexSwift(position: p01, normal: frameN, texCoord: SIMD2(s0, 1), aoFactor: 0.8),
                ])
                allIndices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
            }
        }

        addFrameStrip(SIMD3(-fo, -fo, fz), SIMD3(fo, -fo, fz), SIMD3(fo, -fi, fz), SIMD3(-fo, -fi, fz))
        addFrameStrip(SIMD3(-fo, fi, fz), SIMD3(fo, fi, fz), SIMD3(fo, fo, fz), SIMD3(-fo, fo, fz))
        addFrameStrip(SIMD3(fi, -fo, fz), SIMD3(fo, -fo, fz), SIMD3(fo, fo, fz), SIMD3(fi, fo, fz))
        addFrameStrip(SIMD3(-fo, -fo, fz), SIMD3(-fi, -fo, fz), SIMD3(-fi, fo, fz), SIMD3(-fo, fo, fz))

        frameMesh = TileMesh(vertexOffset: frameVStart, indexOffset: frameIStart,
                             indexCount: allIndices.count - frameIStart)

        // Floors — keyed by openings mask (low 4 bits) plus accumulated quarter-turns
        // (high 2 bits). The path/prop split depends only on the openings; the turns
        // rotate the UVs so the ground texture stays glued to the tile across slice
        // rotations (see MazeTile.uvTurns). Key = mask | (turns << 4), a 6-bit UInt8.
        for mask: UInt8 in 0..<16 {
            let openings = DirectionMask(rawValue: mask)
            for turns in 0..<4 {
                let key = mask | (UInt8(turns) << 4)

                let propStart = allIndices.count
                Self.addFloorCells(to: &allVerts, indices: &allIndices, openings: openings, uvTurns: turns, ws: ws, path: false)
                floorMeshes[key] = TileMesh(vertexOffset: 0, indexOffset: propStart, indexCount: allIndices.count - propStart)

                let pathStart = allIndices.count
                Self.addFloorCells(to: &allVerts, indices: &allIndices, openings: openings, uvTurns: turns, ws: ws, path: true)
                let pathCount = allIndices.count - pathStart
                if pathCount > 0 {
                    pathFloorMeshes[key] = TileMesh(vertexOffset: 0, indexOffset: pathStart, indexCount: pathCount)
                }
            }
        }

        // Walls + posts — keyed by the 81 three-state edge configs (each edge wall /
        // gateway / open). Open edges emit no geometry; a corner interior to a merged
        // room (both adjoining edges open) drops its post.
        for key: UInt8 in 0..<81 {
            let (openings, openEdges) = Self.decodeEdgeConfig(key)
            let tile = MazeTile(openings: openings, styleSeed: 0, openEdges: openEdges)

            let wStart = allIndices.count
            for dir in SurfaceDirection.allCases {
                Self.addEdgeWall(edge: dir, type: tile.edgeType(dir), to: &allVerts, indices: &allIndices, ws: ws)
            }
            let wCount = allIndices.count - wStart
            if wCount > 0 {
                wallMeshes[key] = TileMesh(vertexOffset: 0, indexOffset: wStart, indexCount: wCount)
            }

            let pStart = allIndices.count
            Self.addPosts(tile: tile, to: &allVerts, indices: &allIndices, ws: ws)
            let pCount = allIndices.count - pStart
            if pCount > 0 {
                postMeshes[key] = TileMesh(vertexOffset: 0, indexOffset: pStart, indexCount: pCount)
            }
        }

        // Props (M10 Phase G) — solid-colour meshes; SceneBuilder tints each via the
        // instance base colour, so one mesh per kind is enough.
        let topiaryStart = allIndices.count
        Self.addTopiary(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.topiary.rawValue] = TileMesh(vertexOffset: 0, indexOffset: topiaryStart, indexCount: allIndices.count - topiaryStart)

        let obeliskStart = allIndices.count
        Self.addObelisk(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.obelisk.rawValue] = TileMesh(vertexOffset: 0, indexOffset: obeliskStart, indexCount: allIndices.count - obeliskStart)

        let chestStart = allIndices.count
        Self.addChest(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.chest.rawValue] = TileMesh(vertexOffset: 0, indexOffset: chestStart, indexCount: allIndices.count - chestStart)

        let houseStart = allIndices.count
        Self.addHouseQuarter(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.houseCorner.rawValue] = TileMesh(vertexOffset: 0, indexOffset: houseStart, indexCount: allIndices.count - houseStart)

        let portalStart = allIndices.count
        Self.addPortal(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.portal.rawValue] = TileMesh(vertexOffset: 0, indexOffset: portalStart, indexCount: allIndices.count - portalStart)

        let portalLampStart = allIndices.count
        Self.addPortalLamp(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.portalLamp.rawValue] = TileMesh(vertexOffset: 0, indexOffset: portalLampStart, indexCount: allIndices.count - portalLampStart)

        let portalFieldStart = allIndices.count
        Self.addPortalDisc(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.portalField.rawValue] = TileMesh(vertexOffset: 0, indexOffset: portalFieldStart, indexCount: allIndices.count - portalFieldStart)


        let signpostStart = allIndices.count
        Self.addSignpost(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.signpost.rawValue] = TileMesh(vertexOffset: 0, indexOffset: signpostStart, indexCount: allIndices.count - signpostStart)

        let dialStart = allIndices.count
        Self.addDial(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.dial.rawValue] = TileMesh(vertexOffset: 0, indexOffset: dialStart, indexCount: allIndices.count - dialStart)

        let glyphStart = allIndices.count
        Self.addGlyphPlaque(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.glyph.rawValue] = TileMesh(vertexOffset: 0, indexOffset: glyphStart, indexCount: allIndices.count - glyphStart)

        let plinthStart = allIndices.count
        Self.addPlinth(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.plinth.rawValue] = TileMesh(vertexOffset: 0, indexOffset: plinthStart, indexCount: allIndices.count - plinthStart)
        // The world-model plinth (prototype) borrows the same stone. If it earns its place it wants
        // its own shape — a bowl or a ring to hold the world — but a prototype should not spend an
        // evening on geometry before anyone has seen whether the idea reads.
        propMeshes[PropKind.worldModel.rawValue] = TileMesh(vertexOffset: 0, indexOffset: plinthStart, indexCount: allIndices.count - plinthStart)

        // The two C's. The FIXED half is the prop's own mesh; the TURNING half is standalone,
        // because SceneBuilder emits it as a second instance carrying the quarter turn.
        // WHICH HALF STANDS STILL. The fixed one is the −x half and the turning one +x, because on
        // screen that puts the green standing half on the RIGHT and the purple moving half on the
        // LEFT — the arrangement in Eddie's drawings. Built the other way round they simply swap
        // sides, which reads as the wrong piece moving.
        let pipeAStart = allIndices.count
        Self.addAlignmentPipeHalf(to: &allVerts, indices: &allIndices, ws: ws, negative: true)
        propMeshes[PropKind.alignmentPipes.rawValue] = TileMesh(vertexOffset: 0, indexOffset: pipeAStart, indexCount: allIndices.count - pipeAStart)
        let pipeBStart = allIndices.count
        Self.addAlignmentPipeHalf(to: &allVerts, indices: &allIndices, ws: ws, negative: false)
        alignmentPipeTurning = TileMesh(vertexOffset: 0, indexOffset: pipeBStart, indexCount: allIndices.count - pipeBStart)

        let dustStart = allIndices.count
        Self.addDustMote(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.dustMote.rawValue] = TileMesh(vertexOffset: 0, indexOffset: dustStart, indexCount: allIndices.count - dustStart)

        let vesselStart = allIndices.count
        Self.addLayeredVessel(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.layeredVessel.rawValue] = TileMesh(vertexOffset: 0, indexOffset: vesselStart, indexCount: allIndices.count - vesselStart)

        let basinStart = allIndices.count
        Self.addChannelBasin(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.channelBasin.rawValue] = TileMesh(vertexOffset: 0, indexOffset: basinStart, indexCount: allIndices.count - basinStart)

        let bowlStart = allIndices.count
        Self.addChannelBowl(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.channelBowl.rawValue] = TileMesh(vertexOffset: 0, indexOffset: bowlStart, indexCount: allIndices.count - bowlStart)

        let switchBaseStart = allIndices.count
        Self.addSwitchBase(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.switchBase.rawValue] = TileMesh(vertexOffset: 0, indexOffset: switchBaseStart, indexCount: allIndices.count - switchBaseStart)

        let switchCapStart = allIndices.count
        Self.addSwitchCap(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.switchCap.rawValue] = TileMesh(vertexOffset: 0, indexOffset: switchCapStart, indexCount: allIndices.count - switchCapStart)
        // Scene 4's anchor borrows the switch cap's plate — a recessed control in a plate is the same
        // shape — until it has a mesh of its own.
        propMeshes[PropKind.anchor.rawValue] = propMeshes[PropKind.switchCap.rawValue]
        // Scene 6D's latch borrows the same recessed plate — a control in a plate — like the anchor.
        propMeshes[PropKind.latch.rawValue] = propMeshes[PropKind.switchCap.rawValue]

        let treeStart = allIndices.count
        Self.addTree(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.tree.rawValue] = TileMesh(vertexOffset: 0, indexOffset: treeStart, indexCount: allIndices.count - treeStart)

        let trunkStart = allIndices.count
        Self.addTreeTrunk(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.treeTrunk.rawValue] = TileMesh(vertexOffset: 0, indexOffset: trunkStart, indexCount: allIndices.count - trunkStart)

        let boulderStart = allIndices.count
        Self.addBoulder(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.boulder.rawValue] = TileMesh(vertexOffset: 0, indexOffset: boulderStart, indexCount: allIndices.count - boulderStart)

        let foliageStart = allIndices.count
        Self.addFoliageCard(to: &allVerts, indices: &allIndices, ws: ws)
        let foliageMesh = TileMesh(vertexOffset: 0, indexOffset: foliageStart, indexCount: allIndices.count - foliageStart)
        propMeshes[PropKind.foliageCard.rawValue] = foliageMesh
        propMeshes[PropKind.greeneryCard.rawValue] = foliageMesh   // M20: greenery reuses the crossed-card mesh

        // M20: a tall SINGLE card for the WenrexaTrees billboard sprites — a whole-tree sprite on a
        // 3-way cross shows three offset (often leaning) trunks; one card reads cleanly. (Not yet
        // camera-facing — fine for the front-viewed gallery; true billboarding is a later step.)
        let treeBBStart = allIndices.count
        Self.addFoliageCard(to: &allVerts, indices: &allIndices, ws: ws, height: 1.4, halfWidth: 0.5, cards: 1)
        propMeshes[PropKind.treeBillboard.rawValue] = TileMesh(vertexOffset: 0, indexOffset: treeBBStart, indexCount: allIndices.count - treeBBStart)

        // M19: full-tile ground quad for the natural register (grass/water) — tessellated so it
        // inflates smoothly on the curve, no path-cross split.
        let fieldStart = allIndices.count
        Self.addFieldFloor(to: &allVerts, indices: &allIndices, ws: ws)
        fieldFloor = TileMesh(vertexOffset: 0, indexOffset: fieldStart, indexCount: allIndices.count - fieldStart)

        let channelStart = allIndices.count
        Self.addFieldFloor(to: &allVerts, indices: &allIndices, ws: ws, normalisedUV: true, lift: 0.004)
        channelFloor = TileMesh(vertexOffset: 0, indexOffset: channelStart, indexCount: allIndices.count - channelStart)

        let orbStart = allIndices.count
        Self.addOrb(to: &allVerts, indices: &allIndices)
        orbMesh = TileMesh(vertexOffset: 0, indexOffset: orbStart, indexCount: allIndices.count - orbStart)

        let beamStart = allIndices.count
        Self.addBeam(to: &allVerts, indices: &allIndices)
        beamMesh = TileMesh(vertexOffset: 0, indexOffset: beamStart, indexCount: allIndices.count - beamStart)

        let bandStart = allIndices.count
        Self.addFieldFloor(to: &allVerts, indices: &allIndices, ws: ws, normalisedUV: true)
        bandFloor = TileMesh(vertexOffset: 0, indexOffset: bandStart, indexCount: allIndices.count - bandStart)

        // Celestial bodies (M9): a unit SPHERE, drawn at the sun/moon positions.
        //
        // They were cubes, which was a lovely joke and a spoiler (Eddie, 2026-08-07): the whole
        // prologue is the slow revelation that a world is a cube you can turn, and a cube hanging in
        // Scene 1's sky gives it away in the first thirty seconds. Suns and moons are round here —
        // it is the GROUND that turns out not to be.
        //
        // Nothing else changes: material 13 already lights the moon with `dot(normal, lightDir)`, so
        // a sphere yields real phases rather than the cube's faceted approximation of them.
        let cubeStart = allIndices.count
        Self.addOrb(to: &allVerts, indices: &allIndices)
        celestialCube = TileMesh(vertexOffset: 0, indexOffset: cubeStart, indexCount: allIndices.count - cubeStart)

        vertexBuffer = device.makeBuffer(
            bytes: allVerts,
            length: MemoryLayout<MazeVertexSwift>.stride * allVerts.count,
            options: .storageModeShared
        )!
        vertexBuffer.label = "TileMeshVertices"

        indexBuffer = device.makeBuffer(
            bytes: allIndices,
            length: MemoryLayout<UInt32>.stride * allIndices.count,
            options: .storageModeShared
        )!
        indexBuffer.label = "TileMeshIndices"
    }

    func floorMesh(for openings: DirectionMask, uvTurns: Int) -> TileMesh {
        return floorMeshes[Self.floorKey(openings, uvTurns)] ?? fogLayers[0]
    }

    /// Composite floor-mesh key: openings mask (low 4 bits) | quarter-turns (high 2 bits).
    private static func floorKey(_ openings: DirectionMask, _ uvTurns: Int) -> UInt8 {
        (openings.rawValue & 0x0F) | (UInt8(((uvTurns % 4) + 4) % 4) << 4)
    }

    func wallMesh(configKey: UInt8) -> TileMesh? {
        return wallMeshes[configKey]
    }

    func postMesh(configKey: UInt8) -> TileMesh? {
        return postMeshes[configKey]
    }

    func propMesh(kind: PropKind) -> TileMesh? {
        // M12-E: for .houseCorner this returns just the hip-roof cap; the walls are imported kit
        // meshes drawn through the asset path (Renderer). Both anchor to the same Prop, so roof and
        // walls move and split together. (A kit roof was tried but the kit has no 4-way hip piece.)
        return propMeshes[kind.rawValue]
    }

    /// The path-cross sub-cells (paved). `floorMesh` returns the propSpace remainder.
    func pathFloorMesh(for openings: DirectionMask, uvTurns: Int) -> TileMesh? {
        return pathFloorMeshes[Self.floorKey(openings, uvTurns)]
    }

    /// Decode a base-3 edge-config key (N,E,S,W) into the openings + open-edge masks.
    static func decodeEdgeConfig(_ key: UInt8) -> (openings: DirectionMask, openEdges: DirectionMask) {
        let k = Int(key)
        let states = [(k / 27) % 3, (k / 9) % 3, (k / 3) % 3, k % 3]  // N, E, S, W
        let dirs: [DirectionMask] = [.north, .east, .south, .west]
        var openings = DirectionMask(), openEdges = DirectionMask()
        for d in 0..<4 {
            if states[d] >= 1 { openings.insert(dirs[d]) }
            if states[d] == 2 { openEdges.insert(dirs[d]) }
        }
        return (openings, openEdges)
    }

    // MARK: - Geometry builders

    /// Emit the floor as 3×3 sub-cell quads, selecting either the path-cross cells
    /// (`path: true`) or the propSpace remainder (`path: false`) so each set can be
    /// drawn with its own material. UVs are continuous across the tile so textures
    /// tile seamlessly regardless of the split (M10 Phase C).
    private static func addFloorCells(to verts: inout [MazeVertexSwift], indices: inout [UInt32], openings: DirectionMask, uvTurns: Int, ws: WorldScale, path: Bool) {
        let hs = ws.floorHalfSize
        let z = ws.floorY
        let cell = 2.0 * hs / 3.0
        let tile = MazeTile(openings: openings, styleSeed: 0)

        // Rotate the UV sample point by −uvTurns quarter-turns about the tile center.
        // `openings.rotated(1)` is a local +90° turn (N→E→S→W); the ground texture must
        // counter-rotate by the same amount so it stays fixed to the tile's material as
        // the tile turns, cancelling the 90° UV jump at slice-rotation finalization.
        let turns = ((uvTurns % 4) + 4) % 4
        func uv(_ x: Float, _ y: Float) -> SIMD2<Float> {
            var rx = x, ry = y
            switch turns {
            case 1: rx =  y; ry = -x
            case 2: rx = -x; ry = -y
            case 3: rx = -y; ry =  x
            default: break
            }
            return SIMD2((rx + hs) * ws.uvScale, (ry + hs) * ws.uvScale)
        }

        // M14b: subdivide each sub-cell into an mf×mf grid so per-vertex inflation curves the floor
        // smoothly. UVs stay correct (uv() is linear in x,y) and sub-cell edges keep their exact
        // positions, so neighbouring tiles still share footprints — the curved surface stays seamless.
        let mf = max(1, ws.floorTess)
        for r in 0..<3 {
            for c in 0..<3 {
                guard tile.isPathCell(r, c) == path else { continue }
                let sx0 = -hs + Float(c) * cell
                let sy0 = -hs + Float(r) * cell
                let step = cell / Float(mf)
                for jr in 0..<mf {
                    for jc in 0..<mf {
                        let x0 = sx0 + Float(jc) * step, x1 = x0 + step
                        let y0 = sy0 + Float(jr) * step, y1 = y0 + step
                        let base = UInt32(verts.count)
                        verts.append(contentsOf: [
                            MazeVertexSwift(position: SIMD3(x0, y0, z), normal: SIMD3(0, 0, 1), texCoord: uv(x0, y0), aoFactor: 1.0),
                            MazeVertexSwift(position: SIMD3(x1, y0, z), normal: SIMD3(0, 0, 1), texCoord: uv(x1, y0), aoFactor: 1.0),
                            MazeVertexSwift(position: SIMD3(x1, y1, z), normal: SIMD3(0, 0, 1), texCoord: uv(x1, y1), aoFactor: 1.0),
                            MazeVertexSwift(position: SIMD3(x0, y1, z), normal: SIMD3(0, 0, 1), texCoord: uv(x0, y1), aoFactor: 1.0),
                        ])
                        indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
                    }
                }
            }
        }
    }

    /// Build one tile edge as a wall, a gateway (two stubs framing a centered gap), or
    /// nothing (`open`). Dispatches to `addWall` with the appropriate sub-span(s).
    private static func addEdgeWall(edge: SurfaceDirection, type: EdgeType, to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        switch type {
        case .wall:
            addWall(edge: edge, span: (0, 1), to: &verts, indices: &indices, ws: ws)
        case .gateway:
            let stub = (1.0 - ws.gatewayGapFraction) / 2.0
            addWall(edge: edge, span: (0, stub), to: &verts, indices: &indices, ws: ws)
            addWall(edge: edge, span: (1 - stub, 1), to: &verts, indices: &indices, ws: ws)
        case .open:
            break
        }
    }

    private static func addWall(edge: SurfaceDirection, span: (Float, Float), to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let hs = ws.tileMeshSize / 2.0
        let wt = ws.wallThickness
        let z0 = ws.floorY
        let z1 = ws.wallHeight

        var inner0: SIMD2<Float>, inner1: SIMD2<Float>
        var outer0: SIMD2<Float>, outer1: SIMD2<Float>
        var inN: SIMD3<Float>

        switch edge {
        case .north:
            inner0 = SIMD2( hs, -hs + wt)
            inner1 = SIMD2(-hs, -hs + wt)
            outer0 = SIMD2( hs, -hs)
            outer1 = SIMD2(-hs, -hs)
            inN = SIMD3(0, 1, 0)
        case .south:
            inner0 = SIMD2(-hs, hs - wt)
            inner1 = SIMD2( hs, hs - wt)
            outer0 = SIMD2(-hs, hs)
            outer1 = SIMD2( hs, hs)
            inN = SIMD3(0, -1, 0)
        case .east:
            inner0 = SIMD2(hs - wt,  hs)
            inner1 = SIMD2(hs - wt, -hs)
            outer0 = SIMD2(hs,  hs)
            outer1 = SIMD2(hs, -hs)
            inN = SIMD3(-1, 0, 0)
        case .west:
            inner0 = SIMD2(-hs + wt, -hs)
            inner1 = SIMD2(-hs + wt,  hs)
            outer0 = SIMD2(-hs, -hs)
            outer1 = SIMD2(-hs,  hs)
            inN = SIMD3(1, 0, 0)
        }

        // Restrict the wall to a sub-span of the edge (gateway stubs use two of these).
        let lerp: (SIMD2<Float>, SIMD2<Float>, Float) -> SIMD2<Float> = { a, b, t in a + (b - a) * t }
        (inner0, inner1) = (lerp(inner0, inner1, span.0), lerp(inner0, inner1, span.1))
        (outer0, outer1) = (lerp(outer0, outer1, span.0), lerp(outer0, outer1, span.1))

        let outN = -inN
        let aoBottom: Float = 0.55
        let aoTop: Float = 1.0

        // M14b: emit a bilinear nu×nv grid over corners a(s0,t0) b(s1,t0) c(s1,t1) d(s0,t1) — `s`
        // runs a→b (length), `t` runs a→d (height) — so per-vertex inflation can bend the face to
        // the curved floor. nu=nv=1 reproduces the old single quad exactly.
        func gridQuad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                      _ n: SIMD3<Float>,
                      _ uvA: SIMD2<Float>, _ uvB: SIMD2<Float>, _ uvC: SIMD2<Float>, _ uvD: SIMD2<Float>,
                      _ nu: Int, _ nv: Int) {
            func pos(_ s: Float, _ t: Float) -> SIMD3<Float> {
                let bot = a + (b - a) * s, top = d + (c - d) * s
                return bot + (top - bot) * t
            }
            func uvAt(_ s: Float, _ t: Float) -> SIMD2<Float> {
                let bot = uvA + (uvB - uvA) * s, top = uvD + (uvC - uvD) * s
                return bot + (top - bot) * t
            }
            func ao(_ p: SIMD3<Float>) -> Float { p.z > z0 + 0.01 ? aoTop : aoBottom }
            for i in 0..<nu {
                let s0 = Float(i) / Float(nu), s1 = Float(i + 1) / Float(nu)
                for j in 0..<nv {
                    let t0 = Float(j) / Float(nv), t1 = Float(j + 1) / Float(nv)
                    let p00 = pos(s0, t0), p10 = pos(s1, t0), p11 = pos(s1, t1), p01 = pos(s0, t1)
                    let base = UInt32(verts.count)
                    verts.append(contentsOf: [
                        MazeVertexSwift(position: p00, normal: n, texCoord: uvAt(s0, t0), aoFactor: ao(p00)),
                        MazeVertexSwift(position: p10, normal: n, texCoord: uvAt(s1, t0), aoFactor: ao(p10)),
                        MazeVertexSwift(position: p11, normal: n, texCoord: uvAt(s1, t1), aoFactor: ao(p11)),
                        MazeVertexSwift(position: p01, normal: n, texCoord: uvAt(s0, t1), aoFactor: ao(p01)),
                    ])
                    indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
                }
            }
        }

        let lw = max(1, ws.wallTessLen)
        let hw = max(1, ws.wallTessHeight)
        let wallU = ws.tileMeshSize * ws.uvScale * (span.1 - span.0)
        let wallV = (z1 - z0) * ws.uvScale
        let capU = wt * ws.uvScale

        // Inner face
        gridQuad(SIMD3(inner0.x, inner0.y, z0), SIMD3(inner1.x, inner1.y, z0),
                 SIMD3(inner1.x, inner1.y, z1), SIMD3(inner0.x, inner0.y, z1), inN,
                 SIMD2(0, 0), SIMD2(wallU, 0), SIMD2(wallU, wallV), SIMD2(0, wallV), lw, hw)
        // Outer face
        gridQuad(SIMD3(outer1.x, outer1.y, z0), SIMD3(outer0.x, outer0.y, z0),
                 SIMD3(outer0.x, outer0.y, z1), SIMD3(outer1.x, outer1.y, z1), outN,
                 SIMD2(0, 0), SIMD2(wallU, 0), SIMD2(wallU, wallV), SIMD2(0, wallV), lw, hw)
        // Rounded top cap — semicircular arc from inner to outer edge (subdivided along length too)
        let arcSegments = 6
        let arcRadius = wt / 2.0
        let thickDir = normalize(SIMD2<Float>(outer0.x - inner0.x, outer0.y - inner0.y))
        let mid0 = (inner0 + outer0) / 2.0
        let mid1 = (inner1 + outer1) / 2.0
        for i in 0..<arcSegments {
            let theta0 = Float.pi * (1.0 - Float(i) / Float(arcSegments))
            let theta1 = Float.pi * (1.0 - Float(i + 1) / Float(arcSegments))
            let cos0 = cosf(theta0), sin0 = sinf(theta0)
            let cos1 = cosf(theta1), sin1 = sinf(theta1)
            let a = SIMD3<Float>(mid0.x + thickDir.x * arcRadius * cos0,
                                 mid0.y + thickDir.y * arcRadius * cos0,
                                 z1 + arcRadius * sin0)
            let b = SIMD3<Float>(mid1.x + thickDir.x * arcRadius * cos0,
                                 mid1.y + thickDir.y * arcRadius * cos0,
                                 z1 + arcRadius * sin0)
            let c = SIMD3<Float>(mid1.x + thickDir.x * arcRadius * cos1,
                                 mid1.y + thickDir.y * arcRadius * cos1,
                                 z1 + arcRadius * sin1)
            let d = SIMD3<Float>(mid0.x + thickDir.x * arcRadius * cos1,
                                 mid0.y + thickDir.y * arcRadius * cos1,
                                 z1 + arcRadius * sin1)
            let midTheta = (theta0 + theta1) / 2.0
            let arcNormal = SIMD3<Float>(thickDir.x * cosf(midTheta),
                                         thickDir.y * cosf(midTheta),
                                         sinf(midTheta))
            let arcV0 = wallV + sin0 * arcRadius * ws.uvScale
            let arcV1 = wallV + sin1 * arcRadius * ws.uvScale
            gridQuad(a, b, c, d, arcNormal,
                     SIMD2(0, arcV0), SIMD2(wallU, arcV0), SIMD2(wallU, arcV1), SIMD2(0, arcV1), lw, 1)
        }
        // End cap at p0 side (narrow — subdivide in height only)
        let capN0 = SIMD3<Float>(normalize(SIMD2(inner0.x - inner1.x, inner0.y - inner1.y)), 0)
        gridQuad(SIMD3(outer0.x, outer0.y, z0), SIMD3(inner0.x, inner0.y, z0),
                 SIMD3(inner0.x, inner0.y, z1), SIMD3(outer0.x, outer0.y, z1), capN0,
                 SIMD2(0, 0), SIMD2(capU, 0), SIMD2(capU, wallV), SIMD2(0, wallV), 1, hw)
        // End cap at p1 side
        let capN1 = -capN0
        gridQuad(SIMD3(inner1.x, inner1.y, z0), SIMD3(outer1.x, outer1.y, z0),
                 SIMD3(outer1.x, outer1.y, z1), SIMD3(inner1.x, inner1.y, z1), capN1,
                 SIMD2(0, 0), SIMD2(capU, 0), SIMD2(capU, wallV), SIMD2(0, wallV), 1, hw)
    }

    // MARK: - Celestial (M9)


    // MARK: - Props (M10 Phase G)

    /// A hedge-sculpture topiary: a slightly squashed ball resting on the floor, sized to
    /// sit inside one 3×3 sub-cell (~0.33 wide) with margin. Wound CCW-outward (front-face
    /// culled) like the walls/posts; single-colour, tinted per-instance by SceneBuilder.
    private static func addTopiary(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let rXY: Float = 0.11
        let rZ: Float = 0.12
        let cz = ws.floorY + rZ          // rest the ball on the floor
        let nLon = 8, nLat = 6

        func sph(_ theta: Float, _ phi: Float) -> SIMD3<Float> {
            SIMD3(rXY * sinf(theta) * cosf(phi), rXY * sinf(theta) * sinf(phi), cz + rZ * cosf(theta))
        }
        func vtx(_ p: SIMD3<Float>) -> MazeVertexSwift {
            // Ellipsoid gradient → outward normal.
            let n = normalize(SIMD3(p.x / (rXY * rXY), p.y / (rXY * rXY), (p.z - cz) / (rZ * rZ)))
            let ao = 0.55 + 0.45 * max(0, min(1, (p.z - ws.floorY) / (2 * rZ)))  // darker at the base
            return MazeVertexSwift(position: p, normal: n, texCoord: SIMD2(0, 0), aoFactor: ao)
        }

        for lat in 0..<nLat {
            let t0 = Float.pi * Float(lat) / Float(nLat)
            let t1 = Float.pi * Float(lat + 1) / Float(nLat)
            for lon in 0..<nLon {
                let p0 = 2 * Float.pi * Float(lon) / Float(nLon)
                let p1 = 2 * Float.pi * Float(lon + 1) / Float(nLon)
                // CCW from outside: lower-left → lower-right → upper-right → upper-left.
                let a = sph(t1, p0), b = sph(t1, p1), c = sph(t0, p1), d = sph(t0, p0)
                let base = UInt32(verts.count)
                verts.append(contentsOf: [vtx(a), vtx(b), vtx(c), vtx(d)])
                indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
            }
        }
    }

    /// A tall obelisk landmark — a slightly tapered square shaft capped with a pyramidion,
    /// rising well above the hedges (~1.16 vs wall 0.24) so it reads across the maze. Thin
    /// enough (~0.12 wide) to sit in a sub-cell. Wound CCW-outward with true face normals. (G3)
    private static func addObelisk(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let z0 = ws.floorY
        let shaftTop: Float = 0.92
        let tip: Float = 1.16
        let baseH: Float = 0.062
        let topH: Float = 0.044

        func ring(_ h: Float, _ z: Float) -> [SIMD3<Float>] {
            [SIMD3(-h, -h, z), SIMD3(h, -h, z), SIMD3(h, h, z), SIMD3(-h, h, z)]
        }
        func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> MazeVertexSwift {
            let ao = 0.5 + 0.5 * max(0, min(1, (p.z - z0) / tip))
            return MazeVertexSwift(position: p, normal: n, texCoord: SIMD2(0, 0), aoFactor: ao)
        }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            let n = normalize(cross(b - a, d - a))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [vtx(a, n), vtx(b, n), vtx(c, n), vtx(d, n)])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            let n = normalize(cross(b - a, c - a))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [vtx(a, n), vtx(b, n), vtx(c, n)])
            indices.append(contentsOf: [base+0, base+1, base+2])
        }

        let b = ring(baseH, z0)
        let t = ring(topH, shaftTop)
        let apex = SIMD3<Float>(0, 0, tip)
        for i in 0..<4 {
            let j = (i + 1) % 4
            quad(b[i], b[j], t[j], t[i])   // shaft side
            tri(t[i], t[j], apex)          // pyramidion face
        }
    }

    /// M19 — a single conifer: a stack of two green cones, grounded at floorY. Groves are made by
    /// scattering SEVERAL of these props at random offsets across a tile (CubeModel.stampNatural),
    /// so every grove is arranged differently. SceneBuilder scales/jitters each per instance.
    private static func addTree(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let z0 = ws.floorY
        let top: Float = 0.42
        let seg = 9
        let cones: [(Float, Float, Float)] = [
            (z0,          z0 + 0.26, 0.15),
            (z0 + 0.18,   top,       0.10),
        ]
        func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> MazeVertexSwift {
            let ao = 0.5 + 0.5 * max(0, min(1, (p.z - z0) / (top - z0)))
            return MazeVertexSwift(position: p, normal: n, texCoord: SIMD2(0, 0), aoFactor: ao)
        }
        for (bz, tz, r) in cones {
            let apex = SIMD3<Float>(0, 0, tz)
            for i in 0..<seg {
                let a0 = 2 * Float.pi * Float(i) / Float(seg)
                let a1 = 2 * Float.pi * Float(i + 1) / Float(seg)
                let p0 = SIMD3<Float>(r * cosf(a0), r * sinf(a0), bz)
                let p1 = SIMD3<Float>(r * cosf(a1), r * sinf(a1), bz)
                let n = normalize(cross(p1 - p0, apex - p0))
                let base = UInt32(verts.count)
                verts.append(contentsOf: [vtx(p0, n), vtx(p1, n), vtx(apex, n)])
                indices.append(contentsOf: [base + 0, base + 1, base + 2])
            }
        }
    }

    /// M20 — a leafy bush/tree as crossed **billboard cards**: 3 vertical quads at 60° apart,
    /// each emitted DOUBLE-SIDED (front + back winding) so both faces light correctly. Rendered
    /// with the alpha-cutout foliage material (17), which discards the gaps in a leaf mask — so
    /// this reads as leaves, not solid quads. UVs 0..1 per card (a real leaf texture drops straight
    /// in later; for now the mask is procedural). Rises from the floor; SceneBuilder scales it.
    private static func addFoliageCard(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale,
                                       height: Float = 0.40, halfWidth: Float = 0.16, cards: Int = 3) {
        let z0 = ws.floorY
        let h = height                // card height (bush/small-tree)
        let hw = halfWidth            // half-width
        func quad(_ ax: Float, _ ay: Float) {
            // A vertical card spanning [-hw,hw] along (ax,ay), from z0 to z0+h. Emit both windings.
            let x0 = -ax * hw, y0 = -ay * hw
            let x1 =  ax * hw, y1 =  ay * hw
            let n = normalize(SIMD3<Float>(-ay, ax, 0))     // card face normal (in-plane, horizontal)
            func v(_ x: Float, _ y: Float, _ z: Float, _ u: Float, _ vv: Float, _ nn: SIMD3<Float>) -> MazeVertexSwift {
                MazeVertexSwift(position: SIMD3(x, y, z), normal: nn, texCoord: SIMD2(u, vv), aoFactor: 0.6 + 0.4 * ((z - z0) / h))
            }
            // Front face (normal n), CCW.
            var base = UInt32(verts.count)
            verts.append(contentsOf: [
                v(x0, y0, z0, 0, 0, n), v(x1, y1, z0, 1, 0, n), v(x1, y1, z0 + h, 1, 1, n), v(x0, y0, z0 + h, 0, 1, n),
            ])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
            // Back face (normal -n), reversed winding.
            base = UInt32(verts.count)
            verts.append(contentsOf: [
                v(x0, y0, z0, 0, 0, -n), v(x0, y0, z0 + h, 0, 1, -n), v(x1, y1, z0 + h, 1, 1, -n), v(x1, y1, z0, 1, 0, -n),
            ])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }
        for i in 0..<cards {
            let a = Float.pi * Float(i) / Float(cards)      // 0, 60, 120°
            quad(cosf(a), sinf(a))
        }
    }

    /// M19 — a short brown trunk (a squat octagonal post) under a tree. Its own prop kind so it
    /// takes the brown instance colour; the tree cone sits on top. This is the solid part.
    private static func addTreeTrunk(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let z0 = ws.floorY
        let z1 = ws.floorY + 0.06
        let r: Float = 0.028
        let seg = 8
        func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> MazeVertexSwift {
            MazeVertexSwift(position: p, normal: n, texCoord: SIMD2(0, 0), aoFactor: p.z > z0 + 0.001 ? 1.0 : 0.6)
        }
        for i in 0..<seg {
            let a0 = 2 * Float.pi * Float(i) / Float(seg)
            let a1 = 2 * Float.pi * Float(i + 1) / Float(seg)
            let c0 = SIMD3<Float>(cosf(a0), sinf(a0), 0), c1 = SIMD3<Float>(cosf(a1), sinf(a1), 0)
            let b0 = SIMD3<Float>(r * c0.x, r * c0.y, z0), b1 = SIMD3<Float>(r * c1.x, r * c1.y, z0)
            let t0 = SIMD3<Float>(r * c0.x, r * c0.y, z1), t1 = SIMD3<Float>(r * c1.x, r * c1.y, z1)
            let n = normalize(SIMD3<Float>(cosf((a0 + a1) / 2), sinf((a0 + a1) / 2), 0))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [vtx(b0, n), vtx(b1, n), vtx(t1, n), vtx(t0, n)])
            indices.append(contentsOf: [base + 0, base + 1, base + 2, base + 0, base + 2, base + 3])
        }
    }

    /// M19 — a moon boulder: an angular rock **settled into the regolith** — only the top shows,
    /// the bottom is buried (Eddie, from Apollo surface photos). Built as an irregular sphere
    /// centred at ground level with everything below the surface clamped flat to it, so the rock
    /// emerges as a dome with a flush base and never pokes below the ground at any angle. Coarse
    /// facets + per-vertex radius jitter read as a fractured rock, not a ball. Grey via the
    /// instance colour, darker at the base (contact shadow). SceneBuilder scales per `state`.
    private static func addBoulder(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let rXY: Float = 0.11
        let rZ: Float = 0.10           // full radius; ~half is buried, so the emerged dome ≈ rZ tall
        let cz = ws.floorY             // centre AT the ground → bottom hemisphere is below it (buried)
        let nLon = 8, nLat = 6
        func jitter(_ a: Int, _ b: Int) -> Float {
            var v = UInt32(truncatingIfNeeded: a &* 48611 ^ b &* 24989); v ^= v >> 13
            return 0.74 + 0.42 * Float(v & 0xFF) / 255.0     // 0.74…1.16 — angular, not round
        }
        func p(_ lat: Int, _ lon: Int) -> SIMD3<Float> {
            let theta = Float.pi * Float(lat) / Float(nLat)
            let phi = 2 * Float.pi * Float(lon % nLon) / Float(nLon)
            let j = jitter(lat, lon % nLon)
            let z = cz + rZ * j * cosf(theta)
            // Clamp anything below the surface up onto it — the buried half becomes a flat base.
            return SIMD3(rXY * j * sinf(theta) * cosf(phi), rXY * j * sinf(theta) * sinf(phi), max(ws.floorY, z))
        }
        func vtx(_ q: SIMD3<Float>) -> MazeVertexSwift {
            let dz = q.z - ws.floorY                        // height above the ground
            let horiz = length(SIMD2(q.x, q.y))
            let n: SIMD3<Float>
            if horiz < 1e-5 {
                n = SIMD3(0, 0, 1)                          // apex / buried centre → up (never zero)
            } else if dz < 1e-5 {
                n = normalize(SIMD3(q.x, q.y, 0.35))        // base ring → up-and-out
            } else {
                n = normalize(SIMD3(q.x, q.y, dz))          // emerged dome → out along the slope
            }
            let ao = 0.4 + 0.6 * max(0, min(1, dz / rZ))
            return MazeVertexSwift(position: q, normal: n, texCoord: SIMD2(0, 0), aoFactor: ao)
        }
        for lat in 0..<nLat {
            for lon in 0..<nLon {
                let a = p(lat + 1, lon), b = p(lat + 1, lon + 1), c = p(lat, lon + 1), d = p(lat, lon)
                let base = UInt32(verts.count)
                verts.append(contentsOf: [vtx(a), vtx(b), vtx(c), vtx(d)])
                indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
            }
        }
    }

    /// M19 — a full-tile ground quad, tessellated like the maze floor (3·floorTess per axis) so
    /// per-vertex inflation curves it smoothly. UVs continuous. Used for grass and water tiles.
    /// `normalisedUV` emits (u,v) running 0…1 across the tile instead of the texture-tiling UVs
    /// (`uvScale`-scaled) the grass wants. An overlay that draws "a stripe down the middle" has to
    /// measure in tile fractions; with the tiling UVs, uv 0.5 is a quarter of the way across at
    /// uvScale 2, which is exactly how the bond bands ended up as a thin off-centre line.
    private static func addFieldFloor(to verts: inout [MazeVertexSwift], indices: inout [UInt32],
                                      ws: WorldScale, normalisedUV: Bool = false, lift: Float = 0) {
        let hs = ws.floorHalfSize
        // `lift` raises the quad in LOCAL z. Lifting the model MATRIX is what an overlay wants
        // on a flat world, but on a rounded one the inflation projects the footprint back onto the
        // shell and the offset is simply lost — so the overlay z-fights the ground it sits on, which
        // is why Scene 5's channels were invisible. Local z survives: the inflation extrudes height
        // along the curved normal.
        let z = ws.floorY + lift
        let n = max(1, ws.floorTess) * 3     // match the maze floor's per-tile vertex density
        let step = 2 * hs / Float(n)
        for jr in 0..<n {
            for jc in 0..<n {
                let x0 = -hs + Float(jc) * step, x1 = x0 + step
                let y0 = -hs + Float(jr) * step, y1 = y0 + step
                func uv(_ x: Float, _ y: Float) -> SIMD2<Float> {
                    normalisedUV ? SIMD2((x + hs) / (2 * hs), (y + hs) / (2 * hs))
                                 : SIMD2((x + hs) * ws.uvScale, (y + hs) * ws.uvScale)
                }
                let base = UInt32(verts.count)
                verts.append(contentsOf: [
                    MazeVertexSwift(position: SIMD3(x0, y0, z), normal: SIMD3(0, 0, 1), texCoord: uv(x0, y0), aoFactor: 1.0),
                    MazeVertexSwift(position: SIMD3(x1, y0, z), normal: SIMD3(0, 0, 1), texCoord: uv(x1, y0), aoFactor: 1.0),
                    MazeVertexSwift(position: SIMD3(x1, y1, z), normal: SIMD3(0, 0, 1), texCoord: uv(x1, y1), aoFactor: 1.0),
                    MazeVertexSwift(position: SIMD3(x0, y1, z), normal: SIMD3(0, 0, 1), texCoord: uv(x0, y1), aoFactor: 1.0),
                ])
                indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
            }
        }
    }

    /// A portal marker (M11.2) — a TARDIS-style police box: a tall blue body with a tented (pyramid)
    /// roof, taller than the hedges so it's easy to spot. A separate `portalLamp` prop sits at the
    /// apex and flashes. Interacting (F) or stepping onto its tile switches worlds. Wound CCW-outward.
    /// The police box — now that every OTHER door is a frameless disc, this one is deliberately an
    /// object: the dev hub's boxes are a joke the game is in on, and the prologue's red DARSIT doors
    /// are the same joke wearing a different coat. Eddie asked for more of the real thing, so the
    /// silhouette earns its reference: corner posts, a stepped roof, the sign band, and windows in
    /// the top quarter of every face.
    ///
    /// One baseColor for the whole prop, so every distinction here is carried by `aoFactor` — posts
    /// darker than panels, the band lighter, the windows brightest. That is the only shading channel
    /// a single-colour prop has, and it turns out to be enough for a shape this familiar.
    private static func addPortal(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let z0 = ws.floorY
        // LIFE SIZE — 2.17 m to the apex, Eddie's number for a real police box.
        //
        // These were authored by eye against the hedges and nothing ever checked them against a
        // person: the apex sat at 0.50 local, and a facelet is ~19.5 m (`WorldScale.metre` (`ws.metre`)), so the
        // box stood 9.7 m — four and a half times life size. "How tall are these things? I feel
        // like a midget or an insect next to them. The real tardis is only a little over 2 meters
        // high (217 cms)."
        //
        // The proportions were right, so they are kept and scaled as one: every height is measured
        // from the floor, multiplied, and put back. Widths take the same factor, which lands the
        // footprint at ~1.9 m square against a real box's 1.37 m — near enough, and a door narrower
        // than a single 1.3 m pace would be hard to read at all.
        let vertexStart = verts.count   // everything below is rescaled as one at the end
        let bodyTop: Float = 0.40       // top of the box body
        let bandTop: Float = 0.425      // the POLICE BOX sign band
        let roof1: Float = 0.445        // first roof slab
        let roof2: Float = 0.462        // second, narrower slab
        let roofTop: Float = 0.50       // apex of the tented roof
        let h: Float = 0.11             // body half-width (squarish police-box footprint)
        let postW: Float = 0.016        // corner post thickness
        let proud: Float = 0.004        // how far posts/band/panes stand off the body

        func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ ao: Float) -> MazeVertexSwift {
            MazeVertexSwift(position: p, normal: n, texCoord: SIMD2(0, 0), aoFactor: ao)
        }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ ao: Float) {
            let n = normalize(cross(b - a, d - a))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [vtx(a, n, ao), vtx(b, n, ao), vtx(c, n, ao), vtx(d, n, ao)])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ ao: Float) {
            let n = normalize(cross(b - a, c - a))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [vtx(a, n, ao), vtx(b, n, ao), vtx(c, n, ao)])
            indices.append(contentsOf: [base+0, base+1, base+2])
        }
        /// A box given by half-extents and a z range — posts, slabs and the band are all boxes.
        func box(hx: Float, hy: Float, z0 zA: Float, z1 zB: Float, cx: Float = 0, cy: Float = 0, ao: Float) {
            let p = [SIMD3<Float>(cx-hx, cy-hy, zA), SIMD3(cx+hx, cy-hy, zA),
                     SIMD3(cx+hx, cy+hy, zA), SIMD3(cx-hx, cy+hy, zA)]
            let q = p.map { SIMD3($0.x, $0.y, zB) }
            for i in 0..<4 { let j = (i + 1) % 4; quad(p[i], p[j], q[j], q[i], ao) }
            quad(q[0], q[1], q[2], q[3], ao * 1.05)     // lid
        }

        // Body panels, then the four corner posts standing proud of them.
        box(hx: h, hy: h, z0: z0, z1: bodyTop, ao: 0.62)
        for sx in [Float(-1), 1] {
            for sy in [Float(-1), 1] {
                box(hx: postW, hy: postW, z0: z0, z1: bandTop,
                    cx: sx * (h - postW + proud), cy: sy * (h - postW + proud), ao: 0.42)
            }
        }
        // The sign band, and the two roof slabs stepping in toward the apex.
        box(hx: h + proud, hy: h + proud, z0: bodyTop, z1: bandTop, ao: 0.92)
        box(hx: h + 0.008, hy: h + 0.008, z0: bandTop, z1: roof1, ao: 0.70)
        box(hx: h - 0.004, hy: h - 0.004, z0: roof1, z1: roof2, ao: 0.60)

        // Windows: four panes in the top quarter of each face, standing just proud so they catch
        // the light as separate surfaces rather than reading as paint.
        let winB: Float = 0.30, winT: Float = 0.375
        for face in 0..<4 {
            let mid = (winB + winT) * 0.5
            for (i, uOff) in [Float(-0.052), -0.018, 0.018, 0.052].enumerated() {
                for (zA, zB) in [(winB, mid - 0.003), (mid + 0.003, winT)] {
                    let w: Float = 0.014
                    let ao: Float = 1.0 - Float(i % 2) * 0.06     // faint pane-to-pane variation
                    switch face {
                    case 0: box(hx: w, hy: proud, z0: zA, z1: zB, cx: uOff, cy: -(h + proma()), ao: ao)
                    case 1: box(hx: proud, hy: w, z0: zA, z1: zB, cx:  (h + proma()), cy: uOff, ao: ao)
                    case 2: box(hx: w, hy: proud, z0: zA, z1: zB, cx: uOff, cy:  (h + proma()), ao: ao)
                    default: box(hx: proud, hy: w, z0: zA, z1: zB, cx: -(h + proma()), cy: uOff, ao: ao)
                    }
                }
            }
        }

        // The tented pyramid, from the narrower upper slab.
        let ht = h - 0.004
        let t = [SIMD3<Float>(-ht, -ht, roof2), SIMD3(ht, -ht, roof2), SIMD3(ht, ht, roof2), SIMD3(-ht, ht, roof2)]
        let apex = SIMD3<Float>(0, 0, roofTop)
        for i in 0..<4 { let j = (i + 1) % 4; tri(t[i], t[j], apex, 0.55) }

        // ── LIFE SIZE, APPLIED TO THE GEOMETRY RATHER THAN TO THE NUMBERS ──────────────
        //
        // 2.17 m to the apex, Eddie's figure for a real police box. The shape above was authored by
        // eye against the hedges and nothing ever checked it against a person: a facelet is ~19.5 m
        // (`WorldScale.metre` (`ws.metre`)), so an apex at 0.50 stood 9.7 m — four and a half times life size.
        //
        // Scaling the CONSTANTS was the obvious fix and the wrong one. There are a dozen more of
        // them below the frame — panels, panes, the sign band, the door furniture — and I scaled the
        // first eight and missed the rest, so the box shrank and its door panels stayed hanging in
        // the sky at the old roofline. Eddie recognised them from a photograph; I had reported them
        // as unidentified.
        //
        // So the scale is applied here, once, to every vertex this function emitted. A uniform
        // scale about (0, 0, floor) leaves the normals correct, and nothing authored above — now or
        // later — can be left behind.
        let k = Self.policeBoxScale(ws: ws)
        for i in vertexStart..<verts.count {
            var v = verts[i]
            v.position = SIMD3(v.position.x * k, v.position.y * k, z0 + (v.position.z - z0) * k)
            verts[i] = v
        }
    }

    /// How far a window pane stands off the body. Named rather than inlined because it appears eight
    /// times and a mismatch shows up as z-fighting rather than as a wrong number.
    private static func proma() -> Float { 0.002 }

    /// THE PORTAL DISC. Every door in the game is now the same object: a vertical circle showing
    /// what is on the other side, ringed by a wormhole swirl, and attached to nothing.
    ///
    /// Eddie's reasoning (2026-08-06) is better than the arches were: these openings are projections
    /// the Builders make, so *"why would there be stonework?"* A masonry arch is a human idea about
    /// doors — and so is up and down, which makes Scene 2→3→4 "descending" our metaphor rather than
    /// theirs. A circular aperture attached to no architecture says "something was opened here"
    /// without claiming anyone built a wall around it.
    ///
    /// Sunk 10% of its diameter below the floor so it reads as planted rather than hovering: the job
    /// the glowing ground ring used to do, done by the shape itself.
    // The numbers live in `PortalDisc` (model layer) so Scene 3's beam can aim at the top of a shape
    // the renderer builds. See WorldScale.swift.
    static var portalDiscRadius: Float { PortalDisc.radius }

    private static func addPortalDisc(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let r = PortalDisc.radius
        let cz = PortalDisc.centre(floorY: ws.floorY)   // bottom sits under the ground
        let seg = 64
        // texCoord spans the disc's BOUNDING SQUARE, so the shader reads radius as
        // `length(uv - 0.5) * 2`, and a square capture maps 1:1 — a circle is the one shape whose
        // bounding box needs no cover-fit at all. (The rectangular veil needed one, and I got the
        // axis backwards; the geometry choice deletes the question.)
        func v(_ x: Float, _ z: Float, _ n: SIMD3<Float>) -> MazeVertexSwift {
            MazeVertexSwift(position: SIMD3(x, 0, z), normal: n,
                            texCoord: SIMD2(0.5 + x / (2 * r), 0.5 + (z - cz) / (2 * r)), aoFactor: 1.0)
        }
        for (n, flip) in [(SIMD3<Float>(0, -1, 0), false), (SIMD3<Float>(0, 1, 0), true)] {
            let centre = UInt32(verts.count)
            verts.append(v(0, cz, n))
            for i in 0...seg {
                let a = Float(i) / Float(seg) * 2 * .pi
                verts.append(v(cos(a) * r, cz + sin(a) * r, n))
            }
            for i in 0..<seg {
                let a = centre + 1 + UInt32(i), b = centre + 2 + UInt32(i)
                if flip { indices.append(contentsOf: [centre, b, a]) }
                else    { indices.append(contentsOf: [centre, a, b]) }
            }
        }
    }

    /// M20 (Eddie) — a wooden SIGNPOST naming a portal: a square post + a square board whose FRONT
    /// face (facing +Y, toward a player approaching from the south) carries the label (texCoord u,v in
    /// [0,1] → material 24 samples the label array by `state`). Every other face flags wood (u = −1).
    private static func addSignpost(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let z0 = ws.floorY
        let signVertexStart = verts.count   // rescaled as one at the end — see below
        let ph: Float = 0.012                 // post half-thickness
        let boardBot = z0 + 0.06              // board sits at the top of the post
        let bw: Float = 0.055, bt: Float = 0.008, boardTop = boardBot + 0.11   // ~square board
        func v(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ u: Float, _ w: Float) -> MazeVertexSwift {
            MazeVertexSwift(position: p, normal: n, texCoord: SIMD2(u, w), aoFactor: 0.95)
        }
        func woodQuad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            let n = normalize(cross(b - a, d - a))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [v(a, n, -1, -1), v(b, n, -1, -1), v(c, n, -1, -1), v(d, n, -1, -1)])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }
        func woodBox(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) {
            let x0 = lo.x, y0 = lo.y, zb = lo.z, x1 = hi.x, y1 = hi.y, zt = hi.z
            woodQuad(SIMD3(x0,y0,zb), SIMD3(x1,y0,zb), SIMD3(x1,y0,zt), SIMD3(x0,y0,zt))   // −Y
            woodQuad(SIMD3(x1,y1,zb), SIMD3(x0,y1,zb), SIMD3(x0,y1,zt), SIMD3(x1,y1,zt))   // +Y
            woodQuad(SIMD3(x1,y0,zb), SIMD3(x1,y1,zb), SIMD3(x1,y1,zt), SIMD3(x1,y0,zt))   // +X
            woodQuad(SIMD3(x0,y1,zb), SIMD3(x0,y0,zb), SIMD3(x0,y0,zt), SIMD3(x0,y1,zt))   // −X
            woodQuad(SIMD3(x0,y0,zt), SIMD3(x1,y0,zt), SIMD3(x1,y1,zt), SIMD3(x0,y1,zt))   // +Z top
            woodQuad(SIMD3(x0,y1,zb), SIMD3(x1,y1,zb), SIMD3(x1,y0,zb), SIMD3(x0,y0,zb))   // −Z bottom
        }
        woodBox(SIMD3(-ph, -ph, z0), SIMD3(ph, ph, boardBot + 0.02))   // post
        woodBox(SIMD3(-bw, -bt, boardBot), SIMD3(bw, bt, boardTop))    // board (wood; the +Y face is hidden by the label below)
        // Label face, proud of the board on +Y. The viewer faces the sign looking −Y, so THEIR left is
        // +X — the text's left edge (u=0) must map to +X, else it reads mirrored (Eddie). v: 0 top(+Z).
        let y1 = bt + 0.001, n = SIMD3<Float>(0, 1, 0)
        let base = UInt32(verts.count)
        verts.append(contentsOf: [
            v(SIMD3( bw, y1, boardBot), n, 0, 1),   // +X, viewer-left, text-left  → u=0, bottom
            v(SIMD3(-bw, y1, boardBot), n, 1, 1),   // −X, viewer-right, text-right → u=1, bottom
            v(SIMD3(-bw, y1, boardTop), n, 1, 0),   // −X → u=1, top
            v(SIMD3( bw, y1, boardTop), n, 0, 0),   // +X → u=0, top
        ])
        indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])

        // ── HUMAN SIZE ────────────────────────────────────────────────────────────────
        //
        // These stood 3.3 m to the top of a board 2.1 m square — half again taller than a real
        // police box, with a board about the size of the box's whole front. Nobody had noticed
        // because nothing in the engine could be measured until `WorldScale.metre` (`ws.metre`) existed; the
        // sign and the box had only ever been sized against each other.
        //
        // Scaled UNIFORMLY and as vertices, for two reasons. The board carries rendered text from
        // `labelArray`, so squashing its aspect would squash the words; and scaling constants is
        // exactly how the police box shrank while its door panels stayed in the sky.
        //
        // The plaza was pulled in to match (`stampPortalHub`) — a smaller sign you can reach is
        // worth more than a billboard you can read from a hundred metres.
        let signTop: Float = 2.2 * ws.metre
        let k = signTop / (boardTop - z0)
        for i in signVertexStart..<verts.count {
            var v = verts[i]
            v.position = SIMD3(v.position.x * k, v.position.y * k, z0 + (v.position.z - z0) * k)
            verts[i] = v
        }
    }


    /// The flashing lamp atop the portal (M11.2 / TARDIS) — a tiny box sitting at the roof apex.
    /// SceneBuilder renders it emissive (materialID 12) with a blinking brightness, so it reads as a
    /// beacon "about to take off". Its own prop so it can animate independently of the blue body.
    /// M16.3: a squat stone lock-dial — pedestal, dial plate, and a pointer wedge toward local
    /// north (−y). The prop's `facing` rotates the whole mesh (existing machinery), so the pointer
    /// direction IS the dial's setting; interact turns it to north.
    private static func addDial(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let z0 = ws.floorY
        func box(_ hx: Float, _ hy: Float, _ cy: Float, _ zb: Float, _ zt: Float) {
            let corners = [SIMD3<Float>(-hx, cy - hy, 0), SIMD3<Float>(hx, cy - hy, 0),
                           SIMD3<Float>(hx, cy + hy, 0), SIMD3<Float>(-hx, cy + hy, 0)]
            func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> MazeVertexSwift {
                MazeVertexSwift(position: p, normal: n, texCoord: SIMD2(0, 0), aoFactor: 0.9)
            }
            func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
                let n = normalize(cross(b - a, d - a))
                let base = UInt32(verts.count)
                verts.append(contentsOf: [vtx(a, n), vtx(b, n), vtx(c, n), vtx(d, n)])
                indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
            }
            let b0 = corners.map { SIMD3($0.x, $0.y, zb) }
            let t0 = corners.map { SIMD3($0.x, $0.y, zt) }
            for i in 0..<4 {
                let j = (i + 1) % 4
                quad(b0[i], b0[j], t0[j], t0[i])          // side
            }
            quad(t0[3], t0[2], t0[1], t0[0])              // top (wound to face +z)
        }
        box(0.085, 0.085, 0, z0, z0 + 0.045)              // pedestal
        box(0.065, 0.065, 0, z0 + 0.045, z0 + 0.065)      // dial plate
        box(0.015, 0.024, -0.042, z0 + 0.065, z0 + 0.090) // pointer wedge, toward local north (−y)
    }

    /// M16.5: the first carved Builder glyph — an upright stone plaque bearing a frozen 4D
    /// cross-section (the cell-first tesseract shadow: a square within a square, corners joined)
    /// as raised linework. The language's first public appearance — presence, not system (see
    /// `Mazen Docs/Builder Glyphs — 4D Shadows.md`). All linework is double-sided, so winding
    /// never hides a stroke.
    /// Plinth height in metres — shared by the plinth mesh and by everything that stands on it (the
    /// rotator pipes, the switch cap), so their bases are planted exactly on the plinth top.
    static let plinthHeightM: Float = 0.9
    /// M16.6 (Eddie) — the switch cap's height when DISENGAGED (a flush disc) and ENGAGED (poking
    /// out). The cap mesh is built at the engaged height; SceneBuilder scales Z between these by the
    /// cap's `anim`, so ONE cylinder is the disc (min) and the raised switch (max) — no separate disc.
    static let switchCapFlushM: Float = 0.05
    static let switchCapOutM: Float = 0.35

    /// M16.6 (Eddie) — the switch's disc-less plinth base (the cap provides the top). Same tapered
    /// grey-metallic form as the plinth, minus the glyph disc.
    private static func addSwitchBase(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let z0 = ws.floorY
        let mUnit: Float = ws.eyeHeight / 1.7
        let rb = 0.55 * mUnit, rt = 0.42 * mUnit    // a touch narrower than the door plinth
        let h = plinthHeightM * mUnit
        func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ ao: Float) -> MazeVertexSwift {
            MazeVertexSwift(position: p, normal: n, texCoord: SIMD2(-1, -1), aoFactor: ao)   // metal flag (material 21)
        }
        let b = [SIMD3<Float>(-rb, -rb, z0), SIMD3<Float>(rb, -rb, z0), SIMD3<Float>(rb, rb, z0), SIMD3<Float>(-rb, rb, z0)]
        let t = [SIMD3<Float>(-rt, -rt, z0 + h), SIMD3<Float>(rt, -rt, z0 + h), SIMD3<Float>(rt, rt, z0 + h), SIMD3<Float>(-rt, rt, z0 + h)]
        for i in 0..<4 {
            let j = (i + 1) % 4
            let n = normalize(cross(b[j] - b[i], t[i] - b[i]))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [vtx(b[i], n, 0.55), vtx(b[j], n, 0.55), vtx(t[j], n, 0.95), vtx(t[i], n, 0.95)])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }
        let up = SIMD3<Float>(0, 0, 1)
        let cap = UInt32(verts.count)
        verts.append(contentsOf: [vtx(t[0], up, 1.0), vtx(t[1], up, 1.0), vtx(t[2], up, 1.0), vtx(t[3], up, 1.0)])
        indices.append(contentsOf: [cap+0, cap+1, cap+2, cap+0, cap+2, cap+3])
    }

    /// M16.6 (Eddie) — the switch CAP: a resin cylinder with the number glyph on top. Built at the
    /// ENGAGED height (`switchCapOutM`); SceneBuilder scales its Z to `switchCapFlushM` when
    /// disengaged, so the same cylinder is the flush disc (min) and the poking-out switch (max).
    /// Material 22 (no square-wrap band here → only the top-glyph + resin branches fire).
    private static func addSwitchCap(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let mUnit: Float = ws.eyeHeight / 1.7
        let zBase = ws.floorY + plinthHeightM * mUnit
        let rD = 0.40 * mUnit
        let zTop = zBase + switchCapOutM * mUnit
        func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float>, _ ao: Float) -> MazeVertexSwift {
            MazeVertexSwift(position: p, normal: n, texCoord: uv, aoFactor: ao)
        }
        let resinUV = SIMD2<Float>(-1, -2)
        let seg = 24
        for i in 0..<seg {
            let a0 = Float(i) / Float(seg) * 2 * .pi, a1 = Float(i + 1) / Float(seg) * 2 * .pi
            let p0 = SIMD2<Float>(cos(a0) * rD, sin(a0) * rD)
            let p1 = SIMD2<Float>(cos(a1) * rD, sin(a1) * rD)
            let n = normalize(SIMD3<Float>(cos((a0 + a1) * 0.5), sin((a0 + a1) * 0.5), 0))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [vtx(SIMD3(p0.x, p0.y, zBase), n, resinUV, 0.9), vtx(SIMD3(p1.x, p1.y, zBase), n, resinUV, 0.9),
                                      vtx(SIMD3(p1.x, p1.y, zTop), n, resinUV, 1.0), vtx(SIMD3(p0.x, p0.y, zTop), n, resinUV, 1.0)])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }
        let up = SIMD3<Float>(0, 0, 1)
        let cap = UInt32(verts.count)
        verts.append(vtx(SIMD3(0, 0, zTop), up, SIMD2(0.5, 0.5), 1.0))
        var ring: [UInt32] = []
        for i in 0..<seg {
            let a = Float(i) / Float(seg) * 2 * .pi
            let x = cos(a) * rD, y = sin(a) * rD
            ring.append(UInt32(verts.count))
            verts.append(vtx(SIMD3(x, y, zTop), up, SIMD2(x / (2 * rD) + 0.5, 0.5 - y / (2 * rD)), 1.0))
        }
        for i in 0..<seg { indices.append(contentsOf: [cap, ring[i], ring[(i + 1) % seg]]) }
    }

    ///
    /// UV convention read by material 22 (texCoord):
    ///   u ≥ 2      → the square-wrap band (FULL circumference; u−2 runs 0…1 once around), sheared
    ///               by the align value
    ///   0 ≤ u < 2  → the top cap; (u, v) is the swirl glyph UV
    /// v runs 0 at the top → 1 at the base, so the shear can split the square's upper half.
    /// THE TWO C's — one square tube, cut in half, floating over Scene 2's control plinth.
    ///
    /// Cut a square loop at the midpoints of two opposite sides and you get two identical C pieces,
    /// each a half-side + side + side + half-side, one the other turned through 180°. Counter to
    /// each other, exactly as Eddie described them, and when they meet they close into a single
    /// square tube with nothing doubled — which is what makes the solved state unmistakable. A
    /// control that shows you when you are RIGHT is worth more, in the scene that first asks you to
    /// turn something, than one that shows you what you are turning.
    ///
    /// The loop stands in a VERTICAL plane through the tile's local z axis, and that is the whole
    /// trick: rotating one half about that same axis swings it out of plane and back, so 0° is
    /// closed and 90° is open, with the pivot running through the loop's own centre. It also reads
    /// the way Eddie first saw it — "it kind of looks like a 4-d shape twisting" — which is the
    /// Builders' own vocabulary (slice = word, rotation = verb) rather than us drawing a diagram of
    /// our own mechanic for the player.
    ///
    /// `half == false` builds the +x half, `true` the −x half. Two meshes, because the two pieces
    /// have to move independently and one instance matrix cannot do that.
    /// Half the square's side. SceneBuilder needs it to swing the turning piece about its OUTER
    /// edge rather than the loop's centre — see the note there.
    static func alignmentPipeSpan(ws: WorldScale) -> Float { 0.45 * (ws.eyeHeight / 1.7) }

    /// Height of the loop's CENTRE above the tile floor. The turn has to be taken about this point:
    /// the loop floats well clear of the tile origin, so rotating about the origin swung the moving
    /// half bodily off the plinth and onto the grass beside it.
    static func alignmentPipeCentreZ(ws: WorldScale) -> Float {
        ws.floorY + (plinthHeightM + 0.75) * (ws.eyeHeight / 1.7)
    }

    private static func addAlignmentPipeHalf(to verts: inout [MazeVertexSwift], indices: inout [UInt32],
                                             ws: WorldScale, negative: Bool) {
        let mUnit: Float = ws.eyeHeight / 1.7
        // Floats clear of the plinth, centred a little under eye height so the closed square reads
        // as an object held up for you to look at rather than something overhead.
        let zc = Self.alignmentPipeCentreZ(ws: ws)
        let sHalf: Float = Self.alignmentPipeSpan(ws: ws)   // half the square's side — a ~90 cm loop
        let t: Float = 0.085 * mUnit           // tube half-thickness — chunky, as Eddie drew it
        let sx: Float = negative ? -1 : 1

        func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> MazeVertexSwift {
            MazeVertexSwift(position: p, normal: n, texCoord: SIMD2(-1, -1), aoFactor: 0.95)
        }
        /// A square-section bar between two points in the loop's plane (x, z), extruded in y.
        ///
        /// `mitreA`/`mitreB` say whether each END meets a corner of this C. A corner needs the bar
        /// run half a thickness past the turn or the right angle shows a notch — but a CUT end, where
        /// this half meets the other, must stop exactly on the line. Mitring those too made each
        /// half overrun the join by half a thickness, so the closed ring had the two colours
        /// overlapping instead of meeting (Eddie: "maybe make them both narrower so they just touch").
        func bar(_ a: SIMD2<Float>, _ b: SIMD2<Float>, mitreA: Bool, mitreB: Bool) {
            let d = simd_normalize(b - a)
            let perp = SIMD2<Float>(-d.y, d.x)
            let a2 = a - d * (mitreA ? t : 0), b2 = b + d * (mitreB ? t : 0)
            var ring: [[SIMD3<Float>]] = []
            for e in [a2, b2] {
                ring.append([
                    SIMD3(e.x + perp.x * t, -t, zc + e.y + perp.y * t),
                    SIMD3(e.x - perp.x * t, -t, zc + e.y - perp.y * t),
                    SIMD3(e.x - perp.x * t,  t, zc + e.y - perp.y * t),
                    SIMD3(e.x + perp.x * t,  t, zc + e.y + perp.y * t),
                ])
            }
            let base = UInt32(verts.count)
            for i in 0..<4 {
                let j = (i + 1) % 4
                let p0 = ring[0][i], p1 = ring[0][j], p2 = ring[1][j], p3 = ring[1][i]
                let n = simd_normalize(simd_cross(p1 - p0, p3 - p0))
                let k = UInt32(verts.count)
                verts.append(contentsOf: [vtx(p0, n), vtx(p1, n), vtx(p2, n), vtx(p3, n)])
                indices.append(contentsOf: [k+0, k+1, k+2, k+0, k+2, k+3])
            }
            // Caps, so a cut end reads as a tube rather than a hole.
            for (r, sgn) in [(ring[0], Float(-1)), (ring[1], Float(1))] {
                let n = simd_normalize(SIMD3(d.x, 0, d.y)) * sgn
                let k = UInt32(verts.count)
                verts.append(contentsOf: [vtx(r[0], n), vtx(r[1], n), vtx(r[2], n), vtx(r[3], n)])
                if sgn > 0 { indices.append(contentsOf: [k+0, k+1, k+2, k+0, k+2, k+3]) }
                else { indices.append(contentsOf: [k+0, k+2, k+1, k+0, k+3, k+2]) }
            }
            _ = base
        }

        // Half a square, walked from the top midpoint round to the bottom midpoint: half the top,
        // the whole side, half the bottom. The other piece is this mirrored in x.
        let top = SIMD2<Float>(0, sHalf), topOut = SIMD2<Float>(sx * sHalf, sHalf)
        let botOut = SIMD2<Float>(sx * sHalf, -sHalf), bot = SIMD2<Float>(0, -sHalf)
        // `top` and `bot` are the CUT ends — the midpoints of the square's top and bottom sides,
        // where this half meets the other. Everything else is a corner.
        bar(top, topOut, mitreA: false, mitreB: true)
        bar(topOut, botOut, mitreA: true, mitreB: true)
        bar(botOut, bot, mitreA: true, mitreB: false)
    }


    /// M16.6 — the Builder plinth (Eddie's exact spec, 2026-07-16): a grey-metallic tapered block
    /// with a flat translucent disc lying on top, the glyph lit on the disc's upper face. Replaces
    /// the glyph plaque beside the M16.3 dials and by the temple door.
    ///
    /// Dimensions are given in METRES and converted by the world's perceptual scale (WorldScale:
    /// eyeHeight 0.09u ≈ 1.7 m). Plinth: 1.4 m square base tapering to a 1 m square top, 0.9 m tall
    /// (Eddie 2026-07-16 — top + disc doubled from the first spec for readability, height kept LOW so
    /// the disc stays below the 1.7 m eye; base 0.7 m half-width < the 1.26 m nearest stand cell, so
    /// you still stand clear of it and it still blocks only one stand cell).
    /// Disc: 80 cm diameter, 4 cm thick, sitting on the top face (fits inside the 1 m square).
    ///
    /// One prop mesh, one material (21) that branches on the UV flag in `texCoord`:
    ///   u ≥ 0            → the disc's top face, UV [0,1]² carrying the caustic glyph
    ///   u = -1 (y = -1)  → metallic plinth body
    ///   u = -1 (y = -2)  → translucent disc side/rim
    /// (The disc can later GROW in Z into a glyph sequence or a waldo — Eddie's states 3 & 4 — but
    /// this builds the flat single-glyph form, states 1 (blank) & 2.)
    private static func addPlinth(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let z0 = ws.floorY
        let mUnit: Float = ws.eyeHeight / 1.7       // world units per metre (anchored to eye ≈ 1.7 m)
        let rb = 0.70 * mUnit, rt = 0.50 * mUnit    // half-widths: 1.4 m base → 1 m top
        let h = plinthHeightM * mUnit                // 0.9 m tall (kept low so the disc reads from above)
        let discR = 0.40 * mUnit                      // 80 cm diameter
        let discThick = 0.04 * mUnit                  // 4 cm
        func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float>, _ ao: Float) -> MazeVertexSwift {
            MazeVertexSwift(position: p, normal: n, texCoord: uv, aoFactor: ao)
        }
        let metalUV = SIMD2<Float>(-1, -1)          // plinth body
        let discUV  = SIMD2<Float>(-1, -2)          // translucent disc rim

        // ── Plinth body: four tapered sides + a top cap (the cap is capped so no hole shows under
        //    the smaller disc). AO darkens the base so it sits into the ground.
        let b = [SIMD3<Float>(-rb, -rb, z0), SIMD3<Float>(rb, -rb, z0), SIMD3<Float>(rb, rb, z0), SIMD3<Float>(-rb, rb, z0)]
        let t = [SIMD3<Float>(-rt, -rt, z0 + h), SIMD3<Float>(rt, -rt, z0 + h), SIMD3<Float>(rt, rt, z0 + h), SIMD3<Float>(-rt, rt, z0 + h)]
        for i in 0..<4 {
            let j = (i + 1) % 4
            let n = normalize(cross(b[j] - b[i], t[i] - b[i]))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [vtx(b[i], n, metalUV, 0.55), vtx(b[j], n, metalUV, 0.55),
                                      vtx(t[j], n, metalUV, 0.95), vtx(t[i], n, metalUV, 0.95)])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }
        let up = SIMD3<Float>(0, 0, 1)
        let capBase = UInt32(verts.count)
        verts.append(contentsOf: [vtx(t[0], up, metalUV, 1.0), vtx(t[1], up, metalUV, 1.0),
                                  vtx(t[2], up, metalUV, 1.0), vtx(t[3], up, metalUV, 1.0)])
        indices.append(contentsOf: [capBase+0, capBase+1, capBase+2, capBase+0, capBase+2, capBase+3])

        // ── The disc: an N-gon prism lying flat on the plinth top. Rim = translucent material; top
        //    face = UV [0,1]² over the disc's bounding square so the (centred) glyph lands square.
        let seg = 28
        let zBot = z0 + h, zTop = z0 + h + discThick
        // Rim
        for i in 0..<seg {
            let a0 = Float(i) / Float(seg) * 2 * .pi, a1 = Float(i + 1) / Float(seg) * 2 * .pi
            let p0 = SIMD2<Float>(cos(a0) * discR, sin(a0) * discR)
            let p1 = SIMD2<Float>(cos(a1) * discR, sin(a1) * discR)
            let n = normalize(SIMD3<Float>(cos((a0 + a1) * 0.5), sin((a0 + a1) * 0.5), 0))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [vtx(SIMD3(p0.x, p0.y, zBot), n, discUV, 0.9), vtx(SIMD3(p1.x, p1.y, zBot), n, discUV, 0.9),
                                      vtx(SIMD3(p1.x, p1.y, zTop), n, discUV, 1.0), vtx(SIMD3(p0.x, p0.y, zTop), n, discUV, 1.0)])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }
        // Top face — a triangle fan; UV maps the disc's [-R,R] xy into [0,1] so the square glyph
        // texture is centred on the round disc (its corners fall outside the circle, unused).
        let centre = UInt32(verts.count)
        verts.append(vtx(SIMD3(0, 0, zTop), up, SIMD2(0.5, 0.5), 1.0))
        var ring: [UInt32] = []
        for i in 0..<seg {
            let a = Float(i) / Float(seg) * 2 * .pi
            let x = cos(a) * discR, y = sin(a) * discR
            ring.append(UInt32(verts.count))
            verts.append(vtx(SIMD3(x, y, zTop), up, SIMD2(x / (2 * discR) + 0.5, 0.5 - y / (2 * discR)), 1.0))
        }
        for i in 0..<seg {
            indices.append(contentsOf: [centre, ring[i], ring[(i + 1) % seg]])
        }
    }

    private static func addGlyphPlaque(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let z0 = ws.floorY
        func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> MazeVertexSwift {
            MazeVertexSwift(position: p, normal: n, texCoord: SIMD2(0, 0), aoFactor: 0.92)
        }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            let n = normalize(cross(b - a, d - a))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [vtx(a, n), vtx(b, n), vtx(c, n), vtx(d, n)])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }
        func quadDS(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            quad(a, b, c, d); quad(d, c, b, a)
        }
        // The slab: upright, x across, z up, thin in y; the glyph face is the −y (north) side.
        func slabBox(_ hx: Float, _ hy: Float, _ zb: Float, _ zt: Float) {
            let corners = [SIMD3<Float>(-hx, -hy, 0), SIMD3<Float>(hx, -hy, 0),
                           SIMD3<Float>(hx, hy, 0), SIMD3<Float>(-hx, hy, 0)]
            let b0 = corners.map { SIMD3($0.x, $0.y, zb) }
            let t0 = corners.map { SIMD3($0.x, $0.y, zt) }
            for i in 0..<4 { let j = (i + 1) % 4; quad(b0[i], b0[j], t0[j], t0[i]) }
            quad(t0[3], t0[2], t0[1], t0[0])
        }
        // A raised stroke on the glyph face: (x,z)-plane segment, half-width w, standing off
        // the face toward −y.
        let faceY: Float = -0.014
        let raise: Float = 0.012
        func stroke(_ a2: SIMD2<Float>, _ b2: SIMD2<Float>, _ w: Float) {
            let dir = simd_normalize(b2 - a2)
            let perp = SIMD2<Float>(-dir.y, dir.x) * w
            let p0 = a2 - perp, p1 = a2 + perp, p2 = b2 + perp, p3 = b2 - perp
            func P(_ v: SIMD2<Float>, _ y: Float) -> SIMD3<Float> { SIMD3(v.x, y, v.y) }
            let yb = faceY, yf = faceY - raise
            quadDS(P(p0, yf), P(p1, yf), P(p2, yf), P(p3, yf))     // stroke face
            quadDS(P(p0, yb), P(p1, yb), P(p1, yf), P(p0, yf))     // sides
            quadDS(P(p2, yb), P(p3, yb), P(p3, yf), P(p2, yf))
            quadDS(P(p1, yb), P(p2, yb), P(p2, yf), P(p1, yf))
            quadDS(P(p3, yb), P(p0, yb), P(p0, yf), P(p3, yf))
        }
        slabBox(0.085, 0.014, z0, z0 + 0.24)
        // The glyph: cell-first tesseract shadow, centred on the slab.
        let zc: Float = z0 + 0.145
        let w: Float = 0.0065
        func square(_ h: Float) -> [SIMD2<Float>] {
            [SIMD2(-h, zc - h), SIMD2(h, zc - h), SIMD2(h, zc + h), SIMD2(-h, zc + h)]
        }
        let outer = square(0.054)
        let inner = square(0.023)
        for i in 0..<4 {
            let j = (i + 1) % 4
            stroke(outer[i], outer[j], w)   // outer cell
            stroke(inner[i], inner[j], w)   // inner cell
            stroke(outer[i], inner[i], w)   // the joining edges — the 4D hint
        }
    }

    /// How much the police box (and the lamp that sits on it) shrinks to reach life size.
    ///
    /// **2.6 m to the apex.** The first pass used Eddie's 217 cm and it read short standing next to
    /// it, so he asked for 20% more. That lands almost exactly on the real prop's OVERALL height:
    /// 217 cm is the body and doors, and the tented roof and lamp sit above them. The number was
    /// right and the thing it measured was not.
    ///
    /// Shared, because the lamp is a SEPARATE prop: scaling the box alone left every lamp hanging
    /// in the sky at the height the old roof used to be — visible from across the plaza, which is
    /// how it was caught. Anything else that lands on this roof must use this too.
    static func policeBoxScale(ws: WorldScale) -> Float {
        (2.60 * ws.metre) / (0.50 - ws.floorY)
    }

    private static func addPortalLamp(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let lampVertexStart = verts.count   // rescaled with the roof it stands on, at the end
        let base: Float = 0.50, top: Float = 0.56, h: Float = 0.028
        func ring(_ z: Float) -> [SIMD3<Float>] {
            [SIMD3(-h, -h, z), SIMD3(h, -h, z), SIMD3(h, h, z), SIMD3(-h, h, z)]
        }
        func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> MazeVertexSwift {
            MazeVertexSwift(position: p, normal: n, texCoord: SIMD2(0, 0), aoFactor: 1.0)
        }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            let n = normalize(cross(b - a, d - a))
            let bi = UInt32(verts.count)
            verts.append(contentsOf: [vtx(a, n), vtx(b, n), vtx(c, n), vtx(d, n)])
            indices.append(contentsOf: [bi+0, bi+1, bi+2, bi+0, bi+2, bi+3])
        }
        let lb = ring(base), lt = ring(top)
        for i in 0..<4 { let j = (i + 1) % 4; quad(lb[i], lb[j], lt[j], lt[i]) }   // sides
        quad(lt[0], lt[1], lt[2], lt[3])                                          // top cap

        // Rides the roof, so it takes the roof's scaling — see `addPortal`. Applied to the vertices
        // for the same reason: it cannot then be missed.
        let k = Self.policeBoxScale(ws: ws), z0 = ws.floorY
        for i in lampVertexStart..<verts.count {
            var v = verts[i]
            v.position = SIMD3(v.position.x * k, v.position.y * k, z0 + (v.position.z - z0) * k)
            verts[i] = v
        }
    }

    /// A chest — a simple box (4 sides + top) sitting on the floor. The open/closed look is
    /// conveyed by the instance colour (SceneBuilder), so one mesh is enough. Placeholder for
    /// the eventual imported model (e.g. a fire pit that lights). Wound CCW-outward. (G4)
    private static func addChest(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let z0 = ws.floorY
        let hx: Float = 0.085, hy: Float = 0.06
        let zt = z0 + 0.10

        func vtx(_ p: SIMD3<Float>) -> MazeVertexSwift {
            let ao = 0.55 + 0.45 * max(0, min(1, (p.z - z0) / (zt - z0)))
            return MazeVertexSwift(position: p, normal: SIMD3(0, 0, 1), texCoord: SIMD2(0, 0), aoFactor: ao)
        }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            let n = normalize(cross(b - a, d - a))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [
                MazeVertexSwift(position: a, normal: n, texCoord: SIMD2(0, 0), aoFactor: vtx(a).aoFactor),
                MazeVertexSwift(position: b, normal: n, texCoord: SIMD2(0, 0), aoFactor: vtx(b).aoFactor),
                MazeVertexSwift(position: c, normal: n, texCoord: SIMD2(0, 0), aoFactor: vtx(c).aoFactor),
                MazeVertexSwift(position: d, normal: n, texCoord: SIMD2(0, 0), aoFactor: vtx(d).aoFactor),
            ])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }

        let b = [SIMD3<Float>(-hx, -hy, z0), SIMD3(hx, -hy, z0), SIMD3(hx, hy, z0), SIMD3(-hx, hy, z0)]
        let t = [SIMD3<Float>(-hx, -hy, zt), SIMD3(hx, -hy, zt), SIMD3(hx, hy, zt), SIMD3(-hx, hy, zt)]
        for i in 0..<4 {
            let j = (i + 1) % 4
            quad(b[i], b[j], t[j], t[i])   // sides
        }
        quad(t[0], t[1], t[2], t[3])       // top
    }

    /// The **hip-roof cap** for one quarter of the 2×2 modular house (M12-E). The walls are now
    /// imported kit meshes (Renderer.buildHouseQuarter); this supplies just the roof, because the
    /// kit has no 4-way hip piece and this geometry was already built for exactly this footprint.
    /// A single slope over the tile's inner-corner cell, peaking at the tile corner `(hw,hw)` — the
    /// shared 2×2 centre — so the four quarters' peaks meet there with no gap. Rides its tile's
    /// slice via the same `.houseCorner` Prop anchor as the imported walls, so roof and walls split
    /// together. The eave sits at the imported wall height so it rests cleanly on top. (M12-E)
    private static func addHouseQuarter(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let hw = ws.floorHalfSize          // 0.5 — the shared 2×2 centre corner (apex lands here)
        let inner = -hw                    // roof covers the full tile now that walls are on its edges
        let z0 = ws.floorY
        let eave = z0 + 0.30               // wall top (imported wall height hS = 0.30)
        let peak = z0 + 0.62               // roof peak at the shared 2×2 centre, above the walls

        func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> MazeVertexSwift {
            let ao = 0.55 + 0.45 * max(0, min(1, (p.z - z0) / (peak - z0)))
            return MazeVertexSwift(position: p, normal: n, texCoord: SIMD2(0, 0), aoFactor: ao)
        }
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            let n = normalize(cross(b - a, d - a))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [vtx(a, n), vtx(b, n), vtx(c, n), vtx(d, n)])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            let n = normalize(cross(b - a, c - a))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [vtx(a, n), vtx(b, n), vtx(c, n)])
            indices.append(contentsOf: [base+0, base+1, base+2])
        }

        // Hip-roof quarter: peak at the inner corner (hw,hw) = shared 2×2 centre; eave at the
        // other three corners of the inner-corner cell (resting on the imported walls). The walls
        // themselves come from the kit (Renderer), so this emits only the roof. Emit each slope
        // twice with opposite winding so it's visible from outside AND as a ceiling from inside
        // (a thin single-sided slope back-face-culls to nothing when you look up at it).
        let apex = SIMD3<Float>(hw, hw, peak)
        tri(SIMD3(inner, inner, eave), SIMD3(hw, inner, eave), apex)
        tri(SIMD3(inner, inner, eave), apex, SIMD3(inner, hw, eave))
        tri(SIMD3(hw, inner, eave), SIMD3(inner, inner, eave), apex)   // underside
        tri(apex, SIMD3(inner, inner, eave), SIMD3(inner, hw, eave))   // underside
    }

    // MARK: - Posts (M10 Phase B)

    /// Corner posts at all four tile corners plus jamb posts flanking each gateway gap.
    /// These are emitted with a distinct material (light green) by the scene builder.
    private static func addPosts(tile: MazeTile, to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let hs = ws.tileMeshSize / 2.0
        let wt = ws.wallThickness
        let z0 = ws.floorY

        // No corner posts: with walls now filling the cell (tileMeshSize == cellSpacing)
        // the hedge is continuous at corners, so there is no joint crack to cover. The
        // old corner posts only masked that crack and, once recessed to avoid coplanar
        // z-fighting, were invisible geometry — dropped entirely.

        // Jamb posts: bold (1.5× wall thickness) and rising above the hedges — they
        // frame each gateway prominently.
        let jambH = wt * 1.5 / 2.0
        let jambTop = ws.wallHeight * 1.15
        let stub = (1.0 - ws.gatewayGapFraction) / 2.0
        for dir in SurfaceDirection.allCases where tile.edgeType(dir) == .gateway {
            let (c0, c1) = wallCenterline(edge: dir, hs: hs, wt: wt)
            for t in [stub, 1 - stub] {
                addPost(center: c0 + (c1 - c0) * t, halfSize: jambH, z0: z0, zTop: jambTop, to: &verts, indices: &indices)
            }
        }
    }

    /// Endpoints of an edge's wall centerline (t=0 → t=1), used to place jamb posts.
    private static func wallCenterline(edge: SurfaceDirection, hs: Float, wt: Float) -> (SIMD2<Float>, SIMD2<Float>) {
        switch edge {
        case .north: return (SIMD2( hs, -hs + wt / 2), SIMD2(-hs, -hs + wt / 2))
        case .south: return (SIMD2(-hs,  hs - wt / 2), SIMD2( hs,  hs - wt / 2))
        case .east:  return (SIMD2( hs - wt / 2,  hs), SIMD2( hs - wt / 2, -hs))
        case .west:  return (SIMD2(-hs + wt / 2, -hs), SIMD2(-hs + wt / 2,  hs))
        }
    }

    /// A vertical box post (4 sides + top), wound CCW-outward for back-face culling.
    private static func addPost(center c: SIMD2<Float>, halfSize h: Float, z0: Float, zTop: Float,
                                to verts: inout [MazeVertexSwift], indices: inout [UInt32]) {
        let x0 = c.x - h, x1 = c.x + h, y0 = c.y - h, y1 = c.y + h

        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ cc: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>) {
            let base = UInt32(verts.count)
            verts.append(contentsOf: [
                MazeVertexSwift(position: a, normal: n, texCoord: SIMD2(0, 0), aoFactor: 0.85),
                MazeVertexSwift(position: b, normal: n, texCoord: SIMD2(1, 0), aoFactor: 0.85),
                MazeVertexSwift(position: cc, normal: n, texCoord: SIMD2(1, 1), aoFactor: 1.0),
                MazeVertexSwift(position: d, normal: n, texCoord: SIMD2(0, 1), aoFactor: 1.0),
            ])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }

        quad(SIMD3(x1, y0, z0), SIMD3(x1, y1, z0), SIMD3(x1, y1, zTop), SIMD3(x1, y0, zTop), SIMD3( 1, 0, 0)) // +X
        quad(SIMD3(x0, y1, z0), SIMD3(x0, y0, z0), SIMD3(x0, y0, zTop), SIMD3(x0, y1, zTop), SIMD3(-1, 0, 0)) // -X
        quad(SIMD3(x1, y1, z0), SIMD3(x0, y1, z0), SIMD3(x0, y1, zTop), SIMD3(x1, y1, zTop), SIMD3( 0, 1, 0)) // +Y
        quad(SIMD3(x0, y0, z0), SIMD3(x1, y0, z0), SIMD3(x1, y0, zTop), SIMD3(x0, y0, zTop), SIMD3( 0,-1, 0)) // -Y
        quad(SIMD3(x0, y0, zTop), SIMD3(x1, y0, zTop), SIMD3(x1, y1, zTop), SIMD3(x0, y1, zTop), SIMD3(0, 0, 1)) // top
    }

    /// Scene 4 (and Scene 1's silhouette) — the LAYERED VESSEL. A lathe of the profile the script
    /// describes: "broad circular bowls, compressed spherical chambers, narrow connecting stems,
    /// flared collars, stacked rotationally symmetrical sections … several different objects
    /// threaded onto the same invisible vertical axis."
    ///
    /// Three of those sections are the **major rings**, each crossed by a narrow luminous seam that
    /// does not line up with the others until its bond is released. Because the body is a surface of
    /// revolution, a ring turning and a ring's SEAM turning are indistinguishable — so the seam is a
    /// shader feature at an angle (material 28), not rotated geometry. That is what lets one static
    /// mesh show three independently-turning rings with no per-ring instance data.
    ///
    /// UV convention read by material 28 (following the alignment cylinder's u≥2 trick):
    ///   0 ≤ u < 2 → the top cap, (u,v) = the swirl glyph UV
    ///   u ≥ 2     → the body; u−2 runs 0…1 once around from the front seam
    ///               v = ringIndex + t  (0,1,2 = the three major rings, t local within the band)
    ///               v = 3 + t          (plain stem/bowl — no seam)
    /// Revolve a (radius, height) profile about local z — the shared spine of the Scene 5 fixtures.
    /// `uv.y` carries a 0…1 FILL coordinate (height / total height): material 35 lights the fixture
    /// from the bottom up as its `anim` rises, which is what makes a bowl read as FILLING.
    private static func latheProfile(_ profile: [(r: Float, h: Float)], seg: Int, ws: WorldScale,
                                     verts: inout [MazeVertexSwift], indices: inout [UInt32]) {
        let mUnit: Float = ws.eyeHeight / 1.7
        let z0 = ws.floorY
        let hMax = profile.map { $0.h }.max() ?? 1
        for i in 0..<(profile.count - 1) {
            let (r0, h0) = profile[i], (r1, h1) = profile[i + 1]
            let zA = z0 + h0 * mUnit, zB = z0 + h1 * mUnit
            let rA = r0 * mUnit, rB = r1 * mUnit
            let slope = normalize(SIMD2<Float>(h1 - h0, -(r1 - r0)))
            for k in 0..<seg {
                let a0 = Float(k) / Float(seg) * 2 * .pi, a1 = Float(k + 1) / Float(seg) * 2 * .pi
                let (c0, s0) = (cos(a0), sin(a0)), (c1, s1) = (cos(a1), sin(a1))
                let n0 = SIMD3<Float>(c0 * slope.x, s0 * slope.x, slope.y)
                let n1 = SIMD3<Float>(c1 * slope.x, s1 * slope.x, slope.y)
                let base = UInt32(verts.count)
                verts.append(contentsOf: [
                    MazeVertexSwift(position: SIMD3(c0 * rA, s0 * rA, zA), normal: n0, texCoord: SIMD2(0, h0 / hMax), aoFactor: 1),
                    MazeVertexSwift(position: SIMD3(c1 * rA, s1 * rA, zA), normal: n1, texCoord: SIMD2(0, h0 / hMax), aoFactor: 1),
                    MazeVertexSwift(position: SIMD3(c1 * rB, s1 * rB, zB), normal: n1, texCoord: SIMD2(0, h1 / hMax), aoFactor: 1),
                    MazeVertexSwift(position: SIMD3(c0 * rB, s0 * rB, zB), normal: n0, texCoord: SIMD2(0, h1 / hMax), aoFactor: 1),
                ])
                indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            }
        }
    }


    /// Scene 5C — the SOURCE: "a low circular basin set into the ground, surrounded by three nested
    /// rings of translucent mineral." The basin dishes inward; each ring is a thin free-standing
    /// wall. ~4.5 m across — wide enough to be the origin of a world's circuit, low enough to look
    /// down into.
    private static func addChannelBasin(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        // The dish: rim down into a shallow inner floor, back up a centre boss the light rises from.
        latheProfile([(1.05, 0.16), (0.95, 0.18), (0.55, 0.05), (0.18, 0.08), (0.10, 0.22), (0.0, 0.24)],
                     seg: 28, ws: ws, verts: &verts, indices: &indices)
        // Three nested rings, each a thin wall: out-up-in-down.
        for (radius, height) in [(Float(1.35), Float(0.26)), (1.75, 0.20), (2.15, 0.14)] {
            latheProfile([(radius - 0.05, 0.0), (radius - 0.05, height), (radius + 0.05, height), (radius + 0.05, 0.0)],
                         seg: 28, ws: ws, verts: &verts, indices: &indices)
        }
    }

    /// Scene 5D — a RECEIVER: "a raised crescent or bowl-like structure embedded into a channel
    /// junction." A pedestal opening into a wide bowl, ~2 m tall — recognisable from distance,
    /// related to the basin without repeating it.
    private static func addChannelBowl(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        latheProfile([(0.55, 0.0), (0.30, 0.10), (0.22, 0.75), (0.80, 1.55), (0.95, 1.95),
                      (0.85, 2.00), (0.55, 1.70), (0.30, 1.62), (0.12, 1.66)],
                     seg: 24, ws: ws, verts: &verts, indices: &indices)
    }

    private static func addLayeredVessel(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let mUnit: Float = ws.eyeHeight / 1.7
        let z0 = ws.floorY
        func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float>, _ ao: Float) -> MazeVertexSwift {
            MazeVertexSwift(position: p, normal: n, texCoord: uv, aoFactor: ao)
        }
        // Profile: (radius in metres, height in metres, ring index or -1 for plain body). Read bottom
        // to top. ~1.55 m overall — just under eye height, so you look slightly DOWN at the swirl on
        // its cap and can read all three seams at once without circling it.
        let profile: [(Float, Float, Int)] = [
            (0.34, 0.00, -1), (0.40, 0.06, -1),                 // foot
            (0.22, 0.16, -1),                                   // narrow connecting stem
            (0.46, 0.30,  0), (0.50, 0.42,  0), (0.44, 0.52, 0), // RING 0 — broad bowl
            (0.20, 0.62, -1),                                   // stem
            (0.40, 0.74,  1), (0.43, 0.86,  1), (0.38, 0.96, 1), // RING 1 — compressed chamber
            (0.18, 1.05, -1),                                   // stem
            (0.33, 1.16,  2), (0.36, 1.28,  2), (0.30, 1.38, 2), // RING 2 — upper chamber
            (0.20, 1.46, -1), (0.30, 1.55, -1),                 // flared collar
        ]
        let seg = 28
        // Lathe the profile. Each ring band carries v = ringIndex + t so the shader knows which of
        // the three seams it is drawing; plain sections get v = 3 + t and never show one.
        for i in 0..<(profile.count - 1) {
            let (r0, h0, k0) = profile[i], (r1, h1, k1) = profile[i + 1]
            let band = (k0 >= 0 && k1 >= 0) ? k0 : 3
            // Local v within the band: for a ring, run 0→1 across its own sections so the seam has a
            // full-height gradient to fade at; plain sections park mid-band.
            let v0 = Float(band) + (band < 3 ? Float(i % 3) / 3.0 : 0.5)
            let v1 = Float(band) + (band < 3 ? Float(i % 3 + 1) / 3.0 : 0.5)
            let zA = z0 + h0 * mUnit, zB = z0 + h1 * mUnit
            let rA = r0 * mUnit, rB = r1 * mUnit
            // Slope-correct normal for the lathe segment (a cone frustum, not a cylinder).
            let dr = rB - rA, dz = zB - zA
            let nLen = max(1e-6, sqrt(dr * dr + dz * dz))
            let nR = dz / nLen, nZ = -dr / nLen
            for j in 0..<seg {
                let a0 = -Float.pi + Float(j) / Float(seg) * 2 * .pi
                let a1 = -Float.pi + Float(j + 1) / Float(seg) * 2 * .pi
                let u0 = 2.0 + (a0 + .pi) / (2 * .pi)
                let u1 = 2.0 + (a1 + .pi) / (2 * .pi)
                let c0 = cos(a0), s0 = sin(a0), c1 = cos(a1), s1 = sin(a1)
                // AO: darker low down so it sits into the ground, brighter toward the cap.
                let ao0 = 0.72 + 0.28 * (h0 / 1.55), ao1 = 0.72 + 0.28 * (h1 / 1.55)
                let base = UInt32(verts.count)
                verts.append(contentsOf: [
                    vtx(SIMD3(c0 * rA, s0 * rA, zA), normalize(SIMD3(c0 * nR, s0 * nR, nZ)), SIMD2(u0, v0), ao0),
                    vtx(SIMD3(c1 * rA, s1 * rA, zA), normalize(SIMD3(c1 * nR, s1 * nR, nZ)), SIMD2(u1, v0), ao0),
                    vtx(SIMD3(c1 * rB, s1 * rB, zB), normalize(SIMD3(c1 * nR, s1 * nR, nZ)), SIMD2(u1, v1), ao1),
                    vtx(SIMD3(c0 * rB, s0 * rB, zB), normalize(SIMD3(c0 * nR, s0 * nR, nZ)), SIMD2(u0, v1), ao1)])
                indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
            }
        }
        // Top cap — UV [0,1]² over its bounding square, carrying the swirl (the MOTION glyph Scene 2
        // introduced). Same convention as the plinth disc and the alignment cylinder's cap.
        let rTop = profile[profile.count - 1].0 * mUnit
        let zTop = z0 + profile[profile.count - 1].1 * mUnit
        let up = SIMD3<Float>(0, 0, 1)
        let cap = UInt32(verts.count)
        verts.append(vtx(SIMD3(0, 0, zTop), up, SIMD2(0.5, 0.5), 1.0))
        for j in 0...seg {
            let a = -Float.pi + Float(j) / Float(seg) * 2 * .pi
            let c = cos(a), s = sin(a)
            verts.append(vtx(SIMD3(c * rTop, s * rTop, zTop), up, SIMD2(0.5 + 0.5 * c, 0.5 + 0.5 * s), 1.0))
        }
        for j in 0..<seg {
            indices.append(contentsOf: [cap, cap + UInt32(j) + 1, cap + UInt32(j) + 2])
        }
    }

    /// Scene 2 — a dust mote shaken from a wall joint. Two crossed quads a few cm across, built
    /// ABOVE the floor at joint height: the prop's `heightScale` (about the floor pivot) then scales
    /// that height down as its life runs out, so it FALLS and lands rather than fading in mid-air.
    /// Reusing the height machinery is what keeps the engine's first particle a dozen lines instead
    /// of a subsystem.
    private static func addDustMote(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let mUnit: Float = ws.eyeHeight / 1.7
        let hw = 0.16 * mUnit                       // ~16 cm: a speck at 4.5 cm was unfindable (Eddie)
        let z0 = ws.floorY + 1.35 * mUnit           // shaken loose at about joint height
        func quad(_ ax: Float, _ ay: Float) {
            let n = SIMD3<Float>(-ay, ax, 0)
            let base = UInt32(verts.count)
            for (dx, dz) in [(-hw, -hw), (hw, -hw), (hw, hw), (-hw, hw)] {
                verts.append(MazeVertexSwift(position: SIMD3(ax * dx, ay * dx, z0 + dz), normal: n,
                                             texCoord: SIMD2(dx / hw * 0.5 + 0.5, dz / hw * 0.5 + 0.5),
                                             aoFactor: 1.0))
            }
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
            indices.append(contentsOf: [base+0, base+2, base+1, base+0, base+3, base+2])  // two-sided
        }
        quad(1, 0)
        quad(0, 1)
    }

    /// Scene 3's ORB — a unit sphere at the origin, scaled and placed by the instance. UV-mapped so
    /// the material can run facets over it; `localPosition` does the real work in the shader, but
    /// the texCoord gives it a stable seam-free-enough parameterisation for the surface planes.
    ///
    /// "From one angle it appears spherical. From another, its surface reveals shifting crystalline
    /// planes." The geometry is the easy half of that — the sphere is deliberately plain, and every
    /// facet the player sees is the material's doing, because faceted GEOMETRY would freeze the
    /// shape and the script wants it to refuse classification.
    private static func addOrb(to verts: inout [MazeVertexSwift], indices: inout [UInt32]) {
        let rings = 16, segs = 24
        let base = UInt32(verts.count)
        for i in 0...rings {
            let v = Float(i) / Float(rings)
            let phi = v * .pi
            for j in 0...segs {
                let u = Float(j) / Float(segs)
                let theta = u * 2 * .pi
                let n = SIMD3<Float>(sinf(phi) * cosf(theta), cosf(phi), sinf(phi) * sinf(theta))
                verts.append(MazeVertexSwift(position: n, normal: n, texCoord: SIMD2(u, v), aoFactor: 1.0))
            }
        }
        for i in 0..<rings {
            for j in 0..<segs {
                let a = base + UInt32(i * (segs + 1) + j)
                let b = a + UInt32(segs + 1)
                indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
    }

    /// Scene 3's BEAM — a square tube of unit length running 0…1 along +Z, half-width 1 in x/y, so
    /// the instance matrix sets both length and thickness. Four sides, no caps: you are meant to see
    /// along it, and a capped end reads as a rod rather than as light.
    ///
    /// texCoord.y carries the position ALONG the beam (0 at the obelisk, 1 at the orb end), which is
    /// what lets the material run a travelling pulse and taper it toward the tip.
    private static func addBeam(to verts: inout [MazeVertexSwift], indices: inout [UInt32]) {
        let corners: [SIMD2<Float>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
        for k in 0..<4 {
            let p0 = corners[k], p1 = corners[(k + 1) % 4]
            let n = normalize(SIMD3<Float>((p0.x + p1.x) * 0.5, (p0.y + p1.y) * 0.5, 0))
            let base = UInt32(verts.count)
            verts.append(contentsOf: [
                MazeVertexSwift(position: SIMD3(p0.x, p0.y, 0), normal: n, texCoord: SIMD2(0, 0), aoFactor: 1.0),
                MazeVertexSwift(position: SIMD3(p1.x, p1.y, 0), normal: n, texCoord: SIMD2(1, 0), aoFactor: 1.0),
                MazeVertexSwift(position: SIMD3(p1.x, p1.y, 1), normal: n, texCoord: SIMD2(1, 1), aoFactor: 1.0),
                MazeVertexSwift(position: SIMD3(p0.x, p0.y, 1), normal: n, texCoord: SIMD2(0, 1), aoFactor: 1.0)])
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            indices.append(contentsOf: [base, base + 2, base + 1, base, base + 3, base + 2])   // two-sided
        }
    }
}
