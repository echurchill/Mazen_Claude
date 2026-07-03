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
    private var floorMeshes: [UInt8: TileMesh] = [:]      // propSpace sub-cells (base ground)
    private var pathFloorMeshes: [UInt8: TileMesh] = [:]  // path-cross sub-cells (paved)
    private var wallMeshes: [UInt8: TileMesh] = [:]
    private var postMeshes: [UInt8: TileMesh] = [:]

    init(device: MTLDevice, worldScale ws: WorldScale) {
        var allVerts: [MazeVertexSwift] = []
        var allIndices: [UInt16] = []

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
            let base = UInt16(start)
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
            let bi = UInt16(allVerts.count)
            allVerts.append(MazeVertexSwift(position: a, normal: n, texCoord: SIMD2(0, 0), aoFactor: 1.0))
            allVerts.append(MazeVertexSwift(position: b, normal: n, texCoord: SIMD2(1, 0), aoFactor: 1.0))
            allVerts.append(MazeVertexSwift(position: pmTip, normal: n, texCoord: SIMD2(0.5, 1), aoFactor: 1.0))
            allIndices.append(contentsOf: [bi, bi+1, bi+2])
        }
        let arrowN = SIMD3<Float>(0, 0, 1)
        let arrowZ: Float = 0.03
        let ai = UInt16(allVerts.count)
        allVerts.append(MazeVertexSwift(position: SIMD3(0, pmR + 0.22, arrowZ), normal: arrowN, texCoord: SIMD2(0.5, 1), aoFactor: 1.0))
        allVerts.append(MazeVertexSwift(position: SIMD3(-0.08, pmR + 0.04, arrowZ), normal: arrowN, texCoord: SIMD2(0, 0), aoFactor: 1.0))
        allVerts.append(MazeVertexSwift(position: SIMD3( 0.08, pmR + 0.04, arrowZ), normal: arrowN, texCoord: SIMD2(1, 0), aoFactor: 1.0))
        allIndices.append(contentsOf: [ai, ai+1, ai+2])
        let pmIdxCount = allIndices.count - pmIStart
        playerMarker = TileMesh(vertexOffset: pmVStart, indexOffset: pmIStart, indexCount: pmIdxCount)

        // Pad index buffer to 4-byte alignment (UInt16 pairs) so all subsequent
        // drawIndexedPrimitives calls get a 4-byte-aligned GPU address
        if allIndices.count % 2 != 0 {
            allIndices.append(0)
        }

        // Cubie frame — dark border ring around each tile perimeter
        let frameVStart = allVerts.count
        let frameIStart = allIndices.count
        let fi: Float = 0.46
        let fo: Float = 0.52
        let fz: Float = 0.0
        let frameN = SIMD3<Float>(0, 0, 1)

        func addFrameStrip(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            let base = UInt16(allVerts.count)
            allVerts.append(contentsOf: [
                MazeVertexSwift(position: a, normal: frameN, texCoord: SIMD2(0, 0), aoFactor: 0.8),
                MazeVertexSwift(position: b, normal: frameN, texCoord: SIMD2(1, 0), aoFactor: 0.8),
                MazeVertexSwift(position: c, normal: frameN, texCoord: SIMD2(1, 1), aoFactor: 0.8),
                MazeVertexSwift(position: d, normal: frameN, texCoord: SIMD2(0, 1), aoFactor: 0.8),
            ])
            allIndices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }

        addFrameStrip(SIMD3(-fo, -fo, fz), SIMD3(fo, -fo, fz), SIMD3(fo, -fi, fz), SIMD3(-fo, -fi, fz))
        addFrameStrip(SIMD3(-fo, fi, fz), SIMD3(fo, fi, fz), SIMD3(fo, fo, fz), SIMD3(-fo, fo, fz))
        addFrameStrip(SIMD3(fi, -fo, fz), SIMD3(fo, -fo, fz), SIMD3(fo, fo, fz), SIMD3(fi, fo, fz))
        addFrameStrip(SIMD3(-fo, -fo, fz), SIMD3(-fi, -fo, fz), SIMD3(-fi, fo, fz), SIMD3(-fo, fo, fz))

        frameMesh = TileMesh(vertexOffset: frameVStart, indexOffset: frameIStart,
                             indexCount: allIndices.count - frameIStart)

        // Floors — keyed by the 16 openings masks (the path/prop split depends only on
        // which edges are passable, so gateway vs open doesn't matter here).
        for mask: UInt8 in 0..<16 {
            let openings = DirectionMask(rawValue: mask)

            let propStart = allIndices.count
            Self.addFloorCells(to: &allVerts, indices: &allIndices, openings: openings, ws: ws, path: false)
            floorMeshes[mask] = TileMesh(vertexOffset: 0, indexOffset: propStart, indexCount: allIndices.count - propStart)

            let pathStart = allIndices.count
            Self.addFloorCells(to: &allVerts, indices: &allIndices, openings: openings, ws: ws, path: true)
            let pathCount = allIndices.count - pathStart
            if pathCount > 0 {
                pathFloorMeshes[mask] = TileMesh(vertexOffset: 0, indexOffset: pathStart, indexCount: pathCount)
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

        vertexBuffer = device.makeBuffer(
            bytes: allVerts,
            length: MemoryLayout<MazeVertexSwift>.stride * allVerts.count,
            options: .storageModeShared
        )!
        vertexBuffer.label = "TileMeshVertices"

        indexBuffer = device.makeBuffer(
            bytes: allIndices,
            length: MemoryLayout<UInt16>.stride * allIndices.count,
            options: .storageModeShared
        )!
        indexBuffer.label = "TileMeshIndices"
    }

    func floorMesh(for openings: DirectionMask) -> TileMesh {
        return floorMeshes[openings.rawValue & 0x0F] ?? fogLayers[0]
    }

    func wallMesh(configKey: UInt8) -> TileMesh? {
        return wallMeshes[configKey]
    }

    func postMesh(configKey: UInt8) -> TileMesh? {
        return postMeshes[configKey]
    }

    /// The path-cross sub-cells (paved). `floorMesh` returns the propSpace remainder.
    func pathFloorMesh(for openings: DirectionMask) -> TileMesh? {
        return pathFloorMeshes[openings.rawValue & 0x0F]
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
    private static func addFloorCells(to verts: inout [MazeVertexSwift], indices: inout [UInt16], openings: DirectionMask, ws: WorldScale, path: Bool) {
        let hs = ws.floorHalfSize
        let z = ws.floorY
        let cell = 2.0 * hs / 3.0
        let tile = MazeTile(openings: openings, styleSeed: 0)

        func uv(_ x: Float, _ y: Float) -> SIMD2<Float> { SIMD2((x + hs) * ws.uvScale, (y + hs) * ws.uvScale) }

        for r in 0..<3 {
            for c in 0..<3 {
                guard tile.isPathCell(r, c) == path else { continue }
                let x0 = -hs + Float(c) * cell, x1 = x0 + cell
                let y0 = -hs + Float(r) * cell, y1 = y0 + cell
                let base = UInt16(verts.count)
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

    /// Build one tile edge as a wall, a gateway (two stubs framing a centered gap), or
    /// nothing (`open`). Dispatches to `addWall` with the appropriate sub-span(s).
    private static func addEdgeWall(edge: SurfaceDirection, type: EdgeType, to verts: inout [MazeVertexSwift], indices: inout [UInt16], ws: WorldScale) {
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

    private static func addWall(edge: SurfaceDirection, span: (Float, Float), to verts: inout [MazeVertexSwift], indices: inout [UInt16], ws: WorldScale) {
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

        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                  _ n: SIMD3<Float>,
                  _ uvA: SIMD2<Float>, _ uvB: SIMD2<Float>, _ uvC: SIMD2<Float>, _ uvD: SIMD2<Float>) {
            let base = UInt16(verts.count)
            func ao(_ p: SIMD3<Float>) -> Float { p.z > z0 + 0.01 ? aoTop : aoBottom }
            verts.append(contentsOf: [
                MazeVertexSwift(position: a, normal: n, texCoord: uvA, aoFactor: ao(a)),
                MazeVertexSwift(position: b, normal: n, texCoord: uvB, aoFactor: ao(b)),
                MazeVertexSwift(position: c, normal: n, texCoord: uvC, aoFactor: ao(c)),
                MazeVertexSwift(position: d, normal: n, texCoord: uvD, aoFactor: ao(d)),
            ])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }

        let wallU = ws.tileMeshSize * ws.uvScale * (span.1 - span.0)
        let wallV = (z1 - z0) * ws.uvScale
        let capU = wt * ws.uvScale

        // Inner face
        quad(SIMD3(inner0.x, inner0.y, z0), SIMD3(inner1.x, inner1.y, z0),
             SIMD3(inner1.x, inner1.y, z1), SIMD3(inner0.x, inner0.y, z1), inN,
             SIMD2(0, 0), SIMD2(wallU, 0), SIMD2(wallU, wallV), SIMD2(0, wallV))
        // Outer face
        quad(SIMD3(outer1.x, outer1.y, z0), SIMD3(outer0.x, outer0.y, z0),
             SIMD3(outer0.x, outer0.y, z1), SIMD3(outer1.x, outer1.y, z1), outN,
             SIMD2(0, 0), SIMD2(wallU, 0), SIMD2(wallU, wallV), SIMD2(0, wallV))
        // Rounded top cap — semicircular arc from inner to outer edge
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
            quad(a, b, c, d, arcNormal,
                 SIMD2(0, arcV0), SIMD2(wallU, arcV0), SIMD2(wallU, arcV1), SIMD2(0, arcV1))
        }
        // End cap at p0 side
        let capN0 = SIMD3<Float>(normalize(SIMD2(inner0.x - inner1.x, inner0.y - inner1.y)), 0)
        quad(SIMD3(outer0.x, outer0.y, z0), SIMD3(inner0.x, inner0.y, z0),
             SIMD3(inner0.x, inner0.y, z1), SIMD3(outer0.x, outer0.y, z1), capN0,
             SIMD2(0, 0), SIMD2(capU, 0), SIMD2(capU, wallV), SIMD2(0, wallV))
        // End cap at p1 side
        let capN1 = -capN0
        quad(SIMD3(inner1.x, inner1.y, z0), SIMD3(outer1.x, outer1.y, z0),
             SIMD3(outer1.x, outer1.y, z1), SIMD3(inner1.x, inner1.y, z1), capN1,
             SIMD2(0, 0), SIMD2(capU, 0), SIMD2(capU, wallV), SIMD2(0, wallV))
    }

    // MARK: - Posts (M10 Phase B)

    /// Corner posts at all four tile corners plus jamb posts flanking each gateway gap.
    /// These are emitted with a distinct material (light green) by the scene builder.
    private static func addPosts(tile: MazeTile, to verts: inout [MazeVertexSwift], indices: inout [UInt16], ws: WorldScale) {
        let hs = ws.tileMeshSize / 2.0
        let wt = ws.wallThickness
        let z0 = ws.floorY

        // Corner posts: a slim light-green cap at each corner joint. Kept *narrower*
        // than the wall and centered within its thickness so no vertical face is
        // coplanar with a wall face (that coplanarity caused 45°-grazing z-fighting at
        // wall joints); it pokes above the hedge so the cap still reads. Skipped where a
        // corner is interior to a merged room (both adjoining edges open).
        let cornerH = wt * 0.4
        let cornerTop = ws.wallHeight + wt   // above the hedge crown
        let cornerCenter = hs - wt / 2.0     // centered in the wall thickness
        for sx: Float in [-1, 1] {
            for sy: Float in [-1, 1] {
                let horiz: SurfaceDirection = sx > 0 ? .east : .west
                let vert: SurfaceDirection = sy > 0 ? .south : .north
                if tile.edgeType(horiz) == .open && tile.edgeType(vert) == .open { continue }
                addPost(center: SIMD2(sx * cornerCenter, sy * cornerCenter), halfSize: cornerH, z0: z0, zTop: cornerTop, to: &verts, indices: &indices)
            }
        }

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
                                to verts: inout [MazeVertexSwift], indices: inout [UInt16]) {
        let x0 = c.x - h, x1 = c.x + h, y0 = c.y - h, y1 = c.y + h

        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ cc: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>) {
            let base = UInt16(verts.count)
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
