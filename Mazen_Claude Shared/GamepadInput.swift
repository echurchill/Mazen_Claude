import Foundation
import GameController

/// A GAMEPAD, on both platforms, from one file.
///
/// `GCController` is the same framework and the same API on macOS and iPadOS, and this game's entire
/// input surface is about eight calls — hold forward, hold back, turn, interact, twist either way,
/// toggle the camera, look. Both view controllers already funnel into exactly those, so a controller
/// is a third caller rather than a new subsystem.
///
/// It also does something the touch build needed: **the twist gets two real buttons.** On an iPad
/// Q/E maps to a two-finger swipe nobody discovers, and Scene 4 — whose whole job is to teach the
/// twist — has no way to teach it. A shoulder button is not the diegetic answer that scene still
/// wants, but it makes the prologue properly playable on a device today.
///
/// Polled once per frame from the renderer rather than driven by handlers: movement and look are
/// continuous, the frame already knows its `dt`, and polling keeps repeat-rate logic in one place
/// instead of scattered across callbacks.
final class GamepadInput {

    // Sticks are noisy at rest and analog triggers rarely sit at zero.
    private let deadZone: Float = 0.22
    /// Turning is DISCRETE (45° steps), so a held stick has to repeat rather than stream. Press
    /// beyond `turnOn`, and it will not fire again until it falls back under `turnOff` or the repeat
    /// timer elapses — the same hysteresis the LOD boundary needed, for the same reason: a threshold
    /// something can sit exactly on is a threshold that chatters.
    private let turnOn: Float = 0.55
    private let turnOff: Float = 0.35
    private let turnRepeat: Double = 0.22
    /// Radians per second at full deflection. Mouse look is 0.0022 rad per point of motion; this is
    /// the same feel expressed as a rate, and it is the first number to change if it feels wrong.
    private let lookRate: Float = 2.6
    private let orbitRate: Float = 1.8

    /// True while a stick or d-pad is actually pushed. See the movement block: without it, a paired
    /// but untouched controller silently overrides the keyboard every frame.
    private var padOwnsMovement = false
    private var turnArmed = true
    private var turnCooldown: Double = 0
    /// Edge-triggered buttons: the value last frame, so a hold fires once.
    private var wasPressed: [String: Bool] = [:]

    /// THE PORTAL HUB, on the MENU button (Eddie, 2026-08-29). The hub is the single entry point to
    /// every world and it was keyboard-only (`` ` ``), so on an iPad with a controller — the way this
    /// game is actually being played now — there was no way to reach it at all. Menu was the one
    /// button already being read for "press anything" and bound to nothing.
    ///
    /// A closure rather than a call, because this is the one action a pad can take that is not a
    /// fact about the player: it changes which world the Renderer is showing, and the Renderer owns
    /// that.
    var onPortalHub: (() -> Void)?

    private(set) var connectedName: String?
    /// Anything at all touched this frame — for "press anything to begin", which has to mean it.
    private(set) var sawAnyInput = false

    init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
            let name = (note.object as? GCController)?.vendorName ?? "controller"
            NSLog("[gamepad] connected: %@", name)
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { _ in
            NSLog("[gamepad] disconnected")
        }
        GCController.startWirelessControllerDiscovery {}
    }

    /// True on the frame a button goes down.
    private func pressed(_ key: String, _ button: GCControllerButtonInput?) -> Bool {
        let now = button?.isPressed ?? false
        defer { wasPressed[key] = now }
        return now && !(wasPressed[key] ?? false)
    }

    private func dead(_ v: Float) -> Float {
        abs(v) < deadZone ? 0 : (v - (v > 0 ? deadZone : -deadZone)) / (1 - deadZone)
    }

    /// Drive one frame of input. Safe to call with no controller attached — it does nothing.
    func poll(_ gs: GameState, dt: Double, acceptsGameInput: Bool = true) {
        sawAnyInput = false
        guard let pad = GCController.current?.extendedGamepad else {
            // A disconnected controller must not leave the player walking forever.
            if connectedName != nil {
                // Clear only if the PAD was the one holding them — a controller going to sleep must
                // not stop a player who is walking with the keyboard.
                if padOwnsMovement { gs.forwardHeld = false; gs.backwardHeld = false; padOwnsMovement = false }
                connectedName = nil
            }
            return
        }
        if connectedName == nil {
            // The connect NOTIFICATION only says a device appeared; this says the extended profile
            // actually resolved, which is the part that has to be true for any of the mapping below
            // to run. Under the macOS sandbox a wireless pad needs the Bluetooth entitlement — without
            // it the notification never arrives at all and this line never prints.
            NSLog("[gamepad] active: %@ — sticks, shoulders and A/Y are live",
                  GCController.current?.vendorName ?? "controller")
        }
        connectedName = GCController.current?.vendorName ?? "controller"

        // ── movement: left stick or d-pad, whichever is further from rest ──────────────
        // (Read even when the game is not accepting input: the attract screen is listening for
        //  ANY of this, and only stops it from reaching the player.)
        let stickX = dead(pad.leftThumbstick.xAxis.value)
        let stickY = dead(pad.leftThumbstick.yAxis.value)
        let padX: Float = pad.dpad.right.isPressed ? 1 : (pad.dpad.left.isPressed ? -1 : 0)
        let padY: Float = pad.dpad.up.isPressed ? 1 : (pad.dpad.down.isPressed ? -1 : 0)
        let moveX = abs(padX) > abs(stickX) ? padX : stickX
        let moveY = abs(padY) > abs(stickY) ? padY : stickY

        // Held, not tapped: `update` chains hops for as long as the flag is set, exactly as the
        // keyboard's W/S do — which is precisely the problem, because BOTH write the same two flags.
        //
        // Writing them unconditionally every frame killed W/S outright (Eddie): the key sets
        // `forwardHeld = true`, and the next frame this poll — stick at rest, with a controller
        // merely PAIRED, not touched — sets it straight back to false. The keyboard never got a
        // single frame of movement.
        //
        // So the pad only speaks when it has something to say. It takes ownership while a stick or
        // d-pad is pushed, clears the flags ONCE on release, and then keeps its hands off. Two input
        // paths, one piece of state: whoever moved last wins, and neither silences the other.
        let lookX = dead(pad.rightThumbstick.xAxis.value)
        let lookY = dead(pad.rightThumbstick.yAxis.value)
        // Anything at all: a stick off centre, a d-pad, or any of the buttons we read.
        sawAnyInput = moveX != 0 || moveY != 0 || lookX != 0 || lookY != 0
            || pad.buttonA.isPressed || pad.buttonB.isPressed || pad.buttonX.isPressed
            || pad.buttonY.isPressed || pad.leftShoulder.isPressed || pad.rightShoulder.isPressed
            || (pad.buttonMenu.isPressed)

        guard acceptsGameInput else { return }
        let padForward = moveY > 0.5, padBack = moveY < -0.5
        if padForward || padBack || padOwnsMovement {
            gs.forwardHeld = padForward
            gs.backwardHeld = padBack
            padOwnsMovement = padForward || padBack
        }

        // ── turning: discrete, with hysteresis and a repeat ────────────────────────────
        turnCooldown = max(0, turnCooldown - dt)
        if abs(moveX) < turnOff { turnArmed = true }
        if abs(moveX) > turnOn, turnArmed || turnCooldown == 0 {
            if moveX > 0 { gs.player.tryTurnRight() } else { gs.player.tryTurnLeft() }
            turnArmed = false
            turnCooldown = turnRepeat
        }

        // ── look: right stick ─────────────────────────────────────────────────────────
        if gs.camera.mode == .firstPerson {
            gs.camera.lookYaw -= lookX * lookRate * Float(dt)
            gs.camera.lookPitch = max(-1.4, min(1.4, gs.camera.lookPitch + lookY * lookRate * Float(dt)))
        } else {
            gs.camera.orbitRotation.x += lookX * orbitRate * Float(dt)
            gs.camera.orbitRotation.y = max(-Float.pi / 2 + 0.01,
                                            min(Float.pi / 2 - 0.01,
                                                gs.camera.orbitRotation.y - lookY * orbitRate * Float(dt)))
        }

        // ── buttons ───────────────────────────────────────────────────────────────────
        if pressed("a", pad.buttonA) { gs.interact() }
        if pressed("y", pad.buttonY) { gs.camera.mode = gs.camera.mode == .orbit ? .firstPerson : .orbit }
        if pressed("menu", pad.buttonMenu) { onPortalHub?() }
        // THE TWIST. Shoulders rather than face buttons because it is the world moving, not the
        // player acting on a thing in front of them — and because L/R reads as "that way round".
        if pressed("l1", pad.leftShoulder)  { gs.startSliceRotation(clockwise: false) }
        if pressed("r1", pad.rightShoulder) { gs.startSliceRotation(clockwise: true) }
    }
}
