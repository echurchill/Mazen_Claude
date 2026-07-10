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

    /// Cube size the app launches with. The N key cycles odd sizes (3→5→7→9) live. This can go as high as 25 but N only cycles from 3 to 9.
    static let initialCubeSize = 9
    /// The moon world's cube size (M11). Used to calibrate its apparent size in the sky.
    static let moonWorldSize = 3

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
    var fadePipelineState: MTLRenderPipelineState   // M11.2b world-transition fade overlay
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
    /// Stamp the imported decorations into the overworld once (lazily, after the registry loads).
    /// They become `.importedAsset` Props on facelets so they ride slice rotations — and, being
    /// stamped only into the overworld, they don't appear in portal-worlds like the test interior.
    private var needsDecorativeStamp = true
    var houseAssembly: [HouseKitPiece] = []       // M12-E: canonical imported house quarter (two walls)
    var houseAssemblyDoor: [HouseKitPiece] = []   // the front quarter — one wall swapped for a door
    var assetInstanceBuffers: [MTLBuffer] = []
    var assetDrawCmds: [AssetDrawCmd] = []
    var opaqueDrawCalls: [DrawCall] = []
    var wallDrawCallRange: Range<Int> = 0..<0
    var translucentDrawCalls: [DrawCall] = []
    // M11 killer visual: the counterpart world (the one you can see in the sky) rendered into its
    // own instance buffers with an orbital offset, when you're standing in a sub-world.
    var counterpartInstanceBuffers: [MTLBuffer] = []
    var counterpartOpaqueDrawCalls: [DrawCall] = []

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

    // M11.2b world-transition fade: swap the active world at the midpoint of a quick fade-to-black.
    private enum TransitionPhase { case none, fadingOut, fadingIn }
    private var transitionPhase: TransitionPhase = .none
    private var transitionT: Float = 0          // 0 clear … 1 fully black
    private var pendingWorldToggle = false
    private let transitionSpeed: Float = 5.5    // ~0.18 s per half (fade out, then fade in)
    var lastFrameTime: CFTimeInterval = 0
    var frameTimeSamples: [Float] = []
    var debugSingleTile = false
    /// Debug: render the maze as flat matte grey (no texture, normal map, or fog) so the raw
    /// geometry — e.g. M14 roundness — is legible. Toggled with `M`.
    var debugPlainShading = false

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

        // Fade pipeline (M11.2b): reuses the sky fullscreen triangle, alpha-blended over the scene.
        let fadeFragDesc = MTL4LibraryFunctionDescriptor()
        fadeFragDesc.library = library
        fadeFragDesc.name = "fadeFragmentShader"
        let fadePipeDesc = MTL4RenderPipelineDescriptor()
        fadePipeDesc.label = "FadePipeline"
        fadePipeDesc.rasterSampleCount = metalKitView.sampleCount
        fadePipeDesc.vertexFunctionDescriptor = skyVertDesc
        fadePipeDesc.fragmentFunctionDescriptor = fadeFragDesc
        fadePipeDesc.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        fadePipeDesc.colorAttachments[0].blendingState = .enabled
        fadePipeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        fadePipeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        fadePipeDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        fadePipeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.fadePipelineState = try! compiler.makeRenderPipelineState(descriptor: fadePipeDesc)

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
        // The moon world exists from the start (persists across visits) so it can hang in earth's
        // sky — and so any tears you make on it stay put (M11 killer visual).
        let moon = GameState(size: Self.moonWorldSize)
        Self.setupInitialDiscovery(gameState: moon)
        self.testInterior = moon

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

        // Per-frame buffers. R2.16: a tile emits SEVERAL instances (frame rail + floor + path-cross
        // + wall + posts; adjacent tiles add dissolve-fog layers; plus props/marker/celestials), so
        // provision a generous per-tile budget — the old 1-per-tile math silently overran beyond
        // ~size 13. SceneBuilder now also hard-guards the write, so any future shortfall is loud.
        let instancesPerTileBudget = 8
        let maxInstances = 6 * WorldScale.maxSupportedSize * WorldScale.maxSupportedSize * instancesPerTileBudget
        let instanceSize = MemoryLayout<InstanceDataSwift>.stride * maxInstances
        let frameSize = MemoryLayout<FrameUniformsSwift>.stride

        var frameBufs: [MTLBuffer] = []
        var instBufs: [MTLBuffer] = []
        var counterpartBufs: [MTLBuffer] = []
        for _ in 0..<maxBuffersInFlight {
            frameBufs.append(device.makeBuffer(length: frameSize, options: .storageModeShared)!)
            instBufs.append(device.makeBuffer(length: instanceSize, options: .storageModeShared)!)
            counterpartBufs.append(device.makeBuffer(length: instanceSize, options: .storageModeShared)!)
        }
        self.frameUniformBuffers = frameBufs
        self.instanceBuffers = instBufs
        self.counterpartInstanceBuffers = counterpartBufs

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
            // loadProp("stone_fire_pit_2k",  "stone_fire_pit_diff_2k",     ( 0,  0), 0.35),  // removed for now (Eddie)
            loadProp("horse_statue_01_2k",    "horse_statue_01_diff_2k",    (-1, -1), 0.60),
            loadProp("tree_stump_01_2k",      "tree_stump_01_diff_2k",      (-1,  1), 0.30),
            loadProp("tree_stump_02_2k",      "tree_stump_02_diff_2k",      ( 1, -1), 0.30),
            // loadProp("old_military_crate_2k", "old_military_crate_diff_2k", ( 1,  1), 0.32),  // removed for now (Eddie)
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
        resDesc.initialCapacity = 9 + frameBufs.count + instBufs.count + counterpartBufs.count + assetBufs.count + loadedProps.count * 3
        let rs = try! device.makeResidencySet(descriptor: resDesc)
        rs.addAllocation(tileMeshLib.vertexBuffer)
        rs.addAllocation(tileMeshLib.indexBuffer)
        if let d = self.diffuseArray { rs.addAllocation(d) }
        if let n = self.normalArray { rs.addAllocation(n) }
        if let s = self.skyboxTexture { rs.addAllocation(s) }
        rs.addAllocation(self.shadowMapTexture)
        for buf in frameBufs { rs.addAllocation(buf) }
        for buf in instBufs { rs.addAllocation(buf) }
        for buf in counterpartBufs { rs.addAllocation(buf) }
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
        needsDecorativeStamp = true   // re-stamp the imported decorations into the fresh overworld
    }

    /// M14b debug: dial shape roundness on **every** world — the active stack *and* the persistent
    /// moon (the counterpart that hangs in the sky) — so the whole cluster inflates together and you
    /// can see the round moon over the round Earth. (Per-world authored roundness comes later.)
    func adjustRoundness(_ delta: Float) {
        let apply: (GameState) -> Void = {
            $0.cubeModel.roundness = max(0, min(1, $0.cubeModel.roundness + delta))
        }
        worldStack.forEach(apply)
        if let moon = testInterior { apply(moon) }
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
        // Stop the departing world walking, so neither world auto-continues across the switch —
        // with walk-through portals, an un-cleared "forward held" would ping-pong through gates.
        gameState.forwardHeld = false; gameState.backwardHeld = false
        if worldStack.count > 1 {
            exitWorld()
        } else if let moon = testInterior {
            enterWorld(moon)   // the moon persists (created at startup), so its tears stay put
        }
        // …and the arriving world starts stationary (a fresh key press resumes walking).
        gameState.forwardHeld = false; gameState.backwardHeld = false
    }

    /// Begin a fade-to-black, swap the world at the midpoint, then fade back (M11.2b). Ignored if a
    /// transition is already running. Both the portal (F) and the debug O key route through here.
    func beginWorldTransition() {
        guard transitionPhase == .none else { return }
        transitionPhase = .fadingOut
        transitionT = 0
        pendingWorldToggle = true
    }

    /// Advance the fade each frame; performs the queued world swap at the fully-black midpoint.
    private func updateTransition(dt: Float) {
        switch transitionPhase {
        case .none: break
        case .fadingOut:
            transitionT += dt * transitionSpeed
            if transitionT >= 1 {
                transitionT = 1
                if pendingWorldToggle { toggleTestInterior(); pendingWorldToggle = false }
                transitionPhase = .fadingIn
            }
        case .fadingIn:
            transitionT -= dt * transitionSpeed
            if transitionT <= 0 { transitionT = 0; transitionPhase = .none }
        }
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
        // M11 killer visual — the counterpart world shown hanging in the sky: from earth you see the
        // MOON, and from inside a sub-world you see the world beneath it. It persists, so tears made
        // on it stay. When one is shown, suppress the active world's plain M9 moon (no double moon).
        let counterpart: GameState? = debugSingleTile ? nil
            : (worldStack.count > 1 ? worldStack[worldStack.count - 2] : testInterior)
        let result = debugSingleTile
            ? sceneBuilder.buildSingleTile(tileMeshLib: tileMeshLib, instanceBuffer: buffer)
            : sceneBuilder.build(gameState: gameState, tileMeshLib: tileMeshLib, instanceBuffer: buffer,
                                 includeMoon: counterpart == nil)
        opaqueDrawCalls = result.opaque
        translucentDrawCalls = result.translucent
        wallDrawCallRange = result.wallRange

        // Render the counterpart's real current state (every twist baked in) into its own instance
        // buffer, pushed out by the orbital offset. No celestials (it shouldn't carry its own sky).
        counterpartOpaqueDrawCalls = []
        if let cp = counterpart {
            let cbuf = counterpartInstanceBuffers[currentBufferIndex]
            let offset = Self.skyWorldOffset(cs: gameState.celestialSystem, time: gameState.time)
            let cresult = sceneBuilder.build(gameState: cp, tileMeshLib: tileMeshLib,
                                             instanceBuffer: cbuf, worldOffset: offset, includeCelestials: false)
            counterpartOpaqueDrawCalls = cresult.opaque
        }
    }

    /// Where the counterpart world hangs in the sky (M11): at the **moon's natural orbital position
    /// and apparent size** — it *is* the moon, in its real place in the sky (rising and setting with
    /// the day). Scale is calibrated so the 3³ moon matches the M9 moon's disc, and a larger world
    /// (earth, seen from the moon) reads proportionally bigger. A gentle spin turns it so every side
    /// comes into view; the world's *state* stays frozen. (Earlier this used an artificially-close
    /// distance to make the maze / torn house legible while verifying — now reset to natural.)
    private static func skyWorldOffset(cs: CelestialSystem, time: Float) -> float4x4 {
        let pos = cs.moonPosition(time: time)                  // the moon's real orbital position
        let scale = cs.moonSize / (Float(moonWorldSize) / 2)   // 3³ moon → the M9 moon's apparent size
        let spin = float4x4.rotation(radians: time * 0.06, axis: SIMD3(0, 1, 0))
        return float4x4.translation(pos.x, pos.y, pos.z) * spin * float4x4.scale(scale)
    }

    private func updateFrameUniforms() {
        let buf = frameUniformBuffers[currentBufferIndex]
        let ptr = buf.contents().bindMemory(to: FrameUniformsSwift.self, capacity: 1)
        let ws = gameState.worldScale
        let framePose = gameState.framePose(aspect: aspect)   // one camera-pose evaluation (R2.4)
        let vp = framePose.viewProjection
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
        // R2.11: size-derived fog. First-person keeps the historical values exactly (the fog is a
        // depth cue on far tiles there). In orbit the fog now begins BEYOND the cube's far corner
        // (camera distance + √3·halfN), so the planet always reads with clean, unfogged textures —
        // the old fixed 4→14 range was tuned for the size-5 world and silver-veiled everything at
        // size 7+.
        let isOrbit = gameState.camera.mode == .orbit
        let halfDiagonal = 1.7320508 * ws.faceDistance
        let camDist = simd_length(framePose.position)
        let fogNear: Float = isOrbit ? camDist + halfDiagonal : 1.0
        let fogFar: Float = isOrbit ? camDist + halfDiagonal + 2.0 * Float(gameState.cubeModel.size) : 3.5
        // Everything local lies within camDist + halfDiagonal of the camera (the far corner of the
        // active world); beyond that is SKY — the counterpart world hanging up there — which sits
        // outside the local atmosphere and must not take fog (from FP it was reading as a silver
        // blob: the 1→3.5 depth-cue fog saturates long before its ~50-unit distance). +1 margin
        // covers wall height / top arcs poking past the corner radius.
        let skyDistance: Float = camDist + halfDiagonal + 1.0
        ptr.pointee = FrameUniformsSwift(
            viewProjectionMatrix: vp,
            cameraPosition: framePose.position,
            time: gameState.time,
            lightDirection: lightDir,
            inverseViewProjectionMatrix: vp.inverse,
            cameraUp: framePose.up,
            lightViewProjectionMatrix: lightVP,
            sunElevation: lightDir.y,
            moonDirection: moonDir,
            moonIntensity: 0.30,
            eclipseFactor: eclipse,
            fadeAmount: transitionPhase == .none ? 0 : transitionT,
            plainShading: debugPlainShading ? 1 : 0,
            fogNear: fogNear,
            fogFar: fogFar,
            orbitBlend: isOrbit ? 1 : 0,
            skyDistance: skyDistance
        )
    }

    /// Stamp the imported decorations into a world as `.importedAsset` Props (one per registry entry,
    /// at its `faceOffset` tile on +Z, `state` = registry index). As Props on facelets they now ride
    /// slice rotations and get carried like any other prop — instead of the old static placement.
    private func stampImportedProps(into gs: GameState) {
        let n = gs.cubeModel.size
        for (assetID, p) in importedProps.enumerated() {
            let row = n / 2 + p.faceOffset.row
            let col = n / 2 + p.faceOffset.col
            if let (ci, fi) = gs.cubeModel.faceletAt(face: .positiveZ, row: row, col: col) {
                gs.cubeModel.cubies[ci].facelets[fi].props.append(
                    Prop(kind: .importedAsset, subRow: 1, subCol: 1, facing: .n, state: assetID))
            }
        }
    }

    /// Place every imported prop for the frame. Both the decorations (`.importedAsset`, single mesh
    /// from the registry) and the modular house (`.houseCorner`, kit assembly) are now anchored to
    /// facelets and scanned here, so they ride the slice `animMat` (worldMatrix → animMat → spin →
    /// sub-cell → facing) and are carried by `Prop.rotate` — the arena decorations turn with their
    /// slice exactly like the house. Scans by (face,row,col) so a prop carried to a neighbouring
    /// face reports its new position.
    private func updateAssetInstances() {
        assetDrawCmds.removeAll(keepingCapacity: true)
        // Lazily stamp the decorations into the overworld (bottom of the stack) once the registry is
        // loaded — overworld only, so portal-worlds (the test interior) stay clear of them.
        if needsDecorativeStamp, let overworld = worldStack.first {
            stampImportedProps(into: overworld)
            needsDecorativeStamp = false
        }
        guard !importedProps.isEmpty || !houseAssembly.isEmpty else { return }
        let cap = assetInstanceBuffers[currentBufferIndex].length / MemoryLayout<InstanceDataSwift>.stride
        let ptr = assetInstanceBuffers[currentBufferIndex].contents().bindMemory(to: InstanceDataSwift.self, capacity: cap)
        let ws = gameState.worldScale
        let n = gameState.cubeModel.size
        let spin = gameState.worldSpinMatrix()
        let model = gameState.cubeModel
        let sr = gameState.sliceRotation
        let sliceMat = sr.currentMatrix   // single source: SliceRotation (R2.3)
        let step = ws.subCellStep
        var inst = 0

        // Emit one flat-colour sub-mesh or a whole textured mesh at `m`.
        func emit(_ mesh: AssetMesh, _ m: float4x4, diffuse: MTLTexture?) {
            if let diff = diffuse {
                guard inst < cap else { return }
                ptr[inst] = InstanceDataSwift(modelMatrix: m, baseColor: SIMD4(1,1,1,1), materialID: 11, tileID: 0, discoveryAmount: 1.0, styleSeed: 0)
                assetDrawCmds.append(AssetDrawCmd(vertexBuffer: mesh.vertexBuffer, indexBuffer: mesh.indexBuffer, indexOffset: 0, indexCount: mesh.totalIndexCount, instanceIndex: inst, diffuse: diff))
                inst += 1
            } else {
                for sm in mesh.submeshes {
                    guard inst < cap else { return }
                    ptr[inst] = InstanceDataSwift(modelMatrix: m, baseColor: sm.color, materialID: 10, tileID: 0, discoveryAmount: 1.0, styleSeed: 0)
                    assetDrawCmds.append(AssetDrawCmd(vertexBuffer: mesh.vertexBuffer, indexBuffer: mesh.indexBuffer, indexOffset: sm.indexOffset, indexCount: sm.indexCount, instanceIndex: inst, diffuse: nil))
                    inst += 1
                }
            }
        }

        for face in CubeFace.allCases {
            for row in 0..<n {
                for col in 0..<n {
                    guard let (ci, fi) = model.faceletAt(face: face, row: row, col: col) else { continue }
                    let props = model.cubies[ci].facelets[fi].props
                    if props.isEmpty { continue }
                    // M14b: seat each rigid asset at the inflated sub-cell footprint, tilted to the
                    // local surface normal (roundness==0 → flat, exactly as before). Then facing +
                    // slice animation + spin. The asset stays rigid (its instance roundness stays 0);
                    // only its anchor rides the curve, so it no longer pokes through / floats.
                    for prop in props {
                        let localX = Float(prop.subCol - 1) * step
                        let localY = Float(prop.subRow - 1) * step
                        var placement = model.inflatedPlacement(face: face, row: row, col: col, localX: localX, localY: localY)
                        if sr.isActive && sr.affectedCubies.contains(ci) { placement = sliceMat * placement }
                        let tileM = spin * placement
                            * float4x4.rotation(radians: Float(prop.facing.rawValue) * (.pi / 4), axis: SIMD3(0, 0, 1))
                        switch prop.kind {
                        case .importedAsset:
                            guard prop.state >= 0 && prop.state < importedProps.count else { continue }
                            let p = importedProps[prop.state]
                            // Fit the widest dimension to `target`, stand it up (Y-up OBJ → tile Z-up),
                            // centre the footprint, rest the base on the floor.
                            let dim = p.mesh.size
                            let maxDim = max(dim.x, max(dim.y, dim.z))
                            let fs: Float = maxDim > 0 ? p.target / maxDim : 1
                            let c = p.mesh.center
                            let orient = p.yUp ? float4x4.rotation(radians: .pi / 2, axis: SIMD3(1, 0, 0)) : matrix_identity_float4x4
                            let ty = p.yUp ? c.z * fs : -c.y * fs
                            let tz = ws.floorY - (p.yUp ? p.mesh.boundsMin.y : p.mesh.boundsMin.z) * fs
                            let m = tileM * float4x4.translation(-c.x * fs, ty, tz) * float4x4.scale(fs) * orient
                            emit(p.mesh, m, diffuse: p.diffuse)
                        case .houseCorner:
                            let assembly = prop.facing == .s ? houseAssemblyDoor : houseAssembly
                            for piece in assembly { emit(piece.mesh, tileM * piece.local, diffuse: nil) }
                        default:
                            break
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

        // M11.2: a portal interaction switches worlds — through a fade (M11.2b). Clear the flag on
        // the requesting world and start the transition; the swap happens at the fully-black midpoint.
        if gameState.portalRequested {
            gameState.portalRequested = false
            beginWorldTransition()
        }
        updateTransition(dt: dt)

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
                    indexType: .uint32,
                    indexBuffer: idxBase + UInt64(dc.indexOffset * MemoryLayout<UInt32>.stride),
                    indexBufferLength: idxLen - dc.indexOffset * MemoryLayout<UInt32>.stride,
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
                indexType: .uint32,
                indexBuffer: idxBufBase + UInt64(dc.indexOffset * MemoryLayout<UInt32>.stride),
                indexBufferLength: idxBufLen - dc.indexOffset * MemoryLayout<UInt32>.stride,
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

        // M11 killer visual: the counterpart world hanging in the sky. Same maze meshes, its own
        // instance buffer (built with the orbital offset). Still in the opaque pass (depth on), so it
        // sits correctly behind near geometry and in front of the sky.
        if !counterpartOpaqueDrawCalls.isEmpty {
            vertexArgTable.setAddress(counterpartInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
            fragmentArgTable.setAddress(counterpartInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
            for dc in counterpartOpaqueDrawCalls {
                encoder.drawIndexedPrimitives(
                    primitiveType: .triangle,
                    indexCount: dc.indexCount,
                    indexType: .uint32,
                    indexBuffer: idxBufBase + UInt64(dc.indexOffset * MemoryLayout<UInt32>.stride),
                    indexBufferLength: idxBufLen - dc.indexOffset * MemoryLayout<UInt32>.stride,
                    instanceCount: dc.instanceCount,
                    baseVertex: 0,
                    baseInstance: dc.instanceOffset
                )
            }
            vertexArgTable.setAddress(instanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
            fragmentArgTable.setAddress(instanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
        }

        // Pass 2: translucent overlays (depth write OFF)
        encoder.setDepthStencilState(depthStateNoWrite)
        for dc in translucentDrawCalls {
            encoder.drawIndexedPrimitives(
                primitiveType: .triangle,
                indexCount: dc.indexCount,
                indexType: .uint32,
                indexBuffer: idxBufBase + UInt64(dc.indexOffset * MemoryLayout<UInt32>.stride),
                indexBufferLength: idxBufLen - dc.indexOffset * MemoryLayout<UInt32>.stride,
                instanceCount: dc.instanceCount,
                baseVertex: 0,
                baseInstance: dc.instanceOffset
            )
        }

        // M11.2b: world-transition fade — a fullscreen black quad blended over everything, alpha
        // from frame.fadeAmount (0 except during a portal swap). Fullscreen triangle, no depth.
        if transitionPhase != .none {
            encoder.setRenderPipelineState(fadePipelineState)
            encoder.setDepthStencilState(depthStateAlways)
            encoder.setCullMode(.none)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
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

extension InstanceData {
    /// Convenience init that defaults the M14b inflation fields to "flat/rigid" (spin baked into
    /// modelMatrix by the caller, as before). Existing call sites keep their original 6 arguments;
    /// only the per-vertex-inflated maze surface passes `spinMatrix`/`roundness`/`invHalfExtent`.
    init(modelMatrix: matrix_float4x4, baseColor: SIMD4<Float>, materialID: UInt32,
         tileID: UInt32, discoveryAmount: Float, styleSeed: UInt32,
         spinMatrix: matrix_float4x4 = matrix_identity_float4x4,
         roundness: Float = 0, invHalfExtent: Float = 0) {
        self.init()
        self.modelMatrix = modelMatrix
        self.baseColor = baseColor
        self.materialID = materialID
        self.tileID = tileID
        self.discoveryAmount = discoveryAmount
        self.styleSeed = styleSeed
        self.spinMatrix = spinMatrix
        self.roundness = roundness
        self.invHalfExtent = invHalfExtent
    }
}
