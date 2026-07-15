import Foundation
import Metal
import simd
import ImageIO   // CGImageSource — probing a texture PNG for an alpha channel (cutout detection)
import ModelIO

/// One sub-mesh's resolved diffuse + whether it needs alpha-cutout (its PNG carries an alpha
/// channel — Quaternius leaves/flowers do; rock/grass don't). Drives materialID 20 vs 11.
struct SubmeshMaterial {
    let diffuse: MTLTexture?
    let cutout: Bool
}

/// One imported model placed on the cube (M12-D asset registry).
struct ImportedProp {
    let mesh: AssetMesh
    let diffuse: MTLTexture?                // textured (one draw, materialID 11); nil = per-sub-mesh flat colours (materialID 10)
    let faceOffset: (row: Int, col: Int)   // tile offset from the +Z face centre
    let target: Float                       // fit the widest dimension to this many units
    let yUp: Bool                           // OBJ kits import Y-up; USD props Z-up
    var name: String = ""                   // gallery HUD label
    var galleryOnly: Bool = false           // skip the overworld decoration stamp (eval-grid props)
    /// Per-sub-mesh material, parallel to `mesh.submeshes` — for kits whose sub-meshes each want a
    /// DIFFERENT texture (a Quaternius tree = bark + leaves). Empty ⇒ use `diffuse` / flat colours.
    /// A nil diffuse falls back to that sub-mesh's flat `Kd` colour.
    var submeshMaterials: [SubmeshMaterial] = []
}

/// One piece of the imported modular house, positioned in a quarter's tile-local frame
/// (M12-E). All pieces of a quarter share that quarter's `.houseCorner` Prop anchor (tile
/// matrix + facing), so they ride slice rotations together and split as a unit — reusing the
/// exact machinery that already carries the procedural house.
struct HouseKitPiece {
    let mesh: AssetMesh
    let local: float4x4   // Y-up→Z-up, non-uniform scale, and edge placement within the tile
}

/// Loading + world-stamping of the imported 3D assets — the decoration props (M12-D) and the
/// modular house kit (M12-E). (R2.8 — extracted verbatim from Renderer's init; logic unchanged.
/// The per-frame placement of these assets stays in Renderer.updateAssetInstances.)
enum AssetRegistry {

    /// Tile-local width the imported house occupies per quarter. 1.0 puts the walls on the tile's
    /// outer edges → the four quarters form a full 2×2 room the player can walk inside (M12-E).
    /// `houseWallHeight` is the wall height in tile-Z (the procedural hip roof rests on top of it).
    static let houseQuarterWidth: Float = 1.0
    static let houseWallHeight: Float = 0.30

    /// Gallery normalisation: every Quaternius model is fitted to this many units, so each one reads
    /// equally in the catalogue. (The birch was hand-tuned to 0.9 and looked right — this matches it.)
    static let galleryTarget: Float = 0.85

    /// Does this texture actually USE its alpha — i.e. does it need cutout?
    ///
    /// The presence of an alpha channel proves nothing: Quaternius' `BirchTree_Bark.png` carries a
    /// fully-opaque one, so testing the channel alone would push solid bark down the cutout path
    /// (defeating early-Z, and masking real problems as we scale to the rest of the pack). So decode
    /// and look for genuinely transparent texels. Run once per unique texture, then cached.
    static func usesAlpha(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
        switch img.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: break
        default: return false            // no alpha channel at all — nothing to cut out
        }
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return false }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return false }
        for i in stride(from: 3, to: buf.count, by: 4) where buf[i] < 128 { return true }
        return false
    }

    /// Load the whole registry: decoration props + the two house-quarter assemblies.
    /// (Dev absolute path — these get bundled for shipping later; see roadmap "shipping hygiene".)
    static func loadAll(device: MTLDevice) -> (props: [ImportedProp], house: [HouseKitPiece], houseDoor: [HouseKitPiece]) {
        let modelsRoot = "/Volumes/Code Work/xCode work/Mazen_Claude/Mazen_Models"
        // Textured USD prop (one diffuse map, Z-up).
        func loadProp(_ dir: String, _ diffuse: String, _ off: (Int, Int), _ target: Float) -> ImportedProp? {
            guard let mesh = AssetMesh(url: URL(fileURLWithPath: "\(modelsRoot)/\(dir)/\(dir).usdc"), device: device) else {
                print("[AssetRegistry] prop FAILED to load: \(dir)"); return nil
            }
            let diff = TextureLoader.loadTextureFromFile(url: URL(fileURLWithPath: "\(modelsRoot)/\(dir)/textures/\(diffuse).jpg"), device: device, srgb: true)
            return ImportedProp(mesh: mesh, diffuse: diff, faceOffset: off, target: target, yUp: false)
        }
        // Texture-less OBJ kit piece — flat per-material colours, Y-up.
        func loadSolid(_ relPath: String, _ off: (Int, Int), _ target: Float) -> ImportedProp? {
            guard let mesh = AssetMesh(url: URL(fileURLWithPath: "\(modelsRoot)/\(relPath)"), device: device) else {
                print("[AssetRegistry] solid prop FAILED: \(relPath)"); return nil
            }
            return ImportedProp(mesh: mesh, diffuse: nil, faceOffset: off, target: target, yUp: true)
        }
        // Textured USD props at the plaza centre + its diagonal neighbours; solid-colour OBJ
        // temple pieces at the edge-middle tiles.
        let props: [ImportedProp] = [
            // loadProp("stone_fire_pit_2k",  "stone_fire_pit_diff_2k",     ( 0,  0), 0.35),  // removed for now (Eddie)
            loadProp("horse_statue_01_2k",    "horse_statue_01_diff_2k",    (-1, -1), 0.60),
            loadProp("tree_stump_01_2k",      "tree_stump_01_diff_2k",      (-1,  1), 0.30),
            loadProp("tree_stump_02_2k",      "tree_stump_02_diff_2k",      ( 1, -1), 0.30),
            // loadProp("old_military_crate_2k", "old_military_crate_diff_2k", ( 1,  1), 0.32),  // removed for now (Eddie)
            // loadSolid("Modular Temple/Pillar_Large_Base.obj", (-1, 0), 0.55),  // hidden for now — blocked the moon-door path (Eddie)
            loadSolid("Modular Temple/Prop_Flag_Sun.obj",     ( 0, -1), 0.50),
            loadSolid("Modular Temple/Prop_Flag_Moon.obj",    ( 0,  1), 0.50),
            loadSolid("Modular Temple/Prop_Vase.obj",         ( 1,  1), 0.28),   // moved off the temple-door path (Eddie)
        ].compactMap { $0 }

        // M20 — a sampling of the Quaternius Ultimate Stylized Nature Pack (CC0). Gallery-only, so
        // they don't clutter the overworld. See `loadNature` for why these come from USD, not OBJ.
        let natureDir = "Quaternius Ultimate Stylized Nature Pack"
        var texCache: [String: SubmeshMaterial] = [:]
        /// Load a texture the USD itself bound, noting whether it needs alpha-cutout. Cached — many
        /// models share one leaf/flower map.
        func natureTexture(_ url: URL) -> SubmeshMaterial {
            if let hit = texCache[url.path] { return hit }
            // Decide cutout FIRST: the loader needs it, because a cut-out texture must be
            // un-premultiplied and colour-dilated (see TextureLoader.loadTextureFromFile).
            let isCutout = Self.usesAlpha(url)
            let tex = TextureLoader.loadTextureFromFile(url: url, device: device, srgb: true, cutout: isCutout)
            let mat = SubmeshMaterial(diffuse: tex, cutout: tex != nil && isCutout)
            texCache[url.path] = mat
            return mat
        }
        /// Loaded from USD (exported from the pack's per-model .blend files via Blender), NOT the
        /// shipped OBJ. The OBJ/MTL is the pack's lossiest export: it carries no `map_Kd`, so we had
        /// to guess textures by material name plus a hand-written exception table (Rock→"Rocks.png",
        /// Blender's unnamed "None"→"Grass.png"), and it collapsed some multi-material models. The
        /// USD carries a real UsdPreviewSurface material→texture binding that ModelIO resolves to an
        /// absolute URL — so the asset tells us its texture and all that guessing is gone.
        /// Z-up (Blender's axes, like our other USD props) ⇒ yUp: false.
        ///
        /// Every model is normalised to the same `galleryTarget` rather than kept at true relative
        /// scale: this is a catalogue, so each one should read equally well (at true scale a flower
        /// next to a birch is a speck). Real relative size is the *world's* job, not the gallery's.
        func loadNature(_ file: String) -> ImportedProp? {
            guard let mesh = AssetMesh(url: URL(fileURLWithPath: "\(modelsRoot)/\(natureDir)/USD/\(file).usdc"), device: device) else {
                print("[AssetRegistry] nature prop FAILED: \(file)"); return nil
            }
            let mats = mesh.submeshes.map { sm in
                sm.baseColorURL.map { natureTexture($0) } ?? SubmeshMaterial(diffuse: nil, cutout: false)
            }
            return ImportedProp(mesh: mesh, diffuse: nil, faceOffset: (0, 0), target: galleryTarget, yUp: false,
                                name: "Quaternius \(file)", galleryOnly: true, submeshMaterials: mats)
        }
        // Load EVERY exported model, enumerated from disk so the gallery tracks the USD folder
        // without a hand-maintained list (re-run Tools/export_quaternius_usd.py to refresh it).
        let usdDir = "\(modelsRoot)/\(natureDir)/USD"
        let natureFiles = ((try? FileManager.default.contentsOfDirectory(atPath: usdDir)) ?? [])
            .filter { $0.hasSuffix(".usdc") }
            .map { String($0.dropLast(5)) }
            .sorted()
        let nature: [ImportedProp] = natureFiles.compactMap { loadNature($0) }
        if nature.count != natureFiles.count {
            print("[AssetRegistry] nature: \(nature.count)/\(natureFiles.count) models loaded")
        }

        // M12-E: imported modular house. Load the kit's solid-colour OBJ pieces and assemble one
        // canonical quarter (authored for facing.n — two outer walls on the −X/−Y tile edges +
        // floor). The four `.houseCorner` props stamped in CubeModel place/orient the quarters and
        // carry them through slice rotations, so the building splits at the tile seams for free.
        func loadKit(_ name: String) -> AssetMesh? {
            AssetMesh(url: URL(fileURLWithPath: "\(modelsRoot)/modular_house_collection/\(name).obj"), device: device)
        }
        var house: [HouseKitPiece] = []
        var houseDoor: [HouseKitPiece] = []
        if let wall = loadKit("Structure_Exterior_Wall_Straight") {
            house     = buildHouseQuarter(wall: wall, front: false)
            houseDoor = buildHouseQuarter(wall: wall, front: true)
        } else {
            print("[AssetRegistry] house kit FAILED to load")
        }
        return (props + nature, house, houseDoor)
    }

    /// Stamp the imported decorations into a world as `.importedAsset` Props (one per registry entry,
    /// at its `faceOffset` tile on +Z, `state` = registry index). As Props on facelets they ride
    /// slice rotations and get carried like any other prop — instead of the old static placement.
    static func stamp(_ props: [ImportedProp], into gs: GameState) {
        let n = gs.cubeModel.size
        for (assetID, p) in props.enumerated() {
            if p.galleryOnly { continue }   // eval-grid props are placed only in the gallery world
            let row = n / 2 + p.faceOffset.row
            let col = n / 2 + p.faceOffset.col
            if let (ci, fi) = gs.cubeModel.faceletAt(face: .positiveZ, row: row, col: col) {
                gs.cubeModel.cubies[ci].facelets[fi].props.append(
                    Prop(kind: .importedAsset, subRow: 1, subCol: 1, facing: .n, state: assetID))
            }
        }
    }

    /// Normalize a kit module (1×1 Y-up, arbitrary authored size) to the quarter: scale its length
    /// (authored X) to `bw` and its height (authored Y) to `hS`, recentre it on its length/thickness
    /// with the base at 0, then rotate Y-up → tile-Z-up. The result is a piece lying along tile X,
    /// centred at the origin, standing in +Z — ready to slide onto a perimeter edge. Handles the
    /// wall (1.0 wide, 1.0 tall) and the taller/narrower door (0.8 wide, 1.9 tall) uniformly.
    private static func kitBase(_ mesh: AssetMesh, bw: Float, hS: Float) -> float4x4 {
        let s = mesh.size
        let lenScale = s.x > 0 ? bw / s.x : bw
        let htScale  = s.y > 0 ? hS / s.y : hS
        let up = float4x4.rotation(radians: .pi / 2, axis: SIMD3(1, 0, 0))
        let recenter = float4x4.translation(-mesh.center.x, -mesh.boundsMin.y, -mesh.center.z)
        return up * float4x4.scale(lenScale, htScale, lenScale) * recenter
    }

    /// Assemble one imported house quarter (M12-E) in a tile's local frame, authored for `facing.n`.
    /// Each quarter fills its full tile, contributing two of the building's perimeter walls (an L on
    /// the −X/−Y outer edges). The four `.houseCorner` props' facings (n/e/w/s) rotate this into the
    /// four corners, so the L's close a full 2×2 room; the procedural hip roof (TileMeshLibrary) caps
    /// it. The `front` quarter omits its front wall, leaving an open entrance aligned with the plaza
    /// opening. Plain imported walls only — a plain box stretches cleanly to fill the big tile,
    /// unlike the tall window/door modules which squash. No floor slab (the tile already has one).
    private static func buildHouseQuarter(wall: AssetMesh, front: Bool) -> [HouseKitPiece] {
        let floorY: Float = 0.001
        let bw = houseQuarterWidth
        let hS = houseWallHeight
        let c: Float = 0.5      // shared 2×2 centre corner in tile-local (facing.n → +X,+Y)
        let lift = float4x4.translation(0, 0, floorY)
        let rotZ90 = float4x4.rotation(radians: .pi / 2, axis: SIMD3(0, 0, 1))
        // `kitBase` leaves a wall piece centred on tile X (length bw) and Y (thickness), base at Z=0.
        // Slide it onto a perimeter edge: the −Y edge runs along X; the −X edge is rotated to run Y.
        let onMinusY = lift * float4x4.translation(c - bw / 2, c - bw, 0) * kitBase(wall, bw: bw, hS: hS)
        let onMinusX = lift * float4x4.translation(c - bw, c - bw / 2, 0) * rotZ90 * kitBase(wall, bw: bw, hS: hS)
        var pieces = [HouseKitPiece(mesh: wall, local: onMinusX)]   // side wall (always)
        if !front { pieces.append(HouseKitPiece(mesh: wall, local: onMinusY)) }   // front wall, unless this is the entrance
        return pieces
    }
}
