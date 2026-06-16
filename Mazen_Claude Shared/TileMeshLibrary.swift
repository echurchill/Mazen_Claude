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
    private var tileMeshes: [UInt8: [TileMesh]] = [:]

    static let tileSize: Float = 0.96
    static let wallHeight: Float = 0.65
    static let wallThickness: Float = 0.08
    static let floorY: Float = 0.001

    init(device: MTLDevice) {
        var allVerts: [MazeVertexSwift] = []
        var allIndices: [UInt16] = []

        func recordMesh() -> TileMesh {
            // placeholder, actual meshes added below
            TileMesh(vertexOffset: 0, indexOffset: 0, indexCount: 0)
        }

        // Fog quad — flat quad lying on the surface
        let fogStart = allVerts.count
        let fogIdxStart = allIndices.count
        let hs = Self.tileSize / 2.0
        allVerts.append(contentsOf: [
            MazeVertexSwift(position: SIMD3(-hs, -hs, 0.02), normal: SIMD3(0, 0, 1), texCoord: SIMD2(0, 0)),
            MazeVertexSwift(position: SIMD3( hs, -hs, 0.02), normal: SIMD3(0, 0, 1), texCoord: SIMD2(1, 0)),
            MazeVertexSwift(position: SIMD3( hs,  hs, 0.02), normal: SIMD3(0, 0, 1), texCoord: SIMD2(1, 1)),
            MazeVertexSwift(position: SIMD3(-hs,  hs, 0.02), normal: SIMD3(0, 0, 1), texCoord: SIMD2(0, 1)),
        ])
        let fBase = UInt16(fogStart)
        allIndices.append(contentsOf: [fBase+0, fBase+1, fBase+2, fBase+0, fBase+2, fBase+3])
        fogQuad = TileMesh(vertexOffset: fogStart, indexOffset: fogIdxStart, indexCount: 6)

        // Player marker — diamond body + arrow pointing in +Y (north)
        let pmVStart = allVerts.count
        let pmIStart = allIndices.count
        let pmH: Float = 0.45
        let pmR: Float = 0.12
        let pmUp = SIMD3<Float>(0, 0, 1)
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

        // Generate all 16 possible connection masks (4 bits = NESW)
        for mask: UInt8 in 0..<16 {
            let openings = DirectionMask(rawValue: mask)

            // For each mask, generate 1 rotation variant (mask already encodes orientation)
            let vStart = allVerts.count
            let iStart = allIndices.count

            // Floor
            Self.addFloor(to: &allVerts, indices: &allIndices)

            // Walls on closed edges
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

            let idxCount = allIndices.count - iStart
            let mesh = TileMesh(vertexOffset: vStart, indexOffset: iStart, indexCount: idxCount)
            tileMeshes[mask] = [mesh]
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

    func mesh(for openings: DirectionMask) -> TileMesh {
        if let meshes = tileMeshes[openings.rawValue & 0x0F] {
            return meshes[0]
        }
        return fogQuad
    }

    // MARK: - Geometry builders

    private static func addFloor(to verts: inout [MazeVertexSwift], indices: inout [UInt16]) {
        let hs = tileSize / 2.0
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
        let wt = wallThickness / 2.0
        let wh = wallHeight
        let z0 = floorY
        let z1 = wh

        // Wall is an extruded box along one edge
        // In tile-local space: X = tangent (east), Y = bitangent (north), Z = normal (outward)
        // Walls extrude along Z from floor to wallHeight

        var p0: SIMD3<Float>, p1: SIMD3<Float>  // wall edge endpoints in XY
        var inwardNormal: SIMD3<Float>  // normal pointing into the corridor
        var wallOffset: Float  // how far from center to place the wall

        switch edge {
        case .north:  // -Y edge (toward row-1)
            p0 = SIMD3( hs, -hs + wt, 0)
            p1 = SIMD3(-hs, -hs + wt, 0)
            inwardNormal = SIMD3(0, 1, 0)
            wallOffset = hs
        case .south:  // +Y edge (toward row+1)
            p0 = SIMD3(-hs, hs - wt, 0)
            p1 = SIMD3( hs, hs - wt, 0)
            inwardNormal = SIMD3(0, -1, 0)
            wallOffset = hs
        case .east:  // right edge: X = +hs
            p0 = SIMD3(hs - wt,  hs, 0)
            p1 = SIMD3(hs - wt, -hs, 0)
            inwardNormal = SIMD3(-1, 0, 0)
            wallOffset = hs
        case .west:  // left edge: X = -hs
            p0 = SIMD3(-hs + wt, -hs, 0)
            p1 = SIMD3(-hs + wt,  hs, 0)
            inwardNormal = SIMD3(1, 0, 0)
            wallOffset = hs
        }

        // Inner face of the wall (facing the corridor)
        let base = UInt16(verts.count)
        verts.append(contentsOf: [
            MazeVertexSwift(position: SIMD3(p0.x, p0.y, z0), normal: inwardNormal, texCoord: SIMD2(0, 0)),
            MazeVertexSwift(position: SIMD3(p1.x, p1.y, z0), normal: inwardNormal, texCoord: SIMD2(1, 0)),
            MazeVertexSwift(position: SIMD3(p1.x, p1.y, z1), normal: inwardNormal, texCoord: SIMD2(1, 1)),
            MazeVertexSwift(position: SIMD3(p0.x, p0.y, z1), normal: inwardNormal, texCoord: SIMD2(0, 1)),
        ])
        indices.append(contentsOf: [base+0, base+1, base+2, base+0, base+2, base+3])

        // Top face of the wall
        let topNorm = SIMD3<Float>(0, 0, 1)
        let base2 = UInt16(verts.count)
        // Extend top cap from inner edge to outer edge
        let outerOffset = inwardNormal * (-wallThickness)
        verts.append(contentsOf: [
            MazeVertexSwift(position: SIMD3(p0.x, p0.y, z1), normal: topNorm, texCoord: SIMD2(0, 0)),
            MazeVertexSwift(position: SIMD3(p1.x, p1.y, z1), normal: topNorm, texCoord: SIMD2(1, 0)),
            MazeVertexSwift(position: SIMD3(p1.x + outerOffset.x, p1.y + outerOffset.y, z1), normal: topNorm, texCoord: SIMD2(1, 1)),
            MazeVertexSwift(position: SIMD3(p0.x + outerOffset.x, p0.y + outerOffset.y, z1), normal: topNorm, texCoord: SIMD2(0, 1)),
        ])
        indices.append(contentsOf: [base2+0, base2+1, base2+2, base2+0, base2+2, base2+3])
    }
}
