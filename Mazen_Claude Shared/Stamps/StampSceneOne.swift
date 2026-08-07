import Foundation
import simd

/// B2 — Scene 1 "The First Clearing", moved verbatim from CubeModel.swift.
extension CubeModel {
    /// The opening. A walled clearing with a break in its north wall, a corridor through stone that
    /// is thicker than it looks, and beyond it a maze whose every dead end holds a vessel.
    ///
    /// Nothing here is a puzzle. The scene's whole job is to establish that the world is ENCLOSED,
    /// that the way on is horizontal rather than upward, and that these objects keep appearing —
    /// "by the fourth, the vessels no longer feel like decoration. They feel placed." So it is
    /// authored as architecture, not as a lock: no bond, no switch, no twist (the verb is withheld
    /// until Scene 4), and the portal at the end is open from the moment it is found.
    func stampSceneOne() {
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
            styledPortals.append(StyledPortal(ci: ci, fi: fi, facing: .s))
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



    // MARK: - Prologue Scene 5 — "The Broken Meridian"

}
