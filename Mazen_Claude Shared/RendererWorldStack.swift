import Metal
import MetalKit
import simd

/// B1 — the world-graph half of the Renderer: building worlds by name, the stack, portal swaps,
/// transitions and the initial-discovery pass. Moved verbatim from Renderer.swift; stored
/// properties remain on the class (Swift extensions cannot hold them).
extension Renderer {
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

    /// Scene 1's day runs at a third of the usual speed. The default ~8 minutes is tuned for
    /// watching a shadow sweep during development; here the light is meant to move over a whole
    /// exploration without ever being the thing you notice (Eddie: "the day seems to go by a little
    /// too fast"). At ~24 minutes dawn still becomes morning while you walk the maze, but no faster
    /// than the walking.
    static func slowTheDay(_ w: GameState) {
        w.celestialSystem.sunPeriod *= 3
        w.celestialSystem.moonPeriod *= 3
    }

    /// Build a world from its name — the single place a destination's size, stamp and dressing
    /// are decided. Used by the portal swap on first arrival, and by the sky binding below, so
    /// a world hanging overhead is stamped identically to the one you can walk into.
    func buildWorld(named dest: String) -> GameState {
        // First visit — build the destination. (The moon is pre-bound at init, so its
        // create only runs as a fallback for an unexpected origin.)
        let w: GameState
        switch dest {
        case "temple-interior":
            w = GameState(size: 5, name: dest, interior: true, stamp: .templeInterior)
            // M20 — the return portal is an UP elevator; add its flanking columns (imported).
            w.cubeModel.stampPortalFrames(column: namedProp("Dungeons Column"), archRuins: namedProp("Ruins Wall_ArchRound_Overgrown"))
        case "natural":
            // M18 Phase 1 open-field testbed (T key) — size 7 gives a real horizon walk.
            w = GameState(size: 7, name: dest, stamp: .natural)
        case "garden":
            // M20 — the entry world. Size 11 = exactly the sealed maze play region (R=5),
            // so the world IS the garden with no fog border on the play face (Eddie shrank it
            // from 25). Trade-off: a smaller cube shows more surface curvature. The stamp
            // reveals ONLY its region, so DON'T reveal-all here.
            w = GameState(size: 11, name: dest, stamp: .gardenMaze)
            // M20 (Eddie) — the garden's own sky: the Eagle Nebula composite. Measured as the
            // most banding-prone of the five (widest, faintest soft haze), so it's also the
            // best showcase for the gradient-aware sky dither.
            w.skyboxName = "SynthStarfield_5_EagleNebulaComposite"
            // Reskin the garden with Quaternius plants — the Renderer owns the registry
            // indices, so it groups them by kind and stamps the vegetation after the build.
            w.cubeModel.stampGardenVegetation(gardenFlora())
            // M20 — the garden's walls are DRESSED with stone models (Ruins pieces + rocks/bushes)
            // instead of hedges: capture the palette; `updateAssetInstances` emits it per closed
            // edge every frame from live topology, so the stone walls survive slice-twists. (The
            // static "stone-in-hedges" look — `stampGardenWalls` — is kept available for reuse.)
            wallDressingPalette = wallFlora()
            // M20 — a stone path marking the correct route between the puzzle elements (tapers off).
            w.cubeModel.stampGardenPath(pathStones())
            // M20 — the temple door is a DOWN elevator; add its flanking columns (imported).
            w.cubeModel.stampPortalFrames(column: namedProp("Dungeons Column"), archRuins: namedProp("Ruins Wall_ArchRound_Overgrown"))
        case "gallery":
            // M20 dev tool — procedural prop/glyph catalog (Y key) + the natural-wall
            // prototype east of it. Size 25 to fit the catalog. Stamp partial-reveals.
            w = GameState(size: 25, name: dest, stamp: .gallery)
            // M20 prototype — sample "natural walls" (Ruins wall pieces + Nature rocks/bushes).
            w.cubeModel.stampGalleryWalls(wallFlora())
            // M20 prototype — rock-path options west of the catalog (MegaKit RockPath models).
            w.cubeModel.stampGalleryPaths(pathStones())
            // M20 (Eddie) — three new PORTAL styles in a showroom north of the catalog
            // (retiring the TARDIS): elevator, spot-to-spot energy veils, level-to-level arch.
            w.cubeModel.stampGalleryPortals(column: namedProp("Dungeons Column"),
                                            archRuins: namedProp("Ruins Wall_ArchRound_Overgrown"))
        case "gallery-dungeons":
            w = GameState(size: 25, name: dest, stamp: .bare)
            w.cubeModel.stampPackGallery(packIndices("Dungeons "))
            w.cubeModel.noFog = true              // showroom, not a story world — no fog
        case "gallery-nature":
            w = GameState(size: 25, name: dest, stamp: .bare)
            w.cubeModel.stampPackGallery(packIndices("Nature "))
            w.cubeModel.noFog = true
        case "gallery-ruins":
            w = GameState(size: 25, name: dest, stamp: .bare)
            w.cubeModel.stampPackGallery(packIndices("Ruins "))
            w.cubeModel.noFog = true
        case "gallery-megakit":
            w = GameState(size: 25, name: dest, stamp: .bare)
            w.cubeModel.stampPackGallery(packIndices("MegaKit "))
            w.cubeModel.noFog = true
        case "gallery-cyberpunk":
            // The Cyberpunk kit's structural half — the machinery Scene 6's underside is dressed
            // with. Same aisled gallery as the other packs, so a new pack is looked at the same way
            // every other one was.
            w = GameState(size: 25, name: dest, stamp: .bare)
            w.cubeModel.stampPackGallery(packIndices("Cyberpunk "))
            w.cubeModel.noFog = true
        case "portal-hub":
            // M20 (Eddie) — the labeled hub of TARDIS portals + signposts. Size 15 fits the 3×3.
            w = GameState(size: 15, name: dest, stamp: .portalHub)
        case "scene-5":
            // Prologue Scene 5 — the pale world. Player twists ENABLED and needed constantly: this
            // is the first scene where the verb is the tool rather than the revelation.
            w = GameState(size: PrologueSize.sceneFive, name: dest, stamp: .sceneFive)
            // Scene 4's world hangs overhead "in the persistent configuration in which the player
            // left it" — the same registry edge that hangs Scene 2 over Scene 4.
            w.cubeModel.stampPortalFrames(column: namedProp("Dungeons Column"),
                                          archRuins: namedProp("Ruins Wall_ArchRound_Overgrown"))
        case "scene-3":
            // Prologue Scene 3 — the INTERIOR of Scene 2's world. No sky, no celestials, no
            // counterpart overhead; the orb at the centre is the only thing to navigate by.
            w = GameState(size: PrologueSize.sceneThree, name: dest, interior: true, stamp: .sceneThree)
            w.twistEnabled = false          // "player twist access: disabled"
            w.cubeModel.stampPortalFrames(column: namedProp("Dungeons Column"),
                                          archRuins: namedProp("Ruins Wall_ArchRound_Overgrown"))
        case "scene-1":
            // Prologue Scene 1 — the opening. No lock, no twist: "initial twist access: disabled or
            // unexplained". The verb is not withheld as a puzzle here, it simply does not exist yet.
            w = GameState(size: PrologueSize.sceneOne, name: dest, stamp: .sceneOne)
            w.twistEnabled = false
            // DAWN. The script opens here and lets the light move as the player explores: "the maze
            // exploration should last long enough for the opening celestial arrangement to change…
            // the world itself marks the player's movement through the scene."
            Self.slowTheDay(w)
            // DAWN, and `time` is seconds into a cycle that STARTS at noon — so 6.0 was midday, not
            // six in the morning. Sunrise is three quarters of the way round; a shade past it puts
            // the sun just clear of the eastern wall, which is where the script opens: "its light
            // reaches only the upper stones at first, then spills down into the clearing."
            w.time = w.celestialSystem.sunPeriod * 0.765
            w.cubeModel.stampGardenVegetation(gardenFlora())
            wallDressingPalette = wallFlora()
            w.cubeModel.stampPortalFrames(column: namedProp("Dungeons Column"),
                                          archRuins: namedProp("Ruins Wall_ArchRound_Overgrown"))
        case "scene-4":
            // Prologue Scene 4 — the player is GRANTED the twist here. Not on arrival, though: the
            // script hands it over only once the VESSEL has demonstrated it ("after the vessel is
            // inspected, player-controlled twist input becomes available"), so the verb is learned
            // from an object rather than found in a control list. GameState grants it.
            w = GameState(size: PrologueSize.sceneFour, name: dest, stamp: .sceneFour)
            w.twistEnabled = false
            w.cubeModel.stampGardenVegetation(gardenFlora())
            wallDressingPalette = wallFlora()
            w.cubeModel.stampPortalFrames(column: namedProp("Dungeons Column"),
                                          archRuins: namedProp("Ruins Wall_ArchRound_Overgrown"))
        case "scene-2":
            // Prologue Scene 2 — "The Four Corners". The twist is the puzzle's reward, not a
            // tool the player owns yet, so the player's own Q/E stays withheld here.
            w = GameState(size: PrologueSize.sceneTwo, name: dest, stamp: .sceneTwo)
            w.twistEnabled = false
            // SCENE 6C — the far side of the slab the player turns here is Scene 6's arrival region,
            // and it was bare. Dressed with the machinery kit, densest against the edge the portal
            // assembly stands on, because that is the underside the player walks out to read.
            w.cubeModel.stampGardenVegetation(gardenFlora())
            wallDressingPalette = wallFlora()
            w.cubeModel.stampPortalFrames(column: namedProp("Dungeons Column"),
                                          archRuins: namedProp("Ruins Wall_ArchRound_Overgrown"))
            // LAST: the underside clears the world's dressing off its face before laying machinery,
            // so it has to run after everything that dresses.
            w.cubeModel.stampSceneSixUnderside(undersideMachinery())
        default:
            w = GameState(size: Self.moonWorldSize, name: dest, stamp: .lunar)  // M19: grey regolith moon
        }
        // Gardens, gallery worlds, and the hub reveal only their own stamped region (no reveal-all).
        //
        // SCENE 1 IS NO LONGER EXCLUDED (Eddie, 2026-08-01) — though the exclusion turned out to be
        // INERT, which is worth writing down. `stampSceneOne` marks every one of its 486 facelets
        // discovered, so keeping Scene 1 off the reveal-all list changed nothing: measured, the world
        // is fully discovered at stamp either way. The popping Eddie saw while walking was not
        // discovery at all — it was the broken horizon cull, which killed anything more than a couple
        // of tiles away and let it back in as he approached. That is fixed separately.
        //
        // The line goes anyway, so a dead exclusion cannot come back to life the day the stamp stops
        // discovering its own tiles. The script's "understand its scale gradually through movement"
        // still deserves a mechanism; tile discovery was the wrong one twice (the volumetric fog
        // before it arrived as blocks lifting out of mist). Tight DISTANCE FOG is the idea worth
        // trying: nothing pops, the far maze is simply hazy.
        if !dest.hasPrefix("gallery") && dest != "garden" && dest != "portal-hub" {
            Self.setupInitialDiscovery(gameState: w)
        }
        // An authored sky (`skyCounterpart`) is bound as a real edge now, while we can still build
        // the other world if the player has never been there — the sky lookup itself must never
        // conjure a world mid-frame. Reuses the existing instance when there is one, so the world
        // overhead is the same place, with the same scars, as the one behind its door.
        if let sky = w.skyCounterpart, worldRegistry.existing(WorldKey(destination: sky, origin: dest)) == nil {
            // One level only: a sky world's own sky stays the default rule, so this cannot recurse.
            worldRegistry.bind(WorldKey(destination: sky, origin: dest),
                               to: worldRegistry.anyNamed(sky) ?? buildWorld(named: sky))
        }
        return w
    }

    /// Perform the world swap (at the fade midpoint): inside any sub-world, pop back out;
    /// from the root, enter the destination — resolved by route through the registry (M15.2),
    /// created on first visit, persistent forever after.
    func performPortalSwap(destinationID: Int, transition: WorldTransition = .auto) {
        // Phase E — the world you are leaving goes quiet AT the swap, and the new one's bed is held
        // back for a beat. "Silence on arrival, then the wind returns" is the whole effect.
        audio?.setAmbience(world: nil)
        ambienceSilenceRemaining = 1.4
        // Stop the departing world walking, so neither world auto-continues across the switch —
        // with walk-through portals, an un-cleared "forward held" would ping-pong through gates.
        gameState.forwardHeld = false; gameState.backwardHeld = false
        let departingMode = gameState.camera.mode   // FPV stays FPV across worlds (Eddie, M15.2)
        let departingName = gameState.name          // Phase 0: recorded on the arriving world
        var dest = WorldCatalog.destination(for: destinationID)
        // SCENE 6 IS SCENE 2. "Scene 6 must use the actual persisted state of Scene 2, not a visually
        // similar duplicate" — so its hub door does not build a world, it resolves to the Scene 2
        // instance and declares that you arrived FROM SCENE 5. That origin is what picks the arrival
        // on `-X`, the far side of the slab the player turned there; without it the door would drop
        // you at Scene 2's own opening and there would be no Scene 6 at all.
        let sceneSixReturn = (dest == "scene-6")
        if sceneSixReturn { dest = "scene-2" }
        // Phase 0 — the portal says how it travels (see `WorldTransition`). This replaces the old
        // name-matching (`dest == "temple-interior"` / `name == "portal-hub"`), which was two special
        // cases for four worlds and had no way to express the six-scene prologue. `.auto` preserves
        // the legacy toggle exactly: inside a sub-world pop, otherwise push.
        let popping: Bool, replacing: Bool
        switch transition {
        case .push: popping = false; replacing = false
        case .pop:  popping = true;  replacing = false
        case .auto: popping = worldStack.count > 1; replacing = false
        case .goto: popping = false; replacing = true   // sideways: swap the top, don't nest
        }
        let pushed: Bool
        if popping && worldStack.count > 1 {
            exitWorld()
            pushed = false
        } else {
            // The prologue's scenes are single-instance: one Scene 2, however you reach it. Every
            // other world keeps the registry's per-edge default, where arriving by a new door may
            // legitimately yield a variant. Without this, Scene 4 building Scene 2 for its sky
            // would leave a *second* Scene 2 behind the hub door — you would walk into a world that
            // was not the one overhead, and the two would diverge on the first twist.
            // (The rule itself now lives on the registry, where it can be tested.)
            let world = worldRegistry.resolve(destination: dest, origin: gameState.name) {
                self.buildWorld(named: dest)
            }
            if replacing {
                // `goto` — the destination becomes the current world in place. The world we leave
                // stays in the registry with all its state, so this loses nothing; it just doesn't
                // nest. (Arrival is treated as an entry, hence pushed = true: you emerge from the
                // destination's own doorway rather than turning round on the door you left by.)
                worldStack[worldStack.count - 1] = world
            } else {
                enterWorld(world)
            }
            pushed = true
        }

        // Arrival = stepping OUT of a door (Eddie, M15.2): same camera mode as you left in, and
        // you emerge looking the portal's exit direction — the door at your back.
        let arriving = gameState
        // Phase 0: "how you got here", for route-keyed behaviour. The Scene 6 door says Scene 5
        // however you actually reached it, because Scene 6 IS that route.
        arriving.lastArrivalOrigin = sceneSixReturn ? "scene-5" : departingName
        // Scene 2A — the way back CLOSES behind you. Only in the prologue's scenes, which are
        // explicitly one-way ("no going back to the prologue's world"); the dev hub and the sandbox
        // worlds keep their doors, or building would become a chore.
        if WorldCatalog.prologueNames.contains(arriving.name) && pushed {
            arriving.closeArrivalDoorway()
        }
        arriving.camera.mode = departingMode
        arriving.camera.lookYaw = 0
        arriving.camera.lookPitch = 0
        arriving.player.isMoving = false
        arriving.player.isTurning = false
        if pushed {
            // Arrive where the world says, if it says; otherwise emerge FROM its own doorway, wherever
            // that stands. The fallback assumes a world's first portal is its entrance, which is only
            // true for the older worlds — a scene whose exit is hidden on another face (Scene 2) would
            // otherwise drop the player onto that face, walled in.
            // Route-keyed: a world may name a different arrival point per origin (Scene 6 returns
            // to Scene 2 on a face Scene 2's own entrance never reaches). `lastArrivalOrigin` is set
            // just above, so this is the first thing that has ever read it.
            if let spawn = arriving.cubeModel.spawn(arrivingFrom: arriving.lastArrivalOrigin) {
                arriving.player.face = spawn.face
                arriving.player.row = spawn.row
                arriving.player.col = spawn.col
                arriving.player.subRow = arriving.player.standCenter
                arriving.player.subCol = arriving.player.standCenter
                arriving.player.facing = spawn.facing
            } else if let door = arriving.cubeModel.firstPortalLocation() {
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
    func beginWorldTransition(destinationID: Int = 0, transition: WorldTransition = .auto) {
        guard transitionPhase == .none else { return }
        transitionPhase = .fadingOut
        transitionT = 0
        pendingPortalDestination = destinationID
        pendingPortalTransition = transition
    }

    /// Advance the fade each frame; performs the queued world swap at the fully-black midpoint.
    func updateTransition(dt: Float) {
        switch transitionPhase {
        case .none: break
        case .fadingOut:
            transitionT += dt * transitionSpeed
            if transitionT >= 1 {
                transitionT = 1
                if let id = pendingPortalDestination {
                    performPortalSwap(destinationID: id, transition: pendingPortalTransition)
                    pendingPortalDestination = nil
                    pendingPortalTransition = .auto
                }
                transitionPhase = .fadingIn
            }
        case .fadingIn:
            transitionT -= dt * transitionSpeed
            if transitionT <= 0 { transitionT = 0; transitionPhase = .none }
        }
    }

    static func setupInitialDiscovery(gameState: GameState) {
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

}
