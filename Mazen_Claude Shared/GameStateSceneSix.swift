import Foundation
import simd

/// Refactor #4 — Scene 6's simulation: the route-keyed arrival/portal and the metal vessel.
extension GameState {
    func tickRouteKeyedArrival(_ dt: Float) {
        if arrivalAcknowledge > 0 { arrivalAcknowledge = max(0, arrivalAcknowledge - dt / 6.0) }
        // 6H — the metal vessel exists only once the scene-6 route has entered this chamber.
        if routeFacts.contains("via-underside") { cubeModel.ensureMetalVessel() }
        // 6I — "the new portal should open only because three facts are true simultaneously:
        // Scene 2's exterior world remains twisted; Scene 3's interior world remains solved; the
        // player returned through Scene 5, entering the interior from a new route." The first two
        // arrive as route facts; the third IS the route. "It is a response to accumulated history."
        if cubeModel.routeKeyedExit == nil,
           routeFacts.contains("via-underside"),
           routeFacts.contains("scene-2-turned"),
           sceneThreeAllObelisksAwake {
            if let at = cubeModel.createRouteKeyedExit(destinationID: 9) {
                let mtx = cubeModel.restMatrix(face: at.face, row: at.row, col: at.col)
                let p = SIMD3(mtx.columns.3.x, mtx.columns.3.y, mtx.columns.3.z)
                // 6J — "the portal sound includes familiar fragments… they align into one new tone":
                // the four remembered voices, played together.
                pendingAudioCues.append(.portalOpened(at: p))
                pendingAudioCues.append(.channelPulse(at: p))
                pendingAudioCues.append(.twistStrain)
                pendingAudioCues.append(.switchEngaged(at: p))
            }
        }
    }

    /// 6H — the metal vessel: "when a beam pulses, one of its rings answers a fraction of a second
    /// later." The beams breathe on the chamber's clock, so the rings step a quarter-turn on the
    /// same clock, one beat behind — the same grammar in metal.
    func tickMetalVessel() {
        guard cubeModel.symbolPairedPlinths else { return }
        let step = Float(Int((time - 0.4) / 3.2) % 4)
        for (cu, f) in cubeModel.propIndex(of: .layeredVessel) {
            for pi in cubeModel.cubies[cu].facelets[f].props.indices
            where cubeModel.cubies[cu].facelets[f].props[pi].kind == .layeredVessel
                && cubeModel.cubies[cu].facelets[f].props[pi].state == 6 {
                if cubeModel.cubies[cu].facelets[f].props[pi].anim != step {
                    cubeModel.cubies[cu].facelets[f].props[pi].anim = step
                }
            }
        }
    }
}
