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

/// One imported model placed on the cube (M12-D asset registry).
struct ImportedProp {
    let mesh: AssetMesh
    let diffuse: MTLTexture?                // textured (one draw, materialID 11); nil = per-sub-mesh flat colours (materialID 10)
    let faceOffset: (row: Int, col: Int)   // tile offset from the +Z face centre
    let target: Float                       // fit the widest dimension to this many units
    let yUp: Bool                           // OBJ kits import Y-up; USD props Z-up
}

/// One piece of the imported modular house, positioned in a quarter's tile-local frame
/// (M12-E). All pieces of a quarter share that quarter's `.houseCorner` Prop anchor (tile
/// matrix + facing), so they ride slice rotations together and split as a unit — reusing the
/// exact machinery that already carries the procedural house.
struct HouseKitPiece {
    let mesh: AssetMesh
    let local: float4x4   // Y-up→Z-up, non-uniform scale, and edge placement within the tile
}

/// One prepared asset draw for the frame (a whole textured mesh, or one flat-colour sub-mesh).
struct AssetDrawCmd {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexOffset: Int        // element offset
    let indexCount: Int
    let instanceIndex: Int
    let diffuse: MTLTexture?
}

class Renderer: NSObject, MTKViewDelegate {

    /// Cube size the app launches with. The N key cycles odd sizes (3→5→7→9) live.
    static let initialCubeSize = 7

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
    // M12: imported props (asset registry) + a per-frame instance buffer + draw list.
    var importedProps: [ImportedProp] = []
    var houseAssembly: [HouseKitPiece] = []       // M12-E: canonical imported house quarter (two walls)
    var houseAssemblyDoor: [HouseKitPiece] = []   // the front quarter — one wall swapped for a door
    var assetInstanceBuffers: [MTLBuffer] = []
    var assetDrawCmds: [AssetDrawCmd] = []
    var opaqueDrawCalls: [DrawCall] = []
    var wallDrawCallRange: Range<Int> = 0..<0
    var translucentDrawCalls: [DrawCall] = []

    var currentBufferIndex = 0
    var aspect: Float = 1.0

    /// The world stack (M11.1). Bottom = the cube overworld (hub); pushing a portal-world puts
    /// it on top. Everything in the draw loop and input reads `gameState` = the active (top) world,
    /// so a single push/pop swaps the whole rendered world while every other world's state is
    /// retained on the stack (the scars persist). Same-size *and* different-size worlds work — the
    /// tile-mesh library and instance buffers are size-agnostic (see `resetGame`).
    var worldStack: [GameState] = []
    /// The active world — top of the stack. Read-only; mutate the stack via enter/exitWorld.
    var gameState: GameState { worldStack.last! }
    /// A throwaway 3³ interior world used to prove the swap in M11.1 (toggled with the O key).
    /// Replaced by real portal destinations in M11.2.
    private var testInterior: GameState?
    var lastFrameTime: CFTimeInterval = 0
    var frameTimeSamples: [Float] = []
    var debugSingleTile = false

    let sceneBuilder = SceneBuilder()

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
        argDesc.maxTextureBindCount = 5   // 0..3 maze/shadow + 4 = M12 asset diffuse
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

        // Shadow map texture (2048x2048 — keeps texel density up as the ortho volume
        // grows with cube size; a 9-face jamb/wall is only a few texels at 1024)
        let shadowDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
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

        // Game state (owns the per-world scale) — mark some tiles discovered for visual testing.
        // The overworld is the bottom of the world stack (M11.1). Use a local here: the computed
        // `gameState` getter can't be called before super.init().
        let overworld = GameState(size: Self.initialCubeSize)
        Self.setupInitialDiscovery(gameState: overworld)
        self.worldStack = [overworld]

        // Tile mesh library (geometry baked from the world scale)
        self.tileMeshLib = TileMeshLibrary(device: device, worldScale: overworld.worldScale)

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
        let maxInstances = 6 * WorldScale.maxSupportedSize * WorldScale.maxSupportedSize
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

        // M12: load an imported prop (dev absolute path — these get bundled for shipping later)
        // plus a small per-frame instance buffer for its transform/material.
        let modelsRoot = "/Volumes/Code Work/xCode work/Mazen_Claude/Mazen_Models"
        // Textured USD prop (one diffuse map, Z-up).
        func loadProp(_ dir: String, _ diffuse: String, _ off: (Int, Int), _ target: Float) -> ImportedProp? {
            guard let mesh = AssetMesh(url: URL(fileURLWithPath: "\(modelsRoot)/\(dir)/\(dir).usdc"), device: device) else {
                print("[Renderer] prop FAILED to load: \(dir)"); return nil
            }
            let diff = Self.loadTextureFromFile(url: URL(fileURLWithPath: "\(modelsRoot)/\(dir)/textures/\(diffuse).jpg"), device: device, srgb: true)
            return ImportedProp(mesh: mesh, diffuse: diff, faceOffset: off, target: target, yUp: false)
        }
        // Texture-less OBJ kit piece — flat per-material colours, Y-up.
        func loadSolid(_ relPath: String, _ off: (Int, Int), _ target: Float) -> ImportedProp? {
            guard let mesh = AssetMesh(url: URL(fileURLWithPath: "\(modelsRoot)/\(relPath)"), device: device) else {
                print("[Renderer] solid prop FAILED: \(relPath)"); return nil
            }
            return ImportedProp(mesh: mesh, diffuse: nil, faceOffset: off, target: target, yUp: true)
        }
        // Textured USD props at the plaza centre + its diagonal neighbours; solid-colour OBJ
        // temple pieces at the edge-middle tiles.
        let loadedProps: [ImportedProp] = [
            loadProp("stone_fire_pit_2k",     "stone_fire_pit_diff_2k",     ( 0,  0), 0.35),
            loadProp("horse_statue_01_2k",    "horse_statue_01_diff_2k",    (-1, -1), 0.60),
            loadProp("tree_stump_01_2k",      "tree_stump_01_diff_2k",      (-1,  1), 0.30),
            loadProp("tree_stump_02_2k",      "tree_stump_02_diff_2k",      ( 1, -1), 0.30),
            loadProp("old_military_crate_2k", "old_military_crate_diff_2k", ( 1,  1), 0.32),
            loadSolid("Modular Temple/Pillar_Large_Base.obj", (-1, 0), 0.55),
            loadSolid("Modular Temple/Prop_Flag_Sun.obj",     ( 0, -1), 0.50),
            loadSolid("Modular Temple/Prop_Flag_Moon.obj",    ( 0,  1), 0.50),
            loadSolid("Modular Temple/Prop_Vase.obj",         ( 1,  0), 0.28),
        ].compactMap { $0 }
        self.importedProps = loadedProps

        // M12-E: imported modular house. Load the kit's solid-colour OBJ pieces and assemble one
        // canonical quarter (authored for facing.n — two outer walls on the −X/−Y tile edges +
        // floor). The four `.houseCorner` props stamped in CubeModel place/orient the quarters and
        // carry them through slice rotations, so the building splits at the tile seams for free.
        func loadKit(_ name: String) -> AssetMesh? {
            AssetMesh(url: URL(fileURLWithPath: "\(modelsRoot)/modular_house_collection/\(name).obj"), device: device)
        }
        if let wall = loadKit("Structure_Exterior_Wall_Straight") {
            self.houseAssembly     = Self.buildHouseQuarter(wall: wall, front: false)
            self.houseAssemblyDoor = Self.buildHouseQuarter(wall: wall, front: true)
        } else {
            print("[Renderer] house kit FAILED to load")
        }

        var assetBufs: [MTLBuffer] = []
        for _ in 0..<maxBuffersInFlight {
            assetBufs.append(device.makeBuffer(length: MemoryLayout<InstanceDataSwift>.stride * 512, options: .storageModeShared)!)
        }
        self.assetInstanceBuffers = assetBufs

        // Residency set
        let resDesc = MTLResidencySetDescriptor()
        resDesc.initialCapacity = 9 + frameBufs.count + instBufs.count + assetBufs.count + loadedProps.count * 3
        let rs = try! device.makeResidencySet(descriptor: resDesc)
        rs.addAllocation(tileMeshLib.vertexBuffer)
        rs.addAllocation(tileMeshLib.indexBuffer)
        if let d = self.diffuseArray { rs.addAllocation(d) }
        if let n = self.normalArray { rs.addAllocation(n) }
        if let s = self.skyboxTexture { rs.addAllocation(s) }
        rs.addAllocation(self.shadowMapTexture)
        for buf in frameBufs { rs.addAllocation(buf) }
        for buf in instBufs { rs.addAllocation(buf) }
        for p in loadedProps {
            rs.addAllocation(p.mesh.vertexBuffer); rs.addAllocation(p.mesh.indexBuffer)
            if let d = p.diffuse { rs.addAllocation(d) }
        }
        for buf in assetBufs { rs.addAllocation(buf) }
        rs.commit()
        commandQueue.addResidencySet(rs)
        self.residencySet = rs

        super.init()
#endif
    }

    func resetGame(size: Int) {
        // Collapse to a single fresh overworld (drops any pushed portal-worlds).
        worldStack = [GameState(size: size)]
        Self.setupInitialDiscovery(gameState: gameState)
    }

    // MARK: - World stack (M11.1)

    /// Push a portal-world; it becomes the active world. The current world stays on the stack,
    /// fully intact, so returning to it preserves every twist and step (persistent scars).
    func enterWorld(_ world: GameState) {
        worldStack.append(world)
    }

    /// Pop back to the world beneath. No-op at the bottom (the overworld is never popped).
    func exitWorld() {
        if worldStack.count > 1 { worldStack.removeLast() }
    }

    /// M11.1 spine proof (O key): toggle a throwaway 3³ interior world. A 3³ cube reads as
    /// obviously different from the 7³ overworld, so a glance confirms the swap — and it also
    /// exercises a *different-size* world sharing the same tile library + buffers. Replaced by
    /// real portal props + a transition in M11.2.
    func toggleTestInterior() {
        if worldStack.count > 1 { exitWorld(); return }
        if testInterior == nil {
            let interior = GameState(size: 3)
            Self.setupInitialDiscovery(gameState: interior)
            testInterior = interior
        }
        enterWorld(testInterior!)
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

    /// M12: load a texture from an arbitrary file URL (imported model textures live outside
    /// the bundle). CGImageSource decodes JPG/PNG all the same.
    private static func loadTextureFromFile(url: URL, device: MTLDevice, srgb: Bool) -> MTLTexture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            NSLog("Asset texture not found/decodable: %@", url.path)
            return nil
        }
        let w = cgImage.width, h = cgImage.height
        let bytesPerRow = w * 4
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = url.lastPathComponent
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        texture.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: w, height: h, depth: 1)),
                        mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        return texture
    }

    // MARK: - Per-frame

    private func buildDrawCalls() {
        let buffer = instanceBuffers[currentBufferIndex]
        let result = debugSingleTile
            ? sceneBuilder.buildSingleTile(tileMeshLib: tileMeshLib, instanceBuffer: buffer)
            : sceneBuilder.build(gameState: gameState, tileMeshLib: tileMeshLib, instanceBuffer: buffer)
        opaqueDrawCalls = result.opaque
        translucentDrawCalls = result.translucent
        wallDrawCallRange = result.wallRange
    }

    private func updateFrameUniforms() {
        let buf = frameUniformBuffers[currentBufferIndex]
        let ptr = buf.contents().bindMemory(to: FrameUniformsSwift.self, capacity: 1)
        let ws = gameState.worldScale
        let vp = gameState.viewProjectionMatrix(aspect: aspect)
        let cs = gameState.celestialSystem
        // Lighting uses the true sun direction; the shadow map (M9-6) follows the sun by day and
        // the moon at night — one map, switched light — so nights get faint moon shadows.
        let lightDir = cs.sunDirection(time: gameState.time)
        let moonDir = cs.moonDirection(time: gameState.time)
        let shadowDir = lightDir.y > -0.05 ? lightDir : (moonDir.y > 0.05 ? moonDir : lightDir)
        let lightPos = shadowDir * ws.lightDistance
        // Swap the lookAt up-vector when the light is near-vertical to avoid gimbal collapse.
        let lightUp: SIMD3<Float> = abs(shadowDir.y) > 0.99 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let lightView = float4x4.lookAt(eye: lightPos, target: SIMD3(0,0,0), up: lightUp)
        let r = ws.shadowOrthoRadius
        let lightProj = float4x4.orthographic(left: -r, right: r, bottom: -r, top: r, nearZ: ws.shadowNearZ, farZ: ws.shadowFarZ)
        let lightVP = lightProj * lightView
        // M9-7 eclipse: the nearer moon covers the sun when their directions align. Equal
        // apparent sizes (~1.8° radius each), so ramp across the ~2-radius overlap (cos of it).
        let align = dot(lightDir, moonDir)
        let et = max(0, min(1, (align - 0.9981) / (0.99999 - 0.9981)))
        let eclipse = et * et * (3 - 2 * et)
        ptr.pointee = FrameUniformsSwift(
            viewProjectionMatrix: vp,
            cameraPosition: gameState.cameraPosition(),
            time: gameState.time,
            lightDirection: lightDir,
            inverseViewProjectionMatrix: vp.inverse,
            cameraUp: gameState.cameraUp(),
            lightViewProjectionMatrix: lightVP,
            sunElevation: lightDir.y,
            moonDirection: moonDir,
            moonIntensity: 0.30,
            eclipseFactor: eclipse
        )
    }

    /// M12: place the imported prop each frame — fit to ~0.7 units, stand it up (model Y-up →
    /// tile Z-up), rest its base on the floor, centre it on the plaza-centre tile, and ride the
    /// world spin like any other prop. Rendered flat-coloured for now (texture is M12-C).
    private func updateAssetInstances() {
        assetDrawCmds.removeAll(keepingCapacity: true)
        guard !importedProps.isEmpty || !houseAssembly.isEmpty else { return }
        let cap = assetInstanceBuffers[currentBufferIndex].length / MemoryLayout<InstanceDataSwift>.stride
        let ptr = assetInstanceBuffers[currentBufferIndex].contents().bindMemory(to: InstanceDataSwift.self, capacity: cap)
        let ws = gameState.worldScale
        let n = gameState.cubeModel.size
        let spin = gameState.worldSpinMatrix()
        var inst = 0
        for p in importedProps {
            let dim = p.mesh.size
            let maxDim = max(dim.x, max(dim.y, dim.z))
            let fs: Float = maxDim > 0 ? p.target / maxDim : 1
            let c = p.mesh.center
            // Y-up (OBJ) → tile Z-up needs a +90° X rotation; Z-up (USD) needs none. Fit the widest
            // dimension to `target`, centre the footprint, rest the base on the floor (the base and
            // vertical-centre axes swap with the up-convention), and ride the world spin.
            let orient = p.yUp ? float4x4.rotation(radians: .pi / 2, axis: SIMD3(1, 0, 0)) : matrix_identity_float4x4
            let ty = p.yUp ? c.z * fs : -c.y * fs
            let tz = ws.floorY - (p.yUp ? p.mesh.boundsMin.y : p.mesh.boundsMin.z) * fs
            let model = spin
                * gameState.cubeModel.worldMatrix(face: .positiveZ, row: n / 2 + p.faceOffset.row, col: n / 2 + p.faceOffset.col)
                * float4x4.translation(-c.x * fs, ty, tz)
                * float4x4.scale(fs)
                * orient
            if let diff = p.diffuse {
                guard inst < cap else { break }
                ptr[inst] = InstanceDataSwift(modelMatrix: model, baseColor: SIMD4(1, 1, 1, 1), materialID: 11, tileID: 0, discoveryAmount: 1.0, styleSeed: 0)
                assetDrawCmds.append(AssetDrawCmd(vertexBuffer: p.mesh.vertexBuffer, indexBuffer: p.mesh.indexBuffer, indexOffset: 0, indexCount: p.mesh.totalIndexCount, instanceIndex: inst, diffuse: diff))
                inst += 1
            } else {
                for sm in p.mesh.submeshes {
                    guard inst < cap else { break }
                    ptr[inst] = InstanceDataSwift(modelMatrix: model, baseColor: sm.color, materialID: 10, tileID: 0, discoveryAmount: 1.0, styleSeed: 0)
                    assetDrawCmds.append(AssetDrawCmd(vertexBuffer: p.mesh.vertexBuffer, indexBuffer: p.mesh.indexBuffer, indexOffset: sm.indexOffset, indexCount: sm.indexCount, instanceIndex: inst, diffuse: nil))
                    inst += 1
                }
            }
        }

        // M12-E: imported modular house. Placed via the four `.houseCorner` Prop anchors (not the
        // static faceOffset registry) so each quarter rides its tile's slice rotation — the split
        // mechanic. Mirror SceneBuilder's tile-matrix math (worldMatrix → animMat → spin → sub-cell
        // → facing) exactly so the quarters stay glued to their tiles through a rotation. Scan by
        // (face,row,col): a quarter carried onto a neighbouring face reports its new position here.
        if !houseAssembly.isEmpty {
            let model = gameState.cubeModel
            let sr = gameState.sliceRotation
            let sliceAxis: SIMD3<Float> = sr.axis == 0 ? SIMD3(1,0,0) : sr.axis == 1 ? SIMD3(0,1,0) : SIMD3(0,0,1)
            let sliceT = sr.progress * sr.progress * (3 - 2 * sr.progress)   // smoothstep, matches SceneBuilder
            let sliceMat = float4x4.rotation(radians: sr.angle * sliceT, axis: sliceAxis)
            let step = ws.subCellStep
            for face in CubeFace.allCases {
                for row in 0..<n {
                    for col in 0..<n {
                        guard let (ci, fi) = model.faceletAt(face: face, row: row, col: col) else { continue }
                        for prop in model.cubies[ci].facelets[fi].props where prop.kind == .houseCorner {
                            var tileM = model.worldMatrix(face: face, row: row, col: col)
                            if sr.isActive && sr.affectedCubies.contains(ci) { tileM = sliceMat * tileM }
                            tileM = spin * tileM
                                * float4x4.translation(Float(prop.subCol - 1) * step, Float(prop.subRow - 1) * step, 0)
                                * float4x4.rotation(radians: Float(prop.facing.rawValue) * (.pi / 4), axis: SIMD3(0, 0, 1))
                            // The `.s` quarter is the building's front — it gets the door variant.
                            let assembly = prop.facing == .s ? houseAssemblyDoor : houseAssembly
                            for piece in assembly {
                                let m = tileM * piece.local
                                for sm in piece.mesh.submeshes {
                                    guard inst < cap else { break }
                                    ptr[inst] = InstanceDataSwift(modelMatrix: m, baseColor: sm.color, materialID: 10, tileID: 0, discoveryAmount: 1.0, styleSeed: 0)
                                    assetDrawCmds.append(AssetDrawCmd(vertexBuffer: piece.mesh.vertexBuffer, indexBuffer: piece.mesh.indexBuffer, indexOffset: sm.indexOffset, indexCount: sm.indexCount, instanceIndex: inst, diffuse: nil))
                                    inst += 1
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Tile-local width the imported house occupies per quarter. 1.0 puts the walls on the tile's
    /// outer edges → the four quarters form a full 2×2 room the player can walk inside (M12-E).
    /// `houseWallHeight` is the wall height in tile-Z (the procedural hip roof rests on top of it).
    static let houseQuarterWidth: Float = 1.0
    static let houseWallHeight: Float = 0.30

    /// Normalize a kit module (1×1 Y-up, arbitrary authored size) to the quarter: scale its length
    /// (authored X) to `bw` and its height (authored Y) to `hS`, recentre it on its length/thickness
    /// with the base at 0, then rotate Y-up → tile-Z-up. The result is a piece lying along tile X,
    /// centred at the origin, standing in +Z — ready to slide onto a perimeter edge. Handles the
    /// wall (1.0 wide, 1.0 tall) and the taller/narrower door (0.8 wide, 1.9 tall) uniformly.
    private static func kitBase(_ mesh: AssetMesh, bw: Float, hS: Float) -> float4x4 {
        let s = mesh.size
        let lenScale = s.x > 0 ? bw / s.x : bw
        let htScale  = s.y > 0 ? hS / s.y : hS
        let up = float4x4.rotation(radians: .pi / 2, axis: SIMD3(1, 0, 0))
        let recenter = float4x4.translation(-mesh.center.x, -mesh.boundsMin.y, -mesh.center.z)
        return up * float4x4.scale(lenScale, htScale, lenScale) * recenter
    }

    /// Assemble one imported house quarter (M12-E) in a tile's local frame, authored for `facing.n`.
    /// Each quarter fills its full tile, contributing two of the building's perimeter walls (an L on
    /// the −X/−Y outer edges). The four `.houseCorner` props' facings (n/e/w/s) rotate this into the
    /// four corners, so the L's close a full 2×2 room; the procedural hip roof (TileMeshLibrary) caps
    /// it. The `front` quarter omits its front wall, leaving an open entrance aligned with the plaza
    /// opening. Plain imported walls only — a plain box stretches cleanly to fill the big tile,
    /// unlike the tall window/door modules which squash. No floor slab (the tile already has one).
    private static func buildHouseQuarter(wall: AssetMesh, front: Bool) -> [HouseKitPiece] {
        let floorY: Float = 0.001
        let bw = houseQuarterWidth
        let hS = houseWallHeight
        let c: Float = 0.5      // shared 2×2 centre corner in tile-local (facing.n → +X,+Y)
        let lift = float4x4.translation(0, 0, floorY)
        let rotZ90 = float4x4.rotation(radians: .pi / 2, axis: SIMD3(0, 0, 1))
        // `kitBase` leaves a wall piece centred on tile X (length bw) and Y (thickness), base at Z=0.
        // Slide it onto a perimeter edge: the −Y edge runs along X; the −X edge is rotated to run Y.
        let onMinusY = lift * float4x4.translation(c - bw / 2, c - bw, 0) * kitBase(wall, bw: bw, hS: hS)
        let onMinusX = lift * float4x4.translation(c - bw, c - bw / 2, 0) * rotZ90 * kitBase(wall, bw: bw, hS: hS)
        var pieces = [HouseKitPiece(mesh: wall, local: onMinusX)]   // side wall (always)
        if !front { pieces.append(HouseKitPiece(mesh: wall, local: onMinusY)) }   // front wall, unless this is the entrance
        return pieces
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
        updateAssetInstances()
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
            // M12: imported props cast shadows too (each draw = its own vertex + uint32 range).
            if !assetDrawCmds.isEmpty {
                vertexArgTable.setAddress(assetInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
                for cmd in assetDrawCmds {
                    vertexArgTable.setAddress(cmd.vertexBuffer.gpuAddress, index: BufferIndex.vertices.rawValue)
                    shadowEncoder.drawIndexedPrimitives(
                        primitiveType: .triangle, indexCount: cmd.indexCount, indexType: .uint32,
                        indexBuffer: cmd.indexBuffer.gpuAddress + UInt64(cmd.indexOffset * MemoryLayout<UInt32>.stride),
                        indexBufferLength: cmd.indexBuffer.length - cmd.indexOffset * MemoryLayout<UInt32>.stride,
                        instanceCount: 1, baseVertex: 0, baseInstance: cmd.instanceIndex)
                }
                vertexArgTable.setAddress(tileMeshLib.vertexBuffer.gpuAddress, index: BufferIndex.vertices.rawValue)
                vertexArgTable.setAddress(instanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
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
        // Keep the asset-diffuse slot bound to a valid texture for the maze draws (they don't
        // sample it, but the shader declares it); the prop loop rebinds it per-prop below.
        if let d = importedProps.first?.diffuse { fragmentArgTable.setTexture(d.gpuResourceID, index: TextureIndex.assetDiffuse.rawValue) }
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

        // M12: imported props (each draw = its own vertex + uint32 range + optional texture).
        if !assetDrawCmds.isEmpty {
            vertexArgTable.setAddress(assetInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
            fragmentArgTable.setAddress(assetInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
            for cmd in assetDrawCmds {
                vertexArgTable.setAddress(cmd.vertexBuffer.gpuAddress, index: BufferIndex.vertices.rawValue)
                if let d = cmd.diffuse { fragmentArgTable.setTexture(d.gpuResourceID, index: TextureIndex.assetDiffuse.rawValue) }
                encoder.drawIndexedPrimitives(
                    primitiveType: .triangle, indexCount: cmd.indexCount, indexType: .uint32,
                    indexBuffer: cmd.indexBuffer.gpuAddress + UInt64(cmd.indexOffset * MemoryLayout<UInt32>.stride),
                    indexBufferLength: cmd.indexBuffer.length - cmd.indexOffset * MemoryLayout<UInt32>.stride,
                    instanceCount: 1, baseVertex: 0, baseInstance: cmd.instanceIndex)
            }
            // restore maze buffers for the translucent pass
            vertexArgTable.setAddress(tileMeshLib.vertexBuffer.gpuAddress, index: BufferIndex.vertices.rawValue)
            vertexArgTable.setAddress(instanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
            fragmentArgTable.setAddress(instanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
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

// MARK: - Shader struct bridging
//
// The Swift code uses the C structs from the ShaderTypes.h bridging header directly.
// These aliases keep call sites stable while guaranteeing a single source of layout
// truth: add a field to FrameUniforms / InstanceData / MazeVertex in ShaderTypes.h
// and the Swift side sees it automatically — there is no hand-maintained mirror to
// fall out of sync (which is exactly the skew M9's new uniform fields would risk).

typealias MazeVertexSwift = MazeVertex
typealias FrameUniformsSwift = FrameUniforms
typealias InstanceDataSwift = InstanceData
