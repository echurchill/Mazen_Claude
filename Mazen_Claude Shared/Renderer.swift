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

    /// EVERY texture the GPU reads must be in the residency set. In Metal 4 a non-resident read is
    /// undefined, and on this machine "undefined" meant garbage sampled into an emissive surface,
    /// a fuchsia screen, and a display wedged hard enough to need a restart (2026-08-06, the portal
    /// view array — bound, never made resident). It has now happened three times in different
    /// clothes: attachments after a resize, a freed world's identifier reused as a cache key, and
    /// this.
    ///
    /// Nothing in Metal will tell you: there is no API to ask a residency set what it holds. So we
    /// keep our own record next to it and check bindings against it in DEBUG. The check cannot make
    /// the GPU safe — it runs after the fact — but it turns a silent, screen-wedging fault into a
    /// named line in the log the first time a new texture is bound without being registered.
    private var residentTextureIDs: Set<ObjectIdentifier> = []
    private var reportedNonResident: Set<ObjectIdentifier> = []

    /// Register a texture as resident AND record it. Use in place of `rs.addAllocation(tex)` for
    /// textures, so the record cannot drift from the set.
    func makeResident(_ tex: MTLTexture, in set: MTLResidencySet) {
        set.addAllocation(tex)
        residentTextureIDs.insert(ObjectIdentifier(tex as AnyObject))
    }

    /// The init-time version. Swift forbids calling a method on `self` before `super.init`, so the
    /// registrations there collect into a local set which is handed over once initialisation is
    /// complete. Same guarantee, different plumbing.
    private static func makeResident(_ tex: MTLTexture, in set: MTLResidencySet,
                                     recording ids: inout Set<ObjectIdentifier>) {
        set.addAllocation(tex)
        ids.insert(ObjectIdentifier(tex as AnyObject))
    }

    /// Bind a texture, and in DEBUG shout if it was never made resident.
    @inline(__always)
    func bindTexture(_ tex: MTLTexture, _ table: MTL4ArgumentTable, _ index: Int) {
#if DEBUG
        let id = ObjectIdentifier(tex as AnyObject)
        if !residentTextureIDs.contains(id), !residentAttachments.contains(id), reportedNonResident.insert(id).inserted {
            NSLog("[residency] NOT RESIDENT: '%@' bound at texture index %d. In Metal 4 the GPU read is undefined — this is the fuchsia-screen bug. Add it via makeResident().",
                  tex.label ?? "unlabelled", index)
        }
#endif
        table.setTexture(tex.gpuResourceID, index: index)
    }

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

    /// Advance the teaching text and re-render its strip when the words change. The texture is
    /// rebuilt only on a change — three times in a playthrough, not once a frame.
    private func updateTeachingPrompts(dt: Float) {
        let pad = gamepad.connectedName != nil
        prompts.update(gameState, padAttached: pad, anyInput: anyInputThisFrame(), dt: dt)
        // Re-render when the words change OR when the drawable resizes: the strip is rendered at the
        // display's own pixel width, so a window resize is a change of resolution, not just of layout.
        let dw = Int(lastDrawableSize.width), dh = Int(lastDrawableSize.height)
        if prompts.textDirty || dw != promptBuiltForWidth, dw > 0 {
            prompts.clearDirty()
            promptBuiltForWidth = dw
            promptTexture = prompts.makeTexture(device: device, padAttached: pad, drawableWidth: dw)
            if let t = promptTexture {
                makeResident(t, in: residencySet)
                residencySet.commit()
                // 1:1 mapping: a clip half-extent of texWidth/drawableWidth is exactly the texture's
                // own pixels. Anything else magnifies or minifies the letterforms.
                promptHalfW = Float(t.width) / Float(dw)
                promptHalfH = Float(t.height) / Float(max(1, dh))
            }
        }
    }

    /// "Press anything" has to mean anything: a key, a mouse button, any pad button, any stick.
    /// Keyboard and touch set `sawInput` from their own handlers; the pad is polled here.
    func anyInputThisFrame() -> Bool {
        if sawInput { sawInput = false; return true }
        return gamepad.sawAnyInput
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
    /// Captured portal views — nil when `PortalViews/` is empty, in which case every door keeps its
    /// procedural vortex. A missing capture must never be a hole in a wall.
    var portalViewArray: MTLTexture?
    /// Capture state: armed by the debug key, spent on the NEXT portal arrival. Eddie's shape —
    /// "take the picture the next time I exit a portal, magically" — because the view that belongs
    /// in a door is the one you get standing where the door puts you, and hand-framing that from a
    /// screenshot never quite matches.
    var portalCaptureArmed = false
    /// Frames to wait after arrival before grabbing: the fade must finish and the first frames of a
    /// new world still have caches warming. Counted down only once `transitionPhase == .none`.
    var portalCaptureSettle = 0
    var portalCaptureName: String? = nil
#if DEBUG
    /// `MAZEN_SHOT=name` — photograph one bench frame to `PortalViews/name.png`. The bench renders to
    /// a real drawable, so this is the same capture the portal-view key uses.
    var benchShot: (name: String, atFrame: Int)? = nil
#endif
    var portalCaptureTexture: MTLTexture?
    /// A blit is in flight; read it back once the GPU has certainly finished. Counted in frames
    /// rather than waited on, because the frame loop already paces itself and a stall here would
    /// show up as a hitch in the very shot being taken.
    var pendingCapture: (name: String, w: Int, h: Int, framesLeft: Int)?
    weak var portalCaptureView: MTKView?
    private var portalCaptureTitleWas: String?

    /// The only feedback an armed capture had was a log line, which is invisible while playing
    /// (Eddie: "maybe the HUD should have something indicating the mode is on"). There is no HUD, so
    /// the WINDOW TITLE carries it — unmissable, costs nothing, and needs no new rendering.
    private func setCaptureTitle(_ text: String?) {
#if os(macOS)
        guard let w = portalCaptureView?.window else { return }
        if let text {
            if portalCaptureTitleWas == nil { portalCaptureTitleWas = w.title }
            w.title = text
        } else if let old = portalCaptureTitleWas {
            w.title = old
            portalCaptureTitleWas = nil
        }
#endif
    }

    /// Arm the capture (debug key). The picture is taken on the NEXT portal arrival, once the fade
    /// has finished and the world has settled — "take the picture the next time I exit a portal,
    /// magically" (Eddie). Framing a door's view by hand never matches where the door actually puts
    /// you; this way the capture IS the arrival.
    func armPortalCapture(_ view: MTKView) {
        portalCaptureArmed = true
        portalCaptureView = view
        setCaptureTitle("● PORTAL CAPTURE ARMED — walk through a portal")
        // The drawable must be readable to be copied out of. Only from here, so the normal frame
        // path keeps whatever fast-path framebufferOnly buys it.
        view.framebufferOnly = false
        NSLog("[PortalViews] capture ARMED — walk through a portal")
    }
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
    /// Names already looked up and not found, so a world naming a sky that is not in the bundle asks
    /// the filesystem once rather than every frame.
    private var missingSkyboxNames: Set<String> = []

    /// A named sky, loaded on FIRST USE. macOS fills this eagerly for the cycling key; iOS does not,
    /// so a world that names its own sky (`GameState.skyboxName`) would otherwise silently fall back
    /// to the default one on device — a difference nobody would notice until they compared screens.
    /// Loading here keeps both platforms showing the same sky, and pins only what is asked for.
    func skybox(named name: String) -> MTLTexture? {
        if let t = skyboxesByName[name] { return t }
        guard !missingSkyboxNames.contains(name) else { return nil }
        let url = URL(fileURLWithPath: "\(ResourcePaths.skyboxes)/\(name).png")
        guard let t = TextureLoader.loadTextureFromFile(url: url, device: device, srgb: true) else {
            NSLog("[skybox] a world asked for '%@' and it is not in the bundle", name)
            missingSkyboxNames.insert(name)
            return nil
        }
        t.label = "Skybox \(name)"
        skyboxesByName[name] = t
        // The residency set only exists off-simulator (see the guard around its declaration) — the
        // simulator renderer is a separate branch entirely. This lazy loader sits outside that guard
        // because BOTH branches call it, so the pinning has to be guarded here instead.
#if !targetEnvironment(simulator)
        makeResident(t, in: residencySet)
        residencySet.commit()
#endif
        return t
    }
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
        if let name = gameState.skyboxName, let tex = skybox(named: name) { return tex }
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
    /// PROTOTYPE — the world in miniature above its plinth. Its own buffers rather than the sky's,
    /// because Scene 5 has BOTH: a counterpart overhead and, when the plinth is woken, the world you
    /// are standing in, small, in front of you. Sharing would make one blink out to show the other —
    /// the kind of artefact that gets mistaken for the idea failing.
    ///
    /// After R2.6 this needs no separate BUILD at all: the offset becomes a per-draw uniform and the
    /// model is the same instances drawn a second time. These buffers are the prototype's price.
    var modelInstanceBuffers: [MTLBuffer] = []
    var modelAssetInstanceBuffers: [MTLBuffer] = []
    var modelOpaqueDrawCalls: [DrawCall] = []
    var modelAssetDrawCmds: [AssetDrawCmd] = []
    var modelOffset = matrix_identity_float4x4
#if DEBUG
    static var facingShots = 0
#endif
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
    /// A controller, if one is attached — polled per frame, silent when there is none. See
    /// `GamepadInput`; it is the only input path that works identically on both platforms.
    let gamepad = GamepadInput()
    /// The game's first words — see `TeachingPrompts`. Holds the attract screen until any input.
    let prompts = TeachingPrompts(
        enabled: ProcessInfo.processInfo.environment["MAZEN_BENCH"] == nil
              || ProcessInfo.processInfo.environment["MAZEN_PROMPTS"] != nil)
    var promptTexture: MTLTexture?
    /// A 1×1 transparent 2D texture for the frames with no words on screen.
    ///
    /// NOT `placeholderArray`: that is a texture2d_ARRAY, and `promptFragmentShader` declares a plain
    /// `texture2d`. Binding the wrong TYPE does not bind at all — Metal reports the slot as "never
    /// set" and aborts the draw. Same shape of mistake as writing a value to a channel nobody reads,
    /// except this one is fatal rather than invisible.
    var promptPlaceholder: MTLTexture!
    var promptBuiltForWidth = 0
    var promptHalfW: Float = 0.44
    var promptHalfH: Float = 0.055
    /// The drawable's pixel size, kept because the prompt strip is rendered to match it.
    var lastDrawableSize = CGSize(width: 0, height: 0)
    /// Set by the platform input handlers (a key, a click, a tap) and consumed once per frame.
    var sawInput = false
    var promptPipelineState: MTLRenderPipelineState!
    private let inputSelfTest = ProcessInfo.processInfo.environment["MAZEN_INPUT_SELFTEST"] != nil

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
        // COUNT, not index (this bit has bitten once already): the prompt strip binds at 12, so the
        // count must be 13. There is deliberately no slack — the next texture added must raise it
        // again, and a too-small count is a hard Metal validation failure rather than a silent one.
        argDesc.maxTextureBindCount = 13   // …+8 caustics, +9 labels, +10 dendrites (surveyor)
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
        let ppDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
                                                             width: 1, height: 1, mipmapped: false)
        ppDesc.usage = .shaderRead
        ppDesc.storageMode = .shared
        self.promptPlaceholder = device.makeTexture(descriptor: ppDesc)
        self.promptPlaceholder.label = "PromptPlaceholder"
        var clear: UInt32 = 0
        self.promptPlaceholder.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                                       withBytes: &clear, bytesPerRow: 4)

        self.promptPipelineState = PipelineFactory.makePromptPipeline(
            compiler: compiler, library: library,
            sampleCount: metalKitView.sampleCount, colorFormat: metalKitView.colorPixelFormat)
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
        ResourcePaths.log()
        self.skyboxTexture = TextureLoader.loadTexture2D(device: device, name: "skybox", srgb: true)
        // EAGER ONLY ON macOS. The composites exist for the `L` cycling key, which no iPad has, and
        // they are not free: each one decodes to a full-resolution GPU texture pinned for the life of
        // the process. iOS loads a sky the first time a world actually asks for it by name
        // (`skybox(named:)`), which in practice is one of the five.
#if os(macOS)
        if let sb = self.skyboxTexture { self.debugSkyboxes = [sb]; self.debugSkyboxNames = ["default"] }
        let skyDir = ResourcePaths.skyboxes
        for f in (((try? FileManager.default.contentsOfDirectory(atPath: skyDir)) ?? [])
                    .filter { $0.hasSuffix("Composite.png") }.sorted()) {
            if let t = TextureLoader.loadTextureFromFile(url: URL(fileURLWithPath: "\(skyDir)/\(f)"), device: device, srgb: true) {
                self.debugSkyboxes.append(t); self.debugSkyboxNames.append(f)
                // Addressable by basename so a world can name it (GameState.skyboxName).
                self.skyboxesByName[(f as NSString).deletingPathExtension] = t
            }
        }
        if verboseDebugLog { NSLog("[skybox] %d cyclable (press L)", self.debugSkyboxes.count) }
#endif
        // LeafSets + misc_greenery asset folders were removed (Eddie) — leave these arrays nil so the
        // foliage materials fall back gracefully. Repoint here if new card assets land.
        self.leafArray = nil
        self.greeneryArray = nil
        self.treeSpriteArray = nil   // M20: WenrexaTrees billboards removed (Eddie) — folder no longer used
        self.causticArray = TextureLoader.makeCausticArray(device: device)
        self.portalViewArray = PortalViews.loadArray(device: device)
        SceneBuilder.portalViewSlices = PortalViews.slices
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

        var modelBufs: [MTLBuffer] = []
        var modelAssetBufs: [MTLBuffer] = []
        for _ in 0..<maxBuffersInFlight {
            modelBufs.append(device.makeBuffer(length: instanceSize, options: .storageModeShared)!)
            modelAssetBufs.append(device.makeBuffer(length: MemoryLayout<InstanceDataSwift>.stride * 32768,
                                                    options: .storageModeShared)!)
        }
        self.modelInstanceBuffers = modelBufs
        self.modelAssetInstanceBuffers = modelAssetBufs

        // Residency set
        let resDesc = MTLResidencySetDescriptor()
        resDesc.initialCapacity = 11 + frameBufs.count + instBufs.count + counterpartBufs.count + assetBufs.count + cpAssetBufs.count + modelBufs.count + modelAssetBufs.count
            + loadedProps.count * 3 + loadedProps.reduce(0) { $0 + $1.submeshMaterials.count }
        let rs = try! device.makeResidencySet(descriptor: resDesc)
        var initResident = Set<ObjectIdentifier>()
        rs.addAllocation(tileMeshLib.vertexBuffer)
        rs.addAllocation(tileMeshLib.indexBuffer)
        if let d = self.diffuseArray { Self.makeResident(d, in: rs, recording: &initResident) }
        if let n = self.normalArray { Self.makeResident(n, in: rs, recording: &initResident) }
        if let s = self.skyboxTexture { Self.makeResident(s, in: rs, recording: &initResident) }
        for t in self.debugSkyboxes { Self.makeResident(t, in: rs, recording: &initResident) }   // DEBUG: keep every cyclable skybox resident
        if let lf = self.leafArray { Self.makeResident(lf, in: rs, recording: &initResident) }
        if let g = self.greeneryArray { Self.makeResident(g, in: rs, recording: &initResident) }
        if let t = self.treeSpriteArray { Self.makeResident(t, in: rs, recording: &initResident) }
        Self.makeResident(self.placeholderArray, in: rs, recording: &initResident)
        if let c = self.causticArray { Self.makeResident(c, in: rs, recording: &initResident) }
        if let d = self.dendriteArray { Self.makeResident(d, in: rs, recording: &initResident) }
        if let l = self.labelArray { Self.makeResident(l, in: rs, recording: &initResident) }
        // THE PORTAL-VIEW ARRAY MUST BE RESIDENT. Omitting it is what turned Eddie's screen
        // fuchsia: in Metal 4 a shader read of a non-resident texture is undefined, and undefined
        // here means garbage sampled into an emissive full-screen-ish surface — and it can fault the
        // GPU hard enough to wedge the display. It only bit once real captures existed, because an
        // empty PortalViews/ falls back to `placeholderArray`, which IS resident. A binding that is
        // only exercised when data shows up is a binding whose residency nobody tested.
        if let pv = self.portalViewArray { Self.makeResident(pv, in: rs, recording: &initResident) }
        Self.makeResident(self.shadowMapTexture, in: rs, recording: &initResident)
        // The prompt's 1x1 placeholder. Missed last night: the line that should have added it aimed
        // at an anchor an earlier edit had already rewritten, so the replace silently did nothing and
        // a texture was bound every frame without being resident. The residency guard named it this
        // morning — which is exactly the failure it was built for, caught before Eddie ran it.
        Self.makeResident(self.promptPlaceholder, in: rs, recording: &initResident)
        for buf in frameBufs { rs.addAllocation(buf) }
        for buf in instBufs { rs.addAllocation(buf) }
        for buf in counterpartBufs { rs.addAllocation(buf) }
        for buf in cpAssetBufs { rs.addAllocation(buf) }
        for buf in modelBufs { rs.addAllocation(buf) }
        for buf in modelAssetBufs { rs.addAllocation(buf) }
        for p in loadedProps {
            rs.addAllocation(p.mesh.vertexBuffer); rs.addAllocation(p.mesh.indexBuffer)
            if let d = p.diffuse { Self.makeResident(d, in: rs, recording: &initResident) }
            for m in p.submeshMaterials { if let t = m.diffuse { Self.makeResident(t, in: rs, recording: &initResident) } }   // per-sub-mesh maps
        }
        for buf in assetBufs { rs.addAllocation(buf) }
        rs.commit()
        commandQueue.addResidencySet(rs)
        self.residencySet = rs
        // Hand the init-time registrations to the live record (see `makeResident`). Anything bound
        // that is not in here gets named in the log rather than corrupting a frame.
        self.residentTextureIDs = initResident

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
#if DEBUG
            if let shot = ProcessInfo.processInfo.environment["MAZEN_SHOT"] {
                benchShot = (name: shot,
                             atFrame: Int(ProcessInfo.processInfo.environment["MAZEN_SHOT_FRAME"] ?? "") ?? 90)
                NSLog("BENCH shot '%@' at frame %d", shot, benchShot!.atFrame)
            }
#endif
        }
#endif
    }

    func resetGame(size: Int) {
        // Collapse to a single fresh overworld (drops any pushed portal-worlds). It keeps the
        // "earth" identity, so its sky edges (moon-earth) keep resolving; registry worlds persist.
        worldStack = [GameState(size: size, name: "earth", stamp: .homeClearing)]
        Self.setupInitialDiscovery(gameState: gameState)
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
        // `includeMoon` keys off whether a counterpart will be DRAWN, not merely resolved: an
        // off-screen sky world must not silently delete the M9 moon from the sky as well.
        let counterpart: GameState? = frameCounterpart.flatMap { skyWorldIsOnScreen($0) ? $0.world : nil }
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
        // PROTOTYPE — THE WORLD ON THE PLINTH. The same world the player stands in, built a second
        // time at a hand's scale above the pedestal. No new machinery: this is the sky counterpart's
        // path with a different offset matrix.
        modelOpaqueDrawCalls = []
        if gameState.worldModelWake > 0.01, let t = gameState.worldModelTile {
            let ws = gameState.worldScale
            let base = gameState.cubeModel.inflatedPlacement(face: t.face, row: t.row, col: t.col,
                                                             localX: 0, localY: 0)
            let up = SIMD3<Float>(base.columns.2.x, base.columns.2.y, base.columns.2.z)
            // ~1.4 m across, floating a little above head height over the stone: big enough to read a
            // channel, small enough to take in at once. Grown by the wake so it unfolds from the
            // plinth rather than appearing.
            let metres: Float = 0.0529
            let radius = ws.faceDistance * 1.732
            var wantScale: Float = 0.70
#if DEBUG
            if let o = ProcessInfo.processInfo.environment["MAZEN_MODEL_SIZE"], let v = Float(o) { wantScale = v }
#endif
            let want = wantScale * metres * gameState.worldModelWake

            let scale = max(0.0001, want / max(0.0001, radius))
            var centre = base.position + up * (ws.floorY + 1.5 * metres)
#if DEBUG
            // MAZEN_MODEL=front parks the miniature a metre in front of the camera, wherever that
            // is. A bench run has no player to walk it up to the plinth, and "photograph the thing
            // and look at it" beats another round of reasoning about why it cannot be seen.
            if ProcessInfo.processInfo.environment["MAZEN_MODEL"] == "front" {
                let pose = gameState.framePose(aspect: aspect)
                let ahead = pose.position + pose.forward * (3.2 * wantScale * metres)
                let inv = simd_inverse(gameState.worldSpinMatrix())
                let c4 = inv * SIMD4<Float>(ahead.x, ahead.y, ahead.z, 1)
                centre = SIMD3(c4.x, c4.y, c4.z)
            }
#endif

            // TURN IT TO FACE THE PLAYER — see `WorldModelPlinth`.
            //
            // Three frames meet here, which is what made getting it wrong easy. `centre` and the
            // face normal come out of the model in CUBE space; the eye is in WORLD space; and
            // `build` multiplies whatever offset it is handed by the world's own spin, so the
            // geometry is spun once INSIDE the offset and the whole placement is spun again
            // OUTSIDE it. The presentation rotation sits between the two, so it takes an
            // already-spun face normal and an eye direction wound back out of world space.
            let spun = gameState.worldSpinMatrix()
            let unspin = simd_inverse(spun)
            let faceRest = gameState.cubeModel.restMatrix(face: gameState.player.face,
                                                          row: gameState.cubeModel.size / 2,
                                                          col: gameState.cubeModel.size / 2)
            let faceN4 = spun * SIMD4<Float>(faceRest.columns.2.x, faceRest.columns.2.y,
                                             faceRest.columns.2.z, 0)
            let faceN = simd_normalize(SIMD3(faceN4.x, faceN4.y, faceN4.z))
            let cw4 = spun * SIMD4<Float>(centre.x, centre.y, centre.z, 1)
            let centreWorld = SIMD3(cw4.x, cw4.y, cw4.z)
            let eyeP = gameState.framePose(aspect: aspect).position
            let te4 = unspin * SIMD4<Float>(simd_normalize(eyeP - centreWorld), 0)
            let toEye = simd_normalize(SIMD3(te4.x, te4.y, te4.z))
            let present = WorldModelPlinth.presenting(faceNormal: faceN, toEye: toEye)
            modelOffset = spun * float4x4.translation(centre.x, centre.y, centre.z)
                * float4x4.scale(scale) * present
            let mres = sceneBuilder.build(gameState: gameState, tileMeshLib: tileMeshLib,
                                          instanceBuffer: modelInstanceBuffers[currentBufferIndex],
                                          worldOffset: modelOffset,
                                          includeCelestials: false, includeMoon: false,
                                          seamFace: gameState.player.face)
            modelOpaqueDrawCalls = mres.opaque
#if DEBUG
            // The failure this fixes is SILENT — a model with its back turned is a plain stone ball,
            // not an error. One line per bench run says which way it is facing.
            if ProcessInfo.processInfo.environment["MAZEN_MODEL"] != nil, Self.facingShots < 1 {
                Self.facingShots += 1
                let n4 = modelOffset * spun * SIMD4<Float>(faceRest.columns.2.x, faceRest.columns.2.y,
                                                          faceRest.columns.2.z, 0)
                let n = SIMD3(n4.x, n4.y, n4.z)
                let toE = simd_normalize(eyeP - centreWorld)
                NSLog("[model] presenting %@ (the player's own face) at %.2f toward the eye — 1.00 is dead-on",
                      String(describing: gameState.player.face), simd_dot(simd_normalize(n), toE))
            }
#endif
        }

        counterpartOpaqueDrawCalls = []
        // Off-screen sky worlds cost NOTHING. This build ran unconditionally — 1.66 ms a frame
        // (Debug) rebuilding a world nobody could see, because the sky is behind you most of the
        // time. Same bounding-sphere test the props pass uses.
        if let cp = frameCounterpart, skyWorldIsOnScreen(cp) {
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
        audio?.updateEmitters(gameState.activeEmitters, worldSpin: gameState.worldSpinMatrix(),
                              dt: Double(gameState.frameTimeMs) / 1000.0)
        // Scene 1's two layers. Birds only in a world that HAS an outdoors and no lock — the opening
        // — and they fall silent within two tiles of the arch, which is the only warning the scene
        // gives that the corridor ahead is different. The undertone starts once the player has moved
        // and stays, "almost below conscious notice" until the portal's own tone joins it.
        let outdoors = !gameState.worldScale.interior && ambienceSilenceRemaining <= 0
        let nearArch = (gameState.tilesToNearestPortal ?? 99) <= 2
        // The undertone belongs to SCENE 1 — "after the player first moves, a low tonal layer enters
        // almost below conscious notice" is that scene's script, and its job is to introduce the
        // Builders' voice once. The condition had no scene in it, so the layer played in every
        // outdoor world forever after: the same 49 Hz tone under the garden, the natural world, the
        // galleries, all six scenes. A cue that never stops is not a cue, it is a room tone.
        audio?.setAmbienceLayers(birds: outdoors && !nearArch,
                                 underTone: outdoors && gameState.hasMoved
                                            && gameState.name == "scene-1")
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
            promptOpacity: prompts.opacity,
            promptHalfW: promptHalfW,
            promptHalfH: promptHalfH,
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
        // Read it here rather than trusting `drawableSizeWillChange` to have fired: on the very first
        // frame it may not have, and a prompt built for a zero-width drawable is a prompt nobody sees.
        lastDrawableSize = view.drawableSize
        let tUpdate0 = CACurrentMediaTime()
        // Input BEFORE the tick: a turn or an interact pressed this frame should be acted on in this
        // frame's update, not held over to the next one.
        // THE ATTRACT SCREEN HOLDS THE GAME. The pad is still polled — "press anything" has to hear
        // it — but nothing it says reaches the player until the game has begun.
        gamepad.poll(gameState, dt: Double(dt), acceptsGameInput: !prompts.waitingToBegin)
        updateTeachingPrompts(dt: dt)
        if prompts.waitingToBegin {
            gameState.camera.mode = .orbit          // the world, seen whole, before you are in it
        } else if prompts.justBegan {
            prompts.justBegan = false
            gameState.camera.mode = .firstPerson    // and now you are standing in it
        }
        // MAZEN_INPUT_SELFTEST=1 — does a keyboard hold survive a gamepad poll? Two input paths write
        // `forwardHeld`, and when the pad wrote it unconditionally a merely-PAIRED controller killed
        // W/S entirely. The failure is invisible in code review and obvious in one line here.
        if inputSelfTest, frameIndex == 60 {
            let before = gameState.forwardHeld
            gameState.forwardHeld = true
            gamepad.poll(gameState, dt: 1.0 / 60.0)
            NSLog("[input selftest] keyboard hold survives a gamepad poll: %@  (controller: %@)",
                  gameState.forwardHeld ? "YES" : "NO — REGRESSION",
                  gamepad.connectedName ?? "none attached; test is vacuous")
            gameState.forwardHeld = before
        }
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

        if var p = pendingCapture {
            p.framesLeft -= 1
            if p.framesLeft <= 0, let tex = portalCaptureTexture {
                var bytes = [UInt8](repeating: 0, count: p.w * p.h * 4)
                bytes.withUnsafeMutableBytes { buf in
                    tex.getBytes(buf.baseAddress!, bytesPerRow: p.w * 4,
                                 from: MTLRegionMake2D(0, 0, p.w, p.h), mipmapLevel: 0)
                }
                let wrote = PortalViews.write(bgraPixels: bytes, width: p.w, height: p.h, name: p.name)
                setCaptureTitle(wrote == nil ? "✕ capture FAILED — see log" : nil)
                pendingCapture = nil
            } else {
                pendingCapture = p
            }
        }

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
                        bindTexture(d, fragmentArgTable, TextureIndex.assetDiffuse.rawValue)
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
        if let d = diffuseArray { bindTexture(d, fragmentArgTable, TextureIndex.diffuseArray.rawValue) }
        if let n = normalArray { bindTexture(n, fragmentArgTable, TextureIndex.normalArray.rawValue) }
        if let sb = activeSkyboxTexture { bindTexture(sb, fragmentArgTable, TextureIndex.skybox.rawValue) }
        // Every declared foliage slot must be bound even when its asset array is nil (the shader's
        // `*Loaded` flags gate sampling, but Metal validation still requires a bound texture) — fall
        // back to the 1×1 placeholder array so the first draw doesn't abort under Xcode's validation.
        bindTexture(leafArray ?? placeholderArray, fragmentArgTable, TextureIndex.leaf.rawValue)
        bindTexture(greeneryArray ?? placeholderArray, fragmentArgTable, TextureIndex.greenery.rawValue)
        bindTexture(treeSpriteArray ?? placeholderArray, fragmentArgTable, TextureIndex.treeSprite.rawValue)
        bindTexture(causticArray ?? placeholderArray, fragmentArgTable, TextureIndex.caustic.rawValue)
        bindTexture(portalViewArray ?? placeholderArray, fragmentArgTable, TextureIndex.portalView.rawValue)
        // The teaching strip. Bound EVERY frame even when there is nothing to say: the prompt
        // pipeline declares the slot, and Metal 4 aborts the draw if it was never set — a texture
        // slot is a promise made by the shader, not by whether the draw felt like using it.
        bindTexture(promptTexture ?? promptPlaceholder, fragmentArgTable, TextureIndex.prompt.rawValue)
        bindTexture(labelArray ?? placeholderArray, fragmentArgTable, TextureIndex.label.rawValue)
        bindTexture(dendriteArray ?? placeholderArray, fragmentArgTable, TextureIndex.dendrite.rawValue)
        bindTexture(shadowMapTexture, fragmentArgTable, TextureIndex.shadowMap.rawValue)
        // Keep the asset-diffuse slot bound to a valid texture for the maze draws (they don't
        // sample it, but the shader declares it); the prop loop rebinds it per-prop below.
        if let d = importedProps.first?.diffuse { bindTexture(d, fragmentArgTable, TextureIndex.assetDiffuse.rawValue) }
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
                if let d = cmd.diffuse { bindTexture(d, fragmentArgTable, TextureIndex.assetDiffuse.rawValue) }
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
                    if let d = cmd.diffuse { bindTexture(d, fragmentArgTable, TextureIndex.assetDiffuse.rawValue) }
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

        // PROTOTYPE — the model on the plinth: same meshes, its own instance buffers, in the opaque
        // pass so it is a real object standing in the room at real depth.
        if !modelOpaqueDrawCalls.isEmpty {
            vertexArgTable.setAddress(modelInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
            fragmentArgTable.setAddress(modelInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
            for dc in modelOpaqueDrawCalls {
                encoder.drawIndexedPrimitives(
                    primitiveType: .triangle, indexCount: dc.indexCount, indexType: .uint32,
                    indexBuffer: idxBufBase + UInt64(dc.indexOffset * MemoryLayout<UInt32>.stride),
                    indexBufferLength: idxBufLen - dc.indexOffset * MemoryLayout<UInt32>.stride,
                    instanceCount: dc.instanceCount, baseVertex: 0, baseInstance: dc.instanceOffset)
            }
            if !modelAssetDrawCmds.isEmpty, !ablate.contains("assets") {
                vertexArgTable.setAddress(modelAssetInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
                fragmentArgTable.setAddress(modelAssetInstanceBuffers[currentBufferIndex].gpuAddress, index: BufferIndex.instances.rawValue)
                for cmd in modelAssetDrawCmds {
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

        // The teaching text, over the world and under the fade.
        if prompts.opacity > 0.001, promptTexture != nil {
            encoder.setRenderPipelineState(promptPipelineState)
            encoder.setDepthStencilState(depthStateAlways)
            encoder.setCullMode(.none)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
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

#if DEBUG
        // The bench's shutter: photograph one frame so a headless run can be LOOKED at rather than
        // reasoned about. Feeds the same capture path the portal-view key uses.
        if let shot = benchShot, frameIndex >= shot.atFrame {
            benchShot = nil
            portalCaptureName = shot.name
            portalCaptureSettle = 1
            NSLog("BENCH shutter at frame %d", frameIndex)
        }
#endif

        // ── Portal-view capture ──────────────────────────────────────
        // Copy the finished frame out, once the fade is done and the world has settled. The read is
        // deferred by a few frames rather than synchronised: waiting on the GPU here would stall the
        // very frame being photographed.
        if portalCaptureName != nil, transitionPhase == .none {
            portalCaptureSettle -= 1
            if portalCaptureSettle <= 0, let name = portalCaptureName {
                let src = drawable.texture
                let w = src.width, h = src.height
                if portalCaptureTexture?.width != w || portalCaptureTexture?.height != h {
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat,
                                                                     width: w, height: h, mipmapped: false)
                    d.storageMode = .shared
                    d.usage = [.shaderRead]
                    portalCaptureTexture = device.makeTexture(descriptor: d)
                    // Same rule, second offender: the copy DESTINATION is touched by the GPU too.
                    if let t = portalCaptureTexture {
                        makeResident(t, in: residencySet)
                        residencySet.commit()
                    }
                }
                // Metal 4 has no blit encoder: texture copies live on the COMPUTE encoder now.
                if let dst = portalCaptureTexture, let copyEnc = commandBuffer.makeComputeCommandEncoder() {
                    copyEnc.copy(sourceTexture: src, sourceSlice: 0, sourceLevel: 0,
                                 sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                                 sourceSize: MTLSize(width: w, height: h, depth: 1),
                                 destinationTexture: dst, destinationSlice: 0, destinationLevel: 0,
                                 destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    copyEnc.endEncoding()
                    pendingCapture = (name, w, h, maxBuffersInFlight + 1)
                    portalCaptureName = nil
                }
            }
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
        lastDrawableSize = size
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
