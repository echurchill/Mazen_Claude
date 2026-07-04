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
        let text = String(format: """
            Face: %@  Pos: (%d,%d)  Dir: %@
            Camera: %@  Cube: %dx%dx%d
            Frame: %.1f ms  (%.0f fps)
            """,
            "\(gs.player.face)", gs.player.row, gs.player.col, "\(gs.player.facing)",
            gs.camera.mode == .orbit ? "orbit" : "FP", gs.cubeModel.size, gs.cubeModel.size, gs.cubeModel.size,
            gs.avgFrameTimeMs, fps)
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
            gs.forwardHeld = true
        case 125, 1:  // Down arrow, S — hold to walk back
            gs.backwardHeld = true
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
        case 17:      // T — cycle world time-scale (fast-forward the sky): 1x → 8x → 60x
            let scales: [Float] = [1, 8, 60]
            let idx = scales.firstIndex(of: gs.timeScale) ?? 0
            gs.timeScale = scales[(idx + 1) % scales.count]
        case 35:      // P — toggle auto-rotation
            gs.camera.orbitAutoRotate.toggle()
        case 4:       // H — toggle debug HUD
            showDebugHUD.toggle()
            debugLabel?.isHidden = !showDebugHUD
        case 45:      // N — cycle cube size, odd only (3→5→7→9→3)
            let sizes = [3, 5, 7, 9]
            let idx = sizes.firstIndex(of: gs.cubeModel.size) ?? 0
            renderer.resetGame(size: sizes[(idx + 1) % sizes.count])
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
