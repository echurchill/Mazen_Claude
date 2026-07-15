import Foundation
import Metal
import simd

/// One imported model placed on the cube (M12-D asset registry).
struct ImportedProp {
    let mesh: AssetMesh
    let diffuse: MTLTexture?                // textured (one draw, materialID 11); nil = per-sub-mesh flat colours (materialID 10)
    let faceOffset: (row: Int, col: Int)   // tile offset from the +Z face centre
    let target: Float                       // fit the widest dimension to this many units
    let yUp: Bool                           // OBJ kits import Y-up; USD props Z-up
    var name: String = ""                   // gallery HUD label
    var galleryOnly: Bool = false           // skip the overworld decoration stamp (eval-grid props)
    /// Per-sub-mesh diffuse, parallel to `mesh.submeshes` — for kits whose sub-meshes each want a
    /// DIFFERENT texture (a Quaternius tree = bark + leaves). Empty ⇒ use `diffuse` / flat colours.
    /// A nil entry falls back to that sub-mesh's flat `Kd` colour.
    var submeshDiffuse: [MTLTexture?] = []
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

        // M20 — a sampling of the Quaternius Ultimate Stylized Nature Pack (CC0), loaded straight from
        // its OBJ/ folder (no conversion needed). Gallery-only so they don't clutter the overworld.
        //
        // Texturing: the pack's `.mtl` files ship NO `map_Kd` — just a flat grey `Kd`. Quaternius
        // instead expects the material NAME to name the texture ("BirchTree_Bark" →
        // Textures/BirchTree_Bark.png), so resolve each sub-mesh's texture by its material name and
        // hand them over per-sub-mesh (a tree = bark + leaves, two different maps). Textures are
        // shared across models (many trees reuse one leaf map), so cache by name. A name that has no
        // matching PNG just falls back to that sub-mesh's flat colour.
        let natureDir = "Quaternius Ultimate Stylized Nature Pack"
        var texCache: [String: MTLTexture?] = [:]
        func natureTexture(_ materialName: String) -> MTLTexture? {
            guard !materialName.isEmpty else { return nil }
            if let hit = texCache[materialName] { return hit }
            let url = URL(fileURLWithPath: "\(modelsRoot)/\(natureDir)/Textures/\(materialName).png")
            let tex = TextureLoader.loadTextureFromFile(url: url, device: device, srgb: true)
            texCache[materialName] = tex
            return tex
        }
        // `fallbackTex` names the texture for models the name-match can't resolve — the convention
        // isn't universal: Rock_1's material is "Rock" but the file is "Rocks.png", and Grass_Large's
        // material is Blender's unnamed default "None". Only needed for those exceptions.
        func loadNature(_ file: String, _ label: String, _ target: Float, fallbackTex: String? = nil) -> ImportedProp? {
            guard let mesh = AssetMesh(url: URL(fileURLWithPath: "\(modelsRoot)/\(natureDir)/OBJ/\(file).obj"), device: device) else {
                print("[AssetRegistry] nature prop FAILED: \(file)"); return nil
            }
            let texes = mesh.submeshes.map { sm in
                natureTexture(sm.materialName) ?? fallbackTex.flatMap { natureTexture($0) }
            }
            return ImportedProp(mesh: mesh, diffuse: nil, faceOffset: (0, 0), target: target, yUp: true,
                                name: label, galleryOnly: true, submeshDiffuse: texes)
        }
        let nature: [ImportedProp] = [
            loadNature("BirchTree_1",    "Quaternius BirchTree_1",  0.90),
            loadNature("Bush_Large",     "Quaternius Bush_Large",   0.45),
            loadNature("Rock_1",         "Quaternius Rock_1",       0.40, fallbackTex: "Rocks"),
            loadNature("Grass_Large",    "Quaternius Grass_Large",  0.35, fallbackTex: "Grass"),
            loadNature("Flower_1_Clump", "Quaternius Flower_1_Clump", 0.35),
            loadNature("Plant_1",        "Quaternius Plant_1",      0.35),
        ].compactMap { $0 }

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
