import Foundation
import simd

// DOORS, ROUTES, AND THE REGISTRY — which door leads where, what a world is called, what hangs in
// its sky, and the identity rules that make Scene 6 *the* Scene 2 rather than a convincing copy.
// Route-keyed behaviour lives here: same place, different edge, different world.
//
// Part of `CoordinateMathTests` (split out 2026-08-05 — one 4,158-line file was hard to navigate
// and worse to review). Everything here is an extension on the same type, so the shared helpers and
// `check()` are available exactly as before, and `main()` in CoordinateMathTests.swift still names
// every test it runs. ADDING A FILE HERE MEANS ADDING IT TO `Tests/run-tests.sh` in the same
// commit — the runner lists its sources explicitly and will not find a new one on its own.

extension CoordinateMathTests {
    /// Phase 0 — the portals that used to depend on the Renderer's hardcoded name-matching must now
    /// carry their own `.push`. If either of these regresses to `.auto`, the hub's doors and the
    /// garden's temple descent would POP instead of nesting (you'd fall out of the world you're in
    /// rather than descend into the next), which is exactly the bug the name-matching existed to
    /// prevent. Cheap to assert, and it can't be caught by a headless boot.
    static func testPortalTransitionsAreExplicit() {
        // The hub's nine doors: entering a destination must PUSH so its return portal comes back here.
        let hub = GameState(size: 15, name: "portal-hub", stamp: .portalHub).cubeModel
        var hubPortals = 0
        for r in 0..<15 { for c in 0..<15 {
            guard let (ci, fi) = hub.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
            for p in hub.cubies[ci].facelets[fi].props where p.kind == .portal {
                hubPortals += 1
                check(p.transition == .push, "hub portal at (\(r),\(c)) must be .push, got \(p.transition)")
            }
        } }
        // One per entry in CubeModel's hubDestinations: the 9 legacy worlds plus every prologue
        // scene, with the hub itself skipped. The count is derived rather than written down, so
        // adding a scene does not fail a test for the sole reason that a scene was added — what
        // matters is that every door is a door, laid out where they can be walked to, which the
        // signpost and `.push` checks above cover. (It was a literal 14; Scene 6 made it 15.)
        check(hubPortals >= 14, "the hub lost doors: found only \(hubPortals)")
        // The grid is 3 rows × 6 columns since the Cyberpunk gallery made it sixteen. The ceiling
        // matters: a slot past the end would silently drop a door rather than fail to build.
        check(hubPortals <= 18, "the hub grid holds 18 doors (3 rows × 6); found \(hubPortals)")
        // Every door in the hub must be somewhere the plaza actually is — an off-grid slot puts a
        // portal outside the walkable region, where it reads as missing.
        check(hubPortals == WorldCatalog.destinations.count - 1,
              "the hub should show every destination but itself: \(hubPortals) doors for "
              + "\(WorldCatalog.destinations.count) destinations")

        // The garden's temple door: a descent from an already-pushed world, so it must PUSH too.
        let garden = GameState(size: 11, name: "garden", stamp: .gardenMaze).cubeModel
        var descents = 0
        for r in 0..<11 { for c in 0..<11 {
            guard let (ci, fi) = garden.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
            for p in garden.cubies[ci].facelets[fi].props where p.kind == .portal && p.state == 1 {
                descents += 1
                check(p.transition == .push, "garden temple descent must be .push, got \(p.transition)")
            }
        } }
        check(descents == 1, "expected 1 temple-descent portal in the garden, found \(descents)")
    }

    /// Releasing an anchor must make the world visibly GIVE more, even while the turn is still
    /// refused — "partial progress may weaken a lock without yet making a turn legal". With a fixed
    /// strain, three anchors felt exactly like one and the middle of the puzzle read as no progress.
    /// Scene 4's script hangs the larger Scene 2 world overhead, and that is the ONLY thing in
    /// sight that stays put when the player's whole face rotates. Authored on the stamp, so the
    /// fact travels with the scene rather than living at the Renderer's build site.
    static func testSceneFourHangsSceneTwoOverhead() {
        // 6A — the sky as an EDGE. Scene 2 is one instance reached two ways, and only the way in
        // from Scene 5 (i.e. as Scene 6) hangs Scene 4 overhead. Every other case must fall through
        // to what the stamp authored, or the first return trip would permanently rewrite the sky of
        // a world the player can still reach by its own front door.
        check(WorldCatalog.skyCounterpart(world: "scene-2", arrivedFrom: "scene-5", authored: nil)
              == "scene-4", "Scene 2 entered from Scene 5 IS Scene 6: the dark world overhead")
        check(WorldCatalog.skyCounterpart(world: "scene-2", arrivedFrom: "scene-1", authored: nil)
              == nil, "Scene 2 by its own route keeps its authored sky — Scene 4 is not spoiled early")
        check(WorldCatalog.skyCounterpart(world: "scene-2", arrivedFrom: nil, authored: nil)
              == nil, "a first visit, with no route at all, is not the Scene 6 case")
        check(WorldCatalog.skyCounterpart(world: "scene-4", arrivedFrom: "scene-5", authored: "scene-2")
              == "scene-2", "another world's authored sky survives the same origin string")
        check(WorldCatalog.skyCounterpart(world: "scene-5", arrivedFrom: "scene-4", authored: "scene-4")
              == "scene-4", "the rule is keyed to Scene 2, not to any world arriving from Scene 5")

        check(WorldStamp.sceneFour.skyCounterpart == "scene-2", "Scene 4 authors Scene 2 as its sky")
        check(GameState(size: PrologueSize.sceneFour, name: "scene-4", stamp: .sceneFour)
                .skyCounterpart == "scene-2", "the built world carries the authored sky")
        // Every other world keeps the default rule (world beneath you, else the moon edge).
        for st in [WorldStamp.sceneTwo, .gardenMaze, .portalHub, .lunar, .homeClearing, .bare] {
            check(st.skyCounterpart == nil, "\(st) leaves its sky to the default rule")
        }
    }

    /// The world overhead must be the SAME INSTANCE as the one behind the door. Scene 4 builds
    /// Scene 2 for its sky before the player has necessarily been there, so a second Scene 2
    /// created later by the hub door would diverge on the first twist — you'd walk into a world
    /// that wasn't the one you'd been looking at.
    static func testSkyCounterpartIsTheSameWorldYouCanVisit() {
        let reg = WorldRegistry()
        let sceneTwo = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo)
        reg.bind(WorldKey(destination: "scene-2", origin: "scene-4"), to: sceneTwo)   // the sky edge
        check(reg.anyNamed("scene-2") === sceneTwo, "the sky-bound world is findable by name")
        check(reg.anyNamed("scene-9") == nil, "a world never built is not conjured")
        // The hub door then resolves to that same instance (the Renderer's prologue single-instance
        // rule), so a twist made in the sky copy is present in the one you walk into.
        let hubEdge = WorldKey(destination: "scene-2", origin: "portal-hub")
        let walked = reg.world(for: hubEdge) { reg.anyNamed("scene-2") ?? sceneTwo }
        check(walked === sceneTwo, "walking in from the hub reaches the world that was overhead")
        check(reg.allWorlds.count == 1, "two edges, one Scene 2 — not a divergent copy")
    }

    /// Every prologue door in the hub must be a DARSIT, not a TARDIS (Eddie). The livery is keyed to
    /// a set of destination ids, and it is easy to add a scene and forget to add its id — at which
    /// point its door silently comes up blue and looks like a dev world.
    static func testEveryPrologueSceneHasADarsitDoor() {
        // The prologue worlds that exist so far, by destination index.
        let prologue = [10, 11]
        let hub = GameState(size: 15, name: "portal-hub", stamp: .portalHub).cubeModel
        var found = Set<Int>()
        for r in 0..<15 { for c in 0..<15 {
            guard let (ci, fi) = hub.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
            for p in hub.cubies[ci].facelets[fi].props where p.kind == .portal {
                if prologue.contains(p.state) { found.insert(p.state) }
            }
        } }
        check(found == Set(prologue),
              "every prologue scene needs a hub door: expected \(prologue), found \(found.sorted())")
    }

    /// A sealed world has to STAY sealed. The stamps closed their region border one-sidedly, which
    /// was enough while movement was tested on the departing tile — you could not step out. Then
    /// `reconcileSharedEdges` arrived to fix the invisible walls, resolving disagreements in favour
    /// of OPEN, and silently undid every one of those seals: Eddie walked off Scene 2's face and
    /// across to a portal that was not meant to be reachable.
    ///
    /// This walks the whole cube from the spawn and asserts the player cannot leave the play face —
    /// the property that actually matters, rather than the state of any particular edge.
    static func testSealedWorldsCannotBeWalkedOutOf() {
        for (label, gs) in [("scene-1", GameState(size: PrologueSize.sceneOne, name: "s1", stamp: .sceneOne)),
                            ("scene-2", GameState(size: PrologueSize.sceneTwo, name: "s2", stamp: .sceneTwo)),
                            ("garden",  GameState(size: 11, name: "g", stamp: .gardenMaze)),
                            ("hub",     GameState(size: 15, name: "h", stamp: .portalHub))] {
            let m = gs.cubeModel
            let n = m.size
            struct T: Hashable { let f: Int; let r: Int; let c: Int }
            let start = T(f: gs.player.face.rawValue, r: gs.player.row, c: gs.player.col)
            var seen: Set<T> = [start], q = [start], head = 0
            while head < q.count {
                let t = q[head]; head += 1
                guard let face = CubeFace(rawValue: t.f),
                      let (ci, fi) = m.faceletAt(face: face, row: t.r, col: t.c) else { continue }
                let op = m.cubies[ci].facelets[fi].mazeTile.openings
                for (dir, mask, dr, dc) in [(SurfaceDirection.north, DirectionMask.north, -1, 0),
                                            (.south, .south, 1, 0), (.west, .west, 0, -1), (.east, .east, 0, 1)] {
                    guard op.contains(mask) else { continue }
                    let nr = t.r + dr, nc = t.c + dc
                    let nt: T
                    if nr >= 0, nr < n, nc >= 0, nc < n { nt = T(f: t.f, r: nr, c: nc) }
                    else {
                        let cr = m.edgeCrossing(face: face, direction: dir, row: t.r, col: t.c)
                        nt = T(f: cr.face.rawValue, r: cr.row, c: cr.col)
                    }
                    if !seen.contains(nt) { seen.insert(nt); q.append(nt) }
                }
            }
            // Guard against a vacuous pass: if the walk explored almost nothing, "did not escape"
            // means nothing either.
            check(seen.count > 20, "\(label): the walk only reached \(seen.count) tiles")
            let escaped = seen.filter { $0.f != start.f }
            check(escaped.isEmpty,
                  "\(label): the player can walk off the play face onto \(Set(escaped.map { $0.f }).sorted())")
        }
    }

    /// …and it has to stay sealed AFTER a twist, which is the case that actually bit. Sealing the
    /// play face was enough while the world stood still; turning a slab swings tiles from other
    /// faces into reach, and those had never been sealed, so the payoff of Scene 2 also handed the
    /// player a way to walk off the world (Eddie).
    static func testSealSurvivesTheScriptedTurn() {
        let gs = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo)
        let m = gs.cubeModel
        let n = m.size
        guard let slice = m.scriptedTwistSlice else { check(false, "Scene 2 names a slab to turn"); return }
        // Dissolve the lock so the turn is legal, then take it.
        while !m.bondedGroups.isEmpty { m.removeBond(containing: m.bondedGroups[0].first!) }
        m.applySliceRotation(axis: slice.axis, index: slice.index, angle: .pi / 2)

        struct T: Hashable { let f: Int; let r: Int; let c: Int }
        let start = T(f: gs.player.face.rawValue, r: gs.player.row, c: gs.player.col)
        var seen: Set<T> = [start], q = [start], head = 0
        while head < q.count {
            let t = q[head]; head += 1
            guard let face = CubeFace(rawValue: t.f),
                  let (ci, fi) = m.faceletAt(face: face, row: t.r, col: t.c) else { continue }
            let tile = m.cubies[ci].facelets[fi].mazeTile
            for (dir, mask, dr, dc) in [(SurfaceDirection.north, DirectionMask.north, -1, 0),
                                        (.south, .south, 1, 0), (.west, .west, 0, -1), (.east, .east, 0, 1)] {
                // Use the real movement rule, so a border left open only in `openEdges` counts.
                guard tile.openings.contains(mask) || tile.openEdges.contains(mask) else { continue }
                let nr = t.r + dr, nc = t.c + dc
                let nt: T
                if nr >= 0, nr < n, nc >= 0, nc < n { nt = T(f: t.f, r: nr, c: nc) }
                else {
                    let cr = m.edgeCrossing(face: face, direction: dir, row: t.r, col: t.c)
                    nt = T(f: cr.face.rawValue, r: cr.row, c: cr.col)
                }
                if !seen.contains(nt) { seen.insert(nt); q.append(nt) }
            }
        }
        check(seen.count > 20, "the walk after the turn only reached \(seen.count) tiles")
        let escaped = Set(seen.filter { $0.f != start.f }.map { $0.f }).sorted()
        check(escaped.isEmpty, "after the turn the player reaches faces \(escaped)")
    }

    /// An interior world must not spin. The spin exists so the sun sweeps across a planet's faces;
    /// an interior has neither sun nor sky, so it buys nothing — and it is not free, because it turns
    /// the world-space normals under everything. Shading that reads them then drifts while the player
    /// stands still, which is how Scene 3's metal walls came to flicker between frames from a fixed
    /// camera.
    static func testInteriorsDoNotSpin() {
        let inside = GameState(size: PrologueSize.sceneThree, name: "s3", interior: true, stamp: .sceneThree)
        let outside = GameState(size: PrologueSize.sceneFour, name: "s4", stamp: .sceneFour)
        for gs in [inside, outside] { gs.spinEnabled = true; gs.time = 37 }
        let still = inside.worldSpinMatrix(), turning = outside.worldSpinMatrix()
        check(still == matrix_identity_float4x4, "an interior world stands still")
        check(turning != matrix_identity_float4x4, "an exterior world still turns under its sun")
    }

    /// The prologue has to be a CHAIN. Each scene was built against whatever existed at the time, so
    /// each one's exit pointed at a stand-in — Scene 2 at the temple interior, Scene 3 back at Scene
    /// 2 — and the sequence quietly dropped the player into dev worlds partway through. Nothing
    /// catches that except walking it or asserting it.
    ///
    /// Indices are into Renderer.portalDestinations, which the headless harness cannot see, so they
    /// are named here: 10 scene-2, 11 scene-4, 13 scene-3.
    static func testThePrologueScenesLeadToEachOther() {
        func exitDestination(of gs: GameState, ignoring skip: Set<Int> = []) -> [Int] {
            var out: [Int] = []
            let m = gs.cubeModel
            for face in CubeFace.allCases {
                for r in 0..<m.size {
                    for c in 0..<m.size {
                        guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                        for p in m.cubies[ci].facelets[fi].props
                        where p.kind == .portal && !skip.contains(p.state) { out.append(p.state) }
                    }
                }
            }
            return out
        }
        let one = GameState(size: PrologueSize.sceneOne, name: "s1", stamp: .sceneOne)
        check(exitDestination(of: one) == [10], "Scene 1's arch leads to Scene 2, got \(exitDestination(of: one))")

        let two = GameState(size: PrologueSize.sceneTwo, name: "s2", stamp: .sceneTwo)
        check(exitDestination(of: two) == [13], "Scene 2's chamber descends into Scene 3, got \(exitDestination(of: two))")

        // Scene 5 closes the loop: its exit leads back to SCENE 2 (destination 10), which is Scene 6
        // — the same world, entered from a new direction. And it `goto`s rather than pushing, since
        // pushing a world already on the stack would put one instance in it twice.
        let five = GameState(size: PrologueSize.sceneFive, name: "s5", stamp: .sceneFive)
        for (axis, index) in [(2, 0), (0, 0), (0, 0)] {
            five.cubeModel.applySliceRotation(axis: axis, index: index, angle: -.pi / 2)
        }
        five.update(deltaTime: 1.0 / 60.0)
        check(exitDestination(of: five) == [10],
              "Scene 5 leads back into Scene 2 as Scene 6, got \(exitDestination(of: five))")
        var sixTransition: WorldTransition? = nil
        if let exit = five.cubeModel.chosenExit,
           let (ci, fi) = five.cubeModel.faceletAt(face: exit.face, row: exit.row, col: exit.col) {
            sixTransition = five.cubeModel.cubies[ci].facelets[fi].props
                .first(where: { $0.kind == .portal })?.transition
        }
        check(sixTransition == .goto, "the return to Scene 2 must replace, not nest (got \(String(describing: sixTransition)))")

        // Scene 3's exit does not exist until the orb chooses one, so complete the puzzle first.
        let four = GameState(size: PrologueSize.sceneFour, name: "s4", stamp: .sceneFour)
        check(exitDestination(of: four) == [14], "Scene 4 leads on to Scene 5, got \(exitDestination(of: four))")

        let three = GameState(size: PrologueSize.sceneThree, name: "s3", interior: true, stamp: .sceneThree)
        let m3 = three.cubeModel
        for cu in m3.cubies.indices {
            for f in m3.cubies[cu].facelets.indices {
                for pi in m3.cubies[cu].facelets[f].props.indices
                where m3.cubies[cu].facelets[f].props[pi].kind == .obelisk {
                    m3.cubies[cu].facelets[f].props[pi].anim = 1
                }
            }
        }
        m3.createChosenExit(destinationID: 11)
        check(exitDestination(of: three) == [11], "Scene 3 leads on to Scene 4, got \(exitDestination(of: three))")
    }

    /// 5F — "their rings contain small gaps or windows that show whether nearby channels are
    /// currently aligned… They do not give instructions. They mirror local truth."
    ///
    /// The distinction is the point: a junction vessel reads how many of ITS OWN arms carry current,
    /// so it can show three while the circuit is still broken. A vessel that tracked puzzle progress
    /// would be a hint, and this scene does not hint.
    /// Scene 5C — "the circuit explains itself by failing visibly". The pulse is therefore not a
    /// shader scroll but a front with a position, and the only property that matters is that it
    /// STOPS WHERE THE ROUTE STOPS: a pulse that ran to the end of the world would teach the player
    /// the opposite of the truth. Also checks that it cycles, since one failure the player missed
    /// has to come round again.
    /// SCENE 6's FOUNDATION. "Scene 6 must use the actual persisted state of Scene 2, not a visually
    /// similar duplicate… The scene depends on trust. If the world resets here, the theme collapses."
    ///
    /// The whole scene is a return to a world the player already changed, so this is the one property
    /// it cannot be built without — and until now the rule lived in the Renderer, which the harness
    /// cannot reach, so it had no test at all.
    static func testAPrologueWorldIsTheSamePlaceHoweverYouReachIt() {
        let registry = WorldRegistry()
        registry.singleInstanceNames = ["scene-2", "scene-3"]

        var builds = 0
        func makeSceneTwo() -> GameState {
            builds += 1
            return GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo)
        }
        // First visit: arrived from Scene 1.
        let first = registry.resolve(destination: "scene-2", origin: "scene-1", create: makeSceneTwo)
        check(builds == 1, "the first visit builds the world")

        // Change it, the way the player does: turn a slab, and discover a tile.
        first.cubeModel.applySliceRotation(axis: 1, index: 0, angle: .pi / 2)
        let scarred = first.cubeModel.topologyVersion
        guard let (ci, fi) = first.cubeModel.faceletAt(face: .positiveZ, row: 0, col: 0) else {
            check(false, "scene-2 has no (0,0) on +Z"); return
        }
        first.cubeModel.cubies[ci].facelets[fi].tileState = .discovered
        let openings = first.cubeModel.cubies[ci].facelets[fi].mazeTile.openings

        // Scene 6: the same world, reached from Scene 5 instead. Not a rebuild, and not a copy.
        let returned = registry.resolve(destination: "scene-2", origin: "scene-5", create: makeSceneTwo)
        check(builds == 1, "returning by a NEW route must not build a second Scene 2 (built \(builds))")
        check(returned === first, "Scene 6 must arrive in the very world Scene 2 left behind")
        check(returned.cubeModel.topologyVersion == scarred, "the twist did not survive the return")
        check(returned.cubeModel.cubies[ci].facelets[fi].tileState == .discovered,
              "what the player had seen was forgotten")
        check(returned.cubeModel.cubies[ci].facelets[fi].mazeTile.openings == openings,
              "the maze reconnected itself between visits")

        // And the sky lookup finds that same instance, so what hangs overhead is the place you
        // walked in — this is what `anyNamed` exists for.
        check(registry.anyNamed("scene-2") === first, "the world overhead is a different Scene 2")

        // A world NOT on the single-instance list keeps the registry's per-edge default: arriving by
        // a different door may legitimately be a different place. Scene 6 depends on the distinction.
        var galleryBuilds = 0
        func makeGallery() -> GameState {
            galleryBuilds += 1
            return GameState(size: 5, name: "gallery-a", stamp: .bare)
        }
        _ = registry.resolve(destination: "gallery-a", origin: "hub", create: makeGallery)
        _ = registry.resolve(destination: "gallery-a", origin: "scene-1", create: makeGallery)
        check(galleryBuilds == 2, "a per-edge world should vary by route, got \(galleryBuilds) builds")
    }

    /// Scene 3's interior is the second half of Scene 6's promise: "the player has returned to a
    /// solved machine. The machine is still solved." Six obelisks lit, orb connected, and the exit
    /// it created still standing.
    static func testTheInteriorStaysSolvedBetweenVisits() {
        let registry = WorldRegistry()
        registry.singleInstanceNames = ["scene-3"]
        let three = registry.resolve(destination: "scene-3", origin: "scene-2") {
            GameState(size: PrologueSize.sceneThree, name: "scene-3", interior: true, stamp: .sceneThree)
        }
        // Wake every obelisk, the way the scene does, and let the exit be created.
        for cu in three.cubeModel.cubies.indices {
            for f in three.cubeModel.cubies[cu].facelets.indices {
                for p in three.cubeModel.cubies[cu].facelets[f].props.indices
                where three.cubeModel.cubies[cu].facelets[f].props[p].kind == .obelisk {
                    three.cubeModel.cubies[cu].facelets[f].props[p].anim = 1
                }
            }
        }
        for _ in 0..<10 { three.update(deltaTime: 1.0 / 60.0) }
        check(three.sceneThreeAllObelisksAwake, "the chamber should be awake once every obelisk is lit")
        // 3K's exit is created by the plinth INTERACTION, not by the obelisks being lit — lighting
        // them here is a shortcut past that path, so the door is placed directly. What is being
        // tested is that it survives the return, not what creates it.
        three.cubeModel.createChosenExit(destinationID: 11)
        let exit = three.cubeModel.chosenExit
        check(exit != nil, "Scene 3 should be able to place its exit")

        let again = registry.resolve(destination: "scene-3", origin: "scene-6") {
            check(false, "Scene 6 rebuilt the interior instead of returning to it")
            return GameState(size: PrologueSize.sceneThree, name: "scene-3", interior: true, stamp: .sceneThree)
        }
        check(again === three, "the second descent must reach the same chamber")
        check(again.sceneThreeAllObelisksAwake, "the machine forgot it was solved")
        check(again.cubeModel.chosenExit?.face == exit?.face
              && again.cubeModel.chosenExit?.row == exit?.row,
              "the portal Scene 3 created is no longer where it was left")
    }

    /// Scene 6A — "They are arriving from a new direction into a world that remembers." The arrival
    /// point is a property of the ROUTE, not of the world: the same Scene 2, entered from Scene 5,
    /// must land on the region that only exists because of the twist made there.
    static func testAWorldCanNameADifferentDoorPerRoute() {
        let gs = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo)
        let m = gs.cubeModel
        guard let home = m.spawnLocation else { check(false, "scene-2 states its own arrival"); return }
        // Unknown routes, and no route at all, keep the world's own opening image.
        check(m.spawn(arrivingFrom: nil)?.face == home.face, "no route named ⇒ the world's own spawn")
        check(m.spawn(arrivingFrom: "scene-1")?.face == home.face, "an unnamed route ⇒ the same")
        // A named route overrides it, and only it.
        let far: CubeFace = home.face == .negativeY ? .positiveY : .negativeY
        m.arrivalSpawns["scene-5"] = (face: far, row: 1, col: 2, facing: .n)
        check(m.spawn(arrivingFrom: "scene-5")?.face == far, "the route's own door was ignored")
        check(m.spawn(arrivingFrom: "scene-5")?.col == 2, "the route's door landed on the wrong tile")
        check(m.spawn(arrivingFrom: "scene-1")?.face == home.face,
              "naming one route must not move every other arrival")
    }

    /// Scene 6C — "The area feels like the reverse side of a familiar stage." Measured rather than
    /// designed: the slab carrying Scene 2's hidden assembly is the x = 0 slab, and its outward
    /// end-cap is the whole of `-X` — walkable, connected to itself, and reachable from nowhere
    /// else, because Scene 2 seals every face into an island. That is the region, and the test that
    /// matters is that it is genuinely UNREACHABLE from Scene 2's own route. The day it becomes
    /// reachable, Scene 6's arrival stops being a discovery and becomes a place you could have
    /// walked to.
    static func testSceneSixArrivesWhereSceneTwoCouldNotReach() {
        let gs = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo)
        let m = gs.cubeModel
        guard let home = m.spawnLocation, let six = m.spawn(arrivingFrom: "scene-5") else {
            check(false, "Scene 2 should state both its own arrival and Scene 6's"); return
        }
        check(six.face != home.face, "Scene 6 must arrive on a different face from Scene 2's opening")

        // Walk what is reachable from each, through openings, across face edges.
        func reachable(from start: (face: CubeFace, row: Int, col: Int)) -> Set<Int> {
            struct T: Hashable { let f: Int; let r: Int; let c: Int }
            var seen: Set<T> = [T(f: start.face.rawValue, r: start.row, c: start.col)]
            var ids: Set<Int> = []
            var q = Array(seen), head = 0
            while head < q.count {
                let t = q[head]; head += 1
                guard let face = CubeFace(rawValue: t.f),
                      let (ci, fi) = m.faceletAt(face: face, row: t.r, col: t.c) else { continue }
                ids.insert(m.cubies[ci].facelets[fi].id.rawValue)
                let op = m.cubies[ci].facelets[fi].mazeTile.openings
                for (dir, mask, dr, dc) in [(SurfaceDirection.north, DirectionMask.north, -1, 0),
                                            (.south, .south, 1, 0), (.west, .west, 0, -1), (.east, .east, 0, 1)]
                where op.contains(mask) {
                    let nr = t.r + dr, nc = t.c + dc
                    let nt: T
                    if nr >= 0, nr < m.size, nc >= 0, nc < m.size { nt = T(f: t.f, r: nr, c: nc) }
                    else {
                        let cr = m.edgeCrossing(face: face, direction: dir, row: t.r, col: t.c)
                        nt = T(f: cr.face.rawValue, r: cr.row, c: cr.col)
                    }
                    if seen.insert(nt).inserted { q.append(nt) }
                }
            }
            return ids
        }
        let fromHome = reachable(from: (home.face, home.row, home.col))
        let fromSix = reachable(from: (six.face, six.row, six.col))
        guard let (sci, sfi) = m.faceletAt(face: six.face, row: six.row, col: six.col) else {
            check(false, "Scene 6's arrival is not a real tile"); return
        }
        let sixTile = m.cubies[sci].facelets[sfi]
        check(!sixTile.mazeTile.openings.isEmpty, "Scene 6 arrives inside a sealed tile")
        check(!fromHome.contains(sixTile.id.rawValue),
              "Scene 6's arrival is walkable from Scene 2's spawn — the region is not new")
        check(fromSix.count > 40, "the arrival region should be somewhere to explore, got \(fromSix.count) tiles")
        check(fromHome.intersection(fromSix).isEmpty,
              "the two regions overlap by \(fromHome.intersection(fromSix).count) tiles; they should be separate until 6D opens the way")
    }

    /// Build a prologue world the way `Renderer.buildWorld` does — same size, same interior flag,
    /// same withheld twist, same reveal. A world built any other way is not the one being shipped,
    /// and a suite that tests a different world tests nothing.
    static func prologueWorld(_ name: String) -> GameState {
        let w: GameState
        switch name {
        case "scene-1": w = GameState(size: PrologueSize.sceneOne, name: name, stamp: .sceneOne)
        case "scene-2": w = GameState(size: PrologueSize.sceneTwo, name: name, stamp: .sceneTwo)
        case "scene-3": w = GameState(size: PrologueSize.sceneThree, name: name, interior: true, stamp: .sceneThree)
        case "scene-4": w = GameState(size: PrologueSize.sceneFour, name: name, stamp: .sceneFour)
        default:        w = GameState(size: PrologueSize.sceneFive, name: name, stamp: .sceneFive)
        }
        w.twistEnabled = (name == "scene-5")   // scenes 1-4 withhold it; Scene 4 grants it in play
        if name != "scene-1" {                 // buildWorld reveals every world except Scene 1's
            for cu in w.cubeModel.cubies.indices {
                for f in w.cubeModel.cubies[cu].facelets.indices {
                    w.cubeModel.cubies[cu].facelets[f].tileState = .discovered
                    w.cubeModel.cubies[cu].facelets[f].discoveryAmount = 1.0
                }
            }
        }
        return w
    }

    /// A portal Prop stores an INDEX; its signpost samples the same index out of the label list. Two
    /// index-aligned lists that live apart will drift, and this one did: Scene 6 was appended as
    /// destination 15 while the labels stopped at 14, so its sign sampled a slice that did not exist
    /// and came back reading "Moon" — a door in the hub confidently pointing at the wrong world
    /// (Eddie). Nothing could have caught it, because both lists lived on the Renderer, which this
    /// harness cannot compile. They are now in `WorldCatalog`, and this is why.
    static func testEveryDoorKnowsWhatItIsCalled() {
        check(WorldCatalog.labels.count == WorldCatalog.destinations.count,
              "\(WorldCatalog.destinations.count) destinations but \(WorldCatalog.labels.count) labels — "
              + "a door at the end of the longer list will read as whatever slice 0 happens to be")
        for (i, name) in WorldCatalog.destinations.enumerated() {
            // Guarded, not assumed: when the lists DO drift, indexing the shorter one traps and
            // takes the whole suite down with it — the first run of this test crashed the binary
            // instead of reporting, which hides every other result in the file.
            guard WorldCatalog.labels.indices.contains(i) else { continue }
            if name == "portal-hub" {
                check(WorldCatalog.labels[i].isEmpty, "the hub does not signpost itself")
            } else {
                check(!WorldCatalog.labels[i].isEmpty, "destination \(i) (\(name)) has no sign text")
            }
        }
        // Every prologue id must name a real destination — these paint the DARSIT doors and decide
        // which worlds are single-instance, so an id past the end silently drops both.
        for id in WorldCatalog.prologueIDs {
            check(WorldCatalog.destinations.indices.contains(id),
                  "prologue id \(id) is past the end of the destination list")
        }
        // Names are unique: two entries with the same name would resolve to one world by different
        // indices, and only one of the two doors would keep its state.
        check(Set(WorldCatalog.destinations).count == WorldCatalog.destinations.count,
              "duplicate destination names in the catalogue")
        // Scene 6 is the one destination that is not its own world — it must name Scene 2's.
        check(WorldCatalog.destinations.contains("scene-6"), "Scene 6 has no hub door")
    }

    /// A world says where you stand, and that has to hold however you got there. `spawnLocation` was
    /// applied only on arrival THROUGH A PORTAL, so a world entered any other way — the boot world
    /// above all — left the player at PlayerState's default, the centre of the front face.
    ///
    /// Harmless while every world revealed itself at build; fatal once one keeps its fog. It put the
    /// player in the middle of Scene 1's maze with only the clearing revealed, which reads as three
    /// separate bugs at once: no walls, fog where the ground should be, and no clearing in sight.
    static func testWorldsPlaceThePlayerWhereTheySay() {
        for (label, gs) in [("scene-1", GameState(size: PrologueSize.sceneOne, name: "s1", stamp: .sceneOne)),
                            ("scene-2", GameState(size: PrologueSize.sceneTwo, name: "s2", stamp: .sceneTwo)),
                            ("scene-4", GameState(size: PrologueSize.sceneFour, name: "s4", stamp: .sceneFour))] {
            guard let spawn = gs.cubeModel.spawnLocation else {
                check(false, "\(label) should author a spawn"); continue
            }
            check(gs.player.face == spawn.face && gs.player.row == spawn.row && gs.player.col == spawn.col,
                  "\(label) starts the player at (\(gs.player.row),\(gs.player.col)), authored (\(spawn.row),\(spawn.col))")
            check(gs.player.facing == spawn.facing, "\(label) starts the player facing \(spawn.facing)")
            // And the tile under them is one they can see — standing in fog is not a start.
            guard let (ci, fi) = gs.cubeModel.faceletAt(face: gs.player.face, row: gs.player.row, col: gs.player.col)
            else { check(false, "\(label) spawn is off the grid"); continue }
            check(gs.cubeModel.cubies[ci].facelets[fi].tileState != .unknown,
                  "\(label) must not start the player on an unrevealed tile")
        }
    }

    /// The arrival doorway closes behind you (Scene 2A) — and must take ONLY itself with it. Its veil
    /// is the same prop kind the scene's real exit portal uses, so a cleanup that matched by kind
    /// swept the whole world and stripped the exit of its visuals. (There used to be a ring too;
    /// the disc grounds itself now, so the veil alone carries the marker.)
    static func testClosingDoorwayLeavesTheRealPortalAlone() {
        let gs = GameState(size: PrologueSize.sceneFour, name: "scene-4", stamp: .sceneFour)
        let m = gs.cubeModel
        func portalDressing() -> Int {
            var n = 0
            for cu in m.cubies { for f in cu.facelets {
                n += f.props.filter { $0.kind == .portalField && $0.anim <= 0.5 }.count
            } }
            return n
        }
        let before = portalDressing()
        check(before > 0, "Scene 4's exit portal should have a disc to protect")
        gs.closeArrivalDoorway()
        check(portalDressing() == before, "closing must not disturb the real portal's dressing")
        for _ in 0..<300 { gs.update(deltaTime: 1.0 / 60.0) }
        check(portalDressing() == before, "and the real portal still has them once it is gone")
        var arrivals = 0
        for cu in m.cubies { for f in cu.facelets {
            arrivals += f.props.filter { $0.kind == .portalField && $0.anim > 0.5 }.count
        } }
        check(arrivals == 0, "the arrival doorway itself is gone, not merely invisible")
    }

    /// M20 — the walk-through portal trigger (the two regressions Eddie hit, as permanent guards):
    /// (a) tile-entry must NOT fire it — only reaching the portal's own centre sub-cell does
    ///     ("sensitive" bug: fired half a tile early);
    /// (b) the continuous check must fire when you settle on the centre — not only on tile
    ///     crossings (dead-centre-nothing-happens bug);
    /// (c) priming: a portal you spawn on, stand on, or that re-primes under you (a twist) must
    ///     not teleport you — you have to walk OFF and back ON.
    static func testWalkThroughPortalGating() {
        func makeState() -> GameState {
            let g = GameState(size: 5, name: "portal-test", stamp: .bare)
            let c = g.cubeModel.size / 2
            if let (ci, fi) = g.cubeModel.faceletAt(face: .positiveZ, row: c + 1, col: c) {
                g.cubeModel.cubies[ci].facelets[fi].props.append(
                    Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n, state: 3))
            }
            return g
        }
        let dt: Float = 1.0 / 60.0
        let g = makeState()
        let c = g.cubeModel.size / 2
        let center = g.player.standCenter
        // (prime) player settled off-portal: first update records position, no fire
        g.update(deltaTime: dt)
        check(!g.portalRequested, "portal: no fire while off the portal tile")
        // (a) step onto the portal TILE but at its edge sub-cell — must NOT fire
        g.player.row = c + 1; g.player.col = c
        g.player.subRow = 0; g.player.subCol = center
        g.update(deltaTime: dt)
        check(!g.portalRequested, "portal: entering the tile edge does not fire (the 'sensitive' bug)")
        // (b) reach the CENTRE sub-cell — must fire, with the portal's destination
        g.player.subRow = center; g.player.subCol = center
        g.update(deltaTime: dt)
        check(g.portalRequested, "portal: settling on the centre sub-cell fires")
        check(g.portalDestinationID == 3, "portal: destination rides Prop.state")
        // (c1) standing still must not re-fire
        g.portalRequested = false
        g.update(deltaTime: dt)
        check(!g.portalRequested, "portal: standing on it does not re-fire (edge-triggered)")
        // (c2) re-prime (what a finalized twist does) with the player ON the portal: no fire
        g.reprimePortalZone()
        g.update(deltaTime: dt)
        check(!g.portalRequested, "portal: re-prime on the portal (twist case) does not teleport")
        // walk off and back on — fires again
        g.player.subRow = 0
        g.update(deltaTime: dt)
        g.player.subRow = center
        g.update(deltaTime: dt)
        check(g.portalRequested, "portal: off then back on fires again")
        // (c3) spawn directly on a portal: the first evaluations must not fire
        let g2 = makeState()
        g2.player.row = c + 1; g2.player.col = c
        g2.player.subRow = center; g2.player.subCol = center
        g2.update(deltaTime: dt)
        g2.update(deltaTime: dt)
        check(!g2.portalRequested, "portal: spawning on a portal does not teleport (priming)")
    }

}
