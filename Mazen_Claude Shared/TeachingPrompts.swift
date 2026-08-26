import Foundation
import Metal
import CoreGraphics
import CoreText

/// THE GAME'S FIRST WORDS.
///
/// Until now the prologue taught exactly one thing — Scene 4's vessel, which holds the anchors shut
/// until you have looked at it. Everything else the player has to already know: walk, turn, look,
/// interact, twist. The game simply put them in a world (Eddie, 2026-08-07: *"we really haven't
/// taught any interactions, simply dumped the player in a world"*).
///
/// Three rules, from that conversation:
///
///  1. **A prompt is dismissed by DOING the thing**, never by a timer. It stays until obeyed, so
///     nobody is ever stuck wondering — which matters most at a demo, where the player is a guest.
///  2. **It says what the player's own hands are holding.** The wording follows the live input:
///     "left stick" with a controller attached, "W and S" without, and it changes the moment they
///     pick the other one up.
///  3. **It is not dressed as an artifact of the world.** This is the game speaking. Pretending an
///     instruction is diegetic reads as neither instruction nor world.
///
/// Deliberately a general mechanism rather than three lines hard-coded into Scene 1: the ledger of
/// untaught verbs is long (interact, twist, the orbit view, walking across a face), and each will
/// want the same shape.
final class TeachingPrompts {

    enum Moment {
        case begin          // attract: any input starts the game
        case walk           // dismissed by actually moving
        case look           // dismissed by actually looking around
        case use            // dismissed by actually using something
    }

    /// The strip is rendered at the DRAWABLE's own width, so a glyph is drawn at the size it is
    /// displayed. The first version was a fixed 1024 stretched across the screen and looked like a
    /// VIC-20 (Eddie): magnified type is mush, and Ultra Light at wide tracking is the least
    /// survivable kind. Capped so a very wide display cannot allocate something silly.
    static let maxTextureWidth = 4096
    static let aspect: CGFloat = 8

    private(set) var current: Moment?

    /// Off for benchmarks, or they would measure the attract screen instead of the game — and the
    /// player would never "press anything" in a headless run. `MAZEN_PROMPTS=1` forces them back on
    /// so the render path can still be validated from a bench.
    init(enabled: Bool = true) {
        current = enabled ? .begin : nil
        taughtLook = !enabled
        taughtUse = !enabled
    }
    private(set) var opacity: Float = 0
    /// Set when the text changes, so the Renderer knows to re-render the strip.
    private(set) var textDirty = true
    private var shownText = ""

    /// Has the player looked around since the look prompt appeared? Compared against the camera's
    /// angles at the moment it was shown, so simply arriving does not count as looking.
    private var lookAnchor: (yaw: Float, pitch: Float)?
    /// Where the player started, to notice them leaving the opening room.
    private var spawn: (face: CubeFace, row: Int, col: Int)?

    /// True while the attract screen holds the game — the player has agency only after `begin`.
    var waitingToBegin: Bool { current == .begin }

    /// Called when the game actually starts, so the attract camera hands back to the player.
    var justBegan = false

    // MARK: - Wording

    /// `padAttached` decides which hands we are talking to. Lower case throughout: these are quiet
    /// words at the bottom of the screen, not a headline.
    func text(padAttached: Bool) -> String {
        switch current {
        case .begin: return "press anything to begin"
        case .walk:  return padAttached ? "left stick to walk" : "W and S to walk"
        case .look:  return padAttached ? "right stick to look around" : "move the mouse to look around"
        case .use:   return padAttached ? "A to use it" : "F to use it"
        case nil:    return ""
        }
    }

    // MARK: - Tick

    /// Advance the prompt state. Returns true if the strip needs re-rendering.
    @discardableResult
    func update(_ gs: GameState, padAttached: Bool, anyInput: Bool, dt: Float) -> Bool {
        // Fade in whatever is showing; fade out when nothing is.
        let target: Float = current == nil ? 0 : 1
        let rate: Float = target > opacity ? 1.6 : 2.6      // arrives gently, leaves briskly
        opacity += max(-rate * dt, min(rate * dt, target - opacity))

        switch current {
        case .begin:
            // Any input at all begins — a key, a button, a stick, a tap. Nothing else is listening
            // yet, which is what makes "press anything" true rather than a figure of speech.
            if anyInput {
                current = .walk
                justBegan = true
                spawn = (gs.player.face, gs.player.row, gs.player.col)
            }

        case .walk:
            // Moving, not merely holding: the flag goes up on the keypress, but the hop is the proof.
            if gs.player.isMoving || movedFromSpawn(gs) >= 1 { current = nil }

        case .look:
            if let a = lookAnchor,
               abs(gs.camera.lookYaw - a.yaw) > 0.35 || abs(gs.camera.lookPitch - a.pitch) > 0.25 {
                current = nil
            }

        case .use:
            if gs.hasInteracted { current = nil }

        case nil:
            // Out of the opening room and never told about looking? Say it once, here.
            if !taughtLook, spawn != nil, movedFromSpawn(gs) >= 3 {
                taughtLook = true
                current = .look
                lookAnchor = (gs.camera.lookYaw, gs.camera.lookPitch)
                break
            }
            // STANDING ON SOMETHING, AND NOBODY HAS EVER SAID HOW TO PRESS IT. Interact is the verb
            // with the most dependents — ten prop kinds — and the only one a player cannot guess.
            //
            // Held back until the player has come THROUGH a portal, which is Scene 2 by definition
            // (`lastArrivalOrigin` is nil in the world you boot into). That is deliberate rather
            // than incidental: Scene 1 is for moving and looking, and its vessels are scenery that
            // rewards curiosity — they should not be the game's first instruction. Scene 2 is where
            // something first REQUIRES pressing. No scene names in the rule; just "not the first
            // world you were put in".
            if !taughtUse, !gs.hasInteracted, gs.lastArrivalOrigin != nil, gs.hasInteractableHere {
                taughtUse = true
                current = .use
            }
        }

        let want = text(padAttached: padAttached)
        if want != shownText { shownText = want; textDirty = true }
        return textDirty
    }

    private var taughtLook = false
    private var taughtUse = false

    /// Chebyshev distance from where the player started, in tiles. Crude on purpose: it does not
    /// need to know what a "room" is, only that the player has got somewhere.
    private func movedFromSpawn(_ gs: GameState) -> Int {
        guard let s = spawn, s.face == gs.player.face else { return 99 }   // a face change is leaving
        return max(abs(gs.player.row - s.row), abs(gs.player.col - s.col))
    }

    func clearDirty() { textDirty = false }

    // MARK: - Rendering the strip

    /// Draw the current text into an RGBA texture. A light, wide-tracked face with a soft dark
    /// shadow so it stays legible over a bright sky or a dark ruin without a panel behind it.
    func makeTexture(device: MTLDevice, padAttached: Bool, drawableWidth: Int) -> MTLTexture? {
        let w = max(512, min(Self.maxTextureWidth, drawableWidth))
        let h = Int(CGFloat(w) / Self.aspect)
        let s = text(padAttached: padAttached)
        guard !s.isEmpty else { return nil }

        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)

        // MEDIUM, not ultra light. A hairline face over a bright sky at a distance is unreadable
        // before it is elegant; this is a line someone has to act on. Tracking eased off with it —
        // the two together were what fell apart.
        let size = CGFloat(h) * 0.40
        let font = CTFontCreateWithName("Avenir Next Medium" as CFString, size, nil)
        // CoreText's own keys rather than AppKit/UIKit's: this file compiles for both platforms and
        // `NSAttributedString.Key.font` is defined by whichever UI framework happens to be imported.
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 0.96),
            kCTKernAttributeName: Double(size * 0.045),
        ]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, s as CFString, attrs as CFDictionary)!)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let x = (CGFloat(w) - bounds.width) / 2 - bounds.origin.x
        let y = (CGFloat(h) - bounds.height) / 2 - bounds.origin.y

        // The shadow is what lets one colour of text work over both a noon sky and a night ruin.
        ctx.setShadow(offset: .zero, blur: size * 0.28,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.9))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
                                                            width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.label = "TeachingPrompt"
        px.withUnsafeBytes { buf in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: buf.baseAddress!, bytesPerRow: w * 4)
        }
        return tex
    }
}
