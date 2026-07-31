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
        static let portalClose = "portal.close"
        static let controlRaised = "control.raised"
        static let turnSlow = "turn.slow"
        static let turnFast = "turn.fast"
        // Phase C — SUSTAINED emitters. Looping, so they are a presence rather than an event.
        static let obeliskHum = "emitter.obelisk"
        static let portalHum  = "emitter.portal"
        static let vesselHum  = "emitter.vessel"
        /// Scene 3 — six obelisk voices, one per symbol. Audio Phase F.
        static func obeliskVoice(_ i: Int) -> String { "emitter.obelisk.\(i)" }
        // Phase E — the world's own bed.
        static let ambienceBed = "ambience.bed"
        /// An enclosed world's room tone — the outdoor bed is wind, which a sealed chamber has none of.
        static let chamberBed = "ambience.chamber"
        // Scene 1B/1G — the two layers the opening is built on.
        static let birds = "ambience.birds"
        static let underTone = "ambience.undertone"
    }

    /// A world unit is ~18.9 m (WorldScale: eyeHeight 0.09u == 1.7 m). PHASE reasons in metres, so
    /// positions are converted on the way in — otherwise the whole world would sit inside a couple of
    /// metres and distance attenuation would do nothing.
    private static let metresPerUnit: Float = 18.89

    /// Spatial mixer shared by every positioned event, kept so sound events can be bound to it.
    private var spatialMixer: PHASESpatialMixerDefinition?
    /// One-shot sources are retained until their event completes, then released.
    private var liveSources: [ObjectIdentifier: PHASESource] = [:]
    /// Which registered assets live on the SPATIAL mixer. A spatial asset cannot be started without
    /// source/listener binding — it throws — so a cue that omits a position must still be given one.
    /// Tracking this here means registration and call sites can never silently disagree, which they
    /// did: the refused-twist strain was registered spatial but always fired positionless, so it
    /// never sounded at all (Eddie: "I see strain/spring back but no audio").
    private var spatialAssets: Set<String> = []
    /// Last listener position, so a positionless spatial sound can be played AT the player.
    private var listenerPosition = SIMD3<Float>(0, 0, 0)

    /// Phase C — one live looping event per emitter id. Keyed by the model's stable facelet id, so a
    /// source that MOVES under a twist is repositioned rather than stopped and restarted; restarting
    /// a loop every frame is a stutter, not a sound.
    private var emitterEvents: [Int: (event: PHASESoundEvent, source: PHASESource)] = [:]
    /// Phase E — the current ambience bed, and which world it belongs to.
    private var ambienceEvent: PHASESoundEvent?
    private var ambienceWorld: String?
    /// Which sounds have already reported a failure. A broken sound fires on every keypress, so
    /// without this one mistake buries the console — the spatial-mixer bug produced dozens of
    /// identical lines and made the genuinely interesting logs hard to find (Eddie).
    private var reportedFailures: Set<String> = []

    private func reportOnce(_ identifier: String, _ error: Error) {
        guard reportedFailures.insert(identifier).inserted else { return }
        NSLog("[audio] could not start %@ (further failures for this sound are suppressed): %@",
              identifier, String(describing: error))
    }

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
            // The way back closing (Scene 2A): the portal-open tone INVERTED — descending, and
            // landing lower than it began, so it folds inward and resolves shut. The relationship is
            // the point: the same voice saying the opposite thing.
            try registerTone(identifier: EventID.portalClose, frequency: 147, duration: 2.2,
                             harmonics: [1.0, 0.6, 0.4, 0.25], spatial: true, sweepTo: 58)

            // Phase C — sustained emitter voices. An awakened obelisk hums; an open portal holds the
            // "low, stable tone" the scripts describe. Both loop, both are spatial, and both are
            // deliberately quiet: they are landmarks you notice when you stop, not an alarm.
            try registerTone(identifier: EventID.obeliskHum, frequency: 174, duration: 2.0,
                             harmonics: [1.0, 0.3, 0.14], spatial: true, sustain: true, looping: true)
            try registerTone(identifier: EventID.portalHum, frequency: 98, duration: 2.4,
                             harmonics: [1.0, 0.5, 0.22, 0.1], spatial: true, sustain: true, looping: true)
            // Scene 1E — a vessel's "barely audible tone". A perfect fifth above the undertone, so
            // it is unmistakably the same voice; almost nothing but the fundamental, so it carries
            // no character to identify it by.
            try registerTone(identifier: EventID.vesselHum, frequency: 73.5, duration: 3.1,
                             harmonics: [1.0, 0.12], spatial: true, sustain: true, looping: true)
            // Audio F — SCENE 3's SIX KIN TONES. "Six obelisks whose tones are distinguishable but
            // obviously kin — that's a harmonic series, trivially generated, painful to source"
            // (the audio plan, and the reason this engine synthesises rather than samples).
            //
            // A harmonic series on a low fundamental: every voice is literally a multiple of the
            // same note, so they are related by construction rather than by taste, and six of them
            // sounding at once are consonant no matter which order the player wakes them in. The
            // partial weights thin as the series climbs, so the high ones stay slender rather than
            // shrill.
            for i in 0..<6 {
                let fundamental: Float = 55                 // A1 — under everything
                let voice = fundamental * Float(i + 2)      // 2f, 3f, 4f, 5f, 6f, 7f
                try registerTone(identifier: EventID.obeliskVoice(i), frequency: voice, duration: 2.6,
                                 harmonics: [1.0, 0.34 / Float(i + 1), 0.14 / Float(i + 1)],
                                 spatial: true, sustain: true, looping: true)
            }

            // Phase E — the world's bed: broadband, slow-moving, non-spatial. Not a tune, a room.
            try registerBed(identifier: EventID.ambienceBed, seconds: 6)
            // Scene 3 — "music: low harmonic texture, initially almost inaudible". A sealed metal
            // chamber has no wind, and it was playing the outdoor bed: the loop is broadband noise,
            // which is weather, and there is no weather in here. This is a room tone instead — three
            // partials of the same 55 Hz fundamental the obelisks sing, beating slowly against each
            // other, so the chamber hums in the key its own objects answer in.
            try registerTone(identifier: EventID.chamberBed, frequency: 55, duration: 9,
                             harmonics: [1.0, 0.30, 0.16, 0.07], sustain: true, looping: true)
            // "Distant birds, sparse and difficult to locate." Sparse is the point — a dense loop
            // would place them, and the script wants them unplaceable.
            try registerBirds(identifier: EventID.birds, seconds: 11)
            // "After the player first moves, a low tonal layer enters almost below conscious notice."
            // It is the Builders, and it is the same voice the vessels and the portal speak in — so
            // it is a held chord on the portal tone's fundamental rather than a new instrument.
            try registerTone(identifier: EventID.underTone, frequency: 49, duration: 8,
                             harmonics: [1.0, 0.62, 0.30, 0.16, 0.09], sustain: true, looping: true)

            try engine.start()
            ready = true
            if verboseDebugLog { NSLog("[audio] PHASE engine started") }
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
        listenerPosition = position * Self.metresPerUnit
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
            reportOnce(EventID.testTone, error)
        }
    }

    /// Play everything the world queued this frame.
    ///
    /// `worldSpin` is the world's slow idle rotation. Cue positions arrive in UNSPUN world space (the
    /// model does not know about presentation), but the listener is placed in SPUN space — the first
    /// person pose is built with the spin folded in, and in orbit the world turns beneath a fixed
    /// camera. Leaving it out drifts every sound away from its object as the world turns, and at the
    /// half-cycle puts it exactly 180° out: sounds on the left arrive from the right (Eddie).
    func play(cues: [AudioCue], worldSpin: float4x4) {
        guard ready else { return }
        func spun(_ p: SIMD3<Float>?) -> SIMD3<Float>? {
            guard let p else { return nil }
            let v = worldSpin * SIMD4(p.x, p.y, p.z, 1)
            return SIMD3(v.x, v.y, v.z)
        }
        for cue in cues {
            switch cue {
            case .twistStrain:                 fire(EventID.twistStrain, at: nil)
            case .controlRaised:               fire(EventID.controlRaised, at: nil)
            case .twistTurning(let p, let slow): fire(slow ? EventID.turnSlow : EventID.turnFast, at: spun(p))
            case .twistLocked(let p):          fire(EventID.twistLocked, at: spun(p))
            case .switchEngaged(let p):        fire(EventID.switchUp, at: spun(p))
            case .switchDisengaged(let p):     fire(EventID.switchDown, at: spun(p))
            case .portalOpened(let p):         fire(EventID.portalOpen, at: spun(p))
            case .portalClosed(let p):         fire(EventID.portalClose, at: spun(p))
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
            // A spatial asset MUST be bound to a source, so one without a position is placed at the
            // listener — heard as happening here, which is exactly what "no position" means (the
            // world straining around you; a plate under your hand).
            let needsSource = spatialAssets.contains(identifier)
            if needsSource, let sm = spatialMixer {
                let src = PHASESource(engine: engine)
                let m = position.map { $0 * Self.metresPerUnit } ?? listenerPosition
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
            reportOnce(identifier, error)
        }
    }

    // MARK: - Sustained emitters (Phase C) and occlusion (Phase D)

    /// Reconcile the live loops against what the world says is sounding right now.
    ///
    /// The model republishes every emitter every frame from live topology, so this is a diff: start
    /// what is new, MOVE what persists, stop what has gone. Moving rather than restarting is the
    /// whole point — an emitter riding a twist must keep sounding while its position changes.
    ///
    /// Occlusion (Phase D) is applied by pushing the source further away along the listener→source
    /// direction. PHASE offers no per-event gain here, and distance is what the spatial mixer already
    /// understands; more walls really does mean less energy arriving. It is an ATTENUATION model, not
    /// a filter — a muffled sound gets quieter but not duller. Honest about what it is.
    func updateEmitters(_ emitters: [AudioEmitter], worldSpin: float4x4) {
        guard ready, let sm = spatialMixer else { return }
        var seen = Set<Int>()
        for e in emitters {
            seen.insert(e.id)
            let v = worldSpin * SIMD4(e.position.x, e.position.y, e.position.z, 1)
            var world = SIMD3(v.x, v.y, v.z) * Self.metresPerUnit
            if e.occlusion > 0 {
                // Push away from the listener: up to ~3× the distance when fully walled off.
                let away = world - listenerPosition
                world = listenerPosition + away * (1 + 2.0 * e.occlusion)
            }
            if let live = emitterEvents[e.id] {
                live.source.transform = Self.transform(at: world)
                continue
            }
            do {
                let src = PHASESource(engine: engine)
                src.transform = Self.transform(at: world)
                try engine.rootObject.addChild(src)
                let id: String
                switch e.kind {
                // A voiced obelisk (Scene 3) sings its own note; an ordinary one hums.
                case .obelisk: id = e.voice >= 0 ? EventID.obeliskVoice(min(5, e.voice)) : EventID.obeliskHum
                case .portal:  id = EventID.portalHum
                case .vessel:  id = EventID.vesselHum
                }
                let mixerParams = PHASEMixerParameters()
                mixerParams.addSpatialMixerParameters(identifier: sm.identifier, source: src, listener: listener)
                let event = try PHASESoundEvent(engine: engine, assetIdentifier: id, mixerParameters: mixerParams)
                event.start()
                emitterEvents[e.id] = (event, src)
            } catch {
                reportOnce("emitter", error)
            }
        }
        for (id, live) in emitterEvents where !seen.contains(id) {
            live.event.stopAndInvalidate()
            live.source.parent?.removeChild(live.source)
            emitterEvents.removeValue(forKey: id)
        }
    }

    private static func transform(at p: SIMD3<Float>) -> simd_float4x4 {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4(p.x, p.y, p.z, 1)
        return t
    }

    // MARK: - Ambience (Phase E)

    private var birdsEvent: PHASESoundEvent?
    private var underToneEvent: PHASESoundEvent?

    /// Scene 1's two extra layers, each switched independently of the wind bed.
    ///
    /// `birds` go quiet as the player nears the arch — "the ambient birds fall silent" — which is
    /// the scene's only warning that the corridor ahead is not another corridor. `underTone` starts
    /// once the player has moved and never stops: it is "almost below conscious notice" at first and
    /// merely becomes audible later, so it is a level change, not an entrance.
    func setAmbienceLayers(birds: Bool, underTone: Bool) {
        guard ready else { return }
        if birds && birdsEvent == nil {
            birdsEvent = try? PHASESoundEvent(engine: engine, assetIdentifier: EventID.birds)
            birdsEvent?.start()
        } else if !birds, let e = birdsEvent {
            e.stopAndInvalidate(); birdsEvent = nil
        }
        if underTone && underToneEvent == nil {
            underToneEvent = try? PHASESoundEvent(engine: engine, assetIdentifier: EventID.underTone)
            underToneEvent?.start()
        } else if !underTone, let e = underToneEvent {
            e.stopAndInvalidate(); underToneEvent = nil
        }
    }

    /// Give each world its own bed, and let a portal land in SILENCE before it returns.
    ///
    /// Scene 2's script is precise about this: you step through and the world is quiet, then the wind
    /// comes back. Arrival silence is the cheapest possible way to make a world feel like a different
    /// place, and it costs nothing but restraint. Passing nil stops the bed; passing a new world name
    /// restarts it, which the Renderer delays so the silence is real.
    func setAmbience(world: String?, enclosed: Bool = false) {
        guard ready else { return }
        if world == ambienceWorld { return }
        ambienceWorld = world
        ambienceEvent?.stopAndInvalidate()
        ambienceEvent = nil
        guard world != nil else {
            // Leaving a world takes its layers with it, or Scene 1's birds follow you to the moon.
            setAmbienceLayers(birds: false, underTone: false)
            return
        }
        do {
            let event = try PHASESoundEvent(engine: engine,
                                            assetIdentifier: enclosed ? EventID.chamberBed : EventID.ambienceBed)
            event.start()
            ambienceEvent = event
        } catch {
            reportOnce(EventID.ambienceBed, error)
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
                              sweepTo: Float? = nil, transient: Float = 0, sustain: Bool = false,
                              looping: Bool = false) throws {
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
            spatialAssets.insert(identifier)
        } else {
            // Non-spatial: the Phase A bring-up tone, and anything that happens AT the player.
            mixer = PHASEChannelMixerDefinition(channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Mono)!)
        }
        let sampler = PHASESamplerNodeDefinition(
            soundAssetIdentifier: identifier + ".asset",
            mixerDefinition: mixer)
        sampler.playbackMode = looping ? .looping : .oneShot
        sampler.setCalibrationMode(calibrationMode: .relativeSpl, level: 0)
        try engine.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: identifier)
    }

    /// Phase E — a seamless ambience bed: broadband noise, slowly filtered and swelling, with the
    /// tail crossfaded into the head so a loop point cannot be heard. Not a tune and not a drone
    /// with a pitch — a world with weather in it. Non-spatial, because it is everywhere.
    private func registerBed(identifier: String, seconds: Float) throws {
        let sampleRate = 48_000.0
        let frames = Int(Double(seconds) * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "audio", code: 1)
        }
        var samples = [Float](repeating: 0, count: frames)
        // Deterministic noise — the bed should be identical every launch, so a change in the mix is
        // always a change someone MADE.
        var rng: UInt32 = 0x9E3779B9
        var lp: Float = 0, lp2: Float = 0
        for i in 0..<frames {
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
            let white = Float(rng & 0xFFFF) / 32767.5 - 1.0
            lp += (white - lp) * 0.04          // two poles of lowpass: wind, not hiss
            lp2 += (lp - lp2) * 0.09
            let t = Float(i) / Float(sampleRate)
            // Two slow swells at unrelated rates, so the bed never settles into a pulse.
            let swell = 0.55 + 0.30 * sinf(t * 0.21) + 0.15 * sinf(t * 0.073 + 1.3)
            samples[i] = lp2 * swell * 0.30
        }
        // Crossfade the last quarter-second into the first, so the loop seam is inaudible.
        let fade = min(frames / 4, Int(0.25 * sampleRate))
        for i in 0..<fade {
            let a = Float(i) / Float(fade)
            samples[i] = samples[i] * a + samples[frames - fade + i] * (1 - a)
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try engine.assetRegistry.registerSoundAsset(
            data: data, identifier: identifier + ".asset", format: format, normalizationMode: .none)
        let mixer = PHASEChannelMixerDefinition(
            channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Mono)!)
        let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: identifier + ".asset",
                                                 mixerDefinition: mixer)
        sampler.playbackMode = .looping
        sampler.setCalibrationMode(calibrationMode: .relativeSpl, level: -12)   // a bed, not a voice
        try engine.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: identifier)
    }

    /// Sparse, hard-to-place birdcalls over a long loop. Each call is a short pair of FM chirps at a
    /// randomised pitch, scattered thinly enough that you never quite catch where one came from —
    /// "distant birds, sparse and difficult to locate". Non-spatial, because a bird you could point
    /// at would be a bird that was somewhere, and these are meant to be everywhere and nowhere.
    private func registerBirds(identifier: String, seconds: Float) throws {
        let sampleRate = 48_000.0
        let frames = Int(Double(seconds) * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "audio", code: 1)
        }
        var samples = [Float](repeating: 0, count: frames)
        var rng: UInt32 = 0xB1D5_0007
        func next() -> UInt32 { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng }
        let calls = 14
        for _ in 0..<calls {
            let start = Int(next() % UInt32(max(1, frames - Int(sampleRate))))
            let base = 1800 + Float(next() % 1400)          // 1.8–3.2 kHz: small birds, far off
            let notes = 2 + Int(next() % 2)
            var cursor = start
            for _ in 0..<notes {
                let len = Int(0.05 * sampleRate) + Int(next() % UInt32(0.05 * sampleRate))
                let bend = 1.0 + (Float(next() % 100) / 100.0 - 0.5) * 0.35
                for i in 0..<len where cursor + i < frames {
                    let u = Float(i) / Float(len)
                    let f = base * (1 + (bend - 1) * u)
                    let env = sinf(u * .pi)                 // no click either end
                    samples[cursor + i] += sinf(2 * .pi * f * Float(i) / Float(sampleRate)) * env * 0.05
                }
                cursor += len + Int(0.04 * sampleRate) + Int(next() % UInt32(0.05 * sampleRate))
            }
        }
        // Crossfade the seam, same as the wind bed.
        let fade = min(frames / 4, Int(0.4 * sampleRate))
        for i in 0..<fade {
            let a = Float(i) / Float(fade)
            samples[i] = samples[i] * a + samples[frames - fade + i] * (1 - a)
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try engine.assetRegistry.registerSoundAsset(
            data: data, identifier: identifier + ".asset", format: format, normalizationMode: .none)
        let mixer = PHASEChannelMixerDefinition(
            channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Mono)!)
        let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: identifier + ".asset",
                                                 mixerDefinition: mixer)
        sampler.playbackMode = .looping
        sampler.setCalibrationMode(calibrationMode: .relativeSpl, level: -16)
        try engine.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: identifier)
    }
}
