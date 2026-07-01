//
//  GameViewController.swift
//  Mazen_Claude iOS
//
//  Created by Eddie Churchill on 6/16/26.
//

import UIKit
import MetalKit

class GameViewController: UIViewController {

    var renderer: Renderer!
    var mtkView: MTKView!

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let mtkView = self.view as? MTKView else {
            print("View of Gameview controller is not an MTKView")
            return
        }

        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported")
            return
        }

#if targetEnvironment(simulator)
        print("Metal 4 is not supported on simulator")
        return
#else
        if !defaultDevice.supportsFamily(.metal4) {
            print("Metal 4 is not supported")
            return
        }

        mtkView.device = defaultDevice
        mtkView.backgroundColor = UIColor.black
        mtkView.preferredFramesPerSecond = 120

        guard let newRenderer = Renderer(metalKitView: mtkView) else {
            print("Renderer cannot be initialized")
            return
        }

        renderer = newRenderer
        renderer.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)
        mtkView.delegate = renderer

        self.mtkView = mtkView
        setupGestures()
#endif
    }

    // MARK: - Gesture Setup

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        mtkView.addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        mtkView.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        let swipe = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        mtkView.addGestureRecognizer(swipe)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        mtkView.addGestureRecognizer(pinch)
    }

    // MARK: - First-Person Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let gs = renderer?.gameState else { return }
        guard gs.camera.mode == .firstPerson else { return }
        gs.player.tryMoveForward(cubeModel: gs.cubeModel)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let gs = renderer?.gameState else { return }
        gs.camera.mode = gs.camera.mode == .orbit ? .firstPerson : .orbit
    }

    private var swipeStartPoint: CGPoint = .zero
    private var swipeHandled = false

    @objc private func handleSwipe(_ gesture: UIPanGestureRecognizer) {
        guard let gs = renderer?.gameState else { return }

        switch gesture.state {
        case .began:
            swipeStartPoint = gesture.location(in: mtkView)
            swipeHandled = false

        case .changed:
            if gs.camera.mode == .orbit {
                handleOrbitPan(gesture)
                return
            }

            guard !swipeHandled else { return }
            let translation = gesture.translation(in: mtkView)
            let threshold: CGFloat = 40

            if abs(translation.x) > threshold || abs(translation.y) > threshold {
                if abs(translation.x) > abs(translation.y) {
                    if translation.x > 0 {
                        gs.player.tryTurnRight()
                    } else {
                        gs.player.tryTurnLeft()
                    }
                } else {
                    if translation.y > 0 {
                        gs.player.tryMoveBackward(cubeModel: gs.cubeModel)
                    } else {
                        gs.player.tryMoveForward(cubeModel: gs.cubeModel)
                    }
                }
                swipeHandled = true
            }

        default:
            break
        }
    }

    private func handleOrbitPan(_ gesture: UIPanGestureRecognizer) {
        guard let gs = renderer?.gameState else { return }
        let velocity = gesture.velocity(in: mtkView)
        gs.camera.orbitAutoRotate = false
        gs.camera.orbitRotation.x += Float(velocity.x) * 0.00003
        gs.camera.orbitRotation.y += Float(velocity.y) * 0.00003
        gs.camera.orbitRotation.y = max(-.pi / 2 + 0.01, min(.pi / 2 - 0.01, gs.camera.orbitRotation.y))
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let gs = renderer?.gameState else { return }

        if gs.camera.mode == .orbit {
            if gesture.state == .changed {
                gs.camera.orbitDistance /= Float(gesture.scale)
                gs.camera.orbitDistance = max(3.0, min(15.0, gs.camera.orbitDistance))
                gesture.scale = 1.0
            }
        } else {
            if gesture.state == .ended && gesture.scale != 1.0 {
                if gesture.scale > 1.0 {
                    gs.startSliceRotation(clockwise: true)
                } else {
                    gs.startSliceRotation(clockwise: false)
                }
            }
        }
    }
}
