import simd

/// What gets stamped onto a freshly generated world (M15.2). The maze itself is always generated;
/// the stamp is the authored layer on top — rooms, props, portals.
enum WorldStamp {
    case overworldDemo   // the dev overworld: start plaza + props, BOTH doorways, the −Z house court
    case moonDemo        // the moon: the demo plaza but only its one door home (no temple doorway)
    case templeInterior  // the first hand-stamped interior: central hall, pedestal, return portal
    case bare            // nothing authored — the bare generated maze (tests; procedural worlds later)
    case natural         // M18 Phase 1: no walls anywhere — open ground + a few landmarks (the open-field testbed; M19 grows it into the Natureworld)
    case homeClearing    // M20 (Eddie): the FIRST world — a pastoral natural clearing whose one portal is a stone arch to the garden
    case lunar           // M19: the Moon — open grey regolith + boulders (grey in the sky, walkable when visited)
    case gardenMaze      // M20 first cut: a hedge maze on a green planet — grass floors, some trees, roundness (the Journey garden)
    case gallery         // M20 dev tool: a flat grid of every prop/foliage variant, one per cell, for isolated evaluation
    case portalHub       // M20 (Eddie): a flat plaza of labeled portals — one TARDIS + signpost per world, to navigate by reading not memorised keys
    case sceneTwo        // Prologue Scene 2 "The Four Corners": four corner switches, a control plinth, and the way onward hidden on a face that must be TURNED into view
    case sceneOne        // Prologue Scene 1 "The First Clearing": a walled clearing, a break in its north wall, and a maze of vessels beyond — the opening, and the first sight of the Builders' objects
    case sceneThree      // Prologue Scene 3 "The Heart of the World": the INSIDE of Scene 2's world — six interior faces, six obelisks, six remote plinths, and a suspended orb at the centre
    case sceneFour       // Prologue Scene 4 "The First Turn": the player is handed the twist, and must first read and release a bond before the world will move

    /// The world this stamp wants hanging overhead, by name (see `GameState.skyCounterpart`).
    /// Authored here, beside the stamp, rather than at the Renderer's build site: it is a fact
    /// about the scene, so it holds in the tests too, and a new scene declares its sky in the
    /// same place it declares everything else about itself.
    var skyCounterpart: String? {
        switch self {
        case .sceneFour: return "scene-2"   // the larger world overhead — Scene 4's fixed reference
        default:         return nil         // default rule: the world beneath you, or the moon
        }
    }
}

/// Authored sizes for the prologue's worlds, so the Renderer and the tests cannot drift apart.
enum PrologueSize {
    /// Scene 2. Was 15, which put ~130 m between the control plinth and the slab that turns — far
    /// enough that the payoff was easy to miss (Eddie, playtest). At 11 the play region fills the
    /// whole face and the turn happens within sight of where you trigger it.
    static let sceneTwo = 11
    /// Scene 4. Small on purpose: the script wants a world the player can circumnavigate quickly,
    /// because its job is to make the effect of a twist easy to READ, not to occupy them.
    static let sceneFour = 5
    /// Scene 1. The clearing is 3×3 tiles and the script wants a maze of "approximately three times
    /// the playable area" — 9 tiles of clearing against ~35 of maze at this size, which is that,
    /// walked rather than counted.
    static let sceneOne = 9
    /// Scene 3. "World dimensions: 5x5x5 … playable surface: six interior faces, each 5x5 tiles" —
    /// the script is explicit, and it has to be: the player must be able to see the orb from every
    /// face, which a larger chamber would put out of reach of the eye.
    static let sceneThree = 5
}

/// M20 — how a world's maze WALLS are rendered.
/// - `.hedge`: the procedural hedge-wall mesh (default; `SceneBuilder` draws it, keyed by edge config).
///   A world can additionally stamp static rock/bush overgrowth ON the hedges ("stone-in-hedges",
///   `stampGardenWalls`) — a look we keep as an option.
/// - `.dressed`: the hedge mesh is suppressed; imported wall MODELS (Ruins pieces + rocks/bushes) are
///   emitted per closed edge DYNAMICALLY from topology every frame by the Renderer (a `WallDressing`).
///   This is the only stone-wall look that survives a slice-twist (it re-derives, like the hedge mesh).
enum WallStyle {
    case hedge
    case dressed
}

class CubeModel {
    let size: Int
    let worldScale: WorldScale
    var cubies: [Cubie]

    private var projectionDirty = true
    private var cachedProjection: [CubeFace: [[FaceletID?]]] = [:]

    // Static map: facelet id → its fixed location in the cubies array. Assigned once
    // in buildCubies and never invalidated — slice rotations mutate cubie position /
    // orientation in place but never reorder the array or reassign facelet ids. This
    // turns findFaceletIndices(id:) (hit once per faceletAt, ~6·n² times per frame)
    // from an O(n²) scan into an O(1) lookup.
    private var faceletLocation: [FaceletID: (cubieIndex: Int, faceletIndex: Int)] = [:]

    init(worldScale: WorldScale, stamp: WorldStamp = .overworldDemo) {
        self.worldScale = worldScale
        self.size = worldScale.cubeSize
        self.cubies = []
        buildCubies()
        buildFaceletLocationMap()
        generateMaze()
        addEdgeBridges()
        rebuildProjection()
        switch stamp {
        case .overworldDemo:
            stampDemoRoom()
            stampDemoProps(templeDoor: true)
        case .moonDemo:
            stampDemoRoom()
            stampDemoProps(templeDoor: false)
        case .templeInterior:
            stampTempleInterior()
        case .bare:
            break
        case .natural:
            stampNatural()
            roundness = 1.0         // M19: natural worlds are planets (Eddie) — authored per-world roundness
            reliefAmplitude = 0.05  // gentle rolling hills (tune live with ,/. )
        case .homeClearing:
            stampNatural(homePortalToGarden: true)   // M20: the first world; its portal is a stone arch → garden
            roundness = 1.0
            reliefAmplitude = 0.05
        case .lunar:
            stampLunar()
            roundness = 1.0         // M19: the moon is a round grey body, in the sky and underfoot
            reliefAmplitude = 0.08  // deeper than earth so the craters + hills/dunes read (Apollo)
        case .gardenMaze:
            stampGardenMaze()
            naturalDressing = true
            roundness = 1.0         // a round hedged planet
        case .gallery:
            stampGallery()          // flat (roundness stays 0) so each item reads in isolation
            noFog = true            // a showroom, not a story world — no fog
        case .portalHub:
            stampPortalHub()        // flat plaza of labeled portals
            noFog = true
        case .sceneFour:
            stampSceneFour()
            naturalDressing = true
            // Hard cube, like Scene 2: the player TWISTS here, so the cut faces that give a moving
            // slab its thickness must line up, and those only do so at roundness 0. The script asks
            // for "low to moderate, visibly softened" — worth revisiting once the cut plane can be
            // inflated to match a curved shell (see Open Questions).
            roundness = 0.0
        case .sceneOne:
            stampSceneOne()
            naturalDressing = true      // grass floors, no dark cube frame
            // "Roundness: high enough that the world reads as a planet, though curvature should not
            // yet be obvious from the playable area." Nothing twists here, so the flat-cut-face
            // constraint that pins Scenes 2 and 4 to zero does not apply.
            roundness = 1.0
            reliefAmplitude = 0.02      // barely there: "small irregularities suggest natural earth"
        case .sceneThree:
            stampSceneThree()
            roundness = 0.0             // "shape: hard-edged cube"
        case .sceneTwo:
            stampSceneTwo()
            naturalDressing = true
            // HARD CUBE (Eddie, playtest). Roundness inflates each surface tile out onto a curved
            // shell, but a slab's CUT faces are interior — they stay on the flat cube — so any
            // roundness above 0 makes the two disagree and the cut planes float away from the slab
            // they belong to. A world whose puzzle is watching a slice turn wants its grid legible
            // anyway; curvature was fighting the very thing the scene is about.
            roundness = 0.0
        }
        reconcileSharedEdges()
    }

    /// An edge is one thing, but it is STORED twice — once in each tile that meets at it. Nothing
    /// enforced that the two halves agree, and several stamps carve a passage by opening one side
    /// only (`openings.insert(.east)` and friends, never a matching insert on the neighbour). The
    /// halves then disagreed, with two consequences that look unrelated:
    ///
    ///   • Movement is checked on the DEPARTING tile, so the edge was passable one way and solid the
    ///     other. Walk east freely, then find you cannot walk back west.
    ///   • The dressed wall is drawn once, by whichever of the two tiles owns it. If the owner is the
    ///     side that thinks the edge is OPEN, nothing is drawn at all — an invisible wall. That is
    ///     what Eddie hit beside Scene 2's control plinth (18 disagreeing halves there, 38 in the hub).
    ///
    /// OPEN wins, and that is not arbitrary: every one-sided edit in this file is an `insert` — there
    /// is no one-sided `remove` anywhere — so a disagreement always means "someone carved a passage
    /// and did not tell the far side". Opening both halves is what they meant. It also cannot seal a
    /// route, so it can only ever fix reachability, never break it.
    private func reconcileSharedEdges() {
        let dirs: [(SurfaceDirection, DirectionMask, Int, Int)] = [
            (.north, .north, -1, 0), (.south, .south, 1, 0), (.west, .west, 0, -1), (.east, .east, 0, 1)
        ]
        for face in CubeFace.allCases {
            for r in 0..<size {
                for c in 0..<size {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: c) else { continue }
                    for (sdir, mask, dr, dc) in dirs {
                        guard cubies[ci].facelets[fi].mazeTile.openings.contains(mask) else { continue }
                        let nr = r + dr, nc = c + dc
                        let far: (face: CubeFace, row: Int, col: Int, back: SurfaceDirection)
                        if nr >= 0, nr < size, nc >= 0, nc < size {
                            far = (face, nr, nc, sdir.opposite)
                        } else {
                            // Across a cube edge the far side's "back" direction is conjugated, so ask
                            // the crossing rather than assuming north pairs with south.
                            let cr = edgeCrossing(face: face, direction: sdir, row: r, col: c)
                            far = (cr.face, cr.row, cr.col, cr.facing.opposite)
                        }
                        guard let (nci, nfi) = faceletAt(face: far.face, row: far.row, col: far.col) else { continue }
                        let backMask: DirectionMask = far.back == .north ? .north : far.back == .south ? .south
                                                    : far.back == .west ? .west : .east
                        cubies[nci].facelets[nfi].mazeTile.openings.insert(backMask)
                    }
                }
            }
        }
    }


    // MARK: - Prologue Scene 1 — "The First Clearing"

    /// The opening. A walled clearing with a break in its north wall, a corridor through stone that
    /// is thicker than it looks, and beyond it a maze whose every dead end holds a vessel.
    ///
    /// Nothing here is a puzzle. The scene's whole job is to establish that the world is ENCLOSED,
    /// that the way on is horizontal rather than upward, and that these objects keep appearing —
    /// "by the fourth, the vessels no longer feel like decoration. They feel placed." So it is
    /// authored as architecture, not as a lock: no bond, no switch, no twist (the verb is withheld
    /// until Scene 4), and the portal at the end is open from the moment it is found.
    private func stampSceneOne() {
        let n = size
        wallStyle = .dressed
        cleanWalls = true                    // fitted stone, no moss: this world is not ruined yet

        // Start from solid stone and CARVE. Sealing every edge also seals the face's border, so the
        // clearing and maze are genuinely enclosed rather than opening onto the rest of the cube —
        // "they rise well above the player's reach and offer no obvious handholds".
        for r in 0..<n {
            for c in 0..<n {
                for dir in [SurfaceDirection.north, .east, .south, .west] {
                    setSharedEdge(face: .positiveZ, row: r, col: c, dir, open: false)
                }
            }
        }

        // Deterministic RNG — the opening should be the same place every launch.
        var rng: UInt32 = 0x5CE1_0001
        func next() -> UInt32 { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng }

        // ── THE CLEARING: a 3×3 room at the south, walled but for one break ────────────────────
        let clearTop = n - 3, clearLeft = n / 2 - 1, mid = n / 2
        for r in clearTop..<(clearTop + 3) {
            for c in clearLeft..<(clearLeft + 3) {
                if r > clearTop { setSharedEdge(face: .positiveZ, row: r, col: c, .north, open: true) }
                if c > clearLeft { setSharedEdge(face: .positiveZ, row: r, col: c, .west, open: true) }
            }
        }
        // "A narrow break interrupts the northern wall. It is not framed as a doorway. It is simply
        // a place where the wall stops." At the clearing's north-WEST corner, diagonally opposite
        // the arrival — so it is found by looking rather than by being stood in front of.
        let corridor = clearTop - 1
        setSharedEdge(face: .positiveZ, row: clearTop, col: clearLeft, .north, open: true)
        // The corridor DOG-LEGS inside the wall (Eddie): in at the west, one step east, then north
        // into the maze. A straight corridor showed the maze through the gap before you entered it;
        // a bend means "crossing through the break reveals that the outer wall is much thicker than
        // expected" is discovered by walking it, and the maze arrives only at the turn.
        setSharedEdge(face: .positiveZ, row: corridor, col: clearLeft, .east, open: true)
        setSharedEdge(face: .positiveZ, row: corridor, col: mid, .north, open: true)
        // Two ALCOVES off the dog-leg, one at each end (Eddie). They are dead ends inside the wall
        // itself, which is the first time the player meets the scene's rule — a dead end is where a
        // vessel stands — and they meet it before the maze, on a stretch they cannot get lost in.
        setSharedEdge(face: .positiveZ, row: corridor, col: clearLeft - 1, .east, open: true)
        setSharedEdge(face: .positiveZ, row: corridor, col: clearLeft + 2, .west, open: true)

        // ── THE MAZE: recursive backtracker over everything north of the corridor ───────────────
        let mazeBottom = corridor - 1
        var visited = Array(repeating: Array(repeating: false, count: n), count: mazeBottom + 1)
        var stack = [[mazeBottom, mid]]
        visited[mazeBottom][mid] = true
        while let cur = stack.last {
            let r = cur[0], c = cur[1]
            var options: [(SurfaceDirection, Int, Int)] = []
            for (dir, dr, dc) in [(SurfaceDirection.north, -1, 0), (.south, 1, 0), (.west, 0, -1), (.east, 0, 1)] {
                let nr = r + dr, nc = c + dc
                guard nr >= 0, nr <= mazeBottom, nc >= 0, nc < n, !visited[nr][nc] else { continue }
                options.append((dir, nr, nc))
            }
            guard !options.isEmpty else { stack.removeLast(); continue }
            let pick = options[Int(next() % UInt32(options.count))]
            setSharedEdge(face: .positiveZ, row: r, col: c, pick.0, open: true)
            visited[pick.1][pick.2] = true
            stack.append([pick.1, pick.2])
        }
        // "one or two loops" — a perfect maze is all dead ends and no choices that come back.
        for _ in 0..<2 {
            let r = Int(next() % UInt32(mazeBottom + 1)), c = Int(next() % UInt32(n))
            let dirs: [SurfaceDirection] = [.north, .south, .west, .east]
            let dir = dirs[Int(next() % 4)]
            let (dr, dc) = dir == .north ? (-1, 0) : dir == .south ? (1, 0) : dir == .west ? (0, -1) : (0, 1)
            guard r + dr >= 0, r + dr <= mazeBottom, c + dc >= 0, c + dc < n else { continue }
            setSharedEdge(face: .positiveZ, row: r, col: c, dir, open: true)
        }

        // ── DEAD ENDS: one open edge apiece, and the whole point of the scene ──────────────────
        var deadEnds: [[Int]] = []
        for r in 0...mazeBottom {
            for c in 0..<n {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                let op = cubies[ci].facelets[fi].mazeTile.openings
                var open = 0
                for d in [DirectionMask.north, .east, .south, .west] where op.contains(d) { open += 1 }
                if open == 1 { deadEnds.append([r, c]) }
            }
        }
        // The portal goes to the dead end FURTHEST from the corridor by walking distance, so the
        // player finds it last and has met several vessels on the way.
        var dist: [[Int]: Int] = [[mazeBottom, mid]: 0]
        var queue = [[mazeBottom, mid]], head = 0
        while head < queue.count {
            let t = queue[head]; head += 1
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: t[0], col: t[1]) else { continue }
            let op = cubies[ci].facelets[fi].mazeTile.openings
            for (mask, dr, dc) in [(DirectionMask.north, -1, 0), (.south, 1, 0), (.west, 0, -1), (.east, 0, 1)]
            where op.contains(mask) {
                let nt = [t[0] + dr, t[1] + dc]
                guard nt[0] >= 0, nt[0] <= mazeBottom, nt[1] >= 0, nt[1] < n, dist[nt] == nil else { continue }
                dist[nt] = dist[t]! + 1; queue.append(nt)
            }
        }
        let portalTile = deadEnds.max { (dist[$0] ?? 0) < (dist[$1] ?? 0) } ?? [0, mid]

        // ── VESSELS ────────────────────────────────────────────────────────────────────────────
        // "At every dead end stands another vessel. Some are solitary. Others appear in pairs or
        // small groups. No two need be completely identical, but they share the same stacked axial
        // grammar." `state` carries a per-vessel variation seed; `anim` is how many of its rings sit
        // aligned, so a maze of them shows the same object saying slightly different things — "the
        // first syllables of a language the player does not know they are hearing".
        func placeVessel(_ r: Int, _ c: Int, _ h: UInt32, group: Bool) {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: c) else { return }
            let count = group ? 2 + Int(h % 2) : 1
            for k in 0..<count {
                let hk = h &+ UInt32(k &* 7919)
                let p = scatterPlacement(hk, avoidCentre: count > 1,
                                         clearCells: PropKind.layeredVessel.footprintRadius(grid: worldScale.standGrid))
                var v = Prop(kind: .layeredVessel, subRow: p.subRow, subCol: p.subCol,
                             state: Int(hk % 5), viewAngle: p.yaw,
                             extraScale: 0.82 + Float(hk % 40) / 100.0,
                             offsetX: p.ox, offsetY: p.oy)
                v.anim = Float(hk % 4)          // 0…3 rings home — none of it means anything yet
                cubies[ci].facelets[fi].props.append(v)
            }
        }
        for (i, t) in deadEnds.enumerated() where t != portalTile {
            placeVessel(t[0], t[1], next(), group: i % 3 == 0)
        }
        // "In one corner of the clearing stands a small group of unusual vessels." The first ones
        // the player ever sees, before there is any maze to give them meaning.
        placeVessel(clearTop, clearLeft, next(), group: true)
        // The corridor alcoves. Placed explicitly rather than by the dead-end sweep, which only
        // scans the maze proper — and deliberately so, or the arch would be free to end up in one
        // of these instead of at the far end of the maze.
        placeVessel(corridor, clearLeft - 1, next(), group: false)
        placeVessel(corridor, clearLeft + 2, next(), group: true)

        // ── THE ARCHWAY ────────────────────────────────────────────────────────────────────────
        // Active, unsealed, no pull: "the player must choose to cross."
        if let (ci, fi) = faceletAt(face: .positiveZ, row: portalTile[0], col: portalTile[1]) {
            cubies[ci].facelets[fi].props.append(
                Prop(kind: .portal, subRow: 1, subCol: 1, facing: .s, state: 10, transition: .push))
            styledPortals.append(StyledPortal(ci: ci, fi: fi, facing: .s, fieldStyle: 2))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalRing, subRow: 1, subCol: 1))
            cubies[ci].facelets[fi].props.append(
                Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .s, state: 2))
            // "This vessel is the largest encountered so far. Its uppermost layer turns slowly
            // toward the player. Not like a head. Not quite."
            var watcher = Prop(kind: .layeredVessel, subRow: 2, subCol: 1, facing: .n,
                               state: 5, extraScale: 1.45)
            watcher.anim = 3                    // fully aligned — the only one in the world that is
            cubies[ci].facelets[fi].props.append(watcher)
        }

        // ── ARRIVAL, AND FOG ───────────────────────────────────────────────────────────────────
        // "The player is standing near the center of the clearing. The camera begins facing roughly
        // north, but not directly toward the opening. The gap in the wall rests near the edge of the
        // initial view, discoverable through looking rather than presented as an objective marker."
        // Standing on the break's own column and facing due north made the exit the first thing you
        // saw, which inverts the whole intent — so: centre tile, one column west of the break, and a
        // north-EAST facing that puts the gap at the edge of view rather than in the middle of it.
        // The far corner from the break, facing north: the gap sits at the left edge of the opening
        // view rather than in the middle of it, which is what the script is after — "discoverable
        // through looking rather than presented as an objective marker".
        spawnLocation = (face: .positiveZ, row: clearTop + 2, col: clearLeft + 2, facing: .n)
        // The script asks for "fog of discovery: active beyond the immediately visible clearing", and
        // it was built that way — but revealed by walking it looked wrong (Eddie: "really damn
        // odd"), because the fog is a solid volume rather than a horizon, so the maze arrived as
        // blocks lifting off rather than as distance resolving. Revealed in full for now. The
        // gradual-scale idea is worth another go with a different mechanism, not this one.
        for face in CubeFace.allCases {
            for r in 0..<n {
                for c in 0..<n {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: c) else { continue }
                    cubies[ci].facelets[fi].tileState = .discovered
                    cubies[ci].facelets[fi].discoveryAmount = 1.0
                }
            }
        }
    }


    // MARK: - Prologue Scene 3 — "The Heart of the World"

    /// The inside of Scene 2's world. Six interior faces under one continuous maze, an obelisk
    /// standing inward from the middle of each, and six plinths that control them REMOTELY — no
    /// plinth on the same face as the obelisk it wakes, so every pairing is a journey.
    ///
    /// The scene's real subject is the chamber's geometry: every surface's "up" points at the same
    /// centre, so the orb hangs in the same place above you whichever face you are on, and crossing
    /// a face reorients the world around you rather than moving you through it. The puzzle exists to
    /// make you walk all six.
    private func stampSceneThree() {
        let n = size, c = n / 2
        wallStyle = .hedge          // the metal-block walls are their own look; hedges stay off
        symbolPairedPlinths = true

        // The six symbols. Distinct but visibly of one language — they are all caustic glyphs, which
        // is the Builders' hand. (The script asks for six purpose-made marks; these stand in until
        // that art exists, and the pairing logic does not care which slices they are.)
        let symbols = [TextureLoader.CausticSymbol.one.rawValue,
                       TextureLoader.CausticSymbol.two.rawValue,
                       TextureLoader.CausticSymbol.three.rawValue,
                       TextureLoader.CausticSymbol.four.rawValue,
                       TextureLoader.CausticSymbol.swirl.rawValue,
                       TextureLoader.CausticSymbol.square.rawValue]
        let faces: [CubeFace] = [.positiveZ, .positiveY, .negativeX, .negativeZ, .positiveX, .negativeY]

        // AN OBELISK IN THE MIDDLE OF EVERY FACE, pointing inward at the orb. Inactive: "they are
        // dark and silent", and interacting with one does nothing — the control is somewhere else.
        for (i, face) in faces.enumerated() {
            guard let (ci, fi) = faceletAt(face: face, row: c, col: c) else { continue }
            for dir in [SurfaceDirection.north, .east, .south, .west] {
                setSharedEdge(face: face, row: c, col: c, dir, open: true)   // reachable from anywhere
            }
            var ob = Prop(kind: .obelisk, subRow: 1, subCol: 1, state: symbols[i])
            ob.anim = 0
            cubies[ci].facelets[fi].props.append(ob)
        }

        // THE PLINTHS. Face i's obelisk is controlled from face i+1 — a six-cycle, so no pairing is
        // the opposite face and none is local. "The exact mapping may be authored for navigational
        // rhythm, but should not follow an immediately obvious opposite-face rule for all six."
        // Positions vary per face so the six do not sit on a pattern either.
        let spots = [(1, 1), (1, c + 1), (c + 1, 1), (c + 1, c + 1), (1, c), (c + 1, c)]
        for (i, _) in faces.enumerated() {
            let host = faces[(i + 1) % faces.count]          // the face the CONTROL stands on
            let spot = spots[i]
            guard let (ci, fi) = faceletAt(face: host, row: spot.0, col: spot.1) else { continue }
            for dir in [SurfaceDirection.north, .east, .south, .west] {
                setSharedEdge(face: host, row: spot.0, col: spot.1, dir, open: true)
            }
            cubies[ci].facelets[fi].props.append(Prop(kind: .switchBase, subRow: 1, subCol: 1, facing: .n))
            // `state` is the SYMBOL, which is the whole binding: the plinth wakes whichever obelisk
            // carries the same mark, and nothing has to remember a pairing table.
            var cap = Prop(kind: .switchCap, subRow: 1, subCol: 1, facing: .n, state: symbols[i])
            cap.alignAnim = 0                                // 0 = flush and dark; 1 = raised, lit
            cubies[ci].facelets[fi].props.append(cap)
        }

        // THE WAY ON, "created only after all six obelisks are active" — so it is stamped sealed and
        // opens when the last obelisk wakes. On the floor face, away from every plinth.
        if let (ci, fi) = faceletAt(face: .negativeY, row: n - 1, col: c) {
            for dir in [SurfaceDirection.north, .east, .south, .west] {
                setSharedEdge(face: .negativeY, row: n - 1, col: c, dir, open: true)
            }
            cubies[ci].facelets[fi].props.append(
                Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n, state: 13, transition: .push))
            styledPortals.append(StyledPortal(ci: ci, fi: fi, facing: .n, fieldStyle: 2))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalRing, subRow: 1, subCol: 1))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .n, state: 2))
            sealedPortalCubies.insert(ci)
        }

        // Arrival: on the floor, looking across the chamber. "The player enters from above" — the
        // descent from Scene 2 lands them on a surface, and every surface here is a floor.
        spawnLocation = (face: .positiveZ, row: n - 1, col: c, facing: .n)

        // Fog stays ON (the script asks for it), but the six faces are large and the maze is the
        // point — reveal the arrival tile's surroundings so the first frame is not a wall of grey.
        for face in CubeFace.allCases {
            for r in 0..<n {
                for col in 0..<n {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: col) else { continue }
                    cubies[ci].facelets[fi].tileState = .discovered
                    cubies[ci].facelets[fi].discoveryAmount = 1.0
                }
            }
        }
    }

    // MARK: - Prologue Scene 2 — "The Four Corners"

    /// Scene 2: four corner switches control a hidden slab, and the way onward is already built on a
    /// face the player cannot see. Solving the lock raises a control; turning it rotates that slab so
    /// the exit swings into view. Nothing is spawned by the puzzle — the assembly exists from the
    /// first frame, riding facelets on the hidden face (props travel with their tiles through a twist,
    /// so this needs no special support).
    ///
    /// **Geometry** (measured, not assumed — see `sceneTwoHiddenSlice`): the player walks `+Z`; the
    /// assembly sits on `+Y`, the face over the top edge; both have tiles in the outer **X** slab.
    /// One counter-clockwise quarter-turn of that slab carries `+Y` tiles onto `+Z` — the exit arrives
    /// on the player's own surface. The same slab also carries one edge column of `+Z`, which is why
    /// the far side of the maze visibly travels with it.
    // MARK: - Prologue Scene 4 — "The First Turn"

    /// Scene 4: the player is handed the twist, and the world refuses it.
    ///
    /// The portal is present from the first frame but **sealed**, and the route to it does not line
    /// up. Turning the slab would fix both — except three anchors bind that slab to the rest of the
    /// world, so the turn strains and springs back. Releasing all three makes the turn *legal*; the
    /// player still has to perform it. "Understanding prepares the world. Choice moves it."
    ///
    /// **The lock needs no new engine code.** Each anchor is its own BOND, and `canRotateSlice`
    /// already refuses a turn when *any* bonded group straddles the slice, while `dissolveBond`
    /// already removes one. So three bonds, each with one cubie inside the twistable slab and one
    /// outside, reproduce the scripted behaviour exactly — including the turn staying refused until
    /// the third is gone — using only machinery the garden's temple lock already proved.
    /// Set BOTH halves of a shared edge at once. An edge lives in two tiles, and `reconcileSharedEdges`
    /// resolves any disagreement in favour of OPEN — so closing one half alone does nothing at all.
    /// Every deliberate wall has to be written on both sides, which is exactly the mistake that put
    /// invisible walls in Scene 2 and the hub.
    /// Seal a rectangular play region's border on BOTH halves of every edge.
    ///
    /// The stamps used to do this with a one-sided `op.remove(.north)` on the inside tile, which was
    /// enough while movement was tested on the departing tile — you simply could not step out. Then
    /// `reconcileSharedEdges` arrived to fix the invisible walls, resolving disagreements in favour
    /// of OPEN, and quietly undid every one of those seals: the neighbour still said the edge was
    /// open, so the border re-opened and the player could walk off the world (Eddie, Scene 2).
    ///
    /// The reasoning that justified "open wins" was that every one-sided edit in this file is an
    /// insert. That was wrong, and wrong in a way a grep for `openings.remove` could not see: these
    /// six sites mutate a local `op` and assign it back. Hence this, and hence `setSharedEdge`.
    func sealRegionBorder(face: CubeFace, rLo: Int, rHi: Int, cLo: Int, cHi: Int) {
        for r in rLo...rHi {
            setSharedEdge(face: face, row: r, col: cLo, .west, open: false)
            setSharedEdge(face: face, row: r, col: cHi, .east, open: false)
        }
        for c in cLo...cHi {
            setSharedEdge(face: face, row: rLo, col: c, .north, open: false)
            setSharedEdge(face: face, row: rHi, col: c, .south, open: false)
        }
    }

    func setSharedEdge(face: CubeFace, row: Int, col: Int, _ dir: SurfaceDirection, open: Bool) {
        let mask: DirectionMask = dir == .north ? .north : dir == .south ? .south : dir == .west ? .west : .east
        guard let (ci, fi) = faceletAt(face: face, row: row, col: col) else { return }
        // Closing an edge must clear it from openEdges too. That mask means "fully open, no geometry
        // at all" (a merged room's interior) and `edgeAllows` checks it FIRST — so an edge closed
        // only in `openings` stayed walkable, and a sealed border made of such tiles still let the
        // player out. Opening does NOT set it: a gateway is not a room.
        if open { cubies[ci].facelets[fi].mazeTile.openings.insert(mask) }
        else {
            cubies[ci].facelets[fi].mazeTile.openings.remove(mask)
            cubies[ci].facelets[fi].mazeTile.openEdges.remove(mask)
        }

        let (dr, dc) = dir == .north ? (-1, 0) : dir == .south ? (1, 0) : dir == .west ? (0, -1) : (0, 1)
        let nr = row + dr, nc = col + dc
        let far: (face: CubeFace, row: Int, col: Int, back: SurfaceDirection)
        if nr >= 0, nr < size, nc >= 0, nc < size {
            far = (face, nr, nc, dir.opposite)
        } else {
            let cr = edgeCrossing(face: face, direction: dir, row: row, col: col)
            far = (cr.face, cr.row, cr.col, cr.facing.opposite)
        }
        guard let (nci, nfi) = faceletAt(face: far.face, row: far.row, col: far.col) else { return }
        let backMask: DirectionMask = far.back == .north ? .north : far.back == .south ? .south
                                    : far.back == .west ? .west : .east
        if open { cubies[nci].facelets[nfi].mazeTile.openings.insert(backMask) }
        else {
            cubies[nci].facelets[nfi].mazeTile.openings.remove(backMask)
            cubies[nci].facelets[nfi].mazeTile.openEdges.remove(backMask)
        }
    }

    private func stampSceneFour() {
        let n = size, c = n / 2
        wallStyle = .dressed

        // Reveal EVERY face. The anchors are deliberately spread across the world so releasing them
        // circumnavigates it, and the script asks for "fog of discovery: minimal or disabled" — a
        // world you are meant to walk right around should not be hidden from you.
        for face in CubeFace.allCases {
            for r in 0..<n {
                for col in 0..<n {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: col) else { continue }
                    cubies[ci].facelets[fi].tileState = .discovered
                    cubies[ci].facelets[fi].discoveryAmount = 1.0
                    cubies[ci].facelets[fi].mazeTile.wallType = 0
                }
            }
        }
        for r in 0..<n {
            for col in 0..<n {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { continue }
                cubies[ci].facelets[fi].tileState = .discovered
                cubies[ci].facelets[fi].discoveryAmount = 1.0
                cubies[ci].facelets[fi].mazeTile.wallType = 0
            }
        }

        // The player TWISTS here, so the slab that moves is the one under their feet: the outer slice
        // of the face they walk. Everything the scene needs — portal, route, bonds — is arranged
        // around that one slab.
        let (tAxis, tIndex) = sliceAxisAndIndex(for: .positiveZ)
        scriptedTwistSlice = (axis: tAxis, index: tIndex, clockwise: false)   // used by the debug replay key

        // ── THE MISALIGNED ROUTE (Scene 4's actual puzzle) ─────────────────────────────────────
        // "A portal is present, but the maze does not connect to it. The necessary route already
        // exists in pieces… the maze route leading toward it terminates against a closed wall at the
        // boundary between the current outer slice and the rest of the world."
        //
        // That boundary is the only thing a turn can change. Measured: the slab is the WHOLE +Z face
        // plus a one-tile ring around it (five tiles on each side face); everything in it rotates
        // together, so within-+Z reachability is untouched by a turn. The 20 places where that ring
        // meets the static shell are the entire editable surface, and a 90° turn slides each ring
        // tile a quarter of the way round — so a doorway that opened onto a dead end now opens onto
        // somewhere else entirely.
        //
        // So: the portal's corner of +Z is walled off from the rest of the face, and its ONE way out
        // is a single ring tile whose along-ring edges are shut. Before the turn that tile's outer
        // door faces a sealed pocket — the route reaching the boundary and stopping, which is what
        // the player is meant to walk up to and read. After the turn the same door faces the live
        // shell, and the world is joined up. Nothing is created; a piece is brought into line.
        let portalCorner = [(0, 0), (0, 1), (1, 0), (1, 1)]
        for (r, cc) in portalCorner {
            // Seal the corner from the REST of +Z (its own four tiles stay open to each other).
            for (dir, dr, dc) in [(SurfaceDirection.north, -1, 0), (.south, 1, 0), (.west, 0, -1), (.east, 0, 1)] {
                let nr = r + dr, nc = cc + dc
                let insideCorner = portalCorner.contains { $0 == (nr, nc) }
                let leavesFace = nr < 0 || nr >= n || nc < 0 || nc >= n
                if insideCorner { setSharedEdge(face: .positiveZ, row: r, col: cc, dir, open: true) }
                else if !leavesFace { setSharedEdge(face: .positiveZ, row: r, col: cc, dir, open: false) }
                else { setSharedEdge(face: .positiveZ, row: r, col: cc, dir, open: false) }
            }
        }
        // The one way out: west from +Z(1,0) onto the ring tile -X(1,4).
        setSharedEdge(face: .positiveZ, row: 1, col: 0, .west, open: true)
        // That ring tile is a doorway, not a corridor: shut along the ring so it cannot be walked
        // around to, and open OUTWARD so the route continues — into a pocket, for now.
        setSharedEdge(face: .negativeX, row: 1, col: 4, .north, open: false)
        setSharedEdge(face: .negativeX, row: 1, col: 4, .south, open: false)
        setSharedEdge(face: .negativeX, row: 1, col: 4, .west, open: true)
        // The pocket it currently opens onto — one tile, sealed on every other side. This is the
        // "closed wall at the boundary" the script asks the player to find.
        for dir in [SurfaceDirection.north, .south, .west] {
            setSharedEdge(face: .negativeX, row: 1, col: 3, dir, open: false)
        }
        // Where that same doorway lands after a 90° turn (measured, not derived): -Y(4,3), opening
        // onto -Y(3,3). Make sure THAT tile is joined to the shell, so the turn completes the route.
        for dir in [SurfaceDirection.north, .south, .west, .east] {
            setSharedEdge(face: .negativeY, row: 3, col: 3, dir, open: true)
        }

        // The vessel stands BESIDE the arrival — "met before anything else" — so guarantee that one
        // step rather than hoping the generated maze provides it.
        setSharedEdge(face: .positiveZ, row: min(n - 1, c + 1), col: c, .north, open: true)

        // Sealing the portal's corner can ORPHAN tiles that only reached the rest of the face
        // THROUGH it — which is exactly what happened: the vessel at the centre of +Z, and the two
        // tiles beside the corner, were cut off along with the portal, so the scene had a puzzle
        // piece the player could not walk to (Eddie: "I don't see how to get to the vessel").
        //
        // Repair afterwards rather than trying to author around it: flood from the spawn and open
        // one edge from any stranded tile back toward reached ground. The portal corner is exempt —
        // being unreachable is its entire job.
        var reached = Set<[Int]>([[min(n - 1, c + 1), c]])
        var frontier = Array(reached)
        while let t = frontier.popLast() {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: t[0], col: t[1]) else { continue }
            let op = cubies[ci].facelets[fi].mazeTile.openings
            for (mask, dr, dc) in [(DirectionMask.north, -1, 0), (.south, 1, 0), (.west, 0, -1), (.east, 0, 1)]
            where op.contains(mask) {
                let nt = [t[0] + dr, t[1] + dc]
                guard nt[0] >= 0, nt[0] < n, nt[1] >= 0, nt[1] < n, !reached.contains(nt) else { continue }
                reached.insert(nt); frontier.append(nt)
            }
        }
        for r in 0..<n {
            for cc in 0..<n where !reached.contains([r, cc]) && !portalCorner.contains(where: { $0 == (r, cc) }) {
                for (dir, dr, dc) in [(SurfaceDirection.north, -1, 0), (.south, 1, 0), (.west, 0, -1), (.east, 0, 1)] {
                    let nt = [r + dr, cc + dc]
                    guard reached.contains(nt), !portalCorner.contains(where: { $0 == (nt[0], nt[1]) }) else { continue }
                    setSharedEdge(face: .positiveZ, row: r, col: cc, dir, open: true)
                    reached.insert([r, cc])
                    break
                }
            }
        }

        // Arrival, and the gate it cannot yet reach.
        spawnLocation = (face: .positiveZ, row: min(n - 1, c + 1), col: c, facing: .n)
        var portalCubie: Int? = nil
        if let (ci, fi) = faceletAt(face: .positiveZ, row: max(0, c - 1), col: max(0, c - 1)) {
            cubies[ci].facelets[fi].props.append(
                Prop(kind: .portal, subRow: 1, subCol: 1, facing: .s, state: 1, transition: .push))
            styledPortals.append(StyledPortal(ci: ci, fi: fi, facing: .s, fieldStyle: 2))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalRing, subRow: 1, subCol: 1))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .s, state: 2))
            // NOT sealed. "A portal is present, but the maze does not connect to it" — the obstacle
            // is the route, not a dark door, and two locks at once would blur the one idea the turn
            // is meant to land. It is lit and alive from the moment the player arrives, and simply
            // cannot be walked to.
            portalCubie = ci
        }

        // The layered vessel (Scene 4D): the object from Scene 1, arranged differently — three major
        // rings whose luminous seams do not align, and which come home one at a time as the anchors
        // release. It reflects the state of the lock, so it can be READ from across the world before
        // the player has any idea what a bond is. Stands beside the arrival, met before anything else.
        if let (ci, fi) = faceletAt(face: .positiveZ, row: c, col: c) {
            var vessel = Prop(kind: .layeredVessel, subRow: 1, subCol: 1, facing: .s)
            vessel.anim = 0                              // rings aligned so far, 0…3
            cubies[ci].facelets[fi].props.append(vessel)
        }

        // THREE ANCHORS, on three different faces, so releasing them circumnavigates the world.
        // Each is a switch (a plate with a recessed control — the same interaction, and it already
        // has the engaged/flush animation), and each anchors one bond.
        let anchorSpots: [(CubeFace, Int, Int)] = [
            (.negativeZ, c, c),          // directly opposite: the far side
            (.positiveY, c, c),          // over the top edge
            (.negativeY, c, c),          // and under the bottom
        ]
        guard let pc = portalCubie else { return }
        for (i, spot) in anchorSpots.enumerated() {
            guard let (ci, fi) = faceletAt(face: spot.0, row: spot.1, col: spot.2) else { continue }
            cubies[ci].facelets[fi].tileState = .discovered
            cubies[ci].facelets[fi].discoveryAmount = 1.0
            cubies[ci].facelets[fi].props.append(Prop(kind: .switchBase, subRow: 1, subCol: 1, facing: .n))
            var plate = Prop(kind: .anchor, subRow: 1, subCol: 1, facing: .n, state: i + 1)
            plate.anim = 1                          // 1 = still holding its bond; 0 = released
            cubies[ci].facelets[fi].props.append(plate)
            // One bond per anchor, straddling the twistable slab: the portal's cubie is inside it,
            // the anchor's is outside, so `canRotateSlice` refuses while ANY of the three remain.
            addBond([pc, ci])
        }
    }

    private func stampSceneTwo() {
        let n = size, c = n / 2
        let R = 5                                            // play region half-extent → an (2R+1)² arena
        let rLo = max(0, c - R), rHi = min(n - 1, c + R)
        let cLo = max(0, c - R), cHi = min(n - 1, c + R)
        wallStyle = .dressed                                 // ruined stone, re-derived from topology (twist-safe)

        // A clearing at the centre — done BEFORE sealing so it can't reopen the region wall.
        stampRoom(face: .positiveZ, top: max(rLo, c - 1), left: max(cLo, c - 1), height: 3, width: 3)

        for r in rLo...rHi {
            for col in cLo...cHi {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { continue }
                var op = cubies[ci].facelets[fi].mazeTile.openings
                if r == rLo { op.remove(.north) }             // seal the region border
                if r == rHi { op.remove(.south) }
                if col == cLo { op.remove(.west) }
                if col == cHi { op.remove(.east) }
                cubies[ci].facelets[fi].mazeTile.openings = op
                cubies[ci].facelets[fi].tileState = .discovered
                cubies[ci].facelets[fi].discoveryAmount = 1.0
                // Scene 2's ruin gradient runs the OPPOSITE way to the garden's: the centre is the
                // most collapsed ("age has radiated outward from the centre") and the perimeter is
                // nearly intact. wallType 0 = cleanest … 3 = most broken.
                let d = min(min(r - rLo, rHi - r), min(col - cLo, cHi - col))
                cubies[ci].facelets[fi].mazeTile.wallType = UInt8(d >= 4 ? 0 : (d == 3 ? 1 : (d >= 1 ? 2 : 3)))
            }
        }

        // Carve the spine so the puzzle is solvable through the procedural maze: the spawn row, the
        // four corridors out to the corner switches, and the spur north to the central plinth.
        let spread = 3
        var spine = Set<[Int]>()
        for col in (c - spread)...(c + spread) { spine.insert([c, col]) }
        for row in (c - spread)...(c + spread) { spine.insert([row, c - spread]); spine.insert([row, c + spread]) }
        for row in (c - spread)...c { spine.insert([row, c]) }
        for rc in spine {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: rc[0], col: rc[1]) else { continue }
            var op = cubies[ci].facelets[fi].mazeTile.openings
            if spine.contains([rc[0] - 1, rc[1]]) { op.insert(.north) }
            if spine.contains([rc[0] + 1, rc[1]]) { op.insert(.south) }
            if spine.contains([rc[0], rc[1] - 1]) { op.insert(.west) }
            if spine.contains([rc[0], rc[1] + 1]) { op.insert(.east) }
            cubies[ci].facelets[fi].mazeTile.openings = op
            cubies[ci].facelets[fi].mazeTile.openEdges = op
        }

        // The four corner switches — three engaged, the fourth off (the one to find). Reuses the
        // proven switch cap/base pair and the shared switchMask() bookkeeping.
        let switchSpots: [(Int, Int, Int, Int)] = [
            (c - spread, c - spread, 1, 1), (c - spread, c + spread, 1, 2),
            (c + spread, c - spread, 1, 3), (c + spread, c + spread, 0, 4),
        ]
        for (r, col, engaged, ordinal) in switchSpots {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { continue }
            cubies[ci].facelets[fi].props.append(Prop(kind: .switchBase, subRow: 1, subCol: 1, facing: .n))
            var cap = Prop(kind: .switchCap, subRow: 1, subCol: 1, facing: .n, state: ordinal)
            cap.anim = Float(engaged); cap.alignAnim = Float(engaged)
            cubies[ci].facelets[fi].props.append(cap)
        }

        // The control plinth — a map of CONDITIONS, not of the maze: one dot per switch, filled when
        // that switch is engaged. `updateDoorPlinths` drives it from switchMask().
        //
        // It stands TWO tiles from where the assembly arrives (Eddie, playtest): the turn happens at
        // the world's edge, and from the middle of the face that is ~100 m away — far enough that the
        // payoff was easy to miss entirely, and invisible if you happened to be facing the other way.
        // Standing here you commit the turn and the exit swings in directly ahead of you, with only
        // the approach corridor between. It also makes the script's "nothing stands behind it" literal:
        // the empty ground beyond the plinth is exactly where the way onward will appear.
        if let (ci, fi) = faceletAt(face: .positiveZ, row: c, col: 2) {
            cubies[ci].facelets[fi].props.append(
                Prop(kind: .plinth, subRow: 1, subCol: 1, facing: .w, state: TextureLoader.progressMaskBase + 0b0111))
            progressPlinth = (ci, fi)
        }

        // "The player stands near the southern edge of a broad, irregular clearing… Directly ahead
        // stands a single stone plinth." Arrive south of centre looking north, across the clearing to
        // the plinth — NOT at the hidden chamber, which is where the default arrival would land.
        spawnLocation = (face: .positiveZ, row: min(n - 1, c + 1), col: c, facing: .n)

        // SCENE 2I — the approach that only completes after the turn. "A route that previously
        // terminated at the far wall now continues onto the rotated slice."
        //
        // The assembly arrives in column 0 of this face (measured: the twist slab's `+Z` column), which
        // is outside the sealed play region — so a corridor runs west out of the clearing, breaches the
        // region border, and then runs the full height of column 1, ending against the world's edge.
        // Before the turn it is a dead end against blank wall. After it, column 0 holds the assembly,
        // whose tiles are open on all four sides, and the corridor simply continues onto them.
        //
        // The column-1 run is deliberately full height rather than a single spur: the rotation remaps
        // rows as well as faces, so authoring one row would be betting on where the assembly lands.
        // Meeting it along the whole edge is robust to that, and reads as a perimeter route.
        let approachRow = c
        for r in 0..<n {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: 1) else { continue }
            var op: DirectionMask = [.east, .west]                 // through to the region, and out to the edge
            if r > 0 { op.insert(.north) }
            if r < n - 1 { op.insert(.south) }
            cubies[ci].facelets[fi].mazeTile.openings = op
            cubies[ci].facelets[fi].mazeTile.openEdges = op
            cubies[ci].facelets[fi].tileState = .discovered
            cubies[ci].facelets[fi].discoveryAmount = 1.0
            cubies[ci].facelets[fi].mazeTile.wallType = 0          // the perimeter is the best-preserved stone
        }
        // Run the approach east from that corridor to the spine's western arm, breaching the region's
        // sealed west border on the way. INSERT rather than assign: this row crosses the north–south
        // corridor that serves the western corner switches, and replacing its openings would sever it.
        for col in 1...(c - spread) {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: approachRow, col: col) else { continue }
            cubies[ci].facelets[fi].mazeTile.openings.insert(.east)
            cubies[ci].facelets[fi].mazeTile.openings.insert(.west)
            cubies[ci].facelets[fi].mazeTile.openEdges.insert(.east)
            cubies[ci].facelets[fi].mazeTile.openEdges.insert(.west)
            cubies[ci].facelets[fi].tileState = .discovered
            cubies[ci].facelets[fi].discoveryAmount = 1.0
        }

        // Reveal the ENTIRE turning slab (Eddie, playtest: "as the slice rotates, it is very
        // transparent" — a band of floating fragments with sky between them).
        //
        // A slab is a plate: its `-X` face is the outer shell, and its RIM is one column each of `+Z`,
        // `-Z`, `+Y` and `-Y`. Only the `+Z` column and the three assembly tiles had ever been
        // revealed, and undiscovered tiles render nothing — so most of the plate was simply absent.
        // Revealing `-X` alone does not help either: its normal is parallel to the rotation axis, so
        // it never tilts into view; it is the rim that sweeps past the player.
        //
        // So: reveal every tile whose cubie lies in the slab, on whichever face it belongs to. The
        // plate then turns as a continuous surface, with its own dressed walls riding it.
        // Named BEFORE the reveal below, which needs to know which slab is the turning one. (Verified
        // by testSceneTwoHiddenFaceTurnsIntoView: this slab, counter-clockwise, lands `+Y` on `+Z`.)
        let hidden = sceneTwoHiddenSlice()
        scriptedTwistSlice = (axis: hidden.axis, index: hidden.index, clockwise: false)
        let turning = hidden
        for face in CubeFace.allCases {
            for r in 0..<n {
                for col in 0..<n {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: col) else { continue }
                    let p = cubies[ci].position
                    let inSlab = (turning.axis == 0 && p.x == Int32(turning.index))
                              || (turning.axis == 1 && p.y == Int32(turning.index))
                              || (turning.axis == 2 && p.z == Int32(turning.index))   // (axis is 0 today; kept general)
                    guard inSlab, cubies[ci].facelets[fi].tileState != .discovered else { continue }
                    cubies[ci].facelets[fi].tileState = .discovered
                    cubies[ci].facelets[fi].discoveryAmount = 1.0
                    cubies[ci].facelets[fi].mazeTile.wallType = 0   // the outer shell is the best-preserved stone
                    // Terrain by role, now that the cut faces carry their own plating:
                    //  • `-X` — the slab's outer SHELL. Plated: it is the underside of a slab of
                    //    world, and reads as built structure rather than a floating lawn.
                    //  • `+Z` — playable ground the player walks. Left as maze, untouched.
                    //  • the rest — the slab's RIM columns. Ordinary ground, so grass: these are the
                    //    world's surface seen edge-on, not part of the machine (Eddie).
                    switch face {
                    case .negativeX: cubies[ci].facelets[fi].terrain = .plating
                    case .positiveZ: break
                    default:         cubies[ci].facelets[fi].terrain = .grass
                    }
                }
            }
        }

        stampSceneTwoHiddenAssembly()

        // The LOCK. Without a bond the rotation control could be raised before the puzzle is solved
        // (the gate is `bondedGroups.isEmpty`), and the twist itself would already be legal. Bond the
        // hidden chamber's cubie to the central plinth's: the group STRADDLES the twistable slab, so
        // `canRotateSlice` refuses the turn, and dissolving it on the fourth switch is what makes the
        // world movable. Stored in `templeDoorBond` so disengaging a switch re-applies it.
        if let pp = progressPlinth, let chamberCI = sealedPortalCubies.first {
            let bond: Set<Int> = [chamberCI, pp.ci]
            addBond(bond)
            templeDoorBond = bond
        }

        // Two-sided, and LAST, so nothing carved above can leave a way out and
        // `reconcileSharedEdges` has nothing to disagree with.
        sealRegionBorder(face: .positiveZ, rLo: rLo, rHi: rHi, cLo: cLo, cHi: cHi)
        // …and EVERY other face too. Sealing the play face was enough while the world stood still,
        // but the whole point of this scene is that a slab TURNS: tiles from other faces swing into
        // reach, and those had never been sealed, so the turn handed the player a way to walk
        // straight off the world (Eddie). Edges travel with their tiles through a twist, so sealing
        // each face now keeps every face an island however the world is rearranged.
        for face in CubeFace.allCases where face != .positiveZ {
            sealRegionBorder(face: face, rLo: 0, rHi: n - 1, cLo: 0, cHi: n - 1)
        }
    }

    /// The outer X-slab that carries the hidden face into view, and the `+Y` tiles riding it.
    /// Derived from live cubie positions rather than hardcoded, so it stays correct at any size.
    /// Returns the slab index plus the hidden-face tiles in it, ordered along the strip.
    func sceneTwoHiddenSlice() -> (axis: Int, index: Int, strip: [(row: Int, col: Int)]) {
        let n = size
        let index = 0                                     // the x == 0 outer slab
        var strip: [(row: Int, col: Int)] = []
        for r in 0..<n {
            for col in 0..<n {
                guard let (ci, _) = faceletAt(face: .positiveY, row: r, col: col) else { continue }
                if cubies[ci].position.x == Int32(index) { strip.append((r, col)) }
            }
        }
        return (0, index, strip)
    }

    /// The exit, built on the hidden `+Y` face from the first frame: two obelisks flanking a portal
    /// chamber, sealed and dark until the slab turns. They ride their facelets, so the twist carries
    /// them onto `+Z` with no spawning.
    private func stampSceneTwoHiddenAssembly() {
        let slice = sceneTwoHiddenSlice()
        guard slice.strip.count >= 3 else { return }
        // Centre three tiles of the strip: obelisk · chamber · obelisk.
        let mid = slice.strip.count / 2
        let trio = [slice.strip[mid - 1], slice.strip[mid], slice.strip[mid + 1]]
        for (i, t) in trio.enumerated() {
            guard let (ci, fi) = faceletAt(face: .positiveY, row: t.row, col: t.col) else { continue }
            cubies[ci].facelets[fi].tileState = .discovered   // it exists; it is simply facing away
            cubies[ci].facelets[fi].discoveryAmount = 1.0
            cubies[ci].facelets[fi].mazeTile.openings = [.north, .east, .south, .west]
            cubies[ci].facelets[fi].mazeTile.openEdges = [.north, .east, .south, .west]
            if i == 1 {
                // The chamber: a DOWNWARD elevator into the world's interior (Scene 3).
                // Faces EAST — the side the player arrives from, since the control plinth stands two
                // tiles east of where this lands. A prop's `facing` is NOT rotated by a twist (only
                // its tile's openings and uv are), so this is authored in FINAL orientation: pointing
                // north here would leave the chamber edge-on to the player after the turn.
                cubies[ci].facelets[fi].props.append(
                    Prop(kind: .portal, subRow: 1, subCol: 1, facing: .e, state: 1, transition: .push))
                styledPortals.append(StyledPortal(ci: ci, fi: fi, facing: .e, fieldStyle: 3))
                cubies[ci].facelets[fi].props.append(Prop(kind: .portalRing, subRow: 1, subCol: 1))
                cubies[ci].facelets[fi].props.append(Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .e, state: 3))
                sealedPortalCubies.insert(ci)     // dark until the slab has turned
            } else {
                cubies[ci].facelets[fi].props.append(Prop(kind: .obelisk, subRow: 1, subCol: 1))
            }
        }
    }

    /// M20 dev tool — the **gallery**: a flat grass grid with one prop/foliage variant per cell,
    /// laid out in a documented order (see Gallery Layout doc) so assets can be evaluated in near-
    /// isolation. The debug HUD (H) names the item on the player's tile. Sealed + region-revealed
    /// like the entry world. Catalog order = the grid reading order (row-major, near row first).
    // (LeafSet bushes + misc_greenery cards were removed from the gallery when Eddie deleted those
    //  asset folders — they'd only render as blank fallback cells now. Repoint here if new card
    //  assets land; the .foliageCard / .greeneryCard prop kinds + shader materials still exist.)
    static let galleryCatalog: [(PropKind, Int)] = [
        (.topiary, 0), (.obelisk, 0), (.chest, 0), (.dial, 0), (.dial, 1),
        (.glyph, 0), (.tree, 0), (.tree, 1), (.tree, 2), (.treeTrunk, 0),
        (.boulder, 0), (.boulder, 1), (.boulder, 2),
        // M16.6: every Builder-plinth glyph, so it can be evaluated up close in isolation
        // (state = TextureLoader.CausticSymbol: 0 blank, 1–4 ordinals, 5 swirl, 6 portal, 7 square).
        (.plinth, 0), (.plinth, 1), (.plinth, 2), (.plinth, 3),
        (.plinth, 4), (.plinth, 5), (.plinth, 6), (.plinth, 7),
        (.plinth, 8), (.plinth, 9),   // three-of-four (locked) + four-filled (ready)
        // Phase 2 — the alignment cylinder (the square/world drum). It renders from the plinth-top
        // height, so pair it with a plinth (next cell) to read it grounded.
        (.plinth, 7), (.alignmentCylinder, 5),
    ]

    /// M20 — WenrexaTrees grouped into single trees rendered as **intersecting billboard cards**
    /// (each entry = the sprite slices, in view order, that form one tree). Eddie's groupings so far;
    /// the rest are singletons pending his mapping. (Slice = filename−1: "01"→0 … "27"→26.)
    /// M20: emptied — the WenrexaTrees billboard sprites were removed (Eddie), so no tree groups are
    /// placed in the gallery. (`placeTreeGroup` / `.treeBillboard` remain as inert scaffolding.)
    static let treeGroups: [[Int]] = []

    /// Display names for `treeGroups` (same order). Shown in the gallery HUD.
    static let treeGroupNames = [
        "Tall Purple", "Wide Purple", "Dead", "Orange", "Dark Red",
        "Tall Green", "Dark Green", "Red Tree", "Dark Yellow",
    ]

    /// Place one WenrexaTrees "tree" (a group of view-slices) as intersecting billboard cards at a
    /// tile — the cards share the centre and fan out by even angles so the tree reads from any side.
    private func placeTreeGroup(_ slices: [Int], face: CubeFace, row: Int, col: Int) {
        guard let (ci, fi) = faceletAt(face: face, row: row, col: col), !slices.isEmpty else { return }
        let n = slices.count
        for (i, slice) in slices.enumerated() {
            // Spread over 180° (cards are double-sided, so 180° covers all directions).
            let angle = Float(i) * 180.0 / Float(n)
            cubies[ci].facelets[fi].props.append(Prop(kind: .treeBillboard, subRow: 1, subCol: 1, state: slice, viewAngle: angle))
        }
    }
    private func stampGallery() {
        let n = size, c = n / 2
        let cols = 8
        let catalog = Self.galleryCatalog
        let groups = Self.treeGroups
        let total = catalog.count + groups.count                     // single items + one cell per tree group
        let rows = (total + cols - 1) / cols
        let gTop = max(1, c - rows), gLeft = max(1, c - cols / 2)     // grid sits just north of spawn
        let rLo = gTop - 1, rHi = min(n - 1, c + 1)
        let cLo = gLeft - 1, cHi = min(n - 1, gLeft + cols)
        let all: DirectionMask = [.north, .east, .south, .west]
        for r in rLo...rHi {
            for col in cLo...cHi {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { continue }
                var op = all
                if r == rLo { op.remove(.north) }
                if r == rHi { op.remove(.south) }
                if col == cLo { op.remove(.west) }
                if col == cHi { op.remove(.east) }
                cubies[ci].facelets[fi].mazeTile.openings = op
                cubies[ci].facelets[fi].mazeTile.openEdges = op
                cubies[ci].facelets[fi].terrain = .grass
                cubies[ci].facelets[fi].tileState = .discovered
                cubies[ci].facelets[fi].discoveryAmount = 1.0
            }
        }
        func cell(_ k: Int) -> (Int, Int) { (gTop + k / cols, gLeft + k % cols) }
        for (k, item) in catalog.enumerated() {
            let (gr, gc) = cell(k)
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: gr, col: gc) else { continue }
            var pr = Prop(kind: item.0, subRow: 1, subCol: 1, facing: .s, state: item.1)
            // Show the alignment cylinder in its finished state (fully risen + square whole), so the
            // gallery reads it as a static form rather than mid-animation.
            if item.0 == .alignmentCylinder { pr.anim = 1; pr.alignAnim = 1 }
            cubies[ci].facelets[fi].props.append(pr)
        }
        for (j, group) in groups.enumerated() {   // WenrexaTrees, each group = one intersecting-card tree
            let (gr, gc) = cell(catalog.count + j)
            placeTreeGroup(group, face: .positiveZ, row: gr, col: gc)
        }
        // Return portal beside the spawn (the player spawns at the face centre, facing the grid).
        if let (ci, fi) = faceletAt(face: .positiveZ, row: min(n - 1, c + 1), col: c) {
            cubies[ci].facelets[fi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))
        }

        // Two-sided, and LAST, so nothing carved above can leave a way out and
        // `reconcileSharedEdges` has nothing to disagree with.
        sealRegionBorder(face: .positiveZ, rLo: rLo, rHi: rHi, cLo: cLo, cHi: cHi)
    }

    /// M20 (Eddie) — the PORTAL HUB: a flat grass plaza with a 3×3 grid of simple TARDIS portals, each
    /// with a wooden SIGNPOST naming its destination, so the dev worlds are navigable by walking up and
    /// reading rather than remembering `O I B V Y 1-4`. Spawn is south of the grid; the signs face the
    /// player. Portal + sign `state` = the destination index (== `Renderer.portalDestinations` /
    /// `destinationLabels`), so the 9 cells map 1:1 to the 9 labeled destinations.
    private func stampPortalHub() {
        let n = size, c = n / 2
        let all: DirectionMask = [.north, .east, .south, .west]
        let rLo = max(0, c - 6), rHi = min(n - 1, c + 2)
        let cLo = max(0, c - 5), cHi = min(n - 1, c + 5)
        for r in rLo...rHi {
            for col in cLo...cHi {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { continue }
                var op = all
                if r == rLo { op.remove(.north) }
                if r == rHi { op.remove(.south) }
                if col == cLo { op.remove(.west) }
                if col == cHi { op.remove(.east) }
                cubies[ci].facelets[fi].mazeTile.openings = op
                cubies[ci].facelets[fi].mazeTile.openEdges = op
                cubies[ci].facelets[fi].terrain = .grass
                cubies[ci].facelets[fi].tileState = .discovered
                cubies[ci].facelets[fi].discoveryAmount = 1.0
            }
        }
        // Destination indices into Renderer.portalDestinations, laid out in a grid NORTH of spawn
        // (spawn = face centre, kept clear). Index 9 is the hub itself, so it is skipped. Dev
        // navigation: the prologue's scenes chain forward through their own portals, and this hub
        // exists so any of them can be reached directly while building.
        let hubDestinations = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13]
        // Four rows now — the 3×4 grid filled up at twelve, and Scene 3 is the thirteenth.
        let gridRows = [c - 5, c - 3, c - 1, c + 1], gridCols = [c - 5, c - 2, c + 1, c + 4]
        for (slot, idx) in hubDestinations.enumerated() {
            let gr = gridRows[slot / 4], gc = gridCols[slot % 4]
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: gr, col: gc) else { continue }
            // `.push`: stepping off the hub onto a destination ENTERS it, so that world's return
            // portal pops you back to the hub. (Phase 0 — this used to be inferred by the Renderer
            // recognising the name "portal-hub"; the portal now says so itself.)
            cubies[ci].facelets[fi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n, state: idx, transition: .push))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))
            // Signpost on the south sub-cell of the same tile, facing the approaching player.
            cubies[ci].facelets[fi].props.append(Prop(kind: .signpost, subRow: 2, subCol: 1, facing: .n, state: idx))
        }

        // Two-sided, and LAST, so nothing carved above can leave a way out and
        // `reconcileSharedEdges` has nothing to disagree with.
        sealRegionBorder(face: .positiveZ, rLo: rLo, rHi: rHi, cLo: cLo, cHi: cHi)
    }

    /// M20 (Eddie) — three PORTAL-STYLE prototypes in a showroom revealed just NORTH of the catalog
    /// (we're retiring the TARDIS): an ELEVATOR (outer world → temple), two SPOT-TO-SPOT energy veils
    /// (a place on the world → another place / its moon), and a LEVEL-TO-LEVEL stone arch with a
    /// starfield fill (solved level → next). Imported model indices come from the Renderer (which owns
    /// the registry); pass `nil` for any it couldn't resolve and that part is skipped.
    func stampGalleryPortals(column: Int?, archRuins: Int?) {
        let n = size, c = n / 2
        let rLo = 3, rHi = 6                                  // showroom rows, north of the catalog (7–13)
        let cLo = max(1, c - 4), cHi = min(n - 1, c + 4)      // cols 8–16
        let all: DirectionMask = [.north, .east, .south, .west]
        for r in rLo...rHi {
            for col in cLo...cHi {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { continue }
                var op = all
                if r == rLo { op.remove(.north) }
                if col == cLo { op.remove(.west) }
                if col == cHi { op.remove(.east) }
                cubies[ci].facelets[fi].mazeTile.openings = op
                cubies[ci].facelets[fi].mazeTile.openEdges = op
                cubies[ci].facelets[fi].terrain = .grass
                cubies[ci].facelets[fi].tileState = .discovered
                cubies[ci].facelets[fi].discoveryAmount = 1.0
            }
        }
        // Open the seam between the showroom (row rHi) and the catalog room (row 7) so you can walk up.
        for col in cLo...cHi {
            if let (ci, fi) = faceletAt(face: .positiveZ, row: rHi, col: col) {
                cubies[ci].facelets[fi].mazeTile.openings.insert(.south); cubies[ci].facelets[fi].mazeTile.openEdges.insert(.south)
            }
            if let (ci, fi) = faceletAt(face: .positiveZ, row: 7, col: col) {
                cubies[ci].facelets[fi].mazeTile.openings.insert(.north); cubies[ci].facelets[fi].mazeTile.openEdges.insert(.north)
            }
        }
        let row = 4
        func add(_ col: Int, _ p: Prop) {
            if let (ci, fi) = faceletAt(face: .positiveZ, row: row, col: col) { cubies[ci].facelets[fi].props.append(p) }
        }
        func part(_ idx: Int?, _ col: Int, _ scale: Float, _ ox: Float, _ oy: Float, _ sink: Float = 0, _ facing: Heading8 = .s) {
            guard let i = idx else { return }
            var p = Prop(kind: .importedFoliage, subRow: 1, subCol: 1, facing: facing, state: i, extraScale: scale)
            p.offsetX = ox; p.offsetY = oy; p.sink = sink
            add(col, p)
        }
        func veil(_ col: Int, _ style: Int) {
            add(col, Prop(kind: .portalRing, subRow: 1, subCol: 1))                                   // base glow
            add(col, Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .s, state: style))        // energy surface
        }

        // (1) ELEVATOR (outer world ↔ temple) — a flat energy CURTAIN wedged between two columns, on a
        // lit plate. Two variants (Eddie): streaks flow DOWN (style 3, the surface world) and UP (style
        // 4, the temple). The curtain's top is a ragged energy edge (see material 23).
        func elevator(_ col: Int, _ style: Int) {
            add(col, Prop(kind: .portalRing, subRow: 1, subCol: 1))                                   // lit floor plate
            // Two TRANSLUCENT streak layers a little apart in depth (Eddie): a denser back and a
            // thinner front (opacity carried in `alignAnim` → screen-door dither in material 23).
            // Centered, ~10 cm apart (Eddie): 0.1 m ≈ 0.0053u ⇒ ±0.0026u. Opacity (alignAnim) both
            // sets the screen-door translucency AND desyncs the two layers (see material 23).
            var back = Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .s, state: style)
            back.offsetY = -0.0026; back.alignAnim = 0.85
            add(col, back)
            var front = Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .s, state: style)
            front.offsetY = 0.0026; front.alignAnim = 0.55
            add(col, front)
            part(column, col, 0.25, -0.09, 0)                                                         // left jamb column (~4 m)
            part(column, col, 0.25,  0.09, 0)                                                         // right jamb column
        }
        elevator(c - 4, 3)                                                                            // surface (streaks down)
        elevator(c - 2, 4)                                                                            // temple  (streaks up)

        // (2) SPOT-TO-SPOT — two frameless energy veils (blue, pink), each on a glow ring.
        veil(c, 0)
        veil(c + 2, 1)

        // (3) LEVEL-TO-LEVEL at col c+4 — an overgrown arched WALL (a solid panel with a round-arch
        // opening). The field is stretched taller (extraScale) and arch-shaped so it fills the ENTIRE
        // opening up into the curved top. The "Overgrown" model wears its own moss, so no separate vines.
        let aCol = c + 4
        add(aCol, Prop(kind: .portalRing, subRow: 1, subCol: 1))                                      // base glow
        // Rectangular fill, shorter than 4 m so it doesn't stick past the arch top, and centered
        // depthwise IN the opening (offsetY 0 = the arch's mid-plane), not set behind it (Eddie).
        add(aCol, Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .s, state: 2, extraScale: 0.9375))  // ~3.75 m (4 m − 0.25)
        part(archRuins, aCol, 0.24, 0, 0, 0)                                                          // the arched wall
    }

    /// M20 (Eddie) — the imported FRAME of each styled portal: a stone arch (fieldStyle 2) or two
    /// flanking columns (streak elevators, 3/4). The Renderer owns the model indices and calls this
    /// after the world builds (pass `nil` for any not loaded → that frame is skipped). Non-solid, so
    /// you still walk through; always shown (the frame stays even while the energy field is sealed off).
    func stampPortalFrames(column: Int?, archRuins: Int?) {
        defer { markTopologyChanged() }   // PERF: appends props (the home world stamps this lazily, post-boot)
        for e in styledPortals {
            if e.fieldStyle == 2 {                           // ARCH (level-to-level cloud portal)
                guard let a = archRuins else { continue }
                cubies[e.ci].facelets[e.fi].props.append(
                    Prop(kind: .importedFoliage, subRow: 1, subCol: 1, facing: e.facing, state: a, extraScale: 0.24))
            } else {                                         // ELEVATOR — two columns astride the streak curtain
                guard let column = column else { continue }
                let horiz = (e.facing == .n || e.facing == .s)   // doorway runs perpendicular to the facing
                for s in [Float(-0.09), 0.09] {
                    var p = Prop(kind: .importedFoliage, subRow: 1, subCol: 1, facing: .s, state: column, extraScale: 0.25)
                    if horiz { p.offsetX = s } else { p.offsetY = s }
                    cubies[e.ci].facelets[e.fi].props.append(p)
                }
            }
        }
    }

    /// M20 proof — lay `.importedAsset` eval cells (3D models) in their own revealed strip just SOUTH
    /// of the catalog grid, connected to the spawn by a short corridor so the player can walk down to
    /// them. `states` are registry indices into `Renderer.importedProps`; the Renderer owns those
    /// indices, so it calls this after the gallery world is built.
    func stampGalleryImports(_ states: [Int]) {
        guard !states.isEmpty else { return }
        let n = size, c = n / 2
        // Lay the models on a grid with an EMPTY COLUMN between neighbours, forming north–south
        // aisles: you walk an aisle and the models line both sides, each read in near-isolation
        // (they're solid props, so you walk *to* them, not through). Rows are adjacent — a prop only
        // blocks the middle third of its tile, so rows stay passable.
        let colsN = 11                                    // 11 aisled columns × 6 rows = 66 slots ≥ 63
        let rowsN = (states.count + colsN - 1) / colsN
        let left = max(1, c - (colsN - 1))                // model columns: left, left+2, … (span 2n-1)
        let cLo = max(0, left - 1), cHi = min(n - 1, left + 2 * (colsN - 1) + 1)
        let top = c + 1                                   // the catalog room's south row — the join
        let firstRow = top + 1
        let bot = min(n - 1, firstRow + rowsN)            // a walkable rank past the last model row
        func reveal(_ r: Int, _ col: Int, _ op: DirectionMask) {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { return }
            cubies[ci].facelets[fi].mazeTile.openings = op
            cubies[ci].facelets[fi].mazeTile.openEdges = op
            cubies[ci].facelets[fi].terrain = .grass
            cubies[ci].facelets[fi].tileState = .discovered
            cubies[ci].facelets[fi].discoveryAmount = 1.0
        }
        func discovered(_ r: Int, _ col: Int) -> Bool {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { return false }
            return cubies[ci].facelets[fi].tileState == .discovered
        }
        func inBlock(_ r: Int, _ col: Int) -> Bool { r >= top && r <= bot && col >= cLo && col <= cHi }
        // Open an edge only where it leads somewhere real: inside the block, or (along the top rank)
        // into the already-revealed catalog room. Never open into an unrevealed tile — the block is
        // wider than the catalog, so most of its top rank must stay sealed against the fog.
        for r in top...bot {
            for col in cLo...cHi {
                var op: DirectionMask = []
                if inBlock(r - 1, col) || discovered(r - 1, col) { op.insert(.north) }
                if inBlock(r + 1, col) { op.insert(.south) }
                if inBlock(r, col - 1) { op.insert(.west) }
                if inBlock(r, col + 1) { op.insert(.east) }
                reveal(r, col, op)
            }
        }
        // The return portal (stampGallery put it at (c+1, c), directly south of spawn) now sits right
        // on the spawn→models path — you'd teleport home the instant you walked toward them. Move it
        // (and its lamp) to a far corner of the walkway: still an obvious "step here to leave", but
        // off the direct path. The exact portal prop is preserved (its state = destination).
        if let (spci, spfi) = faceletAt(face: .positiveZ, row: min(n - 1, c + 1), col: c),
           let (dsci, dsfi) = faceletAt(face: .positiveZ, row: bot, col: cLo) {
            let moved = cubies[spci].facelets[spfi].props.filter { $0.kind == .portal || $0.kind == .portalLamp }
            if !moved.isEmpty {
                cubies[spci].facelets[spfi].props.removeAll { $0.kind == .portal || $0.kind == .portalLamp }
                cubies[dsci].facelets[dsfi].props.append(contentsOf: moved)
            }
        }
        // One model per grid cell, spaced two columns apart so the aisles stay open.
        for (i, state) in states.enumerated() {
            let gr = firstRow + i / colsN
            let gc = left + 2 * (i % colsN)
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: gr, col: gc) else { continue }
            cubies[ci].facelets[fi].props.append(
                Prop(kind: .importedAsset, subRow: 1, subCol: 1, facing: .s, state: state))
        }
    }

    /// M20 prototype (Eddie) — sample "natural walls" in the gallery: instead of a stone hedge slab, a
    /// maze wall is built from **Ruins `Wall` pieces overgrown by Nature rocks + bushes** (Eddie), so
    /// a structure reads as reclaimed by nature. Lays four **E–W** runs (walk east down a clear lane
    /// alongside each) in a plot east of the catalog: bare wall, lightly-overgrown ruin, heavily-
    /// overgrown ruin, and a rocks+bushes-only ridge (to compare). Gallery scale. Non-solid — walk
    /// through to inspect. Registry indices come from the Renderer (`wallFlora`).
    func stampGalleryWalls(_ flora: GardenFlora) {
        let n = size, c = n / 2
        // A clear grassy plot east of the catalog (cols c+5…), north of the imported-models strip
        // (rows ≤ c so we never collide with the strip at c+1↓). Walls run E–W; you enter the south
        // lane (row c) walking east from spawn, then step north between walls to compare them.
        let pLo = max(1, c - 7), pHi = c                              // rows 5…12 at size 25
        let qLo = min(n - 2, c + 5), qHi = min(n - 2, c + 11)         // cols 17…23 (the wall length)
        guard qLo < qHi, pLo < pHi else { return }
        func inPlot(_ r: Int, _ q: Int) -> Bool { r >= pLo && r <= pHi && q >= qLo && q <= qHi }
        for r in pLo...pHi {
            for q in qLo...qHi {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: q) else { continue }
                var op: DirectionMask = []
                if inPlot(r - 1, q) { op.insert(.north) }
                if inPlot(r + 1, q) { op.insert(.south) }
                if inPlot(r, q - 1) { op.insert(.west) }
                if inPlot(r, q + 1) { op.insert(.east) }
                if r == c && q == qLo { op.insert(.west) }            // entry from the catalog/spawn
                cubies[ci].facelets[fi].mazeTile.openings = op
                cubies[ci].facelets[fi].mazeTile.openEdges = op
                cubies[ci].facelets[fi].terrain = .grass
                cubies[ci].facelets[fi].tileState = .discovered
                cubies[ci].facelets[fi].discoveryAmount = 1.0
            }
        }
        // Open the catalog side of the entry (row c, col qLo-1 → east).
        if let (ci, fi) = faceletAt(face: .positiveZ, row: c, col: qLo - 1) {
            cubies[ci].facelets[fi].mazeTile.openings.insert(.east)
            cubies[ci].facelets[fi].mazeTile.openEdges.insert(.east)
            cubies[ci].facelets[fi].tileState = .discovered
            cubies[ci].facelets[fi].discoveryAmount = 1.0
        }

        func hash(_ a: Int, _ b: Int, _ d: Int) -> UInt32 {
            var v = UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663 ^ d &* 83492791)
            v ^= v >> 15; v = v &* 2246822519; v ^= v >> 13
            return v
        }
        // Eddie: ~4 m walls (was ~16 at full gallery scale — too tall). Derive the scale from a metre
        // target via eyeHeight (1.7 m ≈ 0.09 u); rocks/bushes overgrow the base a bit smaller. Spacing
        // is derived from the size too, so the run stays continuous when the height is retuned.
        let mUnit = worldScale.eyeHeight / 1.7                    // metres → world units
        let tileM = 1.0 / mUnit                                   // a tile is ~18.9 m across
        let wallHeightM: Float = 4.0
        let galleryTarget: Float = 0.85                          // == AssetRegistry.galleryTarget (kept local: test target excludes AssetRegistry)
        let wallScale = wallHeightM * mUnit / galleryTarget
        let rockScale = wallScale * 0.85, bushScale = wallScale * 0.6
        let spread = wallHeightM * mUnit                          // overgrowth scatter across the wall line
        func perTileFor(_ spacingM: Float) -> Int { max(1, Int((tileM / spacingM).rounded())) }
        let wallPT = perTileFor(wallHeightM * 0.55)               // wall pieces overlap into a ridge
        let growthPT = perTileFor(wallHeightM * 0.40)             // rocks/bushes tighter

        // Structural backbone: Ruins `Wall` pieces laid end-to-end along the row (facing .n so their
        // length runs along the wall; if they read rotated, that's the one knob to flip). perTile 2
        // (~9 m) ⇒ they overlap into a continuous wall regardless of exact piece width.
        func placeWalls(row wr: Int, perTile: Int) {
            guard !flora.walls.isEmpty, pLo <= wr, wr <= pHi else { return }
            for q in qLo...qHi {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: wr, col: q) else { continue }
                for k in 0..<perTile {
                    let fx = -0.5 + (Float(k) + 0.5) / Float(perTile)
                    let h = hash(wr &* 131 &+ q &* 17, 100, k &* 7 &+ 1)
                    var p = Prop(kind: .importedFoliage, subRow: 1, subCol: 1, facing: .n,
                                 state: flora.walls[Int(h % UInt32(flora.walls.count))], extraScale: wallScale)
                    p.offsetX = fx; p.offsetY = 0
                    cubies[ci].facelets[fi].props.append(p)
                }
            }
        }
        // Overgrowth: rocks (Nature) + bushes (Nature/Ruins) scattered across the wall line, resting
        // on the ground in front of / behind the wall, so a ruin reads as reclaimed by nature.
        func placeOvergrowth(row wr: Int, perTile: Int, rockPct: Int) {
            guard pLo <= wr, wr <= pHi else { return }
            for q in qLo...qHi {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: wr, col: q) else { continue }
                for k in 0..<perTile {
                    let fx = -0.5 + (Float(k) + 0.5) / Float(perTile)
                    let h = hash(wr &* 131 &+ q &* 17, 200, k &* 7 &+ 5)
                    let useRock = Int(h % 100) < rockPct
                    let pool = useRock ? flora.rocks : flora.bushes
                    guard !pool.isEmpty else { continue }
                    let base = (useRock ? rockScale : bushScale) * (0.8 + Float((h >> 6) % 40) / 100.0)
                    var p = Prop(kind: .importedFoliage, subRow: 1, subCol: 1,
                                 facing: Heading8(rawValue: Int(h % 8)) ?? .n,
                                 state: pool[Int((h >> 8) % UInt32(pool.count))], extraScale: base)
                    p.offsetX = fx
                    p.offsetY = (Float((h >> 3) % 20) / 20.0 - 0.5) * spread   // scatter across the wall
                    p.sink = useRock ? 0.20 : 0.10                             // seat into the ground (no floating)
                    cubies[ci].facelets[fi].props.append(p)
                }
            }
        }
        // A SOLID boulder wall (no brick): the MegaKit big/medium rocks, big and packed with a tight
        // scatter so they overlap into a continuous berm with no breaks (Eddie), plus a few bushes.
        func placeRockWall(row wr: Int, perTile: Int) {
            let rocks = flora.bigRocks.isEmpty ? flora.rocks : flora.bigRocks
            guard !rocks.isEmpty, pLo <= wr, wr <= pHi else { return }
            for q in qLo...qHi {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: wr, col: q) else { continue }
                for k in 0..<perTile {
                    let fx = -0.5 + (Float(k) + 0.5) / Float(perTile)
                    let h = hash(wr &* 131 &+ q &* 17, 300, k &* 7 &+ 5)
                    let bush = Int(h % 100) < 18 && !flora.bushes.isEmpty
                    let pool = bush ? flora.bushes : rocks
                    let base = (bush ? bushScale : wallScale * 0.9) * (0.85 + Float((h >> 6) % 30) / 100.0)
                    var p = Prop(kind: .importedFoliage, subRow: 1, subCol: 1,
                                 facing: Heading8(rawValue: Int(h % 8)) ?? .n,
                                 state: pool[Int((h >> 8) % UInt32(pool.count))], extraScale: base)
                    p.offsetX = fx
                    p.offsetY = (Float((h >> 3) % 20) / 20.0 - 0.5) * spread * 0.6   // tight ⇒ boulders overlap into a solid berm
                    p.sink = bush ? 0.10 : 0.20
                    cubies[ci].facelets[fi].props.append(p)
                }
            }
        }
        // Four E–W walls, a walkable lane between each: a progression from bare structure to fully
        // reclaimed, then a solid boulder wall (no brick) of the MegaKit big/medium rocks.
        placeWalls(row: c - 1, perTile: wallPT)                                   // structural wall only
        placeWalls(row: c - 3, perTile: wallPT); placeOvergrowth(row: c - 3, perTile: growthPT, rockPct: 45)       // lightly overgrown ruin
        placeWalls(row: c - 5, perTile: wallPT); placeOvergrowth(row: c - 5, perTile: growthPT + 3, rockPct: 35)   // heavily overgrown ruin
        placeRockWall(row: c - 7, perTile: growthPT + 4)                          // solid boulder wall (big/medium MegaKit rocks)
    }

    /// M20 prototype (Eddie) — path-stone options in the gallery, in a plot WEST of the catalog:
    /// three N–S columns to compare — **just the paved path** (the current path texture), **stones on
    /// the paved path**, and **just stones** (rock-path models on grass, no paving). `stones` = the
    /// MegaKit RockPath registry indices (Renderer supplies them). Walk west from spawn to reach it.
    func stampGalleryPaths(_ stones: [Int]) {
        guard !stones.isEmpty else { return }
        let n = size, c = n / 2
        let pLo = max(1, c - 3), pHi = min(n - 2, c + 3)       // rows 9…15
        let qLo = 1, qHi = 6                                   // cols west of the catalog (col 7)
        func inPlot(_ r: Int, _ q: Int) -> Bool { r >= pLo && r <= pHi && q >= qLo && q <= qHi }
        for r in pLo...pHi {
            for q in qLo...qHi {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: q) else { continue }
                var op: DirectionMask = []
                if inPlot(r - 1, q) { op.insert(.north) }
                if inPlot(r + 1, q) { op.insert(.south) }
                if inPlot(r, q - 1) { op.insert(.west) }
                if inPlot(r, q + 1) { op.insert(.east) }
                if r == c && q == qHi { op.insert(.east) }     // entry from the catalog/spawn (east side)
                cubies[ci].facelets[fi].mazeTile.openings = op
                cubies[ci].facelets[fi].mazeTile.openEdges = op
                // cols 2 & 4 are the paved "path texture" (all-open ⇒ paved, no hedge walls); rest grass.
                cubies[ci].facelets[fi].terrain = (q == 2 || q == 4) ? .maze : .grass
                cubies[ci].facelets[fi].tileState = .discovered
                cubies[ci].facelets[fi].discoveryAmount = 1.0
            }
        }
        if let (ci, fi) = faceletAt(face: .positiveZ, row: c, col: qHi + 1) {   // open catalog side of entry
            cubies[ci].facelets[fi].mazeTile.openings.insert(.west)
            cubies[ci].facelets[fi].mazeTile.openEdges.insert(.west)
            cubies[ci].facelets[fi].tileState = .discovered
            cubies[ci].facelets[fi].discoveryAmount = 1.0
        }
        func hash(_ a: Int, _ b: Int, _ d: Int) -> UInt32 {
            var v = UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663 ^ d &* 83492791)
            v ^= v >> 15; v = v &* 2246822519; v ^= v >> 13
            return v
        }
        // Lay ~1.5 m rock-path stones down a column: 3 per tile, seated slightly into the ground.
        let stoneScale = 1.5 * (worldScale.eyeHeight / 1.7) / 0.85
        let perTile = 9                                    // dense — a packed stone path (Eddie)
        func layStones(col q: Int) {
            for r in pLo...pHi {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: q) else { continue }
                for k in 0..<perTile {
                    for band in [-0.12, 0.0, 0.12] as [Float] {   // three tight runs, kept within the paved strip
                        let h = hash(r &* 131 &+ q &* 17, 7, k &* 13 &+ Int(band * 100))
                        var p = Prop(kind: .importedFoliage, subRow: 1, subCol: 1,
                                     facing: Heading8(rawValue: Int(h % 8)) ?? .n,
                                     state: stones[Int(h % UInt32(stones.count))],
                                     extraScale: stoneScale * (0.8 + Float((h >> 6) % 40) / 100.0))
                        p.offsetY = -0.5 + (Float(k) + 0.5) / Float(perTile)
                        p.offsetX = band + (Float((h >> 3) % 20) / 20.0 - 0.5) * 0.05
                        p.sink = 0.2
                        cubies[ci].facelets[fi].props.append(p)
                    }
                }
            }
        }
        layStones(col: 4)   // stones ON the paved path
        layStones(col: 6)   // just stones, on grass
    }

    /// M20 — a full-face evaluation grid for ONE imported pack (Dungeons / Nature / Ruins, up to 150
    /// models). Unlike the mixed `stampGallery`, this fills the whole +Z face with just this pack's
    /// models on an open grass field — models on even columns leave clear odd-column lanes to walk.
    /// `states` = registry indices (Renderer supplies them). Spawn sits among the grid; a return
    /// portal is beside the spawn. Built on a `.bare` world, so only this plot is revealed.
    func stampPackGallery(_ states: [Int]) {
        guard !states.isEmpty else { return }
        let n = size, c = n / 2
        let rLo = 2, rHi = n - 3                                   // rows 2…22 at size 25
        let cLo = 1, cHi = n - 2                                   // cols 1…23
        let modelCols = Array(stride(from: 2, through: cHi - 1, by: 2))   // 2,4,…,22 (11 aisled cols)
        let portalTile = (min(rHi, c + 1), c)
        func inPlot(_ r: Int, _ q: Int) -> Bool { r >= rLo && r <= rHi && q >= cLo && q <= cHi }
        for r in rLo...rHi {
            for q in cLo...cHi {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: q) else { continue }
                var op: DirectionMask = []
                if inPlot(r - 1, q) { op.insert(.north) }
                if inPlot(r + 1, q) { op.insert(.south) }
                if inPlot(r, q - 1) { op.insert(.west) }
                if inPlot(r, q + 1) { op.insert(.east) }
                cubies[ci].facelets[fi].mazeTile.openings = op
                cubies[ci].facelets[fi].mazeTile.openEdges = op
                cubies[ci].facelets[fi].terrain = .grass
                cubies[ci].facelets[fi].tileState = .discovered
                cubies[ci].facelets[fi].discoveryAmount = 1.0
            }
        }
        // Lay the pack's models row-major on the aisled grid, skipping the spawn + portal cells.
        var idx = 0
        outer: for r in rLo...rHi {
            for q in modelCols {
                if (r, q) == (c, c) || (r, q) == portalTile { continue }
                if idx >= states.count { break outer }
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: q) else { continue }
                cubies[ci].facelets[fi].props.append(
                    Prop(kind: .importedAsset, subRow: 1, subCol: 1, facing: .s, state: states[idx]))
                idx += 1
            }
        }
        // Return portal beside the spawn.
        if let (ci, fi) = faceletAt(face: .positiveZ, row: portalTile.0, col: portalTile.1) {
            cubies[ci].facelets[fi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))
        }
    }

    /// M20 — the Journey **entry world**: a large world (size 25 → local surface reads nearly
    /// flat, little apparent curvature, Eddie) whose natural-maze garden is only a **bounded entry
    /// region**, SEALED so the player can't wander off into the unauthored rest, and the rest left
    /// **undiscovered** (fog) so it isn't seen or rendered. Inside the region: the generated hedge
    /// maze (paths, dead-ends, twistable slices) dressed natural (grass, foliage) via
    /// `naturalDressing`; a clearing at spawn; the way home. Rough first cut to react to.
    private func stampGardenMaze() {
        let n = size
        let c = n / 2
        let R = 5                                   // entry region half-extent → an (2R+1)² garden
        let rLo = max(0, c - R), rHi = min(n - 1, c + R)
        let cLo = max(0, c - R), cHi = min(n - 1, c + R)
        // M20 (Eddie) — this world's walls are DRESSED with imported stone models (Ruins pieces + rocks
        // /bushes), not hedges: SceneBuilder skips the hedge mesh and the Renderer emits the wall models
        // per closed edge, dynamically from topology, so they survive slice-twists. See `WallStyle`.
        wallStyle = .dressed

        // A clearing at spawn (room to get bearings) — done BEFORE sealing so it can't reopen the wall.
        stampRoom(face: .positiveZ, top: max(rLo, c - 1), left: max(cLo, c - 1), height: 3, width: 3)

        for r in rLo...rHi {
            for col in cLo...cHi {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { continue }
                // SEAL: close every region-boundary edge that leads outside, so there's no escape.
                var op = cubies[ci].facelets[fi].mazeTile.openings
                if r == rLo { op.remove(.north) }
                if r == rHi { op.remove(.south) }
                if col == cLo { op.remove(.west) }
                if col == cHi { op.remove(.east) }
                cubies[ci].facelets[fi].mazeTile.openings = op
                // REVEAL only the region (the rest of the world stays .unknown ⇒ fog, unseen).
                cubies[ci].facelets[fi].tileState = .discovered
                cubies[ci].facelets[fi].discoveryAmount = 1.0
                // Per-tile wall "type" for the dressed walls: graded by distance to the region border,
                // so the OUTERMOST walls are the cleanest/most wall-like (0) and the inner ones the most
                // overgrown (3). Stored on the tile so it travels through slice-twists (not recomputed
                // from position, which the twist would scramble).
                let d = min(min(r - rLo, rHi - r), min(col - cLo, cHi - col))
                cubies[ci].facelets[fi].mazeTile.wallType = UInt8(d <= 1 ? 0 : (d == 2 ? 1 : (d == 3 ? 2 : 3)))
                // (Vegetation is stamped separately in `stampGardenVegetation` — it needs the
                //  Renderer's Quaternius registry indices, which aren't available here in init.)
            }
        }
        // Forward-only (Eddie): no way-home portal — the only exits are into the temple and (later,
        // Arc 3) the onward arch.

        // M20 Phase 1 — stage the VERIFIED temple lock into the garden (see M20 Journey Shot List):
        // temple NORTH of spawn (door faces south, toward the player), the four switches at the
        // diagonal ±3 corners (SE one off). Carve a reachable "spine" — corridors from the spawn
        // clearing to the door plinth and out to every switch — so the puzzle is solvable through the
        // otherwise-procedural maze (the rest stays maze filler). Then re-stamp the shared lock.
        guard c - 3 >= rLo, c + 3 <= rHi else { return }
        var spine = Set<[Int]>()
        for col in (c - 3)...(c + 3) { spine.insert([c, col]) }         // spawn-row spur, E–W to the switch columns
        for row in (c - 3)...(c + 3) { spine.insert([row, c - 3]); spine.insert([row, c + 3]) }   // W/E corridors to the corner switches
        for row in (c - 3)...c { spine.insert([row, c]) }              // spawn up to the plinth + door
        for rc in spine {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: rc[0], col: rc[1]) else { continue }
            var op = cubies[ci].facelets[fi].mazeTile.openings
            if spine.contains([rc[0] - 1, rc[1]]) { op.insert(.north) }
            if spine.contains([rc[0] + 1, rc[1]]) { op.insert(.south) }
            if spine.contains([rc[0], rc[1] - 1]) { op.insert(.west) }
            if spine.contains([rc[0], rc[1] + 1]) { op.insert(.east) }
            cubies[ci].facelets[fi].mazeTile.openings = op
            cubies[ci].facelets[fi].mazeTile.openEdges = op
        }
        stampTempleLock(doorRow: c - 3, doorCol: c, doorFacing: .s,
                        plinthRow: c - 2, plinthSubRow: 2,
                        switchCenter: c, spread: 3, elevatorStyle: 3)   // M20: elevator DOWN into the temple
        // M20 dressing — the clue (Player Journey: "a fallen slab carved four dots, three filled"):
        // a plinth wearing the caustic `threeOfFour` glyph (index 8), the lock's GOAL. Placed east on
        // the approach, off the door-plinth column so it doesn't read as the live progress display, and
        // not adjacent to the door (updateDoorPlinths only rewrites the door-adjacent plinth).
        if let (ci, fi) = faceletAt(face: .positiveZ, row: c, col: min(cHi, c + 2)) {
            cubies[ci].facelets[fi].props.append(Prop(kind: .plinth, subRow: 1, subCol: 1, facing: .n, state: 8))
        }

        // Two-sided, and LAST, so nothing carved above can leave a way out and
        // `reconcileSharedEdges` has nothing to disagree with.
        sealRegionBorder(face: .positiveZ, rLo: rLo, rHi: rHi, cLo: cLo, cHi: cHi)
    }

    /// M20 — Quaternius plant registry indices, grouped by kind, for the garden reskin. The Renderer
    /// builds this (it owns the `importedProps` indices) and hands it to `stampGardenVegetation`.
    struct GardenFlora {
        var trees: [Int] = []
        var bushes: [Int] = []
        var flowers: [Int] = []
        var grasses: [Int] = []
        var rocks: [Int] = []
        var walls: [Int] = []      // M20: structural wall pieces (Ruins) for the wall-builder
        var bigRocks: [Int] = []   // M20: MegaKit Rock_Big/Rock_Medium — for a solid boulder wall
    }

    /// M20 (Eddie) — tiles that must stay CLEAR of dressing so nothing hides a puzzle element: every
    /// tile holding a switch / plinth / temple pillar / sealed door / cylinder, plus its 4 neighbours.
    /// Scanned from the actual placed props (so it tracks whatever the lock stamped). +Z face only.
    /// Where a SCATTERED decorative prop actually stands: anywhere in the tile, continuously.
    ///
    /// The first attempt at this jittered props *within* their authoring sub-cell, which did nothing
    /// visible (Eddie, twice). The lattice the eye reads is the TILE grid — one prop per ~19 m tile —
    /// and a nudge of ±2.7 m cannot break a 19 m rhythm. Placement has to be continuous across the
    /// whole tile, and the number of props per tile has to VARY, or the regularity survives whatever
    /// you do to the positions.
    ///
    /// Returns the authoring sub-cell that CONTAINS the point plus the offset from that sub-cell's
    /// centre, so `Prop.blocks` (which reasons in sub-cell + offset) keeps a solid prop's footprint
    /// exactly under its mesh. Yaw is a full turn, so callers can leave `facing` at `.n`.
    /// `clearCells` keeps a SOLID prop's centre far enough from the tile border that its footprint
    /// cannot reach the border strip — where gateways are, and where a rock would silently wall off
    /// a passage. (The headless reachability tests caught exactly that the first time this went
    /// continuous: 280 severed gateway cells on the moon.) Non-solid scatter passes 0.
    func scatterPlacement(_ seed: UInt32, avoidCentre: Bool = false, clearCells: Int = 0)
        -> (subRow: Int, subCol: Int, ox: Float, oy: Float, yaw: Float) {
        var g = seed &* 2654435761
        g ^= g >> 16; g = g &* 2246822519; g ^= g >> 13
        var u = Float(g & 0xFFF) / 4095.0
        var v = Float((g >> 12) & 0xFFF) / 4095.0
        if avoidCentre {
            // Big plants stay off the line through the middle of the tile — that is where a player
            // walks, and a bush in the face reads as an obstacle even when it cannot block you.
            u = (g & 0x0100_0000) != 0 ? 0.06 + u * 0.27 : 0.67 + u * 0.27
            v = (g & 0x0200_0000) != 0 ? 0.06 + v * 0.27 : 0.67 + v * 0.27
        } else {
            // A margin off the tile edge so nothing grows inside a wall; widened for solid props so
            // their whole footprint clears the border strip.
            let m = max(0.06, (Float(clearCells) + 2.0) / Float(worldScale.standGrid))
            u = m + u * (1 - 2 * m)
            v = m + v * (1 - 2 * m)
        }
        let hs = worldScale.floorHalfSize, step = worldScale.subCellStep
        let x = (u - 0.5) * 2 * hs, y = (v - 0.5) * 2 * hs
        let sc = min(2, max(0, Int(u * 3))), sr = min(2, max(0, Int(v * 3)))
        return (sr, sc, x - Float(sc - 1) * step, y - Float(sr - 1) * step,
                Float((g >> 4) & 0x3FF) * (360.0 / 1023.0))
    }

    /// A smooth 0…1 field over TILE coordinates, wavelength ~4 tiles — used to make scatter DENSITY
    /// vary from place to place. Without it every tile rolls its own count independently, which is
    /// uniform noise: statistically random, visually a grid, because no tile is ever much emptier or
    /// fuller than its neighbours. This is what turns an even sprinkle into thickets and clearings.
    func clumpField(_ r: Int, _ c: Int, salt: Int) -> Float {
        let cell = 4
        func corner(_ a: Int, _ b: Int) -> Float {
            var v = UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663 ^ salt &* 83492791)
            v ^= v >> 15; v = v &* 2246822519; v ^= v >> 13
            return Float(v & 0xFFFF) / 65535.0
        }
        let r0 = Int(floor(Float(r) / Float(cell))), c0 = Int(floor(Float(c) / Float(cell)))
        let fr = Float(r - r0 * cell) / Float(cell), fc = Float(c - c0 * cell) / Float(cell)
        let sr = fr * fr * (3 - 2 * fr), sc = fc * fc * (3 - 2 * fc)   // smoothstep, so no seams
        let top = corner(r0, c0) + (corner(r0, c0 + 1) - corner(r0, c0)) * sc
        let bot = corner(r0 + 1, c0) + (corner(r0 + 1, c0 + 1) - corner(r0 + 1, c0)) * sc
        return top + (bot - top) * sr
    }

    private func gardenClearTiles() -> Set<[Int]> {
        var s = Set<[Int]>()
        let puzzle: Set<PropKind> = [.switchBase, .switchCap, .plinth, .obelisk, .alignmentCylinder]
        for r in 0..<size {
            for c in 0..<size {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                let props = cubies[ci].facelets[fi].props
                if props.contains(where: { puzzle.contains($0.kind) || ($0.kind == .portal && $0.state == 1) }) {
                    for (dr, dc) in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)] { s.insert([r + dr, c + dc]) }
                }
            }
        }
        return s
    }

    /// M20 — dress the sealed garden region with Quaternius plants (the reskin of the old procedural
    /// cone/card scatter). NON-solid: the hedges still do all the blocking, these are pure scenery, so
    /// the maze stays fully walkable. Deterministic (spatial hash, no RNG) so the garden looks the
    /// same each visit. Called by the Renderer after the garden is built (it owns the indices).
    func stampGardenVegetation(_ flora: GardenFlora) {
        let n = size, c = n / 2
        let R = 5
        let rLo = max(0, c - R), rHi = min(n - 1, c + R)
        let cLo = max(0, c - R), cHi = min(n - 1, c + R)
        let clear = gardenClearTiles()   // keep puzzle elements visible (Eddie)

        func hash(_ a: Int, _ b: Int, _ d: Int) -> UInt32 {
            var v = UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663 ^ d &* 83492791)
            v ^= v >> 15; v = v &* 2246822519; v ^= v >> 13
            return v
        }
        // Fit-to-`target` (0.85 u) is the gallery's uniform size; scale each kind DOWN to garden scale
        // (a hedge wall ≈ 0.24 u tall). Trees clear the hedges; bushes sit below; ground cover is small.
        let treeScale: Float = 0.5, bushScale: Float = 0.16, flowerScale: Float = 0.07,
            grassScale: Float = 0.07, rockScale: Float = 0.12

        func place(_ ci: Int, _ fi: Int, _ pool: [Int], _ base: Float, _ h: UInt32, corner: Bool) {
            guard !pool.isEmpty else { return }
            let idx = pool[Int(h % UInt32(pool.count))]
            let jitter = 0.85 + Float((h >> 6) % 30) / 100.0    // 0.85…1.15 size variety
            // Continuous across the whole tile (`scatterPlacement`), not one of nine sub-cell points:
            // at ~19 m per tile the sub-cell lattice was never what the eye was reading. `corner`
            // now means "keep off the walking line through the middle", not "sit on a lattice point".
            let p = scatterPlacement(h, avoidCentre: corner)
            cubies[ci].facelets[fi].props.append(
                Prop(kind: .importedFoliage, subRow: p.subRow, subCol: p.subCol,
                     state: idx, viewAngle: p.yaw, extraScale: base * jitter,
                     offsetX: p.ox, offsetY: p.oy))
        }

        for r in rLo...rHi {
            for col in cLo...cHi {
                if (r, col) == (c, c) || clear.contains([r, col]) { continue }
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { continue }
                let h = hash(r * 37, col, r &+ col)
                let roll = h % 100
                // Primary plant — weighted so the garden reads mostly green with occasional trees/rocks.
                if roll < 14       { place(ci, fi, flora.trees,   treeScale,   h, corner: true)  }
                else if roll < 38  { place(ci, fi, flora.bushes,  bushScale,   h, corner: true)  }
                else if roll < 56  { place(ci, fi, flora.flowers, flowerScale, h, corner: false) }
                else if roll < 71  { place(ci, fi, flora.grasses, grassScale,  h, corner: false) }
                else if roll < 78  { place(ci, fi, flora.rocks,   rockScale,   h, corner: false) }
                // Ground-cover accent — a second small plant on ~a third of tiles (a different
                // sub-cell) to layer the density without walling the paths.
                let h2 = hash(col * 37, r, r &* col &+ 7)
                if h2 % 100 < 32 {
                    if (h2 & 1) == 0 { place(ci, fi, flora.flowers, flowerScale, h2, corner: false) }
                    else             { place(ci, fi, flora.grasses, grassScale,  h2, corner: false) }
                }
            }
        }
        // Eddie — the OTHER FIVE FACES had no ground scatter at all: this stamp was +Z-only, so they
        // were carried entirely by wall dressing and read sparse and regular beside the start face.
        // (That asymmetry is what made every "the scatter still looks regular" report ambiguous.)
        // Same continuous, clumped scatter over the whole face — no puzzle lives out here, so there
        // is nothing to keep clear, and these are non-solid props so none of it can block a route.
        for face in CubeFace.allCases where face != .positiveZ {
            let faceIdx = face.rawValue
            for r in 0..<n {
                for col in 0..<n {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: col) else { continue }
                    let density = clumpField(r, col, salt: faceIdx &* 23 &+ 5)
                    // Tuned against a measured +Z (3.3 ground props per tile): the first pass at
                    // 0.4 + 7·d² landed the other faces at 1.0–2.9, thinner than the start face and
                    // visibly so. Eddie asked for roughly double.
                    let count = Int((1.0 + density * density * 12.0).rounded())
                    for k in 0..<count {
                        let h = hash(faceIdx &* 131 &+ r &* 53 &+ col &* 3, k &* 29 &+ 11, r &* col &+ k &* 7)
                        let roll = h % 100
                        // One tree per tile at most — they are by far the largest of these, and a
                        // clump of eight would read as a wall rather than as planting.
                        if k == 0 && roll < 12 { place(ci, fi, flora.trees, treeScale, h, corner: true) }
                        else if roll < 46      { place(ci, fi, flora.bushes,  bushScale,   h, corner: true)  }
                        else if roll < 66      { place(ci, fi, flora.grasses, grassScale,  h, corner: false) }
                        else if roll < 86      { place(ci, fi, flora.flowers, flowerScale, h, corner: false) }
                        else                   { place(ci, fi, flora.rocks,   rockScale,   h, corner: false) }
                    }
                }
            }
        }
        // Eddie — considerably MORE greenery ("can't add too much"; non-solid, so it never impedes
        // movement): a dense EVEN second pass over the whole region (no center-heavy cluster — the
        // distribution should read uniform), skipping the puzzle tiles so nothing hides a switch/plinth.
        for r in rLo...rHi {
            for col in cLo...cHi {
                if (r, col) == (c, c) || clear.contains([r, col]) { continue }
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { continue }
                // How many, not just where. A fixed four-per-tile is uniform noise: statistically
                // random, visually a grid, because no tile is ever emptier or fuller than its
                // neighbours. Draw the count from a field that varies over ~4 tiles so the garden
                // gets thickets and clearings — which is what actually reads as natural.
                let density = clumpField(r, col, salt: 11)
                let n2 = Int((0.35 + density * density * 7.4).rounded())     // ~0…8 per tile
                for k in 0..<n2 {
                    let h = hash(r &* 53 &+ col &* 3, k &* 29 &+ 11, r &* col &+ k &* 7)
                    let roll = h % 100
                    if roll < 55       { place(ci, fi, flora.bushes,  bushScale,  h, corner: false) }
                    else if roll < 80  { place(ci, fi, flora.grasses, grassScale, h, corner: false) }
                    else if roll < 92  { place(ci, fi, flora.flowers, flowerScale, h, corner: false) }
                    else               { place(ci, fi, flora.rocks,   rockScale,  h, corner: false) }
                }
            }
        }
    }

    /// M20 (Eddie) — REPLACE the garden's hedge maze walls with the packed natural walls built for the
    /// gallery: a run of Ruins wall pieces + Nature/MegaKit rocks & bushes along every closed maze edge.
    /// The four wall "types" are graded by distance to the region boundary — the **outermost walls are
    /// the most wall-like** (bare Ruins pieces), the innermost the most overgrown/foliage. The hedge
    /// mesh is suppressed (`foliageWalls`); movement is unchanged (the maze topology still blocks). Runs
    /// after construction (needs the Renderer's registry indices), like `stampGardenVegetation`.
    func stampGardenWalls(_ flora: GardenFlora) {
        guard !flora.walls.isEmpty || !flora.rocks.isEmpty || !flora.bushes.isEmpty else { return }
        let n = size, c = n / 2, R = 5
        let rLo = max(0, c - R), rHi = min(n - 1, c + R)
        let cLo = max(0, c - R), cHi = min(n - 1, c + R)
        // Keep the DYNAMIC hedge walls (do NOT suppress them): they re-derive from topology on the
        // whole cube every frame, so they're the only TWIST-SAFE wall — a door-twist that rotates in
        // tiles from outside the small stamped region can't create invisible/mis-placed walls (static
        // stamped props can't cover those). The Ruins pieces + rocks/bushes below sit ON the hedges, so
        // the maze reads as an overgrown stone ruin while staying legible and twist-correct.
        let clear = gardenClearTiles()              // overgrowth skips puzzle tiles (walls still placed there)
        let mUnit = worldScale.eyeHeight / 1.7
        let wallScale = 4.0 * mUnit / 0.85          // ~4 m, matching the hedges they replace
        let rockScale = wallScale * 0.7, bushScale = wallScale * 0.5
        func hash(_ a: Int, _ b: Int, _ d: Int) -> UInt32 {
            var v = UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663 ^ d &* 83492791)
            v ^= v >> 15; v = v &* 2246822519; v ^= v >> 13
            return v
        }
        // Distance to the region boundary → wall type: 0 bare structural … 3 mostly foliage.
        func wallType(_ r: Int, _ cc: Int) -> Int {
            let d = min(min(r - rLo, rHi - r), min(cc - cLo, cHi - cc))
            return d <= 1 ? 0 : (d == 2 ? 1 : (d == 3 ? 2 : 3))
        }
        func put(_ ci: Int, _ fi: Int, _ pool: [Int], _ scale: Float, _ sink: Float, _ facing: Heading8,
                 _ h: UInt32, _ ox: Float, _ oy: Float) {
            guard !pool.isEmpty else { return }
            var p = Prop(kind: .importedFoliage, subRow: 1, subCol: 1, facing: facing,
                         state: pool[Int(h % UInt32(pool.count))], extraScale: scale * (0.85 + Float((h >> 6) % 30) / 100.0))
            p.offsetX = ox; p.offsetY = oy; p.sink = sink
            cubies[ci].facelets[fi].props.append(p)
        }
        // A stone wall along ONE edge of a tile (only if that edge is closed = a maze wall). A wall
        // piece is placed on EVERY closed edge so the maze reads clearly (Eddie: bring back all the
        // stone walls) — the boundary-distance `type` only grades how OVERGROWN it is (outermost clean,
        // innermost lush). Walls go on puzzle-tile edges too (they don't hide the centre); only the
        // overgrowth skips puzzle tiles so nothing buries a switch/plinth.
        func edge(_ r: Int, _ cc: Int, _ dir: DirectionMask) {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: cc),
                  !cubies[ci].facelets[fi].mazeTile.openings.contains(dir) else { return }
            let type = wallType(r, cc)
            let horiz = dir == .north || dir == .south
            let side: Float = (dir == .north || dir == .west) ? -0.46 : 0.46
            let wallFacing: Heading8 = horiz ? .n : .e
            func pos(_ t: Float, _ across: Float) -> (Float, Float) { horiz ? (t, across) : (across, t) }
            if !flora.walls.isEmpty {                       // structural Ruins wall pieces on every edge
                for k in 0..<6 {
                    let t = -0.5 + (Float(k) + 0.5) / 6.0
                    let h = hash(r &* 131 &+ cc &* 17, Int(dir.rawValue) &* 31 &+ 1, k &* 7 &+ type)
                    let (ox, oy) = pos(t, side)
                    put(ci, fi, flora.walls, wallScale, 0.03, wallFacing, h, ox, oy)
                }
            }
            let overgrowth = clear.contains([r, cc]) ? 0 : [2, 4, 6, 8][type]   // embedded foliage on every wall, more inward; none by puzzles
            if overgrowth > 0 {
                let inward = side < 0 ? side + 0.12 : side - 0.12
                for k in 0..<overgrowth {
                    let t = -0.5 + (Float(k) + 0.5) / Float(overgrowth)
                    let h = hash(r &* 131 &+ cc &* 17, Int(dir.rawValue) &* 31 &+ 2, k &* 7 &+ type)
                    let rock = h % 100 < 45 && !flora.rocks.isEmpty
                    let (ox, oy) = pos(t, inward)
                    put(ci, fi, rock ? flora.rocks : flora.bushes, rock ? rockScale : bushScale,
                        rock ? 0.20 : 0.10, Heading8(rawValue: Int(h % 8)) ?? .n, h >> 3, ox, oy)
                }
            }
        }
        // Each tile owns its NORTH + WEST edges (shared edges placed once); the region's south/east
        // boundary edges have no owner-below, so place them explicitly.
        for r in rLo...rHi {
            for cc in cLo...cHi {
                edge(r, cc, .north); edge(r, cc, .west)
                if r == rHi { edge(r, cc, .south) }
                if cc == cHi { edge(r, cc, .east) }
            }
        }
    }

    // MARK: - M20 dressed walls (dynamic, twist-safe)

    /// M20 (Eddie) — the framework for STONE walls that survive twists. For a `.dressed` world the
    /// hedge mesh is suppressed and, every frame, the Renderer asks each discovered tile for the wall
    /// MODELS on its closed edges via this method and runs them through the normal asset placement.
    /// Because the props are re-derived from the tile's live topology (never stored, never stamped),
    /// they move with the tile through a slice-twist exactly like the hedge mesh — the failure mode
    /// that killed the static `stampGardenWalls` approach can't happen here.
    ///
    /// **Twist stability is the whole point**, and it has two independent parts:
    ///
    /// 1. **Structural walls** are deduped (one physical wall drawn once): a tile owns its **N + W**
    ///    edges always, and its **S + E** edges only on a region border. But a face rotation flips a
    ///    wall's label (a north edge becomes an east edge), so *ownership hands off to the neighbour* —
    ///    a tile with a different `styleSeed`. Seeding off one tile therefore swapped every piece on
    ///    each turn. Fix: seed off the **unordered pair** of tiles the wall separates (`seed ^
    ///    neighbourSeed`), which is identical whichever tile owns it, and invariant as they turn together.
    /// 2. **Foliage** is NOT owner-based: each tile overgrows the INNER face (toward its own centre) of
    ///    its *own* closed edges, seeded by its *own* tile. A shared wall still gets both faces (each
    ///    neighbour dresses its side), but with no handoff, so a twist carries each tile's foliage with it.
    ///
    /// Everything is expressed in a **rigid edge frame** (outward normal + a tangent that rotates with
    /// the edge) and selected by the **canonical edge id** (`dir` un-rotated by `uvTurns`, the twist
    /// accumulator kept in lockstep with `openings`). So the SAME tile always draws a given wall (owner
    /// chosen by tile identity, not by N/W which flips on a turn), each piece keeps its slot and its
    /// facing, and the whole arrangement simply rotates rigidly with the tile — no reordering, mirroring,
    /// or hole-pattern churn on a twist. `skipOvergrowth` (a puzzle-clear tile) drops the foliage but
    /// keeps the wall. `walls`/`rocks`/`bushes` are registry indices; scales are the Renderer's metre fit.
    func dressedWallProps(_ facelet: MazeFacelet, face: CubeFace, row: Int, col: Int,
                          walls: [Int], rocks: [Int], bushes: [Int],
                          wallScale: Float, rockScale: Float, bushScale: Float,
                          skipOvergrowth: Bool) -> [Prop] {
        guard !walls.isEmpty || !rocks.isEmpty || !bushes.isEmpty else { return [] }
        let op = facelet.mazeTile.openings
        let type = min(3, Int(facelet.mazeTile.wallType))
        let seed = UInt32(truncatingIfNeeded: facelet.mazeTile.styleSeed)
        let uvTurns = Int(facelet.mazeTile.uvTurns)
        var out: [Prop] = []
        func hash(_ s: UInt32, _ a: Int, _ b: Int) -> UInt32 {
            var v = s &+ UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663)
            v ^= v >> 15; v = v &* 2246822519; v ^= v >> 13
            return v
        }
        func neighbor(_ dir: DirectionMask) -> (ci: Int, fi: Int)? {
            let (dr, dc): (Int, Int)
            switch dir {
            case .north: (dr, dc) = (-1, 0)
            case .south: (dr, dc) = (1, 0)
            case .west:  (dr, dc) = (0, -1)
            default:     (dr, dc) = (0, 1)          // east
            }
            guard let f = faceletAt(face: face, row: row + dr, col: col + dc) else { return nil }
            return (f.cubieIndex, f.faceletIndex)
        }
        func put(_ pool: [Int], _ scale: Float, _ sink: Float, _ facing: Heading8, _ h: UInt32,
                 _ ox: Float, _ oy: Float, yawDeg: Float = 0) {
            guard !pool.isEmpty else { return }
            var p = Prop(kind: .importedFoliage, subRow: 1, subCol: 1, facing: facing,
                         state: pool[Int(h % UInt32(pool.count))], extraScale: scale * (0.85 + Float((h >> 6) % 30) / 100.0))
            p.offsetX = ox; p.offsetY = oy; p.sink = sink
            // Fills in between `facing`'s 45° steps. Safe under a twist: `facing` carries the tile's
            // rotation, this is a fixed extra angle in the tile's own frame.
            p.viewAngle = yawDeg
            out.append(p)
        }
        // Rigid edge frame: outward normal (nx,ny), a tangent (tx,ty) that rotates WITH the edge through
        // a twist, and the piece facing. Placing at `normal·r + tangent·t` makes a slot rotate rigidly as
        // the edge turns N→E→S→W (a piece's t no longer runs a fixed world axis), and the n/e/s/w facing
        // gives the full 90°-per-turn rotation (not just horizontal/vertical).
        func frame(_ dir: DirectionMask) -> (nx: Float, ny: Float, tx: Float, ty: Float, facing: Heading8) {
            switch dir {
            case .north: return ( 0, -1,  1,  0, .n)
            case .east:  return ( 1,  0,  0,  1, .e)
            case .south: return ( 0,  1, -1,  0, .s)
            default:     return (-1,  0,  0, -1, .w)   // west
            }
        }
        let canon = { (dir: DirectionMask) in Int(dir.rotated(quarterTurns: -uvTurns).rawValue) }

        // (1) Structural wall pieces along the edge line (radius 0.46 from centre). Owner is the tile
        // that draws it — chosen below by identity — so the same tile always draws it and it rotates
        // rigidly with that tile; pieces selected by the canonical edge id + own seed.
        func wallPieces(_ dir: DirectionMask) {
            let f = frame(dir)
            for k in 0..<6 {
                let h = hash(seed, canon(dir) &* 31 &+ 1, k &* 7 &+ type)
                // NO along-edge jitter. I claimed the pieces overlapped enough to absorb it; they do
                // not. Six pieces about 4 m wide across a ~19 m tile overlap by under a metre, and
                // ±0.055 of the span is ±1 m — so it opened real holes, and since the overgrowth is
                // placed separately you saw walls "with visible breaks that only have the moss bits
                // shown" (Eddie). Position along the wall is now exact.
                let t = -0.5 + (Float(k) + 0.5) / 6.0
                // In and out is free — it cannot open a gap, and it is enough to stop a ruin looking
                // milled. Same for the small yaw below.
                let radial = 0.46 + (Float((h >> 21) & 0x3F) / 63.0 - 0.5) * 0.03
                put(walls, wallScale, 0.03 + Float((h >> 9) & 0xF) / 15.0 * 0.02, f.facing, h,
                    f.nx * radial + f.tx * t, f.ny * radial + f.ty * t,
                    yawDeg: (Float((h >> 27) & 0x1F) / 31.0 - 0.5) * 7)
            }
        }
        // (2) Foliage on this tile's INNER face (radius 0.34, toward centre), same rigid frame + canon.
        // Gentle gradient (outer cleaner → inner lusher; a steep one pooled it into the 3×3 centre).
        func foliage(_ dir: DirectionMask) {
            // This was a FIXED count at exactly even spacing and a constant 0.34 from the wall, which
            // is "three props along every wall of every tile" — the regularity Eddie could still see
            // once the open-ground scatter was fixed. The player's start face hid it, because the
            // garden's continuous vegetation is layered over that one face and nothing else.
            //
            // Everything here is still derived from twist-INVARIANT inputs only (the tile's seed, the
            // canonical edge id, k, type — never row/col), so the dressing stays rigid through a
            // twist. That is the constraint that makes this fiddly rather than free.
            let hN = hash(seed, canon(dir) &* 31 &+ 9, type &* 5 &+ 3)
            let overgrowth = max(1, [3, 4, 4, 5][type] - 2 + Int(hN % 4))
            let f = frame(dir)
            for k in 0..<overgrowth {
                let h = hash(seed, canon(dir) &* 31 &+ 2, k &* 7 &+ type)
                // Along the wall: jitter within the slot rather than dead centre of it.
                let slot = (Float(k) + 0.5) / Float(overgrowth)
                let t = -0.5 + slot + (Float((h >> 11) & 0xFF) / 255.0 - 0.5) * (0.9 / Float(overgrowth))
                // And away from it: a constant radius drew a line of evenly-spaced dots parallel to
                // every wall, which reads as a fence. Kept clear of the wall itself (0.46) and short
                // of the tile centre.
                let radial = 0.23 + Float((h >> 19) & 0xFF) / 255.0 * 0.18
                let rock = h % 100 < 45 && !rocks.isEmpty
                // Yaw advances with the tile's turns so an asymmetric bush spins rigidly too.
                let yaw = Heading8(rawValue: (Int(h % 8) + 2 * uvTurns) % 8) ?? .n
                put(rock ? rocks : bushes, rock ? rockScale : bushScale, rock ? 0.20 : 0.10,
                    yaw, h >> 3, f.nx * radial + f.tx * t, f.ny * radial + f.ty * t,
                    yawDeg: Float((h >> 24) & 0x3F) * (45.0 / 64.0))
            }
        }
        // Structural-wall ownership by tile IDENTITY (not N/W): the shared wall is drawn once, by the
        // tile with the smaller styleSeed (id breaks ties). Identity is invariant under a twist, so the
        // owner never hands off — the wall stays drawn in one tile's frame and rotates rigidly.
        func ownsWall(_ dir: DirectionMask) -> Bool {
            guard let (nci, nfi) = neighbor(dir) else { return true }     // region border: sole owner
            let nTile = cubies[nci].facelets[nfi]
            guard nTile.tileState == .discovered else { return true }     // neighbour unseen: sole owner
            let nSeed = UInt32(truncatingIfNeeded: nTile.mazeTile.styleSeed)
            return seed != nSeed ? seed < nSeed : facelet.id.rawValue < nTile.id.rawValue
        }
        for dir in [DirectionMask.north, .east, .south, .west] {
            guard !op.contains(dir) else { continue }                    // only CLOSED edges are walls
            if ownsWall(dir) { wallPieces(dir) }                         // deduped structural wall
            if !skipOvergrowth { foliage(dir) }                          // this tile's own inner face
        }
        return out
    }

    /// M20 — facelet IDs whose dressed-wall OVERGROWTH must be suppressed: a puzzle prop sits on the
    /// tile, or on an in-face neighbour. Re-derived each frame from the live props (which ride their
    /// facelets through a twist), so the clear zone tracks the puzzle wherever the twist carries it.
    /// The structural wall pieces are still placed on these tiles — only the rocks/bushes are dropped.
    func dressedClearTiles() -> Set<Int> {
        let puzzle: Set<PropKind> = [.switchBase, .switchCap, .plinth, .obelisk, .alignmentCylinder]
        var s = Set<Int>()
        for face in CubeFace.allCases {
            for r in 0..<size {
                for cc in 0..<size {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: cc) else { continue }
                    let props = cubies[ci].facelets[fi].props
                    guard props.contains(where: { puzzle.contains($0.kind) || ($0.kind == .portal && $0.state == 1) }) else { continue }
                    for (dr, dc) in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)] {
                        if let (nci, nfi) = faceletAt(face: face, row: r + dr, col: cc + dc) {
                            s.insert(cubies[nci].facelets[nfi].id.rawValue)
                        }
                    }
                }
            }
        }
        return s
    }

    /// M20 (Eddie) — a stone path (MegaKit RockPath) marking the CORRECT route between the puzzle
    /// elements: dense on the "spine" (spawn ↔ switches ↔ door plinth ↔ temple), then TAPERING off as
    /// you go the wrong way (fewer stones the further a tile is, along the maze, from the right path).
    /// `stones` = the MegaKit RockPath registry indices (Renderer supplies them). Runs after build.
    func stampGardenPath(_ stones: [Int]) {
        guard !stones.isEmpty else { return }
        let n = size, c = n / 2, R = 5
        let rLo = max(0, c - R), rHi = min(n - 1, c + R)
        let cLo = max(0, c - R), cHi = min(n - 1, c + R)
        // The correct path — the same spine stampGardenMaze carved — plus the spawn clearing.
        var spine = Set<[Int]>()
        for col in (c - 3)...(c + 3) { spine.insert([c, col]) }
        for row in (c - 3)...(c + 3) { spine.insert([row, c - 3]); spine.insert([row, c + 3]) }
        for row in (c - 3)...c { spine.insert([row, c]) }
        for r in (c - 1)...(c + 1) { for cc in (c - 1)...(c + 1) { spine.insert([r, cc]) } }
        // BFS distance from the spine over WALKABLE tiles (open edges), so the taper follows the maze.
        var dist = [[Int]: Int](); var q = [[Int]](); var head = 0
        for t in spine { dist[t] = 0; q.append(t) }
        while head < q.count {
            let t = q[head]; head += 1; let d = dist[t]!
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: t[0], col: t[1]) else { continue }
            let op = cubies[ci].facelets[fi].mazeTile.openings
            for (ok, nt) in [(op.contains(.north), [t[0]-1, t[1]]), (op.contains(.south), [t[0]+1, t[1]]),
                             (op.contains(.west), [t[0], t[1]-1]), (op.contains(.east), [t[0], t[1]+1])]
            where ok && nt[0] >= rLo && nt[0] <= rHi && nt[1] >= cLo && nt[1] <= cHi && dist[nt] == nil {
                dist[nt] = d + 1; q.append(nt)
            }
        }
        func hash(_ a: Int, _ b: Int, _ d: Int) -> UInt32 {
            var v = UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663 ^ d &* 83492791)
            v ^= v >> 15; v = v &* 2246822519; v ^= v >> 13
            return v
        }
        let stoneScale = 1.5 * (worldScale.eyeHeight / 1.7) / 0.85    // ~1.5 m flat stepping stones
        for (t, d) in dist {
            // Taper off the correct path (Eddie): fewer tiles get a lane, and shorter stubs, the
            // further you go the wrong way.
            let laneChance: UInt32, stubSteps: Int
            switch d {
            case 0:  laneChance = 100; stubSteps = 2
            case 1:  laneChance = 70;  stubSteps = 2
            case 2:  laneChance = 35;  stubSteps = 1
            default: laneChance = 12;  stubSteps = 1
            }
            if hash(t[0] &* 131 &+ t[1] &* 17, 5, 1) % 100 >= laneChance { continue }
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: t[0], col: t[1]) else { continue }
            let op = cubies[ci].facelets[fi].mazeTile.openings
            // A lane down the MIDDLE of the corridor (Eddie): a centre stone, plus stubs running from
            // the centre toward each OPEN edge — so straight corridors read as a line, corners as an L.
            func stone(_ ox: Float, _ oy: Float, _ salt: Int) {
                let h = hash(t[0] &* 131 &+ t[1] &* 17, salt &+ 40, 7)
                var p = Prop(kind: .importedFoliage, subRow: 1, subCol: 1,
                             facing: Heading8(rawValue: Int(h % 8)) ?? .n,
                             state: stones[Int((h >> 8) % UInt32(stones.count))],
                             extraScale: stoneScale * (0.85 + Float((h >> 6) % 30) / 100.0))
                p.offsetX = ox + (Float((h >> 3) % 10) / 10.0 - 0.5) * 0.06   // tiny jitter, stays centred
                p.offsetY = oy + (Float((h >> 11) % 10) / 10.0 - 0.5) * 0.06
                p.sink = 0.25
                cubies[ci].facelets[fi].props.append(p)
            }
            stone(0, 0, 0)   // centre of the corridor
            for (dir, dx, dy) in [(DirectionMask.north, Float(0), Float(-1)), (.south, 0, 1), (.west, -1, 0), (.east, 1, 0)] where op.contains(dir) {
                for s in 1...stubSteps {
                    let tt = Float(s) / Float(stubSteps + 1) * 0.5
                    stone(dx * tt, dy * tt, Int(dir.rawValue) &* 10 &+ s)
                }
            }
        }
    }

    /// M19 — the Moon: open grey regolith on every tile (no walls), grey boulders scattered
    /// across the surface, and a walk-through portal home. Grey in the sky (the killer visual)
    /// and walkable when visited. Craters (relief bowls) wait on the M19 relief pass.
    private func stampLunar() {
        let all: DirectionMask = [.north, .east, .south, .west]
        for ci in cubies.indices {
            for fi in cubies[ci].facelets.indices {
                cubies[ci].facelets[fi].mazeTile.openings = all
                cubies[ci].facelets[fi].mazeTile.openEdges = all
                cubies[ci].facelets[fi].terrain = .regolith
            }
        }
        let c = size / 2
        let spawn = (c, c)
        let portalTile = (min(size - 1, c + 1), c)
        func hash(_ a: Int, _ b: Int, _ d: Int) -> UInt32 {
            var v = UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663 ^ d &* 83492791)
            v ^= v >> 15; v = v &* 2246822519; v ^= v >> 13
            return v
        }
        for (faceIdx, face) in CubeFace.allCases.enumerated() {
            for row in 0..<size {
                for col in 0..<size {
                    if face == .positiveZ && ((row, col) == spawn || (row, col) == portalTile) { continue }
                    guard let (ci, fi) = faceletAt(face: face, row: row, col: col) else { continue }
                    let dir = tileDirection(face: face, row: row, col: col)
                    let boost = cornerBoost(dir)
                    let h = hash(faceIdx * 149 + row, col, row &+ col)
                    // Rock fields (patchy) that thicken heavily toward the corners (random thicket).
                    let rockProb = min(0.98, 0.30 + 0.28 * patchField(dir) + 0.90 * boost)
                    guard Float(h % 1000) / 1000.0 < rockProb else { continue }
                    // A rubble field is the last place a lattice should be readable — place rocks
                    // continuously across the tile, and vary how many land on it.
                    let rocks = boost > 0.4 ? 2 : 1     // solid, 5×5 footprint each — a third would seal the tile
                    for k in 0..<rocks {
                        let hk = hash(faceIdx &* 733 &+ row, col &* 11 &+ k &* 7, row &+ col &+ k &* 13)
                        let p = scatterPlacement(hk, clearCells: PropKind.boulder.footprintRadius(grid: worldScale.standGrid))
                        cubies[ci].facelets[fi].props.append(
                            Prop(kind: .boulder, subRow: p.subRow, subCol: p.subCol,
                                 state: Int((hk >> 8) % 3), viewAngle: p.yaw,
                                 offsetX: p.ox, offsetY: p.oy))
                    }
                }
            }
        }
        if let (ci, fi) = faceletAt(face: .positiveZ, row: portalTile.0, col: portalTile.1) {
            cubies[ci].facelets[fi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))
        }
    }

    /// M19 — the outward unit direction of a tile centre (pre-inflation), for scatter fields.
    private func tileDirection(face: CubeFace, row: Int, col: Int) -> SIMD3<Float> {
        let m = restMatrix(face: face, row: row, col: col)
        let c = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let len = (c.x*c.x + c.y*c.y + c.z*c.z).squareRoot()
        return len > 1e-5 ? c / len : SIMD3(0, 0, 1)
    }
    /// M19 — nearness to the closest of the 8 cube corners (0 away → 1 at a corner). Drives the
    /// corner-density thicket (Eddie: thicken cover near the glitchy triple-points, kept random).
    private func cornerBoost(_ dir: SIMD3<Float>) -> Float {
        let s = 1.0 / Float(3).squareRoot()
        var best: Float = -1
        for sx in [-s, s] { for sy in [-s, s] { for sz in [-s, s] {
            best = max(best, simd_dot(dir, SIMD3(sx, sy, sz)))
        } } }
        return Self.smoothstepF(0.80, 0.965, best)
    }
    /// M19 — a smooth low-frequency patch field (0…1) over the surface direction, so cover clumps
    /// into groves / rock fields with open ground between rather than scattering evenly.
    private func patchField(_ dir: SIMD3<Float>) -> Float {
        let v = (sinf(dir.x * 3.3 + dir.y * 1.7)
               + sinf(dir.y * 2.9 - dir.z * 2.1)
               + sinf(dir.z * 3.1 + dir.x * 1.3)) / 3.0
        return 0.5 + 0.5 * v
    }

    /// M19 — the Natureworld: no maze at all. Every tile is open ground (grass), a winding
    /// stream of unwalkable water threads across the arrival face (the natural world's routing,
    /// in place of hedges), and conifers scatter over the whole planet in varied sizes. The way
    /// home is a walk-through portal beside the spawn. (Also the M18 open-field testbed — B key.)
    /// A small deterministic hash drives the scatter so it's stable across runs without RNG.
    private func stampNatural(homePortalToGarden: Bool = false) {
        let all: DirectionMask = [.north, .east, .south, .west]
        for ci in cubies.indices {
            for fi in cubies[ci].facelets.indices {
                cubies[ci].facelets[fi].mazeTile.openings = all
                cubies[ci].facelets[fi].mazeTile.openEdges = all
                cubies[ci].facelets[fi].terrain = .grass
            }
        }
        let c = size / 2
        let spawn = (c, c)                 // player starts here (+Z centre) — keep it clear
        let portalTile = (min(size - 1, c + 1), c)

        func setWater(_ face: CubeFace, _ r: Int, _ cl: Int) {
            guard (0..<size).contains(r), (0..<size).contains(cl) else { return }
            if face == .positiveZ && ((r, cl) == spawn || (r, cl) == portalTile) { return }
            if let (ci, fi) = faceletAt(face: face, row: r, col: cl) {
                cubies[ci].facelets[fi].terrain = .water
            }
        }

        // A meandering stream down the +Z face: one water tile per row, wiggling around centre.
        // Water tiles are unwalkable, so the player follows the banks — routing without walls.
        let wiggle = [0, 1, 1, 0, -1, -1, 0]
        for r in 0..<size {
            setWater(.positiveZ, r, min(size - 1, max(0, c + wiggle[r % wiggle.count])))
        }
        // A small lake off toward the +Z far corner (away from spawn/portal), fed by the stream —
        // gives the water some body, not just a thread. Bounds-clamped for small sizes.
        let lakeR = max(0, c - 2), lakeC = min(size - 1, c + 2)
        for dr in 0...1 { for dc in 0...1 { setWater(.positiveZ, lakeR + dr, lakeC - dc) } }

        // Conifers over the whole planet, in varied sizes — trunk (solid) + cone (crown). Skip
        // water, the spawn tile, and the portal tile. Deterministic scatter via a spatial hash —
        // denser (42%) so treed areas read as real stands with meadow gaps, toward the concept image.
        func hash(_ a: Int, _ b: Int, _ d: Int) -> UInt32 {
            var v = UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663 ^ d &* 83492791)
            v ^= v >> 15; v = v &* 2246822519; v ^= v >> 13
            return v
        }
        // Cover clumps into groves (patchy forest ↔ open meadow via a smooth patch field) and
        // thickens toward the eight cube corners (a random thicket that steers the player off the
        // glitchy triple-points without an obvious ring). Trees, then bushes and the odd field rock.
        for (faceIdx, face) in CubeFace.allCases.enumerated() {
            for row in 0..<size {
                for col in 0..<size {
                    if face == .positiveZ && ((row, col) == spawn || (row, col) == portalTile) { continue }
                    guard let (ci, fi) = faceletAt(face: face, row: row, col: col) else { continue }
                    if cubies[ci].facelets[fi].terrain == .water { continue }
                    let dir = tileDirection(face: face, row: row, col: col)
                    let boost = cornerBoost(dir)
                    let h = hash(faceIdx * 131 + row, col, row &- col)
                    let rollFrac = Float(h % 1000) / 1000.0
                    // Grove where the patch field is high or near a corner; meadow elsewhere. Corner
                    // cover is heavy (0.9·boost) — a thicket over the glitchy triple-points.
                    let treeProb = min(0.98, 0.14 + 0.55 * patchField(dir) + 0.90 * boost)
                    if rollFrac < treeProb {
                        // A random grove: several conifers scattered across the tile's cells (denser
                        // near corners), each a distinct size; one solid trunk anchors it lightly.
                        let count = 2 + Int(boost * 3.0)          // 2 … ~5 (corners)
                        for i in 0..<count {
                            let th = hash(faceIdx &* 991 + row &* 17, col &* 13 &+ i, i &* 7 &+ row &- col)
                            let ar = Int(th % 3), ac = Int((th / 3) % 3)
                            let st = Int((th >> 8) % 3)
                            // Anywhere in the tile (`scatterPlacement`). The trunk takes the SAME
                            // placement as its crown, or the tree stands beside its own trunk.
                            let p = scatterPlacement(th, clearCells: PropKind.treeTrunk.footprintRadius(grid: worldScale.standGrid))
                            _ = (ar, ac)
                            cubies[ci].facelets[fi].props.append(
                                Prop(kind: .tree, subRow: p.subRow, subCol: p.subCol, state: st,
                                     viewAngle: p.yaw, offsetX: p.ox, offsetY: p.oy))
                            if i == 0 {   // one solid trunk (keeps collision light while trees spread)
                                cubies[ci].facelets[fi].props.append(
                                    Prop(kind: .treeTrunk, subRow: p.subRow, subCol: p.subCol, state: st,
                                         viewAngle: p.yaw, offsetX: p.ox, offsetY: p.oy))
                            }
                        }
                    } else {
                        let r2 = (h >> 12) % 100
                        // These used to sit on the tile CENTRE (1,1) — every bush and rock on the
                        // world dead centre of its own tile, the strongest lattice available. Now
                        // placed continuously, in counts that vary over ~4 tiles so open ground and
                        // rocky patches both exist instead of an even sprinkle everywhere.
                        let dens = clumpField(row, col, salt: faceIdx &* 17 &+ 3)
                        // Bushes are non-solid and can be lush; boulders are solid with a 5×5
                        // footprint, so a tile full of them is a sealed tile.
                        let count = r2 < 20 ? Int((dens * dens * 5.0).rounded())
                                            : min(2, Int((dens * 2.4).rounded()))
                        for k in 0..<count {
                            let hk = hash(row &* 61 &+ col, k &* 23 &+ 5, faceIdx &* 9 &+ k)
                            let p = scatterPlacement(hk, clearCells: r2 < 20 ? 0
                                : PropKind.boulder.footprintRadius(grid: worldScale.standGrid))
                            if r2 < 20 {   // leafy bush — alpha-cutout foliage card; state = LeafSet slice
                                cubies[ci].facelets[fi].props.append(
                                    Prop(kind: .foliageCard, subRow: p.subRow, subCol: p.subCol,
                                         state: Int((hk >> 10) % 8), viewAngle: p.yaw,
                                         offsetX: p.ox, offsetY: p.oy))
                            } else if r2 < 28 {
                                cubies[ci].facelets[fi].props.append(
                                    Prop(kind: .boulder, subRow: p.subRow, subCol: p.subCol,
                                         state: Int((hk >> 8) % 3), viewAngle: p.yaw,
                                         offsetX: p.ox, offsetY: p.oy))
                            }
                        }
                    }
                }
            }
        }

        if let (ci, fi) = faceletAt(face: .positiveZ, row: portalTile.0, col: portalTile.1) {
            if homePortalToGarden {
                // M20 (Eddie) — the FIRST world's one portal: a stone ARCH you step through to the
                // GARDEN (destination index 3). Rendered as the arch model + volumetric-cloud field
                // (material 23), not the TARDIS; always open (never sealed). Faces the approaching
                // player (north, toward spawn). The Renderer stamps the arch model (stampPortalFrames).
                cubies[ci].facelets[fi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n, state: 3))
                styledPortals.append(StyledPortal(ci: ci, fi: fi, facing: .n, fieldStyle: 2))
                cubies[ci].facelets[fi].props.append(Prop(kind: .portalRing, subRow: 1, subCol: 1))
                cubies[ci].facelets[fi].props.append(Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .n, state: 2, extraScale: 0.9375))
            } else {
                // The way home — a walk-through return portal one tile south of arrival.
                cubies[ci].facelets[fi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n))
                cubies[ci].facelets[fi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))
            }
        }
    }

    // MARK: - Rooms (M10 Phase F)

    /// Prototype: merge a 3×3 block of tiles centered on the player's start face into
    /// one open plaza. Interior shared edges become `open` (passable, no geometry).
    private func stampDemoRoom() {
        let h = min(3, size), w = min(3, size)
        let top = max(0, size / 2 - h / 2)
        let left = max(0, size / 2 - w / 2)
        stampRoom(face: .positiveZ, top: top, left: left, height: h, width: w)
    }

    /// Open the interior shared edges of a rectangular tile block so it reads as one room.
    func stampRoom(face: CubeFace, top: Int, left: Int, height: Int, width: Int) {
        func open(_ r: Int, _ c: Int, _ dir: SurfaceDirection) {
            guard let (ci, fi) = faceletAt(face: face, row: r, col: c) else { return }
            let m = Self.directionMask(dir)
            cubies[ci].facelets[fi].mazeTile.openings.insert(m)
            cubies[ci].facelets[fi].mazeTile.openEdges.insert(m)
        }
        for r in top..<(top + height) {
            for c in left..<(left + width) {
                if c + 1 < left + width { open(r, c, .east);  open(r, c + 1, .west) }
                if r + 1 < top + height { open(r, c, .south); open(r + 1, c, .north) }
            }
        }
    }

    /// Open a rectangular block into a fully walkable, hedge-free room the player can enter
    /// (M12-E). Every edge of every block tile is opened — so no interior *or* perimeter hedges
    /// render, leaving the imported house walls to enclose it — and the reciprocal edges of the
    /// same-face neighbours are opened too, so the player can walk in from the surrounding plaza.
    /// Edges that fall off the face (the cube-edge sides where a slice splits the house) simply
    /// find no neighbour and are skipped.
    func stampOpenPlaza(face: CubeFace, top: Int, left: Int, height: Int, width: Int) {
        let n = size
        func open(_ r: Int, _ c: Int, _ dir: SurfaceDirection) {
            guard (0..<n).contains(r), (0..<n).contains(c),
                  let (ci, fi) = faceletAt(face: face, row: r, col: c) else { return }
            let m = Self.directionMask(dir)
            cubies[ci].facelets[fi].mazeTile.openings.insert(m)
            cubies[ci].facelets[fi].mazeTile.openEdges.insert(m)
        }
        for r in top..<(top + height) {
            for c in left..<(left + width) {
                open(r, c, .north); open(r, c, .south); open(r, c, .east); open(r, c, .west)
            }
        }
        // Reciprocal same-face neighbour edges, so the room connects to the plaza around it.
        for c in left..<(left + width) {
            open(top - 1, c, .south)         // north neighbour ↔ block
            open(top + height, c, .north)    // south neighbour ↔ block
        }
        for r in top..<(top + height) {
            open(r, left - 1, .east)         // west neighbour ↔ block
            open(r, left + width, .west)     // east neighbour ↔ block
        }
    }

    /// M16.6 — the temple lock, shared by the overworld (`stampDemoProps`) and the M20 garden
    /// (`stampGardenMaze`). Places the SEALED interior door (portal `state==1`), its rigid **bond**
    /// (the door + its two flanking pillar tiles + the ROOT cubie straight through the hollow core on
    /// the opposite face — so any start-face twist is REFUSED until unlocked), the **door plinth**
    /// (caustic-glyph progress read-out + the turn), and the **four switches** (disc-less base +
    /// number cylinder; three engaged, the fourth off — engage it to unbond). Verified to run
    /// identically on a flat or curved (roundness 1) world (2026-07-17). All on face `.positiveZ`.
    private func stampTempleLock(doorRow: Int, doorCol: Int, doorFacing: Heading8,
                                 plinthRow: Int, plinthSubRow: Int,
                                 switchCenter: Int, spread: Int, elevatorStyle: Int? = nil) {
        guard let (dci, dfi) = faceletAt(face: .positiveZ, row: doorRow, col: doorCol) else { return }
        // `.push`: the temple door is a DESCENT — entering it from the garden (itself already a pushed
        // world) must nest, not pop. (Phase 0 — this used to be inferred by the Renderer recognising
        // the destination name "temple-interior"; the portal now carries the fact.)
        cubies[dci].facelets[dfi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: doorFacing, state: 1, transition: .push))
        if let style = elevatorStyle {
            // M20 (Eddie) — an ELEVATOR portal, not the TARDIS: the streak field + ring (hidden while
            // sealed) and, via the Renderer, two flanking columns. No lamp.
            styledPortals.append(StyledPortal(ci: dci, fi: dfi, facing: doorFacing, fieldStyle: style))
            cubies[dci].facelets[dfi].props.append(Prop(kind: .portalRing, subRow: 1, subCol: 1))
            cubies[dci].facelets[dfi].props.append(Prop(kind: .portalField, subRow: 1, subCol: 1, facing: doorFacing, state: style))
        } else {
            cubies[dci].facelets[dfi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))
        }
        sealedPortalCubies.insert(dci)   // M16.4: closed until unlocked AND twisted open
        // The door plinth — seated on the tile in front of the door (the side the player approaches
        // from), NOT the walk-through door tile. Falls back onto the door tile on a tiny cube.
        if (0..<size).contains(plinthRow), let (mci, mfi) = faceletAt(face: .positiveZ, row: plinthRow, col: doorCol) {
            cubies[mci].facelets[mfi].props.append(Prop(kind: .plinth, subRow: plinthSubRow, subCol: 1, facing: doorFacing, state: 0))
        } else {
            let doorOpenings = cubies[dci].facelets[dfi].mazeTile.openings
            cubies[dci].facelets[dfi].props.append(plinth(onTile: doorOpenings, preferred: doorFacing == .n ? .north : .south, symbol: 0))
        }
        var bond: Set<Int> = [dci]
        for pc in [doorCol - 1, doorCol + 1] where (0..<size).contains(pc) {
            if let (pci, pfi) = faceletAt(face: .positiveZ, row: doorRow, col: pc) {
                cubies[pci].facelets[pfi].props.append(Prop(kind: .obelisk, subRow: 1, subCol: 1))
                bond.insert(pci)
            }
        }
        if let root = cubies.firstIndex(where: { $0.position == SIMD3<Int32>(Int32(doorCol), Int32(doorRow), 0) }) {
            bond.insert(root)
        }
        addBond(bond)
        templeDoorBond = bond   // stored so disengaging a switch can RE-lock the door (goof-and-fix)
        // Four switches: (row, col, engaged, ordinal). Three engaged, the SE one off.
        let switchSpots: [(Int, Int, Int, Int)] = [
            (switchCenter - spread, switchCenter - spread, 1, 1),
            (switchCenter - spread, switchCenter + spread, 1, 2),
            (switchCenter + spread, switchCenter - spread, 1, 3),
            (switchCenter + spread, switchCenter + spread, 0, 4),
        ]
        for (r, c2, engaged, ordinal) in switchSpots {
            if let (ci2, fi2) = faceletAt(face: .positiveZ, row: r, col: c2) {
                cubies[ci2].facelets[fi2].props.append(Prop(kind: .switchBase, subRow: 1, subCol: 1, facing: .n))
                var cap = Prop(kind: .switchCap, subRow: 1, subCol: 1, facing: .n, state: ordinal)
                cap.anim = Float(engaged); cap.alignAnim = Float(engaged)
                cubies[ci2].facelets[fi2].props.append(cap)
            }
        }
    }

    /// Place a hedge-sculpture topiary in the NW corner sub-cell of each start-plaza tile
    /// so Phase G's prop pipeline is visible — and rides slice rotations (the plaza is on
    /// the start face, so Q/E carries the topiaries around). (M10 Phase G)
    private func stampDemoProps(templeDoor: Bool) {
        let h = min(3, size), w = min(3, size)
        let top = max(0, size / 2 - h / 2)
        let left = max(0, size / 2 - w / 2)
        for r in top..<(top + h) {
            for c in left..<(left + w) {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                cubies[ci].facelets[fi].props.append(Prop(kind: .topiary, subRow: 0, subCol: 0))
            }
        }
        // On the plaza-centre tile (the player's start tile): a landmark obelisk (SE corner) and an
        // interactive chest (NE corner).
        if let (ci, fi) = faceletAt(face: .positiveZ, row: size / 2, col: size / 2) {
            cubies[ci].facelets[fi].props.append(Prop(kind: .obelisk, subRow: 2, subCol: 2))
            cubies[ci].facelets[fi].props.append(Prop(kind: .chest, subRow: 0, subCol: 2))
        }
        // Open the start plaza into a walkable hub, and put a portal doorway on the empty tile just
        // NORTH of the plaza (M11.2c): walking onto it switches worlds — step through it like a
        // doorway, no button (F still works). The 3×3 plaza itself is fully packed with the imported
        // decorations, so the portal sits one tile beyond it (reachable — stampOpenPlaza opens that
        // edge). On a tiny cube with no room north, it falls back into the plaza.
        stampOpenPlaza(face: .positiveZ, top: top, left: left, height: h, width: w)
        let portalRow = max(0, top - 1)
        if let (ci, fi) = faceletAt(face: .positiveZ, row: portalRow, col: left + w / 2) {
            // facing = the door's EXIT direction (M15.2): emerge looking south, back at the plaza.
            cubies[ci].facelets[fi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .s))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))  // flashing lamp atop
        }
        // M15.2: a second doorway SOUTH of the plaza — the temple interior (destination id 1;
        // Prop.state carries which world a portal leads to). Overworld only.
        // M16.1: the temple is a LOCKED, bonded structure — the door tile, its two flanking
        // pillar tiles, and a ROOT cubie directly beneath the door are one rigid bond. Because
        // the root lies in the layer below, the start face's own slice twist (Q/E) would tear
        // the bond and is REFUSED — the temple pins the face until the lock is undone (M16.3).
        let templeRow = min(size - 1, top + h)
        let doorCol = left + w / 2
        if templeDoor {
            // Door faces NORTH (toward the plaza the player approaches from); plinth on the plaza tile
            // just north of the door; switches at the diagonal ±spread of the plaza centre.
            stampTempleLock(doorRow: templeRow, doorCol: doorCol, doorFacing: .n,
                            plinthRow: templeRow - 1, plinthSubRow: 0,
                            switchCenter: size / 2, spread: min(3, size / 2))
        }
        // M12-E: the 2×2 modular house gets its OWN open plaza on the −Z (back) face, away from the
        // crowded +Z demo plaza, so it has room to breathe. It sits at the row-0 face edge so an
        // adjacent-face slice still cuts through and splits it. The court is opened into a hedge-free,
        // walkable room and revealed, so the imported walls do the enclosing and the player can walk
        // in from the surrounding plaza.
        let houseFace: CubeFace = .negativeZ
        let courtW = min(4, size), courtH = min(4, size)
        let courtLeft = max(0, size / 2 - courtW / 2)
        stampOpenPlaza(face: houseFace, top: 0, left: courtLeft, height: courtH, width: courtW)
        for r in 0..<courtH {
            for c in courtLeft..<(courtLeft + courtW) {
                if let (ci, fi) = faceletAt(face: houseFace, row: r, col: c) {
                    cubies[ci].facelets[fi].tileState = .discovered
                    cubies[ci].facelets[fi].discoveryAmount = 1.0
                }
            }
        }
        // The 2×2 quarters, centred across the court width, at the row-0 edge (for the split).
        let hLeft = courtLeft + max(0, (courtW - 2) / 2)
        let house: [(Int, Int, Heading8)] = [(0, hLeft, .n), (0, hLeft + 1, .e), (1, hLeft, .w), (1, hLeft + 1, .s)]
        for (r, c, f) in house {
            if let (ci, fi) = faceletAt(face: houseFace, row: r, col: c) {
                cubies[ci].facelets[fi].props.append(Prop(kind: .houseCorner, subRow: 1, subCol: 1, facing: f))
            }
        }
    }

    /// M16.5 placement rules (Eddie): a plaque must never face into a wall, and must never
    /// stand in the walkway. Face it along an OPEN direction of its tile (preferring the
    /// approach side), and stand it in a CORNER subcell — the 3×3 path-cross only ever walks
    /// the centre and edge-centre subcells, so a corner can't block anyone. Of the two corners
    /// on the edge behind it, hug one with a closed lateral wall when there is one.
    /// M16.6 — place a Builder plinth on an open side of the tile (never against a wall), carrying
    /// `symbol` (a TextureLoader.CausticSymbol raw value) lit on its top face. Mirrors
    /// `glyphPlaque`'s siting rules; the plinth supersedes it beside the M16 lock.
    private func plinth(onTile openings: DirectionMask, preferred: SurfaceDirection, symbol: Int) -> Prop {
        let order: [SurfaceDirection] = [preferred, .north, .south, .east, .west]
        let dir = order.first(where: { openings.contains(Self.directionMask($0)) }) ?? preferred
        let westClosed = !openings.contains(.west)
        let northClosed = !openings.contains(.north)
        switch dir {
        case .north: return Prop(kind: .plinth, subRow: 2, subCol: westClosed ? 0 : 2, facing: .n, state: symbol)
        case .south: return Prop(kind: .plinth, subRow: 0, subCol: westClosed ? 0 : 2, facing: .s, state: symbol)
        case .east:  return Prop(kind: .plinth, subRow: northClosed ? 0 : 2, subCol: 0, facing: .e, state: symbol)
        case .west:  return Prop(kind: .plinth, subRow: northClosed ? 0 : 2, subCol: 2, facing: .w, state: symbol)
        }
    }

    private func glyphPlaque(onTile openings: DirectionMask, preferred: SurfaceDirection) -> Prop {
        let order: [SurfaceDirection] = [preferred, .north, .south, .east, .west]
        let dir = order.first(where: { openings.contains(Self.directionMask($0)) }) ?? preferred
        let westClosed = !openings.contains(.west)
        let northClosed = !openings.contains(.north)
        switch dir {
        case .north: return Prop(kind: .glyph, subRow: 2, subCol: westClosed ? 0 : 2, facing: .n)
        case .south: return Prop(kind: .glyph, subRow: 0, subCol: westClosed ? 0 : 2, facing: .s)
        case .east:  return Prop(kind: .glyph, subRow: northClosed ? 0 : 2, subCol: 0, facing: .e)
        case .west:  return Prop(kind: .glyph, subRow: northClosed ? 0 : 2, subCol: 2, facing: .w)
        }
    }

    /// Where this world's (first) portal doorway stands — arrivals emerge here, facing the
    /// portal's `facing` (its exit direction), so travel reads as walking through a door
    /// (M15.2). Scans the grid; worlds have at most a couple of portals.
    func firstPortalLocation() -> (face: CubeFace, row: Int, col: Int, exitFacing: Heading8)? {
        for face in CubeFace.allCases {
            for row in 0..<size {
                for col in 0..<size {
                    if let (ci, fi) = faceletAt(face: face, row: row, col: col),
                       let portal = cubies[ci].facelets[fi].props.first(where: { $0.kind == .portal }) {
                        return (face, row, col, portal.facing)
                    }
                }
            }
        }
        return nil
    }

    /// M15.2 — the first hand-stamped interior world (a 5³ temple, D3). Sparse and legible: a
    /// 3×3 open hall centred on the arrival face (+Z, where the player spawns at the centre), a
    /// pedestal to the north (placeholder for the M17 memory-mote), and the way home to the
    /// south — a walk-through return portal. The generated maze stands everywhere else: the
    /// chamber is the anteroom, the rest of the inside is there to be explored.
    private func stampTempleInterior() {
        let n = size
        let c = n / 2
        let top = max(0, c - 1), left = max(0, c - 1)
        let h = min(3, n), w = min(3, n)
        stampOpenPlaza(face: .positiveZ, top: top, left: left, height: h, width: w)
        // Pedestal north of centre (the player spawns AT centre — keep it clear), with the same
        // carved glyph beside it (M16.5) — the mote's future home, marked in the language.
        if let (ci, fi) = faceletAt(face: .positiveZ, row: max(0, c - 1), col: c) {
            cubies[ci].facelets[fi].props.append(Prop(kind: .obelisk, subRow: 1, subCol: 1))
            let pedOpenings = cubies[ci].facelets[fi].mazeTile.openings
            cubies[ci].facelets[fi].props.append(glyphPlaque(onTile: pedOpenings, preferred: .south))
        }
        // Return portal south of centre (walking onto it exits — depth > 1 always pops).
        // Its exit direction is north: arrivals emerge facing the hall and the pedestal.
        if let (ci, fi) = faceletAt(face: .positiveZ, row: min(n - 1, c + 1), col: c) {
            cubies[ci].facelets[fi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n))
            // M20 (Eddie) — an ELEVATOR portal going UP (temple → surface); always active here (never
            // sealed), so its streak field is always shown. Columns added by the Renderer.
            styledPortals.append(StyledPortal(ci: ci, fi: fi, facing: .n, fieldStyle: 4))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalRing, subRow: 1, subCol: 1))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .n, state: 4))
        }
        // M20 (Eddie) — an obelisk on each of the five OTHER interior surfaces, so the hall is marked
        // on every side rather than only the pedestal wall. Each is dropped at a random spot inside
        // that face's middle 3×3 (never the rim, so it never crowds an edge), from a fixed seed — so
        // the five positions are scattered but identical every run.
        let mid = max(0, (n - 3) / 2)                  // the middle 3×3 spans mid ..< mid+3
        var obeliskRNG = FaceSeededRNG(seed: 4242)
        for face in CubeFace.allCases where face != .positiveZ {
            let r = mid + Int(obeliskRNG.next() % 3)
            let col = mid + Int(obeliskRNG.next() % 3)
            guard let (oci, ofi) = faceletAt(face: face, row: r, col: col) else { continue }
            cubies[oci].facelets[ofi].props.append(Prop(kind: .obelisk, subRow: 1, subCol: 1))
        }
    }

    private static func directionMask(_ dir: SurfaceDirection) -> DirectionMask {
        switch dir {
        case .north: return .north
        case .east:  return .east
        case .south: return .south
        case .west:  return .west
        }
    }

    convenience init(size: Int) {
        self.init(worldScale: WorldScale(cubeSize: size))
    }

    private func buildFaceletLocationMap() {
        faceletLocation.removeAll(keepingCapacity: true)
        for (ci, cubie) in cubies.enumerated() {
            for (fi, facelet) in cubie.facelets.enumerated() {
                faceletLocation[facelet.id] = (ci, fi)
            }
        }
    }

    // MARK: - Initialization

    private func buildCubies() {
        var cubieIndex = 0
        var faceletIndex = 0
        let n = Int32(size)

        for x: Int32 in 0..<n {
            for y: Int32 in 0..<n {
                for z: Int32 in 0..<n {
                    let onMinX = x == 0
                    let onMaxX = x == n - 1
                    let onMinY = y == 0
                    let onMaxY = y == n - 1
                    let onMinZ = z == 0
                    let onMaxZ = z == n - 1

                    let isSurface = onMinX || onMaxX || onMinY || onMaxY || onMinZ || onMaxZ
                    guard isSurface else { continue }

                    let cubieID = CubieID(rawValue: cubieIndex)
                    cubieIndex += 1
                    var facelets: [MazeFacelet] = []

                    let exposedFaces: [(CubeFace, Bool)] = [
                        (.positiveX, onMaxX), (.negativeX, onMinX),
                        (.positiveY, onMaxY), (.negativeY, onMinY),
                        (.positiveZ, onMaxZ), (.negativeZ, onMinZ),
                    ]

                    for (face, exposed) in exposedFaces {
                        guard exposed else { continue }
                        let fid = FaceletID(rawValue: faceletIndex)
                        faceletIndex += 1
                        let seed = UInt32(truncatingIfNeeded: fid.rawValue &* 2654435761)
                        let facelet = MazeFacelet(
                            id: fid,
                            cubieID: cubieID,
                            localFace: face,
                            mazeTile: MazeTile(openings: [], styleSeed: seed),
                            tileState: .unknown,
                            discoveryAmount: 0
                        )
                        facelets.append(facelet)
                    }

                    let cubie = Cubie(
                        id: cubieID,
                        position: SIMD3(x, y, z),
                        orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                        facelets: facelets
                    )
                    cubies.append(cubie)
                }
            }
        }
    }

    private func generateMaze() {
        // Simple per-face maze using recursive backtracker
        // For now, generate a basic pattern that guarantees some connectivity
        for face in CubeFace.allCases {
            generateFaceMaze(face: face)
        }
    }

    private func generateFaceMaze(face: CubeFace) {
        let n = size
        var grid = Array(repeating: Array(repeating: DirectionMask(), count: n), count: n)
        var visited = Array(repeating: Array(repeating: false, count: n), count: n)

        struct Cell { let row: Int; let col: Int }

        func neighbors(_ c: Cell) -> [(SurfaceDirection, Cell)] {
            var result: [(SurfaceDirection, Cell)] = []
            if c.row > 0     { result.append((.north, Cell(row: c.row - 1, col: c.col))) }
            if c.row < n - 1 { result.append((.south, Cell(row: c.row + 1, col: c.col))) }
            if c.col > 0     { result.append((.west,  Cell(row: c.row, col: c.col - 1))) }
            if c.col < n - 1 { result.append((.east,  Cell(row: c.row, col: c.col + 1))) }
            return result
        }

        func directionMask(_ d: SurfaceDirection) -> DirectionMask {
            switch d {
            case .north: return .north
            case .east:  return .east
            case .south: return .south
            case .west:  return .west
            }
        }

        var stack: [Cell] = []
        let start = Cell(row: 0, col: 0)
        visited[0][0] = true
        stack.append(start)

        // Seeded RNG for reproducibility per face
        var rng = FaceSeededRNG(seed: UInt64(face.rawValue) &+ 42)

        while !stack.isEmpty {
            let current = stack.last!
            let unvisited = neighbors(current).filter { !visited[$0.1.row][$0.1.col] }

            if unvisited.isEmpty {
                stack.removeLast()
            } else {
                let idx = Int(rng.next() % UInt64(unvisited.count))
                let (dir, next) = unvisited[idx]
                grid[current.row][current.col].insert(directionMask(dir))
                grid[next.row][next.col].insert(directionMask(dir.opposite))
                visited[next.row][next.col] = true
                stack.append(next)
            }
        }

        // Apply to facelets. faceletAt = cached projection + O(1) id map — the old per-cell
        // findFaceletIndices(face:) linear scan made maze gen O(n⁵): ~58M cubie visits at size 25,
        // the whole of the startup cost (R2, startup-time fix).
        for row in 0..<n {
            for col in 0..<n {
                if let (ci, fi) = faceletAt(face: face, row: row, col: col) {
                    cubies[ci].facelets[fi].mazeTile.openings = grid[row][col]
                }
            }
        }
    }

    // MARK: - Projection

    func rebuildProjection() {
        let n = size
        cachedProjection = [:]
        for face in CubeFace.allCases {
            var grid: [[FaceletID?]] = Array(
                repeating: Array(repeating: nil, count: n),
                count: n
            )
            for cubie in cubies {
                for facelet in cubie.facelets {
                    let worldFace = effectiveFace(cubie: cubie, localFace: facelet.localFace)
                    guard worldFace == face else { continue }
                    let (row, col) = gridPosition(cubie: cubie, face: face)
                    if row >= 0 && row < n && col >= 0 && col < n {
                        grid[row][col] = facelet.id
                    }
                }
            }
            cachedProjection[face] = grid
        }
        projectionDirty = false
    }

    func faceletAt(face: CubeFace, row: Int, col: Int) -> (cubieIndex: Int, faceletIndex: Int)? {
        if projectionDirty { rebuildProjection() }
        // Bounds-guard row/col: the `?[row][col]` below only guards the missing-FACE case (the `?`),
        // NOT the array subscript — so an out-of-face (row, col) crashes "Index out of range" instead
        // of returning nil. Callers like dressedWallProps.neighbor() pass row±1/col±1 and rely on nil
        // at the face edge. Latent until a maze filled a whole face (the size-11 garden — Eddie).
        guard (0..<size).contains(row), (0..<size).contains(col) else { return nil }
        guard let fid = cachedProjection[face]?[row][col] else { return nil }
        return findFaceletIndices(id: fid)
    }

    // MARK: - Shape (M14 — shape-as-meaning)

    /// Roundness dial for the superellipsoid "inflated cube". `0` = today's hard cube
    /// (behavior-neutral); `1` = maximum inflation toward a sphere. **Per-world** — this
    /// is the shape-as-meaning axis: natural worlds bulge round, mechanistic worlds stay
    /// hard-cubic. Only the *render geometry* (tile centers + basis) is remapped; the maze
    /// topology, movement, slice, and bandaging all stay grid-based and untouched.
    var roundness: Float = 0.0

    /// M20 first cut — the natural-maze hybrid flag: this world is a real hedge maze (walls,
    /// gateways, twistable) but dressed natural — grass floors instead of paved, no dark cube
    /// frame. SceneBuilder reads it. Default false ⇒ maze worlds render byte-identically.
    var naturalDressing = false

    /// M20 — how this world's maze walls render (see `WallStyle`). `.dressed` ⇒ SceneBuilder skips the
    /// hedge wall + post meshes and the Renderer emits imported wall models per closed edge instead
    /// (twist-safe, re-derived from topology). Default `.hedge` ⇒ other worlds are byte-identical.
    ///
    /// This used to say "movement is unaffected either way", which was half true and the reason the
    /// garden had invisible walls: closed edges do block from topology alone, but OPEN edges were
    /// still being narrowed to a centred gap between jamb posts that a dressed world never draws.
    /// See `fullWidthGateways`.
    var wallStyle: WallStyle = .hedge

    /// Scene 3 — plinths and obelisks are paired by SYMBOL rather than collectively. Activating a
    /// plinth wakes the obelisk carrying the same symbol, wherever in the chamber it stands: "a
    /// plinth must not be placed on the same face as its matching obelisk… each pairing therefore
    /// requires the player to connect a remote control with a distant response."
    var symbolPairedPlinths = false

    /// Whether an open edge may be crossed at its full width. True where the world draws no jamb
    /// posts to justify a narrower gap — i.e. dressed walls, where the stone sits on closed edges
    /// and an open edge is genuinely empty. The rule is "collision matches what you can see": a
    /// hedge gateway really is a gap in a wall, and is still crossed through its middle third.
    var fullWidthGateways: Bool { wallStyle == .dressed }

    /// Scene 1 — dressed walls with NO overgrowth. Its stone is "old but not ruined… too large, too
    /// evenly fitted, and too free of vegetation to belong comfortably to any recognizable human
    /// period". The garden's walls want the opposite (graded moss and rubble), so this is per-world
    /// rather than a change to the dressing itself.
    var cleanWalls = false

    /// M20 — suppress ALL fog for this world (both the unknown-tile fog cubes and the distance
    /// fog): a dev/showroom world (the gallery) shouldn't have atmosphere. Fog is opt-out — only
    /// worlds that use it for the story/discovery keep it (Eddie: fog off unless it serves a world).
    var noFog = false

    /// M19 relief — how much the surface rolls into hills, as a fraction of the world radius
    /// (0 = smooth planet, the default for every world today). Consumed by `inflatedUnitPoint`
    /// (CPU: camera, rigid seats) and, once wired, `m14bInflate` (GPU: floors, props). Kept 0
    /// until the GPU half lands so the camera never floats above a flat floor.
    var reliefAmplitude: Float = 0.0

    /// Low-distortion cube→sphere map (the standard "Cobb"/`√` cube-sphere): pushes a point
    /// on the unit cube `[-1,1]³` onto the unit sphere, then blends back toward the flat cube
    /// point by `roundness`. `roundness == 0` returns the point unchanged (no-op fast path).
    /// ⚠️ Twin implementation: must stay bit-identical to `m14bInflate` in Shaders.metal — the
    /// camera/props seat on THIS function while the floor renders through the shader one. The
    /// golden-value test in CoordinateMathTests is the tripwire (internal, not private, for it).
    func inflatedUnitPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        guard roundness > 0 else { return p }
        let x = p.x, y = p.y, z = p.z
        let sx = x * (max(0, 1 - (y*y + z*z) / 2 + (y*y * z*z) / 3)).squareRoot()
        let sy = y * (max(0, 1 - (z*z + x*x) / 2 + (z*z * x*x) / 3)).squareRoot()
        let sz = z * (max(0, 1 - (x*x + y*y) / 2 + (x*x * y*y) / 3)).squareRoot()
        let sphere = SIMD3(sx, sy, sz)
        let blended = p + (sphere - p) * roundness
        // M19 relief (CPU half): push the surface point radially by a smooth height field, so the
        // ground rolls into hills. amplitude 0 ⇒ exact no-op (all worlds today). The GPU half
        // (m14bInflate + a FrameUniforms amplitude) is wired with Eddie so the camera-on-ground
        // match can be eyeballed live. Radial == normal on a sphere (relief worlds are roundness 1).
        guard reliefAmplitude > 0 else { return blended }
        let len = (blended.x*blended.x + blended.y*blended.y + blended.z*blended.z).squareRoot()
        guard len > 1e-5 else { return blended }
        let dir = blended / len
        return blended * (1 + reliefAmplitude * Self.reliefHeight(dir))
    }

    /// M19 relief height field — rolling hills (a sum of sinusoids over the surface *direction*)
    /// PLUS a handful of localized bowl dents with a subtle raised rim: these read as **craters**
    /// on the grey moon and as gentle **hollows/dells** on the green earth. Depends only on
    /// direction and is continuous everywhere ⇒ seams stay continuous by construction. Clamped to
    /// [−1, 1]. **Keep byte-identical to `m14bReliefHeight` in Shaders.metal.**
    static let craterCenters: [SIMD3<Float>] = [
        SIMD3(0.30, 0.80, 0.50), SIMD3(-0.60, 0.20, 0.77), SIMD3(0.55, -0.50, 0.67),
        SIMD3(-0.25, -0.70, -0.67), SIMD3(0.80, 0.35, -0.49)
    ]
    static func smoothstepF(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }
    static func reliefHeight(_ dir: SIMD3<Float>) -> Float {
        let a = sinf(dir.x * 5.1 + dir.y * 2.3)
        let b = sinf(dir.y * 4.7 - dir.z * 3.1)
        let c = sinf(dir.z * 5.5 + dir.x * 2.9)
        var h = (a + b + c) / 3.0 * 0.6
        for cc in craterCenters {
            let n = simd_normalize(cc)
            let t = simd_dot(dir, n)
            let bowl = -smoothstepF(0.88, 1.0, t)
            let rim = 0.22 * smoothstepF(0.855, 0.885, t) * (1.0 - smoothstepF(0.885, 0.915, t))
            h += bowl * 0.75 + rim
        }
        return max(-1, min(1, h))
    }

    // MARK: - World matrices

    /// The **flat** (un-inflated, un-spun) placement of a tile — tangent/bitangent/normal basis at
    /// the tile center on the axis-aligned cube face. This is the rest frame the M14b vertex shader
    /// inflates from (per-vertex); rigid objects seat on the curve via `inflatedPlacement` instead.
    /// Audio Phase D — how many WALLS stand between two tiles on the same face.
    ///
    /// The plan's key insight: PHASE can do geometry-aware occlusion, but feeding it the world mesh
    /// would be expensive and pointless when we already hold the maze. Walking `openings` is cheap,
    /// exact, and twist-correct for free — the topology IS the occluder, and it rotates with the
    /// slab, so a twist that opens a corridor also opens the sound down it with no extra work.
    ///
    /// A greedy march toward the target, stepping along whichever axis has the most ground left and
    /// counting the closed edges it crosses. Not a true line-of-sight raycast; on a grid of ~19 m
    /// tiles it is indistinguishable, and it can never claim a clear path where the maze has none.
    func wallsBetween(face: CubeFace, fromRow: Int, fromCol: Int, toRow: Int, toCol: Int) -> Int {
        var r = fromRow, c = fromCol, walls = 0, guardCount = 0
        while (r, c) != (toRow, toCol) && guardCount < 4 * size {
            guardCount += 1
            let dr = toRow - r, dc = toCol - c
            let stepRow = abs(dr) >= abs(dc)
            let dir: SurfaceDirection = stepRow ? (dr < 0 ? .north : .south) : (dc < 0 ? .west : .east)
            guard let (ci, fi) = faceletAt(face: face, row: r, col: c) else { return walls + 1 }
            if !cubies[ci].facelets[fi].mazeTile.openings.contains(direction: dir) { walls += 1 }
            if stepRow { r += dr < 0 ? -1 : 1 } else { c += dc < 0 ? -1 : 1 }
        }
        return walls
    }

    /// Where a (cubie, facelet) pair currently sits on the surface. The reverse of `faceletAt`, and
    /// live rather than remembered: a twist moves facelets between grid slots, so anything holding a
    /// (ci, fi) — a styled portal, an emitter — has to ask again rather than cache.
    func locate(cubie ci: Int, facelet fi: Int) -> (face: CubeFace, row: Int, col: Int)? {
        let want = cubies[ci].facelets[fi].id.rawValue
        for face in CubeFace.allCases {
            for r in 0..<size {
                for c in 0..<size {
                    guard let (aci, afi) = faceletAt(face: face, row: r, col: c) else { continue }
                    if cubies[aci].facelets[afi].id.rawValue == want { return (face, r, c) }
                }
            }
        }
        return nil
    }

    func restMatrix(face: CubeFace, row: Int, col: Int) -> float4x4 {
        let halfN = Float(size) / 2.0
        let spacing = worldScale.cellSpacing
        let normal = face.normal
        let tangent = face.tangent
        let bitangent = face.bitangent
        let colF = (Float(col) + 0.5 - halfN) * spacing
        let rowF = (Float(row) + 0.5 - halfN) * spacing

        // M15.1 — interior world: the tile sits on the SAME face plane but is seen from inside,
        // which is a mirror image. Keep col ↔ +tangent, mirror the row axis instead: basis
        // (tangent, −bitangent, −normal) — right-handed, det +1 (cross(t,−b) = −n ✓), local "up"
        // (+z) points into the cube — and mirror the row *placement* to match (rowF term negated),
        // so tile-local geometry (walls on grid-north edges etc.) stays aligned with grid logic.
        if worldScale.interior {
            let center = normal * halfN + tangent * colF - bitangent * rowF
            return float4x4(columns: (
                SIMD4(tangent.x,    tangent.y,    tangent.z,    0),
                SIMD4(-bitangent.x, -bitangent.y, -bitangent.z, 0),
                SIMD4(-normal.x,    -normal.y,    -normal.z,    0),
                SIMD4(center.x,     center.y,     center.z,     1)
            ))
        }

        let center = normal * halfN + tangent * colF + bitangent * rowF
        return float4x4(columns: (
            SIMD4(tangent.x,   tangent.y,   tangent.z,   0),
            SIMD4(bitangent.x, bitangent.y, bitangent.z, 0),
            SIMD4(normal.x,    normal.y,    normal.z,     0),
            SIMD4(center.x,    center.y,    center.z,     1)
        ))
    }

    /// M14b: the inflated **surface placement** of a point at tile-local offset `(localX, localY)`
    /// from a tile center — position on the curved surface + the local surface frame (tangent /
    /// bitangent / outward normal as the matrix columns). Used to seat *rigid* objects (imported
    /// assets like the horse/house) on the curve, tilted to the local normal, rather than bending
    /// them per-vertex. `roundness == 0` returns the flat placement (offset applied in the tile
    /// plane) — identical to the old `worldMatrix · translation` seating.
    func inflatedPlacement(face: CubeFace, row: Int, col: Int, localX: Float, localY: Float) -> float4x4 {
        return inflatedPlacement(base: restMatrix(face: face, row: row, col: col), localX: localX, localY: localY)
    }

    /// PERF overload — same computation with the tile's rest matrix precomputed, so callers placing
    /// many points on ONE tile (SceneBuilder's per-tile pass, the Renderer's per-prop pass) build the
    /// rest matrix once per tile instead of once per point.
    func inflatedPlacement(base: float4x4, localX: Float, localY: Float) -> float4x4 {
        // Offset the origin within the tile plane, in the base frame (avoids the render-side
        // `float4x4.translation` extension so this stays compilable in the test target).
        let baseRight = SIMD3<Float>(base.columns.0.x, base.columns.0.y, base.columns.0.z)
        let baseUp    = SIMD3<Float>(base.columns.1.x, base.columns.1.y, base.columns.1.z)
        let basePos   = SIMD3<Float>(base.columns.3.x, base.columns.3.y, base.columns.3.z)
        guard roundness > 0 else {
            var m = base
            let p = basePos + baseRight * localX + baseUp * localY
            m.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
            return m
        }
        let halfN = Float(size) / 2.0
        let spacing = worldScale.cellSpacing
        let footRest = basePos + baseRight * localX + baseUp * localY
        let unit = footRest / halfN
        let worldC = inflatedUnitPoint(unit) * halfN

        let tHat = normalize(baseRight)
        let bHat = normalize(baseUp)
        let eps = 0.5 * spacing / halfN
        let dT = inflatedUnitPoint(unit + tHat * eps) * halfN - worldC
        let dB = inflatedUnitPoint(unit + bHat * eps) * halfN - worldC
        var forward = normalize(cross(dT, dB))
        if dot(forward, normalize(worldC)) < 0 { forward = -forward }
        let right = normalize(dT - forward * dot(dT, forward))
        let up = cross(forward, right)
        return float4x4(columns: (
            SIMD4(right.x,   right.y,   right.z,   0),
            SIMD4(up.x,      up.y,      up.z,      0),
            SIMD4(forward.x, forward.y, forward.z, 0),
            SIMD4(worldC.x,  worldC.y,  worldC.z,  1)
        ))
    }

    // (R2.1: the M14-era per-tile-inflating `worldMatrix` — with its 9% seam-overlap hack — is
    // gone. Per-vertex inflation happens in the shader from `restMatrix`; anything that needs a
    // rigid seat ON the curved surface uses `inflatedPlacement`.)

    // MARK: - Slice Rotation

    func cubieIndicesInSlice(axis: Int, index: Int) -> [Int] {
        cubies.indices.filter { i in
            let pos = cubies[i].position
            switch axis {
            case 0: return pos.x == Int32(index)
            case 1: return pos.y == Int32(index)
            case 2: return pos.z == Int32(index)
            default: return false
            }
        }
    }

    // MARK: - Bandaging (M13)

    /// M16.4: portals SEALED behind a lock — inert and dark until, after the bond is undone, a
    /// finalized twist of their slice swings them open (GameState.finalizeSliceRotation removes
    /// them here). Cubie indices, stable across turns like bonds.
    var sealedPortalCubies: Set<Int> = []

    /// M20 (Eddie) — portals shown with a STYLED visual instead of the TARDIS box. `fieldStyle` picks
    /// the energy surface (material 23): 2 = the volumetric-cloud ARCH (level-to-level, home → garden),
    /// 3 = elevator streaks DOWN (garden → temple), 4 = streaks UP (temple → surface). The frame is
    /// derived from the style — a stone arch for 2, two flanking columns for 3/4 — and stamped by the
    /// Renderer (`stampPortalFrames`), which owns the imported indices. The energy field + base ring
    /// render only while the portal is ACTIVE (its cubie not in `sealedPortalCubies`); the frame always
    /// shows. `fi`/`facing` locate/orient it.
    struct StyledPortal { let ci: Int; let fi: Int; let facing: Heading8; let fieldStyle: Int }
    var styledPortals: [StyledPortal] = []

    // MARK: - PERF: topology version + derived caches

    /// Monotone counter bumped whenever topology-derived render inputs change: a finalized slice twist
    /// (openings/uvTurns/props rotate), a tile completing discovery, or a prop added/removed at runtime.
    /// The caches below key on it, so the per-frame 6×n² scans collapse to cache hits between changes —
    /// while a bump forces full re-derivation, preserving the twist-safety invariant (walls/props always
    /// re-derive from live topology after a change).
    private(set) var topologyVersion: UInt64 = 1
    func markTopologyChanged() { topologyVersion &+= 1 }

    struct PropTileEntry { let face: CubeFace; let row: Int; let col: Int; let ci: Int; let fi: Int }
    private var propTilesCache: (version: UInt64, entries: [PropTileEntry]) = (0, [])

    /// Facelets that carry props, as grid locations (the Renderer's asset pass iterates this instead of
    /// scanning all 6×n² tiles per frame). Only LOCATIONS are cached — prop fields are read live by the
    /// consumer; a twist relocates props ⇒ version bump ⇒ rescan.

    private var bondBandCache: (version: UInt64, bands: [[PropTileEntry]]) = (0, [])

    /// The BONDS, drawn as bands of light across the world's surface.
    ///
    /// Scene 4 asks the player to READ a lock before they can release it, and a bond is otherwise
    /// invisible — the turn simply refuses and the reason is nowhere. Each band traces a path over the
    /// surface between the cubies a bond ties together, crossing face edges as it goes, so the player
    /// can see *what is holding what*.
    ///
    /// The script's requirement — "all bond indicators must be derived from the bonded cubies' current
    /// facelets and orientations… no indicator may depend on fixed world coordinates" — is met by
    /// recomputing from live topology and keying the cache on `topologyVersion`. A twist relocates the
    /// bonded cubies and the band is simply rebuilt along the new route; dissolving a bond removes its
    /// band because the band never existed independently of it.
    ///
    /// Paths ignore maze walls: this is dressing set INTO the world, which the script describes as
    /// passing "beneath maze walls and reappearing elsewhere", not a route to walk.
    func bondBands() -> [[PropTileEntry]] {
        if bondBandCache.version != topologyVersion {
            // One representative tile per cubie (a corner cubie has three facelets; any will do, and
            // taking the first keeps it deterministic).
            var tileOf: [Int: PropTileEntry] = [:]
            for face in CubeFace.allCases {
                for r in 0..<size {
                    for c in 0..<size {
                        guard let (ci, fi) = faceletAt(face: face, row: r, col: c), tileOf[ci] == nil else { continue }
                        tileOf[ci] = PropTileEntry(face: face, row: r, col: c, ci: ci, fi: fi)
                    }
                }
            }

            var bands: [[PropTileEntry]] = []
            for group in bondedGroups {
                let members = group.compactMap { tileOf[$0] }
                guard members.count >= 2 else { continue }
                // Chain the members in order, so a bond of three or more reads as one continuous run
                // rather than a star.
                var band: [PropTileEntry] = []
                for i in 0..<(members.count - 1) {
                    let leg = surfacePath(from: members[i], to: members[i + 1], tileOf: tileOf)
                    band.append(contentsOf: i == 0 ? leg : Array(leg.dropFirst()))
                }
                if !band.isEmpty { bands.append(band) }
            }
            bondBandCache = (topologyVersion, bands)
        }
        return bondBandCache.bands
    }

    /// Shortest tile path over the cube's SURFACE, walking face to face through `edgeCrossing` — the
    /// same adjacency movement uses, so a band bends around an edge exactly where a walker would.
    private func surfacePath(from a: PropTileEntry, to b: PropTileEntry,
                             tileOf: [Int: PropTileEntry]) -> [PropTileEntry] {
        struct Key: Hashable { let f: Int; let r: Int; let c: Int }
        func key(_ t: PropTileEntry) -> Key { Key(f: t.face.rawValue, r: t.row, c: t.col) }
        let goal = key(b)
        var came: [Key: PropTileEntry] = [:]
        var seen: Set<Key> = [key(a)]
        var queue: [PropTileEntry] = [a]
        var head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            if key(cur) == goal {
                var path = [cur], node = cur
                while let prev = came[key(node)] { path.append(prev); node = prev }
                return path.reversed()
            }
            for dir in [SurfaceDirection.north, .east, .south, .west] {
                let nr = cur.row + (dir == .north ? -1 : dir == .south ? 1 : 0)
                let nc = cur.col + (dir == .west ? -1 : dir == .east ? 1 : 0)
                let next: (face: CubeFace, row: Int, col: Int)
                if (0..<size).contains(nr) && (0..<size).contains(nc) {
                    next = (cur.face, nr, nc)
                } else {
                    let x = edgeCrossing(face: cur.face, direction: dir, row: cur.row, col: cur.col)
                    next = (x.face, x.row, x.col)
                }
                guard let (ci, fi) = faceletAt(face: next.face, row: next.row, col: next.col) else { continue }
                let entry = PropTileEntry(face: next.face, row: next.row, col: next.col, ci: ci, fi: fi)
                guard seen.insert(key(entry)).inserted else { continue }
                came[key(entry)] = cur
                queue.append(entry)
            }
        }
        return [a]
    }

    func propTiles() -> [PropTileEntry] {
        if propTilesCache.version != topologyVersion {
            var entries: [PropTileEntry] = []
            for face in CubeFace.allCases {
                for row in 0..<size {
                    for col in 0..<size {
                        guard let (ci, fi) = faceletAt(face: face, row: row, col: col) else { continue }
                        if !cubies[ci].facelets[fi].props.isEmpty {
                            entries.append(PropTileEntry(face: face, row: row, col: col, ci: ci, fi: fi))
                        }
                    }
                }
            }
            propTilesCache = (topologyVersion, entries)
        }
        return propTilesCache.entries
    }

    private var dressedClearCache: (version: UInt64, tiles: Set<Int>) = (0, [])
    private var dressedWallCache: (version: UInt64, entries: [(loc: PropTileEntry, props: [Prop])]) = (0, [])

    /// Dressed-wall props for every discovered tile — the same derivation as calling `dressedWallProps`
    /// per tile per frame (twist-safe: any topology change re-derives everything), just cached between
    /// changes. The palette/scales are fixed per world (the Renderer's `wallDressingPalette`), so the
    /// cache keys on `topologyVersion` alone.
    func dressedWallEntries(walls: [Int], rocks: [Int], bushes: [Int],
                            wallScale: Float, rockScale: Float, bushScale: Float) -> [(loc: PropTileEntry, props: [Prop])] {
        if dressedWallCache.version != topologyVersion {
            if dressedClearCache.version != topologyVersion {
                dressedClearCache = (topologyVersion, dressedClearTiles())
            }
            let clear = dressedClearCache.tiles
            var entries: [(loc: PropTileEntry, props: [Prop])] = []
            for face in CubeFace.allCases {
                for row in 0..<size {
                    for col in 0..<size {
                        guard let (ci, fi) = faceletAt(face: face, row: row, col: col) else { continue }
                        let facelet = cubies[ci].facelets[fi]
                        // ADJACENT counts, not just discovered. SceneBuilder emits hedge geometry for
                        // an adjacent tile, and a dressed world suppresses that mesh in favour of these
                        // models — so requiring `.discovered` here meant a fogged dressed world had no
                        // walls on the tile in front of you at all. You saw the props on it (the asset
                        // path never checked discovery) and walked into walls that appeared on arrival.
                        guard facelet.tileState != .unknown else { continue }
                        let props = dressedWallProps(facelet, face: face, row: row, col: col,
                                                     walls: walls, rocks: rocks, bushes: bushes,
                                                     wallScale: wallScale, rockScale: rockScale, bushScale: bushScale,
                                                     skipOvergrowth: cleanWalls || clear.contains(facelet.id.rawValue))
                        if !props.isEmpty {
                            entries.append((PropTileEntry(face: face, row: row, col: col, ci: ci, fi: fi), props))
                        }
                    }
                }
            }
            dressedWallCache = (topologyVersion, entries)
        }
        return dressedWallCache.entries
    }

    /// Facelets carrying animatable puzzle props (switch caps / the alignment cylinder) — replaces
    /// GameState.tickAlignmentCylinder's every-frame full cubie×facelet×prop sweep.
    private var animPropCache: (version: UInt64, entries: [(ci: Int, fi: Int)]) = (0, [])
    func animatablePropTiles() -> [(ci: Int, fi: Int)] {
        if animPropCache.version != topologyVersion {
            var entries: [(ci: Int, fi: Int)] = []
            for ci in cubies.indices {
                for fi in cubies[ci].facelets.indices {
                    if cubies[ci].facelets[fi].props.contains(where: { $0.kind == .switchCap || $0.kind == .alignmentCylinder }) {
                        entries.append((ci, fi))
                    }
                }
            }
            animPropCache = (topologyVersion, entries)
        }
        return animPropCache.entries
    }

    /// Bonded cubie groups: each set of cubie indices must move together, so a slice twist that
    /// would cut through a group — some of its cubies in the rotating slice, some out — is illegal
    /// and refused. Indices are into `cubies` and stay valid across turns (`applySliceRotation`
    /// moves cubies but never reindexes the array). A cubie should belong to at most one group.
    var bondedGroups: [Set<Int>] = []

    /// Scene 2 — the slab the solved lock turns, named by the world rather than derived from where
    /// the player happens to face. `startBackSliceRotation` picks a slice relative to the player,
    /// which is right when the turn is a flourish near them; Scene 2 instead has to turn one specific
    /// distant slab — the one carrying the hidden exit — no matter where the player is standing.
    var scriptedTwistSlice: (axis: Int, index: Int, clockwise: Bool)? = nil

    /// Where the player arrives in this world, when the world authors it. Otherwise arrival falls back
    /// to `firstPortalLocation()` — "emerge from the destination's own doorway" — which is only right
    /// when a world's first portal is its entrance. It isn't for Scene 2: the enum order searches `+Y`
    /// before `+Z`, so the hidden exit was found first and dropped the player onto the far face,
    /// sealed inside three tiles. Every prologue scene specifies its opening image, so scenes state
    /// their arrival point instead of having it inferred.
    var spawnLocation: (face: CubeFace, row: Int, col: Int, facing: Heading8)? = nil

    /// Scene 2 — the plinth that reports lock progress, when it is NOT adjacent to the door it
    /// reports on. The garden's plinth sits beside its door, so `updateDoorPlinths` can find it by
    /// looking around the door; Scene 2's central plinth is deliberately far from the exit ("a map of
    /// conditions, not a map of the maze"), so the world states which plinth to drive.
    /// Cubie indices are stable across twists, like bonds and sealed portals.
    var progressPlinth: (ci: Int, fi: Int)? = nil
    /// M16.6 (Eddie) — the temple-door bond, stored so the lock can be RE-applied when the player
    /// disengages a switch after unlocking (goof-and-fix), and cleared when all switches re-engage.
    var templeDoorBond: Set<Int> = []

    /// Bond a set of cubie indices so they move as one rigid block (M13). Ignores trivial groups.
    func addBond(_ cubieIndices: Set<Int>) {
        guard cubieIndices.count > 1 else { return }
        bondedGroups.append(cubieIndices)
    }

    /// Dissolve the bond containing `cubieIndex` (M16: understanding undoes a lock — the bonded
    /// structure becomes twistable again). Cubie indices stay valid across turns, so the caller
    /// can hold one member (e.g. the structure's anchor cubie) from bond time. Returns whether
    /// a bond was actually removed.
    @discardableResult
    func removeBond(containing cubieIndex: Int) -> Bool {
        guard let i = bondedGroups.firstIndex(where: { $0.contains(cubieIndex) }) else { return false }
        bondedGroups.remove(at: i)
        return true
    }

    /// Whether a slice twist is legal under the current bonds (the bandaged-cube rule): every bonded
    /// group must be **entirely inside** the rotating slice or **entirely outside** it. A group that
    /// straddles the slice would be torn, so the twist is refused. No bonds ⇒ always legal.
    /// How many bonded groups straddle this slice — i.e. how many separate things are refusing the
    /// turn. Scene 4 uses it to make a weakening lock legible: each anchor released lets the world
    /// give further before it springs back.
    func bondsBlocking(axis: Int, index: Int) -> Int {
        guard !bondedGroups.isEmpty else { return 0 }
        let slice = Set(cubieIndicesInSlice(axis: axis, index: index))
        return bondedGroups.filter { !$0.isDisjoint(with: slice) && !$0.isSubset(of: slice) }.count
    }

    func canRotateSlice(axis: Int, index: Int) -> Bool {
        guard !bondedGroups.isEmpty else { return true }
        let slice = Set(cubieIndicesInSlice(axis: axis, index: index))
        for group in bondedGroups where !group.isDisjoint(with: slice) && !group.isSubset(of: slice) {
            return false
        }
        return true
    }

    func applySliceRotation(axis: Int, index: Int, angle: Float) {
        let axisVec: SIMD3<Float> = axis == 0 ? SIMD3(1,0,0) : axis == 1 ? SIMD3(0,1,0) : SIMD3(0,0,1)
        let rotQ = simd_quatf(angle: angle, axis: axisVec)
        let center = Float(size - 1) / 2.0

        for i in cubieIndicesInSlice(axis: axis, index: index) {
            // Rotate maze openings to match the new orientation
            for fi in cubies[i].facelets.indices {
                let oldWorldNormal = cubies[i].orientation.act(cubies[i].facelets[fi].localFace.normal)
                let oldWorldFace = closestFace(to: oldWorldNormal)
                let oldTangent = oldWorldFace.tangent

                let newWorldNormal = rotQ.act(oldWorldNormal)
                let newWorldFace = closestFace(to: newWorldNormal)
                let newTangent = newWorldFace.tangent
                let newBitangent = newWorldFace.bitangent

                let rotatedOldTangent = rotQ.act(oldTangent)
                let dotT = dot(rotatedOldTangent, newTangent)
                let dotB = dot(rotatedOldTangent, newBitangent)
                let quarterTurns: Int
                if abs(dotT) > abs(dotB) {
                    quarterTurns = dotT > 0 ? 0 : 2
                } else {
                    quarterTurns = dotB > 0 ? 1 : 3
                }
                if quarterTurns != 0 {
                    cubies[i].facelets[fi].mazeTile.openings = cubies[i].facelets[fi].mazeTile.openings.rotated(quarterTurns: quarterTurns)
                    cubies[i].facelets[fi].mazeTile.openEdges = cubies[i].facelets[fi].mazeTile.openEdges.rotated(quarterTurns: quarterTurns)
                    // Keep the floor texture glued to the tile through finalization.
                    cubies[i].facelets[fi].mazeTile.uvTurns = (cubies[i].facelets[fi].mazeTile.uvTurns + quarterTurns) % 4
                    // Carry any props around with the tile.
                    for pi in cubies[i].facelets[fi].props.indices {
                        cubies[i].facelets[fi].props[pi].rotate(quarterTurns: quarterTurns)
                    }
                }
            }

            cubies[i].orientation = (rotQ * cubies[i].orientation).normalized

            let pos = SIMD3<Float>(Float(cubies[i].position.x), Float(cubies[i].position.y), Float(cubies[i].position.z))
            let centered = pos - SIMD3(center, center, center)
            let rotated = rotQ.act(centered)
            let newPos = rotated + SIMD3(center, center, center)
            cubies[i].position = SIMD3<Int32>(Int32(round(newPos.x)), Int32(round(newPos.y)), Int32(round(newPos.z)))
        }

        rebuildProjection()
        markTopologyChanged()   // PERF: a twist relocated tiles/props — derived caches must re-derive
    }

    func sliceAxisAndIndex(for face: CubeFace) -> (axis: Int, index: Int) {
        switch face {
        case .positiveX: return (0, size - 1)
        case .negativeX: return (0, 0)
        case .positiveY: return (1, size - 1)
        case .negativeY: return (1, 0)
        case .positiveZ: return (2, size - 1)
        case .negativeZ: return (2, 0)
        }
    }

    // MARK: - Edge Crossing

    func edgeCrossing(face: CubeFace, direction: SurfaceDirection, row: Int, col: Int) -> (face: CubeFace, row: Int, col: Int, facing: SurfaceDirection) {
        guard worldScale.interior else {
            return EdgeCrossing.cross(face: face, direction: direction, row: row, col: col, cubeSize: size)
        }
        // M15.1 — interior adjacency by conjugation: an interior cell (r,c) occupies the same
        // world spot as the exterior cell (n−1−r, c) on the same face (the row axis is mirrored
        // in restMatrix), and grid N/S are world-swapped while E/W are unchanged. So: mirror into
        // exterior coordinates, cross with the proven exterior table, mirror back. The headless
        // edge-continuity test pins this to world positions.
        func flip(_ d: SurfaceDirection) -> SurfaceDirection {
            d == .north ? .south : (d == .south ? .north : d)
        }
        let ext = EdgeCrossing.cross(face: face, direction: flip(direction),
                                     row: size - 1 - row, col: col, cubeSize: size)
        return (ext.face, size - 1 - ext.row, ext.col, flip(ext.facing))
    }

    private func addEdgeBridges() {
        var rng = FaceSeededRNG(seed: 99)
        let n = size

        func mask(for dir: SurfaceDirection) -> DirectionMask {
            switch dir {
            case .north: return .north
            case .east:  return .east
            case .south: return .south
            case .west:  return .west
            }
        }

        let edges: [(CubeFace, SurfaceDirection)] = [
            (.positiveZ, .north), (.positiveZ, .south), (.positiveZ, .east), (.positiveZ, .west),
            (.negativeZ, .north), (.negativeZ, .south), (.negativeZ, .east), (.negativeZ, .west),
            (.positiveY, .east),  (.positiveY, .west),
            (.negativeY, .east),  (.negativeY, .west),
        ]

        // Scale the number of face-to-face bridges with edge length so larger cubes
        // stay comparably connected. max(1, n/3) keeps n<=5 at the historical single
        // bridge per edge (and the identical RNG sequence) while a 7- or 9-face gets
        // 2-3. Duplicate positions just collapse via the idempotent openings.insert.
        let bridgesPerEdge = max(1, n / 3)
        for (face, dir) in edges {
            for _ in 0..<bridgesPerEdge {
                let pos = Int(rng.next() % UInt64(n))
                let departRow: Int, departCol: Int
                switch dir {
                case .north: departRow = 0;     departCol = pos
                case .south: departRow = n - 1; departCol = pos
                case .east:  departRow = pos;   departCol = n - 1
                case .west:  departRow = pos;   departCol = 0
                }

                let crossing = edgeCrossing(face: face, direction: dir, row: departRow, col: departCol)
                let arrivalDir = crossing.facing.opposite

                if let (ci, fi) = faceletAt(face: face, row: departRow, col: departCol) {
                    cubies[ci].facelets[fi].mazeTile.openings.insert(mask(for: dir))
                }
                if let (ci, fi) = faceletAt(face: crossing.face, row: crossing.row, col: crossing.col) {
                    cubies[ci].facelets[fi].mazeTile.openings.insert(mask(for: arrivalDir))
                }
            }
        }
    }

    // MARK: - Helpers

    private func effectiveFace(cubie: Cubie, localFace: CubeFace) -> CubeFace {
        let rotatedNormal = cubie.orientation.act(localFace.normal)
        return closestFace(to: rotatedNormal)
    }

    private func closestFace(to direction: SIMD3<Float>) -> CubeFace {
        var bestFace = CubeFace.positiveX
        var bestDot: Float = -2
        for face in CubeFace.allCases {
            let d = dot(direction, face.normal)
            if d > bestDot {
                bestDot = d
                bestFace = face
            }
        }
        return bestFace
    }

    private func gridPosition(cubie: Cubie, face: CubeFace) -> (row: Int, col: Int) {
        let pos = cubie.position
        let n = Int32(size - 1)
        switch face {
        case .positiveX: return (row: Int(pos.y), col: Int(n - pos.z))
        case .negativeX: return (row: Int(pos.y), col: Int(pos.z))
        case .positiveY: return (row: Int(n - pos.z), col: Int(pos.x))
        case .negativeY: return (row: Int(pos.z), col: Int(pos.x))
        case .positiveZ: return (row: Int(pos.y), col: Int(pos.x))
        case .negativeZ: return (row: Int(pos.y), col: Int(n - pos.x))
        }
    }

    // (R2 startup fix: the old findFaceletIndices(face:row:col:) — a full linear scan over every
    // cubie per lookup — is gone; all callers use faceletAt's cached projection + O(1) id map.)

    private func findFaceletIndices(id: FaceletID) -> (cubieIndex: Int, faceletIndex: Int)? {
        return faceletLocation[id]
    }
}

// MARK: - Simple seeded RNG

private struct FaceSeededRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
