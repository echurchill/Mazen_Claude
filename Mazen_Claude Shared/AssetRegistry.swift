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
    /// Stand this model ON ITS HEAD. The Cyberpunk kit's platform sections are authored as things
    /// you walk on: a broad flat deck with all the trusses, pipes and vents hung beneath it. Placed
    /// the right way up on a surface, the deck lies on the ground and every interesting face is
    /// buried in it. Inverted, the deck beds down flat and the machinery it carries is what you see
    /// — which is precisely what Scene 6's underside is (Eddie, 2026-08-01).
    var inverted: Bool = false
    /// Lay the model DOWN rather than standing it up. The Cyberpunk cables are authored hanging from
    /// a platform's underside — long in −Y — so the usual Y-up rotation stands them on end as poles
    /// (Eddie: "Cable_Small should be laying down on the ground not pointing up"). Skipping that
    /// rotation puts their length along the ground.
    var laidFlat: Bool = false
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

    // (Cutout detection — "does this texture actually USE its alpha?" — lives in
    //  TextureLoader.loadAssetTexture now, sharing the load's single decode. The criterion is
    //  unchanged: any texel below the 0.5 threshold; a merely-present-but-opaque alpha channel,
    //  like BirchTree_Bark.png's, stays on the opaque fast path.)

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
            // tree_stump_01/02 removed (Eddie) — folders no longer used.
            // loadProp("old_military_crate_2k", "old_military_crate_diff_2k", ( 1,  1), 0.32),  // removed for now (Eddie)
            // loadSolid("Modular Temple/Pillar_Large_Base.obj", (-1, 0), 0.55),  // hidden for now — blocked the moon-door path (Eddie)
            loadSolid("Modular Temple/Prop_Flag_Sun.obj",     ( 0, -1), 0.50),
            loadSolid("Modular Temple/Prop_Flag_Moon.obj",    ( 0,  1), 0.50),
            loadSolid("Modular Temple/Prop_Vase.obj",         ( 1,  1), 0.28),   // moved off the temple-door path (Eddie)
        ].compactMap { $0 }

        // M20 — three Quaternius CC0 packs (Dungeons / Nature / Ruins), for evaluation.
        // Unlike the Stylized Nature pack these ship as FLAT-COLOUR OBJ (named Kd materials, no
        // `map_Kd`), so we load the OBJ directly — no USD/Blender step — and each sub-mesh renders
        // with its flat `Kd` colour (materialID 10). Gallery-only; each pack gets its own full-face
        // gallery world (keys 1/2/3). Y-up like all our OBJ kits. Loaded CONCURRENTLY — 290 serial
        // OBJ parses would dominate a Debug boot; each parse is independent (separate MDLAsset).
        // `texBind` optionally binds specific MATERIAL NAMES to a texture (from the pack's `texSubdir`)
        // — used to give Ruins' "overgrown" wall pieces their green foliage (their Leaf_Texture/Green
        // submeshes otherwise render flat grey). Other submeshes stay flat `Kd` (materialID 10).
        func loadFlatPack(_ packDir: String, _ prefix: String,
                          texBind: [String: String] = [:], texSubdir: String = "Textures") -> [ImportedProp] {
            let objDir = "\(modelsRoot)/\(packDir)/OBJ"
            let texDir = "\(modelsRoot)/\(packDir)/\(texSubdir)"
            var texByMat = [String: SubmeshMaterial]()   // loaded once, read-only in the parallel loop
            for (mat, file) in texBind {
                let loaded = TextureLoader.loadAssetTexture(url: URL(fileURLWithPath: "\(texDir)/\(file)"), device: device, srgb: true)
                texByMat[mat] = SubmeshMaterial(diffuse: loaded?.texture, cutout: loaded?.cutout ?? false)
            }
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: objDir)) ?? [])
                .filter { $0.hasSuffix(".obj") }.map { String($0.dropLast(4)) }.sorted()
            var out = [ImportedProp?](repeating: nil, count: files.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                let f = files[i]
                guard let mesh = AssetMesh(url: URL(fileURLWithPath: "\(objDir)/\(f).obj"), device: device) else {
                    print("[AssetRegistry] \(prefix) FAILED: \(f)"); return
                }
                let mats: [SubmeshMaterial] = texByMat.isEmpty ? [] : mesh.submeshes.map {
                    texByMat[$0.materialName] ?? SubmeshMaterial(diffuse: nil, cutout: false)
                }
                // Platform decks are the one family that wants inverting (see `inverted`).
                let flip = prefix == "Cyberpunk" && f.hasPrefix("Platform")
                let flat = prefix == "Cyberpunk" && f.hasPrefix("Cable")
                let p = ImportedProp(mesh: mesh, diffuse: nil, faceOffset: (0, 0), target: galleryTarget,
                                     yUp: true, name: "\(prefix) \(f)", galleryOnly: true,
                                     submeshMaterials: mats, inverted: flip, laidFlat: flat)
                lock.lock(); out[i] = p; lock.unlock()
            }
            let loaded = out.compactMap { $0 }
            if verboseDebugLog { print("[AssetRegistry] \(prefix): \(loaded.count)/\(files.count) models loaded") }
            return loaded
        }
        let dungeons = loadFlatPack("Dungeons Pack", "Dungeons")
        let naturePk = loadFlatPack("Nature Pack",   "Nature")
        // Quaternius' Cyberpunk Game Kit (CC0), adopted 2026-08-01 for its STRUCTURAL half only:
        // platforms, supports, rails, pipes, cables, AC units, antennae, lights. `OBJ/` holds that
        // curated subset — the pack's enemies, character and pickups are a different game, and its
        // neon signage and screens contradict the rule that meaning is read off the world's own
        // geometry and never written down. Same OBJ + flat-Kd shape as the other three packs, so it
        // needs no pipeline work.
        let cyber    = loadFlatPack("Cyberpunk Pack", "Cyberpunk")
        let ruins    = loadFlatPack("Ruins Pack",    "Ruins",
                                    texBind: ["Leaf_Texture": "Leaf_Texture.png"])   // leaf-shaped mesh → cutout leaves; "Green" left flat (solid mesh would go holey)

        // M20 — Stylized Nature MegaKit (Quaternius): a TEXTURED OBJ pack (stylized atlas + alpha
        // leaves/flowers). Its MTL `map_Kd` paths are broken Windows absolutes ("C:/X.png"), so we
        // resolve each sub-mesh's texture by FILENAME against the pack's Blends/textures folder —
        // preferring the map_Kd filename (baseColorURL), falling back to a material→file table. Cutout
        // is auto-detected from the PNG's alpha (loadAssetTexture). Y-up OBJ, gallery-only (key 4).
        let megakit: [ImportedProp] = {
            let dir = "\(modelsRoot)/Stylized Nature MegaKit"
            let objDir = "\(dir)/OBJ", texDir = "\(dir)/Blends/textures"
            let matTex: [String: String] = [
                "Bark_Birch": "Bark_BirchTree.png", "Bark_DeadTree": "Bark_DeadTree.png",
                "Bark_NormalTree": "Bark_NormalTree.png", "Bark_Pine": "Bark_PineTree.png",
                "Bark_TwistedTree": "Bark_TwistedTree.png", "Flowers": "Flowers.png", "Grass": "Grass.png",
                "Leaves": "Leaves.png", "Leaves_Birch": "Leaves_Birch_C.png",
                "Leaves_CherryBlossom": "Leaves_CherryBlossom_C.png", "Leaves_GiantPine": "Leaves_GiantPine_C.png",
                "Leaves_NormalTree": "Leaves_NormalTree_C.png", "Leaves_Pine": "Leaf_Pine_C.png",
                "Leaves_TallThick": "Leaves_TallThick_C.png", "Leaves_TwistedTree": "Leaves_TwistedTree_C.png",
                "Mushrooms": "Mushrooms.png", "PathRocks": "PathRocks_Diffuse.png", "Rocks": "Rocks_Diffuse.png"]
            func texFile(_ sm: AssetSubmesh) -> String? {
                if let u = sm.baseColorURL, FileManager.default.fileExists(atPath: "\(texDir)/\(u.lastPathComponent)") {
                    return u.lastPathComponent
                }
                return matTex[sm.materialName]
            }
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: objDir)) ?? [])
                .filter { $0.hasSuffix(".obj") }.map { String($0.dropLast(4)) }.sorted()
            var meshSlots = [AssetMesh?](repeating: nil, count: files.count)
            let mlock = NSLock()
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                if let m = AssetMesh(url: URL(fileURLWithPath: "\(objDir)/\(files[i]).obj"), device: device) {
                    mlock.lock(); meshSlots[i] = m; mlock.unlock()
                }
            }
            let meshes: [(String, AssetMesh)] = zip(files, meshSlots).compactMap { f, m in m.map { (f, $0) } }
            let uniqueTex = Array(Set(meshes.flatMap { $0.1.submeshes.compactMap { texFile($0) } }))
            var texByName = [String: SubmeshMaterial]()
            let tlock = NSLock()
            DispatchQueue.concurrentPerform(iterations: uniqueTex.count) { k in
                let loaded = TextureLoader.loadAssetTexture(url: URL(fileURLWithPath: "\(texDir)/\(uniqueTex[k])"), device: device, srgb: true)
                let mat = SubmeshMaterial(diffuse: loaded?.texture, cutout: loaded?.cutout ?? false)
                tlock.lock(); texByName[uniqueTex[k]] = mat; tlock.unlock()
            }
            return meshes.map { file, mesh in
                let mats = mesh.submeshes.map { sm in
                    texFile(sm).flatMap { texByName[$0] } ?? SubmeshMaterial(diffuse: nil, cutout: false)
                }
                return ImportedProp(mesh: mesh, diffuse: nil, faceOffset: (0, 0), target: galleryTarget, yUp: true,
                                    name: "MegaKit \(file)", galleryOnly: true, submeshMaterials: mats)
            }
        }()
        if verboseDebugLog { print("[AssetRegistry] MegaKit: \(megakit.count) models loaded") }

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
        return (props + dungeons + naturePk + ruins + megakit + cyber, house, houseDoor)
    }

    // (The old `stamp(_:into:)` demo-decoration pass was retired with the demo overworld — the home
    //  world is pastoral, and each world's stamps place their own imported props. `faceOffset` on
    //  ImportedProp is its vestige; harmless, kept to avoid touching every constructor.)

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
