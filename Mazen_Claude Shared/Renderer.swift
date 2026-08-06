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
    let instanceIndex: Int      // baseInstance of this command's contiguous instance range
    let diffuse: MTLTexture?
    var cutout: Bool = false    // diffuse is a cut-out ⇒ alpha-test it in the shadow pass too
    var instanceCount: Int = 1  // PERF: one instanced draw per unique (mesh, submesh, texture)
    /// A1 — instances are packed CASTERS FIRST, so the shadow pass draws [base, base+casterCount)
    /// and the main pass draws the whole range. Grass does not cast; walls and platforms do.
    var casterCount: Int = 0
}

/// PERF — identity of one instanced asset draw: the same sub-mesh with the same texture, drawn N times
/// with different transforms, becomes ONE `drawIndexedPrimitives(instanceCount: N)` instead of N draws
/// (and N more in the shadow pass). Same bucketing idea SceneBuilder already uses for the maze tiles.
struct AssetBucketKey: Hashable {
    let indexBuffer: ObjectIdentifier   // mesh identity (its index buffer)
    let indexOffset: Int                // sub-mesh range start (0 = whole mesh)
    let diffuse: ObjectIdentifier?      // bound texture identity (nil = flat colour)
}

struct AssetBucket {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexOffset: Int
    let indexCount: Int
    let diffuse: MTLTexture?
    let cutout: Bool
    /// The mesh's largest dimension, for size tests at pack time (A1 shadow subset, A2 LOD):
    /// world size of an instance ≈ meshMaxDim × its matrix scale.
    let meshMaxDim: Float
    var instances: [InstanceDataSwift] = []
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
    /// The same textures, RETAINED. An `ObjectIdentifier` is just the object's address, so once a
    /// texture is released that address can be handed to the next allocation — and a NEW attachment
    /// landing on a dead one's address reads as "already resident", never gets added, and is then
    /// written by the GPU while non-resident. That is undefined behaviour, and what it looked like
    /// was blocks of magenta at startup and on resize (Eddie) — exactly when MTKView is churning its
    /// MSAA/depth textures and the drawable pool is filling. Holding a reference makes the address
    /// un-recyclable, so identity means what the cache assumes it means.
    private var residentAttachmentTextures: [MTLTexture] = []
    /// Set when MTKView is about to reallocate its attachments; the old ones are dropped at the top
    /// of the next frame, once the in-flight frames that may still be reading them have completed.
    private var attachmentResidencyStale = false

    private func ensureAttachmentsResident(_ desc: MTL4RenderPassDescriptor) {
        var added = false
        func ensure(_ tex: MTLTexture?) {
            guard let tex else { return }
            let id = ObjectIdentifier(tex as AnyObject)
            guard !residentAttachments.contains(id) else { return }
            residencySet.addAllocation(tex)
            residentAttachments.insert(id)
            residentAttachmentTextures.append(tex)
            added = true
        }
        ensure(desc.colorAttachments[0].texture)
        ensure(desc.colorAttachments[0].resolveTexture)
        ensure(desc.depthAttachment.texture)
        ensure(desc.stencilAttachment.texture)
        if added { residencySet.commit() }
    }

    /// Drop the attachment registrations so the next frame re-registers whatever MTKView has just
    /// built. Removes them individually rather than clearing the set — the residency set also holds
    /// every mesh, texture and uniform buffer in the game, none of which is going anywhere.
    ///
    /// Call ONLY after the in-flight frames have retired: these textures may still be being read.
    private func releaseAttachmentResidency() {
        guard !residentAttachmentTextures.isEmpty else { return }
        for tex in residentAttachmentTextures { residencySet.removeAllocation(tex) }
        residencySet.commit()
        residentAttachmentTextures.removeAll(keepingCapacity: true)
        residentAttachments.removeAll(keepingCapacity: true)
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
    /// M16.6: Builder-glyph caustic symbols (r8 intensity array); slice = Prop.state. Generated, not loaded.
    var causticArray: MTLTexture!
    var dendriteArray: MTLTexture?
    /// M20 (Eddie): rendered text sign-boards (RGBA array); slice = a portal-hub destination. `nil` ⇒
    /// signposts fall back to plain wood. Order matches `Renderer.portalDestinations` (+0 = "Home").
    var labelArray: MTLTexture?
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
    /// Audio Phase A — PHASE engine + listener. Optional: if it fails to start the game simply runs
    /// silent rather than refusing to launch, and nothing in the model layer depends on it.
    let audio = AudioEngine()

    var skyboxTexture: MTLTexture!
    // DEBUG (Eddie, skybox eval): the 'L' key cycles skyboxTexture through these — index 0 is the
    // shipped default, then every Skyboxes/*Composite.png. Dev-only (absolute path, like modelsRoot).
    var debugSkyboxes: [MTLTexture] = []
    var debugSkyboxNames: [String] = []
    var debugSkyboxIndex = 0
    /// Skyboxes addressable by file basename, so a world can name its own sky (GameState.skyboxName).
    var skyboxesByName: [String: MTLTexture] = [:]
    func cycleDebugSkybox() {
        guard debugSkyboxes.count > 1 else { return }
        // Only move the override index — `skyboxTexture` stays the pristine default so that
        // returning to index 0 hands control back to each world's own skyboxName.
        debugSkyboxIndex = (debugSkyboxIndex + 1) % debugSkyboxes.count
        NSLog("[skybox] %@ (%d/%d)", debugSkyboxNames[debugSkyboxIndex], debugSkyboxIndex + 1, debugSkyboxes.count)
    }
    /// The sky to bind this frame: the `L` debug override if engaged, else this world's own
    /// `skyboxName`, else the shipped default. Resolved per frame, so it follows world switches.
    var activeSkyboxTexture: MTLTexture? {
        if debugSkyboxIndex != 0, debugSkyboxes.indices.contains(debugSkyboxIndex) {
            return debugSkyboxes[debugSkyboxIndex]
        }
        if let name = gameState.skyboxName, let tex = skyboxesByName[name] { return tex }
        return skyboxTexture
    }
    var shadowMapTexture: MTLTexture!
    var texSampler: MTLSamplerState!

    var frameUniformBuffers: [MTLBuffer]
    var instanceBuffers: [MTLBuffer]
    // M12: imported props (asset registry) + a per-frame instance buffer + draw list.
    var importedProps: [ImportedProp] = []
    /// Stamp the imported decorations into the overworld once (lazily, after the registry loads).
    /// They become `.importedAsset` Props on facelets so they ride slice rotations — and, being
    /// stamped only into the overworld, they don't appear in portal-worlds like the test interior.
    var needsDecorativeStamp = true
    /// M20 — the palette for DYNAMIC dressed walls (Ruins wall pieces + rocks/bushes), captured when a
    /// `.dressed` world is built. `updateAssetInstances` re-emits these per closed edge every frame, so
    /// the stone walls survive slice-twists (see `CubeModel.dressedWallProps`). Empty ⇒ hedge worlds.
    var wallDressingPalette = CubeModel.GardenFlora()
    var houseAssembly: [HouseKitPiece] = []       // M12-E: canonical imported house quarter (two walls)
    var houseAssemblyDoor: [HouseKitPiece] = []   // the front quarter — one wall swapped for a door
    var assetInstanceBuffers: [MTLBuffer] = []
    var assetDrawCmds: [AssetDrawCmd] = []
    /// PERF — persistent instancing buckets for the imported-asset pass (cleared per frame with
    /// capacity kept; entries persist so per-frame allocation is ~zero once warmed up).
    /// PER WORLD. These were single-instance, which was correct while only the active world ever
    /// ran the asset pass. The moment the sky world runs it too, one shared cache means each world
    /// invalidates the other's token every frame and BOTH rebuild — the 18-of-28 ms regression this
    /// cache exists to prevent, doubled. Keyed by world identity; pruned in `pruneAssetCaches`.
    var assetCaches: [ObjectIdentifier: WorldAssetCache] = [:]

    final class WorldAssetCache {
        var buckets: [AssetBucketKey: AssetBucket] = [:]
        var lodShown: [AssetBucketKey: [Bool]] = [:]
        var token: AssetCacheToken? = nil
    }
    var opaqueDrawCalls: [DrawCall] = []
    var wallDrawCallRange: Range<Int> = 0..<0
    var translucentDrawCalls: [DrawCall] = []
    // M11 killer visual: the counterpart world (the one you can see in the sky) rendered into its
    // own instance buffers with an orbital offset, when you're standing in a sub-world.
    var counterpartInstanceBuffers: [MTLBuffer] = []
    var counterpartOpaqueDrawCalls: [DrawCall] = []
    /// The sky world's IMPORTED props. Until 2026-08-06 no counterpart had ever shown one: the asset
    /// pass read `gameState` and nothing else, so everything imported — portal frames, dressed walls,
    /// vegetation, machinery — was missing from every world overhead. A `.dressed` world hung there
    /// with no walls at all, because there the walls ARE the imported props. See
    /// `Mazen Docs/Sky Worlds — Dressing the Counterpart.md`.
    var counterpartAssetDrawCmds: [AssetDrawCmd] = []
    var counterpartAssetInstanceBuffers: [MTLBuffer] = []
    /// Resolved ONCE per frame, before the asset pass, because the asset pass and the maze build both
    /// need the same answer and the asset pass runs first.
    var frameCounterpart: (world: GameState, offset: float4x4)? = nil

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
    let worldRegistry: WorldRegistry = {
        let r = WorldRegistry()
        r.singleInstanceNames = WorldCatalog.prologueNames
        return r
    }()
    /// M17 Phase 0 — the player's cross-world knowledge (memories, glyphs, attunement). Held here,
    /// outside the world stack, so it persists across every portal. Inert until a beat uses it.
    let playerKnowledge = PlayerKnowledge()

    // M11.2b world-transition fade: swap the active world at the midpoint of a quick fade-to-black.
    enum TransitionPhase { case none, fadingOut, fadingIn }
    var transitionPhase: TransitionPhase = .none
    /// Phase E — seconds of silence still owed after an arrival, before the new world's bed starts.
    var ambienceSilenceRemaining: Float = 0
    var transitionT: Float = 0          // 0 clear … 1 fully black
    var pendingPortalDestination: Int?  // destination id queued for the fade midpoint (M15.2)
    var pendingPortalTransition: WorldTransition = .auto   // Phase 0: how that swap moves the stack
    let transitionSpeed: Float = 5.5    // ~0.18 s per half (fade out, then fade in)

    /// What a portal Prop's `state` means (M15.2): an index into this table. From inside any
    /// sub-world a portal simply pops back out; the destination only matters from the root.
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
        // COUNT, not highest index: binding index N needs maxTextureBindCount ≥ N+1. The dendrite
        // array at index 10 asserted against the old value of 10 the moment a frame was encoded —
        // on Eddie's machine, because the overnight validation boot could not run against a locked
        // display. 12 leaves one spare slot before the next of these.
        argDesc.maxTextureBindCount = 12   // …+8 caustics, +9 labels, +10 dendrites (surveyor)
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
        // M20 (Eddie) — the FIRST world: a pastoral natural clearing whose one portal is a stone arch
        // to the garden. Kept named "earth" so the moon still hangs in its sky (moon↔earth binding).
        // The app boots into the PROLOGUE now — Scene 1 is where the story starts, and starting
        // anywhere else made it a place you had to go looking for. ("earth"/homeClearing is still
        // built on demand from the hub, and the moon still hangs in ITS sky, since that binding is
        // by name.)
        // A PLACEHOLDER only: `worldStack` has to be non-empty before `super.init()`, but the real
        // Scene 1 is built through `buildWorld` further down — the same path the hub door uses.
        // Constructing it here instead skipped everything buildWorld does around the stamp: the wall
        // dressing palette above all, so the maze had its topology and none of its walls, and the
        // player stood in an open field with vessels on the horizon (Eddie: "the maze is gone!").
        // Duplicating that setup is exactly what caused it, so the boot path no longer has its own.
        self.worldStack = [GameState(size: PrologueSize.sceneOne, name: "scene-1", stamp: .bare)]
        // The moon world exists from the start (persists across visits) so it can hang in earth's
        // sky — and so any tears you make on it stay put (M11 killer visual). Registered on the
        // identity-bound edge moon-earth (M15.0): the moon you see IS the moon you can visit.
        let moon = GameState(size: Self.moonWorldSize, name: "moon", stamp: .lunar)  // M19: grey regolith moon
        Self.setupInitialDiscovery(gameState: moon)
        worldRegistry.bind(WorldKey(destination: "moon", origin: "earth"), to: moon)

        // Tile mesh library (geometry baked from the world scale)
        // The mesh library bakes geometry from a WorldScale, and every prologue world is the same
        // scale family, so the placeholder's is the right one to build from.
        self.tileMeshLib = TileMeshLibrary(device: device, worldScale: self.worldStack[0].worldScale)

        // Textures
        self.diffuseArray = TextureLoader.loadTextureArray(device: device,
            names: ["hedge_diff", "gravel_diff", "stone_diff", "palestone_diff"], srgb: true)
        self.normalArray = TextureLoader.loadTextureArray(device: device,
            names: ["hedge_nor", "gravel_nor", "stone_nor", "palestone_nor"], srgb: false)
        self.skyboxTexture = TextureLoader.loadTexture2D(device: device, name: "skybox", srgb: true)
        // DEBUG (Eddie): preload the composite skyboxes so 'L' can cycle them in place. Dev-only path.
        if let sb = self.skyboxTexture { self.debugSkyboxes = [sb]; self.debugSkyboxNames = ["default"] }
        let skyDir = "/Volumes/Code Work/xCode work/Mazen_Claude/Skyboxes"
        for f in (((try? FileManager.default.contentsOfDirectory(atPath: skyDir)) ?? [])
                    .filter { $0.hasSuffix("Composite.png") }.sorted()) {
            if let t = TextureLoader.loadTextureFromFile(url: URL(fileURLWithPath: "\(skyDir)/\(f)"), device: device, srgb: true) {
                self.debugSkyboxes.append(t); self.debugSkyboxNames.append(f)
                // Addressable by basename so a world can name it (GameState.skyboxName).
                self.skyboxesByName[(f as NSString).deletingPathExtension] = t
            }
        }
        if verboseDebugLog { NSLog("[skybox] %d cyclable (press L)", self.debugSkyboxes.count) }
        // LeafSets + misc_greenery asset folders were removed (Eddie) — leave these arrays nil so the
        // foliage materials fall back gracefully. Repoint here if new card assets land.
        self.leafArray = nil
        self.greeneryArray = nil
        self.treeSpriteArray = nil   // M20: WenrexaTrees billboards removed (Eddie) — folder no longer used
        self.causticArray = TextureLoader.makeCausticArray(device: device)
        self.dendriteArray = TextureLoader.makeDendriteArray(device: device)
        self.labelArray = TextureLoader.makeLabelArray(device: device, labels: WorldCatalog.labels)
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
            // 32768: Scene 2's 11³ asks for 19,944 asset instances and was being clamped to 16,384, so ~3,600
            // props went missing every frame — and WHICH ones depended on dictionary iteration order, so it
            // was not even the same ones twice. Found by the bench, not by looking: a hole in a stone wall
            // reads as authored. (was 512 → 4096 → 16384)
            assetBufs.append(device.makeBuffer(length: MemoryLayout<InstanceDataSwift>.stride * 32768, options: .storageModeShared)!)
        }
        self.assetInstanceBuffers = assetBufs

        // The sky world's props. Sized to match the active world's, and NOT the 8,192 I first
        // guessed: a dressed 11³ overhead asks for ~19,000 instances even after the scatter is
        // filtered out, because its walls are all imported and walls are exactly what must survive.
        // Guessing small here would have clamped the sky silently — the failure this whole change
        // exists to undo.
        var cpAssetBufs: [MTLBuffer] = []
        for _ in 0..<maxBuffersInFlight {
            cpAssetBufs.append(device.makeBuffer(length: MemoryLayout<InstanceDataSwift>.stride * 32768, options: .storageModeShared)!)
        }
        self.counterpartAssetInstanceBuffers = cpAssetBufs

        // Residency set
        let resDesc = MTLResidencySetDescriptor()
        resDesc.initialCapacity = 9 + frameBufs.count + instBufs.count + counterpartBufs.count + assetBufs.count + cpAssetBufs.count
            + loadedProps.count * 3 + loadedProps.reduce(0) { $0 + $1.submeshMaterials.count }
        let rs = try! device.makeResidencySet(descriptor: resDesc)
        rs.addAllocation(tileMeshLib.vertexBuffer)
        rs.addAllocation(tileMeshLib.indexBuffer)
        if let d = self.diffuseArray { rs.addAllocation(d) }
        if let n = self.normalArray { rs.addAllocation(n) }
        if let s = self.skyboxTexture { rs.addAllocation(s) }
        for t in self.debugSkyboxes { rs.addAllocation(t) }   // DEBUG: keep every cyclable skybox resident
        if let lf = self.leafArray { rs.addAllocation(lf) }
        if let g = self.greeneryArray { rs.addAllocation(g) }
        if let t = self.treeSpriteArray { rs.addAllocation(t) }
        rs.addAllocation(self.placeholderArray)
        if let c = self.causticArray { rs.addAllocation(c) }
        if let d = self.dendriteArray { rs.addAllocation(d) }
        if let l = self.labelArray { rs.addAllocation(l) }
        rs.addAllocation(self.shadowMapTexture)
        for buf in frameBufs { rs.addAllocation(buf) }
        for buf in instBufs { rs.addAllocation(buf) }
        for buf in counterpartBufs { rs.addAllocation(buf) }
        for buf in cpAssetBufs { rs.addAllocation(buf) }
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

        // The real boot world, built the one way worlds are built.
        worldStack = [buildWorld(named: "scene-1")]
        if let bench = ProcessInfo.processInfo.environment["MAZEN_BENCH"], !bench.isEmpty {
            worldStack = [buildWorld(named: bench)]
            benchFramesRemaining = Int(ProcessInfo.processInfo.environment["MAZEN_BENCH_FRAMES"] ?? "") ?? 600
            ablate = Set((ProcessInfo.processInfo.environment["MAZEN_BENCH_ABLATE"] ?? "")
                .split(separator: ",").map(String.init))
            if !ablate.isEmpty { NSLog("BENCH ablating: %@", ablate.sorted().joined(separator: ",")) }
            benchActivityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "MAZEN_BENCH frame measurement")
            startBenchHeartbeat()
            // The bench booted in orbit, which is the whole reason a cull test that only worked in
            // orbit shipped. First person is a different camera in a different place and has to be
            // measured as one.
            if let t = ProcessInfo.processInfo.environment["MAZEN_CULL_T"], let v = Float(t) {
                cullBackfaceThreshold = v
                NSLog("BENCH cull threshold %.2f", v)
            }
            if let yaw = ProcessInfo.processInfo.environment["MAZEN_BENCH_YAW"], let y = Float(yaw) {
                // Setting the angle is not enough: worlds do not all boot in orbit, so the "orbit"
                // rows of the last measurement were first person wearing an orbit label.
                worldStack[worldStack.count - 1].camera.mode = .orbit
                worldStack[worldStack.count - 1].camera.orbitRotation.x = y * .pi / 180
                NSLog("BENCH orbit yaw %.0f°", y)
            }
            if ProcessInfo.processInfo.environment["MAZEN_BENCH_FP"] != nil {
                worldStack[worldStack.count - 1].camera.mode = .firstPerson
                NSLog("BENCH first-person")
            }
            NSLog("BENCH world=%@", bench)
        }
#endif
    }

    func resetGame(size: Int) {
        // Collapse to a single fresh overworld (drops any pushed portal-worlds). It keeps the
        // "earth" identity, so its sky edges (moon-earth) keep resolving; registry worlds persist.
        worldStack = [GameState(size: size, name: "earth", stamp: .homeClearing)]
        Self.setupInitialDiscovery(gameState: gameState)
        needsDecorativeStamp = true   // re-stamp the arch portal frame into the fresh home world
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
        // An authored sky (`GameState.skyCounterpart`) outranks both: a world that says what hangs
        // above it means it however the player arrived — Scene 4 reached by the dev hub must still
        // show Scene 2 overhead, not the hub it was pushed from.
        let counterpart: GameState? = frameCounterpart?.world
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
        if let cp = frameCounterpart {
            let cbuf = counterpartInstanceBuffers[currentBufferIndex]
            let offset = cp.offset
            let tcp = CACurrentMediaTime()
            let cresult = sceneBuilder.build(gameState: cp.world, tileMeshLib: tileMeshLib,
                                             instanceBuffer: cbuf, worldOffset: offset, includeCelestials: false)
            counterpartBuildMs += Float(CACurrentMediaTime() - tcp) * 1000
            counterpartOpaqueDrawCalls = cresult.opaque
        }
    }

    /// Where the counterpart world hangs in the sky (M11): at the **moon's natural orbital position
    /// and apparent size** — it *is* the moon, in its real place in the sky (rising and setting with
    /// the day). Scale is calibrated so the 3³ moon matches the M9 moon's disc, and a larger world
    /// (earth, seen from the moon) reads proportionally bigger. A gentle spin turns it so every side
    /// comes into view; the world's *state* stays frozen. (Earlier this used an artificially-close
    /// distance to make the maze / torn house legible while verifying — now reset to natural.)
    /// WHAT HANGS OVERHEAD, and where. Extracted so the asset pass and the maze build cannot
    /// disagree: the asset pass runs first, so it can no longer re-derive this for itself.
    /// Interior worlds (M15.1) are enclosed — no sky, no counterpart.
    /// An authored sky (`GameState.skyCounterpart`, now route-keyed) outranks the stack: a world
    /// that says what hangs above it means it however the player arrived.
    func resolveCounterpart() -> (world: GameState, offset: float4x4)? {
        guard !debugSingleTile, !gameState.worldScale.interior else { return nil }
        let authoredSky = gameState.skyCounterpart.flatMap {
            worldRegistry.existing(WorldKey(destination: $0, origin: gameState.name))
        }
        let world = authoredSky
            ?? (worldStack.count > 1 ? worldStack[worldStack.count - 2]
                                     : worldRegistry.existing(WorldKey(destination: "moon", origin: gameState.name)))
        guard let world else { return nil }
        return (world, Self.skyWorldOffset(cs: gameState.celestialSystem, time: gameState.time))
    }

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
        // Audio Phase A: the listener rides the SAME pose as the camera, so a face crossing or a
        // twist can never desync what you see from where a sound seems to come from.
        audio?.updateListener(position: framePose.position, forward: framePose.forward, up: framePose.up)
        // Scene 1C — the vessels only move when they are not being looked at, so the model needs to
        // know where the camera points. Published rather than reached for: GameState must stay
        // compilable without a renderer.
        gameState.viewForward = framePose.forward
        gameState.viewOrigin = framePose.position
        cullPlanes = Self.frustumPlanes(from: vp)
        cullEye = framePose.position
        cullForward = framePose.forward
        // Drain whatever the world asked to be heard this frame (same hand-off shape as
        // `portalRequested`): the model describes sounds, the renderer plays them.
        if !gameState.pendingAudioCues.isEmpty {
            audio?.play(cues: gameState.pendingAudioCues, worldSpin: gameState.worldSpinMatrix())
            gameState.pendingAudioCues.removeAll(keepingCapacity: true)
        }
        // Phase C/D — sustained emitters, republished by the world every frame from live topology
        // and reconciled here. Spun into the same frame the listener lives in, exactly like the
        // one-shot cues: the world's idle rotation has already caused two bugs by being folded in
        // at different points in different systems, so it is folded in HERE for everything audible.
        audio?.updateEmitters(gameState.activeEmitters, worldSpin: gameState.worldSpinMatrix())
        // Scene 1's two layers. Birds only in a world that HAS an outdoors and no lock — the opening
        // — and they fall silent within two tiles of the arch, which is the only warning the scene
        // gives that the corridor ahead is different. The undertone starts once the player has moved
        // and stays, "almost below conscious notice" until the portal's own tone joins it.
        let outdoors = !gameState.worldScale.interior && ambienceSilenceRemaining <= 0
        let nearArch = (gameState.tilesToNearestPortal ?? 99) <= 2
        audio?.setAmbienceLayers(birds: outdoors && !nearArch,
                                 underTone: outdoors && gameState.hasMoved)
        // Phase E — the world's bed. Arrival is SILENT and the bed returns a moment later (Scene 2's
        // script is precise about this), so the delay is the point rather than a loading artefact.
        if ambienceSilenceRemaining > 0 {
            ambienceSilenceRemaining -= gameState.frameTimeMs / 1000
            if ambienceSilenceRemaining <= 0 {
                audio?.setAmbience(world: gameState.name, enclosed: gameState.worldScale.interior)
            }
        } else if transitionPhase == .none {
            audio?.setAmbience(world: gameState.name, enclosed: gameState.worldScale.interior)
        }

        let camDist = simd_length(framePose.position)
        // Interior worlds (M15.1) and no-fog worlds (M20 gallery): fog off (pushed past everything).
        let haze = gameState.cubeModel.atmosphericDepth
        let noFog = (interior && !haze) || gameState.cubeModel.noFog
        // A hazed interior gets a range measured against the CHAMBER rather than the historical
        // 1→3.5 depth cue: the far wall of a hollow world is two face-distances away, so the fog has
        // to start around one and saturate a little past two, or the opposite face either reads
        // crisp or vanishes entirely. Scene 3's brightest point is its centre, and this is what
        // makes the edges fall away from it.
        let reach = gameState.worldScale.faceDistance
        var fogNear: Float = noFog ? 1e6 : (haze ? reach * 0.9
                                                 : (isOrbit ? camDist + halfDiagonal : 1.0))
        var fogFar: Float = noFog ? 2e6 : (haze ? reach * 2.5
                                                : (isOrbit ? camDist + halfDiagonal + 2.0 * Float(gameState.cubeModel.size) : 3.5))
        // While a slab turns, PULL THE FOG BACK. In first person the turn happens across the world —
        // ~90 m away at the far edge — and the depth-cue fog reduced the one moment the scene is built
        // around to a pale ghost, crisp only from orbit (Eddie, playtest). Eased in and out over the
        // turn (fast in, hold, fast out) so it never pops; at rest the fog is exactly as before.
        let sr = gameState.sliceRotation
        if sr.isActive && !sr.isRefusal && !noFog {
            let relief = min(1.0, min(sr.progress, 1 - sr.progress) * 8.0)
            fogNear += (fogFar - fogNear) * 1.5 * relief
            fogFar *= 1.0 + 2.0 * relief
        }
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
            treeSpriteLoaded: treeSpriteArray != nil ? 1 : 0,
            chamberLightA: chamberLights.a,
            chamberLightB: chamberLights.b,
            chamberLightColor: chamberLights.color,
            chamberLightCount: chamberLights.count,
            chamberWoken: gameState.chamberWoken,
            chamberWave: gameState.chamberWave,
            darkHaze: gameState.cubeModel.atmosphericDepth ? 1 : 0,
            channelPulse: gameState.pulseFront,
            shadowDepthRange: ws.shadowFarZ - ws.shadowNearZ,
            channelPulseBright: gameState.pulseBright,
            worldBloom: gameState.worldBloom,
            portalLightPosition: portalLight.position,
            portalLightRadius: portalLight.radius,
            portalLightColor: portalLight.color,
            portalLightIntensity: portalLight.intensity
        )
    }

    /// Scene 3 — the orb and its beams, as lights. Read from `GameState.chamberEmitters`, the same
    /// definition SceneBuilder draws from, so what lights the room can never end up somewhere other
    /// than what you can see.
    private var chamberLights: (a: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>),
                                b: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>),
                                color: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>),
                                count: Int32) {
        var a = [SIMD4<Float>](repeating: .zero, count: 8)
        var b = [SIMD4<Float>](repeating: .zero, count: 8)
        var col = [SIMD4<Float>](repeating: .zero, count: 8)
        let spin = gameState.worldSpinMatrix()
        var n = 0
        for e in gameState.chamberEmitters where n < 8 {
            let pa = spin * SIMD4(e.a.x, e.a.y, e.a.z, 1)
            let pb = spin * SIMD4(e.b.x, e.b.y, e.b.z, 1)
            let reach = gameState.worldScale.faceDistance
            // The orb throws far and softly; a beam lights the wall it passes, not the whole room.
            let radius = e.isOrb ? reach * 1.25 : reach * 0.42
            let intensity = (e.isOrb ? 0.42 : 0.30) * e.glow
            a[n] = SIMD4(pa.x, pa.y, pa.z, radius)
            b[n] = SIMD4(pb.x, pb.y, pb.z, intensity)
            col[n] = e.isOrb ? SIMD4(0.52, 0.72, 1.00, 0) : SIMD4(0.42, 0.66, 0.98, 0)
            n += 1
        }
        return ((a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]),
                (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]),
                (col[0], col[1], col[2], col[3], col[4], col[5], col[6], col[7]),
                Int32(n))
    }

    /// Scene 1G — the nearest ACTIVE portal, published as a point light so it can spill onto the
    /// floor, the walls and the vessel beside it.
    ///
    /// One light, not one per portal: the scenes stand a single arch at a time, and the whole effect
    /// is a corridor that starts glowing before you reach the turn. Picking the nearest keeps that
    /// true without a light budget. Sealed portals are inert and contribute nothing, which is what
    /// makes a dark door read as dark rather than merely unlit.
    private var portalLight: (position: SIMD3<Float>, radius: Float, color: SIMD3<Float>, intensity: Float) {
        let model = gameState.cubeModel
        guard !model.styledPortals.isEmpty else { return (.zero, 0, .zero, 0) }
        let spin = gameState.worldSpinMatrix()
        let eye = gameState.framePose(aspect: aspect).position
        var best: (pos: SIMD3<Float>, d: Float)? = nil
        for sp in model.styledPortals where !model.sealedPortalCubies.contains(sp.ci) {
            guard let loc = model.locate(cubie: sp.ci, facelet: sp.fi) else { continue }
            let m = spin * model.restMatrix(face: loc.face, row: loc.row, col: loc.col)
            // Lift it to about the middle of the arch rather than the floor, so the spill falls
            // DOWN onto the ground and outward onto the walls the way a doorway's light does.
            let up = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            let p = m.position + up * (0.06 * gameState.worldScale.eyeHeight / 1.7)
            let d = simd_length(p - eye)
            if best == nil || d < best!.d { best = (p, d) }
        }
        guard let b = best else { return (.zero, 0, .zero, 0) }
        // Violet-cyan, and deliberately "too saturated to be sunlight" (script). It breathes, so the
        // illumination "trembles" rather than sitting there like a lamp.
        let t = gameState.time
        let flicker = 0.90 + 0.10 * sinf(t * 2.3) * cosf(t * 1.17)
        // Far dimmer and far shorter than the first pass, which was a floodlight: at 1.35 over three
        // tiles it blew out everything near it and washed the obelisks' own light clean away in
        // Scene 2 (Eddie). This is meant to be a glow you notice on the stone as you approach, not a
        // light source competing with the sun.
        return (b.pos, 1.6 * gameState.worldScale.cellSpacing,
                SIMD3(0.42, 0.62, 1.0), 0.30 * flicker)
    }

    /// M20 — registry indices of every imported model whose gallery `name` starts with `prefix`
    /// (e.g. "Dungeons ", "Ruins ", "Quaternius "), for that pack's full-face evaluation gallery.
    // MARK: - MTKViewDelegate

    var perfSamples: (update: Float, build: Float, encode: Float, wait: Float) = (0, 0, 0, 0)
    var perfSampleCount = 0
    /// DEV — `MAZEN_BENCH=<world name>` boots straight into that world and logs a timing breakdown
    /// every 120 frames, then exits. Scene 2's 11³ was measured once by eye and never diagnosed;
    /// "34 fps" is not a finding, it is the absence of one, and a number nobody can reproduce on
    /// demand gets argued about instead of fixed.
    var benchFramesRemaining = 0
    /// DEV — `MAZEN_BENCH_ABLATE=shadow,assets,...` omits work from the frame so its cost can be read
    /// off the difference. Crude, and decisive: with the GPU as the wall, "how long did this pass
    /// take" is otherwise a counter-heap exercise, while "what happens if it is not there" is a
    /// comma-separated list.
    var ablate: Set<String> = []
    var cullBackfaceThreshold: Float = -0.2
    var counterpartBuildMs: Float = 0
    var subUniformsMs: Float = 0
    var subAssetsMs: Float = 0
    var subDrawCallsMs: Float = 0
    var benchPropTilesMs: Float = 0
    var benchPlaceMs: Float = 0
    var benchPackMs: Float = 0
    var benchPropTileCount = 0
    var benchPropCount = 0
    var benchAssetInstances = 0
    var benchCounterpartAssetMs: Float = 0
    var benchCounterpartAssetInstances = 0
    var benchAssetDemand = 0
    var reportedAssetOverflow = false
    /// Held for the life of a bench run: without it App Nap SUSPENDS the whole process when the
    /// window is occluded — draws, timers, everything — which is what every "hung bench" this week
    /// actually was. Not throttling, not the locked display as such, not a code hang: the OS
    /// putting a hidden app to sleep. The diagnosis took three wrong theories because each
    /// produced silence, and silence supports any theory; the heartbeat exists so the next
    /// condition NAMES itself.
    var benchActivityToken: NSObjectProtocol?
    var benchLastHeartbeat: CFTimeInterval = 0
    var benchHeartbeatFrames = 0
    var benchClearMs: Float = 0
    var benchNonCasters = 0
    static var benchSizeSamples: [Float] = []
    var benchLODDropped = 0
    /// A1 pack scratch — non-casters held back while a bucket's casters are written first.
    var packScratch: [InstanceDataSwift] = []
    /// A2 — per-bucket hysteresis state, aligned to each bucket's instances array; rebuilt with the
    /// cache. `true` = currently shown.
    var benchDressedMs: Float = 0
    static var benchHorizonKills = 0
    static var benchFrustumKills = 0
    var cullPlanes: [SIMD4<Float>] = []
    var cullEye = SIMD3<Float>(0, 0, 0)
    var cullForward = SIMD3<Float>(0, 0, 1)
    static var benchInViewKilled = 0
    var benchCulled = 0

    /// The six frustum planes of a view-projection, in world space (Gribb–Hartmann), each normalised
    /// so a plane·point is a signed distance and a margin can be given in world units.
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

        benchHeartbeatFrames += 1
        let tUpdate0 = CACurrentMediaTime()
        gameState.update(deltaTime: dt)
        let tUpdate1 = CACurrentMediaTime()

        // M11.2: a portal interaction switches worlds — through a fade (M11.2b). Clear the flag on
        // the requesting world and start the transition; the swap happens at the fully-black midpoint.
        if gameState.portalRequested {
            gameState.portalRequested = false
            beginWorldTransition(destinationID: gameState.portalDestinationID,
                                 transition: gameState.portalTransition)
        }
        updateTransition(dt: dt)

        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentMTL4RenderPassDescriptor else { return }

        let waitValue = UInt64(frameIndex - maxBuffersInFlight)
        let tWait0 = CACurrentMediaTime()
        endFrameEvent.wait(untilSignaledValue: waitValue, timeoutMS: 10)
        let tWait1 = CACurrentMediaTime()

        // After the wait: the frames that could still be reading the OLD attachments have retired,
        // so it is now safe to drop them and register whatever this frame is actually drawing into.
        if attachmentResidencyStale {
            attachmentResidencyStale = false
            releaseAttachmentResidency()
        }
        ensureAttachmentsResident(renderPassDesc)

        currentBufferIndex = frameIndex % maxBuffersInFlight
        let allocator = commandAllocators[currentBufferIndex]
        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)

        let tBuild0 = CACurrentMediaTime()
        frameCounterpart = resolveCounterpart()
        updateFrameUniforms()
        let tUni = CACurrentMediaTime()
        updateAssetInstances()
        let tAsset = CACurrentMediaTime()
        buildDrawCalls()
        let tBuild1 = CACurrentMediaTime()
        subUniformsMs += Float(tUni - tBuild0) * 1000
        subAssetsMs += Float(tAsset - tUni) * 1000
        subDrawCallsMs += Float(tBuild1 - tAsset) * 1000

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

        if !ablate.contains("shadow"), let shadowEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: shadowPassDesc) {
            shadowEncoder.label = "Shadow Pass"
            shadowEncoder.setRenderPipelineState(shadowPipelineState)
            shadowEncoder.setDepthStencilState(depthState)
            shadowEncoder.setCullMode(.front)
            shadowEncoder.setFrontFacing(.counterClockwise)
            shadowEncoder.setArgumentTable(vertexArgTable, stages: .vertex)

            let idxBase = tileMeshLib.indexBuffer.gpuAddress
            let idxLen = tileMeshLib.indexBuffer.length
            for dc in opaqueDrawCalls where !ablate.contains("shadowmaze") {
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
            if !assetDrawCmds.isEmpty, !ablate.contains("shadowassets") {
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
                    // A1 — only the caster prefix: instances are packed casters-first, so the
                    // range [base, base+casterCount) is exactly the props big enough for their
                    // shadow to be worth its vertex cost.
                    guard cmd.casterCount > 0 else { continue }
                    shadowEncoder.drawIndexedPrimitives(
                        primitiveType: .triangle, indexCount: cmd.indexCount, indexType: .uint32,
                        indexBuffer: cmd.indexBuffer.gpuAddress + UInt64(cmd.indexOffset * MemoryLayout<UInt32>.stride),
                        indexBufferLength: cmd.indexBuffer.length - cmd.indexOffset * MemoryLayout<UInt32>.stride,
                        instanceCount: cmd.casterCount, baseVertex: 0, baseInstance: cmd.instanceIndex)
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
        if let sb = activeSkyboxTexture { fragmentArgTable.setTexture(sb.gpuResourceID, index: TextureIndex.skybox.rawValue) }
        // Every declared foliage slot must be bound even when its asset array is nil (the shader's
        // `*Loaded` flags gate sampling, but Metal validation still requires a bound texture) — fall
        // back to the 1×1 placeholder array so the first draw doesn't abort under Xcode's validation.
        fragmentArgTable.setTexture((leafArray ?? placeholderArray).gpuResourceID, index: TextureIndex.leaf.rawValue)
        fragmentArgTable.setTexture((greeneryArray ?? placeholderArray).gpuResourceID, index: TextureIndex.greenery.rawValue)
        fragmentArgTable.setTexture((treeSpriteArray ?? placeholderArray).gpuResourceID, index: TextureIndex.treeSprite.rawValue)
        fragmentArgTable.setTexture((causticArray ?? placeholderArray).gpuResourceID, index: TextureIndex.caustic.rawValue)
        fragmentArgTable.setTexture((labelArray ?? placeholderArray).gpuResourceID, index: TextureIndex.label.rawValue)
        fragmentArgTable.setTexture((dendriteArray ?? placeholderArray).gpuResourceID, index: TextureIndex.dendrite.rawValue)
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
        // A turning slab is one cubie thick and has no interior faces, so with back-face culling on
        // it renders as a couple of one-tile rim strips with sky between them — the props riding it
        // appear to float (Eddie, playtest). Its body is the outward face of the slice, a full n×n
        // plane whose normal points AWAY from the player, so culling discards exactly the surface
        // that would read as the plate. Draw two-sided while a twist is in flight: the slab becomes
        // solid for the second or so it moves, and normal rendering resumes the moment it settles.
        encoder.setCullMode(gameState.sliceRotation.isActive ? .none : .back)
        encoder.setFrontFacing(.counterClockwise)

        // Pass 1: opaque geometry (depth write ON)
        encoder.setDepthStencilState(depthState)
        let idxBufBase = tileMeshLib.indexBuffer.gpuAddress
        let idxBufLen = tileMeshLib.indexBuffer.length
        for dc in opaqueDrawCalls where !ablate.contains("maze") {
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
        if !assetDrawCmds.isEmpty, !ablate.contains("assets") {
            vertexArgTable.setAddress(assetInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
            fragmentArgTable.setAddress(assetInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
            for cmd in assetDrawCmds {
                vertexArgTable.setAddress(cmd.vertexBuffer.gpuAddress, index: BufferIndex.vertices.rawValue)
                if let d = cmd.diffuse { fragmentArgTable.setTexture(d.gpuResourceID, index: TextureIndex.assetDiffuse.rawValue) }
                encoder.drawIndexedPrimitives(
                    primitiveType: .triangle, indexCount: cmd.indexCount, indexType: .uint32,
                    indexBuffer: cmd.indexBuffer.gpuAddress + UInt64(cmd.indexOffset * MemoryLayout<UInt32>.stride),
                    indexBufferLength: cmd.indexBuffer.length - cmd.indexOffset * MemoryLayout<UInt32>.stride,
                    instanceCount: cmd.instanceCount, baseVertex: 0, baseInstance: cmd.instanceIndex)
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
            // The sky world's imported props: same asset draws, its own instance buffer, and NEVER
            // in the shadow pass above — a world hanging in the sky does not cast into the world you
            // are standing in.
            if !counterpartAssetDrawCmds.isEmpty, !ablate.contains("assets") {
                vertexArgTable.setAddress(counterpartAssetInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
                fragmentArgTable.setAddress(counterpartAssetInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
                for cmd in counterpartAssetDrawCmds {
                    vertexArgTable.setAddress(cmd.vertexBuffer.gpuAddress, index: BufferIndex.vertices.rawValue)
                    if let d = cmd.diffuse { fragmentArgTable.setTexture(d.gpuResourceID, index: TextureIndex.assetDiffuse.rawValue) }
                    encoder.drawIndexedPrimitives(
                        primitiveType: .triangle, indexCount: cmd.indexCount, indexType: .uint32,
                        indexBuffer: cmd.indexBuffer.gpuAddress + UInt64(cmd.indexOffset * MemoryLayout<UInt32>.stride),
                        indexBufferLength: cmd.indexBuffer.length - cmd.indexOffset * MemoryLayout<UInt32>.stride,
                        instanceCount: cmd.instanceCount, baseVertex: 0, baseInstance: cmd.instanceIndex)
                }
                vertexArgTable.setAddress(tileMeshLib.vertexBuffer.gpuAddress, index: BufferIndex.vertices.rawValue)
            }
            vertexArgTable.setAddress(instanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
            fragmentArgTable.setAddress(instanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
        }

        // Pass 2: translucent overlays (depth write OFF)
        encoder.setDepthStencilState(depthStateNoWrite)
        for dc in translucentDrawCalls where !ablate.contains("translucent") {
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

        // Everything from the end of buildDrawCalls to here is encoding.
        let tEncode1 = CACurrentMediaTime()
        perfSamples.update += Float(tUpdate1 - tUpdate0) * 1000
        perfSamples.build  += Float(tBuild1 - tBuild0) * 1000
        perfSamples.encode += Float(tEncode1 - tBuild1) * 1000
        perfSamples.wait   += Float(tWait1 - tWait0) * 1000
        perfSampleCount += 1
        if perfSampleCount >= 120 {
            let n = Float(perfSampleCount)
            gameState.perf.update = perfSamples.update / n
            gameState.perf.build  = perfSamples.build / n
            gameState.perf.encode = perfSamples.encode / n
            gameState.perf.wait   = perfSamples.wait / n
            gameState.perf.drawCalls = opaqueDrawCalls.count + translucentDrawCalls.count
                + counterpartOpaqueDrawCalls.count + assetDrawCmds.count
            gameState.perf.instances = opaqueDrawCalls.reduce(0) { $0 + $1.instanceCount }
                + translucentDrawCalls.reduce(0) { $0 + $1.instanceCount }
                + counterpartOpaqueDrawCalls.reduce(0) { $0 + $1.instanceCount }
                + assetDrawCmds.reduce(0) { $0 + $1.instanceCount }
            perfSamples = (0, 0, 0, 0); perfSampleCount = 0
            if benchFramesRemaining > 0 { logBenchSample() }
        }

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
#if !targetEnvironment(simulator)
        // MTKView is about to rebuild its MSAA/depth textures and the drawable pool at the new size.
        // Flag the cached residency registrations as stale so the next frame re-registers the new
        // ones; the actual removal waits for the in-flight frames (see `releaseAttachmentResidency`).
        attachmentResidencyStale = true
#endif
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
         roundness: Float = 0, invHalfExtent: Float = 0, reliefAmplitude: Float = 0,
         heightScale: Float = 1, heightPivot: Float = 0) {
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
        self.heightScale = heightScale
        self.heightPivot = heightPivot
    }
}
