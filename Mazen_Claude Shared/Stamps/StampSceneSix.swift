import Foundation
import simd

/// B2 — Scene 6's underside machinery (the kit struct + the stamp), moved verbatim.
extension CubeModel {
    /// SCENE 6C — the pieces the underside is built from, grouped by role rather than by name so the
    /// stamp asks for "something that holds a floor up" instead of for a particular model.
    struct UndersideMachinery {
        var uprights: [Int] = []   // supports, antennae — things that stand
        var runs: [Int] = []       // pipes, cables — things that carry
        var boxes: [Int] = []      // AC units, computers — things that hum
        var rails: [Int] = []      // rails, fence — things that stop you falling
        var plates: [Int] = []     // platform sections — the underside of a floor
        var lamps: [Int] = []      // street/square lights
        var isEmpty: Bool { uprights.isEmpty && runs.isEmpty && boxes.isEmpty && rails.isEmpty }
    }

    /// Dress `-X` — the end-cap of the slab that Scene 2's twist turns, and the region Scene 6
    /// arrives on. It is walkable and connected but was completely bare, which reads as an unfinished
    /// level rather than as the back of a stage.
    ///
    /// "The area feels like the reverse side of a familiar stage… supports, seams, braces, and
    /// machinery that were never visible from the original route."
    ///
    /// Density RISES toward the edge the portal assembly stands on (`-X` col 10 adjoins `+Z` col 0),
    /// so the machinery reads as belonging to that structure and thins out into bare plate as you
    /// walk away from it. Deterministic per tile: the same world every run, and a twist carries the
    /// props with their tiles like anything else.
    func stampSceneSixUnderside(_ kit: UndersideMachinery) {
        guard !kit.isEmpty else { return }
        undersideFace = .negativeX
        let n = size
        let c = n / 2
        // 6D — THE THREE LATCHES, before the scatter so their tiles stay theirs. They hang along
        // the assembly edge: the portal chamber sits at +Z (c, 0) flanked by its obelisks at
        // (c−1, 0) and (c+1, 0), and crossing west from those tiles lands on −X rows c−1, c, c+1,
        // col n−1 — directly beneath the structure. "Three suspended stone latches connected to the
        // two obelisks above and to a sealed interior hatch ahead… activate the latches in physical
        // order along the structure." `state` is that order: left obelisk, chamber, right obelisk.
        for (i, r) in [c - 1, c, c + 1].enumerated() {
            guard let (ci, fi) = faceletAt(face: .negativeX, row: r, col: n - 1) else { continue }
            cubies[ci].facelets[fi].props.removeAll { !$0.kind.isSolid }
            // The latch speaks Scene 2's dialect on purpose (Eddie): a base plate and a cap
            // carrying the ordinal in dots — one, two, three — because the player has already
            // learned that grammar at the four corners, and 6D's lesson is the ORDER, not a new
            // language.
            cubies[ci].facelets[fi].props.append(Prop(kind: .switchBase, subRow: 1, subCol: 1, facing: .w))
            cubies[ci].facelets[fi].props.append(
                Prop(kind: .latch, subRow: 1, subCol: 1, facing: .w, state: i + 1))
        }
        // Clear whatever the world's own dressing put here first. Scene 2 scatters ground foliage
        // over every face but `+Z`, which includes this one — and a bush on the underside of a
        // turning slab is the one thing that stops it reading as the back of a stage.
        for r in 0..<n {
            for c in 0..<n {
                guard let (ci, fi) = faceletAt(face: .negativeX, row: r, col: c) else { continue }
                cubies[ci].facelets[fi].props.removeAll {
                    $0.kind == .importedFoliage || $0.kind == .greeneryCard
                        || $0.kind == .foliageCard || $0.kind == .treeBillboard
                        || $0.kind == .tree || $0.kind == .treeTrunk || $0.kind == .boulder
                }
            }
        }
        for r in 0..<n {
            for c in 0..<n {
                guard let (ci, fi) = faceletAt(face: .negativeX, row: r, col: c) else { continue }
                guard cubies[ci].facelets[fi].props.isEmpty else { continue }
                var h = UInt32(truncatingIfNeeded: r &* 73856093 ^ c &* 19349663 ^ 0x51ED2701)
                h ^= h >> 13; h = h &* 2654435761; h ^= h >> 16
                // A SECOND hash, not more shifts of the first. `h >> 27` leaves five bits — a maximum
                // of 31 — so a "< 55%" test on it is always true, and every deck came up raised
                // (measured: 32 of 32). One 32-bit word does not hold six independent decisions.
                var h2 = UInt32(truncatingIfNeeded: r &* 19349663 ^ c &* 83492791 ^ 0x9E37_79B9)
                h2 ^= h2 >> 15; h2 = h2 &* 2246822519; h2 ^= h2 >> 13
                // 0 at the far side of the cap, 1 against the assembly edge.
                let toward = Float(c) / Float(max(1, n - 1))
                let chance = 0.30 + 0.45 * toward * toward
                guard Float(h % 1000) / 1000.0 < chance else { continue }
                let sub = Int((h >> 3) % 9)
                let facing = Heading8(rawValue: Int((h >> 11) % 8)) ?? .n

                // DECKS EVERYWHERE, not only against the assembly (Eddie: "I was expecting lots more
                // platform_4x1 and its siblings strewn about"). They are the thing that makes this
                // read as the underside of a built surface rather than a floor with clutter on it.
                if !kit.plates.isEmpty, h2 % 100 < 45 {
                    let plate = kit.plates[Int((h >> 7) % UInt32(kit.plates.count))]
                    // Some stand on a PILLAR (Eddie's suggestion), which is what a raised deck wants
                    // in a place like this: `sink` is negative here, so it LIFTS by that fraction of
                    // the model's own height rather than burying it, and a support goes under it on
                    // the same sub-cell to carry the load.
                    let raised = !kit.uprights.isEmpty && (h2 >> 8) % 100 < 55
                    var deck = Prop(kind: .importedFoliage, subRow: sub / 3, subCol: sub % 3,
                                    facing: facing, state: plate,
                                    extraScale: 0.75 + Float((h >> 17) % 45) / 100.0)
                    if raised {
                        deck.sink = -(0.55 + Float((h2 >> 16) % 35) / 100.0)
                        let post = kit.uprights[Int((h >> 9) % UInt32(kit.uprights.count))]
                        cubies[ci].facelets[fi].props.append(
                            Prop(kind: .importedFoliage, subRow: sub / 3, subCol: sub % 3,
                                 facing: facing, state: post, extraScale: 0.9))
                    }
                    cubies[ci].facelets[fi].props.append(deck)
                    continue
                }

                // Everything else: uprights and runs anywhere, the heavier fittings nearer the
                // assembly, so the structure thickens toward what it belongs to.
                var pool: [Int] = kit.uprights + kit.runs
                if toward > 0.45 { pool += kit.boxes + kit.rails }
                if toward > 0.70 { pool += kit.lamps }
                guard !pool.isEmpty else { continue }
                let idx = pool[Int((h >> 7) % UInt32(pool.count))]
                let scale = 0.55 + Float((h >> 17) % 40) / 100.0
                cubies[ci].facelets[fi].props.append(
                    Prop(kind: .importedFoliage, subRow: sub / 3, subCol: sub % 3,
                         facing: facing, state: idx, extraScale: scale))
            }
        }
        markTopologyChanged()
    }

    /// The exit, built on the hidden `+Y` face from the first frame: two obelisks flanking a portal
    /// chamber, sealed and dark until the slab turns. They ride their facelets, so the twist carries
    /// them onto `+Z` with no spawning.
    func stampSceneTwoHiddenAssembly() {
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
                // → SCENE 3, which is literally the inside of this world: "this is literally the
                // inside of the larger exterior world explored in Scene 2". The chamber was still
                // pointing at temple-interior, the stand-in it was built against before Scene 3
                // existed — so the prologue's chain broke at its second link and dropped the player
                // into a dev world. A DOWNWARD elevator, which is the right shape for a descent.
                cubies[ci].facelets[fi].props.append(
                    Prop(kind: .portal, subRow: 1, subCol: 1, facing: .e, state: 13, transition: .push))
                styledPortals.append(StyledPortal(ci: ci, fi: fi, facing: .e, fieldStyle: 3))
                cubies[ci].facelets[fi].props.append(Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .e, state: 3))
                sealedPortalCubies.insert(ci)     // dark until the slab has turned
            } else {
                cubies[ci].facelets[fi].props.append(Prop(kind: .obelisk, subRow: 1, subCol: 1))
            }
        }
        // SCENE 6A — where the player lands when they come back to this world from Scene 5.
        //
        // Measured, not chosen: the slab that carries this assembly is the x = 0 slab, and its
        // outward end-cap is the whole of `-X` — 121 tiles that are walkable, fully connected to
        // each other, and reachable from NOWHERE else, because Scene 2 seals every face into an
        // island. It is the literal reverse side of the stage the player solved: cross the edge west
        // of the assembly (+Z r4–r6 c0) and you are on `-X` r4–r6 c10, underneath it.
        //
        // "The area feels like the reverse side of a familiar stage. The player can see supports,
        // seams, braces, and machinery that were never visible from the original route."
        //
        // The arrival stands at the far end of that cap, facing east toward the assembly edge, so
        // the region is crossed on foot rather than arrived into.
        arrivalSpawns["scene-5"] = (face: .negativeX, row: mid, col: 2, facing: .e)
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

    /// 6D's payoff and 6E's door: "activating it opens a hatch, corridor, or small chamber leading
    /// INWARD." The hatch is the second descent — a portal into the Scene 3 interior — standing one
    /// tile in from the middle latch, so the player turns from the third latch and the way down is
    /// ahead of them. Destination 13 with `.push`, exactly like the first descent; what differs is
    /// the ROUTE, which is what Scene 6 is about.
    func createUndersideHatch() {
        guard undersideHatch == nil else { return }
        let n = size, c = n / 2
        guard let (ci, fi) = faceletAt(face: .negativeX, row: c, col: n - 2) else { return }
        // The tile may carry scatter machinery; the hatch replaces it — a door was always under there.
        cubies[ci].facelets[fi].props.removeAll()
        cubies[ci].facelets[fi].props.append(
            Prop(kind: .portal, subRow: 1, subCol: 1, facing: .e, state: 13, transition: .push))
        styledPortals.append(StyledPortal(ci: ci, fi: fi, facing: .e, fieldStyle: 3))
        cubies[ci].facelets[fi].props.append(Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .e, state: 3))
        undersideHatch = (.negativeX, c, n - 2)
        markTopologyChanged()
    }
}
