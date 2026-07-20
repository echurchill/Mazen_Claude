import Cocoa
import MetalKit

class GameViewController: NSViewController {

    var renderer: Renderer!
    var mtkView: MTKView!
    var debugLabel: NSTextField?
    var debugTimer: Timer?
    var showDebugHUD = false

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let mtkView = self.view as? MTKView else {
            print("View attached to GameViewController is not an MTKView")
            return
        }

        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported on this device")
            return
        }

        if !defaultDevice.supportsFamily(.metal4) {
            print("Metal 4 is not supported")
            return
        }

        mtkView.device = defaultDevice
        mtkView.preferredFramesPerSecond = 120

        guard let newRenderer = Renderer(metalKitView: mtkView) else {
            print("Renderer cannot be initialized")
            return
        }

        renderer = newRenderer
        renderer.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)
        mtkView.delegate = renderer
        self.mtkView = mtkView

        setupDebugHUD()
    }

    private func setupDebugHUD() {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        label.drawsBackground = true
        label.isBezeled = false
        label.isEditable = false
        label.maximumNumberOfLines = 5
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
        ])
        debugLabel = label

        debugTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateDebugHUD()
        }
    }

    private func updateDebugHUD() {
        guard showDebugHUD, let gs = renderer?.gameState else { return }
        let fps = gs.avgFrameTimeMs > 0 ? 1000.0 / gs.avgFrameTimeMs : 0
        let pacing: String
        switch gs.twistPacing {
        case .normal: pacing = "normal"
        case .slow:   pacing = "SLOW"
        case .step:   pacing = "STEP  [ ] to scrub"
        }
        let depth = renderer?.worldStack.count ?? 1
        let world = depth > 1 ? "interior (depth \(depth))" : "overworld"
        // "Here:" — name the prop(s) on the player's tile (the gallery / asset-eval readout).
        var here = "—"
        if let (ci, fi) = gs.cubeModel.faceletAt(face: gs.player.face, row: gs.player.row, col: gs.player.col) {
            let props = gs.cubeModel.cubies[ci].facelets[fi].props.filter { $0.kind != .portalLamp }
            let treeStates = props.filter { $0.kind == .treeBillboard }.map { $0.state }
            if !treeStates.isEmpty,
               let gi = CubeModel.treeGroups.firstIndex(where: { Set($0) == Set(treeStates) }) {
                // A composite WenrexaTrees tree: show its name + member filenames.
                let files = treeStates.sorted().map { String($0 + 1) }.joined(separator: ",")
                here = "\(CubeModel.treeGroupNames[gi]) tree (WenrexaTrees \(files))"
            } else if !props.isEmpty {
                here = props.map { p -> String in
                    switch p.kind {
                    case .foliageCard where Renderer.leafSets.indices.contains(p.state):
                        return "\(Renderer.leafSets[p.state]) (bush slice \(p.state))"
                    case .greeneryCard where Renderer.greenerySets.indices.contains(p.state):
                        return "\(Renderer.greenerySets[p.state]) (greenery slice \(p.state))"
                    case .treeBillboard where Renderer.treeSprites.indices.contains(p.state):
                        return "WenrexaTree \(Renderer.treeSprites[p.state]) (tree slice \(p.state))"
                    case .importedAsset where renderer.importedProps.indices.contains(p.state):
                        let m = renderer.importedProps[p.state]
                        return m.name.isEmpty ? "importedAsset [\(p.state)]" : m.name
                    case .importedFoliage where renderer.importedProps.indices.contains(p.state):
                        let m = renderer.importedProps[p.state]
                        return (m.name.isEmpty ? "foliage [\(p.state)]" : m.name) + " (garden plant)"
                    case .plinth:
                        let names = ["blank", "one", "two", "three", "four", "swirl", "portal", "square", "3of4 (F to turn)", "4filled (F to turn)"]
                        return "plinth: " + (names.indices.contains(p.state) ? names[p.state] : "state \(p.state)")
                    case .alignmentCylinder:
                        return "alignment cylinder (swirl + square — turning the world)"
                    case .switchCap:
                        return "switch #\(p.state) — \(p.alignAnim > 0.5 ? "engaged (F to disengage)" : "disengaged (F to engage)")"
                    case .switchBase:
                        return ""   // named by its cap
                    default:
                        return "\(p.kind)" + (p.state != 0 ? " [state \(p.state)]" : "")
                    }
                }.joined(separator: ", ")
            }
        }
        let text = String(format: """
            Face: %@  Pos: (%d,%d)  Dir: %@
            Here: %@
            Camera: %@  Cube: %dx%dx%d
            Frame: %.1f ms  (%.0f fps)
            Twist(G): %@   World(O): %@
            Roundness(-/=): %.1f   Matte(M): %@   Noon(⇧T): %@
            """,
            "\(gs.player.face)", gs.player.row, gs.player.col, "\(gs.player.facing)",
            here,
            gs.camera.mode == .orbit ? "orbit" : "FP", gs.cubeModel.size, gs.cubeModel.size, gs.cubeModel.size,
            gs.avgFrameTimeMs, fps, pacing, world, gs.cubeModel.roundness,
            (renderer?.debugPlainShading ?? false) ? "ON" : "off",
            (renderer?.sunNoonLock ?? false) ? "ON" : "off")
        debugLabel?.stringValue = text
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
        view.window?.acceptsMouseMovedEvents = true
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        setPointerLock(false)   // never leave the cursor captured/hidden
    }

    override var acceptsFirstResponder: Bool { true }

    private var pointerLocked = false

    /// Capture (hide + free) the cursor for first-person mouse-look; release it in orbit.
    /// Guarded so repeated calls don't unbalance NSCursor's hide/show stack.
    private func setPointerLock(_ locked: Bool) {
        guard locked != pointerLocked else { return }
        pointerLocked = locked
        CGAssociateMouseAndMouseCursorPosition(locked ? 0 : 1)
        if locked { NSCursor.hide() } else { NSCursor.unhide() }
    }


    override func keyDown(with event: NSEvent) {
        guard let renderer = renderer else { return }
        let gs = renderer.gameState

        switch event.keyCode {
        case 126, 13: // Up arrow, W — hold to walk forward (chained in GameState.update)
            if !event.isARepeat { gs.forwardHeld = true }   // ignore OS key-repeat: one press = held until keyUp
        case 125, 1:  // Down arrow, S — hold to walk back
            if !event.isARepeat { gs.backwardHeld = true }
        case 123, 0:  // Left arrow, A
            gs.player.tryTurnLeft()
        case 124, 2:  // Right arrow, D
            gs.player.tryTurnRight()
        case 49:      // Space — toggle camera mode
            gs.camera.mode = gs.camera.mode == .orbit ? .firstPerson : .orbit
            setPointerLock(gs.camera.mode == .firstPerson)
        case 12:      // Q — rotate face clockwise
            gs.startSliceRotation(clockwise: true)
        case 14:      // E — rotate face counterclockwise
            gs.startSliceRotation(clockwise: false)
        case 3:       // F — interact with a prop on the current tile
            gs.interact()
        case 17:      // T — time-scale 1x→8x→60x;  Shift+T — toggle "noon at the player" sun-lock
            if event.modifierFlags.contains(.shift) {
                renderer.sunNoonLock.toggle()   // sun pinned straight overhead the player, always
            } else {
                let scales: [Float] = [1, 8, 60]
                let idx = scales.firstIndex(of: gs.timeScale) ?? 0
                gs.timeScale = scales[(idx + 1) % scales.count]
            }
        case 5:       // G — cycle slice-twist pacing (debug): normal → slow → single-step
            switch gs.twistPacing {
            case .normal: gs.twistPacing = .slow
            case .slow:   gs.twistPacing = .step
            case .step:   gs.twistPacing = .normal
            }
        case 30:      // ] — scrub a held twist forward (single-step pacing)
            gs.stepSlice(0.06)
        case 33:      // [ — scrub a held twist backward
            gs.stepSlice(-0.06)
        case 35:      // P — toggle auto-rotation
            gs.camera.orbitAutoRotate.toggle()
        case 4:       // H — toggle debug HUD
            showDebugHUD.toggle()
            debugLabel?.isHidden = !showDebugHUD
        case 45:      // N — cycle cube size, odd only (3→5→7→9→3)
            let sizes = [3, 5, 7, 9]
            let idx = sizes.firstIndex(of: gs.cubeModel.size) ?? 0
            renderer.resetGame(size: sizes[(idx + 1) % sizes.count])
        case 24:      // = — M14b debug: inflate all worlds toward a sphere (incl. the sky moon)
            renderer.adjustRoundness(0.1)
        case 27:      // - — M14b debug: deflate all worlds toward the hard cube
            renderer.adjustRoundness(-0.1)
        case 46:      // M — M14 debug: toggle flat matte shading (read raw geometry, no texture/fog)
            renderer.debugPlainShading.toggle()
        case 50:      // ` (grave) — M20 (Eddie): the labeled PORTAL HUB — the single entry point to every
                      // world (retired the per-world O/I/B/V/Y/1-4 jumps; navigate by reading signs).
            renderer.beginWorldTransition(destinationID: 9)
        case 43:      // , — M19 debug: lower relief (hill amplitude) on the active world
            renderer.adjustRelief(-0.01)
        case 47:      // . — M19 debug: raise relief (hill amplitude) on the active world
            renderer.adjustRelief(0.01)
        case 38:      // J — debug: toggle the idle world spin only (leaves the sun/time moving)
            gs.spinEnabled.toggle()
        case 32:      // U — M16.6 debug: make the door READY (bypass the dials) so the plinth shows
                      // four-filled; then stand at it and press F to watch the turn-the-world sequence
            gs.debugMakeDoorReady()
        case 40:      // K — debug: freeze/unfreeze time *in place* (no reset to noon, unlike Shift+T)
            gs.timeScale = gs.timeScale == 0 ? 1 : 0
        default:
            break
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let gs = renderer?.gameState else { return }
        switch event.keyCode {
        case 126, 13: gs.forwardHeld = false
        case 125, 1:  gs.backwardHeld = false
        default: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let renderer = renderer else { return }
        let gs = renderer.gameState
        if gs.camera.mode == .firstPerson { handleLook(event); return }
        gs.camera.orbitAutoRotate = false
        gs.camera.orbitRotation.x += Float(event.deltaX) * 0.005
        gs.camera.orbitRotation.y += Float(event.deltaY) * 0.005
        gs.camera.orbitRotation.y = max(-Float.pi / 2 + 0.01, min(Float.pi / 2 - 0.01, gs.camera.orbitRotation.y))
    }

    override func mouseMoved(with event: NSEvent) {
        handleLook(event)
    }

    /// First-person mouse look: yaw from horizontal motion, pitch (clamped) from vertical.
    private func handleLook(_ event: NSEvent) {
        guard let gs = renderer?.gameState, gs.camera.mode == .firstPerson else { return }
        let sens: Float = 0.0022
        gs.camera.lookYaw -= Float(event.deltaX) * sens
        gs.camera.lookPitch = max(-1.4, min(1.4, gs.camera.lookPitch - Float(event.deltaY) * sens))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let renderer = renderer else { return }
        let gs = renderer.gameState
        guard gs.camera.mode == .orbit else { return }
        let ws = gs.worldScale
        let current = gs.camera.orbitDistanceOverride ?? ws.orbitDistance
        gs.camera.orbitDistanceOverride = max(ws.orbitDistanceMin, min(ws.orbitDistanceMax, current - Float(event.deltaY) * 0.1))
    }
}
