# M12 — Asset Import Pipeline Plan

## Goal

Replace the M10 Phase G procedural placeholder props (topiary, obelisk, chest, modular house) with real, **textured 3D models**, by building a runtime asset-import pipeline. First art targets are CC0 [Poly Haven](https://polyhaven.com) models — tree stump, island tree, stone fire pit — plus a house model.

**Sequencing: after M9 (solar system).** M12 is largely orthogonal to the maze / navigation systems: it plugs into the M10 prop system, which was deliberately built **mesh-agnostic** (props anchor to facelets, ride slice rotations, cast/receive shadows, and are colored/scaled per-instance — none of that cares whether the mesh is procedural or imported). So M10 → M12 is a swap of *what mesh fills the slot*, not a rework.

> **Status: M12-A + M12-C ✅ (2026-07-04) — core pipeline proven.** `AssetMesh.swift` loads a USD via ModelIO (plain-load, then per-mesh re-layout to the shader's `MazeVertex` packing — *forcing a vertexDescriptor at load time silently drops the geometry*) into a **32-bit index buffer**, drawn through the existing pipeline (bind the asset's vertex + `uint32` index buffers, one instance) — lit, shadowed, riding the world spin. Its **diffuse JPG** binds at a new texture slot (materialID 11; `maxTextureBindCount` 4→5). Guinea pig: `stone_fire_pit` (11.6k verts) renders with its real stone texture.
>
> **Findings / gotchas:** USD is **Z-up** (no re-orientation needed — the tile's local Z is already out-of-face); a forced load-time `vertexDescriptor` yields 0 meshes (re-lay-out per mesh instead); the macOS app is **sandboxed** (`ENABLE_APP_SANDBOX=YES`) so it can't read the external `Mazen_Models` folder — **dev shortcut in place: sandbox disabled + absolute paths.** Textures came as JPG diffuse + **EXR** normals (unreadable by ImageIO/`sips`; ImageMagick installed to convert EXR→PNG when we add normal maps).
>
> **M12-D ✅ (2026-07-05):** generalized to an `ImportedProp` registry; all five models load + render textured, placed at the plaza-centre tile + its four diagonal neighbours, each riding the world spin and casting shadows. Model stats (verts): fire pit 11.6k, **statue 44.8k**, **stump_01 123k**, **stump_02 187k**, **crate 52.8k (10 sub-meshes)** — the stumps are why 32-bit indices are required. The statue imports tiny (~0.22 native) and the crate's 10 parts (its open/closed geometry) are flattened into one draw for now.
>
> **Remaining:** **normal maps** (EXR→PNG via ImageMagick + tangent extraction for the asset material); the **crate open/closed** state (split its sub-meshes); wire imported props into the M10 prop system + a **house** model; bundle the models (folder reference) + re-enable the sandbox before shipping; scale / placement / winding polish (e.g. the high-poly stumps, the tiny statue's fit).

## Why this is a real pipeline, not a mesh swap

Every piece of geometry in the game today is generated procedurally into **one shared vertex buffer + UInt16 index buffer**, drawn instanced through a custom stylized shader with a fixed texture set. Dropping in a Poly Haven model needs four new capabilities:

1. **A mesh loader.** Apple's **ModelIO** (`MDLAsset`) natively reads **OBJ and USD/USDZ** — *not* glTF (Poly Haven's default). We grab an OBJ if offered, else one-click **export USDZ from Blender** (or convert). Extract position/normal/UV per vertex; map to our `MazeVertexSwift` layout.
2. **32-bit index buffers.** The shared buffer uses 16-bit indices (65,535-vertex ceiling); a detailed model blows past that, so imported meshes get their **own buffer with `MTLIndexType.uint32`**. (We also prefer the **low-poly / LOD** variant regardless — full-res Poly Haven meshes are heavy for a cube covered in props.)
3. **A textured material path.** Models ship PBR textures (albedo / normal / roughness). Our shader is stylized with a fixed texture set, so we add a material branch that samples the model's **own albedo (+ normal)**. Without this they'd render as flat-colored blobs — defeating the point.
4. **Normalization.** Scale to tile size, fix the up-axis (models are **Y-up**; tiles are **Z-up**), recenter to sit on the floor, and reconcile winding/normals with our cull setup (main pass culls back faces, shadow pass culls front).

## What it builds on (M10 prop system — already done)

- `Prop` / `PropKind` anchored to `MazeFacelet` → slice rotations carry props for free.
- `Prop.rotate(quarterTurns:)` spins sub-cell + facing in the `DirectionMask.rotated` sense (glued through finalization).
- Prop transform applies `facing` (`facing.rawValue · 45°`) — asymmetric props already supported.
- `materialID 10` = generic lit + shadow-**receiving** branch; props also **cast** (they ride the opaque draw list into the shadow pass).
- `TileMeshLibrary.propMesh(kind:)` + `SceneBuilder.propColors` — the lookup points where imported assets slot in.
- Placeholders to replace: `topiary` (sub-cell), `obelisk` (landmark), `chest` (interactive), `houseCorner` (multi-tile).

## Assets & formats

- **Licensing:** Poly Haven is **CC0** — free, no attribution.
- **Targets:** `tree_stump_01` → sub-cell decor (topiary slot); `island_tree_01` → landmark (obelisk slot); `stone_fire_pit` → interactive (chest slot; "light the fire" = the existing state toggle driving an emissive glow); **house model** (TBD source) → the G5 modular house.
- **Format:** OBJ or USDZ for ModelIO. Grab the **low-poly / lowest-res mesh** variant. User downloads and drops files into a `Models/` folder (bundle resources); the loader reads them at startup. (Claude can't fetch the binaries.)

## Phases (each independently buildable + verifiable)

### M12-A — Loader foundation
- New `AssetMesh` (own vertex `MTLBuffer` in `MazeVertexSwift` layout + a **`uint32`** index buffer). `MDLAsset` load of **one** model (the tree stump — lowest poly). Walk `MDLMesh` submeshes; map MDL position/normal/texcoord → `MazeVertexSwift` (`aoFactor = 1`).
- Render one instance **flat-colored** (materialID 10) at a fixed test spot on `positiveZ`, through a new draw path (separate buffer + `uint32` draw call). Confirm it joins the shadow pass (casts) and receives shadows.
- **Deliverable:** a gray stump on the cube, grounded with a shadow. No textures yet.

### M12-B — Normalization
- Auto-scale from the model's bounding box to a target footprint (per-asset). Axis fix Y-up → Z-up. Recenter so the base sits at `floorY`.
- Winding/normals: ensure CCW-outward for the main back-face cull **and** the shadow front-face cull; flip/recompute if imported the other way.
- Per-asset transform config (scale, rotation, offset) so each model is tunable.
- **Deliverable:** the stump sits correctly scaled/oriented on the floor.

### M12-C — Textured material
- Load per-model albedo (+ normal, optional roughness) via `MTKTextureLoader`.
- Texture binding: extend the fragment argument table — per-draw texture vs a growable **texture array** vs bindless (decide by asset count). Watch sRGB vs linear.
- Shader: a new `materialID` (e.g. 11) "textured asset" branch — sample albedo, optional normal-map through the existing TBN path, lit + shadowed like materialID 1.
- **Deliverable:** the stump renders with its real bark texture.

### M12-D — Prop-system integration
- Represent imported props: a `Prop.assetID` (registry index) with `kind = .imported`, or per-asset `PropKind` cases. A registry maps id → `AssetMesh` + material + transform.
- `SceneBuilder` emits imported props through the textured draw path; they inherit anchoring, facing rotation, slice-rotation carry, and shadows from the existing prop code.
- Swap the demo placeholders for stump / tree / fire pit.
- **Deliverable:** the demo props are real models.

### M12-E — House model + split
- Replace procedural `houseCorner` with an imported house. **Keep it modular** (M10 decision): 4 imported quarter-models (or one model pre-split into 4), placed exactly as the procedural quarters (same `facing` logic), so the Rubik's split survives. (Alternative — a single-tile model with no split — is simpler but loses the signature mechanic; not recommended.)
- **Deliverable:** a real house that still splits. → runs the house-split verification below.

### M12-F — Polish & perf
- LODs / decimation for distant props; instance many copies through one draw; texture memory budget (atlas or array cap — **`log()` any truncation**, don't silently drop); optional normal/roughness maps.

## Testing plan

### Loader / unit
- Smoke test per model: load succeeds; non-zero vertex/index counts; finite bounds; `maxIndex < vertexCount`.
- **`Prop.rotate` round-trip test** (extend `Tests/CoordinateMathTests.swift`): four `rotate(1)` calls = identity for both sub-cell and facing, across all starting states — guards the split's correctness at the math level (cheap insurance, same spirit as the R4 coordinate tests).

### Visual (per asset)
- Correct scale/orientation, base on the floor (not floating or sunk).
- Casts a shadow **and** receives shadows (front-/back-face cull both correct).
- Texture reads correctly — no obvious UV seams or mip issues; sRGB/linear correct.

### House-split verification — *deferred from M10 G5; the signature Rubik's mechanic, still UNPROVEN*
Applies to **both** the current procedural house and the M12-E imported house. The house is already placed at a face edge (`positiveZ` rows/cols 0–1) precisely so an adjacent face's max-layer slice contains *some* of its cubies.

1. **Assembled:** 4 quarters form one coherent building; roof peaks meet at the shared centre; courtyard doors present.
2. **Same-face rotation (control):** stand on `positiveZ`, press Q/E → the whole house rotates rigidly and **stays intact** (expected — the entire face layer moves together; this is *not* a split).
3. **Adjacent-face split:** walk onto the neighbour face (`positiveX`/`positiveY`) whose max-layer slice contains some-but-not-all house cubies; Q/E → that slice carries away the quarters it contains, **splitting the building at the tile seams** while the rest stays put.
4. **Reassemble:** rotate back → the quarters return and the house is whole again.
5. **Coherence:** during the animation each quarter rides its own tile's `animMat`; at finalization each quarter's `facing`/sub-cell rotate via `Prop.rotate` so pieces land correctly — verify no pop/misplacement (same class as the floor-`uvTurns` and player-sub-cell rotation work).
6. **Edge cases:** slices cutting 1, 2, 3, or all 4 quarters; a quarter carried onto a *different* face — does it reorient correctly on arrival?
- If pieces land misoriented, the fix is in `Prop.rotate` / the `facing → angle` mapping, mirroring the floor-UV direction fix.

### M9 interaction
- Imported meshes auto-join the shadow pass and are lit by the M9 sun/moon. Verify they self-shadow acceptably at low sun angles and that the textured material responds to the moving light like the procedural props.

## Decisions / open questions
- **Format:** OBJ vs USDZ (ModelIO) — settle when the user provides files.
- **Texture binding:** per-draw vs growable array vs bindless — pick in M12-C by asset count.
- **House:** modular (keep the split) vs single-model — **recommend modular.**
- **Asset location:** bundled Resources vs a runtime-loaded `Models/` folder.

## Risks
- ModelIO can't read glTF → a conversion step (Blender USDZ export) or a small glTF loader.
- Poly count / `uint32` buffers / texture memory at cube scale — use LODs, cap prop count, and log any truncation.
- Winding / normal / axis mismatches — the classic import gotchas; M12-B owns them, verified visually.
