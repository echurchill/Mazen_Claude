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
            gs.tryMoveForward()
        case 125, 1:  // Down arrow, S
            gs.tryMoveBackward()
        case 123, 0:  // Left arrow, A
            gs.tryTurnLeft()
        case 124, 2:  // Right arrow, D
            gs.tryTurnRight()
        case 49:      // Space — toggle camera mode
            gs.cameraMode = gs.cameraMode == .orbit ? .firstPerson : .orbit
        case 12:      // Q — rotate face clockwise
            gs.startSliceRotation(clockwise: true)
        case 14:      // E — rotate face counterclockwise
            gs.startSliceRotation(clockwise: false)
        default:
            break
        }
    }
}
