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

    let fogQuad: TileMesh
    let playerMarker: TileMesh
    private var floorMeshes: [UInt8: TileMesh] = [:]
    private var wallMeshes: [UInt8: TileMesh] = [:]

    static let tileSize: Float = 0.96
    static let wallHeight: Float = 0.35
    static let wallThickness: Float = 0.08
    static let floorY: Float = 0.001

    init(device: MTLDevice) {
        var allVerts: [MazeVertexSwift] = []
        var allIndices: [UInt16] = []

        func recordMesh() -> TileMesh {
            // placeholder, actual meshes added below
            TileMesh(vertexOffset: 0, indexOffset: 0, indexCount: 0)
        }

        // Fog quad — slightly smaller than floor to prevent cross-face occlusion at cube corners
        let fogStart = allVerts.count
        let fogIdxStart = allIndices.count
        let fogHs: Float = 0.46
        let fogZ: Float = 0.002
        allVerts.append(contentsOf: [
            MazeVertexSwift(position: SIMD3(-fogHs, -fogHs, fogZ), normal: SIMD3(0, 0, 1), texCoord: SIMD2(0, 0)),
            MazeVertexSwift(position: SIMD3( fogHs, -fogHs, fogZ), normal: SIMD3(0, 0, 1), texCoord: SIMD2(1, 0)),
            MazeVertexSwift(position: SIMD3( fogHs,  fogHs, fogZ), normal: SIMD3(0, 0, 1), texCoord: SIMD2(1, 1)),
            MazeVertexSwift(position: SIMD3(-fogHs,  fogHs, fogZ), normal: SIMD3(0, 0, 1), texCoord: SIMD2(0, 1)),
        ])
        let fBase = UInt16(fogStart)
        allIndices.append(contentsOf: [fBase+0, fBase+1, fBase+2, fBase+0, fBase+2, fBase+3])
        fogQuad = TileMesh(vertexOffset: fogStart, indexOffset: fogIdxStart, indexCount: 6)

        // Player marker — diamond body + arrow pointing in +Y (north)
        let pmVStart = allVerts.count
        let pmIStart = allIndices.count
        let pmH: Float = 0.45
        let pmR: Float = 0.12
        // Diamond body: 4 triangles from base to tip
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
            allVerts.append(MazeVertexSwift(position: a, normal: n, texCoord: SIMD2(0, 0)))
            allVerts.append(MazeVertexSwift(position: b, normal: n, texCoord: SIMD2(1, 0)))
            allVerts.append(MazeVertexSwift(position: pmTip, normal: n, texCoord: SIMD2(0.5, 1)))
            allIndices.append(contentsOf: [bi, bi+1, bi+2])
        }
        // Arrow: flat triangle on the floor pointing +Y (north)
        let arrowN = SIMD3<Float>(0, 0, 1)
        let arrowZ: Float = 0.03
        let ai = UInt16(allVerts.count)
        allVerts.append(MazeVertexSwift(position: SIMD3(0, pmR + 0.22, arrowZ), normal: arrowN, texCoord: SIMD2(0.5, 1)))
        allVerts.append(MazeVertexSwift(position: SIMD3(-0.08, pmR + 0.04, arrowZ), normal: arrowN, texCoord: SIMD2(0, 0)))
        allVerts.append(MazeVertexSwift(position: SIMD3( 0.08, pmR + 0.04, arrowZ), normal: arrowN, texCoord: SIMD2(1, 0)))
        allIndices.append(contentsOf: [ai, ai+1, ai+2])
        let pmIdxCount = allIndices.count - pmIStart
        playerMarker = TileMesh(vertexOffset: pmVStart, indexOffset: pmIStart, indexCount: pmIdxCount)

        // Pad index buffer to 4-byte alignment (UInt16 pairs) so all subsequent
        // drawIndexedPrimitives calls get a 4-byte-aligned GPU address
        if allIndices.count % 2 != 0 {
            allIndices.append(0)
        }

        // Generate all 16 possible connection masks (4 bits = NESW)
        for mask: UInt8 in 0..<16 {
            let openings = DirectionMask(rawValue: mask)

            // Floor mesh (separate from walls for depth bias)
            let fStart = allIndices.count
            Self.addFloor(to: &allVerts, indices: &allIndices)
            let fCount = allIndices.count - fStart
            floorMeshes[mask] = TileMesh(vertexOffset: 0, indexOffset: fStart, indexCount: fCount)

            // Wall mesh
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
        return floorMeshes[openings.rawValue & 0x0F] ?? fogQuad
    }

    func wallMesh(for openings: DirectionMask) -> TileMesh? {
        return wallMeshes[openings.rawValue & 0x0F]
    }

    // MARK: - Geometry builders

    private static func addFloor(to verts: inout [MazeVertexSwift], indices: inout [UInt16]) {
        let hs: Float = 0.46 // smaller than wall extent (0.48) to prevent cube-edge overhang
        let z = floorY
        let base = UInt16(verts.count)

        // Floor quad in XY plane, normal along +Z (outward from cube surface)
        verts.append(contentsOf: [
            MazeVertexSwift(position: SIMD3(-hs, -hs, z), normal: SIMD3(0, 0, 1), texCoord: SIMD2(0, 0)),
            MazeVertexSwift(position: SIMD3( hs, -hs, z), normal: SIMD3(0, 0, 1), texCoord: SIMD2(1, 0)),
            MazeVertexSwift(position: SIMD3( hs,  hs, z), normal: SIMD3(0, 0, 1), texCoord: SIMD2(1, 1)),
            MazeVertexSwift(position: SIMD3(-hs,  hs, z), normal: SIMD3(0, 0, 1), texCoord: SIMD2(0, 1)),
        ])
        indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
    }

    private static func addWall(edge: SurfaceDirection, to verts: inout [MazeVertexSwift], indices: inout [UInt16]) {
        let hs = tileSize / 2.0
        let wt = wallThickness
        let z0 = floorY
        let z1 = wallHeight

        // inner0/inner1 = inner edge (corridor side), outer0/outer1 = outer edge (tile boundary)
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
        let topN = SIMD3<Float>(0, 0, 1)

        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>) {
            let base = UInt16(verts.count)
            verts.append(contentsOf: [
                MazeVertexSwift(position: a, normal: n, texCoord: SIMD2(0, 0)),
                MazeVertexSwift(position: b, normal: n, texCoord: SIMD2(1, 0)),
                MazeVertexSwift(position: c, normal: n, texCoord: SIMD2(1, 1)),
                MazeVertexSwift(position: d, normal: n, texCoord: SIMD2(0, 1)),
            ])
            indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])
        }

        // Inner face
        quad(SIMD3(inner0.x, inner0.y, z0), SIMD3(inner1.x, inner1.y, z0),
             SIMD3(inner1.x, inner1.y, z1), SIMD3(inner0.x, inner0.y, z1), inN)
        // Outer face
        quad(SIMD3(outer1.x, outer1.y, z0), SIMD3(outer0.x, outer0.y, z0),
             SIMD3(outer0.x, outer0.y, z1), SIMD3(outer1.x, outer1.y, z1), outN)
        // Top face
        quad(SIMD3(inner0.x, inner0.y, z1), SIMD3(inner1.x, inner1.y, z1),
             SIMD3(outer1.x, outer1.y, z1), SIMD3(outer0.x, outer0.y, z1), topN)
        // End cap at p0 side
        let capN0 = SIMD3<Float>(normalize(SIMD2(inner0.x - inner1.x, inner0.y - inner1.y)), 0)
        quad(SIMD3(outer0.x, outer0.y, z0), SIMD3(inner0.x, inner0.y, z0),
             SIMD3(inner0.x, inner0.y, z1), SIMD3(outer0.x, outer0.y, z1), capN0)
        // End cap at p1 side
        let capN1 = -capN0
        quad(SIMD3(inner1.x, inner1.y, z0), SIMD3(outer1.x, outer1.y, z0),
             SIMD3(outer1.x, outer1.y, z1), SIMD3(inner1.x, inner1.y, z1), capN1)
    }
}
