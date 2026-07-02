import Metal
import MetalKit
import simd
import ImageIO

let maxBuffersInFlight = 3

nonisolated enum RendererError: Error {
    case badDevice
    case badPipeline
}

struct DrawCall {
    var indexOffset: Int
    var indexCount: Int
    var instanceOffset: Int
    var instanceCount: Int
}

class Renderer: NSObject, MTKViewDelegate {

    public let device: MTLDevice

#if !targetEnvironment(simulator)
    let commandQueue: MTL4CommandQueue
    let commandBuffer: MTL4CommandBuffer
    let commandAllocators: [MTL4CommandAllocator]
    let residencySet: MTLResidencySet
    let vertexArgTable: MTL4ArgumentTable
    let fragmentArgTable: MTL4ArgumentTable
#endif

    let endFrameEvent: MTLSharedEvent
    var frameIndex = 0

    var pipelineState: MTLRenderPipelineState
    var skyPipelineState: MTLRenderPipelineState
    var shadowPipelineState: MTLRenderPipelineState
    var depthState: MTLDepthStencilState
    var depthStateNoWrite: MTLDepthStencilState
    var depthStateAlways: MTLDepthStencilState

    var tileMeshLib: TileMeshLibrary
    var diffuseArray: MTLTexture!
    var normalArray: MTLTexture!
    var skyboxTexture: MTLTexture!
    var shadowMapTexture: MTLTexture!
    var texSampler: MTLSamplerState!

    var frameUniformBuffers: [MTLBuffer]
    var instanceBuffers: [MTLBuffer]
    var opaqueDrawCalls: [DrawCall] = []
    var wallDrawCallRange: Range<Int> = 0..<0
    var translucentDrawCalls: [DrawCall] = []

    var currentBufferIndex = 0
    var aspect: Float = 1.0

    var gameState: GameState
    var lastFrameTime: CFTimeInterval = 0
    var frameTimeSamples: [Float] = []
    var debugSingleTile = false

    private var opaqueFogTiles: [TileEntry] = []
    private var dissolveTiles: [TileEntry] = []
    private var frameTiles: [TileEntry] = []
    private var mazeFloorTiles: [UInt8: [TileEntry]] = [:]
    private var mazeWallTiles: [UInt8: [TileEntry]] = [:]

    private static let faceColors: [CubeFace: SIMD4<Float>] = [
        .positiveX: SIMD4(0.85, 0.75, 0.70, 1.0),
        .negativeX: SIMD4(0.70, 0.80, 0.85, 1.0),
        .positiveY: SIMD4(0.80, 0.85, 0.70, 1.0),
        .negativeY: SIMD4(0.85, 0.80, 0.65, 1.0),
        .positiveZ: SIMD4(0.80, 0.75, 0.85, 1.0),
        .negativeZ: SIMD4(0.75, 0.85, 0.80, 1.0),
    ]

    @MainActor
    init?(metalKitView: MTKView) {
#if targetEnvironment(simulator)
        return nil
#else
        guard let device = metalKitView.device else { return nil }
        self.device = device

        self.commandQueue = device.makeMTL4CommandQueue()!
        self.commandBuffer = device.makeCommandBuffer()!
        self.commandAllocators = (0..<maxBuffersInFlight).map { _ in device.makeCommandAllocator()! }

        let argDesc = MTL4ArgumentTableDescriptor()
        argDesc.maxBufferBindCount = 4
        self.vertexArgTable = try! device.makeArgumentTable(descriptor: argDesc)
        argDesc.maxTextureBindCount = 4
        argDesc.maxSamplerStateBindCount = 1
        self.fragmentArgTable = try! device.makeArgumentTable(descriptor: argDesc)

        self.endFrameEvent = device.makeSharedEvent()!
        self.frameIndex = maxBuffersInFlight
        self.endFrameEvent.signaledValue = UInt64(frameIndex - 1)

        metalKitView.depthStencilPixelFormat = .depth32Float_stencil8
        metalKitView.colorPixelFormat = .bgra8Unorm_srgb
        metalKitView.sampleCount = 4
        metalKitView.clearColor = MTLClearColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1.0)

        // Pipeline
        let library = device.makeDefaultLibrary()!
        let compiler = try! device.makeCompiler(descriptor: MTL4CompilerDescriptor())

        let vertFuncDesc = MTL4LibraryFunctionDescriptor()
        vertFuncDesc.library = library
        vertFuncDesc.name = "vertexShader"
        let fragFuncDesc = MTL4LibraryFunctionDescriptor()
        fragFuncDesc.library = library
        fragFuncDesc.name = "fragmentShader"

        let pipeDesc = MTL4RenderPipelineDescriptor()
        pipeDesc.label = "MazePipeline"
        pipeDesc.rasterSampleCount = metalKitView.sampleCount
        pipeDesc.vertexFunctionDescriptor = vertFuncDesc
        pipeDesc.fragmentFunctionDescriptor = fragFuncDesc
        pipeDesc.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        pipeDesc.colorAttachments[0].blendingState = .enabled
        pipeDesc.colorAttachments[0].rgbBlendOperation = .add
        pipeDesc.colorAttachments[0].alphaBlendOperation = .add
        pipeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipeDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        self.pipelineState = try! compiler.makeRenderPipelineState(descriptor: pipeDesc)

        // Sky pipeline
        let skyVertDesc = MTL4LibraryFunctionDescriptor()
        skyVertDesc.library = library
        skyVertDesc.name = "skyVertexShader"
        let skyFragDesc = MTL4LibraryFunctionDescriptor()
        skyFragDesc.library = library
        skyFragDesc.name = "skyFragmentShader"

        let skyPipeDesc = MTL4RenderPipelineDescriptor()
        skyPipeDesc.label = "SkyPipeline"
        skyPipeDesc.rasterSampleCount = metalKitView.sampleCount
        skyPipeDesc.vertexFunctionDescriptor = skyVertDesc
        skyPipeDesc.fragmentFunctionDescriptor = skyFragDesc
        skyPipeDesc.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat

        self.skyPipelineState = try! compiler.makeRenderPipelineState(descriptor: skyPipeDesc)

        // Shadow pipeline (depth-only, no fragment)
        let shadowVertDesc = MTL4LibraryFunctionDescriptor()
        shadowVertDesc.library = library
        shadowVertDesc.name = "shadowVertexShader"

        let shadowPipeDesc = MTL4RenderPipelineDescriptor()
        shadowPipeDesc.label = "ShadowPipeline"
        shadowPipeDesc.rasterSampleCount = 1
        shadowPipeDesc.vertexFunctionDescriptor = shadowVertDesc

        self.shadowPipelineState = try! compiler.makeRenderPipelineState(descriptor: shadowPipeDesc)

        // Shadow map texture (1024x1024)
        let shadowDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 1024, height: 1024, mipmapped: false)
        shadowDesc.storageMode = .private
        shadowDesc.usage = [.renderTarget, .shaderRead]
        self.shadowMapTexture = device.makeTexture(descriptor: shadowDesc)!
        self.shadowMapTexture.label = "ShadowMap"

        // Depth states
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: depthDesc)!

        let depthDescNoWrite = MTLDepthStencilDescriptor()
        depthDescNoWrite.depthCompareFunction = .less
        depthDescNoWrite.isDepthWriteEnabled = false
        self.depthStateNoWrite = device.makeDepthStencilState(descriptor: depthDescNoWrite)!

        let depthDescAlways = MTLDepthStencilDescriptor()
        depthDescAlways.depthCompareFunction = .always
        depthDescAlways.isDepthWriteEnabled = false
        self.depthStateAlways = device.makeDepthStencilState(descriptor: depthDescAlways)!

        // Tile mesh library
        self.tileMeshLib = TileMeshLibrary(device: device)

        // Textures
        self.diffuseArray = Self.loadTextureArray(device: device,
            names: ["hedge_diff", "gravel_diff", "stone_diff"], srgb: true)
        self.normalArray = Self.loadTextureArray(device: device,
            names: ["hedge_nor", "gravel_nor", "stone_nor"], srgb: false)
        self.skyboxTexture = Self.loadTexture2D(device: device, name: "skybox", srgb: true)

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .repeat
        samplerDesc.tAddressMode = .repeat
        self.texSampler = device.makeSamplerState(descriptor: samplerDesc)!

        // Per-frame buffers
        let maxInstances = 6 * 25 * 25
        let instanceSize = MemoryLayout<InstanceDataSwift>.stride * maxInstances
        let frameSize = MemoryLayout<FrameUniformsSwift>.stride

        var frameBufs: [MTLBuffer] = []
        var instBufs: [MTLBuffer] = []
        for _ in 0..<maxBuffersInFlight {
            frameBufs.append(device.makeBuffer(length: frameSize, options: .storageModeShared)!)
            instBufs.append(device.makeBuffer(length: instanceSize, options: .storageModeShared)!)
        }
        self.frameUniformBuffers = frameBufs
        self.instanceBuffers = instBufs

        // Game state — mark some tiles discovered for visual testing
        self.gameState = GameState(size: 5)
        Self.setupInitialDiscovery(gameState: self.gameState)

        // Residency set
        let resDesc = MTLResidencySetDescriptor()
        resDesc.initialCapacity = 7 + frameBufs.count + instBufs.count
        let rs = try! device.makeResidencySet(descriptor: resDesc)
        rs.addAllocation(tileMeshLib.vertexBuffer)
        rs.addAllocation(tileMeshLib.indexBuffer)
        if let d = self.diffuseArray { rs.addAllocation(d) }
        if let n = self.normalArray { rs.addAllocation(n) }
        if let s = self.skyboxTexture { rs.addAllocation(s) }
        rs.addAllocation(self.shadowMapTexture)
        for buf in frameBufs { rs.addAllocation(buf) }
        for buf in instBufs { rs.addAllocation(buf) }
        rs.commit()
        commandQueue.addResidencySet(rs)
        self.residencySet = rs

        super.init()
#endif
    }

    func resetGame(size: Int) {
        gameState = GameState(size: size)
        Self.setupInitialDiscovery(gameState: gameState)
    }

    private static func setupInitialDiscovery(gameState: GameState) {
        let model = gameState.cubeModel
        let n = model.size
        for face in CubeFace.allCases {
            for row in 0..<n {
                for col in 0..<n {
                    if let (ci, fi) = model.faceletAt(face: face, row: row, col: col) {
                        model.cubies[ci].facelets[fi].tileState = .discovered
                        model.cubies[ci].facelets[fi].discoveryAmount = 1.0
                    }
                }
            }
        }
    }

    private static func loadTextureArray(device: MTLDevice, names: [String], srgb: Bool) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = srgb ? .rgba8Unorm_srgb : .rgba8Unorm
        desc.width = 512
        desc.height = 512
        desc.arrayLength = names.count
        desc.storageMode = .shared
        desc.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = srgb ? "DiffuseArray" : "NormalArray"

        let bytesPerRow = 512 * 4
        let bytesPerImage = bytesPerRow * 512
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        for (i, name) in names.enumerated() {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
                NSLog("Texture not found: %@.png", name)
                continue
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                NSLog("Failed to decode: %@.png", name)
                continue
            }

            var pixels = [UInt8](repeating: 255, count: bytesPerImage)
            guard let ctx = CGContext(data: &pixels,
                                     width: 512, height: 512,
                                     bitsPerComponent: 8,
                                     bytesPerRow: bytesPerRow,
                                     space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                continue
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 512, height: 512))

            let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                   size: MTLSize(width: 512, height: 512, depth: 1))
            texture.replace(region: region, mipmapLevel: 0, slice: i,
                           withBytes: pixels, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
        }

        return texture
    }

    private static func loadTexture2D(device: MTLDevice, name: String, srgb: Bool) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            NSLog("Texture not found: %@.png", name)
            return nil
        }

        let w = cgImage.width
        let h = cgImage.height
        let bytesPerRow = w * 4
        let bytesPerImage = bytesPerRow * h

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm,
            width: w, height: h, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = name

        var pixels = [UInt8](repeating: 255, count: bytesPerImage)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels,
                                 width: w, height: h,
                                 bitsPerComponent: 8,
                                 bytesPerRow: bytesPerRow,
                                 space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: w, height: h, depth: 1))
        texture.replace(region: region, mipmapLevel: 0,
                       withBytes: pixels, bytesPerRow: bytesPerRow)

        return texture
    }

    // MARK: - Per-frame

    private func buildDrawCalls() {
        if debugSingleTile {
            buildSingleTileDrawCalls()
            return
        }
        let model = gameState.cubeModel
        let buf = instanceBuffers[currentBufferIndex]
        let ptr = buf.contents().bindMemory(to: InstanceDataSwift.self, capacity: 6 * model.size * model.size)

        opaqueFogTiles.removeAll(keepingCapacity: true)
        dissolveTiles.removeAll(keepingCapacity: true)
        frameTiles.removeAll(keepingCapacity: true)
        for key in mazeFloorTiles.keys { mazeFloorTiles[key]?.removeAll(keepingCapacity: true) }
        for key in mazeWallTiles.keys { mazeWallTiles[key]?.removeAll(keepingCapacity: true) }

        // Precompute slice rotation matrix if active
        var sliceAnimMatrix: float4x4?
        let sr = gameState.sliceRotation
        if sr.isActive {
            let axisVec: SIMD3<Float> = sr.axis == 0 ? SIMD3(1,0,0) : sr.axis == 1 ? SIMD3(0,1,0) : SIMD3(0,0,1)
            let t = sr.progress * sr.progress * (3 - 2 * sr.progress)
            let currentAngle = sr.angle * t
            sliceAnimMatrix = float4x4.rotation(radians: currentAngle, axis: axisVec)
        }

        for face in CubeFace.allCases {
            for row in 0..<model.size {
                for col in 0..<model.size {
                    var matrix = model.worldMatrix(face: face, row: row, col: col)

                    guard let (ci, fi) = model.faceletAt(face: face, row: row, col: col) else { continue }
                    let facelet = model.cubies[ci].facelets[fi]

                    if let animMat = sliceAnimMatrix, sr.affectedCubies.contains(ci) {
                        matrix = animMat * matrix
                    }

                    let faceColor = Self.faceColors[face]!

                    // Frame rail for every tile
                    let frameInst = InstanceDataSwift(
                        modelMatrix: matrix,
                        baseColor: SIMD4(0.06, 0.06, 0.08, 1.0),
                        materialID: 7,
                        tileID: 0,
                        discoveryAmount: 1.0,
                        styleSeed: 0
                    )
                    frameTiles.append(TileEntry(instance: frameInst, mesh: tileMeshLib.frameMesh))

                    switch facelet.tileState {
                    case .unknown:
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
                        let openings = facelet.mazeTile.openings
                        let pathColor = SIMD4<Float>(0.72, 0.62, 0.45, 1.0)
                        let mazeInst = InstanceDataSwift(
                            modelMatrix: matrix,
                            baseColor: pathColor,
                            materialID: 1,
                            tileID: UInt32(facelet.id.rawValue),
                            discoveryAmount: 1.0,
                            styleSeed: facelet.mazeTile.styleSeed
                        )
                        let key = openings.rawValue & 0x0F
                        mazeFloorTiles[key, default: []].append(TileEntry(instance: mazeInst, mesh: tileMeshLib.floorMesh(for: openings)))
                        if let wm = tileMeshLib.wallMesh(for: openings) {
                            mazeWallTiles[key, default: []].append(TileEntry(instance: mazeInst, mesh: wm))
                        }

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
                        let openings = facelet.mazeTile.openings
                        let pathColor = SIMD4<Float>(0.72, 0.62, 0.45, 1.0)
                        let inst = InstanceDataSwift(
                            modelMatrix: matrix,
                            baseColor: pathColor,
                            materialID: 1,
                            tileID: UInt32(facelet.id.rawValue),
                            discoveryAmount: 1.0,
                            styleSeed: facelet.mazeTile.styleSeed
                        )
                        let key = openings.rawValue & 0x0F
                        mazeFloorTiles[key, default: []].append(TileEntry(instance: inst, mesh: tileMeshLib.floorMesh(for: openings)))
                        if let wm = tileMeshLib.wallMesh(for: openings) {
                            mazeWallTiles[key, default: []].append(TileEntry(instance: inst, mesh: wm))
                        }
                    }
                }
            }
        }

        // Player marker (orbit mode only)
        if gameState.camera.mode == .orbit {
            var pMatrix = model.worldMatrix(face: gameState.player.face, row: gameState.player.row, col: gameState.player.col)
            if let animMat = sliceAnimMatrix, sr.playerCubieIndex >= 0, sr.affectedCubies.contains(sr.playerCubieIndex) {
                pMatrix = animMat * pMatrix
            }
            let facingAngle: Float = {
                switch gameState.player.facing {
                case .north: return .pi
                case .west:  return .pi / 2
                case .south: return 0
                case .east:  return -.pi / 2
                }
            }()
            let localRot = float4x4.rotation(radians: facingAngle, axis: SIMD3(0, 0, 1))
            pMatrix = pMatrix * localRot
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

        // Pack instances — opaque first, then translucent
        var idx = 0
        opaqueDrawCalls.removeAll()
        translucentDrawCalls.removeAll()

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
        wallDrawCallRange = wallDrawCallStart..<opaqueDrawCalls.count

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
    }

    private func buildSingleTileDrawCalls() {
        let buf = instanceBuffers[currentBufferIndex]
        let ptr = buf.contents().bindMemory(to: InstanceDataSwift.self, capacity: 4)

        opaqueDrawCalls.removeAll()
        translucentDrawCalls.removeAll()

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
        let floorMesh = tileMeshLib.floorMesh(for: openings)
        ptr[idx] = inst
        idx += 1
        opaqueDrawCalls.append(DrawCall(
            indexOffset: floorMesh.indexOffset,
            indexCount: floorMesh.indexCount,
            instanceOffset: 0,
            instanceCount: 1
        ))

        // Walls
        if let wallMesh = tileMeshLib.wallMesh(for: openings) {
            ptr[idx] = inst
            idx += 1
            opaqueDrawCalls.append(DrawCall(
                indexOffset: wallMesh.indexOffset,
                indexCount: wallMesh.indexCount,
                instanceOffset: 1,
                instanceCount: 1
            ))
        }
    }

    private func updateFrameUniforms() {
        let buf = frameUniformBuffers[currentBufferIndex]
        let ptr = buf.contents().bindMemory(to: FrameUniformsSwift.self, capacity: 1)
        let vp = gameState.viewProjectionMatrix(aspect: aspect)
        let lightDir = normalize(SIMD3<Float>(0.4, 0.8, 0.6))
        let lightPos = lightDir * 15.0
        let lightView = float4x4.lookAt(eye: lightPos, target: SIMD3(0,0,0), up: SIMD3(0,1,0))
        let lightProj = float4x4.orthographic(left: -8, right: 8, bottom: -8, top: 8, nearZ: 5, farZ: 25)
        let lightVP = lightProj * lightView
        ptr.pointee = FrameUniformsSwift(
            viewProjectionMatrix: vp,
            cameraPosition: gameState.cameraPosition(),
            time: gameState.time,
            lightDirection: lightDir,
            inverseViewProjectionMatrix: vp.inverse,
            cameraUp: gameState.cameraUp(),
            lightViewProjectionMatrix: lightVP
        )
    }

    // MARK: - MTKViewDelegate

    func draw(in view: MTKView) {
#if !targetEnvironment(simulator)
        let now = CACurrentMediaTime()
        let dt = lastFrameTime == 0 ? Float(1.0/60.0) : Float(now - lastFrameTime)
        lastFrameTime = now

        gameState.frameTimeMs = dt * 1000.0
        frameTimeSamples.append(gameState.frameTimeMs)
        if frameTimeSamples.count >= 120 {
            let avg = frameTimeSamples.reduce(0, +) / Float(frameTimeSamples.count)
            gameState.avgFrameTimeMs = avg
            frameTimeSamples.removeAll()
        }

        gameState.update(deltaTime: dt)

        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentMTL4RenderPassDescriptor else { return }

        let waitValue = UInt64(frameIndex - maxBuffersInFlight)
        endFrameEvent.wait(untilSignaledValue: waitValue, timeoutMS: 10)

        currentBufferIndex = frameIndex % maxBuffersInFlight
        let allocator = commandAllocators[currentBufferIndex]
        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)

        updateFrameUniforms()
        buildDrawCalls()

        // ── Shadow pass ──────────────────────────────────────────
        vertexArgTable.setAddress(tileMeshLib.vertexBuffer.gpuAddress, index: BufferIndex.vertices.rawValue)
        vertexArgTable.setAddress(
            frameUniformBuffers[currentBufferIndex].gpuAddress,
            index: BufferIndex.frameUniforms.rawValue
        )
        vertexArgTable.setAddress(
            instanceBuffers[currentBufferIndex].gpuAddress,
            index: BufferIndex.instances.rawValue
        )

        let shadowPassDesc = MTL4RenderPassDescriptor()
        shadowPassDesc.depthAttachment.texture = shadowMapTexture
        shadowPassDesc.depthAttachment.loadAction = .clear
        shadowPassDesc.depthAttachment.storeAction = .store
        shadowPassDesc.depthAttachment.clearDepth = 1.0

        if let shadowEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: shadowPassDesc) {
            shadowEncoder.label = "Shadow Pass"
            shadowEncoder.setRenderPipelineState(shadowPipelineState)
            shadowEncoder.setDepthStencilState(depthState)
            shadowEncoder.setCullMode(.front)
            shadowEncoder.setFrontFacing(.counterClockwise)
            shadowEncoder.setArgumentTable(vertexArgTable, stages: .vertex)

            let idxBase = tileMeshLib.indexBuffer.gpuAddress
            let idxLen = tileMeshLib.indexBuffer.length
            for dc in opaqueDrawCalls {
                shadowEncoder.drawIndexedPrimitives(
                    primitiveType: .triangle,
                    indexCount: dc.indexCount,
                    indexType: .uint16,
                    indexBuffer: idxBase + UInt64(dc.indexOffset * MemoryLayout<UInt16>.stride),
                    indexBufferLength: idxLen - dc.indexOffset * MemoryLayout<UInt16>.stride,
                    instanceCount: dc.instanceCount,
                    baseVertex: 0,
                    baseInstance: dc.instanceOffset
                )
            }
            shadowEncoder.endEncoding()
        }

        // ── Main pass ──────────────────────────────────────────
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            fatalError("Failed to create render encoder")
        }

        encoder.label = "Maze Render"
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setRenderPipelineState(pipelineState)

        encoder.setArgumentTable(vertexArgTable, stages: .vertex)
        encoder.setArgumentTable(fragmentArgTable, stages: .fragment)

        fragmentArgTable.setAddress(
            frameUniformBuffers[currentBufferIndex].gpuAddress,
            index: BufferIndex.frameUniforms.rawValue
        )
        fragmentArgTable.setAddress(
            instanceBuffers[currentBufferIndex].gpuAddress,
            index: BufferIndex.instances.rawValue
        )
        if let d = diffuseArray { fragmentArgTable.setTexture(d.gpuResourceID, index: TextureIndex.diffuseArray.rawValue) }
        if let n = normalArray { fragmentArgTable.setTexture(n.gpuResourceID, index: TextureIndex.normalArray.rawValue) }
        if let sb = skyboxTexture { fragmentArgTable.setTexture(sb.gpuResourceID, index: TextureIndex.skybox.rawValue) }
        fragmentArgTable.setTexture(shadowMapTexture.gpuResourceID, index: TextureIndex.shadowMap.rawValue)
        if let s = texSampler { fragmentArgTable.setSamplerState(s.gpuResourceID, index: 0) }

        // Sky pass: fullscreen triangle, no depth test/write
        encoder.setRenderPipelineState(skyPipelineState)
        encoder.setDepthStencilState(depthStateAlways)
        encoder.setCullMode(.none)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)

        // Restore scene state
        encoder.setRenderPipelineState(pipelineState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)

        // Pass 1: opaque geometry (depth write ON)
        encoder.setDepthStencilState(depthState)
        let idxBufBase = tileMeshLib.indexBuffer.gpuAddress
        let idxBufLen = tileMeshLib.indexBuffer.length
        for dc in opaqueDrawCalls {
            encoder.drawIndexedPrimitives(
                primitiveType: .triangle,
                indexCount: dc.indexCount,
                indexType: .uint16,
                indexBuffer: idxBufBase + UInt64(dc.indexOffset * MemoryLayout<UInt16>.stride),
                indexBufferLength: idxBufLen - dc.indexOffset * MemoryLayout<UInt16>.stride,
                instanceCount: dc.instanceCount,
                baseVertex: 0,
                baseInstance: dc.instanceOffset
            )
        }

        // Pass 2: translucent overlays (depth write OFF)
        encoder.setDepthStencilState(depthStateNoWrite)
        for dc in translucentDrawCalls {
            encoder.drawIndexedPrimitives(
                primitiveType: .triangle,
                indexCount: dc.indexCount,
                indexType: .uint16,
                indexBuffer: idxBufBase + UInt64(dc.indexOffset * MemoryLayout<UInt16>.stride),
                indexBufferLength: idxBufLen - dc.indexOffset * MemoryLayout<UInt16>.stride,
                instanceCount: dc.instanceCount,
                baseVertex: 0,
                baseInstance: dc.instanceOffset
            )
        }

        encoder.endEncoding()

        commandBuffer.useResidencySet((view.layer as! CAMetalLayer).residencySet)
        commandBuffer.endCommandBuffer()

        commandQueue.waitForDrawable(drawable)
        commandQueue.commit([commandBuffer])
        commandQueue.signalDrawable(drawable)
        commandQueue.signalEvent(endFrameEvent, value: UInt64(frameIndex))
        frameIndex += 1
        drawable.present()
#endif
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = Float(size.width) / Float(size.height)
    }
}

struct TileEntry {
    var instance: InstanceDataSwift
    var mesh: TileMesh
}

// MARK: - Swift-side mirror structs

struct MazeVertexSwift {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var texCoord: SIMD2<Float>
    var aoFactor: Float
}

struct FrameUniformsSwift {
    var viewProjectionMatrix: float4x4
    var cameraPosition: SIMD3<Float>
    var time: Float
    var lightDirection: SIMD3<Float>
    var inverseViewProjectionMatrix: float4x4
    var cameraUp: SIMD3<Float>
    var lightViewProjectionMatrix: float4x4
}

struct InstanceDataSwift {
    var modelMatrix: float4x4
    var baseColor: SIMD4<Float>
    var materialID: UInt32
    var tileID: UInt32
    var discoveryAmount: Float
    var styleSeed: UInt32
}
