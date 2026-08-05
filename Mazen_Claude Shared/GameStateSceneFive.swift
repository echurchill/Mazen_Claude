import Foundation
import simd

/// Refactor #4 — Scene 5's simulation, out of the 1,900-line GameState core: the circuit tick,
/// the memoized reach, the travelling pulse and its diagnostic, the 5J bloom, and the surveyor.
/// Methods moved verbatim; the stored properties they drive stay declared on the class in
/// GameState.swift (extensions cannot hold storage), with access relaxed only where this file
/// boundary forces it.
extension GameState {
    /// Scene 5 — receivers follow the current, moment to moment, and the way out appears when all
    /// three hold at once. Ticked rather than event-driven because a twist can UNFEED a receiver as
    /// easily as feed one, and the scene depends on the player seeing that happen.
    func tickChannelCircuit(_ dt: Float) {
        guard !cubeModel.channelReceivers.isEmpty else { return }
        let fed = channelReach
        var changed = false
        // 5D's THREE STATES, not two — "temporary success is deliberately different from lasting
        // success" is a scene pillar, and it used to be invisible: a receiver was lit or dark.
        //   dark 0        the current does not reach it
        //   filling 0.55  fed right now, but the circuit as a whole is broken — the bowl holds
        //                 light while the pulse feeds it and loses it when the pulse withdraws
        //   locked 1.0    part of the live circuit; full, steady, and it hums
        let locked = liveCircuit
        for cu in cubeModel.cubies.indices {
            for f in cubeModel.cubies[cu].facelets.indices {
                let id = cubeModel.cubies[cu].facelets[f].id.rawValue
                for pi in cubeModel.cubies[cu].facelets[f].props.indices {
                    let kind = cubeModel.cubies[cu].facelets[f].props[pi].kind
                    let want: Float
                    if kind == .channelBowl, cubeModel.channelReceivers.contains(id) {
                        want = locked ? 1 : (fed.contains(id) ? 0.55 : 0)
                    } else if kind == .channelBasin {
                        // 5I.9 — "the source basin fills completely" when the circuit locks; a
                        // faint working glow the rest of the time, so it reads as the origin.
                        want = locked ? 1 : 0.18
                    } else { continue }
                    let have = cubeModel.cubies[cu].facelets[f].props[pi].anim
                    if abs(have - want) > 0.001 {
                        // Ease, so a receiver going dark is something you SEE go dark.
                        let next = have + max(-dt * 1.6, min(dt * 1.6, want - have))
                        cubeModel.cubies[cu].facelets[f].props[pi].anim = next
                        changed = true
                    }
                }
            }
        }
        // 5F — the junction vessels mirror LOCAL truth: how many of this tile's channel arms are
        // actually carrying current. Not a hint and not a count of the puzzle's progress — just what
        // is true here, which is why a vessel can read three while the circuit is still broken.
        for cu in cubeModel.cubies.indices {
            for f in cubeModel.cubies[cu].facelets.indices {
                let facelet = cubeModel.cubies[cu].facelets[f]
                guard facelet.props.contains(where: { $0.kind == .layeredVessel }),
                      !facelet.mazeTile.channels.isEmpty else { continue }
                let live = fed.contains(facelet.id.rawValue)
                var arms = 0
                for d in [DirectionMask.north, .east, .south, .west]
                where facelet.mazeTile.channels.contains(d) { arms += 1 }
                let want = live ? Float(min(3, arms)) : 0
                for pi in cubeModel.cubies[cu].facelets[f].props.indices
                where cubeModel.cubies[cu].facelets[f].props[pi].kind == .layeredVessel {
                    let have = cubeModel.cubies[cu].facelets[f].props[pi].anim
                    if abs(have - want) > 0.001 {
                        // Eased, so "the ring rotates out of phase" when a twist breaks the route is
                        // something the player can catch happening.
                        cubeModel.cubies[cu].facelets[f].props[pi].anim =
                            have + max(-dt * 1.2, min(dt * 1.2, want - have))
                        changed = true
                    }
                }
            }
        }
        _ = changed   // animation, not topology: the maze path reads anim live every frame
        // 5K — the way out, created when the circuit goes live. → Scene 6 does not exist yet, so it
        // returns to the hub's Scene 4 for now.
        // 5K — placed by Scene 5's own rule (the far end of the live current), not Scene 3's
        // "as far as you can walk", which would have put the door somewhere the circuit never goes.
        // → SCENE 6, which is Scene 2 RETURNED TO (destination 10): the same world, entered on the
        // far side of the slab the player turned there. Not a new world; that is the whole point.
        if liveCircuit { cubeModel.createCircuitExit(destinationID: 10, depths: channelDepths) }
    }

    /// Scene 5 — every facelet the current reaches, by facelet id. Walked over CHANNELS, not over
    /// openings: the current follows grooves, and a groove crossing a slab boundary only conducts if
    /// the tile on the other side has one facing back. That is the whole scene — a twist rotates a
    /// tile's channels, so it can join two runs or sever one, and neither is announced.
    ///
    /// Recomputed on demand rather than cached, because the thing it depends on is exactly the thing
    /// the player is changing.
    var channelReach: Set<Int> { Set(channelDepths.keys) }


    var channelDepths: [Int: Int] {
        if let memo = depthsMemo, memo.version == cubeModel.topologyVersion { return memo.depths }
        let fresh = computeChannelDepths()
        depthsMemo = (cubeModel.topologyVersion, fresh)
        return fresh
    }

    /// The same walk, keeping HOW FAR each tile is from the source in channel-steps. The set alone
    /// answers "is this lit"; the pulse needs "when does the current get here", which is the same
    /// question the BFS was already answering and throwing away.
    func computeChannelDepths() -> [Int: Int] {
        guard let src = cubeModel.channelSource,
              let (sci, sfi) = cubeModel.faceletAt(face: src.face, row: src.row, col: src.col) else { return [:] }
        struct T: Hashable { let f: Int; let r: Int; let c: Int }
        let n = cubeModel.size
        var reached: [Int: Int] = [cubeModel.cubies[sci].facelets[sfi].id.rawValue: 0]
        var q = [(t: T(f: src.face.rawValue, r: src.row, c: src.col), d: 0)], head = 0
        var seen: Set<T> = [q[0].t]
        while head < q.count {
            let (t, depth) = q[head]; head += 1
            guard let face = CubeFace(rawValue: t.f),
                  let (ci, fi) = cubeModel.faceletAt(face: face, row: t.r, col: t.c) else { continue }
            let ch = cubeModel.cubies[ci].facelets[fi].mazeTile.channels
            for (dir, mask, dr, dc) in [(SurfaceDirection.north, DirectionMask.north, -1, 0),
                                        (.south, .south, 1, 0), (.west, .west, 0, -1), (.east, .east, 0, 1)]
            where ch.contains(mask) {
                let nr = t.r + dr, nc = t.c + dc
                let nt: T
                let back: SurfaceDirection
                if nr >= 0, nr < n, nc >= 0, nc < n {
                    nt = T(f: t.f, r: nr, c: nc); back = dir.opposite
                } else {
                    let cr = cubeModel.edgeCrossing(face: face, direction: dir, row: t.r, col: t.c)
                    nt = T(f: cr.face.rawValue, r: cr.row, c: cr.col); back = cr.facing.opposite
                }
                guard let nFace = CubeFace(rawValue: nt.f),
                      let (nci, nfi) = cubeModel.faceletAt(face: nFace, row: nt.r, col: nt.c) else { continue }
                // BOTH ends must have a groove. A channel that stops against a blank tile is exactly
                // the "thin dark crack where channels have been rotated out of alignment".
                let backMask: DirectionMask = back == .north ? .north : back == .south ? .south
                                            : back == .west ? .west : .east
                guard cubeModel.cubies[nci].facelets[nfi].mazeTile.channels.contains(backMask) else { continue }
                if seen.insert(nt).inserted {
                    reached[cubeModel.cubies[nci].facelets[nfi].id.rawValue] = depth + 1
                    q.append((nt, depth + 1))
                }
            }
        }
        return reached
    }





    /// One tile per this many seconds. Taken from the player's own gait rather than tuned: the script
    /// says walking speed, and "slow enough for the player to follow on foot" is a promise the pulse
    /// has to keep even if the walk speed is retuned later.
    var pulseTilesPerSecond: Float { player.moveSpeed / Float(player.standGrid) }

    func tickChannelPulse(_ dt: Float) {
        guard !cubeModel.channelReceivers.isEmpty, cubeModel.channelSource != nil else { return }
        pulseDepths = channelDepths
        let maxDepth = Float(pulseDepths.values.max() ?? 0)

        if pulseHold > 0 {
            // "It spreads briefly against the dead end… the light withdraws toward the source and
            // begins again." The hold IS that beat; the pulse stays put while it happens.
            pulseHold -= dt
            if pulseHold <= 0 { pulseFront = -1; pulseBrokeAt = -1 }
            return
        }

        let previous = pulseFront
        if pulseFront < 0 {
            pulseFront = 0
            pendingAudioCues.append(.channelPulse(at: faceletPosition(of: cubeModel.channelSource)))
        } else {
            pulseFront += dt * pulseTilesPerSecond
        }

        // A receiver the front has just crossed answers as it is fed, whether or not the circuit as
        // a whole holds — that difference is the scene's subject, not a state to be hidden.
        for id in cubeModel.channelReceivers {
            guard let d = pulseDepths[id] else { continue }
            if Float(d) > previous, Float(d) <= pulseFront {
                pendingAudioCues.append(.channelReceiverFed(at: faceletPosition(ofFaceletID: id)))
            }
        }

        if pulseFront >= maxDepth {
            if liveCircuit {
                // 5I — "it no longer withdraws… the circuit becomes self-sustaining." The front
                // wraps straight back to the source: a rhythm, not a retry.
                pulseFront = 0
                pulseBright = 0
                pendingAudioCues.append(.channelPulse(at: faceletPosition(of: cubeModel.channelSource)))
            } else {
                pulseFront = maxDepth
                pulseHold = 1.6
                pulseBright = 0
                // The deepest tile the current reached: the break the player has to find.
                pulseBrokeAt = pulseDepths.first(where: { Float($0.value) == maxDepth })?.key ?? -1
                pendingAudioCues.append(.channelIncomplete(at: faceletPosition(ofFaceletID: pulseBrokeAt)))
            }
        }

        tickWorldBloom(dt)
    }


    func triggerDiagnosticPulse() {
        pulseHold = 0
        pulseBrokeAt = -1
        pulseFront = 0
        pulseBright = 1
        pendingAudioCues.append(.channelPulse(at: faceletPosition(of: cubeModel.channelSource)))
    }

    func tickSurveyor(_ dt: Float) {
        guard !cubeModel.channelReceivers.isEmpty, cubeModel.channelSource != nil else { return }
        let reach = channelDepths

        // Spawn on first tick: the live channel tile deepest from the source — far from the
        // arrival, so the machine is met as distant industry, not a greeter.
        if surveyorTile == nil {
            var best: (face: CubeFace, row: Int, col: Int, d: Int)? = nil
            for face in CubeFace.allCases {
                for r in 0..<cubeModel.size {
                    for c in 0..<cubeModel.size {
                        guard let (ci, fi) = cubeModel.faceletAt(face: face, row: r, col: c) else { continue }
                        let f = cubeModel.cubies[ci].facelets[fi]
                        guard !f.mazeTile.channels.isEmpty, let d = reach[f.id.rawValue] else { continue }
                        if best == nil || d > best!.d { best = (face, r, c, d) }
                    }
                }
            }
            guard let b = best else { return }
            surveyorTile = (b.face, b.row, b.col)
            placeSurveyorProp(at: (b.face, b.row, b.col))
            return
        }
        guard let here = surveyorTile,
              let (ci, fi) = cubeModel.faceletAt(face: here.face, row: here.row, col: here.col) else { return }

        // Mid-step: slide the body from the previous tile's centre to this one's. Offsets are in
        // the tile-local frame the prop path already understands; cross-face steps skip the slide
        // (the frames differ) and simply arrive. The mast bobs while it works via the same prop.
        // The slide lives in (surveyorFrom, surveyorMove); the renderer's dynamic pass reads it
        // directly. No prop mutation, no topology mark — this used to invalidate the asset-bucket
        // cache every frame the machine walked.
        if surveyorMove < 1 {
            surveyorMove = min(1, surveyorMove + dt * 0.9)
            if surveyorMove >= 1 { surveyorFrom = nil }
            return
        }

        // STALLED — no current, no work. On a channel tile the rule is exact: dead tile, idle
        // machine. On its own filigree (v2 walks the network it built) it works while ANY current
        // flows somewhere — its network drinks from the trunk as a whole.
        let hereF = cubeModel.cubies[ci].facelets[fi]
        let hereID = hereF.id.rawValue
        if hereF.mazeTile.channels.isEmpty {
            guard reach.count > 1 else { surveyorIdle = true; return }
        } else {
            guard reach[hereID] != nil else { surveyorIdle = true; return }
        }
        surveyorIdle = false

        // WORK: grow filigree on one bare neighbour of this live tile.
        if let target = filigreeTarget(of: here) {
            surveyorWork += dt
            let rate = dt / 16.0                          // ~16 s per branch: industry, not spectacle
            if let (nci, nfi) = cubeModel.faceletAt(face: target.loc.face, row: target.loc.row, col: target.loc.col) {
                if cubeModel.cubies[nci].facelets[nfi].filigreeGrowth == 0 {
                    cubeModel.cubies[nci].facelets[nfi].filigreeEntry = target.entry
                    cubeModel.cubies[nci].facelets[nfi].filigreeRing = target.ring
                    cubeModel.cubies[nci].facelets[nfi].filigreeSeed =
                        UInt8(truncatingIfNeeded: cubeModel.cubies[nci].facelets[nfi].id.rawValue &* 31 &+ 7)
                }
                cubeModel.cubies[nci].facelets[nfi].filigreeGrowth =
                    min(1, cubeModel.cubies[nci].facelets[nfi].filigreeGrowth + rate)
            }
            return
        }

        // MOVE: this tile's neighbours are all grown (or ungrowable) — walk to the next live
        // channel tile that still has work, nearest by depth difference; deterministic ties.
        var next: (face: CubeFace, row: Int, col: Int)? = nil
        var bestKey: (Int, Int, Int, Int)? = nil
        for face in CubeFace.allCases {
            for r in 0..<cubeModel.size {
                for c in 0..<cubeModel.size {
                    guard let (qci, qfi) = cubeModel.faceletAt(face: face, row: r, col: c) else { continue }
                    let f = cubeModel.cubies[qci].facelets[qfi]
                    // Work stands: live channel tiles, or finished filigree of its own network.
                    let isTrunk = !f.mazeTile.channels.isEmpty && reach[f.id.rawValue] != nil
                    let isOwnWork = f.mazeTile.channels.isEmpty && f.filigreeGrowth >= 1
                    guard isTrunk || isOwnWork,
                          !(face == here.face && r == here.row && c == here.col),
                          filigreeTarget(of: (face, r, c)) != nil else { continue }
                    // Trunk first, then outward rings — the machine finishes near the current
                    // before wandering, which is also what keeps it findable.
                    let key = (isTrunk ? 0 : Int(f.filigreeRing), face.rawValue, r, c)
                    if bestKey == nil || key < bestKey! { bestKey = key; next = (face, r, c) }
                }
            }
        }
        guard let n = next else { surveyorIdle = true; return }   // everything reachable is grown
        moveSurveyorProp(from: here, to: n)
        surveyorFrom = here
        surveyorTile = n
        surveyorMove = 0
    }


    func filigreeTarget(of loc: (face: CubeFace, row: Int, col: Int))
        -> (loc: (face: CubeFace, row: Int, col: Int), entry: DirectionMask, ring: UInt8)? {
        let n = cubeModel.size
        guard let (pci, pfi) = cubeModel.faceletAt(face: loc.face, row: loc.row, col: loc.col) else { return nil }
        let parent = cubeModel.cubies[pci].facelets[pfi]
        let parentRing: UInt8 = parent.mazeTile.channels.isEmpty ? parent.filigreeRing : 0
        guard parentRing < GameState.filigreeMaxRing else { return nil }
        for (sdir, dr, dc) in [(SurfaceDirection.north, -1, 0), (.east, 0, 1), (.south, 1, 0), (.west, 0, -1)] {
            let nr = loc.row + dr, nc = loc.col + dc
            let far: (face: CubeFace, row: Int, col: Int, back: SurfaceDirection)
            if nr >= 0, nr < n, nc >= 0, nc < n {
                far = (loc.face, nr, nc, sdir.opposite)
            } else {
                let cr = cubeModel.edgeCrossing(face: loc.face, direction: sdir, row: loc.row, col: loc.col)
                far = (cr.face, cr.row, cr.col, cr.facing.opposite)
            }
            guard let (nci, nfi) = cubeModel.faceletAt(face: far.face, row: far.row, col: far.col) else { continue }
            let f = cubeModel.cubies[nci].facelets[nfi]
            guard f.mazeTile.channels.isEmpty, f.props.isEmpty, f.filigreeGrowth < 1 else { continue }
            let entry: DirectionMask = far.back == .north ? .north : far.back == .south ? .south
                                     : far.back == .west ? .west : .east
            return ((far.face, far.row, far.col), entry, parentRing + 1)
        }
        return nil
    }

    func placeSurveyorProp(at loc: (face: CubeFace, row: Int, col: Int)) {
        guard let (ci, fi) = cubeModel.faceletAt(face: loc.face, row: loc.row, col: loc.col) else { return }
        // The prop is a MARKER (audio sweep, tests); rendering is the dynamic pass, which reads
        // surveyorTile/Move directly — so placing or moving it is not a topology event.
        cubeModel.cubies[ci].facelets[fi].props.append(Prop(kind: .surveyor, subRow: 1, subCol: 1, facing: .n))
    }

    func moveSurveyorProp(from: (face: CubeFace, row: Int, col: Int),
                                  to: (face: CubeFace, row: Int, col: Int)) {
        if let (ci, fi) = cubeModel.faceletAt(face: from.face, row: from.row, col: from.col) {
            cubeModel.cubies[ci].facelets[fi].props.removeAll { $0.kind == .surveyor }
        }
        placeSurveyorProp(at: to)
    }



    func tickWorldBloom(_ dt: Float) {
        if bloomElapsed < 0 {
            guard liveCircuit else { return }
            bloomElapsed = 0
            // The three receiver tones and the source align — every voice already registered.
            for id in cubeModel.channelReceivers {
                pendingAudioCues.append(.channelReceiverFed(at: faceletPosition(ofFaceletID: id)))
            }
        }
        bloomElapsed += dt
        let t = bloomElapsed
        if t < 2.5 { worldBloom = t / 2.5 }
        else if t < 6.5 { worldBloom = 1 }
        else { worldBloom = max(0.3, 1 - (t - 6.5) / 4.0 * 0.7) }
    }

    /// The emitter that travels with the front, so the pulse can be followed by ear around the far
    /// side of a world. Placed on the reached tile whose depth the front is currently passing,
    /// choosing the one nearest the player when a branch means there are several.
    var pulseEmitter: AudioEmitter? {
        guard pulseFront >= 0, !pulseDepths.isEmpty else { return nil }
        let want = Int(pulseFront.rounded())
        var best: (id: Int, pos: SIMD3<Float>, dist: Float)? = nil
        let spin = worldSpinMatrix()
        for (id, d) in pulseDepths where d == want {
            guard let p = faceletPosition(ofFaceletID: id) else { continue }
            // Compare in the SPUN frame, where the listener is, but publish the rest position.
            let sp = spin * SIMD4(p, 1)
            let dist = simd_length(SIMD3(sp.x, sp.y, sp.z) - viewOrigin)
            if best == nil || dist < best!.dist { best = (id, p, dist) }
        }
        guard let b = best else { return nil }
        // One STABLE id, not the tile's: the emitter is the pulse, which is a single moving thing.
        // Keying it by tile would restart the loop at every tile boundary — a stutter, not a sound.
        return AudioEmitter(id: -5001, kind: .pulse, position: b.pos, occlusion: 0)
    }

    /// Scene 5 — all three receivers fed from the source AT ONCE. Not "each has been fed at some
    /// point": the scene's whole subject is holding a relationship, so this is a snapshot.
    var liveCircuit: Bool {
        guard !cubeModel.channelReceivers.isEmpty else { return false }
        let fed = channelReach
        return cubeModel.channelReceivers.allSatisfy { fed.contains($0) }
    }
}
