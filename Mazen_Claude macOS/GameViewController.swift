import Cocoa
import MetalKit

class GameViewController: NSViewController {

    var renderer: Renderer!
    var mtkView: MTKView!

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
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let renderer = renderer else { return }
        let gs = renderer.gameState

        switch event.keyCode {
        case 126, 13: // Up arrow, W
            gs.player.tryMoveForward(cubeModel: gs.cubeModel)
        case 125, 1:  // Down arrow, S
            gs.player.tryMoveBackward(cubeModel: gs.cubeModel)
        case 123, 0:  // Left arrow, A
            gs.player.tryTurnLeft()
        case 124, 2:  // Right arrow, D
            gs.player.tryTurnRight()
        case 49:      // Space — toggle camera mode
            gs.camera.mode = gs.camera.mode == .orbit ? .firstPerson : .orbit
        case 12:      // Q — rotate face clockwise
            gs.startSliceRotation(clockwise: true)
        case 14:      // E — rotate face counterclockwise
            gs.startSliceRotation(clockwise: false)
        case 35:      // P — toggle auto-rotation
            gs.camera.orbitAutoRotate.toggle()
        default:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let renderer = renderer else { return }
        let gs = renderer.gameState
        guard gs.camera.mode == .orbit else { return }
        gs.camera.orbitAutoRotate = false
        gs.camera.orbitRotation.x += Float(event.deltaX) * 0.005
        gs.camera.orbitRotation.y += Float(event.deltaY) * 0.005
        gs.camera.orbitRotation.y = max(-Float.pi / 2 + 0.01, min(Float.pi / 2 - 0.01, gs.camera.orbitRotation.y))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let renderer = renderer else { return }
        let gs = renderer.gameState
        guard gs.camera.mode == .orbit else { return }
        gs.camera.orbitDistance -= Float(event.deltaY) * 0.1
        gs.camera.orbitDistance = max(3.0, min(15.0, gs.camera.orbitDistance))
    }
}
