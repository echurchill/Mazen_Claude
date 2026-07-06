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
        let sizes = [3, 5, 7, 9]
        for n in sizes {
            testProjectionBijection(size: n)
            testGridWorldConsistency(size: n)
            testEdgeCrossingRoundTrip(size: n)
            testSliceRotation(size: n)
        }
        testDirectionMaskRotation()
        testPropRotation()

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
}
