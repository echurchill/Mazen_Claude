import simd

/// What gets stamped onto a freshly generated world (M15.2). The maze itself is always generated;
/// the stamp is the authored layer on top — rooms, props, portals.
enum WorldStamp {
    case overworldDemo   // the dev overworld: start plaza + props, BOTH doorways, the −Z house court
    case moonDemo        // the moon: the demo plaza but only its one door home (no temple doorway)
    case templeInterior  // the first hand-stamped interior: central hall, pedestal, return portal
    case bare            // nothing authored — the bare generated maze (tests; procedural worlds later)
    case natural         // M18 Phase 1: no walls anywhere — open ground + a few landmarks (the open-field testbed; M19 grows it into the Natureworld)
    case lunar           // M19: the Moon — open grey regolith + boulders (grey in the sky, walkable when visited)
    case gardenMaze      // M20 first cut: a hedge maze on a green planet — grass floors, some trees, roundness (the Journey garden)
    case gallery         // M20 dev tool: a flat grid of every prop/foliage variant, one per cell, for isolated evaluation
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
        }
    }

    /// M20 dev tool — the **gallery**: a flat grass grid with one prop/foliage variant per cell,
    /// laid out in a documented order (see Gallery Layout doc) so assets can be evaluated in near-
    /// isolation. The debug HUD (H) names the item on the player's tile. Sealed + region-revealed
    /// like the entry world. Catalog order = the grid reading order (row-major, near row first).
    static let galleryCatalog: [(PropKind, Int)] = {
        var c: [(PropKind, Int)] = [
            (.topiary, 0), (.obelisk, 0), (.chest, 0), (.dial, 0), (.dial, 1),
            (.glyph, 0), (.tree, 0), (.tree, 1), (.tree, 2), (.treeTrunk, 0),
            (.boulder, 0), (.boulder, 1), (.boulder, 2),
        ]
        c += (0..<8).map { (.foliageCard, $0) }      // 8 LeafSet bushes
        c += (0..<22).map { (.greeneryCard, $0) }    // 22 misc_greenery plants
        return c
    }()

    /// M20 — WenrexaTrees grouped into single trees rendered as **intersecting billboard cards**
    /// (each entry = the sprite slices, in view order, that form one tree). Eddie's groupings so far;
    /// the rest are singletons pending his mapping. (Slice = filename−1: "01"→0 … "27"→26.)
    static let treeGroups: [[Int]] = {
        var g: [[Int]] = [
            [23, 24, 25, 26],   // filenames 24–27: Tall Purple
            [0, 1, 2],          // filenames 1–3: Wide Purple
            [11, 10, 9],        // filenames 12,11,10: Dead
            [7, 8, 17, 5],      // filenames 8,9,18,6: Orange
            [20, 21, 22],       // filenames 21–23: Dark Red
            [6, 16],            // filenames 7,17: Tall Green
            [12, 13],           // filenames 13,14: Dark Green
        ]
        let used = Set(g.flatMap { $0 })
        for i in 0..<27 where !used.contains(i) { g.append([i]) }   // ungrouped (4,5,15,16,19,20) → single-view
        return g
    }()

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
            cubies[ci].facelets[fi].props.append(Prop(kind: item.0, subRow: 1, subCol: 1, facing: .s, state: item.1))
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
        let portalTile = (min(rHi, c + 1), c)

        // A clearing at spawn (room to get bearings) — done BEFORE sealing so it can't reopen the wall.
        stampRoom(face: .positiveZ, top: max(rLo, c - 1), left: max(cLo, c - 1), height: 3, width: 3)

        func hash(_ a: Int, _ b: Int, _ d: Int) -> UInt32 {
            var v = UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663 ^ d &* 83492791)
            v ^= v >> 15; v = v &* 2246822519; v ^= v >> 13
            return v
        }

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
                // Foliage — non-solid dressing (the hedges do the blocking): leafy card bushes and
                // the odd conifer, off the paths. Skip spawn + portal tiles.
                if (r, col) == (c, c) || (r, col) == portalTile { continue }
                let h = hash(r * 37, col, r &+ col)
                let roll = h % 100
                if roll < 30 {
                    cubies[ci].facelets[fi].props.append(Prop(kind: .foliageCard, subRow: 0, subCol: 0, state: Int((h >> 8) % 3)))
                } else if roll < 44 {
                    cubies[ci].facelets[fi].props.append(Prop(kind: .tree, subRow: 2, subCol: 2, state: Int((h >> 8) % 3)))
                }
            }
        }
        // The way home — a walk-through return portal beside the spawn.
        if let (ci, fi) = faceletAt(face: .positiveZ, row: portalTile.0, col: portalTile.1) {
            cubies[ci].facelets[fi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))
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
                    let ar = Int((h >> 4) % 3), ac = Int((h >> 6) % 3)
                    cubies[ci].facelets[fi].props.append(Prop(kind: .boulder, subRow: ar, subCol: ac, state: Int((h >> 8) % 3)))
                    // Near a corner, drop a second rock at another cell — a denser rubble thicket.
                    if boost > 0.4 {
                        let h2 = hash(faceIdx &* 733 + row, col &* 11, row &+ col &+ 5)
                        cubies[ci].facelets[fi].props.append(Prop(kind: .boulder, subRow: Int(h2 % 3), subCol: Int((h2 / 3) % 3), state: Int((h2 >> 8) % 3)))
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
    private func stampNatural() {
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
                            cubies[ci].facelets[fi].props.append(Prop(kind: .tree, subRow: ar, subCol: ac, state: st))
                            if i == 0 {   // one solid trunk (keeps collision light while trees spread)
                                cubies[ci].facelets[fi].props.append(Prop(kind: .treeTrunk, subRow: ar, subCol: ac, state: st))
                            }
                        }
                    } else {
                        let r2 = (h >> 12) % 100
                        if r2 < 20 {   // leafy bush — M20 alpha-cutout foliage card; state = LeafSet slice
                            cubies[ci].facelets[fi].props.append(Prop(kind: .foliageCard, subRow: 1, subCol: 1, state: Int((h >> 10) % 8)))
                        } else if r2 < 28 {
                            cubies[ci].facelets[fi].props.append(Prop(kind: .boulder, subRow: 1, subCol: 1, state: Int((h >> 8) % 3)))
                        }
                    }
                }
            }
        }

        // The way home — a walk-through return portal one tile south of arrival.
        if let (ci, fi) = faceletAt(face: .positiveZ, row: portalTile.0, col: portalTile.1) {
            cubies[ci].facelets[fi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))
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
        if templeDoor, let (dci, dfi) = faceletAt(face: .positiveZ, row: templeRow, col: doorCol) {
            cubies[dci].facelets[dfi].props.append(Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n, state: 1))
            cubies[dci].facelets[dfi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))
            sealedPortalCubies.insert(dci)   // M16.4: closed until unlocked AND twisted open
            // M16.5: the lock speaks — a carved tesseract-shadow plaque on the door tile (bonded,
            // so the lock livery gilds it and refusals flare it), oriented to face the open
            // approach — never a wall (Eddie).
            let doorOpenings = cubies[dci].facelets[dfi].mazeTile.openings
            cubies[dci].facelets[dfi].props.append(glyphPlaque(onTile: doorOpenings, preferred: .north))
            var bond: Set<Int> = [dci]
            for pc in [doorCol - 1, doorCol + 1] where (0..<size).contains(pc) {
                if let (pci, pfi) = faceletAt(face: .positiveZ, row: templeRow, col: pc) {
                    cubies[pci].facelets[pfi].props.append(Prop(kind: .obelisk, subRow: 1, subCol: 1))
                    bond.insert(pci)
                }
            }
            // The root: the cube is HOLLOW (only surface cubies exist — buildCubies skips
            // interiors), so the lock anchors straight through the world's core to the cubie on
            // the OPPOSITE face (z = 0). Any twist of the start face's slice would tear door from
            // root — refused until the lock is undone.
            if let root = cubies.firstIndex(where: {
                $0.position == SIMD3<Int32>(Int32(doorCol), Int32(templeRow), 0)
            }) {
                bond.insert(root)
            }
            addBond(bond)

            // M16.3: the lock's mechanism — four stone dials spread to the garden's diagonal
            // quarters. Three are aligned (gold, pointer north); the SE one — nearest the temple —
            // is off (grey, pointer east). Align it (F, GameState.interact) and the temple
            // unbonds: understanding is the key. Deliberately "find the pattern and act once";
            // the composable glyph grammar is M17's.
            let cc = size / 2
            let spread = min(3, size / 2)
            let dialSpots: [(Int, Int, Heading8, Int)] = [
                (cc - spread, cc - spread, .n, 1),
                (cc - spread, cc + spread, .n, 1),
                (cc + spread, cc - spread, .n, 1),
                (cc + spread, cc + spread, .e, 0),
            ]
            for (r, c2, f, st) in dialSpots {
                if let (ci2, fi2) = faceletAt(face: .positiveZ, row: r, col: c2) {
                    cubies[ci2].facelets[fi2].props.append(Prop(kind: .dial, subRow: 1, subCol: 1, facing: f, state: st))
                    // M16.5: the same mark beside every dial — the association between the four
                    // dials and the locked temple, said in the Builders' language, not in words.
                    // Oriented to an open direction (preferring toward the plaza), never a wall.
                    let dialOpenings = cubies[ci2].facelets[fi2].mazeTile.openings
                    let towardPlaza: SurfaceDirection = r < cc ? .south : .north
                    cubies[ci2].facelets[fi2].props.append(glyphPlaque(onTile: dialOpenings, preferred: towardPlaza))
                }
            }
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
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalLamp, subRow: 1, subCol: 1))
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
        let base = restMatrix(face: face, row: row, col: col)
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

    /// Bonded cubie groups: each set of cubie indices must move together, so a slice twist that
    /// would cut through a group — some of its cubies in the rotating slice, some out — is illegal
    /// and refused. Indices are into `cubies` and stay valid across turns (`applySliceRotation`
    /// moves cubies but never reindexes the array). A cubie should belong to at most one group.
    var bondedGroups: [Set<Int>] = []

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
