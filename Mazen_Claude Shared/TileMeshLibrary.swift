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
    let celestialCube: TileMesh   // unit cube for the M9 sun/moon bodies
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

        let dialStart = allIndices.count
        Self.addDial(to: &allVerts, indices: &allIndices, ws: ws)
        propMeshes[PropKind.dial.rawValue] = TileMesh(vertexOffset: 0, indexOffset: dialStart, indexCount: allIndices.count - dialStart)

        // Celestial bodies (M9): a unit cube, drawn at the sun/moon positions.
        let cubeStart = allIndices.count
        Self.addUnitCube(to: &allVerts, indices: &allIndices)
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

    /// A unit cube centred at the origin (±0.5), 6 faces wound CCW-outward with true face
    /// normals. Scaled + positioned per-instance to render the sun and moon.
    private static func addUnitCube(to verts: inout [MazeVertexSwift], indices: inout [UInt32]) {
        let h: Float = 0.5
        let p = [
            SIMD3<Float>(-h, -h, -h), SIMD3(h, -h, -h), SIMD3(h, h, -h), SIMD3(-h, h, -h),  // 0..3 back (z=−h)
            SIMD3<Float>(-h, -h,  h), SIMD3(h, -h,  h), SIMD3(h, h,  h), SIMD3(-h, h,  h),   // 4..7 front (z=+h)
        ]
        func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            let n = normalize(cross(p[b] - p[a], p[d] - p[a]))
            let base = UInt32(verts.count)
            for i in [a, b, c, d] {
                verts.append(MazeVertexSwift(position: p[i], normal: n, texCoord: SIMD2(0, 0), aoFactor: 1.0))
            }
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }
        quad(4, 5, 6, 7)  // +Z
        quad(0, 3, 2, 1)  // −Z
        quad(1, 2, 6, 5)  // +X
        quad(0, 4, 7, 3)  // −X
        quad(3, 7, 6, 2)  // +Y
        quad(0, 1, 5, 4)  // −Y
    }

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

    /// A portal marker (M11.2) — a TARDIS-style police box: a tall blue body with a tented (pyramid)
    /// roof, taller than the hedges so it's easy to spot. A separate `portalLamp` prop sits at the
    /// apex and flashes. Interacting (F) or stepping onto its tile switches worlds. Wound CCW-outward.
    private static func addPortal(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
        let z0 = ws.floorY
        let bodyTop: Float = 0.40   // top of the box body (above the 0.24 hedges)
        let roofTop: Float = 0.50   // apex of the tented roof
        let h: Float = 0.11         // body half-width (squarish police-box footprint)
        func ring(_ z: Float) -> [SIMD3<Float>] {
            [SIMD3(-h, -h, z), SIMD3(h, -h, z), SIMD3(h, h, z), SIMD3(-h, h, z)]
        }
        func vtx(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> MazeVertexSwift {
            let ao = 0.55 + 0.45 * max(0, min(1, (p.z - z0) / roofTop))   // slightly darker toward the base
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
        let b = ring(z0), t = ring(bodyTop)
        for i in 0..<4 { let j = (i + 1) % 4; quad(b[i], b[j], t[j], t[i]) }   // body sides
        let apex = SIMD3<Float>(0, 0, roofTop)
        for i in 0..<4 { let j = (i + 1) % 4; tri(t[i], t[j], apex) }          // tented pyramid roof
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

    private static func addPortalLamp(to verts: inout [MazeVertexSwift], indices: inout [UInt32], ws: WorldScale) {
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
}
