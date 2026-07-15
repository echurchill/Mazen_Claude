"""Batch-export each per-model Blends/*.blend to its own USD, materials + textures included.

Run (Blender 5.2 LTS, ~30s for the whole pack):
    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
        --python Tools/export_quaternius_usd.py

Writes <pack>/USD/*.usdc + <pack>/USD/textures/. Those are DERIVED and gitignored along with the
rest of the pack, so re-run this after a fresh checkout / pack re-download — AssetRegistry loads
the nature props from USD at runtime.


Source choice matters: AllModels.blend is a compilation that REUSES materials across models
(its BirchTree_1 trunk is assigned PineTree_Bark, and no BirchTree_Bark material exists there),
so exporting from it would silently regress textures. The per-model blends match the OBJ naming
and are richer than the OBJ export — e.g. Flower_1_Clump has 2 materials in the blend but the
OBJ collapsed it to 1.

Per-object files because AssetMesh concatenates all meshes in a file into one vertex/index
buffer — one scene-wide USD would import as a single fused model.

export_textures_mode='NEW' writes real texture bytes next to the USD: several images are PACKED
inside the blends with stale Windows absolute filepaths, so 'KEEP' would emit dead references.
All exports share one output dir, so identically-named textures overwrite rather than duplicate.
"""
import bpy, os, glob

ROOT = "/Volumes/Code Work/xCode work/Mazen_Claude/Mazen_Models/Quaternius Ultimate Stylized Nature Pack"
OUT = os.path.join(ROOT, "USD")
os.makedirs(OUT, exist_ok=True)

blends = sorted(glob.glob(os.path.join(ROOT, "Blends", "*.blend")))
ok, fail, empty = 0, [], []

for bf in blends:
    name = os.path.splitext(os.path.basename(bf))[0]
    try:
        bpy.ops.wm.open_mainfile(filepath=bf)
    except Exception as e:
        fail.append((name, "open: " + str(e)[:80]))
        continue

    view_objs = bpy.context.view_layer.objects
    meshes = [o for o in bpy.data.objects if o.type == "MESH" and o.name in view_objs]
    if not meshes:
        empty.append(name)
        continue
    try:
        for s in view_objs:
            s.select_set(False)
        for o in meshes:                 # a model may legitimately be several objects
            o.hide_set(False)
            o.select_set(True)
        view_objs.active = meshes[0]
        bpy.ops.wm.usd_export(
            filepath=os.path.join(OUT, name + ".usdc"),
            selected_objects_only=True,
            export_materials=True,
            generate_preview_surface=True,   # UsdPreviewSurface — what ModelIO reads
            export_textures_mode="NEW",
            relative_paths=True,
        )
        ok += 1
    except Exception as e:
        fail.append((name, str(e)[:100]))

print("EXPORT ok=%d fail=%d empty=%d of %d blends" % (ok, len(fail), len(empty), len(blends)))
for f in fail[:8]:
    print("EXPORT FAIL", f)
if empty:
    print("EXPORT EMPTY", empty[:8])
