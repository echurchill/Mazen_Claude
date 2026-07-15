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

// (R2.8: ImportedProp / HouseKitPiece + all asset loading live in AssetRegistry.swift; texture
// decoding in TextureLoader.swift; pipeline/state construction in PipelineFactory.swift. Renderer
// keeps the frame loop, the world stack, and per-frame instance building.)

/// One prepared asset draw for the frame (a whole textured mesh, or one flat-colour sub-mesh).
struct AssetDrawCmd {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexOffset: Int        // element offset
    let indexCount: Int
    let instanceIndex: Int
    let diffuse: MTLTexture?
    var cutout: Bool = false    // diffuse is a cut-out ⇒ alpha-test it in the shadow pass too
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

    /// Attachment textures already registered in the residency set. MTKView owns the drawable
    /// pool / MSAA / depth textures (we never create them), so Metal 4's explicit-residency rule
    /// was being violated every frame ("attachment … not added to any residency set" under API
    /// validation — technically UB). They're registered lazily on first appearance; the pool is
    /// tiny (~3 drawables + MSAA + depth) and only grows on resize.
    private var residentAttachments = Set<ObjectIdentifier>()

    private func ensureAttachmentsResident(_ desc: MTL4RenderPassDescriptor) {
        var added = false
        func ensure(_ tex: MTLTexture?) {
            guard let tex else { return }
            let id = ObjectIdentifier(tex as AnyObject)
            guard !residentAttachments.contains(id) else { return }
            residencySet.addAllocation(tex)
            residentAttachments.insert(id)
            added = true
        }
        ensure(desc.colorAttachments[0].texture)
        ensure(desc.colorAttachments[0].resolveTexture)
        ensure(desc.depthAttachment.texture)
        ensure(desc.stencilAttachment.texture)
        if added { residencySet.commit() }
    }
#endif

    let endFrameEvent: MTLSharedEvent
    var frameIndex = 0

    var pipelineState: MTLRenderPipelineState
    var skyPipelineState: MTLRenderPipelineState
    var fadePipelineState: MTLRenderPipelineState   // M11.2b world-transition fade overlay
    var shadowPipelineState: MTLRenderPipelineState
    var shadowCutoutPipelineState: MTLRenderPipelineState   // M20: alpha-tested shadows for foliage
    var depthState: MTLDepthStencilState
    var depthStateNoWrite: MTLDepthStencilState
    var depthStateAlways: MTLDepthStencilState

    var tileMeshLib: TileMeshLibrary
    var diffuseArray: MTLTexture!
    var leafArray: MTLTexture?     // M20: leaf-atlas array (a slice per LeafSet), nil ⇒ procedural foliage fallback
    /// The LeafSets composed into `leafArray` (order = slice index). SceneBuilder picks a slice
    /// per bush via `styleSeed % leafSetCount`, so bushes vary.
    static let leafSets = ["LeafSet004", "LeafSet010", "LeafSet014", "LeafSet017",
                           "LeafSet022", "LeafSet023", "LeafSet024", "LeafSet030"]
    var greeneryArray: MTLTexture?   // M20: misc_greenery card array (RGBA); slice per plant
    var treeSpriteArray: MTLTexture? // M20: WenrexaTrees billboard-sprite array (RGBA); slice per tree
    /// A 1×1 `type2DArray` placeholder bound to the leaf/greenery/tree-sprite slots when their real
    /// array is nil. The fragment shader declares those textures unconditionally, so Metal API
    /// Validation (Xcode's Run) aborts the first draw if a declared slot is never set — even though
    /// the `*Loaded` flags mean it is never sampled. This keeps every declared slot legally bound.
    var placeholderArray: MTLTexture!
    /// misc_greenery card filenames (order = slice index; also the HUD name).
    static let greenerySets = [
        "vegetation_clover_02", "vegetation_daffodil_01", "vegetation_daisie_05", "vegetation_fern_01",
        "vegetation_fern_08", "vegetation_grass_card_03", "vegetation_leaf_dandelion_03", "vegetation_leaf_dry_01",
        "vegetation_leaf_maple_01", "vegetation_smallplant_03", "vegetation_smallplant_21", "vegetation_strawberry_01",
        "vegetation_strawberry_03", "vegetation_strawberry_04", "vegetation_sunflower_03", "vegetation_tree_branch_10",
        "vegetation_tree_branch_14", "vegetation_tree_branch_16b", "vegetation_tree_branch_17", "vegetation_tree_branch_25",
        "vegetation_tree_branch_30", "vegetation_tree_seed_01"]
    /// WenrexaTrees sprite filenames "01".."27" (order = slice index).
    static let treeSprites = (1...27).map { String(format: "%02d", $0) }
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
    /// Invariant (why `last!` is safe): the stack is created with the overworld in init and
    /// `exitWorld`/`resetGame` never leave it empty — the overworld is never popped.
    var gameState: GameState { worldStack.last! }
    /// The universe (M15.0 world graph): every world reachable by route, keyed
    /// `(destination, origin)`, lazily created, persistent — scars keep. The stack above is the
    /// navigation *history*; this is the *universe*. Sky/counterpart lookups resolve through it.
    let worldRegistry = WorldRegistry()
    /// M17 Phase 0 — the player's cross-world knowledge (memories, glyphs, attunement). Held here,
    /// outside the world stack, so it persists across every portal. Inert until a beat uses it.
    let playerKnowledge = PlayerKnowledge()

    // M11.2b world-transition fade: swap the active world at the midpoint of a quick fade-to-black.
    private enum TransitionPhase { case none, fadingOut, fadingIn }
    private var transitionPhase: TransitionPhase = .none
    private var transitionT: Float = 0          // 0 clear … 1 fully black
    private var pendingPortalDestination: Int?  // destination id queued for the fade midpoint (M15.2)
    private let transitionSpeed: Float = 5.5    // ~0.18 s per half (fade out, then fade in)

    /// What a portal Prop's `state` means (M15.2): an index into this table. From inside any
    /// sub-world a portal simply pops back out; the destination only matters from the root.
    static let portalDestinations = ["moon", "temple-interior", "natural", "garden", "gallery"]
    var lastFrameTime: CFTimeInterval = 0
    var frameTimeSamples: [Float] = []
    var debugSingleTile = false
    /// Debug: render the maze as flat matte grey (no texture, normal map, or fog) so the raw
    /// geometry — e.g. M14 roundness — is legible. Toggled with `M`.
    var debugPlainShading = false
    /// Debug (Shift+T): pin the sun directly overhead the player's current surface point every
    /// frame — perpetual local noon, wherever the player stands. Even top light for evaluating
    /// assets. Exterior worlds only (interiors have their own lantern).
    var sunNoonLock = false

    /// The overhead (local-up) direction over the player in rendered/world space, when noon-lock is
    /// on — the spun surface normal at the player's tile. `nil` when off / interior (normal sun).
    private func noonSunDirection() -> SIMD3<Float>? {
        guard sunNoonLock, !gameState.worldScale.interior else { return nil }
        let p = gameState.player
        let m = gameState.cubeModel.inflatedPlacement(face: p.face, row: p.row, col: p.col, localX: 0, localY: 0)
        let n = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let s = gameState.worldSpinMatrix() * SIMD4<Float>(n.x, n.y, n.z, 0)
        return simd_normalize(SIMD3<Float>(s.x, s.y, s.z))
    }

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
        argDesc.maxTextureBindCount = 8   // +6 greenery +7 tree-sprite arrays (M20)
        argDesc.maxSamplerStateBindCount = 1
        self.fragmentArgTable = try! device.makeArgumentTable(descriptor: argDesc)

        self.endFrameEvent = device.makeSharedEvent()!
        self.frameIndex = maxBuffersInFlight
        self.endFrameEvent.signaledValue = UInt64(frameIndex - 1)

        metalKitView.depthStencilPixelFormat = .depth32Float_stencil8
        metalKitView.colorPixelFormat = .bgra8Unorm_srgb
        metalKitView.sampleCount = 4
        metalKitView.clearColor = MTLClearColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1.0)

        // Pipelines / depth states / shadow map / sampler — one-time construction (PipelineFactory, R2.8)
        let library = device.makeDefaultLibrary()!
        let compiler = try! device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let sampleCount = metalKitView.sampleCount
        let colorFormat = metalKitView.colorPixelFormat
        self.pipelineState = PipelineFactory.makeMazePipeline(compiler: compiler, library: library,
                                                              sampleCount: sampleCount, colorFormat: colorFormat)
        self.skyPipelineState = PipelineFactory.makeSkyPipeline(compiler: compiler, library: library,
                                                                sampleCount: sampleCount, colorFormat: colorFormat)
        self.fadePipelineState = PipelineFactory.makeFadePipeline(compiler: compiler, library: library,
                                                                  sampleCount: sampleCount, colorFormat: colorFormat)
        self.shadowPipelineState = PipelineFactory.makeShadowPipeline(compiler: compiler, library: library)
        self.shadowCutoutPipelineState = PipelineFactory.makeShadowCutoutPipeline(compiler: compiler, library: library)
        self.shadowMapTexture = PipelineFactory.makeShadowMap(device: device)
        let depthStates = PipelineFactory.makeDepthStates(device: device)
        self.depthState = depthStates.write
        self.depthStateNoWrite = depthStates.noWrite
        self.depthStateAlways = depthStates.always

        // Game state (owns the per-world scale) — mark some tiles discovered for visual testing.
        // The overworld is the bottom of the world stack (M11.1). Use a local here: the computed
        // `gameState` getter can't be called before super.init().
        let overworld = GameState(size: Self.initialCubeSize, name: "earth")
        Self.setupInitialDiscovery(gameState: overworld)
        self.worldStack = [overworld]
        // The moon world exists from the start (persists across visits) so it can hang in earth's
        // sky — and so any tears you make on it stay put (M11 killer visual). Registered on the
        // identity-bound edge moon-earth (M15.0): the moon you see IS the moon you can visit.
        let moon = GameState(size: Self.moonWorldSize, name: "moon", stamp: .lunar)  // M19: grey regolith moon
        Self.setupInitialDiscovery(gameState: moon)
        worldRegistry.bind(WorldKey(destination: "moon", origin: "earth"), to: moon)

        // Tile mesh library (geometry baked from the world scale)
        self.tileMeshLib = TileMeshLibrary(device: device, worldScale: overworld.worldScale)

        // Textures
        self.diffuseArray = TextureLoader.loadTextureArray(device: device,
            names: ["hedge_diff", "gravel_diff", "stone_diff"], srgb: true)
        self.normalArray = TextureLoader.loadTextureArray(device: device,
            names: ["hedge_nor", "gravel_nor", "stone_nor"], srgb: false)
        self.skyboxTexture = TextureLoader.loadTexture2D(device: device, name: "skybox", srgb: true)
        // M20: the alpha-cutout leaf array — one downsampled slice per ambientCG LeafSet (Color +
        // Opacity composed to RGBA), so bushes vary. Dev absolute paths; bundle for shipping later.
        let modelsRoot = "/Volumes/Code Work/xCode work/Mazen_Claude/Mazen_Models"
        // LeafSets + misc_greenery asset folders were removed (Eddie) — leave these arrays nil so the
        // foliage materials fall back gracefully. Repoint here if new card assets land.
        self.leafArray = nil
        self.greeneryArray = nil
        self.treeSpriteArray = TextureLoader.loadRGBAArray(device: device,
            urls: Renderer.treeSprites.map { URL(fileURLWithPath: "\(modelsRoot)/WenrexaTrees/\($0).png") },
            size: 384, centerOnTrunk: true)
        self.texSampler = PipelineFactory.makeSampler(device: device)
        // A 1×1 array-texture placeholder for the unconditionally-declared foliage slots (see the
        // `placeholderArray` doc comment). Never sampled — just keeps the binding legal.
        let phDesc = MTLTextureDescriptor()
        phDesc.textureType = .type2DArray
        phDesc.pixelFormat = .rgba8Unorm_srgb
        phDesc.width = 1; phDesc.height = 1; phDesc.arrayLength = 1
        phDesc.storageMode = .shared; phDesc.usage = .shaderRead
        self.placeholderArray = device.makeTexture(descriptor: phDesc)
        self.placeholderArray.label = "FoliagePlaceholder"
        self.placeholderArray.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                                        size: MTLSize(width: 1, height: 1, depth: 1)),
                                      mipmapLevel: 0, slice: 0,
                                      withBytes: [UInt8](repeating: 0, count: 4), bytesPerRow: 4, bytesPerImage: 4)

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

        // M12: the imported assets — decoration props + the modular house kit (AssetRegistry, R2.8).
        let assets = AssetRegistry.loadAll(device: device)
        self.importedProps = assets.props
        let loadedProps = assets.props

        self.houseAssembly = assets.house
        self.houseAssemblyDoor = assets.houseDoor

        var assetBufs: [MTLBuffer] = []
        for _ in 0..<maxBuffersInFlight {
            assetBufs.append(device.makeBuffer(length: MemoryLayout<InstanceDataSwift>.stride * 512, options: .storageModeShared)!)
        }
        self.assetInstanceBuffers = assetBufs

        // Residency set
        let resDesc = MTLResidencySetDescriptor()
        resDesc.initialCapacity = 9 + frameBufs.count + instBufs.count + counterpartBufs.count + assetBufs.count
            + loadedProps.count * 3 + loadedProps.reduce(0) { $0 + $1.submeshMaterials.count }
        let rs = try! device.makeResidencySet(descriptor: resDesc)
        rs.addAllocation(tileMeshLib.vertexBuffer)
        rs.addAllocation(tileMeshLib.indexBuffer)
        if let d = self.diffuseArray { rs.addAllocation(d) }
        if let n = self.normalArray { rs.addAllocation(n) }
        if let s = self.skyboxTexture { rs.addAllocation(s) }
        if let lf = self.leafArray { rs.addAllocation(lf) }
        if let g = self.greeneryArray { rs.addAllocation(g) }
        if let t = self.treeSpriteArray { rs.addAllocation(t) }
        rs.addAllocation(self.placeholderArray)
        rs.addAllocation(self.shadowMapTexture)
        for buf in frameBufs { rs.addAllocation(buf) }
        for buf in instBufs { rs.addAllocation(buf) }
        for buf in counterpartBufs { rs.addAllocation(buf) }
        for p in loadedProps {
            rs.addAllocation(p.mesh.vertexBuffer); rs.addAllocation(p.mesh.indexBuffer)
            if let d = p.diffuse { rs.addAllocation(d) }
            for m in p.submeshMaterials { if let t = m.diffuse { rs.addAllocation(t) } }   // per-sub-mesh maps
        }
        for buf in assetBufs { rs.addAllocation(buf) }
        rs.commit()
        commandQueue.addResidencySet(rs)
        self.residencySet = rs

        super.init()
#endif
    }

    func resetGame(size: Int) {
        // Collapse to a single fresh overworld (drops any pushed portal-worlds). It keeps the
        // "earth" identity, so its sky edges (moon-earth) keep resolving; registry worlds persist.
        worldStack = [GameState(size: size, name: "earth")]
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
        // Whole universe, each distinct world exactly once (a world can be on the stack AND in
        // the registry — e.g. standing on the moon — and must not be double-stepped). Interior
        // worlds stay flat (roundness 0): they're engineered, and the inflation math is
        // exterior-only (M15.1).
        var seen = Set<ObjectIdentifier>()
        for w in worldStack + worldRegistry.allWorlds
        where !w.worldScale.interior && seen.insert(ObjectIdentifier(w)).inserted {
            apply(w)
        }
    }

    /// M19 debug: dial relief (hill amplitude) on the ACTIVE world only, so you can tune the
    /// world you're standing in (`,` down / `.` up). CPU + GPU read the same `reliefAmplitude`,
    /// so the camera stays on the ground as it changes.
    func adjustRelief(_ delta: Float) {
        let m = gameState.cubeModel
        m.reliefAmplitude = max(0, min(0.2, m.reliefAmplitude + delta))
    }

    // (M15.2: the old direct-swap interior debug hop is gone — the I key now routes through
    // beginWorldTransition(destinationID: 1), same as walking through the temple portal.)

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

    /// Perform the world swap (at the fade midpoint): inside any sub-world, pop back out;
    /// from the root, enter the destination — resolved by route through the registry (M15.2),
    /// created on first visit, persistent forever after.
    private func performPortalSwap(destinationID: Int) {
        // Stop the departing world walking, so neither world auto-continues across the switch —
        // with walk-through portals, an un-cleared "forward held" would ping-pong through gates.
        gameState.forwardHeld = false; gameState.backwardHeld = false
        let departingMode = gameState.camera.mode   // FPV stays FPV across worlds (Eddie, M15.2)
        let pushed: Bool
        if worldStack.count > 1 {
            exitWorld()
            pushed = false
        } else {
            let dest = Self.portalDestinations.indices.contains(destinationID)
                ? Self.portalDestinations[destinationID] : "moon"
            let key = WorldKey(destination: dest, origin: gameState.name)
            let world = worldRegistry.world(for: key) {
                // First visit — build the destination. (The moon is pre-bound at init, so its
                // create only runs as a fallback for an unexpected origin.)
                let w: GameState
                switch dest {
                case "temple-interior":
                    w = GameState(size: 5, name: dest, interior: true, stamp: .templeInterior)
                case "natural":
                    // M18 Phase 1 open-field testbed (T key) — size 7 gives a real horizon walk.
                    w = GameState(size: 7, name: dest, stamp: .natural)
                case "garden":
                    // M20 — the entry world: size 25 so the local surface reads flat (little
                    // apparent curvature), with the natural-maze confined to a sealed entry region
                    // (Eddie). The stamp reveals ONLY that region, so DON'T reveal-all here.
                    w = GameState(size: 25, name: dest, stamp: .gardenMaze)
                case "gallery":
                    // M20 dev tool — flat prop/foliage grid (Y key). Size 25 to fit the full catalog
                    // (props + tree sprites). Stamp partial-reveals.
                    w = GameState(size: 25, name: dest, stamp: .gallery)
                    // Append the imported 3D models (Quaternius proof) as their own eval strip — the
                    // Renderer owns the registry indices, so it stamps them after the world is built.
                    let importStates = importedProps.enumerated().filter { $0.element.galleryOnly }.map { $0.offset }
                    w.cubeModel.stampGalleryImports(importStates)
                default:
                    w = GameState(size: Self.moonWorldSize, name: dest, stamp: .lunar)  // M19: grey regolith moon
                }
                if dest != "garden" && dest != "gallery" { Self.setupInitialDiscovery(gameState: w) }
                return w
            }
            enterWorld(world)
            pushed = true
        }

        // Arrival = stepping OUT of a door (Eddie, M15.2): same camera mode as you left in, and
        // you emerge looking the portal's exit direction — the door at your back.
        let arriving = gameState
        arriving.camera.mode = departingMode
        arriving.camera.lookYaw = 0
        arriving.camera.lookPitch = 0
        arriving.player.isMoving = false
        arriving.player.isTurning = false
        if pushed {
            // Emerge FROM the destination's own doorway, wherever it stands.
            if let door = arriving.cubeModel.firstPortalLocation() {
                arriving.player.face = door.face
                arriving.player.row = door.row
                arriving.player.col = door.col
                arriving.player.subRow = arriving.player.standCenter
                arriving.player.subCol = arriving.player.standCenter
                arriving.player.facing = door.exitFacing
            }
        } else {
            // Popping home: you're standing on the door you left through — turn to its exit side.
            if let (ci, fi) = arriving.cubeModel.faceletAt(face: arriving.player.face,
                                                           row: arriving.player.row, col: arriving.player.col),
               let portal = arriving.cubeModel.cubies[ci].facelets[fi].props.first(where: { $0.kind == .portal }) {
                arriving.player.facing = portal.facing
            }
        }
        // …and the arriving world starts stationary (a fresh key press resumes walking).
        gameState.forwardHeld = false; gameState.backwardHeld = false
    }

    /// Begin a fade-to-black, swap the world at the midpoint, then fade back (M11.2b). Ignored if
    /// a transition is already running. Walk-through portals, the O key (moon), and the I key
    /// (temple) all route through here with their destination id (M15.2).
    func beginWorldTransition(destinationID: Int = 0) {
        guard transitionPhase == .none else { return }
        transitionPhase = .fadingOut
        transitionT = 0
        pendingPortalDestination = destinationID
    }

    /// Advance the fade each frame; performs the queued world swap at the fully-black midpoint.
    private func updateTransition(dt: Float) {
        switch transitionPhase {
        case .none: break
        case .fadingOut:
            transitionT += dt * transitionSpeed
            if transitionT >= 1 {
                transitionT = 1
                if let id = pendingPortalDestination { performPortalSwap(destinationID: id); pendingPortalDestination = nil }
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

    // (R2.8: texture decoding lives in TextureLoader.swift.)

    // MARK: - Per-frame

    private func buildDrawCalls() {
        let buffer = instanceBuffers[currentBufferIndex]
        // M11 killer visual — the counterpart world shown hanging in the sky: from earth you see the
        // MOON, and from inside a sub-world you see the world beneath it. It persists, so tears made
        // on it stay. When one is shown, suppress the active world's plain M9 moon (no double moon).
        // What hangs in the sky: from a pushed world, the world beneath you on the stack; from the
        // root, whatever the registry resolves for this world's sky edge (M15.0 — an edge, not a
        // fact: today that's moon-<here>; a lying/variant sky is a registry binding away).
        // Interior worlds (M15.1) are enclosed: no sky, no celestials, no counterpart overhead.
        let interior = gameState.worldScale.interior
        let counterpart: GameState? = (debugSingleTile || interior) ? nil
            : (worldStack.count > 1 ? worldStack[worldStack.count - 2]
                                    : worldRegistry.existing(WorldKey(destination: "moon", origin: gameState.name)))
        let result = debugSingleTile
            ? sceneBuilder.buildSingleTile(tileMeshLib: tileMeshLib, instanceBuffer: buffer)
            : sceneBuilder.build(gameState: gameState, tileMeshLib: tileMeshLib, instanceBuffer: buffer,
                                 includeCelestials: !interior,
                                 includeMoon: counterpart == nil,
                                 sunOverride: noonSunDirection())
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
        // M15.1 (D2): interior worlds have no sun — a fixed warm "lantern" directional instead
        // (mild positive y so the warm low-sun tint stays subtle; revisit after the loop works).
        let interior = gameState.worldScale.interior
        // Shift+T noon-lock: sun straight overhead the player (else the normal time-of-day sun).
        let lightDir = noonSunDirection()
            ?? (interior ? normalize(SIMD3<Float>(0.35, 0.55, 0.75)) : cs.sunDirection(time: gameState.time))
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
        // Interior worlds (M15.1) and no-fog worlds (M20 gallery): fog off (pushed past everything).
        let noFog = interior || gameState.cubeModel.noFog
        let fogNear: Float = noFog ? 1e6 : (isOrbit ? camDist + halfDiagonal : 1.0)
        let fogFar: Float = noFog ? 2e6 : (isOrbit ? camDist + halfDiagonal + 2.0 * Float(gameState.cubeModel.size) : 3.5)
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
            moonIntensity: interior ? 0 : 0.30,
            eclipseFactor: eclipse,
            fadeAmount: transitionPhase == .none ? 0 : transitionT,
            plainShading: debugPlainShading ? 1 : 0,
            fogNear: fogNear,
            fogFar: fogFar,
            orbitBlend: isOrbit ? 1 : 0,
            skyDistance: skyDistance,
            leafLoaded: leafArray != nil ? 1 : 0,
            greeneryLoaded: greeneryArray != nil ? 1 : 0,
            treeSpriteLoaded: treeSpriteArray != nil ? 1 : 0
        )
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
            AssetRegistry.stamp(importedProps, into: overworld)
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
        func emit(_ mesh: AssetMesh, _ m: float4x4, diffuse: MTLTexture?, submeshMaterials: [SubmeshMaterial] = []) {
            // Per-sub-mesh textures (a Quaternius tree: bark map + leaf map). One draw per sub-mesh,
            // each binding its own diffuse; a sub-mesh with no texture keeps its flat `Kd` colour.
            // A diffuse carrying alpha (leaves/flowers) uses the cutout material (20) instead of 11.
            if !submeshMaterials.isEmpty {
                for (i, sm) in mesh.submeshes.enumerated() {
                    guard inst < cap else { return }
                    let mat = i < submeshMaterials.count ? submeshMaterials[i] : SubmeshMaterial(diffuse: nil, cutout: false)
                    let matID: UInt32 = mat.diffuse == nil ? 10 : (mat.cutout ? 20 : 11)
                    ptr[inst] = InstanceDataSwift(modelMatrix: m,
                                                  baseColor: mat.diffuse != nil ? SIMD4(1, 1, 1, 1) : sm.color,
                                                  materialID: matID,
                                                  tileID: 0, discoveryAmount: 1.0, styleSeed: 0)
                    assetDrawCmds.append(AssetDrawCmd(vertexBuffer: mesh.vertexBuffer, indexBuffer: mesh.indexBuffer,
                                                      indexOffset: sm.indexOffset, indexCount: sm.indexCount,
                                                      instanceIndex: inst, diffuse: mat.diffuse, cutout: mat.cutout))
                    inst += 1
                }
                return
            }
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
                            emit(p.mesh, m, diffuse: p.diffuse, submeshMaterials: p.submeshMaterials)
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
            beginWorldTransition(destinationID: gameState.portalDestinationID)
        }
        updateTransition(dt: dt)

        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentMTL4RenderPassDescriptor else { return }
        ensureAttachmentsResident(renderPassDesc)

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
            // M20: a cut-out sub-mesh (foliage) swaps to the alpha-tested shadow pipeline, so its
            // shadow follows the leaf silhouette instead of the solid card/blob it's painted on.
            // Only those draws pay for a fragment stage; the rest stay on the depth-only pipeline.
            if !assetDrawCmds.isEmpty {
                vertexArgTable.setAddress(assetInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
                var cutoutActive = false
                var fragTableBound = false
                for cmd in assetDrawCmds {
                    let needCutout = cmd.cutout && cmd.diffuse != nil
                    if needCutout && !fragTableBound {
                        // Bound lazily: with no cut-out draws the shadow pass never needs a fragment
                        // argument table at all.
                        if let s = texSampler { fragmentArgTable.setSamplerState(s.gpuResourceID, index: 0) }
                        shadowEncoder.setArgumentTable(fragmentArgTable, stages: .fragment)
                        fragTableBound = true
                    }
                    if needCutout != cutoutActive {
                        shadowEncoder.setRenderPipelineState(needCutout ? shadowCutoutPipelineState : shadowPipelineState)
                        cutoutActive = needCutout
                    }
                    if needCutout, let d = cmd.diffuse {
                        fragmentArgTable.setTexture(d.gpuResourceID, index: TextureIndex.assetDiffuse.rawValue)
                    }
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
        // (No pipeline/cull set here — the sky pass below sets its own immediately, and the scene
        // state is established right after it. Setting them twice tripped Metal API validation's
        // "previous set… was unused" every frame.)
        encoder.setFrontFacing(.counterClockwise)

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
        // Every declared foliage slot must be bound even when its asset array is nil (the shader's
        // `*Loaded` flags gate sampling, but Metal validation still requires a bound texture) — fall
        // back to the 1×1 placeholder array so the first draw doesn't abort under Xcode's validation.
        fragmentArgTable.setTexture((leafArray ?? placeholderArray).gpuResourceID, index: TextureIndex.leaf.rawValue)
        fragmentArgTable.setTexture((greeneryArray ?? placeholderArray).gpuResourceID, index: TextureIndex.greenery.rawValue)
        fragmentArgTable.setTexture((treeSpriteArray ?? placeholderArray).gpuResourceID, index: TextureIndex.treeSprite.rawValue)
        fragmentArgTable.setTexture(shadowMapTexture.gpuResourceID, index: TextureIndex.shadowMap.rawValue)
        // Keep the asset-diffuse slot bound to a valid texture for the maze draws (they don't
        // sample it, but the shader declares it); the prop loop rebinds it per-prop below.
        if let d = importedProps.first?.diffuse { fragmentArgTable.setTexture(d.gpuResourceID, index: TextureIndex.assetDiffuse.rawValue) }
        if let s = texSampler { fragmentArgTable.setSamplerState(s.gpuResourceID, index: 0) }

        // Sky pass: fullscreen triangle, no depth test/write. Interior worlds (M15.1) are
        // enclosed — no sky; the dark clear color reads as unlit cavern for now.
        if !gameState.worldScale.interior {
            encoder.setRenderPipelineState(skyPipelineState)
            encoder.setDepthStencilState(depthStateAlways)
            encoder.setCullMode(.none)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // Scene state
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
         roundness: Float = 0, invHalfExtent: Float = 0, reliefAmplitude: Float = 0) {
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
        self.reliefAmplitude = reliefAmplitude
    }
}
