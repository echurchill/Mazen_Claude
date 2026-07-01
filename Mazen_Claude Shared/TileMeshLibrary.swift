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
    private var floorMeshes: [UInt8: TileMesh] = [:]
    private var wallMeshes: [UInt8: TileMesh] = [:]

    static let tileSize: Float = 0.98
    static let wallHeight: Float = 1.2
    static let wallThickness: Float = 0.12
    static let floorY: Float = 0.001
    static let uvScale: Float = 2.0

    init(device: MTLDevice) {
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

        // Generate all 16 possible connection masks (4 bits = NESW)
        for mask: UInt8 in 0..<16 {
            let openings = DirectionMask(rawValue: mask)

            let fStart = allIndices.count
            Self.addFloor(to: &allVerts, indices: &allIndices, openings: openings)
            let fCount = allIndices.count - fStart
            floorMeshes[mask] = TileMesh(vertexOffset: 0, indexOffset: fStart, indexCount: fCount)

            let wStart = allIndices.count
            if !openings.contains(.north) {
                Self.addWall(edge: .north, to: &allVerts, indices: &allIndices)
            }
            if !openings.contains(.east) {
                Self.addWall(edge: .east, to: &allVerts, indices: &allIndices)
            }
            if !openings.contains(.south) {
                Self.addWall(edge: .south, to: &allVerts, indices: &allIndices)
            }
            if !openings.contains(.west) {
                Self.addWall(edge: .west, to: &allVerts, indices: &allIndices)
            }
            let wCount = allIndices.count - wStart
            if wCount > 0 {
                wallMeshes[mask] = TileMesh(vertexOffset: 0, indexOffset: wStart, indexCount: wCount)
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

    func wallMesh(for openings: DirectionMask) -> TileMesh? {
        return wallMeshes[openings.rawValue & 0x0F]
    }

    // MARK: - Geometry builders

    private static func addFloor(to verts: inout [MazeVertexSwift], indices: inout [UInt16], openings: DirectionMask) {
        let hs: Float = 0.48
        let z = floorY
        let base = UInt16(verts.count)

        let n = !openings.contains(.north)
        let s = !openings.contains(.south)
        let e = !openings.contains(.east)
        let w = !openings.contains(.west)

        func cornerAO(_ wall1: Bool, _ wall2: Bool) -> Float {
            if wall1 && wall2 { return 0.5 }
            if wall1 || wall2 { return 0.7 }
            return 1.0
        }

        let fuv = hs * 2.0 * uvScale
        verts.append(contentsOf: [
            MazeVertexSwift(position: SIMD3(-hs, -hs, z), normal: SIMD3(0, 0, 1), texCoord: SIMD2(0, 0), aoFactor: cornerAO(n, w)),
            MazeVertexSwift(position: SIMD3( hs, -hs, z), normal: SIMD3(0, 0, 1), texCoord: SIMD2(fuv, 0), aoFactor: cornerAO(n, e)),
            MazeVertexSwift(position: SIMD3( hs,  hs, z), normal: SIMD3(0, 0, 1), texCoord: SIMD2(fuv, fuv), aoFactor: cornerAO(s, e)),
            MazeVertexSwift(position: SIMD3(-hs,  hs, z), normal: SIMD3(0, 0, 1), texCoord: SIMD2(0, fuv), aoFactor: cornerAO(s, w)),
        ])
        indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
    }

    private static func addWall(edge: SurfaceDirection, to verts: inout [MazeVertexSwift], indices: inout [UInt16]) {
        let hs = tileSize / 2.0
        let wt = wallThickness
        let z0 = floorY
        let z1 = wallHeight

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

        let wallU = tileSize * uvScale
        let wallV = (z1 - z0) * uvScale
        let capU = wt * uvScale

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
            let arcV0 = wallV + sin0 * arcRadius * uvScale
            let arcV1 = wallV + sin1 * arcRadius * uvScale
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
}
