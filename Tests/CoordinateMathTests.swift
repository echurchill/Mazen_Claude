import Foundation
import simd

// Standalone coordinate-math test runner (Phase 0 / R4).
//
// Compiles the pure-Swift model sources (no Metal) together with this file and
// exercises the invariants that the M8 rotation bug violated, across cube sizes
// 3/5/7/9. Run with Tests/run-tests.sh — exits non-zero on any failure.
//
// Covered:
//   1. Projection is a bijection — every (face,row,col) maps to one unique facelet.
//   2. gridPosition ↔ worldMatrix consistency — adjacent grid cells belong to
//      cubies whose integer positions differ by exactly the face tangent/bitangent.
//      (This is the exact invariant that broke in M8.)
//   3. EdgeCrossing round-trips — crossing an edge and coming back returns you home.
//   4. Slice rotation — projection stays bijective after a turn; four quarter turns
//      restore every cubie position.
//   5. DirectionMask.rotated — rotation algebra (identity, composition, negatives).
//   6. Prop.rotate — a placed prop stays glued to its tile: four quarter-turns restore
//      its sub-cell + facing, 0 turns is a no-op, −1 == 3, and the rotation sense matches
//      DirectionMask (N→E). Guards the Rubik's split's correctness at the math level (the
//      cheap insurance the M12-E house-split verification called for).

@main
struct CoordinateMathTests {
    static var passed = 0
    static var failed = 0
    static var failures: [String] = []

    static func check(_ cond: Bool, _ msg: @autoclosure () -> String) {
        if cond { passed += 1 } else { failed += 1; failures.append(msg()) }
    }

    static func main() {
        let sizes = [3, 5, 7, 9, 25]   // 25 = the R2.16 hard cap — the math must hold at the ceiling
        for n in sizes {
            testProjectionBijection(size: n)
            testGridWorldConsistency(size: n)
            testEdgeCrossingRoundTrip(size: n)
            testSliceRotation(size: n)
            testBandagedLegality(size: n)
            testRestPlacement(size: n)
            testFootprintContinuity(size: n)
            testInteriorPlacement(size: n)
            testEdgeContinuity(size: n, interior: false)
            testEdgeContinuity(size: n, interior: true)
        }
        testDirectionMaskRotation()
        testPropRotation()
        testInflateGoldens()
        testSizeCap()

        print("")
        if failed == 0 {
            print("✅ All \(passed) checks passed across sizes \(sizes).")
        } else {
            print("❌ \(failed) checks FAILED (\(passed) passed):")
            for f in failures.prefix(50) { print("   - \(f)") }
            if failures.count > 50 { print("   … and \(failures.count - 50) more") }
            exit(1)
        }
    }

    // MARK: - Helpers

    static func delta(_ a: SIMD3<Int32>, _ b: SIMD3<Int32>) -> SIMD3<Int32> {
        SIMD3(b.x - a.x, b.y - a.y, b.z - a.z)
    }

    static func intStep(_ v: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3(Int32(v.x.rounded()), Int32(v.y.rounded()), Int32(v.z.rounded()))
    }

    static func borderCell(dir: SurfaceDirection, i: Int, n: Int) -> (row: Int, col: Int) {
        switch dir {
        case .north: return (0, i)
        case .south: return (n - 1, i)
        case .east:  return (i, n - 1)
        case .west:  return (i, 0)
        }
    }

    static func checkBijection(_ model: CubeModel, size n: Int, label: String) {
        var seen = Set<Int>()
        for face in CubeFace.allCases {
            for row in 0..<n {
                for col in 0..<n {
                    guard let (ci, fi) = model.faceletAt(face: face, row: row, col: col) else {
                        check(false, "size \(n) \(label): faceletAt(\(face),\(row),\(col)) is nil")
                        continue
                    }
                    let id = model.cubies[ci].facelets[fi].id.rawValue
                    check(!seen.contains(id), "size \(n) \(label): duplicate facelet \(id) at (\(face),\(row),\(col))")
                    seen.insert(id)
                }
            }
        }
        check(seen.count == 6 * n * n, "size \(n) \(label): expected \(6 * n * n) unique facelets, got \(seen.count)")
    }

    // MARK: - Tests

    static func testProjectionBijection(size n: Int) {
        checkBijection(CubeModel(size: n), size: n, label: "initial")
    }

    static func testGridWorldConsistency(size n: Int) {
        let model = CubeModel(size: n)
        for face in CubeFace.allCases {
            let tan = intStep(face.tangent)
            let bit = intStep(face.bitangent)
            for row in 0..<n {
                for col in 0..<n {
                    guard let (ci, _) = model.faceletAt(face: face, row: row, col: col) else { continue }
                    let p = model.cubies[ci].position
                    if col + 1 < n, let (ci2, _) = model.faceletAt(face: face, row: row, col: col + 1) {
                        let d = delta(p, model.cubies[ci2].position)
                        check(d == tan, "size \(n) \(face): col step (\(row),\(col))→(\(row),\(col + 1)) expected \(tan) got \(d)")
                    }
                    if row + 1 < n, let (ci2, _) = model.faceletAt(face: face, row: row + 1, col: col) {
                        let d = delta(p, model.cubies[ci2].position)
                        check(d == bit, "size \(n) \(face): row step (\(row),\(col))→(\(row + 1),\(col)) expected \(bit) got \(d)")
                    }
                }
            }
        }
    }

    static func testEdgeCrossingRoundTrip(size n: Int) {
        for face in CubeFace.allCases {
            for dir in SurfaceDirection.allCases {
                for i in 0..<n {
                    let (r, c) = borderCell(dir: dir, i: i, n: n)
                    let out = EdgeCrossing.cross(face: face, direction: dir, row: r, col: c, cubeSize: n)
                    let back = EdgeCrossing.cross(face: out.face, direction: out.facing.opposite, row: out.row, col: out.col, cubeSize: n)
                    check(back.face == face && back.row == r && back.col == c,
                          "size \(n): roundtrip \(face) \(dir) (\(r),\(c)) → \(out.face)(\(out.row),\(out.col)) f=\(out.facing) → back \(back.face)(\(back.row),\(back.col))")
                    check(back.facing == dir.opposite,
                          "size \(n): roundtrip facing \(face) \(dir): back facing \(back.facing) expected \(dir.opposite)")
                }
            }
        }
    }

    static func testSliceRotation(size n: Int) {
        let model = CubeModel(size: n)
        let orig = model.cubies.map { $0.position }
        let axis = 2, index = n - 1
        let angle: Float = -.pi / 2

        // Stamp a prop on a facelet of a cubie in this slice, to verify props ride the rotation
        // end-to-end (applySliceRotation → Prop.rotate) and a full 4-turn cycle restores them —
        // the M12-E house-split invariant, exercised through the real machinery, not in isolation.
        let sliceCubies = model.cubieIndicesInSlice(axis: axis, index: index)
        var propCubie = -1
        if let ci = sliceCubies.first(where: { !model.cubies[$0].facelets.isEmpty }) {
            propCubie = ci
            model.cubies[ci].facelets[0].props.append(Prop(kind: .topiary, subRow: 0, subCol: 1, facing: .n))
        }

        model.applySliceRotation(axis: axis, index: index, angle: angle)
        checkBijection(model, size: n, label: "after 1 z-rotation")

        model.applySliceRotation(axis: axis, index: index, angle: angle)
        model.applySliceRotation(axis: axis, index: index, angle: angle)
        model.applySliceRotation(axis: axis, index: index, angle: angle)
        for i in model.cubies.indices {
            check(model.cubies[i].position == orig[i],
                  "size \(n): cubie \(i) pos after 4 z-turns \(model.cubies[i].position) != orig \(orig[i])")
        }
        checkBijection(model, size: n, label: "after 4 z-rotations")

        // The stamped prop rode all four turns and returned to its original sub-cell + facing.
        if propCubie >= 0, let p = model.cubies[propCubie].facelets[0].props.first {
            check(p.subRow == 0 && p.subCol == 1 && p.facing == .n,
                  "size \(n): prop after 4 z-turns (\(p.subRow),\(p.subCol),\(p.facing)) != (0,1,n)")
        }
    }

    static func testDirectionMaskRotation() {
        for raw in 0..<16 {
            let m = DirectionMask(rawValue: UInt8(raw))
            let masked = m.rawValue & 0x0F
            check(m.rotated(quarterTurns: 4).rawValue == masked, "mask \(raw): 4-turn identity")
            check(m.rotated(quarterTurns: 0).rawValue == masked, "mask \(raw): 0-turn identity")
            var r = m
            for _ in 0..<4 { r = r.rotated(quarterTurns: 1) }
            check(r.rawValue == masked, "mask \(raw): 1×4 identity")
            check(m.rotated(quarterTurns: -1).rawValue == m.rotated(quarterTurns: 3).rawValue, "mask \(raw): -1 == 3")
        }
        // Bit layout N=1<<0, E=1<<1, S=1<<2, W=1<<3 → +1 turn shifts N→E→S→W.
        check(DirectionMask.north.rotated(quarterTurns: 1).rawValue == DirectionMask.east.rawValue, "north→east on +1 turn")
        check(DirectionMask.east.rotated(quarterTurns: 1).rawValue == DirectionMask.south.rawValue, "east→south on +1 turn")
        check(DirectionMask.south.rotated(quarterTurns: 1).rawValue == DirectionMask.west.rawValue, "south→west on +1 turn")
        check(DirectionMask.west.rotated(quarterTurns: 1).rawValue == DirectionMask.north.rawValue, "west→north on +1 turn")
    }

    /// Find the cubie whose integer position matches (x,y,z), if it exists.
    static func cubieIndex(_ m: CubeModel, _ x: Int, _ y: Int, _ z: Int) -> Int? {
        m.cubies.firstIndex { $0.position == SIMD3<Int32>(Int32(x), Int32(y), Int32(z)) }
    }

    /// Bandaging (M13): a slice twist is legal iff every bonded group is entirely inside or entirely
    /// outside the rotating slice. A group that straddles the slice would be torn → refused.
    static func testBandagedLegality(size n: Int) {
        let m = CubeModel(size: n)
        // No bonds → every slice is legal.
        for axis in 0..<3 {
            for index in 0..<n {
                check(m.canRotateSlice(axis: axis, index: index), "size \(n): no bonds → (\(axis),\(index)) legal")
            }
        }
        // Bond two cubies that share the z=n-1 and y=0 slices but differ in x — a straddle across x.
        guard let a = cubieIndex(m, 0, 0, n - 1), let b = cubieIndex(m, n - 1, 0, n - 1) else {
            check(false, "size \(n): bond cubies not found"); return
        }
        m.addBond([a, b])
        // Slices holding BOTH bonded cubies → legal (the whole bond moves together).
        check(m.canRotateSlice(axis: 2, index: n - 1), "size \(n): z=n-1 holds both → legal")
        check(m.canRotateSlice(axis: 1, index: 0),     "size \(n): y=0 holds both → legal")
        // Slices holding exactly ONE → illegal (would tear the bond).
        check(!m.canRotateSlice(axis: 0, index: 0),     "size \(n): x=0 holds only a → illegal")
        check(!m.canRotateSlice(axis: 0, index: n - 1), "size \(n): x=n-1 holds only b → illegal")
        // Slices holding NEITHER → legal.
        check(m.canRotateSlice(axis: 2, index: 0), "size \(n): z=0 holds neither → legal")
        // The bond survives a full 4-turn cycle of a legal (fully-in) slice: indices stay valid,
        // positions restore, and the same straddle is illegal again.
        for _ in 0..<4 { m.applySliceRotation(axis: 2, index: n - 1, angle: -.pi / 2) }
        check(!m.canRotateSlice(axis: 0, index: 0),    "size \(n): after 4 turns, x=0 straddle still illegal")
        check(m.canRotateSlice(axis: 2, index: n - 1), "size \(n): after 4 turns, z=n-1 still legal")

        // M16.1 groundwork — removeBond (understanding undoes a lock). Both bonds straddle the
        // x=0 slice, so it only becomes legal when BOTH are gone: removing one leaves the other
        // enforcing (bonds are independent), removing the second restores legality, and a repeat
        // remove is a no-op.
        guard let c = cubieIndex(m, 0, n - 1, 0), let d = cubieIndex(m, n - 1, n - 1, 0) else {
            check(false, "size \(n): second-bond cubies not found"); return
        }
        m.addBond([c, d])   // second, independent bond — also straddles x (c at x=0, d at x=n-1)
        check(m.removeBond(containing: a), "size \(n): removeBond finds bond 1 via a member")
        check(!m.canRotateSlice(axis: 0, index: 0), "size \(n): x=0 still illegal — bond 2 untouched")
        check(m.removeBond(containing: c), "size \(n): removeBond finds bond 2 via a member")
        check(m.canRotateSlice(axis: 0, index: 0), "size \(n): x=0 legal once fully unbonded")
        check(!m.removeBond(containing: a), "size \(n): repeat remove is a no-op")
    }

    static func testPropRotation() {
        // A placed prop must stay glued to its tile through a slice rotation: `Prop.rotate`
        // rotates the sub-cell offset and facing in the DirectionMask.rotated sense (N→E).
        // Exhaustively check the round-trip / identity laws over every sub-cell and facing.
        for subRow in 0...2 {
            for subCol in 0...2 {
                for facing in Heading8.allCases {
                    let base = Prop(kind: .topiary, subRow: subRow, subCol: subCol, facing: facing)
                    let tag = "(\(subRow),\(subCol),\(facing))"

                    // 0-turn is a no-op.
                    var p0 = base; p0.rotate(quarterTurns: 0)
                    check(p0.subRow == subRow && p0.subCol == subCol && p0.facing == facing,
                          "prop 0-turn identity \(tag)")

                    // Four single quarter-turns restore the prop exactly.
                    var pFour = base; for _ in 0..<4 { pFour.rotate(quarterTurns: 1) }
                    check(pFour.subRow == subRow && pFour.subCol == subCol && pFour.facing == facing,
                          "prop 1×4 identity \(tag) → (\(pFour.subRow),\(pFour.subCol),\(pFour.facing))")

                    // A single call of 4 is the same identity.
                    var pQuad = base; pQuad.rotate(quarterTurns: 4)
                    check(pQuad.subRow == subRow && pQuad.subCol == subCol && pQuad.facing == facing,
                          "prop 4-in-one identity \(tag)")

                    // −1 turn equals +3 turns (and neither escapes the 3×3 grid).
                    var pNeg = base; pNeg.rotate(quarterTurns: -1)
                    var pPos = base; pPos.rotate(quarterTurns: 3)
                    check(pNeg.subRow == pPos.subRow && pNeg.subCol == pPos.subCol && pNeg.facing == pPos.facing,
                          "prop −1 == 3 \(tag)")
                    check((0...2).contains(pNeg.subRow) && (0...2).contains(pNeg.subCol),
                          "prop stays in 3×3 grid \(tag) → (\(pNeg.subRow),\(pNeg.subCol))")
                }
            }
        }

        // Rotation sense: the centre sub-cell is fixed; +1 quarter-turn carries the north
        // sub-cell (0,1) to the east (1,2) and advances facing N→E — matching DirectionMask.
        var centre = Prop(kind: .chest, subRow: 1, subCol: 1, facing: .n); centre.rotate(quarterTurns: 1)
        check(centre.subRow == 1 && centre.subCol == 1, "prop centre fixed under rotation")
        check(centre.facing == .e, "prop centre facing N→E on +1 turn")

        var north = Prop(kind: .chest, subRow: 0, subCol: 1, facing: .n); north.rotate(quarterTurns: 1)
        check(north.subRow == 1 && north.subCol == 2, "prop north sub-cell → east (got \(north.subRow),\(north.subCol))")
        check(north.facing == .e, "prop north facing N→E on +1 turn")
    }

    // MARK: - M14b placement invariants (R2.5)

    static func col3(_ m: float4x4, _ i: Int) -> SIMD3<Float> {
        let c = i == 0 ? m.columns.0 : i == 1 ? m.columns.1 : i == 2 ? m.columns.2 : m.columns.3
        return SIMD3(c.x, c.y, c.z)
    }

    static func approx(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
    }

    /// R2.5a — the rest placement is the flat cube placement, independently re-derived:
    /// basis = (tangent, bitangent, normal), center = normal·halfN + tangent·colF + bitangent·rowF.
    /// Also: `inflatedPlacement` at roundness 0 == rest basis with the origin offset in-plane,
    /// and the rest frame must NOT change with roundness (it is the pre-inflation frame).
    static func testRestPlacement(size n: Int) {
        let m = CubeModel(size: n)
        let halfN = Float(n) / 2.0
        let spacing = m.worldScale.cellSpacing
        for face in CubeFace.allCases {
            for row in 0..<n {
                for col in 0..<n {
                    let colF = (Float(col) + 0.5 - halfN) * spacing
                    let rowF = (Float(row) + 0.5 - halfN) * spacing
                    let center = face.normal * halfN + face.tangent * colF + face.bitangent * rowF

                    m.roundness = 0
                    let rest = m.restMatrix(face: face, row: row, col: col)
                    check(approx(col3(rest, 0), face.tangent, 1e-6) &&
                          approx(col3(rest, 1), face.bitangent, 1e-6) &&
                          approx(col3(rest, 2), face.normal, 1e-6),
                          "size \(n): rest basis (\(face),\(row),\(col))")
                    check(approx(col3(rest, 3), center, 1e-5), "size \(n): rest center (\(face),\(row),\(col))")

                    // roundness must not leak into the rest frame
                    m.roundness = 0.7
                    let restR = m.restMatrix(face: face, row: row, col: col)
                    check(approx(col3(restR, 3), center, 1e-5) && approx(col3(restR, 2), face.normal, 1e-6),
                          "size \(n): rest is roundness-independent (\(face),\(row),\(col))")

                    // flat inflatedPlacement == rest basis + in-plane offset origin
                    m.roundness = 0
                    let off = m.inflatedPlacement(face: face, row: row, col: col, localX: 0.25, localY: -0.4)
                    let expected = center + face.tangent * 0.25 + face.bitangent * (-0.4)
                    check(approx(col3(off, 0), face.tangent, 1e-6) && approx(col3(off, 2), face.normal, 1e-6),
                          "size \(n): flat placement basis (\(face),\(row),\(col))")
                    check(approx(col3(off, 3), expected, 1e-5), "size \(n): flat placement origin (\(face),\(row),\(col))")
                }
            }
        }
    }

    /// R2.5b — footprint continuity: adjacent tiles' shared-edge placements coincide (position AND
    /// frame) at several roundness values. This is the property that makes the curved surface
    /// seamless — tile A's east edge and its east neighbour's west edge are the SAME cube point,
    /// so they must inflate to the same place with the same local frame.
    static func testFootprintContinuity(size n: Int) {
        let m = CubeModel(size: n)
        let h = m.worldScale.cellSpacing / 2
        for r: Float in [0.0, 0.3, 1.0] {
            m.roundness = r
            for face in CubeFace.allCases {
                for row in 0..<n {
                    for col in 0..<(n - 1) {   // col-adjacent pair, shared edge at +localX / −localX
                        let a = m.inflatedPlacement(face: face, row: row, col: col, localX: h, localY: 0.2)
                        let b = m.inflatedPlacement(face: face, row: row, col: col + 1, localX: -h, localY: 0.2)
                        check(approx(col3(a, 3), col3(b, 3), 1e-4), "size \(n) r=\(r): col-seam pos (\(face),\(row),\(col))")
                        check(approx(col3(a, 0), col3(b, 0), 1e-4) && approx(col3(a, 2), col3(b, 2), 1e-4),
                              "size \(n) r=\(r): col-seam frame (\(face),\(row),\(col))")
                    }
                }
                for row in 0..<(n - 1) {
                    for col in 0..<n {         // row-adjacent pair, shared edge at +localY / −localY
                        let a = m.inflatedPlacement(face: face, row: row, col: col, localX: -0.3, localY: h)
                        let b = m.inflatedPlacement(face: face, row: row + 1, col: col, localX: -0.3, localY: -h)
                        check(approx(col3(a, 3), col3(b, 3), 1e-4), "size \(n) r=\(r): row-seam pos (\(face),\(row),\(col))")
                        check(approx(col3(a, 2), col3(b, 2), 1e-4), "size \(n) r=\(r): row-seam normal (\(face),\(row),\(col))")
                    }
                }
            }
            // Cross-face: +Z's east edge meets +X's west edge at the same cube point — positions
            // must coincide there too (frames legitimately differ; each face has its own basis).
            for row in 0..<n {
                let a = m.inflatedPlacement(face: .positiveZ, row: row, col: n - 1, localX: h, localY: 0)
                let b = m.inflatedPlacement(face: .positiveX, row: row, col: 0, localX: -h, localY: 0)
                check(approx(col3(a, 3), col3(b, 3), 1e-4), "size \(n) r=\(r): cross-face edge pos row \(row)")
            }
        }
    }

    /// R2.5d — golden values for the Cobb cube→sphere map. These constants were computed
    /// independently (double-precision, outside this codebase) and double as the spec that BOTH
    /// twin implementations must match: `CubeModel.inflatedUnitPoint` (tested here) and
    /// `m14bInflate` in Shaders.metal (same math on the GPU; guarded by review + this spec).
    static func testInflateGoldens() {
        let m = CubeModel(size: 3)
        let cases: [(p: SIMD3<Float>, r: Float, want: SIMD3<Float>)] = [
            (SIMD3( 1.0, 0.5, -0.25), 0.5, SIMD3( 0.9606947,  0.4249256, -0.2096254)),
            (SIMD3( 1.0, 0.5, -0.25), 1.0, SIMD3( 0.9213893,  0.3498512, -0.1692508)),
            (SIMD3( 0.2, -0.8,  0.6), 0.5, SIMD3( 0.1759474, -0.7588426,  0.5452917)),
            (SIMD3( 0.2, -0.8,  0.6), 1.0, SIMD3( 0.1518947, -0.7176852,  0.4905833)),
            (SIMD3( 1.0,  1.0,  1.0), 1.0, SIMD3( 0.5773503,  0.5773503,  0.5773503)),  // corner → 1/√3
            (SIMD3( 1.0,  1.0,  1.0), 0.5, SIMD3( 0.7886751,  0.7886751,  0.7886751)),
            (SIMD3( 0.0,  0.0,  1.0), 1.0, SIMD3( 0.0,        0.0,        1.0)),        // face centre fixed
            (SIMD3(-0.7,  0.3,  1.0), 0.5, SIMD3(-0.5937468,  0.2470180,  0.9256466)),
            (SIMD3(-0.7,  0.3,  1.0), 1.0, SIMD3(-0.4874936,  0.1940361,  0.8512931)),
        ]
        for c in cases {
            m.roundness = c.r
            let got = m.inflatedUnitPoint(c.p)
            check(approx(got, c.want, 5e-6), "inflate golden p=\(c.p) r=\(c.r): got \(got), want \(c.want)")
        }
        // r == 0 is the exact identity (the guard path).
        m.roundness = 0
        let p = SIMD3<Float>(0.37, -0.91, 1.0)
        check(m.inflatedUnitPoint(p) == p, "inflate r=0 identity")
    }

    // MARK: - M15.1 interior-world invariants

    /// Interior placement: the tile sits on the same face plane but is seen from inside — basis
    /// (tangent, −bitangent, −normal), right-handed, with the row *placement* mirrored to match,
    /// so tile-local geometry stays aligned with grid logic.
    static func testInteriorPlacement(size n: Int) {
        let m = CubeModel(worldScale: WorldScale(cubeSize: n, interior: true))
        let halfN = Float(n) / 2.0
        let spacing = m.worldScale.cellSpacing
        for face in CubeFace.allCases {
            for row in [0, n / 2, n - 1] {
                for col in [0, n / 2, n - 1] {
                    let colF = (Float(col) + 0.5 - halfN) * spacing
                    let rowF = (Float(row) + 0.5 - halfN) * spacing
                    let center = face.normal * halfN + face.tangent * colF - face.bitangent * rowF
                    let rest = m.restMatrix(face: face, row: row, col: col)
                    check(approx(col3(rest, 0), face.tangent, 1e-6) &&
                          approx(col3(rest, 1), -face.bitangent, 1e-6) &&
                          approx(col3(rest, 2), -face.normal, 1e-6),
                          "size \(n): interior basis (\(face),\(row),\(col))")
                    check(approx(col3(rest, 3), center, 1e-5), "size \(n): interior center (\(face),\(row),\(col))")
                    // Right-handed: cross(right, up) == forward (det +1 — winding/culling safe).
                    let cr = cross(col3(rest, 0), col3(rest, 1))
                    check(approx(cr, col3(rest, 2), 1e-6), "size \(n): interior handedness (\(face),\(row),\(col))")
                }
            }
        }
    }

    /// Edge-crossing continuity, pinned to WORLD positions: walking off a border cell arrives at a
    /// cell whose shared-edge midpoint is the SAME world point. Run on the exterior first (which
    /// validates the test against the proven table), then on the interior (which validates the
    /// M15.1 conjugated crossing). Also: interior crossings round-trip home.
    static func testEdgeContinuity(size n: Int, interior: Bool) {
        let m = CubeModel(worldScale: WorldScale(cubeSize: n, interior: interior))
        let half = m.worldScale.cellSpacing / 2
        let tag = interior ? "interior" : "exterior"

        // World direction of a grid heading on a face = ± the placement basis columns
        // (grid north = tile-local −y = −up; east = +right) — orientation handled by restMatrix.
        func gridDirWorld(_ rest: float4x4, _ d: SurfaceDirection) -> SIMD3<Float> {
            switch d {
            case .north: return -col3(rest, 1)
            case .south: return  col3(rest, 1)
            case .east:  return  col3(rest, 0)
            case .west:  return -col3(rest, 0)
            }
        }

        for face in CubeFace.allCases {
            for dir in SurfaceDirection.allCases {
                for i in [0, n / 2, n - 1] {
                    let (row, col) = borderCell(dir: dir, i: i, n: n)
                    let rest1 = m.restMatrix(face: face, row: row, col: col)
                    let edge1 = col3(rest1, 3) + gridDirWorld(rest1, dir) * half

                    let x = m.edgeCrossing(face: face, direction: dir, row: row, col: col)
                    let rest2 = m.restMatrix(face: x.face, row: x.row, col: x.col)
                    let edge2 = col3(rest2, 3) + gridDirWorld(rest2, x.facing.opposite) * half
                    check(approx(edge1, edge2, 1e-4),
                          "size \(n) \(tag): edge continuity (\(face),\(dir),\(row),\(col)) → (\(x.face),\(x.row),\(x.col))")

                    // Round-trip: cross back through the edge you came in by.
                    let back = m.edgeCrossing(face: x.face, direction: x.facing.opposite, row: x.row, col: x.col)
                    check(back.face == face && back.row == row && back.col == col,
                          "size \(n) \(tag): round-trip (\(face),\(dir),\(row),\(col))")
                }
            }
        }
    }

    /// R2.16 — the hard size cap: WorldScale clamps cubeSize to maxSupportedSize (25), so a world
    /// bigger than the renderer's instance buffers can hold is impossible to construct.
    static func testSizeCap() {
        check(WorldScale(cubeSize: 99).cubeSize == WorldScale.maxSupportedSize, "size 99 clamps to cap")
        check(WorldScale(cubeSize: 25).cubeSize == 25, "cap itself passes through")
        check(WorldScale(cubeSize: 7).cubeSize == 7, "normal sizes untouched")
        check(WorldScale(cubeSize: 1).cubeSize == 2, "floor clamps to 2")
        check(CubeModel(size: 99).size == WorldScale.maxSupportedSize, "CubeModel inherits the cap")
    }
}
