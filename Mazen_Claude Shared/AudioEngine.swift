import Foundation
import AVFoundation
import PHASE
import simd

/// Audio Phase A — the foundation (see `Mazen Docs/Audio Plan — PHASE.md`).
///
/// Boots Apple's Physical Audio Spatialization Engine, keeps its listener glued to the camera, and
/// plays one synthesised tone so the whole path can be proven end to end before any game event
/// depends on it.
///
/// **Why PHASE at all.** The prologue forbids interface overlays, so "where do I look now?" is
/// carried almost entirely by sound, and nearly every audio beat in the scripts is about something
/// the player *cannot see*: "a low tone sounds from elsewhere on the world", "a deep mechanical latch
/// somewhere beyond the visible maze", "the tone repeats from the direction of the matching obelisk".
/// Those only work if the sound genuinely arrives from that direction.
///
/// **Why the tones are synthesised.** What the scripts ask for is tonal, not foley — "a clear tone",
/// "a low incomplete tone", "the tone plays in reverse", six obelisk tones that are distinguishable
/// but obviously kin. Generating them makes those relationships authorable (a harmonic series rather
/// than six sourced files), needs no asset pipeline or licensing, and suits Builders who speak in
/// geometry. Recorded assets stay the right answer for wind, rubble and the mechanical latch.
///
/// **Deliberately not referenced by the model layer.** `GameState` and friends compile into the
/// headless test harness, which has no audio; nothing in this file may be reached from there. The
/// Renderer owns the engine and drives the listener.
final class AudioEngine {

    private let engine: PHASEEngine
    private let listener: PHASEListener
    private var ready = false

    /// Sound-event identifiers registered at boot.
    private enum EventID {
        static let testTone = "test.tone"
        static let twistStrain = "twist.strain"
        static let twistLocked = "twist.locked"
        static let switchUp = "switch.up"
        static let switchDown = "switch.down"
        static let portalOpen = "portal.open"
        static let controlRaised = "control.raised"
        static let turnSlow = "turn.slow"
        static let turnFast = "turn.fast"
    }

    /// A world unit is ~18.9 m (WorldScale: eyeHeight 0.09u == 1.7 m). PHASE reasons in metres, so
    /// positions are converted on the way in — otherwise the whole world would sit inside a couple of
    /// metres and distance attenuation would do nothing.
    private static let metresPerUnit: Float = 18.89

    /// Spatial mixer shared by every positioned event, kept so sound events can be bound to it.
    private var spatialMixer: PHASESpatialMixerDefinition?
    /// One-shot sources are retained until their event completes, then released.
    private var liveSources: [ObjectIdentifier: PHASESource] = [:]

    init?() {
        engine = PHASEEngine(updateMode: .automatic)
        do {
            listener = PHASEListener(engine: engine)
            listener.transform = matrix_identity_float4x4
            try engine.rootObject.addChild(listener)

            // A spatial mixer for everything that comes from somewhere.
            guard let pipeline = PHASESpatialPipeline(flags: [.directPathTransmission]) else {
                throw NSError(domain: "audio", code: 2)
            }
            let sMixer = PHASESpatialMixerDefinition(spatialPipeline: pipeline)
            let distance = PHASEGeometricSpreadingDistanceModelParameters()
            distance.rolloffFactor = 0.7          // gentler than inverse-square: a big world stays audible
            sMixer.distanceModelParameters = distance
            spatialMixer = sMixer

            try registerTone(identifier: EventID.testTone,
                             frequency: 220, duration: 0.9, harmonics: [1.0, 0.5, 0.25])

            // The twist's voice (Scene 2/4). Related timbres, deliberately: the world has one
            // mechanical language, and these are all it saying different words in it.
            //  • strain — low, rough, unresolved: a thing refusing to move.
            //  • locked — the deepest, with a long tail: the sound the scripts call "a deep locking".
            //  • switch up / down — the same short tone, the second an octave below, so disengaging
            //    reads as the first "played in reverse" (Scene 2E) without needing a second asset.
            //  • portal open — higher and sustained: "a low, stable tone".
            try registerTone(identifier: EventID.twistStrain, frequency: 62, duration: 1.1,
                             harmonics: [1.0, 0.8, 0.7, 0.5, 0.35], spatial: true, rough: 0.5)
            try registerTone(identifier: EventID.twistLocked, frequency: 48, duration: 1.9,
                             harmonics: [1.0, 0.55, 0.3, 0.18], spatial: true, transient: 0.5)

            // The control rising: an ASCENDING sweep, deliberately stopping short of resolving. It
            // should read as a question — something is about to move — not as a completion.
            try registerTone(identifier: EventID.controlRaised, frequency: 130, duration: 1.0,
                             harmonics: [1.0, 0.4, 0.22], sweepTo: 300)
            // The turn itself: low, rough and SUSTAINED for the length of the motion, so a slab in
            // flight is audible the whole way round. Two lengths, matching the scripted (~1.4 s) and
            // the player's own faster (~0.4 s) turns.
            try registerTone(identifier: EventID.turnSlow, frequency: 72, duration: 1.45,
                             harmonics: [1.0, 0.7, 0.45, 0.3], spatial: true, rough: 0.55,
                             sweepTo: 58, sustain: true)
            try registerTone(identifier: EventID.turnFast, frequency: 80, duration: 0.45,
                             harmonics: [1.0, 0.7, 0.45, 0.3], spatial: true, rough: 0.55,
                             sweepTo: 64, sustain: true)
            try registerTone(identifier: EventID.switchUp, frequency: 392, duration: 0.55,
                             harmonics: [1.0, 0.35, 0.12], spatial: true)
            try registerTone(identifier: EventID.switchDown, frequency: 196, duration: 0.55,
                             harmonics: [1.0, 0.35, 0.12], spatial: true)
            try registerTone(identifier: EventID.portalOpen, frequency: 147, duration: 2.4,
                             harmonics: [1.0, 0.6, 0.4, 0.25], spatial: true)

            try engine.start()
            ready = true
            NSLog("[audio] PHASE engine started")
        } catch {
            NSLog("[audio] PHASE failed to start: %@", String(describing: error))
            return nil
        }
    }

    // MARK: - Listener

    /// Keep the listener where the camera is, oriented the way the camera looks.
    ///
    /// This is the part unique to a cube world, and the likeliest place for subtle wrongness: the
    /// player's own frame rotates TWICE over — once when they cross a face boundary (what was the
    /// floor becomes a wall behind them) and again while riding a slab through a twist. Both come
    /// from the same `FramePose` the renderer uses, so sound and image cannot disagree.
    func updateListener(position: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) {
        guard ready else { return }
        let f = simd_normalize(forward)
        // Re-orthogonalise: `up` is the surface normal and `forward` the look direction, and after a
        // twist they are not exactly perpendicular.
        var u = simd_normalize(up)
        let right = simd_normalize(simd_cross(f, u))
        u = simd_cross(right, f)
        // PHASE (like Metal) is right-handed with -Z forward, so the basis is (right, up, -forward).
        listener.transform = float4x4(columns: (
            SIMD4(right.x, right.y, right.z, 0),
            SIMD4(u.x,     u.y,     u.z,     0),
            SIMD4(-f.x,    -f.y,    -f.z,    0),
            SIMD4(position.x, position.y, position.z, 1)
        ))
    }

    // MARK: - Playback

    /// Fire the Phase A test tone (non-spatial — Phase B onward gives events a position).
    func playTestTone() {
        guard ready else { return }
        do {
            let event = try PHASESoundEvent(engine: engine, assetIdentifier: EventID.testTone)
            event.start()
        } catch {
            NSLog("[audio] could not start test tone: %@", String(describing: error))
        }
    }

    /// Play everything the world queued this frame.
    func play(cues: [AudioCue]) {
        guard ready else { return }
        for cue in cues {
            switch cue {
            case .twistStrain:                 fire(EventID.twistStrain, at: nil)
            case .controlRaised:               fire(EventID.controlRaised, at: nil)
            case .twistTurning(let p, let slow): fire(slow ? EventID.turnSlow : EventID.turnFast, at: p)
            case .twistLocked(let p):          fire(EventID.twistLocked, at: p)
            case .switchEngaged(let p):        fire(EventID.switchUp, at: p)
            case .switchDisengaged(let p):     fire(EventID.switchDown, at: p)
            case .portalOpened(let p):         fire(EventID.portalOpen, at: p)
            }
        }
    }

    /// Start a one-shot, positioned if the cue said where it happened.
    ///
    /// A positioned event needs its own `PHASESource` in the scene graph, retained until playback
    /// finishes — otherwise it is torn down mid-sound. The completion handler releases it.
    private func fire(_ identifier: String, at position: SIMD3<Float>?) {
        do {
            var params: PHASEMixerParameters? = nil
            var source: PHASESource? = nil
            if let p = position, let sm = spatialMixer {
                let src = PHASESource(engine: engine)
                let m = p * Self.metresPerUnit
                var t = matrix_identity_float4x4
                t.columns.3 = SIMD4(m.x, m.y, m.z, 1)
                src.transform = t
                try engine.rootObject.addChild(src)
                let mp = PHASEMixerParameters()
                mp.addSpatialMixerParameters(identifier: sm.identifier, source: src, listener: listener)
                params = mp
                source = src
            }
            let event = params != nil
                ? try PHASESoundEvent(engine: engine, assetIdentifier: identifier, mixerParameters: params!)
                : try PHASESoundEvent(engine: engine, assetIdentifier: identifier)
            if let src = source {
                let key = ObjectIdentifier(event)
                liveSources[key] = src
                event.start { [weak self] _ in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        if let s = self.liveSources.removeValue(forKey: key) { s.parent?.removeChild(s) }
                    }
                }
            } else {
                event.start()
            }
        } catch {
            NSLog("[audio] could not start %@: %@", identifier, String(describing: error))
        }
    }

    // MARK: - Synthesis

    /// Build one tone as raw PCM and register it as a PHASE sound asset.
    ///
    /// `harmonics` are amplitudes for successive partials (1×, 2×, 3× the fundamental), which is how
    /// a family of related-but-distinguishable tones gets authored later: same envelope, different
    /// partial weights. The envelope is a short attack and a long exponential decay — a struck
    /// resonator rather than a beep.
    private func registerTone(identifier: String, frequency: Float, duration: Float,
                              harmonics: [Float], spatial: Bool = false, rough: Float = 0,
                              sweepTo: Float? = nil, transient: Float = 0, sustain: Bool = false) throws {
        let sampleRate = 48_000.0
        let frames = Int(Double(duration) * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "audio", code: 1)
        }

        var samples = [Float](repeating: 0, count: frames)
        let norm = max(0.0001, harmonics.reduce(0, +))
        // A swept tone needs phase accumulated over a CHANGING frequency; computing sin(2πft) with a
        // moving f would jump the phase every sample and buzz.
        var phase: Float = 0
        for i in 0..<frames {
            let t = Float(i) / Float(sampleRate)
            let u = Float(i) / Float(max(1, frames - 1))
            let f = sweepTo.map { frequency + ($0 - frequency) * u } ?? frequency
            phase += 2 * .pi * f / Float(sampleRate)
            var s: Float = 0
            for (h, amp) in harmonics.enumerated() {
                s += amp * sinf(phase * Float(h + 1))
            }
            s /= norm
            // `rough` detunes a shadow copy against the fundamental, producing beating — the sound
            // of something under load rather than a clean resonance. Used only by the strain.
            if rough > 0 { s += rough * sinf(2 * .pi * frequency * 1.031 * t) }
            // A short bright TRANSIENT on top of a deep body. Without it a 48 Hz lock is inaudible on
            // laptop speakers and buried under anything else playing at the same moment (Eddie: heard
            // the lock alone, but not when the portal opened over it).
            if transient > 0 {
                s += transient * sinf(2 * .pi * 900 * t) * expf(-t * 55)
                s += transient * 0.6 * sinf(2 * .pi * 1570 * t) * expf(-t * 80)
            }
            let attack = min(1, t / 0.012)                      // ~12 ms, no click
            // `sustain` holds the body up and releases at the end — for sounds that accompany a
            // MOTION and must last as long as it does, rather than decaying away under it.
            let decay = sustain
                ? min(1, (1 - u) / 0.18)
                : expf(-t * (3.2 / max(0.05, duration)))
            samples[i] = s * attack * decay * 0.65
        }

        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try engine.assetRegistry.registerSoundAsset(
            data: data, identifier: identifier + ".asset",
            format: format, normalizationMode: .none)

        let mixer: PHASEMixerDefinition
        if spatial, let sm = spatialMixer {
            mixer = sm
        } else {
            // Non-spatial: the Phase A bring-up tone, and anything that happens AT the player.
            mixer = PHASEChannelMixerDefinition(channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Mono)!)
        }
        let sampler = PHASESamplerNodeDefinition(
            soundAssetIdentifier: identifier + ".asset",
            mixerDefinition: mixer)
        sampler.playbackMode = .oneShot
        sampler.setCalibrationMode(calibrationMode: .relativeSpl, level: 0)
        try engine.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: identifier)
    }
}
