import simd

/// Sun and moon orbiting the (stationary) game cube — the M9 "cube solar system".
///
/// The game world is the fixed reference frame at the origin; the sun and moon trace
/// apparent orbits around it. Only pure math lives here (positions/directions from
/// `time`); the renderer turns `sunDirection` into the shadow-casting light and draws
/// the two cube bodies at `sunPosition`/`moonPosition`.
///
/// Distances are fixed (comfortably inside `WorldScale.cameraFarZ = 100`) rather than
/// size-derived: the cube is always small relative to a ~60-unit sun, so the same orbit
/// reads well across cube sizes 3…9 — only the cube's apparent size changes.
struct CelestialSystem {
    // MARK: Tunables
    /// Seconds for a full day. The plan's "real" value is 300; 90 keeps the shadow sweep
    /// visible without being dizzying. Tune up for play, down for testing.
    // ~8-minute day; the moon's period is slightly longer, roughly matching Earth's ratios.
    var sunPeriod: Float = 480
    var moonPeriod: Float = 546
    /// Sun orbit tilt: the plane is spanned by X and an "up" axis leaned `sunTilt` off Y
    /// toward +Z, so the sun rises at +X, passes near overhead, sets at −X, and dips below
    /// at night (a real day/night arc, not a low horizon circle).
    var sunTilt: Float = 23 * .pi / 180
    /// Start the day at high noon (sun overhead) for a bright first impression.
    var sunPhaseOffset: Float = .pi / 2
    /// Moon leans the opposite way (distinct plane → the two cross only occasionally, for
    /// the odd eclipse) and starts half a lap offset so it's usually opposite the sun.
    var moonTilt: Float = -34 * .pi / 180
    var moonPhaseOffset: Float = .pi

    // M9.5-4: distances chosen for apparent size (= size / distance). The sun sits twice as
    // far as before (perceived ~2× more distant), and the moon is pushed out until its
    // apparent size matches the sun's (the Earth eclipse coincidence): moonDist =
    // moonSize · sunDist/sunSize = 3.4 · 176/11 = 54.4. Sun's far point (176 + 5.5) fits
    // inside the bumped WorldScale.cameraFarZ (220).
    var sunOrbitRadius: Float = 176
    var moonOrbitRadius: Float = 54.4
    var sunSize: Float = 11
    var moonSize: Float = 3.4

    // MARK: Positions
    func sunPosition(time: Float) -> SIMD3<Float> {
        let a = time / sunPeriod * 2 * .pi + sunPhaseOffset
        let u = SIMD3<Float>(1, 0, 0)
        let w = SIMD3<Float>(0, cosf(sunTilt), sinf(sunTilt))
        return sunOrbitRadius * (cosf(a) * u + sinf(a) * w)
    }

    func moonPosition(time: Float) -> SIMD3<Float> {
        let a = time / moonPeriod * 2 * .pi + moonPhaseOffset
        let u = SIMD3<Float>(1, 0, 0)
        let w = SIMD3<Float>(0, cosf(moonTilt), sinf(moonTilt))
        return moonOrbitRadius * (cosf(a) * u + sinf(a) * w)
    }

    // MARK: Directions (normalized; for lighting)
    func sunDirection(time: Float) -> SIMD3<Float> { normalize(sunPosition(time: time)) }
    func moonDirection(time: Float) -> SIMD3<Float> { normalize(moonPosition(time: time)) }

    /// dot(sunDir, up) — positive = day, negative = night. Drives the M9-4 day/night blend.
    func sunElevation(time: Float) -> Float { sunDirection(time: time).y }
}
