import Metal
import ModelIO
import simd

/// A 3D model imported from a USD (or OBJ) file via ModelIO (M12). Its geometry is packed
/// into the shader's `MazeVertex` layout with a **32-bit** index buffer (imported meshes
/// routinely exceed the shared tile buffer's 16-bit ceiling), so it renders through the
/// existing pipeline — just bound as a different vertex + index buffer.
///
/// All submeshes are flattened into one vertex/index buffer: M12-A renders the model with a
/// single flat material, so per-submesh material splits aren't needed yet.
final class AssetMesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer   // MTLIndexType.uint32
    let indexCount: Int
    /// Model-space bounds, for normalizing scale + resting the base on the ground.
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>

    var center: SIMD3<Float> { (boundsMin + boundsMax) * 0.5 }
    var size: SIMD3<Float> { boundsMax - boundsMin }

    init?(url: URL, device: MTLDevice) {
        // Plain load first (forcing a vertexDescriptor at load time can silently drop USD
        // geometry); we re-lay-out each mesh below.
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: nil)
        print("[AssetMesh] \(url.lastPathComponent): asset.count=\(asset.count)")

        var meshes: [MDLMesh] = []
        func collect(_ obj: MDLObject) {
            if let m = obj as? MDLMesh { meshes.append(m) }
            for child in obj.children.objects { collect(child) }
        }
        for i in 0..<asset.count { collect(asset.object(at: i)) }
        print("[AssetMesh] meshes found=\(meshes.count)")
        guard !meshes.isEmpty else { print("[AssetMesh] NO MESHES — ModelIO couldn't read the USD"); return nil }

        // Re-lay-out to a known, tightly-packed layout we can read back: pos(12) nor(12) uv(8).
        let vdesc = MDLVertexDescriptor()
        vdesc.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        vdesc.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        vdesc.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        vdesc.layouts[0] = MDLVertexBufferLayout(stride: 32)
        for mesh in meshes {
            if mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.3)
            }
            mesh.vertexDescriptor = vdesc
            print("[AssetMesh] mesh vertexCount=\(mesh.vertexCount) submeshes=\(mesh.submeshes?.count ?? 0)")
        }

        var verts: [MazeVertexSwift] = []
        var indices: [UInt32] = []
        var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var bmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for mesh in meshes {
            let base = UInt32(verts.count)
            let stride = 32
            let vmap = mesh.vertexBuffers[0].map()
            let vp = vmap.bytes
            for i in 0..<mesh.vertexCount {
                let o = i * stride
                func f(_ b: Int) -> Float { vp.load(fromByteOffset: o + b, as: Float.self) }
                let pos = SIMD3<Float>(f(0), f(4), f(8))
                let nor = SIMD3<Float>(f(12), f(16), f(20))
                let uv  = SIMD2<Float>(f(24), f(28))
                verts.append(MazeVertexSwift(position: pos, normal: nor, texCoord: uv, aoFactor: 1.0))
                bmin = min(bmin, pos)
                bmax = max(bmax, pos)
            }
            for case let sm as MDLSubmesh in mesh.submeshes ?? [] {
                let imap = sm.indexBuffer.map()
                let ip = imap.bytes
                switch sm.indexType {
                case .uint16:
                    for j in 0..<sm.indexCount { indices.append(base + UInt32(ip.load(fromByteOffset: j * 2, as: UInt16.self))) }
                case .uint32:
                    for j in 0..<sm.indexCount { indices.append(base + ip.load(fromByteOffset: j * 4, as: UInt32.self)) }
                default:
                    break
                }
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
        self.indexCount = indices.count
        self.boundsMin = bmin
        self.boundsMax = bmax
        print("[AssetMesh] loaded \(url.lastPathComponent): \(verts.count) verts, \(indices.count) indices, bounds \(bmin) … \(bmax)")
    }
}
