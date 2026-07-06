import Metal
import ModelIO
import simd

/// One sub-mesh's index range + its material's flat diffuse colour (from the `.mtl`'s `Kd`).
/// Used to render texture-less OBJ kits with correct per-material colours.
struct AssetSubmesh {
    let indexOffset: Int   // element offset into the mesh's index buffer
    let indexCount: Int
    let color: SIMD4<Float>
}

/// A 3D model imported from a USD or OBJ file via ModelIO (M12). Geometry is packed into the
/// shader's `MazeVertex` layout with a **32-bit** index buffer (imported meshes routinely exceed
/// the shared tile buffer's 16-bit ceiling), rendered through the existing pipeline — just bound
/// as a different vertex + index buffer.
///
/// All meshes are concatenated into one vertex/index buffer, but each sub-mesh keeps its own
/// index range + material colour, so a caller can draw the whole thing textured (one draw) or
/// per-sub-mesh in flat colours (the multi-material OBJ kits).
final class AssetMesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer   // MTLIndexType.uint32
    let submeshes: [AssetSubmesh]
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>

    var totalIndexCount: Int { submeshes.reduce(0) { $0 + $1.indexCount } }
    var center: SIMD3<Float> { (boundsMin + boundsMax) * 0.5 }
    var size: SIMD3<Float> { boundsMax - boundsMin }

    init?(url: URL, device: MTLDevice) {
        // Plain load, then re-lay-out each mesh (forcing a vertexDescriptor at load time drops
        // USD geometry). Works for both USD and OBJ.
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: nil)
        var meshes: [MDLMesh] = []
        func collect(_ obj: MDLObject) {
            if let m = obj as? MDLMesh { meshes.append(m) }
            for child in obj.children.objects { collect(child) }
        }
        for i in 0..<asset.count { collect(asset.object(at: i)) }
        guard !meshes.isEmpty else { print("[AssetMesh] no meshes in \(url.lastPathComponent)"); return nil }

        let vdesc = MDLVertexDescriptor()
        vdesc.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        vdesc.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        vdesc.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        vdesc.layouts[0] = MDLVertexBufferLayout(stride: 32)

        var verts: [MazeVertexSwift] = []
        var indices: [UInt32] = []
        var subs: [AssetSubmesh] = []
        var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var bmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for mesh in meshes {
            if mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.3)
            }
            mesh.vertexDescriptor = vdesc
            let base = UInt32(verts.count)
            let vp = mesh.vertexBuffers[0].map().bytes
            for i in 0..<mesh.vertexCount {
                let o = i * 32
                func f(_ b: Int) -> Float { vp.load(fromByteOffset: o + b, as: Float.self) }
                let pos = SIMD3<Float>(f(0), f(4), f(8))
                // Flip V: Metal's texture origin is top-left, but OBJ/USD UVs are authored
                // bottom-left — without this the diffuse atlas samples vertically mirrored
                // (e.g. the horse statue's wood base bled onto the tail/support strut).
                verts.append(MazeVertexSwift(position: pos, normal: SIMD3(f(12), f(16), f(20)), texCoord: SIMD2(f(24), 1.0 - f(28)), aoFactor: 1.0))
                bmin = min(bmin, pos); bmax = max(bmax, pos)
            }
            for case let sm as MDLSubmesh in mesh.submeshes ?? [] {
                let start = indices.count
                let ip = sm.indexBuffer.map().bytes
                switch sm.indexType {
                case .uint16: for j in 0..<sm.indexCount { indices.append(base + UInt32(ip.load(fromByteOffset: j * 2, as: UInt16.self))) }
                case .uint32: for j in 0..<sm.indexCount { indices.append(base + ip.load(fromByteOffset: j * 4, as: UInt32.self)) }
                default: break
                }
                subs.append(AssetSubmesh(indexOffset: start, indexCount: indices.count - start, color: Self.materialColor(sm)))
            }
        }

        guard !verts.isEmpty, !indices.isEmpty,
              let vb = device.makeBuffer(bytes: verts, length: MemoryLayout<MazeVertexSwift>.stride * verts.count, options: .storageModeShared),
              let ib = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt32>.stride * indices.count, options: .storageModeShared)
        else { return nil }
        vb.label = "AssetVertices(\(url.lastPathComponent))"
        ib.label = "AssetIndices(\(url.lastPathComponent))"

        self.vertexBuffer = vb
        self.indexBuffer = ib
        self.submeshes = subs
        self.boundsMin = bmin
        self.boundsMax = bmax
        print("[AssetMesh] \(url.lastPathComponent): \(verts.count) verts, \(indices.count) indices, \(subs.count) submeshes")
    }

    /// The sub-mesh material's diffuse colour (ModelIO maps the OBJ/MTL `Kd` to `.baseColor`).
    private static func materialColor(_ sm: MDLSubmesh) -> SIMD4<Float> {
        guard let prop = sm.material?.property(with: .baseColor) else { return SIMD4(0.8, 0.8, 0.8, 1) }
        if prop.type == .float3 { let c = prop.float3Value; return SIMD4(c.x, c.y, c.z, 1) }
        if prop.type == .color, let cg = prop.color, let comps = cg.components, comps.count >= 3 {
            return SIMD4(Float(comps[0]), Float(comps[1]), Float(comps[2]), 1)
        }
        return SIMD4(0.8, 0.8, 0.8, 1)
    }
}
